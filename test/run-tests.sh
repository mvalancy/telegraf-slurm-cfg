#!/usr/bin/env bash
# run-tests.sh — one command to test every collector and write an HTML report.
#
#   ./test/run-tests.sh                 # -> report.html
#   ./test/run-tests.sh /tmp/r.html     # custom output path
#   TELEGRAF=/opt/telegraf ./test/run-tests.sh
#
# What it does for each collector:
#   1. Runs `telegraf --test` against the real Slurm command if it produces
#      output, otherwise against the bundled sample fixture (so it works in CI
#      and on machines without a cluster).
#   2. Checks the expected measurement / tags / fields all appear.
#   3. If the `influx` CLI is configured, round-trips the data through InfluxDB
#      and verifies every numeric field is stored as long/double (plottable) —
#      not accidentally a string. (Skipped cleanly when InfluxDB isn't around.)
#
# The report records the git commit and OS / Telegraf / Slurm / InfluxDB
# versions so runs are reproducible and easy to compare as new versions ship.
# Exit code: 0 if everything passed, 1 otherwise.
set -uo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"
REPORT="${1:-$ROOT/report.html}"

ts="$(date -u +'%Y-%m-%d %H:%M:%S UTC')"
git_commit="$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo 'n/a')"
git -C "$ROOT" diff --quiet 2>/dev/null || git_commit="$git_commit (dirty)"
os_ver="$( . /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-$(uname -srm)}" )"
tg_ver="$("$TELEGRAF" --version 2>/dev/null | head -1 || echo 'not installed')"
slurm_ver="$(squeue --version 2>/dev/null || echo 'not installed — fixtures used')"
influx_ver="$(influxd version 2>/dev/null | head -1 || echo 'n/a (not required)')"

esc() { sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'; }

# ── 1+2. run each collector and check output ─────────────────────────────────
declare -A OUT MODE
total=0; passed=0; cards=""; console=""
for p in $PLUGINS; do
  total=$((total+1))
  conf="$(collector_conf "$p")"
  cmd="$(grep -m1 '^  commands' "$conf" | sed 's/^  commands = //')"
  out=""; mode="fixture"
  if command -v "$(collector_binary "$p")" >/dev/null 2>&1; then
    live="$(run_collector "$p" live)"
    [ -n "$live" ] && { out="$live"; mode="live"; }
  fi
  [ -z "$out" ] && { out="$(run_collector "$p" fixture)"; mode="fixture"; }
  OUT[$p]="$out"; MODE[$p]="$mode"
  rows="$(printf '%s' "$out" | grep -c . )"
  expect="$(collector_expect "$p")"; meas="${expect%% *}"
  fails=""
  for tok in $expect; do printf '%s' "$out" | grep -qF "$tok" || fails="$fails $tok"; done
  if [ -n "$out" ] && [ -z "$fails" ]; then status=PASS; passed=$((passed+1)); badge=pass
  else status=FAIL; badge=fail; [ -z "$out" ] && fails="$fails (no output)"; fi
  console="${console}  $(printf '%-7s %-8s %-4s' "$p" "$mode" "$status")  ${meas}\n"

  fixblock=""
  [ "$mode" = fixture ] && fixblock="<p class=lbl>fixture input</p><pre>$(head -3 "$(collector_fixture "$p")" | esc)</pre>"
  failblock=""; [ -n "$fails" ] && failblock="<p class=lbl>missing checks</p><pre class=bad>$(printf '%s' "$fails" | esc)</pre>"
  cards="${cards}
  <div class=card>
    <div class=cardhead><span class=name>$p &rarr; <code>$meas</code></span><span class='b $badge'>$status</span></div>
    <p class=meta>mode: <b>$mode</b> &middot; rows: <b>$rows</b> &middot; checks: <b>$(echo $expect | wc -w)</b></p>
    <p class=lbl>command</p><pre>$(printf '%s' "$cmd" | esc)</pre>
    $fixblock
    <p class=lbl>output (InfluxDB line protocol)</p><pre>$(printf '%s' "$out" | head -6 | esc)</pre>
    $failblock
  </div>"
done

# ── 3. round-trip through InfluxDB and query the schema BACK ──────────────────
# Write every collector's output to a throwaway bucket, then ask InfluxDB for
# each measurement's tag keys (+ example values) and field keys (+ stored type
# and an example value). This proves the data is really queryable — in whatever
# mode (live or fixture) each collector ran.
schema_section=""; type_fail=0
# NB: influx --raw CSV uses CRLF line endings — strip \r or names carry a trailing
# \r that breaks downstream filters and lookups.
tagkeys()   { influx query "import \"influxdata/influxdb/schema\" schema.measurementTagKeys(bucket:\"$1\", measurement:\"$2\")"   --raw 2>/dev/null | tr -d '\r' | awk -F, '/^,,/{print $4}' | grep -vE '^(_start|_stop|_field|_measurement)$'; }
tagvals()   { influx query "import \"influxdata/influxdb/schema\" schema.measurementTagValues(bucket:\"$1\", measurement:\"$2\", tag:\"$3\")" --raw 2>/dev/null | tr -d '\r' | awk -F, '/^,,/{print $4}'; }
fieldkeys() { influx query "import \"influxdata/influxdb/schema\" schema.measurementFieldKeys(bucket:\"$1\", measurement:\"$2\")" --raw 2>/dev/null | tr -d '\r' | awk -F, '/^,,/{print $4}'; }

if command -v influx >/dev/null 2>&1 && influx bucket list >/dev/null 2>&1; then
  B="slurm_cfg_selftest"
  influx bucket delete -n "$B" >/dev/null 2>&1
  if influx bucket create -n "$B" -r 0 >/dev/null 2>&1; then    # infinite retention (sacct stamps at job END time)
    for p in $PLUGINS; do printf '%s\n' "${OUT[$p]}" | influx write -b "$B" -p ns >/dev/null 2>&1; done
    blocks=""
    for p in $PLUGINS; do
      meas="$(collector_measurement "$p")"; numeric=" $(collector_numeric "$p") "
      trows=""
      for t in $(tagkeys "$B" "$meas"); do
        vals="$(tagvals "$B" "$meas" "$t" | head -6 | paste -sd, -)"
        trows="${trows}<tr><td><code>$t</code></td><td>$(printf '%s' "$vals" | esc)</td></tr>"
      done
      [ -n "$trows" ] || trows="<tr><td colspan=2 class=mut>(no data — this collector produced nothing in this environment)</td></tr>"
      frows=""
      for f in $(fieldkeys "$B" "$meas"); do
        res="$(influx query "from(bucket:\"$B\") |> range(start:-3650d) |> filter(fn:(r)=>r._measurement==\"$meas\" and r._field==\"$f\") |> last()" --raw 2>/dev/null | tr -d '\r')"
        dt="$(printf '%s' "$res" | awk -F, '/^#datatype/{print $7; exit}')"
        val="$(printf '%s' "$res" | awk -F, '/^,,/{print $7; exit}')"
        case "$dt" in
          long|double) badge="<span class='b pass'>plottable</span>";;
          boolean)     badge="<span class='b pass'>boolean</span>";;
          string)      badge="<span class=mut>label</span>";;
          *)           badge="<span class=mut>${dt:-—}</span>";;
        esac
        # fields we expect to be numeric must be long/double, or it's a real bug
        case "$numeric" in *" $f "*)
          case "$dt" in long|double) :;; *) badge="<span class='b fail'>NOT NUMERIC</span>"; type_fail=$((type_fail+1));; esac ;;
        esac
        frows="${frows}<tr><td><code>$f</code></td><td>${dt:-—}</td><td>$(printf '%s' "$val" | esc)</td><td>$badge</td></tr>"
      done
      [ -n "$frows" ] || frows="<tr><td colspan=4 class=mut>(no data)</td></tr>"
      blocks="${blocks}
      <div class=card>
        <div class=cardhead><span class=name><code>$meas</code></span><span class=meta>from $p &middot; ${MODE[$p]:-?} mode</span></div>
        <p class=lbl>tags &mdash; queried from InfluxDB</p>
        <table class=env><tr><th>tag</th><th>example values</th></tr>$trows</table>
        <p class=lbl>fields &mdash; queried from InfluxDB</p>
        <table class=env><tr><th>field</th><th>stored type</th><th>example</th><th></th></tr>$frows</table>
      </div>"
    done
    influx bucket delete -n "$B" >/dev/null 2>&1
    schema_section="<h2>InfluxDB round-trip — measurements, tags &amp; fields</h2><p class=sub>Each collector's line protocol was written to a throwaway bucket, then the tags and fields were queried back from InfluxDB. Numeric fields must be <code>long</code>/<code>double</code> to plot; strings/tags are labels by design.</p>$blocks"
  fi
else
  schema_section="<h2>InfluxDB round-trip</h2><p class=sub>Skipped — no <code>influx</code> CLI configured. Run on a host with InfluxDB to query the stored schema back.</p>"
fi

all_pass=$([ "$passed" -eq "$total" ] && [ "$type_fail" -eq 0 ] && echo yes || echo no)
sb=$([ "$all_pass" = yes ] && echo pass || echo fail)

cat > "$REPORT" <<HTML
<!doctype html><html lang=en><head><meta charset=utf-8>
<meta name=viewport content="width=device-width,initial-scale=1">
<title>telegraf-slurm-cfg — test report</title>
<style>
:root{--bg:#0f1419;--card:#1a2029;--ink:#e6e6e6;--mut:#8b97a7;--line:#2a323d;--ok:#2ea043;--no:#d1242f;--acc:#58a6ff}
*{box-sizing:border-box}body{margin:0;font:15px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;background:var(--bg);color:var(--ink)}
.wrap{max-width:920px;margin:0 auto;padding:32px 20px}h1{font-size:22px;margin:0 0 4px}h2{font-size:17px;margin:28px 0 6px}
.sub{color:var(--mut);margin:0 0 20px;font-size:13px}
.summary{display:flex;align-items:center;gap:14px;background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 20px;margin-bottom:20px}
.score{font-size:28px;font-weight:700}
table.env{width:100%;border-collapse:collapse;background:var(--card);border:1px solid var(--line);border-radius:12px;overflow:hidden;margin-bottom:8px}
table.env td,table.env th{padding:9px 16px;border-bottom:1px solid var(--line);text-align:left}table.env tr:last-child td{border-bottom:0}
table.env th{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em}
.card{background:var(--card);border:1px solid var(--line);border-radius:12px;padding:16px 20px;margin-bottom:16px}
.cardhead{display:flex;justify-content:space-between;align-items:center}.name{font-size:17px;font-weight:600}
.meta{color:var(--mut);margin:4px 0 10px;font-size:13px}
.lbl{color:var(--mut);font-size:12px;text-transform:uppercase;letter-spacing:.04em;margin:12px 0 4px}
code{color:var(--acc)}pre{background:#0b0f14;border:1px solid var(--line);border-radius:8px;padding:10px 12px;overflow:auto;font:12px/1.5 ui-monospace,Menlo,Consolas,monospace;margin:0}
pre.bad{color:#ffa198}
.b{font-weight:700;font-size:11px;padding:3px 9px;border-radius:20px;white-space:nowrap}
.b.pass{background:rgba(46,160,67,.15);color:#3fb950;border:1px solid var(--ok)}
.b.fail{background:rgba(209,36,47,.15);color:#ff7b72;border:1px solid var(--no)}
.foot{color:var(--mut);font-size:12px;text-align:center;margin-top:24px}
.mut{color:var(--mut)}
</style></head><body><div class=wrap>
<h1>telegraf-slurm-cfg — test report</h1>
<p class=sub>Monitoring Slurm with Telegraf config only — no scripts.</p>
<div class=summary><span class=score>$passed / $total</span><span class="b $sb">$([ "$all_pass" = yes ] && echo ALL PASSED || echo FAILURES)</span><span style="color:var(--mut)">collectors verified${type_fail:+ &middot; }$([ "$type_fail" -gt 0 ] && echo "$type_fail type problem(s)")</span></div>
<h2>Environment</h2>
<table class=env>
<tr><td>Generated</td><td>$ts</td></tr>
<tr><td>Git commit</td><td><code>$git_commit</code></td></tr>
<tr><td>OS</td><td>$(printf '%s' "$os_ver" | esc)</td></tr>
<tr><td>Telegraf</td><td>$(printf '%s' "$tg_ver" | esc)</td></tr>
<tr><td>Slurm</td><td>$(printf '%s' "$slurm_ver" | esc)</td></tr>
<tr><td>InfluxDB</td><td>$(printf '%s' "$influx_ver" | esc)</td></tr>
</table>
<h2>Collectors</h2>
$cards
$schema_section
<p class=foot>Re-run anytime with <code>./test/run-tests.sh</code>. Live Slurm is used automatically when present; otherwise bundled fixtures keep the test reproducible.</p>
</div></body></html>
HTML

echo "telegraf-slurm-cfg test run @ $ts"
echo "  git=$git_commit | telegraf=${tg_ver#Telegraf } | slurm=${slurm_ver#slurm }"
echo
printf "$console"
echo
echo "  $passed/$total collectors passed${type_fail:+, $type_fail type issue(s)}  ->  report: $REPORT"
[ "$all_pass" = yes ]
