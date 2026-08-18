#!/usr/bin/env python3
"""A hermetic `gh` stand-in for the ca loop end-to-end tests.

Backed by a REAL local bare repository, so `pr diff` is a real git diff of real
pushed commits and `pr create`/`pr ready` move real state. Only the GitHub API is
simulated; git, the ca scripts, and the models under test are the real thing.

State lives in $CA_GH_SIM_STATE (JSON); the bare remote is $CA_GH_SIM_REMOTE.
Supported: auth status | pr create | pr view | pr diff | pr ready | pr comment |
pr checks | pr list. `pr merge` is deliberately refused: the loop's E2E stops at
promotion, and nothing in a test should be able to merge.
"""

from __future__ import annotations

import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        print(f"gh-sim: {name} must be set (it is a test double, not a real gh)", file=sys.stderr)
        raise SystemExit(2)
    return value


STATE = Path(_require_env("CA_GH_SIM_STATE"))
REMOTE = _require_env("CA_GH_SIM_REMOTE")


def die(msg: str, code: int = 1) -> None:
    print(f"gh-sim: {msg}", file=sys.stderr)
    raise SystemExit(code)


def load() -> dict:
    if STATE.exists():
        return json.loads(STATE.read_text(encoding="utf-8"))
    return {"prs": []}


def save(state: dict) -> None:
    STATE.write_text(json.dumps(state, indent=2, sort_keys=True), encoding="utf-8")


def git(*args: str) -> str:
    proc = subprocess.run(["git", "-C", REMOTE, *args], capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"git {' '.join(args)} failed: {proc.stderr.strip()}", 1)
    return proc.stdout


def current_branch() -> str:
    proc = subprocess.run(
        ["git", "rev-parse", "--abbrev-ref", "HEAD"], capture_output=True, text=True
    )
    return proc.stdout.strip() if proc.returncode == 0 else ""


def find_pr(state: dict, selector: str | None):
    prs = state["prs"]
    if not selector:
        selector = current_branch()
    if not selector:
        return None
    if selector.isdigit():
        return next((p for p in prs if p["number"] == int(selector)), None)
    # branch selector: prefer an OPEN pr, exactly like gh does
    matches = [p for p in prs if p["headRefName"] == selector]
    return next((p for p in matches if p["state"] == "OPEN"), matches[0] if matches else None)


def diff_text(pr: dict, name_only: bool = False) -> str:
    base, head = pr["baseRefName"], pr["headRefName"]
    args = ["diff", f"{base}...{head}"]
    if name_only:
        args.insert(1, "--name-only")
    return git(*args)


def file_stats(pr: dict) -> list[dict]:
    out = git("diff", "--numstat", f"{pr['baseRefName']}...{pr['headRefName']}")
    files = []
    for line in out.splitlines():
        parts = line.split("\t")
        if len(parts) != 3:
            continue
        added, deleted, path = parts
        files.append(
            {
                "path": path,
                "additions": int(added) if added.isdigit() else 0,
                "deletions": int(deleted) if deleted.isdigit() else 0,
            }
        )
    return files


def project(pr: dict, fields: list[str]) -> dict:
    out = {}
    for f in fields:
        if f == "files":
            out[f] = file_stats(pr)
        elif f == "headRefOid":
            out[f] = git("rev-parse", pr["headRefName"]).strip()
        elif f == "statusCheckRollup":
            out[f] = []
        elif f == "mergeable":
            out[f] = "MERGEABLE"
        elif f == "mergeStateStatus":
            out[f] = "CLEAN"
        elif f == "reviewDecision":
            out[f] = pr.get("reviewDecision", "")
        elif f == "mergedAt":
            out[f] = pr.get("mergedAt")
        else:
            if f not in pr:
                die(f"unsupported --json field: {f}", 2)
            out[f] = pr[f]
    return out


def _render(value) -> str:
    if isinstance(value, bool):
        return "true" if value else "false"
    if value is None:
        return "null"
    if isinstance(value, (dict, list)):
        return json.dumps(value)
    return str(value)


def emit(payload, jq_expr: str | None) -> None:
    text = json.dumps(payload)
    if not jq_expr:
        print(text)
        return
    # The ca scripts only ever use a handful of shapes; handling them natively keeps this
    # test double runnable on a machine (or CI image) without jq installed.
    expr = jq_expr.strip()
    match = re.fullmatch(r"\.([A-Za-z_][A-Za-z0-9_]*)", expr)
    if match and isinstance(payload, dict):
        print(_render(payload.get(match.group(1))))
        return
    match = re.fullmatch(r"\.\[\]\.([A-Za-z_][A-Za-z0-9_]*)", expr)
    if match and isinstance(payload, list):
        for item in payload:
            print(_render(item.get(match.group(1))))
        return
    match = re.fullmatch(r"\.\[([0-9]+)\]\.([A-Za-z_][A-Za-z0-9_]*)", expr)
    if match and isinstance(payload, list):
        index = int(match.group(1))
        if index < len(payload):
            print(_render(payload[index].get(match.group(2))))
        return
    if shutil.which("jq") is None:
        die(f"unsupported --jq expression for the built-in evaluator and jq is not installed: {expr}", 2)
    proc = subprocess.run(["jq", "-r", expr], input=text, capture_output=True, text=True)
    if proc.returncode != 0:
        die(f"jq failed: {proc.stderr.strip()}", 1)
    sys.stdout.write(proc.stdout)


def take(args: list[str], flag: str) -> str | None:
    if flag in args:
        i = args.index(flag)
        if i + 1 >= len(args):
            die(f"{flag} needs a value", 2)
        value = args[i + 1]
        del args[i : i + 2]
        return value
    return None


def main() -> None:
    argv = sys.argv[1:]
    if not argv:
        die("no command", 2)
    state = load()

    if argv[0] == "auth":
        print("github.com\n  ✓ Logged in to github.com as ca-e2e (gh-sim)")
        return

    if argv[0] != "pr":
        die(f"unsupported command: {argv[0]}", 2)

    sub, rest = argv[1], argv[2:]

    if sub == "create":
        base = take(rest, "--base") or "main"
        head = take(rest, "--head") or current_branch()
        title = take(rest, "--title") or head
        body_file = take(rest, "--body-file")
        body = Path(body_file).read_text(encoding="utf-8") if body_file else (take(rest, "--body") or "")
        draft = "--draft" in rest
        if any(p["headRefName"] == head and p["state"] == "OPEN" for p in state["prs"]):
            die(f"a pull request for branch {head} already exists", 1)
        number = max((p["number"] for p in state["prs"]), default=0) + 1
        pr = {
            "number": number,
            "title": title,
            "body": body,
            "state": "OPEN",
            "isDraft": draft,
            "baseRefName": base,
            "headRefName": head,
            "url": f"https://gh-sim.invalid/ca/e2e/pull/{number}",
            "comments": [],
            "mergedAt": None,
        }
        state["prs"].append(pr)
        save(state)
        print(pr["url"])
        return

    selector = rest[0] if rest and not rest[0].startswith("-") else None
    if selector:
        rest = rest[1:]
    pr = find_pr(state, selector)

    if sub == "view":
        if pr is None:
            die("no pull requests found for the given selector", 1)
        jq_expr = take(rest, "--jq")
        fields = take(rest, "--json")
        if fields is None:
            print(f"#{pr['number']} {pr['title']}\nstate:\t{pr['state']}\ndraft:\t{pr['isDraft']}")
            return
        emit(project(pr, fields.split(",")), jq_expr)
        return

    if sub == "diff":
        if pr is None:
            die("no pull requests found for the given selector", 1)
        sys.stdout.write(diff_text(pr, name_only="--name-only" in rest))
        return

    if sub == "ready":
        if pr is None:
            die("no pull requests found for the given selector", 1)
        pr["isDraft"] = False
        save(state)
        print(f"✓ Pull request #{pr['number']} is marked as ready for review")
        return

    if sub == "comment":
        if pr is None:
            die("no pull requests found for the given selector", 1)
        body_file = take(rest, "--body-file")
        body = Path(body_file).read_text(encoding="utf-8") if body_file else (take(rest, "--body") or "")
        pr["comments"].append(body)
        save(state)
        print(f"{pr['url']}#issuecomment-{len(pr['comments'])}")
        return

    if sub == "checks":
        return  # exit 0: no checks configured in the simulated repo

    if sub == "list":
        jq_expr = take(rest, "--jq")
        take(rest, "--json")
        emit([p for p in state["prs"] if p["state"] == "OPEN"], jq_expr)
        return

    if sub == "merge":
        die("gh-sim refuses `pr merge`: the E2E must never merge anything", 2)

    die(f"unsupported: pr {sub}", 2)


if __name__ == "__main__":
    main()
