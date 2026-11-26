IMAGE ?= plone-varnish:test

.PHONY: build test release

build:
	docker build -t $(IMAGE) .

# varnishtest for the includes, and a compile of the default.vcl of both examples.
test: build
	docker run --rm -v "$(CURDIR)/tests:/tests:ro" --entrypoint varnishtest $(IMAGE) -b 64M -j4 $(addprefix /tests/,$(notdir $(wildcard tests/*.vtc)))
	for example in volto classic; do \
		echo "Compiling example/$$example/default.vcl"; \
		docker run --rm --add-host traefik:127.0.0.1 -v "$(CURDIR)/example/$$example/default.vcl:/etc/varnish/default.vcl:ro" --entrypoint sh $(IMAGE) \
			-c 'varnishd -C -f /etc/varnish/default.vcl > /dev/null 2> /tmp/vcc.log || { grep -v "^#" /tmp/vcc.log | tail -20; exit 1; }' || exit 1; \
	done
	@echo "All tests passed."

# A release with zest.releaser, from an up to date main: the version from
# version.txt, CHANGES.md, a tag, back to development, push.  CI builds the
# image from the tag.
release:
	@test "$$(git branch --show-current)" = "main" || { echo "Release from main, not $$(git branch --show-current)."; exit 1; }
	git fetch origin main
	@test "$$(git rev-parse HEAD)" = "$$(git rev-parse origin/main)" || { echo "main is not the same as origin/main: pull or push first."; exit 1; }
	uvx --from zest.releaser fullrelease
