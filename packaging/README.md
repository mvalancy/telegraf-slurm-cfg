# telegraf-slurm-cfg

**Monitor a Slurm cluster with Telegraf — just copy these config files. No scripts.**

This package is a set of drop-in [Telegraf](https://github.com/influxdata/telegraf)
collectors for [Slurm](https://slurm.schedmd.com/). Each `.conf` runs a standard
Slurm command and lets Telegraf's built-in parsers turn the output into metrics —
nothing to maintain, no wrapper scripts.

Full docs, dashboards, and tests:
**https://github.com/mvalancy/telegraf-slurm-cfg**

## New to this?

- **Slurm** schedules jobs on a shared cluster (`squeue` = the queue, `sinfo` = the nodes).
- **Telegraf** is a small agent that collects numbers and ships them to a database.
- **InfluxDB** stores the time-series numbers; **Grafana** graphs them.

Flow: **Slurm command → Telegraf → InfluxDB → Grafana.**

## Install

First, unzip this package on the machine that runs Slurm commands and `cd` in:

```bash
# `unzip` not installed? add it first:
#   Debian/Ubuntu: sudo apt-get install -y unzip   •   RHEL/Rocky: sudo dnf install -y unzip
unzip telegraf-slurm-cfg-*.zip
cd telegraf-slurm-cfg
```

Then:

1. **Install Telegraf** on a machine that can run `squeue`/`sinfo` (a login or
   controller node). See
   [InfluxData's install guide](https://docs.influxdata.com/telegraf/v1/install/).

2. **Add an InfluxDB output once** in `/etc/telegraf/telegraf.conf`:

   ```toml
   [[outputs.influxdb_v2]]
     urls = ["http://YOUR_INFLUX_HOST:8086"]
     token = "YOUR_WRITE_TOKEN"
     organization = "YOUR_ORG"
     bucket = "slurm"
   ```

3. **Copy the collectors you want** and restart Telegraf:

   ```bash
   sudo cp telegraf.d/*.conf /etc/telegraf/telegraf.d/
   sudo systemctl restart telegraf
   ```

4. **Using `slurm-sacct.conf`? Give the `telegraf` user accounting access.**
   `sacct --allusers` only returns *other* users' finished jobs if the user
   running it (the `telegraf` user) has Slurm **operator** privilege — otherwise
   the accounting collector silently sees only its own (empty) jobs. Grant it once,
   as a Slurm admin:

   ```bash
   sudo sacctmgr -i modify user telegraf set adminlevel=Operator
   # if the telegraf user isn't in the accounting DB yet, add it first:
   sudo sacctmgr -i add user telegraf account=root adminlevel=Operator
   ```

   (`squeue` / `sinfo` / `sdiag` need no special privilege.)

5. **Check one first** (runs it once, prints what *would* be written, touches nothing):

   ```bash
   telegraf --test --config telegraf.d/slurm-squeue.conf
   ```

## What's in the box

| File | Measurement | What it tracks |
|------|-------------|----------------|
| `slurm-squeue.conf` | `slurm_queue` | jobs in the queue (running / pending, by partition, user, reason) |
| `slurm-sinfo.conf` | `slurm_nodes` | node counts per partition + state (idle / allocated / down / drain) |
| `slurm-sacct.conf` | `slurm_accounting` | finished jobs (throughput, failures, CPU-hours) — needs `slurmdbd` |
| `slurm-sdiag.conf` | `slurm_scheduler` | scheduler health (cycle times, queue length, backfill) — needs Slurm 23.02+ |

Telegraf adds a `host` tag automatically. Uncomment the `[inputs.exec.tags]`
block in any file to add a static `cluster` tag.

## Requirements & gotchas

- **Telegraf 1.19+** (for the `json_v2` parser used by `slurm-sdiag.conf`; the
  `csv` parser used by the others is much older).
- **`sacct`** needs Slurm accounting (`slurmdbd`) enabled, and the telegraf user
  needs privilege to read other users' accounting.
- **`sdiag --json`** needs Slurm **23.02+**.
- **Can't find `squeue`?** Slurm often lives in `/opt/slurm/bin` while Telegraf's
  PATH is minimal — uncomment the `environment = ["PATH=…"]` line in each `.conf`,
  or use an absolute path.
- High-cardinality note: `slurm_queue` / `slurm_accounting` tag by `job_id`, so
  send them to a bucket with short retention (e.g. 7–30 days).

## Dashboards

The [`dashboards/`](dashboards/) folder (included in this package) is a copy-paste
[Flux](https://docs.influxdata.com/flux/) cookbook for InfluxDB Data Explorer or
Grafana — queue, nodes, scheduler, and accounting panels. Each `// ── Panel: …`
block is one graph; change the bucket name to yours and paste it in.

## License

[MIT](LICENSE)
