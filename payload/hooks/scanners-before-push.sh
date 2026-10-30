#!/usr/bin/env bash
#
# scanners-before-push.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: before a `git push`, run this repository's WHOLE TREE scanners, and block the push if one
# of them fails (claude-config#518).
#
# The pre push test gate asks a model one question, whether each change in the push carries a
# test, and runs no suite at all. Everything else waits for CI. That is fine for a guard that
# reads the code under change, and useless for the family of guards here that read every tracked
# file in the repository, because those fail over what a change ADDS ANYWHERE: a comment quoting a
# measured number with no date, a pipeline ending in a consumer that leaves early, a hook with no
# coverage. On 2026-09-20 two such defects went to main in one evening and the build went red
# twice, both caught in seconds by a scanner nobody had run.
#
# WHICH suites it runs is derived, never listed. A scanner is a suite that enumerates the
# repository's own tracked files, and it identifies itself by doing so: it asks git what is
# tracked. A hand written list of scanners would exempt the next one somebody writes, which is the
# failure this repo keeps removing (L96, L41).
#
# The rule is deliberately different at the two levels, and the reason is the cost of being wrong.
# A whole suite that mentions git ls-files anywhere is run, because a false positive there costs a
# few seconds. Inside a suite that supports SECTION_ONLY, only the sections that enumerate by
# GLOBBED PATHSPEC are run, because a bare listing inside such a suite is nearly always a fixture
# repository it built itself, and each false positive there costs a section run plus the prelude.
# `--list` prints the selection without running any of it, so what this gate covers can be read
# without paying for it (L102).
#
# It is repo-agnostic by construction: a repository with no payload/hooks/run-all-tests.sh is not
# this one, and the hook does nothing at all there rather than running suites it knows nothing
# about the cost of.
#
# Fails OPEN in every direction it cannot see: not a repository, no scanners found, a suite that
# could not be executed. It blocks on a scanner that ran and failed, and, in its own words, on a
# scanner that could not run because another suite run held its lock past the wait (#642), and on
# a scanner that ran and said, in a SUITE-UNMEASURED line, that it could not read what it judges,
# or, in a SUITE-DEADLINE-UNMEASURED line, that it was stopped at its deadline on a machine busier
# than its cores (#1333), which it calls a fault in its own run rather than a finding (#1146), and on
# scanners that did not finish inside the gate's own time budget, which it names rather than being
# killed by Claude Code and letting the push through unscanned (#1881), and leaves running in the
# background so the next push of the same tree counts their verdict (#1881 follow up). Finding NO
# scanners is reported rather than passed silently, because reading nothing and reading everything
# green look identical otherwise (L98).
#
# MEASURED on this Mac 2026-09-21: the selection was five standalone suites plus one section of the
# sync suite. Run one after another the gate took 27 seconds; run at once, which is how it runs,
# 13. Running that sync suite whole instead would be 268 seconds, which is why a suite with
# sections is run section wise.
#
# Re-measured the same day, after claude-config#522 added the uncommitted files and a sixth
# scanner: 15.3 seconds on a push touching no test section and 18.3 on one that does. Every other
# gate a push waits on costs 0.3 seconds, so this gate is three quarters of the whole wait, which
# is 20 to 26 seconds (claude-config#523, and the table in README.md).
#
# Override: SKIP_SCANNERS_CHECK=1 git push ...   Explain why to the user first, never silently.

# The clock starts here, before anything else, because Claude Code's timeout for this hook starts
# when it spawns the hook, and every second of setup below is spent out of that same allowance
# (claude-config#1881, the budget is explained where it is enforced).
_sc_t0="$(date +%s)"

HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
{ . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && declare -F ps_parse_payload >/dev/null; } || {
  # A library this gate cannot load is not a push with nothing to check (claude-config#1900, L10):
  # with it missing nothing here can tell a push from any other command, so a command naming one
  # is refused, naming the file, and any other passes as it would have.
  payload="$(cat)"
  case "$payload" in *SKIP_SCANNERS_CHECK=1*) exit 0 ;; esac
  case "$payload" in *push*) ;; *) exit 0 ;; esac
  echo "BLOCKED: scanners-before-push.sh could not load $HOOK_DIR/lib/push-scope.sh, which reads whether this command pushes and what it carries, so this command could not be checked. A library this gate cannot load is not a push with nothing to check. Reinstall the hooks with claude-sync pull. For this one command: SKIP_SCANNERS_CHECK=1 <the same command>" >&2
  exit 2
}
# The one test of a whole number above zero, 00 included as zero (claude-config#1948), which reads
# the budget, the lock poll and the age of a run left going. Missing, the same as above: a push is
# refused, naming the file, and any other command passes.
# shellcheck source=lib/whole-number.sh
{ . "$HOOK_DIR/lib/whole-number.sh" 2>/dev/null && declare -F whole_above_zero >/dev/null; } || {
  payload="$(cat)"
  case "$payload" in *SKIP_SCANNERS_CHECK=1*) exit 0 ;; esac
  case "$payload" in *push*) ;; *) exit 0 ;; esac
  echo "BLOCKED: scanners-before-push.sh could not load $HOOK_DIR/lib/whole-number.sh, which reads its budget and other settings, so this push was not scanned. Reinstall the hooks with claude-sync pull. For this one command: SKIP_SCANNERS_CHECK=1 <the same command>" >&2
  exit 2
}

payload="$(cat)"
parsed="$(ps_parse_payload "$payload" segmented)" || exit 0
cmd="${parsed%%$'\x1f'*}"
cwd="${parsed#*$'\x1f'}"
[ -n "$cmd" ] || exit 0

ps_is_git_push "$cmd" || exit 0
ps_has_override "$cmd" SKIP_SCANNERS_CHECK && exit 0

# A push it lets through unscanned says so in a systemMessage, since Claude Code discards a
# PreToolUse hook's stderr on exit 0 (#1906).
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# A gate that runs suites cannot run the suite that drives the gate, or it re-enters itself for
# ever: a script that finds its subjects by a marker matches itself, because it has to name the
# marker (L245). Measured 2026-09-21: this fanned out to dozens of processes and took the machine
# to a load average of 135 before it was killed.
#
# Bounded by an exported marker rather than by excluding a filename, because the next suite to
# name the marker will not be that file. Anything started underneath this gate finds it set and
# refuses, whatever it is.
if [ -n "${SCANNERS_GATE_RUNNING:-}" ]; then
  hook_allow_notice "scanners-before-push: already running inside this gate, so this nested push is not gated again."
fi
export SCANNERS_GATE_RUNNING=1

repo_dir="$(ps_repo_dir "$cmd" "$cwd")" || exit 0
[ -n "$repo_dir" ] || exit 0
cd "$repo_dir" 2>/dev/null || exit 0

# Not this repository, so there is nothing here this hook knows how to run.
[ -f payload/hooks/run-all-tests.sh ] || exit 0

# Every suite that reads the repository's own files, committed or NOT (claude-config#522). Picked
# from what git tracks, a scanner just written was not run until the push after the one that added
# it, and it is the one most likely to be wrong (L456). Read into a variable rather than piped into
# a consumer that leaves early, which under pipefail reports a failure that never happened (L183).
#
# A scanner is recognised by how it lists the repository: through lib/repo-files.sh, the one way
# the scanners here do it, or by asking git directly, which a scanner elsewhere may still do.
REPO_FILES="$HOOK_DIR/lib/repo-files.sh"
SCANS='ls-files|repo-files[.]sh'
suites="$(bash "$REPO_FILES" . '*test-*.sh' 2>/dev/null)"
# The uncommitted files, counted for the line saying what the scanners read; the key is built from
# the wider listing just below (#1910). A listing that fails leaves their number UNKNOWN, said in
# those words, never a zero that reads as a clean tree of drafts (#1146, L90).
if _sc_uncommitted_list="$(bash "$REPO_FILES" --uncommitted . 2>/dev/null)"; then
  uncommitted_n="$(printf '%s' "$_sc_uncommitted_list" | grep -c . || true)"
else
  uncommitted_n="an unknown number of"
fi
# Every path whose contents may differ from the commit, a tracked file edited and not committed
# included, listed once for the key below (#1910). The count above is of new files only, which is
# what the coverage line reports; the key needs every file the scanners read that the tree does not
# already account for.
_sc_changed_unread=""
_sc_changed_list="$(bash "$REPO_FILES" --changed . 2>/dev/null)" || { _sc_changed_list=""; _sc_changed_unread=1; }
scanners=""
while IFS= read -r s; do
  [ -n "$s" ] || continue
  [ -f "$s" ] || continue
  grep -qE "$SCANS" "$s" 2>/dev/null || continue
  # A suite that DRIVES this gate is not a subject of it. It matches the marker because its
  # fixtures have to contain one, and running it re-enters this gate once per fixture. Recognised
  # by the fact that it names this file, so a second suite written to test this gate later is
  # excluded on the same ground rather than needing to be remembered (L96). The exported marker
  # above still bounds anything that re-enters by another route.
  #
  # Only a line of CODE naming it counts. A comment that merely mentions this gate used to drop
  # its suite from the gate's selection, silently, which is how the pipefail ratchet fell out of it
  # the day a comment about this file was added there (claude-config#522).
  _code="$(grep -v '^[[:space:]]*#' "$s" 2>/dev/null)"
  case "$_code" in *"$(basename "${BASH_SOURCE[0]}")"*) continue ;; esac
  scanners="$scanners$s"$'\n'
done <<EOF
$suites
EOF

scanners="${scanners%$'\n'}"
if [ -z "$scanners" ]; then
  hook_allow_notice "scanners-before-push: found no scanner in this repository, which has the marker, so nothing was scanned before this push. That is not a clean run, it is an unmeasured one."
fi

# The sections of a suite that scan: those holding a listing asked for by GLOBBED pathspec. The
# heading a scan sits under is read from the file, so a section added later is covered the day it
# lands. Written once, for the run and for the list of what would run.
scanning_sections(){   # $1 = a suite that supports SECTION_ONLY -> its scanning section titles
  awk -v pat="(ls-files|repo-files[.]sh[^']*) '[*]" '/^section "/ { sec = $0 } $0 ~ pat { if (sec != "") print sec }' "$1" 2>/dev/null \
    | sed 's|^section "||; s|"$||' | sort -u
}

# What it WOULD run, without running any of it. This used to be answered after every scanner had
# already run, so asking what the gate covers cost what the gate costs (L102).
if [ "${SCANNERS_LIST:-}" = "1" ]; then
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
      scanning_sections "$s" | sed "s|^|SECTION $s |"
    else
      printf 'SUITE %s\n' "$s"
    fi
  done <<LIST
$scanners
LIST
  exit 0
fi

# THE FLOOR on how many scanners this repository expects to select (claude-config#530). The set is
# derived rather than listed, which is right, and it can shrink to nothing without a word: on
# 2026-09-21 a conversion moved the scanners off the text the installed gate keyed on, this gate
# silently stopped selecting two of them, and two defects that both of them catch went to main. A
# smaller number reads exactly like a healthy one (L98, L182), so the number is compared with one
# the repository RECORDS, in .claude/scanners-floor.txt.
#
# It is a floor, not an equality: adding a scanner must never fail a push. Removing one deliberately
# means lowering the recorded number in the same change, which is what keeps it a measurement rather
# than a formality. A repository that records nothing is told what to record and not blocked, since
# refusing a repo for lacking a file it never had stops work for no reason (L42).
#
# THE FLOOR BY NAME (claude-config#1744). A count can say only that fewer were selected, never which,
# and it drifted: on 2026-10-25 it recorded 6 while 21 were selected, so 15 could leave unseen. The file may
# list the suites themselves, one path per line as the selection prints them (a line ending in .sh),
# and then every one listed must be selected, and one that is not is named. A suite selected and not
# listed never blocks (adding a scanner never fails a push); the repository's own suite holds the
# list equal to the selection, so it cannot drift low again. A file holding only a number is read as
# the count it always was.
_sc_selected="$(printf '%s\n' "$scanners" | grep -c . || true)"
_sc_floor_file="$repo_dir/.claude/scanners-floor.txt"
_sc_floor=""
_sc_floor_note=""
_sc_named=""
[ -f "$_sc_floor_file" ] && _sc_named="$(awk '/^[[:space:]]*#/ { next } $1 ~ /[.]sh$/ { print $1 }' "$_sc_floor_file" 2>/dev/null)"
if [ -n "$_sc_named" ]; then
  _sc_dropped=""
  while IFS= read -r _n; do
    [ -n "$_n" ] || continue
    # A whole line of the selection, matched by `case` so no pipeline can stop early (L183).
    case $'\n'"$scanners"$'\n' in *$'\n'"$_n"$'\n'*) ;; *) _sc_dropped="$_sc_dropped$_n"$'\n' ;; esac
  done <<NAMED
$_sc_named
NAMED
  if [ -n "$_sc_dropped" ]; then
    {
      echo "PUSH BLOCKED: whole tree scanners this repository records are no longer selected."
      echo ""
      echo "$_sc_floor_file names these, and this gate no longer selects them:"
      printf '%s' "$_sc_dropped" | sed 's/^/    /'
      echo ""
      echo "A scanner that stops being selected is silent: the gate goes on reporting a clean run"
      echo "over a smaller set, which is how two defects reached main on 2026-09-21 after a change"
      echo "moved two scanners off the text this gate recognised them by. A suite is selected when"
      echo "it lists the repository's files (git ls-files or lib/repo-files.sh) in its code."
      echo ""
      echo "If one was removed on purpose, take its line out of $_sc_floor_file in the same change."
      echo "If not, find why it stopped being recognised."
      echo ""
      echo "OVERRIDE, this one push: SKIP_SCANNERS_CHECK=1 <your original git push command>"
    } >&2
    exit 2
  fi
  _sc_floor_note=", meeting the floor of $(printf '%s\n' "$_sc_named" | grep -c .) named suites this repository records"
elif [ -f "$_sc_floor_file" ]; then
  # The first line that is neither blank nor a comment, so the file can say what the number is for.
  _sc_floor="$(awk '/^[[:space:]]*#/ { next } NF { print $1; exit }' "$_sc_floor_file" 2>/dev/null)"
  case "$_sc_floor" in
    ''|*[!0-9]*)
      # Not a number is a refusal to JUDGE, never a silent zero, which would exempt the repository
      # from the very check it recorded (L257).
      echo "scanners-before-push: the floor in $_sc_floor_file is '$_sc_floor', which is not a number, so how many scanners this repository expects could not be read. It selected $_sc_selected. Write there the path of each scanner suite it should select, one per line, or the expected count on its own line." >&2
      _sc_floor="" ;;
    *)
      if [ "$_sc_selected" -lt "$_sc_floor" ]; then
        {
          echo "PUSH BLOCKED: this repository selects fewer whole tree scanners than it records."
          echo ""
          echo "It selected $_sc_selected and $_sc_floor_file records $_sc_floor. A scanner that stops"
          echo "being selected is silent: the gate goes on reporting a clean run over a smaller set,"
          echo "which is how two defects reached main on 2026-09-21 after a change moved two scanners"
          echo "off the text this gate recognised them by."
          echo ""
          echo "What it selected:"
          printf '%s\n' "$scanners" | sed 's/^/    /'
          echo ""
          echo "If a scanner was deliberately removed, lower the number in $_sc_floor_file in the"
          echo "same change. If not, find which suite stopped being recognised."
          echo ""
          echo "OVERRIDE, this one push: SKIP_SCANNERS_CHECK=1 <your original git push command>"
        } >&2
        exit 2
      fi
      _sc_floor_note=", meeting the floor of $_sc_floor this repository records" ;;
  esac
else
  _sc_floor_note=", and no floor is recorded, so a scanner dropping out of this selection would be silent (write the expected count to $_sc_floor_file)"
fi

# Run one suite, or one suite's scanning sections where it supports being run that way. Each run
# writes its own output and its own exit code to its own file, because they all run AT ONCE: five
# suites that share nothing are five lots of wall clock a push waits through for no reason (L302).
#
# Prints nothing on success: a gate that is happy should be quiet, and what it covered is printed
# once at the end instead.
_sc_work="$(mktemp -d "${TMPDIR:-/tmp}/scanners-before-push.XXXXXXXX")" || exit 0
trap 'rm -rf "$_sc_work"' EXIT
_sc_n=0

# SKIPPING A SCANNER WHOSE INPUTS HAVE NOT CHANGED (claude-config#531). Measured 2026-09-21: the
# scanners are 15.3 of the 20.1 seconds a push waits, every other gate costs 0.3, and they re-read
# the whole repository on every push even when nothing they read has changed, which is most pushes.
#
# THE KEY is what the scanners actually read: the commit tree (which holds every tracked file, the
# scanners' own source included, so an edited scanner keys differently) plus a digest of every path
# whose contents on disk may differ from it: a tracked file edited, staged or deleted, a staged
# addition, and an untracked file, which #522 taught the scanners to read. Until #1910 the digest
# covered only the staged additions and untracked files, while the scanners read tracked files from
# disk, so a pass reached before an edit to a tracked file let the next push skip scanning the
# edited file. Computing it is a few git calls and a hash of a handful of files, far cheaper than
# the scan it saves, which is the test that decides whether a cache like this is worth having at
# all (L431).
#
# MEASURED on this Mac 2026-09-21: 14.0 seconds cold against 0.6 with every scanner skipped. The
# saving lands on a REPEAT attempt, a push blocked by another gate and tried again, because a push
# that follows a fresh commit changes the tree and pays in full.
#
# ONLY A PASS IS REMEMBERED. A scanner that failed runs again on the next push, or a failure would
# be skipped past by the very gate that found it (L98).
#
# WHAT IT CANNOT SEE, said plainly: a scanner that reads something OUTSIDE this repository (the
# installed config, a machine setting, the clock) can change its verdict with the key unchanged, and
# would be skipped. None of the scanners here does that today. The skip is announced with the number
# skipped, so a run that scanned nothing never reads as a clean scan of everything.
_sc_state_dir="${SCANNERS_STATE_DIR:-$HOME/.claude/state/scanners-passed}"
_sc_key=""
_sc_tree="$(git rev-parse HEAD^{tree} 2>/dev/null || true)"
# Read from the one listing made above. When that listing failed the files that differ are unknown,
# and a key without them would remember a pass that a later push with different drafts could skip
# on, so there is no key at all: nothing is skipped and nothing remembered (#1146). A deleted path
# is hashed as absent, so a deletion changes the key as an edit does.
if [ -n "$_sc_tree" ] && [ -z "$_sc_changed_unread" ]; then
  _sc_changed_digest="$( { while IFS= read -r _u; do
        [ -n "$_u" ] || continue
        printf '%s ' "$_u"
        if [ -f "$_u" ]; then shasum -a 256 "$_u" 2>/dev/null | awk '{print $1}'; else echo absent; fi
      done <<CHANGED
$_sc_changed_list
CHANGED
      } | shasum -a 256 2>/dev/null | awk '{print $1}')"
  _sc_key="$_sc_tree-${_sc_changed_digest:-none}"
fi
_sc_repo_key="$(printf '%s' "$(git remote get-url origin 2>/dev/null || pwd -P)" | shasum -a 256 2>/dev/null | awk '{print $1}')"
# THE RECORD IS ONE FILE PER TREE, MERGED INTO, NEVER WRITTEN OVER (claude-config#1910). It was one
# file per repository origin, rewritten whole by every push, and worktrees of one repository share
# their origin: two of them pushing in turn erased each other's passes, so each ran again scans that
# had already passed on its own tree. Now a repository's record is a folder holding a file for each
# tree, and a push adds its passes to its tree's file, keeping the lines already there, which are
# other checkouts' passes on the same tree with other uncommitted files. The merge is written to a
# file beside it and renamed over it, under the record's lock, so a reader never sees half of one
# and a writer at the same moment never loses a pass (L5); see _sc_record_merge, where it is written.
_sc_record_dir="$_sc_state_dir/$_sc_repo_key"
_sc_passed_file="$_sc_record_dir/$_sc_tree.txt"
# A tree's file nobody has added to for a day is removed by the next write, so the folder does not
# grow with every tree ever pushed. A day is far past a retry after another gate's refusal, which is
# where the saving lands, and keeps the window short in which a scanner reading something outside
# the repository could be skipped on an old pass. A setting, not a measurement.
_sc_record_keep=86400
_sc_skipped=0
_sc_passed_now=""

_sc_already_passed(){   # $1 = the scanner, $2 = its section or empty -> 0 when this key passed before
  [ -n "$_sc_key" ] || return 1
  [ -f "$_sc_passed_file" ] || return 1
  case "
$(cat "$_sc_passed_file" 2>/dev/null)
" in *"
$_sc_key $1 $2
"*) return 0 ;; esac
  return 1
}

start_one(){         # $1 = the suite path   $2 = a section, or empty
  if _sc_already_passed "$1" "${2:-}"; then
    _sc_skipped=$(( _sc_skipped + 1 ))
    _sc_passed_now="$_sc_passed_now$_sc_key $1 ${2:-}
"
    return 0
  fi
  # Only queued here. It is started below, once the whole selection is known, because each run is
  # told how many runs are in flight with it (#1333).
  _sc_n=$(( _sc_n + 1 ))
  printf '%s\n%s\n' "$1" "${2:-}" > "$_sc_work/$_sc_n.what"
  return 0
}

# THE SHARE OF THE MACHINE EACH RUN IS TOLD IS ITS OWN (claude-config#1333). A suite stopped at its
# deadline judges the load average it reads against its own share of it, HOOK_TESTS_SLOTS, and only
# load BEYOND that share can make the stop UNMEASURED rather than a FAIL (lib/suite-deadline.sh,
# #1330). run-all-tests.sh hands every suite that share. This gate handed none, so each scanner
# judged its share as 1 and counted the scanners running beside it, which this same push started,
# as load from elsewhere: work of the push's own making could excuse a stop as the machine being
# busy. Unlike the runner, nothing here bounds the runs in flight by a budget, so the load this gate
# itself puts on the machine is every run it has in flight at once, and that whole count is each
# run's share. The push is held whether the stop is judged UNMEASURED or FAIL; this decides only
# which it is called. The sync suite also takes the share as its shard count, which a single
# section run does not use: it runs filtered, in one process.
#
# A SCANNER STILL RUNNING AT THE BUDGET IS LEFT RUNNING, NEVER KILLED (follows claude-config#1881
# and #1889). #1889 stopped it, and the whole repository suite, test-run-all-tests.sh, took about
# 410 seconds in CI and 444 on this Mac under load on 2026-10-29, so it could never finish inside
# the budget: every push that needed it was refused, and each retry started it again from nothing.
# The same day one builder's push was refused three times that way. Before #1889 the same scanner was
# killed at Claude Code's 180 seconds and the push went out unscanned, so it had never really run.
#
# So every scanner runs DETACHED from the start: in a session, and so a process group, of its own,
# its input from /dev/null and its output to a file in the state folder, never this hook's pipe,
# which a run still holding would keep the push waiting on (L235). The hook waits for it up to the
# budget. If it is still going then, the hook refuses and leaves it running; the next push of the
# SAME input counts its verdict, waiting for it up to the budget again if it is still going, and
# never starts a second copy. The gate is no weaker for it: a push goes through only once every
# scanner has passed on exactly the input being pushed.
#
# THE INPUT is the key above, the commit tree plus the digest of every file that differs from it on
# disk (#1910), the same key the record of passes uses, so a run's verdict counts exactly where a remembered pass would (L370).
# A run is kept at <state>/runs/<repo>/<scanner>.<key>, where <scanner> is a digest of the suite and
# its section. The checkout that started it is recorded beside it, because two checkouts of one
# repository, worktrees, push different trees at once: a run is SUPERSEDED, stopped and removed,
# only by a push from its OWN checkout with a different input, never by another checkout's, or two
# sessions would stop each other's runs for ever. Runs do not pile up: one per scanner per checkout,
# a finished one removed once its verdict is read, and anything older than the stale age below
# stopped and removed whoever finds it.
#
# WHAT IT CANNOT SEE, said plainly: a file changed while a run reads it and changed BACK before the
# next push leaves the key equal and the verdict about a tree that existed only in between. A run
# inside the budget has always had that window; a run in the background widens it.
#
# Without a key (the files that differ from the commit could not be listed) nothing can be matched
# later, so runs go in this hook's own work folder and are stopped at the budget, as #1889 did.
#
# WHY THAT CASE IS STOPPED RATHER THAN LEFT TO FINISH (claude-config#1910). A run left going is
# worth something only because a later push can count its verdict, and it can count it only where
# it knows the run read exactly what that push carries. Without that listing nothing says what the
# run read, so its verdict could never be counted by any push: left running it would be
# minutes of load with no reader (L46). It is stopped, and the refusal says why, and that a retry
# cannot help a scanner slower than the budget until the cause is fixed, naming the command that
# shows it, so the slow scanner is not refused on every retry with nobody told why (L11, L111). The
# same is said, in its own words, when the lock or the folder for runs is missing.
_sc_checkout="$(pwd -P)"
_sc_detach=""
_sc_detach_why=""
_sc_detach_fix=""
_sc_runs="$_sc_work/runs"
# The lock that lets one push at a time decide about a scanner's runs, shared with claude-sync (L370),
# and the shared rule for a run recorded moments ago (lib/recorded-pid.sh, claude-config#1909).
# Without either, nothing could stop two pushes each starting a copy, so runs are stopped at the
# budget.
# Each is loaded and judged on its own, so a refusal names the one that is missing (#1910, L11). The
# record of passes needs only the lock itself, so it asks _sc_have_pidlock.
_sc_have_lock=""
_sc_have_pidlock=""
_sc_lock_lib_missing=""
# shellcheck source=lib/pid-lock.sh
if . "$HOOK_DIR/lib/pid-lock.sh" 2>/dev/null && command -v take_pid_lock >/dev/null 2>&1; then
  _sc_have_pidlock=1
else
  _sc_lock_lib_missing="$HOOK_DIR/lib/pid-lock.sh"
fi
# shellcheck source=lib/recorded-pid.sh
if ! { . "$HOOK_DIR/lib/recorded-pid.sh" 2>/dev/null && command -v recorded_pid_young >/dev/null 2>&1; }; then
  _sc_lock_lib_missing="${_sc_lock_lib_missing:+$_sc_lock_lib_missing and }$HOOK_DIR/lib/recorded-pid.sh"
fi
[ -z "$_sc_lock_lib_missing" ] && _sc_have_lock=1
# `mkdir -p` is asked, then the folder is looked at, so a push that loses the race to make it with
# another push at the same moment still finds it there and is not left without one.
[ -n "$_sc_key" ] && mkdir -p "$_sc_state_dir/runs/$_sc_repo_key" 2>/dev/null
if [ -n "$_sc_key" ] && [ -n "$_sc_have_lock" ] && [ -d "$_sc_state_dir/runs/$_sc_repo_key" ]; then
  _sc_detach=1
  _sc_runs="$_sc_state_dir/runs/$_sc_repo_key"
elif [ -z "$_sc_tree" ]; then
  _sc_detach_why="this checkout has no commit, so there is no tree a result could be counted against"
elif [ -z "$_sc_key" ]; then
  _sc_detach_why="the files that differ from the commit could not be listed, so nothing says what a run read and no later push could count its result"
  _sc_detach_fix="To see why the listing fails, run:
    bash $REPO_FILES --changed $_sc_checkout"
elif [ -z "$_sc_have_lock" ]; then
  _sc_detach_why="$_sc_lock_lib_missing could not be loaded, and without it two pushes could each start a copy"
  _sc_detach_fix="Reinstall the hooks with claude-sync pull."
else
  _sc_detach_why="the folder for runs left going, $_sc_state_dir/runs/$_sc_repo_key, could not be made"
fi
mkdir -p "$_sc_runs" 2>/dev/null
# Six hours: far past any scanner here (the slowest, test-run-all-tests.sh, about 7 minutes under
# load), so a run older than this is one nobody is coming back for. A setting, not a measurement.
_sc_run_stale="${SCANNERS_RUN_STALE_SECONDS:-21600}"
# Zero however written is the default, never "stale at once" (lib/whole-number.sh, claude-config#1948).
whole_above_zero "$_sc_run_stale" || _sc_run_stale=21600
# A poll delay that can be injected (L524), for the wait on the suite lock further down.
_sc_sleep="${SCANNERS_SLEEP:-sleep}"

# The run's own script: it runs the suite with its output in the run's folder, then records how long
# it took and, last, its exit code, written whole by a rename so a reader never sees half of one.
# The run's folder is its first argument, so the folder shows in the process listing, which is how a
# recorded process id is told from a recycled one before anything is sent to it (L1011).
_SC_RUN='rd=$1; s=$2; sec=$3; slots=$4; last=$5; t0=$(date +%s); if [ -n "$sec" ]; then HOOK_TESTS_SLOTS="$slots" SECTION_ONLY="$sec" bash "$s" > "$rd/out" 2>&1 < /dev/null; else HOOK_TESTS_SLOTS="$slots" bash "$s" > "$rd/out" 2>&1 < /dev/null; fi; rc=$?; printf "%s" $(( $(date +%s) - t0 )) > "$last.$$" && mv -f "$last.$$" "$last"; printf "%s" "$rc" > "$rd/rc.$$" && mv -f "$rd/rc.$$" "$rd/rc"'
# Starts it in a session of its own and records its process id BEFORE returning, so a push that
# looks at this run a moment later always finds the id. The fork's child is never a process group
# leader, so setsid cannot refuse it. perl's setsid rather than the setsid command, which macOS does
# not have: one route, run by the suite on both systems, rather than two each tested on only one.
_SC_LAUNCHER='use POSIX (); my ($run, $rd, @rest) = @ARGV; my $pid = fork(); exit 127 unless defined $pid;
if ($pid == 0) { POSIX::setsid(); open(STDIN, "<", "/dev/null"); open(STDOUT, ">", "/dev/null"); open(STDERR, ">", "/dev/null");
  exec("bash", "-c", $run, "scanners-before-push-run", $rd, @rest); exit 127; }
open(my $fh, ">", "$rd/pid.tmp") or exit 1; print $fh $pid; close $fh; rename("$rd/pid.tmp", "$rd/pid") or exit 1; exit 0;'

_sc_rd(){   # $1 = run index -> the folder its run writes to
  cat "$_sc_work/$1.dir" 2>/dev/null
}
_sc_slot(){   # $1 = run index -> the digest naming its suite and section
  shasum -a 256 < "$_sc_work/$1.what" 2>/dev/null | awk '{print substr($1, 1, 20)}'
}
# WHETHER A RECORDED PROCESS IS STILL THIS RUN. The process id alone is not enough, because an id
# is reused once its process has gone, so the process's command line must name the run's folder.
#
# Except in the first moments of a run (PR #1897). The id is published the instant the run's
# process is forked, and for an instant after that, while the process is inside execve becoming the
# run, Linux shows its command line as EMPTY. A push looking in that instant judged a live run gone
# and started a second copy of it: two pushes of one tree at once did so on Linux CI on 2026-10-29,
# never on this Mac. So a run started within the last minute counts as itself whenever its process
# is running, by the one rule every such check shares, recorded_pid_young in lib/recorded-pid.sh
# (claude-config#1909), read against the start time the run recorded.
_sc_run_alive(){   # $1 = a run's folder -> 0 when the process it recorded is running and is that run
  local p
  p="$(cat "$1/pid" 2>/dev/null)"
  case "$p" in ''|*[!0-9]*) return 1 ;; esac
  kill -0 "$p" 2>/dev/null || return 1
  case "$(ps -ww -o command= -p "$p" 2>/dev/null)" in *" $1 "*|*" $1") return 0 ;; esac
  recorded_pid_young "$p" "$(cat "$1/started" 2>/dev/null)"
}
# How long ago a run started, from the time it RECORDED in its `started` file, never the file's
# modification time, which anything touching the folder moves. Nothing when it cannot be read.
_sc_run_age(){   # $1 = a run's folder
  local s
  s="$(cat "$1/started" 2>/dev/null)"
  case "$s" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$(( $(date +%s) - s ))"
}
# Stops a run's whole process group, once it is shown to be that run. Only the GROUP is signalled,
# never the bare id: the run leads a group of its own, and a process that merely inherited the id
# without leading a group is then never touched (L1011).
_sc_run_stop(){   # $1 = a run's folder
  local p
  _sc_run_alive "$1" || return 0
  p="$(cat "$1/pid" 2>/dev/null)"
  kill -KILL -- "-$p" 2>/dev/null
  return 0
}
_sc_age(){   # $1 = a file -> its age in whole seconds, or nothing when it cannot be read
  perl -e 'my @s = stat(shift) or exit 1; print time - $s[9]' "$1" 2>/dev/null
}

# ONE PUSH AT A TIME DECIDES ABOUT A SCANNER'S RUNS (assume it runs twice). Two pushes of one input
# at once would each find no run and each start one. The lock is take_pid_lock (lib/pid-lock.sh, the
# one claude-sync takes): taken in one atomic step that never leaves it without its holder's id, and
# a dead holder's lock is taken over under a lock of its own, so two waiters cannot both take it
# over. It is held only while the runs are looked at and one is started, which is milliseconds, so
# five seconds is a deadline nobody waits out unless something is wrong, and then this push refuses
# rather than starting a second copy.
_sc_lock(){   # $1 = the lock file -> 0 once this push holds it
  take_pid_lock "$1" 5
}

# Starts the run for an index, in its folder, and waits on it. Called with the slot's lock held.
_sc_launch(){        # $1 = run index   $2 = the runs in flight at once
  local s sec rd
  s="$(sed -n 1p "$_sc_work/$1.what")"; sec="$(sed -n 2p "$_sc_work/$1.what")"
  rd="$(cat "$_sc_work/$1.dir")"
  rm -rf "$rd"; mkdir -p "$rd" 2>/dev/null
  cp "$_sc_work/$1.what" "$rd/what" 2>/dev/null
  printf '%s' "$_sc_key" > "$rd/input"
  printf '%s' "$_sc_checkout" > "$rd/checkout"
  date +%s > "$rd/started"
  perl -e "$_SC_LAUNCHER" "$_SC_RUN" "$rd" "$s" "$sec" "$2" "$(cat "$_sc_work/$1.last")" </dev/null >/dev/null 2>&1
  _sc_watch "$1"
}
# Waits on a run, whether this push started it or an earlier one did: a small watcher, a child of
# this hook, that ends when the run has written its exit code or is gone. The run itself is never a
# child of this hook, so the watcher is what is waited on and, at the budget, what is stopped. Its
# output is closed, so it holds nothing open either (L235). It looks five times a second.
_sc_watch(){   # $1 = run index
  local rd
  rd="$(cat "$_sc_work/$1.dir")"
  perl -e 'my ($p, $f) = @ARGV; while (! -e $f && $p =~ /^\d+$/ && kill(0, $p)) { select(undef, undef, undef, 0.2) } exit 0' \
    "$(cat "$rd/pid" 2>/dev/null)" "$rd/rc" </dev/null >/dev/null 2>&1 &
  # Kept so the runs of this round, and only they, can be waited on and stopped (#1881).
  _sc_inflight="$_sc_inflight $!"
  _sc_inflight_idx="$_sc_inflight_idx $1"
}

# A run that refused because another suite run held the machine wide lock never ran (#642), so its
# exit code is no verdict and it is started again rather than counted.
_sc_lock_refused(){   # $1 = run index -> 0 when that run refused because another run held the lock
  local rd
  rd="$(cat "$_sc_work/$1.dir" 2>/dev/null)"
  [ "$(cat "$rd/rc" 2>/dev/null)" = "5" ] || return 1
  grep -q '^test suite: another run is already going' "$rd/out" 2>/dev/null
}

# Decides, for one index, whether its scanner is started, waited on where an earlier push left it,
# or already has a verdict for this input, and clears away its runs nobody will come back for.
_sc_claim(){   # $1 = run index   $2 = the runs in flight at once
  local slot rd other lock
  slot="$(_sc_slot "$1")"
  printf '%s' "$_sc_runs/$slot-last" > "$_sc_work/$1.last"
  if [ -z "$_sc_detach" ]; then
    printf '%s' "$_sc_runs/$1" > "$_sc_work/$1.dir"
    _sc_launch "$1" "$2"
    return 0
  fi
  rd="$_sc_runs/$slot.$_sc_key"
  printf '%s' "$rd" > "$_sc_work/$1.dir"
  lock="$_sc_runs/$slot-pidlock"
  if ! _sc_lock "$lock"; then
    # Another push is deciding about this very scanner right now. Nothing is started, so there is
    # never a second copy, and the scanner is reported as not finished, which refuses this push.
    : > "$_sc_work/$1.busy"
    return 0
  fi
  for other in "$_sc_runs/$slot".*; do
    [ -d "$other" ] || continue
    [ "$other" = "$rd" ] && continue
    if [ "$(cat "$other/checkout" 2>/dev/null)" = "$_sc_checkout" ] \
       || [ "$(_sc_run_age "$other")" -gt "$_sc_run_stale" ] 2>/dev/null \
       || { [ -f "$other/rc" ] && [ "$(_sc_age "$other/rc")" -gt "$_sc_run_stale" ] 2>/dev/null; }; then
      _sc_run_stop "$other"
      rm -rf "$other"
    fi
  done
  if [ -f "$rd/rc" ] && ! _sc_lock_refused "$1"; then
    # Finished, after the push that started it had gone: its verdict is read back below like any
    # other run's, and it is not run again to find that out.
    : > "$_sc_work/$1.bg"
  elif [ ! -f "$rd/rc" ] && _sc_run_alive "$rd"; then
    : > "$_sc_work/$1.bg"
    _sc_watch "$1"
  else
    _sc_launch "$1" "$2"
  fi
  rm -f "$lock"
  return 0
}
# Starts an index again after it refused on the suite lock, under its slot's lock like any start.
_sc_relaunch(){   # $1 = run index   $2 = the runs in flight at once
  local lock
  if [ -z "$_sc_detach" ]; then _sc_launch "$1" "$2"; return 0; fi
  lock="$_sc_runs/$(_sc_slot "$1")-pidlock"
  _sc_lock "$lock" || { : > "$_sc_work/$1.busy"; return 0; }
  _sc_launch "$1" "$2"
  rm -f "$lock"
}

# THE GATE'S OWN BUDGET (claude-config#1881). On 2026-10-28 this gate was killed at its declared 180
# second timeout on three of three cold readings at a load average of about 145 on 12 cores, against
# 25 seconds at normal load on 2026-10-13. Claude Code's hooks documentation says a PreToolUse hook
# killed at its timeout "doesn't block the tool call", and a headless probe the same day measured
# it on Claude Code 2.1.312: a hook that slept past a 3 second timeout, and would then have refused,
# let the guarded command run. So a push under load went out with nothing scanned, and nothing said
# so. This is a security gate, so it must never pass a push it did not scan.
#
# So the gate stops ITSELF first, at a budget below the declared timeout, stops waiting, and refuses
# the push saying its scanners have not finished. Those still running are left running in the
# background (above, where runs are started) and counted by the next push of the same input. 150
# seconds by default, leaving 30 of the declared 180 for writing the refusal on a machine that busy;
# the suite fails if this default ever reaches the declared timeout. The registration also carries
# onFailure "block", so a gate that overruns even its own budget is a blocked push, never a passed
# one; that is the backstop, and this is the reason, which Claude Code discards from a killed hook.
#
# A scanner that FINISHED and passed inside the budget is remembered as usual, so a retry runs only
# the ones that did not finish rather than starting again from nothing.
#
# The wait on the budget is a signal from a watchdog rather than a poll, so a push whose scanners
# finish in two seconds waits about two seconds, not until the budget (L290); each run's own watcher
# looks five times a second. The watchdog is one perl process with its output closed, so nothing it
# leaves can hold this hook's output open after it exits (L235).
_sc_budget_default=150
_sc_budget="${SCANNERS_BUDGET_SECONDS:-$_sc_budget_default}"
if ! whole_above_zero "$_sc_budget"; then
  # Unreadable is the default, never zero (which would refuse every push) and never no budget
  # (which is the defect), and it is said rather than swallowed (L50, L90).
  echo "scanners-before-push: SCANNERS_BUDGET_SECONDS is '$_sc_budget', not a whole number of seconds, so the default of $_sc_budget_default is used." >&2
  _sc_budget="$_sc_budget_default"
fi
_sc_inflight=""
_sc_inflight_idx=""
_sc_out_of_time=""
_sc_stop_inflight(){   # at the budget: stops waiting on this round's runs
  local p i
  # Only the WATCHERS are stopped, with a kill that cannot be caught (#1889), and never with a walk
  # of their children: the runs are not their children, and a run left going is the point.
  for p in $_sc_inflight; do kill -9 "$p" 2>/dev/null; done
  # Without a key a run's verdict could never be matched later, so it is stopped, its whole process
  # group, as #1889 did.
  if [ -z "$_sc_detach" ]; then
    for i in $_sc_inflight_idx; do _sc_run_stop "$(cat "$_sc_work/$i.dir" 2>/dev/null)"; done
  fi
}
_sc_wait_bounded(){    # waits for this round's runs until the budget runs out, then stops waiting (the runs go on, unless there is no key)
  local left watchdog
  # Nothing launched this round (every scanner skipped): a bare `wait` with no process ids would
  # wait for every child, the watchdog included, so there is nothing to wait for and it returns.
  case "$_sc_inflight" in *[![:space:]]*) ;; *) return 0 ;; esac
  left=$(( _sc_t0 + _sc_budget - $(date +%s) ))
  if [ "$left" -le 0 ]; then
    _sc_out_of_time=1
    _sc_stop_inflight
  else
    trap '_sc_out_of_time=1; _sc_stop_inflight' USR1
    perl -e 'sleep shift; kill "USR1", shift' "$left" "$$" </dev/null >/dev/null 2>&1 &
    watchdog=$!
    # A wait interrupted by the watchdog's signal returns at once, after the trap has stopped the
    # runs, so it is waited again to reap them.
    wait $_sc_inflight 2>/dev/null
    [ -n "$_sc_out_of_time" ] && wait $_sc_inflight 2>/dev/null
    # KILL, never a plain kill (claude-config#1889). When the scanners finish quickly this runs a
    # moment after the watchdog was started, and a plain kill arriving before the watchdog has
    # finished becoming perl is caught by the handler this script's EXIT trap installs and is lost
    # at the exec (L240). Measured 2026-10-29 with a bare loop of this shape: 1 in 40 starts under
    # bash 3.2 and 2 in 80 under bash 5.3 outlived it, and on Linux CI it left a gate waiting here
    # for the watchdog to sleep out the whole budget, a push that took 150 seconds and passed. A
    # KILL cannot be caught or ignored, so the wait below always returns.
    kill -9 "$watchdog" 2>/dev/null
    wait "$watchdog" 2>/dev/null
    trap - USR1
  fi
  wait $_sc_inflight 2>/dev/null
  _sc_inflight=""
  _sc_inflight_idx=""
}

while IFS= read -r s; do
  [ -n "$s" ] || continue
  if grep -q 'SECTION_ONLY' "$s" 2>/dev/null; then
    sections="$(scanning_sections "$s")"
    [ -n "$sections" ] || continue
    while IFS= read -r sec; do
      [ -n "$sec" ] || continue
      start_one "$s" "$sec"
    done <<SECTIONS
$sections
SECTIONS
  else
    start_one "$s" ""
  fi
done <<EOF
$scanners
EOF

_sc_i=1
while [ "$_sc_i" -le "$_sc_n" ]; do
  _sc_claim "$_sc_i" "$_sc_n"
  _sc_i=$(( _sc_i + 1 ))
done
# Its standard error is closed because bash reports every run it reaps after a kill ("Killed: 9",
# with the subshell's source line) on the shell's own standard error, which is this hook's refusal
# text. What was stopped is said in the refusal instead, in words (#1881).
_sc_wait_bounded 2>/dev/null

# A SCANNER THAT NEVER RAN BECAUSE ANOTHER SUITE RUN HELD ITS LOCK (claude-config#642). The sync
# suite takes a machine wide lock and refuses, exit 5, with "test suite: another run is already
# going", when another run holds it. Twice on 2026-10-04 that refusal read here as "a scanner that
# reads the WHOLE repository fails" with an empty detail; each time the section passed 71/0 alone a
# minute later. A refusal is not a verdict, so it is neither a failure nor a pass: the gate holds
# its place and tries again on a poll, to a named deadline (L1012), and if the lock is still held
# then it blocks saying THAT, with the remedy, rather than accusing the scanner (L11).
#
# The deadline is counted in ATTEMPTS, so an injected sleep (SCANNERS_SLEEP, for the tests) cannot
# turn it into a spin (L524, L704). 90 seconds by default, a setting: the bound that matters is the
# gate's own budget of 150 seconds (#1881), which the wait is spent out of and stops at, and a run
# of every scanner was measured at 15 to 18 seconds on 2026-09-21, so a wait of 90 plus a rerun fits
# inside it on a quiet machine. On a busy one the budget, not this wait, decides, and a rerun it
# cuts short is refused as out of time.
_sc_lock_wait="${SCANNERS_LOCK_WAIT_SECONDS:-90}"
case "$_sc_lock_wait" in ''|*[!0-9]*) _sc_lock_wait=90 ;; esac
_sc_lock_poll="${SCANNERS_LOCK_POLL_SECONDS:-5}"
whole_above_zero "$_sc_lock_poll" || _sc_lock_poll=5
_sc_locked_list(){   # prints the indexes of runs that refused on the lock
  local i=1
  while [ "$i" -le "$_sc_n" ]; do
    _sc_lock_refused "$i" && printf '%s\n' "$i"
    i=$(( i + 1 ))
  done
}
_sc_tries_left=$(( _sc_lock_wait / _sc_lock_poll ))
_sc_locked="$(_sc_locked_list)"
# The lock wait is spent out of the gate's budget too (#1881): it stops trying once the budget is
# gone, and a run still refused then is reported as held on the lock, below.
while [ -n "$_sc_locked" ] && [ "$_sc_tries_left" -gt 0 ] && [ -z "$_sc_out_of_time" ] \
      && [ "$(date +%s)" -lt $(( _sc_t0 + _sc_budget )) ]; do
  "$_sc_sleep" "$_sc_lock_poll"
  _sc_tries_left=$(( _sc_tries_left - 1 ))
  # Only the refused runs go again, so they are the runs in flight at once this time.
  _sc_relaunch_n="$(printf '%s\n' "$_sc_locked" | grep -c . || true)"
  while IFS= read -r _sc_i; do
    [ -n "$_sc_i" ] || continue
    _sc_relaunch "$_sc_i" "$_sc_relaunch_n"
  done <<LOCKED
$_sc_locked
LOCKED
  _sc_wait_bounded 2>/dev/null
  _sc_locked="$(_sc_locked_list)"
done
if [ -n "$_sc_locked" ]; then
  {
    echo "PUSH BLOCKED: a whole tree scanner could not run, because another test run is going."
    echo ""
    echo "These never ran, so they neither passed nor failed: each refused to start while another"
    echo "suite run held its lock, and the lock was still held after waiting for it (up to ${_sc_lock_wait}s,"
    echo "inside this gate's own budget of ${_sc_budget}s):"
    while IFS= read -r _sc_i; do
      [ -n "$_sc_i" ] || continue
      printf '    %s\n' "$(head -2 "$_sc_work/$_sc_i.what" 2>/dev/null | tr '\n' ' ')"
      grep -m1 '^test suite: another run is already going' "$(_sc_rd "$_sc_i")/out" 2>/dev/null | sed 's/^/      /'
    done <<LOCKED
$_sc_locked
LOCKED
    echo ""
    echo "Retry the push when that run finishes. The line above names the process holding the lock"
    echo "and, when it is an orphan of a run that was killed, the command that ends it."
    echo ""
    echo "OVERRIDE, this one push: SKIP_SCANNERS_CHECK=1 <your original git push command>"
    echo "Explain to the user first why skipping is legitimate. Never override silently."
  } >&2
  exit 2
fi

# Read every result back. A run whose exit code was never written did not finish saying anything,
# and that is not a pass: it is a scanner whose verdict is missing, which must not read as a clean
# one (L98).
#
# A scanner that RAN but could not read what it judges says so in one agreed line, `SUITE-UNMEASURED
# <what, and why>`, and exits non zero with no FAIL line (claude-config#1146). On 2026-10-13 the
# secret scan could not copy the tree it scans, because a file was listed and gone before tar reached
# it, and this gate blocked with "a scanner that reads the WHOLE repository fails" over a count of
# "(0 files)": a secret scan accusing a push of nothing it had looked at. Such a run measured
# nothing, so it is neither a pass, which would publish an unscanned tree, nor a failure of the code
# (L11, L411). It is held apart and said as a fault in this gate's own run, with the scanner's reason.
# A FAIL line outranks it: a scanner that found something is judged by what it found.
#
# The same holds for a scanner STOPPED AT ITS DEADLINE on a machine busier than its cores
# (claude-config#1333). lib/suite-deadline.sh says so in its own agreed line,
# `SUITE-DEADLINE-UNMEASURED <why>`, and exits 124 with no FAIL line (#1330). Matched on the first
# marker alone, such a scanner blocked under "exited 124 with no FAIL line", a failure heading over
# a run that judged nothing (L11, L683). Both markers are read here, each reason given without its
# marker, and a deadline stop adds the remedy for load, since retrying at once on the same busy
# machine is likely to stop it again. The push is held either way: nothing was scanned.
failed=""
unmeasured=""
unmeasured_load=""
# Runs stopped at, or left running past, the gate's own budget (#1881): no verdict, so neither a
# pass nor a failure. A run left running is named with where its output goes; one that was stopped
# (no key, so nothing could be left running) with the command that runs it directly.
unfinished=""
unfinished_cmds=""
ran=0
# Of those that ran, how many finished in the background after an earlier push had gone, said in
# the summary so a verdict this push did not watch being made is never passed off as one it did.
_sc_bg_done=0
_sc_i=1
while [ "$_sc_i" -le "$_sc_n" ]; do
  _sc_what="$(head -2 "$_sc_work/$_sc_i.what" 2>/dev/null | tr '\n' ' ')"
  _sc_rdir="$(_sc_rd "$_sc_i")"
  ran=$(( ran + 1 ))
  _sc_rc_now="$(cat "$_sc_rdir/rc" 2>/dev/null || printf 'missing')"
  if [ "$_sc_rc_now" = "0" ] && [ -n "$_sc_key" ]; then
    # Only a PASS is remembered, and it is remembered against the key it passed on.
    _sc_passed_now="$_sc_passed_now$_sc_key $(head -1 "$_sc_work/$_sc_i.what" 2>/dev/null) $(sed -n 2p "$_sc_work/$_sc_i.what" 2>/dev/null)
"
  fi
  [ -f "$_sc_rdir/rc" ] && [ -f "$_sc_work/$_sc_i.bg" ] && _sc_bg_done=$(( _sc_bg_done + 1 ))
  # Not finished: another push held its slot, or the budget ran out while it was still going. A run
  # that is gone without an exit code is not that, it is a missing verdict, below.
  if [ ! -f "$_sc_rdir/rc" ] && { [ -f "$_sc_work/$_sc_i.busy" ] \
       || { [ -n "$_sc_out_of_time" ] && { [ -z "$_sc_detach" ] || _sc_run_alive "$_sc_rdir"; }; }; }; then
    _sc_s="$(sed -n 1p "$_sc_work/$_sc_i.what" 2>/dev/null)"; _sc_sec="$(sed -n 2p "$_sc_work/$_sc_i.what" 2>/dev/null)"
    _sc_label="$_sc_s"
    [ -n "$_sc_sec" ] && _sc_label="$_sc_s, section \"$_sc_sec\""
    if [ -f "$_sc_work/$_sc_i.busy" ]; then
      _sc_lockname="$_sc_runs/$(_sc_slot "$_sc_i")-pidlock"
      unfinished="$unfinished    $_sc_label: another push held its lock for 5 seconds while starting or reading it; if this repeats, delete $_sc_lockname (and $_sc_lockname.break if it is there)
"
    elif [ -n "$_sc_detach" ]; then
      _sc_for="$(_sc_run_age "$_sc_rdir")"
      _sc_last="$(cat "$(cat "$_sc_work/$_sc_i.last" 2>/dev/null)" 2>/dev/null)"
      case "$_sc_last" in
        ''|*[!0-9]*) _sc_last="no earlier run of it is recorded" ;;
        *) _sc_last="its last run took ${_sc_last}s" ;;
      esac
      case "$_sc_for" in ''|*[!0-9]*) _sc_for="for an unknown time" ;; *) _sc_for="for ${_sc_for}s" ;; esac
      unfinished="$unfinished    $_sc_label: running $_sc_for, $_sc_last; output: $_sc_rdir/out
"
    else
      unfinished="$unfinished    $_sc_label
"
      if [ -n "$_sc_sec" ]; then
        unfinished_cmds="${unfinished_cmds}    SECTION_ONLY=\"$_sc_sec\" bash $_sc_s
"
      else
        unfinished_cmds="${unfinished_cmds}    bash $_sc_s
"
      fi
    fi
  elif [ ! -f "$_sc_rdir/rc" ]; then
    failed="$failed=== $_sc_what ===
this scanner never reported an exit code, so its verdict is missing rather than clean
"
  elif [ "$_sc_rc_now" != "0" ]; then
    _sc_fails="$(awk '/^FAIL|^not ok/ { if (n++ < 10) print }' "$_sc_rdir/out" 2>/dev/null)"
    _sc_unm="$(awk '/^SUITE-(DEADLINE-)?UNMEASURED / { if (n++ < 5) { sub(/^SUITE-(DEADLINE-)?UNMEASURED /, ""); print } }' "$_sc_rdir/out" 2>/dev/null)"
    if [ -z "$_sc_fails" ] && [ -n "$_sc_unm" ]; then
      unmeasured="$unmeasured=== $_sc_what ===
$_sc_unm
"
      grep -q '^SUITE-DEADLINE-UNMEASURED ' "$_sc_rdir/out" 2>/dev/null && unmeasured_load=1
    else
      # No FAIL line at all is a failure whose reason is somewhere else in what it printed, so the
      # end of that is shown rather than an empty detail (#642 was found behind one).
      [ -n "$_sc_fails" ] || _sc_fails="it exited $_sc_rc_now with no FAIL line; the end of what it printed:
$(tail -5 "$_sc_rdir/out" 2>/dev/null | sed 's/^/  /')"
      failed="$failed=== $_sc_what ===
$_sc_fails
"
    fi
  fi
  _sc_i=$(( _sc_i + 1 ))
done

# What passed on this key, written only when nothing failed or went unmeasured, so a run with
# either in it never lets a sibling be skipped on the strength of a push that was blocked.
#
# A run that only RAN OUT OF TIME is the exception, on purpose (#1881): it found nothing and nothing
# in it failed to read, so each scanner that finished passed on exactly this key, and remembering
# those is what lets a retry on a busy machine run only the scanners that did not finish. The ones
# stopped wrote no exit code, so they are never remembered and always run again.
#
# MERGED INTO THE TREE'S FILE, UNDER ITS LOCK (claude-config#1910, see where the record is named).
# Read, joined with this push's passes, written whole to a file beside it and only then renamed over
# it, so the record is never empty or half written at any instant, and a read that fails writes
# nothing rather than a record missing what was there (L5). The lock is take_pid_lock, the one the
# runs above are decided under, held for the milliseconds of the merge. A record that cannot be
# written is said, never passed over: the push is no less scanned, but a retry runs those again.
_sc_record_merge(){   # -> 0 once the tree's file holds every pass it held and this push's
  local old="" tmp="$_sc_passed_file.$$" p age
  if [ -f "$_sc_passed_file" ]; then old="$(cat "$_sc_passed_file" 2>/dev/null)" || return 1; fi
  if ! printf '%s\n%s' "$old" "$_sc_passed_now" | grep . | sort -u > "$tmp" 2>/dev/null \
     || ! mv -f "$tmp" "$_sc_passed_file" 2>/dev/null; then
    rm -f "$tmp" 2>/dev/null
    return 1
  fi
  for p in "$_sc_record_dir"/*.txt; do
    [ -f "$p" ] && [ "$p" != "$_sc_passed_file" ] || continue
    age="$(_sc_age "$p")"
    case "$age" in ''|*[!0-9]*) continue ;; esac
    [ "$age" -gt "$_sc_record_keep" ] && rm -f "$p"
  done
  # The single file per repository kept before #1910, which nothing reads any more.
  rm -f "$_sc_state_dir/$_sc_repo_key.txt" 2>/dev/null
  return 0
}
_sc_record_unwritten=""
if [ -z "$failed" ] && [ -z "$unmeasured" ] && [ -n "$_sc_key" ] && [ -n "$_sc_passed_now" ]; then
  _sc_record_why=""
  if [ -z "$_sc_have_pidlock" ]; then
    _sc_record_why="the record is written only under the lock lib/pid-lock.sh gives, and it could not be loaded"
  elif ! mkdir -p "$_sc_record_dir" 2>/dev/null; then
    _sc_record_why="its folder, $_sc_record_dir, could not be made"
  else
    _sc_lock "$_sc_record_dir/pidlock"; _sc_lock_rc=$?
    case "$_sc_lock_rc" in
      0)
        _sc_record_merge || _sc_record_why="$_sc_passed_file could not be read or written"
        rm -f "$_sc_record_dir/pidlock" ;;
      1) _sc_record_why="another push held its lock for 5 seconds; if this repeats, delete $_sc_record_dir/pidlock (and $_sc_record_dir/pidlock.break if it is there)" ;;
      *) _sc_record_why="its lock could not be taken in $_sc_record_dir" ;;
    esac
  fi
  [ -n "$_sc_record_why" ] \
    && _sc_record_unwritten="The scanners that passed were not remembered, because $_sc_record_why, so a retry runs them again."
  # A push that goes through says it in its systemMessage, before the line saying what it covered
  # (#1931): on stderr alone, which Claude Code discards on exit 0, it reached nobody. A refused one
  # says it in its refusal, below.
fi

# Every run with a verdict has now been read, so its folder goes, and the record above is the one
# place a pass is remembered (L83). A failure is never remembered, so the next push runs it afresh.
# A pass from a push in which another scanner failed or measured nothing is NOT remembered either,
# by the rule above that a blocked push lets no sibling be skipped (#1146), and that holds for a pass
# made in the background too: its folder goes with the rest and the next push runs it again, even
# when that is the slow one. Keeping the folder would be a second record of passes that the rule
# above does not govern. A failure usually means the tree changes before the next push anyway, which
# would stop the run being counted whatever was kept. Only runs still going are left, for the push
# after this one. Taken under the slot's lock, so a push deciding about the same scanner at this
# moment never sees half a folder.
if [ -n "$_sc_detach" ]; then
  _sc_i=1
  while [ "$_sc_i" -le "$_sc_n" ]; do
    _sc_rdir="$(_sc_rd "$_sc_i")"
    if [ -f "$_sc_rdir/rc" ]; then
      _sc_lockdir="$_sc_runs/$(_sc_slot "$_sc_i")-pidlock"
      if _sc_lock "$_sc_lockdir"; then
        rm -rf "$_sc_rdir"
        rm -f "$_sc_lockdir"
      fi
    fi
    _sc_i=$(( _sc_i + 1 ))
  done
fi

# What the unmeasured scanners said, written once, for the block below whichever form it takes.
_sc_unmeasured_note(){
  echo "These scanners ran and measured nothing: each could not read what it judges, or was stopped"
  echo "at its deadline on a machine too busy to judge it, which is a fault in this gate's own run,"
  echo "not a finding about your change. Nothing was found, and nothing was checked either. Each said why:"
  echo ""
  printf '%s' "$unmeasured"
  # Said in both blocks that print this note, so a deadline stop beside a real failure gets it too.
  if [ -n "$unmeasured_load" ]; then
    echo ""
    echo "A scanner was stopped at its deadline while this Mac was busier than its cores, so retry the push when the machine is quieter."
  fi
}

# What the scanners stopped at the budget were, written once, for whichever block is printed (#1881).
# It names the load, because a budget that is ample on a quiet machine is what a busy one runs out
# of, and it claims only what was measured: that these did not finish in the time, not why (L11).
_sc_unfinished_note(){
  local load="load average unknown"
  if . "$HOOK_DIR/lib/load-average.sh" 2>/dev/null && command -v load_average_note >/dev/null 2>&1; then
    load="$(load_average_note)"
  fi
  if [ -n "$_sc_detach" ]; then
    echo "These scanners did not finish in ${_sc_budget} seconds, so they have neither passed nor failed yet."
    echo "They are still running in the background, on their own, reading exactly this tree and these"
    echo "uncommitted files ($load):"
  else
    echo "These scanners did not finish in ${_sc_budget} seconds and were stopped, so they neither passed nor"
    echo "failed ($load):"
  fi
  printf '%s' "$unfinished"
  echo ""
  # Why they could not be left running, from the one place that decided it (#1910).
  if [ -z "$_sc_detach" ]; then
    echo "They were stopped rather than left running, because $_sc_detach_why."
    echo "Until that is fixed a retry stops them at the same point, so a scanner that needs more than"
    echo "${_sc_budget} seconds cannot pass here."
    [ -n "$_sc_detach_fix" ] && printf '%s\n' "$_sc_detach_fix"
    echo ""
  fi
  echo "This gate stops itself at ${_sc_budget} seconds, inside the timeout its registration declares, because"
  echo "Claude Code lets a push through when it kills a hook at that timeout, with nothing scanned."
  # Said only as far as the write below the read back did it: passes are kept when there is a key
  # and nothing failed or went unmeasured, and the record could be written (#1910).
  if [ -n "$_sc_record_unwritten" ]; then
    echo "$_sc_record_unwritten"
  elif [ -n "$_sc_detach" ] && [ -z "$failed" ] && [ -z "$unmeasured" ]; then
    echo "Every scanner that did finish and pass is remembered, so a retry does not run those again."
  elif [ -n "$_sc_key" ] && [ -z "$failed" ] && [ -z "$unmeasured" ]; then
    echo "Every scanner that did finish and pass is remembered, so a retry runs only the ones above."
  elif [ -n "$_sc_detach" ]; then
    echo "Nothing that finished in this run is remembered, because another scanner failed or measured"
    echo "nothing, so a retry runs those again."
  elif [ -z "$_sc_key" ]; then
    echo "Nothing that finished could be remembered either, with no key to remember it against, so a"
    echo "retry runs every scanner again."
  else
    echo "Nothing from this run is remembered, because another scanner failed or measured nothing, so a"
    echo "retry runs every scanner again."
  fi
  echo ""
  if [ -n "$_sc_detach" ]; then
    echo "So push again once they finish. A push of this same tree and these uncommitted files counts"
    echo "their result without running them again, and waits up to ${_sc_budget} seconds for any still going;"
    echo "a push of anything else from this checkout stops them and starts again. A push goes through only"
    echo "once every scanner has passed on exactly what it carries."
    return 0
  fi
  echo "A retry passes only if every one finishes inside the budget, so retry when the machine is quieter,"
  echo "or run each one directly to see it through:"
  printf '%s' "$unfinished_cmds"
}

if [ -z "$failed" ] && [ -n "$unmeasured" ]; then
  {
    echo "PUSH BLOCKED: a whole tree scanner measured nothing, so this push was not scanned."
    echo ""
    _sc_unmeasured_note
    echo ""
    if [ -n "$unfinished" ]; then
      _sc_unfinished_note
      echo ""
    fi
    echo "Retry the push. If it says this again, run the scanner directly to see the whole of it:"
    echo "    bash <the suite named above>"
    echo ""
    echo "OVERRIDE, this one push: SKIP_SCANNERS_CHECK=1 <your original git push command>"
    echo "Explain to the user first why skipping is legitimate. Never override silently."
  } >&2
  exit 2
fi

# Out of time with nothing failed and nothing unmeasured: refused, never passed (#1881). Before the
# success branch below, which would otherwise count the stopped runs among those that "passed".
if [ -z "$failed" ] && [ -n "$unfinished" ]; then
  {
    echo "PUSH BLOCKED: the whole tree scanners did not finish in ${_sc_budget} seconds, so this push was not scanned."
    echo ""
    _sc_unfinished_note
    echo ""
    echo "OVERRIDE, this one push: SKIP_SCANNERS_CHECK=1 <your original git push command>"
    echo "Explain to the user first why skipping is legitimate. Never override silently."
  } >&2
  exit 2
fi

if [ -z "$failed" ]; then
  # What it covered, once, so the coverage of this gate is visible rather than assumed (L400). As a
  # systemMessage, since on stderr alone Claude Code threw it away on this exit 0 (#1906).
  _sc_bg=""
  if [ "$_sc_bg_done" -gt 0 ]; then
    _sc_bg="$(printf 'scanners-before-push: %s of the scans below finished in the background, on exactly this tree and these uncommitted files, after an earlier push was refused while they ran.' "$_sc_bg_done")"$'\n'
  fi
  if [ "$ran" -eq 0 ] && [ "$_sc_skipped" -gt 0 ]; then
    # Every scanner was skipped, so nothing was scanned at this moment. Said in those words: a line
    # reading "0 scans passed" is what a run that scanned nothing and a clean tree have in common
    # (L98).
    _sc_covered="$(printf 'scanners-before-push: nothing was scanned for this push. All %s whole tree scan(s) had already passed on exactly this tree and these uncommitted files%s.' "$_sc_skipped" "$_sc_floor_note")"
  elif [ "$_sc_skipped" -gt 0 ]; then
    _sc_covered="$(printf 'scanners-before-push: %s whole tree scan(s) passed before this push, run at once, reading %s uncommitted file(s) as well as the committed ones%s. %s more were skipped, having already passed on exactly this tree and these uncommitted files.' "$ran" "${uncommitted_n:-0}" "$_sc_floor_note" "$_sc_skipped")"
  else
    _sc_covered="$(printf 'scanners-before-push: %s whole tree scan(s) passed before this push, run at once, reading %s uncommitted file(s) as well as the committed ones%s.' "$ran" "${uncommitted_n:-0}" "$_sc_floor_note")"
  fi
  _sc_unremembered=""
  [ -n "$_sc_record_unwritten" ] && _sc_unremembered="scanners-before-push: ${_sc_record_unwritten}"$'\n'
  hook_allow_notice "${_sc_unremembered}${_sc_bg}${_sc_covered}"
fi

{
  echo "PUSH BLOCKED: a scanner that reads the WHOLE repository fails."
  echo ""
  echo "These guards fail over what a change adds anywhere, so the gate that reads"
  echo "the diff cannot see them and CI is otherwise the first place they speak. On"
  echo "2026-09-20 that put two defects on main in one evening and turned the build"
  echo "red twice, both of them caught in seconds by a scanner nobody had run."
  echo ""
  printf '%s' "$failed"
  # Uncommitted files are read too (claude-config#522), and a failure in one is a draft rather than
  # anything this push carries, so the count is said where the verdict is.
  echo "These scans read ${uncommitted_n:-0} uncommitted file(s) as well as the committed ones. A failure"
  echo "in one of those is about a file this push does not carry: commit it fixed, or move it aside."
  echo ""
  if [ -n "$unmeasured" ]; then
    _sc_unmeasured_note
    echo ""
  fi
  if [ -n "$unfinished" ]; then
    _sc_unfinished_note
    echo ""
  fi
  echo "Reproduce any of them directly:"
  echo "    bash <the suite named above>"
  echo ""
  echo "OVERRIDE: if this is genuinely a false positive, re-run with:"
  echo "    SKIP_SCANNERS_CHECK=1 <your original git push command>"
  echo "BEFORE overriding you MUST explain to the user, in plain non-technical"
  echo "language, why skipping is legitimate here. Never override silently."
} >&2
exit 2
