#!/usr/bin/env python3
"""Close CHANGELOG.md `## [Unreleased]` section with the current VERSION.

Keeps `## [Unreleased]` in place (empty) so the next cycle has a landing slot.
Idempotent: if the current version already has a dedicated section, exits 0 no-op.

If `--generate-if-empty` is set and `Unreleased` is empty, a lightweight
conventional-commit summary is generated from git history since the last tag.
"""

from __future__ import annotations

import argparse
import datetime
import pathlib
import re
import subprocess
import sys

UNRELEASED = "## [Unreleased]"
VERSION_HEADING_RE = r"^## \[(?:v)?\d+\.\d+\.\d+](?: - .+)?$"
AGENT_PREFIX_RE = re.compile(r"^\[[^\]]+\]\s*")


def generate_changelog_body(root: pathlib.Path) -> str:
    def run_git(*args: str) -> str:
        result = subprocess.run(
            ["git", "-C", str(root), *args],
            check=False,
            capture_output=True,
            text=True,
        )
        if result.returncode != 0:
            return ""
        return result.stdout.strip()

    last_tag = run_git("describe", "--tags", "--abbrev=0")
    if last_tag:
        commit_text = run_git("log", "--oneline", "-100", f"{last_tag}..HEAD")
    else:
        commit_text = run_git("log", "--oneline", "-50")

    added: list[str] = []
    changed: list[str] = []
    fixed: list[str] = []
    security: list[str] = []

    for raw_line in commit_text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        _, _, raw_subject = line.partition(" ")
        if not raw_subject:
            continue
        subject = AGENT_PREFIX_RE.sub("", raw_subject).strip()

        def trim(prefix: str, text: str = subject) -> str:
            message = text[len(prefix) :]
            if message.startswith("(") and "):" in message:
                message = message.split("):", 1)[1]
            message = message.lstrip(":").strip()
            return message or text

        lowered = subject.lower()
        if subject.startswith("feat:") or subject.startswith("feat("):
            added.append(trim("feat"))
        elif subject.startswith("fix:") or subject.startswith("fix("):
            fixed.append(trim("fix"))
        elif (
            subject.startswith("refactor:")
            or subject.startswith("refactor(")
            or subject.startswith("perf:")
            or subject.startswith("perf(")
            or subject.startswith("docs:")
            or subject.startswith("docs(")
            or subject.startswith("chore:")
            or subject.startswith("chore(")
            or subject.startswith("build:")
            or subject.startswith("build(")
        ):
            prefix = subject.split(":", 1)[0].split("(", 1)[0]
            changed.append(trim(prefix))
        elif subject.startswith("security:") or subject.startswith("security("):
            security.append(trim("security"))
        elif "breaking" in lowered or "!:" in subject:
            changed.append(f"**BREAKING**: {subject}")

    sections: list[str] = []
    if added:
        sections.append("### Added\n\n" + "\n".join(f"- {item}" for item in added))
    if changed:
        sections.append("### Changed\n\n" + "\n".join(f"- {item}" for item in changed))
    if fixed:
        sections.append("### Fixed\n\n" + "\n".join(f"- {item}" for item in fixed))
    if security:
        sections.append(
            "### Security\n\n" + "\n".join(f"- {item}" for item in security)
        )
    return "\n\n".join(section.strip() for section in sections if section.strip()).strip()


def split_unreleased(text: str) -> tuple[str, str, str]:
    marker_index = text.find(UNRELEASED)
    if marker_index == -1:
        raise SystemExit(
            "CHANGELOG.md is missing '## [Unreleased]'; refusing to guess."
        )

    body_start = marker_index + len(UNRELEASED)
    next_heading = re.search(
        VERSION_HEADING_RE, text[body_start:], flags=re.MULTILINE
    )
    if next_heading is None:
        return text[:marker_index], text[body_start:], ""

    next_index = body_start + next_heading.start()
    return text[:marker_index], text[body_start:next_index], text[next_index:]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--generate-if-empty",
        action="store_true",
        help="Generate changelog bullets from git history if Unreleased is empty",
    )
    args = parser.parse_args()

    repo_root = pathlib.Path(__file__).resolve().parent.parent
    version_path = repo_root / "VERSION"
    changelog_path = repo_root / "CHANGELOG.md"

    if not version_path.is_file():
        print(f"VERSION not found at {version_path}", file=sys.stderr)
        return 1
    if not changelog_path.is_file():
        print(f"CHANGELOG.md not found at {changelog_path}", file=sys.stderr)
        return 1

    version = version_path.read_text(encoding="utf-8").strip()
    text = changelog_path.read_text(encoding="utf-8")
    today = datetime.date.today().isoformat()

    if f"## [{version}]" in text:
        print(
            f"CHANGELOG already has '## [{version}]' section; nothing to close."
        )
        return 0

    try:
        prefix, unreleased_body, suffix = split_unreleased(text)
    except SystemExit as error:
        print(str(error), file=sys.stderr)
        return 1

    body = unreleased_body.strip()
    if args.generate_if_empty and not body:
        body = generate_changelog_body(repo_root)
        if body:
            print(
                "CHANGELOG generated from commit history for empty Unreleased section."
            )

    parts = [prefix.rstrip(), UNRELEASED, "", f"## [{version}] - {today}"]
    if body:
        parts.extend(["", body])
    new_text = "\n".join(parts).rstrip() + "\n"
    if suffix:
        new_text += "\n" + suffix.lstrip("\n")

    changelog_path.write_text(new_text, encoding="utf-8")
    print(f"CHANGELOG closed: Unreleased -> [{version}] - {today}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
