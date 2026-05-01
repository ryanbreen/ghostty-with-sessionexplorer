#!/bin/bash
#
# zig-build-wrb.sh — wrapper around `zig build` that works on macOS 26
# (Tahoe) with Zig 0.15.2.
#
# Why this exists: macOS 26's libSystem.tbd dropped the `arm64-macos`
# target, leaving only `arm64e-macos`. Zig 0.15.2 emits arm64-macos
# binaries, so the linker fails to resolve libc symbols (abort, fork,
# exit, __availability_version_check, etc.) when building the build
# runner against the latest SDK.
#
# Workaround: redirect `xcrun --show-sdk-path` to the macOS 15.x SDK
# (via /Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk, which
# still ships the arm64-macos symbols) for the duration of the build.
# The resulting object files run fine on macOS 26 because the deployment
# target is still macos 26; we're only borrowing the older SDK's libc
# stubs for link-time symbol resolution.
#
# Drop this when:
#   1) Ghostty bumps to a Zig version (0.16+) that knows about macOS 26
#      and emits arm64e-macos by default, OR
#   2) Apple ships a libSystem.tbd that includes arm64-macos again.
#
# Usage: same as `zig build`, e.g.:
#   ./macos/zig-build-wrb.sh
#   ./macos/zig-build-wrb.sh -Dapp-runtime=none -Demit-xcframework=true

set -eu

ZIG="${ZIG:-/Users/wrb/.local/zig/zig-aarch64-macos-0.15.2/zig}"
OLDER_SDK="/Library/Developer/CommandLineTools/SDKs/MacOSX15.sdk"
WRAP_DIR="${TMPDIR:-/tmp}/ghostty-xcrun-wrap.$$"

if [[ ! -d "$OLDER_SDK" ]]; then
  echo "Older SDK not found at: $OLDER_SDK" >&2
  echo "This SDK should be installed alongside MacOSX26.x.sdk in your" >&2
  echo "Command Line Tools. If absent, install via: xcode-select --install" >&2
  exit 1
fi

if [[ ! -x "$ZIG" ]]; then
  echo "Zig not found at: $ZIG" >&2
  echo "Set the ZIG env var or install Zig 0.15.2." >&2
  exit 1
fi

# Build a one-shot xcrun wrapper that returns the older SDK path when
# Zig asks for it. Real xcrun handles everything else.
mkdir -p "$WRAP_DIR"
trap "rm -rf '$WRAP_DIR'" EXIT

cat > "$WRAP_DIR/xcrun" <<EOF
#!/bin/bash
case "\$*" in
    *--show-sdk-path*)
        if [[ "\$*" == *"--sdk macosx"* || "\$*" != *"--sdk"* ]]; then
            echo "$OLDER_SDK"
            exit 0
        fi
        ;;
esac
exec /usr/bin/xcrun "\$@"
EOF
chmod +x "$WRAP_DIR/xcrun"

cd "$(dirname "$0")/.."

PATH="$WRAP_DIR:$PATH" exec "$ZIG" build "$@"
