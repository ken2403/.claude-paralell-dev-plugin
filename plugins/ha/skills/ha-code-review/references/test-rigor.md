# Test Rigor Standards

## Contents
- How to apply
- The blocking rule
- Behavior coverage, not line coverage
- What to cover (by behavior class)
- Red-green evidence
- Untestable changes (the escape hatch)
- Review heuristics

## How to apply

1. **List the behaviors the diff changes** — new behavior, changed behavior, removed
   behavior — from the diff itself, never from the PR description alone.
2. **For each behavior, find its covering test**: a test that fails if the
   implementation change is reverted. No such test → apply the blocking rule.
3. **Judge adequacy by behavior class** (table below), not by a line-coverage number.

## The blocking rule

A behavior change without a covering test is a **High/blocking** finding unless the
author states why it is untestable — in the PR Notes, or in the report when no PR
exists yet. The stated reason is part of the review surface: verify it holds (see the
escape hatch below), don't take it on faith.

## Behavior coverage, not line coverage

- A **covering test** is one that fails when the behavior change is reverted. A test
  that merely executes the new lines without asserting on their effect covers nothing.
- Line/branch coverage numbers are a smell detector, not a verdict: high coverage with
  weak assertions is a false green; a small, sharp behavioral test beats broad
  incidental execution.
- Prefer asserting on **observable behavior** (return values, emitted events, persisted
  state, error surfaces) over implementation details (internal call order, private
  state) — detail-coupled tests rot on refactor and block legitimate change.

## What to cover (by behavior class)

| Class | Cover when |
|-------|------------|
| Happy path | Always — the primary changed behavior |
| Boundaries | The change touches limits: empty/zero/one/max, off-by-one ranges, unicode/encoding edges |
| Error paths | The change adds or alters `throw`/`return err`/rejection/fallback — each new branch needs a test that forces it |
| State transitions | The change moves something through states (draft→ready, open→merged) — cover illegal transitions too |
| Idempotency / concurrency | The change can run twice or race (retries, hooks, queue consumers) |
| Regression | The change fixes a bug — the reproducing test is mandatory and must fail on the old code |

Not every class applies to every diff; the review question is "which classes does this
change touch, and is each touched class covered?"

## Red-green evidence

- The strongest evidence a test covers the change is a **captured red**: the test
  failing before the implementation (or on the old code), passing after.
- When the workflow records it (e.g. a red-green step), check the failure was for the
  **expected reason** — a test red due to a typo proves nothing.
- A test added in the same commit as the fix, passing on the new code, is weaker
  evidence: verify it would fail on the old code by reading it, or flag it.

## Untestable changes (the escape hatch)

Legitimate reasons a behavior change may ship without a covering test:

- Pure mechanical refactor whose output is verified byte-identical by a checker.
- Generated files whose generator is itself tested.
- Docs/comments/log-message-only changes.
- Glue observable only in a real external environment (CI config, deploy wiring) —
  name the environment where it *is* verified.

"Hard to test" is not on this list: if the code is hard to test, that is usually a
design finding (extract the logic, inject the dependency), report it as one. When the
author's stated reason fails these checks, the blocking rule applies.

## Review heuristics

- A test **modified in the same diff** as the behavior it covers: was the assertion
  weakened to make the change pass? Compare the old and new expected values.
- **Deleted or skipped** tests (`skip`, `only`, commented-out): each needs the same
  justification as an untestable change.
- New conditional branches with no test forcing each branch.
- Assertions that can never fail (`expect(x).toBeDefined()` on a constructed value,
  try/catch swallowing the assertion).
- A bugfix whose test would also have passed before the fix.
