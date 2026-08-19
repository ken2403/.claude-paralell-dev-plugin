#!/usr/bin/env bash
# post-summary.sh must summarize only the gating verdict files: the dual-review
# wiring writes review-round-N.{meta,blind,codex}.json siblings that are NOT
# rounds, and a naive review-round-*.json glob would leak them into the PR
# comment as duplicate/garbage rounds.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/codex/skills/ca-implement-plan/scripts/post-summary.sh"
TMP="${TMPDIR:-/tmp}/post-summary-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/run"

# Stub gh: capture the comment body instead of talking to GitHub.
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
# expected: gh pr comment <pr> --body-file <file>
cp "$5" "${GH_CAPTURE:?}"
SH
chmod +x "$TMP/bin/gh"

RUN="$TMP/run"
printf '{"verdict":"request_changes","summary":"checkpoint summary","findings":[]}\n' \
  > "$RUN/review-checkpoint-1.json"
printf '{"verdict":"approve","summary":"final round summary","findings":[]}\n' \
  > "$RUN/review-round-1.json"
# Dual-review siblings that must NOT appear as rounds:
printf '{"verdict":"GARBAGE_BLIND","summary":"blind"}\n' > "$RUN/review-round-1.blind.json"
printf '{"schema_version":"ca_codex_review.v1","summary":"GARBAGE_CODEX","coverage":"full","findings":[]}\n' \
  > "$RUN/review-round-1.codex.json"
printf '{"dual_review":true,"codex":{"status":"unavailable","reason":"codex_unavailable_or_oversized"},"synthesis":{"status":"skipped_codex_unavailable"}}\n' \
  > "$RUN/review-round-1.meta.json"

OUT="$TMP/comment.md"
GH_CAPTURE="$OUT" PATH="$TMP/bin:$PATH" bash "$SCRIPT" "$RUN" 99 >/dev/null

grep -q "Checkpoint 1" "$OUT" || { echo "FAIL: checkpoint round missing" >&2; exit 1; }
grep -q "Round 1" "$OUT" || { echo "FAIL: final round missing" >&2; exit 1; }
grep -q "GARBAGE" "$OUT" && { echo "FAIL: sibling files leaked into the summary" >&2; exit 1; }
[ "$(grep -c "Claude verdict" "$OUT")" -eq 2 ] || { echo "FAIL: expected exactly 2 rounds" >&2; cat "$OUT" >&2; exit 1; }
# The meta sidecar must still annotate its real round:
grep -q "codex_unavailable_or_oversized" "$OUT" || { echo "FAIL: meta sidecar not surfaced" >&2; exit 1; }

echo "post-summary-test.sh: ok"
