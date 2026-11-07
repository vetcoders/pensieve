#!/usr/bin/env python3
"""Synchronize Pensieve release surfaces around a single semantic version.

This script keeps the release-visible version honest across:

- VERSION
- docs/index.html (JSON-LD softwareVersion, hero release-note, What's new label,
  download panel <dt>Version</dt><dd>...</dd>, and placeholder checksum slot on bump)
- CHANGELOG-derived release notes extraction

Usage:
    python3 scripts/release_sync.py bump patch
    python3 scripts/release_sync.py bump 0.7.1
    python3 scripts/release_sync.py check
    python3 scripts/release_sync.py check 0.7.0 --require-version-section
    python3 scripts/release_sync.py notes
    python3 scripts/release_sync.py notes 0.7.0 --output dist/release-notes.md
"""

from __future__ import annotations

import argparse
import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
VERSION_FILE = ROOT / "VERSION"
LANDING_PAGE = ROOT / "docs" / "index.html"
CHANGELOG = ROOT / "CHANGELOG.md"
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+$")
VERSION_HEADER_RE = re.compile(
    r"^## \[(?P<version>v?\d+\.\d+\.\d+)](?: - .+)?$", re.MULTILINE
)


def root_relative(path: pathlib.Path) -> str:
    try:
        return path.relative_to(ROOT).as_posix()
    except ValueError:
        return path.as_posix()


def read_version() -> str:
    if not VERSION_FILE.is_file():
        raise SystemExit(f"VERSION file not found at {VERSION_FILE}")
    version = VERSION_FILE.read_text(encoding="utf-8").strip()
    if not SEMVER_RE.fullmatch(version):
        raise SystemExit(f"VERSION must be x.y.z semver, got {version!r}")
    return version


def compute_bumped_version(current: str, target: str) -> str:
    parts = [int(part) for part in current.split(".")]
    if target == "patch":
        parts[2] += 1
    elif target == "minor":
        parts[1] += 1
        parts[2] = 0
    elif target == "major":
        parts[0] += 1
        parts[1] = 0
        parts[2] = 0
    elif SEMVER_RE.fullmatch(target):
        return target
    else:
        raise SystemExit(
            f"Invalid VERSION: {target!r}. Use patch|minor|major|x.y.z"
        )
    return ".".join(str(part) for part in parts)


def replace_once(
    text: str,
    pattern: str,
    replacement: str,
    *,
    flags: int = 0,
    label: str,
) -> str:
    new_text, count = re.subn(pattern, replacement, text, count=1, flags=flags)
    if count != 1:
        raise SystemExit(f"Could not sync {label}")
    return new_text


def placeholder_for_version(version: str) -> str:
    dashed = version.replace(".", "-")
    return f"RELEASE-{dashed}-SHA256-FILLED-AT-PUBLISH-DO-NOT-SHIP-THIS-LINE"


def transform_landing_page(
    text: str, version: str, *, reset_checksum: bool
) -> str:
    updated = text
    transforms = (
        (
            r'("softwareVersion"\s*:\s*")\d+\.\d+\.\d+(")',
            rf"\g<1>{version}\g<2>",
            0,
            "docs/index.html JSON-LD softwareVersion",
        ),
        (
            r"(Version\s+<code[^>]*>)\d+\.\d+\.\d+(</code>)",
            rf"\g<1>{version}\g<2>",
            0,
            "docs/index.html hero release-note version",
        ),
        (
            r'(<div class="section-label"[^>]*>Release\s+)\d+\.\d+\.\d+(</div>)',
            rf"\g<1>{version}\g<2>",
            0,
            "docs/index.html What's new section label",
        ),
        (
            r"(<dt>\s*Version\s*</dt>\s*<dd>\s*)\d+\.\d+\.\d+(\s*</dd>)",
            rf"\g<1>{version}\g<2>",
            re.DOTALL,
            "docs/index.html download-panel <dt>Version</dt>",
        ),
    )
    for pattern, replacement, flags, label in transforms:
        updated = replace_once(
            updated, pattern, replacement, flags=flags, label=label
        )

    if reset_checksum:
        placeholder = placeholder_for_version(version)
        updated = replace_once(
            updated,
            r'(<div class="sha"[^>]*>\s*<b>SHA-256</b>\s*<br\s*/?>\s*)[^<\s]+(\s*</div>)',
            rf"\g<1>{placeholder}\g<2>",
            flags=re.DOTALL,
            label="docs/index.html SHA-256 slot",
        )
    return updated


def sync_versions(
    version: str, *, write: bool, reset_checksum: bool = False
) -> list[str]:
    changed: list[str] = []

    version_original = VERSION_FILE.read_text(encoding="utf-8")
    version_updated = f"{version}\n"
    version_changed = version_original != version_updated
    if version_changed:
        changed.append(root_relative(VERSION_FILE))

    page_updated: str | None = None
    page_changed = False
    if LANDING_PAGE.is_file():
        page_original = LANDING_PAGE.read_text(encoding="utf-8")
        page_updated = transform_landing_page(
            page_original, version, reset_checksum=reset_checksum
        )
        page_changed = page_original != page_updated
        if page_changed:
            changed.append(root_relative(LANDING_PAGE))

    if write:
        if version_changed:
            VERSION_FILE.write_text(version_updated, encoding="utf-8")
        if page_changed and page_updated is not None:
            LANDING_PAGE.write_text(page_updated, encoding="utf-8")

    return changed


def version_header_regex(version: str) -> re.Pattern[str]:
    escaped = re.escape(version)
    escaped_v = re.escape(f"v{version}")
    return re.compile(
        rf"^## \[(?:{escaped}|{escaped_v})](?: - .+)?$",
        re.MULTILINE,
    )


def extract_version_notes(version: str) -> str:
    text = CHANGELOG.read_text(encoding="utf-8")
    match = version_header_regex(version).search(text)
    if match is None:
        raise SystemExit(
            f"CHANGELOG.md does not contain a dedicated section for version {version}"
        )

    body_start = match.end()
    next_match = VERSION_HEADER_RE.search(text, body_start)
    body = text[body_start : next_match.start() if next_match else len(text)].strip()
    if not body:
        return "No detailed release notes were recorded for this version."
    return body


def command_bump(args: argparse.Namespace) -> int:
    current = read_version()
    new_version = compute_bumped_version(current, args.target)
    reset_checksum = args.reset_checksum or (new_version != current)
    changed = sync_versions(
        new_version, write=True, reset_checksum=reset_checksum
    )
    if not changed:
        print(f"Release surfaces already synced to {new_version}")
        return 0

    print(f"Release surfaces synced: {current} -> {new_version}")
    for path in changed:
        print(f"  - {path}")
    return 0


def command_check(args: argparse.Namespace) -> int:
    expected = args.version or read_version()
    if not SEMVER_RE.fullmatch(expected):
        print(f"Expected version must be x.y.z, got {expected!r}", file=sys.stderr)
        return 1

    changed = sync_versions(expected, write=False, reset_checksum=False)

    errors: list[str] = []
    changelog_text = CHANGELOG.read_text(encoding="utf-8")
    if "## [Unreleased]" not in changelog_text:
        errors.append("CHANGELOG.md is missing '## [Unreleased]'")
    if (
        args.require_version_section
        and version_header_regex(expected).search(changelog_text) is None
    ):
        errors.append(f"CHANGELOG.md is missing dedicated section for {expected}")

    if changed:
        errors.append(
            "Release surfaces are out of sync for "
            f"{expected}: {', '.join(changed)}"
        )

    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 1

    print(f"Release surfaces are synced to {expected}")
    if version_header_regex(expected).search(changelog_text):
        print(f"CHANGELOG section for {expected}: present")
    else:
        print(
            f"CHANGELOG section for {expected}: not yet closed (Unreleased still open)"
        )
    return 0


def command_notes(args: argparse.Namespace) -> int:
    version = args.version or read_version()
    notes = extract_version_notes(version)
    if args.output:
        output_path = pathlib.Path(args.output)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_text(notes + "\n", encoding="utf-8")
        print(f"Wrote release notes for {version} to {output_path}")
        return 0

    print(notes)
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    bump_parser = subparsers.add_parser("bump", help="Bump and sync release surfaces")
    bump_parser.add_argument("target", help="patch|minor|major|x.y.z")
    bump_parser.add_argument(
        "--reset-checksum",
        action="store_true",
        help="Reset docs/index.html SHA-256 slot to the DO-NOT-SHIP placeholder",
    )
    bump_parser.set_defaults(func=command_bump)

    check_parser = subparsers.add_parser(
        "check", help="Verify release surfaces are synced"
    )
    check_parser.add_argument(
        "version", nargs="?", help="Expected version; defaults to VERSION"
    )
    check_parser.add_argument(
        "--require-version-section",
        action="store_true",
        help="Fail if CHANGELOG.md does not yet contain a dedicated section for this version",
    )
    check_parser.set_defaults(func=command_check)

    notes_parser = subparsers.add_parser(
        "notes", help="Extract release notes from CHANGELOG.md"
    )
    notes_parser.add_argument(
        "version", nargs="?", help="Version to extract; defaults to VERSION"
    )
    notes_parser.add_argument(
        "--output", help="Write notes to a file instead of stdout"
    )
    notes_parser.set_defaults(func=command_notes)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
