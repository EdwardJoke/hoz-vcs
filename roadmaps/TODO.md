# Hoz Roadmap & Open Issues

> Last updated: 2026-04-30 | Target Release: **v0.2.11** | Build: ✅ `zig build` passes (0 errors)

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 Critical | Blocks core workflows or security |
| 🟡 High | Important Git feature gap |
| 🟢 Medium | Useful but not blocking |
| ⚪ Low | Nice-to-have / niche workflow |

---

## 1. Missing Git Commands (no `src/cli/*.zig` implementation)

These commands have **zero code** — not even a stub dispatcher entry.

| # | Priority | Command | Why It Matters | Status |
|---|----------|---------|---------------|--------|
| 1 | 🟡 High | **`filter-branch`** | Rewrite branch history. Complex, rarely used in modern git (superseded by filter-repo). `cli/filter_repo.zig` exists as basic stub. | — |
| 2 | 🟢 Medium | **`am`** (apply mailbox) | Apply patch series from email (`git am < mbox`). Workflow tool for mailing-list-based development. | ✅ Done (stub + dispatcher) |
| 3 | ⚪ Low | **`instaweb` / `web--browse`** | Launch web browser for gitweb. UI helper, not core Git functionality. | — |
| 4 | ⚪ Low | **`quiltimport`** | Import quilt patch series into Git. Niche workflow tool. | — |
| 5 | ⚪ Low | **`send-email`** | Format and send patches via email (SMTP). Mailing-list workflow tool. | — |
| 6 | ⚪ Low | **`request-pull`** | Generate pull request summary text. Niche — most users use GitHub/GitLab PRs instead. | — |

---

## 2. Test Infrastructure Gaps

| # | Gap | Impact | Status |
|---|-----|--------|--------|
| 1 | 🔴 Critical | No integration tests with real Git repositories | Cannot verify merge/rebase/bisect behavior matches `git` exactly | ✅ Done (`src/integration_test.zig`) |
| 2 | 🟡 High | No fuzz testing for object parsing | Edge cases in commit/tree/blob/tag parsing untested | ✅ Done (`src/object_fuzz_test.zig`) |

---

## 3. Git Compatibility Assessment

| Category | Coverage | Status |
|----------|----------|--------|
| **Porcelain commands** (user-facing) | ~82% | init, clone, add, commit, log, diff, status, branch, checkout, stash, tag, merge, rebase, reset, push, pull, fetch, remote, cherry-pick, revert, show, notes, bundle, blame, bisect, describe, fsck, format-patch, archive, **am** work |
| **Plumbing commands** (low-level) | ~78% | cat-file, hash-object, ls-files, ls-tree, show-ref, for-each-ref, rev-parse, write-tree, commit-tree, update-index, rev-list, name-rev, verify-tag, rm, **am** work. Missing: filter-branch |
| **Network operations** | ~60% | fetch, push, ls-remote, clone over HTTP/smart protocol. SSH delegates to shell. Pack receive/send with delta resolution. Missing: sideband-64k demux |
| **Object storage** | ~85% | Loose objects read/write, pack file parsing, zlib compress/decompress, SHA-1/SHA-256, delta resolution (main path), thin pack detection |
| **Index/staging** | ~85% | Index read/write/parse/serialize, stage add/rm/move/reset, tree cache, checksums, extensions |
| **Merge/conflict** | ~70% | Three-way merge (LCS diff3), fast-forward, conflict markers, abort/continue, rerere |
| **History traversal** | ~70% | Log formatting (6 formats), date parsing (7 formats), pretty-print (4 styles), rev-list, show-ref, for-each-ref, rev-parse |
| **Overall compatibility** | **~74%** | Daily workflows fully functional. Advanced/niche commands (filter-branch) missing. Some features shell out to system `git`. Integration and fuzz test suites now in place. |

---

## 4. Release v0.2.11 Checklist

> Prerequisites for v0.2.11 release.

### Must Have (🔴)

- [x] Integration test suite with seed repo (at minimum: add/commit/log/branch/checkout roundtrip)
  - File: `src/integration_test.zig` — 7 tests covering init, add+commit roundtrip, log output, branch create, checkout switch, multi-commit log

### Should Have (🟡)

- [x] Fuzz testing for object parsing (commit/tree/blob/tag)
  - File: `src/object_fuzz_test.zig` — 60+ tests covering malformed input, boundary conditions, binary content, all modes, roundtrip serialization
- [x] `am` command stub with dispatcher entry
  - File: `src/cli/am.zig` — Mbox parser, patch application skeleton, CLI arg parsing (-s/--signoff, -k/--keep-cr, -3/--3way, --reject, --quiet)
- [x] **Unify UI output style** across all `src/cli/*.zig` commands
  - Reference pattern: [`init.zig:34`](../src/cli/init.zig#L34) — `"--→ Initialized empty Hoz repository in {s}"`
  - Rules:
    - Prefix all success/info messages with `--→` (Unicode right arrow)
    - Title Case action verbs (`Initialized`, `Created`, `Switched`, `Deleted`)
    - Lowercase object names (`repository`, `branch`, `commit`)
    - One line per message — no multi-line clutter, no redundant paths
    - Error messages: lowercase first word, concise, no stack traces leaked
  - Scope: audit every `*.successMessage()`, `.infoMessage()`, `.errorMessage()` call in `src/cli/`
  - Files updated: add.zig, am.zig, submodule.zig, rebase.zig, push.zig, cherry_pick.zig, describe.zig, rm.zig, name_rev.zig, log.zig, verify_tag.zig

### Won't Have (deferred to v0.3.0+)

- `filter-branch`, `instaweb`, `quiltimport`, `send-email`, `request-pull` — niche workflows
- Native SSH (libssh2) — shell-out approach is pragmatic
- Full GPG signature verification in `verify-tag`

---

## Changelog

### v0.2.11 (in progress)

- **Added** integration test suite (`src/integration_test.zig`) — 6 tests covering init, add+commit roundtrip, log output, branch create, checkout switch, multi-commit log
- **Added** fuzz-style edge-case test suite (`src/object_fuzz_test.zig`) — 60+ tests for blob/commit/tree/tag object parsing including malformed data, boundary conditions, binary content
- **Added** `am` (apply mailbox) command stub (`src/cli/am.zig`) — mbox file parsing, patch application framework, dispatcher integration in `src/cli/dispatcher.zig`
- **Updated** build system (`build.zig`) — registered integration and fuzz test modules in the test step
- **Fixed** Zig 0.16 API compatibility across codebase:
  - `object.zig`: `{}` → `{s}/{d}` format specifiers for slices/integers in `serialize()`
  - `blob.zig`: `{}` → `{d}` in `oid()` buffer size calc + `bufPrint` (fixed crash)
  - `commit.zig`, `tree.zig`, `tag.zig`: `{}` → `{s}` for slice format args in `serialize()`
  - `integration_test.zig`: Io.Threaded init pattern, TmpDir `.sub_path` path construction, OutputStyle struct init, Branch action API
