// =============================================================================
// Queue dashboards — source measurement: slurm_queue  (from slurm-squeue.conf)
//
// Copy ONE block at a time into InfluxDB Data Explorer (Script Editor) or a
// Grafana panel. Replace the bucket name "slurm" with yours. For Grafana, swap
// range(start: -5m) for range(start: v.timeRangeStart, stop: v.timeRangeStop).
//
// Data model: one point per job per scrape; job_id AND state are tags. A job
// that transitions PENDING->RUNNING therefore has TWO series (one per state).
// To count each job ONCE in its CURRENT state, we collapse per job_id first
// (group by job_id |> last() gives each job's most recent point) and only then
// group by state. Skipping that job_id collapse double-counts transitioned jobs.
// =============================================================================


// ── Panel: jobs by state (pie / stat) ───────────────────────────────────────
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()                              // one point per job = its current state
  |> group(columns: ["state"])
  |> count()
  |> rename(columns: {_value: "jobs"})


// ── Panel: CPUs in use by partition (bar gauge) ──────────────────────────────
// Total CPUs held by RUNNING jobs, per partition (current).
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
  |> filter(fn: (r) => r.state == "RUNNING")
  |> group(columns: ["partition"])
  |> sum()
  |> rename(columns: {_value: "cpus_in_use"})


// ── Panel: top users by job count (table) ────────────────────────────────────
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
  |> group(columns: ["user"])
  |> count()
  |> rename(columns: {_value: "jobs"})
  |> group()
  |> sort(columns: ["jobs"], desc: true)


// ── Panel: why are jobs pending? (table / pie) ───────────────────────────────
// reason is a tag (trimmed to a bounded set by the collector's regex processor).
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> group(columns: ["job_id"])
  |> last()
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
