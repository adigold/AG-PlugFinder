#!/bin/bash
# Copies the Logic plugin pictures taken on this Mac into the app (Bundled/LogicScreenshots),
# as JPEG, so every user gets them without capturing Logic's plugins themselves (BL-21).
set -euo pipefail
cd "$(dirname "$0")/.."
SRC="$HOME/Library/Application Support/AG PlugFinder/Screenshots"
DST=Bundled/LogicScreenshots
mkdir -p "$DST"
n=0
for f in "$SRC"/logic-*.png; do
  [ -e "$f" ] || continue
  sips -s format jpeg -s formatOptions 82 "$f" --out "$DST/$(basename "${f%.png}").jpg" >/dev/null
  n=$((n + 1))
done
echo "Bundled $n Logic plugin pictures ($(du -sh "$DST" | cut -f1))"
