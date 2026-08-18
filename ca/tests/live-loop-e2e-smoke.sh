#!/usr/bin/env bash
# Opt-in LIVE end-to-end run of the ca loop: real Codex implements, real Claude reviews,
# real Codex gives the second opinion, real Claude synthesizes. Same harness as the
# hermetic loop-e2e-test.sh — only the model layer changes.
#
# GitHub stays simulated on purpose. "The E2E must always reach PR open" and "the E2E
# opens real pull requests on someone's account" cannot both be true; gh-sim is backed by
# a real bare remote, so pushes, diffs, draft state and promotion are all real git/state
# transitions without touching anybody's GitHub.
#
#   bash ca/tests/live-loop-e2e-smoke.sh --run
#   CA_LIVE_SMOKE_BUDGET_USD=40 bash ca/tests/live-loop-e2e-smoke.sh --run
set -euo pipefail

if [ "${1:-}" = "--run" ]; then
  shift
elif [ "${RUN_CA_LIVE_LOOP_E2E:-0}" != "1" ]; then
  echo "SKIP: pass --run or set RUN_CA_LIVE_LOOP_E2E=1 to run the real Claude/Codex loop E2E"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
REAL_CLAUDE="$(command -v claude)" || { echo "claude not on PATH" >&2; exit 1; }
REAL_CODEX="$(command -v codex)"   || { echo "codex not on PATH" >&2; exit 1; }
command -v jq >/dev/null || { echo "jq is required by gh-sim" >&2; exit 1; }

TMP="${TMPDIR:-/tmp}/ca-live-loop-e2e.$$"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "live loop E2E failed; artifacts under $TMP (kept for inspection)" >&2
    [ -f "$TMP/work/e2e.log" ] && tail -60 "$TMP/work/e2e.log" >&2
    exit "$status"
  fi
  [ -n "${CA_E2E_KEEP:-}" ] && echo "artifacts kept in $TMP" || rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/work"

cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
exec python3 "$ROOT/ca/tests/support/gh-sim.py" "\$@"
SH
chmod +x "$TMP/bin/gh"

# The budget is a runaway guard, not a per-call estimate: `claude` refuses up front once the
# session/account spend already exceeds it, so keep it generous and overridable.
BUDGET_USD="${CA_LIVE_SMOKE_BUDGET_USD:-25}"
cat > "$TMP/bin/claude-live" <<SH
#!/usr/bin/env bash
exec "$REAL_CLAUDE" --tools "Read,Grep,Glob,Bash,Skill" --no-session-persistence \\
  --max-budget-usd $BUDGET_USD "\$@"
SH
chmod +x "$TMP/bin/claude-live"

export PATH="$TMP/bin:$PATH"
export CLAUDE_BIN="$TMP/bin/claude-live" CODEX_BIN="$REAL_CODEX" GH_BIN="$TMP/bin/gh"
export CA_CLAUDE_PLUGIN_DIR="$ROOT/ca/claude"
export CA_CLAUDE_PERMISSION_MODE="${CA_CLAUDE_PERMISSION_MODE:-dontAsk}"
export CA_CODEX_REVIEW_TIMEOUT="${CA_CODEX_REVIEW_TIMEOUT:-900}"
export PYTHONDONTWRITEBYTECODE=1

bash "$ROOT/ca/tests/support/run-loop-e2e.sh" \
  --workdir "$TMP/work" --implementer codex --repo-root "$ROOT" 2>&1 | tee "$TMP/work/e2e.log"

grep -q 'PR OPEN: #1 (draft=true)' "$TMP/work/e2e.log" || {
  echo "the live loop never reached PR open" >&2; exit 1; }

# ---------------------------------------------------------------------------
# The orchestrator SKIPS synthesis when Codex returns a clean full-coverage pass,
# so leaving the synthesis leg to chance would leave the one place Codex findings
# can move the verdict untested on most runs. Exercise it directly, always.
# ---------------------------------------------------------------------------
ART="$TMP/work/run-artifacts"
BLIND="$ART/review-round-1.blind.json"
CODEX_JSON="$ART/review-round-1.codex.json"
if [ -f "$CODEX_JSON" ]; then
  echo
  echo "=== Live synthesis leg (run directly so it is never left untested) ==="
  bash "$ROOT/ca/codex/skills/ca-implement-plan/scripts/synthesize-review.sh" \
    --blind "$BLIND" --second-opinion "$CODEX_JSON" \
    --plan "$TMP/work/repo/docs/ca/plans/wallet-withdraw.md" \
    --pr 1 --worktree "$TMP/work/repo" --round 1 --out "$ART/live-synthesis.json"
  python3 "$ROOT/ca/claude/skills/review-pr/scripts/validate-review.py" "$ART/live-synthesis.json" \
    --blind "$BLIND" --second-opinion "$CODEX_JSON" \
    --expected-mode final --expected-round 1 --expected-producer synthesis
  echo "live synthesis produced a contract-valid adjudicated verdict"
else
  echo "NOTE: the Codex leg degraded this run, so there was no second opinion to synthesize." >&2
  grep -o '"codex":{[^}]*}' "$ART/review-round-1.meta.json" >&2 || true
  exit 1
fi

echo
echo "live-loop-e2e-smoke.sh: ok"
