# Build statusbar for every supported release target.

ZIG      ?= zig
OPTIMIZE ?= ReleaseSafe
DIST     ?= dist
VERSION  := $(shell sed -n 's/.*\.version = "\([^"]*\)".*/\1/p' build.zig.zon)

TARGETS := \
	aarch64-macos \
	aarch64-linux-musl \
	x86_64-linux-musl

.DEFAULT_GOAL := build
.PHONY: build test test-integration fmt-check check all package clean $(TARGETS)

build:
	$(ZIG) build

test:
	$(ZIG) build test

test-integration: build
	python3 -u tests/multirow_pty.py ./zig-out/bin/statusbar
	python3 -u tests/theme_picker_pty.py ./zig-out/bin/statusbar-theme ./zig-out/bin/statusbar

fmt-check:
	$(ZIG) fmt --check src build.zig build.zig.zon

check: fmt-check test

all: $(TARGETS)

$(TARGETS):
	@echo "==> $@"
	$(ZIG) build -Dtarget=$@ -Doptimize=$(OPTIMIZE) -Dthemes-dir=themes -Dguide-dir=. --prefix $(DIST)/statusbar-$(VERSION)-$@

package: all
	@for target in $(TARGETS); do \
		root="statusbar-$(VERSION)-$$target"; \
		dir="$(DIST)/$$root"; \
		test -x "$$dir/bin/statusbar" || exit 1; \
		test -x "$$dir/bin/statusbar-theme" || exit 1; \
		cmp AGENT_SETUP.md "$$dir/AGENT_SETUP.md" || exit 1; \
		for theme in samples/themes/*.config; do \
			cmp "$$theme" "$$dir/themes/$${theme##*/}" || exit 1; \
		done; \
		COPYFILE_DISABLE=1 tar -czf "$(DIST)/$$root.tar.gz" -C "$(DIST)" "$$root" || exit 1; \
		echo "$(DIST)/$$root.tar.gz"; \
	done

clean:
	rm -rf zig-out .zig-cache $(DIST)
