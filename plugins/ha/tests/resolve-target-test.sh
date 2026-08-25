#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-resolve-conflicts/scripts/resolve-target.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-resolve-target-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567

git init -q -b main "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
printf 'feat/release\trelease/1.x\t%s\n' '$sha'
EOF
chmod +x "$tmp/bin/gh"

out="$(GH_BIN="$tmp/bin/gh" bash "$script" 42 "$tmp/repo")"
eval "$out"
test "$BRANCH" = feat/release
test "$BASE" = release/1.x
test "$EXPECTED_HEAD" = "$sha"

git -C "$tmp/repo" branch 42
out="$(GH_BIN="$tmp/bin/gh" bash "$script" 42 "$tmp/repo")"
eval "$out"
test "$BRANCH" = feat/release
test "$BASE" = release/1.x
test "$EXPECTED_HEAD" = "$sha"
cat >"$tmp/bin/gh-fail" <<'EOF'
#!/bin/sh
exit 99
EOF
chmod +x "$tmp/bin/gh-fail"
out="$(GH_BIN="$tmp/bin/gh-fail" bash "$script" branch:42 "$tmp/repo")"
eval "$out"
test "$BRANCH" = 42
test "$BASE" = main
test -z "$EXPECTED_HEAD"

echo "resolve-target-test.sh: ok"
