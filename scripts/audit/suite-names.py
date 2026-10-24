#!/usr/bin/env python3
"""Suite names declared in Swift test files, via the shared scanner.

One place for "which suites live in this file" so the shell loops and the
cost scripts do not each carry a regex that misses `nonisolated struct`,
attribute-prefixed declarations or XCTest subclasses.

Usage:
  suite-names.py FILE [FILE...]        one type name per line, in file order
  suite-names.py --map FILE [FILE...]  `display<TAB>type` for suites declared
                                       with `@Suite("Display Name")`; xcresult
                                       and Swift Testing's log name such suites
                                       by display name, the inventory by type.
  suite-names.py --warn FILE ...       also print a warning to stderr when a
                                       file contains @Test or XCTestCase but
                                       yields no suite.
"""
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import swiftscan  # noqa: E402

DISPLAY = re.compile(r'@Suite\(\s*"((?:[^"\\]|\\.)*)"')


def display_name(decl, masked):
    """The `@Suite("…")` display name, read from the raw source (the scanner's
    code view blanks string contents)."""
    if not decl.has_attribute("Suite"):
        return None
    # The header view blanks string contents and may not count the newline
    # before the keyword, so look back in the raw source over a generous window
    # and stop at the previous declaration's closing brace.
    window = masked.source[max(0, decl.start - 400):decl.start]
    cut = window.rfind("}")
    if cut != -1:
        window = window[cut + 1:]
    matches = list(DISPLAY.finditer(window))
    return matches[-1].group(1) if matches else None


def main(argv):
    mapping = "--map" in argv
    warn = "--warn" in argv
    paths = [a for a in argv if not a.startswith("--")]
    for path in paths:
        try:
            text = open(path, encoding="utf-8").read()
            masked = swiftscan.mask(text)
            suites = swiftscan.suites_in_file(path, masked)
        except (OSError, UnicodeDecodeError) as exc:
            print(f"suite-names: cannot read {path}: {exc}", file=sys.stderr)
            continue
        if warn and not suites and ("@Test" in text or "XCTestCase" in text):
            print(f"suite-names: {path} has tests but no recognised suite", file=sys.stderr)
        for suite in suites:
            if mapping:
                shown = display_name(suite.declaration, masked)
                if shown:
                    print(f"{shown}\t{suite.name}")
            else:
                print(suite.name)


if __name__ == "__main__":
    main(sys.argv[1:])
