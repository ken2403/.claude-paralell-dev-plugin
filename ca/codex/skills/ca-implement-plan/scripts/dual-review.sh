#!/usr/bin/env bash
# Standalone dual-model review orchestrator: Codex second opinion + blind Claude
# review in PARALLEL, then a separate Claude synthesis call adjudicates — the
# same two-call-blind flow as the ca implement loop's final review, invokable
# on any PR at any time (including re-reviews after the loop finished).
#
# Flow:
#   codex-review.sh (offline, background) ──┐   exit!=0 → visible degrade,
#   claude-review.sh (blind, foreground) ───┤   blind JSON becomes final
#                                           ▼
#   synthesize-review.sh → final ca_claude_review.v1 (producer: synthesis)
#   Clean full-coverage Codex output with zero findings skips synthesis.
#
# Outputs in --out-dir (round N):
#   review-round-N.json         the gating verdict (final)
#   review-round-N.blind.json   the blind Claude review (kept for audit)
#   review-round-N.codex.json   the Codex second opinion (when produced)
#   review-round-N.meta.json    leg statuses / degrade reasons (never gates)
#
# The Codex artifact and log stay outside the worktree until the blind Claude
# leg finishes. This prevents accidental current-round leakage even if the
# reviewer explores the worktree broadly.
#
# --claude-only skips the Codex leg entirely (single-model review, same verdict contract).
#
# Preconditions: `claude` on PATH (or CLAUDE_BIN) with the ca plugin resolvable
# (install it, or set CA_CLAUDE_PLUGIN_DIR); network + authenticated `gh`.
# `codex` (or CODEX_BIN) is OPTIONAL — absent means Claude-only with a note.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PR="" PLAN="" WT="" ROUND="1" OUTDIR="" CLAUDE_ONLY=0
while [ $# -gt 0 ]; do
  case "$1" in
    --pr) PR="$2"; shift 2;;
    --plan) PLAN="$2"; shift 2;;
    --worktree) WT="$2"; shift 2;;
    --round) ROUND="$2"; shift 2;;
    --out-dir) OUTDIR="$2"; shift 2;;
    --claude-only) CLAUDE_ONLY=1; shift;;
    *) echo "dual-review: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$PR" ] && [ -n "$PLAN" ] && [ -n "$WT" ] && [ -n "$OUTDIR" ] || {
  echo "usage: dual-review.sh --pr N --plan P --worktree W [--round N] --out-dir D [--claude-only]" >&2
  exit 2
}
[ -f "$PLAN" ] || { echo "dual-review: plan/intent file not found: $PLAN" >&2; exit 2; }
[ -d "$WT" ] || { echo "dual-review: worktree not found: $WT" >&2; exit 2; }
case "$ROUND" in ''|*[!0-9]*|0) echo "dual-review: --round must be a positive integer" >&2; exit 2;; esac
[ -f "$SCRIPT_DIR/validate-review.py" ] || {
  echo "dual-review: bundled validator missing: $SCRIPT_DIR/validate-review.py" >&2; exit 2; }
mkdir -p "$OUTDIR"

FINAL="$OUTDIR/review-round-$ROUND.json"
BLIND="$OUTDIR/review-round-$ROUND.blind.json"
CODEX="$OUTDIR/review-round-$ROUND.codex.json"
META="$OUTDIR/review-round-$ROUND.meta.json"
PRIVATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/ca-dual-review.XXXXXX")"
PRIVATE_CODEX="$PRIVATE_DIR/review.codex.json"
PRIVATE_CODEX_LOG="$PRIVATE_DIR/codex-leg.log"
PRIVATE_BLIND="$PRIVATE_DIR/review.blind.json"
trap 'rm -rf "$PRIVATE_DIR"' EXIT
rm -f "$FINAL" "$BLIND" "$CODEX" "$META"

# Contract: if an earlier round produced a Codex leg and this round degrades,
# prior_findings_rechecked:false must be machine-readable in the meta sidecar.
PRIOR_RECHECK=""
for prior in "$OUTDIR"/review-round-*.codex.json; do
  [ -f "$prior" ] && [ "$prior" != "$CODEX" ] && PRIOR_RECHECK=',"prior_findings_rechecked":false'
done

# --- Both legs in parallel; the blind review never sees the Codex output -----
# --claude-only deliberately runs no second opinion: it is the single-model review that used to
# live behind its own command. The Claude leg is identical either way, so the verdict is the same
# shape; only the meta sidecar records that no second opinion was asked for.
set +e
CODEX_RC=0
if [ "$CLAUDE_ONLY" -eq 1 ]; then
  bash "$SCRIPT_DIR/claude-review.sh" \
    --plan "$PLAN" --pr "$PR" --worktree "$WT" --mode final --round "$ROUND" --out "$PRIVATE_BLIND"
  BLIND_RC=$?
else
  # The supervisor owns a separate process group for the whole Codex launcher. If blind Claude
  # fails first, terminating the supervisor also terminates/reaps the launcher's process group
  # instead of waiting for the full Codex timeout before reporting that no verdict is possible.
  python3 - "$SCRIPT_DIR/codex-review.sh" \
    --plan "$PLAN" --pr "$PR" --worktree "$WT" --round "$ROUND" --out "$PRIVATE_CODEX" \
    > "$PRIVATE_CODEX_LOG" 2>&1 <<'PY' &
import os
import signal
import subprocess
import sys
import time

child = subprocess.Popen(["bash", *sys.argv[1:]], start_new_session=True)


def stop(_signum, _frame):
    try:
        os.killpg(child.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    # Do not call Popen.wait() recursively from a signal handler: on some POSIX runtimes the
    # interrupted wait owns Popen's waitpid lock. Give the launcher's own TERM handler time to
    # kill its nested Codex group, then force-kill any remaining members of this outer group.
    time.sleep(1)
    try:
        os.killpg(child.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    raise SystemExit(143)


signal.signal(signal.SIGTERM, stop)
signal.signal(signal.SIGINT, stop)
raise SystemExit(child.wait())
PY
  CODEX_JOB=$!
  bash "$SCRIPT_DIR/claude-review.sh" \
    --plan "$PLAN" --pr "$PR" --worktree "$WT" --mode final --round "$ROUND" --out "$PRIVATE_BLIND"
  BLIND_RC=$?
  if [ "$BLIND_RC" -ne 0 ]; then
    kill -TERM "$CODEX_JOB" 2>/dev/null || true
  fi
  wait "$CODEX_JOB"
  CODEX_RC=$?
fi
set -e

# Both legs are done: only now may either answer become visible inside the worktree. Bound the
# persisted whole-leg log (not just the inner stderr file) while preserving useful head and tail.
if [ -f "$PRIVATE_CODEX_LOG" ]; then
  python3 - "$PRIVATE_CODEX_LOG" "$OUTDIR/review-round-$ROUND.codex-leg.log" \
    "${CA_CODEX_REVIEW_LOG_BYTES:-65536}" <<'PY'
import sys
from pathlib import Path

source, destination, limit_s = sys.argv[1:]
try:
    limit = int(limit_s)
    if limit < 1:
        raise ValueError
except ValueError:
    limit = 65536
data = Path(source).read_bytes()
if len(data) > limit:
    marker = f"\n--- {len(data) - limit} leg-log bytes omitted ---\n".encode()
    remaining = max(0, limit - len(marker))
    head = remaining // 2
    tail = remaining - head
    data = data[:head] + marker + (data[-tail:] if tail else b"")
Path(destination).write_bytes(data)
PY
fi
[ -f "$PRIVATE_CODEX" ] && cp "$PRIVATE_CODEX" "$CODEX"
[ -f "$PRIVATE_BLIND" ] && cp "$PRIVATE_BLIND" "$BLIND"
for sidecar in stdout stderr; do
  [ -f "$PRIVATE_DIR/review.blind.$sidecar" ] \
    && cp "$PRIVATE_DIR/review.blind.$sidecar" "$OUTDIR/review-round-$ROUND.blind.$sidecar"
done
:

if [ "$BLIND_RC" -ne 0 ]; then
  echo "dual-review: the blind Claude review failed (rc=$BLIND_RC) — no verdict can be produced." >&2
  echo "  (see claude-review.sh output above; the Codex leg exited $CODEX_RC)" >&2
  exit 1
fi

json_field() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d.get(sys.argv[2],sys.argv[3]))' "$@"; }

if [ "$CLAUDE_ONLY" -eq 1 ]; then
  printf '{"dual_review":false,"codex":{"status":"disabled","reason":"claude_only_requested"},"synthesis":{"status":"disabled"}}\n' > "$META"
  cp "$BLIND" "$FINAL"
else
case "$CODEX_RC" in
  0)
    CODEX_PR="$(json_field "$CODEX" pr '')"
    CODEX_HEAD="$(json_field "$CODEX" head_sha '')"
    BLIND_PR="$(json_field "$BLIND" pr '')"
    BLIND_HEAD="$(json_field "$BLIND" head_sha '')"
    if [ "$CODEX_PR" != "$BLIND_PR" ] || [ "$CODEX_HEAD" != "$BLIND_HEAD" ]; then
      printf '{"dual_review":true,"codex":{"status":"invalid","reason":"subject_mismatch"%s},"synthesis":{"status":"skipped_codex_invalid"}}\n' "$PRIOR_RECHECK" > "$META"
      cp "$BLIND" "$FINAL"
    else
      COVERAGE="$(json_field "$CODEX" coverage partial)"
      NFINDINGS="$(python3 -c 'import json,sys; print(len(json.load(open(sys.argv[1])).get("findings",[])))' "$CODEX")"
      if [ "$COVERAGE" = "full" ] && [ "$NFINDINGS" = "0" ]; then
        printf '{"dual_review":true,"codex":{"status":"clean_no_synthesis","coverage":"full","pr":%s,"head_sha":"%s"},"synthesis":{"status":"skipped_clean"}}\n' \
          "$CODEX_PR" "$CODEX_HEAD" > "$META"
        cp "$BLIND" "$FINAL"
      else
        printf '{"dual_review":true,"codex":{"status":"used","coverage":"%s","pr":%s,"head_sha":"%s"},"synthesis":{"status":"pending"}}\n' \
          "$COVERAGE" "$CODEX_PR" "$CODEX_HEAD" > "$META"
        set +e
        bash "$SCRIPT_DIR/synthesize-review.sh" \
          --blind "$BLIND" --second-opinion "$CODEX" --plan "$PLAN" \
          --pr "$PR" --worktree "$WT" --round "$ROUND" --out "$FINAL"
        SYNTH_RC=$?
        set -e
        if [ "$SYNTH_RC" -ne 0 ]; then
          rm -f "$FINAL"
          printf '{"dual_review":true,"codex":{"status":"used","coverage":"%s","pr":%s,"head_sha":"%s"},"synthesis":{"status":"failed","reason":"synthesis_failed","exit_code":%s}}\n' \
            "$COVERAGE" "$CODEX_PR" "$CODEX_HEAD" "$SYNTH_RC" > "$META"
          echo "dual-review: synthesis failed (rc=$SYNTH_RC) — no verdict can be produced." >&2
          exit 1
        fi
        printf '{"dual_review":true,"codex":{"status":"used","coverage":"%s","pr":%s,"head_sha":"%s"},"synthesis":{"status":"used"}}\n' \
          "$COVERAGE" "$CODEX_PR" "$CODEX_HEAD" > "$META"
      fi
    fi
    ;;
  124)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"codex_timeout"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  1)
    printf '{"dual_review":true,"codex":{"status":"invalid","reason":"schema_validation_failed"%s},"synthesis":{"status":"skipped_codex_invalid"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  2)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"invalid_configuration"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  3)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"codex_unavailable"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  4)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"input_fetch_failed"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  5)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"second_opinion_skill_unavailable"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  6)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"review_input_oversized"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  7)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"unsupported_codex_cli"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
  *)
    printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"unexpected_codex_failure"%s},"synthesis":{"status":"skipped_codex_unavailable"}}\n' "$PRIOR_RECHECK" > "$META"
    cp "$BLIND" "$FINAL"
    ;;
esac
fi

python3 "$SCRIPT_DIR/validate-review.py" "$FINAL" \
  --expected-mode final --expected-round "$ROUND" >/dev/null || {
    echo "dual-review: final output failed strict contract validation — no verdict is usable" >&2
    exit 1
  }

VERDICT="$(json_field "$FINAL" verdict unknown)"
echo ""
echo "dual-review: verdict=$VERDICT"
echo "  final: $FINAL"
echo "  meta:  $(cat "$META")"
