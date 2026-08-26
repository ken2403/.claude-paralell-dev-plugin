#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
INSTALL="$ROOT/ca/install.sh"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/ca-install-test.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

dry="$TMP/dry.log"
CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --codex --dry-run > "$dry"
grep -q 'ca-implement-plan' "$dry"
grep -q 'ca-second-opinion' "$dry"
[ ! -e "$TMP/codex-home/skills" ] || {
  echo "install dry-run created the destination" >&2
  exit 1
}

CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --codex > "$TMP/install.log"
for skill_name in ca-implement-plan ca-second-opinion; do
  diff -qr "$ROOT/ca/codex/skills/$skill_name" \
    "$TMP/codex-home/skills/$skill_name" >/dev/null
done

CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --check > "$TMP/check.log"
grep -q 'installed ca-implement-plan matches' "$TMP/check.log"
grep -q 'installed ca-second-opinion matches' "$TMP/check.log"

# A missing member of the required pair must fail --check.
mv "$TMP/codex-home/skills/ca-second-opinion" "$TMP/missing-second-opinion"
set +e
CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --check > "$TMP/missing.log" 2>&1
missing_rc=$?
set -e
[ "$missing_rc" -ne 0 ] || { echo "missing install unexpectedly passed --check" >&2; exit 1; }
grep -q 'installed skill missing' "$TMP/missing.log"
mv "$TMP/missing-second-opinion" "$TMP/codex-home/skills/ca-second-opinion"

# A stale installation must fail --check instead of reporting a false match.
printf '\nlocal drift\n' >> "$TMP/codex-home/skills/ca-second-opinion/SKILL.md"
set +e
CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --check > "$TMP/stale.log" 2>&1
stale_rc=$?
set -e
[ "$stale_rc" -ne 0 ] || { echo "stale install unexpectedly passed --check" >&2; exit 1; }
grep -q 'installed skill is stale' "$TMP/stale.log"

# Preflight every destination before copying: one collision must not partially install the other.
mkdir -p "$TMP/collision-home/skills/ca-second-opinion"
printf 'keep-me\n' > "$TMP/collision-home/skills/ca-second-opinion/marker"
set +e
CODEX_HOME="$TMP/collision-home" bash "$INSTALL" --codex > "$TMP/collision.log" 2>&1
collision_rc=$?
set -e
[ "$collision_rc" -ne 0 ] || { echo "collision install unexpectedly succeeded" >&2; exit 1; }
[ ! -e "$TMP/collision-home/skills/ca-implement-plan" ] \
  || { echo "collision caused a partial multi-skill install" >&2; exit 1; }
[ "$(cat "$TMP/collision-home/skills/ca-second-opinion/marker")" = keep-me ] \
  || { echo "collision target was modified without --force" >&2; exit 1; }

# --force intentionally replaces both stale/colliding destinations and verifies their bytes.
CODEX_HOME="$TMP/codex-home" bash "$INSTALL" --codex --force > "$TMP/force.log"
for skill_name in ca-implement-plan ca-second-opinion; do
  diff -qr "$ROOT/ca/codex/skills/$skill_name" \
    "$TMP/codex-home/skills/$skill_name" >/dev/null
done

echo "install-test.sh: ok"
