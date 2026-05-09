# Project Purpose — v0.4.2

## What
Build the hoz installer (`install.sh`) that auto-detects system architecture, downloads the correct binary from GitHub Release assets to `~/.hoz/bin/`, and displays PATH setup instructions — plus make `final.zig` and `main.zig` read their version from `build.zig.zon` instead of hardcoding it.

## Why
The project currently has two problems:
1. **Version is duplicated** across 3 locations ([`final.zig:16`](src/final/final.zig#L16), [`main.zig:244`](src/main.zig#L244), [`build.zig.zon:17`](build.zig.zon#L17)) — every release requires manual sync, risking drift where `hoz --version` reports a stale string.
2. **No installation story** — users must manually build from source or guess how to get a binary. The [`install.sh`](install.sh) exists but only contains ASCII art; it doesn't actually install anything.

A proper installer lowers the barrier to adoption and makes distribution via GitHub Releases practical.

## Success Criteria
- [ ] `hoz --version` outputs the version from `build.zig.zon`, not a hardcoded constant
- [ ] `./install.sh` detects OS (macOS/Linux) and CPU architecture (x86_64/aarch64) automatically
- [ ] `./install.sh` downloads the matching binary from GitHub Release assets into `~/.hoz/bin/`
- [ ] `./install.sh` prints clear instructions for adding `~/.hoz/bin` to `$PATH` (without auto-modifying shell config)
- [ ] `./install.sh` displays the existing ASCII art banner on startup
