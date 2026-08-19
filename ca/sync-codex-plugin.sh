#!/usr/bin/env bash
# Keep the canonical ca/codex source and the marketplace package mirror identical.
set -euo pipefail

CA_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$CA_DIR/.." && pwd)"
SOURCE="$CA_DIR/codex"
DEST="$ROOT/plugins/ca"
MODE="${1:-sync}"

[ -f "$SOURCE/.codex-plugin/plugin.json" ] || {
  echo "ca Codex source missing: $SOURCE" >&2
  exit 1
}
# `sync` does `rm -rf "$DEST"`, so refuse anything that is not an existing ca mirror
# (or absent). Comparing DEST to the constant it was just assigned proves nothing.
if [ -e "$DEST" ] && [ ! -f "$DEST/.codex-plugin/plugin.json" ]; then
  echo "refusing to replace $DEST: it is not a ca Codex plugin mirror" >&2
  exit 1
fi

# Ignore build droppings: a stray __pycache__ from running any bundled script must not
# read as "the mirror is stale".
DIFF_OPTS=( -qr -x __pycache__ -x '*.pyc' )

case "$MODE" in
  --check)
    [ -d "$DEST" ] || { echo "ca Codex plugin mirror missing: $DEST" >&2; exit 1; }
    diff "${DIFF_OPTS[@]}" "$SOURCE" "$DEST" >/dev/null || {
      echo "ca Codex plugin mirror is stale; run: bash ca/sync-codex-plugin.sh" >&2
      diff "${DIFF_OPTS[@]}" "$SOURCE" "$DEST" || true
      exit 1
    }
    echo "ca/sync-codex-plugin.sh: mirror is current"
    ;;
  sync)
    rm -rf "$DEST"
    mkdir -p "$(dirname "$DEST")"
    cp -R "$SOURCE" "$DEST"
    find "$DEST" -name __pycache__ -type d -prune -exec rm -rf {} + 2>/dev/null || true
    echo "ca/sync-codex-plugin.sh: refreshed $DEST"
    ;;
  *)
    echo "usage: ca/sync-codex-plugin.sh [--check]" >&2
    exit 2
    ;;
esac
