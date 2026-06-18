#!/usr/bin/env bash
# refresh-reports.sh — rebuild EVERYTHING under test/reports/ with one command:
#
#   1. the cross-OS matrix  ->  report-ubuntu-<rel>-slurm-<ver>.html  +  index.html
#      (docker-matrix.sh: a real single-node Slurm cluster per version, in Docker)
#   2. the InfluxDB round-trip  ->  influxdb-roundtrip-example.html
#      (run-tests.sh writes the collectors into InfluxDB and queries the schema back)
#
# The round-trip example is genericized (this host's name/user -> login01/alice)
# so the committed report is a clean, shareable schema demonstration.
#
# Needs: Docker (for the matrix) and the `influx` CLI (for the round-trip).
#
#   ./test/refresh-reports.sh                  # default OS matrix (20.04/22.04/24.04/26.04)
#   ./test/refresh-reports.sh ubuntu:24.04     # just one (still refreshes the round-trip)
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPORTS="$HERE/reports"

echo "############ 1/2  Docker matrix → per-version reports + index.html ############"
bash "$HERE/docker-matrix.sh" "$@" || true

echo
echo "############ 2/2  InfluxDB round-trip → influxdb-roundtrip-example.html ############"
if command -v influx >/dev/null 2>&1 && influx bucket list >/dev/null 2>&1; then
  tmp="$(mktemp)"
  bash "$HERE/run-tests.sh" "$tmp" >/dev/null || true
  host="$(hostname -s 2>/dev/null || hostname)"; me="$(id -un 2>/dev/null || whoami)"
  gen="s/${host}/login01/g"
  [ -n "$me" ] && [ "$me" != root ] && gen="$gen; s/${me}/alice/g"   # don't touch 'root'
  sed "$gen" "$tmp" > "$REPORTS/influxdb-roundtrip-example.html"
  rm -f "$tmp"
  echo "  wrote $REPORTS/influxdb-roundtrip-example.html (host/user genericized to login01/alice)"
else
  echo "  SKIPPED — the 'influx' CLI isn't configured. The round-trip needs InfluxDB;"
  echo "           install/point the influx CLI at your instance and re-run."
fi

echo
echo "test/reports/ now contains:"
ls -1 "$REPORTS"/*.html 2>/dev/null | sed 's|.*/|  |'
