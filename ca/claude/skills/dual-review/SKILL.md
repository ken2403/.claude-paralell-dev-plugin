---
name: dual-review
description: Review a pull request in ca. Runs the dual-model review — a blind Claude review and an offline Codex second opinion in parallel, then a Claude synthesis pass that adjudicates them into one ca_claude_review.v1 verdict. This is the entry point for reviewing any PR by hand, inside or outside the implement loop. Use when the user says review this PR, dual review this PR, review with both Claude and Codex, re-review after the ca loop, or invokes /ca:dual-review. Pass --claude-only for a single-model review.
license: MIT
argument-hint: '[pr-number] [plan-path] [--comment] [--claude-only]'
effort: medium
disable-model-invocation: true
allowed-tools: Read, Grep, Glob, Bash
---

# dual-review

**The way to review a PR in ca.** Run the loop's dual-model final review as a standalone command: an offline
Codex second opinion and a blind Claude review run in parallel, then a separate
Claude synthesis call adjudicates the Codex findings into one
`ca_claude_review.v1` verdict. Works on any PR — mid-loop, after the loop, or on
PRs the loop never touched. You are the ORCHESTRATOR: the judgment happens in the
subprocesses; you set up inputs, run the script, and report the result.

## Preconditions (check first, fail loudly)

- `claude` on PATH (or `CLAUDE_BIN`) and the ca plugin resolvable by `claude -p`
  (installed, or export `CA_CLAUDE_PLUGIN_DIR=<repo>/ca/claude`).
- Network + authenticated `gh` (`gh auth status`).
- `codex` (or `CODEX_BIN`) is OPTIONAL: absent/failing degrades visibly to a
  Claude-only review with the reason in the meta sidecar — never a hard failure.
- For a real Codex leg, the ca Codex plugin must expose the explicit-only
  `$ca-second-opinion` skill. The bundled launcher explicitly invokes it, disables multi-agent,
  and isolates the child from repository-local skill discovery.

## Step 1 — Resolve inputs

```bash
PR="<first argument, or auto-detect>"
[ -n "$PR" ] || PR="$(gh pr view --json number --jq .number 2>/dev/null)"
[ -n "$PR" ] || { echo "no PR number given and none found for the current branch" >&2; exit 1; }
ROOT="$(git rev-parse --show-toplevel)"
```

**Plan/intent file** — the reviewers judge the PR against it:

- If the user gave a plan path (e.g. `docs/ca/plans/<id>.md`), use it. For a
  re-review after a loop, the loop's staged copy also works:
  `.ca/runs/<plan-id>/plan.md`.
- If no plan is given, derive an intent file from the PR itself — the review
  then judges the PR against its stated intent:

  ```bash
  INTENT="$ROOT/.ca/reviews/pr-$PR/intent.md"
  mkdir -p "$(dirname "$INTENT")"
  gh pr view "$PR" --json title,body --jq '"# PR intent: \(.title)\n\n\(.body)"' > "$INTENT"
  ```

**Output dir and round** — keep every artifact (gitignored under `.ca/`):

```bash
OUTDIR="$ROOT/.ca/reviews/pr-$PR"
ROUND=1; while [ -f "$OUTDIR/review-round-$ROUND.json" ]; do ROUND=$((ROUND+1)); done
```

## Step 2 — Run the orchestrator

```bash
CLAUDE_SKILL_CA_DIR="${CLAUDE_SKILL_DIR}"
bash "$CLAUDE_SKILL_CA_DIR/scripts/dual-review.sh" \
  --pr "$PR" --plan "$INTENT_OR_PLAN" --worktree "$ROOT" \
  --round "$ROUND" --out-dir "$OUTDIR"
```

Pass `--claude-only` when the user asks for a single-model review (or `codex` is deliberately out
of the picture). It runs the same blind Claude leg and emits the same verdict contract; no Codex
process is started and the meta sidecar records `dual_review:false`. Do NOT reach for
`/ca:review-pr` for this — that skill is this command's internal blind leg, not a second entry
point.

It runs both legs in parallel and keeps the current-round Codex output outside the
worktree until the blind review finishes, synthesizes when Codex found anything, skips
synthesis on a clean full-coverage Codex pass, and
degrades to Claude-only with a machine-readable reason when the Codex leg fails. A timeout is
reported distinctly as `codex_timeout`, with partial Codex stderr retained in the leg log.
If it exits non-zero, report the failure verbatim — do not improvise a verdict.

## Step 3 — Report

Read `review-round-N.json` and the meta sidecar; report to the human:

- **Verdict** (approve / request_changes / blocked) and the summary paragraph.
- Findings as a table: id, blocking, severity, title, file:line.
- When synthesis ran: the `second_opinion.ledger` adjudications
  (confirmed/refuted/not_applicable/unresolved) and any
  `resolved_blind_findings` (blind blockers that synthesis downgraded, with
  evidence).
- The leg statuses from the meta sidecar (e.g. Codex `used` coverage `full`,
  `unavailable: codex_timeout`, or `unavailable: codex_unavailable_or_oversized` — say plainly when the
  second opinion did NOT happen).

If `--comment` was passed, also post the summary to the PR:

```bash
gh pr review "$PR" --comment --body "<summary>"
```

## Notes

- This is the same orchestrator the implement loop runs for its final review (dual by default) —
  same parallel isolation, scripts, contract, and fail-closed semantics.
- Verdicts from this command do NOT promote a draft PR; only the loop's
  final-mode approve does (the loop owns `gh pr ready`).
- The `code-review` standards skill (canonical risky-surface list, four
  dimensions) auto-activates in the `claude -p` review sessions — the criteria
  are the same as sa/ha; only the execution differs.

## References

- `references/review-contract.md` — `ca_claude_review.v1` / `ca_codex_review.v1`
  shapes and gate semantics (byte-identical copy; the canonical set lives with
  each skill that consumes it).
