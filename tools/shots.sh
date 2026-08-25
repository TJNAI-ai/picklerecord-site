#!/usr/bin/env bash
# Render a page at three widths for visual review.
# Usage: bash tools/shots.sh index.html /tmp/shots
set -euo pipefail
PAGE="${1:?usage: shots.sh <page-path> <out-dir>}"
OUT="${2:?usage: shots.sh <page-path> <out-dir>}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NAME="$(echo "$PAGE" | sed 's#/#-#g; s#\.html$##')"
mkdir -p "$OUT"
for W in 390 768 1440; do
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --window-size="${W},1400" --force-device-scale-factor=2 \
    --virtual-time-budget=4000 \
    --screenshot="${OUT}/${NAME}-${W}.png" \
    "file://$(pwd)/${PAGE}" 2>/dev/null
  echo "wrote ${OUT}/${NAME}-${W}.png"
done
