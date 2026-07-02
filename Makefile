.PHONY: build setup app release sign install install-app uninstall clean clean-all check test help

# Install destination and build config (override on the command line, e.g.
# `make install BINDIR=/usr/local/bin` or `make install CONFIG=release`).
PREFIX    ?= $(HOME)/.local
BINDIR    ?= $(PREFIX)/bin
CONFIG    ?= debug
BUILD_OUT := .build/$(CONFIG)

# Default target
build: setup app

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build      Full build: check prerequisites + swift build (default)"
	@echo "  setup      Check build prerequisites"
	@echo "  check      Verify all build and runtime prerequisites"
	@echo "  test       Run all package tests"
	@echo "  app        Swift build only (debug)"
	@echo "  release    Release build + .app bundle"
	@echo "  sign       Sign, create DMG, and notarize (requires DEVELOPER_ID_APPLICATION)"
	@echo "  install    Symlink crow + CrowApp into ~/.local/bin (override BINDIR=, CONFIG=release)"
	@echo "  install-app Copy Crow.app into /Applications (run 'make release' first)"
	@echo "  uninstall  Remove installed crow + CrowApp symlinks"
	@echo "  clean      Remove .build/"
	@echo "  clean-all  Remove .build/ and Crow.app"
	@echo ""
	@echo "Prerequisites: Xcode with Command Line Tools"

setup:
	@xcode-select -p >/dev/null 2>&1 || { echo "ERROR: Xcode Command Line Tools not installed. Run: xcode-select --install"; exit 1; }
	@echo "Prerequisites OK"

app:
	bash scripts/generate-build-info.sh
	swift build $(if $(filter release,$(CONFIG)),-c release,)

release:
	bash scripts/generate-build-info.sh
	bash scripts/bundle.sh

sign: release
	bash scripts/sign-and-notarize.sh

install:
	@test -x "$(CURDIR)/$(BUILD_OUT)/crow" && test -x "$(CURDIR)/$(BUILD_OUT)/CrowApp" || \
		{ echo "ERROR: binaries not found in $(BUILD_OUT)/. Run 'make build' (debug) or 'make release' (then 'make install CONFIG=release') first."; exit 1; }
	@mkdir -p "$(BINDIR)"
	@ln -sf "$(CURDIR)/$(BUILD_OUT)/crow" "$(BINDIR)/crow"
	@ln -sf "$(CURDIR)/$(BUILD_OUT)/CrowApp" "$(BINDIR)/CrowApp"
	@echo "Symlinked crow + CrowApp into $(BINDIR) (from $(BUILD_OUT)/)"
	@case ":$$PATH:" in *":$(BINDIR):"*) ;; \
		*) echo "NOTE: $(BINDIR) is not on PATH. Add to your shell rc: export PATH=\"$(BINDIR):\$$PATH\"";; esac

install-app:
	@test -d "$(CURDIR)/Crow.app" || { echo "ERROR: Crow.app not found. Run 'make release' first."; exit 1; }
	rm -rf "/Applications/Crow.app"
	cp -R "$(CURDIR)/Crow.app" "/Applications/Crow.app"
	@echo "Installed Crow.app to /Applications"

uninstall:
	@rm -f "$(BINDIR)/crow" "$(BINDIR)/CrowApp"
	@echo "Removed crow + CrowApp symlinks from $(BINDIR)"

test:
	@for pkg in Packages/*/; do \
		if [ -d "$$pkg/Tests" ]; then \
			echo "==> Testing $$(basename $$pkg)..."; \
			swift test --package-path "$$pkg"; \
		fi; \
	done
	@echo "==> Testing root package (CrowTests)..."
	@swift test

clean:
	rm -rf .build

clean-all: clean
	rm -rf Crow.app

check: setup
	@command -v gh >/dev/null 2>&1 || echo "WARNING: gh (GitHub CLI) not found. Install with: brew install gh"
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude (Claude Code) not found. Install from: https://claude.ai/download"
	@command -v tmux >/dev/null 2>&1 || echo "WARNING: tmux not found. Install with: brew install tmux"
	@echo "All checks complete."
