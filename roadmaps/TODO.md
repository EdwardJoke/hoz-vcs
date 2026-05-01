# Hoz Roadmap & Open Issues

> Last updated: 2026-05-01 | Target Release: **v0.3.0**

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 Critical | Blocks core workflows or security |
| 🟡 High | Important Git feature gap |
| 🟢 Medium | Useful but not blocking |
| ⚪ Low | Nice-to-have / niche workflow |

---

## 1. Git Compatibility Gaps

| # | Priority | Area | Gap Description | Status |
|---|----------|------|-----------------|--------|
| 1 | 🟡 High | **Network protocol** | `sideband-64k demux` — multiplexed data channel for progress/error during push/fetch. Required for full smart protocol compliance. | ✅ Done |
| 2 | 🟡 High | **Security** | Full GPG signature verification in `verify-tag` / `verify-commit`. Currently basic validation only. | ✅ Done |
| 3 | 🟢 Medium | **SSH transport** | Native SSH via libssh2 instead of shell-out to system `ssh`. Improves portability and error handling on Windows. | ✅ Done |
| 4 | ⚪ Low | **`instaweb` / `web--browse`** | Launch web browser for gitweb. UI helper, not core Git functionality. | — |
| 5 | ⚪ Low | **`quiltimport`** | Import quilt patch series into Git. Niche workflow tool. | — |
| 6 | ⚪ Low | **`send-email`** | Format and send patches via email (SMTP). Mailing-list workflow tool. | — |
| 7 | ⚪ Low | **`request-pull`** | Generate pull request summary text. Niche — most users use GitHub/GitLab PRs instead. | — |

---

## 2. Git Compatibility Assessment

| Category | Coverage | Status |
|----------|----------|--------|
| **Porcelain commands** (user-facing) | ~85% | init, clone, add, commit, log, diff, status, branch, checkout, stash, tag, merge, rebase, reset, push, pull, fetch, remote, cherry-pick, revert, show, notes, bundle, blame, bisect, describe, fsck, format-patch, archive, filter-branch work |
| **Plumbing commands** (low-level) | ~82% | cat-file, hash-object, ls-files, ls-tree, show-ref, for-each-ref, rev-parse, write-tree, commit-tree, update-index, rev-list, name-rev, verify-tag, rm, am, filter-branch work |
| **Network operations** | ~65% | fetch, push, ls-remote, clone over HTTP/smart protocol. SSH delegates to shell. Pack receive/send with delta resolution. Missing: sideband-64k demux |
| **Object storage** | ~85% | Loose objects read/write, pack file parsing, zlib compress/decompress, SHA-1/SHA-256, delta resolution (main path), thin pack detection |
| **Index/staging** | ~85% | Index read/write/parse/serialize, stage add/rm/move/reset, tree cache, checksums, extensions |
| **Merge/conflict** | ~70% | Three-way merge (LCS diff3), fast-forward, conflict markers, abort/continue, rerere |
| **History traversal** | ~70% | Log formatting (6 formats), date parsing (7 formats), pretty-print (4 styles), rev-list, show-ref, for-each-ref, rev-parse |
| **Overall compatibility** | **~77%** | Daily workflows fully functional. Network protocol gaps and niche commands remain. Some features shell out to system `git`. Integration and fuzz test suites in place. |

---

## 3. Release v0.3.0 Checklist

> Minor release — medium scope feature additions and compatibility improvements.

### Should Have

- [x] **Implement `sideband-64k demux`** — complete smart protocol multiplexed channel support
  - Enables proper progress output during clone/push/pack operations
  - File: `src/network/sideband.zig`
  - Milestone: `git clone` over smart protocol shows remote progress correctly

- [x] **GPG signature verification in `verify-tag`** — extend beyond basic checksum validation
  - Parse OpenPGP signatures embedded in tag objects
  - Validate against trusted keyring
  - Files: `src/git/gpg.zig`, `src/tag/verify.zig`, `src/cli/verify_tag.zig`

### Nice to Have

- [x] **Native SSH transport (libssh2)** — replace shell-out `ssh` invocation
  - Improves Windows support and connection error diagnostics
  - File: `src/network/ssh_native.zig`
  - Milestone: `git push/pull` over SSH without system `ssh` dependency

### Won't Have (deferred to v0.4.0+)

- `instaweb`, `quiltimport`, `send-email`, `request-pull` — niche workflows with minimal user demand

---
