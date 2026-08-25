#!/usr/bin/env bash
set -euo pipefail

target="${1:?usage: resolve-target.sh <pr-or-branch-or-branch:name> [repo]}"
repo="${2:-$(git rev-parse --show-toplevel)}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
gh_bin="${GH_BIN:-gh}"

if [[ "$target" = branch:* ]]; then
    branch="${target#branch:}"
    base="$(bash "$script_dir/detect-base-branch.sh" "$repo")"
    expected=""
elif printf '%s' "$target" | grep -Eq '^[0-9]+$'; then
    row="$(cd "$repo" && "$gh_bin" pr view "$target" --json headRefName,baseRefName,headRefOid \
      --jq '[.headRefName, .baseRefName, .headRefOid] | @tsv')"
    IFS=$'\t' read -r branch base expected <<<"$row"
else
    branch="$target"
    base="$(bash "$script_dir/detect-base-branch.sh" "$repo")"
    expected=""
fi

git check-ref-format --branch "$branch" >/dev/null
git check-ref-format --branch "$base" >/dev/null
[ -z "$expected" ] || { [ "${#expected}" -eq 40 ] && ! printf '%s' "$expected" | grep -q '[^0-9a-f]'; } \
  || { echo "resolve-target: invalid PR head SHA" >&2; exit 1; }
printf 'BRANCH=%q\nBASE=%q\nEXPECTED_HEAD=%q\n' "$branch" "$base" "$expected"
