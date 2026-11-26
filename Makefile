IMAGE ?= plone-varnish:test

.PHONY: build test

build:
	docker build -t $(IMAGE) .

# varnishtest for the includes, and a compile of the example default.vcl.
test: build
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" --entrypoint varnishtest $(IMAGE) -b 64M -j4 $(addprefix /tests/,$(notdir $(wildcard tests/*.vtc)))
	docker run --rm --add-host traefik:127.0.0.1 -v "$(CURDIR)/example/default.vcl:/etc/varnish/default.vcl:ro" --entrypoint varnishd $(IMAGE) -C -f /etc/varnish/default.vcl > /dev/null
	@echo "All tests passed."
