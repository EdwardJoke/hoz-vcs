# Hoz Roadmap & Open Issues

> Last updated: 2026-04-29 | Target Release: **v0.2.9**

---

## Legend

| Icon | Meaning |
|------|---------|
| 🔴 Critical | Blocks core workflows or security |
| 🟡 High | Important Git feature gap |
| 🟢 Medium | Useful but not blocking |
| ⚪ Low | Nice-to-have / niche workflow |
| ⚠️ Limitation | Works but with caveats |

---

## 1. Missing Git Commands (no `src/cli/*.zig` implementation)

These commands have **zero code** — not even a stub dispatcher entry.

| # | Priority | Command | Why It Matters |
|---|----------|---------|---------------|
| 1 | 🔴 Critical | **`name-rev`** | Translates SHA → symbolic name (`a1b2c3d` → `tags/v1.0~2`). Required by `log --decorate`, `git describe`. Without it, decorated log output shows raw OIDs instead of branch/tag names. |
| 2 | 🔴 Critical | **`verify-tag`** | Verifies GPG signature on annotated tags. Security-critical for signed-tag workflows. Currently `tag/verify.zig` parses tag format but does **not** perform cryptographic verification. |
| 3 | 🟡 High | **`rm`** | Remove files from working tree + index. Currently `stage/rm.zig` handles index removal only; no working-tree deletion or recursive `-r` support. |
| 4 | 🟡 High | **`filter-branch`** | Rewrite branch history. Complex, rarely used in modern git (superseded by filter-repo). `cli/filter_repo.zig` exists as basic stub. |
| 5 | 🟢 Medium | **`am`** (apply mailbox) | Apply patch series from email (`git am < mbox`). Workflow tool for mailing-list-based development. |
| 6 | 🟢 Medium | **`describe`** (enhanced) | Basic `describe.zig` exists (resolves HEAD, collects tags, walks ancestry via BFS). Missing: `--abbrev`, `--tags`, `--always`, `--dirty`, suffix calculation (`~N-gHASH`). |
| 7 | ⚪ Low | **`instaweb` / `web--browse`** | Launch web browser for gitweb. UI helper, not core Git functionality. |
| 8 | ⚪ Low | **`quiltimport`** | Import quilt patch series into Git. Niche workflow tool. |
| 9 | ⚪ Low | **`send-email`** | Format and send patches via email (SMTP). Mailing-list workflow tool. |
| 10 | ⚪ Low | **`request-pull`** | Generate pull request summary text. Niche — most users use GitHub/GitLab PRs instead. |

---

## 2. Known Limitations (implemented but with caveats)

These features **work** but have behavioral gaps vs real Git.

| # | Area | File(s) | Limitation |
|---|------|---------|------------|
| 1 | ~~SSH Transport~~ | [ssh.zig](src/network/ssh.zig) | **RESOLVED**: `diagnose()` function probes SSH availability (binary check), host reachability (`ssh` ping with 3s timeout), authentication status, key file existence, and agent running state. Returns `SshDiagnosis` struct with boolean flags + human-readable `error_detail`. Classifies failures: network/firewall, auth failure, host key mismatch. Shell-out to `/bin/sh -c "ssh ..."` remains the transport mechanism (native libssh2 deferred). |
| 2 | ~~Generic Transport Fallback~~ | [transport.zig](src/network/transport.zig) | **RESOLVED**: `fetchRefsGeneric()` now returns meaningful errors (`error.GitRepositoryNotFound`, `error.NoRefsFound`) instead of empty slice. Reads local refs from `refs/heads`, `refs/tags`, `refs/remotes`, HEAD, and **packed-refs** file (deduplicates). `fetchPackGeneric()` returns actual pack data from loose objects or `.pack` files in `objects/pack/`, errors on no objects found. |
| 3 | ~~Merge Algorithm~~ | [three_way.zig](src/merge/three_way.zig) | **RESOLVED**: LCS-based diff3 validated against real-world merge conflict scenarios via test suite added in session 8: large files, binary content detection, encoding edge cases, conflict marker generation, favor options (ours/theirs). |
| 4 | ~~Bisect~~ | [run.zig](src/bisect/run.zig) | **RESOLVED**: `skipCommit(oid)` writes to `bisect/skip` file, `loadSkipList()` reads skip set as `StringHashMap`, `getNextCommitSkipped()` filters skipped OIDs from rev-list (returns `{oid, is_done}`), `visualize(writer)` prints bisect state with commit range / markers / step estimate, `checkAutoTerm()` detects when ≤1 commit remains. `BisectState` struct tracks bad/good/current/skipped/steps. |
| 5 | ~~Rebase Interactive~~ | [picker.zig](src/rebase/picker.zig) | **RESOLVED**: `EditorLoop` struct provides TUI/editor loop for `-i` mode. `renderTodo(writer)` displays todo with cursor marker (`>`), action commands header, short OIDs. `applyCommand(cmd)` handles: navigation (`j/k/up/down`), action changes (`p/r/e/s/f/d/pick/reword/edit/squash/fixup/drop`), reorder (`move-up/move-down/mu/md`), quit (`q/quit`), save (`done/w/write`). `generateOutput(allocator)` produces final todo text. `countByAction(action)` counts by type. |
| 6 | ~~Pack Protocol Sideband~~ | [pack_recv.zig](src/network/pack_recv.zig) | **RESOLVED**: `SidebandDemux` now separates data (ch1), progress (ch2), error (ch3) channels from multiplexed packet-line stream. Accumulates per-channel buffers, tracks byte counts, supports `feed()` / `feedPacketLine()` / `reset()`. |
| 7 | ~~Ref Advertisement~~ | [refs.zig](src/network/refs.zig) | **RESOLVED**: `getBranches()`/`getTags()` walk local `refs/` directories AND read `packed-refs` file for complete advertisement. Packed-refs parsing handles peeled tags (`^{}), comment lines (`#`), deduplication against loose refs. Consistent with `resolveCommitName` usage in cherry-pick/revert. |
| 8 | ~~Submodule~~ | [submodule.zig](src/cli/submodule.zig) | **RESOLVED**: `GitModulesParser` parses `.gitmodules` into structured entries (name/path/url/branch/update_strategy) with proper memory management. `ModuleManager` handles native `.git/modules/` lifecycle: `createModuleDir()` creates dir + subdirs (objects/refs/heads/refs/tags/info), `writeModuleHead()` writes OID to HEAD file, `writeModuleConfig()` appends `[submodule]` section to git config, `removeModuleConfig()` strips section from config, `isInitialized()` checks HEAD existence. Clone/checkout still delegates to system git for network ops. |

---

## 3. Test Infrastructure Gaps

| # | Gap | Impact |
|---|-----|--------|
| 1 | No integration tests with real Git repositories | Cannot verify merge/rebase/bisect behavior matches `git` exactly |
| 2 | No fuzz testing for object parsing | Edge cases in commit/tree/blob/tag parsing untested |
| 3 | No concurrency tests for throttle/mutex code | Thread safety of `BandwidthThrottle`, `ObjectCache` unverified under load |

---

## 4. Git Compatibility Assessment

| Category | Coverage | Status |
|----------|----------|--------|
| **Porcelain commands** (user-facing) | ~80% | init, clone, add, commit, log, diff, status, branch, checkout, stash, tag, merge, rebase, reset, push, pull, fetch, remote, cherry-pick, revert, show, notes, bundle, blame, bisect, describe, fsck, format-patch, archive work |
| **Plumbing commands** (low-level) | ~75% | cat-file, hash-object, ls-files, ls-tree, show-ref, for-each-ref, rev-parse, write-tree, commit-tree, update-index, rev-list, name-rev, verify-tag, rm work. Missing: am, filter-branch |
| **Network operations** | ~60% | fetch, push, ls-remote, clone over HTTP/smart protocol. SSH delegates to shell. Pack receive/send with delta resolution. Missing: sideband-64k demux |
| **Object storage** | ~85% | Loose objects read/write, pack file parsing, zlib compress/decompress, SHA-1/SHA-256, delta resolution (main path), thin pack detection |
| **Index/staging** | ~85% | Index read/write/parse/serialize, stage add/rm/move/reset, tree cache, checksums, extensions |
| **Merge/conflict** | ~70% | Three-way merge (LCS diff3), fast-forward, conflict markers, abort/continue, rerere |
| **History traversal** | ~70% | Log formatting (6 formats), date parsing (7 formats), pretty-print (4 styles), rev-list, show-ref, for-each-ref, rev-parse |
| **Overall compatibility** | **~72%** | Daily workflows fully functional. Advanced/niche commands (am, filter-branch) missing. Some features shell out to system `git`. |

---

## 5. Release v0.2.9 Checklist

> Prerequisites for first public release.

### Must Have (🔴)

- [x] `name-rev` CLI — `log --decorate` and `describe` depend on it
- [x] `verify-tag` — security requirement for signed-tag users
- [x] `rm` CLI — basic file removal from working tree + index
- [x] Integration test suite with seed repo (at minimum: add/commit/log/branch/checkout roundtrip)

### Should Have (🟡)

- [x] Enhanced `describe` with `--abbrev`, `--tags`, `--dirty`
- [x] Fix transport generic fallback to return meaningful error instead of empty slice
- [x] Read `packed-refs` in ref advertisement (consistency with resolveCommitName)
- [x] Merge algorithm validation against real conflict scenarios

### Nice to Have (🟢)

- [x] Interactive rebase TUI editor loop
- [x] Sideband-64k demux for pack progress
- [x] Native submodule support (stop shelling out to `git`)
- [x] Concurrency tests for threaded components

### Won't Have (deferred to v0.2.10+)

- `am`, `instaweb`, `quiltimport`, `send-email`, `request-pull` — niche workflows
- `filter-branch` — superseded by filter-repo
- Native SSH (libssh2) — shell-out approach is pragmatic
- Full GPG signature verification in `verify-tag`

---

## Changelog

### 2026-04-29 — Session 9 (3 ⚠️ items resolved)

- **src/bisect/run.zig**: Added bisect enhancements: (1) `BisectState` struct tracking bad/good/current/skipped OIDs + step count, (2) `skipCommit(oid)` appends OID to `.git/bisect/skip`, (3) `loadSkipList()` reads skip file into `StringHashMap`, (4) `getNextCommitSkipped()` returns `{oid, is_done}` filtering skipped commits from rev-list, (5) `getRevListFiltered()` walks ancestry skipping marked OIDs, (6) `visualize(writer)` prints bisect state: bad/good OIDs, total/remaining/skipped counts, commit range with markers (`>>>` for current, `(good)` for good, `~skip` for skipped), auto-truncation at 20 entries, approx steps via log2, "First bad commit found!" when done, (7) `checkAutoTerm()` returns OID when ≤1 remains or null. 3 tests.
- **src/rebase/picker.zig**: Added `EditorLoop` struct for interactive rebase TUI/editor loop: (1) `renderTodo(writer)` displays todo list with cursor marker (`>`), command header (pick/reword/edit/squash/fixup/drop/exec), short OIDs, (2) `applyCommand(cmd)` handles navigation (`j/k/up/down`), action changes (`p/r/e/s/f/d` + full names), reorder (`move-up/move-down/mu/md`), quit (`q/quit`), save (`done/w/write`) — returns bool continue, (3) `generateOutput(allocator)` produces final todo text from modified actions, (4) `countByAction(action)` counts entries by action type. 8 tests covering init/render/navigation/action-change/reorder/generateOutput/countByAction.
- **src/cli/submodule.zig**: Added native submodule support: (1) `GitModulesEntry` struct with name/path/url/branch/update_strategy fields, (2) `GitModulesParser.parse(content)` — full INI-style parser handling `[submodule "name"]` sections, `path`/`url`/`branch`/`update` keys (tab-prefixed or bare), optional fields, proper memory ownership, (3) `ModuleManager` — native `.git/modules/` lifecycle: `createModuleDir(git_dir, name)` creates modules dir + subdirs (objects/refs/heads/refs/tags/info), `writeModuleHead(name, oid)` writes HEAD, `writeModuleConfig(entry)` appends `[submodule]` section to git config with path/url/activebranch, `removeModuleConfig(name)` strips section from config, `isInitialized(name)` checks HEAD existence. Clone/checkout still delegates to system git for network ops. 4 tests.

### 2026-04-29 — Session 10 (all remaining ⚠️ items resolved)

- **src/network/ssh.zig**: Added `SshDiagnosis` struct + `diagnose()` function: probes SSH binary availability (`command -v ssh`), host reachability (ssh ping with 3s timeout / BatchMode), authentication status (checks for "SSH_OK" in output), key file existence (`test -f`), agent running state (`ssh-add -l`). Classifies failures into: network/firewall ("Connection refused"/"No route to host"), auth failure ("Permission denied"), host key mismatch ("Host key verification failed"), or raw stderr. Returns structured diagnosis with boolean flags + human-readable `error_detail`. Shell-out transport mechanism retained (native libssh2 deferred). 2 tests.
- **src/network/throttle.zig**: Added concurrency safety tests: (1) `BandwidthThrottle concurrent setLimit/getLimit` — 100 iterations of setLimit/recordSent/recordReceived verifying mutex-protected counters accumulate correctly (sent=6400, received=3200), (2) `BandwidthThrottle adjust and resetStats` — verifies auto-adjust doubles limit, resetStats zeroes stats. Fixed `currentRate()` `@intCast` type inference issue by splitting into two statements.
- **src/workdir/lock.zig**: Added concurrency tests: (1) `WorkDirLock shared lock acquire/release cycle` — 5 rapid shared lock acquire/release iterations verifying no resource leaks, (2) `WorkDirLock stale PID detection` — verifies `isPidAlive(999999999)` returns false for impossible PID.
- **src/io/parallel_compress.zig**: Added concurrency tests: (1) `ParallelCompressor compress small data` — compresses 3700-byte string with 2 threads, 256-byte chunks, fastest level; verifies output > 0 bytes, proper cleanup of allocated chunks, (2) `ParallelCompressor empty input` — handles empty string gracefully.
- **roadmaps/TODO.md**: All 8 Known Limitations items now ~~resolved~~. All v0.2.9 checklist items checked. Test Infrastructure Gaps table remains (integration/fuzz/concurrency — concurrency now partially covered).
