# Sequential fresh-subagent task loop

## Task brief

Each brief contains only what the writer needs: exact plan task, absolute worktree, allowed files, existing interfaces to preserve, acceptance criteria, test strategy/command, repository rules, and forbidden actions. The writer must inspect current code rather than trust stale snippets.

## Writer contract

One fresh writer implements one task. It captures RED evidence before behavior code, makes the smallest coherent change, runs focused GREEN checks, and reports changed files plus actual output. It does not commit, push, ask the human, edit outside scope, or delegate.

## Two-stage review

After the writer stops:

1. The specification reviewer checks only task/plan alignment, missing behavior, and whether tests prove acceptance criteria.
2. The quality reviewer applies HA code-review standards, including security and propagation beyond the diff.

Reviewers are read-only and receive the task brief plus current diff, not the writer's persuasive summary. The parent verifies findings. A fix is reviewed again; passing tests do not erase a valid design or security defect.

## Ledger and resume

Record task state as `pending`, `writing`, `reviewing`, `fixing`, or `complete`; include test commands/results, finding disposition, and commit SHA. On resume, verify the SHA and working tree before trusting `complete`. Never have two tasks in `writing` or `fixing` simultaneously.
