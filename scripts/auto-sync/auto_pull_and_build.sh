#!/usr/bin/env bash
# auto_pull_and_build.sh — リモートに未プルの変更があれば自動でpull & build
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_SCRIPT="$SCRIPT_DIR/../build_and_install.sh"
AUTO_PULL_SCRIPT="$SCRIPT_DIR/auto-pull.sh"
LOG_FILE="$HOME/.starfiler-auto-sync.log"

log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] [auto-pull-build] $*" | tee -a "$LOG_FILE"
}

notify() {
  osascript -e "display notification \"$1\" with title \"Starfiler Auto-Build\"" 2>/dev/null || true
}

cd "$REPO_DIR"

# Ensure we're on main branch
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
if [ "$CURRENT_BRANCH" != "main" ]; then
  log "SKIP: current branch is '$CURRENT_BRANCH', not 'main'"
  exit 0
fi

# rebase/merge in progress — skip
if [ -d ".git/rebase-merge" ] || [ -d ".git/rebase-apply" ] || [ -f ".git/MERGE_HEAD" ]; then
  log "SKIP: rebase or merge in progress"
  exit 0
fi

# Fetch from origin
if ! git fetch origin main 2>&1 | tee -a "$LOG_FILE"; then
  log "WARN: git fetch failed (network issue?)"
  exit 0
fi

# Compare local HEAD with remote
LOCAL_HEAD=$(git rev-parse HEAD 2>/dev/null)
REMOTE_HEAD=$(git rev-parse origin/main 2>/dev/null)

# Count new commits on remote that we don't have
NEW_COMMITS=$(git rev-list HEAD..origin/main --count 2>/dev/null || echo "0")

if [ "$LOCAL_HEAD" = "$REMOTE_HEAD" ] || [ "$NEW_COMMITS" = "0" ]; then
  # No new changes on remote — nothing to do
  exit 0
fi
log "INFO: $NEW_COMMITS new commit(s) detected on origin/main"

# Pull using existing auto-pull.sh (handles stash, conflicts, etc.)
log "INFO: Running auto-pull.sh..."
if ! bash "$AUTO_PULL_SCRIPT"; then
  log "ERROR: auto-pull.sh failed"
  notify "Auto-pull failed. Check log."
  exit 1
fi

# Verify pull actually succeeded
LOCAL_HEAD_AFTER=$(git rev-parse HEAD 2>/dev/null)
if [ "$LOCAL_HEAD_AFTER" = "$LOCAL_HEAD" ]; then
  log "WARN: HEAD unchanged after pull — skipping build"
  exit 0
fi

# Build and install
log "INFO: Running build_and_install.sh..."
notify "New changes pulled. Building..."
if bash "$BUILD_SCRIPT" --launch; then
  log "OK: Build and install succeeded"
  notify "Build complete ($NEW_COMMITS new commit(s))"
else
  log "ERROR: Build failed"
  notify "Build failed after pull. Check log."
  exit 1
fi
