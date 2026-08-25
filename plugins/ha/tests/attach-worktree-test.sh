#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-apply-feedback/scripts/attach-or-create-worktree.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-attach-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
git -C "$tmp/repo" push -q origin main
git -C "$tmp/repo" branch feat/review
git -C "$tmp/repo" push -q origin feat/review
head="$(git -C "$tmp/repo" rev-parse feat/review)"
git -C "$tmp/repo" worktree add -q "$tmp/feature" feat/review

out="$(cd "$tmp/repo" && bash "$script" feat/review "$head")"
eval "$out"
test "$REUSED" = 1
test "$(cd "$WORKTREE_PATH" && pwd -P)" = "$(cd "$tmp/feature" && pwd -P)"
! (cd "$tmp/repo" && bash "$script" feat/review ffffffffffffffffffffffffffffffffffffffff) >/dev/null 2>&1
printf 'dirty\n' >"$tmp/feature/dirty.txt"
! (cd "$tmp/repo" && bash "$script" feat/review "$head") >/dev/null 2>&1

echo "attach-worktree-test.sh: ok"
