# Maintenance mode

picklerecord.app is in partial maintenance. The home page and every path other than the App Store-facing legal pages serve a maintenance page from the repository root (`index.html` and `404.html`).

These paths are published again, copied from `_source/`, because the App Store still lists them:

- `/privacy/` and `/privacy`
- `/support/`

`assets/site.css` and `assets/site.js` are published so those pages render correctly (the support page still references `site.js`; it is a no-op there). Favicons also stay under `assets/`. The `CNAME` file was left in place so the custom domain and HTTPS stay intact. The original site, including unmodified copies of the privacy and support pages, remains in `_source/`, which GitHub Pages (Jekyll) does not publish.

On the published privacy and support pages only, the header brand is a `span` rather than a link to `/`, so it does not send visitors to the maintenance home page. These nav links are still in the header and footer and go to pages that are down (they show the maintenance page or the maintenance 404):

- `/#how`, `/#watch`, `/#pricing` (home page anchors)
- `/compare/`
- `/press/` (footer only)

`/privacy/` and `/support/` still link to each other. The App Store download button is unchanged.

## Restore the rest of the original site

Do not rewrite history or force-push. Work on a branch and merge to `main`. Privacy, support, and some assets already exist at the root; remove those published copies first so the originals in `_source/` can move back.

```bash
git rm -f index.html 404.html robots.txt README.md MAINTENANCE.md _config.yml
git rm -rf privacy support
git rm -f assets/favicon.svg assets/icon-64.png assets/site.css assets/site.js
rmdir assets 2>/dev/null || true
git mv _source/assets _source/compare _source/dev _source/index.html \
  _source/press _source/privacy _source/robots.txt _source/sitemap.xml \
  _source/support _source/tools .
rmdir _source
```

Keep `CNAME` and `.gitignore`. This repo did not previously have a `404.html` or a root `README.md`. Commit as `TJNAI.ai <support@tjnai.ai>`, open a pull request if `main` cannot be pushed directly, and merge. GitHub Pages will republish from `main` at `/`. DNS does not need to change.
