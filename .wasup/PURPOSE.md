# Project Purpose — v

## What
Fix systemic bug patterns discovered through deep codebase analysis: incorrect `openDirAbsolute` usage with relative paths, memory leaks in `object_mod.parse()` callers, and dead code left over from the zlib refactor.

## Why
Analysis of uncommitted fixes in `cli/log.zig` and `compress/zlib.zig` revealed three recurring bug patterns that exist throughout the codebase:

1. **`openDirAbsolute` with relative paths** — `openDirAbsolute` expects absolute paths, but 5 call sites pass `".git"` (relative). This is the same bug already fixed in `cli/log.zig`. The correct API is `cwd.openDir()` for relative paths. Found in `cli/commit.zig`, `cli/add.zig`, and `final/benchmark.zig`.

2. **Memory leak in `object_mod.parse()` callers** — `parse()` allocates `owned_data` via `allocator.alloc()` and returns it as `Object.data`, but callers across `stash/apply.zig`, `stash/pop.zig`, `reset/hard.zig`, `cli/revert.zig`, and others never free `obj.data`. Only the raw input buffer gets freed via `defer`. This is a widespread leak affecting every code path that parses Git objects.

3. **Dead code after zlib refactor** — The `Decompressor` struct in `deflate.zig` is now dead code in production (only used in its own tests) since `zlib.zig` switched to `std.compress.flate.Decompress`. Unused error variants (`ZlibError.InvalidChecksum`, `BadBlockType`, `CorruptData`, `DeflateError.UnsupportedFeature`) and redundant manual header validation remain.

These bugs cause incorrect directory resolution, memory leaks on every object parse, and code bloat from dead code.

## Success Criteria
- [ ] All `openDirAbsolute` calls with relative paths replaced with `cwd.openDir()` or absolute path construction
- [ ] All `object_mod.parse()` callers properly free `obj.data` after use
- [ ] Dead `Decompressor` struct and unused error variants removed
- [ ] Redundant manual zlib header validation removed (stdlib handles it)
- [ ] All existing tests pass after changes
