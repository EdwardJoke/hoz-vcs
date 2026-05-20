# Project Purpose — v0.6.0

## What
Redesign hoz UX: toon format as default output, keyword highlighting, and clean usage descriptions across all commands.

## Why
Current output is functional but noisy. Tree symbols, inconsistent formatting, and verbose headers create visual clutter. The toon format (https://github.com/toon-format/toon) provides a clean, minimal, YAML-like output that's both human-readable and machine-parseable. Switching to toon as the default display format, adding keyword highlighting, and simplifying help text will make hoz feel modern and effortless to use.

## Success Criteria
- [ ] All commands output structured data (JSON internally), displayed as toon format by default
- [ ] Keyword highlighting: commit hashes, branch names, file statuses, refs rendered with color
- [ ] Clean usage descriptions — short, scannable help text without clutter
- [ ] Dead `util/format.zig` removed (already unused)
- [ ] All existing tests pass after changes
