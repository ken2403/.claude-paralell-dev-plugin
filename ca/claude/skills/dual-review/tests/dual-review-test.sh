#!/usr/bin/env bash
# Behavior tests for dual-review.sh (the standalone dual-model orchestrator),
# with claude / codex / gh all stubbed — no network, no real binaries.
#
#   1. Codex finds something        → synthesis runs; final producer=synthesis;
#                                     meta codex=used, synthesis=used
#   2. Codex clean, full coverage   → synthesis SKIPPED; final == blind copy;
#                                     meta clean_no_synthesis
#   3. Codex binary missing         → visible degrade; final == blind;
#                                     meta unavailable
#   4. Degrade in a LATER round after a Codex round → meta carries
#                                     prior_findings_rechecked:false
#   5. Blind Claude review fails    → dual-review exits 1, no final JSON
#   6. Blind Claude review times out → dual-review exits 1, no final JSON
#   7. Codex times out             → visible timeout degrade; final == blind
#   9. --claude-only: no Codex process is started at all, the blind verdict gates directly,
#      and the meta says dual_review:false / codex disabled. This is the single-model review
#      that used to need its own command.
#   8. ISOLATION: while the Codex leg runs, the blind Claude verdict is NOT visible
#      anywhere in the worktree/out-dir it can read. The Codex leg reviews with read
#      access to the tree, so publishing the blind answer early would turn the second
#      opinion into an echo of the first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/claude/skills/dual-review/scripts/dual-review.sh"
TMP="${TMPDIR:-/tmp}/dual-review-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

fail() { echo "FAIL: $*" >&2; exit 1; }

PLAN="$TMP/plan.md"; printf '# Plan\nOne task.\n' > "$PLAN"
WT="$TMP/wt"; mkdir -p "$WT"

# --- gh stub (host-side PR fetch inside codex-review.sh) ---------------------
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view") printf '{"number":7,"title":"t","state":"OPEN","isDraft":true,"baseRefName":"main","headRefName":"b","url":"u"}\n';;
  "pr diff") if [ "${3:-}" = "--name-only" ] || [ "${4:-}" = "--name-only" ]; then printf 'a.txt\n'; else printf 'diff --git a/a.txt b/a.txt\n+x\n'; fi;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/gh"; export GH_BIN="$TMP/bin/gh"

# --- claude stub: blind review vs synthesis, keyed off the prompt ------------
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${CLAUDE_MODE:-ok}" in
  ok) ;;
  fail) exit 1;;
  sleep) sleep 5;;
  *) exit 9;;
esac
case "$*" in
  *synthesize-review*)
    cat > "${CA_OUT:?}" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":1,"mode":"final","pr":7,"head_sha":"0123456789abcdef0123456789abcdef01234567","verdict":"request_changes","summary":"synth","findings":[{"id":"C001","blocking":true,"severity":"major","title":"blind blocker kept","evidence":"a.txt:1","recommended_fix":"fix it"}],"verification":[],"second_opinion":{"provider":"codex","status":"used","coverage":"full","ledger":[{"id":"X001","adjudication":"refuted","evidence":"checked the diff"}],"prior_findings_rechecked":true},"resolved_blind_findings":[]}
JSON
    ;;
  *review-pr*)
    review_round=1
    case "$*" in *"round=2"*) review_round=2;; esac
    printf '{"schema_version":"ca_claude_review.v1","producer":"blind","round":%s,"mode":"final","pr":7,"head_sha":"0123456789abcdef0123456789abcdef01234567","verdict":"request_changes","summary":"blind","findings":[{"id":"C001","blocking":true,"severity":"major","title":"blind blocker","evidence":"a.txt:1","recommended_fix":"fix it"}],"verification":[]}\n' "$review_round" > "${CA_OUT:?}"
    ;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/claude"; export CLAUDE_BIN="$TMP/bin/claude"

# --- codex stub: reply on stdout, shape keyed off CODEX_MODE -----------------
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null   # consume the prompt on stdin
case "${CODEX_MODE:-finding}" in
  finding) printf '{"schema_version":"ca_codex_review.v1","summary":"codex","coverage":"full","findings":[{"id":"X001","blocking":true,"severity":"major","file":"a.txt","line":1,"title":"codex claim","evidence":"e","recommended_fix":"f"}]}\n';;
  clean)   printf '{"schema_version":"ca_codex_review.v1","summary":"codex","coverage":"full","findings":[]}\n';;
  timeout) echo "codex-progress-before-timeout" >&2; sleep 5;;
  leakprobe)
    sleep 1   # let the (instant) blind leg finish first
    { ls "${CA_TEST_OUTDIR:?}" 2>/dev/null | grep -c 'blind' || true; } > "${CA_TEST_LEAK_MARKER:?}"
    printf '{"schema_version":"ca_codex_review.v1","summary":"codex","coverage":"full","findings":[]}\n'
    ;;
esac
SH
chmod +x "$TMP/bin/codex"; export CODEX_BIN="$TMP/bin/codex"

json_get() { python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d.get(sys.argv[2],""))' "$@"; }

# 1. Codex finding → synthesis path
D1="$TMP/out/case1"
CODEX_MODE=finding bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D1" >/dev/null
[ "$(json_get "$D1/review-round-1.json" producer)" = "synthesis" ] || fail "case1: final is not the synthesis output"
grep -q '"synthesis":{"status":"used"}' "$D1/review-round-1.meta.json" || fail "case1: meta does not record synthesis"
[ -f "$D1/review-round-1.blind.json" ] || fail "case1: blind JSON not kept for audit"

# 2. Codex clean + full → synthesis skipped, final == blind
D2="$TMP/out/case2"
CODEX_MODE=clean bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D2" >/dev/null
cmp -s "$D2/review-round-1.json" "$D2/review-round-1.blind.json" || fail "case2: final is not the blind copy"
grep -q clean_no_synthesis "$D2/review-round-1.meta.json" || fail "case2: meta missing clean_no_synthesis"

# 3. Codex missing → visible degrade to Claude-only
D3="$TMP/out/case3"
CODEX_BIN="$TMP/bin/no-such-codex" bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D3" >/dev/null
cmp -s "$D3/review-round-1.json" "$D3/review-round-1.blind.json" || fail "case3: degrade did not fall back to blind"
grep -q '"status":"unavailable"' "$D3/review-round-1.meta.json" || fail "case3: meta missing unavailable status"

# 4. Later degraded round after a Codex round → prior_findings_rechecked:false
CODEX_BIN="$TMP/bin/no-such-codex" bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 2 --out-dir "$D1" >/dev/null
grep -q '"prior_findings_rechecked":false' "$D1/review-round-2.meta.json" || fail "case4: prior recheck flag missing"

# 5. Blind leg failure → hard exit, no verdict fabricated
D5="$TMP/out/case5"
set +e
CLAUDE_MODE=fail bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D5" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "case5: expected non-zero exit when the blind review fails"
[ ! -f "$D5/review-round-1.json" ] || fail "case5: a final verdict was fabricated despite blind failure"

# 6. Blind leg timeout -> hard exit, no verdict fabricated
D6="$TMP/out/case6"
set +e
CA_CLAUDE_REVIEW_TIMEOUT=1 CLAUDE_MODE=sleep bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D6" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "case6: expected non-zero exit when the blind review timed out"
[ ! -f "$D6/review-round-1.json" ] || fail "case6: a final verdict was fabricated after timeout"

# 7. Codex timeout → explicit timeout degrade, blind verdict remains usable
D7="$TMP/out/case7"
CA_CODEX_REVIEW_TIMEOUT=1 CODEX_MODE=timeout bash "$SCRIPT" \
  --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D7" >/dev/null
cmp -s "$D7/review-round-1.json" "$D7/review-round-1.blind.json" \
  || fail "case7: timeout degrade did not fall back to blind"
grep -q '"reason":"codex_timeout"' "$D7/review-round-1.meta.json" \
  || fail "case7: meta does not distinguish a Codex timeout"
grep -q 'codex-progress-before-timeout' "$D7/review-round-1.codex-leg.log" \
  || fail "case7: Codex progress before timeout was discarded"

# 8. the blind verdict must not be readable by the Codex leg while it is still reviewing
D8="$TMP/out/case8"
export CA_TEST_OUTDIR="$D8" CA_TEST_LEAK_MARKER="$TMP/leak.marker"
CODEX_MODE=leakprobe bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D8" >/dev/null
[ "$(cat "$TMP/leak.marker")" = "0" ] \
  || fail "case8: the Codex leg could see $(cat "$TMP/leak.marker") blind artifact(s) mid-review"
[ -f "$D8/review-round-1.blind.json" ] || fail "case8: the blind review was not published afterwards"
unset CA_TEST_OUTDIR CA_TEST_LEAK_MARKER

# 9. --claude-only must not start a Codex process at all
D9="$TMP/out/case9"
CODEX_MARKER="$TMP/codex.invoked"; rm -f "$CODEX_MARKER"
cat > "$TMP/bin/codex-tattle" <<SH
#!/usr/bin/env bash
echo invoked >> "$CODEX_MARKER"
cat > /dev/null
printf '{"schema_version":"ca_codex_review.v1","summary":"x","coverage":"full","findings":[]}\n'
SH
chmod +x "$TMP/bin/codex-tattle"
CODEX_BIN="$TMP/bin/codex-tattle" bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D9" --claude-only >/dev/null
[ ! -f "$CODEX_MARKER" ] || fail "case9: --claude-only still ran the Codex leg"
grep -q '"dual_review":false' "$D9/review-round-1.meta.json" || fail "case9: meta does not record the single-model run"
grep -q '"status":"disabled"' "$D9/review-round-1.meta.json" || fail "case9: meta does not disable the second opinion"
cmp -s "$D9/review-round-1.json" "$D9/review-round-1.blind.json" || fail "case9: final is not the blind review"
[ ! -f "$D9/review-round-1.codex.json" ] || fail "case9: a Codex artifact appeared"

echo "dual-review-test.sh: ok"
