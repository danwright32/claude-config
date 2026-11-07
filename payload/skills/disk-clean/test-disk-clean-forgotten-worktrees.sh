#!/usr/bin/env bash
# Tests for disk-clean's forgotten worktrees kind (payload/skills/disk-clean/categories/
# forgotten-worktrees.sh, claude-config#2346): a folder whose .git file names a gitdir that no longer
# exists, which no repository lists, so `git worktree remove` cannot reach it and the stale worktree
# sweep deliberately skips it.
#
# The rules each check pins, seen failing before the module existed (L1):
#   listed and offered (moved to the Trash, only when Dan ticks it) when its gitdir is gone and sits
#   under this Mac's own home folder, with its size and last change date
#   never listed when its repository still has it (that is the Finished worktrees kind's)
#   left alone, never judged, when the folder is in a synced folder (iCloud Drive, Desktop or
#   Documents when iCloud syncs them, any ~/Library/CloudStorage mount), when its gitdir names
#   another home folder, or when its gitdir is in a synced folder: from this Mac such a link always
#   looks gone, and moving the folder to the Trash would sync that removal back to the Mac using it
#
# Everything runs through the disk-clean harness's dc_run (hooks/lib/disk-clean-harness.sh): HOME is
# a throwaway directory, PATH is stubs plus core tools. Times are SET with touch, never waited for
# (L290), so the 30 day floor and the last change date are both fixed by the fixture.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): hooks/lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan.sh"
CATS="$DIR/categories"
MOD="$CATS/forgotten-worktrees.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo ""
  echo "passed: $pass, failed: $fail"
  echo "SUITE-RESULT passed=$pass failed=$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
eq() { [ "$1" = "$2" ] && echo ok || echo "expected '$2', got '$1'"; }
has() { grep -qF -- "$2" <<< "$1" && echo ok || echo "'$2' not in: $1"; }
hasnt() { grep -qF -- "$2" <<< "$1" && echo "'$2' should not be in: $1" || echo ok; }

. "$DIR/../../hooks/lib/disk-clean-harness.sh" || { check "the harness is there to source" "could not source it"; finish; }
. "$DIR/../../hooks/lib/disk-clean-record.sh" || { check "the record library is there to source" "could not source it"; finish; }
check "the module is there to run" "$([ -f "$MOD" ] && echo ok || echo "missing: $MOD")"
check "the module is executable" "$([ -x "$MOD" ] && echo ok || echo "not executable")"
dc_setup || { check "the harness sets up" "dc_setup failed"; finish; }

H="$DC_HOME"
REC="$H/.claude/state/disk-clean/last-scan.json"
S=$'\037'
OLD=202401011200   # a modification time well past every threshold, and the last change date shown
OLD_DATE=2024-01-01
# Five days ago: well inside the 30 day floor (L290: set, never waited for).
RECENT="$(date -v-5d '+%Y%m%d%H%M' 2>/dev/null || date -d '5 days ago' '+%Y%m%d%H%M')"
# Another Mac's home folder. It must not exist on this machine, or the link would not look gone.
OTHER="/Users/dc-other-home-2346"

dc_stub du 'for a in "$@"; do case "$a" in -*) ;; *) printf "12\t%s\n" "$a" ;; esac; done'
dc_stub lsof 'exit 1'
dc_stub ps 'echo "/usr/bin/login"'
dc_stub pgrep 'exit 1'
dc_stub git 'echo "git stub: $*" >&2; exit 1'
dc_stub gh 'exit 1'

run_scan() { OUT_TEXT="$(dc_run bash "$SCAN" "$@" 2>&1)"; RC=$?; }
dl_run_scan() { OUT_TEXT="$(dc_run env DISK_CLEAN_DATALESS="$DC_ROOT/dataless" bash "$SCAN" "$@" 2>&1)"; RC=$?; }
judge() { JUDGED="$(dc_run env DISK_CLEAN_CATEGORY=forgotten-worktrees bash "$MOD" judge "$1" 2>&1)"; JRC=$?; }
item_of() { [ -f "$REC" ] || return 0; dcr_review_items "$REC" | awk -F "$S" -v t="$1" '$4 == t && !f { print; f = 1 }'; }
item_in() { [ -f "$REC" ] || return 0; dcr_review_items "$REC" | awk -F "$S" -v t="$1" -v c="$2" '$4 == t && $2 == c && !f { print; f = 1 }'; }
field() { awk -F "$S" -v n="$2" '{ print $n }' <<< "$1"; }
fw_item() { item_in "$1" forgotten-worktrees; }
old() { find "$1" -exec touch -t "$OLD" {} + ; }
# A folder holding a .git file whose first line names <gitdir>, with a file in it, all aged.
wtdir() { # <folder> <gitdir as written>
  mkdir -p "$1/src"
  printf 'gitdir: %s\n' "$2" > "$1/.git"
  printf 'x\n' > "$1/src/a.txt"; printf 'readme\n' > "$1/README.md"
  old "$1"
}

check "the other home folder used as another Mac's does not exist here" "$([ -e "$OTHER" ] && echo "$OTHER exists" || echo ok)"

# ================================================================================================
# The fixture
# ================================================================================================
# Forgotten, and this Mac's: the repository is gone entirely (the ~/.overture-wt-<n> shape of the
# 2026-11-06 sweep), or the repository is there but no longer lists the worktree.
wtdir "$H/.overture-wt-1" "$H/Apps/gone/.git/worktrees/wt-1"
printf 'KEY=1\n' > "$H/.overture-wt-1/.env"; old "$H/.overture-wt-1"
mkdir -p "$H/Apps/kept/.git/worktrees"
wtdir "$H/.kept-wt" "$H/Apps/kept/.git/worktrees/kw"
# A relative gitdir (git writes one with worktree.useRelativePaths), resolved against the folder.
wtdir "$H/Apps/rel-wt" "../relrepo/.git/worktrees/r"
# Forgotten but changed five days ago, and forgotten with a session working in it.
wtdir "$H/.fresh-wt" "$H/Apps/gone/.git/worktrees/fresh"; touch -m -t "$RECENT" "$H/.fresh-wt/src/a.txt"
wtdir "$H/.insession-wt" "$H/Apps/gone/.git/worktrees/insession"
mkdir -p "$H/.claude/sessions"
printf '{"pid":1,"sessionId":"s1","cwd":"%s/src"}\n' "$H/.insession-wt" > "$H/.claude/sessions/1.json"
# A live worktree: its gitdir is there, so it is the Finished worktrees kind's, never this one's.
mkdir -p "$H/Apps/live/.git/worktrees/lw"
wtdir "$H/.live-wt" "$H/Apps/live/.git/worktrees/lw"
# Documents synced by iCloud (iCloud Drive holds a Documents folder), holding a worktree whose link
# names the work MacBook's home folder, as the 85 records of 2026-11-06 did, and one whose link names
# this home folder: both are left alone, because removing either would sync back.
mkdir -p "$H/Library/Mobile Documents/com~apple~CloudDocs/Documents"
wtdir "$H/Documents/work-wt" "$OTHER/Apps/work/.git/worktrees/w1"
wtdir "$H/Documents/mine-wt" "$H/Apps/gone/.git/worktrees/mine"
# Not synced, but its link names another home folder: from here it always looks gone.
wtdir "$H/Projects/copied-wt" "$OTHER/Apps/work/.git/worktrees/w2"
# A relative link that climbs out of this home folder into another one.
wtdir "$H/Projects/climb-wt" "../../../../../../../../../..$OTHER/Apps/work/.git/worktrees/w3"
# Its link is into a synced folder of this home, where a missing folder may only not have synced yet.
wtdir "$H/Projects/tosync-wt" "$H/Documents/repo/.git/worktrees/t"
# A folder in a cloud storage mount whose link names this home: the walk never goes there, and the
# judge refuses it on its own too.
wtdir "$H/Library/CloudStorage/GoogleDrive-dan/wt" "$H/Apps/gone/.git/worktrees/cloud"
# A submodule's .git file names .git/modules, and is not a worktree.
wtdir "$H/Apps/sub" "../.git/modules/sub"

# ================================================================================================
# The scan
# ================================================================================================
run_scan --only worktrees,forgotten-worktrees
check "the scan exits 0" "$(eq "$RC" 0)"
check "the record names the kind" "$(has "$(dcr_header "$REC" categories)" forgotten-worktrees)"
check "the kind measured" "$(eq "$(dcr_header "$REC" status.forgotten-worktrees)" measured)"
check "the kind is named in words" "$(eq "$(dcr_title forgotten-worktrees)" "Worktrees whose repository is gone")"

it="$(fw_item "$H/.overture-wt-1")"
check "forgotten, repository gone: listed" "$(eq "$(field "$it" 4)" "$H/.overture-wt-1")"
check "forgotten, repository gone: offered" "$(eq "$(field "$it" 5)" offerable)"
check "forgotten, repository gone: moved to the Trash, never deleted" "$(eq "$(field "$it" 3)" trash)"
check "forgotten, repository gone: its size is read" "$(eq "$(field "$it" 6)" 12288)"
check "forgotten, repository gone: the detail says the repository is gone" "$(has "$(field "$it" 10)" "its repository ~/Apps/gone is gone")"
check "forgotten, repository gone: the detail gives its last change date" "$(has "$(field "$it" 10)" "last changed $OLD_DATE")"
check "forgotten, repository gone: a .env in it is flagged" "$(has "$(field "$it" 9)" credential)"
it="$(fw_item "$H/.kept-wt")"
check "forgotten, repository kept: offered" "$(eq "$(field "$it" 5)" offerable)"
check "forgotten, repository kept: the detail says the repository no longer lists it" "$(has "$(field "$it" 10)" "its repository ~/Apps/kept no longer lists it")"
check "a relative gitdir is resolved against the folder" "$(eq "$(field "$(fw_item "$H/Apps/rel-wt")" 5)" offerable)"
check "the 30 day floor: changed five days ago is not offered" "$(has "$(field "$(fw_item "$H/.fresh-wt")" 5)" "not offerable: changed within 30 days")"
check "a session working in it makes it not offerable" "$(has "$(field "$(fw_item "$H/.insession-wt")" 5)" "not offerable: a session is working in it")"

check "a live worktree is not this kind's" "$(eq "$(fw_item "$H/.live-wt")" "")"
check "a synced folder whose link names another home folder is left alone" "$(eq "$(fw_item "$H/Documents/work-wt")" "")"
check "a synced folder whose link names this home folder is left alone too" "$(eq "$(fw_item "$H/Documents/mine-wt")" "")"
check "a folder whose link names another home folder is left alone" "$(eq "$(fw_item "$H/Projects/copied-wt")" "")"
check "a relative link climbing into another home folder is left alone" "$(eq "$(fw_item "$H/Projects/climb-wt")" "")"
check "a link into a synced folder is left alone" "$(eq "$(fw_item "$H/Projects/tosync-wt")" "")"
check "a cloud storage folder is left alone" "$(eq "$(item_of "$H/Library/CloudStorage/GoogleDrive-dan/wt")" "")"
check "a submodule is not a worktree" "$(eq "$(fw_item "$H/Apps/sub")" "")"
check "what was left alone is counted, never dropped without a word (L10)" \
  "$(has "$(dcr_header "$REC" note.forgotten-worktrees)" "5 worktree folder(s) were left alone")"
check "the Finished worktrees kind no longer lists a forgotten one as well" "$(eq "$(item_in "$H/.overture-wt-1" worktrees)" "")"
check "the Finished worktrees kind still lists the live one" "$(eq "$(field "$(item_in "$H/.live-wt" worktrees)" 4)" "$H/.live-wt")"
check "the scan removed nothing" "$([ -d "$H/.overture-wt-1/src" ] && [ -d "$H/Documents/work-wt/src" ] && [ -f "$H/.kept-wt/.git" ] && echo ok || echo "a fixture folder is gone")"
check "the scan never ran git in a forgotten folder" "$(hasnt "$(dc_calls git)" "$H/.overture-wt-1")"

# ================================================================================================
# The judge, which disk-remove.sh runs again just before moving anything to the Trash
# ================================================================================================
judge "$H/.overture-wt-1"
check "judge: the forgotten one is offerable" "$(eq "$JUDGED" offerable)"
check "judge: exits 0" "$(eq "$JRC" 0)"
judge "$H/Documents/work-wt"
check "judge: the synced folder whose link names another home folder is not offerable" "$(has "$JUDGED" "not offerable: it is in Documents, which iCloud syncs")"
judge "$H/Documents/mine-wt"
check "judge: a synced folder is refused whatever its link" "$(has "$JUDGED" "not offerable: it is in Documents, which iCloud syncs")"
judge "$H/Library/CloudStorage/GoogleDrive-dan/wt"
check "judge: a cloud storage folder is not offerable" "$(has "$JUDGED" "not offerable: it is in a cloud storage folder")"
judge "$H/Projects/copied-wt"
check "judge: a link naming another home folder is not offerable" "$(has "$JUDGED" "outside this Mac's home folder")"
judge "$H/Projects/climb-wt"
check "judge: a relative link climbing out of home is not offerable" "$(has "$JUDGED" "outside this Mac's home folder")"
judge "$H/Projects/tosync-wt"
check "judge: a link into a synced folder is not offerable" "$(has "$JUDGED" "not offerable: its repository is recorded in Documents, which iCloud syncs")"
judge "$H/.live-wt"
check "judge: a live worktree is not offerable here" "$(has "$JUDGED" "not offerable: its repository still has it")"
judge "$H/Apps/sub"
check "judge: a submodule is not offerable" "$(has "$JUDGED" "not offerable: it is not a git worktree")"
judge "$H/Apps/no-such-folder"
check "judge: a folder no longer there is not offerable" "$(has "$JUDGED" "not offerable: it is no longer there")"
touch -a -t "$RECENT" "$H/.overture-wt-1/src/a.txt"
judge "$H/.overture-wt-1"
check "judge: a file in it opened five days ago makes it not offerable" "$(has "$JUDGED" "not offerable: opened within 30 days")"
old "$H/.overture-wt-1"
judge "$H/.overture-wt-1"
check "judge: the control, aged again, is offerable" "$(eq "$JUDGED" offerable)"
# Its repository coming back between the scan and the removal takes it out of the offer.
mkdir -p "$H/Apps/gone/.git/worktrees/wt-1"
judge "$H/.overture-wt-1"
check "judge: once its gitdir is back it is not offerable" "$(has "$JUDGED" "not offerable: its repository still has it")"
rm -rf "$H/Apps/gone"
# A gitdir whose nearest folder that exists cannot be looked inside may be there: unmeasured, never
# gone (L11).
mkdir -p "$H/Apps/locked/.git"
wtdir "$H/.locked-wt" "$H/Apps/locked/.git/worktrees/lk"
chmod 000 "$H/Apps/locked/.git"
judge "$H/.locked-wt"
check "judge: a gitdir that cannot be looked for is unmeasured" "$(has "$JUDGED" "unmeasured: ")"
chmod 755 "$H/Apps/locked/.git"

# ================================================================================================
# A .git file iCloud keeps only in the cloud is never read, since reading it makes iCloud fetch it
# ================================================================================================
wtdir "$H/Projects/evicted-wt" "$H/Apps/gone/.git/worktrees/ev"
printf '%s\n' "$H/Projects/evicted-wt/.git" > "$DC_ROOT/dataless"
dl_run_scan --only forgotten-worktrees
check "a .git file kept only in iCloud: the scan exits 0" "$(eq "$RC" 0)"
check "a .git file kept only in iCloud: not listed" "$(eq "$(fw_item "$H/Projects/evicted-wt")" "")"
check "a .git file kept only in iCloud: counted with what was left alone" \
  "$(has "$(dcr_header "$REC" note.forgotten-worktrees)" "6 worktree folder(s) were left alone")"

finish
