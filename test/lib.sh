#!/usr/bin/env bash
# test/lib.sh — shared helpers for debugging and testing the collectors.
#
# The trick that makes these portable: a collector's .conf is the source of
# truth for the PARSER config. To test without a real Slurm cluster we only
# swap the `commands = [...]` line to `cat` a sample fixture, leaving the CSV /
# json_v2 parser config untouched — so we test the exact config that ships.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TELEGRAF="${TELEGRAF:-telegraf}"

PLUGINS="squeue sinfo sacct sdiag"

collector_conf()        { echo "$ROOT/telegraf.d/slurm-$1.conf"; }
collector_binary()      { echo "$1"; }   # squeue/sinfo/sacct/sdiag are the binaries
collector_measurement() {
  case "$1" in
    squeue) echo slurm_queue;; sinfo) echo slurm_nodes;;
    sacct)  echo slurm_accounting;; sdiag) echo slurm_scheduler;;
  esac
}
collector_fixture() {
  case "$1" in sdiag) echo "$ROOT/samples/sdiag.json";; *) echo "$ROOT/samples/$1.txt";; esac
}
# Things every collector's output must contain to count as "working".
collector_expect() {
  case "$1" in
    squeue) echo "slurm_queue partition= state= user= account= qos= cpus= nodes= job_id= reason=";;
    sinfo)  echo "slurm_nodes partition= state= nodes= cpus_state= memory_mb=";;
    sacct)  echo "slurm_accounting partition= state= user= account= qos= job_id= elapsed_sec= cpu_sec= exit_code=";;
    sdiag)  echo "slurm_scheduler jobs_pending= jobs_running= schedule_cycle_mean= bf_cycle_mean= server_thread_count=";;
  esac
}

# Fields that MUST be numeric (long/double) in InfluxDB so they can be plotted.
collector_numeric() {
  case "$1" in
    squeue) echo "cpus nodes priority";;
    sinfo)  echo "nodes";;   # memory_mb is intentionally a string (can be "192000+"/"N/A")
    sacct)  echo "cpus nodes elapsed_sec cpu_sec";;
    sdiag)  echo "jobs_pending jobs_running jobs_submitted schedule_cycle_mean bf_cycle_mean server_thread_count";;
  esac
}

# auto | live | fixture  → resolved mode
collector_mode() {
  local want="${2:-auto}"
  if [ "$want" != auto ]; then echo "$want"; return; fi
  if command -v "$(collector_binary "$1")" >/dev/null 2>&1; then echo live; else echo fixture; fi
}

# Print the line protocol a collector would emit. Args: plugin [live|fixture]
# Fixture mode swaps only the command (to `cat <fixture>`), keeping the real
# parser config. Uses a ["cat","<path>"] argv form so paths with spaces work,
# and surfaces telegraf's own errors if nothing came out.
run_collector() {
  local plugin="$1" mode="${2:-fixture}" conf tmp="" err out
  conf="$(collector_conf "$plugin")"
  if [ "$mode" = fixture ]; then
    tmp="$(mktemp)"
    # ONE command element ("cat '<path>'"); Telegraf treats each array element as
    # a separate command, so cat+path must be a single string. The single-quoted
    # path keeps spaces intact; `|` sed delimiter avoids clashing with '#' in paths.
    sed "s|^  commands = .*|  commands = [\"cat '$(collector_fixture "$plugin")'\"]|" "$conf" > "$tmp"
    conf="$tmp"
  fi
  err="$(mktemp)"
  out="$("$TELEGRAF" --test --config "$conf" 2>"$err" | sed 's/^> //')"
  # If a collector produced nothing, show telegraf's diagnostics (don't hide them).
  [ -z "$out" ] && [ -s "$err" ] && sed 's/^/  telegraf: /' "$err" >&2
  rm -f "$tmp" "$err"
  printf '%s\n' "$out"
}
