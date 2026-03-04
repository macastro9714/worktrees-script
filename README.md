# worktrees-script

A script to convert a normal Git repository into a bare repository with worktrees and local files management.

## Usage

```bash
./convert-to-bare-interactive.sh [--all] [repo-path]
```

### Arguments

| Argument       | Description                                                   |
| -------------- | ------------------------------------------------------------- |
| `repo-path`    | Path to the git repository (default: current directory)       |
| `--all`        | Execute all steps without confirmation (non-interactive mode) |
| `--help`, `-h` | Show help message                                             |

### Examples

```bash
# Interactive mode, current directory
./convert-to-bare-interactive.sh

# Non-interactive mode, current directory
./convert-to-bare-interactive.sh --all

# Interactive mode, specific path
./convert-to-bare-interactive.sh /path/to/repo

# Non-interactive mode, specific path
./convert-to-bare-interactive.sh --all /path/to/repo
```

## What the Script Does

The script performs the following steps:

1. **Create backup copy** - Creates a timestamped backup of the repository
2. **Get local/ignored files** - Preserves local files (`.env.local`, configs, etc.) excluding build artifacts
3. **Rename current repo** - Renames the repo to `<name>-old` temporarily
4. **Create new bare repo** - Clones a bare repository from the old repo
5. **Move local files** - Moves preserved local files to the new bare repo
6. **Create worktrees directory** - Sets up `worktrees/` with the core branch
7. **Copy local files to worktree** - Copies local files to the core worktree
8. **Final cleanup** - Deletes old repo, renames if needed, fixes worktree paths
9. **Rename local files directory** - Renames `.tmp-local` to `.local-ref`
10. **Create WORKTREES.md** - Generates a reference guide for using worktrees

### Core Branch Selection

In interactive mode, the script prompts you to select the primary branch:

- `main`
- `master`
- Custom branch name

In `--all` mode, `main` is assumed with a warning.

The selected branch is used throughout the conversion and is baked into the generated `WORKTREES.md` documentation and shell functions.

## Resulting Structure

```
repo/
├── .git/              ← Bare repo (shared git data)
├── .local-ref/        ← Local config files (copy to new worktrees)
├── worktrees/         ← All worktrees live here
│   └── <core-branch>/ ← Core branch worktree (with working files)
└── WORKTREES.md       ← Guide for using worktrees
```

## Preserved Files

The script preserves local/ignored files such as:

- `.env.local`, `.env.development.local`, etc.
- IDE configs
- Other git-ignored files

Files **excluded** from preservation (build artifacts):

- `node_modules/`
- `.next/`, `dist/`, `build/`
- `.cache/`, `coverage/`
- `.tsbuildinfo`, `next-env.d.ts`
- `.vercel/`, `.DS_Store`

## Warnings

- The script will warn you about uncommitted or unpushed changes
- A backup is created with the naming pattern `<repo>-backup-YYYYMMDD`
- Worktree paths are automatically fixed after any renaming

## After Conversion

The script generates a `WORKTREES.md` file with shell functions for convenient worktree management. Add these to your `~/.zshrc`:

### Shell Functions

| Function                  | Description                                                          |
| ------------------------- | -------------------------------------------------------------------- |
| `wt-list`                 | List all worktrees                                                   |
| `wt-add <name>`           | Create new branch from core, copy `.local-ref`, and cd into worktree |
| `wt-add-existing <name>`  | Create worktree from existing branch, copy `.local-ref`, cd into it  |
| `wt-remove <name>`        | Remove worktree (prompts to sync local files first)                  |
| `wt-remove --sync <name>` | Remove worktree, sync local files first (no prompt)                  |
| `wt-remove --no-sync <n>` | Remove worktree, skip sync (no prompt)                               |
| `wt-remove --force <n>`   | Force remove without prompts (handles dirty worktrees)               |
| `wt-rm-branch <name>`     | Delete a branch (after removing worktree)                            |
| `wt-cd <name>`            | Navigate to a specific worktree                                      |
| `wt-root`                 | Navigate to bare repo root                                           |
| `wt-sync-to-ref`          | Sync local files from current worktree to `.local-ref/`              |
| `wt-sync-from-ref`        | Copy local files from `.local-ref/` to current worktree              |

### Environment Variable

Set `WT_CORE_BRANCH` to your core branch name (defaults to `main`):

```bash
export WT_CORE_BRANCH="${WT_CORE_BRANCH:-main}"
```

### Quick Example

```bash
# 1. Start a new feature
wt-add add-login
# (creates branch from core, copies .local-ref, and cd's into it)

# 2. Do your work...
npm install
npm run dev
# ... make changes, commit, push ...

# 3. Clean up after merge
wt-remove add-login
wt-rm-branch add-login
```

See `WORKTREES.md` (generated by the script) for detailed worktree usage instructions.
