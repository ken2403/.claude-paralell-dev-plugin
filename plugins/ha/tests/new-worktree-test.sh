#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-implement/scripts/new-worktree.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-worktree-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
git -C "$tmp/repo" push -q origin main
git -C "$tmp/repo" remote set-head origin main

out="$(cd "$tmp/repo" && bash "$script" feat/port-test)"
eval "$out"
test "$REUSED" = 0
test "$BRANCH" = feat/port-test
test -d "$WORKTREE_PATH"
test "$(git -C "$WORKTREE_PATH" branch --show-current)" = feat/port-test
case "$WORKTREE_PATH" in */.claude/worktrees/ha/*) ;; *) exit 1;; esac
! (cd "$tmp/repo" && bash "$script" feat/port-test) >/dev/null 2>&1
! (cd "$tmp/repo" && bash "$script" --bad) >/dev/null 2>&1

echo "new-worktree-test.sh: ok"
