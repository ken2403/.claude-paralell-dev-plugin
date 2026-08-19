# ca — Cooperate Agents (Claude × Codex loop)

`ca` ships **two co-located plugins** that make Claude and Codex cooperate on one feature, end to end:

```
Claude  /ca:plan-loop  ──spar with Codex (codex exec)──▶  saved plan
                                                              │
Claude  /ca:implement <plan>  ──creates ca/<id> worktree, prints kickoff──┐
                                                              ▼
Codex   $ca-implement-plan PLAN=<abs>   (inside the worktree)
   ├─ implement milestone 1 (TDD) ─ push + open a DRAFT PR
   ├─ per milestone: Claude /ca:review-pr mode=checkpoint ─▶ fix blocking before building on
   ├─ final review — dual-model by default (CA_DUAL_REVIEW=0 for Claude-only):
   │     ├─ Claude /ca:review-pr blind final review
   │     ├─ Codex offline second-opinion review (advisory)
   │     └─ Claude /ca:synthesize-review adjudicates one ca_claude_review.v1 verdict
   ├─ address blocking findings, push, re-review the PR   (≤ 2 final rounds)
   └─ on validated approve + zero blockers: hard gate runs gh pr ready + posts summary
/ca:merge-pr (gated) or human merges ─▶ /ca:clean-worktrees reclaims it

Standalone (Claude): /ca:merge-pr [pr], /ca:resolve-conflicts [pr|branch], /ca:clean-worktrees
```

The implementing Codex session keeps continuous memory across rounds; state also lives in files
(`plan.md`, `review-checkpoint-M.json`, `review-round-N.json`) and in the PR itself, so the loop
is reproducible. Plans live in `docs/ca/plans/` (grouped into 2–4 milestones by `/ca:plan-loop`;
small plans are a single milestone and skip checkpoints). Codex implements sandboxed
(`-s workspace-write`); the push, draft-PR, `/ca:review-pr`, and `/ca:synthesize-review` steps
need network + an authenticated `gh`.

> **Network + `gh` note for the review step.** Claude review and synthesis call `claude -p`
> (needs the Anthropic API) and fetch the PR via `gh pr diff` (needs an authenticated `gh`).
> Codex's default
> `-s workspace-write` sandbox **blocks network**, so the review must run where network is allowed
> and `gh` is authenticated: launch Codex for ca with network permitted for that command
> (approval/profile), or run `claude-review.sh` in a host terminal between rounds. `claude-review.sh`
> fails loudly with guidance if no verdict is produced, so an unreachable reviewer is never mistaken
> for a real verdict.

## Layout

```
ca/
  claude/                 # Claude Code plugin (/ca:plan-loop, /ca:implement, /ca:dual-review,
    .claude-plugin/plugin.json          #        /ca:merge-pr, /ca:resolve-conflicts, ...)
                          #   review-pr + synthesize-review are the review's internal legs:
                          #   the loop and /ca:dual-review invoke them through `claude -p`.
    skills/{plan-loop,implement,review-pr,synthesize-review,dual-review,code-review,merge-pr,resolve-conflicts,clean-worktrees}/
  codex/                  # Codex plugin ($ca-implement-plan)
    .codex-plugin/plugin.json
    skills/ca-implement-plan/               # SKILL.md + agents/openai.yaml + scripts/ + references/
  install.sh              # install the Codex skill into ~/.codex/skills; print the Claude install
  sync-codex-plugin.sh    # refresh/check the marketplace package mirror
plugins/ca/               # generated, self-contained Codex marketplace package
```

Each skill is a self-contained folder (scripts bundled inside it) so it stays portable when copied
or distributed independently.

## Install

**Claude Code plugin** (plan + review side):

```bash
/plugin install ca@claude-parallel-dev-plugin     # from the marketplace
# or, for local development:
claude --plugin-dir /path/to/repo/ca/claude
```

**Codex plugin** (implement side):

```bash
# Plugin-aware Codex install (repo marketplace):
codex plugin marketplace add /path/to/claude-parallel-dev-plugin
codex plugin add ca@claude-parallel-dev-plugin

# Compatibility fallback — direct skill copy:
bash ca/install.sh
bash ca/install.sh --force
```

`ca/codex/` is the canonical Codex source. `plugins/ca/` is its byte-identical distribution
mirror for the marketplace's required `./plugins/ca` path; `bash ca/sync-codex-plugin.sh --check`
detects drift. The direct `install.sh` copy remains available for older/non-plugin-aware setups.

## Use

1. `bash ca/install.sh && bash ca/install.sh --claude` — install both, restart Codex.
2. In Claude: `/ca:plan-loop "<your epic>"` → spars with Codex, saves a plan.
3. In Claude: `/ca:implement <plan>` → creates the worktree, prints the Codex command.
4. In a Codex session in that worktree (use a strong model + high reasoning):
   `$ca-implement-plan PLAN=<abs-plan-path>` → implements milestone by milestone, opens a
   **draft** PR at the first milestone, gets a Claude checkpoint review between milestones,
   then the final **dual review** (≤2 rounds), and on a validated approve marks the PR **ready**.
5. Merge the PR — `/ca:merge-pr [pr]` (gated: refuses drafts/red CI/conflicts) or on GitHub —
   then `/ca:clean-worktrees` reclaims the worktree and branch.

**Reviewing a PR by hand: `/ca:dual-review [pr] [plan-path]`** — the single entry point. It is the
loop's Claude×Codex final review as a command, usable on any PR at any time (including re-reviews
after the loop). Add `--claude-only` for a single-model review; the Codex leg is optional anyway
and degrades visibly to Claude-only. Artifacts land in `.ca/reviews/pr-<n>/`.

`/ca:review-pr` and `/ca:synthesize-review` exist as that command's internal legs — the blind
review and the adjudication the orchestrator drives through `claude -p`. They are not second
entry points; invoking them by hand skips the orchestration they are designed to run inside.

Standalone Claude skills: `/ca:merge-pr [pr]` (gated merge — refuses drafts, red CI, conflicts;
in ca a draft means the review loop has not approved), `/ca:resolve-conflicts [pr|branch]`
(resolve base-branch conflicts in an isolated worktree) and `/ca:clean-worktrees` (reclaim merged
ca worktrees) — the same operations ha ships, adapted to ca.

## Tests

Two tiers, one harness (`ca/tests/support/run-loop-e2e.sh`) — the model layer is the only
difference, so the hermetic tier proves the wiring and the live tier proves the models:

```bash
bash ca/tests/loop-e2e-test.sh              # hermetic, in CI, ~8s, no network, no cost
bash ca/tests/live-loop-e2e-smoke.sh --run  # real Codex implements, real Claude reviews
```

Both drive the full loop and assert it reaches **PR open as a draft**, that a checkpoint verdict
can never promote, that promotion happens only on a validated final `approve`, and that the
worktree is reclaimable afterwards. GitHub is simulated (`ca/tests/support/gh-sim.py`) on top of
a real bare remote, so pushes, diffs and draft state are real without touching anyone's account —
the live tier additionally runs the synthesis leg directly, because the orchestrator skips it
whenever Codex returns a clean pass.

> **What the Codex leg is.** Inside the loop Codex is the implementer, so its review leg is a
> fresh-context **self-review** — read-only, no memory of the build, and unable to make
> anything blocking unless Claude confirms it in synthesis. A clean Codex pass there is the
> author approving their own work, not corroboration; the independent judgement is the blind
> Claude leg. Standalone `/ca:dual-review` on a PR Codex did not write is where the second
> opinion is truly second.

## The handoff contract

Claude review returns a strict `ca_claude_review.v1` JSON object that names the PR (`pr`) and
the exact commit it judged (`head_sha`). Promotion requires a final-mode `verdict: "approve"`,
zero blocking findings, and a binding that still matches the PR's live head; `promote-pr.sh`
resolves that head itself and enforces all of it before calling `gh pr ready`. So an approval
cannot be replayed onto another PR, and a commit pushed after the review invalidates it. A
`blocked` verdict never passes even with no findings, an `approve` cannot coexist with a failed
verification record, and missing/malformed/incoherent output fails closed. Checkpoint reviews
(`mode=checkpoint`) use the same contract but only gate continuing to the next milestone — they
never promote the PR. The contract lives in each skill's `references/review-contract.md`,
validated by `validate-review.py`.

## Dual-model final review (the default)

**Final** review rounds are dual-model by default; `CA_DUAL_REVIEW=0` is the Claude-only opt-out.
Checkpoints remain Claude-only progress gates — they cannot promote the PR, and in the loop the
Codex leg is the implementer reviewing its own work rather than an independent second opinion.
In a dual final round:

1. `dual-review.sh` starts both independent legs concurrently and keeps the current Codex artifact
   outside the worktree until blind Claude finishes.
2. `codex-review.sh` fetches PR metadata/diff on the host, builds a bounded prompt, and runs
   `codex exec --sandbox read-only --output-schema` with no network or `gh` access inside Codex.
3. `claude-review.sh` runs the normal blind Claude final review and is instructed not to read prior
   `.ca` review artifacts.
4. If Codex reports findings, warnings, or partial coverage, `synthesize-review.sh` invokes
   `/ca:synthesize-review`; Claude treats Codex output as untrusted claims and emits the one
   gating `ca_claude_review.v1` verdict.
5. If Codex exits clean with zero findings and full coverage, synthesis is skipped and the blind
   Claude JSON is final. If Codex is unavailable or invalid, the round degrades visibly to
   Claude-only and records the reason in `.ca/runs/<id>/review-round-N.meta.json`.

This adds model diversity, not author independence: Codex wrote the code, and a fresh Codex
review may share model-family blind spots with the implementer. Claude remains the sole verdict
holder. Flip-to-default criterion: after at least 5 real dual PRs, the confirmed-finding rate is
nonzero and the invalid/unavailable rate is below 20%.

## Both plugins are required

The loop only works with **both** sides installed: the Codex skill implements, and it calls the
Claude plugin's `/ca:review-pr` (via `claude -p`) to review. Installing only one side makes every
review round fail. `bash ca/install.sh` with no flags handles the Codex install and prints/checks
the Claude side. If you cannot install the Claude plugin globally, set `CA_CLAUDE_PLUGIN_DIR` so the
review call can load it with `--plugin-dir`.

## Environment overrides

- `CODEX_BIN` — path to `codex` if it is not on `PATH` (e.g. a version-manager shim).
- `CLAUDE_BIN` — path to `claude` for the review call.
- `CA_CLAUDE_PLUGIN_DIR` — path to the `ca/claude` plugin dir; lets `claude-review.sh` load
  `/ca:review-pr` via `--plugin-dir` when the Claude plugin isn't installed globally.
- `CA_DUAL_REVIEW=0` — opt OUT of the dual final review, leaving Claude-only rounds.
- `CA_CLAUDE_PERMISSION_MODE` — `--permission-mode` for the `claude -p` review sessions. The
  stock `default` mode cannot prompt non-interactively, so it hangs until the timeout.
- `CA_LIVE_SMOKE_BUDGET_USD` — spend ceiling for the opt-in live tests, default 25. It is a
  runaway guard, not a per-call estimate: `claude` refuses up front once session spend already
  exceeds it, so a too-small value fails every leg before any work happens.
- `CA_CODEX_REVIEW_TIMEOUT` — timeout for the Codex second-opinion leg, default 900 seconds.
- `CA_CLAUDE_REVIEW_TIMEOUT` — timeout for each Claude review leg, default 900 seconds.
- `CA_CLAUDE_SYNTHESIS_TIMEOUT` — optional separate synthesis timeout; defaults to the Claude
  review timeout.
- `CA_CODEX_SPAR_TIMEOUT` — timeout for the plan-sparring Codex leg, default 900 seconds.
- `CA_CODEX_REVIEW_FULL_DIFF_BYTES` — full-diff prompt threshold, default 180000 bytes.
- `CA_CODEX_REVIEW_FALLBACK_PROMPT_BYTES` — structured fallback budget, default 360000 bytes.
- `CODEX_HOME` — where the Codex skill installs (default `~/.codex`).
- `CA_BASE` — optional base-branch override; otherwise origin HEAD then a local
  `main|master|develop|dev` branch is detected.
