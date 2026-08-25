---
name: ha-code-review
description: Apply HA engineering standards whenever Codex implements, changes, verifies, or reviews code. Covers code quality, behavior-focused test rigor, security, and consistency beyond the diff, including the canonical risky-surface list and the blocking rule for behavior changes without covering tests.
license: MIT
---

# HA code-review standards

Apply these standards while writing and reviewing. Repository-specific conventions take precedence when verified from `AGENTS.md` and existing code.

## Four dimensions

- **Quality:** clarity, minimal complexity, type safety, error handling, performance, maintainability, and local style. Read `references/code-quality.md` when evaluating implementation details.
- **Test rigor:** every behavior change has a test that fails without it, including relevant boundaries, errors, and state transitions. A behavior change without a covering test is **High/blocking** unless the author records a defensible untestable reason. Read `references/test-rigor.md`.
- **Security:** never regress injection resistance, authorization, secrets, cryptography, deserialization, SSRF, path handling, sensitive logs, or dependency safety. Read `references/security.md` for security-sensitive work.
- **Consistency beyond the diff:** trace renamed contracts, schemas, APIs, configs, call sites, docs, and cross-layer behavior. Read `references/consistency.md` for broad changes.

## Canonical risky surfaces

Treat a change as risky when it touches authentication, authorization, sessions, tokens, cryptography, secrets, money/billing, external-input parsing, file uploads, permissions, data migration/deletion, or SQL/shell string construction. Also escalate concurrency and irreversible operations when failure can corrupt or lose data.

## Finding standard

Understand existing patterns first. Verify each finding against surrounding code and mitigation layers. Report only actionable evidence:

`Severity — path:line — concrete defect and impact — specific fix/test`

Do not block on preference, style speculation, or unverifiable concern. Use `UNCERTAIN` when evidence is missing; it blocks only on risky surfaces until resolved.
