#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
VALIDATOR="$ROOT/ca/claude/skills/review-pr/scripts/validate-review.py"
TMP="${TMPDIR:-/tmp}/validate-review-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP"

expect_status() {
  local want="$1"; shift
  set +e
  "$@" >/dev/null 2>"$TMP/err"
  local got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "expected status $want, got $got: $*" >&2
    cat "$TMP/err" >&2
    exit 1
  fi
}

cat > "$TMP/approve.json" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","verdict":"approve","summary":"Ready.","findings":[],"verification":[{"claim":"tests pass","result":"pass","evidence":"CI check 42 passed."}]}
JSON
expect_status 0 python3 "$VALIDATOR" "$TMP/approve.json" \
  --expected-mode final --expected-round 1 --expected-producer blind

cat > "$TMP/blind.json" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","pr":12,"head_sha":"0123456789abcdef0123456789abcdef01234567","verdict":"request_changes","summary":"Blind review.","findings":[{"id":"C001","blocking":true,"severity":"major","title":"Blind blocker","evidence":"src/a.py:4 violates the plan.","recommended_fix":"Correct the branch and add a regression test."}],"verification":[]}
JSON
expect_status 0 python3 "$VALIDATOR" "$TMP/blind.json"

cat > "$TMP/codex.json" <<'JSON'
{"schema_version":"ca_codex_review.v1","pr":12,"head_sha":"0123456789abcdef0123456789abcdef01234567","summary":"Second opinion.","coverage":"full","findings":[{"id":"X001","blocking":true,"severity":"major","file":"src/b.py","line":9,"title":"Codex claim","evidence":"src/b.py:9 drops the error.","recommended_fix":"Propagate the error."}]}
JSON
cat > "$TMP/synth.json" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"synthesis","round":1,"mode":"final","pr":12,"head_sha":"0123456789abcdef0123456789abcdef01234567","verdict":"approve","summary":"Claims resolved.","findings":[],"verification":[{"claim":"both claims checked","result":"pass","evidence":"Inspected src/a.py and src/b.py."}],"second_opinion":{"provider":"codex","status":"used","coverage":"full","ledger":[{"id":"X001","adjudication":"refuted","evidence":"The caller handles the error at src/b.py:12."}],"prior_findings_rechecked":true},"resolved_blind_findings":[{"id":"C001","reason":"Plan reading was incomplete.","evidence":"The next branch at src/a.py:8 handles it.","new_severity":"none"}]}
JSON
expect_status 0 python3 "$VALIDATOR" "$TMP/synth.json" --blind "$TMP/blind.json" \
  --second-opinion "$TMP/codex.json" --expected-mode final --expected-round 1 \
  --expected-producer synthesis

python3 - "$TMP/codex.json" "$TMP/wrong-subject-codex.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d["pr"]=13; json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/synth.json" --blind "$TMP/blind.json" \
  --second-opinion "$TMP/wrong-subject-codex.json"

python3 - "$TMP/synth.json" "$TMP/silent-drop.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d["resolved_blind_findings"]=[]
json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/silent-drop.json" --blind "$TMP/blind.json" \
  --second-opinion "$TMP/codex.json"

python3 - "$TMP/synth.json" "$TMP/missing-ledger.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d["second_opinion"]["ledger"]=[]
json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/missing-ledger.json" --blind "$TMP/blind.json" \
  --second-opinion "$TMP/codex.json"

python3 - "$TMP/approve.json" "$TMP/case.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d.pop("schema_version"); json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/case.json"

python3 - "$TMP/approve.json" "$TMP/case.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d["verification"]=[]; json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/case.json"

python3 - "$TMP/blind.json" "$TMP/case.json" <<'PY'
import json, sys
d=json.load(open(sys.argv[1])); d["verdict"]="approve"; json.dump(d, open(sys.argv[2], "w"))
PY
expect_status 1 python3 "$VALIDATOR" "$TMP/case.json"

cat > "$TMP/blocked-empty.json" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","verdict":"blocked","summary":"CI is unreachable.","findings":[],"verification":[{"claim":"CI status","result":"unknown","evidence":"No authenticated GitHub connection."}]}
JSON
expect_status 0 python3 "$VALIDATOR" "$TMP/blocked-empty.json"
expect_status 1 python3 "$VALIDATOR" "$TMP/blocked-empty.json" --expected-mode checkpoint
expect_status 1 python3 "$VALIDATOR" "$TMP/blocked-empty.json" --expected-round 2

cat > "$TMP/request-empty.json" <<'JSON'
{"schema_version":"ca_claude_review.v1","producer":"blind","round":1,"mode":"final","verdict":"request_changes","summary":"Incoherent.","findings":[],"verification":[]}
JSON
expect_status 1 python3 "$VALIDATOR" "$TMP/request-empty.json"

echo "validate-review-test.sh: ok"
