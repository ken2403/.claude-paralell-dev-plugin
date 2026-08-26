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

echo "install-test.sh: ok"
