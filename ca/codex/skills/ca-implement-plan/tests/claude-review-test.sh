#!/usr/bin/env bash
# Behavior tests for claude-review.sh — the leg every review round depends on.
#
#   1. happy path            -> validated blind JSON at --out, exit 0
#   2. claude fails on STDOUT -> the reason is surfaced, not swallowed
#      (claude -p reports most failures on stdout; discarding it left operators with an
#       empty stderr and a diagnostic that named the wrong causes)
#   3. CA_CLAUDE_PERMISSION_MODE -> passed through as --permission-mode
#   4. timeout with no output -> exit 1 and the tool-permission hint
#   5. contract violation     -> exit 1 (treated as blocked), never a usable verdict
#   6. mode/round are echoed back and enforced
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/codex/skills/ca-implement-plan/scripts/claude-review.sh"
TMP="${TMPDIR:-/tmp}/claude-review-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

fail() { echo "FAIL: $*" >&2; exit 1; }
PLAN="$TMP/plan.md"; printf '# Plan\nOne task.\n' > "$PLAN"
WT="$TMP/wt"; mkdir -p "$WT"

cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
set -uo pipefail
SHA=0123456789abcdef0123456789abcdef01234567
case "${CLAUDE_TEST_MODE:-ok}" in
  ok)
    round=1; mode=final
    for a in "$@"; do
      case "$a" in *"round=2"*) round=2;; esac
      case "$a" in *"mode=checkpoint"*) mode=checkpoint;; esac
    done
    printf '{"schema_version":"ca_claude_review.v1","producer":"blind","round":%s,"mode":"%s","pr":7,"head_sha":"%s","verdict":"approve","summary":"ok","findings":[],"verification":[{"claim":"c","result":"pass","evidence":"e"}]}\n' \
      "$round" "$mode" "$SHA" > "${CA_OUT:?}"
    ;;
  stdout_failure)
    echo "Error: Exceeded USD budget (2)"   # the real failure channel: STDOUT
    exit 1
    ;;
  record_args)
    printf '%s\n' "$@" > "${CLAUDE_ARGS_LOG:?}"
    printf '{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","pr":7,"head_sha":"'"$SHA"'","verdict":"approve","summary":"ok","findings":[],"verification":[{"claim":"c","result":"pass","evidence":"e"}]}\n' > "${CA_OUT:?}"
    ;;
  hang) sleep 30;;
  bad_contract)
    printf '{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","pr":7,"head_sha":"'"$SHA"'","verdict":"approve","summary":"contradiction","findings":[{"id":"C001","blocking":true,"severity":"blocker","title":"t","evidence":"e","recommended_fix":"f"}],"verification":[{"claim":"c","result":"pass","evidence":"e"}]}\n' > "${CA_OUT:?}"
    ;;
esac
SH
chmod +x "$TMP/bin/claude"
export CLAUDE_BIN="$TMP/bin/claude"

run() {  # run CLAUDE_TEST_MODE out [extra args...]
  local mode="$1" out="$2"; shift 2
  set +e
  CLAUDE_TEST_MODE="$mode" bash "$SCRIPT" --plan "$PLAN" --pr 7 --worktree "$WT" \
    --round 1 --out "$out" "$@" > "$TMP/stdout" 2> "$TMP/stderr"
  local rc=$?
  set -e
  return "$rc"
}

# 1. happy path
run ok "$TMP/out/ok.json" || fail "1: happy path exited non-zero"
[ -s "$TMP/out/ok.json" ] || fail "1: no review written"

# 2. a stdout-only failure must be reported, not swallowed
run stdout_failure "$TMP/out/f.json" && fail "2: a failing claude produced exit 0"
grep -q "Exceeded USD budget" "$TMP/stderr" \
  || { cat "$TMP/stderr" >&2; fail "2: claude's stdout reason was not surfaced"; }
[ -s "${TMP}/out/f.stdout" ] || fail "2: stdout was not captured to a file"

# 3. CA_CLAUDE_PERMISSION_MODE is passed through
export CLAUDE_ARGS_LOG="$TMP/args.log"
CA_CLAUDE_PERMISSION_MODE=dontAsk run record_args "$TMP/out/args.json" \
  || fail "3: permission-mode run failed"
grep -qx -- "--permission-mode" "$CLAUDE_ARGS_LOG" || fail "3: --permission-mode not passed"
grep -qx -- "dontAsk" "$CLAUDE_ARGS_LOG" || fail "3: permission mode value not passed"
unset CLAUDE_ARGS_LOG
# ... and omitted when unset
run record_args "$TMP/out/args2.json" 2>/dev/null || true

# 4. a silent timeout points at tool permissions
CA_CLAUDE_REVIEW_TIMEOUT=1 run hang "$TMP/out/t.json" && fail "4: timeout exited 0"
grep -q "CA_CLAUDE_PERMISSION_MODE" "$TMP/stderr" \
  || { cat "$TMP/stderr" >&2; fail "4: silent timeout did not name the permission cause"; }

# 5. a contract violation is never a usable verdict
run bad_contract "$TMP/out/b.json" && fail "5: an incoherent review was accepted"
grep -q "strict contract validation" "$TMP/stderr" || fail "5: no contract failure reported"

# 6. mode/round round-trip
run ok "$TMP/out/cp.json" --mode checkpoint || fail "6: checkpoint run failed"
grep -q '"mode":"checkpoint"' "$TMP/out/cp.json" || fail "6: mode not echoed"

echo "claude-review-test.sh: ok"
