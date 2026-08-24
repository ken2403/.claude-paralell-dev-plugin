#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
validator="$plugin/skills/ha-review-pr/scripts/validate-review.py"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-review-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567

mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<EOF
#!/bin/sh
printf '%s\n' "\${GH_HEAD:-$sha}"
EOF
chmod +x "$tmp/bin/gh"
export GH_BIN="$tmp/bin/gh"

git init -q "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init

write_review() {
  verdict="$1" blockers="$2" verify="$3" head="${4:-$sha}"
  if [ "$blockers" = 1 ]; then
    findings='[{"id":"H001","blocking":true,"severity":"high","file":"x.py","line":1,"title":"bug","evidence":"failing case","recommended_fix":"fix and test"}]'
  else findings='[]'; fi
  if [ "$verify" = 1 ]; then
    verification='[{"claim":"tests","result":"pass","evidence":"pytest passed"}]'
  else verification='[]'; fi
  cat >"$tmp/review.json" <<EOF
{"schema_version":"ha_codex_review.v1","pr":12,"head_sha":"$head","verdict":"$verdict","summary":"reviewed","findings":$findings,"verification":$verification}
EOF
}

write_review APPROVE 0 1
(cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12 --record) >/dev/null
test -f "$tmp/repo/.git/ha/reviews/pr-12.json"

write_review APPROVE 1 1
! (cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12) >/dev/null 2>&1
write_review APPROVE 0 0
! (cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12) >/dev/null 2>&1
write_review REQUEST_CHANGES 0 1
! (cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12) >/dev/null 2>&1
write_review BLOCKED 0 0
(cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12) >/dev/null
write_review APPROVE 0 1 ffffffffffffffffffffffffffffffffffffffff
! (cd "$tmp/repo" && python3 "$validator" "$tmp/review.json" --expected-pr 12) >/dev/null 2>&1

echo "validate-review-test.sh: ok"
