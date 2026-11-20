#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

DESTINATION="${WN_TEST_DESTINATION:-$(scripts/pick-simulator.sh)}"
RESULT_BUNDLE="${WN_TEST_RESULT_BUNDLE:-build/TestResults.xcresult}"

rm -rf "$RESULT_BUNDLE"

xcodebuild_args=(
  -project whitenoise-ios.xcodeproj
  -scheme "Whitenoise (Staging)"
  -destination "$DESTINATION"
  -skipPackagePluginValidation
  -skipMacroValidation
)

# Opt-in cache locations. Unset locally so developers keep sharing Xcode's
# DerivedData with the IDE; CI points them at gitignored build/ subdirectories
# it can restore between runs.
if [ -n "${WN_TEST_DERIVED_DATA:-}" ]; then
  xcodebuild_args+=(-derivedDataPath "$WN_TEST_DERIVED_DATA")
fi
if [ -n "${WN_TEST_SOURCE_PACKAGES:-}" ]; then
  xcodebuild_args+=(-clonedSourcePackagesDirPath "$WN_TEST_SOURCE_PACKAGES")
fi

build_settings=(
  ONLY_ACTIVE_ARCH=YES
  CODE_SIGN_STYLE=Manual
  DEVELOPMENT_TEAM=""
  PROVISIONING_PROFILE_SPECIFIER=""
  CODE_SIGN_IDENTITY="-"
  CODE_SIGNING_ALLOWED=YES
)
# Sign ad-hoc with no team rather than skipping signing. The App Group
# entitlement is embedded only when signing runs; without it,
# containerURL(forSecurityApplicationGroupIdentifier:) returns nil and the test
# host fatal-errors initializing Marmot storage at launch. The simulator reads
# the app group from the simulated entitlements, which carry no team prefix, so
# manual ad-hoc signing works on a CI runner with no signing identity.

# Nothing indexes a CI checkout, so skip index-while-building there. Local runs
# keep writing the index store the IDE reads.
if [ -n "${CI:-}" ]; then
  build_settings+=(COMPILER_INDEX_STORE_ENABLE=NO)
fi

# Content-addressed compiler caching. Cache keys hash compiler inputs, not file
# mtimes, so a fresh clone still replays cached objects; prefix mapping keeps
# keys independent of the checkout path.
if [ -n "${WN_TEST_COMPILATION_CACHE:-}" ]; then
  build_settings+=(
    COMPILATION_CACHE_ENABLE_CACHING=YES
    COMPILATION_CACHE_CAS_PATH="$WN_TEST_COMPILATION_CACHE"
    COMPILATION_CACHE_KEEP_CAS_DIRECTORY=YES
    COMPILATION_CACHE_LIMIT_SIZE="${WN_TEST_COMPILATION_CACHE_LIMIT:-2000000000}"
    SWIFT_ENABLE_COMPILE_CACHE=YES
    CLANG_ENABLE_COMPILE_CACHE=YES
    SWIFT_ENABLE_EXPLICIT_MODULES=YES
    CLANG_ENABLE_EXPLICIT_MODULES=YES
    SWIFT_ENABLE_PREFIX_MAPPING=YES
  )
fi

# Opt-in timing for CI experiments. With WN_TEST_TIMING_DIR set, that directory
# receives the raw xcodebuild output with seconds-since-start stamps, the
# build's own result bundle, a system probe every 30 seconds, and a summary of
# when each build milestone happened. xcbeautify buffers its output, so the job
# log alone cannot place them.
SCRIPT_START=$(date +%s)
TIMING_DIR="${WN_TEST_TIMING_DIR:-}"
build_only_args=()
if [ -n "$TIMING_DIR" ]; then
  mkdir -p "$TIMING_DIR"
  : > "$TIMING_DIR/summary.txt"
  rm -rf "$TIMING_DIR/build-for-testing.xcresult"
  # The result bundle keeps Xcode's per-task timeline for the build.
  build_only_args=(-showBuildTimingSummary -resultBundlePath "$TIMING_DIR/build-for-testing.xcresult")
fi

# during-build overlaps the simulator boot with the build; after-build boots it
# once the compilers are done, so the two don't compete for memory and cores;
# job-start means the caller already started the boot, and this script only
# waits for it after the build.
BOOT_SIMULATOR="${WN_TEST_BOOT_SIMULATOR:-during-build}"
case "$BOOT_SIMULATOR" in
  during-build | after-build | job-start) ;;
  *)
    echo "WN_TEST_BOOT_SIMULATOR must be during-build, after-build or job-start, not '$BOOT_SIMULATOR'" >&2
    exit 2
    ;;
esac

elapsed() {
  echo "$(($(date +%s) - SCRIPT_START))"
}

# Print a line and, when timing, keep it for the summary.
note() {
  echo "$@"
  if [ -n "$TIMING_DIR" ]; then
    echo "$@" >> "$TIMING_DIR/summary.txt"
  fi
}

# Pass stdin through unchanged and keep a copy with each line stamped with the
# seconds since this script started. A copy that cannot be written is reported
# once and never stops the build.
stamp() {
  perl -MTime::HiRes=time -e '
    my ($path, $start) = @ARGV;
    my $failed = 0;
    open(my $copy, ">", $path) or die "$path: $!";
    select((select($copy), $| = 1)[0]);
    $| = 1;
    while (my $line = <STDIN>) {
      unless ($failed) {
        printf {$copy} "%8.1f %s", time - $start, $line
          or do { $failed = 1; warn "timing copy $path stopped: $!\n" };
      }
      print $line;
    }
    close($copy) or warn "timing copy $path did not close cleanly: $!\n";
  ' "$1" "$SCRIPT_START"
}

run() {
  if [ -n "$TIMING_DIR" ]; then
    # NSUnbufferedIO makes xcodebuild write each line as it happens; stderr
    # joins the copy so early diagnostics are stamped too.
    NSUnbufferedIO=YES xcodebuild "$@" 2>&1 | stamp "$TIMING_DIR/$1.raw.log" | {
      if command -v xcbeautify >/dev/null 2>&1; then xcbeautify; else cat; fi
    }
  elif command -v xcbeautify >/dev/null 2>&1; then
    xcodebuild "$@" | xcbeautify
  else
    xcodebuild "$@"
  fi
}

phase() {
  local label="$1"
  shift
  local start=$SECONDS
  local status=0
  if [ -n "$TIMING_DIR" ]; then
    note "==> ${label} invoked $(elapsed)s after start"
  fi
  "$@" || status=$?
  note "==> ${label}: $((SECONDS - start))s"
  return "$status"
}

# When each milestone first arrives in a stamped raw log. These are raw line
# arrivals, not the first xcbeautify output the job log shows. The raw log is
# kept whole, so a pattern that misses on a newer Xcode loses nothing.
milestones() {
  local log="$1" label pattern stamp_seconds
  [ -f "$log" ] || return 0
  note "==> first raw-line arrival in $(basename "$log"), seconds since scripts/test.sh started"
  while IFS=';' read -r label pattern; do
    stamp_seconds=$(LC_ALL=C grep -a -m1 -E "$pattern" "$log" | awk '{print $1}' || true)
    note "$(printf '    %-28s %s' "$label" "${stamp_seconds:--}")"
  done <<'PATTERNS'
first raw line;.
package resolution started;Resolve Package Graph
packages resolved;Resolved source packages
target graph computed;ComputeTargetDependencyGraph
build description created;CreateBuildDescription
first target-tagged line;\(in target '
first build task;^ *[0-9.]+ [A-Z][A-Za-z0-9]+[[:space:]].*\(in target '
first Clang dependency scan;^ *[0-9.]+ ScanDependencies[[:space:]]
first Swift compile;^ *[0-9.]+ SwiftCompile[[:space:]]
first app compile;^ *[0-9.]+ SwiftCompile[[:space:]].*\(in target 'whitenoise-ios'
first test-bundle compile;^ *[0-9.]+ SwiftCompile[[:space:]].*\(in target 'whitenoise-iosTests'
first link;^ *[0-9.]+ Ld[[:space:]]
build result;\*\* (TEST )?BUILD (SUCCEEDED|FAILED) \*\*
PATTERNS
}

probe_pid=""
if [ -n "$TIMING_DIR" ]; then
  # Swap, free memory, free disk, the six busiest processes and the four
  # largest, to show what holds the machine while the build is silent. One
  # failed sample must not end the probe.
  (
    set +euo pipefail
    while true; do
      printf '%6ds swap[%s] %s, %s GiB disk free\n' \
        "$(elapsed)" \
        "$(sysctl -n vm.swapusage)" \
        "$(memory_pressure -Q 2>/dev/null | tail -1)" \
        "$(df -g / | awk 'NR == 2 { print $4 }')"
      for order in -r -m; do
        [ "$order" = -r ] && rows='2,7p' || rows='2,5p'
        ps -Ao pcpu,rss,state,comm "$order" | sed -n "$rows" | awk -v order="$order" '{
          cpu = $1; rss = $2; state = $3; $1 = ""; $2 = ""; $3 = "";
          count = split($0, parts, "/");
          printf "          %s %5s%% %6d MB %-4s %s\n", (order == "-r" ? "cpu" : "mem"), cpu, rss / 1024, state, parts[count]
        }'
      done
      sleep 30
    done
  ) > "$TIMING_DIR/probe.log" 2>&1 &
  probe_pid=$!
fi

boot_pid=""
finish() {
  # Reap helpers quietly so the shell doesn't print a "Terminated" notice. A
  # boot still running after a failed build would otherwise hold the step open.
  local helper
  for helper in "$probe_pid" "$boot_pid"; do
    if [ -n "$TIMING_DIR" ] && [ -n "$helper" ]; then
      { kill "$helper" && wait "$helper"; } 2>/dev/null || true
    fi
  done
  if [ -n "$TIMING_DIR" ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ] && [ -f "$TIMING_DIR/summary.txt" ]; then
    {
      echo '```'
      echo "simulator boot: $BOOT_SIMULATOR"
      echo "destination: $DESTINATION"
      cat "$TIMING_DIR/summary.txt"
      echo '```'
    } >> "$GITHUB_STEP_SUMMARY"
  fi
}
trap finish EXIT
if [ -n "$TIMING_DIR" ]; then
  # A timed-out or cancelled step still writes its summary.
  trap 'exit 130' INT
  trap 'exit 143' TERM
fi

case "$DESTINATION" in
  *id=*)
    udid="${DESTINATION##*id=}"
    udid="${udid%%,*}"
    ;;
  *) udid="" ;;
esac

boot_simulator() {
  if [ -z "$TIMING_DIR" ]; then
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 || true
    return 0
  fi
  # A boot that failed, or a device that was already booted, is not a sample
  # of boot cost, so say which this was.
  local start=$SECONDS status=0 log="$TIMING_DIR/simulator-boot.log" outcome state
  local boot_flag="-b"
  state=$(simulator_state)
  if [ "$BOOT_SIMULATOR" = job-start ]; then
    note "==> simulator before post-build wait, $(elapsed)s after start: ${state}"
  else
    note "==> simulator before boot, $(elapsed)s after start: ${state}"
  fi
  if [ "$BOOT_SIMULATOR" = job-start ]; then
    # The caller's own boot log is simulator-boot.log; this is only the wait,
    # so it must not start a boot itself.
    log="$TIMING_DIR/simulator-wait-after-build.log"
    case "$state" in
      *"(Shutdown)"* | "not listed")
        note "==> INVALID job-start sample: the simulator was not booting after the build, booting it now"
        ;;
      *) boot_flag="" ;;
    esac
  fi
  # shellcheck disable=SC2086
  xcrun simctl bootstatus "$udid" $boot_flag > "$log" 2>&1 || status=$?
  # bootstatus exits 0 even when the boot ends in a failed data migration.
  if [ "$status" -ne 0 ]; then
    outcome="FAILED with status ${status}"
  elif LC_ALL=C grep -a -q "Data Migration Failed" "$log" "$TIMING_DIR/simulator-boot.log" 2>/dev/null; then
    outcome="returned, reporting Data Migration Failed"
  else
    outcome="ready"
  fi
  note "==> simulator-boot (${BOOT_SIMULATOR}): $((SECONDS - start))s, ${outcome} $(elapsed)s after start, see $(basename "$log")"
}

simulator_state() {
  local state
  state=$(xcrun simctl list devices | grep -F "$udid" | sed 's/^ *//; s/ *$//' || true)
  echo "${state:-not listed}"
}

if [ -n "$TIMING_DIR" ] && [ -n "$udid" ]; then
  note "==> simulator at script start: $(simulator_state)"
fi

# Booting the simulator is dead time on the critical path, so by default overlap
# it with the build instead of letting `xcodebuild test` serialize the two.
if [ -n "$udid" ] && [ "$BOOT_SIMULATOR" = during-build ]; then
  if [ -n "$TIMING_DIR" ]; then
    boot_simulator &
  else
    xcrun simctl bootstatus "$udid" -b >/dev/null 2>&1 &
  fi
  boot_pid=$!
fi

build_status=0
phase "build-for-testing" run build-for-testing \
  "${xcodebuild_args[@]}" \
  ${build_only_args[@]+"${build_only_args[@]}"} \
  "${build_settings[@]}" || build_status=$?

if [ -n "$TIMING_DIR" ]; then
  milestones "$TIMING_DIR/build-for-testing.raw.log"
  sed -n '/Build Timing Summary/,/\*\* .* \*\*/p' "$TIMING_DIR/build-for-testing.raw.log" \
    | cut -c10- | tee -a "$TIMING_DIR/summary.txt" || true
fi
if [ "$build_status" -ne 0 ]; then
  if [ -n "$TIMING_DIR" ] && [ -n "$boot_pid" ] && kill -0 "$boot_pid" 2>/dev/null; then
    note "==> build failed while the simulator was still booting"
  fi
  exit "$build_status"
fi

if [ -n "$boot_pid" ]; then
  wait "$boot_pid" || true
elif [ -n "$udid" ]; then
  boot_simulator
fi

phase "test-without-building" run test-without-building \
  "${xcodebuild_args[@]}" \
  -resultBundlePath "$RESULT_BUNDLE"
