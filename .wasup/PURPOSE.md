# Project Purpose

## What
Standardize all CLI output formats across Hoz with consistent symbol-based nesting for improved readability by both AI tools and humans.

## Why
Current output formats across modules are inconsistent - some use plain text, others use ad-hoc formatting. Adding structured symbols (tree characters, icons, indentation markers) makes:
- **AI comprehension**: LLMs can parse nested structures reliably from symbol patterns
- **Human readability**: Visual hierarchy helps users quickly scan complex output (diffs, logs, trees, status)
- **Consistency**: Every subcommand follows the same visual language

## Success Criteria
- [ ] All CLI output modules use a unified symbol set for nesting/hierarchy
- [ ] Output is both machine-parseable (AI-friendly) and human-readable
- [ ] Existing tests pass with new formatted output
- [ ] Feature branch merged to `dev` (not master)
