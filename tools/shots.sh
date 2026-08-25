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
#   iframe.contentDocument.body.scrollHeight
# (body, deliberately not documentElement -- see the NOTE inside
# measure_height for why the two are not interchangeable here) from the
# harness's own JS and write it into the harness's own DOM. Both
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
#
# --- Web fonts: the iframe's `load` event fires too early ----------------
# The site pulls Instrument Serif / Inter / Archivo from Google Fonts with
# `display=swap`, which exists precisely so text paints in a fallback face
# immediately and reflows later when the real font arrives -- so the
# @font-face binary fetch is deliberately NOT something the iframe's `load`
# event waits for. Reading scrollHeight the instant `load` fires can catch
# the page mid-fallback-font layout, before the swap-driven reflow. Worse,
# measurement and capture are separate Chrome processes with no shared
# cache, so each independently races the same font fetch -- under slow DNS
# or jitter the measured height and the actually-rendered height could
# diverge. Fix: inside the measured (inner) document, await
# `document.fonts.ready` before reading scrollHeight, with a bounded JS-side
# timeout fallback (FONT_TIMEOUT_MS) so a page whose fonts genuinely never
# settle still gets measured rather than the whole call stalling forever.
#
# That JS-side timeout turns out to be necessary but NOT sufficient: it
# only fires while headless Chrome considers the page's virtual clock
# advanceable, and Chrome's --virtual-time-budget refuses to advance at all
# while *any* network fetch is still outstanding on the page -- verified
# empirically by pointing @font-face at an unreachable host (a black-holed
# IP): the in-page setTimeout fallback never fired, and the whole
# --dump-dom call hung for minutes despite a 9s virtual-time budget and a
# 5s JS timeout, because Chrome was still waiting on that one stuck fetch
# before it would run any more timers at all. So a hung third-party
# resource can't be bounded from *inside* the page under this mode, no
# matter how the in-page JS is written. The only reliable bound is
# external: run_chrome_bounded (below) races every Chrome invocation in
# this script against a real `sleep` watchdog and SIGKILLs Chrome if the
# watchdog wins. SIGKILL can't be ignored regardless of any inherited
# signal disposition, so this is reliable independent of that mechanism.
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
CHROME_PID=""
WATCHDOG_PID=""

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

# How long (ms) the measurement harness's own JS will wait on
# `document.fonts.ready` in the inner document before giving up and
# measuring anyway -- see the web-fonts comment above. MEASURE_VTB is
# Chrome's --virtual-time-budget for the measurement dump-dom call and must
# exceed FONT_TIMEOUT_MS with margin for the dump itself; CAPTURE_VTB is
# the budget for the two actual screenshot calls. CHROME_WALLCLOCK_TIMEOUT_S
# is the real (not virtual) ceiling on any single Chrome invocation, needed
# because neither of the above bounds anything if a network fetch never
# resolves at all -- see run_chrome_bounded below.
FONT_TIMEOUT_MS=5000
MEASURE_VTB=9000
CAPTURE_VTB=8000
CHROME_WALLCLOCK_TIMEOUT_S=25

# Run a command (expected to be a Chrome invocation) with a real wall-clock
# ceiling: backgrounds it, races it against a `sleep` watchdog in a second
# background job, and SIGKILLs the command if the watchdog wins. Needed
# because --virtual-time-budget cannot be trusted to bound a hung network
# fetch (see the header comment). Redirections on the caller's command line
# apply to this function call as a whole and are inherited by the
# backgrounded command as usual, so `run_chrome_bounded "$CHROME" ... >out
# 2>/dev/null` redirects Chrome's own output exactly as a direct call would.
#
# CHROME_PID/WATCHDOG_PID are deliberately GLOBAL, not `local`: if a signal
# lands while this function is blocked in `wait "$CHROME_PID"`, bash
# interrupts that wait to run the EXIT/INT/TERM/HUP trap immediately --
# verified empirically, this is what makes this script's signal handling
# fast in the first place -- but execution never returns into this function
# afterward (the trap itself calls `exit`). That leaves Chrome running as
# an orphan unless something outside this function can still see its PID
# and kill it. cleanup() is that something; a `local` variable wouldn't be
# visible to it once the trap fires from an arbitrary point inside a
# nested call. Both are reset to "" once reaped normally so cleanup() never
# tries to kill an already-gone PID during the ordinary EXIT-trap path.
run_chrome_bounded() {
  "$@" &
  CHROME_PID=$!
  ( sleep "$CHROME_WALLCLOCK_TIMEOUT_S"; kill -9 "$CHROME_PID" 2>/dev/null ) &
  WATCHDOG_PID=$!
  local rc=0
  wait "$CHROME_PID" 2>/dev/null || rc=$?
  kill "$WATCHDOG_PID" 2>/dev/null || true
  wait "$WATCHDOG_PID" 2>/dev/null || true
  CHROME_PID=""
  WATCHDOG_PID=""
  return "$rc"
}

CLEANED_UP=""
cleanup() {
  [[ -n "$CLEANED_UP" ]] && return 0
  CLEANED_UP=1
  # Kill any Chrome invocation (and its watchdog) that was still running
  # when a signal interrupted run_chrome_bounded -- see the comment there.
  # SIGKILL regardless of disposition, since we don't control or trust
  # whatever signal-handling state a mid-flight Chrome process is in.
  if [[ -n "$CHROME_PID" ]] && kill -0 "$CHROME_PID" 2>/dev/null; then
    kill -9 "$CHROME_PID" 2>/dev/null || true
    wait "$CHROME_PID" 2>/dev/null || true
  fi
  if [[ -n "$WATCHDOG_PID" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
    kill -9 "$WATCHDOG_PID" 2>/dev/null || true
    wait "$WATCHDOG_PID" 2>/dev/null || true
  fi
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

# Representative viewport height used ONLY inside the measurement iframe
# (never the capture paths), so that vh-based CSS resolves against
# something realistic instead of an arbitrary stub. `min-height:100vh` is
# the single most common landing-page hero idiom; the site has none of it
# today (grepped), but ten more sections are still to be built, and a fixed
# small stub here would silently mismeasure the first one that uses it --
# the same failure class as the hardcoded 1400 this script is being fixed
# for. There's no single *correct* answer: 100vh is inherently ambiguous
# once you're capturing a whole page taller than any one real viewport. So
# rather than an arbitrary round number, each value below is a real,
# common device logical-viewport height at that exact width:
#   390  -> 844   iPhone 14/15 logical viewport height at 390 CSS px wide
#   768  -> 1024  classic iPad portrait logical viewport height
#   1440 -> 900   1440x900 is itself a common real laptop/desktop
#                 resolution (e.g. 13" MacBook Air logical resolution)
# Any width not listed (none currently passed; the loop below could grow)
# falls back to 900, the desktop figure, as the least-bad general default.
# This is a pure, instant, in-process computation (no blocking call), so
# unlike measure_height itself, wrapping it in a subshell here carries none
# of that function's signal-safety concern.
measurement_viewport_height() {
  case "$1" in
    390) echo 844 ;;
    768) echo 1024 ;;
    1440) echo 900 ;;
    *) echo 900 ;;
  esac
}

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
  local vh
  vh="$(measurement_viewport_height "$w")"
  MEASURE_FILE="${DOCROOT}/tools/.shots-measure-$$-${w}.html"
  # NOTE on idoc.body.scrollHeight vs. idoc.documentElement.scrollHeight:
  # the two are NOT interchangeable here, and picking the wrong one breaks
  # short pages. `documentElement` (<html>) is the page's scrolling root,
  # and per the CSSOM View spec its scrollHeight is defined as at least the
  # viewport's own height -- i.e. `max(viewport height, content height)`,
  # not just content height. Verified empirically: a genuinely 10px-tall
  # test page measured at width 390 (vh=844 below) reported
  # documentElement.scrollHeight = 844 (the viewport we assigned, wrongly
  # padding a tiny page up to full "device height") but body.scrollHeight =
  # 18 (the real content). `<body>` isn't the scrolling root, so its
  # scrollHeight isn't subject to that floor -- it behaves like an ordinary
  # element's scrollHeight (own content extent, including overflow), which
  # is what we actually want. This only started mattering once `vh` below
  # became a realistic device height instead of a 200px stub: at 200px,
  # every real page's content already exceeded it, so the two properties
  # happened to agree and the bug was latent. A synthetic `min-height:100vh`
  # page still measures correctly via body.scrollHeight (confirmed: reports
  # viewport-height-plus-trailing-content, not just the viewport height),
  # so this isn't a tradeoff against the vh fix -- body.scrollHeight is
  # simply the correct property for "true rendered content height" and
  # documentElement.scrollHeight never was.
  cat > "$MEASURE_FILE" <<HTML
<!doctype html><html><head><meta charset="utf-8">
<style>html,body{margin:0;padding:0;}</style></head><body>
<iframe id="f" style="width:${w}px;height:${vh}px;border:0;display:block" src="/${PAGE}"></iframe>
<div id="result">pending</div>
<script>
function report(){
  try {
    var idoc = document.getElementById('f').contentDocument;
    var fontsReady = (idoc.fonts && idoc.fonts.ready) ? idoc.fonts.ready : Promise.resolve();
    var timedOut = new Promise(function(resolve){ setTimeout(resolve, ${FONT_TIMEOUT_MS}); });
    Promise.race([fontsReady, timedOut]).then(function(){
      try {
        var h = idoc.body.scrollHeight;
        var fstatus = idoc.fonts ? idoc.fonts.status : 'unknown';
        document.getElementById('result').textContent =
          'SHOTS_MEASURED_HEIGHT:' + h + '_FONTS_' + fstatus;
      } catch (e2) {
        document.getElementById('result').textContent = 'SHOTS_MEASURE_FAILED';
      }
    });
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
  local rc=0
  run_chrome_bounded "$CHROME" --headless --disable-gpu --window-size=800,600 \
    --virtual-time-budget="${MEASURE_VTB}" \
    --dump-dom "http://127.0.0.1:${PORT}/tools/${mname}" \
    >"$DUMP_FILE" 2>/dev/null || rc=$?

  local h fstatus
  # Anchored to a digit run right after the marker so this can't match the
  # marker's own literal text inside the dumped <script> source (which is
  # followed by a quote character there, never a digit).
  h="$(grep -oE 'SHOTS_MEASURED_HEIGHT:[0-9]+' "$DUMP_FILE" 2>/dev/null | head -1 | grep -oE '[0-9]+' || true)"
  fstatus="$(grep -oE '_FONTS_[A-Za-z]+' "$DUMP_FILE" 2>/dev/null | head -1 | sed 's/^_FONTS_//' || true)"

  rm -f "$MEASURE_FILE" "$DUMP_FILE"
  MEASURE_FILE=""
  DUMP_FILE=""

  if [[ -z "$h" ]]; then
    if [[ "$rc" -eq 137 ]]; then
      echo "shots.sh: measuring ${PAGE} at ${w}px exceeded ${CHROME_WALLCLOCK_TIMEOUT_S}s wall-clock and was killed -- likely a hung network fetch (e.g. an unreachable font host)" >&2
    else
      echo "shots.sh: could not measure content height for ${PAGE} at width ${w}px" >&2
    fi
    exit 1
  fi

  if [[ "$fstatus" != "loaded" ]]; then
    echo "shots.sh: warning -- ${PAGE} at ${w}px: web fonts reported '${fstatus:-unknown}' (not 'loaded') when height was measured; hit the ${FONT_TIMEOUT_MS}ms fallback instead of document.fonts.ready resolving" >&2
  fi

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
    # `|| true`: under `set -e`, a bare non-zero return here (e.g. 137 if
    # the wall-clock watchdog had to SIGKILL Chrome) would abort the script
    # on this line, before the friendlier [[ -s ... ]] diagnostic below
    # ever runs. Swallow the status here and let the file-existence check
    # be the actual failure signal instead.
    run_chrome_bounded "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --window-size="1000,${WINDOW_H}" --force-device-scale-factor="${SCALE}" \
      --virtual-time-budget="${CAPTURE_VTB}" \
      --screenshot="${RAW_SHOT}" \
      "http://127.0.0.1:${PORT}/tools/${HARNESS_NAME}" 2>/dev/null || true

    [[ -s "$RAW_SHOT" ]] || { echo "shots.sh: capturing ${PAGE} at ${W}px produced no image (Chrome may have exceeded ${CHROME_WALLCLOCK_TIMEOUT_S}s wall-clock)" >&2; exit 1; }

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
    # At/above the floor: a direct render is already faithful. `|| true`
    # for the same reason as the harness-capture branch above: let the
    # [[ -s ... ]] check below be the failure signal, not a bare set -e
    # abort on Chrome's own exit status.
    run_chrome_bounded "$CHROME" --headless --disable-gpu --hide-scrollbars \
      --window-size="${W},${HEIGHT}" --force-device-scale-factor="${SCALE}" \
      --virtual-time-budget="${CAPTURE_VTB}" \
      --screenshot="${OUT_FILE}" \
      "http://127.0.0.1:${PORT}/${PAGE}" 2>/dev/null || true

    [[ -s "$OUT_FILE" ]] || { echo "shots.sh: capturing ${PAGE} at ${W}px produced no image (Chrome may have exceeded ${CHROME_WALLCLOCK_TIMEOUT_S}s wall-clock)" >&2; exit 1; }
  fi

  echo "wrote ${OUT_FILE}"
done
