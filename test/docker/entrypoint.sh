#!/usr/bin/env bash
# Bring up a single-node Slurm cluster WITH slurmdbd (so sacct has real data)
# inside a container — no systemd. Picks binary names that vary across distro
# versions (mariadbd-safe vs mysqld_safe, mungekey vs create-munge-key), so the
# same script works from Ubuntu 20.04 through 26.04. Driven by ../docker-test.sh.
set -e
log() { echo "[entrypoint] $*"; }
pick() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 && { echo "$c"; return; }; done; }

MARIADBD="$(pick mariadbd-safe mysqld_safe)"
DBADMIN="$(pick mariadb-admin mysqladmin)"
DBCLI="$(pick mariadb mysql)"
DBINIT="$(pick mariadb-install-db mysql_install_db)"
NODE="$(hostname -s)"
CPUS="$(nproc)"

# Config dir moved from /etc/slurm-llnl (Slurm <= 20.11 on Debian/Ubuntu) to
# /etc/slurm (newer). Use whichever the package created.
SLURMDIR=/etc/slurm
[ -d /etc/slurm ] || { [ -d /etc/slurm-llnl ] && SLURMDIR=/etc/slurm-llnl; }
install -d "$SLURMDIR"

# Version from dpkg (config-independent — `sbatch --version` needs a config first
# on old Slurm, so we can't rely on it here).
SVER="$(dpkg-query -W -f='${Version}' slurm-wlm 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | head -1)"; SVER="${SVER:-0.0}"
SMAJ="${SVER%%.*}"; SMIN="${SVER#*.}"; SMIN="${SMIN%%.*}"
VNUM=$(( 10#$SMAJ * 100 + 10#$SMIN ))   # 23.11 -> 2311, 21.08 -> 2108, 19.05 -> 1905
log "Slurm $SVER (vnum $VNUM), config dir $SLURMDIR"

# config_overrides (register the node despite the container's CPU topology) is a
# 20.02+ option; older Slurm used FastSchedule and rejects it.
OVERRIDES=""; [ "$VNUM" -ge 2002 ] && OVERRIDES="SlurmdParameters=config_overrides"

# ── munge ────────────────────────────────────────────────────────────────────
if [ ! -s /etc/munge/munge.key ]; then
  /usr/sbin/mungekey --create --keyfile /etc/munge/munge.key 2>/dev/null \
    || /usr/sbin/create-munge-key -f 2>/dev/null \
    || dd if=/dev/urandom of=/etc/munge/munge.key bs=1024 count=1 2>/dev/null
fi
chown munge:munge /etc/munge/munge.key; chmod 400 /etc/munge/munge.key
install -d -o munge -g munge /run/munge
runuser -u munge -- /usr/sbin/munged --force
log "munge up"

# ── mariadb (Slurm accounting store) ─────────────────────────────────────────
install -d -o mysql -g mysql /run/mysqld /var/lib/mysql /var/lib/mysql/tmp
chmod 1777 /tmp   # InnoDB writes temp files here; some base images ship /tmp non-sticky
[ -d /var/lib/mysql/mysql ] || $DBINIT --user=mysql --datadir=/var/lib/mysql --auth-root-authentication-method=normal >/dev/null 2>&1
$MARIADBD --user=mysql --datadir=/var/lib/mysql --tmpdir=/var/lib/mysql/tmp >/var/log/mariadb.log 2>&1 &
for _ in $(seq 1 60); do $DBADMIN ping >/dev/null 2>&1 && break; sleep 1; done
$DBCLI -e "CREATE DATABASE IF NOT EXISTS slurm_acct_db;
 CREATE USER IF NOT EXISTS 'slurm'@'localhost' IDENTIFIED BY 'slurmpass';
 GRANT ALL ON slurm_acct_db.* TO 'slurm'@'localhost'; FLUSH PRIVILEGES;"
log "mariadb up ($MARIADBD)"

# ── directories ──────────────────────────────────────────────────────────────
install -d -o slurm -g slurm /var/spool/slurmctld /var/log/slurm
install -d /var/spool/slurmd

# ── slurmdbd ─────────────────────────────────────────────────────────────────
cat >"$SLURMDIR/slurmdbd.conf" <<EOF
DbdHost=localhost
SlurmUser=slurm
StorageType=accounting_storage/mysql
StorageHost=localhost
StorageUser=slurm
StoragePass=slurmpass
StorageLoc=slurm_acct_db
LogFile=/var/log/slurm/slurmdbd.log
PidFile=/run/slurmdbd.pid
EOF
chown slurm:slurm "$SLURMDIR/slurmdbd.conf"; chmod 600 "$SLURMDIR/slurmdbd.conf"

# ── slurm.conf (NodeName matches this container's hostname) ───────────────────
cat >"$SLURMDIR/slurm.conf" <<EOF
ClusterName=testcluster
SlurmctldHost=$NODE
AuthType=auth/munge
ProctrackType=proctrack/linuxproc
TaskPlugin=task/none
SwitchType=switch/none
MpiDefault=none
ReturnToService=2
SlurmctldPidFile=/run/slurmctld.pid
SlurmdPidFile=/run/slurmd.pid
SlurmdSpoolDir=/var/spool/slurmd
StateSaveLocation=/var/spool/slurmctld
SlurmUser=slurm
SlurmdUser=root
SchedulerType=sched/backfill
SelectType=select/cons_tres
SelectTypeParameters=CR_Core
AccountingStorageType=accounting_storage/slurmdbd
AccountingStorageHost=localhost
JobAcctGatherType=jobacct_gather/linux
SlurmctldLogFile=/var/log/slurm/slurmctld.log
SlurmdLogFile=/var/log/slurm/slurmd.log
$OVERRIDES
NodeName=$NODE CPUs=$CPUS State=UNKNOWN
PartitionName=debug Nodes=$NODE Default=YES MaxTime=INFINITE State=UP
PartitionName=gpu   Nodes=$NODE MaxTime=INFINITE State=UP
EOF

# cgroup/v2 with IgnoreSystemd is a 23.02+ feature. On a v2-only host, older
# Slurm (cgroup/v1) can't launch steps — that's fine: slurmctld still serves
# squeue/sinfo/sdiag and the harness falls back to fixtures for sacct.
if [ "$VNUM" -ge 2302 ]; then
  cat >"$SLURMDIR/cgroup.conf" <<EOF
CgroupPlugin=autodetect
IgnoreSystemd=yes
EOF
  mkdir -p /sys/fs/cgroup/system.slice 2>/dev/null || true   # slurmd creates its scope here
fi

# Start slurmdbd now that slurm.conf exists. (Slurm CLIs block up to 60s
# retrying a missing slurm.conf, so the config MUST exist before any sacctmgr.)
slurmdbd || log "slurmdbd failed to start"
for _ in $(seq 1 20); do sacctmgr -i list cluster >/dev/null 2>&1 && break; sleep 1; done
log "slurmdbd up"

sacctmgr -i add cluster testcluster >/dev/null 2>&1 || true
# Daemon start is non-fatal: on old Slurm slurmd may not init cgroups, but we
# still want slurmctld up for the read-only collectors.
slurmctld || log "slurmctld failed to start"; sleep 2
slurmd    || log "slurmd failed to start (no job execution on this version/host)"; sleep 3
# nudge the node out of UNKNOWN/DOWN until it reports idle
for _ in $(seq 1 15); do
  scontrol update nodename="$NODE" state=resume reason=boot >/dev/null 2>&1 || true
  if sinfo -hN -o '%t' 2>/dev/null | grep -qE 'idle|mix|alloc'; then break; fi
  sleep 2
done

# accounting needs an account + association so jobs carry a real account tag
sacctmgr -i add account physics Description=test >/dev/null 2>&1 || true
sacctmgr -i add user root account=physics >/dev/null 2>&1 || true

# 1) short job on the (still empty) node so it RUNS and COMPLETES fast — this is
#    what gives sacct real finished-job data. Wait for it before flooding the
#    node, otherwise the long jobs below would starve it and it'd never run.
WJ="$(sbatch -p debug -A physics -J warmup --wrap 'sleep 2' 2>/dev/null | awk '{print $NF}')"
for _ in $(seq 1 25); do
  [ "$(sacct -nX -j "${WJ:-0}" -o State%30 2>/dev/null | tr -d ' \n')" = COMPLETED ] && break
  sleep 2
done
# 2) flood with longer jobs so squeue shows RUNNING *and* PENDING (the latter
#    exercises the pending-reason tag).
for i in $(seq 1 20); do
  sbatch -p debug -A physics -c 2 -J "job$i" --wrap 'sleep 900' >/dev/null 2>&1 || true
done

log "slurm ready: $(sinfo --version 2>/dev/null)"
exec tail -f /dev/null
