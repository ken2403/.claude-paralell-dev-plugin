---
name: ca-implement-plan
description: Build a saved task-by-task implementation plan in an isolated worktree, milestone by milestone, with Claude checkpoint reviews between milestones and Claude-reviewed final rounds gating the PR before it is marked ready — the Codex half of the ca (Cooperate Agents) loop. Use when the user points at a plan file under docs/ca/plans or any task-by-task plan and says things like "implement this plan", "build the plan at this path", "run the ca loop on this plan", or "have Claude review what you built". Human confirmation is required at key decision points and before cleanup.
license: MIT
metadata:
  short-description: Build a plan with Claude review rounds
---

# ca-implement-plan

Build a saved implementation plan in an isolated worktree, milestone by milestone: an external
Claude reviewer checkpoints each milestone (so defects surface before more code is built on top
of them) and gates the final PR promotion, with the human present. Pause for the human at every
point marked **ASK**.

## Inputs

- `PLAN` — absolute path to the plan markdown file. Ask the human if it was not provided.
- `MAX_ROUNDS` — optional cap on **final** Claude review rounds before forcing a stop. Default 2.
  Milestone checkpoint reviews do not count against it.

Resolve the skill's own bundled scripts from its install dir:

```bash
SKILL_DIR="${CODEX_HOME:-$HOME/.codex}/skills/ca-implement-plan"
```

## Step 0 — Confirm isolation (never skip)

Run only inside a dedicated worktree on a `ca/` branch, never on the default branch or the shared checkout.

```bash
ROOT="$(git rev-parse --show-toplevel)"
BR="$(git -C "$ROOT" rev-parse --abbrev-ref HEAD)"
echo "root=$ROOT branch=$BR"
case "$BR" in ca/*) ;; *) echo "NOT ISOLATED: branch '$BR' is not a ca/ branch — STOP" >&2; exit 1;; esac
case "$ROOT" in */.claude/worktrees/ca/*) ;; *) echo "NOT ISOLATED: '$ROOT' is not a ca worktree — STOP" >&2; exit 1;; esac
```

If either check fails (branch not `ca/*`, or the tree is not under `.claude/worktrees/ca/`),
**STOP** and tell the human to launch from an isolated worktree first:

```bash
bash "$SKILL_DIR/scripts/new-worktree.sh" "$PLAN"
# then run codex inside the printed worktree path and invoke $ca-implement-plan again
```

Proceed only once on a `ca/<plan-id>` branch in its own worktree.

## Step 1 — Read and anchor the plan

1. Read `PLAN` in full. `PLAN` must be the **original** plan file (e.g. `docs/ca/plans/<id>.md`), not a staged copy named `plan.md` — the id is derived from its basename, and a copy named `plan.md` would collapse the id to `plan`. Verify the handoff checksum before refreshing the staged copy; a changed plan requires human confirmation:

   ```bash
   ID="$(basename "$PLAN" .md)"; RUN="$ROOT/.ca/runs/$ID"; mkdir -p "$RUN"
   [ "$ID" = plan ] && echo "WARN: id is 'plan' — pass the original plan path, not a staged copy" >&2
   PLAN_HASH="$(shasum -a 256 "$PLAN" | awk '{print $1}')"
   if [ -f "$RUN/plan.sha256" ] && [ "$(cat "$RUN/plan.sha256")" != "$PLAN_HASH" ]; then
     echo "PLAN CHANGED since worktree creation — STOP and ask the human to approve the new plan" >&2
     exit 1
   fi
   cp "$PLAN" "$RUN/plan.md"; printf '%s\n' "$PLAN_HASH" > "$RUN/plan.sha256"
   BASE="${CA_BASE:-$(cat "$RUN/base.txt" 2>/dev/null || printf main)}"
   ```
2. Restate the goal and the ordered task list in two or three sentences. Note each task's test command.
3. Resolve the **milestone grouping**: use the plan's `## Milestones` section if present;
   otherwise group the tasks yourself at 2–4 natural boundaries (layer/dependency seams, each
   leaving the tree green). A plan of roughly 4 tasks or fewer is a **single milestone** — the
   loop then skips checkpoints entirely and behaves as implement-everything-then-final-review.
4. If the plan contradicts the actual code (a referenced file is gone, an interface drifted), **ASK** the human before building.

## Step 2 — Implement milestone by milestone (test-first, checkpoint-reviewed)

Within each milestone, implement its tasks in plan order:

1. Write the failing test the task specifies. If the task specifies no test, write one yourself
   before implementing — unless the task has no testable behavior, in which case note that in the
   commit body; never silently skip test-first. Run it. Confirm it fails for the stated reason.
2. Write the minimal implementation. Run the test. Confirm it passes.
3. Run the task's lint/build/typecheck if specified. Capture real output — never claim success without evidence.
4. Commit with a conventional message and the repo's co-author footer.

Hard rules while implementing:

- Stay inside this worktree. Never edit `.env`, credentials, keys, or other secret files.
- Keep the diff scoped to the plan. Do not refactor unrelated code.

**At the end of each milestone except the last** (a single-milestone plan goes straight to
Step 3), run a checkpoint review so defects are caught before more code is built on top of them:

1. Push, and on the **first** milestone open the **draft** PR (the reviewer reviews the PR; the
   draft state is the fail-closed gate — it is promoted to ready only after the final review
   approves):

   ```bash
   git -C "$ROOT" push -u origin "$BR"
   gh pr view "$BR" >/dev/null 2>&1 || \
     gh pr create --draft --base "$BASE" --head "$BR" --title "feat: $ID" --body-file "$RUN/plan.md"
   PR="$(gh pr view "$BR" --json number --jq .number)"
   echo "draft PR: #$PR"
   ```
2. Call the checkpoint review (`M` = the milestone number just completed). The same **TWO
   PRECONDITIONS** as the final review apply (Step 3) — a resolvable `/ca:review-pr` plus
   network + authenticated `gh`. If the script fails because the reviewer was unreachable,
   **ASK** the human whether to run it where network works or to skip the remaining checkpoints
   and rely on the final review — do not treat an unreachable reviewer as a real `blocked` verdict.

   ```bash
   bash "$SKILL_DIR/scripts/claude-review.sh" \
     --plan "$RUN/plan.md" --pr "$PR" --worktree "$ROOT" \
     --mode checkpoint --round "$M" --out "$RUN/review-checkpoint-$M.json"
   ```

   Checkpoint mode judges only the milestones built so far (round `M` = milestones 1..M);
   unbuilt later tasks are not defects.
3. Read the validated verdict JSON. Continue only when `verdict == "approve"` **and** there are
   zero `blocking: true` findings. For `request_changes`, address every blocking finding **now** —
   fix, re-run the affected tests, commit, push — before starting the next milestone. There is no
   checkpoint re-review (the final review verifies the fixes). For `blocked`, stop and **ASK** the
   human; an empty findings array does not turn `blocked` into approval. Record non-blocking
   findings for the PR summary. The script rejects malformed or incoherent files.

## Step 3 — Self-review, ensure the draft PR, then the final Claude review

1. Self-review the diff against the plan: every task covered, tests present and green, no placeholder left.
2. Push, and make sure the **draft** PR exists (checkpointed runs opened it at milestone 1; a
   single-milestone run opens it here — the draft state is the fail-closed gate, promoted to
   ready only after Claude approves):

   ```bash
   RUND=1
   git -C "$ROOT" push -u origin "$BR"
   gh pr view "$BR" >/dev/null 2>&1 || \
     gh pr create --draft --base "$BASE" --head "$BR" --title "feat: $ID" --body-file "$RUN/plan.md"
   PR="$(gh pr view "$BR" --json number --jq .number)"
   echo "draft PR: #$PR"
   ```
3. Call the reviewer on the PR in **final** mode (only final rounds count against
   `MAX_ROUNDS`). **The final review is dual-model by default**: Codex reviews the PR from an
   offline host-built prompt, Claude performs its blind final review separately and concurrently,
   and a separate Claude synthesis call adjudicates Codex's advisory findings into the single
   gating `ca_claude_review.v1` verdict. This is the promotion gate, so it gets the heavier check.
   `CA_DUAL_REVIEW=0` falls back to Claude-only (useful when `codex` is unavailable, though the
   orchestrator already degrades on its own and says so in the meta sidecar).

   **Note what the Codex leg is and is not.** In this loop Codex is the *implementer*, so its
   review leg is a fresh-context **self-review**, not an independent second opinion. It runs
   read-only with no memory of the build, and nothing it says can become blocking unless Claude
   confirms it in synthesis — but a clean Codex pass is the author approving their own work, and
   must not be read as corroboration. The genuinely independent judgement is the blind Claude leg.

   **THREE PRECONDITIONS — important.** All must hold or no review is produced:
   - **Skill resolvable:** `claude -p /ca:review-pr` only works if the ca *Claude* plugin is
     installed in the user's Claude config, or `CA_CLAUDE_PLUGIN_DIR` points at the `ca/claude` dir
     (the script then passes `--plugin-dir`). If neither, the skill won't load.
   - **Tool permissions:** the `claude -p` session must be allowed to run its tools. The stock
     `default` permission mode cannot prompt non-interactively, so it blocks and dies at the
     timeout with no output; set `CA_CLAUDE_PERMISSION_MODE` or configure
     `permissions.defaultMode` in the Claude settings.
   - **Network + `gh`:** `claude -p` reaches the Anthropic API, and the review fetches the PR via
     `gh pr diff`, so both network and an authenticated `gh` are required. Codex's default
     `-s workspace-write` sandbox blocks network, so the call fails inside a normal sandboxed
     session. Provide network by launching Codex with it permitted for this command, or run the
     command in a host terminal where `gh` is authenticated.

   Tell the human which arrangement you are relying on before running it.

   ```bash
   FINAL="$RUN/review-round-$RUND.json"
   META="$RUN/review-round-$RUND.meta.json"   # written by the orchestrator, never by hand

   CLAUDE_ONLY=""
   [ "${CA_DUAL_REVIEW:-1}" = "0" ] && CLAUDE_ONLY="--claude-only"
   bash "$SKILL_DIR/scripts/dual-review.sh" \
     --plan "$RUN/plan.md" --pr "$PR" --worktree "$ROOT" \
     --round "$RUND" --out-dir "$RUN" $CLAUDE_ONLY
   ```

   The dual orchestrator runs the Claude and Codex legs concurrently. It keeps the current-round
   Codex artifact outside the worktree until the blind Claude leg finishes, validates both outputs,
   and records any visible Claude-only degradation in the meta sidecar.

   The script fails loudly (non-zero) with an actionable reason if no valid review is produced — if
   it reports the API was unreachable, **STOP and ASK** the human to run the review step where
   network is allowed; do not treat an unreachable reviewer as a real "blocked" verdict.
4. Read `review-round-$RUND.json` and `review-round-$RUND.meta.json`. The review JSON shape is
   documented in `references/review-contract.md`
   (`verdict`, plus `findings` where each has `blocking: true` or `false`). On a malformed file,
   treat it as blocked and **ASK** the human.

## Step 4 — Address feedback and loop

- Go to Step 5 only when `verdict` is exactly `approve` **and** no finding has
  `blocking: true`. `blocked` with an empty findings list is still blocked.
- Otherwise address every blocking finding. For a finding you judge incorrect, do not silently skip
  it — record your disagreement to surface in the PR summary, and **ASK** the human if it is material.
- Re-run the affected tests, commit, and **push** (this updates the draft PR's diff), increment the
  round, and call Claude again on the same PR (Step 3.3 — reuse `$PR`, never open a second PR).
- Stop when approved, when the round count reaches `MAX_ROUNDS` (default 2 — the initial review plus
  at most one fix-and-re-review round), or when two consecutive rounds produce an identical diff. On a forced stop,
  **leave the PR as a draft** and **ASK** the human whether to keep going or take it from here.

This is one continuous session, so prior rounds are already in context — still re-read the latest
review JSON and the current PR diff so decisions rest on the current files, not memory alone.

## Step 5 — Promote the PR to ready, with an exchange summary

The PR already exists (opened as a draft at the first milestone, or in Step 3). Once the final
review is a strict `approve` with zero blocking findings, use the bundled hard gate to promote it.
Never call `gh pr ready` directly from this workflow:

```bash
bash "$SKILL_DIR/scripts/promote-pr.sh" \
  --review "$RUN/review-round-$RUND.json" --pr "$PR" --round "$RUND"
```

If the loop hit a forced stop with unresolved blocking findings, leave it as a draft instead and say so.

Then post the Claude/Codex exchange — every checkpoint and final round (verdicts, what each one
fixed, any disputed findings) — as a PR comment, and report the PR link to the human:

```bash
bash "$SKILL_DIR/scripts/post-summary.sh" "$RUN" "$PR"
```

**ASK** the human to review and merge.

## Step 6 — Cleanup after merge (only on confirmation)

Delete nothing until the human confirms the PR merged. The preferred path is the Claude-side
`/ca:clean-worktrees` (it owns the cleanup guardrails and verifies the merge itself). If the human
asks you to clean up from here instead, derive the main checkout first — `git worktree remove`
must run from OUTSIDE the worktree being removed:

```bash
MAIN="$(git worktree list --porcelain | head -1 | sed 's/^worktree //')"   # first entry = main checkout
[ -n "$MAIN" ] && [ "$MAIN" != "$ROOT" ] || { echo "cannot resolve main checkout — use /ca:clean-worktrees" >&2; exit 1; }
cd "$MAIN"
git worktree remove "$ROOT"   # no --force; refuses uncommitted changes
git branch -d "$BR"           # -d refuses unmerged; never -D
git worktree prune
```

If the PR was closed unmerged, clean nothing and tell the human.

## References

- `references/review-contract.md` — the JSON Claude returns and how `blocking` gates the loop.
