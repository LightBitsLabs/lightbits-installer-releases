#!/bin/sh
# Lightbits Installer Bootstrap Script
#
# Usage:
#   curl -sL https://www.lightbitslabs.com/installer | sh
#   wget -O- https://www.lightbitslabs.com/installer | sh
#
# Environment variables:
#   INSTALLER_VERSION  Pin to a specific version (e.g., v1.0.0). Default: latest.
#   INSTALLER_URL      Override the base download URL.
#
# This script:
#   1. Detects OS and architecture
#   2. Downloads the correct tarball from GitHub Releases
#   3. Verifies SHA256 checksum
#   4. Extracts and launches the binary

set -e

REPO="LightBitsLabs/lightbits-installer-releases"
BINARY_NAME="lightbits-installer"
BASE_URL="${INSTALLER_URL:-https://github.com/${REPO}/releases}"

# ── Detect platform ──

detect_os() {
    case "$(uname -s)" in
        Linux*)  echo "linux" ;;
        Darwin*) echo "darwin" ;;
        *)       echo "unsupported" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "amd64" ;;
        arm64|aarch64) echo "arm64" ;;
        *)             echo "unsupported" ;;
    esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

if [ "$OS" = "unsupported" ]; then
    echo "Error: unsupported operating system: $(uname -s)" >&2
    echo "Supported: Linux, macOS" >&2
    exit 1
fi

if [ "$ARCH" = "unsupported" ]; then
    echo "Error: unsupported architecture: $(uname -m)" >&2
    echo "Supported: x86_64 (amd64), arm64 (aarch64)" >&2
    exit 1
fi

# Darwin arm64 is supported; Darwin amd64 is supported; Linux amd64 only.
if [ "$OS" = "linux" ] && [ "$ARCH" = "arm64" ]; then
    echo "Error: linux/arm64 is not currently supported" >&2
    echo "Supported Linux architecture: amd64 (x86_64)" >&2
    exit 1
fi

check_deps() {
    missing=""
    for cmd in tar awk grep sed mktemp; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo "Error: required tool '$cmd' not found." \
                 "Install it and re-run." >&2
            missing="yes"
        fi
    done
    [ -z "$missing" ] || exit 1
}
check_deps

# ── Resolve version ──

if [ -n "$INSTALLER_VERSION" ]; then
    VERSION="$INSTALLER_VERSION"
else
    echo "Fetching latest release version..."
    if command -v curl >/dev/null 2>&1; then
        VERSION=$(curl -sI "${BASE_URL}/latest" | grep -i "^location:" | sed 's|.*/||' | tr -d '\r\n')
    elif command -v wget >/dev/null 2>&1; then
        VERSION=$(wget --spider --server-response "${BASE_URL}/latest" 2>&1 | grep "Location:" | tail -1 | sed 's|.*/||' | tr -d '\r\n')
    else
        echo "Error: curl or wget is required" >&2
        exit 1
    fi

    if [ -z "$VERSION" ]; then
        echo "Error: could not determine latest version" >&2
        exit 1
    fi
fi

echo "Installing ${BINARY_NAME} ${VERSION} (${OS}/${ARCH})..."

# ── Download ──

TARBALL="${BINARY_NAME}-${VERSION}-${OS}-${ARCH}.tar.gz"
DOWNLOAD_URL="${BASE_URL}/download/${VERSION}/${TARBALL}"
CHECKSUM_URL="${BASE_URL}/download/${VERSION}/SHA256SUMS"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

download() {
    if command -v curl >/dev/null 2>&1; then
        curl -fsSL -o "$1" "$2"
    elif command -v wget >/dev/null 2>&1; then
        wget -q -O "$1" "$2"
    fi
}

echo "Downloading ${TARBALL}..."
download "${TMPDIR}/${TARBALL}" "${DOWNLOAD_URL}"

echo "Downloading checksums..."
download "${TMPDIR}/SHA256SUMS" "${CHECKSUM_URL}"

# ── Verify checksum ──

echo "Verifying SHA256 checksum..."
EXPECTED=$(grep "${TARBALL}" "${TMPDIR}/SHA256SUMS" | awk '{print $1}')
if [ -z "$EXPECTED" ]; then
    echo "Warning: checksum not found for ${TARBALL}, skipping verification" >&2
else
    if command -v sha256sum >/dev/null 2>&1; then
        ACTUAL=$(sha256sum "${TMPDIR}/${TARBALL}" | awk '{print $1}')
    elif command -v shasum >/dev/null 2>&1; then
        ACTUAL=$(shasum -a 256 "${TMPDIR}/${TARBALL}" | awk '{print $1}')
    else
        echo "Warning: sha256sum/shasum not found, skipping verification" >&2
        ACTUAL="$EXPECTED"
    fi

    if [ "$EXPECTED" != "$ACTUAL" ]; then
        echo "Error: checksum mismatch!" >&2
        echo "  expected: ${EXPECTED}" >&2
        echo "  actual:   ${ACTUAL}" >&2
        exit 1
    fi
    echo "Checksum verified."
fi

# ── Extract and run ──

echo "Extracting..."
tar xzf "${TMPDIR}/${TARBALL}" -C "${TMPDIR}"

BINARY_PATH="${TMPDIR}/${BINARY_NAME}-${OS}-${ARCH}"
if [ ! -f "$BINARY_PATH" ]; then
    # Try without platform suffix (older naming).
    BINARY_PATH="${TMPDIR}/${BINARY_NAME}"
fi

chmod +x "$BINARY_PATH"

# Install to a stable path before exec so the EXIT trap cannot race.
# trap 'rm -rf "$TMPDIR"' fires during exec's process handoff and deletes
# the binary before the kernel can load it, causing "No such file or directory".
INSTALL_DIR="$HOME/.local/bin"
if ! mkdir -p "$INSTALL_DIR"; then
    echo "Error: failed to create $INSTALL_DIR" >&2
    exit 1
fi
if ! cp "$BINARY_PATH" "$INSTALL_DIR/lightbits-installer"; then
    echo "Error: failed to install binary to $INSTALL_DIR" >&2
    exit 1
fi
chmod +x "$INSTALL_DIR/lightbits-installer"

# Disarm EXIT trap and clean up temp dir explicitly — no race possible now.
trap - EXIT
rm -rf "$TMPDIR"

# Warn if ~/.local/bin is not in PATH so the user can add it for future runs.
case ":$PATH:" in
    *":$INSTALL_DIR:"*) ;;
    *) echo "Note: add $INSTALL_DIR to your PATH for future runs:" >&2
       echo "  export PATH=\"\$HOME/.local/bin:\$PATH\"" >&2 ;;
esac

echo ""
echo "Lightbits Installer ${VERSION} ready."
echo "Binary installed to: $INSTALL_DIR/lightbits-installer"
echo ""

exec "$INSTALL_DIR/lightbits-installer" "install" "$@"
