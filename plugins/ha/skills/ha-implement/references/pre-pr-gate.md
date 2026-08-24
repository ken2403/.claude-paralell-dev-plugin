# Risk-scaled assembled-change gate

Per-task review cannot prove cross-task integration. This gate challenges the final branch before PR creation without duplicating the later independent PR review.

## Scale

- LOW: one reviewer for correctness plus no regression; one round.
- MEDIUM: correctness/integration and test/compatibility reviewers, then completeness; second round only after fixes.
- HIGH: correctness, security/abuse, and migration/ordering reviewers plus completeness; maximum two fix rounds in `$ha-implement`.

The canonical risky-surface list lives in `$ha-code-review`. Blast radius, irreversible effects, and broad refactors can raise the grade.

## Evidence gate

Review the base-to-head diff and relevant unchanged call sites. Refutation requires a counterexample or check. `UNCERTAIN` is a blocker only when uncertainty concerns a risky surface or required behavior. Verify every finding before fixing it.

## Separation from final review

This is an author-side shipping gate. It may fix the branch and ensures a PR is not obviously broken. `$ha-review-pr` is a separate, SHA-bound, preferably fresh-thread review after the PR exists and remains mandatory before `$ha-merge-pr`.
