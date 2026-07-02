#!/usr/bin/env bash
# Build GhosttyKit.xcframework from the Ghostty submodule.
#
# Usage: bash scripts/build-ghostty.sh  (or: make ghostty)
# Prerequisites: zig 0.15.2, Xcode with Metal Toolchain, ghostty submodule
# Output: Frameworks/GhosttyKit.xcframework/ (universal macOS: arm64 + x86_64)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(dirname "$SCRIPT_DIR")"
GHOSTTY_DIR="$ROOT_DIR/vendor/ghostty"
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
INCLUDE_DIR="$FRAMEWORKS_DIR/GhosttyKit-include"
# NOTE: This script extracts individual object files from Zig's internal cache
# (.zig-cache/o/) to assemble a fat library. This approach is fragile and may
# break when Zig updates its cache layout. If builds fail after a Zig upgrade,
# this is the first place to investigate.
CACHE="$GHOSTTY_DIR/.zig-cache/o"

# Clean up temp files on exit or interruption
cleanup() {
    rm -rf "${ROOT_DIR}/.build/_ghostty_extract_$$" 2>/dev/null || true
    rm -f "${ROOT_DIR}/.build/_ghostty_"*"_$$.a" 2>/dev/null || true
    rm -f "${ROOT_DIR}/.build/_ghostty_extract_$$.wuffs_full.o" 2>/dev/null || true
    rm -f "${ROOT_DIR}/.build/_ghostty_extract_$$.vt_simd.o" 2>/dev/null || true
}
trap cleanup EXIT

object_matches_arch() {
    local obj="$1"
    local arch="$2"
    chmod 644 "$obj" 2>/dev/null || true
    case "$arch" in
        arm64)
            file "$obj" | grep -qE ' arm64| aarch64'
            ;;
        x86_64)
            file "$obj" | grep -q ' x86_64'
            ;;
        *)
            return 1
            ;;
    esac
}

# nm | grep -q triggers SIGPIPE under pipefail when grep -q exits early.
nm_has_symbol() {
    local obj="$1"
    local pattern="$2"
    local out
    out=$(nm "$obj" 2>/dev/null || true)
    [[ "$out" == *"$pattern"* ]]
}

cache_lib_is_macos() {
    local lib="$1"
    local obj probe
    obj=$(ar t "$lib" 2>/dev/null | grep -v '^__' | head -1)
    [ -n "$obj" ] || return 1
    probe="${ROOT_DIR}/.build/_plat_$$.o"
    mkdir -p "${ROOT_DIR}/.build"
    ar p "$lib" "$obj" > "$probe" 2>/dev/null || return 1
    chmod 644 "$probe"
    local plat
    plat=$(otool -l "$probe" 2>/dev/null | awk '/platform/{print $2; exit}')
    rm -f "$probe"
    [ "$plat" = "1" ]
}

find_cache_lib() {
    local libname="$1"
    local arch="$2"
    local zcu_dir="${3:-}"
    if [ -n "$zcu_dir" ] && [ -f "$zcu_dir/$libname" ] && cache_lib_is_macos "$zcu_dir/$libname"; then
        echo "$zcu_dir/$libname"
        return 0
    fi
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if lipo -info "$candidate" 2>/dev/null | grep -qE "(architecture: ${arch}|Architectures: .*${arch})"; then
            cache_lib_is_macos "$candidate" || continue
            echo "$candidate"
            return 0
        fi
    done < <(find "$CACHE" -name "$libname" 2>/dev/null || true)
    return 1
}

find_macos_xcfw_slice() {
    local xcframework_dir="$1"
    local slice
    for slice in "$xcframework_dir"/macos-*; do
        [ -d "$slice" ] || continue
        case "$(basename "$slice")" in
            *simulator*) continue ;;
        esac
        echo "$slice"
        return 0
    done
    return 1
}

object_is_macos() {
    local obj="$1"
    chmod 644 "$obj" 2>/dev/null || true
    local plat
    plat=$(otool -l "$obj" 2>/dev/null | awk '/platform/{print $2; exit}')
    [ "$plat" = "1" ]
}

# Extend a thin (single-arch) libghostty-fat.a with Zig cache objects for $arch.
assemble_arch_fat_lib() {
    local base_lib="$1"
    local arch="$2"
    local output="$3"

    local thin_lib="${ROOT_DIR}/.build/_ghostty_${arch}_thin_$$.a"
    mkdir -p "${ROOT_DIR}/.build"
    if lipo -info "$base_lib" 2>/dev/null | grep -q "Non-fat file:"; then
        cp "$base_lib" "$output"
    else
        lipo -thin "$arch" "$base_lib" -output "$thin_lib"
        cp "$thin_lib" "$output"
        rm -f "$thin_lib"
    fi

    # Find and add the Zig-compiled ghostty API object (libghostty_zcu.o)
    local zcu=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if object_matches_arch "$candidate" "$arch" \
            && object_is_macos "$candidate" \
            && nm_has_symbol "$candidate" "T _ghostty_app_new"; then
            zcu="$candidate"
            break
        fi
    done < <(find "$CACHE" -name "libghostty_zcu.o" 2>/dev/null || true)

    if [ -z "$zcu" ]; then
        echo "WARNING: libghostty_zcu.o with API symbols not found for $arch — fat library may be incomplete"
    else
        ar r "$output" "$zcu" 2>/dev/null
        echo "    Added libghostty_zcu.o ($arch)"
    fi

    local api_dir=""
    if [ -n "$zcu" ]; then
        api_dir="$(dirname "$zcu")"
    fi
    if [ -n "$api_dir" ]; then
        for obj in vt.o stb.o wuffs-v0.4.o base64.o codepoint_width.o index_of.o; do
            if [ -f "$api_dir/$obj" ] && object_matches_arch "$api_dir/$obj" "$arch" \
                && object_is_macos "$api_dir/$obj"; then
                ar r "$output" "$api_dir/$obj" 2>/dev/null
            fi
        done
    fi

    local tmpextract="${ROOT_DIR}/.build/_ghostty_extract_$$"
    for libname in libglslang.a libspirv_cross.a libdcimgui.a libfreetype.a \
                   liboniguruma.a libsentry.a libsimdutf.a libpng.a \
                   libhighway.a libintl.a libmacos.a libutfcpp.a libbreakpad.a libz.a; do
        local found
        found=$(find_cache_lib "$libname" "$arch" "$api_dir" || true)
        if [ -n "$found" ]; then
            mkdir -p "$tmpextract"
            (
                cd "$tmpextract"
                ar x "$found"
                # shellcheck disable=SC2035
                chmod 644 *.o 2>/dev/null || true
                for obj in *.o; do
                    [ -f "$obj" ] || continue
                    ar r "$output" "$obj"
                done
            )
            rm -rf "$tmpextract"
        fi
    done

    local imgui_ext=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if object_matches_arch "$candidate" "$arch" \
            && object_is_macos "$candidate" \
            && nm_has_symbol "$candidate" "T _ImFontConfig_ImFontConfig"; then
            imgui_ext="$candidate"
            break
        fi
    done < <(find "$CACHE" -name "ext.o" 2>/dev/null || true)
    if [ -n "$imgui_ext" ]; then
        ar r "$output" "$imgui_ext" 2>/dev/null
    fi

    local wuffs_full=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if object_matches_arch "$candidate" "$arch" \
            && object_is_macos "$candidate" \
            && nm_has_symbol "$candidate" "T _wuffs_jpeg__decoder__decode_frame"; then
            wuffs_full="$candidate"
            break
        fi
    done < <(find "$CACHE" -name "wuffs-v0.4.o" 2>/dev/null || true)
    if [ -n "$wuffs_full" ] && [ -f "$wuffs_full" ]; then
        cp "$wuffs_full" "${tmpextract}.wuffs_full.o"
        ar r "$output" "${tmpextract}.wuffs_full.o" 2>/dev/null
        rm -f "${tmpextract}.wuffs_full.o"
    fi

    local simd_vt=""
    while IFS= read -r candidate; do
        [ -n "$candidate" ] || continue
        if object_matches_arch "$candidate" "$arch" \
            && object_is_macos "$candidate" \
            && nm_has_symbol "$candidate" "T _ghostty_simd_decode_utf8"; then
            simd_vt="$candidate"
            break
        fi
    done < <(find "$CACHE" -name "vt.o" 2>/dev/null || true)
    if [ -n "$simd_vt" ] && [ -f "$simd_vt" ]; then
        cp "$simd_vt" "${tmpextract}.vt_simd.o"
        ar r "$output" "${tmpextract}.vt_simd.o" 2>/dev/null
        rm -f "${tmpextract}.vt_simd.o"
    fi

    ranlib "$output" 2>/dev/null || true
    echo "    $arch fat library: $(stat -f%z "$output") bytes"
}

# Ensure submodule is initialized
if [ ! -f "$GHOSTTY_DIR/build.zig" ]; then
    echo "==> Initializing Ghostty submodule..."
    git -C "$ROOT_DIR" submodule update --init vendor/ghostty
fi

# Check zig version
REQUIRED_ZIG="0.15.2"
CURRENT_ZIG=$(zig version 2>/dev/null || echo "not found")
if [ "$CURRENT_ZIG" != "$REQUIRED_ZIG" ]; then
    echo "ERROR: Zig $REQUIRED_ZIG required, found: $CURRENT_ZIG"
    echo "Install with: brew install zig@0.15"
    exit 1
fi

# Check Metal Toolchain
if ! xcrun -sdk macosx metal --version &>/dev/null; then
    echo "ERROR: Metal Toolchain not installed."
    echo "Run: xcodebuild -downloadComponent MetalToolchain"
    exit 1
fi

echo "==> Building GhosttyKit (universal: arm64 + x86_64)..."
cd "$GHOSTTY_DIR"

# Build xcframework. The zig build may exit non-zero due to the app link step
# failing (expected — we only need the xcframework). We capture the exit code
# and verify the xcframework was actually produced.
set +e
zig build \
    -Demit-xcframework=true \
    -Dxcframework-target=universal \
    -Doptimize=ReleaseFast
ZIG_EXIT=$?
set -e

# Check that the xcframework was produced
XCFW_SRC="$GHOSTTY_DIR/macos/GhosttyKit.xcframework"
if [ ! -d "$XCFW_SRC" ]; then
    echo "ERROR: GhosttyKit.xcframework not found after zig build (exit code: $ZIG_EXIT)"
    exit 1
fi

MACOS_SLICE_SRC=$(find_macos_xcfw_slice "$XCFW_SRC") || {
    echo "ERROR: No macOS slice found in $XCFW_SRC"
    exit 1
}

BASE_LIB=""
OUTPUT_NAME=""
if [ -f "$MACOS_SLICE_SRC/libghostty-fat.a" ]; then
    BASE_LIB="$MACOS_SLICE_SRC/libghostty-fat.a"
    OUTPUT_NAME="libghostty-fat.a"
elif [ -f "$MACOS_SLICE_SRC/libghostty.a" ]; then
    BASE_LIB="$MACOS_SLICE_SRC/libghostty.a"
    OUTPUT_NAME="libghostty.a"
fi
if [ -z "$BASE_LIB" ]; then
    echo "ERROR: libghostty-fat.a / libghostty.a not found in $(basename "$MACOS_SLICE_SRC")"
    exit 1
fi

echo "==> Assembling complete universal fat library..."
mkdir -p "$FRAMEWORKS_DIR"
rm -rf "$FRAMEWORKS_DIR/GhosttyKit.xcframework"
cp -R "$XCFW_SRC" "$FRAMEWORKS_DIR/GhosttyKit.xcframework"

# Crow only needs the macOS slice. Drop iOS slices so SwiftPM cannot link
# simulator objects when building for macOS (CROW-548).
for ios_slice in "$FRAMEWORKS_DIR/GhosttyKit.xcframework"/ios-*; do
    [ -d "$ios_slice" ] || continue
    rm -rf "$ios_slice"
done

MACOS_SLICE=$(find_macos_xcfw_slice "$FRAMEWORKS_DIR/GhosttyKit.xcframework")
XCFW_DIR="$MACOS_SLICE"
OUTPUT="$XCFW_DIR/$OUTPUT_NAME"

# SPM 6.3+ requires module.modulemap at the library identifier level (not just in Headers/)
if [ -f "$XCFW_DIR/Headers/module.modulemap" ] && [ ! -f "$XCFW_DIR/module.modulemap" ]; then
    cp "$XCFW_DIR/Headers/module.modulemap" "$XCFW_DIR/module.modulemap"
fi

# SwiftPM needs header search paths for C interop; omit module.modulemap here
# because the GhosttyKit binaryTarget already provides the Clang module.
rm -rf "$INCLUDE_DIR"
if [ -d "$XCFW_DIR/Headers" ]; then
    mkdir -p "$INCLUDE_DIR"
    rsync -a --exclude='module.modulemap' "$XCFW_DIR/Headers/" "$INCLUDE_DIR/"
elif [ -d "$GHOSTTY_DIR/include" ]; then
    mkdir -p "$INCLUDE_DIR"
    rsync -a --exclude='module.modulemap' "$GHOSTTY_DIR/include/" "$INCLUDE_DIR/"
fi

# SwiftPM include paths and docs reference macos-arm64; symlink when the slice
# is named macos-arm64_x86_64 (universal) or macos-x86_64 (native Intel).
MACOS_SLICE_NAME=$(basename "$MACOS_SLICE")
if [ "$MACOS_SLICE_NAME" != "macos-arm64" ]; then
    ln -sfn "$MACOS_SLICE_NAME" "$FRAMEWORKS_DIR/GhosttyKit.xcframework/macos-arm64"
fi

ARM64_OUT="${ROOT_DIR}/.build/_ghostty_arm64_$$.a"
X86_OUT="${ROOT_DIR}/.build/_ghostty_x86_64_$$.a"
mkdir -p "${ROOT_DIR}/.build"
ARM64_BASE=$(find_cache_lib "libghostty-fat.a" arm64 || true)
X86_BASE=$(find_cache_lib "libghostty-fat.a" x86_64 || true)
ARM64_BASE="${ARM64_BASE:-$BASE_LIB}"
X86_BASE="${X86_BASE:-$BASE_LIB}"
assemble_arch_fat_lib "$ARM64_BASE" arm64 "$ARM64_OUT"
assemble_arch_fat_lib "$X86_BASE" x86_64 "$X86_OUT"
lipo -create "$ARM64_OUT" "$X86_OUT" -output "$OUTPUT"
ranlib "$OUTPUT" 2>/dev/null || true

# Rewrite Info.plist with the macOS slice only (iOS entries removed above).
MACOS_SLICE_ID=$(basename "$MACOS_SLICE")
cat > "$FRAMEWORKS_DIR/GhosttyKit.xcframework/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AvailableLibraries</key>
    <array>
        <dict>
            <key>BinaryPath</key>
            <string>${OUTPUT_NAME}</string>
            <key>HeadersPath</key>
            <string>Headers</string>
            <key>LibraryIdentifier</key>
            <string>${MACOS_SLICE_ID}</string>
            <key>LibraryPath</key>
            <string>${OUTPUT_NAME}</string>
            <key>SupportedArchitectures</key>
            <array>
                <string>arm64</string>
                <string>x86_64</string>
            </array>
            <key>SupportedPlatform</key>
            <string>macos</string>
        </dict>
    </array>
    <key>CFBundlePackageType</key>
    <string>XFWK</string>
    <key>XCFrameworkFormatVersion</key>
    <string>1.0</string>
</dict>
</plist>
PLIST

echo "    Universal fat library: $(lipo -info "$OUTPUT")"

# Copy Ghostty resources
RESOURCES_SRC="$GHOSTTY_DIR/zig-out/share/ghostty"
if [ -d "$RESOURCES_SRC" ]; then
    rm -rf "$FRAMEWORKS_DIR/ghostty-resources"
    cp -R "$RESOURCES_SRC" "$FRAMEWORKS_DIR/ghostty-resources"
    echo "    Bundled Ghostty resources"
fi

echo "==> Done! GhosttyKit.xcframework is ready (arm64 + x86_64)."
echo "    Verify: swift build --arch arm64 --arch x86_64"
