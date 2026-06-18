// =============================================================================
// Finished-job dashboards — measurement: slurm_accounting  (slurm-sacct.conf)
//
// One point per finished job, stamped at the job's END time, so these queries
// are naturally correct over time (no per-scrape re-emission). Copy ONE block,
// replace bucket "slurm". Requires Slurm accounting (slurmdbd).
// =============================================================================


// ── Panel: job throughput by outcome (time series) ───────────────────────────
// Jobs that finished per hour, split by final state (COMPLETED/FAILED/...).
from(bucket: "slurm")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "slurm_accounting" and r._field == "elapsed_sec")
  |> group(columns: ["state"])
  |> aggregateWindow(every: 1h, fn: count, createEmpty: false)
  |> rename(columns: {_value: "jobs"})


// ── Panel: CPU-hours by account (bar / table) ────────────────────────────────
// cpu_sec is CPU-seconds per job; sum and convert to CPU-hours per account.
from(bucket: "slurm")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "slurm_accounting" and r._field == "cpu_sec")
  |> group(columns: ["account"])
  |> sum()
  |> map(fn: (r) => ({r with _value: float(v: r._value) / 3600.0}))  // int field -> float
  |> rename(columns: {_value: "cpu_hours"})
  |> group()
  |> sort(columns: ["cpu_hours"], desc: true)


// ── Panel: failed / timed-out / cancelled jobs (table) ───────────────────────
from(bucket: "slurm")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "slurm_accounting" and r._field == "elapsed_sec")
  |> filter(fn: (r) => r.state != "COMPLETED")
  |> group(columns: ["state", "user", "account"])
  |> count()
  |> rename(columns: {_value: "jobs"})
  |> group()
  |> sort(columns: ["jobs"], desc: true)


// ── Panel: average job wait → run time (single stat) ─────────────────────────
// Average wall-clock runtime (seconds) of completed jobs in the range.
from(bucket: "slurm")
  |> range(start: -7d)
  |> filter(fn: (r) => r._measurement == "slurm_accounting" and r._field == "elapsed_sec" and r.state == "COMPLETED")
  |> group()
  |> mean()
  |> rename(columns: {_value: "avg_runtime_sec"})


// ── Panel: GPU-hours by account ──────────────────────────────────────────────
// gpus is the job's TOTAL GPUs (sacct AllocTRES). GPU-hours = gpus * elapsed/3600.
// Pivot gpus and elapsed_sec together per job, then sum per account.
from(bucket: "slurm")
  |> range(start: -30d)
  |> filter(fn: (r) => r._measurement == "slurm_accounting" and (r._field == "gpus" or r._field == "elapsed_sec"))
  |> keep(columns: ["job_id", "account", "_field", "_value"])
  |> pivot(rowKey: ["job_id", "account"], columnKey: ["_field"], valueColumn: "_value")
  |> map(fn: (r) => ({account: r.account, _value: float(v: r.gpus) * float(v: r.elapsed_sec) / 3600.0}))
  |> filter(fn: (r) => r._value > 0.0)
  |> group(columns: ["account"])
  |> sum()
  |> rename(columns: {_value: "gpu_hours"})
  |> group()
  |> sort(columns: ["gpu_hours"], desc: true)
