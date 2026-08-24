#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
mode="${1:-}"
pr="${2:-}"
method="squash"
if [ "$mode" = --merge ]; then
  [ "${3:-}" = --method ] || { echo "usage: merge-pr.sh --merge PR --method squash|merge|rebase" >&2; exit 2; }
  method="${4:-}"
elif [ "$mode" != --preflight ]; then
  echo "usage: merge-pr.sh --preflight PR | --merge PR --method squash|merge|rebase" >&2
  exit 2
fi
case "$pr" in ''|*[!0-9]*) echo "merge-pr: PR must be numeric" >&2; exit 2;; esac
case "$method" in squash|merge|rebase) ;; *) echo "merge-pr: invalid method: $method" >&2; exit 2;; esac

gh_bin="${GH_BIN:-gh}"
command -v "$gh_bin" >/dev/null 2>&1 || { echo "merge-pr: gh not found" >&2; exit 1; }

preflight_json="$($gh_bin pr view "$pr" --json state,isDraft,mergeable,mergeStateStatus,reviewDecision,statusCheckRollup,headRefOid)"
printf '%s' "$preflight_json" | python3 -c '
import json, sys
d=json.load(sys.stdin)
errors=[]
if d.get("state") != "OPEN": errors.append("PR is not OPEN")
if d.get("isDraft") is not False: errors.append("PR is still draft")
if d.get("mergeable") != "MERGEABLE": errors.append("PR is not proven mergeable")
if d.get("mergeStateStatus") not in {"CLEAN", "HAS_HOOKS"}: errors.append("merge state is not clean/up-to-date")
if d.get("reviewDecision") == "CHANGES_REQUESTED": errors.append("GitHub review requests changes")
for check in d.get("statusCheckRollup") or []:
    state=check.get("conclusion") or check.get("state") or check.get("status")
    if state not in {"SUCCESS", "NEUTRAL", "SKIPPED"}:
        errors.append("CI contains a non-green or unfinished check")
        break
head=d.get("headRefOid")
if not isinstance(head,str) or len(head)!=40: errors.append("head SHA is unavailable")
if errors:
    print("merge-pr preflight blocked: " + "; ".join(errors), file=sys.stderr)
    raise SystemExit(1)
'

root="$(git rev-parse --show-toplevel)"
common="$(git rev-parse --git-common-dir)"
case "$common" in /*) ;; *) common="$root/$common";; esac
record="$common/ha/reviews/pr-$pr.json"
[ -f "$record" ] || { echo "merge-pr: no HA review record for PR #$pr; run \$ha-review-pr" >&2; exit 1; }
python3 "$script_dir/validate-review.py" "$record" --expected-pr "$pr" >/dev/null
approved_head="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1], encoding="utf-8"))["head_sha"])' "$record")"
python3 - "$record" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    review=json.load(handle)
if review["verdict"] != "APPROVE" or any(f["blocking"] for f in review["findings"]):
    print("merge-pr: current HA review is not an unblocked APPROVE", file=sys.stderr)
    raise SystemExit(1)
PY
echo "merge-pr: preflight PASS for PR #$pr"

[ "$mode" = --merge ] || exit 0
case "$method" in
  squash) flag=--squash ;;
  merge) flag=--merge ;;
  rebase) flag=--rebase ;;
esac
"$gh_bin" pr merge "$pr" "$flag" --delete-branch --match-head-commit "$approved_head"
merged="$($gh_bin pr view "$pr" --json mergedAt --jq .mergedAt)"
[ -n "$merged" ] && [ "$merged" != null ] || { echo "merge-pr: merge was not confirmed" >&2; exit 1; }
echo "merge-pr: PR #$pr merged at $merged"
