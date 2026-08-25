#!/usr/bin/env bash
# Install the ca (Cooperate Agents) plugins.
#
#   ca/install.sh [--codex] [--claude] [--force] [--dry-run] [--check]
#
# --codex   Copy the Codex skill into $CODEX_HOME/skills (default ~/.codex/skills),
#           so a Codex session discovers $ca-implement-plan. Restart Codex afterwards.
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
SKILL_SRC="$HERE/codex/skills/ca-implement-plan"
DEST_ROOT="${CODEX_HOME:-$HOME/.codex}/skills"
DEST="$DEST_ROOT/ca-implement-plan"

do_codex=0 do_claude=0 force=0 dry=0 check=0
while [ $# -gt 0 ]; do case "$1" in
  --codex) do_codex=1; shift;; --claude) do_claude=1; shift;;
  --force) force=1; shift;; --dry-run) dry=1; shift;;
  --check) check=1; do_codex=1; shift;;
  -h|--help) sed -n '2,12p' "$0"; exit 0;;
  *) echo "unknown arg: $1" >&2; exit 2;; esac; done
[ "$do_codex" = 0 ] && [ "$do_claude" = 0 ] && { do_codex=1; do_claude=1; }

[ -f "$SKILL_SRC/SKILL.md" ] || { echo "ca skill not found at $SKILL_SRC" >&2; exit 1; }

if [ "$do_codex" = 1 ]; then
  echo "[ca] Codex skill: $SKILL_SRC -> $DEST"
  if [ "$check" = 1 ]; then
    [ -d "$DEST" ] || { echo "[ca] installed skill missing: $DEST" >&2; exit 1; }
    diff -qr -x __pycache__ -x '*.pyc' "$SKILL_SRC" "$DEST" >/dev/null || {
      echo "[ca] installed skill is stale; run: bash ca/install.sh --codex --force" >&2
      diff -qr -x __pycache__ -x '*.pyc' "$SKILL_SRC" "$DEST" || true
      exit 1
    }
    echo "[ca] installed Codex skill matches the repository source. ✔"
  elif [ "$dry" = 1 ]; then
    echo "[ca] (dry-run) would copy skill (no source files are modified)"
  else
    if [ -e "$DEST" ] && [ "$force" = 0 ]; then
      echo "[ca] $DEST already exists; pass --force to overwrite." >&2; exit 1
    fi
    mkdir -p "$DEST_ROOT"; rm -rf "$DEST"; cp -R "$SKILL_SRC" "$DEST"
    diff -qr -x __pycache__ -x '*.pyc' "$SKILL_SRC" "$DEST" >/dev/null || {
      echo "[ca] copy verification failed: $DEST" >&2; exit 1; }
    echo "[ca] installed. Restart Codex to pick up new skills."
  fi
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
  echo "[ca] Reminder: the loop needs BOTH plugins. The Codex skill calls the Claude plugin's"
  echo "     /ca:review-pr via 'claude -p'. If you cannot install the Claude plugin globally,"
  echo "     export CA_CLAUDE_PLUGIN_DIR=\"$HERE/claude\" so the review can load it with --plugin-dir."
fi
exit 0
