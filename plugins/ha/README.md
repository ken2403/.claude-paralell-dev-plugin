# Higher Agents for Codex

`ha` is the Codex-only port of the repository's thorough Claude HA workflow. It builds **one feature** with front-loaded design rigor, controlled fresh subagents, persistent worktree isolation, evidence-gated review, and deterministic merge/cleanup safety. It has no Claude or `superpowers` runtime dependency.

## Install

```bash
codex plugin marketplace add /path/to/agent-parallel-dev-plugin
codex plugin add ha@claude-parallel-dev-plugin
```

Restart Codex or start a new thread after installing/updating.

## Workflow

```text
$ha-plan
  design dialogue -> repository exploration -> risk grade -> adversarial red-team
  -> human-approved docs/ha/plans/... plan
       |
$ha-implement
  persistent worktree -> sequential fresh writer per task -> spec + quality review
  -> risk-scaled assembled-change gate -> fresh checks -> PR
       |
$ha-review-pr
  independent read-only review panel -> main adjudication -> strict review record
  bound to PR number + exact head SHA
       |
$ha-apply-feedback (when requested) -> push -> review record becomes stale -> re-review
       |
$ha-merge-pr
  deterministic state/CI/conflict/review-SHA preflight -> merge
       |
$ha-clean-worktrees
  positive merge proof -> non-force cleanup
```

Standalone operations: `$ha-review-pr`, `$ha-apply-feedback`, `$ha-resolve-conflicts`, `$ha-merge-pr`, and `$ha-clean-worktrees`.

## Agent control

- The top-level skill agent owns human questions, scope, state, Git operations, external side effects, and final decisions.
- Exactly one writer may edit a worktree at a time. Writers cannot commit, push, ask the human, or delegate.
- Read-only reviewers receive raw task/plan/diff evidence, use distinct lenses, and cannot edit or spawn agents.
- A timeout, malformed response, or missing evidence never becomes approval.
- Side-effecting and orchestration skills require explicit `$ha-*` invocation. Only the code-review and adversarial-verification standards may activate implicitly.

## Review and merge invariant

`$ha-review-pr` writes a strict `ha_codex_review.v1` record under the repository's Git common directory. The record includes the PR number and exact 40-character head SHA. `$ha-merge-pr` fails closed if the PR changed after approval, is draft/behind/conflicting, has changes requested, has non-green checks, or lacks an unblocked approval with passing evidence.

## Skills

| Skill | Purpose |
|---|---|
| `$ha-plan` | Ground, design, red-team, test-plan, and approve one feature. |
| `$ha-implement` | Implement an approved plan task by task and open a PR. |
| `$ha-review-pr` | Independent adversarial PR review and SHA-bound verdict. |
| `$ha-apply-feedback` | Verify feedback, fix it test-first, and update the PR. |
| `$ha-resolve-conflicts` | Preserve both sides' intent in an isolated worktree. |
| `$ha-merge-pr` | Deterministically preflight and merge an approved PR. |
| `$ha-clean-worktrees` | Remove only positively merged, clean worktrees. |
| `$ha-code-review` | Canonical quality, test, security, and consistency standards. |
| `$ha-adversarial-verification` | Evidence-gated claim refutation harness. |

Model and reasoning effort are selected at Codex launch/profile time; Codex Skill frontmatter does not pin them. Use a strong model and high reasoning for plan, implementation, review, feedback, and conflict resolution.
