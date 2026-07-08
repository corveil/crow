.PHONY: build setup install uninstall clean check test help crowd-dev

# Install destination and build config (override on the command line, e.g.
# `make install BINDIR=/usr/local/bin` or `make install CONFIG=release`).
PREFIX    ?= $(HOME)/.local
BINDIR    ?= $(PREFIX)/bin
CONFIG    ?= debug
BUILD_OUT := .build/$(CONFIG)

# Default target: build both binaries (crow CLI + crowd daemon).
build: setup
	bash scripts/generate-build-info.sh
	swift build $(if $(filter release,$(CONFIG)),-c release,)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build      Build crow (CLI) + crowd (daemon) — default"
	@echo "  setup      Check build prerequisites"
	@echo "  check      Verify all build and runtime prerequisites"
	@echo "  test       Run all package tests"
	@echo "  install    Symlink crow + crowd into ~/.local/bin (override BINDIR=, CONFIG=release)"
	@echo "  uninstall  Remove installed crow + crowd symlinks"
	@echo "  clean      Remove .build/"
	@echo "  crowd-dev  Hot-reload dev loop for the crowd daemon"
	@echo ""
	@echo "Prerequisites: Xcode with Command Line Tools"

setup:
	@xcode-select -p >/dev/null 2>&1 || { echo "ERROR: Xcode Command Line Tools not installed. Run: xcode-select --install"; exit 1; }
	@echo "Prerequisites OK"

# Dev hot-reload for the crowd daemon: web UI served live from source (edit +
# refresh), Swift changes trigger a rebuild + restart. See scripts/crowd-dev.sh.
crowd-dev:
	bash scripts/crowd-dev.sh

install:
	@test -x "$(CURDIR)/$(BUILD_OUT)/crow" && test -x "$(CURDIR)/$(BUILD_OUT)/crowd" || \
		{ echo "ERROR: binaries not found in $(BUILD_OUT)/. Run 'make build' (debug) or 'make build CONFIG=release' first."; exit 1; }
	@mkdir -p "$(BINDIR)"
	@ln -sf "$(CURDIR)/$(BUILD_OUT)/crow" "$(BINDIR)/crow"
	@ln -sf "$(CURDIR)/$(BUILD_OUT)/crowd" "$(BINDIR)/crowd"
	@echo "Symlinked crow + crowd into $(BINDIR) (from $(BUILD_OUT)/)"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
		*) echo "NOTE: $(BINDIR) is not on PATH. Add to your shell rc: export PATH=\"$(BINDIR):\$$PATH\"";; esac

uninstall:
	@rm -f "$(BINDIR)/crow" "$(BINDIR)/crowd"
	@echo "Removed crow + crowd symlinks from $(BINDIR)"

test:
	@for pkg in Packages/*/; do \
		if [ -d "$$pkg/Tests" ]; then \
			echo "==> Testing $$(basename $$pkg)..."; \
			swift test --package-path "$$pkg"; \
		fi; \
	done

clean:
	rm -rf .build

check: setup
	@command -v gh >/dev/null 2>&1 || echo "WARNING: gh (GitHub CLI) not found. Install with: brew install gh"
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude (Claude Code) not found. Install from: https://claude.ai/download"
	@command -v tmux >/dev/null 2>&1 || echo "WARNING: tmux not found. Install with: brew install tmux"
	@echo "All checks complete."
