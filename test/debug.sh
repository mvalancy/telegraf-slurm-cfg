#!/usr/bin/env bash
# debug.sh — run ONE Slurm collector through `telegraf --test` and print exactly
# what it would write to InfluxDB. The fastest way to debug a single plugin.
#
# Usage:
#   ./test/debug.sh squeue            # auto: use live Slurm if present, else fixture
#   ./test/debug.sh sdiag --fixture   # force the bundled sample (no cluster needed)
#   ./test/debug.sh sinfo --live      # force the real command
#
# Plugins: squeue | sinfo | sacct | sdiag
set -euo pipefail
. "$(cd "$(dirname "$0")" && pwd)/lib.sh"

plugin="${1:-}"
case " $PLUGINS " in *" $plugin "*) :;; *)
  echo "usage: $0 <squeue|sinfo|sacct|sdiag> [--fixture|--live]" >&2; exit 2;; esac

want=auto
case "${2:-}" in --fixture) want=fixture;; --live) want=live;; "") :;; *)
  echo "unknown option: $2 (use --fixture or --live)" >&2; exit 2;; esac
mode="$(collector_mode "$plugin" "$want")"

if ! command -v "$TELEGRAF" >/dev/null 2>&1; then
  echo "error: '$TELEGRAF' not found. Install Telegraf or set TELEGRAF=/path/to/telegraf" >&2; exit 1
fi

echo "── plugin=$plugin  mode=$mode  measurement=$(collector_measurement "$plugin")" >&2
echo "── config=$(collector_conf "$plugin")" >&2
[ "$mode" = fixture ] && echo "── fixture=$(collector_fixture "$plugin")" >&2
echo >&2
run_collector "$plugin" "$mode"
