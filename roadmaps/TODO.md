# Hoz Roadmap & Open Issues

> Last updated: 2026-04-30 | Target Release: **v0.2.12**

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 Critical | Blocks core workflows or security |
| 🟡 High | Important Git feature gap |
| 🟢 Medium | Useful but not blocking |
| ⚪ Low | Nice-to-have / niche workflow |

---

## 1. Missing Git Commands

| # | Priority | Command | Why It Matters | Status |
|---|----------|---------|---------------|--------|
| 1 | 🟡 High | **`filter-branch`** | Rewrite branch history. Complex, rarely used in modern git (superseded by filter-repo). `cli/filter_repo.zig` exists as basic stub. | — |
| 2 | ⚪ Low | **`instaweb` / `web--browse`** | Launch web browser for gitweb. UI helper, not core Git functionality. | — |
| 3 | ⚪ Low | **`quiltimport`** | Import quilt patch series into Git. Niche workflow tool. | — |
| 4 | ⚪ Low | **`send-email`** | Format and send patches via email (SMTP). Mailing-list workflow tool. | — |
| 5 | ⚪ Low | **`request-pull`** | Generate pull request summary text. Niche — most users use GitHub/GitLab PRs instead. | — |

---

## 2. Git Compatibility Assessment

| Category | Coverage | Status |
|----------|----------|--------|
| **Porcelain commands** (user-facing) | ~82% | init, clone, add, commit, log, diff, status, branch, checkout, stash, tag, merge, rebase, reset, push, pull, fetch, remote, cherry-pick, revert, show, notes, bundle, blame, bisect, describe, fsck, format-patch, archive work |
| **Plumbing commands** (low-level) | ~78% | cat-file, hash-object, ls-files, ls-tree, show-ref, for-each-ref, rev-parse, write-tree, commit-tree, update-index, rev-list, name-rev, verify-tag, rm, am work. Missing: filter-branch |
| **Network operations** | ~60% | fetch, push, ls-remote, clone over HTTP/smart protocol. SSH delegates to shell. Pack receive/send with delta resolution. Missing: sideband-64k demux |
| **Object storage** | ~85% | Loose objects read/write, pack file parsing, zlib compress/decompress, SHA-1/SHA-256, delta resolution (main path), thin pack detection |
| **Index/staging** | ~85% | Index read/write/parse/serialize, stage add/rm/move/reset, tree cache, checksums, extensions |
| **Merge/conflict** | ~70% | Three-way merge (LCS diff3), fast-forward, conflict markers, abort/continue, rerere |
| **History traversal** | ~70% | Log formatting (6 formats), date parsing (7 formats), pretty-print (4 styles), rev-list, show-ref, for-each-ref, rev-parse |
| **Overall compatibility** | **~74%** | Daily workflows fully functional. Advanced/niche commands (filter-branch) missing. Some features shell out to system `git`. Integration and fuzz test suites in place. |

---

## 3. Release v0.2.12 Checklist

> Prerequisites for v0.2.12 release.

### Should Have (�)

- [x] **Implement `filter-branch`** — complete `cli/filter_repo.zig` from basic stub to functional history rewriting
  - File: `src/cli/filter_repo.zig`
  - Milestone: `filter-branch --subdirectory-filter <dir> <branch>` end-to-end roundtrip

### Won't Have (deferred to v0.3.0+)

- `instaweb`, `quiltimport`, `send-email`, `request-pull` — niche workflows
- Native SSH (libssh2) — shell-out approach is pragmatic
- Full GPG signature verification in `verify-tag`
- `sideband-64k demux` in network protocol

---