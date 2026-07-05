.PHONY: build daemon daemon-run app run setup install uninstall clean check test help crowd-dev

# Install destination and build config (override on the command line, e.g.
# `make install BINDIR=/usr/local/bin` or `make build CONFIG=release`).
PREFIX    ?= $(HOME)/.local
BINDIR    ?= $(PREFIX)/bin
CONFIG    ?= debug
BUILD_OUT := .build/$(CONFIG)

# Where `daemon-run` binds. Override on the command line, e.g.
# `make daemon-run CROW_PORT=9000`.
CROW_HOST   ?= 127.0.0.1
CROW_PORT   ?= 8787
CROW_SOCKET ?= $(HOME)/.local/share/crow/crow.sock

# Platform switch. The native "Crow" desktop window (Tauri) builds on macOS
# only; on Linux the app IS the `crowd` daemon + its web UI (served on :8787),
# so `build`/`run` skip the desktop shell there rather than pulling in the whole
# GTK/WebKit dev stack a Tauri build needs.
UNAME_S := $(shell uname -s)

# On Linux, Swift is commonly installed via swiftly, whose bin dir is added to
# PATH from ~/.profile — i.e. login shells only. A non-login `make` invocation
# (a plain terminal sources ~/.bashrc, not ~/.profile) then can't find `swift`.
# If it isn't already on PATH but the swiftly proxy is present, prepend it so
# `make build`/`daemon`/`test`/`crowd-dev` work from any shell. No-op on macOS,
# where `swift` comes from the Xcode toolchain already on PATH.
ifeq (,$(shell command -v swift 2>/dev/null))
ifneq (,$(wildcard $(HOME)/.local/share/swiftly/bin/swift))
export PATH := $(HOME)/.local/share/swiftly/bin:$(PATH)
endif
endif

# Crow desktop app (the native "Crow" window over crowd, built with Tauri).
DESKTOP_DIR := crow-desktop/src-tauri
DESKTOP_BIN := $(DESKTOP_DIR)/target/$(CONFIG)/Crow
# cargo/rustc must be the arm64 toolchain. A plain dev shell can run under
# Rosetta (x86_64) and shadow it with an old x86_64 rust, so pin the Homebrew +
# rustup arm64 paths ahead of $PATH (matches crow-desktop/README.md).
CARGO_ENV := PATH="/opt/homebrew/bin:$(HOME)/.cargo/bin:$$PATH"

# Default target. macOS: build everything — the Swift binaries (crow CLI + crowd
# daemon) plus the native Crow desktop app. Linux: just the Swift binaries — the
# desktop shell is macOS-only, so serve the UI with `make run` + a browser.
ifeq ($(UNAME_S),Darwin)
build: daemon app
else
build: daemon
endif

# Swift only: crow (CLI) + crowd (daemon) → $(BUILD_OUT)/. The fast inner loop
# when you're not touching the desktop shell.
daemon: setup
	bash scripts/generate-build-info.sh
	swift build $(if $(filter release,$(CONFIG)),-c release,)

# Run the compiled crowd daemon in the foreground, serving the web UI from the
# assets baked into the binary — NO `--web-dir` live-reload and NO `--watch`
# rebuild loop (that's what `crowd-dev` is for). Builds first only if Swift
# sources changed, then runs a stable daemon. Ctrl-C to stop. Override the bind
# with CROW_HOST/CROW_PORT/CROW_SOCKET, e.g. `make daemon-run CROW_PORT=9000`.
daemon-run: daemon
	$(BUILD_OUT)/crowd --host $(CROW_HOST) --http-port $(CROW_PORT) --socket $(CROW_SOCKET) --dev-root $(CURDIR)

# Tauri only: the Crow desktop window → $(DESKTOP_BIN). Independent of the Swift
# build (crowd is resolved/launched at runtime, not linked in).
app:
	@$(CARGO_ENV) cargo --version >/dev/null 2>&1 || { \
		echo "ERROR: cargo (Rust, arm64) not found. Install from https://rustup.rs — the Crow desktop app needs it."; \
		echo "       To build only the daemon, run: make daemon"; exit 1; }
	$(CARGO_ENV) cargo build --manifest-path $(DESKTOP_DIR)/Cargo.toml $(if $(filter release,$(CONFIG)),--release,)

# macOS: build everything, then open the Crow desktop window without installing
# a bundle. The window reuses a crowd already listening on :8787 (e.g. one from
# `make crowd-dev`) and leaves it running on quit; if none is up it spawns its
# own $(BUILD_OUT)/crowd and stops that on quit. This is the modern equivalent
# of the old `make && ./.build/debug/CrowApp`.
# Linux: no native window — build the daemon, then serve the web UI live from
# source (http://127.0.0.1:8787; Ctrl-C to stop). Same as `make crowd-dev`.
ifeq ($(UNAME_S),Darwin)
run: build
	$(DESKTOP_BIN)
else
run: daemon
	bash scripts/crowd-dev.sh
endif

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build      Default. macOS: crow CLI + crowd daemon + Crow desktop app. Linux: Swift binaries only"
	@echo "  daemon     Build just the Swift binaries (crow CLI + crowd daemon)"
	@echo "  daemon-run Run the built crowd daemon (bundled web assets; no live-reload/watch) — Ctrl-C to stop"
	@echo "  app        Build just the Crow desktop app (Tauri, macOS only) → $(DESKTOP_BIN)"
	@echo "  run        macOS: open the desktop window over crowd. Linux: serve the web UI on :8787 (crowd-dev)"
	@echo "  crowd-dev  Run crowd with the web UI served live from source (add --watch to rebuild on change)"
	@echo "  setup      Check build prerequisites"
	@echo "  check      Verify all build and runtime prerequisites"
	@echo "  test       Run all package tests"
	@echo "  install    Symlink crow + crowd into ~/.local/bin (override BINDIR=, CONFIG=release)"
	@echo "  uninstall  Remove installed crow + crowd symlinks"
	@echo "  clean      Remove .build/ and the desktop app's target/"
	@echo ""
	@echo "Prerequisites: Swift (macOS: Xcode CLT; Linux: swiftly). Desktop app (macOS): Rust arm64 toolchain"

setup:
	@if [ "$$(uname)" = "Darwin" ]; then \
		xcode-select -p >/dev/null 2>&1 || { echo "ERROR: Xcode Command Line Tools not installed. Run: xcode-select --install"; exit 1; }; \
	else \
		command -v swift >/dev/null 2>&1 || { echo "ERROR: Swift toolchain not found. Install from https://www.swift.org/install/"; exit 1; }; \
	fi
	@echo "Prerequisites OK"

# Run crowd for local dev: build once and serve the web UI live from source
# (edit + refresh — no restart). Add --watch to also rebuild + restart on Swift
# changes: `bash scripts/crowd-dev.sh --watch`. See scripts/crowd-dev.sh.
crowd-dev:
	bash scripts/crowd-dev.sh

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

clean:
	rm -rf .build
	rm -rf $(DESKTOP_DIR)/target

check: setup
	@command -v gh >/dev/null 2>&1 || echo "WARNING: gh (GitHub CLI) not found. Install with: brew install gh"
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude (Claude Code) not found. Install from: https://claude.ai/download"
	@command -v tmux >/dev/null 2>&1 || echo "WARNING: tmux not found. Install with: brew install tmux"
	@$(CARGO_ENV) cargo --version >/dev/null 2>&1 || echo "WARNING: cargo (Rust) not found — needed for the Crow desktop app (make app). Install from: https://rustup.rs"
	@echo "All checks complete."
