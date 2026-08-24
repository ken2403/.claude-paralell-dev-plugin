# Agent-control protocol

Use delegation to isolate context and obtain independent evidence, not to surrender orchestration.

## Ownership

The top-level skill agent alone owns human questions, scope, plan/ledger state, Git operations, final adjudication, and external side effects. A subagent never asks the human, commits, pushes, comments, opens/merges PRs, deletes worktrees, changes scope, or starts another agent.

## Prompt contract

Every delegation names:

1. one bounded role and question;
2. absolute repository/worktree path or PR number plus immutable head SHA;
3. exact writable files, or an explicit read-only rule;
4. applicable `AGENTS.md` rules and required references;
5. required checks and evidence format;
6. stop conditions and forbidden actions;
7. `Do not spawn subagents`.

Omitting a boundary is not permission. Prefer raw plan/diff/test artifacts over the parent agent's conclusions so independent review is not anchored.

## Concurrency

- Writers: exactly one active writer for a worktree. Wait before starting another.
- Read-only agents: parallelize only disjoint exploration or independent review lenses, normally at most three at once.
- Never let reviewers edit. Never review while a writer is still changing the target SHA/diff.
- Main integrates all outputs and verifies consequential claims itself.

## Freshness and failure

Use a fresh subagent per task or review lens. A timeout, tool failure, missing evidence, or malformed result is not approval. Retry once with a narrower prompt; then mark `UNCERTAIN` and stop when the caller's gate requires certainty.

## Reviewer output

Require `REFUTED | UPHELD | UNCERTAIN`, `path:line` evidence, commands and actual results, and a concrete counterexample for refutation. Reject pure confidence statements.
