#!/usr/bin/env bash
# Run an offline Codex second-opinion review for a ca final review round.
#
# The host fetches PR inputs with gh, builds a bounded prompt, then runs:
#   codex exec --sandbox read-only --output-schema <schema> -
# Codex receives no network or gh access. Its output is advisory only and must be
# synthesized by Claude before it can affect the loop gate.
set -euo pipefail

CODEX_BIN="${CODEX_BIN:-codex}"
GH_BIN="${GH_BIN:-gh}"
TIMEOUT_SECONDS="${CA_CODEX_REVIEW_TIMEOUT:-900}"
REASONING_EFFORT="${CA_CODEX_REVIEW_REASONING_EFFORT:-medium}"
FULL_DIFF_BYTES="${CA_CODEX_REVIEW_FULL_DIFF_BYTES:-180000}"
FALLBACK_PROMPT_BYTES="${CA_CODEX_REVIEW_FALLBACK_PROMPT_BYTES:-360000}"

PLAN="" PR="" WT="" ROUND="" OUT="" DRY_RUN=0
while [ $# -gt 0 ]; do
  case "$1" in
    --plan) PLAN="$2"; shift 2;;
    --pr) PR="$2"; shift 2;;
    --worktree) WT="$2"; shift 2;;
    --round) ROUND="$2"; shift 2;;
    --out) OUT="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    *) echo "codex-review: unknown arg: $1" >&2; exit 2;;
  esac
done

[ -n "$PLAN" ] && [ -n "$PR" ] && [ -n "$WT" ] && [ -n "$ROUND" ] && [ -n "$OUT" ] || {
  echo "usage: codex-review.sh --plan P --pr N --worktree W --round N --out O [--dry-run]" >&2
  exit 2
}
[ -f "$PLAN" ] || { echo "codex-review: plan not found: $PLAN" >&2; exit 4; }
[ -d "$WT" ] || { echo "codex-review: worktree not found: $WT" >&2; exit 4; }
WT="$(cd "$WT" && pwd)"
case "$REASONING_EFFORT" in
  none|low|medium|high|xhigh|max) ;;
  *) echo "codex-review: CA_CODEX_REVIEW_REASONING_EFFORT must be none, low, medium, high, xhigh, or max" >&2; exit 2;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCHEMA="$SCRIPT_DIR/codex-review-schema.json"
[ -f "$SCHEMA" ] || { echo "codex-review: schema not found: $SCHEMA" >&2; exit 3; }

command -v "$GH_BIN" >/dev/null 2>&1 || {
  echo "codex-review: '$GH_BIN' not found on PATH. Set GH_BIN or install gh." >&2
  exit 4
}
if [ "$DRY_RUN" -eq 0 ]; then
  command -v "$CODEX_BIN" >/dev/null 2>&1 || {
    echo "codex-review: '$CODEX_BIN' not found on PATH. Set CODEX_BIN or install Codex." >&2
    exit 3
  }
fi

mkdir -p "$(dirname "$OUT")"
rm -f "$OUT"
TMPDIR_REVIEW="$(mktemp -d "${TMPDIR:-/tmp}/ca-codex-review.XXXXXX")"
trap 'rm -rf "$TMPDIR_REVIEW"' EXIT

META="$TMPDIR_REVIEW/pr-view.json"
DIFF="$TMPDIR_REVIEW/pr.diff"
NAMES="$TMPDIR_REVIEW/pr.names"
STAT="$TMPDIR_REVIEW/pr.stat"
PROMPT="$TMPDIR_REVIEW/prompt.md"
RAW="$TMPDIR_REVIEW/codex.raw.json"
COVERAGE_EXPECTED="$TMPDIR_REVIEW/coverage.expected"
ERR="${OUT%.json}.codex.stderr"

if ! "$GH_BIN" pr view "$PR" --json number,title,state,isDraft,baseRefName,headRefName,url > "$META"; then
  echo "codex-review: failed to fetch PR metadata for $PR" >&2
  exit 4
fi
if ! "$GH_BIN" pr diff "$PR" > "$DIFF"; then
  echo "codex-review: failed to fetch PR diff for $PR" >&2
  exit 4
fi
if ! "$GH_BIN" pr diff "$PR" --name-only > "$NAMES"; then
  echo "codex-review: failed to fetch PR file list for $PR" >&2
  exit 4
fi
python3 - "$DIFF" > "$STAT" <<'PY'
import re
import sys
from pathlib import Path

diff = Path(sys.argv[1]).read_text(encoding="utf-8", errors="replace")
files = {}
current = None
for line in diff.splitlines():
    if line.startswith("diff --git "):
        parts = line.split()
        current = parts[3][2:] if len(parts) >= 4 and parts[3].startswith("b/") else line
        files.setdefault(current, [0, 0])
    elif current and line.startswith("+") and not line.startswith("+++"):
        files[current][0] += 1
    elif current and line.startswith("-") and not line.startswith("---"):
        files[current][1] += 1
for path, (added, deleted) in files.items():
    print(f"{path} | +{added} -{deleted}")
print(f"{len(files)} files changed")
PY

set +e
python3 - "$PLAN" "$META" "$DIFF" "$NAMES" "$STAT" "$ROUND" "$FULL_DIFF_BYTES" "$FALLBACK_PROMPT_BYTES" "$WT" "$COVERAGE_EXPECTED" > "$PROMPT" <<'PY'
import json
import re
import sys
from pathlib import Path

plan_path, meta_path, diff_path, names_path, stat_path, round_s, full_s, fallback_s, wt, coverage_path = sys.argv[1:]
plan = Path(plan_path).read_text(encoding="utf-8", errors="replace")
meta = json.loads(Path(meta_path).read_text(encoding="utf-8"))
diff = Path(diff_path).read_text(encoding="utf-8", errors="replace")
names = Path(names_path).read_text(encoding="utf-8", errors="replace")
stat = Path(stat_path).read_text(encoding="utf-8", errors="replace")
full_limit = int(full_s)
fallback_limit = int(fallback_s)

risky = re.compile(
    r"(auth|authori[sz]e|session|token|crypto|secret|bill|payment|invoice|"
    r"upload|multipart|migration|delete|permission|sql|shell|subprocess|"
    r"http|route|handler|deserialize|parse)",
    re.IGNORECASE,
)

def split_file_diffs(text):
    sections = []
    cur = []
    current_path = ""
    for line in text.splitlines():
        if line.startswith("diff --git "):
            if cur:
                sections.append((current_path, "\n".join(cur) + "\n"))
            cur = [line]
            parts = line.split()
            current_path = parts[3][2:] if len(parts) >= 4 and parts[3].startswith("b/") else line
        else:
            cur.append(line)
    if cur:
        sections.append((current_path, "\n".join(cur) + "\n"))
    return sections

diff_bytes = len(diff.encode("utf-8"))
coverage = "full"
diff_section = diff
policy_note = f"Coverage: full; full PR diff included ({diff_bytes} bytes)."
if diff_bytes > full_limit:
    coverage = "partial"
    risky_sections = [section for path, section in split_file_diffs(diff) if risky.search(path)]
    risky_text = "".join(risky_sections).strip()
    diff_section = (
        "Full diff omitted by oversized-diff policy.\n"
        f"Full diff bytes: {diff_bytes}; full threshold: {full_limit}.\n\n"
        "Changed files:\n"
        f"{names.strip() or '(none from gh --name-only)'}\n\n"
        "Diff stat:\n"
        f"{stat.strip() or '(none from gh --stat)'}\n\n"
        "Risky-surface full diffs included below when detected from the canonical list "
        "(auth/session/token, crypto/secrets, money/billing, external-input parsing, "
        "migration/deletion, permissions, SQL/shell construction):\n"
        f"{risky_text or '(no risky-surface file sections detected; Codex silence is not reassuring for omitted files)'}\n"
    )
    policy_note = (
        "Coverage: partial; full diff omitted by deterministic oversized-diff policy. "
        "Review only the included risky-surface sections, file list, and stats."
    )
    if len(diff_section.encode("utf-8")) > fallback_limit:
        print("oversized_diff: fallback prompt exceeds CA_CODEX_REVIEW_FALLBACK_PROMPT_BYTES", file=sys.stderr)
        sys.exit(3)

prompt = f"""**REQUIRED SKILL:** Use $ca-second-opinion.

You are Codex performing the bounded advisory second-opinion review for the ca loop.

This is one single-agent pass. Do not spawn subagents or invoke repository-specific PR-review,
audit, or adversarial-review workflows. The process also disables multi-agent tools and runs from
an isolated temporary root so the reviewed repository's skills cannot be selected implicitly.
Use the reviewed worktree only through absolute paths or `git -C`; read the governing AGENTS.md
files, but do not read `.agents/skills`.

Return exactly one JSON object matching schema ca_codex_review.v1. Do not include Markdown.
There is deliberately no verdict field; your findings never gate the PR directly.
Finding ids must be X001, X002, ... and each finding must include blocking, severity,
file, line, title, evidence, and recommended_fix. Use null for file/line when not known.
Use blocking:true only for must-fix issues.

This is an INDEPENDENT second opinion. Judge from the plan and diff below plus the code in the
worktree. Do not read review artifacts under .ca/runs or .ca/reviews — those are other reviewers'
verdicts from this or an earlier round, and reading them turns a second opinion into an echo.

Round: {round_s}
Reviewed worktree: {wt}
PR metadata:
```json
{json.dumps(meta, indent=2, sort_keys=True)}
```

{policy_note}
Required `coverage` field in your JSON response: "{coverage}".

Implementation plan:
```markdown
{plan}
```

PR diff context:
```diff
{diff_section}
```
"""
Path(coverage_path).write_text(coverage, encoding="utf-8")
print(prompt)
PY
prompt_status=$?
set -e
if [ "$prompt_status" -ne 0 ]; then
  if [ "$prompt_status" -eq 3 ]; then
    echo "codex-review: oversized_diff; fallback prompt could not cover the change meaningfully" >&2
    exit 3
  fi
  echo "codex-review: failed to build prompt" >&2
  exit 4
fi

if [ "$DRY_RUN" -eq 1 ]; then
  cat "$PROMPT"
  exit 0
fi

rm -f "$RAW" "$ERR"
set +e
python3 - "$CODEX_BIN" "$SCHEMA" "$PROMPT" "$RAW" "$ERR" "$TIMEOUT_SECONDS" "$REASONING_EFFORT" <<'PY'
import subprocess
import sys
from pathlib import Path

codex, schema, prompt_path, raw_path, err_path, timeout_s, reasoning_effort = sys.argv[1:]
prompt = Path(prompt_path).read_text(encoding="utf-8")
isolated_root = str(Path(prompt_path).parent)


def output_text(value):
    if value is None:
        return ""
    if isinstance(value, bytes):
        return value.decode("utf-8", errors="replace")
    return value


try:
    proc = subprocess.run(
        [
            codex,
            "exec",
            "-C",
            isolated_root,
            "--skip-git-repo-check",
            "--disable",
            "multi_agent",
            "-c",
            f'model_reasoning_effort="{reasoning_effort}"',
            "--sandbox",
            "read-only",
            "--output-schema",
            schema,
            "-",
        ],
        input=prompt,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=isolated_root,
        timeout=int(timeout_s),
        check=False,
    )
except subprocess.TimeoutExpired as e:
    stdout = output_text(e.stdout)
    stderr = output_text(e.stderr)
    Path(raw_path).write_text(stdout, encoding="utf-8")
    Path(err_path).write_text(
        f"codex exec timed out after {timeout_s}s\n{e}\n"
        f"--- partial codex stderr ---\n{stderr}",
        encoding="utf-8",
    )
    sys.exit(124)
Path(raw_path).write_text(proc.stdout, encoding="utf-8")
Path(err_path).write_text(proc.stderr, encoding="utf-8")
sys.exit(proc.returncode)
PY
codex_status=$?
set -e
if [ "$codex_status" -ne 0 ]; then
  {
    echo "codex-review: codex exec failed; stderr: $ERR"
    if [ -s "$ERR" ]; then
      echo "--- codex stderr tail ---"
      tail -40 "$ERR"
      echo "--- end stderr tail ---"
    fi
  } >&2
  [ "$codex_status" -eq 124 ] && exit 124
  exit 3
fi

[ -s "$RAW" ] || {
  echo "codex-review: codex produced no output file/content" >&2
  exit 3
}

if ! python3 - "$RAW" "$OUT" "$COVERAGE_EXPECTED" <<'PY'
import json
import re
import sys

raw_path, out_path, coverage_path = sys.argv[1:]
expected_coverage = open(coverage_path, encoding="utf-8").read().strip()
ALLOWED_TOP = {"schema_version", "summary", "coverage", "findings"}
ALLOWED_FINDING = {"id", "blocking", "severity", "file", "line", "title", "evidence", "recommended_fix"}
SEVERITIES = {"blocker", "major", "minor"}

def fail(msg):
    print(f"codex review invalid: {msg}", file=sys.stderr)
    sys.exit(1)

try:
    data = json.load(open(raw_path, encoding="utf-8"))
except Exception as e:
    fail(f"parse error: {e}")
if not isinstance(data, dict):
    fail("top level must be an object")
extra = set(data) - ALLOWED_TOP
if extra:
    fail(f"unknown top-level keys: {sorted(extra)}")
if data.get("schema_version") != "ca_codex_review.v1":
    fail("schema_version must be ca_codex_review.v1")
if not isinstance(data.get("summary"), str) or len(data["summary"]) > 2000:
    fail("summary must be a string up to 2000 chars")
if data.get("coverage") not in {"full", "partial"}:
    fail("coverage must be full or partial")
if data.get("coverage") != expected_coverage:
    fail(f"coverage must be {expected_coverage} for this prompt")
findings = data.get("findings")
if not isinstance(findings, list) or len(findings) > 50:
    fail("findings must be a list of at most 50 items")
for i, finding in enumerate(findings):
    if not isinstance(finding, dict):
        fail(f"findings[{i}] must be an object")
    extra = set(finding) - ALLOWED_FINDING
    if extra:
        fail(f"findings[{i}] unknown keys: {sorted(extra)}")
    for key in ("id", "blocking", "severity", "file", "line", "title", "evidence", "recommended_fix"):
        if key not in finding:
            fail(f"findings[{i}].{key} is required")
    if not re.match(r"^X[0-9]{3}$", finding["id"]):
        fail(f"findings[{i}].id must match XNNN")
    if not isinstance(finding["blocking"], bool):
        fail(f"findings[{i}].blocking must be boolean")
    if finding["severity"] not in SEVERITIES:
        fail(f"findings[{i}].severity must be one of {sorted(SEVERITIES)}")
    for key, max_len in (("title", 200), ("evidence", 4000), ("recommended_fix", 2000)):
        if not isinstance(finding[key], str) or len(finding[key]) > max_len:
            fail(f"findings[{i}].{key} must be a bounded string")
    if finding["file"] is not None and (
        not isinstance(finding["file"], str) or len(finding["file"]) > 500
    ):
        fail(f"findings[{i}].file must be null or a bounded string")
    if finding["line"] is not None and (
        not isinstance(finding["line"], int)
        or isinstance(finding["line"], bool)
        or finding["line"] < 1
    ):
        fail(f"findings[{i}].line must be null or a positive integer")
json.dump(data, open(out_path, "w", encoding="utf-8"), indent=2, sort_keys=True)
open(out_path, "a", encoding="utf-8").write("\n")
print(data["coverage"])
PY
then
  echo "codex-review: output failed schema validation" >&2
  exit 1
fi
