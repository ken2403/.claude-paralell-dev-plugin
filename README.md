# agent-parallel-dev-plugin

A **Claude Code and Codex plugin marketplace** — a single repository that hosts and manages
parallel-development plugins. Add the relevant marketplace once, then install whichever plugins
you want.

The repository is named `agent-parallel-dev-plugin`. The marketplace identifier remains
`claude-parallel-dev-plugin` for install-command compatibility.

## Add the marketplace

In Claude Code:

```
/plugin marketplace add ken2403/agent-parallel-dev-plugin
```

In Codex, add this repository as a marketplace, then install `ha` or `ca` from it.

```bash
codex plugin marketplace add /path/to/agent-parallel-dev-plugin
codex plugin add ha@claude-parallel-dev-plugin
```

## Plugins

| Plugin | What it is | Install | Docs |
|--------|------------|---------|------|
| **`sa`** | **Simple Agents for Claude Code** — command-free skills + subagents for fast single-feature work: digest a plan, get your approval, isolate in a worktree, implement, and open a PR. | `/plugin install sa@claude-parallel-dev-plugin` | [Claude docs](sa/README.md) |
| **`ha`** | **Higher Agents** — build ONE feature thoroughly with a red-teamed plan, per-task review, a risk-scaled pre-PR gate, independent PR review, feedback handling, gated merge, and safe cleanup. The Claude version leverages `superpowers`; the standalone Codex version has no Claude or `superpowers` runtime dependency. | Claude: `/plugin install ha@claude-parallel-dev-plugin`; Codex: `codex plugin add ha@claude-parallel-dev-plugin` | [Claude docs](ha/README.md) · [Codex docs](plugins/ha/README.md) |
| **`ca`** | **Cooperate Agents** — a Claude×Codex loop shipped as two co-located plugins: draft a milestone-grouped plan sparring with Codex, hand off to Codex to implement milestone by milestone in an isolated worktree (draft PR at the first milestone, Claude checkpoint review between milestones), then the final **dual review** — blind Claude plus an offline Codex second opinion, adjudicated into one verdict (`/ca:dual-review` runs the same thing standalone; ≤2 final rounds) — before it's promoted to ready, then gated-merge and clean up worktrees — the same full lifecycle as `sa`/`ha`, adapted to the cross-tool loop. | `/plugin install ca@claude-parallel-dev-plugin` | [ca/README.md](ca/README.md) |

New to this? Pick **`sa`** for a single feature you want done fast with a quick approval
gate (Sonnet build, Opus review); reach for **`ha`** when you want that same single feature
built thoroughly — a deeper plan gate, layered review loops, and adversarial verification,
model-agnostic (inherits your session model). All three are foreground and need no tmux.
The Claude `ha` plugin additionally requires `superpowers`; the Codex `ha` plugin is standalone.

## Review base behavior

Every PR review uses `gh pr diff`, so it compares the PR head with that PR's configured base
branch rather than assuming `main` or the repository default. Current structured HA/CA review
records bind approval to the PR and head SHA, but not yet to the base commit SHA. If the base
branch advances after review, rerun the appropriate review before merging.

## Try a plugin locally (without installing)

```
claude --plugin-dir /path/to/agent-parallel-dev-plugin/sa
claude --plugin-dir /path/to/agent-parallel-dev-plugin/ha
```

## Repository layout

```
.
├── .claude-plugin/marketplace.json   # marketplace manifest (lists the plugins below)
├── .agents/plugins/marketplace.json  # Codex marketplace manifest
├── sa/                               # the sa plugin (its own .claude-plugin/plugin.json, skills, agents, hooks)
├── ha/                               # the ha plugin (its own .claude-plugin/plugin.json, skills, agents, hooks)
├── ca/                               # the ca plugin (Claude + Codex sides)
├── plugins/ca/                       # generated Codex marketplace package for ca
├── plugins/ha/                       # standalone Codex marketplace package for ha
├── AGENTS.md                         # canonical cross-tool maintainer guidance
├── CLAUDE.md                         # symlink to AGENTS.md for Claude Code
└── README.md                         # this file
```

Claude plugins are self-contained under their source directories with
`.claude-plugin/plugin.json`. Codex packages live under `plugins/` with
`.codex-plugin/plugin.json`. The matching marketplace manifest points to each package via its
source path. See `AGENTS.md` before changing generated mirrors or shared files.
