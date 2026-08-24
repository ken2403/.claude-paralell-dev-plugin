#!/usr/bin/env python3
"""Repository-owned, CI-stable validation for bundled Codex plugins and skills."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

import yaml


SKILL_KEYS = {"name", "description", "license", "allowed-tools", "metadata"}
NAME_RE = re.compile(r"^[a-z0-9]+(?:-[a-z0-9]+)*$")


def fail(message: str) -> None:
    raise SystemExit(f"validate-codex: {message}")


def frontmatter(path: Path) -> dict:
    text = path.read_text(encoding="utf-8")
    if not text.startswith("---\n") or "\n---\n" not in text[4:]:
        fail(f"{path}: missing YAML frontmatter delimiters")
    raw = text.split("\n---\n", 1)[0][4:]
    data = yaml.safe_load(raw)
    if not isinstance(data, dict):
        fail(f"{path}: frontmatter must be a mapping")
    return data


def validate_skill(skill: Path) -> None:
    spec = skill / "SKILL.md"
    if not spec.is_file():
        fail(f"{skill}: missing SKILL.md")
    if (skill / "README.md").exists():
        fail(f"{skill}: README.md is not allowed inside a skill")
    data = frontmatter(spec)
    unknown = set(data) - SKILL_KEYS
    if unknown:
        fail(f"{spec}: unsupported frontmatter keys {sorted(unknown)}")
    name = data.get("name")
    description = data.get("description")
    if name != skill.name or not isinstance(name, str) or not NAME_RE.fullmatch(name) or len(name) > 64:
        fail(f"{spec}: name must equal kebab-case directory name")
    if not isinstance(description, str) or not description.strip() or len(description) >= 1024 or "<" in description or ">" in description:
        fail(f"{spec}: description violates Codex skill constraints")
    agent = skill / "agents" / "openai.yaml"
    if agent.exists():
        meta = yaml.safe_load(agent.read_text(encoding="utf-8"))
        if not isinstance(meta, dict) or not isinstance(meta.get("interface"), dict):
            fail(f"{agent}: interface mapping is required")
        prompt = meta["interface"].get("default_prompt")
        if not isinstance(prompt, str) or f"${name}" not in prompt:
            fail(f"{agent}: default_prompt must mention ${name}")
        policy = meta.get("policy", {})
        if "allow_implicit_invocation" in policy and type(policy["allow_implicit_invocation"]) is not bool:
            fail(f"{agent}: allow_implicit_invocation must be boolean")


def validate_plugin(plugin: Path) -> None:
    manifest_path = plugin / ".codex-plugin" / "plugin.json"
    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        fail(f"{manifest_path}: {exc}")
    if manifest.get("name") != plugin.name:
        fail(f"{manifest_path}: name must equal plugin directory")
    if not isinstance(manifest.get("version"), str) or not manifest["version"].strip():
        fail(f"{manifest_path}: non-empty version is required")
    skills_path = manifest.get("skills")
    if not isinstance(skills_path, str):
        fail(f"{manifest_path}: skills path is required")
    skills = (plugin / skills_path).resolve()
    if not skills.is_dir() or plugin.resolve() not in skills.parents:
        fail(f"{manifest_path}: skills must resolve inside the plugin")
    found = sorted(path for path in skills.iterdir() if path.is_dir())
    if not found:
        fail(f"{plugin}: no skills found")
    for skill in found:
        validate_skill(skill)
    print(f"validate-codex: ok {plugin} ({len(found)} skills)")


if __name__ == "__main__":
    if len(sys.argv) < 2:
        fail("usage: validate-codex.py <plugin>...")
    for item in sys.argv[1:]:
        validate_plugin(Path(item))
