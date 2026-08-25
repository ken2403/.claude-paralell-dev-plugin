---
name: ha-review-pr
description: Independently and adversarially review a GitHub PR against its plan, repository rules, correctness, behavioral test coverage, security, architecture, and cross-codebase consistency. Use after $ha-implement or for any PR needing high confidence. Produces a strict SHA-bound review record consumed by $ha-merge-pr; optionally posts a human-readable GitHub review comment.
license: MIT
---

# HA review PR

Act as an independent reviewer, not the implementer. Prefer a new Codex thread. Ignore prior implementation rationales and ground every conclusion in the PR, plan, repository, and fresh checks.

Resolve this skill directory from the loaded `SKILL.md` path. Read `references/review-contract.md`, `references/reviewer-protocol.md`, and `references/agent-control.md` before reviewing.

## 1. Resolve and snapshot the PR

Resolve the explicit PR number or auto-detect the current branch PR. Fetch:

```bash
gh pr view "$PR" --json number,title,body,headRefName,headRefOid,baseRefName,isDraft,state,additions,deletions,files,reviewDecision,statusCheckRollup
gh pr diff "$PR"
```

Record the exact `headRefOid`. Read the linked plan/issue and applicable `AGENTS.md`. If the PR head changes during review, discard the result and restart against the new SHA.

## 2. Run independent lenses

Start three fresh read-only subagents in parallel. Each gets the PR number, head SHA, plan/intent, exact lens, output contract, no-edit/no-comment/no-nested-agent rule, and must return only evidence-backed findings:

1. correctness and edge cases;
2. test rigor, missed propagation, and compatibility;
3. security, architecture, operations, and production readiness.

For a small low-risk PR, two lenses may be combined, but never use fewer than two independent reviewers. For risky surfaces, keep all three and add a completeness critic asking what the panel missed.

## 3. Adjudicate in the main agent

- Read the full diff yourself; do not outsource architectural fit, repository-rule compliance, or security-critical judgment.
- Verify every proposed finding against surrounding code and tests. Reject speculative or duplicate claims.
- A behavior change without a test that would fail without the change is blocking unless the PR gives a defensible untestable reason.
- Run targeted read-only checks that settle disputed claims and at least one fresh verification command appropriate to the change.
- Use `REFUTED`, `UPHELD`, or `UNCERTAIN` for central claims. `UNCERTAIN` on a risky surface blocks approval.

## 4. Produce and record the verdict

Write one `ha_codex_review.v1` JSON file matching `references/review-contract.md`. Use `APPROVE` only when there are zero blocking findings, all risky claims are upheld with evidence, and verification contains at least one passing record. Use `REQUEST_CHANGES` when at least one blocking defect is established; use `BLOCKED` when required evidence cannot be obtained.

Validate and bind it to the current PR head:

```bash
python3 <skill-dir>/scripts/validate-review.py review.json --expected-pr "$PR" --record
```

The validator re-reads GitHub's current head SHA and stores the approved/rejected record under the repository's Git common directory. `$ha-merge-pr` accepts only an `APPROVE` record for the still-current SHA.

If the user passed `--comment`, post the human-readable summary with `gh pr review --comment`; never submit a GitHub approval on the author's behalf.

Report blocking issues first with `path:line`, evidence, impact, and specific fix. Hand off `REQUEST_CHANGES` to `$ha-apply-feedback <PR>` and `APPROVE` to `$ha-merge-pr <PR>`.
