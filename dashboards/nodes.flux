// =============================================================================
// Node / partition dashboards — measurement: slurm_nodes  (from slurm-sinfo.conf)
//
// Copy ONE block into InfluxDB Data Explorer or a Grafana panel. Replace the
// bucket name "slurm" with yours. sinfo already groups by (partition, state),
// so the `nodes` field is a node count per group.
//
// The "current" panels use last() to get each (partition,state) group's latest
// count, then a recency filter to drop groups that stopped being emitted (e.g.
// a partition that no longer has idle nodes) — otherwise last() would hold a
// stale count. 90s ≈ 2-3× the default 30s collection interval; tune to yours.
// =============================================================================


// ── Panel: nodes by state (pie / stat) ───────────────────────────────────────
// Cluster-wide node counts per state (idle / allocated / mixed / down / drain …)
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> group(columns: ["state"])
  |> sum()
  |> rename(columns: {_value: "nodes"})


// ── Panel: nodes by partition + state (table) ────────────────────────────────
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> group(columns: ["partition", "state"])
  |> sum()
  |> rename(columns: {_value: "nodes"})
  |> group()
  |> sort(columns: ["partition", "state"])


// ── Panel: problem nodes — down / drained / failing (stat, alert) ────────────
// Broad match over the unhealthy base states (the collector strips Slurm's
// flag-suffix chars, so e.g. "down~" is stored as "down").
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> filter(fn: (r) => r.state =~ /down|drain|fail|err|maint|unknown|reboot|power|invalid|future|planned/)
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
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


// ── Panel: GPU capacity by partition (configured) ────────────────────────────
// gpus_per_node is a TAG (sinfo %G). Total configured GPUs in a partition = sum
// over its (state) groups of gpus_per_node * nodes. Plot this against the queue
// dashboard's "GPUs in use" panel — the gap is GPUs free.
import "experimental"
from(bucket: "slurm")
  |> range(start: -15m)
  |> filter(fn: (r) => r._measurement == "slurm_nodes" and r._field == "nodes")
  |> last()
  |> filter(fn: (r) => r._time >= experimental.subDuration(d: 90s, from: now()))
  |> map(fn: (r) => ({partition: r.partition, _value: r._value * int(v: r.gpus_per_node)}))
  |> filter(fn: (r) => r._value > 0)
  |> group(columns: ["partition"])
  |> sum()
  |> rename(columns: {_value: "gpus_total"})
