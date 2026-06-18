# Docker test harness

Spin up a **real, single-node Slurm cluster (with `slurmdbd`)** in a container
and run every collector against it — so `sacct` and `sdiag --json` are validated
against *live* Slurm, not just fixtures. Used to test multiple Slurm versions by
picking the base image.

## Run it

```bash
./test/docker-test.sh ubuntu:24.04     # one version  -> Slurm 23.11
./test/docker-matrix.sh                 # the default matrix (20.04/22.04/24.04/26.04)
```

Each run builds the image, brings the cluster up, runs `test/run-tests.sh`
*inside* the container against live `squeue`/`sinfo`/`sacct`/`sdiag`, and saves
`test/reports/report-slurm-<version>.html`.

## Slurm version per base image

| Base image     | Slurm  | `sdiag --json` |
|----------------|--------|----------------|
| `ubuntu:20.04` | 19.05  | no (text only) |
| `ubuntu:22.04` | 21.08  | no (text only) |
| `ubuntu:24.04` | 23.11  | yes            |
| `ubuntu:26.04` | 24.x+  | yes            |

(`debian:12` → 22.05, `debian:13` → 24.11 also work.)

## How the container comes up (`entrypoint.sh`)

No systemd, so the stack is started by hand, in order:

1. **munge** — auth daemon (key generated on first boot).
2. **mariadb** — Slurm's accounting store (own tmpdir so InnoDB works in a container).
3. **slurmdbd** — accounting daemon, pointed at mariadb.
4. **slurmctld + slurmd** — controller + node. `cgroup.conf` uses
   `IgnoreSystemd=yes` and the container runs `--privileged` so cgroup v2 works
   without systemd; `SlurmdParameters=config_overrides` lets the node register
   despite the container's CPU topology.
5. **sacctmgr** registers a cluster/account/user, then a short job is submitted
   that **completes** (so `sacct` has real finished-job data) plus several longer
   jobs (so `squeue` shows RUNNING and PENDING).

## Notes

- Requires `--privileged` (slurmd needs writable cgroup v2 to launch steps).
- Older Slurm (19.05/21.08) has no `sdiag --json`; that collector falls back to
  the bundled fixture there — visible as `mode: fixture` in the report.
- This is **test-only** infrastructure. The collectors themselves
  (`telegraf.d/*.conf`) remain pure config with no scripts.
