#!/usr/bin/env bash
# Drive the ENTIRE ca loop end to end, in the same order the $ca-implement-plan skill
# prescribes, against a real git remote and a hermetic `gh`:
#
#   new-worktree.sh -> implement milestone 1 -> push -> OPEN THE DRAFT PR
#     -> claude-review.sh --mode checkpoint -> implement milestone 2 -> push
#     -> dual-review.sh (final: blind Claude + Codex second opinion [+ synthesis])
#     -> promote-pr.sh (the only thing allowed to run `gh pr ready`)
#     -> post-summary.sh
#
# Everything except GitHub itself is real: real worktrees, real commits, real pushes,
# real ca scripts, real contract validation. The MODELS are supplied by the caller via
# CLAUDE_BIN / CODEX_BIN, so the same loop runs with stubs (hermetic, in CI) or with
# real Claude and real Codex (the live smoke).
#
# Required env: CLAUDE_BIN, CODEX_BIN, GH_BIN (gh-sim shim), CA_CLAUDE_PLUGIN_DIR
# Usage: run-loop-e2e.sh --workdir DIR --implementer stub|codex [--repo-root R]
set -euo pipefail

WORKDIR="" IMPLEMENTER="stub" REPO_ROOT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --workdir) WORKDIR="$2"; shift 2;;
    --implementer) IMPLEMENTER="$2"; shift 2;;
    --repo-root) REPO_ROOT="$2"; shift 2;;
    *) echo "run-loop-e2e: unknown arg: $1" >&2; exit 2;;
  esac
done
[ -n "$WORKDIR" ] || { echo "usage: run-loop-e2e.sh --workdir DIR --implementer stub|codex" >&2; exit 2; }
case "$IMPLEMENTER" in stub|codex) ;; *) echo "bad --implementer" >&2; exit 2;; esac
[ -n "$REPO_ROOT" ] || REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

SCRIPTS="$REPO_ROOT/ca/codex/skills/ca-implement-plan/scripts"
VALIDATOR="$REPO_ROOT/ca/claude/skills/review-pr/scripts/validate-review.py"
step() { printf '\n=== %s ===\n' "$*"; }
fail() { echo "E2E FAIL: $*" >&2; exit 1; }

mkdir -p "$WORKDIR"
REPO="$WORKDIR/repo"
REMOTE="$WORKDIR/remote.git"
export CA_GH_SIM_STATE="$WORKDIR/gh-state.json"
export CA_GH_SIM_REMOTE="$REMOTE"

# ---------------------------------------------------------------- fixture repo
step "Phase 0 — fixture repo, real bare remote, plan with 2 milestones"
git init -q -b main "$REPO"
git -C "$REPO" config user.email ca-e2e@example.invalid
git -C "$REPO" config user.name "ca e2e"
mkdir -p "$REPO/src" "$REPO/tests" "$REPO/docs/ca/plans"
cat > "$REPO/src/wallet.py" <<'PY'
"""Tiny wallet ledger the ca loop E2E builds on."""


def balance(entries):
    return sum(entries)
PY
cat > "$REPO/tests/test_wallet.py" <<'PY'
import unittest

from src.wallet import balance


class WalletTest(unittest.TestCase):
    def test_balance_sums_entries(self):
        self.assertEqual(balance([1, 2, 3]), 6)
PY
touch "$REPO/src/__init__.py" "$REPO/tests/__init__.py"
cat > "$REPO/docs/ca/plans/wallet-withdraw.md" <<'MD'
# Add a guarded `withdraw` to the wallet ledger

## Goal

`src/wallet.py` can sum entries but cannot spend. Add a `withdraw(entries, amount)`
helper that appends a negative entry, and make it refuse to overdraw.

## Milestones

1. **Core withdraw** — Task 1.
2. **Overdraft guard** — Task 2.

## Task 1 — `withdraw` appends a negative entry

- File: `src/wallet.py`
- Failing test first, in `tests/test_wallet.py`:
  `test_withdraw_appends_negative_entry` — `withdraw([10], 4)` returns `[10, -4]`.
- Implement `withdraw(entries, amount)` returning `entries + [-amount]`.
- Test command: `python3 -m unittest discover -s tests -t . -q`

## Task 2 — `withdraw` refuses to overdraw

- File: `src/wallet.py`
- Failing test first, in `tests/test_wallet.py`:
  `test_withdraw_rejects_overdraft` — `withdraw([5], 9)` raises `ValueError`.
- Implement: raise `ValueError` when `amount` exceeds `balance(entries)`.
  A non-positive `amount` is also a `ValueError`.
- Test command: `python3 -m unittest discover -s tests -t . -q`

## Success criteria

`python3 -m unittest discover -s tests -t . -q` passes, and no entry list is mutated in place.
MD
git -C "$REPO" add .
git -C "$REPO" commit -qm "chore: wallet ledger baseline"
git init -q --bare -b main "$REMOTE"
git -C "$REPO" remote add origin "$REMOTE"
git -C "$REPO" push -q -u origin main
git -C "$REMOTE" symbolic-ref HEAD refs/heads/main
echo "repo=$REPO remote=$REMOTE"

PLAN="$REPO/docs/ca/plans/wallet-withdraw.md"
ID="wallet-withdraw"

# ------------------------------------------------------------------ Step 0/1
step "Phase 1 — new-worktree.sh creates the isolated ca/<id> worktree"
(cd "$REPO" && bash "$SCRIPTS/new-worktree.sh" "$PLAN") > "$WORKDIR/new-worktree.out"
cat "$WORKDIR/new-worktree.out"
WT="$REPO/.claude/worktrees/ca/$ID"
BR="ca/$ID"
RUN="$WT/.ca/runs/$ID"
[ -d "$WT" ] || fail "worktree was not created at $WT"
[ "$(git -C "$WT" rev-parse --abbrev-ref HEAD)" = "$BR" ] || fail "worktree is not on $BR"
[ -f "$RUN/plan.md" ] && [ -f "$RUN/plan.sha256" ] && [ -f "$RUN/base.txt" ] || fail "run state missing"
BASE="$(cat "$RUN/base.txt")"

# the skill's own Step 0 isolation assertions, run verbatim
case "$BR" in ca/*) ;; *) fail "isolation check: branch";; esac
case "$WT" in */.claude/worktrees/ca/*) ;; *) fail "isolation check: path";; esac
[ -z "$(git -C "$WT" status --porcelain)" ] || fail "worktree dirty right after creation (.ca/ not excluded?)"

# ------------------------------------------------------------------- Step 2
implement_milestone() {
  local m="$1"
  local before_head; before_head="$(git -C "$WT" rev-parse HEAD)"
  if [ "$IMPLEMENTER" = stub ]; then
    bash "$WORKDIR/stub-implement.sh" "$WT" "$m"
  else
    "$CODEX_BIN" exec -C "$WT" --sandbox workspace-write -c approval_policy=never - <<CODEX_PROMPT
You are implementing milestone $m of the plan at .ca/runs/$ID/plan.md, in this worktree.
Work test-first: write the failing test the task names, run it, then the minimal implementation,
then run \`python3 -m unittest discover -s tests -t . -q\` and confirm it passes.
Implement ONLY milestone $m; leave later milestones untouched. Do not touch .ca/ or git history.
Do not create a commit — the harness commits for you.
CODEX_PROMPT
  fi
  git -C "$WT" add -A
  if ! git -C "$WT" -c user.email=ca-e2e@example.invalid -c user.name="ca e2e" \
       commit -qm "feat($ID): milestone $m" 2>/dev/null; then
    # a real implementer may have committed on its own; only "nothing happened" is a failure
    [ "$(git -C "$WT" rev-parse HEAD)" != "$before_head" ] \
      || fail "milestone $m produced no change and no commit"
  fi
  ( cd "$WT" && python3 -m unittest discover -s tests -t . -q ) > "$WORKDIR/tests-m$m.log" 2>&1 \
    || { cat "$WORKDIR/tests-m$m.log"; fail "milestone $m left the tree red"; }
  echo "milestone $m: committed, tests green"
}

step "Phase 2 — Codex builds milestone 1 (implementer=$IMPLEMENTER)"
implement_milestone 1

# ------------------------------------------------------- Step 2.1: THE DRAFT PR
step "Phase 3 — push and OPEN THE DRAFT PR (the loop's fail-closed gate)"
git -C "$WT" push -q -u origin "$BR"
"$GH_BIN" pr view "$BR" >/dev/null 2>&1 || \
  "$GH_BIN" pr create --draft --base "$BASE" --head "$BR" --title "feat: $ID" --body-file "$RUN/plan.md"
PR="$("$GH_BIN" pr view "$BR" --json number --jq .number)"
[ -n "$PR" ] || fail "no PR number after create"
IS_DRAFT="$("$GH_BIN" pr view "$PR" --json isDraft --jq .isDraft)"
[ "$IS_DRAFT" = true ] || fail "the PR was not opened as a draft"
echo "PR OPEN: #$PR (draft=$IS_DRAFT)  <-- the E2E reached PR open"
"$GH_BIN" pr diff "$PR" --name-only | grep -q 'src/wallet.py' || fail "pr diff does not show the change"

# --------------------------------------------------- Step 2.2: checkpoint review
step "Phase 4 — Claude checkpoint review of milestone 1 (mode=checkpoint)"
bash "$SCRIPTS/claude-review.sh" \
  --plan "$RUN/plan.md" --pr "$PR" --worktree "$WT" \
  --mode checkpoint --round 1 --out "$RUN/review-checkpoint-1.json"
python3 "$VALIDATOR" "$RUN/review-checkpoint-1.json" \
  --expected-mode checkpoint --expected-round 1 --expected-producer blind >/dev/null \
  || fail "checkpoint review failed contract validation"
CP_VERDICT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$RUN/review-checkpoint-1.json")"
echo "checkpoint verdict: $CP_VERDICT"
# a checkpoint verdict must NEVER be able to promote, even when it approves
if bash "$SCRIPTS/promote-pr.sh" --review "$RUN/review-checkpoint-1.json" --pr "$PR" --round 1 >/dev/null 2>&1; then
  fail "a checkpoint verdict promoted the PR"
fi
[ "$("$GH_BIN" pr view "$PR" --json isDraft --jq .isDraft)" = true ] || fail "PR left draft after a checkpoint"
echo "checkpoint could not promote the PR (still draft) — correct"

step "Phase 5 — Codex builds milestone 2"
implement_milestone 2
git -C "$WT" push -q origin "$BR"

# ------------------------------------------------------- Step 3: final review
step "Phase 6 — final review (dual by default; CA_DUAL_REVIEW=0 falls back to Claude-only)"
FINAL="$RUN/review-round-1.json"
META="$RUN/review-round-1.meta.json"
# This branch is copied from the $ca-implement-plan skill on purpose: the E2E must exercise the
# DEFAULT the loop actually takes, not a path the harness picked for it.
CLAUDE_ONLY=""
[ "${CA_DUAL_REVIEW:-1}" = "0" ] && CLAUDE_ONLY="--claude-only"
bash "$SCRIPTS/dual-review.sh" \
  --plan "$RUN/plan.md" --pr "$PR" --worktree "$WT" --round 1 --out-dir "$RUN" $CLAUDE_ONLY
WANT_DUAL=true; [ "${CA_DUAL_REVIEW:-1}" = "0" ] && WANT_DUAL=false
GOT_DUAL="$(python3 -c 'import json,sys;print(str(json.load(open(sys.argv[1]))["dual_review"]).lower())' "$META")"
[ "$GOT_DUAL" = "$WANT_DUAL" ] \
  || fail "final review took the wrong path: dual_review=$GOT_DUAL, expected $WANT_DUAL"
echo "final review path: dual_review=$GOT_DUAL (CA_DUAL_REVIEW=${CA_DUAL_REVIEW:-unset})"
[ -f "$FINAL" ] || fail "no final verdict produced"
python3 "$VALIDATOR" "$FINAL" --expected-mode final --expected-round 1 >/dev/null \
  || fail "final review failed contract validation"
VERDICT="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["verdict"])' "$FINAL")"
PRODUCER="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["producer"])' "$FINAL")"
echo "final verdict: $VERDICT (producer=$PRODUCER)"
echo "meta: $(cat "$RUN/review-round-1.meta.json")"
if [ "$WANT_DUAL" = true ]; then
  [ -f "$RUN/review-round-1.blind.json" ] || fail "blind review not kept for audit"
fi

# ------------------------------------------------------------ Step 5: promote
step "Phase 7 — promotion is gated by the verdict"
set +e
bash "$SCRIPTS/promote-pr.sh" --review "$FINAL" --pr "$PR" --round 1 > "$WORKDIR/promote.log" 2>&1
PROMOTE_RC=$?
set -e
NOW_DRAFT="$("$GH_BIN" pr view "$PR" --json isDraft --jq .isDraft)"
if [ "$VERDICT" = approve ]; then
  [ "$PROMOTE_RC" -eq 0 ] || { cat "$WORKDIR/promote.log"; fail "approve did not promote"; }
  [ "$NOW_DRAFT" = false ] || fail "approve promoted but the PR is still a draft"
  echo "approve -> PR promoted to ready"
else
  [ "$PROMOTE_RC" -ne 0 ] || fail "$VERDICT promoted the PR"
  [ "$NOW_DRAFT" = true ] || fail "$VERDICT left the PR non-draft"
  echo "$VERDICT -> PR correctly left as a draft"
  cat "$WORKDIR/promote.log"
fi

step "Phase 7b — the approval does not survive a new push (stale-head gate)"
printf 'A commit pushed after the review finished.\n' > "$WT/docs/post-review-drift.md"
git -C "$WT" add -A
git -C "$WT" -c user.email=ca-e2e@example.invalid -c user.name="ca e2e" \
  commit -qm "docs($ID): a commit the review never saw"
git -C "$WT" push -q origin "$BR"
if bash "$SCRIPTS/promote-pr.sh" --review "$FINAL" --pr "$PR" --round 1 > "$WORKDIR/stale.log" 2>&1; then
  fail "a verdict for an older commit still promoted the PR"
fi
grep -q "head_sha" "$WORKDIR/stale.log" || {
  cat "$WORKDIR/stale.log"; fail "the refusal did not name the moved head"; }
echo "post-review push -> the old verdict no longer promotes"

step "Phase 8 — exchange summary posted to the PR"
GH_BIN="$GH_BIN" bash "$SCRIPTS/post-summary.sh" "$RUN" "$PR"
python3 - "$CA_GH_SIM_STATE" "$PR" <<'CHECK_PY'
import json, sys
state = json.load(open(sys.argv[1], encoding="utf-8"))
pr = next(p for p in state["prs"] if p["number"] == int(sys.argv[2]))
assert pr["comments"], "no exchange summary comment was posted"
body = pr["comments"][-1]
assert "Checkpoint 1" in body, "summary is missing the checkpoint round"
assert "Round 1" in body, "summary is missing the final round"
print("summary comment contains both the checkpoint and the final round")
CHECK_PY

step "Phase 9 — the loop left no untracked run state behind"
# preserve the round artifacts for the caller's assertions before the worktree goes away
cp -R "$RUN" "$WORKDIR/run-artifacts"
[ -z "$(git -C "$WT" status --porcelain)" ] || {
  git -C "$WT" status --short
  fail "the worktree is dirty; /ca:clean-worktrees could never reclaim it"
}
git -C "$REPO" worktree remove "$WT" || fail "worktree could not be removed without --force"
echo "worktree reclaimed cleanly"

printf '\nE2E OK: reached PR open (#%s) and completed the loop; final verdict=%s producer=%s\n' \
  "$PR" "$VERDICT" "$PRODUCER"
