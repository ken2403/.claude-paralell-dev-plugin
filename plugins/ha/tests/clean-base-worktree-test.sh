#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-clean-worktrees/scripts/clean.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-clean-base-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q --bare -b main "$tmp/origin.git"
git clone -q "$tmp/origin.git" "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
git -C "$tmp/repo" push -q origin main
git -C "$tmp/repo" remote set-head origin main
git -C "$tmp/repo" switch -q -c driver
mkdir -p "$tmp/repo/.claude/worktrees/ha" "$tmp/bin"
git -C "$tmp/repo" worktree add -q "$tmp/repo/.claude/worktrees/ha/base-main" main
printf '#!/bin/sh\nexit 1\n' >"$tmp/bin/gh"
chmod +x "$tmp/bin/gh"

out="$(cd "$tmp/repo" && PATH="$tmp/bin:$PATH" bash "$script" all-merged)"
test -d "$tmp/repo/.claude/worktrees/ha/base-main"
git -C "$tmp/repo" show-ref --verify --quiet refs/heads/main
printf '%s' "$out" | grep -q 'base branch worktrees are never cleanup targets'

echo "clean-base-worktree-test.sh: ok"
