// =============================================================================
// Scheduler-health dashboards — measurement: slurm_scheduler  (slurm-sdiag.conf)
//
// One point per scrape with ~40 numeric fields. Copy ONE block. Replace bucket
// name "slurm". Cycle-time fields are in MICROSECONDS.
// =============================================================================


// ── Panel: jobs pending vs running (time series) ─────────────────────────────
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_scheduler")
  |> filter(fn: (r) => r._field == "jobs_pending" or r._field == "jobs_running")
  |> aggregateWindow(every: 1m, fn: last, createEmpty: false)


// ── Panel: main scheduling cycle time, µs (time series) ──────────────────────
// Rising mean/max cycle time = the scheduler is working harder / falling behind.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_scheduler")
  |> filter(fn: (r) => r._field == "schedule_cycle_mean" or r._field == "schedule_cycle_max" or r._field == "schedule_cycle_last")
  |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)


// ── Panel: scheduler queue length (time series) ──────────────────────────────
// How many jobs the main scheduler had to consider each cycle.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_scheduler" and r._field == "schedule_queue_length")
  |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)


// ── Panel: backfill health (time series) ─────────────────────────────────────
// bf_queue_len = jobs the backfill scheduler looked at; bf_depth_mean = how deep
// it got; bf_cycle_mean (µs) = how long a backfill cycle took.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_scheduler")
  |> filter(fn: (r) => r._field == "bf_queue_len" or r._field == "bf_depth_mean" or r._field == "bf_cycle_mean")
  |> aggregateWindow(every: 5m, fn: mean, createEmpty: false)


// ── Panel: jobs backfilled, rate per interval (time series) ──────────────────
// bf_backfilled_jobs is a running counter since slurmctld start; difference()
// turns it into "jobs backfilled per window". nonNegative:true absorbs the reset
// to 0 on a slurmctld restart. Caveat: difference() spans gaps, so the value
// right after Telegraf/slurmctld downtime covers the whole gap, not just 10m —
// read spikes immediately after a data gap with that in mind.
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_scheduler" and r._field == "bf_backfilled_jobs")
  |> aggregateWindow(every: 10m, fn: last, createEmpty: false)
  |> difference(nonNegative: true)
  |> rename(columns: {_value: "backfilled_per_10m"})
