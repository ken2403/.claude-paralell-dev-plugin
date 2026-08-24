#!/usr/bin/env bash
set -euo pipefail

branch="${1:?usage: attach-or-create-worktree.sh <branch>}"
git check-ref-format --branch "$branch" >/dev/null
root="$(git rev-parse --show-toplevel)"
common="$(git -C "$root" rev-parse --git-common-dir)"
case "$common" in
  /*) main="$(cd "$(dirname "$common")" && pwd)" ;;
  *) main="$(cd "$root/$(dirname "$common")" && pwd)" ;;
esac

existing=""
while IFS=$'\t' read -r path checked; do
  if [ "$checked" = "$branch" ]; then existing="$path"; break; fi
done < <(git -C "$root" worktree list --porcelain | awk '
  /^worktree / {if (seen) print path "\t" branch; path=substr($0,10); branch="DETACHED"; seen=1}
  /^branch / {branch=$2; sub(/^refs\/heads\//,"",branch)}
  END {if (seen) print path "\t" branch}')

if [ -n "$existing" ]; then
  [ "$existing" != "$main" ] || { echo "attach-worktree: branch is checked out in the main checkout" >&2; exit 1; }
  printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=1\n' "$existing" "$branch"
  exit 0
fi

slug="$(printf '%s' "$branch" | tr '/' '-' | tr -cs 'A-Za-z0-9._-' '-')"
worktree="$main/.claude/worktrees/ha/$slug"
[ ! -e "$worktree" ] || { echo "attach-worktree: unregistered path exists: $worktree" >&2; exit 1; }
git -C "$main" fetch origin "$branch" --quiet 2>/dev/null || true
mkdir -p "$main/.claude/worktrees/ha"
if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
  git -C "$main" worktree add "$worktree" "$branch" >&2
elif git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  git -C "$main" worktree add -b "$branch" "$worktree" "origin/$branch" >&2
else
  echo "attach-worktree: branch not found locally or on origin: $branch" >&2
  exit 1
fi
[ "$(git -C "$worktree" branch --show-current)" = "$branch" ] || exit 1
printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=0\n' "$worktree" "$branch"
