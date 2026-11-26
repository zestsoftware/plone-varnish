# What only a Volto site needs, on top of caching.vcl.
#
#     include "plone/caching.vcl";
#     include "plone/volto.vcl";
#
# Call plone_volto_recv in vcl_recv just before plone_recv, and
# plone_volto_backend_response in vcl_backend_response just before
# plone_backend_response.
#
# It assumes the usual routing behind Varnish: /++api++/ and /ClassicUI/ go to
# Plone, everything else to Volto.
vcl 4.1;

sub plone_volto_recv {
    # Volto's build (JavaScript, CSS, fonts, with a hash in the name) is the
    # same for everybody: from the cache, also for logged in users.
    if (req.url ~ "^/static/" && (req.method == "GET" || req.method == "HEAD")) {
        unset req.http.Cookie;
        unset req.http.Authorization;
    }
}

sub plone_volto_backend_response {
    # The pages that Volto renders on the server have no Cache-Control.  For
    # anonymous visitors they are cached for 30 seconds, served stale for a
    # minute more while Volto renders them again, and banned by a PURGE of
    # their URL like the content they show.
    if (!bereq.uncacheable &&
        beresp.status == 200 &&
        bereq.url !~ "^/(\+\+api\+\+|ClassicUI)(/|$)" &&
        beresp.http.Content-Type ~ "^text/html" &&
        !beresp.http.Cache-Control && !beresp.http.Set-Cookie) {
        set beresp.http.x-plone-volto = "1";
        set beresp.ttl = 30s;
        set beresp.grace = 60s;
    }
}
