# syntax=docker/dockerfile:1
ARG VARNISH_VERSION=9.1
FROM varnish:${VARNISH_VERSION}

LABEL org.opencontainers.image.title="plone-varnish" \
      org.opencontainers.image.description="Varnish with shared protection rules for Plone sites behind Traefik." \
      org.opencontainers.image.source="https://github.com/zestsoftware/plone-varnish" \
      org.opencontainers.image.vendor="Zest Software" \
      org.opencontainers.image.licenses="MIT"

# Included from the default.vcl of each project.
COPY vcl/plone/ /etc/varnish/plone/
