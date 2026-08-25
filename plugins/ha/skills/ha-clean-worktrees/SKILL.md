---
name: ha-clean-worktrees
description: Safely reclaim linked worktrees and local branches only after positive proof that their PR or branch merged. Use explicitly after feature PRs land, for one named branch/path or all merged worktrees. Never removes the main checkout, uncommitted work, unmerged branches, or unknown locks; never uses force deletion.
license: MIT
---

# HA clean worktrees

Delegate all decisions and removals to the bundled deterministic script. Resolve this skill directory from the loaded `SKILL.md` path.

- No argument means `all-merged`; a named branch/path limits scope.
- The script scans every registered linked worktree regardless of plugin path.
- Merge proof must be positive: merged GitHub PR or Git ancestry. Missing/deleted branch is not proof.
- Plain `git worktree remove` protects uncommitted work; `git branch -d` protects unmerged work. Never substitute `--force` or `-D`.
- The main checkout and unknown/live locks are absolute barriers.

Run only after explicit invocation:

```bash
bash <skill-dir>/scripts/clean.sh "${TARGET:-all-merged}"
```

Return the script's cleaned/skipped table and recovery implications. Do not perform extra deletion outside the script.
