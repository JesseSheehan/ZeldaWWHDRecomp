#!/usr/bin/env bash
# Builds everything the visionOS app (visionos/WindWakerVision) links, from your own copy of the game:
# the recompiled game code and the runtime, for Apple Vision Pro. See docs/visionos.md.
#
#   tools/visionos/build.sh --game DIR                 an extracted game folder (code/, content/, meta/)
#   tools/visionos/build.sh --image GAME.wux [KEYS]    a Wii U disc image (.wux / .wud) and its keys
#   tools/visionos/build.sh --archive GAME.wua         a Cemu archive
#
# KEYS (for --image; nothing is printed, logged or stored):
#   --disc-key FILE     the disc key (default: the image's name with .key)
#   --common-key FILE   the Wii U common key (default: WIIU_COMMON_KEY, then common.key next to the image)
#   --keys-stdin        "disc <32 hex digits>" / "common <32 hex digits>" lines on standard input
#
# Options:
#   --build-dir DIR     where everything goes (default: build-visionos/ in the repository, ignored by git)
#   --jobs N            parallel compile jobs (default: all cores)
#
# Output, all inside the build directory (game-derived: never commit or share it):
#   game/      the extracted game (--image / --archive), to import into the app
#   gen/       the recompiled game code (C)
#   runtime/   the visionOS libraries the Xcode project links (libwwhd.a, libgamecode.a, ...)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILD="$REPO/build-visionos"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 8)"
GAME="" IMAGE="" ARCHIVE=""
EXTRACT_ARGS=()

die() { echo "error: $*" >&2; exit 1; }
step() { echo; echo "==> $*"; }
usage() { sed -n '2,24p' "$0" | sed 's/^# \{0,1\}//'; exit 2; }

while [ $# -gt 0 ]; do
    case "$1" in
        --game) GAME="${2:?}"; shift 2 ;;
        --image) IMAGE="${2:?}"; shift 2 ;;
        --archive) ARCHIVE="${2:?}"; shift 2 ;;
        --disc-key|--common-key) EXTRACT_ARGS+=("$1" "${2:?}"); shift 2 ;;
        --keys-stdin) EXTRACT_ARGS+=("$1"); shift ;;
        --build-dir) BUILD="${2:?}"; shift 2 ;;
        --jobs) JOBS="${2:?}"; shift 2 ;;
        -h|--help) usage ;;
        *) echo "unknown option: $1" >&2; usage ;;
    esac
done
[ -n "$GAME$IMAGE$ARCHIVE" ] || usage
mkdir -p "$BUILD"
BUILD="$(cd "$BUILD" && pwd)"

# ---------------------------------------------------------------- prerequisites
step "Checking the tools"
command -v xcodebuild >/dev/null || die "Xcode is not installed (App Store), or not selected: sudo xcode-select -s /Applications/Xcode.app"
XCODE="$(xcodebuild -version 2>/dev/null | head -1)"
[ -n "$XCODE" ] || die "xcodebuild does not run: open Xcode once to finish its setup, and check xcode-select -p"
xcrun --sdk xros --show-sdk-path >/dev/null 2>&1 ||
    die "the visionOS SDK is missing: Xcode > Settings > Components, install visionOS"
for tool in cmake ninja python3; do
    command -v "$tool" >/dev/null || die "$tool is missing (Homebrew: brew install $tool)"
done
echo "$XCODE, visionOS SDK $(xcrun --sdk xros --show-sdk-version), $(cmake --version | head -1), ninja $(ninja --version), $(python3 --version)"

# ---------------------------------------------------------------- the game
if [ -n "$IMAGE$ARCHIVE" ]; then
    step "Building the game extractor (macOS)"
    # zstd (Cemu archives), the pinned release the CMake build uses, checked by its SHA-256
    ZSTD="$BUILD/host/zstd-1.5.7"
    if [ ! -d "$ZSTD/lib" ]; then
        mkdir -p "$BUILD/host"
        curl -fsSL -o "$BUILD/host/zstd.tar.gz" https://github.com/facebook/zstd/releases/download/v1.5.7/zstd-1.5.7.tar.gz
        echo "eb33e51f49a15e023950cd7825ca74a4a2b43db8354825ac24fc1b7ee09e6fa3  $BUILD/host/zstd.tar.gz" | shasum -a 256 -c - >/dev/null ||
            die "zstd download does not match its SHA-256"
        tar -xzf "$BUILD/host/zstd.tar.gz" -C "$BUILD/host"
    fi
    EXTRACT="$BUILD/host/wwhd-extract"
    if [ ! -x "$EXTRACT" ]; then
        xcrun clang -O2 -w -DZSTD_DISABLE_ASM -DXXH_NAMESPACE=ZSTD_ -I"$ZSTD/lib" -c \
            "$ZSTD"/lib/common/*.c "$ZSTD"/lib/decompress/*.c "$ZSTD"/lib/compress/*.c
        mv ./*.o "$BUILD/host/" 2>/dev/null || true
        xcrun clang++ -O2 -std=c++20 -I"$ZSTD/lib" -I"$REPO/tools/wudextract" -o "$EXTRACT" \
            "$REPO/tools/wudextract/wwhd_extract.cpp" "$REPO/tools/wudextract/zarchive.cpp" "$REPO/tools/wudextract/crypto.cpp" \
            "$BUILD"/host/*.o
    fi
    step "Extracting the game into $BUILD/game"
    rm -rf "$BUILD/game.partial"
    if [ -n "$IMAGE" ]; then
        "$EXTRACT" ${EXTRACT_ARGS[@]+"${EXTRACT_ARGS[@]}"} --progress extract "$IMAGE" "$BUILD/game.partial" ||
            die "extraction failed (exit $?): 3/4 disc key missing or wrong, 5/6 common key missing or wrong, 7 not a Wii U image, 8 corrupt image"
    else
        "$EXTRACT" --progress extract "$ARCHIVE" "$BUILD/game.partial" ||
            die "extraction failed (exit $?): 7 not a Cemu archive, 8 corrupt archive, 10 no single game title in it"
    fi
    rm -rf "$BUILD/game"
    mv "$BUILD/game.partial" "$BUILD/game"
    GAME="$BUILD/game"
fi
GAME="$(cd "$GAME" && pwd)"
RPX="$GAME/code/cking.rpx"
[ -f "$RPX" ] || die "no code/cking.rpx in $GAME (the folder with code/, content/ and meta/)"
[ -d "$GAME/content" ] || die "no content/ folder in $GAME"

step "Checking the game"
BUILD_NAME="$(python3 -I - "$REPO/tools/recomp" "$RPX" <<'EOF'
import sys
sys.path.insert(0, sys.argv[1])
import builds
b = builds.identify(sys.argv[2])
print(b.name if b else "")
EOF
)"
[ -n "$BUILD_NAME" ] || die "$RPX is not a version of the game this port supports (see docs/builds.md)"
echo "cking.rpx: the $BUILD_NAME version"

# ---------------------------------------------------------------- recompile
step "Recompiling the game code into $BUILD/gen"
python3 "$REPO/tools/recomp/recomp.py" "$RPX" "$BUILD/gen" > "$BUILD/recomp.log" 2>&1 ||
    { tail -20 "$BUILD/recomp.log"; die "the recompiler failed (log: $BUILD/recomp.log)"; }
grep -E "^(build|functions):" "$BUILD/recomp.log" || true

# ---------------------------------------------------------------- the visionOS libraries
step "Building the runtime and the game code for visionOS (about 10 minutes the first time)"
cmake -S "$REPO" -B "$BUILD/runtime" -G Ninja -DCMAKE_SYSTEM_NAME=visionOS -DCMAKE_OSX_SYSROOT=xros \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=27.0 -DCMAKE_BUILD_TYPE=RelWithDebInfo \
    -DGEN_DIR="$BUILD/gen" > "$BUILD/cmake.log" 2>&1 || { tail -20 "$BUILD/cmake.log"; die "CMake configuration failed (log: $BUILD/cmake.log)"; }
ninja -C "$BUILD/runtime" -j "$JOBS" wwhd gamecode cemu_latte imgui wwhd_zstd_static lz4_static > "$BUILD/ninja.log" 2>&1 ||
    { grep -E "error:|FAILED" "$BUILD/ninja.log" | head -20; die "the build failed (log: $BUILD/ninja.log)"; }

# ---------------------------------------------------------------- next steps
LOCAL="$REPO/visionos/Local.xcconfig"
step "Done"
cat <<EOF
The visionOS libraries are in $BUILD/runtime.

Next:
  1. Signing: copy visionos/Local.xcconfig.example to visionos/Local.xcconfig and set your team ID
     $( [ -f "$LOCAL" ] && echo "(you have one)" || echo "(not there yet)" )
  2. Open visionos/WindWakerVision/WindWakerVision.xcodeproj, choose your Apple Vision Pro, and Run
     (or: xcodebuild -project visionos/WindWakerVision/WindWakerVision.xcodeproj -scheme WindWakerVision \\
          -destination 'generic/platform=visionOS' -allowProvisioningUpdates build)
  3. Start the app on the headset: it asks for the game folder ($GAME).
     Put that folder in iCloud Drive or another Files location first (docs/visionos.md, "Importing the game").
EOF
if [ "$BUILD" != "$REPO/build-visionos" ]; then
    echo
    echo "Your build directory is not the default one: tell Xcode in visionos/Local.xcconfig:"
    echo "  WWHD_RUNTIME_BUILD = $BUILD/runtime"
fi
