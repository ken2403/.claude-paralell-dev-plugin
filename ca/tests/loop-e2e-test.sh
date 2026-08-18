#!/usr/bin/env bash
# Hermetic end-to-end test of the WHOLE ca loop, up to and past opening the draft PR.
#
# Real: git, worktrees, commits, pushes to a real bare remote, every ca script, the
#       strict contract validator, promote-pr's gate, the exchange summary.
# Simulated: GitHub (gh-sim, backed by that bare remote) and the two models.
#
# Two scenarios, because a gate is only proven by both of its answers:
#   A. blocked  — blind Claude finds a blocker, Codex adds a claim, synthesis keeps the
#                 blocker  -> request_changes -> promote REFUSED, PR stays a draft.
#   B. approve  — blind Claude is clean, Codex raises a claim, synthesis refutes it with
#                 evidence -> approve       -> promote SUCCEEDS, PR becomes ready.
#   D. claude_only — CA_DUAL_REVIEW=0, the documented opt-out: no Codex leg, no synthesis,
#                 the blind verdict gates directly and the meta says dual_review:false.
#   C. blocked  — a `blocked` verdict with an EMPTY findings list. This is the case the
#                 contract names explicitly ("blocked never implies approval, even when
#                 findings is empty"), and the only scenario that isolates promote-pr's
#                 verdict check from its blocking-finding check: mutate either one away
#                 and this scenario is what notices.
# Both scenarios run the real synthesis cross-check (ledger ids vs Codex ids, no silent
# drop of blind blockers), so Claude x Codex cooperation is exercised, not assumed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMP="${TMPDIR:-/tmp}/ca-loop-e2e.$$"
# CA_E2E_KEEP=1 preserves the workdirs (repo, remote, worktree, every review artifact).
trap '[ -n "${CA_E2E_KEEP:-}" ] && echo "artifacts kept in $TMP" || rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

# ------------------------------------------------------------------ gh shim
cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
exec python3 "$ROOT/ca/tests/support/gh-sim.py" "\$@"
SH
chmod +x "$TMP/bin/gh"

# ------------------------------------------------- stub implementer (Codex half)
cat > "$TMP/stub-implement.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
WT="$1"; M="$2"
python3 - "$WT" "$M" <<'PY'
import sys
from pathlib import Path

wt, milestone = Path(sys.argv[1]), sys.argv[2]
src = wt / "src/wallet.py"
tests = wt / "tests/test_wallet.py"
if milestone == "1":
    src.write_text(src.read_text() + '''

def withdraw(entries, amount):
    return entries + [-amount]
''')
    text = tests.read_text().replace(
        "from src.wallet import balance",
        "from src.wallet import balance, withdraw")
    tests.write_text(text + '''
    def test_withdraw_appends_negative_entry(self):
        self.assertEqual(withdraw([10], 4), [10, -4])
''')
else:
    src.write_text(src.read_text().replace(
        "def withdraw(entries, amount):\n    return entries + [-amount]",
        '''def withdraw(entries, amount):
    if amount > balance(entries):
        raise ValueError("insufficient funds")
    return entries + [-amount]'''))
    tests.write_text(tests.read_text() + '''
    def test_withdraw_rejects_overdraft(self):
        with self.assertRaises(ValueError):
            withdraw([5], 9)
''')
PY
SH
chmod +x "$TMP/stub-implement.sh"

# ------------------------------------------------------------- stub Claude
cat > "$TMP/bin/claude" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
PROMPT="$*"
OUT="${CA_OUT:?stub claude: CA_OUT must be set by the caller}"
mode=final; round=1
# a review must bind itself to its subject, exactly as a real reviewer does
pr="$(printf '%s\n' "$PROMPT" | sed -n 's/^pr=//p' | head -1)"
head_sha="$(gh pr view "$pr" --json headRefOid --jq .headRefOid)"
case "$PROMPT" in *"mode=checkpoint"*) mode=checkpoint;; esac
case "$PROMPT" in *"round=2"*) round=2;; esac

if [ "${PROMPT#*synthesize-review}" != "$PROMPT" ]; then
  # --- synthesis: adjudicate the Codex claim, never silently drop a blind blocker ---
  if [ "${CA_E2E_SCENARIO:-blocked}" = blocked_empty ]; then
    cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"blocked",
 "summary":"The Codex claim about in-place mutation could not be settled: the test run could not be reproduced in this environment, so no evidence supports either answer.",
 "findings":[],
 "verification":[{"claim":"the committed test suite runs","result":"unknown","evidence":"the runner could not be executed here"}],
 "second_opinion":{"provider":"codex","status":"used","coverage":"full",
   "ledger":[{"id":"X001","adjudication":"unresolved_missing_evidence","evidence":"could not execute the suite to observe mutation"}],
   "prior_findings_rechecked":true},
 "resolved_blind_findings":[]}
JSON
  elif [ "${CA_E2E_SCENARIO:-blocked}" = approve ]; then
    cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"approve",
 "summary":"Both plan tasks are implemented with covering tests. The Codex claim about in-place mutation does not hold: withdraw builds a new list.",
 "findings":[],
 "verification":[{"claim":"pytest tests/test_wallet.py passes","result":"pass","evidence":"2 passed"},
                 {"claim":"withdraw does not mutate its argument","result":"pass","evidence":"src/wallet.py returns entries + [-amount]"}],
 "second_opinion":{"provider":"codex","status":"used","coverage":"full",
   "ledger":[{"id":"X001","adjudication":"refuted","evidence":"src/wallet.py builds a new list; the caller's list is untouched"}],
   "prior_findings_rechecked":true},
 "resolved_blind_findings":[]}
JSON
  else
    cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"request_changes",
 "summary":"The overdraft guard is present but the blind review's blocking finding stands, and the Codex claim is confirmed.",
 "findings":[{"id":"C001","blocking":true,"severity":"blocker","file":"src/wallet.py","line":9,
   "title":"withdraw accepts a non-positive amount","evidence":"src/wallet.py:9 has no lower bound check","recommended_fix":"raise ValueError for amount <= 0"},
  {"id":"X001","blocking":false,"severity":"minor","file":"src/wallet.py","line":9,
   "title":"no type hints on withdraw","evidence":"confirmed by reading src/wallet.py:9","recommended_fix":"annotate the signature"}],
 "verification":[{"claim":"pytest tests/test_wallet.py passes","result":"pass","evidence":"2 passed"}],
 "second_opinion":{"provider":"codex","status":"used","coverage":"full",
   "ledger":[{"id":"X001","adjudication":"confirmed","evidence":"read src/wallet.py:9"}],
   "prior_findings_rechecked":true},
 "resolved_blind_findings":[]}
JSON
  fi
  exit 0
fi

# --- blind review (checkpoint or final) ---
if [ "$mode" = checkpoint ]; then
  cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"blind","round":$round,"mode":"checkpoint","pr":$pr,"head_sha":"$head_sha",
 "verdict":"approve",
 "summary":"Milestone 1 implements withdraw with a covering test. Later milestones are intentionally unbuilt and are not defects.",
 "findings":[],
 "verification":[{"claim":"milestone 1 task is implemented with a test","result":"pass","evidence":"src/wallet.py withdraw + tests/test_wallet.py::test_withdraw_appends_negative_entry"}]}
JSON
  exit 0
fi

if [ "${CA_E2E_SCENARIO:-blocked}" = blocked_empty ]; then
  cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"blind","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"blocked",
 "summary":"The change looks plausible but the suite could not be executed here, so correctness cannot be verified.",
 "findings":[],
 "verification":[{"claim":"the committed test suite runs","result":"unknown","evidence":"the runner could not be executed here"}]}
JSON
elif [ "${CA_E2E_SCENARIO:-blocked}" = approve ]; then
  cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"blind","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"approve",
 "summary":"Both plan tasks are implemented test-first and the suite is green.",
 "findings":[],
 "verification":[{"claim":"pytest tests/test_wallet.py passes","result":"pass","evidence":"2 passed"}]}
JSON
else
  cat > "$OUT" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"blind","round":$round,"mode":"final","pr":$pr,"head_sha":"$head_sha",
 "verdict":"request_changes",
 "summary":"The overdraft guard exists but a non-positive amount is still accepted, which the plan requires rejecting.",
 "findings":[{"id":"C001","blocking":true,"severity":"blocker","file":"src/wallet.py","line":9,
   "title":"withdraw accepts a non-positive amount","evidence":"src/wallet.py:9 has no lower bound check","recommended_fix":"raise ValueError for amount <= 0"}],
 "verification":[{"claim":"pytest tests/test_wallet.py passes","result":"pass","evidence":"2 passed"}]}
JSON
fi
SH
chmod +x "$TMP/bin/claude"

# -------------------------------------------------------------- stub Codex
cat > "$TMP/bin/codex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat > /dev/null   # consume the host-built prompt on stdin
cat <<'JSON'
{"schema_version":"ca_codex_review.v1","coverage":"full",
 "summary":"Reviewed the wallet withdraw change against the plan.",
 "findings":[{"id":"X001","blocking":false,"severity":"minor","file":"src/wallet.py","line":9,
   "title":"withdraw may mutate the caller's entry list","evidence":"advisory: the return path was not fully traced","recommended_fix":"return a new list explicitly"}]}
JSON
SH
chmod +x "$TMP/bin/codex"

export PATH="$TMP/bin:$PATH"
export CLAUDE_BIN="$TMP/bin/claude" CODEX_BIN="$TMP/bin/codex" GH_BIN="$TMP/bin/gh"
export CA_CLAUDE_PLUGIN_DIR="$ROOT/ca/claude"
export PYTHONDONTWRITEBYTECODE=1

run_scenario() {
  local scenario="$1" work="$TMP/$1"
  local claude_only=""
  case "$scenario" in claude_only) claude_only=0; scenario=approve;; esac
  mkdir -p "$work"
  cp "$TMP/stub-implement.sh" "$work/stub-implement.sh"
  echo
  echo "############ scenario: $1 ############"
  env CA_E2E_SCENARIO="$scenario" ${claude_only:+CA_DUAL_REVIEW=0} \
    bash "$ROOT/ca/tests/support/run-loop-e2e.sh" \
    --workdir "$work" --implementer stub --repo-root "$ROOT" > "$work/e2e.log" 2>&1 || {
      cat "$work/e2e.log" >&2
      echo "loop-e2e-test.sh: scenario $scenario FAILED" >&2
      exit 1
    }
  grep -q "PR OPEN: #1 (draft=true)" "$work/e2e.log" || {
    cat "$work/e2e.log" >&2; echo "scenario $scenario never reached PR open" >&2; exit 1; }
  tail -4 "$work/e2e.log"
}

run_scenario blocked
grep -q 'final review path: dual_review=true (CA_DUAL_REVIEW=unset)' "$TMP/blocked/e2e.log" \
  || { echo "the final review is not dual by default" >&2; exit 1; }
grep -q 'final verdict: request_changes (producer=synthesis)' "$TMP/blocked/e2e.log" \
  || { echo "blocked scenario did not go through synthesis" >&2; exit 1; }
grep -q 'request_changes -> PR correctly left as a draft' "$TMP/blocked/e2e.log" \
  || { echo "blocked scenario promoted the PR" >&2; exit 1; }

run_scenario approve
grep -q 'final verdict: approve (producer=synthesis)' "$TMP/approve/e2e.log" \
  || { echo "approve scenario did not go through synthesis" >&2; exit 1; }
grep -q 'approve -> PR promoted to ready' "$TMP/approve/e2e.log" \
  || { echo "approve scenario did not promote" >&2; exit 1; }

run_scenario claude_only
grep -q 'final review path: dual_review=false' "$TMP/claude_only/e2e.log" \
  || { echo "CA_DUAL_REVIEW=0 did not fall back to Claude-only" >&2; exit 1; }
grep -q 'final verdict: approve (producer=blind)' "$TMP/claude_only/e2e.log" \
  || { echo "the Claude-only opt-out did not gate on the blind verdict" >&2; exit 1; }

run_scenario blocked_empty
grep -q 'final verdict: blocked (producer=synthesis)' "$TMP/blocked_empty/e2e.log" \
  || { echo "blocked_empty scenario did not reach a blocked synthesis verdict" >&2; exit 1; }
grep -q 'blocked -> PR correctly left as a draft' "$TMP/blocked_empty/e2e.log" \
  || { echo "a blocked verdict with no findings promoted the PR" >&2; exit 1; }
python3 - "$TMP/blocked_empty/run-artifacts/review-round-1.json" <<'PY' || exit 1
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["verdict"] == "blocked" and d["findings"] == [], "scenario C must be blocked with zero findings"
print("scenario C verified: verdict=blocked, findings=[] — promote still refused")
PY

echo
echo "loop-e2e-test.sh: ok"
