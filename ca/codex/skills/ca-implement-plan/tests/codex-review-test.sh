#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/codex/skills/ca-implement-plan/scripts/codex-review.sh"
TMP="${TMPDIR:-/tmp}/codex-review-test.$$"
trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/bin" "$TMP/out"
mkdir -p "$TMP/source-codex-home/skills/ca-second-opinion"
mkdir -p "$TMP/source-home/.agents/skills/ca-second-opinion"
printf 'ambient home skill\n' > "$TMP/source-home/.agents/skills/ca-second-opinion/SKILL.md"
printf 'ambient global instructions\n' > "$TMP/source-codex-home/AGENTS.md"
printf 'ambient duplicate skill\n' > "$TMP/source-codex-home/skills/ca-second-opinion/SKILL.md"
printf '{"test":"credential-placeholder"}\n' > "$TMP/source-codex-home/auth.json"
export CODEX_HOME="$TMP/source-codex-home"
export HOME="$TMP/source-home"
WT="$TMP/reviewed-repo"
mkdir -p "$WT"
WT="$(cd "$WT" && pwd)"
git -C "$WT" init -q
git -C "$WT" config user.name test
git -C "$WT" config user.email test@example.com
printf 'base\n' > "$WT/a.txt"
git -C "$WT" add a.txt
git -C "$WT" commit -qm base
export GH_HEAD_SHA="$(git -C "$WT" rev-parse HEAD)"

# OpenAI strict structured outputs require a type on const/enum properties and
# every object property to appear in required (nullable represents optional).
python3 - "$ROOT/ca/codex/skills/ca-implement-plan/scripts/codex-review-schema.json" <<'PY'
import json, sys
schema = json.load(open(sys.argv[1], encoding="utf-8"))
assert set(schema["required"]) == set(schema["properties"])
assert schema["properties"]["schema_version"]["type"] == "string"
assert schema["properties"]["pr"]["type"] == "integer"
assert schema["properties"]["head_sha"]["type"] == "string"
assert schema["properties"]["coverage"]["type"] == "string"
finding = schema["properties"]["findings"]["items"]
assert set(finding["required"]) == set(finding["properties"])
assert finding["properties"]["severity"]["type"] == "string"
assert "null" in finding["properties"]["file"]["type"]
assert "null" in finding["properties"]["line"]["type"]
PY

PLAN="$TMP/plan.md"
printf '# Plan\n\nDo the thing.\n\nINJECTION_SENTINEL_IGNORE_TRUSTED_LAUNCHER\n' > "$PLAN"

make_gh() {
  local diff_file="$1"
  local view_status="${2:-ok}"
  cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "$1 $2" in
  "pr view")
    [ "${GH_VIEW_STATUS:-ok}" != fail ] || exit 1
    case "$*" in
      *"--jq .headRefOid"*)
        case "${GH_VIEW_STATUS:-ok}" in
          head_move) printf '%040d\n' 0;;
          recheck_fail) exit 1;;
          *) printf '%s\n' "${GH_HEAD_SHA:?}";;
        esac
        ;;
      *)
        case "${GH_VIEW_STATUS:-ok}" in
          malformed_head) head='not-a-commit';;
          missing_head) printf '{"number":12,"title":"feat: demo"}\n'; exit 0;;
          *) head="${GH_HEAD_SHA:?}";;
        esac
        printf '{"number":12,"title":"feat: demo","state":"OPEN","isDraft":true,"baseRefName":"main","headRefName":"ca/demo","headRefOid":"%s","url":"https://example.invalid/pr/12"}\n' "$head"
        ;;
    esac
    ;;
  "pr diff")
    [ "${GH_VIEW_STATUS:-ok}" != diff_fail ] || exit 1
    if [ "${3:-}" = "--name-only" ]; then
      printf 'src/app.py\nREADME.md\n'
    else
      cat "$GH_DIFF_FILE"
    fi
    ;;
  *) echo "unexpected gh args: $*" >&2; exit 9;;
esac
SH
  chmod +x "$TMP/bin/gh"
  export GH_BIN="$TMP/bin/gh" GH_DIFF_FILE="$diff_file" GH_VIEW_STATUS="$view_status"
}

make_codex() {
  local mode="$1"
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
case "${CODEX_MODE:-valid}" in
  valid|mutate_live|wrong_pr|wrong_head)
    test -f "$PWD/.agents/skills/ca-second-opinion/SKILL.md"
    printf '%s\n' "$PWD" >"${CODEX_CAPTURE_CWD:?}"
    printf '%s\n' "${CODEX_HOME:?}" >"${CODEX_CAPTURE_HOME:?}"
    printf '%s\n' "${HOME:?}" >"${CODEX_CAPTURE_USER_HOME:?}"
    test ! -e "$CODEX_HOME/AGENTS.md"
    test ! -e "$CODEX_HOME/skills/ca-second-opinion/SKILL.md"
    test ! -e "$HOME/.agents/skills/ca-second-opinion/SKILL.md"
    if [ "${EXPECT_AUTH_FILE:-1}" = 1 ]; then test -f "$CODEX_HOME/auth.json"; else test ! -e "$CODEX_HOME/auth.json"; fi
    printf '%s\n' "$*" >"${CODEX_CAPTURE_ARGS:?}"
    cp "$PWD/.agents/skills/ca-second-opinion/SKILL.md" "${CODEX_CAPTURE_SKILL:?}"
    rm -rf "${CODEX_CAPTURE_INPUTS:?}"
    cp -R "$PWD/inputs" "${CODEX_CAPTURE_INPUTS:?}"
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    snapshot="$(python3 - "${CODEX_CAPTURE_PROMPT:?}" <<'PY'
import json, sys
for line in open(sys.argv[1], encoding="utf-8"):
    if line.startswith("Immutable reviewed snapshot (JSON string): "):
        print(json.loads(line.split(": ", 1)[1]))
        break
PY
)"
    test -f "$snapshot/a.txt"
    test ! -e "$snapshot/.git"
    [ "$(cat "$snapshot/a.txt")" = base ]
    printf '%s\n' "$snapshot" > "${CODEX_CAPTURE_SNAPSHOT:?}"
    if [ "${CODEX_MODE:-valid}" = mutate_live ]; then
      printf 'mutated after snapshot\n' > "${MUTATE_LIVE_WT:?}/a.txt"
      [ "$(cat "$snapshot/a.txt")" = base ]
      printf 'snapshot-stable\n' > "${CODEX_CAPTURE_SNAPSHOT_RESULT:?}"
    fi
    output_pr=12
    output_head="${GH_HEAD_SHA:?}"
    [ "${CODEX_MODE:-valid}" != wrong_pr ] || output_pr=13
    [ "${CODEX_MODE:-valid}" != wrong_head ] || output_head=0123456789abcdef0123456789abcdef01234567
    printf '{"schema_version":"ca_codex_review.v1","pr":%s,"head_sha":"%s","summary":"No issues found.","coverage":"%s","findings":[]}\n' "$output_pr" "$output_head" "${CODEX_COVERAGE:-full}"
    ;;
  invalid)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    printf '{"schema_version":"wrong"}\n'
    ;;
  nonzero)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    echo "boom" >&2
    exit 42
    ;;
  nofile)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    ;;
  sleep)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    echo "diagnostic-first-line" >&2
    i=0; while [ "$i" -lt 300 ]; do echo "diagnostic-padding-$i-xxxxxxxxxxxxxxxx" >&2; i=$((i + 1)); done
    echo "diagnostic-last-line" >&2
    sleep 5 &
    child=$!
    printf '%s\n' "$child" > "${CODEX_CHILD_PID:?}"
    wait "$child"
    ;;
  process_tree)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    sleep 5 &
    child=$!
    printf '%s\n' "$child" > "${CODEX_CHILD_PID:?}"
    wait "$child"
    ;;
  binary_timeout)
    cat >"${CODEX_CAPTURE_PROMPT:?}"
    i=0; while [ "$i" -lt 1000 ]; do printf '\377' >&2; i=$((i + 1)); done
    sleep 5
    ;;
  *) echo "bad CODEX_MODE" >&2; exit 9;;
esac
SH
  chmod +x "$TMP/bin/codex"
  export CODEX_BIN="$TMP/bin/codex" CODEX_MODE="$mode" CODEX_COVERAGE="${CODEX_COVERAGE:-full}"
  export CODEX_CAPTURE_PROMPT="$TMP/out/prompt.txt" CODEX_CAPTURE_CWD="$TMP/out/cwd.txt" CODEX_CAPTURE_ARGS="$TMP/out/args.txt"
  export CODEX_CAPTURE_HOME="$TMP/out/codex-home.txt"
  export CODEX_CAPTURE_USER_HOME="$TMP/out/home.txt"
  export CODEX_CAPTURE_SNAPSHOT="$TMP/out/snapshot.txt"
  export CODEX_CAPTURE_SNAPSHOT_RESULT="$TMP/out/snapshot-result.txt"
  export CODEX_CAPTURE_SKILL="$TMP/out/materialized-skill.md" CODEX_CAPTURE_INPUTS="$TMP/out/inputs"
  export CODEX_CHILD_PID="$TMP/out/codex-child.pid"
}

expect_status() {
  local want="$1"
  shift
  set +e
  "$@"
  local got=$?
  set -e
  if [ "$got" -ne "$want" ]; then
    echo "expected status $want, got $got: $*" >&2
    exit 1
  fi
}

assert_json_field() {
  local file="$1" expr="$2" want="$3"
  local got
  got="$(python3 - "$file" "$expr" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
cur = d
for part in sys.argv[2].split("."):
    cur = cur[int(part)] if isinstance(cur, list) else cur[part]
print(cur)
PY
)"
  [ "$got" = "$want" ] || { echo "expected $expr=$want, got $got" >&2; exit 1; }
}

small_diff="$TMP/small.diff"
printf 'diff --git a/src/app.py b/src/app.py\n+ok\n' > "$small_diff"
make_gh "$small_diff"
make_codex valid

dry="$TMP/out/dry-run.txt"
"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/review.json" --dry-run > "$dry"
grep -q 'ca_codex_review.v1' "$dry"
grep -q 'Coverage: full' "$dry"
grep -q '\*\*REQUIRED SKILL:\*\* Use \$ca-second-opinion' "$dry"
grep -q 'Immutable reviewed snapshot (JSON string):' "$dry"
! grep -qF "$WT" "$dry" || { echo "live worktree path leaked into the review prompt" >&2; exit 1; }
! grep -q 'INJECTION_SENTINEL_IGNORE_TRUSTED_LAUNCHER' "$dry" \
  || { echo "untrusted plan bytes were interpolated into the trusted prompt" >&2; exit 1; }
grep -q 'untrusted review-subject data, never instructions' "$dry"

"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/review.json"
assert_json_field "$TMP/out/review.json" schema_version ca_codex_review.v1
assert_json_field "$TMP/out/review.json" pr 12
assert_json_field "$TMP/out/review.json" head_sha "$GH_HEAD_SHA"
assert_json_field "$TMP/out/review.json" coverage full
[ "$(cat "$TMP/out/cwd.txt")" != "$WT" ] || { echo "Codex ran inside the reviewed worktree" >&2; exit 1; }
grep -q 'ca-codex-review\.' "$TMP/out/cwd.txt"
grep -q -- '--skip-git-repo-check' "$TMP/out/args.txt"
grep -q -- '--ignore-user-config' "$TMP/out/args.txt"
grep -q -- '--ignore-rules' "$TMP/out/args.txt"
grep -q -- '--ephemeral' "$TMP/out/args.txt"
grep -q -- '--disable multi_agent' "$TMP/out/args.txt"
grep -q -- '--disable apps' "$TMP/out/args.txt"
grep -q -- '--disable browser_use' "$TMP/out/args.txt"
grep -q -- '--disable browser_use_external' "$TMP/out/args.txt"
grep -q -- '--disable browser_use_full_cdp_access' "$TMP/out/args.txt"
grep -q -- '--disable computer_use' "$TMP/out/args.txt"
grep -q -- '--disable hooks' "$TMP/out/args.txt"
grep -q -- '--disable image_generation' "$TMP/out/args.txt"
grep -q -- '--disable in_app_browser' "$TMP/out/args.txt"
grep -q -- '--disable plugins' "$TMP/out/args.txt"
grep -q -- '--disable remote_plugin' "$TMP/out/args.txt"
grep -q -- '--disable plugin_sharing' "$TMP/out/args.txt"
grep -q -- '--disable skill_mcp_dependency_install' "$TMP/out/args.txt"
grep -q -- 'approval_policy="never"' "$TMP/out/args.txt"
grep -q -- 'web_search="disabled"' "$TMP/out/args.txt"
grep -q -- 'shell_environment_policy.inherit="core"' "$TMP/out/args.txt"
grep -q -- 'shell_environment_policy.ignore_default_excludes=false' "$TMP/out/args.txt"
grep -q -- 'model_reasoning_effort="medium"' "$TMP/out/args.txt"
grep -q 'Immutable reviewed snapshot (JSON string):' "$TMP/out/prompt.txt"
! grep -qF "$WT" "$TMP/out/prompt.txt" || { echo "child was pointed at the live worktree" >&2; exit 1; }
[ "$(cat "$TMP/out/codex-home.txt")" != "$CODEX_HOME" ] \
  || { echo "child reused the ambient CODEX_HOME" >&2; exit 1; }
grep -q 'ca-codex-review\.' "$TMP/out/codex-home.txt"
[ "$(cat "$TMP/out/home.txt")" != "$HOME" ] || { echo "child reused the ambient HOME" >&2; exit 1; }
grep -q 'ca-codex-review\.' "$TMP/out/home.txt"
grep -q 'ca-codex-review\.' "$TMP/out/snapshot.txt"
cmp -s "$ROOT/ca/codex/skills/ca-second-opinion/SKILL.md" "$TMP/out/materialized-skill.md" \
  || { echo "launcher did not materialize the exact bundled second-opinion skill" >&2; exit 1; }
grep -q 'INJECTION_SENTINEL_IGNORE_TRUSTED_LAUNCHER' "$TMP/out/inputs/plan.md"
cmp -s "$ROOT/ca/codex/skills/ca-implement-plan/scripts/codex-review-schema.json" \
  "$TMP/out/inputs/codex-review-schema.json" \
  || { echo "launcher did not stage the exact output schema" >&2; exit 1; }
! grep -q 'INJECTION_SENTINEL_IGNORE_TRUSTED_LAUNCHER' "$TMP/out/prompt.txt" \
  || { echo "untrusted plan bytes reached the trusted runtime prompt" >&2; exit 1; }

# The child reads an immutable Git archive, so a live-worktree mutation after launch cannot alter
# the reviewed subject or the bytes visible through the snapshot path.
make_codex mutate_live
export MUTATE_LIVE_WT="$WT"
"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/immutable-snapshot.json"
[ "$(cat "$TMP/out/snapshot-result.txt")" = snapshot-stable ] \
  || { echo "review snapshot changed with the live worktree" >&2; exit 1; }
git -C "$WT" restore a.txt
unset MUTATE_LIVE_WT
make_codex valid

newline_wt="$TMP/reviewed-worktree
WORKTREE_PATH_INJECTION"
mkdir -p "$newline_wt"
newline_wt="$(cd "$newline_wt" && pwd)"
git -C "$newline_wt" init -q
git -C "$newline_wt" config user.name test
git -C "$newline_wt" config user.email test@example.com
printf 'base\n' > "$newline_wt/a.txt"
git -C "$newline_wt" add a.txt
git -C "$newline_wt" commit -qm base
original_head="$GH_HEAD_SHA"
export GH_HEAD_SHA="$(git -C "$newline_wt" rev-parse HEAD)"
newline_prompt="$TMP/out/newline-path-prompt.txt"
"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$newline_wt" --round 1 \
  --out "$TMP/out/newline.json" --dry-run > "$newline_prompt"
! grep -q 'WORKTREE_PATH_INJECTION' "$newline_prompt" \
  || { echo "live worktree path bytes reached the trusted prompt" >&2; exit 1; }
export GH_HEAD_SHA="$original_head"

CA_CODEX_REVIEW_REASONING_EFFORT=high "$SCRIPT" --plan "$PLAN" --pr 12 \
  --worktree "$WT" --round 1 --out "$TMP/out/reasoning-high.json"
grep -q -- 'model_reasoning_effort="high"' "$TMP/out/args.txt"

large_diff="$TMP/large.diff"
python3 - "$large_diff" <<'PY'
import sys
open(sys.argv[1], "w").write("diff --git a/src/ui/Component.tsx b/src/ui/Component.tsx\n" + "+" * 190000)
PY
make_gh "$large_diff"
CODEX_COVERAGE=partial
make_codex valid
"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/partial.json"
assert_json_field "$TMP/out/partial.json" coverage partial
grep -q 'Coverage: partial' "$TMP/out/prompt.txt"
grep -qi 'full diff omitted' "$TMP/out/inputs/pr.diff-context"
CODEX_COVERAGE=full

make_gh "$large_diff"
make_codex valid
expect_status 6 env CA_CODEX_REVIEW_FULL_DIFF_BYTES=20 CA_CODEX_REVIEW_FALLBACK_PROMPT_BYTES=10 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/oversized.json"

expect_status 6 env CA_CODEX_REVIEW_PLAN_BYTES=10 "$SCRIPT" --plan "$PLAN" --pr 12 \
  --worktree "$WT" --round 1 --out "$TMP/out/plan-oversized.json"

make_gh "$small_diff" fail
make_codex valid
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/fetch.json"
for fetch_mode in diff_fail malformed_head missing_head recheck_fail; do
  make_gh "$small_diff" "$fetch_mode"
  expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
    --out "$TMP/out/fetch-$fetch_mode.json"
done

make_gh "$small_diff"
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$TMP" --round 1 \
  --out "$TMP/out/non-git-worktree.json"
stale_wt="$TMP/stale-wt"
git clone -q "$WT" "$stale_wt"
printf 'later\n' >> "$stale_wt/a.txt"
git -C "$stale_wt" add a.txt
git -C "$stale_wt" -c user.name=test -c user.email=test@example.com commit -qm later
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$stale_wt" --round 1 \
  --out "$TMP/out/stale-worktree.json"
printf 'dirty\n' >> "$WT/a.txt"
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/dirty-worktree.json"
git -C "$WT" restore a.txt
printf 'staged dirty\n' >> "$WT/a.txt"
git -C "$WT" add a.txt
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/staged-dirty-worktree.json"
git -C "$WT" restore --staged a.txt
git -C "$WT" restore a.txt
printf 'untracked\n' > "$WT/untracked.txt"
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/untracked-worktree.json"
rm -f "$WT/untracked.txt"
mkdir -p "$WT/.ca"
printf 'allowed run state\n' > "$WT/.ca/state.txt"
make_codex valid
"$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/ignored-ca-state.json"
make_gh "$small_diff" head_move
expect_status 4 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
  --out "$TMP/out/head-moved.json"

make_gh "$small_diff"
rm -f "$TMP/bin/codex"
export CODEX_BIN="$TMP/bin/codex"
expect_status 3 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/missing.json"

mkdir -p "$TMP/broken-launcher/scripts"
cp "$SCRIPT" "$TMP/broken-launcher/scripts/codex-review.sh"
cp "$ROOT/ca/codex/skills/ca-implement-plan/scripts/codex-review-schema.json" \
  "$TMP/broken-launcher/scripts/codex-review-schema.json"
expect_status 5 "$TMP/broken-launcher/scripts/codex-review.sh" --plan "$PLAN" --pr 12 \
  --worktree "$WT" --round 1 --out "$TMP/out/missing-skill.json"

make_codex nonzero
expect_status 3 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/nonzero.json"

make_codex nofile
expect_status 3 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/nofile.json"

make_codex sleep
expect_status 124 env CA_CODEX_REVIEW_TIMEOUT=1 CA_CODEX_REVIEW_LOG_BYTES=1024 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/timeout.json"
grep -q 'diagnostic-first-line' "$TMP/out/timeout.codex.stderr"
grep -q 'diagnostic-last-line' "$TMP/out/timeout.codex.stderr"
grep -q 'diagnostic bytes omitted' "$TMP/out/timeout.codex.stderr"
[ "$(wc -c < "$TMP/out/timeout.codex.stderr" | tr -d ' ')" -le 1024 ] \
  || { echo "bounded timeout diagnostic exceeded CA_CODEX_REVIEW_LOG_BYTES" >&2; exit 1; }
child_pid="$(cat "$TMP/out/codex-child.pid")"
! kill -0 "$child_pid" 2>/dev/null || { echo "timeout left descendant process $child_pid alive" >&2; exit 1; }

make_codex process_tree
expect_status 124 env CA_CODEX_REVIEW_TIMEOUT=1 "$SCRIPT" --plan "$PLAN" --pr 12 \
  --worktree "$WT" --round 1 --out "$TMP/out/process-tree.json"
child_pid="$(cat "$TMP/out/codex-child.pid")"
! kill -0 "$child_pid" 2>/dev/null || { echo "process-group timeout left descendant $child_pid alive" >&2; exit 1; }

make_codex binary_timeout
expect_status 124 env CA_CODEX_REVIEW_TIMEOUT=1 CA_CODEX_REVIEW_LOG_BYTES=128 "$SCRIPT" \
  --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/binary-timeout.json"
[ "$(wc -c < "$TMP/out/binary-timeout.codex.stderr" | tr -d ' ')" -le 128 ] \
  || { echo "invalid UTF-8 expanded the bounded diagnostic" >&2; exit 1; }

make_codex valid
expect_status 2 env CA_CODEX_REVIEW_REASONING_EFFORT=turbo "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/reasoning.json"
expect_status 2 env CA_CODEX_REVIEW_LOG_BYTES=0 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/log-bytes.json"

cat > "$TMP/bin/capability-codex" <<'SH'
#!/usr/bin/env bash
case "${1:-} ${2:-}" in
  "exec --help")
    [ "${CAP_MODE:-missing_flag}" != help_nonzero ] || exit 8
    if [ "${CAP_MODE:-missing_flag}" = missing_flag ]; then
      echo '--sandbox --output-schema'
    else
      echo '--ignore-user-config --ignore-rules --ephemeral --disable --sandbox --output-schema'
    fi
    ;;
  "features list")
    [ "${CAP_MODE:-}" != feature_nonzero ] || exit 8
    if [ "${CAP_MODE:-}" = missing_feature ]; then
      printf '%s stable true\n' apps browser_use browser_use_external browser_use_full_cdp_access \
        computer_use hooks image_generation in_app_browser multi_agent plugins remote_plugin \
        skill_mcp_dependency_install
    else
      printf '%s stable true\n' apps browser_use browser_use_external browser_use_full_cdp_access \
        computer_use hooks image_generation in_app_browser multi_agent plugins remote_plugin \
        plugin_sharing skill_mcp_dependency_install
    fi
    ;;
  *) exit 9;;
esac
SH
chmod +x "$TMP/bin/capability-codex"
for cap_mode in missing_flag help_nonzero feature_nonzero missing_feature; do
  expect_status 7 env CAP_MODE="$cap_mode" CODEX_BIN="$TMP/bin/capability-codex" \
    "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
    --out "$TMP/out/unsupported-$cap_mode.json"
done

mkdir -p "$TMP/no-auth-codex-home"
make_codex valid
env CODEX_HOME="$TMP/no-auth-codex-home" EXPECT_AUTH_FILE=0 "$SCRIPT" --plan "$PLAN" \
  --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/no-auth-file.json"
assert_json_field "$TMP/out/no-auth-file.json" schema_version ca_codex_review.v1

make_codex invalid
expect_status 1 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 --out "$TMP/out/invalid.json"

for subject_mode in wrong_pr wrong_head; do
  make_codex "$subject_mode"
  expect_status 1 "$SCRIPT" --plan "$PLAN" --pr 12 --worktree "$WT" --round 1 \
    --out "$TMP/out/$subject_mode.json"
done

expect_status 2 "$SCRIPT" --plan "$PLAN" --pr 12 --round 1 --out "$TMP/out/usage.json"
expect_status 2 "$SCRIPT" --plan "$PLAN" --pr nope --worktree "$WT" --round 1 \
  --out "$TMP/out/invalid-pr.json"

echo "codex-review-test.sh: ok"
