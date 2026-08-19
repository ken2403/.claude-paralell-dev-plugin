# claude-parallel-dev-plugin

A **Claude Code and Codex plugin marketplace** — a single repository that hosts and manages
parallel-development plugins. Add the relevant marketplace once, then install whichever plugins
you want.

## Add the marketplace

In Claude Code:

```
/plugin marketplace add ken2403/claude-parallel-dev-plugin
```

## Plugins

| Plugin | What it is | Install | Docs |
|--------|------------|---------|------|
| **`sa`** | **Simple Agents** — command-free skills + subagents for fast single-feature work: digest a plan, get your approval, isolate in a worktree, implement, and open a PR. | `/plugin install sa@claude-parallel-dev-plugin` | [sa/README.md](sa/README.md) |
| **`ha`** | **Higher Agents** — the **thorough** counterpart to `sa` for building ONE feature properly: a deep, red-teamed plan, an SDD per-task loop plus a risk-scaled pre-PR adversarial gate, an independent review, apply-feedback, and a gated merge. Leverages the `superpowers` disciplines (required). | `/plugin install ha@claude-parallel-dev-plugin` | [ha/README.md](ha/README.md) |
| **`ca`** | **Cooperate Agents** — a Claude×Codex loop shipped as two co-located plugins: draft a milestone-grouped plan sparring with Codex, hand off to Codex to implement milestone by milestone in an isolated worktree (draft PR at the first milestone, Claude checkpoint review between milestones), then the final **dual review** — blind Claude plus an offline Codex second opinion, adjudicated into one verdict (`/ca:dual-review` runs the same thing standalone; ≤2 final rounds) — before it's promoted to ready, then gated-merge and clean up worktrees — the same full lifecycle as `sa`/`ha`, adapted to the cross-tool loop. | `/plugin install ca@claude-parallel-dev-plugin` | [ca/README.md](ca/README.md) |

New to this? Pick **`sa`** for a single feature you want done fast with a quick approval
gate (Sonnet build, Opus review); reach for **`ha`** when you want that same single feature
built thoroughly — a deeper plan gate, layered review loops, and adversarial verification,
model-agnostic (inherits your session model). All three are foreground and need no tmux
(`ha` additionally requires the `superpowers` plugin).

## Try a plugin locally (without installing)

```
claude --plugin-dir /path/to/claude-parallel-dev-plugin/sa
claude --plugin-dir /path/to/claude-parallel-dev-plugin/ha
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
├── CLAUDE.md                         # maintainer guidance for this repo
└── README.md                         # this file
```

Each plugin is self-contained under its own directory with its own
`.claude-plugin/plugin.json`. The marketplace manifest at the repo root points to
each one via its `source` path. To add another plugin, create a new directory,
give it a `.claude-plugin/plugin.json`, and add an entry to `marketplace.json`.
