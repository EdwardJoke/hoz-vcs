#!/bin/bash
set -euo pipefail

REPO="EdwardJoke/hoz-vcs"
TAP="EdwardJoke/homebrew-tap"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m'

info()  { printf "${GREEN}[info]${NC}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[warn]${NC}  %s\n" "$1"; }
error() { printf "${RED}[error]${NC} %s\n" "$1" >&2; exit 1; }

if command -v brew >/dev/null 2>&1; then
    if brew list hoz &>/dev/null; then
        info "Hoz is already installed. Checking for updates..."
        brew upgrade hoz 2>/dev/null || true
    else
        info "Adding tap ${TAP}..."
        brew tap "${TAP}"
        info "Installing hoz via Homebrew..."
        brew install hoz
    fi
else
    info "Homebrew not found. Installing via direct download..."

    ARCH=$(uname -m)
    if [ "$ARCH" = "x86_64" ]; then
        SUFFIX="linux-x86_64"
    elif [ "$ARCH" = "aarch64" ] || [ "$ARCH" = "arm64" ]; then
        SUFFIX="linux-x86_64"
    else
        error "Unsupported architecture: ${ARCH}"
    fi

    LATEST=$(curl -fsL "https://api.github.com/repos/${REPO}/releases/latest" | grep '"tag_name"' | head -1 | sed -E 's/.*"v([^"]+)".*/\1/')
    [ -z "$LATEST" ] && error "Could not determine latest version"

    info "Latest version: ${LATEST}"
    FILENAME="hoz-${LATEST}-${SUFFIX}.tar.gz"
    URL="https://github.com/${REPO}/releases/download/v${LATEST}/${FILENAME}"

    TMPDIR=$(mktemp -d)
    trap 'rm -rf "$TMPDIR"' EXIT

    info "Downloading ${URL}..."
    curl -fsSL "$URL" -o "${TMPDIR}/${FILENAME}"
    tar -xzf "${TMPDIR}/${FILENAME}" -C "${TMPDIR}"

    INSTALL_DIR="${HOME}/.local/bin"
    mkdir -p "$INSTALL_DIR"

    install -m 755 "${TMPDIR}/hoz" "${INSTALL_DIR}/hoz"

    info "Installed hoz to ${INSTALL_DIR}/hoz"

    case ":${PATH}:" in
        *":${INSTALL_DIR}:"*) ;;
        *)
            SHELL_RC="${HOME}/.bashrc"
            [ -f "${HOME}/.zshrc" ] && SHELL_RC="${HOME}/.zshrc"
            echo '' >> "$SHELL_RC"
            echo 'export PATH="${HOME}/.local/bin:${PATH}"' >> "$SHELL_RC"
            warn "Added ${INSTALL_DIR} to PATH in ${SHELL_RC}"
            warn "Run: source ${SHELL_RC}"
            ;;
    esac
fi

if command -v hoz >/dev/null 2>&1; then
    VERSION=$(hoz --version 2>/dev/null || echo "unknown")
    info "Hoz ${VERSION} installed successfully!"
else
    error "Installation failed. hoz not found in PATH."
fi