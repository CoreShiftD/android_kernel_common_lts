#!/usr/bin/env python3
"""Generate a manifest overlay from the resolved ACK manifest."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path
from xml.etree import ElementTree
from xml.sax.saxutils import escape


BASE_KEEP_PATTERNS = (
    "build",
    "build/*",
    "kernel/configs",
    "kernel/configs/*",
    "kernel/prebuilts",
    "kernel/prebuilts/*",
    "prebuilts/clang",
    "prebuilts/clang/*",
    "prebuilts/gcc",
    "prebuilts/gcc/*",
    "prebuilts/build-tools",
    "prebuilts/build-tools/*",
    "prebuilts/kernel-build-tools",
    "prebuilts/kernel-build-tools/*",
    "prebuilts/misc",
    "prebuilts/misc/*",
    "tools",
    "tools/*",
)

KLEAF_EXTRA_PATTERNS = (
    "external/bazel*",
    "external/stardoc*",
    "external/rules_*",
    "external/*rules*",
    "platform/prebuilts",
    "platform/prebuilts/*",
    "prebuilts/python",
    "prebuilts/python/*",
    "prebuilts/go",
    "prebuilts/go/*",
    "prebuilts/jdk",
    "prebuilts/jdk/*",
    "prebuilts/bazel",
    "prebuilts/bazel/*",
    "prebuilts/rust",
    "prebuilts/rust/*",
    "external/rust",
    "external/rust/*",
    "external/llvm*",
)

KLEAF_CONTAINS = (
    "bazel",
    "kleaf",
    "rules",
    "stardoc",
    "jdk",
    "java",
    "python",
    "rust",
    "clang",
    "prebuilts",
    "build",
    "tools",
)


@dataclass(frozen=True)
class Project:
    name: str
    path: str


def fail(message: str) -> None:
    raise SystemExit(message)


def load_profile(path: Path) -> dict[str, object]:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except json.JSONDecodeError as exc:
        fail(f"{path}: invalid JSON: {exc}")
    if not isinstance(data, dict):
        fail(f"{path}: top-level JSON value must be an object")
    return data


def load_static_overlay(path: Path | None) -> list[str]:
    if path is None:
        return []
    try:
        root = ElementTree.parse(path).getroot()
    except ElementTree.ParseError as exc:
        fail(f"static overlay {path} is not valid XML: {exc}")
    removals: list[str] = []
    for remove_node in root.findall(".//remove-project"):
        name = remove_node.get("name")
        if name and name not in removals:
            removals.append(name)
    return removals


def run_repo_manifest(workspace: Path) -> list[Project]:
    workspace = workspace.resolve()
    with tempfile.NamedTemporaryFile(
        prefix="coreshift-resolved-manifest-",
        suffix=".xml",
        delete=False,
    ) as handle:
        manifest_path = Path(handle.name)
    try:
        result = subprocess.run(
            ["repo", "manifest", "-o", str(manifest_path)],
            cwd=workspace,
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            stderr = result.stderr.strip() or result.stdout.strip() or "unknown repo manifest failure"
            fail(f"repo manifest failed in {workspace}: {stderr}")
        try:
            root = ElementTree.parse(manifest_path).getroot()
        except ElementTree.ParseError as exc:
            fail(f"resolved manifest is not valid XML: {exc}")
    finally:
        manifest_path.unlink(missing_ok=True)

    projects: list[Project] = []
    seen_names: set[str] = set()
    for project_node in root.findall(".//project"):
        name = project_node.get("name")
        if not name or name in seen_names:
            continue
        seen_names.add(name)
        path = project_node.get("path") or name
        projects.append(Project(name=name, path=path))
    return projects


def pattern_matches(candidate: str, pattern: str) -> bool:
    if "*" in pattern:
        from fnmatch import fnmatch

        return fnmatch(candidate, pattern)
    return candidate == pattern


def match_pattern_reason(project: Project, patterns: tuple[str, ...]) -> str | None:
    for pattern in patterns:
        for field_name, candidate in (("path", project.path), ("name", project.name)):
            if pattern_matches(candidate, pattern):
                return f"{field_name} matched {pattern}"
    return None


def match_contains_reason(project: Project, tokens: tuple[str, ...]) -> str | None:
    path_lower = project.path.lower()
    name_lower = project.name.lower()
    for token in tokens:
        if token in path_lower:
            return f"path contains {token}"
        if token in name_lower:
            return f"name contains {token}"
    return None


def keep_reason(project: Project, is_kleaf: bool) -> str | None:
    reason = match_pattern_reason(project, BASE_KEEP_PATTERNS)
    if reason:
        return reason
    if not is_kleaf:
        return None
    reason = match_pattern_reason(project, KLEAF_EXTRA_PATTERNS)
    if reason:
        return reason
    return match_contains_reason(project, KLEAF_CONTAINS)


def build_overlay(
    projects: list[Project],
    profile: dict[str, object],
    mode: str,
    keep_manifest_common: bool,
    safe_mode_removals: set[str],
) -> tuple[list[str], list[tuple[Project, str]], list[Project]]:
    bazel_target = profile.get("bazel_target")
    is_kleaf = isinstance(bazel_target, str) and bool(bazel_target)
    removed: list[str] = []
    kept: list[tuple[Project, str]] = []
    removed_projects: list[Project] = []

    for project in projects:
        if mode == "safe":
            if project.name in safe_mode_removals:
                removed.append(project.name)
                removed_projects.append(project)
            else:
                kept.append((project, "trim mode safe"))
            continue

        if project.name == "kernel/common":
            if mode == "none" and keep_manifest_common:
                kept.append((project, "kept by CORESHIFT_KEEP_MANIFEST_COMMON=1"))
            else:
                removed.append(project.name)
                removed_projects.append(project)
            continue

        if mode == "none":
            kept.append((project, "trim mode none"))
            continue

        reason = keep_reason(project, is_kleaf)
        if reason:
            kept.append((project, reason))
        else:
            removed.append(project.name)
            removed_projects.append(project)

    return removed, kept, removed_projects


def write_overlay(output: Path, removed: list[str]) -> None:
    output.parent.mkdir(parents=True, exist_ok=True)
    lines = ['<?xml version="1.0" encoding="UTF-8"?>', "<manifest>"]
    for name in removed:
        lines.append(f'  <remove-project name="{escape(name)}" />')
    lines.append("</manifest>")
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def write_report(
    report_path: Path,
    profile: dict[str, object],
    mode: str,
    projects: list[Project],
    kept: list[tuple[Project, str]],
    removed_projects: list[Project],
) -> None:
    lines = [
        f"profile name: {profile.get('name', '')}",
        f"manifest branch: {profile.get('manifest_branch', '')}",
        f"build_config: {profile.get('build_config', '')}",
        f"bazel_target: {profile.get('bazel_target', '')}",
        f"trim mode: {mode}",
        f"total projects: {len(projects)}",
        "",
        "kept projects with reason:",
    ]
    for project, reason in kept:
        lines.append(f"- {project.name} ({project.path}) [{reason}]")
    lines.extend(["", "removed projects:"])
    for project in removed_projects:
        lines.append(f"- {project.name} ({project.path})")
    report_path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile-json", required=True)
    parser.add_argument("--workspace", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--mode", required=True, choices=("safe", "aggressive", "none"))
    parser.add_argument("--static-overlay")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    profile_path = Path(args.profile_json).resolve()
    workspace = Path(args.workspace).resolve()
    output = Path(args.output).resolve()
    report_path = workspace / "manifest-trim-report.txt"
    keep_manifest_common = os.environ.get("CORESHIFT_KEEP_MANIFEST_COMMON") == "1"
    static_overlay = Path(args.static_overlay).resolve() if args.static_overlay else None
    safe_mode_removals = set(load_static_overlay(static_overlay))
    if args.mode == "safe" and not safe_mode_removals:
        safe_mode_removals = {"kernel/common"}

    profile = load_profile(profile_path)
    projects = run_repo_manifest(workspace)
    removed, kept, removed_projects = build_overlay(
        projects=projects,
        profile=profile,
        mode=args.mode,
        keep_manifest_common=keep_manifest_common,
        safe_mode_removals=safe_mode_removals,
    )
    write_overlay(output, removed)
    write_report(
        report_path=report_path,
        profile=profile,
        mode=args.mode,
        projects=projects,
        kept=kept,
        removed_projects=removed_projects,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
