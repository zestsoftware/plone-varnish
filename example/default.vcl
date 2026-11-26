# Example default.vcl of a project, used by example/docker-compose.yml:
#
#     client → Traefik :80 (entrypoint web) → Varnish
#            → Traefik :8000 (entrypoint internal, VirtualHostMonster rewrite)
#            → Volto / Plone
#
# req.url is the public path of the site: Traefik adds the VirtualHostMonster
# path only on the way back, on its internal entrypoint.  That entrypoint is
# not published, so only Varnish (and other containers) can reach Plone
# through it.
#
# Only the protection is shown here; the caching rules of the project go in
# the same subroutines.
vcl 4.1;

import std;

include "zest/client.vcl";
include "zest/protection.vcl";

backend traefik {
    .host = "traefik";
    .port = "8000";
    .connect_timeout = 2s;
    .first_byte_timeout = 300s;
    .between_bytes_timeout = 60s;
}

# The proxies between the client and Varnish: here only Traefik, at its fixed
# address in docker-compose.yml.  With a load balancer in front of Traefik,
# add its addresses here, to the trustedIPs of Traefik's web entrypoint, and
# a second call to zest_strip_proxy below.
acl zest_proxies {
    "172.31.231.10";
}

sub zest_strip_proxies {
    # Traefik.
    call zest_strip_proxy;
}

# The containers of the stack, which send PURGE and BAN directly.
acl zest_purge {
    "localhost";
    "172.31.231.0"/24;
}

sub vcl_recv {
    set req.backend_hint = traefik;
    call zest_detect_client_ip;
    call zest_block_junk;

    if (req.method == "PURGE") {
        call zest_purge_allowed;
        return (purge);
    }
    if (req.method == "BAN") {
        call zest_purge_allowed;
        std.ban("req.http.host == " + req.http.host + " && req.url == " + req.url);
        return (synth(200, "Ban added"));
    }
}

sub vcl_miss {
    call zest_ratelimit;
}

sub vcl_pass {
    call zest_ratelimit;
}

sub vcl_pipe {
    set bereq.http.X-Forwarded-For = req.http.x-client-ip;
    unset bereq.http.x-client-ip;
}

sub vcl_backend_fetch {
    call zest_forward_client_ip;
}
