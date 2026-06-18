// =============================================================================
// Node / partition dashboards — measurement: slurm_nodes  (from slurm-sinfo.conf)
//
// Copy ONE block into InfluxDB Data Explorer or a Grafana panel. Replace the
// bucket name "slurm" with yours. sinfo already groups by (partition, state),
// so the `nodes` field is a node count per group.
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
from(bucket: "slurm")
  |> range(start: -5m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> filter(fn: (r) => r.state =~ /down|drain|fail|maint|unknown/)
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
