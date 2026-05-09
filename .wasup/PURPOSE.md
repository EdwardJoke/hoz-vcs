# Project Purpose — v0.4.1

## What
Fix all remaining runtime crashes and critical bugs in the hoz codebase following the Zig 0.16.0 migration, achieving zero test crashes and improved code quality.

## Why
The v0.4.0 migration resolved 60+ compilation errors but left **6 test crashes** and **38 failing tests** (87.7% pass rate). These remaining issues represent technical debt that undermines code quality, developer confidence in the test suite, and the reliability of the Zig 0.16.0 upgrade. Without addressing these crashes, the codebase remains fragile and difficult to maintain.

## Success Criteria
- [ ] All 6 test crashes eliminated — `zig build test` completes with zero panics/segfaults
- [ ] Test crash count reduced from 6 → 0 (100% reduction)
- [ ] No new regressions introduced — previously passing tests continue to pass
- [ ] Code quality improvements from fixing root causes (memory safety, type correctness)
