#!/usr/bin/env bash
set -euo pipefail

root="${1:?usage: run-checks.sh <worktree>}"
[ -d "$root" ] || { echo "run-checks: not a directory: $root" >&2; exit 2; }
cd "$root"

if [ -f Makefile ] && grep -qE '^(check|test|ci):' Makefile; then
  if grep -qE '^check:' Makefile; then exec make check; fi
  if grep -qE '^test:' Makefile; then exec make test; fi
  exec make ci
elif [ -f package.json ]; then
  if [ -f pnpm-lock.yaml ]; then exec pnpm test; fi
  if [ -f yarn.lock ]; then exec yarn test; fi
  exec npm test
elif [ -f pyproject.toml ] || [ -f pytest.ini ] || [ -d tests ]; then
  if command -v uv >/dev/null 2>&1 && [ -f pyproject.toml ]; then exec uv run pytest; fi
  exec pytest
elif [ -f go.mod ]; then
  exec go test ./...
elif [ -f Cargo.toml ]; then
  exec cargo test
elif [ "${HA_ALLOW_NO_STANDARD_CHECK:-0}" = 1 ]; then
  echo "run-checks: no standard check found; caller accepted plan-specific verification"
  exit 0
else
  echo "run-checks: no standard check found; run plan-specific checks or set HA_ALLOW_NO_STANDARD_CHECK=1 after documenting them" >&2
  exit 2
fi
