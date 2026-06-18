#!/usr/bin/env bash
# docker-matrix.sh — run the full Docker validation across several Slurm versions
# (one per Ubuntu release), then roll the per-version reports up into a single
# cross-OS summary at test/reports/index.html.
#
#   ./test/docker-matrix.sh                          # default matrix
#   ./test/docker-matrix.sh ubuntu:24.04 debian:12   # custom set
#
# Ubuntu release -> Slurm version (approx):
#   20.04 -> 19.05   22.04 -> 21.08   24.04 -> 23.11   26.04 -> 25.11
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORTS="$HERE/reports"; mkdir -p "$REPORTS"
BASES=("$@"); [ ${#BASES[@]} -eq 0 ] && BASES=(ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04)

: > "$REPORTS/.matrix.tsv"   # fresh record file; docker-test.sh appends one row per version

declare -A RESULT
for base in "${BASES[@]}"; do
  echo; echo "############################################################"
  echo "# $base"
  echo "############################################################"
  if bash "$HERE/docker-test.sh" "$base"; then RESULT[$base]="PASS"; else RESULT[$base]="FAIL"; fi
done

# ── build the cross-OS summary report (index.html) ───────────────────────────
python3 - "$REPORTS/.matrix.tsv" "$REPORTS/index.html" <<'PY'
import sys, datetime, html
tsv, out = sys.argv[1], sys.argv[2]
rows = [l.rstrip("\n").split("\t") for l in open(tsv) if l.strip()]
def badge(cell):
    if "/" not in cell:
        return f'<span class=mut>{html.escape(cell)}</span>'
    mode, st = cell.split("/", 1)
    if st != "PASS":                                   # red — something failed
        return f'<span class="b fail">{html.escape(mode)} {html.escape(st)}</span>'
    if mode == "live":                                 # green — validated against real Slurm
        return '<span class="b pass">live</span>'
    return f'<span class=mut>{html.escape(mode)}</span>'  # muted — fixture (version can't do it live)
trs, npass = "", 0
for r in rows:
    osn, ver, rep = r[1], r[2], r[3]
    cells = r[4:8] if len(r) >= 8 else ["?"]*4
    if all(c.endswith("/PASS") for c in cells): npass += 1
    trs += "<tr><td>%s</td><td>%s</td>%s<td><a href=\"%s\">report</a></td></tr>" % (
        html.escape(osn), html.escape(ver), "".join(f"<td>{badge(c)}</td>" for c in cells), html.escape(rep))
ts = datetime.datetime.utcnow().strftime("%Y-%m-%d %H:%M:%S UTC")
sb = "pass" if rows and npass == len(rows) else "fail"
open(out, "w").write(f"""<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>telegraf-slurm-cfg — tested matrix</title>
<style>
:root{{--bg:#0f1419;--card:#1a2029;--ink:#e6e6e6;--mut:#8b97a7;--line:#2a323d;--ok:#2ea043;--no:#d1242f;--acc:#58a6ff}}
*{{box-sizing:border-box}}body{{margin:0;font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink)}}
.wrap{{max-width:840px;margin:0 auto;padding:32px 20px}}h1{{font-size:22px;margin:0 0 4px}}
.sub{{color:var(--mut);margin:0 0 20px;font-size:13px}}
.summary{{display:flex;align-items:center;gap:14px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 20px;margin-bottom:20px}}
.score{{font-size:28px;font-weight:700}}
table{{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden}}
td,th{{padding:10px 14px;border-bottom:1px solid var(--line);text-align:left}}tr:last-child td{{border-bottom:0}}
th{{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}}
a{{color:var(--acc)}}.b{{font-weight:700;font-size:11px;padding:3px 9px;border-radius:20px;white-space:nowrap}}
.b.pass{{background:rgba(46,160,67,.15);color:#3fb950;border:1px solid var(--ok)}}
.b.fail{{background:rgba(209,36,47,.15);color:#ff7b72;border:1px solid var(--no)}}
.mut{{color:var(--mut)}}.foot{{color:var(--mut);font-size:12px;text-align:center;margin-top:24px}}
</style></head><body><div class=wrap>
<h1>telegraf-slurm-cfg — tested across Slurm versions</h1>
<p class=sub>Each row is a real single-node Slurm cluster (with slurmdbd) brought up in Docker. Cells show whether each collector ran against <b>live</b> Slurm or a bundled fixture (older Slurm can't launch jobs on a cgroup-v2 host, and <code>sdiag --json</code> predates Slurm 23.02).</p>
<div class=summary><span class=score>{npass} / {len(rows)}</span><span class="b {sb}">{'ALL PASS' if sb=='pass' else 'FAILURES'}</span><span class=mut>OS / Slurm versions</span></div>
<table><tr><th>OS</th><th>Slurm</th><th>squeue</th><th>sinfo</th><th>sacct</th><th>sdiag</th><th></th></tr>
{trs}
</table>
<p class=foot>Generated {ts} &middot; re-run with <code>./test/docker-matrix.sh</code></p>
</div></body></html>""")
print(f"  summary: {out}  ({npass}/{len(rows)} versions fully live + passing)")
PY

echo; echo "============================================================"
echo "Matrix summary"
echo "============================================================"
fail=0
for base in "${BASES[@]}"; do
  printf "  %-16s %s\n" "$base" "${RESULT[$base]}"
  [ "${RESULT[$base]}" = PASS ] || fail=1
done
echo "  reports: test/reports/   (open test/reports/index.html for the matrix)"
exit $fail
