# plone-varnish

Shared protection rules for the Varnish in front of Plone sites, as VCL include
files and as an image: the official `varnish` image with the includes in
`/etc/varnish/zest/`.

Each project keeps its own `default.vcl` with what differs per site (backend,
probe, ACLs, caching rules) and includes these files.  A change to the rules is
then a new image tag in each project, instead of a copy in each project.

## What is in it

`zest/client.vcl`

- `zest_detect_client_ip`: sets `req.http.x-client-ip` from
  `X-Forwarded-For`, skipping your own proxies from the right (a fixed number
  of hops, and only addresses in `zest_proxies`).  Addresses the client put in
  front itself are ignored.
- `zest_forward_client_ip`: sends only that client to the backend in
  `X-Forwarded-For`, so Traefik, Volto and Plone can't be given a forged one.
- `zest_purge_allowed`: PURGE and BAN only directly from `zest_purge`, never
  through a proxy.

`zest/protection.vcl`

- `zest_block_junk`: answers scanners and junk without the backend.  It looks
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
- `zest_ratelimit`: 100 backend requests per 10 seconds per client, 300 with a
  login cookie or `Authorization`.  Cache hits don't count.  Rejected requests
  get a 429 and are logged:

  ```
  varnishlog -g request -q 'VCL_Log:ratelimit'
  ```

## Assumptions

- **Varnish sees the public URL.**  The VirtualHostMonster rewrite happens
  behind Varnish: Traefik → Varnish → Traefik (adds `/VirtualHostBase/…`) →
  Volto/Plone.  The rules match on `req.url`.
- **Varnish goes back to Traefik on an internal entrypoint**, one that is not
  published.  Not on the public entrypoint with a router that matches a
  header such as `X-Varnish-Routed`: anybody can send that header and skip
  Varnish.

[example/docker-compose.yml](example/docker-compose.yml) is a whole stack
(Traefik, Varnish, Volto, Plone) with the routers and rewrites for Volto, the
REST API and `/ClassicUI`, and the one rewrite a Classic UI site needs
instead.  Run it with `cd example && docker compose up -d --build` and open
http://plone.localhost:8090.
- **The client comes from `X-Forwarded-For`.**  Every proxy in front of
  Varnish appends to it and trusts the one before it (Traefik:
  `forwardedHeaders.trustedIPs`), and the first proxy you control does not
  trust what the internet sends.

## Use

Your `default.vcl` defines two ACLs and the number of proxy hops, and calls the
subroutines.  See [example/default.vcl](example/default.vcl) for a whole one.

```vcl
vcl 4.1;

include "zest/client.vcl";
include "zest/protection.vcl";

# The proxies between the client and Varnish, and nothing else: visitors on
# an internal network have private addresses too.
acl zest_proxies {
    "10.0.1.0"/24;      # Traefik
}

# Once per proxy hop, for example Traefik and a load balancer in front of it.
sub zest_strip_proxies {
    call zest_strip_proxy;
}

# Who may PURGE and BAN, directly (Plone).
acl zest_purge {
    "localhost";
    "10.0.0.0"/8;
}

sub vcl_recv {
    call zest_detect_client_ip;
    call zest_block_junk;
    if (req.method == "PURGE") {
        call zest_purge_allowed;
        return (purge);
    }
    # ...
}

sub vcl_miss { call zest_ratelimit; }
sub vcl_pass { call zest_ratelimit; }
sub vcl_backend_fetch { call zest_forward_client_ip; }
```

Varnish refuses VCL with a subroutine that is never called, so once you
include a file you have to call all of its `zest_*` subroutines.  That is on
purpose: forgetting `zest_forward_client_ip` or `zest_ratelimit` is a
compile error, not a hole you find later.

The image, with your `default.vcl` on top:

```dockerfile
FROM ghcr.io/zestsoftware/plone-varnish:1
COPY etc/varnish.vcl /etc/varnish/default.vcl
```

or use the image as it is, with `default.vcl` as a bind mount
(`./varnish.vcl:/etc/varnish/default.vcl:ro`) or a Swarm config with target
`/etc/varnish/default.vcl`.

Tags: `1.2.3`, `1.2`, `1` for releases, `main` and `latest` for the main
branch.  Pin a release; Dependabot or Renovate opens the update.

## Development

```
make test
```

builds the image, runs the varnishtest cases in `tests/` and compiles
`example/default.vcl`.  Needs Docker.

## Release

Add the version and date to `CHANGES.md`, commit, and push a tag with the
version (`1.0.0`, no `v`).  CI tests it and pushes the image with the tags
`1.0.0`, `1.0` and `1`.
