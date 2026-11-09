#!/usr/bin/env sh
# Downloads the ZLS release in ./version into this directory (Linux and macOS).
# On Windows use download.cmd.
#
# To update ZLS:
#   1. Write the new release, for example 0.17.0, into ./version. Pick the one that
#      matches the Zig release in ../version.
#   2. Copy the SHA-256 checksums of its archives (the "shasum" fields in
#      https://builds.zigtools.org/index.json) into ./checksums.txt,
#      one "<arch>-<os> <sha256>" line per platform.
#   3. Run this script.
set -eu
cd "$(dirname "$0")"

case "$(uname -m)" in
    arm64|aarch64) ZLS_ARCH=aarch64 ;;
    x86_64|amd64) ZLS_ARCH=x86_64 ;;
    *) echo "Unsupported architecture: $(uname -m)"; exit 1 ;;
esac
case "$(uname)" in
    Linux) ZLS_OS=linux ;;
    Darwin) ZLS_OS=macos ;;
    *) echo "Unsupported OS: $(uname)"; exit 1 ;;
esac

ZLS_VERSION=$(cat version)
ZLS_SHA256=$(grep "^${ZLS_ARCH}-${ZLS_OS} " checksums.txt | cut -d ' ' -f 2)
ZLS_NAME="zls-${ZLS_ARCH}-${ZLS_OS}-${ZLS_VERSION}"
ZLS_ARCHIVE="cache/${ZLS_NAME}.tar.xz"
ZLS_URL="https://builds.zigtools.org/${ZLS_NAME}.tar.xz"

if [ -z "$ZLS_SHA256" ]; then
    echo "No checksum for ${ZLS_ARCH}-${ZLS_OS} in checksums.txt."
    exit 1
fi

if [ -x zls ] && [ "$(./zls version)" = "$ZLS_VERSION" ]; then
    echo "ZLS $ZLS_VERSION is already installed."
    exit 0
fi

# The archive is kept in ./cache, so CI can cache that directory.
mkdir -p cache
if [ ! -f "$ZLS_ARCHIVE" ]; then
    echo "Downloading $ZLS_URL ..."
    curl --fail --location --retry 3 --silent --show-error --output "$ZLS_ARCHIVE.part" "$ZLS_URL"
    mv "$ZLS_ARCHIVE.part" "$ZLS_ARCHIVE"
fi

# sha256sum is missing on older macOS, which has shasum instead.
ZLS_ACTUAL=$(sha256sum "$ZLS_ARCHIVE" 2>/dev/null || shasum -a 256 "$ZLS_ARCHIVE")
ZLS_ACTUAL=${ZLS_ACTUAL%% *}
if [ "$ZLS_ACTUAL" != "$ZLS_SHA256" ]; then
    rm "$ZLS_ARCHIVE"
    echo "Checksum mismatch for $ZLS_URL: expected $ZLS_SHA256, got $ZLS_ACTUAL."
    exit 1
fi

# The archive holds its files at the top level. Only the binary is installed.
echo "Extracting $ZLS_ARCHIVE ..."
rm -f zls
tar -xf "$ZLS_ARCHIVE" zls

echo "Installed ZLS $ZLS_VERSION to $(pwd)/zls"
