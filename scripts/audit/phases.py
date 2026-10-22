#!/usr/bin/env python3
"""Break one test run into phases using only xcodebuild's own markers.

Input is a raw xcodebuild log, ideally one written by
scripts/audit/timed-xcodebuild.sh so each line starts with a
`YYYY-MM-DDTHH:MM:SS ` wall-clock prefix, plus optionally an .xcresult bundle
read through `xcrun xcresulttool get test-results summary|tests`. One row is
appended to build/audit/phases.csv and the phase table plus the slowest Swift
Testing suites are printed.

Markers (emitted by scripts/test.sh, xcodebuild, XCTest or Swift Testing):
  ==> build-for-testing: Ns / ==> test-without-building: Ns      scripts/test.sh
  Testing started                                                 xcodebuild
  Test Suite 'All tests' started at <clock>. / passed|failed at   XCTest
  Test run started. / Test run with N tests in M suites passed after X seconds.
  Suite <name> passed|failed after X seconds.                     Swift Testing
  <clock> xcodebuild[...] IDETestOperationsObserverDebug: X elapsed -- Testing started completed.
  Test session results, code coverage, and logs:                  xcodebuild

Logs that went through xcbeautify lose most of these lines, and a log without
the wall-clock prefix cannot place Swift Testing's start. Both degrade to empty
cells rather than estimates; the slowest-suite list still comes out.

Clocks: every log clock is the runner's local time, while the xcresult summary
stores epoch seconds that this script converts in the *analyst's* local time
zone. Analysing CI artifacts on a machine in another zone therefore skews any
cell that mixes the two by the zone difference. When a raw log is present its
own markers win for testing_started_at and run_end_at and the summary only
fills gaps; a disagreement over a minute is reported on stderr.
"""
import argparse
import csv
import datetime
import json
import pathlib
import re
import subprocess
import sys

CSV_COLUMNS = [
    "run_id",
    "build_for_testing_s",
    "test_without_building_s",
    "testing_started_at",
    "first_xctest_suite_at",
    "xctest_s",
    "swift_testing_started_at",
    "swift_testing_s",
    "gap_build_end_to_first_test_s",
    "finalize_s",
]

PREFIX = re.compile(r"^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}) (.*)$")
CLOCK = r"\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d+"
PHASE_MARKER = re.compile(r"^==> (build-for-testing|test-without-building): (\d+)s$")
XCTEST_STARTED = re.compile(r"^Test Suite 'All tests' started at (" + CLOCK + r")\.")
XCTEST_ENDED = re.compile(r"^Test Suite 'All tests' (?:passed|failed) at (" + CLOCK + r")\.")
ST_STARTED = re.compile(r"^(?:\S )?Test run started\.")
ST_ENDED = re.compile(
    r"^(?:\S )?Test run with (\d+) tests?(?: in (\d+) suites?)? (passed|failed) after ([\d.]+) seconds"
)
ANSI_SGR = re.compile(r"\x1b\[[0-9;]*m")
ST_SUITE = re.compile(r"^(?:\S )?Suite (.+?) (passed|failed) after ([\d.]+) seconds")
IDE_ELAPSED = re.compile(
    r"^(" + CLOCK + r") xcodebuild\[.*IDETestOperationsObserverDebug: ([\d.]+) elapsed -- Testing started completed"
)
SESSION_RESULTS = re.compile(r"^Test session results, code coverage, and logs:")
DURATION_TOKEN = re.compile(r"([\d.,]+)\s*(ms|h|m|s)")


def parse_clock(text):
    return datetime.datetime.strptime(text, "%Y-%m-%d %H:%M:%S.%f")


def parse_prefix(text):
    return datetime.datetime.strptime(text, "%Y-%m-%dT%H:%M:%S")


def parse_log(lines):
    """Pull the raw markers out of a log; every field is None until seen."""
    parsed = {
        "build_for_testing_s": None,
        "test_without_building_s": None,
        "build_end_at": None,
        "first_line_at": None,
        "testing_started_line_at": None,
        "xctest_started_at": None,
        "xctest_ended_at": None,
        "swift_testing_started_at": None,
        "swift_testing_end_line_at": None,
        "swift_testing_s": None,
        "swift_testing_tests": None,
        "swift_testing_suites": None,
        "ide_elapsed_s": None,
        "ide_line_at": None,
        "session_results_at": None,
        "suites": [],
    }
    for raw in lines:
        raw = ANSI_SGR.sub("", raw.rstrip("\n"))
        stamp = None
        match = PREFIX.match(raw)
        if match:
            stamp = parse_prefix(match.group(1))
            raw = match.group(2)
            if parsed["first_line_at"] is None:
                parsed["first_line_at"] = stamp
        line = raw.strip()
        match = PHASE_MARKER.match(line)
        if match:
            parsed[match.group(1).replace("-", "_") + "_s"] = int(match.group(2))
            if match.group(1) == "build-for-testing":
                parsed["build_end_at"] = stamp
            continue
        if line == "Testing started":
            parsed["testing_started_line_at"] = stamp
            continue
        match = XCTEST_STARTED.match(line)
        if match:
            if parsed["xctest_started_at"] is None:
                parsed["xctest_started_at"] = parse_clock(match.group(1))
            continue
        match = XCTEST_ENDED.match(line)
        if match:
            parsed["xctest_ended_at"] = parse_clock(match.group(1))
            continue
        if ST_STARTED.match(line):
            if parsed["swift_testing_started_at"] is None:
                parsed["swift_testing_started_at"] = stamp
            continue
        match = ST_ENDED.match(line)
        if match:
            parsed["swift_testing_tests"] = int(match.group(1))
            parsed["swift_testing_suites"] = int(match.group(2)) if match.group(2) else None
            parsed["swift_testing_s"] = float(match.group(4))
            parsed["swift_testing_end_line_at"] = stamp
            continue
        match = ST_SUITE.match(line)
        if match:
            parsed["suites"].append((match.group(1).strip('"'), match.group(2), float(match.group(3))))
            continue
        match = IDE_ELAPSED.match(line)
        if match:
            parsed["ide_line_at"] = parse_clock(match.group(1))
            parsed["ide_elapsed_s"] = float(match.group(2))
            continue
        if SESSION_RESULTS.match(line):
            parsed["session_results_at"] = stamp
    return parsed


def parse_duration(text):
    """Turn xcresulttool's `0,083s` / `3s` / `1m 2s` strings into seconds."""
    if not text:
        return None
    total = 0.0
    seen = False
    for value, unit in DURATION_TOKEN.findall(text):
        seen = True
        number = float(value.replace(",", "."))
        total += number * {"ms": 0.001, "s": 1, "m": 60, "h": 3600}[unit]
    return total if seen else None


def suite_durations_from_xcresult(tests):
    """Sum test-case durations under each `Test Suite` node of the tests tree.

    Suites run in parallel, so this is CPU-ish time per suite, not wall time;
    it is the only per-suite number a pretty (xcbeautify) CI run leaves behind.
    """
    found = []

    def total(node):
        seconds = 0.0
        count = 0
        for child in node.get("children", []):
            if child.get("nodeType") == "Test Case":
                seconds += parse_duration(child.get("duration")) or 0.0
                count += 1
            else:
                child_seconds, child_count = total(child)
                seconds += child_seconds
                count += child_count
        return seconds, count

    def walk(node):
        if node.get("nodeType") == "Test Suite":
            seconds, count = total(node)
            found.append((node.get("name", "?"), seconds, count))
        for child in node.get("children", []):
            walk(child)

    for node in tests.get("testNodes", []):
        walk(node)
    return found


def seconds_between(start, end):
    if start is None or end is None:
        return None
    return (end - start).total_seconds()


def compute_phases(parsed, summary=None, run_id="run", warn=None):
    """Combine log markers and an optional xcresult summary into the CSV row.

    Log markers win over the summary (see the module docstring on clocks);
    `warn` receives a message when the two disagree by more than a minute.
    """
    summary = summary or {}
    summary_start = summary.get("startTime")
    summary_finish = summary.get("finishTime")
    summary_start = datetime.datetime.fromtimestamp(summary_start) if summary_start else None
    summary_finish = datetime.datetime.fromtimestamp(summary_finish) if summary_finish else None

    testing_started_at = None
    if parsed["ide_line_at"] and parsed["ide_elapsed_s"] is not None:
        testing_started_at = parsed["ide_line_at"] - datetime.timedelta(seconds=parsed["ide_elapsed_s"])
    if testing_started_at is not None and summary_start is not None and warn is not None:
        skew = abs((testing_started_at - summary_start).total_seconds())
        if skew > 60:
            warn(f"log and xcresult disagree on the test start by {skew:.0f}s; "
                 "the xcresult epoch is shown in this machine's time zone, the log in the runner's")
    if testing_started_at is None:
        testing_started_at = summary_start
    if testing_started_at is None:
        testing_started_at = parsed["testing_started_line_at"]

    xctest_started = parsed["xctest_started_at"]
    xctest_s = seconds_between(xctest_started, parsed["xctest_ended_at"])

    st_started = parsed["swift_testing_started_at"]
    st_s = parsed["swift_testing_s"]
    st_ended = parsed["swift_testing_end_line_at"]
    if st_started is None and st_ended is not None and st_s is not None:
        st_started = st_ended - datetime.timedelta(seconds=st_s)
    if st_ended is None and st_started is not None and st_s is not None:
        st_ended = st_started + datetime.timedelta(seconds=st_s)

    phase_start = parsed["build_end_at"] or parsed["first_line_at"] or testing_started_at
    first_test = min((t for t in (xctest_started, st_started) if t is not None), default=None)
    gap_s = seconds_between(phase_start, first_test)

    run_end = parsed["session_results_at"] or parsed["ide_line_at"] or summary_finish
    tests_end = None
    xctest_ran = xctest_started is not None
    st_ran = st_s is not None or st_started is not None
    ends = []
    if xctest_ran:
        ends.append(parsed["xctest_ended_at"])
    if st_ran:
        ends.append(st_ended)
    if ends and all(end is not None for end in ends):
        tests_end = max(ends)
    finalize_s = seconds_between(tests_end, run_end)

    return {
        "run_id": run_id,
        "build_for_testing_s": parsed["build_for_testing_s"],
        "test_without_building_s": parsed["test_without_building_s"],
        "testing_started_at": testing_started_at,
        "first_xctest_suite_at": xctest_started,
        "xctest_s": xctest_s,
        "swift_testing_started_at": st_started,
        "swift_testing_s": st_s,
        "gap_build_end_to_first_test_s": gap_s,
        "finalize_s": finalize_s,
        "ide_elapsed_s": parsed["ide_elapsed_s"],
        "swift_testing_tests": parsed["swift_testing_tests"],
        "swift_testing_suites": parsed["swift_testing_suites"],
        "run_end_at": run_end,
    }


def format_cell(value):
    if value is None:
        return ""
    if isinstance(value, datetime.datetime):
        return value.isoformat(timespec="milliseconds")
    if isinstance(value, float):
        return f"{value:.3f}"
    return str(value)


def append_csv(path, row):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    write_header = not path.exists() or path.stat().st_size == 0
    with path.open("a", newline="") as handle:
        writer = csv.writer(handle)
        if write_header:
            writer.writerow(CSV_COLUMNS)
        writer.writerow([format_cell(row[column]) for column in CSV_COLUMNS])


def slowest(suites, top, seconds_index=1):
    """Longest-first prefix of the suite tuples; ties keep input order."""
    return sorted(suites, key=lambda item: -item[seconds_index])[:top]


PHASE_NOTES = [
    ("build_for_testing_s", "`==> build-for-testing` marker from scripts/test.sh"),
    ("test_without_building_s", "`==> test-without-building` marker from scripts/test.sh"),
    ("gap_build_end_to_first_test_s",
     "build end (or log start) to the first XCTest suite or Swift Testing run; "
     "includes the remaining simulator-boot wait, test-host install and the discovery launch"),
    ("xctest_s", "XCTest `All tests` started to passed/failed"),
    ("swift_testing_s", "Swift Testing `Test run with N tests` duration"),
    ("finalize_s", "last test end to the run end (`Test session results`, else IDE clock, else xcresult finish)"),
    ("ide_elapsed_s", "`IDETestOperationsObserverDebug` elapsed: xcodebuild's own test-phase total"),
]
TIMESTAMP_NOTES = [
    ("testing_started_at", "IDE elapsed back-dated from its clock, else xcresult startTime, else `Testing started`"),
    ("first_xctest_suite_at", "`Test Suite 'All tests' started at`"),
    ("swift_testing_started_at", "`Test run started.` wall-clock prefix"),
    ("run_end_at", "`Test session results` prefix, else IDE line clock, else xcresult finishTime"),
]


def render(row, log_suites, xcresult_suites, top, markdown):
    out = []
    if markdown:
        out.append(f"## Test phases: {row['run_id']}")
        out.append("")
        out.append("| Phase | Seconds | Source |")
        out.append("|---|---:|---|")
        for key, note in PHASE_NOTES:
            out.append(f"| {key} | {format_cell(row[key])} | {note} |")
        out.append("")
        out.append("| Timestamp | Value | Source |")
        out.append("|---|---|---|")
        for key, note in TIMESTAMP_NOTES:
            out.append(f"| {key} | {format_cell(row[key])} | {note} |")
        if row["swift_testing_tests"] is not None:
            out.append("")
            suites = f" in {row['swift_testing_suites']} suites" if row["swift_testing_suites"] is not None else ""
            out.append(f"Swift Testing ran {row['swift_testing_tests']} tests{suites}.")
    else:
        out.append(f"Test phases: {row['run_id']}")
        for key, note in PHASE_NOTES:
            out.append(f"  {key:32} {format_cell(row[key]):>10}  {note}")
        for key, note in TIMESTAMP_NOTES:
            out.append(f"  {key:32} {format_cell(row[key]):>23}  {note}")

    def table(title, header, rows):
        out.append("")
        if markdown:
            out.append(f"### {title}")
            out.append("")
            out.append("| " + " | ".join(header) + " |")
            out.append("|" + "|".join("---:" if i else "---" for i in range(len(header))) + "|")
            for cells in rows:
                out.append("| " + " | ".join(cells) + " |")
        else:
            out.append(title)
            for cells in rows:
                out.append("  " + "  ".join(f"{c:>10}" if i else f"{c:48}" for i, c in enumerate(cells)))

    if log_suites:
        table(
            f"Slowest {len(log_suites)} Swift Testing suites (log wall time; suites overlap)",
            ["Suite", "Seconds", "Result"],
            [(name, f"{seconds:.3f}", status) for name, status, seconds in log_suites],
        )
    if xcresult_suites:
        table(
            f"Slowest {len(xcresult_suites)} suites by summed test-case duration (xcresult)",
            ["Suite", "Seconds", "Cases"],
            [(name, f"{seconds:.3f}", str(count)) for name, seconds, count in xcresult_suites],
        )
    if not log_suites and not xcresult_suites:
        out.append("")
        out.append(f"No per-suite durations found (top {top} requested).")
    return "\n".join(out) + "\n"


def xcresulttool(subcommand, bundle):
    result = subprocess.run(
        ["xcrun", "xcresulttool", "get", "test-results", subcommand, "--path", str(bundle)],
        check=True,
        capture_output=True,
        text=True,
    )
    return json.loads(result.stdout)


def load_xcresult(bundle, warn):
    """Read the summary and tests tree; a partial or unreadable bundle gives (None, None)."""
    try:
        return xcresulttool("summary", bundle), xcresulttool("tests", bundle)
    except (subprocess.CalledProcessError, OSError, ValueError) as error:
        detail = getattr(error, "stderr", None) or str(error)
        warn(f"could not read {bundle}: {detail.strip()}")
        return None, None


def main(argv=None):
    root = pathlib.Path(__file__).resolve().parents[2]
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("log", nargs="?", help="raw xcodebuild log (timed-xcodebuild.sh output)")
    parser.add_argument("--log", dest="log_option", help="same as the positional log")
    parser.add_argument("--xcresult", help=".xcresult bundle read through xcresulttool")
    parser.add_argument("--csv", default=str(root / "build" / "audit" / "phases.csv"))
    parser.add_argument("--no-csv", action="store_true", help="print only; do not append a row")
    parser.add_argument("--run-id", help="row label; defaults to the log or bundle name")
    parser.add_argument("--markdown", action="store_true", help="render for GITHUB_STEP_SUMMARY")
    parser.add_argument("--top", type=int, default=20)
    args = parser.parse_args(argv)

    log_path = args.log_option or args.log
    if not log_path and not args.xcresult:
        parser.error("give a log, an --xcresult bundle, or both")

    parsed = parse_log([])
    if log_path:
        with open(log_path, encoding="utf-8", errors="replace") as handle:
            parsed = parse_log(handle)

    def warn(message):
        print(f"phases: {message}", file=sys.stderr)

    summary = None
    xcresult_suites = []
    if args.xcresult:
        summary, tests = load_xcresult(args.xcresult, warn)
        if tests is not None:
            xcresult_suites = slowest(suite_durations_from_xcresult(tests), args.top)

    run_id = args.run_id or pathlib.Path(log_path or args.xcresult).stem
    row = compute_phases(parsed, summary, run_id, warn)
    if not args.no_csv:
        append_csv(args.csv, row)
    log_suites = slowest(parsed["suites"], args.top, seconds_index=2)
    sys.stdout.write(render(row, log_suites, xcresult_suites, args.top, args.markdown))
    return 0


if __name__ == "__main__":
    sys.exit(main())
