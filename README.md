# plone-varnish

Varnish for Plone sites, Classic UI and Volto: caching, protection against
scanners and scrapers, and a rate limit, as VCL include files and as an image.
The image is the official `varnish` image with the includes in
`/etc/varnish/plone/`.

A site keeps a short `default.vcl` with what differs per site (backend, ACLs,
its own redirects or blocks) and includes these files.  Improvements to the
rules then reach every site with a new image tag, instead of being copied
from project to project.

- [example/volto/](example/volto/): a Volto site, Traefik, Varnish, Volto
  and Plone.
- [example/classic/](example/classic/): a Classic UI site, Traefik, Varnish
  and Plone.

```
cd example/volto          # or example/classic
docker compose up -d --build
open http://plone.localhost:8090      # 8091 for classic; admin / admin
docker compose down -v
```

## How requests go

```
client → (load balancer) → Traefik, public entrypoint → Varnish
       → Traefik, internal entrypoint: VirtualHostMonster rewrite → Volto / Plone
```

- **Varnish sees the public URL.**  The VirtualHostMonster rewrite happens
  behind Varnish, when Traefik routes the request a second time.  So the rules
  work on public paths, the same for every site, and a PURGE of a path matches
  what is in the cache.
- **Varnish goes back to Traefik on an internal entrypoint** that is not
  published.  Not on the public entrypoint with a router that matches a
  header such as `X-Varnish-Routed`: anybody can send that header and skip
  Varnish.
- **The client comes from `X-Forwarded-For`.**  Every proxy in front of
  Varnish appends to it.  The first proxy you control trusts nothing from the
  internet; each next one trusts the one before it (Traefik:
  `forwardedHeaders.trustedIPs`).  Varnish passes only the client on, and
  Traefik's internal entrypoint trusts Varnish, so Plone and Volto see the
  client.

## The includes

`plone/client.vcl`

- `plone_detect_client_ip`: sets `req.http.x-client-ip` from
  `X-Forwarded-For`, skipping your own proxies from the right (a fixed number
  of hops, and only addresses in `plone_proxies`).  Addresses the client put in
  front itself are ignored.
- `plone_forward_client_ip`: sends only that client to the backend in
  `X-Forwarded-For`, so Traefik, Volto and Plone can't be given a forged one.
- `plone_purge_allowed`: PURGE and BAN only directly from `plone_purge`, never
  through a proxy.

`plone/protection.vcl`

- `plone_block_junk`: answers scanners and junk without the backend.  It looks
  at the path only, never at the query string.
  - 400: invalid UTF-8 (a server error in Zope), path traversal, characters
    that are never in a Plone path (quotes, `<>`, backslash, `{}`, `|`, `==`,
    `&&`: JavaScript and escaped JSON cut out of bundles and Volto pages), and
    a `b_start:int` that is not an integer.
  - 404 anywhere: segments starting with a dot (except `/.well-known/`),
    extensions that are never Plone content (`.php`, `.yml`, `.env`, `.log`,
    `.tfstate`, `.pem`, backups, ...), `node_modules`, `phpinfo`, `wp-*`,
    secrets such as `id_rsa`, and "links" that crawlers cut out of CSS, SVG
    and fonts (SVG path data, glyph names, comma lists).
  - 404 only in the root: archives, `package.json` and other build files,
    `Makefile` and friends, `*.config.js`, the login pages and APIs of other
    software.  Deeper in the site such files may be uploads by editors.
  - 405 for CONNECT, TRACE and TRACK; 403 for a truncated scraper user agent.

  Not blocked, because a Plone site may have such content: names like
  `test`, `api`, `status`, `health`, `info`, `version`, `mcp`.  The rate limit
  takes care of scanners that try those.
- `plone_ratelimit`: 100 backend requests per 10 seconds per client, 300 with a
  login cookie or `Authorization`.  Cache hits don't count.  Rejected requests
  get a 429 and are logged:

  ```
  varnishlog -g request -q 'VCL_Log:ratelimit'
  ```

`plone/caching.vcl`

- `plone_recv`:
  - PURGE bans every cached object with that URL, whatever `Host` the purger
    sends (Plone sends the host of Varnish, not the public one).  BAN takes a
    regular expression on the URL, for the host it is sent to.
  - Only GET and HEAD come from the cache.  Other methods are passed (not
    piped, so they count for the rate limit); websockets are piped.
  - Logged in users (`__ac`, `auth_token`, `_ZopeId`, `Authorization`) are
    passed, except for static resources (`++plone++`, `++resource++`,
    `++theme++`, `++webresource++`), which are the same for everybody.
  - Cookies other than Plone's and a load balancer's are removed.  A request
    that still has `statusmessages`, `I18N_LANGUAGE` or the clipboard is
    passed: the page depends on it.
  - JSON for a URL that also has an HTML page (plone.restapi with Classic UI)
    is passed.  Large media and archives are streamed, not stored.
- `plone_backend_response`: caches what the backend allows with
  `Cache-Control` (plone.app.caching), never responses with `Set-Cookie`,
  `private`, `no-cache` or `no-store`, nor responses without any caching
  headers (no plone.app.caching rule: they may be personal).  404 for 5
  minutes, icons for a day.  Errors are not cached; a failed background
  refresh keeps serving the stale page.  Stale pages are served for at most a
  minute while Plone is healthy, ten minutes while it is down.
- `plone_deliver`: `X-Cache` (HIT or MISS) and `X-Cacheable` (why), and
  `s-maxage=0` for caches after this one, so a purge reaches everything.
- `plone_synth`: a plain error page, and redirects:
  `return (synth(301, "/new/path"))` in `vcl_recv`.

`plone/volto.vcl`, for Volto sites on top of `caching.vcl`:

- `plone_volto_recv`: Volto's build under `/static/` comes from the cache for
  logged in users too.
- `plone_volto_backend_response`: pages that Volto renders have no
  `Cache-Control`; for anonymous visitors they are cached for 30 seconds,
  and banned by a PURGE of their URL like the content they show.

### Plone settings

Varnish only caches what Plone allows, so the caching settings decide how
much it does.  Tried with Plone 6.2 (see the examples):

- A new Classic UI site does not have plone.app.caching installed: install
  it in Site Setup → Add-ons first.
- In Site Setup → Caching, import the profile "With caching proxy", enable
  caching and purging, with caching proxy `http://varnish:80` (the Varnish
  service, directly, not through Traefik), and leave "Virtual host rewriting
  takes place in front of the caching proxy" off: the rewrite happens behind
  Varnish.
- That profile caches resources (a year), files and feeds (a day) in
  Varnish, but not pages: `plone.content.itemView` and
  `plone.content.folderView` get `weakCaching`, which is `private`.  Map
  them to `moderateCaching` to cache pages too.
- Plone only purges the content types in "Content types to purge" (File,
  Image and News Item by default).  Add the types whose pages you cache, or
  an edited page stays old in Varnish until its TTL ends.

## Use

Your `default.vcl` defines two ACLs and the number of proxy hops, and calls the
subroutines.  [example/volto/default.vcl](example/volto/default.vcl) is a
whole one; for Classic UI leave out `volto.vcl` and its two calls
([example/classic/default.vcl](example/classic/default.vcl)).

```vcl
vcl 4.1;

include "plone/client.vcl";
include "plone/protection.vcl";
include "plone/caching.vcl";
include "plone/volto.vcl";           # Volto only

backend traefik {
    .host = "traefik";
    .port = "8000";                  # Traefik's internal entrypoint
}

# The proxies between the client and Varnish, and nothing else: visitors on
# an internal network have private addresses too.
acl plone_proxies {
    "10.0.1.0"/24;                   # Traefik
}

# Once per proxy hop, for example Traefik and a load balancer in front of it.
sub plone_strip_proxies {
    call plone_strip_proxy;
}

# Who may PURGE and BAN, directly (Plone).
acl plone_purge {
    "localhost";
    "10.0.0.0"/8;
}

sub vcl_recv {
    set req.backend_hint = traefik;
    call plone_detect_client_ip;
    call plone_block_junk;
    # Site specific redirects and blocks go here.
    call plone_volto_recv;           # Volto only
    call plone_recv;                 # last: it returns
}

sub vcl_miss { call plone_ratelimit; }
sub vcl_pass { call plone_ratelimit; }
sub vcl_pipe { call plone_forward_client_ip; }
sub vcl_backend_fetch { call plone_forward_client_ip; }

sub vcl_backend_response {
    call plone_volto_backend_response;   # Volto only
    call plone_backend_response;
}

sub vcl_deliver { call plone_deliver; }
sub vcl_synth { call plone_synth; }
```

Varnish refuses VCL with a subroutine that is never called, so once you
include a file you have to call all of its `plone_*` subroutines.  That is on
purpose: forgetting `plone_forward_client_ip` or `plone_ratelimit` is a
compile error, not a hole you find later.

The image, with your `default.vcl` on top:

```dockerfile
FROM ghcr.io/zestsoftware/plone-varnish:1
COPY etc/varnish.vcl /etc/varnish/default.vcl
```

or use the image as it is, with `default.vcl` as a bind mount
(`./varnish.vcl:/etc/varnish/default.vcl:ro`) or a Swarm config with target
`/etc/varnish/default.vcl`.

Tags: `1.2.3`, `1.2`, `1`, only for releases.  Pin a release; Dependabot or
Renovate opens the update.

## Development

```
make test
```

builds the image, runs the varnishtest cases in `tests/` and compiles the
`default.vcl` of both examples.  Needs Docker.

## Release

With [zest.releaser](https://zestreleaser.readthedocs.io/), on `main`:

```
uvx --from zest.releaser fullrelease
```

It takes the version from `version.txt` (`1.1.0.dev0` becomes `1.1.0`), dates
the section in `CHANGES.md`, commits, tags (`1.1.0`, no `v`), goes back to
development (`1.1.1.dev0`, a new changelog section) and pushes.  This is no
Python package, so it builds and uploads nothing.  On the tag, CI checks that
the tag matches `version.txt`, tests, and pushes the image with the tags
`1.1.0`, `1.1` and `1`.

## License

MIT, see [LICENSE.md](LICENSE.md).  `plone/caching.vcl` is based on the VCL of
the cookieplone templates (MIT) and plone.recipe.varnish (BSD).
