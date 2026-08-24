---
name: ha-apply-feedback
description: Evaluate and address HA, human, or GitHub review feedback on a PR in an isolated worktree, verifying each claim before changing code, using test-first fixes, re-verification, and a push to the existing PR branch. Use after $ha-review-pr requests changes or when the user asks Codex to act on PR feedback.
license: MIT
---

# HA apply feedback

Apply verified feedback without blind obedience or edits to the main checkout. Resolve this skill directory from the loaded `SKILL.md` path. Read `references/feedback-discipline.md` and `references/agent-control.md` first.

## 1. Gather and normalize feedback

Resolve the PR number or auto-detect it. Fetch the PR head branch, diff, reviews, review threads, and comments. Also read the latest HA review record if present under the Git common directory. Turn all feedback into a table: source, claim, location, severity, evidence needed, and status.

For each item, verify it against current code before acting. Mark it `valid`, `already fixed`, `incorrect`, `unclear`, or `conflicts with approved design`. Push back with technical evidence when wrong; ask the human when material intent is unclear. Do not use performative agreement.

## 2. Attach an isolated worktree

```bash
BRANCH="$(gh pr view "$PR" --json headRefName --jq .headRefName)"
eval "$(bash <skill-dir>/scripts/attach-or-create-worktree.sh "$BRANCH")"
test -n "${WORKTREE_PATH:-}" || exit 1
```

The script reuses or creates `.claude/worktrees/ha/<slug>` and refuses the main checkout. Every edit uses an absolute path under `$WORKTREE_PATH`; every command uses `git -C` or one self-contained `cd` call.

## 3. Fix one verified item at a time

- Keep one active writer only. The main agent may make a small fix; otherwise start one bounded writer subagent with exact files, worktree, acceptance criteria, and no commit/push/question/delegation permission.
- For behavior changes, first add or identify a test that fails for the reported defect, then make the minimal fix and show it passes.
- Do not combine unrelated refactors with feedback fixes.
- Reply to inline threads with the concrete resolution or evidence-based rejection when tooling permits.

## 4. Re-verify and update the PR

For correctness/security findings, start a fresh read-only verifier against the claim that the fix closes the defect without regression. Run targeted tests and `<skill-dir>/scripts/run-checks.sh "$WORKTREE_PATH"`.

Commit using repository rules and push the existing branch. Do not force-push. The prior HA approval record is intentionally stale because the head SHA changed; report that `$ha-review-pr <PR>` must run again before merge.
