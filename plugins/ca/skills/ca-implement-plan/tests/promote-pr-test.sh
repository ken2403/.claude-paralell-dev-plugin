#!/usr/bin/env bash
# Behavior tests for promote-pr.sh — the ONLY thing allowed to run `gh pr ready`.
#
#   1. a validated final approve for THIS pr at THIS head  -> promotes
#   2. blocked (even with an empty findings list)          -> refuses
#   3. round mismatch                                      -> refuses
#   4. checkpoint verdict                                  -> refuses
#   5. approve written for a DIFFERENT pr                  -> refuses
#   6. approve for a commit the branch has moved past      -> refuses
#   7. approve with no subject binding at all              -> refuses
# 5-7 are the reason the verdict carries `pr` and `head_sha`: an approval is only an
# approval of something, and a stale one must not open the gate.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/codex/skills/ca-implement-plan/scripts/promote-pr.sh"
TMP="${TMPDIR:-/tmp}/promote-pr-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin"

HEAD_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OLD_SHA=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

cat > "$TMP/bin/gh" <<SH
#!/usr/bin/env bash
case "\$*" in
  *headRefOid*) printf '%s\n' "$HEAD_SHA";;
  "pr ready "*) printf '%s\n' "\$*" >> "\${GH_LOG:?}";;
  *) echo "promote-pr-test gh stub: unexpected: \$*" >&2; exit 2;;
esac
SH
chmod +x "$TMP/bin/gh"
export GH_BIN="$TMP/bin/gh" GH_LOG="$TMP/gh.log"
: > "$GH_LOG"

review() {  # review <file> <json-body-overrides...>
  local file="$1" pr="$2" sha="$3" mode="$4" round="$5" verdict="$6" findings="$7" 
  local subject=""
  [ "$pr" = "none" ] || subject="\"pr\":$pr,\"head_sha\":\"$sha\","
  cat > "$file" <<JSON
{"schema_version":"ca_claude_review.v1","producer":"blind","round":$round,"mode":"$mode",
 $subject"verdict":"$verdict","summary":"Summary for the test.","findings":$findings,
 "verification":[{"claim":"tests","result":"pass","evidence":"green"}]}
JSON
}

expect() {  # expect <want-status> <label> <args...>
  local want="$1" label="$2"; shift 2
  set +e
  "$SCRIPT" "$@" >/dev/null 2>"$TMP/err"
  local got=$?
  set -e
  [ "$got" -eq "$want" ] || { echo "FAIL($label): expected $want, got $got" >&2; cat "$TMP/err" >&2; exit 1; }
}

# 1. the happy path
review "$TMP/ok.json" 42 "$HEAD_SHA" final 2 approve '[]'
expect 0 "approve promotes" --review "$TMP/ok.json" --pr 42 --round 2
grep -qx 'pr ready 42' "$GH_LOG" || { echo "FAIL: gh pr ready was not called" >&2; exit 1; }

refuse() {  # refuse <label> <file> <pr> <round>
  : > "$GH_LOG"
  expect 1 "$1" --review "$2" --pr "$3" --round "$4"
  [ ! -s "$GH_LOG" ] || { echo "FAIL($1): reached gh pr ready" >&2; exit 1; }
}

# 2. blocked with an empty findings list is still blocked
review "$TMP/blocked.json" 42 "$HEAD_SHA" final 2 blocked '[]'
refuse "blocked" "$TMP/blocked.json" 42 2

# 3. round mismatch
refuse "round mismatch" "$TMP/ok.json" 42 1

# 4. a checkpoint verdict can never promote
review "$TMP/cp.json" 42 "$HEAD_SHA" checkpoint 1 approve '[]'
refuse "checkpoint" "$TMP/cp.json" 42 1

# 5. an approve written for another PR
review "$TMP/otherpr.json" 7 "$HEAD_SHA" final 2 approve '[]'
refuse "wrong pr" "$TMP/otherpr.json" 42 2

# 6. an approve for a commit the branch has moved past
review "$TMP/stale.json" 42 "$OLD_SHA" final 2 approve '[]'
refuse "stale head" "$TMP/stale.json" 42 2

# 7. an approve that binds itself to nothing
review "$TMP/nosubject.json" none "" final 2 approve '[]'
refuse "no subject" "$TMP/nosubject.json" 42 2

echo "promote-pr-test.sh: ok"
