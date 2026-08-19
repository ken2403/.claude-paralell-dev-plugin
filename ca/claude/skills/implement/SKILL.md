---
name: implement
description: Kick off the ca implement loop for a saved plan — create an isolated git worktree for it and print the exact Codex command to run there. Use when the user has a saved plan and wants to build it with the ca loop, or says things like "implement this plan with ca", "start building this plan", "kick off implementation of", "set up the worktree for", or invokes /ca:implement. Hands off to a Codex session; it does not implement the plan itself.
license: MIT
effort: medium
disable-model-invocation: true
allowed-tools: Read, Bash
---

# implement

Prepare an isolated worktree for a saved plan and hand off to Codex. This is the bridge between `/ca:plan-loop` (which produced the plan) and `$ca-implement-plan` (which builds it). It is human-in-the-loop: you set up isolation and print the launch commands; the human runs Codex.

## Step 1 — Create the worktree

Given the plan path, run the bundled script (it creates a `ca/<plan-id>` worktree off the base branch under `.claude/worktrees/ca/`, copies the plan in, and records a checksum):

```bash
bash "${CLAUDE_SKILL_DIR}/scripts/new-worktree.sh" /abs/path/to/plan.md
```

`CA_BASE` optionally overrides the base branch. Otherwise the script detects origin HEAD, then a
local `main`, `master`, `develop`, or `dev` branch. It records the resolved base with the staged
plan and prints the worktree path, branch, and base.

## Step 2 — Print the Codex kickoff

Report to the human, verbatim, the commands the script printed:

```bash
codex -C "<worktree-path>"
# then in the Codex session:
$ca-implement-plan PLAN=<abs-plan-path>
```

## Step 3 — Recommend the Codex launch settings

The Codex skill cannot set model/effort in its frontmatter, so tell the human to launch Codex with a strong model and high reasoning, e.g.:

```bash
codex -C "<worktree-path>" -m <strong-model> -c model_reasoning_effort=high
```

State clearly what the Codex session will do: it implements the plan milestone by milestone, **opens a draft PR at the first milestone**, gets a Claude checkpoint review (`/ca:review-pr`, `mode=checkpoint`) between milestones, then runs the final review over at most 2 rounds, and — once the final review approves — **marks the PR ready**. Do not attempt to implement the plan from here.
