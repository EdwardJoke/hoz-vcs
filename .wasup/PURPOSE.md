# Project Purpose

## What
Refactor duplicate code across the Hoz codebase by extracting repeated patterns into shared reusable components, reducing maintenance burden and eliminating copy-paste drift risk.

## Why
v0.3.2 fixed all test failures but left significant structural debt: **7 categories of duplicated code** totaling ~1140+ redundant lines spread across 50+ files. The most critical issues:
- **`readObject()` copied 25+ times** — same OID→path→read→decompress logic in CLI commands, reset, stash, blame, describe, checkout, clean modules. A bug fix here requires touching 25+ files.
- **`resolveHead()` copied 8+ times** — `commit/head.zig` already has a proper implementation but nobody imports it; each copy has slightly different error handling.
- **`makeMockCommit()` duplicated** in both merge test files (fast_forward.zig + analyze.zig) with identical ~15-line function bodies.
- **GitCompatTester's 16 `run*()` methods** in compat.zig are nearly identical boilerplate (~400+ lines) differing only in which git/hoz commands they run.
- **Empty tree pattern repeated 4x** inside commit.zig's single `writeTree()` function.
- **`writeLooseObject()` duplicated** between commit.zig and filter_repo.zig.
- Without shared components, every bug fix or behavior change risks inconsistent fixes across copies.

## Success Criteria
- [ ] `readObject()` consolidated into a single shared location (e.g., `object/io.zig` or enhanced `object/reader.zig`), all 25+ call sites updated to use it
- [ ] `resolveHead()` consolidated via reusing existing `commit/head.zig`, all 8+ inline copies replaced with import
- [ ] `makeMockCommit()` extracted to shared test helper (e.g., `src/testing/mock.zig`), both merge test files updated to import it
- [ ] GitCompatTester refactored with generic `runPairTest()` helper eliminating ~300+ lines of boilerplate from 16 run* methods
- [ ] Empty tree creation extracted as a helper method inside commit.zig, removing 4 duplicate blocks
- [ ] `writeLooseObject()` unified into one shared implementation, filter_repo.zig and commit.zig both delegate to it
- [ ] All existing tests still pass after refactoring (zero regressions)
- [ ] Net reduction of at least 600 lines of redundant code
