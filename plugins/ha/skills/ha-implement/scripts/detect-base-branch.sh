#!/usr/bin/env bash
set -euo pipefail

repo_root="${1:-.}"
if [ -n "${HA_BASE:-}" ]; then
  printf '%s\n' "$HA_BASE"
  exit 0
fi

base=""
for rules in "$repo_root/AGENTS.md" "$repo_root/CLAUDE.md"; do
  [ -f "$rules" ] || continue
  base="$(grep -iE 'base[ ._-]*branch|default[ ._-]*branch|primary[ ._-]*branch' "$rules" 2>/dev/null | head -1 | grep -oE '(main|master|develop|dev|release[^[:space:]]*)' | head -1 || true)"
  [ -z "$base" ] || break
done
if [ -z "$base" ]; then
  base="$(git -C "$repo_root" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || true)"
fi
if [ -z "$base" ]; then
  base="$(git -C "$repo_root" ls-remote --symref origin HEAD 2>/dev/null | awk '/^ref:/ {sub("refs/heads/", "", $2); print $2; exit}' || true)"
fi
if [ -z "$base" ]; then
  for candidate in main master develop dev; do
    if git -C "$repo_root" show-ref --verify --quiet "refs/heads/$candidate" || git -C "$repo_root" show-ref --verify --quiet "refs/remotes/origin/$candidate"; then
      base="$candidate"
      break
    fi
  done
fi
[ -n "$base" ] || { echo "detect-base-branch: cannot determine base; set HA_BASE" >&2; exit 1; }
printf '%s\n' "$base"
