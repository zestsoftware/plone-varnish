# Requests answered without the backend, and a rate limit.
#
#     include "zest/client.vcl";
#     include "zest/protection.vcl";
#
# req.url must be the public path of the site: the VirtualHostMonster
# rewrite happens behind Varnish.  Call zest_block_junk in vcl_recv after
# zest_detect_client_ip, and zest_ratelimit in vcl_miss and vcl_pass.
vcl 4.1;

import std;
import vsthrottle;

sub zest_block_junk {
    # A scraper on a proxy network (about 300 addresses at once) with this
    # truncated user agent.  Browsers send more.
    if (req.http.User-Agent == "Mozilla/5.0 (Windows NT 10.0; Win64; x64)") {
        return (synth(403, "Forbidden"));
    }

    # Open proxy probes with CONNECT, and TRACE/TRACK.  (An absolute URL,
    # GET http://other.host/path, Varnish itself turns into a path and a
    # Host header, for which Traefik has no router.)
    if (req.method ~ "^(CONNECT|TRACE|TRACK)$") {
        return (synth(405, "Method Not Allowed"));
    }

    # The rules below look at the path only: a query string may contain
    # anything a visitor searches for.
    set req.http.x-zest-path = regsub(req.url, "\?.*$", "");

    # Invalid UTF-8 (bytes cut out of font files and the like) gives a server
    # error in Zope.  Valid sequences are removed, a high byte left over is
    # invalid.
    if (regsuball(req.http.x-zest-path,
            "(?i)%(c[2-9a-f]|d[0-9a-f])%[89ab][0-9a-f]|%e[0-9a-f](%[89ab][0-9a-f]){2}|%f[0-4](%[89ab][0-9a-f]){3}",
            "") ~ "(?i)%[89a-f][0-9a-f]") {
        return (synth(400, "Bad Request"));
    }

    # Path traversal, and characters that are never in the path of a Plone
    # site: quotes, <>, backslash, {}, |, ^, backtick, NUL (raw or encoded),
    # and == or && from JavaScript cut out of the bundles.  This includes
    # links scraped from the JSON in Volto's pages, with escaped slashes.
    if (req.http.x-zest-path ~ "(?i)(\.|%2e){2}(/|%2f|\\|%5c|$)|etc(/|%2f)passwd" ||
        req.http.x-zest-path ~ "(?i)[\x22<>\\^`{|}]|%(00|22|3c|3e|5c|5e|60|7b|7c|7d)|==|&&") {
        return (synth(400, "Bad Request"));
    }

    # Not a URL at all, but taken for one by crawlers that cut "links" out of
    # CSS, SVG and fonts: SVG path data (M1468 1156q...) and comma separated
    # lists (glyph names, polygon points).
    if (req.http.x-zest-path ~ "(?i)/M-?[0-9]+(\.[0-9]+)?%20-?[0-9]+(\.[0-9]+)?[a-z]" ||
        req.http.x-zest-path ~ "/[^/]*,[^/]*,[^/]*,[^/]*") {
        return (synth(404, "Not Found"));
    }

    # Vulnerability scans, anywhere in the site:
    # - a segment starting with a dot (.git, .env, .ssh, .idea, glyph names
    #   like .notdef), except /.well-known/;
    # - extensions that are never Plone content: server side scripts,
    #   configuration, backups, keys, logs, font glyph variants;
    # - directories and files of other software, and secrets.
    if (req.http.x-zest-path ~ "/\.(?!well-known(/|$))[^/]" ||
        req.http.x-zest-path ~ "(?i)\.(php[0-9]?|phtml|asp|aspx|asax|asa|jsp|cgi|env|ini|cfg|inc|sql|bak|old|orig|save|swp|ya?ml|toml|lock|tf|tfstate|tfvars|pem|enc|gradle|properties|log|t?osf|ss[0-9]{2})(/|$)" ||
        req.http.x-zest-path ~ "[^/]~(/|$)" ||
        req.http.x-zest-path ~ "(?i)/(node_modules|phpinfo|cgi-bin|_ignition|@fs|storage/logs|var/log)(/|$)" ||
        req.http.x-zest-path ~ "(?i)/(wp-(admin|content|includes|login|json)|xmlrpc)" ||
        req.http.x-zest-path ~ "(?i)/((local_)?settings(_local)?|config|wsgi|manage)\.py$" ||
        req.http.x-zest-path ~ "(?i)/(id_(rsa|dsa|ecdsa|ed25519)|master\.key|secret_token\.rb|(aws-)?credentials(\.[a-z]+)?|appsettings\.[^/]*\.json)$") {
        return (synth(404, "Not Found"));
    }

    # The same, only in the root of the site: here they are scans, deeper in
    # the site they may be files that editors uploaded.  And the login pages
    # and APIs of other software.
    if (req.http.x-zest-path ~ "(?i)^/([^/]*\.(zip|tar|tgz|tar\.gz|rar|7z|py|rb|md|key|crt|db|sqlite3?|config)|(package(-lock)?|composer|tsconfig|jsconfig|angular|vercel|railway|settings|secrets|mix-manifest|appsettings|firebase|app|config)\.json|[^/]*\.config\.(js|ts|mjs|cjs)|(make|rake|cap|gem|pip|proc|vagrant|gulp|grunt|jenkins|brew|docker)file(\.lock|\.js)?|(crossdomain|clientaccesspolicy|phpunit|pom)\.xml|(requirements|build)\.txt|main\.dart\.js|firebase-messaging-sw\.js|direnv|consul\.kv|env|hnap1|_debugbar)$" ||
        req.http.x-zest-path ~ "(?i)^/(autodiscover/|remote/login|rest/applinks/|server-(status|info)|telescope|webui/|sdk$|odinhttpcall|config/[^/]*\.json$|actuator(/|$)|solr/|geoserver/|evox/|developmentserver/)") {
        return (synth(404, "Not Found"));
    }
    unset req.http.x-zest-path;

    # The Zope converter of b_start:int (also URL encoded, b_start%3Aint)
    # gives a server error in Plone for a value that is not an integer
    # (empty, letters, injection attempts).
    if (req.url ~ "[?&]b_start(:|%3[aA])int=([^&]*[^0-9&][^&]*)?(&|$)") {
        return (synth(400, "Bad Request"));
    }
}

# Only requests that go to Plone count, cache hits are cheap, so Varnish
# keeps absorbing peaks.  100 requests per 10s per client: in production
# logs that only hit scrapers and scanners.  Requests with a login cookie or
# Authorization get 300, for several editors behind one office address
# (a client can send a fake cookie too, so 300 is the real ceiling).
# Rejected requests are logged, see them with:
#   varnishlog -g request -q 'VCL_Log:ratelimit'
sub zest_ratelimit {
    if (req.http.Cookie ~ "(^|;\s*)(__ac|auth_token)=" || req.http.Authorization) {
        if (vsthrottle.is_denied("auth:" + req.http.x-client-ip, 300, 10s)) {
            std.log("ratelimit:" + req.http.x-client-ip);
            return (synth(429, "Too Many Requests"));
        }
    } elseif (vsthrottle.is_denied("client:" + req.http.x-client-ip, 100, 10s)) {
        std.log("ratelimit:" + req.http.x-client-ip);
        return (synth(429, "Too Many Requests"));
    }
}
