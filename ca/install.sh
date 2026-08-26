#!/usr/bin/env bash
# Install the ca (Cooperate Agents) plugins.
#
#   ca/install.sh [--codex] [--claude] [--force] [--dry-run] [--check]
#
# --codex   Copy both Codex skills into $CODEX_HOME/skills (default ~/.codex/skills),
#           so Codex discovers $ca-implement-plan and internal $ca-second-opinion.
# --claude  Print how to install the Claude Code plugin (marketplace or --plugin-dir).
# --force   Overwrite an existing installed skill directory.
# --dry-run Print planned actions without changing anything.
# --check   Verify the installed Codex skill exactly matches the repository source.
#
# With no flag, BOTH sides are handled — the loop needs BOTH plugins: the Codex skill
# implements, and it calls the Claude plugin's /ca:review-pr to review. Installing only
# one side makes every review round fail.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"            # .../ca
SKILLS_SRC_ROOT="$HERE/codex/skills"
SKILL_NAMES=(ca-implement-plan ca-second-opinion)
DEST_ROOT="${CODEX_HOME:-$HOME/.codex}/skills"

do_codex=0 do_claude=0 force=0 dry=0 check=0
while [ $# -gt 0 ]; do case "$1" in
  --codex) do_codex=1; shift;; --claude) do_claude=1; shift;;
  --force) force=1; shift;; --dry-run) dry=1; shift;;
  --check) check=1; do_codex=1; shift;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
[ "$do_codex" = 0 ] && [ "$do_claude" = 0 ] && { do_codex=1; do_claude=1; }

for skill_name in "${SKILL_NAMES[@]}"; do
  [ -f "$SKILLS_SRC_ROOT/$skill_name/SKILL.md" ] \
    || { echo "ca skill not found at $SKILLS_SRC_ROOT/$skill_name" >&2; exit 1; }
done

if [ "$do_codex" = 1 ]; then
  if [ "$check" = 0 ] && [ "$dry" = 0 ] && [ "$force" = 0 ]; then
    for skill_name in "${SKILL_NAMES[@]}"; do
      dest="$DEST_ROOT/$skill_name"
      [ ! -e "$dest" ] || {
        echo "[ca] $dest already exists; pass --force to overwrite." >&2
        exit 1
      }
    done
  fi

  for skill_name in "${SKILL_NAMES[@]}"; do
    skill_src="$SKILLS_SRC_ROOT/$skill_name"
    dest="$DEST_ROOT/$skill_name"
    echo "[ca] Codex skill: $skill_src -> $dest"
    if [ "$check" = 1 ]; then
      [ -d "$dest" ] || { echo "[ca] installed skill missing: $dest" >&2; exit 1; }
      diff -qr -x __pycache__ -x '*.pyc' "$skill_src" "$dest" >/dev/null || {
        echo "[ca] installed skill is stale; run: bash ca/install.sh --codex --force" >&2
        diff -qr -x __pycache__ -x '*.pyc' "$skill_src" "$dest" || true
        exit 1
      }
      echo "[ca] installed $skill_name matches the repository source. ✔"
    elif [ "$dry" = 1 ]; then
      echo "[ca] (dry-run) would copy $skill_name (no source files are modified)"
    else
      mkdir -p "$DEST_ROOT"
      rm -rf "$dest"
      cp -R "$skill_src" "$dest"
      diff -qr -x __pycache__ -x '*.pyc' "$skill_src" "$dest" >/dev/null || {
        echo "[ca] copy verification failed: $dest" >&2; exit 1; }
      echo "[ca] installed $skill_name."
    fi
  done
  [ "$check" = 1 ] || [ "$dry" = 1 ] || echo "[ca] Restart Codex to pick up new skills."
fi

if [ "$do_claude" = 1 ]; then
  echo "[ca] Claude Code plugin (REQUIRED for the review step — provides /ca:review-pr):"
  echo "    /plugin install ca@agent-parallel-dev-plugin"
  echo "    # or, for local dev:  claude --plugin-dir \"$HERE/claude\""
  # Warn if the Claude plugin does not appear installed, since claude-review.sh calls plain
  # `claude -p /ca:review-pr` and will fail (no review) without it.
  if command -v claude >/dev/null 2>&1; then
    if claude plugin list 2>/dev/null | grep -q "ca@"; then
      echo "[ca] detected: the ca Claude plugin appears installed. ✔"
    else
      echo "[ca] WARNING: the ca Claude plugin is NOT installed. Until it is (or you set"
      echo "     CA_CLAUDE_PLUGIN_DIR=\"$HERE/claude\" when running the loop), /ca:review-pr"
      echo "     will not resolve and every review round will fail." >&2
    fi
  fi
fi

if [ "$dry" = 0 ]; then
  echo
  echo "[ca] Reminder: the loop needs BOTH plugins. The Codex plugin supplies implementation"
  echo "     and the bounded second opinion; it calls the Claude plugin's /ca:review-pr via"
  echo "     'claude -p'. If you cannot install the Claude plugin globally,"
  echo "     export CA_CLAUDE_PLUGIN_DIR=\"$HERE/claude\" so the review can load it with --plugin-dir."
fi
exit 0
