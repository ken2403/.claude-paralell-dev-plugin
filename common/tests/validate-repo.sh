#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
PYTHONPYCACHEPREFIX="$(mktemp -d "${TMPDIR:-/tmp}/validate-pycache.XXXXXX")"
export PYTHONPYCACHEPREFIX
trap 'rm -rf "$PYTHONPYCACHEPREFIX"' EXIT

fail() {
  echo "validate-repo: $*" >&2
  exit 1
}

echo "== generated files =="
bash common/sync.sh --check
bash ca/sync-codex-plugin.sh --check
bash common/tests/run.sh

echo "== plugin validation =="
CLAUDE_BIN="${CLAUDE_BIN:-claude}"
if command -v "$CLAUDE_BIN" >/dev/null 2>&1; then
  "$CLAUDE_BIN" plugin validate ./ha
  "$CLAUDE_BIN" plugin validate ./sa
  "$CLAUDE_BIN" plugin validate ./ca/claude
else
  if [ "${ALLOW_MISSING_CLAUDE_VALIDATE:-0}" = "1" ]; then
    echo "::warning::Claude CLI not available; skipping 'claude plugin validate' in this environment."
    echo "Plugin validation was not silently treated as run. Install Claude Code and run:"
    echo "  claude plugin validate ./ha"
    echo "  claude plugin validate ./sa"
    echo "  claude plugin validate ./ca/claude"
  else
    fail "claude CLI is required for plugin validation; set ALLOW_MISSING_CLAUDE_VALIDATE=1 only in CI environments that intentionally degrade this check"
  fi
fi

python3 -c 'import json; d=json.load(open(".agents/plugins/marketplace.json")); got={p["name"]:p["source"]["path"] for p in d["plugins"]}; expected={"ca":"./plugins/ca","ha":"./plugins/ha"}; assert all(got.get(k)==v for k,v in expected.items()), (got,expected)' \
  || fail "Codex marketplace must map ca and ha to their package directories"

echo "== manifests =="
python3 -m json.tool .claude-plugin/marketplace.json >/dev/null
python3 -m json.tool .agents/plugins/marketplace.json >/dev/null
for plugin in ha sa ca/claude ca/codex plugins/ca plugins/ha; do
  manifest="$plugin/.claude-plugin/plugin.json"
  [ -f "$manifest" ] || manifest="$plugin/.codex-plugin/plugin.json"
  [ -f "$manifest" ] || fail "missing plugin manifest for $plugin"
  python3 -m json.tool "$manifest" >/dev/null
done
[ ! -e common/.claude-plugin ] || fail "common/ must not be a Claude plugin"
[ ! -e common/.codex-plugin ] || fail "common/ must not be a Codex plugin"
[ ! -e common/plugin.json ] || fail "common/ must not be a plugin"

echo "== syntax =="
while IFS= read -r sh_file; do
  bash -n "$sh_file"
done < <(find ha sa ca common plugins -type f -name '*.sh' | sort)
while IFS= read -r py_file; do
  python3 -m py_compile "$py_file"
done < <(find ha sa ca common plugins -type f -name '*.py' | sort)

echo "== Codex plugin and skill validation =="
python3 common/tests/validate-codex.py plugins/ca plugins/ha
CODEX_PLUGIN_VALIDATOR="${CODEX_PLUGIN_VALIDATOR:-$HOME/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py}"
CODEX_SKILL_VALIDATOR="${CODEX_SKILL_VALIDATOR:-$HOME/.codex/skills/.system/skill-creator/scripts/quick_validate.py}"
if python3 -c 'import yaml' >/dev/null 2>&1 && [ -f "$CODEX_PLUGIN_VALIDATOR" ] && [ -f "$CODEX_SKILL_VALIDATOR" ]; then
  python3 "$CODEX_PLUGIN_VALIDATOR" plugins/ca
  python3 "$CODEX_PLUGIN_VALIDATOR" plugins/ha
  python3 "$CODEX_SKILL_VALIDATOR" ca/codex/skills/ca-implement-plan
  while IFS= read -r skill; do
    python3 "$CODEX_SKILL_VALIDATOR" "$skill"
  done < <(find plugins/ha/skills -mindepth 1 -maxdepth 1 -type d | sort)
else
  echo "::warning::Optional Codex system validators unavailable; checked-in Codex validation still ran."
fi

echo "== ca contract copies =="
# STAR, never a chain: every copy is compared against the one master. Pairwise chains let a
# copy drift as long as its own partner drifts with it, and a newly added copy joins nothing.
CONTRACT_MASTER=ca/claude/skills/review-pr/references/review-contract.md
[ -f "$CONTRACT_MASTER" ] || fail "missing review-contract.md master"
while IFS= read -r copy; do
  cmp -s "$CONTRACT_MASTER" "$copy" \
    || fail "review-contract.md copy $copy must be byte-identical to $CONTRACT_MASTER"
done < <(find ca -name review-contract.md -type f | sort)

VALIDATOR_MASTER=ca/claude/skills/review-pr/scripts/validate-review.py
[ -f "$VALIDATOR_MASTER" ] || fail "missing validate-review.py master"
while IFS= read -r copy; do
  cmp -s "$VALIDATOR_MASTER" "$copy" \
    || fail "validate-review.py copy $copy must be byte-identical to $VALIDATOR_MASTER"
done < <(find ca -name validate-review.py -type f | sort)

echo "== ca dual-review script copies =="
for f in codex-review.sh codex-review-schema.json claude-review.sh synthesize-review.sh dual-review.sh; do
  cmp -s "ca/codex/skills/ca-implement-plan/scripts/$f" \
    "ca/claude/skills/dual-review/scripts/$f" \
    || fail "dual-review copy of $f must be byte-identical to the ca/codex master"
done
cmp -s ca/codex/skills/ca-implement-plan/scripts/new-worktree.sh \
  ca/claude/skills/implement/scripts/new-worktree.sh \
  || fail "ca new-worktree.sh copies must be byte-identical"

echo "== ca loop harness agrees with the skill =="
# The E2E harness necessarily RE-IMPLEMENTS the loop the $ca-implement-plan skill describes in
# prose, so it can drift from it silently. Pin the decisions that actually gate behaviour: if
# either side changes one of these, the other has to change with it.
CA_SKILL=ca/codex/skills/ca-implement-plan/SKILL.md
CA_HARNESS=ca/tests/support/run-loop-e2e.sh
while IFS= read -r line; do
  grep -qF -- "$line" "$CA_SKILL" \
    || fail "harness/skill drift: $CA_SKILL no longer contains: $line"
  grep -qF -- "$line" "$CA_HARNESS" \
    || fail "harness/skill drift: $CA_HARNESS no longer contains: $line"
done <<'PINNED'
[ "${CA_DUAL_REVIEW:-1}" = "0" ] && CLAUDE_ONLY="--claude-only"
pr create --draft --base
--mode checkpoint --round
PINNED

echo "== ca script tests =="
while IFS= read -r test_file; do
  bash "$test_file"
done < <(find ca -path '*/tests/*-test.sh' -type f | sort)

echo "== Codex ha script tests =="
bash plugins/ha/tests/run.sh

echo "== clean-worktrees behavior =="
bash common/tests/clean-worktrees-test.sh

echo "== skill and agent identity =="
while IFS= read -r skill; do
  dir="$(basename "$(dirname "$skill")")"
  name="$(awk '/^---$/ { fm++; next } fm == 1 && /^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }' "$skill")"
  [ "$name" = "$dir" ] || fail "$skill has name '$name', expected '$dir'"
done < <(find ha/skills sa/skills ca/claude/skills ca/codex/skills plugins/ca/skills plugins/ha/skills -name SKILL.md | sort)

while IFS= read -r agent; do
  file="$(basename "$agent" .md)"
  name="$(awk '/^name:/ { sub(/^name:[[:space:]]*/, ""); print; exit }' "$agent")"
  [ "$name" = "$file" ] || fail "$agent has name '$name', expected '$file'"
done < <(find ha/agents sa/agents -name '*.md' | sort)

echo "== skill body length =="
while IFS= read -r skill; do
  body_lines="$(awk 'BEGIN { fm=0; body=0 } /^---$/ { fm++; next } fm >= 2 { body++ } END { print body }' "$skill")"
  [ "$body_lines" -le 500 ] || fail "$skill body has $body_lines lines; keep it <= 500"
done < <(find ha/skills sa/skills ca/claude/skills ca/codex/skills plugins/ca/skills plugins/ha/skills -name SKILL.md | sort)

echo "== ca skill packaging rules =="
[ ! -e ca/codex/skills/ca-implement-plan/README.md ] || fail "README.md is not allowed inside a skill"
[ ! -e plugins/ca/skills/ca-implement-plan/README.md ] || fail "README.md is not allowed inside a skill"
grep -q '^  allow_implicit_invocation: false$' ca/codex/skills/ca-implement-plan/agents/openai.yaml \
  || fail "side-effecting Codex skill must disable implicit invocation"
if sed -n '1,/^---$/p' ca/codex/skills/ca-implement-plan/SKILL.md | grep -Eq '^(model|effort|disable-model-invocation):'; then
  fail "Codex skill frontmatter contains Claude-only control fields"
fi

echo "== generated modes and symlinks =="
[ -L CLAUDE.md ] || fail "CLAUDE.md must remain a symlink to AGENTS.md"
[ "$(readlink CLAUDE.md)" = "AGENTS.md" ] || fail "CLAUDE.md must point to AGENTS.md"
while IFS=$'\t' read -r class _src dest; do
  [ -z "${class:-}" ] && continue
  case "$class" in \#*) continue ;; esac
  mode="$(git ls-files -s -- "$dest" | awk '{print $1}')"
  [ -n "$mode" ] || fail "$dest is not tracked"
  [ "$mode" != "120000" ] || fail "$dest must not be a symlink"
  case "$class" in
    script) [ "$mode" = "100755" ] || fail "$dest mode is $mode; expected 100755" ;;
    reference|skill) [ "$mode" = "100644" ] || fail "$dest mode is $mode; expected 100644" ;;
    *) fail "unknown manifest class '$class'" ;;
  esac
done < common/manifest.tsv

echo "validate-repo: ok"
