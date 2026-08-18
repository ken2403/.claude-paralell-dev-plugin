#!/usr/bin/env bash
# Create an isolated worktree for a plan and print the command to start Codex inside it.
# The worktree (not the model) owns isolation, per the ca design. Run from the repo.
set -euo pipefail
PLAN="${1:?usage: new-worktree.sh <plan.md>}"
[ -f "$PLAN" ] || { echo "plan not found: $PLAN" >&2; exit 1; }

# Resolve the ORIGINAL plan to an absolute path; its basename is the stable feature id.
# (Always pass this original path to the skill — never the staged copy, whose basename
# would collapse the id to "plan".)
ABS_PLAN="$(cd "$(dirname "$PLAN")" && pwd)/$(basename "$PLAN")"
ID="$(basename "$PLAN" .md)"
ROOT="$(git -C "$(dirname "$ABS_PLAN")" rev-parse --show-toplevel 2>/dev/null || git rev-parse --show-toplevel)"
git check-ref-format "refs/heads/ca/$ID" >/dev/null 2>&1 || {
  echo "invalid plan id for a ca branch: $ID (rename the plan to a git-safe filename)" >&2
  exit 1
}
BASE="${CA_BASE:-}"
if [ -z "$BASE" ]; then
  BASE="$(git -C "$ROOT" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
fi
if [ -z "$BASE" ]; then
  for candidate in main master develop dev; do
    if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$candidate"; then
      BASE="$candidate"
      break
    fi
  done
fi
BASE="${BASE:-main}"
WT="$ROOT/.claude/worktrees/ca/$ID"  # isolated worktree under .claude/worktrees/ca/ (matches sa/ha)
BR="ca/$ID"

git -C "$ROOT" fetch origin "$BASE" >/dev/null 2>&1 || true
mkdir -p "$ROOT/.claude/worktrees/ca"
if git -C "$ROOT" show-ref --verify --quiet "refs/heads/$BR"; then
  git -C "$ROOT" worktree add "$WT" "$BR"
else
  git -C "$ROOT" worktree add -b "$BR" "$WT" "origin/$BASE" 2>/dev/null \
    || git -C "$ROOT" worktree add -b "$BR" "$WT" "$BASE"
fi

# Keep ca's run state out of the PR AND out of `git status`. Without this, `.ca/` is
# untracked in the worktree, which (a) risks being swept into a `git add -A` commit and
# (b) makes `git worktree remove` (deliberately never --force) refuse forever, so
# /ca:clean-worktrees can never reclaim the worktree. info/exclude lives in the shared
# common dir, is never committed, and covers the main checkout too.
EXCLUDE="$(git -C "$WT" rev-parse --git-path info/exclude)"
case "$EXCLUDE" in /*) ;; *) EXCLUDE="$WT/$EXCLUDE";; esac
mkdir -p "$(dirname "$EXCLUDE")"
for pattern in '.ca/' '.claude/worktrees/'; do
  grep -qxF "$pattern" "$EXCLUDE" 2>/dev/null || printf '%s\n' "$pattern" >> "$EXCLUDE"
done

RUN="$WT/.ca/runs/$ID"; mkdir -p "$RUN"
cp "$ABS_PLAN" "$RUN/plan.md"
shasum -a 256 "$ABS_PLAN" | awk '{print $1}' > "$RUN/plan.sha256"
printf '%s\n' "$BASE" > "$RUN/base.txt"

echo "worktree ready: $WT  (branch $BR, base $BASE)"
echo
echo "Start Codex inside it and invoke the skill (pass the ORIGINAL plan path):"
echo "  codex -C \"$WT\""
echo "  # then in the session:  \$ca-implement-plan  PLAN=$ABS_PLAN"
