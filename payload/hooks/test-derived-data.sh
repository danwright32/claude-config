#!/usr/bin/env bash
# Tests for lib/derived-data.sh, the one decision about which Xcode build caches can never be used
# again (claude-config#1369).
#
# The decision was LIFTED from Overture (overture#2596, closing overture#2585, lesson L114), where it
# lived in scripts/lib/derived-data.sh and ran only inside Overture's own test-all. The first half of
# this file is Overture's scripts/lib/derived-data.test.sh, ported case for case, so the shared copy
# is held to every promise the original made (a relative path, a missing key and an unmounted volume
# are never orphans). The second half covers what the shared copy adds: saying WHY a folder could not
# be attributed, and keeping an orphan a build may still be using (modified in the last hour, or
# named by a running xcodebuild), which the issue asked for and Overture's version did not have.
#
# Every case builds a THROWAWAY DerivedData root and never reads or writes the real
# ~/Library/Developer/Xcode/DerivedData (L2). The plists are real XML plists read by the same readers
# the library uses, so a fixture cannot agree with an assumption about a format nobody checked.
# Fixture folders are backdated, because a folder made a moment ago is exactly what the "modified in
# the last hour" guard keeps, and a test that forgot that would pass for the wrong reason.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$DIR/lib/derived-data.sh"

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

if [ ! -f "$LIB" ]; then
  check "lib/derived-data.sh is there to test" "missing: $LIB"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  exit 1
fi
# shellcheck source=./lib/derived-data.sh
. "$LIB"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/derived-data-lib.XXXXXXXX")" || TMP_ROOT=""
case "${TMP_ROOT%/}" in
  ''|/|"${HOME%/}") echo "test-derived-data: refusing to run: throwaway directory came back as '$TMP_ROOT'." >&2; exit 2 ;;
esac
trap 'chmod -R u+w "$TMP_ROOT" 2>/dev/null; rm -rf "$TMP_ROOT"' EXIT

# No real process list, ever: a fake ps that prints nothing, unless a case names another.
FAKE_PS_EMPTY="$TMP_ROOT/ps-empty"
printf '#!/bin/sh\nexit 0\n' > "$FAKE_PS_EMPTY"; chmod +x "$FAKE_PS_EMPTY"
export DERIVED_DATA_PS="$FAKE_PS_EMPTY"
export DERIVED_DATA_RECENT_MINUTES=60

# Every file and folder under $1 dated 2026-01-01, so the recent change guard has nothing to see.
backdate() { find "$1" -exec touch -t 202601011200 {} + 2>/dev/null; }

# One DerivedData shaped folder. With a workspace it gets an info.plist naming it; without one it
# gets no plist at all, the shape of a folder Xcode is midway through creating.
make_folder() {
  local root="$1" name="$2" workspace="${3-}" dir
  dir="$root/$name"
  mkdir -p "$dir"
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
  mkdir -p "$dir/Build/Intermediates.noindex"
  printf 'object' > "$dir/Build/Intermediates.noindex/a.o"
  backdate "$dir"
  printf '%s' "$dir"
}

make_folder_without_workspace_key() {
  local root="$1" name="$2" dir
  dir="$root/$name"
  mkdir -p "$dir"
  cat > "$dir/info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>LastAccessedDate</key>
	<string>2026-08-12T10:00:00Z</string>
</dict>
</plist>
PLIST
  backdate "$dir"
  printf '%s' "$dir"
}

# ================== ported from Overture: derived_data_classify ==================
CASE_ROOT="$TMP_ROOT/classify"
mkdir -p "$CASE_ROOT"

# The caches every project shares. Not keyed by a workspace at all, so the orphan rule cannot speak
# about them, and deleting one costs every project on the Mac a rebuild.
for shared in ModuleCache.noindex CompilationCache.noindex SDKStatCaches.noindex; do
  mkdir -p "$CASE_ROOT/$shared"
  check "$shared is a shared cache" "$(eq "$(derived_data_classify "$CASE_ROOT/$shared")" shared-cache)"
done

LIVE_WORKSPACE="$TMP_ROOT/live-checkout/mac/Overture.xcodeproj"
mkdir -p "$LIVE_WORKSPACE"
LIVE_DIR="$(make_folder "$CASE_ROOT" "Overture-live" "$LIVE_WORKSPACE")"
check "a workspace still on disk is live" "$(eq "$(derived_data_classify "$LIVE_DIR")" live)"

ORPHAN_DIR="$(make_folder "$CASE_ROOT" "Overture-orphan" "$TMP_ROOT/deleted-worktree/mac/Overture.xcodeproj")"
check "a workspace that is gone is an orphan" "$(eq "$(derived_data_classify "$ORPHAN_DIR")" orphan)"

NO_PLIST_DIR="$(make_folder "$CASE_ROOT" "Overture-noplist")"
check "no info.plist is unreadable, never an orphan" "$(eq "$(derived_data_classify "$NO_PLIST_DIR")" unreadable)"

NO_KEY_DIR="$(make_folder_without_workspace_key "$CASE_ROOT" "Overture-nokey")"
check "a plist with no WorkspacePath is unreadable" "$(eq "$(derived_data_classify "$NO_KEY_DIR")" unreadable)"

EMPTY_PATH_DIR="$(make_folder "$CASE_ROOT" "Overture-emptypath" "")"
check "an empty WorkspacePath is unreadable" "$(eq "$(derived_data_classify "$EMPTY_PATH_DIR")" unreadable)"

# The one way the rule can fail open: an unplugged drive makes every workspace on it look deleted.
UNMOUNTED_DIR="$(make_folder "$CASE_ROOT" "Overture-unmounted" \
  "/Volumes/ClaudeConfigFixtureVolumeThatIsNotMounted/checkout/mac/Overture.xcodeproj")"
check "a workspace on an unmounted volume is unreadable, not an orphan" \
  "$(eq "$(derived_data_classify "$UNMOUNTED_DIR")" unreadable)"

RELATIVE_DIR="$(make_folder "$CASE_ROOT" "Overture-relative" "some/relative/path.xcodeproj")"
check "a relative WorkspacePath is unreadable" "$(eq "$(derived_data_classify "$RELATIVE_DIR")" unreadable)"

check "a folder that does not exist is unreadable" \
  "$(eq "$(derived_data_classify "$CASE_ROOT/never-created")" unreadable)"

# ================== ported from Overture: derived_data_orphans ==================
ORPHANS="$(derived_data_orphans "$CASE_ROOT")"
check "the orphan is listed" "$(has "$ORPHANS" "Overture-orphan")"
check "the live folder is not listed" "$(hasnt "$ORPHANS" "Overture-live")"
check "a shared cache is not listed" "$(hasnt "$ORPHANS" "ModuleCache.noindex")"
check "an unreadable folder is not listed" "$(hasnt "$ORPHANS" "Overture-noplist")"
check "an unmounted volume's folder is not listed" "$(hasnt "$ORPHANS" "Overture-unmounted")"
check "exactly one orphan in this root" "$(eq "$(printf '%s\n' "$ORPHANS" | grep -c . || true)" 1)"
check "a DerivedData root that does not exist yields nothing" \
  "$(eq "$(derived_data_orphans "$TMP_ROOT/no-such-root")" "")"

# ================== added here: why a folder could not be attributed ==================
# The sweep reports these apart, because "no info.plist" and "its drive is unplugged" call for
# different things from the reader (L11).
check "no info.plist says so" "$(eq "$(derived_data_unreadable_reason "$NO_PLIST_DIR")" no-info-plist)"
check "a plist without the key says so" "$(eq "$(derived_data_unreadable_reason "$NO_KEY_DIR")" no-workspace-path)"
check "an empty path is the same as no path" "$(eq "$(derived_data_unreadable_reason "$EMPTY_PATH_DIR")" no-workspace-path)"
check "a relative path says so" "$(eq "$(derived_data_unreadable_reason "$RELATIVE_DIR")" relative-path)"
check "an unmounted volume says so" "$(eq "$(derived_data_unreadable_reason "$UNMOUNTED_DIR")" volume-not-mounted)"

# ================== added here: an orphan a build may still be using ==================
USE_ROOT="$TMP_ROOT/in-use"
mkdir -p "$USE_ROOT"
IDLE="$(make_folder "$USE_ROOT" "Idle-orphan" "$TMP_ROOT/gone-idle/App.xcodeproj")"
check "an orphan nothing has touched for an hour is not in use" \
  "$(derived_data_in_use "$IDLE" >/dev/null && echo "called in use: $(derived_data_in_use "$IDLE")" || echo ok)"

# A write deep inside, which is where a build writes: the folder's own date does not move for that.
FRESH="$(make_folder "$USE_ROOT" "Fresh-orphan" "$TMP_ROOT/gone-fresh/App.xcodeproj")"
printf 'new' > "$FRESH/Build/Intermediates.noindex/b.o"
fresh_reason="$(derived_data_in_use "$FRESH")"; fresh_rc=$?
check "an orphan with a file written in the last hour is in use" "$(eq "$fresh_rc" 0)"
check "and the reason says it was modified recently" "$(has "$fresh_reason" "modified in the last 60 minutes")"

# The window is a setting, and 0 turns the recent change guard off rather than keeping everything.
check "with the window at 0 the recent write no longer keeps it" \
  "$(DERIVED_DATA_RECENT_MINUTES=0 derived_data_in_use "$FRESH" >/dev/null && echo "still in use" || echo ok)"

# A running xcodebuild naming the folder, or the workspace it records, keeps it.
FAKE_PS_NAMING="$TMP_ROOT/ps-naming"
cat > "$FAKE_PS_NAMING" <<PS
#!/bin/sh
echo "  101 /usr/bin/login -f someone"
echo "  4242 /Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -derivedDataPath $USE_ROOT/Named-orphan build"
echo "  4343 xcodebuild -project $TMP_ROOT/gone-ws/App.xcodeproj -scheme App test"
echo "  5151 /usr/bin/vim $USE_ROOT/Idle-orphan/notes.txt"
PS
chmod +x "$FAKE_PS_NAMING"
NAMED="$(make_folder "$USE_ROOT" "Named-orphan" "$TMP_ROOT/gone-named/App.xcodeproj")"
named_reason="$(DERIVED_DATA_PS="$FAKE_PS_NAMING" derived_data_in_use "$NAMED")"; named_rc=$?
check "an orphan a running xcodebuild names by folder is in use" "$(eq "$named_rc" 0)"
check "and the reason names the process" "$(has "$named_reason" "xcodebuild (pid 4242)")"
WS="$(make_folder "$USE_ROOT" "Ws-orphan" "$TMP_ROOT/gone-ws/App.xcodeproj")"
ws_reason="$(DERIVED_DATA_PS="$FAKE_PS_NAMING" derived_data_in_use "$WS")"; ws_rc=$?
check "an orphan whose workspace a running xcodebuild names is in use" "$(eq "$ws_rc" 0)"
check "and the reason names that process" "$(has "$ws_reason" "pid 4343")"
check "a process that is not xcodebuild naming a folder does not keep it" \
  "$(DERIVED_DATA_PS="$FAKE_PS_NAMING" derived_data_in_use "$IDLE" >/dev/null && echo "kept by vim" || echo ok)"

# A process list that cannot be read is not an empty one: nothing can say no build is running, so
# everything is kept (L98).
FAKE_PS_BROKEN="$TMP_ROOT/ps-broken"
printf '#!/bin/sh\necho "ps: cannot read" >&2\nexit 1\n' > "$FAKE_PS_BROKEN"; chmod +x "$FAKE_PS_BROKEN"
broken_reason="$(DERIVED_DATA_PS="$FAKE_PS_BROKEN" derived_data_in_use "$IDLE")"; broken_rc=$?
check "a process list that could not be read keeps the folder" "$(eq "$broken_rc" 0)"
check "and says the list could not be read" "$(has "$broken_reason" "process list could not be read")"

# A window that is not a number keeps everything rather than landing on the permissive side (L50).
check "a window that is not a number keeps the folder" \
  "$(DERIVED_DATA_RECENT_MINUTES=abc derived_data_in_use "$IDLE" >/dev/null && echo ok || echo "let go")"

# ================== reclaimable: orphaned AND not in use ==================
RECLAIMABLE="$(DERIVED_DATA_PS="$FAKE_PS_NAMING" derived_data_reclaimable "$USE_ROOT")"
check "the idle orphan is reclaimable" "$(has "$RECLAIMABLE" "Idle-orphan")"
check "the freshly written orphan is not" "$(hasnt "$RECLAIMABLE" "Fresh-orphan")"
check "the orphan an xcodebuild names is not" "$(hasnt "$RECLAIMABLE" "Named-orphan")"
check "the orphan whose workspace an xcodebuild names is not" "$(hasnt "$RECLAIMABLE" "Ws-orphan")"

# ================== ported from Overture: derived_data_reclaim, now with the in use guard ==================
RECLAIM_ROOT="$TMP_ROOT/reclaim"
mkdir -p "$RECLAIM_ROOT/ModuleCache.noindex"
KEEP_LIVE="$(make_folder "$RECLAIM_ROOT" "Overture-keep" "$LIVE_WORKSPACE")"
KEEP_UNREADABLE="$(make_folder "$RECLAIM_ROOT" "Overture-unreadable")"
GO_1="$(make_folder "$RECLAIM_ROOT" "Overture-gone-1" "$TMP_ROOT/gone-1/mac/Overture.xcodeproj")"
GO_2="$(make_folder "$RECLAIM_ROOT" "Overture-gone-2" "$TMP_ROOT/gone-2/mac/Overture.xcodeproj")"
# Another project's orphan: the proof that it can never be reused is the same proof, and it does not
# know which project made it (Dan's call in Overture, 2026-08-12).
GO_3="$(make_folder "$RECLAIM_ROOT" "PostRoll-gone" "$TMP_ROOT/gone-3/PostRoll.xcodeproj")"
KEEP_BUSY="$(make_folder "$RECLAIM_ROOT" "Overture-busy" "$TMP_ROOT/gone-4/mac/Overture.xcodeproj")"
printf 'new' > "$KEEP_BUSY/Build/Intermediates.noindex/c.o"

RECLAIMED="$(derived_data_reclaim "$RECLAIM_ROOT")"
check "reclaimed three orphans" "$(eq "$RECLAIMED" 3)"
check "the first orphan is gone" "$(gone "$GO_1")"
check "the second orphan is gone" "$(gone "$GO_2")"
check "another project's orphan is gone" "$(gone "$GO_3")"
check "the live folder survives" "$(isdir "$KEEP_LIVE")"
check "the unreadable folder survives" "$(isdir "$KEEP_UNREADABLE")"
check "the shared cache survives" "$(isdir "$RECLAIM_ROOT/ModuleCache.noindex")"
check "the orphan written to in the last hour survives" "$(isdir "$KEEP_BUSY")"
check "a second run reclaims nothing and does not fail" "$(eq "$(derived_data_reclaim "$RECLAIM_ROOT")" 0)"
check "a root that does not exist reclaims nothing" "$(eq "$(derived_data_reclaim "$TMP_ROOT/no-such-root")" 0)"

# A folder that cannot be removed is named and NOT counted, so the number is what happened (L12).
STUCK_ROOT="$TMP_ROOT/stuck"
mkdir -p "$STUCK_ROOT"
STUCK="$(make_folder "$STUCK_ROOT" "Stuck-orphan" "$TMP_ROOT/gone-stuck/App.xcodeproj")"
chmod 500 "$STUCK/Build/Intermediates.noindex"
stuck_err="$TMP_ROOT/stuck.err"
stuck_count="$(derived_data_reclaim "$STUCK_ROOT" 2>"$stuck_err")"
chmod 700 "$STUCK/Build/Intermediates.noindex"
check "a folder that could not be removed is not counted" "$(eq "$stuck_count" 0)"
check "and is named on stderr" "$(has "$(cat "$stuck_err")" "could not remove $STUCK")"

# ================== sizes ==================
idle_kib="$(derived_data_size_kib "$IDLE")"
check "the size of a folder is read in KiB" \
  "$(grep -qxE '[0-9]+' <<< "$idle_kib" && echo ok || echo "got '$idle_kib'")"
check "a folder that does not exist has no size rather than zero" \
  "$(eq "$(derived_data_size_kib "$TMP_ROOT/nothing-here")" "")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
