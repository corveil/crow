.PHONY: build setup ghostty app release sign clean clean-all check test help

FRAMEWORKS_DIR := Frameworks
XCFW := $(FRAMEWORKS_DIR)/GhosttyKit.xcframework
SUBMODULE_MARKER := vendor/ghostty/build.zig

# Default target
build: setup ghostty app

help:
	@echo "Usage: make [target]"
	@echo ""
	@echo "Targets:"
	@echo "  build      Full build: submodules + ghostty + swift build (default)"
	@echo "  setup      Init submodules and check build prerequisites"
	@echo "  check      Verify all build and runtime prerequisites"
	@echo "  test       Run all package tests"
	@echo "  ghostty    Build GhosttyKit framework"
	@echo "  app        Swift build only (debug)"
	@echo "  release    Release build + .app bundle"
	@echo "  sign       Sign, create DMG, and notarize (requires DEVELOPER_ID_APPLICATION)"
	@echo "  clean      Remove .build/ (keeps ghostty framework)"
	@echo "  clean-all  Remove .build/ and Frameworks/ (full rebuild)"
	@echo ""
	@echo "Prerequisites: Zig 0.15.2, Xcode with Metal Toolchain"

# --- Setup ---

$(SUBMODULE_MARKER):
	git submodule update --init --recursive

setup: $(SUBMODULE_MARKER)
	@command -v zig >/dev/null 2>&1 || { echo "ERROR: zig not found. Install with: brew install zig@0.15"; exit 1; }
	@ZIG_VER=$$(zig version); \
	if [ "$$ZIG_VER" != "0.15.2" ]; then \
		echo "ERROR: Zig 0.15.2 required, found: $$ZIG_VER. Install with: brew install zig@0.15"; \
		exit 1; \
	fi
	@xcrun -sdk macosx metal --version >/dev/null 2>&1 || { echo "ERROR: Metal Toolchain not installed. Run: xcodebuild -downloadComponent MetalToolchain"; exit 1; }
	@echo "Prerequisites OK"

# --- Ghostty ---

$(XCFW): $(SUBMODULE_MARKER)
	bash scripts/build-ghostty.sh

ghostty: setup $(XCFW)

# --- App ---

app: $(XCFW)
	bash scripts/generate-build-info.sh
	swift build

release: $(XCFW)
	bash scripts/generate-build-info.sh
	bash scripts/bundle.sh

sign: release
	bash scripts/sign-and-notarize.sh

# --- Test ---

test: $(XCFW)
	@for pkg in Packages/*/; do \
		if [ -d "$$pkg/Tests" ]; then \
			echo "==> Testing $$(basename $$pkg)..."; \
			swift test --package-path "$$pkg"; \
		fi; \
	done
	@echo "==> Testing root package (CrowTests)..."
	@swift test

# --- Clean ---

clean:
	rm -rf .build

clean-all: clean
	rm -rf $(FRAMEWORKS_DIR)

# --- Check ---

check: setup
	@command -v gh >/dev/null 2>&1 || echo "WARNING: gh (GitHub CLI) not found. Install with: brew install gh"
	@command -v claude >/dev/null 2>&1 || echo "WARNING: claude (Claude Code) not found. Install from: https://claude.ai/download"
	@echo "All checks complete."
