#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
script="$plugin/skills/ha-merge-pr/scripts/merge-pr.sh"
tmp="$(mktemp -d "${TMPDIR:-/tmp}/ha-merge-test.XXXXXX")"
trap 'rm -rf "$tmp"' EXIT
sha=0123456789abcdef0123456789abcdef01234567

git init -q "$tmp/repo"
git -C "$tmp/repo" config user.email test@example.invalid
git -C "$tmp/repo" config user.name test
git -C "$tmp/repo" commit -q --allow-empty -m init
mkdir -p "$tmp/repo/.git/ha/reviews" "$tmp/bin"
cat >"$tmp/repo/.git/ha/reviews/pr-12.json" <<EOF
{"schema_version":"ha_codex_review.v1","pr":12,"head_sha":"$sha","verdict":"APPROVE","summary":"clean","findings":[],"verification":[{"claim":"tests","result":"pass","evidence":"passed"}]}
EOF

cat >"$tmp/bin/gh" <<'EOF'
#!/bin/sh
set -eu
sha=0123456789abcdef0123456789abcdef01234567
if [ "$1 $2 $3" = "pr view 12" ]; then
  case "$*" in
    *headRefOid*--jq*) printf '%s\n' "${GH_HEAD:-$sha}" ;;
    *mergedAt*--jq*) printf '%s\n' '2026-01-01T00:00:00Z' ;;
    *)
      if [ "${GH_MODE:-clean}" = draft ]; then draft=true; else draft=false; fi
      if [ "${GH_MODE:-clean}" = changes ]; then decision=CHANGES_REQUESTED; else decision=APPROVED; fi
      printf '{"state":"OPEN","isDraft":%s,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","reviewDecision":"%s","statusCheckRollup":[{"conclusion":"SUCCESS"}],"headRefOid":"%s"}\n' "$draft" "$decision" "${GH_HEAD:-$sha}"
      ;;
  esac
  exit 0
fi
if [ "$1 $2 $3" = "pr merge 12" ]; then
  printf '%s\n' "$*" >>"$GH_LOG"
  exit 0
fi
exit 9
EOF
chmod +x "$tmp/bin/gh"
export GH_BIN="$tmp/bin/gh" GH_LOG="$tmp/gh.log"

(cd "$tmp/repo" && bash "$script" --preflight 12) >/dev/null
(cd "$tmp/repo" && bash "$script" --merge 12 --method squash) >/dev/null
grep -q -- '--squash' "$tmp/gh.log"
grep -q -- "--match-head-commit $sha" "$tmp/gh.log"
! (export GH_MODE=draft; cd "$tmp/repo"; bash "$script" --preflight 12) >/dev/null 2>&1
! (export GH_MODE=changes; cd "$tmp/repo"; bash "$script" --preflight 12) >/dev/null 2>&1
! (export GH_HEAD=ffffffffffffffffffffffffffffffffffffffff; cd "$tmp/repo"; bash "$script" --preflight 12) >/dev/null 2>&1

echo "merge-pr-test.sh: ok"
