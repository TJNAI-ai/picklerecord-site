#!/usr/bin/env bash
# Render a page at three widths for visual review.
# Usage: bash tools/shots.sh index.html /tmp/shots
#
# Serves the page over http://127.0.0.1 (not file://) because the site uses
# root-absolute asset paths (/assets/site.css, /assets/icon-64.png, ...).
# Under file://, a leading "/" resolves against the filesystem root, so none
# of the CSS or images would load.
#
# --- The sub-500px floor -------------------------------------------------
# Headless Chrome refuses to lay out a page below an ~500px viewport: ask
# for --window-size=390,1400 and it silently lays the page out at
# innerWidth=500, then scales the rendered image down to fit the requested
# 390px frame. Verified empirically: requesting 490 *or* 500 both report
# innerWidth=500 (500 is the exact floor, not just "roughly 500"); 501
# reports 501 and is genuine from there up. So a "390px screenshot" from a
# naive direct render is really a 500px layout wearing a 390px picture
# frame, and every @media rule below 500px never evaluates.
#
# Fix: for any width below the floor, render through an iframe harness --
# a wrapper page sized comfortably above the floor (1000x1450) containing
# an <iframe> set to the true target width/height and pointing at the real
# page, then crop the capture down to the iframe's box. Media queries
# evaluate against the iframe's own viewport, so this genuinely lays the
# page out at the requested width. Widths at/above the floor (768, 1440
# here) are rendered directly, since a direct render is already faithful
# there and the extra iframe indirection buys nothing.
#
# The harness file is written into tools/ (which tools/check.py's page
# walker already skips) under a per-run unique dotfile name, served by the
# same http.server so its root-absolute iframe src resolves, and removed
# by cleanup() on every exit path -- see HARNESS_FILE below.
set -euo pipefail
PAGE="${1:?usage: shots.sh <page-path> <out-dir>}"
OUT="${2:?usage: shots.sh <page-path> <out-dir>}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NAME="$(echo "$PAGE" | sed 's#/#-#g; s#\.html$##')"
mkdir -p "$OUT"

DOCROOT="$(pwd)"
SERVER_LOG="$(mktemp)"
SERVER_PID=""
HARNESS_FILE=""
RAW_SHOT=""

# Chrome's floor is exactly 500 (see the block comment above); anything
# requested at or below it needs the harness. HEIGHT matches the capture
# height the direct path has always used -- keep both paths in sync.
FLOOR=500
HEIGHT=1400
SCALE=2

CLEANED_UP=""
cleanup() {
  [[ -n "$CLEANED_UP" ]] && return 0
  CLEANED_UP=1
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$SERVER_LOG" "$HARNESS_FILE" "$RAW_SHOT"
}
# A trapped signal runs its handler and then execution falls through to the
# next statement -- it does not itself terminate the script. Without an
# explicit exit in each signal's own trap, termination on INT/TERM/HUP would
# depend on some later foreground command happening to return a
# signal-derived nonzero status under `set -e`, which is not guaranteed if
# the signal lands while curl or the PORT assignment (both exempted from
# errexit by their `if`/`&&` guards) is the thing running. cleanup() is
# idempotent so the EXIT trap firing after these exit calls is a no-op.
trap cleanup EXIT
trap 'cleanup; exit 130' INT
trap 'cleanup; exit 143' TERM
trap 'cleanup; exit 129' HUP

# Port 0 asks the OS for a free ephemeral port, avoiding collisions with a
# stale server or another process. -u disables Python's stdout buffering so
# the "Serving HTTP on ... port NNNNN" line actually reaches the log file
# promptly instead of sitting in a block buffer until the process exits.
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$DOCROOT" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

PORT=""
for _ in $(seq 1 100); do
  PORT="$(grep -oE 'port [0-9]+' "$SERVER_LOG" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  [[ -n "$PORT" ]] && break
  kill -0 "$SERVER_PID" 2>/dev/null || { echo "shots.sh: server exited early" >&2; cat "$SERVER_LOG" >&2; exit 1; }
  sleep 0.1
done
[[ -n "$PORT" ]] || { echo "shots.sh: server did not report a port" >&2; exit 1; }

# Don't just sleep and hope: poll until the server actually answers.
READY=""
for _ in $(seq 1 100); do
  if curl -sf -o /dev/null "http://127.0.0.1:${PORT}/${PAGE}"; then
    READY=1
    break
  fi
  sleep 0.1
done
[[ -n "$READY" ]] || { echo "shots.sh: server never answered on port ${PORT}" >&2; exit 1; }

for W in 390 768 1440; do
  OUT_FILE="${OUT}/${NAME}-${W}.png"

  if (( W < FLOOR )); then
    # Below the floor: route through the iframe harness. The harness's own
    # window is sized comfortably above the floor (1000x1450) so *it* lays
    # out genuinely; the iframe inside it is pinned to the true target
    # width/height, and media queries inside the iframe evaluate against
    # that, not the harness window.
    # macOS's BSD mktemp only substitutes a trailing run of Xs (no suffix
    # after them), so a templated ".html"/".png" name isn't safe to build
    # with it here -- use pid+width instead, which is unique enough for
    # this script's own concurrent invocations without that limitation.
    HARNESS_FILE="${DOCROOT}/tools/.shots-harness-$$-${W}.html"
    cat > "$HARNESS_FILE" <<HTML
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;padding:0;background:#fff;}
iframe{display:block;border:0;width:${W}px;height:${HEIGHT}px;}</style>
</head><body><iframe src="/${PAGE}"></iframe></body></html>
HTML
    HARNESS_NAME="$(basename "$HARNESS_FILE")"

    RAW_SHOT="${TMPDIR:-/tmp}/shots-raw-$$-${W}.png"
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --window-size=1000,1450 --force-device-scale-factor="${SCALE}" \
      --virtual-time-budget=4000 \
      --screenshot="${RAW_SHOT}" \
      "http://127.0.0.1:${PORT}/tools/${HARNESS_NAME}" 2>/dev/null

    # Crop the harness capture down to the iframe's box. The iframe sits at
    # (0,0) in CSS pixels; --force-device-scale-factor multiplies both axes
    # by SCALE to get image pixels.
    python3 - "$RAW_SHOT" "$OUT_FILE" "$((W * SCALE))" "$((HEIGHT * SCALE))" <<'PY'
import sys
from PIL import Image
raw, out, w, h = sys.argv[1], sys.argv[2], int(sys.argv[3]), int(sys.argv[4])
Image.open(raw).crop((0, 0, w, h)).save(out)
PY

    rm -f "$RAW_SHOT" "$HARNESS_FILE"
    RAW_SHOT=""
    HARNESS_FILE=""
  else
    # At/above the floor: a direct render is already faithful.
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --window-size="${W},${HEIGHT}" --force-device-scale-factor="${SCALE}" \
      --virtual-time-budget=4000 \
      --screenshot="${OUT_FILE}" \
      "http://127.0.0.1:${PORT}/${PAGE}" 2>/dev/null
  fi

  echo "wrote ${OUT_FILE}"
done
