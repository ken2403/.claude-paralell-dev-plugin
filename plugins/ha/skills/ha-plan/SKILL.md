---
name: ha-plan
description: Plan one non-trivial feature thoroughly before implementation. Use when the user wants a design dialogue, repository-grounded impact analysis, adversarial red-team, explicit behavioral test strategy, and a human-approved plan ready for $ha-implement. Accepts an issue, specification file, or free-text feature request. Never writes feature code.
license: MIT
---

# HA plan

Create one executable design-plus-implementation plan. Front-load ambiguity, failure modes, and tests; do not write feature code or open a PR.

Resolve this skill directory from the loaded `SKILL.md` path. Read `references/design-plan-delta.md` before the design red-team and `references/agent-control.md` before delegating.

## 1. Resolve the request and repository rules

- Resolve `#N` with `gh issue view N`; read a referenced file; otherwise use the request text.
- Find the repository root and read every applicable `AGENTS.md` from root to the affected paths.
- Restate the goal, non-goals, constraints, and unknowns. Ask one focused question at a time until no material ambiguity remains.
- Choose the plan directory in this order: an explicit `plan.dir:` instruction, an existing `docs/plans/`, then `docs/ha/plans/`. Never use `docs/superpowers/`.

## 2. Explore ground truth

Keep the main agent responsible for decisions and human questions. Delegate only bounded read-only work:

- Start at most two exploration subagents with disjoint questions: affected code/call sites and tests/conventions.
- For a cross-cutting or risky change, add at most one read-only impact analyst for compatibility, migration, concurrency, and blast radius.
- Tell every subagent the repository root, exact question, read-only constraint, no nested delegation, and required `path:line` evidence.
- Wait for all results; verify consequential claims yourself. Record uncertainty rather than inventing facts.

Assign `LOW`, `MEDIUM`, or `HIGH` risk using the canonical risky-surface list in `$ha-code-review` plus blast radius and reversibility.

## 3. Design with the human

Present two or three viable approaches with trade-offs and a recommendation. Cover data flow, interfaces, failure behavior, compatibility/migration, security boundaries, observability, and rollout/rollback where relevant. Make every deviation from the request explicit.

Ask the human to approve the design before turning it into implementation tasks. An unanswered question is not approval.

## 4. Red-team the design

Enumerate the design's load-bearing claims. Use `$ha-adversarial-verification` in design mode:

- `LOW`: one read-only verifier for missing requirements and regressions.
- `MEDIUM`: two independent verifiers for correctness/test rigor and integration/compatibility.
- `HIGH`: three independent verifiers for correctness, security/abuse, and migration/ordering, then one completeness critic.

Subagents return evidence, not edits or replacement plans. Convert every surviving concern into a success criterion, explicit mitigation, or test task.

## 5. Write the fused plan

Save `YYYY-MM-DD-<slug>.md` in the selected plan directory with:

1. `Status: awaiting approval`.
2. Goal, non-goals, constraints, chosen design, explicit deviations, and risk grade.
3. File map with exact paths and interfaces.
4. Ordered, bite-sized tasks. Each task names files, dependencies, acceptance criteria, and commands.
5. A test strategy per behavior: default `RED -> GREEN`; alternatives (`characterization`, `test-after`, `e2e`, or untestable) require a one-line reason.
6. Security, migration, rollback, observability, and compatibility work where applicable.
7. Verification matrix mapping every requirement and red-team concern to a test or check.
8. Residual risks and human decisions.

Run a final consistency check: no placeholders, every symbol/path exists or is explicitly new, dependencies are ordered, every behavior change has a covering test, and no plan artifact appeared under `docs/superpowers/`.

## 6. Approval gate

Show the plan path, approach, file map, risk grade, test strategy, and residual risks. Ask the human to choose approval or adjustment. On approval, change only the plan status to `Status: approved`; otherwise revise and ask again.

End with: `plan approved at <path>; next: $ha-implement <path>`.
