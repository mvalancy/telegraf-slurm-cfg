// =============================================================================
// Node / partition dashboards — measurement: slurm_nodes  (from slurm-sinfo.conf)
//
// Copy ONE block into InfluxDB Data Explorer or a Grafana panel. Replace the
// bucket name "slurm" with yours. sinfo already groups by (partition, state),
// so the `nodes` field is a node count per group.
//
// Note: these "current" panels use last() over a short window. When a
// (partition,state) group empties, sinfo stops emitting it, so last() can hold a
// stale count until the window slides past. Keep the range close to a couple of
// scrape intervals (e.g. -2m to -5m) to bound that staleness.
// =============================================================================


// ── Panel: nodes by state (pie / stat) ───────────────────────────────────────
// Cluster-wide node counts per state (idle / allocated / mixed / down / drain …)
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> last()
  |> group(columns: ["state"])
  |> sum()
  |> rename(columns: {_value: "nodes"})


// ── Panel: nodes by partition + state (table) ────────────────────────────────
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> last()
  |> group(columns: ["partition", "state"])
  |> sum()
  |> rename(columns: {_value: "nodes"})
  |> group()
  |> sort(columns: ["partition", "state"])


// ── Panel: problem nodes — down / drained / failing (stat, alert) ────────────
// Broad match over the unhealthy base states (the collector strips Slurm's
// flag-suffix chars, so e.g. "down~" is stored as "down").
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> filter(fn: (r) => r.state =~ /down|drain|fail|err|maint|unknown|reboot|power|invalid|future|planned/)
  |> last()
  |> group()
  |> sum()
  |> rename(columns: {_value: "unhealthy_nodes"})


// ── Panel: idle node capacity over time (time series) ────────────────────────
from(bucket: "slurm")
  |> range(start: -24h)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes" and r.state == "idle")
  |> group(columns: ["partition"])
  |> aggregateWindow(every: 30s, fn: last, createEmpty: false)
  |> rename(columns: {_value: "idle_nodes"})
