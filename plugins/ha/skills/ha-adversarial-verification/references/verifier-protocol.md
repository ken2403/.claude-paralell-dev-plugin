# Refutation-oriented verifier protocol

Each verifier receives one falsifiable claim and one distinct lens. It is read-only and reports:

```text
Claim: ...
Lens: ...
Verdict: REFUTED | UPHELD | UNCERTAIN
Evidence:
- path:line — observation — implication
Checks:
- command — actual result
Counterexample or missing evidence: ...
```

`REFUTED` without a counterexample or direct failure is invalid. `UPHELD` requires positive evidence that addresses the claim. `UNCERTAIN` is correct when the repository or available checks cannot settle it.

The verifier must not edit, commit, push, comment, ask the human, broaden scope, or spawn subagents. It should inspect relevant unchanged code and call sites, not only the diff.
