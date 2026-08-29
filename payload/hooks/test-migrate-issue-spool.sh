#!/usr/bin/env bash
# Tests for the one-time spool migration.
#
# It moves records that were keyed on the AGENT's directory to the key their own
# SESSION reads. The cases that matter are the ones where a mistake is silent: a
# record moved somewhere nobody looks is indistinguishable from one that was
# never moved, and a record dropped in transit leaves no trace at all.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MIGRATE="$DIR/migrate-issue-spool.py"
SPOOL_LIB="$DIR/lib/issue-spool.sh"

pass=0
fail=0
check() {
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT
export CLAUDE_ISSUE_SPOOL_DIR="$TMPROOT/spool"
export CLAUDE_PROJECTS_DIR="$TMPROOT/projects"
export CLAUDE_ISSUE_SPOOL_LIB="$SPOOL_LIB"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR" "$CLAUDE_PROJECTS_DIR/-a-project"

# The session this record belongs to, discoverable exactly as it is in the real
# layout: a transcript sitting directly in its project directory.
touch "$CLAUDE_PROJECTS_DIR/-a-project/session-aaa.jsonl"
DEST="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/-a-project/any-session.jsonl")"
WRONG="wrongkey00001"

# One record per LINE. Without the newline all three fuse into a single
# unreadable line, and every assertion below then passes or fails for a reason
# that has nothing to do with the migration.
rec() { printf '{"ts":"2026-08-29T10:00:00Z","status":"found","session":"%s","findings":["%s"]}\n' "$1" "$2"; }

seed() {
  rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
  { rec session-aaa "a finding whose session is known"
    rec session-zzz "a finding whose session is nowhere"
    printf 'not a record at all\n'
  } > "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
}

# A dry run must change nothing at all. It is the only thing standing between a
# person and an irreversible move of their whole spool.
seed
before="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")"
out_dry="$(python3 "$MIGRATE" 2>&1)"
[ "$before" = "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")" ] \
  && check "a dry run changes nothing" ok \
  || check "a dry run changes nothing" "the file was rewritten"
contains "DRY RUN" "$out_dry" \
  && check "a dry run says so" ok \
  || check "a dry run says so" "out=${out_dry:0:200}"
[ ! -f "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" ] \
  && check "a dry run creates no destination" ok \
  || check "a dry run creates no destination" "it wrote $DEST"

# The move itself.
seed
out_apply="$(python3 "$MIGRATE" --apply 2>&1)"
contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null)" \
  && check "a record moves to the key its session reads" ok \
  || check "a record moves to the key its session reads" "not in $DEST"

# The positive control: it must have LEFT the old key, not been copied. A copy
# is shown twice and filed once, which strands the other half.
contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "the moved record really left the old key" "it was copied, not moved" \
  || check "the moved record really left the old key" ok

# A session that cannot be located must stay put. Guessing would move it
# somewhere nobody looks, which is the fault being repaired.
contains "a finding whose session is nowhere" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "a record whose session is unknown stays put" ok \
  || check "a record whose session is unknown stays put" "it was moved anyway"

# An unreadable line is not a record anyone has classified, so it is not moved
# and not dropped.
contains "not a record at all" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "an unreadable line is kept where it was" ok \
  || check "an unreadable line is kept where it was" "it vanished"

# Nothing may be lost in transit, and the tool must SAY the count rather than
# leave it to be discovered.
contains "3 record(s) before, 3 after" "$out_apply" \
  && check "the move reports its own record count" ok \
  || check "the move reports its own record count" "out=${out_apply: -200}"

# Running it twice must be safe: the second run finds nothing left to move.
out_twice="$(python3 "$MIGRATE" --apply 2>&1)"
contains "moving: 0" "$out_twice" \
  && check "running it again moves nothing" ok \
  || check "running it again moves nothing" "out=${out_twice: -200}"
after_twice="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null | grep -c "session is known" || true)"
[ "$after_twice" = "1" ] \
  && check "running it again does not duplicate a record" ok \
  || check "running it again does not duplicate a record" "$after_twice copies"

# The key must come from the library, never from a second implementation here.
# Point the tool at a library that answers differently and the destination must
# follow it: if it does not, this file is computing its own key.
seed
FAKELIB="$TMPROOT/fake-lib.sh"
printf '#!/usr/bin/env bash\necho fakekey99999\n' > "$FAKELIB"
chmod +x "$FAKELIB"
CLAUDE_ISSUE_SPOOL_LIB="$FAKELIB" python3 "$MIGRATE" --apply >/dev/null 2>&1
[ -f "$CLAUDE_ISSUE_SPOOL_DIR/fakekey99999.jsonl" ] \
  && check "the destination key comes from the spool library" ok \
  || check "the destination key comes from the spool library" "it computed its own"

# A library that answers with NOTHING must stop the run, not send every record
# to an empty-named file.
seed
printf '#!/usr/bin/env bash\nexit 1\n' > "$FAKELIB"
CLAUDE_ISSUE_SPOOL_LIB="$FAKELIB" python3 "$MIGRATE" --apply >/dev/null 2>&1
rc=$?
[ "$rc" -ne 0 ] \
  && check "a library that gives no key stops the run" ok \
  || check "a library that gives no key stops the run" "it exited 0"
[ -f "$CLAUDE_ISSUE_SPOOL_DIR/.jsonl" ] \
  && check "no record is sent to an empty key" "it created .jsonl" \
  || check "no record is sent to an empty key" ok

# ---------------------------------------------------------------------------
# Order and recoverability. This tool moves the only copy of records nobody has
# read yet, and it will be run unsupervised on another machine.
# ---------------------------------------------------------------------------

# The destination must be written BEFORE the source is emptied. Killed between
# the two, the worst outcome must be a record present twice, never a record
# present nowhere: a duplicate is visible and fixable, a loss is neither (L5).
seed
CLAUDE_MIGRATE_ABORT_AFTER_WRITE=1 python3 "$MIGRATE" --apply >/dev/null 2>&1
survived_dest="$(contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null)" && echo yes || echo no)"
survived_src="$(contains "a finding whose session is known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" && echo yes || echo no)"
[ "$survived_dest" = "yes" ] || [ "$survived_src" = "yes" ] \
  && check "a run killed midway loses no record" ok \
  || check "a run killed midway loses no record" "gone from both"
# The positive control for that: the abort must really have happened partway,
# not before anything was done, or the check above is satisfied by a run that
# never started.
[ "$survived_dest" = "yes" ] \
  && check "the abort really happened after the write" ok \
  || check "the abort really happened after the write" "nothing was written first"

# A backup is taken before anything moves, and it holds the original content.
# The person running this on the other Mac has no copy of their spool otherwise,
# and nothing here can be undone by hand (L7).
seed
original="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")"
out_bk="$(python3 "$MIGRATE" --apply 2>&1)"
backup_dir=""
while IFS= read -r line_bk; do
  case "$line_bk" in "backup: "*) [ -n "$backup_dir" ] || backup_dir="${line_bk#backup: }" ;; esac
done <<< "$out_bk"
[ -n "$backup_dir" ] && [ -d "$backup_dir" ] \
  && check "the move takes a backup first" ok \
  || check "the move takes a backup first" "no backup named in ${out_bk:0:200}"
[ "$(cat "$backup_dir/$WRONG.jsonl" 2>/dev/null)" = "$original" ] \
  && check "the backup holds what was there before the move" ok \
  || check "the backup holds what was there before the move" "backup differs"

# A dry run must not take one: it changes nothing, so a backup would only be
# litter that looks like a real recovery point.
seed
out_dry2="$(python3 "$MIGRATE" 2>&1)"
contains "backup:" "$out_dry2" \
  && check "a dry run takes no backup" "it made one" \
  || check "a dry run takes no backup" ok

# ---------------------------------------------------------------------------
# When the session id leads nowhere.
#
# Measured on the second Mac, 2026-08-29: 128 spool keys holding one record
# each, and 117 of them named a session with no transcript left on disk. Keying
# on the session alone therefore rescued 11 records and stranded the rest, which
# is the same silence this whole exercise is about.
#
# The record also carries the directory the agent worked in, and Claude Code
# names a project's folder after that path with every character that is not a
# letter or digit replaced by a dash. That is checkable rather than guessed: the
# encoded name either IS a folder that exists or it is not.
#
# The walk goes UP from the agent's directory, because a session sits at or
# above where its agents work. It STOPS BEFORE the home directory: everything
# lives under home, so matching it proves nothing and would sweep every
# unmatched record in the machine into one heap.
# ---------------------------------------------------------------------------
export CLAUDE_MIGRATE_HOME="$TMPROOT/home"
mkdir -p "$CLAUDE_MIGRATE_HOME/work/repo/nested"
ENC_REPO="$(printf '%s' "$CLAUDE_MIGRATE_HOME/work/repo" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC_REPO"
REPO_KEY="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/$ENC_REPO/any-session.jsonl")"

rec_cwd() { # rec_cwd <session-or-empty> <cwd> <text>
  python3 -c '
import json, sys
r = {"ts": "2026-08-29T10:00:00Z", "status": "found", "cwd": sys.argv[2],
     "findings": [sys.argv[3]]}
if sys.argv[1]:
    r["session"] = sys.argv[1]
print(json.dumps(r))' "$1" "$2" "$3"
}

seed_cwd() {
  rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
  { rec_cwd "" "$CLAUDE_MIGRATE_HOME/work/repo" "no session recorded at all"
    rec_cwd session-gone "$CLAUDE_MIGRATE_HOME/work/repo/nested" "session gone, worked deeper"
    rec_cwd session-gone "$CLAUDE_MIGRATE_HOME/elsewhere" "session gone, nothing matches"
  } > "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
}

seed_cwd
python3 "$MIGRATE" --apply >/dev/null 2>&1
landed="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$REPO_KEY.jsonl" 2>/dev/null)"
contains "no session recorded at all" "$landed" \
  && check "a record with no session is placed by the directory it worked in" ok \
  || check "a record with no session is placed by the directory it worked in" "not in $REPO_KEY"
contains "session gone, worked deeper" "$landed" \
  && check "a record from a subdirectory walks up to its project" ok \
  || check "a record from a subdirectory walks up to its project" "not in $REPO_KEY"

# The refusal that keeps the rest honest: nothing matches, so it stays put
# rather than being swept somewhere nobody looks.
contains "session gone, nothing matches" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "a record matching no project stays where it is" ok \
  || check "a record matching no project stays where it is" "it was moved anyway"

# The home directory must never be the match that rescues a record, or every
# unplaceable record on the machine ends up in one pile.
ENC_HOME="$(printf '%s' "$CLAUDE_MIGRATE_HOME" | sed 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$CLAUDE_PROJECTS_DIR/$ENC_HOME"
HOME_KEY="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/$ENC_HOME/any-session.jsonl")"
seed_cwd
python3 "$MIGRATE" --apply >/dev/null 2>&1
contains "nothing matches" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$HOME_KEY.jsonl" 2>/dev/null)" \
  && check "the walk stops before the home directory" "it was swept into home" \
  || check "the walk stops before the home directory" ok

# A session that CAN be found still wins: it is what the review actually keys
# on, and the directory is only a fallback for when it is gone.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
touch "$CLAUDE_PROJECTS_DIR/-a-project/session-aaa.jsonl"
rec_cwd session-aaa "$CLAUDE_MIGRATE_HOME/work/repo" "session known, directory says otherwise" \
  > "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
python3 "$MIGRATE" --apply >/dev/null 2>&1
contains "session known" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$DEST.jsonl" 2>/dev/null)" \
  && check "a findable session beats the directory fallback" ok \
  || check "a findable session beats the directory fallback" "it went by the directory instead"

# The two ways a session can fail to place a record are different problems and
# must be reported as different lines (L11): one is a record that never named a
# session, the other is a session whose transcript is gone.
seed_cwd
rm -rf "$CLAUDE_PROJECTS_DIR/$ENC_REPO" "$CLAUDE_PROJECTS_DIR/$ENC_HOME"
out_why="$(python3 "$MIGRATE" 2>&1)"
contains "no session recorded" "$out_why" && contains "session not found" "$out_why" \
  && check "the two ways a record cannot be placed are named apart" ok \
  || check "the two ways a record cannot be placed are named apart" "out=${out_why: -300}"

# A record that was ALREADY in the right place is not a record that could not be
# placed, and must not be counted under that heading: the line naming why things
# failed is the line a person reads to decide whether the run went well.
seed
out_lbl="$(python3 "$MIGRATE" 2>&1)"
# A herestring, not a pipe: `producer | grep` under this suite's pipefail can
# report the producer's death rather than the match (L183).
why_line=""
while IFS= read -r line_lbl; do
  case "$line_lbl" in *"could not be placed"*) why_line="$line_lbl" ;; esac
done <<< "$out_lbl"
contains "already" "$why_line" \
  && check "records already in place are not counted as failures" "counted as one: $why_line" \
  || check "records already in place are not counted as failures" ok

# The tally has to add up: every record that found a home is either moving or
# already where it belongs, and none may appear on two lines. The first version
# reported the same 332 records under two headings at once.
#
# The fixture must CONTAIN records already in the right place, or the double
# count cannot happen and the check passes without ever being exercised: a run
# with nothing already in place was seen to pass with the counting deliberately
# broken.
seed
python3 "$MIGRATE" --apply >/dev/null 2>&1
out_tally="$(python3 "$MIGRATE" 2>&1)"
contains "already in the right place: 1" "$out_tally" \
  && check "the tally fixture really holds a settled record" ok \
  || check "the tally fixture really holds a settled record" "out=${out_tally: -300}"
contains "COUNTS DO NOT ADD UP" "$out_tally" \
  && check "the placement tally adds up" "it does not: ${out_tally: -300}" \
  || check "the placement tally adds up" ok

# ---------------------------------------------------------------------------
# A record that cannot be placed must SHOW why, not just be counted.
#
# Measured on the second Mac, 2026-08-29: 119 records carried no session id at
# all and 118 of those matched no project folder either, so the fallback rescued
# one. A count alone cannot say whether those directories are worktrees that
# were deleted, paths from another machine, or something nobody has thought of,
# and guessing at it from a number is how the previous two attempts at this went
# wrong. The tool names the directories instead.
# ---------------------------------------------------------------------------
seed_cwd
rm -rf "$CLAUDE_PROJECTS_DIR/$ENC_REPO"
out_ex="$(python3 "$MIGRATE" 2>&1)"
contains "$CLAUDE_MIGRATE_HOME/elsewhere" "$out_ex" \
  && check "the dry run names a directory it could not place" ok \
  || check "the dry run names a directory it could not place" "out=${out_ex: -400}"

# It must also say whether that directory is still on disk, because a path that
# no longer exists (a deleted worktree) and one that exists but was never opened
# as a project are different problems with different answers.
contains "gone" "$out_ex" \
  && check "the dry run says whether the directory still exists" ok \
  || check "the dry run says whether the directory still exists" "no existence marker in ${out_ex: -400}"

# The examples are a sample, not a dump: one line per distinct directory, capped,
# so a spool with hundreds of unplaceable records stays readable.
i=0
while [ "$i" -lt 30 ]; do
  rec_cwd "" "$CLAUDE_MIGRATE_HOME/nowhere-$i" "unplaceable $i" >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
  i=$((i + 1))
done
out_many="$(python3 "$MIGRATE" 2>&1)"
ex_lines=0
while IFS= read -r l_ex; do
  case "$l_ex" in *"nowhere-"*) ex_lines=$((ex_lines + 1)) ;; esac
done <<< "$out_many"
[ "$ex_lines" -gt 0 ] && [ "$ex_lines" -le 12 ] \
  && check "the examples are capped rather than dumped" ok \
  || check "the examples are capped rather than dumped" "$ex_lines example lines"

# Whether the unplaceable records are worth rescuing at all depends on WHAT they
# are. A stranded finding an agent deliberately wrote down is worth real effort;
# a stranded record of a harvest that failed is worth none, and the two are
# indistinguishable in a count of records.
seed_cwd
rm -rf "$CLAUDE_PROJECTS_DIR/$ENC_REPO"
printf '{"ts":"2026-08-29T10:00:00Z","status":"error","cwd":"%s","error":"the harvest model exited 1"}\n' \
  "$CLAUDE_MIGRATE_HOME/elsewhere" >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
out_kind="$(python3 "$MIGRATE" 2>&1)"
contains "found" "$out_kind" && contains "error" "$out_kind" \
  && check "the dry run says what kind of records it could not place" ok \
  || check "the dry run says what kind of records it could not place" "out=${out_kind: -400}"

# ---------------------------------------------------------------------------
# Forgetting records that were never real.
#
# 120 of one machine's records, and 5 of the other's, were written by a test
# suite into the live spool: findings about a fixture, naming a temp directory
# that no longer exists. They can never be placed, because no project ever lived
# there, and they are not worth placing.
#
# The rule is deliberately narrow and evidence based: the record could not be
# placed, the directory it names is inside a temp directory, and that directory
# is gone. No real project lives in a temp directory, so this cannot reach a
# genuine finding, and all three conditions must hold.
# ---------------------------------------------------------------------------
seed_cwd
rm -rf "$CLAUDE_PROJECTS_DIR/$ENC_REPO"
TMPGONE="${TMPDIR:-/tmp}/gone-fixture-$$/spool-project"
rec_cwd "" "$TMPGONE" "a finding about a test fixture" >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"

# A dry run must not delete anything, and must say what it would take.
out_forget_dry="$(python3 "$MIGRATE" --forget-test-records 2>&1)"
contains "a finding about a test fixture" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl")" \
  && check "forgetting is a dry run until it is applied" ok \
  || check "forgetting is a dry run until it is applied" "it deleted without --apply"
contains "would forget" "$out_forget_dry" \
  && check "the dry run says what it would forget" ok \
  || check "the dry run says what it would forget" "out=${out_forget_dry: -300}"

python3 "$MIGRATE" --forget-test-records --apply >/dev/null 2>&1
left="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)"
contains "a finding about a test fixture" "$left" \
  && check "a record naming a vanished temp directory is forgotten" "it is still there" \
  || check "a record naming a vanished temp directory is forgotten" ok

# What it must NOT touch, checked in the same fixture so the deletion above is
# not passing because nothing matched at all.
#
# The path has to sit OUTSIDE any temp directory: this whole suite runs inside
# one, so a fixture built from its own scratch directory is indistinguishable
# from the leftovers being deleted, and the first version of this check failed
# for exactly that reason.
rec_cwd "" "$HOME/no-such-project-for-this-test" "a vanished project outside any temp directory" \
  >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
python3 "$MIGRATE" --forget-test-records --apply >/dev/null 2>&1
left="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)"
contains "a vanished project outside any temp directory" "$left" \
  && check "an unplaceable record outside a temp directory is kept" ok \
  || check "an unplaceable record outside a temp directory is kept" "it was deleted too"

# A temp directory that STILL EXISTS is not evidence of anything, so it stays.
TMPHERE="${TMPDIR:-/tmp}/still-here-$$/spool-project"
mkdir -p "$TMPHERE"
rec_cwd "" "$TMPHERE" "a finding in a temp directory that still exists" >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
python3 "$MIGRATE" --forget-test-records --apply >/dev/null 2>&1
contains "temp directory that still exists" "$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl" 2>/dev/null)" \
  && check "a record in a temp directory that still exists is kept" ok \
  || check "a record in a temp directory that still exists is kept" "it was deleted"
rm -rf "${TMPDIR:-/tmp}/still-here-$$"

# And forgetting takes a backup too, since it is the only destructive mode here.
contains "backup:" "$(python3 "$MIGRATE" --forget-test-records --apply 2>&1)" \
  && check "forgetting takes a backup first" ok \
  || check "forgetting takes a backup first" "no backup was named"

# A record that CAN be placed is not a test leftover, whatever directory it
# names. Sitting in a vanished temp directory is only evidence when nothing else
# accounts for the record: an agent that genuinely worked in a temp directory,
# for a session that still exists, left a real finding.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
touch "$CLAUDE_PROJECTS_DIR/-a-project/session-aaa.jsonl"
rec_cwd session-aaa "${TMPDIR:-/tmp}/vanished-$$/spool-project" "a real finding from a temp directory" \
  > "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
python3 "$MIGRATE" --forget-test-records --apply >/dev/null 2>&1
kept_placeable="$(cat "$CLAUDE_ISSUE_SPOOL_DIR"/*.jsonl 2>/dev/null)"
contains "a real finding from a temp directory" "$kept_placeable" \
  && check "a record its session can place is never forgotten" ok \
  || check "a record its session can place is never forgotten" "it was deleted"

# The destructive path must show EVERY directory it would take, not a sample.
# The list is the only thing standing between a person and a delete, and the
# migration plan's ten-line cap would hide most of it: 120 records across 120
# distinct directories were about to be deleted on the strength of ten of them.
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
i=0
while [ "$i" -lt 25 ]; do
  rec_cwd "" "${TMPDIR:-/tmp}/leftover-$$-$i/spool-project" "leftover $i" \
    >> "$CLAUDE_ISSUE_SPOOL_DIR/$WRONG.jsonl"
  i=$((i + 1))
done
out_all="$(python3 "$MIGRATE" --forget-test-records 2>&1)"
listed=0
while IFS= read -r l_all; do
  case "$l_all" in *"leftover-$$-"*) listed=$((listed + 1)) ;; esac
done <<< "$out_all"
[ "$listed" -eq 25 ] \
  && check "the delete lists every directory it would take" ok \
  || check "the delete lists every directory it would take" "listed $listed of 25"

# ---------------------------------------------------------------------------
# A file that is BOTH a source and a destination.
#
# Hit on the second Mac, 2026-08-29: 30 records before, 29 after, and the tool's
# own loss check stopped the run. One spool file had records staying in it AND a
# record arriving into it. Arrivals are appended first, for crash safety, and the
# sources are then rewritten from a list computed BEFORE that append, so the
# rewrite destroyed the record that had just arrived.
#
# Reordering the two phases is not the answer: sources-first is what loses
# records when a run is killed. The rewrite has to include what arrived.
# ---------------------------------------------------------------------------
rm -rf "$CLAUDE_ISSUE_SPOOL_DIR"; mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"
mkdir -p "$CLAUDE_PROJECTS_DIR/-project-one" "$CLAUDE_PROJECTS_DIR/-project-two"
touch "$CLAUDE_PROJECTS_DIR/-project-one/session-one.jsonl"
touch "$CLAUDE_PROJECTS_DIR/-project-two/session-two.jsonl"
K_ONE="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/-project-one/any.jsonl")"
K_TWO="$(bash "$SPOOL_LIB" key "$TMPROOT" "$CLAUDE_PROJECTS_DIR/-project-two/any.jsonl")"

# K_ONE holds a record that belongs there (it stays) and also receives one from
# K_TWO, so it is a source and a destination at once.
rec_cwd session-one "$TMPROOT/anywhere" "the record that already lived here" > "$CLAUDE_ISSUE_SPOOL_DIR/$K_ONE.jsonl"
rec_cwd session-one "$TMPROOT/anywhere" "the record that has to move here" > "$CLAUDE_ISSUE_SPOOL_DIR/$K_TWO.jsonl"

out_both="$(python3 "$MIGRATE" --apply 2>&1)"
landed_both="$(cat "$CLAUDE_ISSUE_SPOOL_DIR/$K_ONE.jsonl" 2>/dev/null)"
contains "the record that has to move here" "$landed_both" \
  && check "a record moving into a file that also has residents survives" ok \
  || check "a record moving into a file that also has residents survives" "it was overwritten"
contains "the record that already lived here" "$landed_both" \
  && check "the residents of that file survive too" ok \
  || check "the residents of that file survive too" "they were overwritten"
contains "LOST RECORDS" "$out_both" \
  && check "the run does not report losing records" "it did: ${out_both: -200}" \
  || check "the run does not report losing records" ok

echo
echo "passed: $pass  failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
