# sa — Simple Agents

A command-free Claude Code plugin for getting **one simple feature** done fast: hand it a
plan, approve it, and it isolates a worktree, implements with subagents, and opens a PR.
Build and review both run on the latest **Sonnet**; accuracy comes from **stacked
independent cross-checks** — mandatory red-green tests, a risk-scaled pre-PR check, and
three mutually blind verifier lenses at review — with a targeted **Opus** escalation only
where a check signals doubt. The fast, lightweight counterpart to
[`ha`](../ha/README.md), which builds one feature thoroughly.

## Install

```
/plugin install sa@agent-parallel-dev-plugin
```

Or try it locally without installing:

```
claude --plugin-dir /path/to/agent-parallel-dev-plugin/sa
```

Requirements: `git`, the GitHub CLI (`gh`, authenticated), and access to the latest
Sonnet, Opus, and Haiku models.

Note on model pins: sa pins model aliases, and a skill's `model` overrides the session
model **in both directions** — review runs on Sonnet even in an Opus session (the Opus
look comes from the `deep-verifier` escalation, not the session). If you want reviews on
your session's model, use `ha`, which is model-agnostic by design.

## Why sa

Not every feature needs `ha`'s deep plan gate, layered review loops, and multi-pass
adversarial verification. `sa` is the fast path for a **single, well-scoped change** where
you want to stay in the loop: it asks before it builds, gets your approval, then runs to a
PR without hand-holding. Speed and cost come from an all-Sonnet path with graded effort
and parallel subagents; quality comes from **error-rate multiplication** — several cheap,
independent checks (red-green evidence, a pre-PR verifier pass, blind review lenses) miss
less together than one expensive correlated pass, and an Opus `deep-verifier` handles only
the claims they cannot settle.

## The flow

```
(1) /sa:simple-implement <plan | task>
      digest plan -> explore (read-only) -> ask if unsure -> APPROVE GATE
        -> create worktree (.claude/worktrees/sa/<slug>)
          -> implement red-green (you + parallel `implementer` subagents)
            -> run tests -> pre-PR cross-check (risk-scaled `verifier`s) -> open PR -> STOP

(2) on demand:
      /sa:review-pr <pr>             independent review (sonnet/high + 3 blind `verifier`
                                     lenses; escalates hard cases to opus `deep-verifier`)
        -> /sa:apply-feedback <pr>      fix + push
      /sa:resolve-conflicts <pr>     merge base + resolve conflicts (isolated) + push
      /sa:merge-pr [pr]              gated merge (no changes requested + green + mergeable)
        -> /sa:clean-worktrees          reclaim merged worktrees + branches
```

`simple-implement` deliberately **stops at PR creation** for speed; reviewing is a separate,
explicit step.

`/sa:review-pr` reads the PR's configured base through `gh pr diff`; it does not substitute the
repository default branch. Rerun it if that base branch advances before merge.

## Components

**Skills** (`/sa:<name>`)
- `simple-implement` — plan -> approve -> worktree -> red-green implement -> risk-scaled
  pre-PR cross-check -> PR (sonnet, effort medium).
- `review-pr` — independent correctness/security/consistency review via three blind
  `verifier` lenses, with deterministic escalation to `deep-verifier` (sonnet, effort high).
- `apply-feedback` — turn review feedback into committed fixes (sonnet, effort medium).
- `resolve-conflicts` — merge the base branch and resolve conflicts in an isolated
  worktree, verify, and push (opus, effort high).
- `merge-pr` — gated merge: refuses drafts, changes-requested reviews, red CI, and conflicts
  (haiku, effort low; the preflight is mechanical `gh pr view` field checks, and
  `gh pr merge` + branch protection refuse ineligible merges server-side).
- `clean-worktrees` — reclaim merged sa worktrees + branches, safely (haiku, effort low).
- `code-review` — the single source of engineering standards (quality, security,
  consistency); **auto-activates** during both implementation and review.

**Subagents** (`sa/agents/`)
- `implementer` — builds one file-disjoint slice in the worktree, red-green (sonnet, effort medium).
- `verifier` — adversarial read-only reviewer that tries to refute a claim; the cheap
  fan-out cross-checker (sonnet, effort high).
- `deep-verifier` — escalation-only refuter for claims the verifiers could not settle:
  risky surfaces, UNCERTAIN-on-blocking, conflicting verdicts (opus, effort high).

**Hook** — `sa/hooks/` ships a PreToolUse guard that refuses edits/writes to secret files
(`.env`, keys, credentials), allowing `*.example`/`*.sample` variants.

**Guardrails for "fast but accurate"** — instead of buying accuracy with an expensive
model everywhere, sa stacks independent cheap checks so their misses multiply down:
mandatory red-green (a test that failed first is mechanical evidence), an objective
build/test gate, a risk-scaled pre-PR `verifier` pass, and at review three mutually blind
Sonnet lenses (correctness counter-example, security input→sink, consistency beyond the
diff) adjudicated with evidence. Only the claims those checks cannot settle — risky
surfaces, UNCERTAIN on a blocking claim, conflicting verdicts — escalate to a single
scoped Opus `deep-verifier`, whose verdict is final. The `code-review` standards (security
non-negotiable; a behavior change without a covering test is blocking) apply throughout.

## Relationship to ha

| | `sa` (Simple Agents) | `ha` (Higher Agents) |
|---|---|---|
| Scope | one simple feature, fast | one feature, thorough |
| Plan | digests a given plan | design dialogue + question gate + vetted plan |
| Implement | red-green subagents → light risk-scaled pre-PR cross-check → PR | SDD per-task loop + risk-scaled pre-PR adversarial gate → PR |
| Verification | code-review standards + blind-lens review-pr (on demand) | + multi-pass adversarial verification |
| Speed dial | all-Sonnet cross-checks, targeted Opus escalation, graded effort | thoroughness-first (effort high) |

Both are foreground, single-feature, and need no tmux (`ha` also requires the `superpowers` plugin).
