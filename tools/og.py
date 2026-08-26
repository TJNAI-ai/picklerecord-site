#!/usr/bin/env python3
"""Render the 1200x630 Open Graph card from the hero, via headless Chrome.

The serif headline (Instrument Serif) is loaded from Google Fonts with
`display=swap`, which paints a fallback face immediately and swaps in the
real font only once it has actually downloaded. A screenshot fired on a
fixed timer can land in that fallback window and silently ship a Times
-looking headline in the OG card -- exactly the failure tools/shots.sh was
built to avoid for the same font, by awaiting `document.fonts.ready`
instead of trusting a fixed delay (see its header comment for the full
mechanism, including why Chrome's own --virtual-time-budget can't be
trusted alone to bound a stuck network fetch).

Chrome's `--screenshot` CLI flag has no equivalent to `--dump-dom`'s "wait,
then read back whatever the page's own JS wrote into the DOM" trick -- it
just navigates and screenshots once the virtual-time budget elapses, with
no hook for a JS-side readiness condition. (A prior version of this script
tried to route around that by sharing one `--user-data-dir` across a
dump-dom "warm-up" pass and the real screenshot pass, hoping the warm-up
would populate the on-disk HTTP cache the capture pass could then reuse.
That doesn't work: a *persistent*, non-ephemeral `--user-data-dir` makes
Chrome start up as a full browser profile -- background sync, GCM
registration, default-app installation -- none of which the headless
`--dump-dom`/`--screenshot` run ever finishes waiting on, so the process
hangs well past any virtual-time budget and has to be wall-clock-killed.
Confirmed empirically: the identical invocation with no `--user-data-dir`
at all -- the ephemeral, ordinary headless mode -- exits cleanly in under
a second.)

So instead this script uses two ephemeral (default, no custom profile)
Chrome invocations and treats the first as a *measurement*, exactly the
way tools/shots.sh measures content height before capturing at that
height:

  1. A --dump-dom pass loads the exact same card, awaits
     document.fonts.ready (bounded by FONT_TIMEOUT_MS so a font that never
     settles doesn't hang forever), and writes the resulting
     document.fonts.status into the DOM so it can be read back out of the
     dumped HTML. If that doesn't report "loaded", the budget is raised
     and it retries -- never silently proceeding on an unconfirmed font
     state.
  2. Only once that pass has *empirically confirmed* fonts finish loading
     within some budget B, on this network, for this exact page, does the
     real --screenshot pass run -- with a budget at least as large as the
     one that just proved sufficient.

This is a real measurement gate, not a guessed timeout: the number the
capture pass uses is one Chrome, moments earlier, actually demonstrated is
enough for this exact page's fonts to finish loading.
"""
import re
import shutil
import subprocess
import sys
import tempfile

CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

# How long the in-page JS will wait on document.fonts.ready before giving
# up and reporting whatever status it has. WARMUP_VTB (Chrome's own
# --virtual-time-budget for the dump-dom measurement call) must exceed
# this with margin for the dump itself, matching the relationship
# shots.sh uses between its FONT_TIMEOUT_MS and MEASURE_VTB.
FONT_TIMEOUT_MS = 5000
WARMUP_VTB = 9000
WARMUP_VTB_STEP = 4000
CAPTURE_VTB_MARGIN = 2000  # capture budget = the warm-up budget that worked, plus this
WALLCLOCK_TIMEOUT_S = 30
MAX_ATTEMPTS = 3

HTML = """<!DOCTYPE html><html><head><meta charset="utf-8">
<link rel="preconnect" href="https://fonts.googleapis.com">
<link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link href="https://fonts.googleapis.com/css2?family=Archivo:wght@800&family=Instrument+Serif:ital@0;1&family=Inter:wght@600;700&display=swap" rel="stylesheet">
<style>
*{margin:0;box-sizing:border-box}
body{width:1200px;height:630px;background:#FAFBF7;font-family:Inter,sans-serif;
     position:relative;overflow:hidden;display:flex;align-items:center;padding:0 82px}
svg.court{position:absolute;inset:0;width:100%;height:100%}
.bloom{position:absolute;width:520px;height:520px;border-radius:50%;
       filter:blur(80px);background:#D6F553;opacity:.42;left:-120px;top:-160px}
.z{position:relative;z-index:3;max-width:720px}
.ey{font-size:15px;font-weight:700;letter-spacing:.2em;text-transform:uppercase;
    color:#1F7A3C;margin-bottom:22px}
h1{font-family:'Instrument Serif',serif;font-weight:400;font-size:76px;
   line-height:1.02;letter-spacing:-.018em;color:#0B0F16}
h1 em{font-style:italic;color:#1F7A3C}
p{margin-top:22px;font-size:23px;color:#4E5866;max-width:26ch}
.strip{position:absolute;left:0;right:0;bottom:0;height:74px;background:#0B0F16;
       border-top:4px solid #D6F553;display:flex;align-items:center;gap:38px;
       padding:0 82px;z-index:4}
.strip b{font-family:Archivo,sans-serif;font-weight:800;font-size:27px;color:#fff}
.strip span{font-size:16px;font-weight:600;color:#BAC4D2;margin-left:8px}
#fontstatus{position:absolute;left:-9999px;top:-9999px}
</style></head><body>
<svg class="court" viewBox="0 0 200 100" preserveAspectRatio="xMidYMid slice">
  <g transform="translate(140 44) rotate(-9) scale(2.3) translate(-22 -10)">
    <rect x="0" y="0" width="44" height="20" fill="#2F9E52" fill-opacity=".05"/>
    <rect x="15" y="0" width="14" height="20" fill="#D6F553" fill-opacity=".18"/>
    <g fill="none" stroke="#2F9E52" stroke-opacity=".22" stroke-width=".34">
      <rect x="0" y="0" width="44" height="20"/>
      <line x1="15" y1="0" x2="15" y2="20"/><line x1="29" y1="0" x2="29" y2="20"/>
      <line x1="0" y1="10" x2="15" y2="10"/><line x1="29" y1="10" x2="44" y2="10"/>
    </g></g></svg>
<div class="bloom"></div>
<div class="z">
  <div class="ey">iPhone &middot; Apple Watch</div>
  <h1>Other apps keep score.<br>This one keeps your <em>record</em>.</h1>
  <p>Two taps a game. A season you can actually read.</p>
</div>
<div class="strip">
  <div><b>47</b><span>games</span></div><div><b>3,525</b><span>swings</span></div>
  <div><b>0</b><span>accounts</span></div><div><b>$0</b><span>to keep your history</span></div>
</div>
<div id="fontstatus">pending</div>
<script>
(function () {
  var el = document.getElementById('fontstatus');
  var fontsReady = (document.fonts && document.fonts.ready) ? document.fonts.ready : Promise.resolve();
  var timedOut = new Promise(function (resolve) { setTimeout(resolve, __FONT_TIMEOUT_MS__); });
  Promise.race([fontsReady, timedOut]).then(function () {
    var fstatus = document.fonts ? document.fonts.status : 'unknown';
    el.textContent = 'OG_FONTS_STATUS:' + fstatus;
  });
})();
</script>
</body></html>""".replace("__FONT_TIMEOUT_MS__", str(FONT_TIMEOUT_MS))


def run_chrome_bounded(args):
    """Run a Chrome invocation with a real wall-clock ceiling.

    --virtual-time-budget cannot be trusted to bound a hung network fetch
    (a black-holed font host, say) -- see tools/shots.sh's header comment
    for the empirical case. subprocess.run's own `timeout` provides the
    same external, signal-based bound shots.sh builds by hand with a
    watchdog `sleep` + SIGKILL.
    """
    try:
        return subprocess.run(args, check=True, timeout=WALLCLOCK_TIMEOUT_S,
                               stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
    except subprocess.TimeoutExpired:
        print(f"og.py: chrome invocation exceeded {WALLCLOCK_TIMEOUT_S}s wall-clock "
              f"-- likely a hung network fetch", file=sys.stderr)
        raise


def measure_fonts_ready(chrome_html_path, vtb):
    """Load the card, wait for fonts, return document.fonts.status or None.

    Deliberately no --user-data-dir: an ephemeral, throwaway profile per
    invocation, exactly like tools/shots.sh's own dump-dom measurement
    calls -- see the module docstring for why a persistent profile hangs
    here instead of exiting.
    """
    result = run_chrome_bounded([
        CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
        "--window-size=1200,630", "--force-device-scale-factor=1",
        f"--virtual-time-budget={vtb}", "--dump-dom",
        f"file://{chrome_html_path}",
    ])
    dom = result.stdout.decode("utf-8", errors="replace")
    m = re.search(r"OG_FONTS_STATUS:([A-Za-z]+)", dom)
    return m.group(1) if m else None


def capture(chrome_html_path, out_path, vtb):
    run_chrome_bounded([
        CHROME, "--headless", "--disable-gpu", "--hide-scrollbars",
        "--window-size=1200,630", "--force-device-scale-factor=1",
        f"--virtual-time-budget={vtb}", f"--screenshot={out_path}",
        f"file://{chrome_html_path}",
    ])


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else "assets/og-image.png"

    tmp_dir = tempfile.mkdtemp(prefix="og-render-")
    html_path = f"{tmp_dir}/og-source.html"
    with open(html_path, "w", encoding="utf-8") as fh:
        fh.write(HTML)

    try:
        vtb = WARMUP_VTB
        status = None
        for attempt in range(1, MAX_ATTEMPTS + 1):
            status = measure_fonts_ready(html_path, vtb)
            print(f"attempt {attempt}: document.fonts.status = {status!r} "
                  f"(measurement virtual-time-budget {vtb}ms)")
            if status == "loaded":
                break
            vtb += WARMUP_VTB_STEP  # raise the budget and retry, per the brief's guidance
        else:
            print("og.py: fonts never reported 'loaded' after "
                  f"{MAX_ATTEMPTS} attempts -- refusing to ship a possible "
                  "fallback-font render", file=sys.stderr)
            sys.exit(1)

        # `vtb` just proved sufficient, on this exact page and network, for
        # fonts to finish loading -- give the capture pass that same floor
        # plus margin, rather than an unrelated guessed constant.
        capture_vtb = vtb + CAPTURE_VTB_MARGIN
        print(f"capturing with virtual-time-budget {capture_vtb}ms")
        capture(html_path, out, capture_vtb)
    finally:
        shutil.rmtree(tmp_dir, ignore_errors=True)

    from PIL import Image
    im = Image.open(out)
    print(f"{out}: {im.size}")
    assert im.size == (1200, 630), f"expected 1200x630, got {im.size}"


if __name__ == "__main__":
    main()
