# Caching for Plone, Classic UI and Volto.
#
#     include "plone/client.vcl";
#     include "plone/protection.vcl";
#     include "plone/caching.vcl";
#
# Varnish caches what the backend allows with Cache-Control (plone.app.caching
# for Plone, Volto for /static/), never for logged in users, and serves stale
# pages while Plone is slow or down.  Call:
#
# - plone_recv last in vcl_recv: it handles PURGE and BAN (with
#   plone_purge_allowed from client.vcl) and returns;
# - plone_backend_response in vcl_backend_response;
# - plone_deliver in vcl_deliver;
# - plone_synth in vcl_synth.
#
# A Volto site also includes volto.vcl, see there.
vcl 4.1;

import std;

sub plone_recv {
    # PURGE, as plone.cachepurging and cluster purgers send it: every cached
    # object with this URL, whatever host it was asked for.  The purger
    # sends the Host of Varnish itself (http://varnish:80), not the public
    # one, so an ordinary purge of the hash would miss.  The bans test
    # headers on the objects, so the ban lurker cleans them up.
    if (req.method == "PURGE") {
        call plone_purge_allowed;
        if (std.ban("obj.http.x-plone-url == " + req.url)) {
            return (synth(200, "Purged"));
        }
        return (synth(400, std.ban_error()));
    }
    # BAN: a regular expression on the URL, for this host only.
    if (req.method == "BAN") {
        call plone_purge_allowed;
        if (std.ban("obj.http.x-plone-host == " + req.http.host +
                    " && obj.http.x-plone-url ~ " + req.url)) {
            return (synth(200, "Banned"));
        }
        return (synth(400, std.ban_error()));
    }

    # Websockets need a direct connection.
    if (req.http.Upgrade ~ "(?i)websocket") {
        return (pipe);
    }
    # Only GET and HEAD come from the cache.  Everything else (POST, OPTIONS
    # for CORS, WebDAV) is passed, not piped: piped requests skip the rate
    # limit.
    if (req.method != "GET" && req.method != "HEAD") {
        return (pass);
    }
    # A JSON response of plone.restapi for a URL that also has an HTML page
    # (Classic UI): not from the cache.  Volto uses /++api++/, see below.
    if (req.http.Accept ~ "application/json" && req.url !~ "^/\+\+api\+\+(/|$)") {
        return (pass);
    }

    # Logged in: Classic UI (__ac), Volto (auth_token), a Zope session, or
    # basic authentication.  Never from the cache, except static resources:
    # they are the same for everybody, so they are asked without the cookie.
    if (req.http.Authorization ||
        req.http.Cookie ~ "(^|;\s*)(__ac(_[a-z]+)?|auth_token|_ZopeId)=") {
        if (req.url ~ "/\+\+(plone|resource|theme|webresource)\+\+" &&
            req.url !~ "/\+\+resource\+\+zmi/") {
            unset req.http.Cookie;
            unset req.http.Authorization;
        } else {
            return (pass);
        }
    }

    # Only the cookies of Plone and of a load balancer behind Varnish stay;
    # the rest (statistics and the like) would make every page uncacheable.
    if (req.http.Cookie) {
        set req.http.Cookie = ";" + req.http.Cookie;
        set req.http.Cookie = regsuball(req.http.Cookie, "; +", ";");
        set req.http.Cookie = regsuball(req.http.Cookie, ";(statusmessages|I18N_LANGUAGE|__cp|__rf|beaker\.session|authomatic|sticky|serverid)=", "; \1=");
        set req.http.Cookie = regsuball(req.http.Cookie, ";[^ ][^;]*", "");
        set req.http.Cookie = regsuball(req.http.Cookie, "^[; ]+|[; ]+$", "");
        if (req.http.Cookie == "") {
            unset req.http.Cookie;
        }
    }
    # A cookie that changes the page (a status message, the language, the
    # clipboard): not from the cache.  The load balancer cookies don't.
    if (req.http.Cookie ~ "(^|;\s*)(statusmessages|I18N_LANGUAGE|__cp|__rf|beaker\.session|authomatic)=") {
        return (pass);
    }

    # Large media and archives are streamed, not stored.
    if (req.url ~ "(?i)\.(mp3|mp4|m4a|m4v|mov|avi|webm|ogg|ogv|wav|flac|zip|rar|7z|tar|tgz|iso|dmg)(\?.*)?$") {
        return (pass);
    }

    # While Plone is healthy, a stale object is served for at most a minute
    # (and refreshed in the background); when it is sick, as long as
    # beresp.grace allows.
    if (std.healthy(req.backend_hint)) {
        set req.grace = 60s;
    }
    return (hash);
}

sub plone_backend_response {
    # For PURGE and BAN, see plone_recv.  Removed in plone_deliver.
    set beresp.http.x-plone-url = bereq.url;
    set beresp.http.x-plone-host = bereq.http.host;

    # Errors are not cached.  A background refresh that fails keeps the stale
    # object.
    if (beresp.status >= 500) {
        if (bereq.is_bgfetch) {
            return (abandon);
        }
        set beresp.http.X-Cacheable = "NO - error";
        set beresp.http.Cache-Control = "no-cache, max-age=0, must-revalidate";
        set beresp.uncacheable = true;
        set beresp.ttl = 0s;
        return (deliver);
    }

    # Static files for anonymous visitors don't need cookies (from a load
    # balancer, for instance), which would make them uncacheable.  Passed
    # requests keep them: that is where a login cookie gets renewed.
    if (!bereq.uncacheable &&
        bereq.url ~ "(?i)\.(css|js|mjs|map|png|gif|jpe?g|webp|avif|svg|ico|woff2?|ttf|eot)(\?.*)?$") {
        unset beresp.http.Set-Cookie;
    }

    if (beresp.http.Set-Cookie) {
        set beresp.http.X-Cacheable = "NO - Set-Cookie";
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }
    if (beresp.http.Cache-Control ~ "(?i)private|no-cache|no-store") {
        set beresp.http.X-Cacheable = "NO - Cache-Control";
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }
    if (beresp.http.Surrogate-Control ~ "(?i)no-store" || beresp.http.Vary == "*") {
        set beresp.http.X-Cacheable = "NO - Surrogate-Control or Vary";
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    # Not found is not found for everybody, and mostly asked by bots.
    if (beresp.status == 404) {
        set beresp.http.X-Cacheable = "YES - 404, 5m";
        set beresp.ttl = 5m;
        set beresp.grace = 10m;
        return (deliver);
    }
    # Icons only get a short max-age from Plone and Volto.
    if (beresp.status == 200 &&
        bereq.url ~ "^/(favicon\.ico|icon\.svg|site\.webmanifest|apple-touch-icon[^/]*\.png)(\?.*)?$") {
        set beresp.http.X-Cacheable = "YES - icon, 1d";
        set beresp.ttl = 1d;
        set beresp.grace = 10m;
        return (deliver);
    }

    # No Cache-Control: plone.app.caching has no rule for this response, so
    # it may be personal.  Expires alone doesn't count: without
    # plone.app.caching Plone sends "Expires: Sat, 1 Jan 2000 00:00:00 GMT"
    # to say "don't cache", which Varnish ignores (the day has one digit) and
    # would replace by its default TTL.  (volto.vcl marks the pages that Volto
    # renders, which never have Cache-Control.)
    if (!beresp.http.Cache-Control && !beresp.http.Surrogate-Control &&
        !beresp.http.x-plone-volto) {
        set beresp.http.X-Cacheable = "NO - no Cache-Control";
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }
    if (beresp.ttl <= 0s) {
        set beresp.http.X-Cacheable = "NO - TTL 0";
        set beresp.uncacheable = true;
        set beresp.ttl = 120s;
        return (deliver);
    }

    if (beresp.http.x-plone-volto) {
        set beresp.http.X-Cacheable = "YES - Volto page, " + beresp.ttl;
    } else {
        set beresp.http.X-Cacheable = "YES";
        set beresp.grace = 10m;
    }
    return (deliver);
}

sub plone_deliver {
    if (obj.hits > 0) {
        set resp.http.X-Cache = "HIT";
    } else {
        set resp.http.X-Cache = "MISS";
    }
    unset resp.http.x-plone-url;
    unset resp.http.x-plone-host;
    unset resp.http.x-plone-volto;
    unset resp.http.X-Powered-By;
    # s-maxage is for this cache: proxies and CDNs after it must not keep the
    # page that long, or a purge would not reach them.
    if (resp.http.Cache-Control ~ "s-maxage") {
        set resp.http.Cache-Control = regsub(resp.http.Cache-Control, "s-maxage=[0-9]+", "s-maxage=0");
    }
    if (resp.http.Cache-Control ~ ",\s*proxy-revalidate") {
        set resp.http.Cache-Control = regsub(resp.http.Cache-Control, ",\s*proxy-revalidate", "");
    }
}

sub plone_synth {
    # Redirects: return (synth(301, "/new/location")) in vcl_recv.
    if (resp.status == 301 || resp.status == 302 || resp.status == 307 || resp.status == 308) {
        set resp.http.Location = resp.reason;
        if (resp.status == 301 || resp.status == 308) {
            set resp.reason = "Moved Permanently";
        } else {
            set resp.reason = "Found";
        }
        set resp.body = "";
        return (deliver);
    }
    if (resp.status == 429 || resp.status == 503) {
        set resp.http.Retry-After = "5";
    }
    set resp.http.Content-Type = "text/html; charset=utf-8";
    set resp.body = {"<!doctype html>
<html>
  <head>
    <meta charset="utf-8">
    <title>"} + resp.status + " " + resp.reason + {"</title>
  </head>
  <body>
    <h1>"} + resp.status + " " + resp.reason + {"</h1>
    <p>Request "} + req.xid + {"</p>
  </body>
</html>
"};
    return (deliver);
}
