#!/usr/bin/env bash
# Generated from common/src/scripts/clean.sh; edit common/src and run common/sync.sh.
# ==============================================================================
# Worktree cleanup script for the ha plugin.
# Ported from sa/skills/clean-worktrees/scripts/clean.sh (sa->ha).
#
# Scans linked worktrees via `git worktree list` and removes EVERY worktree —
# regardless of location — whose branch has been merged. This is intentionally
# repo-wide: it reclaims ha/sa/ca worktrees and any other merged worktree, so a
# single run cleans them all. The main checkout is always preserved; the current
# worktree is removed too if its branch is merged. An unmerged branch is never
# deleted.
#
# Follows superpowers:finishing-a-development-branch's cleanup guardrails:
# cd to the main root before removing, merge-verified-only, `git worktree prune`,
# never `--force` / `-D`.
#
# Usage:
#   scripts/clean.sh [branch | path | all-merged | --all]
#     (no arg / all-merged / --all) → consider every worktree
#     (a name/branch/path) → only that one
#
# Safety:
#   - Considers every worktree in `git worktree list` (any path).
#   - NEVER deletes a worktree whose branch has NOT been merged.
#   - NEVER deletes the main checkout. The CURRENT worktree IS removed if its
#     branch is merged (done from the main checkout, since git refuses to remove
#     the worktree you stand in); skipped only if there is no separate main dir.
#   - NEVER uses `git worktree remove --force` — a worktree with uncommitted
#     changes is skipped and reported, not destroyed.
#   - `git branch -d` (not -D) — refuses to delete an unmerged branch.
#   - Locked worktrees: a MERGED worktree whose lock holder is a dead process
#     (e.g. a finished Claude session's "pid N" lock) is unlocked and removed;
#     a lock held by a RUNNING process, or with no parseable pid, is skipped.
#   - Orphan directories under .claude/worktrees/ (present on disk but not in
#     `git worktree list`): removed only when EMPTY. A non-empty orphan has no
#     git metadata to verify a merge against, so it is reported, never deleted.
# ==============================================================================
set -e

echo "=== Worktree Cleanup ==="

INPUT_ARG="${1:-}"

# Detect git repository
GIT_ROOT=""
if git rev-parse --show-toplevel &>/dev/null; then
  GIT_ROOT=$(git rev-parse --show-toplevel)
else
  for dir in . */; do
    if [ -d "$dir/.git" ] || git -C "$dir" rev-parse --show-toplevel &>/dev/null 2>&1; then
      GIT_ROOT=$(cd "$dir" && git rev-parse --show-toplevel)
      break
    fi
  done
fi

if [ -z "$GIT_ROOT" ]; then
  echo "ERROR: No git repository found"
  exit 1
fi

cd "$GIT_ROOT"
echo "Repository: $GIT_ROOT"

# Helper scripts are co-located in this skill's own scripts/ dir (self-contained).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Base branch detection
BASE_BRANCH=$("$SCRIPT_DIR/detect-base-branch.sh" 2>/dev/null || echo "main")
echo "Base branch: $BASE_BRANCH"

# ============================================================
# Pre-cleanup sync: bring local <base> up to origin/<base> BEFORE
# any deletion decision so the user can verify merges locally
# (e.g. `git log main`) once the command finishes.
# ============================================================
echo ""
echo "=== Syncing $BASE_BRANCH with origin ==="

if ! git fetch origin "$BASE_BRANCH" --prune --quiet; then
  echo "WARNING: git fetch origin $BASE_BRANCH failed."
  echo "  Continuing, but local state may be stale."
  echo "  Merge verification will still use 'gh pr' as the authoritative source."
fi

CURRENT_BRANCH=$(git branch --show-current 2>/dev/null || echo "")
if [ "$CURRENT_BRANCH" = "$BASE_BRANCH" ]; then
  if git pull --ff-only origin "$BASE_BRANCH" --quiet; then
    echo "Local $BASE_BRANCH fast-forwarded to origin/$BASE_BRANCH"
  else
    echo "WARNING: Local $BASE_BRANCH could not be fast-forwarded (diverged?)."
    echo "  Continuing; 'gh pr' will still drive merge verification."
  fi
else
  if git fetch origin "$BASE_BRANCH:$BASE_BRANCH" --quiet 2>/dev/null; then
    echo "Local $BASE_BRANCH ref fast-forwarded to origin/$BASE_BRANCH"
  else
    echo "WARNING: Local $BASE_BRANCH ref could not be fast-forwarded (checked out elsewhere or diverged)."
    echo "  Continuing; 'gh pr' will still drive merge verification."
  fi
fi

# Parse arguments
CLEANUP_ALL=false
{ [ -z "$INPUT_ARG" ] || [ "$INPUT_ARG" = "--all" ] || [ "$INPUT_ARG" = "all-merged" ]; } && CLEANUP_ALL=true

# Source canonical merge verification (defines is_branch_merged)
source "$SCRIPT_DIR/merge-check.sh"

# ============================================================
# The main checkout is NEVER removed. The current worktree CAN be removed if it
# is merged — but git refuses to remove the worktree you are standing in, so we
# run all removals from the main checkout. When there is no separate main
# checkout to relocate to, the current worktree is skipped (fail-safe).
# ============================================================
CURRENT_WT="$(git rev-parse --show-toplevel 2>/dev/null || echo "")"
COMMON_GIT_DIR="$(git rev-parse --git-common-dir 2>/dev/null || echo "")"
case "$COMMON_GIT_DIR" in
  "") MAIN_WT="" ;;
  /*) MAIN_WT="$(cd "$(dirname "$COMMON_GIT_DIR")" 2>/dev/null && pwd || echo "")" ;;
  *)  MAIN_WT="$(cd "$GIT_ROOT/$(dirname "$COMMON_GIT_DIR")" 2>/dev/null && pwd || echo "")" ;;
esac

# Removals run from REMOVE_FROM. Using the main checkout lets us also remove the
# current worktree; fall back to GIT_ROOT (and skip the current worktree) when
# there is no separate main checkout.
REMOVE_FROM="$GIT_ROOT"
CAN_REMOVE_CURRENT=false
if [ -n "$MAIN_WT" ] && [ "$MAIN_WT" != "$CURRENT_WT" ]; then
  REMOVE_FROM="$MAIN_WT"
  CAN_REMOVE_CURRENT=true
fi

echo ""
echo "=== Scanning all worktrees ==="

MERGED_JOBS=()     # entries: "<path>\t<branch>"
UNMERGED_JOBS=()   # "<name>:<branch>"
UNKNOWN_JOBS=()    # "<name>:<reason>"
CLEANED_JOBS=()
FAILED_JOBS=()

while IFS=$'\t' read -r wt_path wt_branch; do
  [ -z "$wt_path" ] && continue
  name="$(basename "$wt_path")"

  # Never touch the main checkout.
  if [ -n "$MAIN_WT" ] && [ "$wt_path" = "$MAIN_WT" ]; then
    continue
  fi
  # The current worktree is only skipped when we cannot relocate the removal to a
  # separate main checkout; otherwise it is evaluated (and removed if merged)
  # like any other worktree.
  if [ "$wt_path" = "$CURRENT_WT" ] && [ "$CAN_REMOVE_CURRENT" = false ]; then
    echo ""
    echo "--- $name --- skip: current worktree (no separate main checkout to remove it from)"
    continue
  fi

  # If a specific target was given, only act on the matching worktree.
  if [ "$CLEANUP_ALL" = false ]; then
    case "$INPUT_ARG" in
      "$name"|"$wt_branch"|"$wt_path") ;;
      *) continue ;;
    esac
  fi

  echo ""
  echo "--- $name ($wt_path) ---"

  if [ -z "$wt_branch" ] || [ "$wt_branch" = "DETACHED" ]; then
    echo "Branch: UNKNOWN/detached"
    echo "  *** SAFETY BLOCK: no branch to verify — treating as NOT MERGED ***"
    UNKNOWN_JOBS+=("$name:detached")
    continue
  fi

  echo "Branch: $wt_branch"
  if is_branch_merged "$wt_branch" "$BASE_BRANCH"; then
    echo "Status: MERGED into $BASE_BRANCH"
    MERGED_JOBS+=("$wt_path"$'\t'"$wt_branch")
  else
    echo "Status: NOT MERGED"
    echo "  *** ALERT: '$wt_branch' is not merged — will NOT be deleted ***"
    UNMERGED_JOBS+=("$name:$wt_branch")
  fi
done < <(git worktree list --porcelain 2>/dev/null | awk '
  /^worktree /{ if (have) print path "\t" branch; path=substr($0,10); branch="DETACHED"; have=1 }
  /^branch /{ branch=$2; sub(/^refs\/heads\//,"",branch) }
  END{ if (have) print path "\t" branch }
')

echo ""
echo "=== Summary ==="
echo "Merged (safe to delete): ${#MERGED_JOBS[@]}"
echo "Not merged (BLOCKED):    ${#UNMERGED_JOBS[@]}"
echo "Unknown/detached (BLOCKED): ${#UNKNOWN_JOBS[@]}"

if [ ${#UNMERGED_JOBS[@]} -gt 0 ]; then
  echo ""
  echo "*** BLOCKED (not merged) — left untouched ***"
  for item in "${UNMERGED_JOBS[@]}"; do echo "  - ${item%%:*} (${item##*:})"; done
fi
if [ ${#UNKNOWN_JOBS[@]} -gt 0 ]; then
  echo ""
  echo "*** BLOCKED (unknown branch) — left untouched ***"
  for item in "${UNKNOWN_JOBS[@]}"; do echo "  - ${item%%:*}"; done
fi

# ============================================================
# Orphan sweep: directories under .claude/worktrees/ that are on disk but NOT
# registered in `git worktree list` (leftover group dirs like ca/, or remnants
# whose metadata was pruned). An EMPTY orphan is safely removed. A NON-EMPTY
# orphan has no git metadata to verify a merge against, so it is reported and
# left untouched — never guess-delete unverifiable content.
# Depth-2 first so an emptied group dir (ha/sa/ca) folds up in the same run.
# Runs in BOTH paths: with and without merged worktrees to clean.
# ============================================================
ORPHANS_REMOVED=()
ORPHANS_KEPT=()
sweep_orphans() {
  # Anchored at the MAIN checkout (REMOVE_FROM): launched from a linked
  # worktree, GIT_ROOT points inside that worktree, where .claude/worktrees
  # does not exist and the sweep would silently no-op.
  local wt_base="$REMOVE_FROM/.claude/worktrees" registered dir reg keep
  [ -d "$wt_base" ] || return 0
  registered="$(git -C "$REMOVE_FROM" worktree list --porcelain 2>/dev/null | awk '/^worktree /{print substr($0,10)}')"
  while IFS= read -r dir; do
    [ -d "$dir" ] || continue
    keep=false
    while IFS= read -r reg; do
      [ -z "$reg" ] && continue
      # Keep a candidate that IS a registered worktree or CONTAINS one.
      case "$reg" in "$dir"|"$dir"/*) keep=true; break ;; esac
      # Keep a candidate INSIDE a registered worktree (a depth-1 registered
      # worktree owns its own subdirs) — but only for worktrees that live
      # INSIDE the sweep base: the main checkout contains the whole sweep
      # base by construction, and matching it would keep every candidate.
      case "$wt_base" in "$reg"|"$reg"/*) ;; *)
        case "$dir" in "$reg"/*) keep=true; break ;; esac ;;
      esac
    done <<< "$registered"
    [ "$keep" = true ] && continue
    # One guarded step: probe emptiness, then rmdir (which itself refuses a
    # non-empty dir, so a race can only make it fail — never delete content).
    # Any failure (unreadable, unremovable, raced) lands in KEPT and is
    # reported; it must never abort the script under `set -e`.
    if [ -z "$(find "$dir" -mindepth 1 -print -quit 2>/dev/null)" ] && rmdir "$dir" 2>/dev/null; then
      ORPHANS_REMOVED+=("$dir")
    else
      ORPHANS_KEPT+=("$dir")
    fi
  done < <(find "$wt_base" -mindepth 2 -maxdepth 2 -type d 2>/dev/null || true; find "$wt_base" -mindepth 1 -maxdepth 1 -type d 2>/dev/null || true)
  return 0
}
report_orphans() {
  if [ ${#ORPHANS_REMOVED[@]} -gt 0 ]; then
    echo ""
    echo "Removed ${#ORPHANS_REMOVED[@]} empty orphan dir(s) under .claude/worktrees/"
  fi
  if [ ${#ORPHANS_KEPT[@]} -gt 0 ]; then
    echo ""
    echo "*** ORPHANED (on disk, not a registered worktree; non-empty, unreadable, or unremovable) ***"
    echo "    No git metadata — a merge CANNOT be verified, so these are never auto-deleted."
    echo "    Inspect each and remove manually if the work is confirmed landed:"
    for d in "${ORPHANS_KEPT[@]}"; do echo "  - $d"; done
  fi
  return 0
}

if [ ${#MERGED_JOBS[@]} -eq 0 ]; then
  sweep_orphans
  report_orphans
  echo ""
  echo "No merged worktrees to clean up."
  echo "Orphan dirs removed (empty): ${#ORPHANS_REMOVED[@]}"
  echo "Orphan dirs kept (non-empty, unverifiable): ${#ORPHANS_KEPT[@]}"
  exit 0
fi

echo ""
echo "=== Cleaning Merged Worktrees ==="
# Run every removal from REMOVE_FROM (the main checkout when available) so the
# current worktree can be removed too. cd there so post-removal git calls and
# `git worktree prune` keep working even if the cwd's worktree was just removed.
cd "$REMOVE_FROM" 2>/dev/null || true
CURRENT_WT_REMOVED=false
for item in "${MERGED_JOBS[@]}"; do
  wt_path="${item%%$'\t'*}"
  branch="${item##*$'\t'}"
  name="$(basename "$wt_path")"

  echo ""
  echo "Cleaning: $name ($wt_path)"

  # Locked worktrees: merge is already positively verified at this point, so a
  # lock whose holder is DEAD (e.g. "claude session ... (pid N ...)" from a
  # finished session) is stale — unlock it. A lock held by a RUNNING process,
  # or one with no parseable pid, is respected: skip and report.
  lock_line="$(git -C "$REMOVE_FROM" worktree list --porcelain 2>/dev/null | awk -v p="$wt_path" '
    $0 == "worktree " p {found=1; next}
    /^worktree /{found=0}
    found && /^locked/ {print "LOCKED:" substr($0, 8); exit}')"
  if [ -n "$lock_line" ]; then
    lock_reason="${lock_line#LOCKED:}"
    lock_reason="${lock_reason# }"
    # Only our own session-bookkeeping locks are ever auto-released: the reason
    # must match the exact "claude session ... (pid N ...)" shape, ANCHORED at
    # the start. Any other lock — a human's deliberate `git worktree lock`, an
    # unrecognized tool, or free text that merely contains "pid" (e.g.
    # "KEEP: rapid 200 files") — is an absolute barrier: skip, never unlock.
    # Greedy .* means the LAST "(pid N ...)" group wins — correct because the
    # lock creator appends the real pid group at the END of the reason, after
    # the (potentially bait-carrying) worktree name. Pinned by the bait-name
    # scenario in common/tests/clean-worktrees-test.sh.
    lock_pid="$(printf '%s' "$lock_reason" | sed -n 's/^claude session .*(pid \([0-9][0-9]*\)[^)]*).*/\1/p')"
    if [ -z "$lock_pid" ]; then
      echo "  SKIP: locked (${lock_reason:-no reason}) — not a claude-session lock; 'git worktree unlock' manually if intended"
      FAILED_JOBS+=("$name")
      continue
    fi
    # Liveness via ps -p, which sees processes of ANY user. (`kill -0` reports
    # EPERM on another user's LIVE pid, which would misread as "gone".) A
    # restricted sandbox can deny `ps` itself; that is UNKNOWN, never proof of
    # death. Only ps status 1 is accepted as positive evidence that no selected
    # process exists. Any other failure preserves the lock (fail closed).
    set +e
    ps -p "$lock_pid" >/dev/null 2>&1
    ps_status=$?
    set -e
    if [ "$ps_status" -eq 0 ]; then
      echo "  SKIP: locked by a RUNNING process (pid $lock_pid: $lock_reason)"
      FAILED_JOBS+=("$name")
      continue
    fi
    if [ "$ps_status" -ne 1 ]; then
      echo "  SKIP: cannot verify lock-holder liveness (pid $lock_pid, ps status $ps_status) — preserving lock"
      FAILED_JOBS+=("$name")
      continue
    fi
    echo "  Stale claude-session lock (holder pid $lock_pid is gone) — unlocking"
    git -C "$REMOVE_FROM" worktree unlock "$wt_path" 2>/dev/null || true
  fi

  # NEVER --force: a plain remove fails on uncommitted changes, which is the
  # signal to inspect — not to destroy.
  if git -C "$REMOVE_FROM" worktree remove "$wt_path" 2>/dev/null; then
    echo "  Worktree removed"
    if [ "$wt_path" = "$CURRENT_WT" ]; then CURRENT_WT_REMOVED=true; fi
  else
    echo "  SKIP: uncommitted changes or locked — inspect and remove manually (no --force)"
    FAILED_JOBS+=("$name")
    continue
  fi

  if git -C "$REMOVE_FROM" show-ref --verify --quiet "refs/heads/$branch" 2>/dev/null; then
    if git -C "$REMOVE_FROM" branch -d "$branch" 2>/dev/null; then
      echo "  Local branch '$branch' deleted"
    else
      echo "  Local branch '$branch' kept (not fully merged locally)"
    fi
  else
    echo "  Local branch already gone"
  fi

  CLEANED_JOBS+=("$name")
done

git -C "$REMOVE_FROM" worktree prune 2>/dev/null || true

sweep_orphans
report_orphans

echo ""
echo "=== Cleanup Complete ==="
echo "Cleaned: ${#CLEANED_JOBS[@]}"
echo "Skipped (uncommitted/locked): ${#FAILED_JOBS[@]}"
echo "Blocked (not merged): ${#UNMERGED_JOBS[@]}"
echo "Blocked (unknown):    ${#UNKNOWN_JOBS[@]}"
echo "Orphan dirs removed (empty): ${#ORPHANS_REMOVED[@]}"
echo "Orphan dirs kept (non-empty, unverifiable): ${#ORPHANS_KEPT[@]}"
echo "Default branch ($BASE_BRANCH) was synced with origin before cleanup."

if [ "$CURRENT_WT_REMOVED" = true ]; then
  echo ""
  echo "NOTE: the worktree you were in was merged and has been removed."
  echo "      cd to the main checkout: $REMOVE_FROM"
fi
