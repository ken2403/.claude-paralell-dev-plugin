#!/usr/bin/env bash
# Promote a ca draft PR only after a strict, final-mode approval.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GH_BIN="${GH_BIN:-gh}"
REVIEW="" PR="" ROUND=""
while [ $# -gt 0 ]; do
  case "$1" in
    --review) REVIEW="$2"; shift 2;;
    --pr) PR="$2"; shift 2;;
    --round) ROUND="$2"; shift 2;;
    *) echo "promote-pr: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$REVIEW" ] && [ -n "$PR" ] && [ -n "$ROUND" ] || {
  echo "usage: promote-pr.sh --review REVIEW.json --pr N --round N" >&2
  exit 2
}
case "$ROUND" in ''|*[!0-9]*|0) echo "promote-pr: --round must be a positive integer" >&2; exit 2;; esac

command -v "$GH_BIN" >/dev/null 2>&1 || {
  echo "promote-pr: '$GH_BIN' not found on PATH" >&2
  exit 1
}

# An approval is only an approval OF SOMETHING. Bind it to this PR and to the exact commit
# that was reviewed: without this, a verdict written for another PR — or for a commit that
# has since been pushed over — still opens the gate.
HEAD_SHA="$("$GH_BIN" pr view "$PR" --json headRefOid --jq .headRefOid)" || {
  echo "promote-pr: cannot resolve the PR head commit; draft PR remains blocked" >&2
  exit 1
}
[ -n "$HEAD_SHA" ] || { echo "promote-pr: empty PR head commit" >&2; exit 1; }

python3 "$SCRIPT_DIR/validate-review.py" "$REVIEW" \
  --expected-mode final --expected-round "$ROUND" \
  --require-subject --expected-pr "$PR" --expected-head-sha "$HEAD_SHA" >/dev/null || {
    echo "promote-pr: review is invalid or is not an approval of PR #$PR at $HEAD_SHA;" >&2
    echo "            draft PR remains blocked" >&2
    exit 1
  }

python3 - "$REVIEW" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    review = json.load(handle)
if review["verdict"] != "approve":
    print(f"promote-pr: verdict is {review['verdict']}, not approve", file=sys.stderr)
    raise SystemExit(1)
if any(finding["blocking"] for finding in review["findings"]):
    print("promote-pr: approval contains a blocking finding", file=sys.stderr)
    raise SystemExit(1)
PY

"$GH_BIN" pr ready "$PR"
