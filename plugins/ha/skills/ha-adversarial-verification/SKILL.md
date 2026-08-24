---
name: ha-adversarial-verification
description: Refute load-bearing claims about a design, implementation, conflict resolution, or PR using bounded independent read-only Codex subagents and evidence-gated adjudication. Use for risk-scaled HA design red-teams, assembled-change pre-PR gates, independent PR reviews, and any risky correctness, security, completeness, or no-regression claim.
license: MIT
---

# HA adversarial verification

Try to prove the change wrong. Resolve this skill directory from the loaded `SKILL.md` path. Read `references/verifier-protocol.md` and `references/agent-control.md` before dispatch.

## 1. Enumerate claims

State specific falsifiable claims for correctness, safety, completeness, compatibility, and no regression. Scale them to the change; do not review generic qualities without a concrete claim.

## 2. Choose bounded rigor

- `LOW`: one verifier, one round.
- `MEDIUM`: two distinct lenses plus completeness check; second round only after a fix.
- `HIGH`: three distinct lenses plus completeness critic; maximum three rounds here, though caller-specific limits may be lower.

Run read-only verifiers in parallel only when their questions are independent. Every prompt includes exact root/PR, claim, lens, evidence format, no edits, no comments, no nested agents, and no human questions. The caller's main agent remains the only adjudicator.

## 3. Judge evidence

- `REFUTED` requires a concrete counterexample, failing check, or path/line proof.
- `UPHELD` requires positive evidence, not absence of findings.
- `UNCERTAIN` means the evidence could not settle the claim. Treat it as failure on risky surfaces.
- Majority voting can increase recall but never overrides concrete contradictory evidence; the main agent investigates disagreement.

After claim reviewers, ask a separate completeness critic what requirement, call site, ordering, error path, or test all others missed. New evidence becomes a claim for the next round.

## 4. Fix and repeat

Verify findings before editing. Use one bounded writer at a time for minimal fixes, then re-run affected checks and claims. Stop on a clean round or the round cap. At the cap, unresolved risky claims mean `FAIL`, not provisional approval.

Report claims, verdicts, reviewer lenses, exact evidence/check output, fixes, and residual risk.
