#!/usr/bin/env bash
set -euo pipefail

plugin="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fail() { echo "structure-test: $*" >&2; exit 1; }

test -f "$plugin/.codex-plugin/plugin.json" || fail "missing manifest"
python3 -m json.tool "$plugin/.codex-plugin/plugin.json" >/dev/null
! grep -R -nE 'TODO|superpowers:|CLAUDE_SKILL|/ha:' "$plugin" --exclude='structure-test.sh' >/dev/null || fail "Claude-only dependency or placeholder remains"
! find "$plugin/skills" -name README.md -print -quit | grep -q . || fail "README inside skill"

while IFS= read -r skill; do
  dir="$(basename "$(dirname "$skill")")"
  name="$(awk '/^---$/ {fm++; next} fm==1 && /^name:/ {sub(/^name:[[:space:]]*/,""); print; exit}' "$skill")"
  test "$name" = "$dir" || fail "$skill name mismatch"
  lines="$(awk 'BEGIN{fm=0;n=0} /^---$/{fm++;next} fm>=2{n++} END{print n}' "$skill")"
  test "$lines" -le 500 || fail "$skill exceeds 500 body lines"
done < <(find "$plugin/skills" -name SKILL.md | sort)

for skill in ha-plan ha-implement ha-review-pr ha-apply-feedback ha-merge-pr ha-resolve-conflicts ha-clean-worktrees; do
  grep -q 'allow_implicit_invocation: false' "$plugin/skills/$skill/agents/openai.yaml" || fail "$skill must require explicit invocation"
done
for skill in ha-code-review ha-adversarial-verification; do
  grep -q 'allow_implicit_invocation: true' "$plugin/skills/$skill/agents/openai.yaml" || fail "$skill standards should be implicitly available"
done

while IFS= read -r script; do bash -n "$script"; done < <(find "$plugin" -name '*.sh' | sort)
while IFS= read -r py; do python3 -m py_compile "$py"; done < <(find "$plugin" -name '*.py' | sort)
echo "structure-test.sh: ok"
