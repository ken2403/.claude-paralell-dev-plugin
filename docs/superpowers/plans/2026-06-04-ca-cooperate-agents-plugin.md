# ca (Cooperate Agents) — Claude × Codex Loop: Best-Practice Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

## Context

We are building one repository area, `ca/` ("Cooperate Agents"), that ships **two installable plugins** — a **Claude Code plugin** (`ca/claude/`) and a **Codex plugin** (`ca/codex/`) — that together realize one human-in-the-loop workflow: **Claude drafts a plan and spars with Codex → Codex implements a big epic inside an isolated git worktree → Claude reviews the diff vs. the plan, up to 2 rounds → Codex opens a PR with an exchange summary → human merges → worktree cleaned up.**

The design (driver split, explicit session ids, files as source of truth, host-side Claude review) was settled over prior turns and partly built **under the working name `cx`**, which is now renamed to **`ca`**. This revision also makes the skill/script placement and install mechanisms follow each tool's published best practices. Two primary sources were read in full and are the authority here:

- **Anthropic — "The Complete Guide to Building Skills for Claude"** (28 pp). Canonical skill structure, frontmatter rules, progressive disclosure, distribution.
- **OpenAI Codex — Best practices** + the **installed `skill-creator`/`plugin-creator`/`skill-installer`** system skills (codex-cli 0.128.0). Codex skill rules, install locations, plugin manifest.

**Goal:** Ship `ca/claude` (Claude Code plugin) and `ca/codex` (Codex plugin) driving the plan→implement→review(≤2)→PR loop, each installable via its native plugin mechanism, every skill following the canonical self-contained layout.

**Architecture:** Two co-located plugin roots under `ca/`. Each tool scans only its own `skills/`, so the (nearly identical, but differently-validated) SKILL.md frontmatter rules never collide. Each skill is a **self-contained folder** (`SKILL.md` + its own `scripts/` + `references/`) so it stays portable when copied/distributed independently. Handoff between tools is JSON files validated by a bundled script against the versioned `ca_claude_review.v1` contract.

**Tech Stack:** Bash, `python3` (stdlib only), `git worktree`, `gh` CLI, Claude Code plugin + skills, Codex CLI (`codex exec` with `--output-schema`/`--json`/`resume <id>`/`-C`/`-s`), Codex skill format.

## Global Constraints (best practices — apply to every task)

**Skill structure (both tools share the SKILL.md open standard):**
- A skill is a folder: `SKILL.md` (required) + optional `scripts/` (executable code) + `references/` (docs loaded as needed) + `assets/`. **Helper scripts live INSIDE the owning skill's `scripts/`, never in a plugin-level `scripts/`.**
- **No `README.md` inside a skill folder.** Docs go in SKILL.md or `references/`. Human-facing READMEs live at the repo/plugin root only.
- Keep `SKILL.md` body focused and **under 5,000 words**; push detail to `references/` (progressive disclosure). Critical instructions at the top; use `## Important`; be specific and actionable ("Run `python scripts/x.py …`", not "validate the data").
- For critical validation, **bundle a script** that checks programmatically (Anthropic guide, "Advanced technique").

**Frontmatter:**
- `name`: kebab-case, **equal to the folder name** (Codex caps ≤64). No "claude"/"anthropic" in names.
- `description`: WHAT + WHEN (real trigger phrases) + negative triggers where useful; **< 1024 chars; no `<` or `>`**.
- Codex allowed keys only: `name, description, license, allowed-tools, metadata`. Claude additionally allows `model`, `effort`, `disable-model-invocation`, `compatibility`.
- Codex side-effecting skills set `agents/openai.yaml` → `policy.allow_implicit_invocation: false`. Claude side-effecting skills set `disable-model-invocation: true`.

**Model & effort (per skill — set where each tool allows it):**
- **Codex `ca-implement-plan`**: frontmatter **cannot** carry `model`/`effort`. The implementing model/effort comes from the human's Codex session at launch (`codex -m <model>`, `~/.codex/config.toml`, or a profile). Recommend a strong model + high reasoning in the README/skill body, not in frontmatter.
- **Claude `plan-loop`**: `model: opus`, `effort: xhigh`.
- **Claude `review-diff`**: `model: opus`, `effort: high` (also governs the model when invoked via `claude -p "/ca:review-diff …"`).
- **Claude `start`**: `effort: low`; model inherits.
- **Cross-tool calls set effort by flag/skill**: `spar-codex.sh` runs `codex exec -c model_reasoning_effort=high`; `claude-review.sh` invokes `/ca:review-diff`, so that skill's `opus/high` applies.

**Behavior:**
- **Review rounds capped at 2** (`MAX_ROUNDS` default `2`).
- Implementation runs in a `ca/<plan-id>` git worktree created by a script (never the model, never `main`).
- Codex runs `-s workspace-write` + `-c approval_policy=never`, **no network/no `gh`**; Claude review runs on the host. Capture `thread_id` from `codex exec --json` and resume by id — **never `--last`**.
- Use `opus` alias (no pinned model ids). Never edit secret files.

## Already built (branch `worktree-cx-plan`, committed under the OLD name `cx`)

These exist and are best-practice-compliant except for the name and the round cap; Task 0 renames them:
- `cx/codex/.codex-plugin/plugin.json`; `cx/codex/skills/cx-implement-plan/` (self-contained: `SKILL.md` + `agents/openai.yaml` with `allow_implicit_invocation: false` + `scripts/{claude-review.sh,new-worktree.sh,post-summary.sh}` + `references/review-contract.md`).
- `cx/claude/.claude-plugin/plugin.json`; `cx/claude/skills/.gitkeep`.
- `docs/superpowers/plans/2026-06-04-cx-claude-codex-loop-plugin.md` (stale; replaced in Task 8).

## Final File Structure (best-practice-aligned, `ca` naming)

```
AGENTS.md                                # CREATE: canonical agent instructions (open standard; Codex + 30+ tools)
CLAUDE.md                                # REPLACE with a symlink -> AGENTS.md (Claude Code reads the same source)
.claude-plugin/marketplace.json          # MODIFY: register ca (source ./ca/claude)
.agents/plugins/marketplace.json         # CREATE: Codex marketplace registering ca (source ../../ca/codex)
ca/
  README.md                              # CREATE: human-facing — flow, both-tool install, design notes
  install.sh                             # CREATE: install Codex skill -> ~/.codex/skills; print Claude install
  claude/                                # Claude Code plugin root
    .claude-plugin/plugin.json
    skills/
      plan-loop/
        SKILL.md                         # /ca:plan-loop — draft plan, spar with Codex, save
        scripts/spar-codex.sh
      review-diff/
        SKILL.md                         # /ca:review-diff — diff-vs-plan review -> ca_claude_review.v1 JSON
        scripts/validate-review.py
        references/review-contract.md
      start/
        SKILL.md                         # /ca:start — create worktree + print Codex kickoff
        scripts/new-worktree.sh
  codex/                                 # Codex plugin root
    .codex-plugin/plugin.json
    skills/ca-implement-plan/
      SKILL.md
      agents/openai.yaml
      scripts/{claude-review.sh,new-worktree.sh,post-summary.sh}
      references/review-contract.md
```

**Self-containment over DRY:** `review-contract.md` and `new-worktree.sh` are duplicated into each skill that needs them (skills must be portable when copied/distributed). `install.sh` re-copies the canonical Codex copies on install; Task 9 verifies they are byte-identical.

**Naming map (applied everywhere in Task 0 and all new files):** `cx`→`ca`; `cx-implement-plan`→`ca-implement-plan`; `/cx:*`→`/ca:*`; `$cx-implement-plan`→`$ca-implement-plan`; plugin name `cx`→`ca`; `cx_claude_review.v1`→`ca_claude_review.v1`; `cx_codex_loop_result.v1`→`ca_codex_loop_result.v1`; `CX_OUT`→`CA_OUT`; run dir `.cx/`→`.ca/`; worktrees `.cx-worktrees`→`.ca-worktrees`; branch prefix `cx/<id>`→`ca/<id>`.

---

## Task A: AGENTS.md canonical + CLAUDE.md alias (single source of truth)

**Why:** The user wants to keep evolving this system, with one instruction file both tools obey. Best practice (AGENTS.md open standard, Linux Foundation; 30+ tools incl. Codex read it): keep instructions in `AGENTS.md` and make `CLAUDE.md` a symlink to it (git tracks symlinks natively; Claude Code follows them). The repo currently has a hand-written root `CLAUDE.md` — migrate it verbatim so nothing is lost.

**Files:** Create `AGENTS.md`; replace `CLAUDE.md` with a symlink.

- [ ] **Step 1:** Copy the current `CLAUDE.md` content verbatim into a new `AGENTS.md` (preserves the pw/hv/authoring rules).
- [ ] **Step 2:** Append an `## Working on the ca plugin` section to `AGENTS.md`: the ca two-plugin layout; the cross-tool loop design; skill best-practice rules (self-contained skills, scripts inside skills, no README in skill folders, frontmatter limits, no `<>`, ≤1024 desc, <5000-word body); model/effort policy; the `ca_claude_review.v1` contract; and the validation commands (`claude plugin validate ./ca/claude`, the Codex frontmatter check, `ca/install.sh --dry-run`).
- [ ] **Step 3:** Replace the file with a symlink: `git rm CLAUDE.md` then `ln -s AGENTS.md CLAUDE.md` and `git add CLAUDE.md` (commits as a symlink). Document the `@AGENTS.md` import bridge as the alternative for environments where symlinks are undesirable.
- [ ] **Step 4 (verify):** `test -L CLAUDE.md && readlink CLAUDE.md` → `AGENTS.md`; `git ls-files -s CLAUDE.md` shows mode `120000` (symlink); `head -1 AGENTS.md` shows the migrated content; Codex/Claude both resolve to the same text.
- [ ] **Step 5 (commit):** `git commit -m "docs: make AGENTS.md canonical, CLAUDE.md an alias symlink"`

## Task 0: Rename the already-built `cx` → `ca`

**Files:** `git mv cx ca`; then update internal references in every moved file.

- [ ] **Step 1:** `git mv cx ca`; `git mv ca/codex/skills/cx-implement-plan ca/codex/skills/ca-implement-plan`.
- [ ] **Step 2:** In moved files, replace per the naming map: skill `name: cx-implement-plan`→`ca-implement-plan` (and SKILL_DIR path `~/.codex/skills/ca-implement-plan`); plugin.json `"name": "cx"`→`"ca"` (both manifests) + display strings; `$cx-implement-plan`→`$ca-implement-plan`; `cx_codex_loop_result.v1`→`ca_codex_loop_result.v1`; `cx_claude_review.v1`→`ca_claude_review.v1`; `CX_OUT`→`CA_OUT`; `/cx:review-diff`→`/ca:review-diff`; `.cx/`→`.ca/`; `.cx-worktrees`→`.ca-worktrees`; `cx/<id>` branch→`ca/<id>`; `cx/` worktree guard→`ca/`.
- [ ] **Step 3 (verify):** `! grep -rn "\bcx\b\|cx-implement\|cx_\|CX_OUT\|/cx:" ca/` (no stray `cx`); frontmatter rule check on `ca-implement-plan` → VALID; `claude plugin validate ./ca/claude`.
- [ ] **Step 4 (commit):** `git commit -m "refactor(ca): rename cx -> ca (Cooperate Agents)"`

## Task 1: Cap review rounds at 2 in the Codex skill

**Files:** Modify `ca/codex/skills/ca-implement-plan/SKILL.md`.

- [ ] **Step 1:** `MAX_ROUNDS … Default 3.` → `Default 2.`
- [ ] **Step 2:** Step 4 loop text: "Stop when approved, when the round count reaches `MAX_ROUNDS` (default 2 — initial review plus at most two fix rounds), or when two consecutive rounds produce an identical diff."
- [ ] **Step 3 (verify):** `grep -n "default 2\|MAX_ROUNDS"`; frontmatter check → VALID.
- [ ] **Step 4 (commit):** `git commit -m "fix(ca): cap Claude review at 2 rounds"`

## Task 2: Claude skill `/ca:review-diff` (SKILL.md + validator + contract)

**Files:** Create `ca/claude/skills/review-diff/SKILL.md`, `…/scripts/validate-review.py`, `…/references/review-contract.md`.

**Interfaces — Consumes:** args `plan=`, `diff=`, `worktree=`, `round=`, output path. **Produces:** `ca_claude_review.v1` JSON `{schema_version,"round":int,verdict∈{approve,request_changes,blocked},summary,findings:[{id,blocking:bool,severity∈{blocker,major,minor},file?,line?,title,evidence?,recommended_fix?}],verification?:[…]}`.

- [ ] **Step 1:** Write `references/review-contract.md` (fields + enums + fail-closed rule + `blocking:true` gates the PR).
- [ ] **Step 2 (failing test):** `echo '{}' > /tmp/bad.json; python3 ca/claude/skills/review-diff/scripts/validate-review.py /tmp/bad.json` → "not found".
- [ ] **Step 3:** Implement `validate-review.py` (stdlib): assert `verdict`∈enum, `findings` list, each `blocking` bool; print `verdict`+exit 0 on success; stderr+exit 1 on violation; exit 2 on parse error.
- [ ] **Step 4:** Write `SKILL.md`: `name: review-diff`, `description:` (WHAT+WHEN+triggers, no `<>`), `model: opus`, `effort: high`, `allowed-tools: Read, Grep, Glob, Bash, WebFetch`, `disable-model-invocation: true`. Body: read plan+diff+surrounding code; criteria ported from `hv/skills/review-pr/SKILL.md`; web search when needed; "Run `python scripts/validate-review.py <out>` before returning"; write JSON to `$CA_OUT`. Link `references/review-contract.md`.
- [ ] **Step 5 (verify):** good→verdict/exit0, bad→exit1; `py_compile`; `claude plugin validate ./ca/claude`.
- [ ] **Step 6 (commit):** `git commit -m "feat(ca): /ca:review-diff self-contained reviewer skill"`

## Task 3: Claude skill `/ca:plan-loop` (SKILL.md + spar-codex.sh)

**Files:** Create `ca/claude/skills/plan-loop/SKILL.md`, `…/scripts/spar-codex.sh`.

- [ ] **Step 1 (failing test):** stub `codex`; `CODEX_BIN=stub bash …/spar-codex.sh /tmp/p.md` → "not found".
- [ ] **Step 2:** Implement `spar-codex.sh`: `"${CODEX_BIN:-codex}" exec --sandbox read-only -c model_reasoning_effort=high - < "$1"`.
- [ ] **Step 3:** Write `SKILL.md` (`name: plan-loop`, `model: opus`, `effort: xhigh`, `allowed-tools: Read, Grep, Glob, Bash, WebFetch, Agent`): draft a plan per superpowers writing-plans; spar with Codex 1–2 rounds via `scripts/spar-codex.sh`, re-feeding the full draft each round (Codex `exec` is stateless); finalize + save to `docs/superpowers/plans/YYYY-MM-DD-<name>.md`.
- [ ] **Step 4 (verify):** stub prints critique; `claude plugin validate ./ca/claude`.
- [ ] **Step 5 (commit):** `git commit -m "feat(ca): /ca:plan-loop with Codex sparring"`

## Task 4: Claude skill `/ca:start` (SKILL.md + new-worktree.sh)

**Files:** Create `ca/claude/skills/start/SKILL.md`, `…/scripts/new-worktree.sh` (copy of the Codex skill's, kept identical).

- [ ] **Step 1:** Copy `new-worktree.sh` into `start/scripts/`.
- [ ] **Step 2:** Write `SKILL.md` (`name: start`, `description:` with triggers, `effort: low`, `disable-model-invocation: true`, `allowed-tools: Read, Bash`): run `scripts/new-worktree.sh <plan>`, then print the exact `codex -C <wt>` command and `$ca-implement-plan PLAN=<abs>` for the human. State it hands off to a Codex session (human-in-the-loop). Recommend the Codex launch model/effort in the body (frontmatter can't set them).
- [ ] **Step 3 (verify):** `bash -n …/new-worktree.sh`; `claude plugin validate ./ca/claude`.
- [ ] **Step 4 (commit):** `git commit -m "feat(ca): /ca:start kickoff skill"`

## Task 5: Register the Claude plugin in the marketplace

**Files:** Modify `.claude-plugin/marketplace.json`.

- [ ] **Step 1:** Append `{ "name": "ca", "source": "./ca/claude", "description": "Cooperate Agents — Claude×Codex loop (plan & review side)", "category": "workflow", "tags": ["codex","cross-tool","worktree","code-review"] }`.
- [ ] **Step 2 (verify):** assert `ca` present; `claude plugin validate ./ca/claude`. Install: `/plugin install ca@agent-parallel-dev-plugin`.
- [ ] **Step 3 (commit):** `git commit -m "feat(ca): register ca Claude plugin in marketplace"`

## Task 6: Codex install mechanism (plugin marketplace + skill install)

**Files:** Create `.agents/plugins/marketplace.json`, `ca/install.sh`.

- [ ] **Step 1 (failing test):** `bash ca/install.sh --dry-run` → "not found".
- [ ] **Step 2:** Implement `install.sh`: `--codex` (default) copies `ca/codex/skills/ca-implement-plan` → `${CODEX_HOME:-$HOME/.codex}/skills/ca-implement-plan` (refuse-if-exists unless `--force`), prints "Restart Codex to pick up new skills."; `--claude` prints `/plugin install ca@agent-parallel-dev-plugin` and `claude --plugin-dir <abs>/ca/claude`; `--dry-run` prints planned actions.
- [ ] **Step 3:** Create `.agents/plugins/marketplace.json` per plugin-json-spec: one `ca` entry, `source.source: "local"`, `path` to the codex plugin root, `policy.installation: "AVAILABLE"`, `policy.authentication: "ON_INSTALL"`, `category: "Productivity"`.
- [ ] **Step 4 (verify):** `bash ca/install.sh --dry-run`; `bash -n ca/install.sh`; JSON loads.
- [ ] **Step 5 (commit):** `git commit -m "feat(ca): Codex install.sh + marketplace registration"`

## Task 7: Human-facing README (root only — never inside a skill)

**Files:** Create `ca/README.md`.

- [ ] **Step 1:** Flow diagram; two-plugin layout; **install both** (Codex: `bash ca/install.sh` + restart, or `.codex-plugin` route; Claude: `/plugin install ca@agent-parallel-dev-plugin` or `claude --plugin-dir …/ca/claude`); the contract; session/sandbox model; `CODEX_BIN`/`CLAUDE_BIN` overrides.
- [ ] **Step 2 (commit):** `git commit -m "docs(ca): human-facing README for both plugins"`

## Task 8: Replace the stale plan doc

**Files:** Replace `docs/superpowers/plans/2026-06-04-cx-claude-codex-loop-plugin.md` with a `ca`-named final plan (`…-ca-cooperate-agents-plugin.md`), `git rm` the old one.

- [ ] **Step 1:** Save this plan as the new doc; remove the old `cx` doc.
- [ ] **Step 2 (commit):** `git commit -m "docs(ca): sync plan to final ca design"`

## Task 9: Best-practice validation gate + install smoke test

- [ ] **Step 1 (Claude rules):** `claude plugin validate ./ca/claude` and `./hv` pass. Each `ca/claude/skills/*/SKILL.md`: `name`==folder, kebab-case, `description` WHAT+WHEN + **no `<>`** + <1024; **no README in any skill folder** (`! find ca -path '*/skills/*/README.md'`); SKILL.md <5,000 words.
- [ ] **Step 2 (Codex rules):** allowed-keys check on `ca-implement-plan` → VALID; if PyYAML available, run `quick_validate.py`.
- [ ] **Step 3 (self-containment):** `diff` the two `new-worktree.sh` copies and the two `review-contract.md` copies → identical.
- [ ] **Step 4 (syntax):** `bash -n` all `*.sh`; `py_compile` all `*.py`; all `*.json` load.
- [ ] **Step 5 (install smoke):** `CODEX_HOME=$(mktemp -d) bash ca/install.sh --codex` → installed `SKILL.md` exists + validates. Confirm `.agents/plugins/marketplace.json` `source.path`; if Codex rejects a non-`./plugins/<name>` path, document `install.sh` as the supported Codex install.
- [ ] **Step 6 (triggering self-check):** for each skill, confirm spec phrases ("implement this plan", "review what you built", "draft a plan") plausibly trigger its `description`.
- [ ] **Step 7 (no stray `cx`):** `! grep -rn "\bcx\b\|/cx:\|cx-implement\|cx_\|CX_OUT" ca .claude-plugin/marketplace.json .agents 2>/dev/null`.
- [ ] **Step 8 (commit):** `git commit -m "test(ca): best-practice validation gate + install smoke"`

## Task 10: Open the PR

- [ ] **Step 1:** `git push -u origin worktree-cx-plan`.
- [ ] **Step 2:** `gh pr create` (base `main`) summarizing the ca design, best-practice compliance, and install for both tools.

---

## Verification (end-to-end)

1. **Install:** `bash ca/install.sh --codex` (restart Codex) + `/plugin install ca@agent-parallel-dev-plugin` (or `claude --plugin-dir …/ca/claude`).
2. **Plan + spar:** Claude `/ca:plan-loop "<epic>"` → calls Codex (sparring text), saves a plan.
3. **Kickoff:** `/ca:start <plan>` → prints worktree path + `$ca-implement-plan` command.
4. **Loop:** in a Codex session in that worktree, `$ca-implement-plan PLAN=<abs>` → implements task-by-task, `claude-review.sh` → `/ca:review-diff` returns `ca_claude_review.v1` JSON; addresses blocking findings for **≤2 rounds**; opens a (ready/draft) PR with an exchange-summary comment.
5. **Cleanup:** after a human merges, worktree + branch removed.
6. **Guards:** Codex ran `-s workspace-write`, no network; only captured `thread_id` (never `--last`).

## Self-Review

- **Spec coverage:** AGENTS.md canonical + CLAUDE.md alias (Task A) ✓; rename cx→ca (Task 0) ✓; Claude drafts+spars (Task 3) ✓; Codex implements epic in worktree (existing skill + Task 1/4) ✓; Claude reviews ≤2 (Task 1 + Task 2) ✓; PR+summary (existing `post-summary.sh`) ✓; best-practice placement (Global Constraints + Tasks 2–4, gate Task 9) ✓; Codex-plugin install (Task 6) ✓; Claude-plugin install (Task 5) ✓.
- **Placeholder scan:** schemas/scripts/frontmatter concrete; skill bodies specified by responsibility + linked contract.
- **Identifier consistency:** `ca_claude_review.v1`, `MAX_ROUNDS`, `CA_OUT`, `CODEX_BIN`/`CLAUDE_BIN`, branch prefix `ca/`, run dir `.ca/` consistent across all tasks; Task 9 Step 7 enforces zero stray `cx`.

## Open item (non-blocking, resolved in Task 9 Step 5)

- Codex marketplace `source.path` resolution for a plugin not under `<root>/plugins/`. Fallback: copy-based `install.sh` is the supported Codex install; the manifest remains valid plugin metadata.

Note: the git branch stays `worktree-cx-plan` (already created); only the plugin/identifier naming becomes `ca`.
