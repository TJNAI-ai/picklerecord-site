#!/usr/bin/env bash
# Render a page at three widths for visual review.
# Usage: bash tools/shots.sh index.html /tmp/shots
#
# Serves the page over http://127.0.0.1 (not file://) because the site uses
# root-absolute asset paths (/assets/site.css, /assets/icon-64.png, ...).
# Under file://, a leading "/" resolves against the filesystem root, so none
# of the CSS or images would load.
set -euo pipefail
PAGE="${1:?usage: shots.sh <page-path> <out-dir>}"
OUT="${2:?usage: shots.sh <page-path> <out-dir>}"
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
NAME="$(echo "$PAGE" | sed 's#/#-#g; s#\.html$##')"
mkdir -p "$OUT"

DOCROOT="$(pwd)"
SERVER_LOG="$(mktemp)"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -f "$SERVER_LOG"
}
trap cleanup EXIT INT TERM

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
  "$CHROME" --headless --disable-gpu --hide-scrollbars \
    --window-size="${W},1400" --force-device-scale-factor=2 \
    --virtual-time-budget=4000 \
    --screenshot="${OUT}/${NAME}-${W}.png" \
    "http://127.0.0.1:${PORT}/${PAGE}" 2>/dev/null
  echo "wrote ${OUT}/${NAME}-${W}.png"
done
