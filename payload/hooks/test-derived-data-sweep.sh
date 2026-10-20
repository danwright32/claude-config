#!/usr/bin/env bash
# Tests for derived-data-sweep.sh, the command that lists Xcode build caches whose project folder is
# gone and deletes them when told to with --delete, or on its own through --start when the low free
# space warning fires (claude-config#1369).
#
# Deleting on its own happens only through --start, which the low free space warning runs (Dan's
# decision on #1369, 2026-10-20, L9), so the promise held here first is still that a plain run
# deletes nothing: every folder in the fixture is
# checked to still be there after a plain run. --delete is then checked to remove exactly the true
# orphans and nothing that is live, unattributable, on an unplugged drive, freshly written, or named
# by a running xcodebuild, and to report the df gain so a delete that frees nothing is visible
# (L93, L98).
#
# Every run points at a throwaway DerivedData root and a fake process list, never the real ones (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SWEEP="$DIR/derived-data-sweep.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
eq() { [ "$1" = "$2" ] && echo ok || echo "expected '$2', got '$1'"; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in: $1" || echo ok; }
isdir() { [ -d "$1" ] && echo ok || echo "$1 is gone"; }
gone() { [ -d "$1" ] && echo "$1 is still there" || echo ok; }

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/derived-data-sweep.XXXXXXXX")" || TMP_ROOT=""
case "${TMP_ROOT%/}" in
  ''|/|"${HOME%/}") echo "test-derived-data-sweep: refusing to run: throwaway directory came back as '$TMP_ROOT'." >&2; exit 2 ;;
esac
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

check "the sweep is there to run" "$([ -f "$SWEEP" ] && echo ok || echo "missing: $SWEEP")"

backdate() { find "$1" -exec touch -t 202601011200 {} + 2>/dev/null; }

make_folder() {   # make_folder <root> <name> [workspace]   (no workspace argument: no info.plist)
  local root="$1" name="$2" workspace="${3-}" dir
  dir="$root/$name"
  mkdir -p "$dir/Build/Intermediates.noindex"
  head -c 40000 /dev/zero > "$dir/Build/Intermediates.noindex/a.o"
  if [ "$#" -ge 3 ]; then
    cat > "$dir/info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>WorkspacePath</key>
	<string>${workspace}</string>
</dict>
</plist>
PLIST
  fi
  backdate "$dir"
  printf '%s' "$dir"
}

# One fixture holding every kind of folder the issue names.
build_fixture() {   # build_fixture <root>
  local root="$1"
  mkdir -p "$root/ModuleCache.noindex"
  mkdir -p "$TMP_ROOT/live-checkout/App.xcodeproj"
  make_folder "$root" "App-orphan" "$TMP_ROOT/removed-worktree/App.xcodeproj" >/dev/null
  make_folder "$root" "App-orphan-two" "$TMP_ROOT/removed-scratch/App.xcodeproj" >/dev/null
  make_folder "$root" "App-live" "$TMP_ROOT/live-checkout/App.xcodeproj" >/dev/null
  make_folder "$root" "App-unmounted" "/Volumes/ClaudeConfigFixtureVolumeThatIsNotMounted/App.xcodeproj" >/dev/null
  make_folder "$root" "App-noplist" >/dev/null
  make_folder "$root" "App-fresh" "$TMP_ROOT/removed-fresh/App.xcodeproj" >/dev/null
  printf 'new' > "$root/App-fresh/Build/Intermediates.noindex/b.o"
  make_folder "$root" "App-building" "$TMP_ROOT/removed-building/App.xcodeproj" >/dev/null
  backdate "$root/ModuleCache.noindex"
}

FAKE_PS="$TMP_ROOT/ps"
write_fake_ps() {   # write_fake_ps <root>
  cat > "$FAKE_PS" <<PS
#!/bin/sh
echo "  77 /usr/bin/login -f someone"
echo "  4242 /usr/bin/xcodebuild -derivedDataPath $1/App-building build"
PS
  chmod +x "$FAKE_PS"
}

run_sweep() {   # run_sweep <root> [args...]  -> sets OUT and RC
  local root="$1"; shift
  OUT="$(XCODE_DERIVED_DATA_ROOT="$root" DERIVED_DATA_PS="$FAKE_PS" DERIVED_DATA_RECENT_MINUTES=60 \
    DERIVED_DATA_DF_VOLUME="$TMP_ROOT" bash "$SWEEP" "$@" 2>&1)"
  RC=$?
}

# ================== the default lists, and deletes NOTHING ==================
ROOT="$TMP_ROOT/dd-list"
mkdir -p "$ROOT"; build_fixture "$ROOT"; write_fake_ps "$ROOT"
run_sweep "$ROOT"
LIST="$OUT"
check "a plain run exits 0" "$(eq "$RC" 0)"
for name in ModuleCache.noindex App-orphan App-orphan-two App-live App-unmounted App-noplist App-fresh App-building; do
  check "a plain run leaves $name in place" "$(isdir "$ROOT/$name")"
done
check "it says nothing was deleted" "$(has "$LIST" "Nothing was deleted.")"

orphan_section="$(awk '/^Orphaned, their project folder is gone/{on=1; print; next} /^[^ ]/{on=0} on' <<< "$LIST")"
check "the orphans have a section of their own, with their count" \
  "$(has "$orphan_section" "Orphaned, their project folder is gone: 2")"
check "the first orphan is listed there by path" "$(has "$orphan_section" "$ROOT/App-orphan ")"
check "the second orphan is listed there by path" "$(has "$orphan_section" "$ROOT/App-orphan-two")"
check "each orphan names the project path it recorded" \
  "$(has "$orphan_section" "project was $TMP_ROOT/removed-worktree/App.xcodeproj")"
check "each orphan carries its last modified date" "$(has "$orphan_section" "last modified 2026-01-01")"
check "each orphan carries a size" \
  "$(grep -qE '^  +[0-9]+(\.[0-9])? (KB|MB|GB) ' <<< "$orphan_section" && echo ok || echo "no size in: $orphan_section")"
check "the live, unattributable, unmounted, fresh and building folders are not in the orphan section" \
  "$(listed=""; for n in App-live App-noplist App-unmounted App-fresh App-building; do grep -qF "$ROOT/$n" <<< "$orphan_section" && listed="$listed $n"; done; [ -z "$listed" ] && echo ok || echo "listed:$listed")"
check "the orphan section states a total" "$(has "$orphan_section" "by du")"

check "a fresh orphan is reported as kept because it may be in use" \
  "$(has "$(grep -F "$ROOT/App-fresh" <<< "$LIST")" "modified in the last 60 minutes")"
check "an orphan a running xcodebuild names is reported as kept, naming the process" \
  "$(has "$(grep -F "$ROOT/App-building" <<< "$LIST")" "xcodebuild (pid 4242)")"
check "a folder with no info.plist is reported as unattributable" \
  "$(has "$LIST" "Kept, no info.plist, so nothing says which project made them: 1")"
check "and listed by path" "$(has "$LIST" "$ROOT/App-noplist")"
check "a folder on an unmounted volume is reported as kept" \
  "$(has "$LIST" "Kept, project on a volume that is not mounted: 1")"
check "a live folder is counted as kept" "$(has "$LIST" "Kept, project still on disk: 1")"
check "the shared cache is counted and never touched" "$(has "$LIST" "Shared caches")"
check "it hands over the command that deletes, which it did not run" \
  "$(has "$LIST" "bash ~/.claude/hooks/derived-data-sweep.sh --delete")"

# ================== --delete removes the true orphans and nothing else ==================
ROOT2="$TMP_ROOT/dd-delete"
mkdir -p "$ROOT2"; build_fixture "$ROOT2"; write_fake_ps "$ROOT2"
run_sweep "$ROOT2" --delete
DEL="$OUT"
check "--delete exits 0 when every removal worked" "$(eq "$RC" 0)"
check "--delete removes the first orphan" "$(gone "$ROOT2/App-orphan")"
check "--delete removes the second orphan" "$(gone "$ROOT2/App-orphan-two")"
for name in ModuleCache.noindex App-live App-unmounted App-noplist App-fresh App-building; do
  check "--delete leaves $name in place" "$(isdir "$ROOT2/$name")"
done
check "--delete names each folder it removed" "$(has "$DEL" "Deleted $ROOT2/App-orphan-two")"
check "--delete says how many it removed" "$(has "$DEL" "Deleted 2 of 2 orphaned folder(s)")"
check "--delete reports the gain df measured, in MB" \
  "$(grep -qE "Free space on $TMP_ROOT: [0-9]+ MB before, [0-9]+ MB after" <<< "$DEL" && echo ok || echo "said: $DEL")"
check "--delete never prints the command to delete as if there were more to do" \
  "$(hasnt "$DEL" "To delete")"

run_sweep "$ROOT2" --delete
check "a second --delete finds nothing to remove and says so" "$(has "$OUT" "Nothing was orphaned and idle, so nothing was deleted.")"
check "and exits 0" "$(eq "$RC" 0)"

# A removal that fails is named and fails the run, so a partial clear never reads as done (L12).
ROOT3="$TMP_ROOT/dd-stuck"
mkdir -p "$ROOT3"
make_folder "$ROOT3" "Stuck-orphan" "$TMP_ROOT/removed-stuck/App.xcodeproj" >/dev/null
chmod 500 "$ROOT3/Stuck-orphan/Build/Intermediates.noindex"
write_fake_ps "$ROOT3"
run_sweep "$ROOT3" --delete
chmod 700 "$ROOT3/Stuck-orphan/Build/Intermediates.noindex"
check "a removal that fails exits 1" "$(eq "$RC" 1)"
check "and names the folder it could not remove" "$(has "$OUT" "Could not delete $ROOT3/Stuck-orphan")"
check "and does not count it as deleted" "$(has "$OUT" "Deleted 0 of 1 orphaned folder(s)")"

# ================== --summary, the one line the low space warning carries ==================
ROOT4="$TMP_ROOT/dd-summary"
mkdir -p "$ROOT4"; build_fixture "$ROOT4"; write_fake_ps "$ROOT4"
run_sweep "$ROOT4" --summary
check "--summary exits 0" "$(eq "$RC" 0)"
check "--summary counts the orphans by the same rule" \
  "$(has "$OUT" "Xcode build caches whose project folder is gone: 4 folder(s)")"
check "--summary names the command that lists them" "$(has "$OUT" "bash ~/.claude/hooks/derived-data-sweep.sh")"
check "--summary names the command that deletes them" "$(has "$OUT" "bash ~/.claude/hooks/derived-data-sweep.sh --delete")"
check "--summary deletes nothing" \
  "$(missing=""; for n in App-orphan App-orphan-two App-fresh App-building; do [ -d "$ROOT4/$n" ] || missing="$missing $n"; done; [ -z "$missing" ] && echo ok || echo "gone:$missing")"

# A sizing bound of 0 skips the sizing rather than handing perl `alarm 0`, which means no bound.
OUT="$(XCODE_DERIVED_DATA_ROOT="$ROOT4" DERIVED_DATA_SUMMARY_SECONDS=0 bash "$SWEEP" --summary 2>&1)"
check "--summary with a sizing bound of 0 counts without sizing, and says so" \
  "$(has "$OUT" "4 folder(s), not sized (DERIVED_DATA_SUMMARY_SECONDS is 0)")"

ROOT5="$TMP_ROOT/dd-clean"
mkdir -p "$ROOT5"; mkdir -p "$TMP_ROOT/live-checkout/App.xcodeproj"
make_folder "$ROOT5" "App-live" "$TMP_ROOT/live-checkout/App.xcodeproj" >/dev/null
run_sweep "$ROOT5" --summary
check "--summary with nothing orphaned says so, naming how many it checked" \
  "$(has "$OUT" "No Xcode build cache is orphaned (1 folder(s) checked).")"

run_sweep "$TMP_ROOT/no-such-root" --summary
check "--summary on a Mac with no DerivedData says nothing" "$(eq "$OUT" "")"
check "and exits 0" "$(eq "$RC" 0)"

# ================== what it cannot read is said, never passed over ==================
run_sweep "$TMP_ROOT/no-such-root"
check "a plain run on a Mac with no DerivedData says there is nothing to look at" \
  "$(has "$OUT" "There is no Xcode build output on this Mac")"
check "and exits 0" "$(eq "$RC" 0)"

run_sweep "$ROOT" --bogus
check "an unknown argument is refused with exit 2" "$(eq "$RC" 2)"
check "and nothing is listed or deleted under a refused argument" "$(isdir "$ROOT/App-orphan")"

OUT="$(XCODE_DERIVED_DATA_ROOT="$ROOT" DERIVED_DATA_PS="$FAKE_PS" DERIVED_DATA_RECENT_MINUTES=soon \
  DERIVED_DATA_DF_VOLUME="$TMP_ROOT" bash "$SWEEP" --delete 2>&1)"; RC=$?
check "a window setting that is not a number is refused with exit 2" "$(eq "$RC" 2)"
check "and the refusal names the setting" "$(has "$OUT" "DERIVED_DATA_RECENT_MINUTES")"
check "and nothing was deleted under it" "$(isdir "$ROOT/App-orphan")"

# ================== --start, --auto and --last: the sweep that runs on its own ==================
# Dan's decision on #1369 (2026-10-20): when the low free space warning fires, the orphans are cleared
# without asking and the space freed is reported. The warning runs inside a 10 second hook timeout,
# so --start takes the lock and hands the work to a detached --auto, and the outcome goes into a
# record the NEXT warning reads with --last, so a sweep that freed nothing, failed, or died partway
# is still seen (L13, L98). Every case gets a state folder of its own; none reads ~/.claude/state.
run_state() {   # run_state <root> <state dir> [args...]  -> sets OUT and RC
  local root="$1" state="$2"; shift 2
  OUT="$(XCODE_DERIVED_DATA_ROOT="$root" DERIVED_DATA_PS="$FAKE_PS" DERIVED_DATA_RECENT_MINUTES="${RECENT_FOR_RUN:-60}" \
    DERIVED_DATA_DF_VOLUME="$TMP_ROOT" DERIVED_DATA_SWEEP_STATE_DIR="$state" bash "$SWEEP" "$@" 2>&1)"
  RC=$?
}
# Waits on the CONDITION, a finished record with no sweep still marked in progress, never a fixed
# time (L290). The deadline only turns a sweep that never finishes into a failure rather than a hang.
wait_finished() {   # wait_finished <state dir> -> 0 once finished, 1 at the deadline
  local deadline=$(( $(date +%s) + 30 ))
  while [ ! -f "$1/last-result" ] || [ -e "$1/in-progress" ]; do
    [ "$(date +%s)" -ge "$deadline" ] && return 1
    sleep 0.1
  done
  return 0
}
run_logs() { find "$1" -name 'run-*.log' 2>/dev/null | wc -l | tr -d ' '; }

S_EMPTY="$TMP_ROOT/state-empty"
run_state "$ROOT" "$S_EMPTY" --last
check "--last before any sweep has run says nothing" "$(eq "$OUT" "")"
check "and exits 0" "$(eq "$RC" 0)"

ROOT6="$TMP_ROOT/dd-auto"; S6="$TMP_ROOT/state-auto"
mkdir -p "$ROOT6"; build_fixture "$ROOT6"; write_fake_ps "$ROOT6"
auto_start="$(date +%s)"
run_state "$ROOT6" "$S6" --start
auto_took=$(( $(date +%s) - auto_start ))
check "--start exits 0 when it started a sweep" "$(eq "$RC" 0)"
check "and returns at once rather than waiting for the sweep" "$([ "$auto_took" -lt 3 ] && echo ok || echo "took ${auto_took}s")"
check "the started sweep finishes and records what it did" "$(wait_finished "$S6" && echo ok || echo "no finished record in $S6")"
check "the automatic sweep removes the first orphan" "$(gone "$ROOT6/App-orphan")"
check "the automatic sweep removes the second orphan" "$(gone "$ROOT6/App-orphan-two")"
for name in ModuleCache.noindex App-live App-unmounted App-noplist App-fresh App-building; do
  check "the automatic sweep leaves $name in place" "$(isdir "$ROOT6/$name")"
done
run_state "$ROOT6" "$S6" --last
LAST="$OUT"
check "--last reports how many the last sweep deleted" "$(has "$LAST" "deleted 2 of 2 orphaned folder(s)")"
check "--last reports the gain df measured, not only du" "$(has "$LAST" "df measured")"
log6="$(find "$S6" -name 'run-*.log' -print -quit)"
check "--last names the log of that sweep" "$([ -n "$log6" ] && has "$LAST" "$log6" || echo "no run log in $S6, said: $LAST")"
check "and that log names each folder it removed" \
  "$([ -n "$log6" ] && has "$(cat "$log6")" "Deleted $ROOT6/App-orphan-two" || echo "no run log in $S6")"
check "the record holds df before and after" \
  "$(grep -qE '^df_before_mb=[0-9]+$' "$S6/last-result" && grep -qE '^df_after_mb=[0-9]+$' "$S6/last-result" && echo ok || echo "record: $(cat "$S6/last-result" 2>/dev/null)")"

# Two warnings at once never run two sweeps: the lock is taken by --start itself, before the sweep is
# handed off, so the second --start is refused even while the first is still starting (assume it
# runs twice). The process list blocks until the suite releases it, so the first sweep is
# demonstrably still running when the second is asked for.
ROOT7="$TMP_ROOT/dd-locked"; S7="$TMP_ROOT/state-locked"; RELEASE7="$TMP_ROOT/release-7"
mkdir -p "$ROOT7"
make_folder "$ROOT7" "Lock-orphan" "$TMP_ROOT/removed-lock/App.xcodeproj" >/dev/null
BLOCKING_PS="$TMP_ROOT/blocking-ps"
cat > "$BLOCKING_PS" <<PS
#!/bin/sh
n=0
while [ ! -e "$RELEASE7" ] && [ "\$n" -lt 300 ]; do sleep 0.1; n=\$((n + 1)); done
echo "  77 /usr/bin/login -f someone"
PS
chmod +x "$BLOCKING_PS"
SAVED_PS="$FAKE_PS"; FAKE_PS="$BLOCKING_PS"
run_state "$ROOT7" "$S7" --start
first_rc="$RC"
run_state "$ROOT7" "$S7" --start
second_rc="$RC"; second_out="$OUT"
: > "$RELEASE7"
FAKE_PS="$SAVED_PS"
check "the first --start starts a sweep" "$(eq "$first_rc" 0)"
check "a second --start while it runs is refused with exit 75" "$(eq "$second_rc" 75)"
check "and says a sweep is already running" "$(has "$second_out" "already running")"
check "the one sweep finishes" "$(wait_finished "$S7" && echo ok || echo "no finished record in $S7")"
check "and only one sweep ran" "$(eq "$(run_logs "$S7")" 1)"
check "and it removed the orphan" "$(gone "$ROOT7/Lock-orphan")"

# A sweep that fails is reported as failing by the next reader, never as a sweep that freed nothing.
ROOT8="$TMP_ROOT/dd-auto-stuck"; S8="$TMP_ROOT/state-stuck"
mkdir -p "$ROOT8"
make_folder "$ROOT8" "Stuck-orphan" "$TMP_ROOT/removed-stuck-auto/App.xcodeproj" >/dev/null
chmod 500 "$ROOT8/Stuck-orphan/Build/Intermediates.noindex"
write_fake_ps "$ROOT8"
run_state "$ROOT8" "$S8" --start
check "a failing sweep still finishes and records" "$(wait_finished "$S8" && echo ok || echo "no finished record in $S8")"
chmod 700 "$ROOT8/Stuck-orphan/Build/Intermediates.noindex"
run_state "$ROOT8" "$S8" --last
check "--last says the last sweep FAILED" "$(has "$OUT" "FAILED")"
check "and how many it could not delete" "$(has "$OUT" "could not delete 1 of 1")"

# A refusal inside the detached sweep is recorded as a failure too, and deletes nothing.
ROOT9="$TMP_ROOT/dd-auto-refused"; S9="$TMP_ROOT/state-refused"
mkdir -p "$ROOT9"
make_folder "$ROOT9" "Refused-orphan" "$TMP_ROOT/removed-refused/App.xcodeproj" >/dev/null
RECENT_FOR_RUN=soon run_state "$ROOT9" "$S9" --start
check "a sweep that refuses still records" "$(wait_finished "$S9" && echo ok || echo "no finished record in $S9")"
run_state "$ROOT9" "$S9" --last
check "--last says a refused sweep FAILED, with its exit code" "$(has "$OUT" "FAILED (it exited 2)")"
check "and the refused sweep deleted nothing" "$(isdir "$ROOT9/Refused-orphan")"

# A sweep killed partway leaves its in-progress mark and no record, and nothing holds the lock: that
# is said, never read as no sweep at all (L13).
S10="$TMP_ROOT/state-died"; mkdir -p "$S10"
printf 'started=%s\nlog=%s\n' "$(( $(date +%s) - 600 ))" "$S10/run-1.log" > "$S10/in-progress"
run_state "$ROOT" "$S10" --last
check "--last says a sweep stopped before recording what it did" "$(has "$OUT" "stopped before recording")"
# The next --start turns that mark into the record, so the death is still reported while the new
# sweep runs, and not read as a record nobody can parse. The process list blocks until released, so
# the new sweep is demonstrably still running when --last is asked.
RELEASE10="$TMP_ROOT/release-10"
sed "s|$RELEASE7|$RELEASE10|" "$BLOCKING_PS" > "$TMP_ROOT/blocking-ps-10"; chmod +x "$TMP_ROOT/blocking-ps-10"
ROOT10="$TMP_ROOT/dd-after-death"; mkdir -p "$ROOT10"
make_folder "$ROOT10" "After-orphan" "$TMP_ROOT/removed-after/App.xcodeproj" >/dev/null
SAVED_PS="$FAKE_PS"; FAKE_PS="$TMP_ROOT/blocking-ps-10"
run_state "$ROOT10" "$S10" --start
start10_rc="$RC"
run_state "$ROOT10" "$S10" --last
died_out="$OUT"
: > "$RELEASE10"
FAKE_PS="$SAVED_PS"
check "a --start after a sweep died starts a new one" "$(eq "$start10_rc" 0)"
check "and while it runs, --last still says the earlier sweep stopped before recording" \
  "$(has "$died_out" "stopped before recording")"
check "rather than calling its record unreadable" "$(hasnt "$died_out" "could not be read")"
check "the new sweep finishes" "$(wait_finished "$S10" && echo ok || echo "no finished record in $S10")"

run_state "$ROOT" "$TMP_ROOT/state-direct" --auto
check "--auto run by hand, without the lock --start takes, is refused with exit 2" "$(eq "$RC" 2)"
check "and deletes nothing" "$(isdir "$ROOT/App-orphan")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
