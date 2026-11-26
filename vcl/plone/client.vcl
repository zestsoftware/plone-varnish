# The client address, from X-Forwarded-For, and who may PURGE or BAN.
#
#     include "plone/client.vcl";
#
# The including VCL defines:
#
#     # The proxies between the client and Varnish, and nothing else:
#     # visitors on an internal network have private addresses too.
#     acl plone_proxies { "10.0.1.0"/24; }
#
#     # Once for each proxy hop between the client and Varnish.
#     sub plone_strip_proxies { call plone_strip_proxy; }
#
#     # The addresses that may send PURGE and BAN directly to Varnish.
#     acl plone_purge { "localhost"; "10.0.0.0"/8; }
#
# and calls plone_detect_client_ip first thing in vcl_recv, and
# plone_forward_client_ip in vcl_backend_fetch.
vcl 4.1;

import std;

# Sets req.http.x-client-ip.
#
# Every proxy appends the address its connection came from to
# X-Forwarded-For, and Varnish appends client.ip itself before vcl_recv.  So
# the right end was written by our own proxies, and everything left of the
# client was sent by the client and cannot be trusted.  plone_strip_proxies
# removes our own hops from the right, by position and only if they are in
# plone_proxies, and the rightmost address left is the client.  Without a
# proxy in front (a local stack) only proxies remain, and the leftmost of
# them is used.
sub plone_detect_client_ip {
    set req.http.x-client-ip = req.http.X-Forwarded-For;
    call plone_strip_proxies;
    set req.http.x-client-ip = regsub(req.http.x-client-ip, "^.*,\s*", "");
}

# Removes the rightmost address of x-client-ip if it is one of plone_proxies,
# and at least one address stays.
sub plone_strip_proxy {
    if (req.http.x-client-ip ~ "," &&
        std.ip(regsub(req.http.x-client-ip, "^.*,\s*", ""), std.ip("0.0.0.0", client.ip)) ~ plone_proxies) {
        set req.http.x-client-ip = regsub(req.http.x-client-ip, "\s*,[^,]*$", "");
    }
}

# Passes on only the client found by plone_detect_client_ip, not the
# X-Forwarded-For the client sent: Traefik, Volto and Plone read the
# leftmost address, which a client can forge.
sub plone_forward_client_ip {
    set bereq.http.X-Forwarded-For = bereq.http.x-client-ip;
    unset bereq.http.x-client-ip;
}

# Call before handling PURGE and BAN.
#
# Requests from outside come through a proxy, from an address in the
# network of the stack, so plone_purge alone does not do.  A request through
# a proxy always has more than one address in X-Forwarded-For (the proxy's
# and the one Varnish appended); a direct request has only client.ip.
sub plone_purge_allowed {
    if (!client.ip ~ plone_purge || req.http.X-Forwarded-For ~ ",") {
        return (synth(405, "This IP is not allowed to send PURGE or BAN requests."));
    }
}
