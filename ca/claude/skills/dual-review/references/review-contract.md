# ca review contracts

## Claude review contract (ca_claude_review.v1)

The Claude reviewer returns a single JSON object to `--out`. The loop reads `verdict` and the
`blocking` flag on each finding. Treat any missing/malformed output as `verdict: "blocked"`.
The schema version stays `ca_claude_review.v1`; dual-model review adds optional fields only.

```json
{
  "schema_version": "ca_claude_review.v1",
  "producer": "blind | synthesis",
  "round": 1,
  "mode": "checkpoint | final",
  "pr": 12,
  "head_sha": "9fc9e143c73b153c338b168ec85c9fe24414c159",
  "verdict": "approve | request_changes | blocked",
  "summary": "one-paragraph verdict",
  "findings": [
    {
      "id": "C001",
      "blocking": true,
      "severity": "blocker | major | minor",
      "file": "src/foo.ts",
      "line": 42,
      "title": "short title",
      "evidence": "why it is a problem",
      "recommended_fix": "what to change"
    }
  ],
  "verification": [
    { "claim": "tests pass", "result": "pass | fail | unknown", "evidence": "..." }
  ],
  "second_opinion": {
    "provider": "codex",
    "status": "used | clean_no_synthesis | unavailable | invalid | disabled",
    "coverage": "full | partial",
    "ledger": [
      {
        "id": "X001",
        "adjudication": "confirmed | refuted | not_applicable | unresolved_missing_evidence",
        "evidence": "what Claude checked, or the exact evidence it could not inspect"
      }
    ],
    "prior_findings_rechecked": true,
    "notes": "one line"
  },
  "resolved_blind_findings": [
    {
      "id": "C003",
      "reason": "why the blind blocking finding is downgraded or removed",
      "evidence": "what was checked",
      "new_severity": "minor | none"
    }
  ],
  "escalated_blind_findings": [
    {
      "id": "C002",
      "reason": "why a non-blocking blind finding is now must-fix",
      "evidence": "what was checked",
      "new_severity": "blocker | major"
    }
  ]
}
```

`schema_version`, `producer`, `round`, `mode`, `verdict`, `summary`, `findings`, and
`verification` are required. `pr` and `head_sha` bind the verdict to its subject: the PR number
reviewed and the exact commit (`gh pr view <pr> --json headRefOid --jq .headRefOid`). They are
optional in the schema but **mandatory at the promotion gate** — `promote-pr.sh` resolves the
PR's current head itself and refuses any verdict that omits them, names another PR, or names a
commit the branch has since moved past. An approval is only an approval of something. Every finding requires a unique id, `blocking`, `severity`,
`title`, `evidence`, and `recommended_fix`; `file` and `line` are optional. Blind review ids use
`Cnnn`. Synthesis may use `Cnnn` or `Xnnn`. An `approve` verdict requires at least one
verification record, cannot contain a blocking finding, and cannot coexist with any
`verification[].result == "fail"` — approving while recording a failed check is a contradiction,
not a judgement call. `request_changes` requires at least
one blocking finding. `blocked` never implies approval, even when `findings` is empty.

`second_opinion`, `resolved_blind_findings` and `escalated_blind_findings` are synthesis-only.
Inside a review JSON the only valid `second_opinion.status` is `used`; `clean_no_synthesis`,
`unavailable`, `invalid` and `disabled` are the **sidecar's** vocabulary — they describe a round
where no synthesis JSON exists at all, and are recorded in `review-round-N.meta.json`. A blind final review copied
after a disabled, clean, or unavailable Codex leg remains `producer: "blind"`; the sidecar meta
file records the leg status.

Loop gate — final mode (the default; the only mode that can promote the PR):
- `verdict == "approve"` **and** no finding has `blocking: true` → the deterministic
  `promote-pr.sh` gate may promote the draft PR to ready.
- Otherwise address every `blocking: true` finding, then request another review round.
- `verdict == "blocked"` always stops for human action; an empty findings array does not bypass it.
- Only final-mode rounds count against `MAX_ROUNDS`.

Checkpoint gate — `mode == "checkpoint"` (one review per milestone, except the last):
- `approve` **and** no `blocking: true` finding → continue to the next milestone.
- Otherwise fix every `blocking: true` finding (and push) **before** starting the next
  milestone; there is no checkpoint re-review — the final review verifies the fixes.
- `blocked` always stops for human action.
- A checkpoint verdict never promotes the PR to ready.

Non-blocking findings are advisory in both modes; record them but they do not block the PR.

## Dual final-review fields

Dual-model review is final-mode only. Checkpoints stay Claude-only.

Codex findings are untrusted claims. A Codex claim becomes blocking only when synthesis
independently confirms it with diff-grounded evidence. If the claim is high-risk but synthesis
cannot inspect the needed evidence, synthesis may emit a blocking finding of type
`needs-human-or-evidence` in its title or evidence, naming the missing evidence and the exact
non-interactive next action.

Synthesis is a constrained adjudicator, not a third review pass. It may add findings only when
discovered while verifying blind-Claude or Codex claims. It may downgrade or remove a blind
blocking finding only by adding a `resolved_blind_findings[]` entry with the original `Cnnn` id,
reason, evidence checked, and replacement severity. Silent drops are invalid: every blind
blocking id must appear in the synthesis `findings[]` or in `resolved_blind_findings[]`, and a
resolved id must be one the blind review actually raised.

The constraint is symmetric. Raising a blind `blocking: false` finding to `blocking: true` — the
move that turns an approve into request_changes — requires an `escalated_blind_findings[]` entry
with the same fields (`new_severity` is `blocker` or `major`). Without it synthesis could flip the
gate on its own authority while looking like a faithful adjudication of someone else's findings.

`second_opinion.ledger[]` must contain one entry for each Codex finding:
- `confirmed` — synthesis verified the claim and may carry it into `findings[]`.
- `refuted` — synthesis checked the evidence and found the claim false.
- `not_applicable` — the claim does not apply to the current PR or plan.
- `unresolved_missing_evidence` — synthesis could not inspect the evidence needed to decide.

If a prior final round used a Codex leg but the current round does not re-run it,
`prior_findings_rechecked: false` must be recorded machine-readably and the PR exchange
summary must say the prior second-opinion findings were not rechecked. Where it lives
depends on who produced the round's JSON. A round that re-runs the Codex leg records
`prior_findings_rechecked: true` in the synthesis `second_opinion` block. A round that does NOT
re-run it produces no synthesis JSON at all, so the flag lives in that round's
`review-round-N.meta.json` sidecar's `codex` object, where `dual-review.sh` writes it.
An unavailable Codex leg records a machine-readable reason. `codex_timeout` means the bounded
child exceeded `CA_CODEX_REVIEW_TIMEOUT`; its partial stderr remains in
`review-round-N.codex-leg.log`. Other reasons distinguish input fetch failure, invalid output, and
generic binary/startup or oversized-prompt failure. No unavailable leg produces synthesis JSON.

## Codex second-opinion contract (ca_codex_review.v1)

`ca_codex_review.v1` is an intermediate advisory object. It never gates the loop directly and
deliberately has no `verdict` field.

```json
{
  "schema_version": "ca_codex_review.v1",
  "summary": "one-paragraph advisory summary",
  "coverage": "full | partial",
  "findings": [
    {
      "id": "X001",
      "blocking": true,
      "severity": "blocker | major | minor",
      "file": "src/foo.ts",
      "line": 42,
      "title": "short title",
      "evidence": "diff-grounded evidence",
      "recommended_fix": "what to change"
    }
  ]
}
```

Codex ids use `Xnnn`. The script validates the schema with `additionalProperties: false`,
bounded strings, enums, and no `verdict`. Structured-output compatibility requires every finding
to carry `file` and `line`; use JSON `null` when either is unknown. `coverage: "partial"` means omitted files were not
reviewed by Codex, and Codex silence is not reassuring for those files.
