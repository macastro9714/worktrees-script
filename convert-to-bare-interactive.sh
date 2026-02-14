#!/bin/bash

# Interactive script to safely convert a repo to bare with worktrees
# Usage: ./convert-to-bare-interactive.sh [--all] [repo-path]
#   repo-path: Path to the repo (default: current directory)
#   --all:     Execute all steps without confirmation

set -e

# Parse arguments
EXECUTE_ALL="false"
REPO_PATH="$PWD"

if [ "$1" = "--help" ] || [ "$1" = "-h" ]; then
    echo "Usage: ./convert-to-bare-interactive.sh [--all] [repo-path]"
    echo ""
    echo "Arguments:"
    echo "  repo-path  Path to the git repository (default: current directory)"
    echo "  --all      Execute all steps without confirmation"
    echo "  --help, -h Show this help message"
    echo ""
    echo "Examples:"
    echo "  ./convert-to-bare-interactive.sh                    # Interactive, current directory"
    echo "  ./convert-to-bare-interactive.sh --all              # Non-interactive, current directory"
    echo "  ./convert-to-bare-interactive.sh /path/to/repo      # Interactive, specific path"
    echo "  ./convert-to-bare-interactive.sh --all /path/to/repo # Non-interactive, specific path"
    exit 0
fi

while [[ $# -gt 0 ]]; do
    case $1 in
        --all)
            EXECUTE_ALL="true"
            shift
            ;;
        *)
            REPO_PATH="$1"
            shift
            ;;
    esac
done

if [ "$EXECUTE_ALL" = "true" ]; then
    echo -e "${YELLOW}Running in non-interactive mode (execute all steps)${NC}"
fi

# Convert to absolute path
REPO_PATH=$(cd "$REPO_PATH" && pwd)
REPO_NAME=$(basename "$REPO_PATH")
REPO_DIR=$(dirname "$REPO_PATH")

BACKUP_NAME="${REPO_NAME}-backup-$(date +%Y%m%d)"
OLD_NAME="${REPO_NAME}-old"
NEW_NAME="${REPO_NAME}"  # Use same name for final repo
TMP_NAME="${REPO_NAME}-tmp"
TMP_DIR=".tmp-local"
LOCAL_REF_DIR=".local-ref"  # Final name for local files directory
WORKTREES_DIR="worktrees"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

print_step() {
    echo -e "${BLUE}--- Step $1: $2 ---${NC}"
}

print_success() {
    echo -e "${GREEN}✓ $1${NC}"
}

print_warning() {
    echo -e "${YELLOW}⚠ $1${NC}"
}

confirm() {
    if [ "$EXECUTE_ALL" = "true" ]; then
        return 0
    fi
    read -p "$1 (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

skip_step() {
    if [ "$EXECUTE_ALL" = "true" ]; then
        return 1
    fi
    read -p "$1 (y/n): " -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

check_prerequisites() {
    if [ ! -d "$REPO_PATH/.git" ]; then
        echo -e "${RED}Error: Not a git repository: $REPO_PATH${NC}"
        exit 1
    fi

    if [ -d "$REPO_DIR/$BACKUP_NAME" ]; then
        echo -e "${RED}Error: Backup directory '$BACKUP_NAME' already exists in $REPO_DIR${NC}"
        exit 1
    fi

    if [ -d "$REPO_DIR/$OLD_NAME" ]; then
        echo -e "${RED}Error: Old repo directory '$OLD_NAME' already exists in $REPO_DIR${NC}"
        exit 1
    fi

    if [ -d "$REPO_DIR/$TMP_NAME" ]; then
        echo -e "${RED}Error: Temp repo directory already exists in $REPO_DIR${NC}"
        exit 1
    fi
}

# Parse flags was already done above

echo -e "${BLUE}=== Bare Repo Conversion Script ===${NC}"
echo -e "Repo: $REPO_PATH"
echo ""

check_prerequisites

# ============================================================================
# WARNING: Check for uncommitted/pushed changes
# ============================================================================
UNPUSHED_COMMITS=$(cd "$REPO_PATH" && git log --branches --not --remotes --oneline 2>/dev/null || echo "")
UNSTAGED_CHANGES=$(cd "$REPO_PATH" && git diff --name-only 2>/dev/null || echo "")
STAGED_CHANGES=$(cd "$REPO_PATH" && git diff --cached --name-only 2>/dev/null || echo "")

if [ -n "$UNPUSHED_COMMITS" ] || [ -n "$UNSTAGED_CHANGES" ] || [ -n "$STAGED_CHANGES" ]; then
    print_warning "WARNING: You have changes not pushed to GitHub!"
    echo ""
    [ -n "$UNPUSHED_COMMITS" ] && echo "  Unpushed commits:" && echo "$UNPUSHED_COMMITS" | head -5
    [ -n "$UNSTAGED_CHANGES" ] && echo "  Unstaged files:" && echo "$UNSTAGED_CHANGES" | head -5
    [ -n "$STAGED_CHANGES" ] && echo "  Staged files:" && echo "$STAGED_CHANGES" | head -5
    echo ""
    echo -e "${YELLOW}These changes will be LOST if the backup is deleted!${NC}"
    echo ""
    if ! confirm "Continue anyway?"; then
        echo "Aborting. Please commit and push your changes first."
        exit 1
    fi
fi

# ============================================================================
# STEP 1: Create backup copy
# ============================================================================
print_step 1 "Create backup copy"

if skip_step "Skip backup creation?"; then
    echo "Skipping backup"
else
    echo "Creating backup: $REPO_DIR/$BACKUP_NAME"
    cd "$REPO_DIR"
    cp -r "$REPO_NAME" "$BACKUP_NAME"
    print_success "Backup created"
fi

# ============================================================================
# STEP 2: Get local files
# ============================================================================
print_step 2 "Get local/ignored files"

EXCLUDE_PATTERNS=(
    "node_modules/"
    ".next/"
    "dist/"
    "build/"
    ".tsbuildinfo"
    "next-env.d.ts"
    ".cache/"
    "coverage/"
    ".vercel/"
    ".DS_Store"
)

echo "Finding user-specific local files..."

cd "$REPO_PATH"

# Get git-tracked status first
GIT_STATUS=$(git status --porcelain 2>/dev/null || echo "")
if [ -n "$GIT_STATUS" ]; then
    echo -e "${RED}Warning: Git working tree has changes!${NC}"
    if ! confirm "Continue anyway? (Changes may be lost)"; then
        echo "Aborting"
        exit 1
    fi
fi

IGNORED=$(git ls-files --others --ignored --exclude-standard | grep -v "^$TMP_DIR/" || true)

PRESERVE_COUNT=0
if [ -n "$IGNORED" ]; then
    mkdir -p "$TMP_DIR"
    echo "Finding files to preserve..."
    echo "$IGNORED" | while read -r file; do
        if [ -n "$file" ]; then
            SKIP=0
            for pattern in "${EXCLUDE_PATTERNS[@]}"; do
                if [[ "$file" == *"$pattern"* ]]; then
                    SKIP=1
                    break
                fi
            done
            if [ "$SKIP" -eq 0 ] && [ -e "$file" ]; then
                mkdir -p "$TMP_DIR/$(dirname "$file")"
                cp -r "$file" "$TMP_DIR/$file"
                echo "  - $file"
                ((PRESERVE_COUNT++)) || true
            fi
        fi
    done
fi

if [ -d "$TMP_DIR" ] && [ "$(ls -A "$TMP_DIR" 2>/dev/null)" ]; then
    print_success "Local files preserved to $TMP_DIR/"
else
    echo "No local files to preserve"
fi

# ============================================================================
# STEP 3: Rename current repo
# ============================================================================
print_step 3 "Rename current repo to '$OLD_NAME'"

RENAME_SKIPPED="false"
if skip_step "Skip renaming repo?"; then
    echo "Skipping rename"
    RENAME_SKIPPED="true"
else
    cd "$REPO_DIR"
    mv "$REPO_NAME" "$OLD_NAME"
    print_success "Renamed to $OLD_NAME"
    cd "$OLD_NAME"
fi

# Determine the name for the new bare repo
# If original name is still available (rename was skipped), use it directly
# Otherwise, use the -tmp suffix
if [ -d "$REPO_DIR/$REPO_NAME" ]; then
    # Original name still exists, need to use -tmp suffix
    BARE_REPO_NAME="$TMP_NAME"
    echo ""
    echo -e "${YELLOW}Original repo name still in use, will create bare repo as '$TMP_NAME'${NC}"
else
    # Original name is available, use it directly
    BARE_REPO_NAME="$REPO_NAME"
    echo ""
    echo -e "${GREEN}Original repo name available, will create bare repo as '$REPO_NAME'${NC}"
fi

# ============================================================================
# STEP 4: Clone new bare repo
# ============================================================================
print_step 4 "Create new bare repo"

if skip_step "Skip creating new bare repo?"; then
    echo "Skipping bare repo creation"
    cd "$REPO_DIR/$BARE_REPO_NAME"
else
    cd "$REPO_DIR"
    
    # Determine source for clone (either old repo or current repo if rename was skipped)
    if [ "$RENAME_SKIPPED" = "true" ]; then
        CLONE_SOURCE="$REPO_NAME"
    else
        CLONE_SOURCE="$OLD_NAME"
    fi
    
    # Get the original remote URL before cloning
    ORIGINAL_REMOTE_URL=$(cd "$CLONE_SOURCE" && git remote get-url origin 2>/dev/null || echo "")
    
    mkdir -p "$BARE_REPO_NAME/.git"
    git clone --bare "$CLONE_SOURCE" "$BARE_REPO_NAME/.git"
    cd "$BARE_REPO_NAME"
    
    # Fix the remote URL (clone from local dir sets origin to local path)
    if [ -n "$ORIGINAL_REMOTE_URL" ]; then
        git --git-dir=.git remote set-url origin "$ORIGINAL_REMOTE_URL"
        echo "Fixed remote origin to: $ORIGINAL_REMOTE_URL"
        
        # Set up fetch refspec and fetch all remote branches
        git --git-dir=.git config remote.origin.fetch "+refs/heads/*:refs/remotes/origin/*"
        git --git-dir=.git fetch origin
        echo "Fetched all remote branches"
    fi
    
    print_success "Bare repo created"
fi

# ============================================================================
# STEP 5: Move local files to new repo
# ============================================================================
print_step 5 "Move local files to new repo"

if skip_step "Skip moving local files?"; then
    echo "Skipping local files move"
else
    # Source depends on whether rename was skipped
    if [ "$RENAME_SKIPPED" = "true" ]; then
        LOCAL_FILES_SOURCE="$REPO_DIR/$REPO_NAME/$TMP_DIR"
    else
        LOCAL_FILES_SOURCE="$REPO_DIR/$OLD_NAME/$TMP_DIR"
    fi
    
    if [ -d "$LOCAL_FILES_SOURCE" ] && [ "$(ls -A "$LOCAL_FILES_SOURCE" 2>/dev/null)" ]; then
        cp -r "$LOCAL_FILES_SOURCE" .
        print_success "Local files moved"
    else
        echo "No local files to move"
    fi
fi

# ============================================================================
# STEP 6: Create worktrees directory and main worktree
# ============================================================================
print_step 6 "Create worktrees directory with main branch"

if skip_step "Skip worktrees setup?"; then
    echo "Skipping worktrees setup"
else
    cd "$REPO_DIR/$BARE_REPO_NAME"
    mkdir -p "$WORKTREES_DIR"
    git worktree add "$WORKTREES_DIR/main" main
    # Set upstream tracking for main branch
    cd "$WORKTREES_DIR/main" && git branch --set-upstream-to=origin/main main
    cd "$REPO_DIR/$BARE_REPO_NAME"
    print_success "Main worktree created: $WORKTREES_DIR/main"
fi

# ============================================================================
# STEP 7: Copy local files to main worktree
# ============================================================================
print_step 7 "Copy local files to main worktree"

if skip_step "Skip copying local files to worktree?"; then
    echo "Skipping local files copy"
else
    if [ -d "$REPO_DIR/$BARE_REPO_NAME/$TMP_DIR" ] && [ "$(ls -A "$REPO_DIR/$BARE_REPO_NAME/$TMP_DIR" 2>/dev/null)" ]; then
        echo "Copying local files to $WORKTREES_DIR/main..."
        cp -r "$REPO_DIR/$BARE_REPO_NAME/$TMP_DIR"/. "$REPO_DIR/$BARE_REPO_NAME/$WORKTREES_DIR/main/" 2>/dev/null || true
        print_success "Local files copied to worktree"
    else
        echo "No local files to copy"
    fi
fi

# ============================================================================
# STEP 8: Rename final repo and cleanup
# ============================================================================
print_step 8 "Final cleanup: delete old repo, rename if needed"

if skip_step "Skip cleanup?"; then
    echo "Skipping cleanup"
    if [ "$BARE_REPO_NAME" != "$REPO_NAME" ]; then
        echo -e "${YELLOW}Note: Manually delete '$REPO_DIR/$OLD_NAME' (if exists) and rename '$REPO_DIR/$BARE_REPO_NAME' to '$REPO_NAME' when ready${NC}"
        echo -e "${YELLOW}Note: Update worktree gitdir paths in .git/worktrees/*/gitdir after renaming${NC}"
    else
        echo -e "${YELLOW}Note: Manually delete '$REPO_DIR/$OLD_NAME' if it exists${NC}"
    fi
else
    cd "$REPO_DIR"
    
    # Delete old repo if it exists
    if [ -d "$OLD_NAME" ]; then
        rm -rf "$OLD_NAME"
        echo "Deleted $OLD_NAME"
    fi
    
    # Rename if needed (if we used -tmp suffix)
    if [ "$BARE_REPO_NAME" != "$REPO_NAME" ]; then
        mv "$BARE_REPO_NAME" "$REPO_NAME"
        cd "$REPO_NAME"
        # Fix worktree paths after rename
        if [ -d ".git/worktrees" ]; then
            for worktree_dir in .git/worktrees/*/; do
                if [ -d "$worktree_dir" ]; then
                    worktree_name=$(basename "$worktree_dir")
                    # Update gitdir path in .git/worktrees/<name>/gitdir
                    new_path="$PWD/$WORKTREES_DIR/$worktree_name/.git"
                    echo "$new_path" > "$worktree_dir/gitdir"
                    # Update gitdir path in worktree/.git file
                    if [ -f "$WORKTREES_DIR/$worktree_name/.git" ]; then
                        sed -i "s|$BARE_REPO_NAME|$REPO_NAME|g" "$WORKTREES_DIR/$worktree_name/.git"
                    fi
                fi
            done
        fi
        echo "Renamed $BARE_REPO_NAME to $REPO_NAME"
    else
        cd "$REPO_NAME"
        echo "No rename needed (already using correct name)"
    fi
    
    print_success "Cleanup complete"
fi

# ============================================================================
# STEP 9: Rename .tmp-local to .local-ref
# ============================================================================
print_step 9 "Rename $TMP_DIR to $LOCAL_REF_DIR"

if skip_step "Skip renaming local files directory?"; then
    echo "Skipping rename"
else
    # Determine the correct path (might be different if cleanup was skipped)
    if [ -d "$REPO_DIR/$REPO_NAME/$TMP_DIR" ]; then
        cd "$REPO_DIR/$REPO_NAME"
        mv "$TMP_DIR" "$LOCAL_REF_DIR"
        print_success "Renamed $TMP_DIR to $LOCAL_REF_DIR"
    elif [ -d "$REPO_DIR/$BARE_REPO_NAME/$TMP_DIR" ]; then
        cd "$REPO_DIR/$BARE_REPO_NAME"
        mv "$TMP_DIR" "$LOCAL_REF_DIR"
        print_success "Renamed $TMP_DIR to $LOCAL_REF_DIR"
        echo -e "${YELLOW}Note: Repo is still at $REPO_DIR/$BARE_REPO_NAME (cleanup was skipped)${NC}"
    else
        echo "No $TMP_DIR directory found"
    fi
fi

# ============================================================================
# STEP 10: Create WORKTREES.md reference file
# ============================================================================
print_step 10 "Create WORKTREES.md reference file"

if skip_step "Skip creating WORKTREES.md?"; then
    echo "Skipping WORKTREES.md creation"
else
    # Determine the correct path for the bare repo
    if [ -d "$REPO_DIR/$REPO_NAME/.git" ]; then
        BARE_REPO_PATH="$REPO_DIR/$REPO_NAME"
    elif [ -d "$REPO_DIR/$BARE_REPO_NAME/.git" ]; then
        BARE_REPO_PATH="$REPO_DIR/$BARE_REPO_NAME"
    else
        echo "Cannot find bare repo directory"
        BARE_REPO_PATH=""
    fi
    
    if [ -n "$BARE_REPO_PATH" ]; then
        cat > "$BARE_REPO_PATH/WORKTREES.md" << 'WORKTREES_EOF'
# Worktrees Guide

This repository uses Git worktrees for isolated development environments.

## What are Worktrees?

Worktrees allow you to have multiple working directories from the same Git repository. Each worktree is connected to the bare repo but has its own checked-out files. This lets you:

- Work on multiple branches simultaneously
- Keep your `main` worktree clean while developing features
- Avoid constantly switching branches and rebuilding

## Structure

```
repo/
├── .git/              ← Bare repo (shared git data)
├── .local-ref/        ← Local config files (copy to new worktrees)
└── worktrees/         ← All worktrees live here
    ├── main/          ← Main branch worktree
    ├── feature-x/     ← Feature branch worktree
    └── staging/       ← Staging branch worktree
```

## Common Commands

### Create a worktree for a NEW branch

```bash
# From the bare repo root
git --git-dir=.git worktree add worktrees/feature-name -b feature-name

# Copy local config files to the new worktree
cp -r .local-ref/. worktrees/feature-name/

# Navigate to the new worktree
cd worktrees/feature-name
```

### Create a worktree from an EXISTING branch

```bash
# From the bare repo root
git --git-dir=.git worktree add worktrees/staging staging

# Copy local config files to the new worktree
cp -r .local-ref/. worktrees/staging/

# Navigate to the new worktree
cd worktrees/staging
```

### List all worktrees

```bash
git --git-dir=.git worktree list
```

### Remove a worktree

```bash
# First, navigate to the worktree and make sure it's clean
cd worktrees/feature-name
git status

# Go back to bare repo root
cd ../..

# Remove the worktree (branch is NOT deleted)
git --git-dir=.git worktree remove worktrees/feature-name

# To also delete the branch
git --git-dir=.git branch -d feature-name
```

### Force remove a worktree (if dirty)

```bash
git --git-dir=.git worktree remove --force worktrees/feature-name
```

### Move a worktree

```bash
git --git-dir=.git worktree move worktrees/old-name worktrees/new-name
```

### Prune stale worktrees

```bash
# If you manually deleted a worktree directory, clean up references
git --git-dir=.git worktree prune
```

## Workflow Example

```bash
# 1. Start a new feature
git --git-dir=.git worktree add worktrees/add-login -b add-login
cp -r .local-ref/. worktrees/add-login/
cd worktrees/add-login

# 2. Do your work...
npm install
npm run dev
# ... make changes, commit, push ...

# 3. When done, go back to main
cd ../..

# 4. Clean up after merge
git --git-dir=.git worktree remove worktrees/add-login
git --git-dir=.git branch -d add-login
```

## Tips

- Always copy `.local-ref/` to new worktrees for local config (`.env.local`, `.husky/`, etc.)
- You can run `npm install` independently in each worktree
- Each worktree has its own `node_modules/` and build artifacts
- Use descriptive worktree names that match your branch names
- Clean up merged worktrees to keep things organized

## Keeping .local-ref/ Updated

When you update local config files in a worktree (e.g., add a new `.env` variable), sync them back to `.local-ref/` so new worktrees get the latest:

```bash
# From any worktree
wt-sync-ref
```

Or manually:
```bash
# Sync from current worktree to .local-ref/
cp .env.local ../.local-ref/
```

## Shell Functions (Optional)

Add these to your `~/.bashrc` or `~/.zshrc` for convenience:

```bash
# Helper: Get bare repo root path
_wt_root() {
  local git_dir=$(git rev-parse --git-common-dir 2>/dev/null)
  if [ "$git_dir" = ".git" ]; then
    pwd
  else
    echo "$git_dir" | sed 's|/\.git$||'
  fi
}

# Worktree shortcuts (run from bare repo root or any worktree)
wt-list() { git --git-dir=$(_wt_root)/.git worktree list; }
wt-add() { local r=$(_wt_root); git --git-dir=$r/.git worktree add $r/worktrees/$1 -b $1 && [ -d "$r/.local-ref" ] && cp -r $r/.local-ref/. $r/worktrees/$1/ || true; }
wt-add-existing() { local r=$(_wt_root); git --git-dir=$r/.git worktree add $r/worktrees/$1 $1 && [ -d "$r/.local-ref" ] && cp -r $r/.local-ref/. $r/worktrees/$1/ || true && cd $r/worktrees/$1 && git branch --set-upstream-to=origin/$1 $1 && cd -; }
wt-remove() { git --git-dir=$(_wt_root)/.git worktree remove $(_wt_root)/worktrees/$1; }
wt-rm-branch() { git --git-dir=$(_wt_root)/.git branch -d $1; }
wt-cd() { cd $(_wt_root)/worktrees/$1; }
wt-root() { cd $(_wt_root); }

# Sync local files from current worktree back to .local-ref/
wt-sync-ref() {
  local bare_root=$(_wt_root)
  local ref_dir="$bare_root/.local-ref"
  if [ ! -d "$ref_dir" ]; then
    echo "No .local-ref/ directory found"
    return 1
  fi
  local exclude_patterns=("node_modules/" ".next/" "dist/" "build/" ".tsbuildinfo" "next-env.d.ts" ".cache/" "coverage/" ".vercel/" ".DS_Store")
  git ls-files --others --ignored --exclude-standard | while read -r file; do
    local skip=0
    for pattern in "${exclude_patterns[@]}"; do
      [[ "$file" == *"$pattern"* ]] && skip=1 && break
    done
    if [ "$skip" -eq 0 ] && [ -e "$file" ]; then
      mkdir -p "$ref_dir/$(dirname "$file")"
      cp -r "$file" "$ref_dir/$file"
      echo "Synced: $file"
    fi
  done
  echo "Sync complete"
}
```

Usage:
```bash
wt-list                    # List all worktrees
wt-add feature-x           # Create new branch and worktree + copy local files
wt-add-existing staging    # Create worktree from existing branch + copy local files
wt-sync-ref                # Sync local files from current worktree to .local-ref/
wt-remove feature-x        # Remove a worktree
wt-rm-branch feature-x     # Delete a branch (after removing worktree)
wt-cd main                 # Go to specific worktree
wt-root                    # Go to bare repo root
```

Note: Functions work from bare repo root or any worktree.
WORKTREES_EOF
        
        print_success "WORKTREES.md created"
    fi
fi

echo ""
echo -e "${GREEN}=== Conversion Complete ===${NC}"
echo ""
echo "Structure:"
echo "  $REPO_DIR/$REPO_NAME/"
echo "    ├── .git/              ← Bare repo"
echo "    ├── .local-ref/        ← Local files (.env.local, etc.)"
echo "    ├── worktrees/         ← Worktrees"
echo "    │   └── main/          ← Main branch worktree (with working files)"
echo "    └── WORKTREES.md       ← Guide for using worktrees"
echo ""
echo "Backup: $REPO_DIR/$BACKUP_NAME"
echo ""
echo "To add new worktrees:"
echo "  cd $REPO_DIR/$REPO_NAME"
echo "  git --git-dir=.git worktree add worktrees/your-branch-name -b your-branch-name"
echo "  cp -r .local-ref/. worktrees/your-branch-name/"
echo ""
echo "See WORKTREES.md for detailed instructions."
