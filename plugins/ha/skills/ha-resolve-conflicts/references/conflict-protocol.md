# Conflict-resolution protocol

## Recover intent

For every hunk inspect the common ancestor, ours, theirs, surrounding code, tests, plan/PR discussion, and related changes. Record what each side intended before choosing a result.

## Strategy

- Keep ours only when theirs is provably obsolete or unrelated.
- Keep theirs only when ours is provably superseded.
- Combine when both add valid behavior; reconcile types, imports, call sites, tests, configs, and ordering as a unit.
- Ask or abort when intent cannot be established safely.

## Integration proof

No markers/unmerged paths is necessary but not sufficient. Verify both behaviors survive, interfaces agree across files, generated/config/schema artifacts match, targeted tests cover each side, and the full relevant check is green. A fresh read-only verifier examines the assembled resolution before commit.
