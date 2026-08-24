---
name: ha-implement
description: Implement one human-approved HA plan completely in an isolated persistent worktree, using sequential fresh Codex subagents, per-task specification and quality review, risk-scaled adversarial verification, fresh build evidence, and an open PR. Use after $ha-plan or when given an equivalent approved task-by-task plan. Stops at the PR; use $ha-review-pr independently afterward.
license: MIT
---

# HA implement

Drive one approved plan to an open PR. Resolve this skill directory from the loaded `SKILL.md` path. Read `references/task-loop.md`, `references/pre-pr-gate.md`, and `references/agent-control.md` before delegation.

## 1. Digest and validate the plan

- Read the plan and applicable `AGENTS.md` files in full.
- Require `Status: approved` or obtain explicit human approval now. Never infer approval from silence.
- Restate scope, success criteria, task order, test commands, and risk grade.
- Compare the plan with current code. If a path/interface/assumption drifted materially, stop for a human decision; do not silently rewrite the design.

## 2. Create or reuse isolation

Choose `feat/<slug>` unless the plan specifies an approved branch. From the main checkout run:

```bash
eval "$(bash <skill-dir>/scripts/new-worktree.sh 'feat/<slug>')"
test -n "${WORKTREE_PATH:-}" || exit 1
```

The script creates a persistent `.claude/worktrees/ha/<slug>` worktree or reuses the current linked worktree. It refuses branch/path collisions.

Hard rule: every edit targets an absolute path under `$WORKTREE_PATH`; every command uses `git -C "$WORKTREE_PATH"` or one self-contained `cd "$WORKTREE_PATH" && ...`. Never edit the main checkout. Add `.ha/` to the repository-local Git exclude for the task ledger.

## 3. Run the sequential task loop

Maintain `.ha/sdd/<plan-slug>/ledger.md` with task status, RED evidence, GREEN evidence, review findings, fixes, and commit SHA. Resume from this ledger; never rerun a completed task without evidence that its commit is absent.

For each task in order:

1. Create a task brief containing the exact plan text, allowed files, acceptance criteria, test command, absolute worktree, and applicable `AGENTS.md` rules.
2. Start exactly one fresh writer subagent. It may edit only this task's files, must not commit/push, ask the human, or spawn agents. It must capture a failing test before behavior code unless the plan approved another strategy.
3. Wait for the writer. Inspect the diff and actual test output.
4. Start two fresh read-only reviewers, concurrently when useful:
   - specification reviewer: plan/acceptance/test-strategy alignment;
   - quality reviewer: `$ha-code-review` dimensions and regression risk.
   Give them the task brief and diff, not the writer's self-assessment. They must not edit or spawn agents.
5. Verify every finding against the code. Give the writer one bounded fix turn for verified findings, then re-run the affected review. Allow at most two review/fix cycles; unresolved blocking issues stop for the human.
6. Run the task checks freshly, then commit from the main agent using the target repository's commit rules. Update the ledger.

There is never more than one active writer. The main agent alone owns task state, integration, Git operations, and human questions.

## 4. Risk-scaled assembled-change gate

Review `git -C "$WORKTREE_PATH" diff <base>...HEAD` as an assembled system using `$ha-adversarial-verification`:

- `LOW`: one refutation-oriented read-only reviewer; one round.
- `MEDIUM`: two distinct reviewers plus completeness check; a second round only after fixes.
- `HIGH`: three distinct reviewers plus completeness critic; maximum two fix/review rounds.

A finding is actionable only with concrete evidence. `UNCERTAIN` blocks risky surfaces until evidence or a human decision resolves it. Apply verified fixes with one writer at a time and repeat the affected checks.

## 5. Objective verification

Run `<skill-dir>/scripts/run-checks.sh "$WORKTREE_PATH"` plus every plan-specific command. Read exit codes and output before claiming success. Confirm every required behavior/failure-mode test exists and passed. On failure, diagnose the root cause before editing; do not patch by guesswork.

## 6. Open the PR and stop

Ensure `.ha/` is excluded, no secrets or unrelated files are staged, then commit remaining work, push the feature branch, and create a PR. Use `--draft` when any check is red, a blocking claim is unresolved, or the plan was materially deviated from without approval. The PR body must include:

- plan path and risk grade;
- design summary and deviations;
- task/commit summary;
- exact verification commands and results;
- adversarial gate claims and verdicts;
- residual risk or draft blocker.

Always open a PR; never merge here. Report the URL and hand off to a fresh review context: `$ha-review-pr <PR>`.
