# Project Purpose

## What
Fix all test failures (35 failing + 5 crashing + 11 leaks) and replace dummy/placeholder test code with production-ready tests across the Hoz codebase.

## Why
v0.3.1 introduced standardized CLI output formatting but left the test suite in a broken state:
- **77 pass, 35 fail, 5 crash, 11 leaks** out of 117 total tests
- Root causes: Identity.parse() whitespace handling bug, OID test data using invalid hex lengths, Object.parse() error type mismatches, Tree.parse() hardcoded allocator causing memory leaks, and stub/dummy test code that doesn't validate real behavior
- Without passing tests, v0.3.1's output formatting changes have no safety net against regressions

## Success Criteria
- [ ] All 117+ tests pass with zero failures, zero crashes, zero memory leaks
- [ ] Identity.parse() correctly handles whitespace in author/committer/tagger strings (root cause of commit/tag parse failures)
- [ ] OID tests use valid hex strings matching Zig 0.16 API contract
- [ ] Object.parse() error types match test expectations (or tests updated to match actual behavior)
- [ ] Tree.parse() accepts allocator parameter instead of hardcoding std.testing.allocator
- [ ] All dummyGetCommit stubs replaced with proper mock commit objects
- [ ] Placeholder tests (ReflogEntry format) replaced with real validation logic
