
<div align="center">

# Hoz - Git-Compatible Version Control System

![GitHub Stars](https://shieldcn.dev/github/stars/edwardjoke/hoz-vcs.svg?variant=branded) ![GitHub Forks](https://shieldcn.dev/github/forks/edwardjoke/hoz-vcs.svg?variant=branded) ![GitHub Release](https://shieldcn.dev/github/release/edwardjoke/hoz-vcs.svg?variant=branded)<br/>
![GitHub Last Commit](https://shieldcn.dev/github/last-commit/edwardjoke/hoz-vcs.svg?variant=outline) ![GitHub Open Issues](https://shieldcn.dev/github/open-issues/vercel/next.js.svg?variant=outline)<br/>
![Runs on Linux](https://shieldcn.dev/badge/Runs%20on-Linux-FCC624.svg?logo=linux&logoColor=000) ![Runs on MacOS](https://shieldcn.dev/badge/Runs%20on-MacOS-000000.svg?mode=light&logo=apple&logoColor=fff) ![Cross Platform](https://shieldcn.dev/badge/cross-platform-brightgreen.svg?variant=outline&logo=ri%3AGoDeviceDesktop)

*A full-featured Git implementation in Zig 0.16.0, *<br/>
*built for type safety and performance. *
Hoz is the next generation of Git-compatible version control with a clean, modern codebase.

</div>

## Why Hoz?

- **Git-Compatible** - Works with existing Git repositories and workflows
- **Type-Safe** - Written in Zig for memory safety and compile-time verification
- **Fast** - Optimized object database and efficient diff engine
- **Portable** - Runs anywhere Zig 0.16.0 is available

## Quick Start

> [!WARNING]  
> This project is in active development and now just a toy, please do not use it in production.

Initialize a new repository:

```bash
hoz init my-project
cd my-project
```

Stage and commit changes:

```bash
hoz add .
hoz commit -m "Initial commit"
```

## Common Commands

### Repository Operations
```bash
hoz init           # Create a new repository
hoz clone <url>    # Clone an existing repository
```

### Making Changes
```bash
hoz add <file>     # Stage files for commit
hoz commit -m ""   # Record staged changes
hoz status         # Show working tree status
hoz diff           # Show unstaged changes
```

### Branching
```bash
hoz branch                    # List branches
hoz branch <name>             # Create a branch
hoz checkout <branch>         # Switch branches
hoz merge <branch>            # Merge branches
```

### History & Inspection
```bash
hoz log           # View commit history
hoz show <ref>    # Show commit details
hoz blame <file>  # Show file annotations
hoz describe      # Describe commit using tags
hoz verify-tag    # Verify annotated tag signature
hoz name-rev      # Translate SHA to symbolic name
```

### File Operations
```bash
hoz add <file>     # Stage files for commit
hoz rm <file>      # Remove from working tree and index
```

### Remote Collaboration
```bash
hoz fetch         # Download objects from remote
hoz push          # Upload objects to remote
hoz pull          # Fetch and merge remote changes
```

## Project Status

Hoz is in active development. Core Git functionality is implemented including:
- Object database (blobs, trees, commits, tags)
- Reference management (branches, tags, HEAD)
- Staging area (index)
- Working directory operations
- Diff and merge algorithms

## Contributing

Contributions welcome. Please ensure `zig build test` passes before submitting changes.

## License

Apache License 2.0
