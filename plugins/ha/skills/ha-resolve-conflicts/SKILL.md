---
name: ha-resolve-conflicts
description: Resolve a PR or feature branch against its base branch in an isolated worktree while preserving both sides' intent, then independently verify integration, run the build, commit, and push. Use when GitHub reports conflicts or an out-of-date HA branch. Never resolves in the main checkout.
license: MIT
---

# HA resolve conflicts

Resolve intent, not markers. Resolve this skill directory from the loaded `SKILL.md` path. Read `references/conflict-protocol.md` and `references/agent-control.md` first.

## 1. Resolve target and isolation

Resolve the input as a PR number or branch. All-digit input always means a PR; use `branch:<name>` for an all-digit branch (for example `branch:42`). For a PR, preserve its actual `baseRefName` and bind the checkout to `headRefOid`; never replace a PR base with the repository default:

```bash
eval "$(bash <skill-dir>/scripts/resolve-target.sh "$TARGET" "$REPO_ROOT")"
eval "$(bash <skill-dir>/scripts/attach-or-create-worktree.sh "$BRANCH" "${EXPECTED_HEAD:-}")"
test -n "${WORKTREE_PATH:-}" || exit 1
```

The helper refuses the main checkout. Use absolute worktree paths and `git -C` for every operation.

## 2. Surface and plan conflicts

Require a clean feature worktree. Fetch the base and run `git -C "$WORKTREE_PATH" merge --no-edit "origin/$BASE"`; a conflict exit is expected. List unmerged files.

Before editing, inspect each hunk plus both parents and record a per-hunk strategy: keep ours, keep theirs, or combine, with the intent preserved from each side. Ask the human when intent cannot be recovered from code, tests, history, plan, or PR discussion.

## 3. Resolve under controlled writes

Use one writer at a time. Give it the absolute worktree, exact files, approved strategies, applicable rules, and no commit/push/question/nested-agent permission. The main agent integrates and stages each resolved file. Never choose an entire side mechanically when both contain real behavior.

## 4. Verify integration

Confirm no unmerged paths or conflict markers remain and run `git diff --check`. Start a fresh read-only verifier against: both sides' intent survives, cross-file seams agree, and no marker or silent deletion remains. Then run `<skill-dir>/scripts/run-checks.sh "$WORKTREE_PATH"` plus affected integration tests.

If verification fails, diagnose and fix; if intent remains uncertain, abort the merge and ask. Only after green evidence commit the merge and push without force. Any prior HA review record becomes stale, so require `$ha-review-pr` again.
