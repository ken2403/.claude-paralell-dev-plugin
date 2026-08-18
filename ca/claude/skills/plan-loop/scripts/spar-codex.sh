#!/usr/bin/env bash
# Send a prompt to Codex for an adversarial "sparring" critique and print its reply.
# Read-only sandbox (no edits), high reasoning. Override the binary with CODEX_BIN
# if `codex` is not on PATH (e.g. a version-manager shim).
#
# Usage: spar-codex.sh <prompt-file>
# Fails loudly (non-zero) with the captured stderr if Codex cannot run, rather than
# silently returning an empty critique.
set -euo pipefail
CODEX_BIN="${CODEX_BIN:-codex}"
TIMEOUT_SECONDS="${CA_CODEX_SPAR_TIMEOUT:-900}"
PROMPT_FILE="${1:?usage: spar-codex.sh <prompt-file>}"
[ -f "$PROMPT_FILE" ] || { echo "prompt file not found: $PROMPT_FILE" >&2; exit 1; }
case "$TIMEOUT_SECONDS" in ''|*[!0-9]*|0) echo "spar-codex: CA_CODEX_SPAR_TIMEOUT must be a positive integer" >&2; exit 2;; esac
command -v "$CODEX_BIN" >/dev/null 2>&1 || {
  echo "spar-codex: '$CODEX_BIN' not found on PATH. Set CODEX_BIN or install Codex." >&2; exit 1; }

TMP_SPAR="$(mktemp -d "${TMPDIR:-/tmp}/ca-spar-codex.XXXXXX")"
trap 'rm -rf "$TMP_SPAR"' EXIT
OUT="$TMP_SPAR/final.txt"
ERR="$TMP_SPAR/stderr.txt"

if ! python3 - "$CODEX_BIN" "$PROMPT_FILE" "$OUT" "$ERR" "$TIMEOUT_SECONDS" <<'PY'
import subprocess
import sys
from pathlib import Path

codex, prompt_path, out_path, err_path, timeout_s = sys.argv[1:]
prompt = Path(prompt_path).read_text(encoding="utf-8")
try:
    proc = subprocess.run(
        [
            codex,
            "exec",
            "--sandbox",
            "read-only",
            "-c",
            "approval_policy=never",
            "-c",
            "model_reasoning_effort=high",
            "--output-last-message",
            out_path,
            "-",
        ],
        input=prompt,
        text=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        timeout=int(timeout_s),
        check=False,
    )
except subprocess.TimeoutExpired as error:
    Path(err_path).write_text(f"timed out after {timeout_s}s\n{error}\n", encoding="utf-8")
    raise SystemExit(124)
Path(err_path).write_text(proc.stderr, encoding="utf-8")
raise SystemExit(proc.returncode)
PY
then
  echo "spar-codex: codex exec failed:" >&2
  cat "$ERR" >&2
  exit 1
fi
[ -s "$OUT" ] || { echo "spar-codex: codex returned no final message:" >&2; cat "$ERR" >&2; exit 1; }
cat "$OUT"
