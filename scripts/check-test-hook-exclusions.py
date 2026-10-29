#!/usr/bin/env python3
"""Fail on stale file exclusions in SwiftLint's `no_test_hook_in_app_code` rule.

The rule's `excluded` list names app files that still have test-only hooks
(#1241). An entry whose file is gone or no longer has a `…ForTesting` name in
code would let a new hook into that file unnoticed, so every file entry must
exist and still have one. Comments and string literals don't count, matching
the rule's `excluded_match_kinds`; the stripping is approximate (a hook used
only inside a string interpolation or a nested block comment can disagree with
SwiftLint), which is enough to spot a file whose hooks are gone.
"""

import argparse
import re
import sys
from pathlib import Path

RULE = "no_test_hook_in_app_code"
HOOK = re.compile(r"\b(?:\w*ForTesting|forTesting)\w*")
# The tests target, the only directory the rule excludes.
TESTS_ENTRY = "(^|/)whitenoise-iosTests/"
# A file entry, as written in .swiftlint.yml: '(^|/)<escaped relative path>\.swift$'.
FILE_ENTRY = re.compile(r"^\(\^\|/\)(?P<path>.+\\\.swift)\$$")
# Line and block comments, then string literals (multi-line first). Good enough
# for deciding whether a hook name is still in code.
NON_CODE = re.compile(r'//[^\n]*|/\*.*?\*/|"""(?:\\.|[^\\])*?"""|"(?:\\.|[^"\\\n])*"', re.DOTALL)


def excluded_entries(config: str) -> list[str]:
    lines = config.splitlines()
    try:
        start = lines.index(f"  {RULE}:")
    except ValueError:
        sys.exit(f"error: .swiftlint.yml has no `{RULE}` custom rule")
    entries: list[str] = []
    in_excluded = False
    for line in lines[start + 1:]:
        if re.match(r"^  \S", line):  # next custom rule
            break
        if re.match(r"^    \w+:", line):  # a key of this rule
            in_excluded = line.startswith("    excluded:")
            if in_excluded and line.strip() != "excluded:":
                sys.exit(f"error: write `{RULE}`'s exclusions as a list, one '- ...' item per line")
            continue
        if not in_excluded or not line.strip() or line.lstrip().startswith("#"):
            continue
        item = re.match(r"^    - '(.*)'$", line)
        if not item:
            sys.exit(f"error: unexpected line in `{RULE}`'s exclusions: {line.strip()}")
        entries.append(item.group(1))
    if not entries:
        sys.exit(f"error: `{RULE}` has no `excluded` list")
    return entries


def has_hook_in_code(source: str) -> bool:
    return HOOK.search(NON_CODE.sub("", source)) is not None


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    root = parser.parse_args().root

    problems: list[str] = []
    for entry in excluded_entries((root / ".swiftlint.yml").read_text(encoding="utf-8")):
        if entry == TESTS_ENTRY:
            continue
        match = FILE_ENTRY.match(entry)
        if not match:
            problems.append(f"{entry}: write file exclusions as '(^|/)<path>\\.swift$'")
            continue
        relative = re.sub(r"\\(.)", r"\1", match.group("path"))
        path = root / relative
        if not path.is_file():
            problems.append(f"{relative}: excluded but missing")
        elif not has_hook_in_code(path.read_text(encoding="utf-8")):
            problems.append(f"{relative}: excluded but has no hook left; remove it from `{RULE}`'s exclusions")

    for problem in problems:
        print(f"error: {problem}", file=sys.stderr)
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
