// =============================================================================
// Queue dashboards — source measurement: slurm_queue  (from slurm-squeue.conf)
//
// Copy ONE block at a time into InfluxDB Data Explorer (Script Editor) or a
// Grafana panel. Replace the bucket name "slurm" with yours. For Grafana, swap
// range(start: -5m) for range(start: v.timeRangeStart, stop: v.timeRangeStop).
//
// Data model reminder: one point per job per scrape; job_id is a tag (unique),
// so we use last() to take each job's most recent sample, then count/sum.
// =============================================================================


// ── Panel: jobs by state (pie / stat) ───────────────────────────────────────
// How many jobs are RUNNING vs PENDING vs ... right now.
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> last()
  |> group(columns: ["state"])
  |> count()
  |> rename(columns: {_value: "jobs"})


// ── Panel: CPUs in use by partition (bar gauge) ──────────────────────────────
// Total CPUs held by RUNNING jobs, per partition.
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus" and r.state == "RUNNING")
  |> last()
  |> group(columns: ["partition"])
  |> sum()
  |> rename(columns: {_value: "cpus_in_use"})


// ── Panel: top users by job count (table) ────────────────────────────────────
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> last()
  |> group(columns: ["user"])
  |> count()
  |> rename(columns: {_value: "jobs"})
  |> group()
  |> sort(columns: ["jobs"], desc: true)


// ── Panel: why are jobs pending? (table / pie) ───────────────────────────────
// reason is a tag, so we can group by it directly.
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus" and r.state == "PENDING")
  |> last()
  |> group(columns: ["reason"])
  |> count()
  |> rename(columns: {_value: "jobs"})


// ── Panel: running vs pending over time (time series) ────────────────────────
// `every` should match your squeue collection interval (default 30s) so each
// window holds one scrape = a true job count. Increase the range as needed.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_queue" and r._field == "cpus")
  |> filter(fn: (r) => r.state == "RUNNING" or r.state == "PENDING")
  |> group(columns: ["state"])
  |> aggregateWindow(every: 30s, fn: count, createEmpty: false)
  |> rename(columns: {_value: "jobs"})
