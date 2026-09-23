#!/usr/bin/env python3
"""Keep tracked string catalogs in Xcode's JSON format without changing content."""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key!r}")
        result[key] = value
    return result


def reject_constant(value):
    raise ValueError(f"invalid JSON constant: {value}")


def format_catalog(raw):
    catalog = json.loads(raw, object_pairs_hook=unique_object, parse_constant=reject_constant)
    formatted = json.dumps(
        catalog, ensure_ascii=False, sort_keys=True, indent=2, separators=(",", " : ")
    )
    # Xcode expands empty objects with a blank line and writes no trailing newline.
    return re.sub(
        r"(?m)^( *)(.* : )?\{\}(,?)$",
        lambda match: match[1] + (match[2] or "") + "{\n\n" + match[1] + "}" + match[3],
        formatted,
    ).encode("utf-8")


def tracked_catalogs():
    output = subprocess.check_output(
        ["git", "ls-files", "-z", "--", "*.xcstrings"], cwd=ROOT
    )
    return [ROOT / path.decode("utf-8") for path in output.split(b"\0") if path]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="report formatting drift without writing")
    mode.add_argument("--write", action="store_true", help="format catalogs in place")
    parser.add_argument("paths", nargs="*", type=Path, help="defaults to all Git-tracked .xcstrings files")
    args = parser.parse_args()

    try:
        paths = args.paths or tracked_catalogs()
        # Validate every input before writing any file.
        changes = []
        for path in paths:
            try:
                original = path.read_bytes()
                formatted = format_catalog(original)
            except (OSError, ValueError, UnicodeError) as error:
                raise ValueError(f"{path}: {error}") from error
            if original != formatted:
                changes.append((path, formatted))
        for path, formatted in changes:
            if args.write:
                path.write_bytes(formatted)
            print(f"{'Formatted' if args.write else 'Needs formatting'}: {path}")
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 2

    if args.check and changes:
        print("Run: just format-localizations", file=sys.stderr)
        return 1
    print(f"Checked {len(paths)} string catalog(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
