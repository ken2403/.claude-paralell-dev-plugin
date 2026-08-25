#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for test_file in "$root"/*-test.sh; do
  bash "$test_file"
done
echo "plugins/ha tests: ok"
