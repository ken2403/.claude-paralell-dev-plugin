---
name: ha-merge-pr
description: Merge a GitHub PR only after deterministic fail-closed preflight proves it is open, ready, conflict-free, green, free of changes-requested reviews, and still at the exact head SHA approved by $ha-review-pr. Use when the user explicitly asks to merge a reviewed HA PR. Never bypasses protection or force-merges.
license: MIT
---

# HA merge PR

Merging is irreversible. Resolve this skill directory from the loaded `SKILL.md` path. Do not reproduce or weaken the script's checks in prose.

## 1. Preflight

Resolve the PR number or auto-detect the current branch PR. Run:

```bash
bash <skill-dir>/scripts/merge-pr.sh --preflight "$PR"
```

The script fails closed unless all of these are true:

- PR state is open and it is not a draft;
- GitHub reports it mergeable and not behind/conflicting;
- no review decision is `CHANGES_REQUESTED`;
- every reported CI check is successful, neutral, or skipped;
- a strict `ha_codex_review.v1` record exists with `APPROVE`, zero blockers, passing verification, and the exact current `headRefOid`.

If preflight fails, stop and state the missing gate. Never use admin bypass, `--force`, or a direct merge command.

## 2. Confirm method and merge

Use the repository's required method; otherwise default to squash. If the user's invocation did not already explicitly authorize merging now, show the preflight evidence and ask once before proceeding.

```bash
bash <skill-dir>/scripts/merge-pr.sh --merge "$PR" --method squash
```

The script repeats preflight immediately before `gh pr merge` and confirms `mergedAt`. Report the result and hand off to `$ha-clean-worktrees`.
