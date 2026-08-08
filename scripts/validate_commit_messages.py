#!/usr/bin/env python3
# SPDX-License-Identifier: MPL-2.0
"""Validate Sierra History Bridge commit messages and pull request titles."""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys


ALLOWED_SUBJECT = re.compile(
    r"^(feat|fix|docs|refactor|test|build|ci|chore|perf|revert)"
    r"(\([a-z0-9][a-z0-9-]*\))?!?: [a-z0-9].+$"
)
SUBSTANTIVE_SUBJECT = re.compile(r"^(feat|fix|refactor|build|ci|perf|revert)(\(|!|:)")
TEMPORARY_SUBJECT = re.compile(
    r"(^|: )(wip|fixup!?|squash!?|retry|try ci|address review|updates?)(:|\s|$)",
    re.IGNORECASE,
)


def validate_message(message: str, label: str, *, subject_only: bool = False) -> list[str]:
    """Return policy failures for one complete commit message or PR title."""
    subject, separator, body = message.replace("\r\n", "\n").partition("\n")
    failures: list[str] = []

    if len(subject) > 72:
        failures.append(f"{label}: subject exceeds 72 characters")
    if not ALLOWED_SUBJECT.fullmatch(subject):
        failures.append(
            f"{label}: subject does not match the project Conventional Commit format"
        )
    if subject.endswith("."):
        failures.append(f"{label}: subject must not end with a period")
    if TEMPORARY_SUBJECT.search(subject):
        failures.append(f"{label}: temporary or process-oriented subject is prohibited")

    nonblank_body_lines = [line for line in body.splitlines() if line.strip()]
    if (
        not subject_only
        and SUBSTANTIVE_SUBJECT.match(subject)
        and (not separator or len(body.strip()) < 80 or len(nonblank_body_lines) < 2)
    ):
        failures.append(
            f"{label}: substantive commits require a detailed multi-line body"
        )

    return failures


def git_output(*arguments: str) -> str:
    """Run Git and return UTF-8 text, failing with Git's diagnostic."""
    return subprocess.run(
        ["git", *arguments],
        check=True,
        text=True,
        encoding="utf-8",
        stdout=subprocess.PIPE,
    ).stdout


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--message-file", type=pathlib.Path)
    parser.add_argument("--all-reachable", action="store_true")
    parser.add_argument("--pull-request-title")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    failures: list[str] = []

    if not (args.message_file or args.all_reachable or args.pull_request_title):
        raise SystemExit("select at least one validation target")

    if args.message_file:
        failures.extend(
            validate_message(
                args.message_file.read_text(encoding="utf-8"), str(args.message_file)
            )
        )

    if args.all_reachable:
        commit_ids = git_output("rev-list", "--reverse", "HEAD").splitlines()
        for commit_id in commit_ids:
            failures.extend(
                validate_message(
                    git_output("show", "-s", "--format=%B", commit_id), commit_id
                )
            )

    if args.pull_request_title:
        failures.extend(
            validate_message(
                args.pull_request_title, "pull request title", subject_only=True
            )
        )

    if failures:
        for failure in failures:
            print(failure, file=sys.stderr)
        return 1

    print("Commit-message policy passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
