# Higher Agents for Codex

`ha` is the Codex-only port of the repository's thorough Claude HA workflow. It builds **one feature** with front-loaded design rigor, controlled fresh subagents, persistent worktree isolation, evidence-gated review, and deterministic merge/cleanup safety. It has no Claude or `superpowers` runtime dependency.

For the original Claude Code plugin, see [`ha/README.md`](../../ha/README.md).

## Install

```bash
codex plugin marketplace add /path/to/agent-parallel-dev-plugin
codex plugin add ha@claude-parallel-dev-plugin
```

Restart Codex or start a new thread after installing/updating.

The repository path uses `agent-parallel-dev-plugin`; the marketplace identifier intentionally
remains `claude-parallel-dev-plugin` for compatibility with existing installs.

## Requirements

- Codex CLI with Plugin and subagent support.
- `git`, Bash, Python 3, and an authenticated GitHub CLI (`gh`).
- Network access for fetching issues/PRs, pushing branches, opening PRs, reviewing live PR state,
  and merging. Local planning and most checks can run without network.
- A strong session model and high reasoning for planning, implementation, review, feedback, and
  conflict resolution. Codex Skill frontmatter does not pin a model or reasoning effort.

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

The workflow is a coordinated Plugin suite, not one uninterrupted command. Planning requires a
human design/plan approval, implementation stops at a PR, merge requires explicit authorization,
and cleanup is a separate post-merge operation.

## Review and merge invariant

`$ha-review-pr` writes a strict `ha_codex_review.v1` record under the repository's Git common directory. The record includes the PR number and exact 40-character head SHA. `$ha-merge-pr` fails closed if the PR changed after approval, is draft/behind/conflicting, has changes requested, has non-green checks, or lacks an unblocked approval with passing evidence.

The review reads the PR's configured base branch through `gh pr diff` and records `baseRefName`
during the review snapshot. The current `ha_codex_review.v1` contract binds approval to the PR and
**head SHA only**; it does not yet bind the base commit SHA. Until base-SHA binding is implemented,
rerun `$ha-review-pr <PR>` whenever the base branch advances after a review, even if the feature
head did not change. `mergeStateStatus` is an additional merge gate, not proof that the reviewed
base commit is unchanged.

## Security boundary

The Claude HA package includes a secret-file write guard. This Codex package does not currently
bundle an equivalent Plugin Hook, so do not treat the Plugin as an enforcement boundary for
`.env`, credential, key, or certificate files. Repository policy, sandboxing, review, and explicit
authorization still apply. A Codex-specific `PreToolUse` guard must parse Codex's `apply_patch`
input before this parity claim can be made.

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

## Validation and test scope

```bash
uv run --with pyyaml bash common/tests/validate-repo.sh
bash plugins/ha/tests/run.sh
```

The repository validates the Codex manifest, all nine Skill packages, shell/Python syntax,
duplicated helper identity, review-contract coherence, worktree attach/create behavior,
merge preflight, and fail-closed cleanup. The current HA tests are component/integration tests;
they do **not** yet drive a fresh installed Codex session through the complete
plan → implement → PR → review → feedback → merge → cleanup lifecycle. Do not describe HA as
full-lifecycle E2E proven until that harness exists and passes.
