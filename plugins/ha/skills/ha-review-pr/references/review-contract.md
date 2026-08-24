# HA Codex review contract

`$ha-review-pr` emits one JSON object. Unknown fields are rejected.

```json
{
  "schema_version": "ha_codex_review.v1",
  "pr": 123,
  "head_sha": "40 lowercase hex characters",
  "verdict": "APPROVE | REQUEST_CHANGES | BLOCKED",
  "summary": "concise evidence-based verdict",
  "findings": [
    {
      "id": "H001",
      "blocking": true,
      "severity": "critical | high | medium | low",
      "file": "src/example.ts",
      "line": 42,
      "title": "short defect",
      "evidence": "counterexample or observed failure",
      "recommended_fix": "specific correction and test"
    }
  ],
  "verification": [
    {
      "claim": "targeted tests pass",
      "result": "pass | fail | unknown",
      "evidence": "command and observed result"
    }
  ]
}
```

All root fields are required. Finding IDs are unique `Hnnn`. `file` and `line` may be JSON `null` only when no precise location exists. Strings must be non-empty.

- `APPROVE`: zero blocking findings and at least one `pass` verification.
- `REQUEST_CHANGES`: at least one blocking finding.
- `BLOCKED`: evidence/tooling is insufficient; never counts as approval even with no findings.

The validator compares `pr` and `head_sha` with live GitHub data before recording. Any head change invalidates the record.
