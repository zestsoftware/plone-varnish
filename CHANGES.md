# Changelog

## 1.1.0 (2026-11-26)

- Neutral names, so that any Plone project (and cookieplone) can use it: the
  subroutines are `plone_*` instead of `zest_*`, the ACLs `plone_proxies` and
  `plone_purge`, and the includes are in `/etc/varnish/plone/` instead of
  `/etc/varnish/zest/`.  Rename them in your `default.vcl`.
- MIT License instead of GPL-2.0, like cookieplone (`LICENSE.md`).  Added
  `CONTRIBUTORS.md` and `version.txt`, which CI checks against the release
  tag.
- New `plone/caching.vcl`: the caching every Plone site needs, Classic UI and
  Volto, from the VCL of the cookieplone template and of plone.recipe.varnish.
  PURGE bans by URL whatever Host the purger sends; other methods are passed,
  not piped, so they count for the rate limit; anonymous requests with a
  cookie that changes the page are passed.
- New `plone/volto.vcl`: pages that Volto renders, and `/static/`.
- `plone_block_junk` leaves PURGE and BAN to `plone_purge_allowed`: a BAN has a
  regular expression as its URL.
- Examples for Volto (`example/volto/`) and Classic UI (`example/classic/`).
- Images only for releases: no more `main` and `latest` tags.

## 1.0.0 (2026-11-26)

- First version: `zest/client.vcl` (client address from X-Forwarded-For,
  forwarding it, PURGE and BAN only directly) and `zest/protection.vcl`
  (blocking scanners and junk, rate limit), on Varnish 9.1.0.
