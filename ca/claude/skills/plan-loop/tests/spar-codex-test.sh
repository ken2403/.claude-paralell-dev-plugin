#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/claude/skills/plan-loop/scripts/spar-codex.sh"
TMP="${TMPDIR:-/tmp}/spar-codex-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"
printf 'review this plan\n' > "$TMP/prompt.md"

cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" > "${CODEX_ARGS_LOG:?}"
cat > /dev/null
out=""
while [ $# -gt 0 ]; do
  if [ "$1" = "--output-last-message" ]; then out="$2"; break; fi
  shift
done
[ -n "$out" ] || exit 8
case "${CODEX_TEST_MODE:-ok}" in
  ok) printf 'bounded critique\n' > "$out";;
  empty) : > "$out";;
  fail) echo 'stub failure' >&2; exit 9;;
esac
SH
chmod +x "$TMP/bin/codex"
export CODEX_BIN="$TMP/bin/codex" CODEX_ARGS_LOG="$TMP/args.log"

[ "$(bash "$SCRIPT" "$TMP/prompt.md")" = "bounded critique" ]
grep -q -- '--sandbox read-only' "$CODEX_ARGS_LOG"
grep -q -- 'approval_policy=never' "$CODEX_ARGS_LOG"
grep -q -- 'model_reasoning_effort=high' "$CODEX_ARGS_LOG"

set +e
CODEX_TEST_MODE=empty bash "$SCRIPT" "$TMP/prompt.md" >/dev/null 2>&1; empty_rc=$?
CODEX_TEST_MODE=fail bash "$SCRIPT" "$TMP/prompt.md" >/dev/null 2>&1; fail_rc=$?
CA_CODEX_SPAR_TIMEOUT=bad bash "$SCRIPT" "$TMP/prompt.md" >/dev/null 2>&1; timeout_rc=$?
set -e
[ "$empty_rc" -ne 0 ] && [ "$fail_rc" -ne 0 ] && [ "$timeout_rc" -eq 2 ]

echo "spar-codex-test.sh: ok"
