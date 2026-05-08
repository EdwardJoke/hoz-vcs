# Project Purpose — v0.4.0

## What
Upgrade the entire hoz codebase from Zig 0.15 to Zig 0.16 API compatibility, fixing all 60 compilation errors and 11 test failures to achieve a fully-passing build on Zig 0.16.0.

## Why
The project currently builds on Zig 0.16.0 but **60 compilation errors** and **11 test failures** remain when running the full test suite. The errors span 12 categories of breaking API changes between 0.15 → 0.16: Io system restructure (`Io.Threaded.new()` removed, `Io.init()` removed, `Io.Writer.interface` gone), std.fs reorganization (`fs.File` namespace), crypto module reshuffle (`crypto.hash.sha1` path changed), const-correctness tightening (DebugAllocator, RefStore), and OID type changes. Without this upgrade, the codebase is stuck on deprecated APIs that will only accumulate more tech debt.

## Success Criteria
- [ ] All 60 compilation errors resolved — `zig build test` compiles with 0 errors
- [ ] All 11 runtime test failures fixed — test suite passes at same or better rate than v0.3.5 baseline
- [ ] Build (`zig build`) continues to pass with zero errors
- [ ] No regressions in previously-passing 106 tests
- [ ] All Zig 0.16 API usage follows current std library conventions (no deprecated patterns)
