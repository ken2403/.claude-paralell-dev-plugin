#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/codex/skills/ca-implement-plan/scripts/new-worktree.sh"
TMP="${TMPDIR:-/tmp}/ca-new-worktree-test.$$"
trap 'rm -rf "$TMP"' EXIT

git init -q -b master "$TMP/repo"
git -C "$TMP/repo" config user.email test@example.invalid
git -C "$TMP/repo" config user.name test
mkdir -p "$TMP/repo/docs/ca/plans"
printf '# Plan\n' > "$TMP/repo/docs/ca/plans/feature.md"
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm init

(cd "$TMP/repo" && bash "$SCRIPT" "$TMP/repo/docs/ca/plans/feature.md") > "$TMP/out"
WT="$TMP/repo/.claude/worktrees/ca/feature"
[ -d "$WT" ]
[ "$(git -C "$WT" branch --show-current)" = "ca/feature" ]
[ "$(cat "$WT/.ca/runs/feature/base.txt")" = "master" ]
grep -q 'base master' "$TMP/out"

printf '# Bad plan\n' > "$TMP/repo/docs/ca/plans/bad name.md"
set +e
(cd "$TMP/repo" && bash "$SCRIPT" "$TMP/repo/docs/ca/plans/bad name.md") >/dev/null 2>&1
bad_rc=$?
set -e
[ "$bad_rc" -ne 0 ] || { echo "invalid branch name was accepted" >&2; exit 1; }

cmp -s "$SCRIPT" "$ROOT/ca/claude/skills/implement/scripts/new-worktree.sh"
echo "new-worktree-test.sh: ok"
