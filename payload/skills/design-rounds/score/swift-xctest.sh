# swift-xctest.sh: run the SwiftUI adapter's snapshot tests and say whether they ran (claude-config#1400).
# Sourced by test-score-adapters.sh; test-swift-xctest.sh replays real toolchain logs through it.
#
# A Mac whose developer directory is the command line tools has Swift but no XCTest, so `swift test`
# cannot build a test target there and the snapshot tests never run. That is a fact about the
# machine, not the adapter, so it must read as UNMEASURED rather than FAIL (L411), and only the
# attempt itself may say so (L460): no OS name or file path is consulted, the real `swift test` is
# the probe and costs nothing beyond the run the suite makes anyway.

# swift_xctest_missing <log>: prints why, and succeeds, when the log shows the compiler could not find
# the XCTest module and no other source file failed to compile. Anything else (a type error in the
# adapter, a crash with no diagnosis) fails, so a broken adapter on such a Mac still reads as a fault.
swift_xctest_missing() {
  local log="$1" located line missing=0
  [ -s "$log" ] || return 1
  # Diagnostics that point at a place in a Swift file, in either form swift build prints. The
  # compiler colours them even into a file, so the escapes are dropped before reading.
  located="$(sed $'s/\x1b\\[[0-9;]*m//g' "$log" | grep -E '\.swift:[0-9]+:[0-9]+.*error|error.*\.swift:[0-9]+:[0-9]+' || true)"
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "$line" in
      *module*"'XCTest'"*) missing=1 ;;
      *) return 1 ;;
    esac
  done <<< "$located"
  [ "$missing" -eq 1 ] || return 1
  local dir="${DEVELOPER_DIR:-$(xcode-select -p 2>/dev/null || true)}"
  printf "swift test could not find the XCTest module, which the toolchain at %s does not have. Install Xcode and select it with: sudo xcode-select -s /Applications/Xcode.app\n" "${dir:-an unknown developer directory}"
}

# swift_xctest_run <package dir> <log>: runs swift test in the package with the caller's environment,
# keeps its whole output in <log>, and prints one line: `ran`, `failed`, or `unmeasured <why>`.
swift_xctest_run() {
  local pkg="$1" log="$2" why
  if (cd "$pkg" && swift test > "$log" 2>&1); then
    echo ran
  elif why="$(swift_xctest_missing "$log")"; then
    echo "unmeasured $why"
  else
    echo failed
  fi
}
