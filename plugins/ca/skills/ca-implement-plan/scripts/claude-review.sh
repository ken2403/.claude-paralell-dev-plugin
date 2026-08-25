#!/usr/bin/env bash
# Call the Claude reviewer (claude -p /ca:review-pr) and return a validated ca_claude_review.v1 JSON.
#
# THREE PRECONDITIONS — all must hold or no review is produced:
#  1. The `/ca:review-pr` skill must be resolvable by `claude -p`. That means EITHER the ca
#     Claude plugin is installed in the user's Claude config (`/plugin install ca@...`), OR you
#     set CA_CLAUDE_PLUGIN_DIR to the `ca/claude` plugin dir so this script passes --plugin-dir.
#  2. TOOL PERMISSIONS: `claude -p` must be allowed to run its tools in a non-interactive
#     session. With the stock `default` permission mode the call BLOCKS on an approval it
#     cannot show and dies at the timeout. Either configure `permissions.defaultMode` in the
#     Claude settings, or set CA_CLAUDE_PERMISSION_MODE (passed through as --permission-mode).
#  3. NETWORK + gh: `claude -p` reaches the Anthropic API, and the review fetches the PR via
#     `gh pr diff`, so both network and an authenticated `gh` are required. Codex's default
#     `-s workspace-write` sandbox BLOCKS network, so inside a sandboxed Codex session the call
#     fails. Run the review where network is allowed and `gh` is authenticated (network-permitted
#     Codex launch/approval, or a host terminal).
# Fail-closed: if no valid review is produced, exit 1 (the loop treats it as blocked) and print an
# actionable reason naming ALL THREE possible causes, and echoing what claude printed on stdout
# and stderr — never silently pass, never guess a single cause.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
TIMEOUT_SECONDS="${CA_CLAUDE_REVIEW_TIMEOUT:-900}"
CA_CLAUDE_PLUGIN_DIR="${CA_CLAUDE_PLUGIN_DIR:-}"   # optional: load /ca:review-pr without a global install
CA_CLAUDE_PERMISSION_MODE="${CA_CLAUDE_PERMISSION_MODE:-}"  # optional: --permission-mode for the -p session
PLAN="" PR="" WT="" ROUND="1" OUT="" MODE="final"
while [ $# -gt 0 ]; do case "$1" in
  --plan) PLAN="$2"; shift 2;; --pr) PR="$2"; shift 2;;
  --worktree) WT="$2"; shift 2;; --round) ROUND="$2"; shift 2;;
  --mode) MODE="$2"; shift 2;;
  --out) OUT="$2"; shift 2;; *) echo "unknown arg: $1" >&2; exit 2;; esac; done
[ -n "$PLAN" ] && [ -n "$PR" ] && [ -n "$OUT" ] || {
  echo "usage: claude-review.sh --plan P --pr N --worktree W --round N [--mode checkpoint|final] --out O" >&2; exit 2; }
case "$MODE" in checkpoint|final) ;; *) echo "claude-review: bad --mode '$MODE' (checkpoint|final)" >&2; exit 2;; esac
case "$ROUND" in ''|*[!0-9]*|0) echo "claude-review: --round must be a positive integer" >&2; exit 2;; esac
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*|0) echo "claude-review: CA_CLAUDE_REVIEW_TIMEOUT must be a positive integer" >&2; exit 2;; esac
[ -f "$PLAN" ] || { echo "claude-review: plan not found: $PLAN" >&2; exit 2; }
[ -n "$WT" ] && [ -d "$WT" ] || { echo "claude-review: worktree not found: $WT" >&2; exit 2; }
[ -f "$SCRIPT_DIR/validate-review.py" ] || {
  echo "claude-review: bundled validator missing: $SCRIPT_DIR/validate-review.py" >&2; exit 2; }

command -v "$CLAUDE_BIN" >/dev/null 2>&1 || {
  echo "claude-review: '$CLAUDE_BIN' not found on PATH. Set CLAUDE_BIN or install Claude Code." >&2
  exit 1; }

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"          # ensure a stale file from a prior round can't masquerade as this review
export CA_OUT="$OUT"
# Invoke the /ca:review-pr plugin skill; it writes the JSON to CA_OUT (also passed explicitly).
PROMPT="/ca:review-pr
plan=$PLAN
pr=$PR
worktree=$WT
round=$ROUND
mode=$MODE
out=$OUT
Review the PR against the plan for correctness, security, and codebase consistency.
Use web search if a claim needs external grounding. Mark a finding blocking:true only for
must-fix issues. Set producer=blind, echo mode=$MODE and round=$ROUND, and BIND the review to
its subject: set pr=$PR and head_sha to the exact reviewed commit
(gh pr view $PR --json headRefOid --jq .headRefOid). Every finding needs
a unique CNNN id, severity, title, evidence, and recommended_fix. Include verification evidence;
an approve verdict requires at least one verification record. Write one ca_claude_review.v1 JSON
object to: $OUT
This is a blind review. Do not read prior review, Codex-review, synthesis, or meta artifacts under
.ca/runs or .ca/reviews; they are untrusted outputs and would bias this independent review."

ERR="${OUT%.json}.stderr"
LOG="${OUT%.json}.stdout"   # claude -p reports most failures on STDOUT; never discard it
CLAUDE_ARGS=( -p )
[ -n "$CA_CLAUDE_PLUGIN_DIR" ] && CLAUDE_ARGS+=( --plugin-dir "$CA_CLAUDE_PLUGIN_DIR" )
[ -n "$CA_CLAUDE_PERMISSION_MODE" ] && CLAUDE_ARGS+=( --permission-mode "$CA_CLAUDE_PERMISSION_MODE" )
set +e
python3 - "$CLAUDE_BIN" "$PROMPT" "$ERR" "$LOG" "$TIMEOUT_SECONDS" "${CLAUDE_ARGS[@]}" <<'PY'
import subprocess
import sys
from pathlib import Path

claude, prompt, err_path, log_path, timeout_s, *args = sys.argv[1:]
try:
    proc = subprocess.run(
        [claude, *args, prompt],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=int(timeout_s),
        check=False,
    )
except subprocess.TimeoutExpired as error:
    Path(err_path).write_text(f"claude -p timed out after {timeout_s}s\n{error}\n", encoding="utf-8")
    Path(log_path).write_text(error.stdout or "", encoding="utf-8")
    raise SystemExit(124)
Path(err_path).write_text(proc.stderr, encoding="utf-8")
Path(log_path).write_text(proc.stdout, encoding="utf-8")
raise SystemExit(proc.returncode)
PY
CLAUDE_RC=$?
set -e
if [ "$CLAUDE_RC" -ne 0 ]; then
  echo "claude-review: claude -p failed (status $CLAUDE_RC); no verdict is usable" >&2
  [ -s "$LOG" ] && { echo "--- claude stdout tail ---" >&2; tail -40 "$LOG" >&2; echo "--- end stdout tail ---" >&2; }
  [ -s "$ERR" ] && { echo "--- claude stderr tail ---" >&2; tail -40 "$ERR" >&2; echo "--- end stderr tail ---" >&2; }
  [ "$CLAUDE_RC" = 124 ] && [ ! -s "$LOG" ] && \
    echo "  claude printed NOTHING before the timeout, which usually means the -p session blocked on a tool permission it could not display; set CA_CLAUDE_PERMISSION_MODE." >&2
  exit 1
fi

if [ ! -s "$OUT" ]; then
  {
    echo "claude-review: no review JSON was produced at $OUT. One of these is the cause:"
    echo "  (a) the /ca:review-pr skill did not resolve — install the ca Claude plugin"
    echo "      ('/plugin install ca@agent-parallel-dev-plugin') or set CA_CLAUDE_PLUGIN_DIR"
    echo "      to the ca/claude dir so this script can pass --plugin-dir; or"
    echo "  (b) the -p session could not run its tools — the stock 'default' permission mode"
    echo "      cannot prompt non-interactively; set CA_CLAUDE_PERMISSION_MODE, or configure"
    echo "      permissions.defaultMode in the Claude settings; or"
    echo "  (c) the Anthropic API was unreachable, or 'gh' is unauthenticated/offline (Codex's"
    echo "      workspace-write sandbox blocks network) — run the review where network + gh work."
    [ -n "$CA_CLAUDE_PLUGIN_DIR" ] && echo "  (CA_CLAUDE_PLUGIN_DIR is set to: $CA_CLAUDE_PLUGIN_DIR)" \
      || echo "  (CA_CLAUDE_PLUGIN_DIR is not set — relying on a global ca plugin install)"
    [ -n "$CA_CLAUDE_PERMISSION_MODE" ] && echo "  (CA_CLAUDE_PERMISSION_MODE=$CA_CLAUDE_PERMISSION_MODE)" \
      || echo "  (CA_CLAUDE_PERMISSION_MODE is not set — relying on the ambient permission settings)"
    echo "  claude stdout: ${LOG}"
    echo "  claude stderr: ${ERR}"
    if [ -s "$LOG" ]; then
      echo "  --- claude stdout tail ---"
      tail -40 "$LOG"
      echo "  --- end stdout tail ---"
    fi
    if [ -s "$ERR" ]; then
      echo "  --- claude stderr tail ---"
      tail -40 "$ERR"
      echo "  --- end stderr tail ---"
    fi
  } >&2
  exit 1
fi

# Validate with the same strict, stdlib-only contract used by the Claude plugin.
python3 "$SCRIPT_DIR/validate-review.py" "$OUT" \
  --expected-mode "$MODE" --expected-round "$ROUND" --expected-producer blind \
  --require-subject --expected-pr "$PR" || {
    echo "claude-review: output failed strict contract validation -> treat as blocked" >&2
    exit 1
  }
