#!/usr/bin/env python3
"""Validate and optionally record a SHA-bound HA Codex PR review."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT_KEYS = {
    "schema_version", "pr", "head_sha", "verdict", "summary", "findings", "verification"
}
FINDING_KEYS = {
    "id", "blocking", "severity", "file", "line", "title", "evidence", "recommended_fix"
}
VERIFY_KEYS = {"claim", "result", "evidence"}
SHA_RE = re.compile(r"^[0-9a-f]{40}$")
ID_RE = re.compile(r"^H[0-9]{3}$")


def fail(message: str) -> None:
    raise ValueError(message)


def nonempty(value: object, label: str, limit: int = 8000) -> str:
    if not isinstance(value, str) or not value.strip():
        fail(f"{label} must be a non-empty string")
    if len(value) > limit:
        fail(f"{label} exceeds {limit} characters")
    return value


def live_head(pr: int) -> str:
    gh = os.environ.get("GH_BIN", "gh")
    proc = subprocess.run(
        [gh, "pr", "view", str(pr), "--json", "headRefOid", "--jq", ".headRefOid"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if proc.returncode != 0:
        fail(f"cannot read live PR head: {proc.stderr.strip() or 'gh failed'}")
    head = proc.stdout.strip()
    if not SHA_RE.fullmatch(head):
        fail("live PR head is not a 40-character lowercase SHA")
    return head


def validate(data: object, expected_pr: int | None) -> dict:
    if not isinstance(data, dict):
        fail("review root must be an object")
    if set(data) != ROOT_KEYS:
        fail(f"root keys must be exactly {sorted(ROOT_KEYS)}")
    if data["schema_version"] != "ha_codex_review.v1":
        fail("schema_version must be ha_codex_review.v1")
    if type(data["pr"]) is not int or data["pr"] < 1:
        fail("pr must be a positive integer")
    if expected_pr is not None and data["pr"] != expected_pr:
        fail(f"review pr {data['pr']} does not match expected PR {expected_pr}")
    if not isinstance(data["head_sha"], str) or not SHA_RE.fullmatch(data["head_sha"]):
        fail("head_sha must be 40 lowercase hex characters")
    if data["verdict"] not in {"APPROVE", "REQUEST_CHANGES", "BLOCKED"}:
        fail("invalid verdict")
    nonempty(data["summary"], "summary", 4000)

    findings = data["findings"]
    if not isinstance(findings, list) or len(findings) > 100:
        fail("findings must be an array with at most 100 entries")
    seen: set[str] = set()
    blockers = 0
    for index, item in enumerate(findings):
        label = f"findings[{index}]"
        if not isinstance(item, dict) or set(item) != FINDING_KEYS:
            fail(f"{label} keys must be exactly {sorted(FINDING_KEYS)}")
        if not isinstance(item["id"], str) or not ID_RE.fullmatch(item["id"]):
            fail(f"{label}.id must match Hnnn")
        if item["id"] in seen:
            fail(f"duplicate finding id {item['id']}")
        seen.add(item["id"])
        if type(item["blocking"]) is not bool:
            fail(f"{label}.blocking must be boolean")
        blockers += int(item["blocking"])
        if item["severity"] not in {"critical", "high", "medium", "low"}:
            fail(f"{label}.severity is invalid")
        if item["file"] is not None:
            nonempty(item["file"], f"{label}.file", 1000)
        if item["line"] is not None and (type(item["line"]) is not int or item["line"] < 1):
            fail(f"{label}.line must be null or a positive integer")
        nonempty(item["title"], f"{label}.title", 500)
        nonempty(item["evidence"], f"{label}.evidence")
        nonempty(item["recommended_fix"], f"{label}.recommended_fix")

    verification = data["verification"]
    if not isinstance(verification, list) or len(verification) > 50:
        fail("verification must be an array with at most 50 entries")
    passes = 0
    for index, item in enumerate(verification):
        label = f"verification[{index}]"
        if not isinstance(item, dict) or set(item) != VERIFY_KEYS:
            fail(f"{label} keys must be exactly {sorted(VERIFY_KEYS)}")
        nonempty(item["claim"], f"{label}.claim", 1000)
        if item["result"] not in {"pass", "fail", "unknown"}:
            fail(f"{label}.result is invalid")
        passes += int(item["result"] == "pass")
        nonempty(item["evidence"], f"{label}.evidence")

    if data["verdict"] == "APPROVE" and (blockers or not passes):
        fail("APPROVE requires zero blocking findings and at least one passing verification")
    if data["verdict"] == "REQUEST_CHANGES" and not blockers:
        fail("REQUEST_CHANGES requires at least one blocking finding")
    return data


def git_common_dir() -> Path:
    root = subprocess.run(
        ["git", "rev-parse", "--show-toplevel"], text=True, stdout=subprocess.PIPE, check=True
    ).stdout.strip()
    common = subprocess.run(
        ["git", "rev-parse", "--git-common-dir"], text=True, stdout=subprocess.PIPE, check=True
    ).stdout.strip()
    path = Path(common)
    return path if path.is_absolute() else Path(root) / path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("review", type=Path)
    parser.add_argument("--expected-pr", type=int)
    parser.add_argument("--record", action="store_true")
    args = parser.parse_args()
    try:
        with args.review.open(encoding="utf-8") as handle:
            review = validate(json.load(handle), args.expected_pr)
        current = live_head(review["pr"])
        if current != review["head_sha"]:
            fail(f"review head {review['head_sha']} is stale; live head is {current}")
        if args.record:
            target = git_common_dir() / "ha" / "reviews" / f"pr-{review['pr']}.json"
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(args.review, target)
            print(target)
        else:
            print(review["verdict"])
    except (OSError, json.JSONDecodeError, ValueError, subprocess.SubprocessError) as exc:
        print(f"HA review invalid: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
