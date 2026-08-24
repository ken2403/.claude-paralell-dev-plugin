#!/usr/bin/env bash
# Generated from common/src/scripts/merge-check.sh; edit common/src and run common/sync.sh.
# ==============================================================================
# Canonical merge verification for the ha plugin.
# Ported from sa/skills/clean-worktrees/scripts/merge-check.sh (sa->ha header).
#
# This is the SINGLE SOURCE OF TRUTH for branch merge verification logic.
# All commands and scripts should use this implementation.
#
# Usage (sourced):
#   source path/to/merge-check.sh
#   if is_branch_merged "branch-name" "base-branch" [repo-root]; then
#     echo "merged"
#   fi
#
# Parameters:
#   $1 - branch name to check
#   $2 - base branch to check against
#   $3 - repository root (optional, defaults to ".")
#
# Returns: 0 if branch is confirmed merged, 1 otherwise.
# Messages are output to stderr so they don't interfere with stdout capture.
#
# Principle: NEVER return "merged" unless we have POSITIVE PROOF.
# When in doubt, return "not merged" (safe side).
#
# Verification methods (in order):
#   1. gh pr — check GitHub PR state (most reliable, handles squash merge)
#   2. git branch --merged — check local git merge status
#   3. If all methods are inconclusive → return NOT MERGED
# ==============================================================================

is_branch_merged() {
  local branch="$1"
  local base="$2"
  local repo_root="${3:-.}"

  # --- Method 1: Check via GitHub PR (most reliable) ---
  # This correctly handles squash merges, rebase merges, etc.
  if command -v gh &>/dev/null; then
    local pr_state=""
    pr_state=$(cd "$repo_root" && gh pr list --head "$branch" --state merged --json number,state --jq '.[0].state' 2>/dev/null || echo "")
    if [ "$pr_state" = "MERGED" ]; then
      echo "  Merge verified by: GitHub PR (state=MERGED)" >&2
      return 0
    fi

    # Check if PR is still open (definitively NOT merged)
    local pr_open=""
    pr_open=$(cd "$repo_root" && gh pr list --head "$branch" --state open --json number --jq '.[0].number' 2>/dev/null || echo "")
    if [ -n "$pr_open" ]; then
      echo "  PR #$pr_open is still OPEN — NOT merged" >&2
      return 1
    fi
  fi

  # --- Method 2: Check local git merge status ---
  # Only works for non-squash merges; requires branch to exist locally.
  # Note: `git branch` marks a branch checked out in another worktree with a
  # leading `+`, so strip `[ *+]` (not just `[ *]`) before the exact-name match.
  if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    if git -C "$repo_root" branch --merged "$base" 2>/dev/null | sed 's/^[ *+]*//' | grep -Fqx "$branch"; then
      echo "  Merge verified by: git branch --merged $base" >&2
      return 0
    fi
    if git -C "$repo_root" branch --merged "origin/$base" 2>/dev/null | sed 's/^[ *+]*//' | grep -Fqx "$branch"; then
      echo "  Merge verified by: git branch --merged origin/$base" >&2
      return 0
    fi
    echo "  Branch exists locally but is NOT merged into $base" >&2
    return 1
  fi

  # --- Branch does not exist locally ---
  # CRITICAL: Do NOT assume "branch gone = merged".
  # The branch could have been deleted without merging, or the name could be wrong.
  # Without positive proof from GitHub PR, we REFUSE to confirm merge.
  echo "  Branch not found locally and no merged PR found — REFUSING to confirm merge" >&2
  return 1
}
