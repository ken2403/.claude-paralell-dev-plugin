#!/usr/bin/env bash
set -euo pipefail

branch="${1:?usage: new-worktree.sh <branch> [base]}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
root="$(git rev-parse --show-toplevel)"
git check-ref-format --branch "$branch" >/dev/null
case "$branch" in -*) echo "new-worktree: branch must not start with '-'" >&2; exit 2;; esac

git_dir="$(git -C "$root" rev-parse --git-dir)"
git_common="$(git -C "$root" rev-parse --git-common-dir)"
super="$(git -C "$root" rev-parse --show-superproject-working-tree 2>/dev/null || true)"
if [ "$git_dir" != "$git_common" ] && [ -z "$super" ]; then
  current="$(git -C "$root" branch --show-current)"
  [ -n "$current" ] || { echo "new-worktree: detached linked worktree cannot be reused" >&2; exit 1; }
  printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=1\n' "$root" "$current"
  exit 0
fi

base="${2:-$(bash "$script_dir/detect-base-branch.sh" "$root")}"
slug="$(printf '%s' "$branch" | tr '/' '-' | tr -cs 'A-Za-z0-9._-' '-')"
worktree="$root/.claude/worktrees/ha/$slug"

git -C "$root" show-ref --verify --quiet "refs/heads/$branch" && {
  echo "new-worktree: local branch already exists: $branch" >&2; exit 1;
}
if git -C "$root" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
  echo "new-worktree: remote branch already exists: $branch" >&2; exit 1
fi
[ ! -e "$worktree" ] || { echo "new-worktree: path already exists: $worktree" >&2; exit 1; }

git -C "$root" fetch origin "$base" --quiet 2>/dev/null || true
start="$base"
git -C "$root" show-ref --verify --quiet "refs/remotes/origin/$base" && start="origin/$base"
mkdir -p "$root/.claude/worktrees/ha"
git -C "$root" worktree add -b "$branch" "$worktree" "$start" >&2

on_branch="$(git -C "$worktree" branch --show-current)"
[ "$on_branch" = "$branch" ] || { echo "new-worktree: created unexpected branch $on_branch" >&2; exit 1; }
[ "$on_branch" != "$base" ] || { echo "new-worktree: refusing base branch worktree" >&2; exit 1; }
printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=0\n' "$worktree" "$branch"
