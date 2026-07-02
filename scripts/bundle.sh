#!/usr/bin/env bash
# Bundle Crow into a .app
#
# Usage: bash scripts/bundle.sh  (or: make release)
# Output: Crow.app/ in the repo root
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
BUILD_DIR="$ROOT_DIR/.build/release"
APPLE_RELEASE_DIR="$ROOT_DIR/.build/apple/Products/Release"
APP_DIR="$ROOT_DIR/Crow.app"

# Read version: CROW_VERSION env var takes precedence, then VERSION file
if [ -n "${CROW_VERSION:-}" ]; then
    VERSION="$CROW_VERSION"
elif [ -f "$ROOT_DIR/VERSION" ]; then
    VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
else
    echo "ERROR: No VERSION file found and CROW_VERSION not set" >&2
    exit 1
fi

# Build number from git commit count
if git -C "$ROOT_DIR" rev-parse HEAD >/dev/null 2>&1; then
    BUILD_NUMBER=$(git -C "$ROOT_DIR" rev-list --count HEAD)
else
    BUILD_NUMBER="1"
fi

echo "==> Generating build info..."
bash "$SCRIPT_DIR/generate-build-info.sh"

echo "==> Building release (universal: arm64 + x86_64)..."
swift build -c release --arch arm64 --arch x86_64

# Dual-arch builds land under .build/apple/Products/Release; single-arch under .build/release.
if [ -f "$APPLE_RELEASE_DIR/CrowApp" ]; then
    BUILD_DIR="$APPLE_RELEASE_DIR"
elif [ ! -f "$BUILD_DIR/CrowApp" ]; then
    echo "ERROR: Release binary not found at $BUILD_DIR/CrowApp or $APPLE_RELEASE_DIR/CrowApp"
    exit 1
fi

if [ ! -f "$BUILD_DIR/crow" ]; then
    echo "ERROR: CLI binary not found at $BUILD_DIR/crow"
    exit 1
fi

echo "==> Creating app bundle (v$VERSION)..."
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

# Copy binaries
cp "$BUILD_DIR/CrowApp" "$APP_DIR/Contents/MacOS/"
cp "$BUILD_DIR/crow" "$APP_DIR/Contents/MacOS/"

# Copy template resources for Scaffolder (CLAUDE.md, SKILL.md, setup.sh, settings)
for f in "$ROOT_DIR"/Resources/*.template; do
    [ -f "$f" ] && cp "$f" "$APP_DIR/Contents/Resources/"
done
echo "    Bundled template resources"

# TODO: Add CFBundleIconFile and bundle AppIcon.icns once icon asset pipeline is created

# Create Info.plist
cat > "$APP_DIR/Contents/Info.plist" << PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CrowApp</string>
    <key>CFBundleIdentifier</key>
    <string>com.radiusmethod.crow</string>
    <key>CFBundleName</key>
    <string>Crow</string>
    <key>CFBundleDisplayName</key>
    <string>Crow</string>
    <key>CFBundleVersion</key>
    <string>$BUILD_NUMBER</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.developer-tools</string>
</dict>
</plist>
PLIST

echo "==> App bundle created at: $APP_DIR (version: $VERSION, build: $BUILD_NUMBER)"
