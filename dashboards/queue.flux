// =============================================================================
// Queue dashboards — source measurement: slurm_queue  (from slurm-squeue.conf)
//
// Copy ONE block at a time into InfluxDB Data Explorer (Script Editor) or a
// Grafana panel. Replace the bucket name "slurm" with yours. For Grafana, swap
// range(start: -15m) for range(start: v.timeRangeStart, stop: v.timeRangeStop).
//
// Data model: one point per job per scrape; job_id AND state are tags. Two
// gotchas the "current" panels below handle:
//   1. A job that went PENDING->RUNNING has TWO series — collapse per job_id
//      (group by job_id |> last()) so it's counted once, in its current state.
//   2. A job that already LEFT the queue still has an old last point. We drop it
//      with a recency filter — keep only points from the latest scrape:
//         |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
//      90s ≈ 2-3× the default 30s collection interval; set it to ~2-3× yours.
//      (Without this, finished jobs inflate the counts — e.g. CPUs-in-use can
//      read above a partition's real capacity.)
// =============================================================================


// ── Panel: jobs by state (pie / stat) ───────────────────────────────────────
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()                                                                  // each job's most recent point
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))  // jobs still in the queue now
  |> group(columns: ["state"])
  |> count()
  |> rename(columns: {_value: "jobs"})


// ── Panel: CPUs in use by partition (bar gauge) ──────────────────────────────
// Total CPUs held by RUNNING jobs, per partition (current).
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> filter(fn: (r) => r.state == "RUNNING")
  |> group(columns: ["partition"])
  |> sum()
  |> rename(columns: {_value: "cpus_in_use"})


// ── Panel: top users by job count (table) ────────────────────────────────────
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> group(columns: ["user"])
  |> count()
  |> rename(columns: {_value: "jobs"})
  |> group()
  |> sort(columns: ["jobs"], desc: true)


// ── Panel: why are jobs pending? (table / pie) ───────────────────────────────
// reason is a tag (trimmed to a bounded set by the collector's regex processor).
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> filter(fn: (r) => r.state == "PENDING")
  |> group(columns: ["reason"])
  |> count()
  |> rename(columns: {_value: "jobs"})


// ── Panel: running vs pending over time (time series) ────────────────────────
// `every` should match your squeue collection interval (default 30s) so each
// window holds one scrape — then each job is counted once per scrape in the
// state it had at that moment (it correctly moves from pending to running over
// time). Keep `every` == the interval; a larger window sums multiple scrapes.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> filter(fn: (r) => r.state == "RUNNING" or r.state == "PENDING")
  |> group(columns: ["state"])
  |> aggregateWindow(every: 30s, fn: count, createEmpty: false)
  |> rename(columns: {_value: "jobs"})


// ── Panel: GPUs in use by partition (now) ────────────────────────────────────
// gpus is GPUs PER NODE (squeue %b); a running job's total = gpus * nodes. Pivot
// the two fields together per job, multiply, then sum the running jobs per
// partition. Plot against slurm_nodes' "GPU capacity" panel to see GPUs free.
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r.state == "RUNNING")
  |> filter(fn: (r) => r._field == "gpus" or r._field == "nodes")
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> keep(columns: ["job_id", "partition", "_field", "_value"])
  |> pivot(rowKey: ["job_id", "partition"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({partition: r.partition, _value: r.gpus * r.nodes}))
  |> filter(fn: (r) => r._value > 0)
  |> group(columns: ["partition"])
  |> sum()
  |> rename(columns: {_value: "gpus_in_use"})


// ── Panel: GPUs held by user (now) ───────────────────────────────────────────
// Who's holding GPUs right now — sum of (gpus * nodes) over each user's running
// jobs. Handy for spotting who to ask when the GPU partition is full.
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r.state == "RUNNING")
  |> filter(fn: (r) => r._field == "gpus" or r._field == "nodes")
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> keep(columns: ["job_id", "user", "_field", "_value"])
  |> pivot(rowKey: ["job_id", "user"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({user: r.user, _value: r.gpus * r.nodes}))
  |> filter(fn: (r) => r._value > 0)
  |> group(columns: ["user"])
  |> sum()
  |> rename(columns: {_value: "gpus"})
  |> group()
  |> sort(columns: ["gpus"], desc: true)
