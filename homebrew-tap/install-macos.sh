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

command -v brew >/dev/null 2>&1 || error "Homebrew not found. Install from https://brew.sh"

if brew list hoz &>/dev/null; then
    info "Hoz is already installed. Checking for updates..."
    brew upgrade hoz 2>/dev/null || true
else
    info "Adding tap ${TAP}..."
    brew tap "${TAP}"

    info "Installing hoz..."
    brew install hoz
fi

if command -v hoz &>/dev/null; then
    VERSION=$(hoz --version 2>/dev/null || echo "unknown")
    info "Hoz ${VERSION} installed successfully!"
else
    error "Installation failed. hoz not found in PATH."
fi