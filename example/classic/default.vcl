# default.vcl of a Classic UI site, used by docker-compose.yml next to it:
#
#     client → Traefik :80 (entrypoint web) → Varnish
#            → Traefik :8000 (entrypoint internal, VirtualHostMonster rewrite)
#            → Plone
#
# req.url is the public path of the site: Traefik adds the VirtualHostMonster
# path only on the way back, on its internal entrypoint.  That entrypoint is
# not published, so only Varnish (and other containers) can reach Plone
# through it.
#
# What is left here is specific to the site: backend, ACLs, and the order of
# the calls.  Site specific rules (redirects, extra blocks) go before or after
# the calls.
vcl 4.1;

include "plone/client.vcl";
include "plone/protection.vcl";
include "plone/caching.vcl";

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
# a second call to plone_strip_proxy below.
acl plone_proxies {
    "172.31.232.10";
}

sub plone_strip_proxies {
    # Traefik.
    call plone_strip_proxy;
}

# The containers of the stack, which send PURGE and BAN directly.
acl plone_purge {
    "localhost";
    "172.31.232.0"/24;
}

sub vcl_recv {
    set req.backend_hint = traefik;
    call plone_detect_client_ip;
    call plone_block_junk;
    call plone_recv;
}

sub vcl_miss {
    call plone_ratelimit;
}

sub vcl_pass {
    call plone_ratelimit;
}

sub vcl_pipe {
    call plone_forward_client_ip;
}

sub vcl_backend_fetch {
    call plone_forward_client_ip;
}

sub vcl_backend_response {
    call plone_backend_response;
}

sub vcl_deliver {
    call plone_deliver;
}

sub vcl_synth {
    call plone_synth;
}
