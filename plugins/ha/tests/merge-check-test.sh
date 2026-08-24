#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-clean-worktrees/scripts/merge-check.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-merge-check-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT

git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
git -C "$tmp/repo" switch -q -c feat/reused
printf 'new work\n' >"$tmp/repo/change.txt"
git -C "$tmp/repo" add change.txt
git -C "$tmp/repo" commit -q -m change
head="$(git -C "$tmp/repo" rev-parse HEAD)"

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
case " $* " in
  *" --state merged "*)
    case "${GH_MODE:-}" in
      current) printf 'MERGED\t%s\n' "$GH_HEAD" ;;
      historical) printf 'MERGED\t%s\n' ffffffffffffffffffffffffffffffffffffffff ;;
    esac
    ;;
  *" --state open "*) printf '\n' ;;
esac
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_HEAD="$head"

! (export GH_MODE=historical; cd "$tmp/repo"; source "$script"; is_branch_merged feat/reused main "$tmp/repo") >/dev/null 2>&1
(export GH_MODE=current; cd "$tmp/repo"; source "$script"; is_branch_merged feat/reused main "$tmp/repo") >/dev/null 2>&1

echo "merge-check-test.sh: ok"
