# Maintenance mode

picklerecord.app is serving a maintenance page from the files at the repository root (`index.html` and `404.html`). The original site is in `_source/`, which GitHub Pages (Jekyll) does not publish. The `CNAME` file was left in place so the custom domain and HTTPS stay intact. Only the favicon and a small app icon remain under `assets/` so the browser tab still shows the PickleRecord icon.

## Restore the original site

Do not rewrite history or force-push. Work on a branch and merge to `main`.

1. From the repository root, remove the maintenance-only copies of the icon files, then move the original files back:

   ```bash
   git rm -f assets/favicon.svg assets/icon-64.png
   rmdir assets 2>/dev/null || true
   git mv _source/assets _source/compare _source/dev _source/index.html \
     _source/press _source/privacy _source/robots.txt _source/sitemap.xml \
     _source/support _source/tools .
   rmdir _source
   ```

2. Remove the maintenance-only files that should not stay on the live site:

   ```bash
   git rm -f 404.html _config.yml MAINTENANCE.md README.md
   ```

   Keep `CNAME` and `.gitignore`. The move in step 1 replaces the maintenance `index.html` and `robots.txt`. This repo did not previously have a `404.html` or a root `README.md`.

3. Commit, open a pull request if `main` cannot be pushed directly, and merge. GitHub Pages will republish from `main` at `/`. DNS does not need to change.
