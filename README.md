# Hoz - Git-Compatible Version Control System

A full-featured Git implementation in Zig 0.16.0, built for type safety and performance.

## Features

- **Full Git Compatibility** - All major Git commands implemented
- **Modular Architecture** - Clean separation of concerns
- **Type-Safe** - Zig's safety guarantees throughout
- **Performance** - Optimized object database and diff engine

## Building

```bash
zig build
```

## Testing

```bash
zig build test
```

## Installation

```bash
zig build install
```

## Quick Start

```bash
hoz init
hoz add .
hoz commit -m "Initial commit"
```

## Commands

- `init`, `clone` - Repository creation
- `add`, `stage` - File staging
- `commit` - Recording changes
- `branch`, `checkout`, `switch` - Branching
- `merge`, `rebase` - Integration
- `stash` - Work in progress
- `log`, `blame`, `show` - History
- `diff`, `status` - Changes
- `fetch`, `push`, `pull` - Remote operations
- `tag` - Tagging

## Architecture

```
src/
├── object/    # Blob, tree, commit, tag objects
├── odb/       # Object database
├── ref/       # References and branches
├── index/     # Staging area
├── workdir/   # Working directory
├── diff/      # Diff engine
├── merge/     # Merge algorithms
├── network/   # Protocol handling
└── cli/       # Command interface
```

## Status

Phase 1 complete - Core infrastructure implemented.

## License

MIT