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
#      in its private snapshot or the public output directory. Publishing the blind
#      answer early would turn the second opinion into an echo of the first.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/claude/skills/dual-review/scripts/dual-review.sh"
TMP="${TMPDIR:-/tmp}/dual-review-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"

fail() { echo "FAIL: $*" >&2; exit 1; }

PLAN="$TMP/plan.md"; printf '# Plan\nOne task.\n' > "$PLAN"
WT="$TMP/wt"; mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" config user.name test
git -C "$WT" config user.email test@example.com
printf 'base\n' > "$WT/a.txt"
git -C "$WT" add a.txt
git -C "$WT" commit -qm base
export GH_HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

# --- gh stub (host-side PR fetch inside codex-review.sh) ---------------------
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr view")
    [ "${GH_MODE:-ok}" = ok ] || exit 1
    case "$*" in
      *"--jq .headRefOid"*) printf '%s\n' "${GH_HEAD_SHA:?}";;
      *) printf '{"number":7,"title":"t","state":"OPEN","isDraft":true,"baseRefName":"main","headRefName":"b","headRefOid":"%s","url":"u"}\n' "${GH_HEAD_SHA:?}";;
    esac
    ;;
  "pr diff") if [ "${3:-}" = "--name-only" ] || [ "${4:-}" = "--name-only" ]; then printf 'a.txt\n'; else printf 'diff --git a/a.txt b/a.txt\n+x\n'; fi;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/gh"; export GH_BIN="$TMP/bin/gh"

# --- claude stub: blind review vs synthesis, keyed off the prompt ------------
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  *synthesize-review*)
    [ "${CLAUDE_MODE:-ok}" != synthesis_fail ] || exit 9
    printf '{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":1,"mode":"final","pr":7,"head_sha":"%s","verdict":"request_changes","summary":"synth","findings":[{"id":"C001","blocking":true,"severity":"major","title":"blind blocker kept","evidence":"a.txt:1","recommended_fix":"fix it"}],"verification":[],"second_opinion":{"provider":"codex","status":"used","coverage":"full","ledger":[{"id":"X001","adjudication":"refuted","evidence":"checked the diff"}],"prior_findings_rechecked":true},"resolved_blind_findings":[]}\n' "${GH_HEAD_SHA:?}" > "${CA_OUT:?}"
    ;;
  *review-pr*)
    case "${CLAUDE_MODE:-ok}" in
      ok|synthesis_fail|different_subject) ;;
      fail) exit 1;;
      fail_after_codex_start)
        i=0; while [ ! -s "${CODEX_DESCENDANT_PID:?}" ] && [ "$i" -lt 40 ]; do sleep 0.05; i=$((i + 1)); done
        exit 1
        ;;
      sleep) sleep 5;;
      *) exit 9;;
    esac
    review_round=1
    case "$*" in *"round=2"*) review_round=2;; esac
    blind_head="${GH_HEAD_SHA:?}"
    [ "${CLAUDE_MODE:-ok}" != different_subject ] || blind_head=0000000000000000000000000000000000000000
    printf '{"schema_version":"ca_claude_review.v1","producer":"blind","round":%s,"mode":"final","pr":7,"head_sha":"%s","verdict":"request_changes","summary":"blind","findings":[{"id":"C001","blocking":true,"severity":"major","title":"blind blocker","evidence":"a.txt:1","recommended_fix":"fix it"}],"verification":[]}\n' "$review_round" "$blind_head" > "${CA_OUT:?}"
    ;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/claude"; export CLAUDE_BIN="$TMP/bin/claude"

# --- codex stub: reply on stdout, shape keyed off CODEX_MODE -----------------
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-} ${2:-}" = "exec --help" ]; then
  printf '%s\n' '--ignore-user-config --ignore-rules --ephemeral --disable --sandbox --output-schema'
  exit 0
fi
if [ "${1:-} ${2:-}" = "features list" ]; then
  printf '%s stable true\n' apps browser_use browser_use_external browser_use_full_cdp_access \
    computer_use hooks image_generation in_app_browser multi_agent plugins remote_plugin \
    plugin_sharing skill_mcp_dependency_install
  exit 0
fi
cat > /dev/null   # consume the prompt on stdin
case "${CODEX_MODE:-finding}" in
  finding) printf '{"schema_version":"ca_codex_review.v1","pr":7,"head_sha":"%s","summary":"codex","coverage":"full","findings":[{"id":"X001","blocking":true,"severity":"major","file":"a.txt","line":1,"title":"codex claim","evidence":"e","recommended_fix":"f"}]}\n' "${GH_HEAD_SHA:?}";;
  clean)   printf '{"schema_version":"ca_codex_review.v1","pr":7,"head_sha":"%s","summary":"codex","coverage":"full","findings":[]}\n' "${GH_HEAD_SHA:?}";;
  timeout)
    echo "codex-progress-before-timeout" >&2
    i=0; while [ "$i" -lt 300 ]; do echo "codex-timeout-padding-$i-xxxxxxxxxxxxxxxx" >&2; i=$((i + 1)); done
    echo "codex-progress-at-timeout-tail" >&2
    sleep 5
    ;;
  invalid) printf '{"schema_version":"wrong"}\n';;
  longtree)
    sleep 5 &
    child=$!
    printf '%s\n' "$child" > "${CODEX_DESCENDANT_PID:?}"
    wait "$child"
    ;;
  leakprobe)
    sleep 1   # let the (instant) blind leg finish first
    { ls "${CA_TEST_OUTDIR:?}" 2>/dev/null | grep -c 'blind' || true; } > "${CA_TEST_LEAK_MARKER:?}"
    printf '{"schema_version":"ca_codex_review.v1","pr":7,"head_sha":"%s","summary":"codex","coverage":"full","findings":[]}\n' "${GH_HEAD_SHA:?}"
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
grep -q '"reason":"codex_unavailable"' "$D3/review-round-1.meta.json" || fail "case3: meta missing exact unavailable reason"

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

# 5b. Blind failure cancels a slow Codex process group promptly instead of waiting its timeout.
D5B="$TMP/out/case5b"
export CODEX_DESCENDANT_PID="$TMP/codex-descendant.pid"
rm -f "$CODEX_DESCENDANT_PID"
started="$(date +%s)"
set +e
CA_CODEX_REVIEW_TIMEOUT=30 CODEX_MODE=longtree CLAUDE_MODE=fail_after_codex_start \
  bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D5B" \
  >/dev/null 2>&1
RC=$?
set -e
elapsed=$(( $(date +%s) - started ))
[ "$RC" -ne 0 ] || fail "case5b: expected blind failure"
[ "$elapsed" -lt 5 ] || fail "case5b: blind failure waited ${elapsed}s for slow Codex"
[ -s "$CODEX_DESCENDANT_PID" ] || fail "case5b: slow Codex descendant never started"
descendant="$(cat "$CODEX_DESCENDANT_PID")"
! kill -0 "$descendant" 2>/dev/null || fail "case5b: Codex descendant $descendant survived cancellation"

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
CA_CODEX_REVIEW_TIMEOUT=1 CA_CODEX_REVIEW_LOG_BYTES=1024 CODEX_MODE=timeout bash "$SCRIPT" \
  --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D7" >/dev/null
cmp -s "$D7/review-round-1.json" "$D7/review-round-1.blind.json" \
  || fail "case7: timeout degrade did not fall back to blind"
grep -q '"reason":"codex_timeout"' "$D7/review-round-1.meta.json" \
  || fail "case7: meta does not distinguish a Codex timeout"
grep -q 'codex-progress-before-timeout' "$D7/review-round-1.codex-leg.log" \
  || fail "case7: Codex progress before timeout was discarded"
grep -q 'codex-progress-at-timeout-tail' "$D7/review-round-1.codex-leg.log" \
  || fail "case7: Codex timeout diagnostic tail was discarded"
grep -q 'leg-log bytes omitted' "$D7/review-round-1.codex-leg.log" \
  || fail "case7: persisted leg log was not bounded with an omission marker"
[ "$(wc -c < "$D7/review-round-1.codex-leg.log" | tr -d ' ')" -le 1024 ] \
  || fail "case7: persisted leg log exceeded CA_CODEX_REVIEW_LOG_BYTES"

# 8. Invalid Codex launcher configuration is distinguished from runtime unavailability
D8="$TMP/out/case8"
CA_CODEX_REVIEW_REASONING_EFFORT=turbo bash "$SCRIPT" \
  --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D8" >/dev/null
cmp -s "$D8/review-round-1.json" "$D8/review-round-1.blind.json" \
  || fail "case8: invalid configuration did not fall back to blind"
grep -q '"reason":"invalid_configuration"' "$D8/review-round-1.meta.json" \
  || fail "case8: meta does not distinguish invalid configuration"

# 9. the blind verdict must not be readable by the Codex leg while it is still reviewing
D9="$TMP/out/case9"
export CA_TEST_OUTDIR="$D9" CA_TEST_LEAK_MARKER="$TMP/leak.marker"
CODEX_MODE=leakprobe bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" --round 1 --out-dir "$D9" >/dev/null
[ "$(cat "$TMP/leak.marker")" = "0" ] \
  || fail "case9: the Codex leg could see $(cat "$TMP/leak.marker") blind artifact(s) mid-review"
[ -f "$D9/review-round-1.blind.json" ] || fail "case9: the blind review was not published afterwards"
unset CA_TEST_OUTDIR CA_TEST_LEAK_MARKER

# 10. --claude-only must not start a Codex process at all
D10="$TMP/out/case10"
CODEX_MARKER="$TMP/codex.invoked"; rm -f "$CODEX_MARKER"
cat > "$TMP/bin/codex-tattle" <<SH
#!/usr/bin/env bash
echo invoked >> "$CODEX_MARKER"
cat > /dev/null
printf '{"schema_version":"ca_codex_review.v1","pr":7,"head_sha":"%s","summary":"x","coverage":"full","findings":[]}\n' "${GH_HEAD_SHA:?}"
SH
chmod +x "$TMP/bin/codex-tattle"
CODEX_BIN="$TMP/bin/codex-tattle" bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D10" --claude-only >/dev/null
[ ! -f "$CODEX_MARKER" ] || fail "case10: --claude-only still ran the Codex leg"
grep -q '"dual_review":false' "$D10/review-round-1.meta.json" || fail "case10: meta does not record the single-model run"
grep -q '"status":"disabled"' "$D10/review-round-1.meta.json" || fail "case10: meta does not disable the second opinion"
cmp -s "$D10/review-round-1.json" "$D10/review-round-1.blind.json" || fail "case10: final is not the blind review"
[ ! -f "$D10/review-round-1.codex.json" ] || fail "case10: a Codex artifact appeared"

# 11. Schema-invalid Codex output maps to the exact invalid reason.
D11="$TMP/out/case11"
CODEX_MODE=invalid bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D11" >/dev/null
grep -q '"reason":"schema_validation_failed"' "$D11/review-round-1.meta.json" \
  || fail "case11: schema-invalid reason mapping regressed"

# 12. Host input-fetch failure maps to its exact reason.
D12="$TMP/out/case12"
GH_MODE=fail bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D12" >/dev/null
grep -q '"reason":"input_fetch_failed"' "$D12/review-round-1.meta.json" \
  || fail "case12: input-fetch reason mapping regressed"

# 13. Missing bundled skill is exercised through a complete temporary launcher copy.
D13="$TMP/out/case13"
BROKEN_SKILL="$TMP/broken-skill-launcher"
cp -R "$ROOT/ca/claude/skills/dual-review" "$BROKEN_SKILL"
rm -f "$BROKEN_SKILL/references/second-opinion-skill.md"
bash "$BROKEN_SKILL/scripts/dual-review.sh" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D13" >/dev/null
grep -q '"reason":"second_opinion_skill_unavailable"' "$D13/review-round-1.meta.json" \
  || fail "case13: missing-skill reason mapping regressed"

# 14. Oversized input maps to its exact reason.
D14="$TMP/out/case14"
CA_CODEX_REVIEW_PLAN_BYTES=1 bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D14" >/dev/null
grep -q '"reason":"review_input_oversized"' "$D14/review-round-1.meta.json" \
  || fail "case14: oversized-input reason mapping regressed"

# 15. Unexpected launcher exit maps to the default reason.
D15="$TMP/out/case15"
BROKEN_RUNTIME="$TMP/unexpected-launcher"
cp -R "$ROOT/ca/claude/skills/dual-review" "$BROKEN_RUNTIME"
printf '#!/usr/bin/env bash\nexit 9\n' > "$BROKEN_RUNTIME/scripts/codex-review.sh"
chmod +x "$BROKEN_RUNTIME/scripts/codex-review.sh"
bash "$BROKEN_RUNTIME/scripts/dual-review.sh" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D15" >/dev/null
grep -q '"reason":"unexpected_codex_failure"' "$D15/review-round-1.meta.json" \
  || fail "case15: unexpected-failure reason mapping regressed"

# 16. Synthesis failure removes any final verdict and replaces pending meta with failed.
D16="$TMP/out/case16"
set +e
CODEX_MODE=finding CLAUDE_MODE=synthesis_fail bash "$SCRIPT" --pr 7 --plan "$PLAN" \
  --worktree "$WT" --round 1 --out-dir "$D16" >/dev/null 2>&1
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "case16: synthesis failure unexpectedly succeeded"
[ ! -f "$D16/review-round-1.json" ] || fail "case16: unusable final survived synthesis failure"
grep -q '"synthesis":{"status":"failed","reason":"synthesis_failed","exit_code":' \
  "$D16/review-round-1.meta.json" || fail "case16: synthesis failure meta is not explicit"

# 17. An older Codex CLI is rejected before launch with an exact compatibility reason.
D17="$TMP/out/case17"
cat > "$TMP/bin/old-codex" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "exec --help") echo '--sandbox --output-schema'; exit 0;;
  *) exit 1;;
esac
SH
chmod +x "$TMP/bin/old-codex"
CODEX_BIN="$TMP/bin/old-codex" bash "$SCRIPT" --pr 7 --plan "$PLAN" --worktree "$WT" \
  --round 1 --out-dir "$D17" >/dev/null
grep -q '"reason":"unsupported_codex_cli"' "$D17/review-round-1.meta.json" \
  || fail "case17: unsupported CLI reason mapping regressed"

# 18. Codex and blind Claude subjects must match before clean skip or synthesis.
D18="$TMP/out/case18"
CODEX_MODE=clean CLAUDE_MODE=different_subject bash "$SCRIPT" --pr 7 --plan "$PLAN" \
  --worktree "$WT" --round 1 --out-dir "$D18" >/dev/null
cmp -s "$D18/review-round-1.json" "$D18/review-round-1.blind.json" \
  || fail "case18: subject mismatch did not fall back to blind"
grep -q '"reason":"subject_mismatch"' "$D18/review-round-1.meta.json" \
  || { cat "$D18/review-round-1.meta.json" >&2; fail "case18: cross-leg subject mismatch was not recorded"; }

echo "dual-review-test.sh: ok"
