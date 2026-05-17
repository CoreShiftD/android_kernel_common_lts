#!/usr/bin/env python3
"""Generate a manifest overlay from the resolved ACK manifest."""

from __future__ import annotations

import argparse
import json
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
VALID_MANIFEST_TRIM_VALUES = {"safe", "aggressive", "none"}


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


def get_manifest_trim_mode(profile: dict[str, object], override: str | None) -> str:
    if override is not None:
        if override not in VALID_MANIFEST_TRIM_VALUES:
            allowed = ", ".join(sorted(VALID_MANIFEST_TRIM_VALUES))
            fail(f"override trim mode must be one of: {allowed}")
        return override
    mode = profile.get("manifest_trim", "safe")
    if mode not in VALID_MANIFEST_TRIM_VALUES:
        allowed = ", ".join(sorted(VALID_MANIFEST_TRIM_VALUES))
        fail(f"profile field 'manifest_trim' must be one of: {allowed}")
    return str(mode)


def get_string_list(profile: dict[str, object], field: str) -> list[str]:
    value = profile.get(field)
    if value is None:
        return []
    if not isinstance(value, list):
        fail(f"profile field {field!r} must be a list of non-empty strings")
    result: list[str] = []
    for entry in value:
        if not isinstance(entry, str) or not entry:
            fail(f"profile field {field!r} must contain only non-empty strings")
        result.append(entry)
    return result


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


def keep_reason_with_profile_patterns(
    project: Project,
    is_kleaf: bool,
    profile_keep_patterns: list[str],
) -> str | None:
    reason = keep_reason(project, is_kleaf)
    if reason:
        return reason
    profile_reason = match_pattern_reason(project, tuple(profile_keep_patterns))
    if profile_reason:
        return f"{profile_reason} (profile keep pattern)"
    return None


def build_overlay(
    projects: list[Project],
    profile: dict[str, object],
    mode: str,
    safe_mode_removals: set[str],
    profile_keep_patterns: list[str],
    profile_drop_projects: list[str],
) -> tuple[list[str], list[tuple[Project, str]], list[Project]]:
    bazel_target = profile.get("bazel_target")
    is_kleaf = isinstance(bazel_target, str) and bool(bazel_target)
    removed: list[str] = []
    kept: list[tuple[Project, str]] = []
    removed_projects: list[Project] = []
    forced_drops = set(profile_drop_projects)

    for project in projects:
        if mode == "safe":
            if project.name in safe_mode_removals:
                removed.append(project.name)
                removed_projects.append(project)
            else:
                kept.append((project, "trim mode safe"))
            continue

        if project.name == "kernel/common":
            removed.append(project.name)
            removed_projects.append(project)
            continue

        if mode == "none":
            if project.name in forced_drops:
                removed.append(project.name)
                removed_projects.append(project)
            else:
                kept.append((project, "trim mode none"))
            continue

        reason = keep_reason_with_profile_patterns(project, is_kleaf, profile_keep_patterns)
        if reason and project.name not in forced_drops:
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
    overlay_manifest: str,
    projects: list[Project],
    kept: list[tuple[Project, str]],
    removed_projects: list[Project],
    profile_keep_patterns: list[str],
    profile_drop_projects: list[str],
) -> None:
    lines = [
        f"profile name: {profile.get('name', '')}",
        f"manifest branch: {profile.get('manifest_branch', '')}",
        f"trim mode: {mode}",
        f"overlay_manifest: {overlay_manifest}",
        f"total projects: {len(projects)}",
        f"profile keep patterns: {', '.join(profile_keep_patterns) if profile_keep_patterns else '(none)'}",
        f"profile drop projects: {', '.join(profile_drop_projects) if profile_drop_projects else '(none)'}",
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
    parser.add_argument("--mode", choices=("safe", "aggressive", "none"))
    parser.add_argument("--static-overlay")
    return parser.parse_args(argv)


def main(argv: list[str]) -> int:
    args = parse_args(argv)
    profile_path = Path(args.profile_json).resolve()
    workspace = Path(args.workspace).resolve()
    output = Path(args.output).resolve()
    report_path = workspace / "manifest-trim-report.txt"
    static_overlay = Path(args.static_overlay).resolve() if args.static_overlay else None
    safe_mode_removals = set(load_static_overlay(static_overlay))

    profile = load_profile(profile_path)
    mode = get_manifest_trim_mode(profile, args.mode)
    profile_keep_patterns = get_string_list(profile, "manifest_keep_patterns")
    profile_drop_projects = get_string_list(profile, "manifest_drop_projects")
    if mode == "safe" and not safe_mode_removals:
        safe_mode_removals = {"kernel/common"}
    projects = run_repo_manifest(workspace)
    removed, kept, removed_projects = build_overlay(
        projects=projects,
        profile=profile,
        mode=mode,
        safe_mode_removals=safe_mode_removals,
        profile_keep_patterns=profile_keep_patterns,
        profile_drop_projects=profile_drop_projects,
    )
    write_overlay(output, removed)
    write_report(
        report_path=report_path,
        profile=profile,
        mode=mode,
        overlay_manifest=str(profile.get("overlay_manifest", "")),
        projects=projects,
        kept=kept,
        removed_projects=removed_projects,
        profile_keep_patterns=profile_keep_patterns,
        profile_drop_projects=profile_drop_projects,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
