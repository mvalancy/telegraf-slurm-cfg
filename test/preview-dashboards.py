#!/usr/bin/env python3
"""
preview-dashboards.py — render sample images of the Slurm dashboards.

What it does:
  1. Simulates ~3 hours of a small cluster: jobs get submitted, scheduled onto
     four partitions (cpu / gpu / bigmem / debug), run for a while, and finish
     (some fail); a couple of nodes are down / drained for maintenance.
  2. Writes that history to a throwaway InfluxDB bucket ("slurm_demo").
  3. Runs the SAME queries the real dashboards in ../dashboards/ use, so the
     pictures reflect what you'd actually see in Grafana / InfluxDB.
  4. Saves one PNG per dashboard into test/dashboard/.

It exists so the committed preview images stay reproducible and the demo never
drifts far from the real queries. It is NOT needed to use the collectors — it's
a developer tool for refreshing the screenshots in the README.

Requirements:
  - python3 with matplotlib   (pip install matplotlib)
  - the `influx` CLI, already pointed at a local InfluxDB 2.x
    (the same setup test/run-tests.sh uses for its round-trip check)

Usage:
  python3 test/preview-dashboards.py                       # writes test/dashboard/
  python3 test/preview-dashboards.py --out /tmp/shots      # somewhere else
  python3 test/preview-dashboards.py --bucket my_demo      # different bucket name

The bucket is DELETED and recreated on every run, so never point --bucket at a
bucket that holds real data.
"""
import argparse
import os
import random
import re
import shutil
import subprocess
import tempfile
import time
import datetime as dt

HERE = os.path.dirname(os.path.abspath(__file__))

ap = argparse.ArgumentParser(description="Render sample images of the Slurm dashboards.")
ap.add_argument("--out", default=os.path.join(HERE, "dashboard"),
                help="output directory for the PNGs (default: test/dashboard/)")
ap.add_argument("--bucket", default="slurm_demo",
                help="InfluxDB bucket to (re)create and use (default: slurm_demo)")
args = ap.parse_args()

if not shutil.which("influx"):
    raise SystemExit("error: the `influx` CLI was not found on PATH.\n"
                     "Install InfluxDB's CLI and run `influx config` so it can reach "
                     "your local InfluxDB, then re-run this script.")
if subprocess.run(["influx", "bucket", "list"], stdout=subprocess.DEVNULL,
                  stderr=subprocess.DEVNULL).returncode != 0:
    raise SystemExit("error: the `influx` CLI is installed but not configured (or can't reach "
                     "InfluxDB).\nRun `influx config create ...` so it can talk to your local "
                     "InfluxDB (same setup test/run-tests.sh uses), then re-run this script.")

import matplotlib                       # noqa: E402  (after the influx preflight)
matplotlib.use("Agg")
import matplotlib.pyplot as plt          # noqa: E402
from matplotlib import dates as mdates   # noqa: E402

random.seed(7)                           # deterministic demo
BUCKET = args.bucket
OUT = args.out
os.makedirs(OUT, exist_ok=True)

SCRAPE = 60                              # seconds between samples (Telegraf interval)
WINDOW = 3 * 3600                        # simulate 3 hours
now = int(time.time())
t0 = now - WINDOW
NSC = WINDOW // SCRAPE

# partition -> total nodes, cpus/node, and how many sit down / drained (maintenance)
PARTS = {
    "cpu":    {"nodes": 16, "cpn": 32, "down": 0, "drain": 1},
    "gpu":    {"nodes": 8,  "cpn": 16, "down": 1, "drain": 0},
    "bigmem": {"nodes": 4,  "cpn": 64, "down": 0, "drain": 1},
    "debug":  {"nodes": 2,  "cpn": 16, "down": 0, "drain": 0},
}
PART_W = {"cpu": 42, "gpu": 26, "bigmem": 18, "debug": 14}
JOB_SIZES = {"cpu": [16, 32, 64, 128], "gpu": [16, 32, 64], "bigmem": [64, 128, 192], "debug": [8, 16, 32]}
USERS = ["alice", "bob", "carol", "dave", "erin", "frank"]
ACCTS = {"alice": "physics", "bob": "chem", "carol": "chem", "dave": "ml", "erin": "bio", "frank": "ml"}
QOS = ["normal", "long", "high"]

def sched_cpus(p):
    c = PARTS[p]
    return (c["nodes"] - c["down"] - c["drain"]) * c["cpn"]

# Realistic squeue pending reasons. "sched" is a placeholder resolved per-scrape
# to Resources (partition full) or Priority (waiting its turn); the rest are
# fixed per job so the "why pending" panel shows a believable spread.
REASON_POOL = ["sched", "Priority", "Dependency",
               "QOSMaxJobsPerUserLimit", "AssocGrpCpuLimit", "ReqNodeNotAvail"]
REASON_W = [50, 14, 14, 9, 7, 6]

# ── generate a job population ────────────────────────────────────────────────
part_names = list(PARTS)
part_weights = [PART_W[p] for p in part_names]
jobs = []
for jid in range(1, 241):
    part = random.choices(part_names, weights=part_weights)[0]
    cpn = PARTS[part]["cpn"]
    cpus = min(random.choice(JOB_SIZES[part]), sched_cpus(part))
    u = random.choice(USERS)
    # submission burst around the 1h mark so the queue fills then drains
    if random.random() < 0.55:
        sub = t0 + int(random.gauss(3600, 900))
    else:
        sub = t0 + random.randint(-1800, WINDOW - 600)
    sub = max(t0 - 1800, min(sub, now - 120))
    dur = (random.randint(4, 20) if part == "debug" else random.randint(8, 95)) * 60
    fs = random.choices(["COMPLETED", "FAILED", "TIMEOUT", "CANCELLED"], weights=[72, 16, 7, 5])[0]
    jobs.append(dict(id=jid, part=part, cpus=cpus, nodes=max(1, -(-cpus // cpn)),
                     user=u, acct=ACCTS[u], qos=random.choice(QOS), sub=sub, dur=dur,
                     fs=fs, start=None, end=None, prio=4294900000 - jid * 7,
                     rbase=random.choices(REASON_POOL, weights=REASON_W)[0]))
jobs.sort(key=lambda j: j["sub"])

# ── forward simulation (per-partition FIFO with blocking → realistic queues) ──
lp = []
running, pending, started = [], [], set()
alloc = {p: 0 for p in PARTS}
cum = dict(submitted=0, started=0, completed=0, canceled=0, failed=0)
bf_total = 0
for k in range(NSC + 1):
    t = t0 + k * SCRAPE
    for j in running[:]:
        if t - j["start"] >= j["dur"]:
            j["end"] = t; running.remove(j); alloc[j["part"]] -= j["cpus"]
            cum["completed" if j["fs"] == "COMPLETED" else ("canceled" if j["fs"] == "CANCELLED" else "failed")] += 1
            el = j["end"] - j["start"]; cps = el * j["cpus"]
            lp.append(f'slurm_accounting,job_id={j["id"]},partition={j["part"]},state={j["fs"]},'
                      f'user={j["user"]},account={j["acct"]},qos={j["qos"]} '
                      f'cpus={j["cpus"]}i,nodes={j["nodes"]}i,elapsed_sec={el}i,cpu_sec={cps}i,'
                      f'req_mem="{j["cpus"]*2}Gn",exit_code="{0 if j["fs"]=="COMPLETED" else 1}:0" {j["end"]}')
    for j in jobs:
        if j["sub"] <= t and j["id"] not in started and j not in pending and j not in running and j["end"] is None:
            pending.append(j); cum["submitted"] += 1
    blocked = set()
    for j in list(pending):
        if j["part"] in blocked:
            continue
        if alloc[j["part"]] + j["cpus"] <= sched_cpus(j["part"]):
            j["start"] = t; alloc[j["part"]] += j["cpus"]; pending.remove(j); running.append(j)
            started.add(j["id"]); cum["started"] += 1
            if random.random() < 0.4:
                bf_total += 1
        else:
            blocked.add(j["part"])
    # slurm_queue points (one per job per scrape; job_id AND state are tags)
    for j in running:
        lp.append(f'slurm_queue,job_id={j["id"]},partition={j["part"]},state=RUNNING,user={j["user"]},'
                  f'account={j["acct"]},qos={j["qos"]},reason=None cpus={j["cpus"]}i,nodes={j["nodes"]}i,priority={j["prio"]}i {t}')
    for j in pending:
        if j["rbase"] == "sched":
            reason = "Resources" if j["part"] in blocked else "Priority"
        else:
            reason = j["rbase"]
        lp.append(f'slurm_queue,job_id={j["id"]},partition={j["part"]},state=PENDING,user={j["user"]},'
                  f'account={j["acct"]},qos={j["qos"]},reason={reason} cpus={j["cpus"]}i,nodes={j["nodes"]}i,priority={j["prio"]}i {t}')
    # slurm_nodes points — split each partition into allocated / mixed / idle,
    # plus the constant down / drained maintenance nodes.
    for p, c in PARTS.items():
        cpn = c["cpn"]; sched_nodes = c["nodes"] - c["down"] - c["drain"]; a = alloc[p]
        full = min(a // cpn, sched_nodes)
        partial = 1 if (a % cpn) and full < sched_nodes else 0
        idle = sched_nodes - full - partial
        mem = f'memory_mb="{cpn*8000}"'
        if full:        lp.append(f'slurm_nodes,partition={p},state=allocated nodes={full}i,{mem} {t}')
        if partial:     lp.append(f'slurm_nodes,partition={p},state=mixed nodes={partial}i,{mem} {t}')
        if idle:        lp.append(f'slurm_nodes,partition={p},state=idle nodes={idle}i,{mem} {t}')
        if c["down"]:   lp.append(f'slurm_nodes,partition={p},state=down nodes={c["down"]}i,{mem} {t}')
        if c["drain"]:  lp.append(f'slurm_nodes,partition={p},state=drained nodes={c["drain"]}i,{mem} {t}')
    # slurm_scheduler point
    npend, nrun = len(pending), len(running)
    cyc = int(700 + npend * 35 + random.gauss(0, 80))
    lp.append(f'slurm_scheduler,host=login01 jobs_pending={npend},jobs_running={nrun},'
              f'jobs_submitted={cum["submitted"]},jobs_started={cum["started"]},jobs_completed={cum["completed"]},'
              f'jobs_failed={cum["failed"]},jobs_canceled={cum["canceled"]},'
              f'schedule_cycle_mean={cyc},schedule_cycle_last={int(cyc*random.uniform(.5,1.5))},'
              f'schedule_cycle_max={int(cyc*random.uniform(2,5))},schedule_queue_length={npend},'
              f'bf_backfilled_jobs={bf_total},bf_queue_len={npend},bf_depth_mean={min(npend,50)},'
              f'bf_cycle_mean={int(cyc*1.8)},server_thread_count=3,agent_queue_size={max(0,npend//10)} {t}')

print(f"generated {len(lp)} points over {WINDOW//3600}h; writing to bucket '{BUCKET}' ...")
subprocess.run(["influx", "bucket", "delete", "-n", BUCKET], stderr=subprocess.DEVNULL)
subprocess.run(["influx", "bucket", "create", "-n", BUCKET, "-r", "0"], check=True, stdout=subprocess.DEVNULL)
lp_path = os.path.join(tempfile.gettempdir(), f"{BUCKET}.lp")
with open(lp_path, "w") as f:
    f.write("\n".join(lp))
subprocess.run(["influx", "write", "-b", BUCKET, "-p", "s", "-f", lp_path], check=True)

# ── query helper ─────────────────────────────────────────────────────────────
# The simulated history ends at "now", so the dashboards' relative ranges
# (range(start: -15m), -4h, ...) and the recency filter (now()) all line up with
# the data without any rewriting.
B = f'from(bucket:"{BUCKET}")'

def q(flux):
    proc = subprocess.run(["influx", "query", flux, "--raw"],
                          capture_output=True, text=True, timeout=90)
    if proc.returncode != 0:
        raise SystemExit(f"influx query failed (so the preview would be blank):\n{proc.stderr}\n"
                         f"offending query:\n{flux}")
    raw = proc.stdout
    rows, cols = [], None
    for line in raw.replace("\r", "").splitlines():
        if not line.strip():
            cols = None; continue
        if line.startswith("#"):
            continue
        parts = line.split(",")
        if cols is None:
            cols = parts
        else:
            rows.append(dict(zip(cols, parts)))
    return rows

# ── plot styling ─────────────────────────────────────────────────────────────
plt.rcParams.update({"figure.facecolor": "#0f1419", "axes.facecolor": "#1a2029",
    "axes.edgecolor": "#2a323d", "axes.labelcolor": "#e6e6e6", "text.color": "#e6e6e6",
    "xtick.color": "#8b97a7", "ytick.color": "#8b97a7", "grid.color": "#2a323d",
    "axes.titlecolor": "#e6e6e6", "font.size": 9})
ACC = ["#58a6ff", "#3fb950", "#d29922", "#ff7b72", "#bc8cff", "#39c5cf"]
PART_COLOR = {"cpu": "#58a6ff", "gpu": "#bc8cff", "bigmem": "#d29922", "debug": "#39c5cf"}
STATE_COLOR = {"idle": "#3fb950", "allocated": "#58a6ff", "mixed": "#39c5cf",
               "down": "#ff7b72", "drained": "#d29922"}

def parse_t(s):
    s = re.sub(r'(\.\d{6})\d+', r'\1', s.replace("Z", "+00:00"))
    return dt.datetime.fromisoformat(s)

def fmt_time(ax):
    ax.xaxis.set_major_formatter(mdates.DateFormatter("%H:%M")); ax.grid(True, alpha=.3)

def series(rows, key):
    d = {}
    for r in rows:
        d.setdefault(r.get(key, "?"), []).append((parse_t(r["_time"]), float(r["_value"])))
    for k in d:
        d[k].sort()
    return d

# The "current" panels below mirror dashboards/*.flux verbatim — same job_id
# collapse + recency filter — so they double as a check that those queries work.
RECENT = 'filter(fn:(r)=>r._time>=experimental.subDuration(d:90s,from:now()))'

# ════════════════════════════ QUEUE dashboard ═══════════════════════════════
fig, ax = plt.subplots(2, 2, figsize=(11, 7)); fig.suptitle("slurm_queue — the queue (squeue)", fontsize=14, fontweight="bold")
# running vs pending over time
d = series(q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_queue" and r._field=="cpus")|>filter(fn:(r)=>r.state=="RUNNING" or r.state=="PENDING")|>group(columns:["state"])|>aggregateWindow(every:60s,fn:count,createEmpty:false)'), "state")
for i, (st, pts) in enumerate(sorted(d.items())):
    ax[0, 0].plot([p[0] for p in pts], [p[1] for p in pts], label=st, color=ACC[i], lw=2)
ax[0, 0].set_title("running vs pending over time"); ax[0, 0].legend(); fmt_time(ax[0, 0]); ax[0, 0].set_ylabel("jobs")
# cpus in use by partition (current)
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_queue" and r._field=="cpus")|>group(columns:["job_id"])|>last()|>{RECENT}|>filter(fn:(r)=>r.state=="RUNNING")|>group(columns:["partition"])|>sum()')
parts = [r["partition"] for r in rows]; vals = [float(r["_value"]) for r in rows]
o = sorted(range(len(parts)), key=lambda i: -vals[i]); parts = [parts[i] for i in o]; vals = [vals[i] for i in o]
ax[0, 1].bar(parts, vals, color=[PART_COLOR.get(p, ACC[0]) for p in parts]); ax[0, 1].set_title("CPUs in use by partition (now)"); ax[0, 1].set_ylabel("cpus")
for x, v in zip(parts, vals):
    ax[0, 1].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=8)
# top users by job count (current)
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_queue" and r._field=="cpus")|>group(columns:["job_id"])|>last()|>{RECENT}|>group(columns:["user"])|>count()|>group()|>sort(columns:["_value"],desc:true)')
us = [r["user"] for r in rows]; uv = [float(r["_value"]) for r in rows]
ax[1, 0].bar(us, uv, color=ACC[0]); ax[1, 0].set_title("top users by jobs in queue (now)"); ax[1, 0].set_ylabel("jobs")
for x, v in zip(us, uv):
    ax[1, 0].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=8)
# pending reasons (current) — horizontal bar, largest on top
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_queue" and r._field=="cpus")|>group(columns:["job_id"])|>last()|>{RECENT}|>filter(fn:(r)=>r.state=="PENDING")|>group(columns:["reason"])|>count()')
rs = [r["reason"] for r in rows]; rv = [float(r["_value"]) for r in rows]
order = sorted(range(len(rs)), key=lambda i: rv[i])      # ascending → largest ends on top
rs = [rs[i] for i in order]; rv = [rv[i] for i in order]
ax[1, 1].barh(rs, rv, color=ACC[3]); ax[1, 1].set_title("why jobs are pending (now)"); ax[1, 1].set_xlabel("jobs")
for i, v in enumerate(rv):
    ax[1, 1].text(v, i, f" {int(v)}", va="center", fontsize=8)
fig.tight_layout(rect=[0, 0, 1, .96]); fig.savefig(f"{OUT}/dashboard-queue.png", dpi=110); plt.close(fig)

# ════════════════════════════ NODES dashboard ═══════════════════════════════
fig, ax = plt.subplots(2, 2, figsize=(11, 7)); fig.suptitle("slurm_nodes — node health (sinfo)", fontsize=14, fontweight="bold")
# nodes by state (now)
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_nodes" and r._field=="nodes")|>last()|>{RECENT}|>group(columns:["state"])|>sum()')
st = [r["state"] for r in rows]; nv = [float(r["_value"]) for r in rows]
o = sorted(range(len(st)), key=lambda i: -nv[i]); st = [st[i] for i in o]; nv = [nv[i] for i in o]
ax[0, 0].bar(st, nv, color=[STATE_COLOR.get(s, "#8b97a7") for s in st]); ax[0, 0].set_title("nodes by state (now)"); ax[0, 0].set_ylabel("nodes")
for x, v in zip(st, nv):
    ax[0, 0].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=8)
# nodes by partition + state (stacked)
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_nodes" and r._field=="nodes")|>last()|>{RECENT}|>group(columns:["partition","state"])|>sum()')
grid = {}
for r in rows:
    grid.setdefault(r["state"], {})[r["partition"]] = float(r["_value"])
pcols = list(PARTS)
bottom = {p: 0.0 for p in pcols}
for s in ["allocated", "mixed", "idle", "drained", "down"]:
    if s not in grid:
        continue
    vals = [grid[s].get(p, 0.0) for p in pcols]
    ax[0, 1].bar(pcols, vals, bottom=[bottom[p] for p in pcols], label=s, color=STATE_COLOR.get(s, "#8b97a7"))
    for p in pcols:
        bottom[p] += grid[s].get(p, 0.0)
ax[0, 1].set_title("nodes by partition + state (now)"); ax[0, 1].set_ylabel("nodes"); ax[0, 1].legend(fontsize=7)
# problem nodes by state (now)
rows = q(f'import "experimental"\n{B}|>range(start:-15m)|>filter(fn:(r)=>r._measurement=="slurm_nodes" and r._field=="nodes")|>filter(fn:(r)=>r.state=~/down|drain|fail|err|maint|unknown|reboot|power|invalid|future|planned/)|>last()|>{RECENT}|>group(columns:["state"])|>sum()')
ps = [r["state"] for r in rows]; pv = [float(r["_value"]) for r in rows]
if ps:
    ax[1, 0].bar(ps, pv, color=[STATE_COLOR.get(s, "#ff7b72") for s in ps])
    for x, v in zip(ps, pv):
        ax[1, 0].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=8)
else:
    ax[1, 0].text(.5, .5, "no problem nodes", ha="center", va="center", transform=ax[1, 0].transAxes)
ax[1, 0].set_title("problem nodes — down / drained (now)"); ax[1, 0].set_ylabel("nodes")
# idle nodes over time
d = series(q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_nodes" and r._field=="nodes" and r.state=="idle")|>group(columns:["partition"])|>aggregateWindow(every:60s,fn:last,createEmpty:false)'), "partition")
for p, pts in sorted(d.items()):
    ax[1, 1].plot([x[0] for x in pts], [x[1] for x in pts], label=p, color=PART_COLOR.get(p, ACC[0]), lw=2)
ax[1, 1].set_title("idle nodes over time (free capacity)"); ax[1, 1].legend(fontsize=7); fmt_time(ax[1, 1]); ax[1, 1].set_ylabel("idle nodes")
fig.tight_layout(rect=[0, 0, 1, .95]); fig.savefig(f"{OUT}/dashboard-nodes.png", dpi=110); plt.close(fig)

# ════════════════════════════ SCHEDULER dashboard ═══════════════════════════
fig, ax = plt.subplots(2, 2, figsize=(11, 7)); fig.suptitle("slurm_scheduler — scheduler health (sdiag)", fontsize=14, fontweight="bold")

def sched(field):
    return [(parse_t(r["_time"]), float(r["_value"])) for r in q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_scheduler" and r._field=="{field}")|>aggregateWindow(every:2m,fn:mean,createEmpty:false)')]

for i, f in enumerate(["jobs_pending", "jobs_running"]):
    p = sched(f); ax[0, 0].plot([x[0] for x in p], [x[1] for x in p], label=f, color=ACC[i], lw=2)
ax[0, 0].set_title("jobs pending vs running"); ax[0, 0].legend(); fmt_time(ax[0, 0])
p = sched("schedule_cycle_mean"); ax[0, 1].plot([x[0] for x in p], [x[1] for x in p], color=ACC[2], lw=2)
ax[0, 1].fill_between([x[0] for x in p], [x[1] for x in p], color=ACC[2], alpha=.15)
ax[0, 1].set_title("main schedule cycle mean (µs)"); fmt_time(ax[0, 1])
p = sched("schedule_queue_length"); ax[1, 0].plot([x[0] for x in p], [x[1] for x in p], color=ACC[3], lw=2)
ax[1, 0].fill_between([x[0] for x in p], [x[1] for x in p], color=ACC[3], alpha=.15)
ax[1, 0].set_title("scheduler queue length"); fmt_time(ax[1, 0])
p = sched("bf_backfilled_jobs"); ax[1, 1].plot([x[0] for x in p], [x[1] for x in p], color=ACC[4], lw=2)
ax[1, 1].set_title("backfilled jobs (cumulative)"); fmt_time(ax[1, 1])
fig.tight_layout(rect=[0, 0, 1, .96]); fig.savefig(f"{OUT}/dashboard-scheduler.png", dpi=110); plt.close(fig)

# ════════════════════════════ ACCOUNTING dashboard ══════════════════════════
fig, ax = plt.subplots(2, 2, figsize=(11, 7)); fig.suptitle("slurm_accounting — finished jobs (sacct)", fontsize=14, fontweight="bold")
d = series(q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_accounting" and r._field=="elapsed_sec")|>group(columns:["state"])|>aggregateWindow(every:20m,fn:count,createEmpty:false)'), "state")
for i, (st, pts) in enumerate(sorted(d.items())):
    ax[0, 0].plot([x[0] for x in pts], [x[1] for x in pts], label=st, marker="o", color=ACC[i], lw=2)
ax[0, 0].set_title("jobs finished per 20m, by outcome"); ax[0, 0].legend(fontsize=7); fmt_time(ax[0, 0]); ax[0, 0].set_ylabel("jobs")
rows = q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_accounting" and r._field=="cpu_sec")|>group(columns:["account"])|>sum()|>map(fn:(r)=>({{r with _value: float(v:r._value)/3600.0}}))')
ac = [r["account"] for r in rows]; av = [float(r["_value"]) for r in rows]
o = sorted(range(len(ac)), key=lambda i: -av[i]); ac = [ac[i] for i in o]; av = [av[i] for i in o]
ax[0, 1].bar(ac, av, color=ACC[0]); ax[0, 1].set_title("CPU-hours by account"); ax[0, 1].set_ylabel("cpu-hours")
for x, v in zip(ac, av):
    ax[0, 1].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=7)
rows = q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_accounting" and r._field=="elapsed_sec")|>group(columns:["state"])|>count()')
st = [r["state"] for r in rows]; sv = [float(r["_value"]) for r in rows]
o = sorted(range(len(st)), key=lambda i: -sv[i]); st = [st[i] for i in o]; sv = [sv[i] for i in o]
cols = [ACC[1] if s == "COMPLETED" else ACC[3] for s in st]
ax[1, 0].bar(st, sv, color=cols); ax[1, 0].set_title("finished jobs by outcome (3h)"); ax[1, 0].set_ylabel("jobs")
for x, v in zip(st, sv):
    ax[1, 0].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=8)
rows = q(f'{B}|>range(start:-4h)|>filter(fn:(r)=>r._measurement=="slurm_accounting" and r._field=="elapsed_sec")|>group(columns:["user"])|>mean()')
us = [r["user"] for r in rows]; uv = [float(r["_value"]) / 60 for r in rows]
o = sorted(range(len(us)), key=lambda i: -uv[i]); us = [us[i] for i in o]; uv = [uv[i] for i in o]
ax[1, 1].bar(us, uv, color=ACC[5]); ax[1, 1].set_title("avg runtime by user (min)"); ax[1, 1].set_ylabel("minutes")
for x, v in zip(us, uv):
    ax[1, 1].text(x, v, f" {int(v)}", va="bottom", ha="center", fontsize=7)
fig.tight_layout(rect=[0, 0, 1, .96]); fig.savefig(f"{OUT}/dashboard-accounting.png", dpi=110); plt.close(fig)

print("rendered:", ", ".join(sorted(f for f in os.listdir(OUT) if f.endswith(".png"))), "->", OUT)
