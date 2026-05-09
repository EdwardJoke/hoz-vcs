# Project Purpose — v0.5.0

## What
Fix all 8 issues identified in `zig-out/hoz-vcs-audit-report.md` to eliminate fake/demo code, broken tooling, placeholder artifacts, and code quality problems that undermine project credibility and maintainability.

## Why
The v0.4.2 audit revealed critical credibility issues:
1. **Fake/demo code** — [`src/root.zig`](src/root.zig) contains Zig template scaffold (`printAnotherMessage`, `add()`) unrelated to VCS functionality
2. **Broken installation** — [`install.sh`](install.sh) references wrong repo (`edwardxie/hoz` instead of `EdwardJoke/hoz-vcs`), making it completely non-functional
3. **Opaque binary** — [`network/libservice.a`](src/network/libservice.a) is a precompiled 2,264-byte static library with no source or build documentation, violating open-source transparency
4. **False test coverage** — 7 modules have `expect(true)` placeholder tests that validate nothing (cli, network, stash, perf, ci, history, reset)
5. **Stale configuration** — [`wasup.toml`](.wasup/wasup.toml) shows v0.4.1 while actual version is v0.4.2; [`build.zig.zon`](build.zig.zon) has commented-out dependency residue
6. **Code duplication** — `findCommand()` and `dispatch()` use 40+ if-else chains instead of iterating over existing `ALL_COMMANDS` array

These issues damage trust with contributors and users. A clean codebase is essential before adding new features.

## Success Criteria
- [ ] All template scaffold code removed from [`root.zig`](src/root.zig) — no more `printAnotherMessage()`, `add()`, or arithmetic tests
- [ ] [`install.sh`](install.sh) correctly references `EdwardJoke/hoz-vcs` repository
- [ ] [`network/libservice.a`](src/network/libservice.a) either removed or accompanied by source + build instructions
- [ ] All 7 modules have real unit tests replacing `expect(true)` placeholders
- [ ] [`build.zig.zon`](build.zig.zon) cleaned of commented dependency residue
- [ ] [`.wasup/wasup.toml`](.wasup/wasup.toml) synchronized to current version
- [ ] `findCommand()` in [`main.zig`](src/main.zig) and `dispatch()` in [`dispatcher.zig`](src/cli/dispatcher.zig) refactored to use `ALL_COMMANDS` iteration
- [ ] Project passes audit re-check with zero P0/P1/P2 findings
