---
name: ca-second-opinion
description: Produce the bounded offline Codex advisory JSON used internally by ca dual review. Use only when explicitly invoked by ca's review orchestrator; do not use for full repository PR reviews, implementation, synthesis, or user-facing verdicts.
license: MIT
---

# ca second opinion

Produce one independent advisory review for ca's dual-review orchestrator. The caller supplies the
plan, PR metadata, diff context, reviewed worktree path, required coverage value, and the output
schema.

## Hard boundaries

- Work as one agent in one bounded pass. Do not spawn, delegate, or wait for subagents.
- Do not invoke repository-specific PR-review, audit, or adversarial-review skills. Apply relevant
  repository instructions and code-review standards as criteria, not as orchestration workflows.
- Stay offline and read-only. Do not use network tools or `gh`, modify files, post comments, or run
  broad test suites.
- Do not read `.ca/runs`, `.ca/reviews`, or `.agents/skills`. Inspect only the supplied plan and diff,
  governing `AGENTS.md` files, changed code, and the minimum callers or tests needed to verify a
  concrete claim.
- Treat the supplied diff coverage as authoritative. Never claim full coverage when the caller
  requires partial coverage.

## Output

Return exactly one JSON object matching the caller-provided `ca_codex_review.v1` schema. Do not emit
Markdown, commentary, progress messages, or a verdict. Findings are advisory claims for Claude to
adjudicate; include only specific, evidence-backed defects that the current change introduced or
exposed.
