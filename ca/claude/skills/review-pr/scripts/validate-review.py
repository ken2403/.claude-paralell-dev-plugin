#!/usr/bin/env python3
"""Strictly validate ca_claude_review.v1 output.

Any contract or gate inconsistency fails closed. Callers must never infer approval
from an invalid file.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Any


VERDICTS = {"approve", "request_changes", "blocked"}
SEVERITIES = {"blocker", "major", "minor"}
MODES = {"checkpoint", "final"}
PRODUCERS = {"blind", "synthesis"}
SECOND_OPINION_STATUSES = {"used", "clean_no_synthesis", "unavailable", "invalid", "disabled"}
COVERAGES = {"full", "partial"}
ADJUDICATIONS = {"confirmed", "refuted", "not_applicable", "unresolved_missing_evidence"}
RESOLVED_SEVERITIES = {"minor", "none"}
ESCALATED_SEVERITIES = {"blocker", "major"}
HEAD_SHA_RE = re.compile(r"^[0-9a-f]{7,64}$")
FINDING_ID_RE = re.compile(r"^[CX][0-9]{3}$")
BLIND_FINDING_ID_RE = re.compile(r"^C[0-9]{3}$")
CODEX_FINDING_ID_RE = re.compile(r"^X[0-9]{3}$")
ALLOWED_TOP = {
    "schema_version",
    "producer",
    "round",
    "mode",
    "verdict",
    "summary",
    "findings",
    "verification",
    "pr",
    "head_sha",
    "second_opinion",
    "resolved_blind_findings",
    "escalated_blind_findings",
}
ALLOWED_FINDING = {
    "id",
    "blocking",
    "severity",
    "file",
    "line",
    "title",
    "evidence",
    "recommended_fix",
}


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Validate a ca_claude_review.v1 JSON file")
    parser.add_argument("review")
    parser.add_argument("--blind")
    parser.add_argument("--second-opinion")
    parser.add_argument("--expected-mode", choices=sorted(MODES))
    parser.add_argument("--expected-round", type=int)
    parser.add_argument("--expected-producer", choices=sorted(PRODUCERS))
    parser.add_argument("--expected-pr", type=int)
    parser.add_argument("--expected-head-sha")
    parser.add_argument(
        "--require-subject",
        action="store_true",
        help="fail unless the review binds itself to a pr AND a head_sha",
    )
    return parser.parse_args()


def fail(message: str) -> None:
    print(f"review invalid: {message}", file=sys.stderr)
    raise SystemExit(1)


def load_json(path: str, label: str = "review") -> Any:
    try:
        with Path(path).open(encoding="utf-8") as handle:
            return json.load(handle)
    except FileNotFoundError:
        print(f"{label} file not found: {path}", file=sys.stderr)
        raise SystemExit(2)
    except (OSError, json.JSONDecodeError) as error:
        print(f"{label} parse error: {error}", file=sys.stderr)
        raise SystemExit(2)


def require_string(obj: dict[str, Any], key: str, context: str, max_len: int) -> str:
    value = obj.get(key)
    if not isinstance(value, str) or not value.strip():
        fail(f"{context}.{key} must be a non-empty string")
    if len(value) > max_len:
        fail(f"{context}.{key} exceeds {max_len} characters")
    return value


def reject_extra(obj: dict[str, Any], allowed: set[str], context: str) -> None:
    extra = set(obj) - allowed
    if extra:
        fail(f"{context} has unknown keys: {sorted(extra)}")


def validate_findings(findings: Any, producer: str) -> list[dict[str, Any]]:
    if not isinstance(findings, list) or len(findings) > 50:
        fail("findings must be a list of at most 50 items")
    seen: set[str] = set()
    result: list[dict[str, Any]] = []
    for index, finding in enumerate(findings):
        context = f"findings[{index}]"
        if not isinstance(finding, dict):
            fail(f"{context} must be an object")
        reject_extra(finding, ALLOWED_FINDING, context)
        finding_id = require_string(finding, "id", context, 4)
        pattern = BLIND_FINDING_ID_RE if producer == "blind" else FINDING_ID_RE
        if pattern.fullmatch(finding_id) is None:
            expected = "CNNN" if producer == "blind" else "CNNN or XNNN"
            fail(f"{context}.id must match {expected}")
        if finding_id in seen:
            fail(f"duplicate finding id: {finding_id}")
        seen.add(finding_id)
        if not isinstance(finding.get("blocking"), bool):
            fail(f"{context}.blocking must be a boolean")
        if finding.get("severity") not in SEVERITIES:
            fail(f"{context}.severity must be one of {sorted(SEVERITIES)}")
        require_string(finding, "title", context, 200)
        require_string(finding, "evidence", context, 4000)
        require_string(finding, "recommended_fix", context, 2000)
        if "file" in finding and finding["file"] is not None:
            require_string(finding, "file", context, 500)
        if "line" in finding and finding["line"] is not None and (
            not isinstance(finding["line"], int)
            or isinstance(finding["line"], bool)
            or finding["line"] < 1
        ):
            fail(f"{context}.line must be a positive integer")
        result.append(finding)
    return result


def validate_verification(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 50:
        fail("verification must be a list of at most 50 items")
    for index, item in enumerate(value):
        context = f"verification[{index}]"
        if not isinstance(item, dict):
            fail(f"{context} must be an object")
        reject_extra(item, {"claim", "result", "evidence"}, context)
        require_string(item, "claim", context, 500)
        if item.get("result") not in {"pass", "fail", "unknown"}:
            fail(f"{context}.result must be pass, fail, or unknown")
        require_string(item, "evidence", context, 4000)
    return value


def validate_second_opinion(value: Any) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail("second_opinion must be an object")
    reject_extra(
        value,
        {"provider", "status", "coverage", "ledger", "prior_findings_rechecked", "notes"},
        "second_opinion",
    )
    if value.get("provider") != "codex":
        fail("second_opinion.provider must be codex")
    if value.get("status") not in SECOND_OPINION_STATUSES:
        fail(f"second_opinion.status must be one of {sorted(SECOND_OPINION_STATUSES)}")
    if value.get("coverage") not in COVERAGES:
        fail(f"second_opinion.coverage must be one of {sorted(COVERAGES)}")
    ledger = value.get("ledger")
    if not isinstance(ledger, list) or len(ledger) > 50:
        fail("second_opinion.ledger must be a list of at most 50 items")
    seen: set[str] = set()
    for index, item in enumerate(ledger):
        context = f"second_opinion.ledger[{index}]"
        if not isinstance(item, dict):
            fail(f"{context} must be an object")
        reject_extra(item, {"id", "adjudication", "evidence"}, context)
        item_id = require_string(item, "id", context, 4)
        if CODEX_FINDING_ID_RE.fullmatch(item_id) is None:
            fail(f"{context}.id must match XNNN")
        if item_id in seen:
            fail(f"duplicate second-opinion ledger id: {item_id}")
        seen.add(item_id)
        if item.get("adjudication") not in ADJUDICATIONS:
            fail(f"{context}.adjudication must be one of {sorted(ADJUDICATIONS)}")
        require_string(item, "evidence", context, 4000)
    if not isinstance(value.get("prior_findings_rechecked"), bool):
        fail("second_opinion.prior_findings_rechecked must be a boolean")
    if "notes" in value:
        require_string(value, "notes", "second_opinion", 1000)
    return value


def validate_resolved(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 50:
        fail("resolved_blind_findings must be a list of at most 50 items")
    seen: set[str] = set()
    for index, item in enumerate(value):
        context = f"resolved_blind_findings[{index}]"
        if not isinstance(item, dict):
            fail(f"{context} must be an object")
        reject_extra(item, {"id", "reason", "evidence", "new_severity"}, context)
        item_id = require_string(item, "id", context, 4)
        if BLIND_FINDING_ID_RE.fullmatch(item_id) is None:
            fail(f"{context}.id must match CNNN")
        if item_id in seen:
            fail(f"duplicate resolved blind finding id: {item_id}")
        seen.add(item_id)
        require_string(item, "reason", context, 1000)
        require_string(item, "evidence", context, 4000)
        if item.get("new_severity") not in RESOLVED_SEVERITIES:
            fail(f"{context}.new_severity must be one of {sorted(RESOLVED_SEVERITIES)}")
    return value


def validate_escalated(value: Any) -> list[dict[str, Any]]:
    if not isinstance(value, list) or len(value) > 50:
        fail("escalated_blind_findings must be a list of at most 50 items")
    seen: set[str] = set()
    for index, item in enumerate(value):
        context = f"escalated_blind_findings[{index}]"
        if not isinstance(item, dict):
            fail(f"{context} must be an object")
        reject_extra(item, {"id", "reason", "evidence", "new_severity"}, context)
        item_id = require_string(item, "id", context, 4)
        if BLIND_FINDING_ID_RE.fullmatch(item_id) is None:
            fail(f"{context}.id must match CNNN")
        if item_id in seen:
            fail(f"duplicate escalated blind finding id: {item_id}")
        seen.add(item_id)
        require_string(item, "reason", context, 1000)
        require_string(item, "evidence", context, 4000)
        if item.get("new_severity") not in ESCALATED_SEVERITIES:
            fail(f"{context}.new_severity must be one of {sorted(ESCALATED_SEVERITIES)}")
    return value


def validate_codex_review(value: Any) -> set[str]:
    if not isinstance(value, dict):
        fail("Codex second opinion must be an object")
    reject_extra(value, {"schema_version", "pr", "head_sha", "summary", "coverage", "findings"}, "Codex review")
    if value.get("schema_version") != "ca_codex_review.v1":
        fail("Codex review schema_version must be ca_codex_review.v1")
    if not isinstance(value.get("pr"), int) or isinstance(value.get("pr"), bool) or value["pr"] < 1:
        fail("Codex review pr must be a positive integer")
    head_sha = require_string(value, "head_sha", "Codex review", 64)
    if len(head_sha) < 40 or HEAD_SHA_RE.fullmatch(head_sha) is None:
        fail("Codex review head_sha must be a 40-64 character hexadecimal commit id")
    require_string(value, "summary", "Codex review", 2000)
    if value.get("coverage") not in COVERAGES:
        fail("Codex review coverage must be full or partial")
    findings = value.get("findings")
    if not isinstance(findings, list) or len(findings) > 50:
        fail("Codex review findings must be a list of at most 50 items")
    ids: set[str] = set()
    for index, finding in enumerate(findings):
        context = f"Codex review findings[{index}]"
        if not isinstance(finding, dict):
            fail(f"{context} must be an object")
        reject_extra(finding, ALLOWED_FINDING, context)
        finding_id = require_string(finding, "id", context, 4)
        if CODEX_FINDING_ID_RE.fullmatch(finding_id) is None:
            fail(f"{context}.id must match XNNN")
        if finding_id in ids:
            fail(f"duplicate Codex finding id: {finding_id}")
        ids.add(finding_id)
        if not isinstance(finding.get("blocking"), bool):
            fail(f"{context}.blocking must be a boolean")
        if finding.get("severity") not in SEVERITIES:
            fail(f"{context}.severity must be one of {sorted(SEVERITIES)}")
        require_string(finding, "title", context, 200)
        require_string(finding, "evidence", context, 4000)
        require_string(finding, "recommended_fix", context, 2000)
        for key in ("file", "line"):
            if key not in finding:
                fail(f"{context}.{key} is required; use null when unknown")
        if finding["file"] is not None:
            require_string(finding, "file", context, 500)
        if finding["line"] is not None and (
            not isinstance(finding["line"], int)
            or isinstance(finding["line"], bool)
            or finding["line"] < 1
        ):
            fail(f"{context}.line must be a positive integer")
    return ids


def validate_review(data: Any, args: argparse.Namespace) -> dict[str, Any]:
    if not isinstance(data, dict):
        fail("top level must be an object")
    reject_extra(data, ALLOWED_TOP, "review")
    if data.get("schema_version") != "ca_claude_review.v1":
        fail("schema_version must be ca_claude_review.v1")
    producer = data.get("producer")
    if producer not in PRODUCERS:
        fail(f"producer must be one of {sorted(PRODUCERS)}")
    mode = data.get("mode")
    if mode not in MODES:
        fail(f"mode must be one of {sorted(MODES)}")
    round_number = data.get("round")
    if not isinstance(round_number, int) or isinstance(round_number, bool) or round_number < 1:
        fail("round must be a positive integer")
    if args.expected_mode is not None and mode != args.expected_mode:
        fail(f"mode must echo requested mode {args.expected_mode}")
    if args.expected_round is not None and round_number != args.expected_round:
        fail(f"round must echo requested round {args.expected_round}")
    if args.expected_producer is not None and producer != args.expected_producer:
        fail(f"producer must be {args.expected_producer}")
    if "pr" in data and (
        not isinstance(data["pr"], int) or isinstance(data["pr"], bool) or data["pr"] < 1
    ):
        fail("pr must be a positive integer")
    if "head_sha" in data:
        head_sha = require_string(data, "head_sha", "review", 64)
        if HEAD_SHA_RE.fullmatch(head_sha) is None:
            fail("head_sha must be a lowercase hex commit sha")
    if args.require_subject and ("pr" not in data or "head_sha" not in data):
        fail("review must bind itself to the reviewed pr and head_sha")
    if args.expected_pr is not None:
        if data.get("pr") != args.expected_pr:
            fail(f"pr must be {args.expected_pr}; a verdict cannot be reused across PRs")
    if args.expected_head_sha is not None:
        if data.get("head_sha") != args.expected_head_sha:
            fail(
                "head_sha must be the reviewed commit "
                f"{args.expected_head_sha}; the branch moved after the review"
            )
    verdict = data.get("verdict")
    if verdict not in VERDICTS:
        fail(f"verdict must be one of {sorted(VERDICTS)}")
    require_string(data, "summary", "review", 2000)
    findings = validate_findings(data.get("findings"), producer)
    verification = validate_verification(data.get("verification"))
    blockers = [finding for finding in findings if finding["blocking"]]
    if verdict == "approve" and blockers:
        fail("approve verdict cannot contain blocking findings")
    if verdict == "approve" and not verification:
        fail("approve verdict requires at least one verification record")
    if verdict == "approve":
        failed = [item["claim"] for item in verification if item["result"] == "fail"]
        if failed:
            fail(f"approve verdict contradicts failed verification: {failed}")
    if verdict == "request_changes" and not blockers:
        fail("request_changes verdict requires at least one blocking finding")

    if producer == "blind":
        synthesis_only = {"second_opinion", "resolved_blind_findings", "escalated_blind_findings"}
        if synthesis_only & set(data):
            fail("blind review cannot contain synthesis-only fields")
    else:
        if mode != "final":
            fail("synthesis output is final-mode only")
        second = validate_second_opinion(data.get("second_opinion"))
        if second.get("status") != "used":
            fail("synthesis second_opinion.status must be used")
        validate_resolved(data.get("resolved_blind_findings"))
        validate_escalated(data.get("escalated_blind_findings", []))
    return data


def enforce_synthesis_ledger(
    synthesis: dict[str, Any], blind: dict[str, Any], codex: dict[str, Any] | None
) -> None:
    if synthesis.get("producer") != "synthesis":
        fail("--blind/--second-opinion are valid only for synthesis output")
    blind_by_id = {finding["id"]: finding for finding in blind["findings"]}
    blind_blockers = {i for i, f in blind_by_id.items() if f["blocking"]}
    final_by_id = {finding["id"]: finding for finding in synthesis["findings"]}
    final_ids = set(final_by_id)
    resolved_ids = {item["id"] for item in synthesis["resolved_blind_findings"]}
    missing = sorted(blind_blockers - final_ids - resolved_ids)
    if missing:
        fail(f"synthesis silently dropped blind blocking findings: {missing}")
    if final_ids & resolved_ids:
        fail("a blind finding cannot be both retained and resolved")
    unknown_resolved = sorted(resolved_ids - set(blind_by_id))
    if unknown_resolved:
        fail(f"resolved_blind_findings cite ids the blind review never raised: {unknown_resolved}")

    # Downgrades are accountable (resolved_blind_findings); escalations must be too,
    # or synthesis can flip a verdict on its own authority with no trail.
    escalated_ids = {item["id"] for item in synthesis.get("escalated_blind_findings", [])}
    unknown_escalated = sorted(escalated_ids - set(blind_by_id))
    if unknown_escalated:
        fail(f"escalated_blind_findings cite ids the blind review never raised: {unknown_escalated}")
    silent_escalations = sorted(
        finding_id
        for finding_id, finding in final_by_id.items()
        if finding["blocking"]
        and finding_id in blind_by_id
        and not blind_by_id[finding_id]["blocking"]
        and finding_id not in escalated_ids
    )
    if silent_escalations:
        fail(
            "synthesis escalated non-blocking blind findings without recording them in "
            f"escalated_blind_findings: {silent_escalations}"
        )
    not_escalated = sorted(
        finding_id
        for finding_id in escalated_ids
        if finding_id not in final_by_id or not final_by_id[finding_id]["blocking"]
    )
    if not_escalated:
        fail(f"escalated_blind_findings list ids that are not blocking findings: {not_escalated}")

    if codex is None:
        return
    codex_ids = validate_codex_review(codex)
    if codex["pr"] != blind.get("pr") or codex["head_sha"] != blind.get("head_sha"):
        fail("Codex second opinion and blind review must name the same pr and head_sha")
    ledger = synthesis["second_opinion"]["ledger"]
    ledger_by_id = {item["id"]: item["adjudication"] for item in ledger}
    if set(ledger_by_id) != codex_ids:
        fail("second_opinion.ledger ids must exactly match Codex finding ids")
    for finding_id in final_ids:
        if not finding_id.startswith("X"):
            continue
        if ledger_by_id.get(finding_id) not in {"confirmed", "unresolved_missing_evidence"}:
            fail(f"final Codex finding {finding_id} must be confirmed or unresolved_missing_evidence")


def main() -> None:
    args = parse_args()
    review = validate_review(load_json(args.review), args)
    blind = None
    if args.blind:
        # the blind leg must be about the SAME subject as the synthesis that quotes it
        blind_args = argparse.Namespace(
            expected_mode="final",
            expected_round=args.expected_round,
            expected_producer="blind",
            expected_pr=args.expected_pr,
            expected_head_sha=args.expected_head_sha,
            require_subject=args.require_subject,
        )
        blind = validate_review(load_json(args.blind, "blind review"), blind_args)
    codex = load_json(args.second_opinion, "Codex second opinion") if args.second_opinion else None
    if blind is not None or codex is not None:
        if blind is None:
            fail("--second-opinion requires --blind")
        enforce_synthesis_ledger(review, blind, codex)
    print(review["verdict"])


if __name__ == "__main__":
    main()
