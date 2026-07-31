.PHONY: build daemon app run setup install uninstall clean check test coverage parity help daemon-run docs

# Install destination and build config (override on the command line, e.g.
# `make install BINDIR=/usr/local/bin` or `make build CONFIG=release`).
PREFIX    ?= $(HOME)/.local
BINDIR    ?= $(PREFIX)/bin
CONFIG    ?= debug
BUILD_OUT := .build/$(CONFIG)

# Crow desktop app (the native "Crow" window over crowd, built with Tauri).
DESKTOP_DIR := crow-desktop/src-tauri
DESKTOP_BIN := $(DESKTOP_DIR)/target/$(CONFIG)/Crow
# cargo/rustc must be the arm64 toolchain. A plain dev shell can run under
# Rosetta (x86_64) and shadow it with an old x86_64 rust, so pin the Homebrew +
# rustup arm64 paths ahead of $PATH (matches crow-desktop/README.md).
CARGO_ENV := PATH="/opt/homebrew/bin:$(HOME)/.cargo/bin:$$PATH"

# Default target: build everything — the Swift binaries (crow CLI + crowd
# daemon) and the Crow desktop app.
build: daemon app

# Swift only: crow (CLI) + crowd (daemon) → $(BUILD_OUT)/. The fast inner loop
# when you're not touching the desktop shell.
daemon: setup
	bash scripts/generate-build-info.sh
	swift build $(if $(filter release,$(CONFIG)),-c release,)

# Tauri only: the Crow desktop window → $(DESKTOP_BIN). Independent of the Swift
# build (crowd is resolved/launched at runtime, not linked in).
app:
	@$(CARGO_ENV) cargo --version >/dev/null 2>&1 || { \
		echo "ERROR: cargo (Rust, arm64) not found. Install from https://rustup.rs — the Crow desktop app needs it."; \
		echo "       To build only the daemon, run: make daemon"; exit 1; }
	$(CARGO_ENV) cargo build --manifest-path $(DESKTOP_DIR)/Cargo.toml $(if $(filter release,$(CONFIG)),--release,)

# Build everything, then open the Crow desktop window without installing a
# bundle. The window reuses a crowd already listening on :8787 (e.g. one from
# `make daemon-run`) and leaves it running on quit; if none is up it spawns its
# own $(BUILD_OUT)/crowd and stops that on quit. This is the modern equivalent
# of the old `make && ./.build/debug/CrowApp`.
run: build
	$(DESKTOP_BIN)

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build      Build everything: crow CLI + crowd daemon + Crow desktop app — default"
	@echo "  daemon     Build just the Swift binaries (crow CLI + crowd daemon)"
	@echo "  app        Build just the Crow desktop app (Tauri) → $(DESKTOP_BIN)"
	@echo "  run        Build, then open the Crow desktop window over a running (or fresh) crowd"
	@echo "  daemon-run Run crowd serving the frozen bundle-baked web UI (add --watch to rebuild on Swift/web change)"
	@echo "  setup      Check build prerequisites"
	@echo "  check      Verify all build and runtime prerequisites"
	@echo "  test       Run all package tests, then the parity gates"
	@echo "  coverage   Run all package tests with coverage → coverage/coverage-summary.{json,md}"
	@echo "  parity     Run just the source-level drift gates (catalogs + CLI/RPC parity)"
	@echo "  docs       Regenerate docs/cli.md from the CLI's ArgumentParser metadata"
	@echo "  install    Symlink crow + crowd into ~/.local/bin (override BINDIR=, CONFIG=release)"
	@echo "  uninstall  Remove installed crow + crowd symlinks"
	@echo "  clean      Remove .build/ and the desktop app's target/"
	@echo ""
	@echo "Prerequisites: Xcode Command Line Tools (Swift); Rust arm64 toolchain (desktop app)"

setup:
	@if [ "$$(uname)" = "Darwin" ]; then \
		xcode-select -p >/dev/null 2>&1 || { echo "ERROR: Xcode Command Line Tools not installed. Run: xcode-select --install"; exit 1; }; \
	else \
		command -v swift >/dev/null 2>&1 || { echo "ERROR: Swift toolchain not found. Install from https://www.swift.org/install/"; exit 1; }; \
	fi
	@echo "Prerequisites OK"

# Run crowd for local dev: build once and serve the frozen web UI baked into
# crowd's resource bundle (edit + rebuild to pick up UI changes — same as `make
# run`). Add --watch to also rebuild + restart on Swift or web-asset changes:
# `bash scripts/daemon-run.sh --watch`. See scripts/daemon-run.sh.
daemon-run:
	bash scripts/daemon-run.sh

install:
	@test -x "$(CURDIR)/$(BUILD_OUT)/crow" && test -x "$(CURDIR)/$(BUILD_OUT)/crowd" || \
		{ echo "ERROR: binaries not found in $(BUILD_OUT)/. Run 'make daemon' (debug) or 'make daemon CONFIG=release' first."; exit 1; }
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
	@$(MAKE) --no-print-directory parity

# Local twin of the CI coverage artifact (CROW-928). Runs the same suites as
# `test` with instrumentation, then merges the per-package llvm-cov exports
# through the same script CI uses, so a local run and a downloaded artifact are
# byte-comparable over the same package set. This is a full sweep — budget ~30
# minutes. All 17 packages build here; the Linux PR lane sees only 12, so its
# artifact reports a different (smaller) tree. See docs/adr/0007-linux-ci-swift.md.
#
# `|| exit 1` matters: a shell for-loop does not abort on a failing iteration and
# a recipe's status is the last iteration's, so without it a suite failing at
# package 4 of 17 would still print an authoritative-looking table — built partly
# from the *previous* run's export for the package that just failed — and exit 0.
coverage:
	@bash scripts/generate-build-info.sh
	@for pkg in Packages/*/; do \
		if [ -d "$$pkg/Tests" ]; then \
			echo "==> Testing $$(basename $$pkg) with coverage..."; \
			swift test --enable-code-coverage --package-path "$$pkg" || exit 1; \
		fi; \
	done
	@bash scripts/coverage-summary.sh

# Source-level drift gates. Cheap, no build required, and both also run in CI —
# see the `parity` job in .github/workflows/ci.yml.
parity:
	@echo "==> Checking notification-event catalogs (CROW-768)..."
	@./scripts/check-notification-events.sh
	@echo "==> Checking CLI/RPC control-plane parity (CROW-807)..."
	@./scripts/check-cli-parity.sh
	@echo "==> Checking for banned NSLog (CROW-874)..."
	@./scripts/check-no-nslog.sh

# Regenerate the CLI reference from the commands themselves (CROW-808). Run
# after adding or changing a subcommand — a stale docs/cli.md fails CrowCLI's
# test suite, which is what keeps the docs honest.
docs:
	@bash scripts/generate-build-info.sh
	@swift build $(if $(filter release,$(CONFIG)),-c release,) --product crow
	@$(BUILD_OUT)/crow generate-docs

clean:
	rm -rf .build
	rm -rf $(DESKTOP_DIR)/target

check: setup
	@command -v gh >/dev/null 2>&1 || echo "WARNING: gh (GitHub CLI) not found. Install with: brew install gh"
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude (Claude Code) not found. Install from: https://claude.ai/download"
	@command -v tmux >/dev/null 2>&1 || echo "WARNING: tmux not found. Install with: brew install tmux"
	@$(CARGO_ENV) cargo --version >/dev/null 2>&1 || echo "WARNING: cargo (Rust) not found — needed for the Crow desktop app (make app). Install from: https://rustup.rs"
	@echo "All checks complete."
