#!/usr/bin/env python3
"""Structural, copy, and asset checks for the PickleRecord site.

Run: python3 tools/check.py
Exit 0 = all pass. Exit 1 = one or more failures, printed one per line.
"""
import argparse
import os
import re
import sys
from html.parser import HTMLParser

BANNED_COPY = [
    "seamlessly", "effortlessly", "elevate", "unlock", "revolutionize",
    "empower", "game-changer", "game changer", "powered by ai",
    "next level", "coming soon",
]
ALLOWED_HOSTS = {"fonts.googleapis.com", "fonts.gstatic.com", "apps.apple.com",
                 "www.apple.com", "tjnai.ai"}
REQUIRED_META = ["description", "og:title", "og:description", "og:image", "og:url",
                 "twitter:card"]
REQUIRED_PRICES = ["$2.99", "$19.99", "$39.99"]
APPSTORE_URL = "https://apps.apple.com/app/id6792869715"
# Exact App Store URL, not followed by a query string, extra path segment,
# or other continuation character (a quote, whitespace, or end-of-string is fine).
APPSTORE_RE = re.compile(re.escape(APPSTORE_URL) + r"(?![\w./?#-])")

ALLOWED_PALETTE = {"#D6F553", "#0B0F16", "#16202F", "#3A4657",
                   "#2F9E52", "#1F7A3C", "#FAFBF7", "#BAC4D2",
                   "#0D0F12",  # device bezel, distinct from --ink
                   "#fff", "#000"}
# 8/6/4/3-digit hex, longest first so e.g. #0B0F16AA isn't cut short at 6
# and left dangling on a hex digit (which broke the old \b-anchored regex).
# The leading (?<!&) excludes numeric character references such as
# &#8646; or &#160; — those "#" are the start of an HTML entity, not a
# colour, and the digits that follow happen to fall in hex-digit ranges.
# Named entities (&mdash;, &rarr;, ...) never contain "#" and are unaffected.
HEX_RE = re.compile(
    r"(?<!&)#(?:[0-9a-fA-F]{8}|[0-9a-fA-F]{6}|[0-9a-fA-F]{4}|[0-9a-fA-F]{3})"
    r"(?![0-9a-fA-F])"
)


def hex_rgb6(hexval):
    """Normalize a 3/4/6/8-digit hex colour to its RRGGBB part, upper-cased.

    3- and 4-digit forms are shorthand (one hex nibble per channel, plus an
    optional alpha nibble); 8-digit forms carry a full two-digit alpha
    channel after RRGGBB. Alpha is dropped so an approved colour with any
    alpha value still matches, while an unapproved RGB is still caught.
    """
    h = hexval.lstrip("#")
    if len(h) in (3, 4):
        h = "".join(c * 2 for c in h[:3])
    else:
        h = h[:6]
    return h.upper()


ALLOWED_RGB6 = {hex_rgb6(c) for c in ALLOWED_PALETTE}


def check_palette(text, label):
    for m in HEX_RE.finditer(text):
        bad = m.group(0)
        if hex_rgb6(bad) not in ALLOWED_RGB6:
            fail("palette", label, f"{bad} is not in the approved palette")


# tools/shots.sh measures a page's rendered content height at a fixed
# viewport width, then re-launches the browser window sized to *that
# measured height* and captures at that size. If the page's own height
# depends on viewport height -- e.g. `min-height:32vh`, which scales with
# whatever window height it's rendered in -- then the measurement pass
# (one viewport height) and the capture pass (a different viewport height,
# namely the measured value itself) disagree about how tall the page is,
# and the page grows in response to being resized to fit it. That loop has
# no fixed point in general: it previously produced a capture that
# silently truncated mid-page, with no error, because the page kept
# growing past whatever height it had just been measured at. Viewport-
# WIDTH units (vw) don't have this problem -- shots.sh's capture width
# always matches its measurement width -- so only height-relative units
# are banned here. See the shots.sh header comment for the full mechanism.
#
# Matched only as an actual CSS length token: a number immediately
# followed by one of the four viewport-height units, with a non-alnum
# boundary on each side. That keeps it from firing on a class name like
# `.vh-100` (unit comes before the number -- no match), a word or
# identifier that merely contains the letters "vh", or the CSS comment
# text explaining this very rule -- comments are stripped before matching.
CSS_COMMENT_RE = re.compile(r"/\*.*?\*/", re.S)
VH_UNIT_RE = re.compile(r"(?<![\w.-])(-?\d*\.?\d+)(dvh|svh|lvh|vh)(?![a-zA-Z0-9])")
STYLE_BLOCK_RE = re.compile(r"<style\b[^>]*>(.*?)</style>", re.S | re.I)


def check_vh(css_text, label):
    stripped = CSS_COMMENT_RE.sub(" ", css_text)
    for m in VH_UNIT_RE.finditer(stripped):
        fail("viewport-height-unit", label,
             f"{m.group(0)} uses a viewport-height unit (see shots.sh: "
             f"capture height depends on measured height, so page height "
             f"must not depend on viewport height)")


failures = []


def fail(check, path, detail):
    failures.append(f"FAIL {check} {path}: {detail}")


class Doc(HTMLParser):
    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.headings = []          # (level, text)
        self.imgs = []              # (src, alt, aria_hidden)
        self.links = []             # href
        self.metas = {}             # name/property -> content
        self.svgs = []              # aria_hidden bool
        self.title = None
        self._cur_h = None
        self._in_title = False
        self.canonical = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if re.fullmatch(r"h[1-6]", tag):
            self._cur_h = (int(tag[1]), "")
        elif tag == "img":
            self.imgs.append((a.get("src", ""), a.get("alt"),
                              a.get("aria-hidden") == "true"))
        elif tag == "a" and "href" in a:
            self.links.append(a["href"])
        elif tag == "meta":
            key = a.get("name") or a.get("property")
            if key:
                self.metas[key] = a.get("content", "")
        elif tag == "svg":
            self.svgs.append(a.get("aria-hidden") == "true")
        elif tag == "title":
            self._in_title = True
        elif tag == "link" and a.get("rel") == "canonical":
            self.canonical = a.get("href")

    def handle_endtag(self, tag):
        if re.fullmatch(r"h[1-6]", tag) and self._cur_h:
            self.headings.append(self._cur_h)
            self._cur_h = None
        elif tag == "title":
            self._in_title = False

    def handle_data(self, data):
        if self._cur_h:
            self._cur_h = (self._cur_h[0], self._cur_h[1] + data)
        if self._in_title:
            self.title = (self.title or "") + data


def visible_text(html):
    """Strip script/style/comments so copy checks don't fire on code.

    Collapses whitespace runs to a single space so inline markup like
    `next <em>level</em>` (which tag-stripping turns into "next  level")
    still matches banned two-word phrases.
    """
    html = re.sub(r"<!--.*?-->", " ", html, flags=re.S)
    html = re.sub(r"<(script|style)\b.*?</\1>", " ", html, flags=re.S | re.I)
    text = re.sub(r"<[^>]+>", " ", html)
    return re.sub(r"\s+", " ", text)


def chrome_block(html, name):
    m = re.search(rf"<!--\s*#chrome:{name}\s*-->(.*?)<!--\s*/#chrome:{name}\s*-->",
                  html, flags=re.S)
    return m.group(1).strip() if m else None


def check_page(root, rel, html, chrome_ref):
    doc = Doc()
    doc.feed(html)
    text = visible_text(html)

    # --- copy ---
    low = text.lower()
    for word in BANNED_COPY:
        if word in low:
            fail("banned-copy", rel, f"contains {word!r}")

    # --- headings ---
    h1s = [h for h in doc.headings if h[0] == 1]
    if len(h1s) != 1:
        fail("h1-count", rel, f"expected exactly 1 <h1>, found {len(h1s)}")
    prev = 0
    for level, _ in doc.headings:
        if prev and level > prev + 1:
            fail("heading-skip", rel, f"h{prev} followed by h{level}")
        prev = level

    # --- images ---
    for src, alt, hidden in doc.imgs:
        if not hidden and not (alt or "").strip():
            fail("img-alt", rel, f"{src} has no alt text")
        if src and not src.startswith(("http://", "https://", "data:")):
            target = os.path.normpath(os.path.join(root, os.path.dirname(rel),
                                                   src.lstrip("/")))
            if src.startswith("/"):
                target = os.path.normpath(os.path.join(root, src.lstrip("/")))
            if not os.path.exists(target):
                fail("img-missing", rel, f"{src} does not resolve")

    # --- decorative svg ---
    for i, hidden in enumerate(doc.svgs):
        if not hidden:
            fail("svg-aria", rel, f"svg #{i + 1} lacks aria-hidden=\"true\"")

    # --- links ---
    for href in doc.links:
        if href.startswith(("mailto:", "tel:", "#", "data:")):
            continue
        if href.startswith(("http://", "https://")):
            host = re.sub(r"^https?://([^/]+).*$", r"\1", href)
            if host not in ALLOWED_HOSTS:
                fail("external-host", rel, f"{host} is not in the allowlist")
            continue
        target = os.path.normpath(os.path.join(root, href.lstrip("/").split("#")[0]))
        if os.path.isdir(target):
            target = os.path.join(target, "index.html")
        if not os.path.exists(target):
            fail("link-broken", rel, f"{href} does not resolve")

    # --- meta ---
    if not (doc.title or "").strip():
        fail("meta", rel, "missing <title>")
    for key in REQUIRED_META:
        if not doc.metas.get(key, "").strip():
            fail("meta", rel, f"missing meta {key}")
    if not doc.canonical:
        fail("meta", rel, "missing canonical link")

    # --- chrome consistency ---
    for name in ("nav", "footer"):
        block = chrome_block(html, name)
        if block is None:
            fail("chrome-missing", rel, f"no #chrome:{name} block")
        elif chrome_ref.get(name) is None:
            chrome_ref[name] = (rel, block)
        elif chrome_ref[name][1] != block:
            fail("chrome-drift", rel,
                 f"#chrome:{name} differs from {chrome_ref[name][0]}")

    return doc


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--root", default=".")
    args = ap.parse_args()
    root = os.path.abspath(args.root)

    pages = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = [d for d in dirnames
                       if d not in {".git", "tools", "dev", "assets"}]
        for fn in filenames:
            if fn.endswith(".html"):
                pages.append(os.path.relpath(os.path.join(dirpath, fn), root))
    pages.sort()

    if not pages:
        fail("pages", ".", "no HTML pages found")

    chrome_ref = {"nav": None, "footer": None}
    index_html = None
    for rel in pages:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            html = fh.read()
        if rel == "index.html":
            index_html = html
        check_page(root, rel, html, chrome_ref)

    # --- landing-page-only checks ---
    if index_html is not None:
        text = visible_text(index_html)
        for price in REQUIRED_PRICES:
            if price not in text:
                fail("pricing", "index.html", f"missing {price}")
        if not APPSTORE_RE.search(index_html):
            fail("appstore", "index.html", "exact App Store URL not present")

    # --- reduced motion ---
    css_path = os.path.join(root, "assets", "site.css")
    if os.path.exists(css_path):
        with open(css_path, encoding="utf-8") as fh:
            css = fh.read()
        if "prefers-reduced-motion" not in css:
            fail("reduced-motion", "assets/site.css",
                 "no prefers-reduced-motion block")
        check_palette(css, "assets/site.css")
        check_vh(css, "assets/site.css")

    # --- palette (HTML pages: inline <style> blocks and style= attributes) ---
    # --- viewport-height units (HTML pages: inline <style> blocks only) ---
    for rel in pages:
        with open(os.path.join(root, rel), encoding="utf-8") as fh:
            html = fh.read()
        check_palette(html, rel)
        for m in STYLE_BLOCK_RE.finditer(html):
            check_vh(m.group(1), rel)

    for line in failures:
        print(line)
    print(f"\n{len(pages)} page(s) checked, {len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
