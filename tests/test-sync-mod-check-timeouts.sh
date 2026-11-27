#!/usr/bin/env bash
# A mod check that timed out says "could not check", never "a mod is not loading" (claude-config#3759).
#
# claude-sync's check_mods_loaded asks `claude plugin validate` about each mod, bounded by
# SYNC_CLAUDE_CHECK_TIMEOUT. On 2026-11-26 at 11:14 AM ET one validation on the personal MacBook did
# not answer in time at a load average of about 60, and Dan was shown "a mod is not loading on this
# Mac" though no mod was failing: three outcomes (not listed, refused, timed out) set the one flag.
# Now a mod Claude Code does not list, or that validation refuses, still notifies at once; a time out
# is said as could not check, in the run's output and in `claude-sync status`; and it notifies only
# once it has repeated for the same mod on SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY syncs in a row (5), so
# a check that can never finish is still heard. The count lives in the clone's .mod-check-timeouts,
# and a record that cannot be read is said so and never counted as no time outs.
#
# Every claude here is a stand in, and the one that answers late is ended by the very alarm
# run_bounded sets, fired at once, so no test waits for a real bound (L290).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SCRIPT="$ROOT/claude-sync"
pass=0; fail=0
check(){ # check <name> <command>
  if bash -c "$2" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sync-mod-check-timeouts.XXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "FAIL: $(basename "$0"): the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_SUITE_RUN_ID="${CLAUDE_SUITE_RUN_ID:-test-sync-mod-check-timeouts}"
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry" SYNC_ZSHRC="$WORK/zshrc-guard"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root" SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here" SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard"
export SYNC_HOLD_FILE="$WORK/hold-guard" SYNC_RETIRED_FILE="$WORK/retired-guard" SYNC_LOG_FILE="$WORK/sync-log"
export SYNC_GH="$WORK/no-such-gh-here"
export SYNC_LAUNCHAGENTS="$WORK/launchagents-guard" SYNC_MANAGED_SETTINGS="$WORK/managed-settings-guard.json"
export SYNC_PS_FIXTURE="$WORK/ps-guard"
mkdir -p "$SYNC_SCRATCH_ROOT"; printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"; : > "$SYNC_PS_FIXTURE"

H="$WORK/home"; R="$WORK/repo"; C="$WORK/dot-claude"
mkdir -p "$H" "$C" "$R/payload"
for m in alpha-mod beta-mod; do
  mkdir -p "$C/mods/$m/.claude-plugin" "$R/payload/mods/$m/.claude-plugin"
  printf '{ "name": "%s" }\n' "$m" > "$C/mods/$m/.claude-plugin/plugin.json"
  cp "$C/mods/$m/.claude-plugin/plugin.json" "$R/payload/mods/$m/.claude-plugin/plugin.json"
done
echo '{"hooks":{}}' > "$C/settings.json"
RECORD="$R/.mod-check-timeouts"

# The stand in claude. `plugin list` lists the names in LISTED as enabled folder plugins (the
# <name>@inline form measured on 2.1.288); `plugin validate` refuses a mod named in REFUSED, answers
# late for one named in LATE, and passes the rest. Answering late is the bound firing: the stand in
# reads the alarm it inherited across exec (so a run with no bound at all fails instead), then
# raises it at once, which is exactly what the bound does to a validation that does not answer.
FAKE="$WORK/claude"
cat > "$FAKE" <<'FAKE'
#!/bin/bash
case "$1 $2" in
  "plugin list") printf '['; sep=''; for n in ${LISTED-alpha-mod beta-mod}; do printf '%s{"id":"%s@inline","enabled":true}' "$sep" "$n"; sep=','; done; printf ']\n' ;;
  "plugin validate")
    for n in ${REFUSED:-}; do case "$3" in */"$n"|*/"$n"/) echo "error: hooks: refused"; exit 1 ;; esac; done
    for n in ${LATE:-}; do case "$3" in */"$n"|*/"$n"/) exec perl -e 'my $left = alarm 0; if (!$left) { print "error: no bound\n"; exit 3 } kill "ALRM", $$; sleep 60' ;; esac; done
    echo "ok" ;;
  *) exit 2 ;;
esac
FAKE
chmod +x "$FAKE"
NL="$WORK/notified"; : > "$NL"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -message ] && { printf "%%s\\n" "$2" >> "%s"; shift; }; shift; done\n' "$NL" > "$WORK/notifier"
chmod +x "$WORK/notifier"

N=0
pull(){ # pull [VAR=value ...] -> the pull's output in $WORK/pull.<n>, its name in $OUT
  N=$((N + 1)); OUT="$WORK/pull.$N"
  env "$@" HOME="$H" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=0 SYNC_NOTIFIER="$WORK/notifier" SYNC_CLAUDE_BIN="$FAKE" \
    CLAUDE_HOME="$C" SYNC_REPO="$R" bash "$SCRIPT" pull > "$OUT" 2>&1 < /dev/null
}
status(){ HOME="$H" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_CLAUDE_BIN="$FAKE" CLAUDE_HOME="$C" SYNC_REPO="$R" bash "$SCRIPT" status 2>&1 < /dev/null; }
notes(){ wc -l < "$NL" | tr -d ' '; }
show(){ echo "    $1 said:"; sed -n '1,25p' "$2" | cut -c1-300 | sed 's/^/      /'; }
# check runs its command in a new bash, which sees only what is exported.
export SCRIPT NL H FAKE C R
export -f notes status

# Control: every mod lists and validates. Nothing is said about either and nobody is notified, so
# the words the checks below look for come from the outcome under test (L1).
pull
check "control: a healthy check notifies nobody" "[ \"\$(notes)\" = 0 ]"
[ "$(notes)" = 0 ] || { echo "    it posted:"; sed 's/^/      /' "$NL"; }
check "control: and says no mod could not be checked" "! grep -q 'could not check mod' '$OUT'"
check "control: and leaves no record of time outs" "[ ! -e '$RECORD' ]"

# One time out. Said as could not check, naming the mod, and never as a mod that is not loading.
pull LATE=alpha-mod
cp "$OUT" "$WORK/first-late"
check "a time out is said as could not check, naming the mod" "grep -q 'could not check mod alpha-mod' '$WORK/first-late'"
check "and never as a mod that is not loading" "! grep -q -i 'not loading' '$WORK/first-late'"
check "and notifies nobody the first time" "[ \"\$(notes)\" = 0 ]"
grep -q 'could not check mod alpha-mod' "$WORK/first-late" || show "the pull" "$WORK/first-late"
status > "$WORK/status.1"
check "status says it could not check that mod" "grep -q 'could not check mod alpha-mod' '$WORK/status.1'"
check "status never says a mod is not loading" "grep -q 'mod' '$WORK/status.1' && ! grep -q -i 'not loading' '$WORK/status.1'"
grep -q 'could not check mod alpha-mod' "$WORK/status.1" || { echo "    status said:"; grep -i -e mod -e check "$WORK/status.1" | sed -n '1,20p' | sed 's/^/      /'; }

# Four more in a row: the fifth notifies, once, saying could not check.
for i in 2 3 4; do pull LATE=alpha-mod; done
check "four time outs in a row still notify nobody" "[ \"\$(notes)\" = 0 ]"
pull LATE=alpha-mod
check "the fifth in a row for the same mod notifies" "[ \"\$(notes)\" = 1 ] && grep -q 'alpha-mod' '$NL'"
check "and the notification says could not check, never not loading" "grep -q 'could not check' '$NL' && ! grep -q -i 'not loading' '$NL'"
check "and it is in the sync log with a time" "grep -q 'could not check mod alpha-mod' '$SYNC_LOG_FILE'"
grep -q 'alpha-mod' "$NL" || show "the fifth pull" "$OUT"
pull LATE=alpha-mod
check "a sixth in a row does not notify again" "[ \"\$(notes)\" = 1 ]"
check "and status gives the count" "grep -q 'could not check mod alpha-mod' <<< \"\$(status)\" && grep -q '6 syncs in a row' <<< \"\$(status)\""

# A check that answers ends the run, and counting starts again from one.
pull
check "a check that answers clears the record" "[ ! -e '$RECORD' ] || ! grep -q '^alpha-mod' '$RECORD'"
check "and status no longer names the mod" "! grep -q 'could not check mod alpha-mod' <<< \"\$(status)\""
for i in 1 2 3 4; do pull LATE=alpha-mod; done
check "four time outs after an answer do not notify" "[ \"\$(notes)\" = 1 ]"
pull

# A different mod's time outs are its own count: alternating between two mods never reaches five.
for i in 1 2 3; do pull LATE=alpha-mod; pull LATE=beta-mod; done
check "time outs that move between mods are not one run" "[ \"\$(notes)\" = 1 ]"
pull

# A mod Claude Code does not list notifies at once, as before ...
: > "$NL"
pull LISTED=beta-mod
check "an unlisted mod notifies on the first sync" "[ \"\$(notes)\" = 1 ] && grep -q -i 'not loading' '$NL'"
check "and is named in the output" "grep -q 'mod alpha-mod is in' '$OUT'"
# ... and so does one validation refuses ...
: > "$NL"
pull REFUSED=beta-mod
check "a refused mod notifies on the first sync" "[ \"\$(notes)\" = 1 ] && grep -q -i 'not loading' '$NL'"
check "and is named with the reason" "grep -q 'mod beta-mod was refused' '$OUT'"
# ... and so does a list that names no mod at all.
: > "$NL"
pull LISTED=
check "a list naming no mod notifies on the first sync" "[ \"\$(notes)\" = 1 ]"
# A refusal beside a time out notifies for the refusal, and still says could not check for the other.
: > "$NL"
pull REFUSED=beta-mod LATE=alpha-mod
check "a refusal beside a time out notifies at once" "[ \"\$(notes)\" = 1 ] && grep -q -i 'not loading' '$NL'"
check "and the time out is still said as could not check" "grep -q 'could not check mod alpha-mod' '$OUT'"
pull

# Failure path: a record that cannot be read is said so, and is not taken for no time outs. The
# time out it meets notifies, since nothing can say it is the first.
: > "$NL"
printf 'this is not a record\n' > "$RECORD"
status > "$WORK/status.2"
check "status says a record it cannot read could not be read" "grep -q 'mod-check-timeouts, could not be read' '$WORK/status.2'"
pull LATE=alpha-mod
check "a pull says the record could not be read" "grep -q 'mod-check-timeouts' '$OUT' && grep -q 'could not be read' '$OUT'"
check "and a time out it meets then notifies, rather than counting from zero" "[ \"\$(notes)\" = 1 ] && grep -q 'alpha-mod' '$NL'"
check "and that notification still never says not loading" "! grep -q -i 'not loading' '$NL'"
check "and the unreadable record is kept aside for a look" "grep -q 'this is not a record' '$RECORD.unreadable'"
check "and a new record counts from this sync" "grep -q '^alpha-mod	1	' '$RECORD'"
grep -q 'could not be read' "$OUT" || show "the pull meeting an unreadable record" "$OUT"
# A record whose count is not a number is unreadable too, never zero.
: > "$NL"; rm -f "$RECORD.unreadable"
printf 'alpha-mod\tmany\t1700000000\t0\n' > "$RECORD"
pull LATE=alpha-mod
check "a record whose count is not a number is unreadable, not zero" "grep -q 'could not be read' '$OUT' && [ \"\$(notes)\" = 1 ]"
pull

# Failure path: the number of time outs that notify is refused when it cannot be read.
HOME="$H" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$C" SYNC_REPO="$R" SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY=soon bash "$SCRIPT" status > "$WORK/status.bad" 2>&1; rc_bad=$?
check "an unreadable SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY is refused" "[ '$rc_bad' -eq 2 ] && grep -q 'SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY=.soon. is not a positive whole number' '$WORK/status.bad'"
# And a smaller number set for one run is honoured.
: > "$NL"
pull LATE=beta-mod SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY=1
check "SYNC_MOD_CHECK_TIMEOUTS_TO_NOTIFY=1 notifies on the first time out" "[ \"\$(notes)\" = 1 ] && grep -q 'beta-mod' '$NL'"

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
