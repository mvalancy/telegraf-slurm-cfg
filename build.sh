#!/usr/bin/env bash
# build.sh — assemble the copyable deploy package: a slim README, the LICENSE,
# and the telegraf.d/ config folder. Produces dist/<name>/ and a zip.
#
#   ./build.sh            -> dist/telegraf-slurm-cfg/  +  dist/telegraf-slurm-cfg.zip
#   ./build.sh v1.2.0     -> dist/telegraf-slurm-cfg-v1.2.0.zip
#
# The zip is what the GitHub release workflow attaches to each tagged release;
# it's also handy for copying onto an air-gapped cluster.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
NAME="telegraf-slurm-cfg"
VER="${1:-}"

command -v zip >/dev/null 2>&1 || { echo "error: 'zip' is required (apt install zip)"; exit 1; }

STAGE="$HERE/dist/$NAME"
rm -rf "$HERE/dist"
mkdir -p "$STAGE"
cp -r "$HERE/telegraf.d"          "$STAGE/telegraf.d"   # the collectors
cp -r "$HERE/dashboards"          "$STAGE/dashboards"   # copy-paste Flux queries
cp    "$HERE/LICENSE"             "$STAGE/LICENSE"
cp    "$HERE/packaging/README.md" "$STAGE/README.md"

zipname="$NAME${VER:+-$VER}.zip"
( cd "$HERE/dist" && zip -rq "$zipname" "$NAME" )

echo "Built:"
echo "  dist/$NAME/            ($(find "$STAGE" -type f | wc -l | tr -d ' ') files)"
echo "  dist/$zipname"
echo
echo "Contents:"
( cd "$HERE/dist" && find "$NAME" -type f | sort | sed 's/^/    /' )
echo
echo "Deploy: unzip, then copy telegraf.d/*.conf into /etc/telegraf/telegraf.d/ and restart telegraf."
