#!/usr/bin/env sh
# Downloads the Zig release in ./version into this directory (Linux and macOS).
# On Windows use download.cmd.
#
# Usage: ./zig/download.sh [mirror]
#
#   mirror  Optional Zig community mirror to download from instead of ziglang.org,
#           for example https://pkg.hexops.org/zig (no trailing slash).
#           See https://ziglang.org/download/community-mirrors/.
#
# To update Zig:
#   1. Write the new release, for example 0.17.1, into ./version.
#   2. Copy the SHA-256 checksums of its archives from https://ziglang.org/download/
#      (or the "shasum" fields in https://ziglang.org/download/index.json) into
#      ./checksums.txt, one "<arch>-<os> <sha256>" line per platform.
#   3. Update ZLS to a matching release, see zls/download.sh.
#   4. Run this script.
set -eu
cd "$(dirname "$0")"

case "$(uname -m)" in
    arm64|aarch64) ZIG_ARCH=aarch64 ;;
    x86_64|amd64) ZIG_ARCH=x86_64 ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
case "$(uname)" in
    Linux) ZIG_OS=linux ;;
    Darwin) ZIG_OS=macos ;;
    *) echo "Unsupported OS: $(uname)"; exit 1 ;;
esac

ZIG_VERSION=$(cat version)
ZIG_SHA256=$(grep "^${ZIG_ARCH}-${ZIG_OS} " checksums.txt | cut -d ' ' -f 2)
ZIG_NAME="zig-${ZIG_ARCH}-${ZIG_OS}-${ZIG_VERSION}"
ZIG_ARCHIVE="cache/${ZIG_NAME}.tar.xz"
# ziglang.org keeps releases in a directory per version, mirrors serve them flat.
ZIG_URL="https://ziglang.org/download/${ZIG_VERSION}/${ZIG_NAME}.tar.xz"
if [ -n "${1:-}" ]; then
    ZIG_URL="$1/${ZIG_NAME}.tar.xz"
fi

if [ -z "$ZIG_SHA256" ]; then
    echo "No checksum for ${ZIG_ARCH}-${ZIG_OS} in checksums.txt."
    exit 1
fi

if [ -x zig ] && [ "$(./zig version)" = "$ZIG_VERSION" ]; then
    echo "Zig $ZIG_VERSION is already installed."
    exit 0
fi

# The archive is kept in ./cache, so CI can cache that directory.
mkdir -p cache
if [ ! -f "$ZIG_ARCHIVE" ]; then
    echo "Downloading $ZIG_URL ..."
    curl --fail --location --retry 3 --silent --show-error --output "$ZIG_ARCHIVE.part" "$ZIG_URL"
    mv "$ZIG_ARCHIVE.part" "$ZIG_ARCHIVE"
fi

# sha256sum is missing on older macOS, which has shasum instead.
ZIG_ACTUAL=$(sha256sum "$ZIG_ARCHIVE" 2>/dev/null || shasum -a 256 "$ZIG_ARCHIVE")
ZIG_ACTUAL=${ZIG_ACTUAL%% *}
if [ "$ZIG_ACTUAL" != "$ZIG_SHA256" ]; then
    rm "$ZIG_ARCHIVE"
    echo "Checksum mismatch for $ZIG_URL: expected $ZIG_SHA256, got $ZIG_ACTUAL."
    exit 1
fi

echo "Extracting $ZIG_ARCHIVE ..."
rm -rf zig doc lib
tar -xf "$ZIG_ARCHIVE" --strip-components=1

echo "Installed Zig $ZIG_VERSION to $(pwd)/zig"
