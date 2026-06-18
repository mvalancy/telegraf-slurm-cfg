#!/usr/bin/env bash
# docker-test.sh — validate every collector against a REAL Slurm cluster
# (with slurmdbd, so sacct works) running in Docker. Fully repeatable:
#   build image -> start cluster -> run test/run-tests.sh INSIDE the container
#   against live squeue/sinfo/sacct/sdiag -> save the HTML report.
#
#   ./test/docker-test.sh ubuntu:24.04      # one version
#   ./test/docker-matrix.sh                 # all the versions we test
#
# Reports land in test/reports/report-<os>-slurm-<version>.html (committed paper
# trail); docker-matrix.sh rolls them up into test/reports/index.html.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; ROOT="$(dirname "$HERE")"
BASE="${1:-ubuntu:24.04}"
slug="$(echo "$BASE" | tr ':/' '--')"
img="slurm-cfg-test:$slug"; name="slurmcfg-$slug"
reports="$ROOT/test/reports"; mkdir -p "$reports"

cleanup() { docker rm -f "$name" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "==> [$BASE] build image"
docker build -q -t "$img" --build-arg BASE="$BASE" "$HERE/docker" || { echo "build failed"; exit 1; }

cleanup
echo "==> [$BASE] start cluster"
# --privileged: slurmd needs writable cgroup v2 to launch job steps in a container
docker run -d --name "$name" --hostname slurmnode --privileged "$img" >/dev/null || { echo "run failed"; exit 1; }

echo -n "==> [$BASE] waiting for slurmctld "
up=no
for _ in $(seq 1 90); do
  docker inspect -f '{{.State.Status}}' "$name" 2>/dev/null | grep -q exited && break
  if docker exec "$name" bash -c 'sinfo >/dev/null 2>&1'; then up=yes; break; fi
  sleep 2; echo -n .
done
echo
if [ "$up" != yes ]; then
  echo "!! slurmctld did not start. Recent logs:"
  docker logs "$name" 2>&1 | tail -8
  docker exec "$name" bash -c 'tail -n 15 /var/log/slurm/slurmctld.log 2>/dev/null' || true
  exit 1
fi
# Best-effort: wait for a job to actually FINISH (terminal state) so the sacct
# collector has real completed-job data. Old Slurm can't run jobs on a v2 host;
# we cap the wait and proceed, falling back to the sacct fixture there.
echo -n "==> [$BASE] waiting for a completed job (best-effort) "
for _ in $(seq 1 45); do
  docker exec "$name" bash -c 'sacct -nX -S now-1hour --state=CD,F,TO,CA,NF,OOM 2>/dev/null | grep -q .' && break
  sleep 2; echo -n .
done
echo

ver="$(docker exec "$name" bash -c 'squeue --version' 2>/dev/null | awk '{print $2}')"
[ -n "$ver" ] || ver="$slug"   # fall back to the image slug so the report name is never empty/colliding
osname="$(docker exec "$name" bash -c '. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-'"$slug"'}"')"
echo "==> [$BASE] $osname / Slurm $ver — testing collectors against live cluster"

# copy the CURRENT repo configs/tests in and run the existing harness inside
docker exec "$name" rm -rf /cfg && docker exec "$name" mkdir -p /cfg
docker cp "$ROOT/telegraf.d" "$name":/cfg/telegraf.d
docker cp "$ROOT/samples"   "$name":/cfg/samples
docker cp "$ROOT/test"      "$name":/cfg/test

summary="$(docker exec -e TELEGRAF=/usr/local/bin/telegraf "$name" bash /cfg/test/run-tests.sh /cfg/report.html)"
rc=$?
printf '%s\n' "$summary"

# report named by OS image + Slurm version (e.g. report-ubuntu-24.04-slurm-23.11.4.html)
out="$reports/report-${slug}-slurm-${ver}.html"
docker cp "$name":/cfg/report.html "$out" 2>/dev/null && echo "==> [$BASE] saved $(basename "$out")"

# append a tab-separated record so docker-matrix.sh can build the cross-OS summary
rec="$(printf '%s\t%s\t%s\t%s' "$BASE" "$osname" "$ver" "$(basename "$out")")"
for plug in squeue sinfo sacct sdiag; do
  cell="$(printf '%s\n' "$summary" | awk -v p="$plug" '$1==p{print $2"/"$3; exit}')"
  rec="$rec$(printf '\t%s' "${cell:-?}")"
done
printf '%s\n' "$rec" >> "$reports/.matrix.tsv"
exit $rc
