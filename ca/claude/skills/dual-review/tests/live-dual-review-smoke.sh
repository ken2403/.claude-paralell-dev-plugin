#!/usr/bin/env bash
# Opt-in live smoke: real Claude + real Codex, fake gh, no external PR mutation.
set -euo pipefail

if [ "${1:-}" = "--run" ]; then
  shift
elif [ "${RUN_CA_LIVE_SMOKE:-0}" != "1" ]; then
  echo "SKIP: pass --run or set RUN_CA_LIVE_SMOKE=1 to run the real Claude/Codex smoke test"
  exit 0
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../../.." && pwd)"
SCRIPT="$ROOT/ca/claude/skills/dual-review/scripts/dual-review.sh"
VALIDATOR="$ROOT/ca/claude/skills/review-pr/scripts/validate-review.py"
REAL_CLAUDE="$(command -v claude)"
REAL_CODEX="$(command -v codex)"
TMP="${TMPDIR:-/tmp}/ca-live-dual-smoke.$$"
cleanup() {
  status=$?
  if [ "$status" -ne 0 ]; then
    echo "live smoke failed; diagnostic artifacts:" >&2
    find "$TMP/out" -maxdepth 1 -type f -print \
      -exec sh -c 'echo "--- $1"; tail -80 "$1"' _ {} \; >&2 || true
  fi
  rm -rf "$TMP"
  exit "$status"
}
trap cleanup EXIT
mkdir -p "$TMP/bin" "$TMP/repo/src" "$TMP/repo/tests" "$TMP/out"

cat > "$TMP/repo/plan.md" <<'MD'
# Calculator plan

## Milestones

1. Add `add(a, b)` returning the numeric sum.
2. Add a regression test covering positive integers.
MD
cat > "$TMP/repo/src/calc.py" <<'PY'
def add(a, b):
    return a + b
PY
cat > "$TMP/repo/tests/test_calc.py" <<'PY'
from src.calc import add


def test_adds_positive_integers():
    assert add(2, 3) == 5
PY
git -C "$TMP/repo" init -q -b ca/live-smoke
git -C "$TMP/repo" config user.email smoke@example.invalid
git -C "$TMP/repo" config user.name smoke
git -C "$TMP/repo" add .
git -C "$TMP/repo" commit -qm smoke

cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "pr view")
    printf '%s\n' '{"number":7,"title":"feat: add calculator","body":"Implements the supplied calculator plan.","state":"OPEN","isDraft":true,"baseRefName":"main","headRefName":"ca/live-smoke","url":"https://example.invalid/pr/7","files":[{"path":"src/calc.py","additions":2,"deletions":0},{"path":"tests/test_calc.py","additions":5,"deletions":0}]}'
    ;;
  "pr diff")
    case "$*" in
      *--name-only*) printf 'src/calc.py\ntests/test_calc.py\n';;
      *) cat <<'DIFF'
diff --git a/src/calc.py b/src/calc.py
new file mode 100644
--- /dev/null
+++ b/src/calc.py
@@ -0,0 +1,2 @@
+def add(a, b):
+    return a + b
diff --git a/tests/test_calc.py b/tests/test_calc.py
new file mode 100644
--- /dev/null
+++ b/tests/test_calc.py
@@ -0,0 +1,5 @@
+from src.calc import add
+
+
+def test_adds_positive_integers():
+    assert add(2, 3) == 5
DIFF
      ;;
    esac
    ;;
  "pr checks") exit 0;;
  *) echo "live smoke gh stub: unsupported args: $*" >&2; exit 2;;
esac
SH
chmod +x "$TMP/bin/gh"

# The budget is a runaway guard, NOT a per-call estimate: `claude` refuses up front once the
# session/account spend already exceeds it, so a too-small value fails every leg with
# "Error: Exceeded USD budget" on stdout. Keep it generous and overridable.
BUDGET_USD="${CA_LIVE_SMOKE_BUDGET_USD:-25}"
cat > "$TMP/bin/claude-live" <<SH
#!/usr/bin/env bash
exec "$REAL_CLAUDE" --permission-mode dontAsk --tools "Read,Grep,Glob,Bash,Skill" \
  --no-session-persistence --max-budget-usd $BUDGET_USD "\$@"
SH
chmod +x "$TMP/bin/claude-live"

export PATH="$TMP/bin:$PATH"
export CLAUDE_BIN="$TMP/bin/claude-live"
export CODEX_BIN="$REAL_CODEX"
export GH_BIN="$TMP/bin/gh"
export CA_CLAUDE_PLUGIN_DIR="$ROOT/ca/claude"
export CA_CODEX_REVIEW_TIMEOUT=600
export PYTHONDONTWRITEBYTECODE=1
export PYTEST_ADDOPTS="-p no:cacheprovider"

(cd "$TMP/repo" && bash "$SCRIPT" --pr 7 --plan "$TMP/repo/plan.md" \
  --worktree "$TMP/repo" --round 1 --out-dir "$TMP/out")

python3 "$VALIDATOR" "$TMP/out/review-round-1.json" \
  --expected-mode final --expected-round 1 >/dev/null
python3 - "$TMP/out/review-round-1.meta.json" <<'PY'
import json, sys
data = json.load(open(sys.argv[1], encoding="utf-8"))
assert data["dual_review"] is True
assert data["codex"]["status"] in {"used", "clean_no_synthesis"}
PY
[ -z "$(git -C "$TMP/repo" status --porcelain)" ] || {
  echo "live smoke modified reviewed code" >&2
  git -C "$TMP/repo" status --short >&2
  exit 1
}

echo "live-dual-review-smoke.sh: ok"
