# Changelog

## 1.0.1 (unreleased)

- Images only for releases: no more `main` and `latest` tags.

## 1.0.0 (2026-11-26)

- First version: `zest/client.vcl` (client address from X-Forwarded-For,
  forwarding it, PURGE and BAN only directly) and `zest/protection.vcl`
  (blocking scanners and junk, rate limit), on Varnish 9.1.0.
