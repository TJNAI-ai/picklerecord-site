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
# for --window-size=390,<h> and it silently lays the page out at
# innerWidth=500, then scales the rendered image down to fit the requested
# 390px frame. Verified empirically: requesting 490 *or* 500 both report
# innerWidth=500 (500 is the exact floor, not just "roughly 500"); 501
# reports 501 and is genuine from there up. So a "390px screenshot" from a
# naive direct render is really a 500px layout wearing a 390px picture
# frame, and every @media rule below 500px never evaluates.
#
# Fix: for any width below the floor, render through an iframe harness --
# a wrapper page sized comfortably above the floor (1000 wide) containing
# an <iframe> set to the true target width/height and pointing at the real
# page, then crop the capture down to the iframe's box. Media queries
# evaluate against the iframe's own viewport, so this genuinely lays the
# page out at the requested width. Widths at/above the floor (768, 1440
# here) are rendered directly, since a direct render is already faithful
# there and the extra iframe indirection buys nothing.
#
# --- Full-page height (was: hardcoded HEIGHT=1400) ------------------------
# A fixed capture height silently drops anything below it -- with no error,
# just a screenshot that looks complete but isn't. The page grows by a
# section per task, so a constant tall enough today is guaranteed to be too
# short later. Fix: measure the real rendered content height per width and
# capture exactly that (clamped -- see MAX_HEIGHT below).
#
# Measurement uses the same trick as the sub-floor capture path: serve a
# tiny harness page with an <iframe src="/$PAGE"> pinned to the target CSS
# width, let it load, then read
#   iframe.contentDocument.documentElement.scrollHeight
# from the harness's own JS and write it into the harness's own DOM. Both
# documents are served from the same http.server origin, so contentDocument
# access isn't blocked by cross-origin restrictions. Chrome's --dump-dom
# gives us the harness's rendered DOM (including that written-in number) as
# text, no screenshot needed. Doing this through an iframe -- rather than
# just pointing Chrome straight at the page at width W -- means the same
# harness works for every width, including the ones below the 500px floor,
# where a direct measurement would suffer the exact innerWidth=500 problem
# described above. It also naturally gives a *different* height per width,
# which matters: this page's height is not width-invariant (measured
# 2644px at 768 vs 1954px at 1440 on 2026-08-25), because responsive
# layouts reflow, not just rescale.
#
# Both harness files (measure and capture) are written into tools/ (which
# tools/check.py's page walker already skips) under per-run unique dotfile
# names, served by the same http.server so root-absolute asset/iframe paths
# resolve, and removed by cleanup() on every exit path.
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
MEASURE_FILE=""
DUMP_FILE=""

# Chrome's floor is exactly 500 (see the block comment above); anything
# requested at or below it needs the harness.
FLOOR=500
SCALE=2

# Guard rails on the measured height. MAX_HEIGHT stops a runaway
# measurement (a broken page, an infinite-height bug, JS gone wild) from
# asking Chrome/Pillow to allocate a canvas of absurd size -- at SCALE=2 a
# 12000px-tall capture is already a 24000px-tall image, which is generous
# for a marketing landing page and nowhere near "let's allocate 100,000px".
# If real content ever exceeds it, we say so on stdout and capture the
# ceiling rather than silently truncating -- silent truncation is the exact
# defect this script is being fixed for. MIN_HEIGHT keeps a very short page
# (an empty dev stub, say) from producing a degenerate sliver of an image.
MAX_HEIGHT=12000
MIN_HEIGHT=200

CLEANED_UP=""
cleanup() {
  [[ -n "$CLEANED_UP" ]] && return 0
  CLEANED_UP=1
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$SERVER_LOG" "$HARNESS_FILE" "$RAW_SHOT" "$MEASURE_FILE" "$DUMP_FILE"
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

# Measure the rendered content height of $PAGE at CSS width $1, through the
# iframe trick described in the header comment. Sets MEASURED_HEIGHT as a
# side effect. Deliberately NOT run via `H=$(measure_height 390)`: a
# command substitution forks a subshell, and a subshell only inherits the
# parent's traps at fork time -- it does not share the parent's variables
# afterward, and its own EXIT/INT/etc. traps firing would end the subshell,
# not the whole script. Running it in-process keeps a signal that lands
# mid-measurement subject to the exact same top-level traps as everything
# else in this script.
measure_height() {
  local w="$1"
  MEASURE_FILE="${DOCROOT}/tools/.shots-measure-$$-${w}.html"
  cat > "$MEASURE_FILE" <<HTML
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;padding:0;}</style></head><body>
<iframe id="f" style="width:${w}px;height:200px;border:0;display:block" src="/${PAGE}"></iframe>
<div id="result">pending</div>
<script>
function report(){
  try {
    var h = document.getElementById('f').contentDocument.documentElement.scrollHeight;
    document.getElementById('result').textContent = 'SHOTS_MEASURED_HEIGHT:' + h;
  } catch (e) {
    document.getElementById('result').textContent = 'SHOTS_MEASURE_FAILED';
  }
}
var f = document.getElementById('f');
f.addEventListener('load', report);
</script>
</body></html>
HTML
  local mname
  mname="$(basename "$MEASURE_FILE")"
  DUMP_FILE="$(mktemp)"
  "$CHROME" --headless --disable-gpu --window-size=800,600 \
    --virtual-time-budget=4000 \
    --dump-dom "http://127.0.0.1:${PORT}/tools/${mname}" \
    >"$DUMP_FILE" 2>/dev/null

  local h
  # Anchored to a digit run right after the marker so this can't match the
  # marker's own literal text inside the dumped <script> source (which is
  # followed by a quote character there, never a digit).
  h="$(grep -oE 'SHOTS_MEASURED_HEIGHT:[0-9]+' "$DUMP_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"

  rm -f "$MEASURE_FILE" "$DUMP_FILE"
  MEASURE_FILE=""
  DUMP_FILE=""

  [[ -n "$h" ]] || { echo "shots.sh: could not measure content height for ${PAGE} at width ${w}px" >&2; exit 1; }

  if (( h > MAX_HEIGHT )); then
    echo "shots.sh: ${PAGE} at ${w}px measures ${h}px tall, over the ${MAX_HEIGHT}px ceiling -- capturing only the first ${MAX_HEIGHT}px (truncated, not full page)"
    h=$MAX_HEIGHT
  elif (( h < MIN_HEIGHT )); then
    h=$MIN_HEIGHT
  fi
  MEASURED_HEIGHT="$h"
}

for W in 390 768 1440; do
  OUT_FILE="${OUT}/${NAME}-${W}.png"

  measure_height "$W"
  HEIGHT="$MEASURED_HEIGHT"
  echo "measured ${PAGE} at ${W}px: ${HEIGHT}px tall"

  if (( W < FLOOR )); then
    # Below the floor: route through the iframe harness. The harness's own
    # window is sized comfortably above the floor and tall enough to show
    # the whole iframe, so *it* lays out genuinely; the iframe inside it is
    # pinned to the true target width/height, and media queries inside the
    # iframe evaluate against that, not the harness window.
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

    # A little slack above the iframe's own height so the harness window
    # itself never has to scroll to show the whole iframe.
    WINDOW_H=$((HEIGHT + 50))

    RAW_SHOT="${TMPDIR:-/tmp}/shots-raw-$$-${W}.png"
    "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --window-size="1000,${WINDOW_H}" --force-device-scale-factor="${SCALE}" \
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
