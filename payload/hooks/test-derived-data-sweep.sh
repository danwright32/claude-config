#!/usr/bin/env bash
# Tests for derived-data-sweep.sh, the command that lists Xcode build caches whose project folder is
# gone and deletes them only when told to (claude-config#1369).
#
# Whether the sweep may delete on its own is Dan's decision and has not been made (L9), so the
# promise held here above all is that the DEFAULT deletes nothing: every folder in the fixture is
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

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
