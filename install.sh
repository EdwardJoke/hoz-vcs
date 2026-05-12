#!/bin/sh
set -eu

HOZ_REPO="EdwardJoke/hoz-vcs"
HOZ_VERSION="${HOZ_VERSION:-}"
PREFIX="${HOME}/.hoz/bin"

echo ' ▄▄   ▄▄ ▄▄▄▄▄▄▄ ▄▄▄▄▄▄▄    ▄▄▄ ▄▄    ▄ ▄▄▄▄▄▄▄ ▄▄▄▄▄▄▄ ▄▄▄▄▄▄ ▄▄▄     ▄▄▄     ▄▄▄▄▄▄▄ ▄▄▄▄▄▄'
echo '█  █ █  █       █       █  █   █  █  █ █       █       █      █   █   █   █   █       █   ▄  █'
echo '█  █▄█  █   ▄   █▄▄▄▄   █  █   █   █▄█ █  ▄▄▄▄▄█▄     ▄█  ▄   █   █   █   █   █    ▄▄▄█  █ █ █'
echo '█       █  █ █  █▄▄▄▄█  █  █   █       █ █▄▄▄▄▄  █   █ █ █▄█  █   █   █   █   █   █▄▄▄█   █▄▄█▄'
echo '█   ▄   █  █▄█  █ ▄▄▄▄▄▄█  █   █  ▄    █▄▄▄▄▄  █ █   █ █      █   █▄▄▄█   █▄▄▄█    ▄▄▄█    ▄▄  █'
echo '█  █ █  █       █ █▄▄▄▄▄   █   █ █ █   █▄▄▄▄▄█ █ █   █ █  ▄   █       █       █   █▄▄▄█   █  █ █'
echo '█▄▄█ █▄▄█▄▄▄▄▄▄▄█▄▄▄▄▄▄▄█  █▄▄▄█▄█  █▄▄█▄▄▄▄▄▄▄█ █▄▄▄█ █▄█ █▄▄█▄▄▄▄▄▄▄█▄▄▄▄▄▄▄█▄▄▄▄▄▄▄█▄▄▄█  █▄█'

usage() {
    echo ""
    echo "Usage: ./install.sh [OPTIONS]"
    echo ""
    echo "Install hoz from GitHub Releases (with Codeberg fallback)."
    echo ""
    echo "Options:"
    echo "  --version TAG   Install a specific version (default: latest)"
    echo "  --prefix DIR    Install to custom directory (default: ~/.hoz/bin)"
    echo "  --codeberg      Download from Codeberg instead of GitHub"
    echo "  --uninstall     Remove installed hoz binary"
    echo "  --help          Show this help message"
    echo ""
}

for arg in "$@"; do
    case "$arg" in
        --version)  shift; HOZ_VERSION="$1"; shift ;;
        --prefix)   shift; PREFIX="$1"; shift ;;
        --uninstall) UNINSTALL=1; shift ;;
        --codeberg)  CODEBERG=1; shift ;;
        --help|-h)   usage; exit 0 ;;
        *) echo "Unknown option: $arg"; usage; exit 1 ;;
    esac
done

if [ "${UNINSTALL:-0}" = "1" ]; then
    if [ ! -f "${PREFIX}/hoz" ]; then
        echo "hoz is not installed at ${PREFIX}/hoz"
        echo "Nothing to remove."
        exit 0
    fi
    EXISTING=$("${PREFIX}/hoz" --version 2>/dev/null || echo "unknown")
    rm -f "${PREFIX}/hoz"
    rmdir "${PREFIX}" 2>/dev/null || true
    echo ""
    echo "✓  hoz removed (${EXISTING})"
    echo ""
    case "$SHELL" in
        */zsh)  SHELL_RC=".zshrc" ;;
        */bash) SHELL_RC=".bashrc" ;;
        */fish) SHELL_RC=".config/fish/config.fish" ;;
        *)      SHELL_RC=".profile" ;;
    esac
    echo "To complete uninstallation, remove this line from ~/${SHELL_RC}:"
    echo ""
    if [ "$SHELL_RC" = ".config/fish/config.fish" ]; then
        echo "  fish_add_path ${PREFIX}"
    else
        echo "  export PATH=\"${PREFIX}:\$PATH\""
    fi
    echo ""
    exit 0
fi

detect_os() {
    case "$(uname -s)" in
        Darwin*)  echo "macos" ;;
        Linux*)   echo "linux" ;;
        *)        echo "unsupported" ;;
    esac
}

detect_arch() {
    case "$(uname -m)" in
        x86_64|amd64)  echo "x86_64" ;;
        aarch64|arm64) echo "aarch64" ;;
        *)             echo "unsupported" ;;
    esac
}

OS="$(detect_os)"
ARCH="$(detect_arch)"

if [ "$OS" = "unsupported" ]; then
    echo "Error: Unsupported OS: $(uname -s)"
    echo "       hoz installer supports macOS and Linux."
    exit 1
fi

if [ "$ARCH" = "unsupported" ]; then
    echo "Error: Unsupported architecture: $(uname -m)"
    echo "       hoz supports x86_64 and aarch64."
    exit 1
fi

if [ -n "$HOZ_VERSION" ]; then
    RELEASE_TAG="v${HOZ_VERSION#v}"
else
    RELEASE_TAG=$(curl -fsSL "https://api.github.com/repos/${HOZ_REPO}/releases/latest" \
        | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/')
fi

if [ -z "$RELEASE_TAG" ]; then
    echo "Error: Could not determine release tag."
    echo "       Check your internet connection or specify --version <TAG>"
    exit 1
fi

BINARY_NAME="hoz-${RELEASE_TAG}-${OS}-${ARCH}"

GITHUB_URL="https://github.com/${HOZ_REPO}/releases/download/${RELEASE_TAG}/${BINARY_NAME}.tar.gz"
CODEBERG_URL="https://codeberg.org/${HOZ_REPO}/releases/download/${RELEASE_TAG}/${BINARY_NAME}.tar.gz"

if [ "${CODEBERG:-0}" = "1" ]; then
    DOWNLOAD_URL="$CODEBERG_URL"
    SOURCE="Codeberg"
else
    DOWNLOAD_URL="$GITHUB_URL"
    SOURCE="GitHub"
fi

echo ""
echo "  Version : ${RELEASE_TAG}"
echo "  Target  : ${OS}-${ARCH}"
echo "  Source  : ${SOURCE}"
echo "  Install : ${PREFIX}/hoz"
echo ""

if [ -f "${PREFIX}/hoz" ]; then
    EXISTING=$("${PREFIX}/hoz" --version 2>/dev/null || echo "unknown")
    echo "⚠  Existing installation found (${EXISTING})."
    printf "   Overwrite? [y/N] "
    read -r confirm
    case "$confirm" in
        [yY][eE][sS]|[yY]) ;;
        *) echo "Installation cancelled."; exit 0 ;;
    esac
fi

mkdir -p "${PREFIX}"

download_file() {
    _url="$1"
    _dest="$2"
    if command -v curl >/dev/null 2>&1; then
        curl -fL --progress-bar "$_url" -o "$_dest"
        return $?
    elif command -v wget >/dev/null 2>&1; then
        wget --progress=bar:force:noscroll "$_url" -O "$_dest"
        return $?
    else
        echo "Error: Neither curl nor wget found. Please install one and try again."
        exit 1
    fi
}

echo "Downloading ${BINARY_NAME} from ${SOURCE}..."

if download_file "${DOWNLOAD_URL}" "${PREFIX}/hoz.tmp"; then
    echo ""
else
    if [ "${CODEBERG:-0}" = "1" ]; then
        echo ""
        echo "Error: Download from Codeberg failed."
        exit 1
    fi
    echo ""
    echo "GitHub download failed. Retrying from Codeberg..."
    SOURCE="Codeberg"
    echo "Downloading ${BINARY_NAME} from ${SOURCE}..."
    if download_file "${CODEBERG_URL}" "${PREFIX}/hoz.tmp"; then
        echo ""
    else
        echo ""
        echo "Error: Download from both GitHub and Codeberg failed."
        exit 1
    fi
fi

tar -xzf "${PREFIX}/hoz.tmp" -C "${PREFIX}" hoz 2>/dev/null || {
    _tmpdir=$(mktemp -d)
    tar -xzf "${PREFIX}/hoz.tmp" -C "$_tmpdir" 2>/dev/null || {
        echo "Error: Failed to extract ${BINARY_NAME}.tar.gz"
        rm -rf "$_tmpdir"
        exit 1
    }
    mv -f "$_tmpdir"/hoz "${PREFIX}/hoz" 2>/dev/null || mv -f "$_tmpdir"/hoz-* "${PREFIX}/hoz" 2>/dev/null || {
        echo "Error: Could not find hoz binary in archive."
        ls -la "$_tmpdir"/
        rm -rf "$_tmpdir"
        exit 1
    }
    rm -rf "$_tmpdir"
}
rm -f "${PREFIX}/hoz.tmp"

INSTALLED=$("${PREFIX}/hoz" --version 2>/dev/null || echo "(version unknown)")

echo ""
echo "✓  hoz installed successfully!"
echo "   ${INSTALLED}"
echo ""

case "$SHELL" in
    */zsh)  SHELL_RC=".zshrc" ;;
    */bash) SHELL_RC=".bashrc" ;;
    */fish) SHELL_RC=".config/fish/config.fish" ;;
    *)      SHELL_RC=".profile" ;;
esac

echo "To use hoz, add it to your PATH:"
echo ""
if [ "$SHELL_RC" = ".config/fish/config.fish" ]; then
    echo "  fish_add_path ${PREFIX}"
else
    echo "  export PATH=\"${PREFIX}:\$PATH\""
fi
echo ""
echo "Add the above line to ~/${SHELL_RC}, then run:"
echo ""
echo "  source ~/${SHELL_RC}"
echo ""
echo "Or run it once to test:"
echo ""
echo "  export PATH=\"${PREFIX}:\$PATH\" && hoz --help"
echo ""