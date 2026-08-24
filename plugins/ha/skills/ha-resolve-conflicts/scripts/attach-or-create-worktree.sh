#!/usr/bin/env bash
set -euo pipefail

branch="${1:?usage: attach-or-create-worktree.sh <branch>}"
expected="${2:-}"
git check-ref-format --branch "$branch" >/dev/null
[ -z "$expected" ] || { [ "${#expected}" -eq 40 ] && ! printf '%s' "$expected" | grep -q '[^0-9a-f]'; } \
  || { echo "attach-worktree: expected head must be 40 lowercase hex characters" >&2; exit 2; }
root="$(git rev-parse --show-toplevel)"
common="$(git -C "$root" rev-parse --git-common-dir)"
case "$common" in
  /*) main="$(cd "$(dirname "$common")" && pwd)" ;;
  *) main="$(cd "$root/$(dirname "$common")" && pwd)" ;;
esac

git -C "$main" fetch origin "$branch" --quiet 2>/dev/null || true

verify_checkout() {
  local path="$1" actual
  [ -z "$(git -C "$path" status --porcelain)" ] \
    || { echo "attach-worktree: worktree has uncommitted changes: $path" >&2; return 1; }
  if [ -n "$expected" ]; then
    actual="$(git -C "$path" rev-parse HEAD)"
    [ "$actual" = "$expected" ] \
      || { echo "attach-worktree: checkout head $actual does not match PR head $expected" >&2; return 1; }
  fi
}

existing=""
while IFS=$'\t' read -r path checked; do
  if [ "$checked" = "$branch" ]; then existing="$path"; break; fi
done < <(git -C "$root" worktree list --porcelain | awk '
  /^worktree / {if (seen) print path "\t" branch; path=substr($0,10); branch="DETACHED"; seen=1}
  /^branch / {branch=$2; sub(/^refs\/heads\//,"",branch)}
  END {if (seen) print path "\t" branch}')

if [ -n "$existing" ]; then
  [ "$existing" != "$main" ] || { echo "attach-worktree: branch is checked out in the main checkout" >&2; exit 1; }
  verify_checkout "$existing"
  printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=1\n' "$existing" "$branch"
  exit 0
fi

slug="$(printf '%s' "$branch" | tr '/' '-' | tr -cs 'A-Za-z0-9._-' '-')"
worktree="$main/.claude/worktrees/ha/$slug"
[ ! -e "$worktree" ] || { echo "attach-worktree: unregistered path exists: $worktree" >&2; exit 1; }
mkdir -p "$main/.claude/worktrees/ha"
if git -C "$main" show-ref --verify --quiet "refs/heads/$branch"; then
  if [ -n "$expected" ] && [ "$(git -C "$main" rev-parse "refs/heads/$branch")" != "$expected" ]; then
    echo "attach-worktree: local branch does not match PR head $expected" >&2
    exit 1
  fi
  git -C "$main" worktree add "$worktree" "$branch" >&2
elif git -C "$main" show-ref --verify --quiet "refs/remotes/origin/$branch"; then
  if [ -n "$expected" ] && [ "$(git -C "$main" rev-parse "refs/remotes/origin/$branch")" != "$expected" ]; then
    echo "attach-worktree: origin branch does not match PR head $expected" >&2
    exit 1
  fi
  git -C "$main" worktree add -b "$branch" "$worktree" "origin/$branch" >&2
else
  echo "attach-worktree: branch not found locally or on origin: $branch" >&2
  exit 1
fi
[ "$(git -C "$worktree" branch --show-current)" = "$branch" ] || exit 1
verify_checkout "$worktree"
printf 'WORKTREE_PATH=%q\nBRANCH=%q\nREUSED=0\n' "$worktree" "$branch"
