# Dashboard queries

A starter cookbook of [Flux](https://docs.influxdata.com/flux/) queries for
building Slurm dashboards from the data these collectors produce. Each `.flux`
file groups several copy-paste **panel queries**, one per `// ── Panel: …`
block.

| File | Measurement | Example panels |
|------|-------------|----------------|
| [`queue.flux`](queue.flux) | `slurm_queue` | jobs by state, CPUs in use, top users, pending reasons, running-vs-pending trend |
| [`nodes.flux`](nodes.flux) | `slurm_nodes` | nodes by state, problem (down/drain) nodes, idle capacity |
| [`scheduler.flux`](scheduler.flux) | `slurm_scheduler` | scheduling cycle time, queue length, backfill health |
| [`accounting.flux`](accounting.flux) | `slurm_accounting` | job throughput, CPU-hours by account, failures |

## How to use

**InfluxDB Data Explorer** — open Data Explorer → *Script Editor*, paste one
panel block, set your time range, and *Submit*. Save it to a cell on an
InfluxDB dashboard.

**Grafana** (InfluxDB datasource in Flux mode) — paste a block into a panel
query. For Grafana's time picker and auto interval, replace:

```flux
  |> range(start: -24h)                              // becomes:
  |> range(start: v.timeRangeStart, stop: v.timeRangeStop)

  |> aggregateWindow(every: 30s, ...)                // becomes:
  |> aggregateWindow(every: v.windowPeriod, ...)
```

## Before you run them

- **Change the bucket name.** Every query uses `bucket: "slurm"` — set it to
  the bucket your Telegraf output writes to.
- **Match the trend window to your scrape interval.** Count-over-time panels use
  `aggregateWindow(every: 30s, …)`; 30s is the collectors' default `interval`.
  If you changed it, change `every` to match so each window is one scrape.
- **Retention.** `slurm_queue` and `slurm_accounting` carry `job_id` as a tag,
  so series count grows with the number of distinct jobs. Send them to a bucket
  with retention that fits how much history you want (e.g. 30 days). Node and
  scheduler data are low-cardinality and can live anywhere.

## Notes on correctness

- `slurm_queue` re-emits every job each scrape, so "current" panels use
  `last()` to take each job's latest sample before counting/summing.
- `slurm_accounting` writes one point per finished job, stamped at the job's end
  time — so its time-series panels are naturally correct (no re-emission).
- Cycle-time fields in `slurm_scheduler` are **microseconds**.
