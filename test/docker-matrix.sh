#!/usr/bin/env bash
# docker-matrix.sh — run the full Docker validation across several Slurm versions
# (one per Ubuntu release) and print a summary. Each version's HTML report is
# saved under test/reports/.
#
#   ./test/docker-matrix.sh                       # default matrix
#   ./test/docker-matrix.sh ubuntu:24.04 debian:12   # custom set
#
# Ubuntu release -> Slurm version (approx):
#   20.04 -> 19.05   22.04 -> 21.08   24.04 -> 23.11   26.04 -> 24.x/25.x
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
BASES=("$@"); [ ${#BASES[@]} -eq 0 ] && BASES=(ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04)

declare -A RESULT
for base in "${BASES[@]}"; do
  echo; echo "############################################################"
  echo "# $base"
  echo "############################################################"
  if bash "$HERE/docker-test.sh" "$base"; then RESULT[$base]="PASS"; else RESULT[$base]="FAIL"; fi
done

echo; echo "============================================================"
echo "Matrix summary"
echo "============================================================"
fail=0
for base in "${BASES[@]}"; do
  printf "  %-16s %s\n" "$base" "${RESULT[$base]}"
  [ "${RESULT[$base]}" = PASS ] || fail=1
done
echo "  reports: test/reports/"
exit $fail
