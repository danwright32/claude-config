#!/usr/bin/env bash
# Tests the core logic of claude-sync WITHOUT touching real git/GitHub or the
# real ~/.claude. Everything runs in throwaway temp dirs via env overrides:
#   CLAUDE_HOME  - stand-in for ~/.claude
#   SYNC_REPO    - stand-in for the sync repo
#   SYNC_NO_GIT  - skip all git operations
set -uo pipefail

# Both honour a value passed IN. A stopped-early run (#27) executes an extracted copy from a
# temp directory, where deriving these from $0 points at a claude-sync that does not exist:
# every run then silently did nothing while the suite reported the resulting failures as if
# the code were broken.
SCRIPT="${SCRIPT:-$(cd "$(dirname "$0")/.." && pwd)/claude-sync}"
SCRIPT_SELF="${SCRIPT_SELF:-$(cd "$(dirname "$0")" && pwd)/$(basename "$0")}"

# ---- a hard limit on suite runs that spawn suite runs (#34) ----
# #27 let this suite run itself as a subprocess, and 45528c7 fixed one way that recursed without
# bound, after seventeen suite processes were found multiplying on this Mac. That fix was one
# flag read correctly, proven by a single observation, and its own check had to be deleted
# because the child stopped before ever reaching the guard. The SHAPE stayed: anything running
# the suite from inside the suite can multiply.
#
# So a run now carries how deep it already is, every spawn hands its child one more, and a run
# past the limit refuses to start. That closes the class rather than the instance, and it is
# reachable in milliseconds, which is what makes it testable at all.
#
# This lives HERE, ahead of the section runner below, for two reasons. A run that is too deep
# must cost nothing rather than be stopped somewhere inside itself. And the section runner
# re-executes the suite from a temp copy, so a guard placed after it would never be reached by
# a filtered run, which is exactly the kind of run that was multiplying.
SUITE_MAX_DEPTH="${SUITE_MAX_DEPTH:-1}"
for _dpair in "SUITE_DEPTH:${SUITE_DEPTH:-0}" "SUITE_MAX_DEPTH:$SUITE_MAX_DEPTH"; do
  # Fails CLOSED on anything that is not a whole number. `[ abc -gt 1 ]` is a shell ERROR, not a
  # false, and this suite deliberately runs without `set -e`, so an unvalidated comparison would
  # be read as "not too deep" and the limit would be off at exactly the moment the environment
  # is wrong (L50: a value that cannot be parsed must never land on the permissive side).
  case "${_dpair#*:}" in
    ''|*[!0-9]*)
      echo "test suite: ${_dpair%%:*}='${_dpair#*:}' is not a whole number, so how deeply this run is nested cannot be judged. Refusing to run rather than guessing." >&2
      exit 4 ;;
  esac
done
SUITE_DEPTH="${SUITE_DEPTH:-0}"
if [ "$SUITE_DEPTH" -gt "$SUITE_MAX_DEPTH" ]; then
  echo "test suite: refusing to run at depth $SUITE_DEPTH (the limit is $SUITE_MAX_DEPTH). A suite run spawned from inside a suite run multiplies, and the pile-up presents as slowness rather than as a failure, so nobody investigates it." >&2
  exit 4
fi
# Said out loud, because a counter that never moves reads exactly like a limit that works, and
# because a stray suite process in a process list is otherwise attributable to nothing.
if [ "$SUITE_DEPTH" -gt 0 ]; then
  echo "test suite: running at depth $SUITE_DEPTH (the limit is $SUITE_MAX_DEPTH)"
fi
# What every spawn below hands its child. Named once rather than written as an expression at
# each call site, so the sites cannot drift apart from each other.
SUITE_CHILD_DEPTH=$((SUITE_DEPTH + 1))

# ---- run one section at a time (#27) ----
# SECTION_FILTER=<text> runs only the sections whose heading contains <text>. Default is a
# full run, so the pre-push gate is unaffected and nobody can narrow it by accident.
# `section` REPLACES the bare `echo "== ... =="` headings: every check that follows a heading
# belongs to it, and a skipped section's checks are never executed rather than executed and
# hidden, which would save no time at all and defeat the point.
# Also records where the run has got to, for the deadline below to name when it kills a hung run
# (#31), and carries the seam that makes that deadline testable. Both are inert until the
# deadline is armed further down, which is after the section runner has decided whether this
# process is the one that will actually execute the sections.
section(){
  echo "$1"
  if [ -n "$SUITE_SECTION_MARK" ]; then printf '%s\n' "$1" > "$SUITE_SECTION_MARK"; fi
  # SUITE_HANG_IN=<text> stalls deliberately in the first matching section. A deadline can only
  # be trusted once it has been watched killing something (L1), and waiting for a real stall to
  # turn up is not a test.
  if [ -n "${SUITE_HANG_IN:-}" ] && printf '%s' "$1" | grep -qi -- "$SUITE_HANG_IN"; then
    echo "  (test seam: hanging deliberately in this section)"
    while true; do sleep 60; done
  fi
  return 0
}
SUITE_SECTION_MARK=""

# SECTION_UNTIL=<text> runs from the beginning UP TO AND INCLUDING the matching section, then
# stops. Deliberately not "only the matching section": the sections are not independent, they
# build on fixtures and settings established by earlier ones (`unset SYNC_NO_GIT` alone
# changes everything after it), so running one alone produced 24 failures that were purely
# missing setup. A tool that reports failures the code did not cause is worse than a slow
# one, so this trades some of the speed-up for never lying. Iterating on an early or middle
# section is where it pays; asking for the last one is honestly just a full run.
if [ -n "${SECTION_UNTIL:-}" ] && [ -z "${SUITE_FILTERED:-}" ]; then
  _filtered="$(mktemp)"
  awk -v pat="$SECTION_UNTIL" '
    BEGIN{ keep=1; matched=0 }
    /^section "/ {
      if (matched) { keep=0 }
      else if (index(tolower($0), tolower(pat)) > 0) { matched=1; keep=1 }
    }
    keep { print }
    END{ if (!matched) exit 9 }
  ' "$0" > "$_filtered"
  awk_rc=$?
  if [ "$awk_rc" -eq 9 ]; then
    rm -f "$_filtered"
    # A filter that matched no section is an ERROR, never a silent green run: a suite that
    # checked nothing and exits 0 is indistinguishable from one where everything passed.
    echo "test suite: SECTION_UNTIL='$SECTION_UNTIL' matched no section. Run without it, or check the spelling against the '==' headings." >&2
    exit 2
  fi
  printf '\necho ""\necho "PASS=$PASS FAIL=$FAIL (stopped after SECTION_UNTIL=%s, NOT a full run)"\n[ "$FAIL" -eq 0 ]\n' "$SECTION_UNTIL" >> "$_filtered"
  # The extracted file must PARSE before it is run. Cutting at section boundaries can land
  # inside a multi-line construct and produce invalid shell, and without this the broken
  # script runs anyway and its parse errors are reported as if the code under test failed.
  # Found by a mutation that dropped a section and produced exactly that. The seam exists so
  # this refusal can be tested rather than assumed.
  [ -n "${SUITE_EXTRACT_BREAK:-}" ] && printf '\nif then fi\n' >> "$_filtered"
  if ! bash -n "$_filtered" 2>/dev/null; then
    rm -f "$_filtered"
    echo "test suite: stopping after '$SECTION_UNTIL' produced a script that does not parse, so it was NOT run. This is a bug in the section extractor, not in the code under test. Run the full suite." >&2
    exit 3
  fi
  # #34: the depth is passed through UNCHANGED here, deliberately. This is the same logical run
  # re-executed from a temp copy, not a run nested inside another, and counting it would put an
  # ordinary `SECTION_UNTIL=... bash tests/...` at depth 1, whose own #27 subruns would then be
  # refused at depth 2 for no reason. Depth counts suites started BY a suite.
  SUITE_FILTERED=1 SUITE_DEPTH="$SUITE_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$_filtered"; _rc=$?
  rm -f "$_filtered"
  exit "$_rc"
fi

# ---- every run gets a deadline (#31) ----
# Armed HERE rather than at the top, because everything above either exits immediately or hands
# the work to a re-executed copy that arms its own. A run waiting on a covered child needs no
# deadline of its own; the child's fires first and the wait then returns.
#
# The failure this closes: a wait with no deadline cannot fail, it can only hang, and a hang is
# indistinguishable from an ordinary slow run, so nobody investigates and the time is spent
# before anyone suspects anything (L110). It also holds whatever the run had acquired.
#
# The default is measured, not guessed: a full run of this suite took 123 seconds on this Mac on
# 2026-08-17, so 15 minutes is roughly 7x the real thing. Deliberately generous, because wrong
# LOW turns a slow or contended machine into a false failure, and an alarm that cries wolf stops
# being read (L36), which would leave the suite worse off than with no deadline at all.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-900}"
case "$SUITE_TIMEOUT" in
  ''|*[!0-9]*)
    echo "test suite: SUITE_TIMEOUT='$SUITE_TIMEOUT' is not a whole number of seconds. Refusing to run rather than running with no deadline at all, which is the state this exists to end." >&2
    exit 4 ;;
esac
SUITE_SECTION_MARK="$(mktemp -t suite-section)"
if [ "$SUITE_TIMEOUT" -gt 0 ]; then
  _suite_pid=$$
  # A watchdog must not share the abort-on-error behaviour of the work it watches, or an
  # incidental failure kills the watchdog and leaves the work running unobserved, which looks
  # exactly like a healthy system (L71). This is a plain subshell with no `set -e` reaching it.
  #
  # It polls for the run being GONE rather than sleeping the whole deadline in one go, so a
  # normal run's watchdog exits within a couple of seconds of the run finishing instead of
  # lingering. A watchdog outliving its run holds a process id the system may reuse, and would
  # then kill whatever inherited it.
  (
    exec -a suite-deadline-watchdog sh -c '
      waited=0
      while [ "$waited" -lt "$2" ]; do
        sleep 2
        waited=$((waited + 2))
        kill -0 "$1" 2>/dev/null || exit 0
      done
      where="$(cat "$3" 2>/dev/null)"
      echo "" >&2
      echo "test suite: TIMED OUT after ${2}s, still inside section: ${where:-<no section reached>}" >&2
      echo "It was killed rather than left waiting. A run with no deadline cannot fail, it can only hang, and a hang reads as an ordinary slow run (L110). Raise SUITE_TIMEOUT if this machine is genuinely slower than that." >&2
      # Kill the run AND everything it started. Killing only the run itself leaves its children
      # alive, and anything reading the run output then waits for THEM: a 6 second deadline
      # measured 60, the length of the sleep the run happened to be sitting in. Its children are
      # also precisely what is still holding whatever the hung run acquired, which is half the
      # reason a hang is worse than a failure.
      self=$$
      kill_tree() {
        [ "$1" = "$self" ] && return 0    # never the watchdog: it is a child of the run too
        for c in $(pgrep -P "$1" 2>/dev/null); do kill_tree "$c"; done
        kill -9 "$1" 2>/dev/null
      }
      kill_tree "$1"
      rm -f "$3"    # the victim was killed outright and cannot clean up after itself
    ' suite-deadline-watchdog "$_suite_pid" "$SUITE_TIMEOUT" "$SUITE_SECTION_MARK"
  ) &
  SUITE_WATCHDOG_PID=$!
  # Taken out of the job table, or bash announces the kill at cleanup by printing the whole
  # watchdog source, which CONTAINS the words it prints on a real timeout. A healthy run then
  # ends with a timeout message in its own output and anything reading for one is fooled. Caught
  # by the check that a healthy run is not killed by its own deadline, which is the half of this
  # that only exists because a guard has to be seen NOT firing too.
  disown "$SUITE_WATCHDOG_PID" 2>/dev/null || true
else
  SUITE_WATCHDOG_PID=""
fi

# ---- one run at a time (#32) ----
# Three copies of this suite ran at once on 2026-08-17, competing for the machine, and the only
# symptom was output appearing to stall. Beyond being slow, it corrupts the measurements: the
# stale lock ceiling in #25 was set from a measured sync duration, and a duration measured under
# two other suites is not the number anyone thinks it is.
#
# Only a top-level run locks. #27 runs the suite as a subprocess, and a nested run meeting its own
# parent's lock would refuse, so every one of those checks would fail. Depth is what tells a
# nested run from a competing one, which is why #34 had to land first.
SUITE_LOCK="${SUITE_LOCK:-${TMPDIR:-/tmp}/claude-sync-suite.lock}"
SUITE_LOCK_HELD=""

# The cleanup handler is installed BEFORE the lock is taken, not after, or a run that dies in the
# gap between taking it and arming the handler leaves it standing. One cleanup, ADDED to rather
# than replaced further down: #21 shipped a defect of exactly that shape here, an exit handler
# that replaced the one removing the pull temp file, and nothing noticed because both handlers
# were individually correct.
suite_cleanup(){
  [ -n "${SUITE_WATCHDOG_PID:-}" ] && kill "$SUITE_WATCHDOG_PID" 2>/dev/null
  [ -n "${SUITE_SECTION_MARK:-}" ] && rm -f "$SUITE_SECTION_MARK"
  # Only a run that actually TOOK the lock releases it, or a run that refused would delete the
  # lock belonging to the run it just refused for.
  [ -n "${SUITE_LOCK_HELD:-}" ] && rm -rf "$SUITE_LOCK"
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}
trap suite_cleanup EXIT

# A run killed by the deadline above cannot release its lock, and deliberately nothing tries to do
# it on the run's behalf: the next run finds a recorded process that is gone and takes over saying
# so, which is the same recovery a crash needs and is therefore the path worth having work.
if [ "$SUITE_DEPTH" -eq 0 ] && [ -z "${SUITE_NO_LOCK:-}" ]; then
  # mkdir is the atomic step that decides who wins, never the reading that judged the previous
  # owner dead: two runs can reach that judgement together and act on a lock a third has since
  # taken (L157, downbeat#218, which deleted a LIVE lock doing exactly this).
  # Bounded, because an unbounded retry is a wait with no deadline wearing a loop (L110). Each
  # turn either takes the lock or removes exactly one dead lock, so a handful of turns is already
  # far more than the real contention, and anything past that is a lock path that cannot be
  # written at all rather than a lock that keeps being retaken.
  _lk_try=0
  while [ "$_lk_try" -lt 5 ]; do
    _lk_try=$((_lk_try + 1))
    if mkdir "$SUITE_LOCK" 2>/dev/null; then
      printf '%s\n' "$$" > "$SUITE_LOCK/pid"
      printf '%s\n' "$(hostname)" > "$SUITE_LOCK/host"
      printf '%s\n' "$(date +%s)" > "$SUITE_LOCK/started"
      SUITE_LOCK_HELD=1
      break
    fi
    _lk_pid="$(cat "$SUITE_LOCK/pid" 2>/dev/null || true)"
    _lk_host="$(cat "$SUITE_LOCK/host" 2>/dev/null || true)"
    _lk_started="$(cat "$SUITE_LOCK/started" 2>/dev/null || true)"
    case "$_lk_started" in ''|*[!0-9]*) _lk_started=0 ;; esac
    _lk_age=$(( $(date +%s) - _lk_started ))
    [ "$_lk_started" -eq 0 ] && _lk_age=0     # unknown counts as young, so a lock is never broken on no evidence
    # Whose lock is it? A lock taken on THIS machine is judged by whether its process is still
    # alive, and the clock is not consulted at all, or a clock jump (a correction, a wake from
    # sleep) would make a live lock look ancient and let a second run start on top of a running
    # one, which is the collision the lock exists to prevent (#29). Age is the fallback only for a
    # lock from ELSEWHERE, whose recorded process id refers to a machine that is not this one.
    if [ "$_lk_host" = "$(hostname)" ]; then
      if [ -n "$_lk_pid" ] && kill -0 "$_lk_pid" 2>/dev/null; then
        echo "test suite: another run is already going (process $_lk_pid on $_lk_host, started ${_lk_age}s ago). Refusing rather than queueing behind it: two suites competing for this machine make each other slower and make every timing either of them reports wrong. Wait for it, or run with SUITE_NO_LOCK=1 if you know it is finished." >&2
        exit 5
      fi
      echo "test suite: took over a lock whose run is gone (process $_lk_pid is not running)." >&2
    else
      if [ "$_lk_age" -lt "${SUITE_LOCK_MAX_AGE:-1800}" ]; then
        echo "test suite: another run is already going (process $_lk_pid on $_lk_host, started ${_lk_age}s ago). Refusing rather than queueing behind it. Wait for it, or run with SUITE_NO_LOCK=1 if you know it is finished." >&2
        exit 5
      fi
      # 30 minutes against a full run measured at 123 seconds, so roughly 15x the real thing. It is
      # the one threshold where being wrong LOW starts a second run on top of a live one.
      echo "test suite: took over a lock from $_lk_host that is ${_lk_age}s old, older than any run can be." >&2
    fi
    rm -rf "$SUITE_LOCK"
  done
  # Exhausting the turns is its own outcome, and a loud one. Falling through silently would run the
  # suite with no lock at all while every line above claims it is serialized, which is worse than
  # not locking because it reads as protected.
  if [ -z "$SUITE_LOCK_HELD" ]; then
    echo "test suite: could not take the lock at $SUITE_LOCK after $_lk_try attempts, and it is not held by a run this could identify. Refusing rather than running unserialized. Check that path is writable." >&2
    exit 5
  fi
fi

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expr: $2)"; fi; }

WORK="$(mktemp -d)"
# No trap here any more. It used to remove WORK and would now REPLACE suite_cleanup, silently
# leaving the deadline watchdog running after every run, which is the precise defect #21 shipped
# once already. suite_cleanup removes WORK as well, so this is one handler doing all of it.

# Redirect the shell rc for the WHOLE suite, not just the alias tests. install-autosync
# installs the claudesync alias, and the older autosync tests below call it without
# setting this, so a default of ~/.zshrc means the suite edits the real shell config of
# whoever runs it. It did exactly that, appending aliases pointing at temp dirs. A test
# must be structurally unable to touch live config, so the safe value is the default
# here and individual tests override it only to point at another throwaway file.
export SYNC_ZSHRC="$WORK/zshrc-guard"
CH="$WORK/dot-claude"          # fake ~/.claude
REPO="$WORK/repo"              # fake sync repo
mkdir -p "$CH/hooks" "$CH/skills/plan-council" "$CH/skills/wrangler" \
         "$CH/agents" "$CH/commands" "$REPO/payload"

# ---- seed a fake ~/.claude ----
echo 'echo hi' > "$CH/hooks/tdd-nudge.sh"
# Python bytecode cache next to a hook: local build cruft, tied to one Python
# version, invalidated by a timestamp that syncing scrambles. Must never travel.
mkdir -p "$CH/hooks/__pycache__"
echo 'BYTECODE' > "$CH/hooks/__pycache__/gh_issue_scan.cpython-314.pyc"
echo 'BYTECODE' > "$CH/hooks/stray.pyc"
echo 'SKILL custom' > "$CH/skills/plan-council/SKILL.md"
echo 'SKILL plugin-owned' > "$CH/skills/wrangler/SKILL.md"   # should be EXCLUDED from sync
echo 'AGENT' > "$CH/agents/plan-redteam.md"
echo 'CMD' > "$CH/commands/plannotator-last.md"
echo '# global rules v1' > "$CH/CLAUDE.md"
echo '# rtk notes' > "$CH/RTK.md"
echo '# lessons L1' > "$CH/LESSONS.md"
cat > "$CH/settings.json" <<JSON
{
  "model": "opus",
  "effortLevel": "high",
  "permissions": { "allow": ["LOCAL-ONLY"] },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$CH/hooks/tdd-nudge.sh" } ] }
    ]
  }
}
JSON

export CLAUDE_HOME="$CH" SYNC_REPO="$REPO" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1

section "== push =="
bash "$SCRIPT" push >/dev/null 2>&1
check "payload has the custom skill"        "[ -f '$REPO/payload/skills/plan-council/SKILL.md' ]"
check "payload EXCLUDES plugin skill"       "[ ! -e '$REPO/payload/skills/wrangler' ]"
check "payload has the hook script"         "[ -f '$REPO/payload/hooks/tdd-nudge.sh' ]"
check "payload EXCLUDES __pycache__ dir"    "[ ! -e '$REPO/payload/hooks/__pycache__' ]"
check "payload EXCLUDES a stray .pyc"       "[ ! -e '$REPO/payload/hooks/stray.pyc' ]"
check "payload has the agent"               "[ -f '$REPO/payload/agents/plan-redteam.md' ]"
check "payload has the command"             "[ -f '$REPO/payload/commands/plannotator-last.md' ]"
check "hooks fragment written"              "[ -f '$REPO/payload/settings.hooks.json' ]"
check "fragment path is tokenized"          "grep -q '__CLAUDE_HOME__/hooks/tdd-nudge.sh' '$REPO/payload/settings.hooks.json'"
check "fragment does NOT leak real home"    "! grep -q '$CH' '$REPO/payload/settings.hooks.json'"
check "payload has CLAUDE.md"               "[ -f '$REPO/payload/CLAUDE.md' ]"
check "payload has RTK.md"                  "[ -f '$REPO/payload/RTK.md' ]"
check "payload has LESSONS.md"              "[ -f '$REPO/payload/LESSONS.md' ]"

section "== pull into a DIFFERENT home (simulates other Mac) =="
CH2="$WORK/dot-claude-2"
mkdir -p "$CH2/skills/wrangler"
echo 'PLUGIN-LOCAL' > "$CH2/skills/wrangler/SKILL.md"   # plugin skill present on Mac 2
cat > "$CH2/settings.json" <<JSON
{ "model": "opus", "effortLevel": "high",
  "permissions": { "allow": ["MAC2-ONLY-KEEP-ME"] },
  "hooks": {} }
JSON
export CLAUDE_HOME="$CH2"
bash "$SCRIPT" pull >/dev/null 2>&1
check "skill arrived on Mac 2"              "[ -f '$CH2/skills/plan-council/SKILL.md' ]"
check "hook script arrived on Mac 2"        "[ -f '$CH2/hooks/tdd-nudge.sh' ]"
check "agent arrived on Mac 2"              "[ -f '$CH2/agents/plan-redteam.md' ]"
check "Mac 2 plugin skill NOT deleted"      "[ -f '$CH2/skills/wrangler/SKILL.md' ]"
check "hooks merged into settings"          "jq -e '.hooks.UserPromptSubmit' '$CH2/settings.json' >/dev/null"
check "hook path rewritten to Mac2 home"    "jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' '$CH2/settings.json' | grep -q '$CH2/hooks/tdd-nudge.sh'"
check "no token left in settings"           "! grep -q '__CLAUDE_HOME__' '$CH2/settings.json'"
check "Mac 2 model preserved"               "jq -e '.model==\"opus\"' '$CH2/settings.json' >/dev/null"
check "Mac 2 LOCAL permissions preserved"   "jq -e '.permissions.allow[0]==\"MAC2-ONLY-KEEP-ME\"' '$CH2/settings.json' >/dev/null"
check "CLAUDE.md arrived on Mac 2"          "[ -f '$CH2/CLAUDE.md' ]"
check "RTK.md arrived on Mac 2"             "[ -f '$CH2/RTK.md' ]"
check "CLAUDE.md content matches source"    "grep -q 'global rules v1' '$CH2/CLAUDE.md'"
check "LESSONS.md arrived on Mac 2"          "grep -q 'lessons L1' '$CH2/LESSONS.md'"

section "== install-schedule plist content (background job must find Homebrew tools) =="
PLDIR="$WORK/launchagents"; mkdir -p "$PLDIR"
SYNC_LAUNCHAGENTS="$PLDIR" SYNC_NO_LAUNCHCTL=1 bash "$SCRIPT" install-schedule >/dev/null 2>&1
PL="$PLDIR/com.claudesync.pull.plist"
check "plist written"                 "[ -f '$PL' ]"
check "plist sets a PATH for the job" "grep -q '<key>PATH</key>' '$PL'"
check "PATH includes Homebrew bin"    "grep -q '/opt/homebrew/bin' '$PL'"
check "schedule is monthly (Day key)" "grep -q '<key>Day</key>' '$PL'"

section "== sync (two-way) over a local fake remote =="
unset SYNC_NO_GIT   # this section exercises the real git round-trip
BARE="$WORK/bare.git"; git init -q --bare "$BARE"
# Mac A: has a custom skill, syncs it up
RA="$WORK/repoA"; git clone -q "$BARE" "$RA"
CA="$WORK/homeA"; mkdir -p "$CA/skills/alpha"
echo '{"model":"opus","hooks":{}}' > "$CA/settings.json"
echo 'ALPHA' > "$CA/skills/alpha/SKILL.md"
CLAUDE_HOME="$CA" SYNC_REPO="$RA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B: empty, syncs and should receive A's skill
RB="$WORK/repoB"; git clone -q "$BARE" "$RB"
CB="$WORK/homeB"; mkdir -p "$CB"
echo '{"model":"opus","permissions":{"allow":["B-LOCAL"]},"hooks":{}}' > "$CB/settings.json"
CLAUDE_HOME="$CB" SYNC_REPO="$RB" bash "$SCRIPT" sync >/dev/null 2>&1
check "sync pushed+committed from A"   "[ -n \"\$(git -C '$RA' log --oneline 2>/dev/null)\" ]"
check "B received A's skill via sync"  "[ -f '$CB/skills/alpha/SKILL.md' ]"
check "B kept its local permissions"   "jq -e '.permissions.allow[0]==\"B-LOCAL\"' '$CB/settings.json' >/dev/null"

section "== install-autosync writes a receive-timer; adds an fswatch watcher when available =="
PLDIR2="$WORK/la2"; mkdir -p "$PLDIR2"
# no fswatch -> timer only, plus a hint
FAKEFS="$WORK/fake-fswatch"
outA="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
TPL="$PLDIR2/com.claudesync.timer.plist"; WPL="$PLDIR2/com.claudesync.watch.plist"
check "timer plist written"            "[ -f '$TPL' ]"
check "timer has StartInterval"        "grep -q 'StartInterval' '$TPL'"
check "timer sets Homebrew PATH"        "grep -q '/opt/homebrew/bin' '$TPL'"
check "timer runs sync"                 "grep -q '<string>sync</string>' '$TPL'"
check "no watcher without fswatch"      "[ ! -f '$WPL' ]"
check "hints to install fswatch"        "printf '%s' \"\$outA\" | grep -qi fswatch"
# with fswatch present -> also a watcher agent that runs 'watch' and stays alive
printf '#!/usr/bin/env bash\ntrue\n' > "$FAKEFS"; chmod +x "$FAKEFS"
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "watcher plist written"          "[ -f '$WPL' ]"
check "watcher runs the watch command"  "grep -q '<string>watch</string>' '$WPL'"
check "watcher stays alive"            "grep -q 'KeepAlive' '$WPL'"
check "watcher sets Homebrew PATH"      "grep -q '/opt/homebrew/bin' '$WPL'"

section "== watch: errors without fswatch; runs a sync per event when present =="
out_nofs="$(SYNC_FSWATCH="$WORK/nope" CLAUDE_HOME="$CA" SYNC_REPO="$RA" bash "$SCRIPT" watch 2>&1)"; rcw=$?
check "watch fails without fswatch"     "[ $rcw -ne 0 ]"
check "watch error mentions fswatch"    "printf '%s' \"\$out_nofs\" | grep -qi fswatch"
# fake fswatch that emits one batch then exits; the watch loop should fire one sync
WBARE="$WORK/wbare.git"; git init -q --bare "$WBARE"
WR="$WORK/wrepo"; git clone -q "$WBARE" "$WR"
WC="$WORK/wchome"; mkdir -p "$WC/skills/zeta"; echo Z > "$WC/skills/zeta/SKILL.md"; echo '{"hooks":{}}' > "$WC/settings.json"
EMIT="$WORK/emit-fswatch"; printf '#!/usr/bin/env bash\necho 1\n' > "$EMIT"; chmod +x "$EMIT"
SYNC_FSWATCH="$EMIT" CLAUDE_HOME="$WC" SYNC_REPO="$WR" bash "$SCRIPT" watch >/dev/null 2>&1
check "watch pushed a commit on event"  "[ -n \"\$(git -C '$WR' log --oneline 2>/dev/null)\" ]"

section "== apply is idempotent (no-op sync must not rewrite settings.json -> no watch loop) =="
CI="$WORK/idem"; mkdir -p "$CI/skills/keep"; echo K > "$CI/skills/keep/SKILL.md"
echo '# rules' > "$CI/CLAUDE.md"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$CI/settings.json"
RI="$WORK/repoI"; mkdir -p "$RI"
# first pull-style apply establishes canonical form
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
before_mtime="$(stat -f %m "$CI/settings.json")"
before_cl="$(stat -f %m "$CI/CLAUDE.md")"
sleep 1
# second apply with identical payload must NOT touch settings.json or CLAUDE.md
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
after_mtime="$(stat -f %m "$CI/settings.json")"
after_cl="$(stat -f %m "$CI/CLAUDE.md")"
check "settings.json untouched on no-op sync" "[ '$before_mtime' = '$after_mtime' ]"
check "CLAUDE.md untouched on no-op sync"      "[ '$before_cl' = '$after_cl' ]"

section "== a background failure fires a desktop notification (issue #1) =="
REC="$WORK/notify.rec"
NOTIFIER="$WORK/fake-notifier"
cat > "$NOTIFIER" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC"
EOS
chmod +x "$NOTIFIER"
# a sync that hits the merge-conflict path should notify when run non-interactively.
# Build divergent histories on a shared remote so the rebase fails.
CBARE="$WORK/cbare.git"; git init -q --bare "$CBARE"
CR1="$WORK/cr1"; git clone -q "$CBARE" "$CR1"; CC1="$WORK/cc1"; mkdir -p "$CC1"
echo '{"hooks":{}}' > "$CC1/settings.json"; mkdir -p "$CC1/hooks"; echo one > "$CC1/hooks/h.sh"
CLAUDE_HOME="$CC1" SYNC_REPO="$CR1" bash "$SCRIPT" sync >/dev/null 2>&1
CR2="$WORK/cr2"; git clone -q "$CBARE" "$CR2"; CC2="$WORK/cc2"; mkdir -p "$CC2/hooks"
echo '{"hooks":{}}' > "$CC2/settings.json"
# both sides change the same tracked file differently, without pulling
echo TWO_a > "$CC1/hooks/h.sh"; CLAUDE_HOME="$CC1" SYNC_REPO="$CR1" bash "$SCRIPT" sync >/dev/null 2>&1
echo TWO_b > "$CC2/hooks/h.sh"
SYNC_NOTIFIER="$NOTIFIER" SYNC_NO_NOTIFY=0 CLAUDE_HOME="$CC2" SYNC_REPO="$CR2" bash "$SCRIPT" sync >/dev/null 2>&1
check "conflict fired a notification"  "[ -s '$REC' ]"
check "notification mentions conflict"  "grep -qi 'merge\\|conflict\\|reconcile' '$REC'"

section "== secret scan blocks sending a credential (issue #3) =="
SS="$WORK/sshome"; mkdir -p "$SS/hooks"
echo '{"hooks":{}}' > "$SS/settings.json"
echo 'export AWS_KEY=AKIAIOSFODNN7EXAMPLE' > "$SS/hooks/leak.sh"
SR="$WORK/ssrepo"; mkdir -p "$SR"
out="$(CLAUDE_HOME="$SS" SYNC_REPO="$SR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"; rc=$?
check "push aborts on detected secret"   "[ $rc -ne 0 ]"
check "message names offending file"     "printf '%s' \"\$out\" | grep -q 'leak.sh'"
# override lets it through if the user insists
SYNC_SKIP_SECRET_SCAN=1 CLAUDE_HOME="$SS" SYNC_REPO="$SR" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "override bypasses the scan"       "[ -f '$SR/payload/hooks/leak.sh' ]"
# clean content is unaffected
SS2="$WORK/sshome2"; mkdir -p "$SS2/hooks"; echo '{"hooks":{}}' > "$SS2/settings.json"; echo 'echo hello world' > "$SS2/hooks/ok.sh"
SR2="$WORK/ssrepo2"; mkdir -p "$SR2"
CLAUDE_HOME="$SS2" SYNC_REPO="$SR2" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "clean payload pushes fine"        "[ -f '$SR2/payload/hooks/ok.sh' ]"

section "== allowlist accepts a known secret by fingerprint; new ones still blocked (issue #3) =="
SA="$WORK/sahome"; mkdir -p "$SA/hooks"; echo '{"hooks":{}}' > "$SA/settings.json"
echo 'KEY=AKIAIOSFODNN7EXAMPLE' > "$SA/hooks/known.sh"
SAR="$WORK/sarepo"; mkdir -p "$SAR"
fp="$(printf '%s' 'AKIAIOSFODNN7EXAMPLE' | shasum -a 256 | cut -d' ' -f1)"
printf '%s  # accepted test key\n' "$fp" > "$SAR/.secret-allowlist"
CLAUDE_HOME="$SA" SYNC_REPO="$SAR" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "allowlisted secret passes"        "[ -f '$SAR/payload/hooks/known.sh' ]"
echo '-----BEGIN RSA PRIVATE KEY-----' > "$SA/hooks/new.sh"
out3="$(CLAUDE_HOME="$SA" SYNC_REPO="$SAR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"; rc3=$?
check "non-allowlisted secret blocks"     "[ $rc3 -ne 0 ]"
check "block names the new file"          "printf '%s' \"\$out3\" | grep -q 'new.sh'"

section "== send (watcher path) propagates a delete and never re-applies to home (issue #2) =="
SDBARE="$WORK/sdbare.git"; git init -q --bare "$SDBARE"
SDR="$WORK/sdrepo"; git clone -q "$SDBARE" "$SDR"
SDC="$WORK/sdhome"; mkdir -p "$SDC/skills/plan-council"; echo '{"hooks":{}}' > "$SDC/settings.json"
echo deep > "$SDC/skills/plan-council/.nested"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SDC" SYNC_REPO="$SDR" bash "$SCRIPT" send >/dev/null 2>&1
check "send pushed the nested add"      "[ -n \"\$(git -C '$SDR' ls-files | grep nested)\" ]"
# delete it locally and send again
rm -f "$SDC/skills/plan-council/.nested"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SDC" SYNC_REPO="$SDR" bash "$SCRIPT" send >/dev/null 2>&1
check "send removed it from the repo"    "[ -z \"\$(git -C '$SDR' ls-files | grep nested)\" ]"
check "send did NOT resurrect it locally" "[ ! -e '$SDC/skills/plan-council/.nested' ]"

section "== auto-commit is scoped to payload; uncommitted tool edits aren't swept (issue 1.1) =="
WB11="$WORK/w11bare.git"; git init -q --bare "$WB11"
WR11="$WORK/w11repo"; git clone -q "$WB11" "$WR11"
WC11="$WORK/w11home"; mkdir -p "$WC11/skills/s"; echo '{"hooks":{}}' > "$WC11/settings.json"; echo a > "$WC11/skills/s/f"
echo 'half-finished tool edit' > "$WR11/claude-sync.wip"   # simulates WIP in the repo
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$WC11" SYNC_REPO="$WR11" bash "$SCRIPT" sync >/dev/null 2>&1
check "payload change committed"        "[ -n \"\$(git -C '$WR11' ls-files | grep 'payload/skills/s/f')\" ]"
check "WIP tool file NOT committed"      "[ -z \"\$(git -C '$WR11' ls-files | grep 'claude-sync.wip')\" ]"
check "WIP still present on disk"        "[ -f '$WR11/claude-sync.wip' ]"

section "== watch: a failed sync leaves a durable log line, not just a transient notification =="
# Regression for the 2026-07-06 incident: a secret-scan false positive blocked
# the real watcher for 4 days with nothing but an (easily-missed) notification
# -- ~/.claude-sync.log itself stayed silent the whole time.
WLBARE="$WORK/wlbare.git"; git init -q --bare "$WLBARE"
WLR="$WORK/wlrepo"; git clone -q "$WLBARE" "$WLR"
WLC="$WORK/wlhome"; mkdir -p "$WLC/hooks"
echo '-----BEGIN RSA PRIVATE KEY-----' > "$WLC/hooks/leak.sh"
echo '{"hooks":{}}' > "$WLC/settings.json"
WLEMIT="$WORK/wl-emit-fswatch"; printf '#!/usr/bin/env bash\necho 1\n' > "$WLEMIT"; chmod +x "$WLEMIT"
WLNOTIFIER="$WORK/wl-fake-notifier"; printf '#!/usr/bin/env bash\ntrue\n' > "$WLNOTIFIER"; chmod +x "$WLNOTIFIER"
wl_out="$(SYNC_FSWATCH="$WLEMIT" SYNC_NOTIFIER="$WLNOTIFIER" CLAUDE_HOME="$WLC" SYNC_REPO="$WLR" bash "$SCRIPT" watch 2>&1)"
check "watch output logs the failure"     "printf '%s' \"\$wl_out\" | grep -qi 'FAILED'"
check "logged failure names the file"     "printf '%s' \"\$wl_out\" | grep -q 'leak.sh'"

section "== pull/sync auto-restarts the watch daemon when claude-sync itself changed =="
# The watch daemon (launchd KeepAlive) keeps the old script loaded until
# restarted -- a pulled edit to claude-sync itself must trigger a restart
# automatically, not rely on a manual launchctl step on each Mac (issue #5).
RSBARE="$WORK/rsbare.git"; git init -q --bare -b main "$RSBARE"
RSA="$WORK/rsrepoA"; git clone -q "$RSBARE" "$RSA"
cp "$SCRIPT" "$RSA/claude-sync"
mkdir -p "$RSA/payload/hooks"; echo '#!/bin/sh' > "$RSA/payload/hooks/dummy.sh"   # non-empty payload, or apply dies with "no payload in repo"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RSA" push -q -u origin main

RSB="$WORK/rsrepoB"; git clone -q "$RSBARE" "$RSB"
RSBHOME="$WORK/rsbhome"; mkdir -p "$RSBHOME"; echo '{"hooks":{}}' > "$RSBHOME/settings.json"
RSPLDIR="$WORK/rs-launchagents"; mkdir -p "$RSPLDIR"
touch "$RSPLDIR/com.claudesync.watch.plist"   # simulates the watcher being installed

# Mac A edits the script itself and pushes.
echo '# a harmless comment appended' >> "$RSA/claude-sync"
git -C "$RSA" add claude-sync && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "edit script" && git -C "$RSA" push -q

out_restart="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$RSBHOME" SYNC_REPO="$RSB" bash "$SCRIPT" pull 2>&1)"
check "pull restarts the watch daemon on a script change" "printf '%s' \"\$out_restart\" | grep -qi 'watch daemon'"

# First pull on a brand new Mac: the clone predates every commit (no local
# HEAD). repo_head used to capture the literal string "HEAD" here, which faked
# a diffable commit: the pull printed an empty "Received changes:" header and
# the script self-change detector diffed HEAD against itself and stayed quiet.
FPBARE="$WORK/fpbare.git"; git init -q --bare -b main "$FPBARE"
FPD="$WORK/fprepoD"; git clone -q "$FPBARE" "$FPD" 2>/dev/null   # clone while EMPTY
FPA="$WORK/fprepoA"; git clone -q "$FPBARE" "$FPA" 2>/dev/null
cp "$SCRIPT" "$FPA/claude-sync"
mkdir -p "$FPA/payload/hooks"; echo '#!/bin/sh' > "$FPA/payload/hooks/dummy.sh"
git -C "$FPA" checkout -q -b main 2>/dev/null || true
git -C "$FPA" add -A && git -C "$FPA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$FPA" push -q -u origin main
FPHOME="$WORK/fphome"; mkdir -p "$FPHOME"; echo '{"hooks":{}}' > "$FPHOME/settings.json"
out_first="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$FPHOME" SYNC_REPO="$FPD" bash "$SCRIPT" pull 2>&1)"
check "first pull announces itself as a first pull"      "printf '%s' \"\$out_first\" | grep -qi 'first pull'"
check "first pull does not print an empty changes header" "! printf '%s' \"\$out_first\" | grep -q 'Received changes from the shared repo'"
check "first pull restarts the watch daemon"              "printf '%s' \"\$out_first\" | grep -qi 'watch daemon'"

# Control: a payload-only change must NOT claim a restart happened.
mkdir -p "$RSA/payload/skills/ctrl"; echo x > "$RSA/payload/skills/ctrl/SKILL.md"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "payload only" && git -C "$RSA" push -q
out_nowatch="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$RSBHOME" SYNC_REPO="$RSB" bash "$SCRIPT" pull 2>&1)"
check "payload-only pull does not restart the daemon" "! printf '%s' \"\$out_nowatch\" | grep -qi 'watch daemon'"

# sync (two-way) must do the same self-change detection as pull, AND must still
# apply the payload afterwards. A self-update makes `sync` resume at an
# apply-only step; asserting only the restart notice would let a regression that
# skipped the copying entirely still pass. (#11)
RSC="$WORK/rsrepoC"; git clone -q "$RSBARE" "$RSC"
RSCHOME="$WORK/rschome"; mkdir -p "$RSCHOME"; echo '{"hooks":{}}' > "$RSCHOME/settings.json"
sed 's/^TOP_FILES_SEED=(CLAUDE.md/TOP_FILES_SEED=(RESUMED.md CLAUDE.md/' "$SCRIPT" > "$RSA/claude-sync"
echo '# only the NEW script version knows to sync this' > "$RSA/payload/RESUMED.md"
echo '#!/bin/sh ordinary' > "$RSA/payload/hooks/ordinary.sh"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "edit script again" && git -C "$RSA" push -q
out_sync_restart="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RSCHOME" SYNC_REPO="$RSC" bash "$SCRIPT" sync 2>&1)"
check "sync also restarts the watch daemon on a script change" "printf '%s' \"\$out_sync_restart\" | grep -qi 'watch daemon'"
check "the resumed sync still applies ordinary payload files" "[ -f '$RSCHOME/hooks/ordinary.sh' ]"
check "the resumed sync applies what only the NEW version syncs" "[ -f '$RSCHOME/RESUMED.md' ]"
check "the resumed sync still reports completion"             "printf '%s' \"\$out_sync_restart\" | grep -q 'Synced'"

# ---- status must actually REPORT a difference (#737) ----
# do_status ran `rsync -an`, which has no -v and no -i, so rsync printed nothing
# no matter what differed. The dry-run section could never report anything and
# status always read clean. A check that reports clean without checking is worse
# than no check, because it gets trusted.
STHOME="$WORK/st-home"; STREPO="$WORK/st-repo"
mkdir -p "$STHOME/hooks" "$STREPO/payload/hooks"
echo '{"hooks":{}}' > "$STHOME/settings.json"

# Identical on both sides -> status must stay quiet.
echo 'same' > "$STHOME/hooks/same.sh"
cp "$STHOME/hooks/same.sh" "$STREPO/payload/hooks/same.sh"
out_st_clean="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status is quiet when local matches payload" \
  "! printf '%s' \"\$out_st_clean\" | grep -q 'hooks: '"

# A hook that exists locally but NOT in the payload: status must name it.
echo 'brand new' > "$STHOME/hooks/added.sh"
out_st_add="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a hook missing from the payload" \
  "printf '%s' \"\$out_st_add\" | grep -q 'added.sh'"

# A file in the payload that is gone locally: --delete is in the command, so a
# working status must show the pending deletion. This is the exact case that
# proved the bug (rsync -an silent, rsync -ain printed '*deleting').
echo 'stale' > "$STREPO/payload/hooks/removed.sh"
out_st_del="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a payload file deleted locally" \
  "printf '%s' \"\$out_st_del\" | grep -q 'removed.sh'"

# An edit to an existing hook with the SAME byte count. -a quick-checks on size
# plus mtime, so without -c this edit is invisible even to an itemized rsync.
printf 'aaaa\n' > "$STHOME/hooks/edit.sh"
printf 'aaaa\n' > "$STREPO/payload/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh" "$STREPO/payload/hooks/edit.sh"
printf 'bbbb\n' > "$STHOME/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh"
out_st_edit="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a same-size same-mtime edit" \
  "printf '%s' \"\$out_st_edit\" | grep -q 'edit.sh'"

# status must report what a push would ACTUALLY do, so it has to honor the same
# exclude set as stage_local_to_payload. Some skills are git clones carrying
# their own .git, and a status that reports those as pending changes is noise
# describing work that will never happen. (#737)
mkdir -p "$STHOME/skills/cloned/.git/hooks"
echo 'ref: refs/heads/main' > "$STHOME/skills/cloned/.git/HEAD"
echo 'SKILL' > "$STHOME/skills/cloned/SKILL.md"
echo 'junk' > "$STHOME/skills/cloned/.DS_Store"
out_st_ex="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status ignores nested .git the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.git/'"
check "status ignores .DS_Store the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.DS_Store'"
check "status still reports the real skill file next to them" \
  "printf '%s' \"\$out_st_ex\" | grep -q 'SKILL.md'"

# A plugin-managed skill is excluded from the sync, so status must not offer it.
mkdir -p "$STHOME/skills/wrangler"
echo 'PLUGIN' > "$STHOME/skills/wrangler/SKILL.md"
out_st_plugin="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status ignores plugin-managed skills the way a push does" \
  "! printf '%s' \"\$out_st_plugin\" | grep -q 'wrangler'"

section "== pull reports WHAT was received, so it's clear the sync worked =="
# A pull used to print only a generic success line; the /sync-config skill even
# claimed the script "prints which files were updated" when it never did. The
# summary must name each received file with what happened to it, and a pull
# that received nothing must say so instead of printing an empty summary.
SUBARE="$WORK/subare.git"; git init -q --bare "$SUBARE"
SUA="$WORK/surepoA"; git clone -q "$SUBARE" "$SUA"
SUAH="$WORK/suhomeA"; mkdir -p "$SUAH/hooks"
echo '{"hooks":{}}' > "$SUAH/settings.json"
echo one > "$SUAH/hooks/mod-me.sh"
echo bye > "$SUAH/hooks/del-me.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SUAH" SYNC_REPO="$SUA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B takes a baseline pull first
SUB="$WORK/surepoB"; git clone -q "$SUBARE" "$SUB"
SUBH="$WORK/suhomeB"; mkdir -p "$SUBH"; echo '{"hooks":{}}' > "$SUBH/settings.json"
CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull >/dev/null 2>&1
# Mac A then modifies, adds, and deletes a hook and syncs up
echo two > "$SUAH/hooks/mod-me.sh"
echo new > "$SUAH/hooks/add-me.sh"
rm -f "$SUAH/hooks/del-me.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SUAH" SYNC_REPO="$SUA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B's next pull must say exactly what it received
out_sum="$(CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull 2>&1)"
check "pull names the modified file"      "printf '%s' \"\$out_sum\" | grep -q 'updated .*hooks/mod-me.sh'"
check "pull names the added file"         "printf '%s' \"\$out_sum\" | grep -q 'added .*hooks/add-me.sh'"
check "pull names the removed file"       "printf '%s' \"\$out_sum\" | grep -q 'removed .*hooks/del-me.sh'"
check "summary strips the payload/ prefix" "! printf '%s' \"\$out_sum\" | grep -q 'payload/hooks'"
# A pull with nothing new must say so, and must not print a change summary
out_noop="$(CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull 2>&1)"
check "no-change pull says up to date"     "printf '%s' \"\$out_noop\" | grep -qi 'up to date'"
check "no-change pull has no change list"  "! printf '%s' \"\$out_noop\" | grep -q 'Received'"

section "== a pull that updates claude-sync itself applies the NEW logic, same pull (#6) =="
# The running process loaded the OLD script at start, so a pull that updates
# claude-sync kept applying with the old code: anything the new version added to
# the synced set was skipped on the very pull that delivered it, and only landed
# on the NEXT pull. That is how CLAUDE.md arrived importing a LESSONS.md that was
# never copied. The pull must hand off to the freshly pulled copy before applying.
SUBARE2="$WORK/subare2.git"; git init -q --bare -b main "$SUBARE2"
# Mac A seeds the repo with the CURRENT (old) script, then upgrades it to a
# version that syncs one more top-level file, and adds that file to the payload.
UPA="$WORK/uprepoA"; git clone -q "$SUBARE2" "$UPA"
cp "$SCRIPT" "$UPA/claude-sync"
mkdir -p "$UPA/payload/hooks"; echo '#!/bin/sh' > "$UPA/payload/hooks/dummy.sh"
git -C "$UPA" checkout -q -b main 2>/dev/null || true
git -C "$UPA" add -A && git -C "$UPA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$UPA" push -q -u origin main
# Mac B clones at the OLD script and runs THAT copy, exactly as the real Mac does.
UPB="$WORK/uprepoB"; git clone -q "$SUBARE2" "$UPB"
UPBH="$WORK/uphomeB"; mkdir -p "$UPBH"; echo '{"hooks":{}}' > "$UPBH/settings.json"
CLAUDE_HOME="$UPBH" SYNC_REPO="$UPB" bash "$UPB/claude-sync" pull >/dev/null 2>&1
# Mac A: new script version teaches the sync about NOTES.md, and ships NOTES.md.
sed 's/^TOP_FILES_SEED=(CLAUDE.md/TOP_FILES_SEED=(NOTES.md CLAUDE.md/' "$SCRIPT" > "$UPA/claude-sync"
echo '# notes from the new version' > "$UPA/payload/NOTES.md"
git -C "$UPA" add -A && git -C "$UPA" -c user.name=t -c user.email=t@e commit -q -m "sync NOTES.md too" && git -C "$UPA" push -q
check "the new version really does sync NOTES.md" "grep -q 'TOP_FILES_SEED=(NOTES.md' '$UPA/claude-sync'"
out_up="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UPBH" SYNC_REPO="$UPB" bash "$UPB/claude-sync" pull 2>&1)"
check "file added by the new script version lands on the SAME pull" "[ -f '$UPBH/NOTES.md' ]"
check "that file has the right content"        "grep -q 'notes from the new version' '$UPBH/NOTES.md' 2>/dev/null"
check "the self-updating pull still reports the change" "printf '%s' \"\$out_up\" | grep -q 'NOTES.md'"
check "the self-updating pull still succeeds"  "printf '%s' \"\$out_up\" | grep -q 'Pulled shared config'"
# and it must not loop: exactly one hand-off, so one daemon-restart notice
restarts="$(printf '%s\n' "$out_up" | grep -ci 'watch daemon' || true)"
check "hand-off happens once, no re-exec loop"  "[ \"\$restarts\" -le 1 ]"

section "== a broken pulled script must not be handed control, and must not restart the daemon (#10) =="
# A pull now hands off to the freshly pulled copy of claude-sync so the apply runs
# current logic. That makes a syntactically broken script pushed from one Mac able
# to break pulls on the other, which the old behavior would have survived. Worse,
# restarting the watch daemon into a broken script leaves it crash-looping. So:
# validate first, warn loudly, and degrade to the copy already running.
BKBARE="$WORK/bkbare.git"; git init -q --bare -b main "$BKBARE"
BKA="$WORK/bkrepoA"; git clone -q "$BKBARE" "$BKA" 2>/dev/null
cp "$SCRIPT" "$BKA/claude-sync"
mkdir -p "$BKA/payload/hooks"; echo '#!/bin/sh' > "$BKA/payload/hooks/base.sh"
git -C "$BKA" checkout -q -b main 2>/dev/null || true
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$BKA" push -q -u origin main
BKB="$WORK/bkrepoB"; git clone -q "$BKBARE" "$BKB" 2>/dev/null
BKBH="$WORK/bkhomeB"; mkdir -p "$BKBH"; echo '{"hooks":{}}' > "$BKBH/settings.json"
BKPL="$WORK/bk-launchagents"; mkdir -p "$BKPL"; touch "$BKPL/com.claudesync.watch.plist"
CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull >/dev/null 2>&1
# Mac A pushes a script with a syntax error, alongside a normal payload change.
# The error goes EARLY in the file, which is the case that actually hurts: bash
# executes a script incrementally, so a trailing error runs the whole pull first
# and only then complains, while an early one aborts before anything is applied.
awk 'NR==26{print "if [ ; then"} {print}' "$SCRIPT" > "$BKA/claude-sync"
echo '#!/bin/sh later' > "$BKA/payload/hooks/later.sh"
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m "break the script" && git -C "$BKA" push -q
check "the pushed script really is broken" "! bash -n '$BKA/claude-sync' 2>/dev/null"
if out_bk="$(SYNC_LAUNCHAGENTS="$BKPL" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull 2>&1)"; then rc_bk=0; else rc_bk=$?; fi
check "the pull still succeeds on a broken pulled script" "[ \"\$rc_bk\" -eq 0 ]"
check "it still applies the payload with the old logic"   "[ -f '$BKBH/hooks/later.sh' ]"
# grep for OUR wording, not 'syntax': bash prints its own syntax-error line, so a
# looser pattern would pass with no guard implemented at all.
check "it warns that the pulled script was rejected"      "printf '%s' \"\$out_bk\" | grep -q 'kept the copy already running'"
check "it does NOT restart the daemon into a broken script" "! printf '%s' \"\$out_bk\" | grep -qi 'restart'"
# The broken script is now the copy sitting in this clone, so the NEXT run
# executes it and cannot help itself. The guard protects the pull that delivers
# the break and keeps the daemon off it; recovering afterwards needs a plain git
# pull, which is why the warning has to name that command.
check "the warning names the plain git recovery command" "printf '%s' \"\$out_bk\" | grep -q 'git -C'"
if bash "$BKB/claude-sync" pull >/dev/null 2>&1; then rc_stuck=0; else rc_stuck=$?; fi
check "running the landed broken script fails (documented limit)" "[ \"\$rc_stuck\" -ne 0 ]"
# Control: after the other Mac fixes it, a plain git pull restores a working tool.
cp "$SCRIPT" "$BKA/claude-sync"
echo '#!/bin/sh fixed' > "$BKA/payload/hooks/fixed.sh"
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m "fix the script" && git -C "$BKA" push -q
git -C "$BKB" pull -q --ff-only
out_bk2="$(SYNC_LAUNCHAGENTS="$BKPL" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull 2>&1)"
check "a recovered script runs and applies again"       "[ -f '$BKBH/hooks/fixed.sh' ]"
check "and no longer warns about the pulled copy"       "! printf '%s' \"\$out_bk2\" | grep -q 'kept the copy already running'"

section "== pull fails loudly when CLAUDE.md references a rules file that isn't here (#7) =="
# CLAUDE.md pulls in extra rule files with an @import. When the imported file is
# missing, Claude Code loads nothing from it and says nothing, so an entire rules
# file goes silently absent. The pull must refuse to report success in that state.
IMH="$WORK/imp-home"; IMR="$WORK/imp-repo"
mkdir -p "$IMH" "$IMR/payload/hooks"
echo '{"hooks":{}}' > "$IMH/settings.json"
echo 'x' > "$IMR/payload/hooks/h.sh"
printf '@GONE.md\n\n# rules\n' > "$IMR/payload/CLAUDE.md"
if out_imp="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull 2>&1)"; then rc_imp=0; else rc_imp=$?; fi
check "pull exits nonzero on a dangling rules import" "[ \"\$rc_imp\" -ne 0 ]"
check "the error names the missing file"             "printf '%s' \"\$out_imp\" | grep -q 'GONE.md'"
check "it does not claim the pull succeeded"         "! printf '%s' \"\$out_imp\" | grep -q 'Pulled shared config'"
# Control: an import naming a file the sync actually carries must pull clean.
printf '@RTK.md\n\n# rules\n' > "$IMR/payload/CLAUDE.md"
printf '# rtk\n' > "$IMR/payload/RTK.md"
if out_imp2="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull 2>&1)"; then rc_imp2=0; else rc_imp2=$?; fi
check "pull succeeds when the import resolves"       "[ \"\$rc_imp2\" -eq 0 ]"
check "the imported file landed"                     "[ -f '$IMH/RTK.md' ]"
# An absolute or ~ path outside the synced set must not be treated as missing.
printf '@~/.some-external-thing-that-does-exist\n' > "$IMR/payload/CLAUDE.md"
touch "$HOME/.some-external-thing-that-does-exist" 2>/dev/null || true
if SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull >/dev/null 2>&1; then rc_imp3=0; else rc_imp3=$?; fi
check "a resolvable ~ import does not fail the pull"  "[ \"\$rc_imp3\" -eq 0 ]"
rm -f "$HOME/.some-external-thing-that-does-exist"

section "== the pull summary describes what was WRITTEN here, not what the repo changed (#8) =="
# The summary was built from the shared repo's commit range, so it could disagree
# with reality in both directions: it announced "added LESSONS.md" when that file
# was never written, then said "Already up to date" on the pull that finally wrote
# it. Both readings were the opposite of the truth, which is how a missing rules
# file went unnoticed. Report the actual local writes.
WRB="$WORK/wrbare.git"; git init -q --bare -b main "$WRB"
WRA="$WORK/wrrepoA"; git clone -q "$WRB" "$WRA"
WRAH="$WORK/wrhomeA"; mkdir -p "$WRAH/hooks"; echo '{"hooks":{}}' > "$WRAH/settings.json"
echo 'keep me' > "$WRAH/hooks/keep.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$WRAH" SYNC_REPO="$WRA" bash "$SCRIPT" sync >/dev/null 2>&1
WRBR="$WORK/wrrepoB"; git clone -q "$WRB" "$WRBR"
WRBH="$WORK/wrhomeB"; mkdir -p "$WRBH"; echo '{"hooks":{}}' > "$WRBH/settings.json"
CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull >/dev/null 2>&1
check "baseline pull delivered the hook"     "[ -f '$WRBH/hooks/keep.sh' ]"
# Now the exact failure mode: the repo has nothing new, but a file IS missing
# locally, so this pull really does write one. It must say so, not "up to date".
rm -f "$WRBH/hooks/keep.sh"
out_wr="$(CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull 2>&1)"
check "a pull that writes a file names it"        "printf '%s' \"\$out_wr\" | grep -q 'keep.sh'"
check "it does NOT claim to be up to date"        "! printf '%s' \"\$out_wr\" | grep -qi 'up to date'"
check "and the file is back"                      "[ -f '$WRBH/hooks/keep.sh' ]"
# A pull that genuinely writes nothing still has to say exactly that.
out_wr2="$(CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull 2>&1)"
check "a pull that writes nothing says up to date" "printf '%s' \"\$out_wr2\" | grep -qi 'up to date'"
check "and lists no files"                         "! printf '%s' \"\$out_wr2\" | grep -q 'keep.sh'"

section "== a newly referenced rules file syncs with no script edit (#9) =="
# TOP_FILES was a hand-maintained list that had to mirror the @imports at the top
# of CLAUDE.md. Keeping the two in step was manual, and forgetting it is what made
# CLAUDE.md arrive referencing a LESSONS.md nobody had told the sync about. The
# list is now derived from the imports, following them through more than one hop.
DVH="$WORK/dv-home"; DVR="$WORK/dv-repo"
mkdir -p "$DVH/hooks" "$DVR/payload"
echo '{"hooks":{}}' > "$DVH/settings.json"
echo 'h' > "$DVH/hooks/h.sh"
printf '@EXTRA.md\n\n# root rules\n' > "$DVH/CLAUDE.md"
printf '@DEEP.md\n\n# extra rules\n' > "$DVH/EXTRA.md"     # a rules file that itself imports one
printf '# deep rules\n' > "$DVH/DEEP.md"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" push >/dev/null 2>&1
check "push carries a newly referenced rules file"  "[ -f '$DVR/payload/EXTRA.md' ]"
check "push follows a reference two hops deep"      "[ -f '$DVR/payload/DEEP.md' ]"
# and they must arrive on the other Mac
DVH2="$WORK/dv-home2"; mkdir -p "$DVH2"; echo '{"hooks":{}}' > "$DVH2/settings.json"
if out_dv="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH2" SYNC_REPO="$DVR" bash "$SCRIPT" pull 2>&1)"; then rc_dv=0; else rc_dv=$?; fi
check "pull delivers the referenced rules file"     "[ -f '$DVH2/EXTRA.md' ]"
check "pull delivers the two-hop rules file"        "[ -f '$DVH2/DEEP.md' ]"
check "the pull succeeds (no dangling reference)"   "[ \"\$rc_dv\" -eq 0 ]"
check "the still-listed defaults are unaffected"    "[ -f '$DVH2/CLAUDE.md' ]"
# status must describe the derived set too, not just the old hard-coded names
printf '# root rules CHANGED\n@EXTRA.md\n' > "$DVH/CLAUDE.md"
printf '# extra rules CHANGED\n' > "$DVH/EXTRA.md"
out_dvst="$(SYNC_NO_GIT=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" status 2>&1)"
check "status reports a referenced rules file differing" "printf '%s' \"\$out_dvst\" | grep -q 'EXTRA.md'"
# a nested reference that resolves nowhere must still fail loudly, not pass quietly
printf '@NOWHERE.md\n' > "$DVH/EXTRA.md"
if SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" push >/dev/null 2>&1; then rc_dv2=0; else rc_dv2=$?; fi
if out_dv3="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH2" SYNC_REPO="$DVR" bash "$SCRIPT" pull 2>&1)"; then rc_dv3=0; else rc_dv3=$?; fi
check "a dangling NESTED reference fails the pull"  "[ \"\$rc_dv3\" -ne 0 ]"
check "and the error names the missing file"        "printf '%s' \"\$out_dv3\" | grep -q 'NOWHERE.md'"

section "== a same-size edit still reaches the other Mac (rsync quick-check data loss) =="
# rsync's default quick check compares size plus mtime at one-second granularity.
# A same-size edit made in the same second as the last sync (a one character fix
# in a hook, a swapped word in CLAUDE.md) was therefore skipped: rsync updated the
# mode bit and left the OLD content, so the edit silently never left this Mac.
# Only -c (checksum) catches it. This is a data-loss path, not a cosmetic one.
QSRC="$WORK/qs-home"; QREPO="$WORK/qs-repo"
mkdir -p "$QSRC/hooks" "$QREPO/payload/hooks"
echo '{"hooks":{}}' > "$QSRC/settings.json"
printf 'aaaa\n' > "$QSRC/hooks/tiny.sh"
printf 'bbbb\n' > "$QREPO/payload/hooks/tiny.sh"          # same byte count, different content
chmod 755 "$QSRC/hooks/tiny.sh"; chmod 644 "$QREPO/payload/hooks/tiny.sh"
touch -t 202601010000 "$QSRC/hooks/tiny.sh" "$QREPO/payload/hooks/tiny.sh"   # identical mtime
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" push >/dev/null 2>&1
check "push propagates a same-size same-mtime edit" "grep -q 'aaaa' '$QREPO/payload/hooks/tiny.sh'"
# and the same hazard on the receiving side
printf 'cccc\n' > "$QREPO/payload/hooks/tiny.sh"
chmod 644 "$QREPO/payload/hooks/tiny.sh"
touch -t 202601010000 "$QSRC/hooks/tiny.sh" "$QREPO/payload/hooks/tiny.sh"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "pull applies a same-size same-mtime edit"     "grep -q 'cccc' '$QSRC/hooks/tiny.sh'"

section "== the apply cleans up its own scratch file (no temp litter per run) =="
# The apply records what it wrote to a temp file so the summary can report real
# writes. That record has to be removed on the way out, including when the run
# ends early via die(), or every pull and sync leaves a file in the temp dir.
TMPD="$WORK/tmpdir"; mkdir -p "$TMPD"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "a clean pull leaves no temp file behind" "[ -z \"\$(ls -A '$TMPD' 2>/dev/null)\" ]"
# same on the failure path: a pull that dies must not litter either
printf '@NOPE.md\n' > "$QREPO/payload/CLAUDE.md"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "a failed pull leaves no temp file behind"  "[ -z \"\$(ls -A '$TMPD' 2>/dev/null)\" ]"
rm -f "$QREPO/payload/CLAUDE.md" "$QSRC/CLAUDE.md"

section "== send must not publish over changes this Mac has never applied =="
# The 2026-07-27 incident, reproduced. Mirroring ~/.claude -> payload is
# unconditional and uses --delete, so whenever the repo holds content this Mac has
# not applied yet (the state right after ANY merge), a watcher firing publishes an
# older snapshot and silently reverts the other Mac's work. It cost a real lesson
# entry: the repo was 20 seconds ahead of ~/.claude and the watcher wiped it.
UABARE="$WORK/uabare.git"; git init -q --bare -b main "$UABARE"
UAA="$WORK/uarepoA"; git clone -q "$UABARE" "$UAA" 2>/dev/null
UAAH="$WORK/uahomeA"; mkdir -p "$UAAH/hooks"; echo '{"hooks":{}}' > "$UAAH/settings.json"
echo one > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
UAB="$WORK/uarepoB"; git clone -q "$UABARE" "$UAB" 2>/dev/null
UABH="$WORK/uahomeB"; mkdir -p "$UABH"; echo '{"hooks":{}}' > "$UABH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts in sync with A"            "grep -q one '$UABH/hooks/shared.sh'"
# A makes a change and sends it up.
echo two > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
# B merges it at the git level but never applies it: repo ahead of ~/.claude.
git -C "$UAB" pull -q --ff-only
check "B's repo now holds A's change"      "grep -q two '$UAB/payload/hooks/shared.sh'"
check "B's home does NOT have it yet"      "grep -q one '$UABH/hooks/shared.sh'"
commits_before="$(git -C "$UAB" rev-list --count HEAD)"
out_ua="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" send 2>&1)"
check "send does NOT revert A's change"    "grep -q two '$UAB/payload/hooks/shared.sh'"
check "send makes no commit in that state" "[ \"\$(git -C '$UAB' rev-list --count HEAD)\" = \"\$commits_before\" ]"
check "send says why it skipped"           "printf '%s' \"\$out_ua\" | grep -qi 'not applied'"
# Control: with both sides agreed, a genuine local edit still sends normally.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B received A's change on pull"      "grep -q two '$UABH/hooks/shared.sh'"
echo 'B-only' > "$UABH/hooks/b-only.sh"
out_ua2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" send 2>&1)"
check "a normal send still works"          "[ -f '$UAB/payload/hooks/b-only.sh' ]"
check "and does not warn"                  "! printf '%s' \"\$out_ua2\" | grep -qi 'not applied'"
# sync in that same state must RECEIVE first, then still send the local edit.
echo three > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$UAB" pull -q --ff-only
echo 'B-second' > "$UABH/hooks/b-two.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" sync >/dev/null 2>&1
check "sync receives before sending"       "grep -q three '$UABH/hooks/shared.sh'"
check "sync keeps A's change in the repo"  "grep -q three '$UAB/payload/hooks/shared.sh'"
check "sync still sends B's own edit"      "[ -f '$UAB/payload/hooks/b-two.sh' ]"

section "== when both Macs changed the same file, keep the local copy and say so =="
# Holding back the paths this Mac is stale on stops it reverting the other Mac,
# but on a REAL conflict (both sides edited the same file) it just moved the loss:
# the apply overwrote this Mac's edit with the other Mac's and said nothing. Trading
# one silent loss for the other is not a fix. Keep the local version beside it.
CFBARE="$WORK/cfbare.git"; git init -q --bare -b main "$CFBARE"
CFA="$WORK/cfrepoA"; git clone -q "$CFBARE" "$CFA" 2>/dev/null
CFAH="$WORK/cfhomeA"; mkdir -p "$CFAH/hooks"; echo '{"hooks":{}}' > "$CFAH/settings.json"
echo original > "$CFAH/hooks/x.sh"
echo untouched > "$CFAH/hooks/y.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFAH" SYNC_REPO="$CFA" bash "$SCRIPT" sync >/dev/null 2>&1
CFB="$WORK/cfrepoB"; git clone -q "$CFBARE" "$CFB" 2>/dev/null
CFBH="$WORK/cfhomeB"; mkdir -p "$CFBH"; echo '{"hooks":{}}' > "$CFBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" pull >/dev/null 2>&1
# A changes both files and sends them up; B merges at the git level only.
echo MAC-A-VERSION > "$CFAH/hooks/x.sh"
echo A-CHANGED-THIS-TOO > "$CFAH/hooks/y.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFAH" SYNC_REPO="$CFA" bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$CFB" pull -q --ff-only
# B edits x.sh (a real conflict) but leaves y.sh alone (not a conflict).
echo MAC-B-MY-OWN-EDIT > "$CFBH/hooks/x.sh"
out_cf="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" sync 2>&1)"
check "the other Mac's version is applied"        "grep -q MAC-A-VERSION '$CFBH/hooks/x.sh'"
check "the local edit is kept beside it"          "grep -rq MAC-B-MY-OWN-EDIT '$CFBH/hooks/'"
check "the kept copy is named as a conflict"      "ls '$CFBH/hooks/' | grep -q 'x.sh.conflict'"
check "and the conflict is reported, not silent"  "printf '%s' \"\$out_cf\" | grep -qi 'both Macs changed'"
check "the report names the file"                 "printf '%s' \"\$out_cf\" | grep -q 'hooks/x.sh'"
# No conflict on a file this Mac never touched: no stray copy, no noise.
check "an untouched file gets the new version"    "grep -q A-CHANGED-THIS-TOO '$CFBH/hooks/y.sh'"
check "and leaves no conflict copy behind"        "! ls '$CFBH/hooks/' | grep -q 'y.sh.conflict'"
# Conflict copies are local evidence; they must never travel to the other Mac.
check "conflict copies are not sent up"           "! ls '$CFB/payload/hooks/' | grep -q conflict"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" sync >/dev/null 2>&1
check "and still are not sent on a later sync"    "! ls '$CFB/payload/hooks/' | grep -q conflict"

section "== a send must not leave this Mac wedged against its own commit =="
# .last-applied is written only by the apply step, and send deliberately has no
# apply step. So a send moved HEAD forward and left .last-applied pointing at the
# commit before it, after which the "behind the other Mac" guard fired on this
# Mac's OWN commit and every later send was silently dropped. One Mac here, no
# other Mac involved: the second edit must still reach the repo.
SWBARE="$WORK/swbare.git"; git init -q --bare -b main "$SWBARE"
SWA="$WORK/swrepoA"; git clone -q "$SWBARE" "$SWA" 2>/dev/null
SWAH="$WORK/swhomeA"; mkdir -p "$SWAH/hooks"; echo '{"hooks":{}}' > "$SWAH/settings.json"
echo base > "$SWAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" sync >/dev/null 2>&1
echo 'first' > "$SWAH/hooks/sw-one.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send >/dev/null 2>&1
check "the first send lands"                   "[ -f '$SWA/payload/hooks/sw-one.sh' ]"
check "a sent commit counts as applied here"   "[ \"\$(cat '$SWA/.last-applied')\" = \"\$(git -C '$SWA' rev-parse HEAD)\" ]"
echo 'second' > "$SWAH/hooks/sw-two.sh"
out_sw="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send 2>&1)"
check "a second send still lands"              "[ -f '$SWA/payload/hooks/sw-two.sh' ]"
check "and is never called behind itself"      "! printf '%s' \"\$out_sw\" | grep -qi 'not applied'"
# The guard this replaces is load-bearing, so prove it still fires: genuinely
# behind the OTHER Mac must still skip, keep the other Mac's content, and say why.
SWB="$WORK/swrepoB"; git clone -q "$SWBARE" "$SWB" 2>/dev/null
SWBH="$WORK/swhomeB"; mkdir -p "$SWBH"; echo '{"hooks":{}}' > "$SWBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWBH" SYNC_REPO="$SWB" bash "$SCRIPT" pull >/dev/null 2>&1
echo 'A-MOVED-ON' > "$SWAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send >/dev/null 2>&1
git -C "$SWB" pull -q --ff-only
echo 'B-local' > "$SWBH/hooks/sw-b.sh"
out_swb="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWBH" SYNC_REPO="$SWB" bash "$SCRIPT" send 2>&1)"
check "still skips when truly behind"          "[ ! -f '$SWB/payload/hooks/sw-b.sh' ]"
check "still keeps the other Mac's change"     "grep -q A-MOVED-ON '$SWB/payload/hooks/shared.sh'"
check "still says why it skipped"              "printf '%s' \"\$out_swb\" | grep -qi 'not applied'"

section "== a pull must not revert a local edit the repo never changed (2026-07-28) =="
# The incident: the watcher was down, a skill script was edited locally, and a
# pull driven by UNRELATED commits mirrored the repo's older copy straight over
# the edit. No conflict copy (preserve_local_conflicts only owns paths the repo
# changed), no warning, original mtime restored, so the loss was invisible. A
# file the repo has not touched since this Mac last applied, whose local copy
# differs, is simply AHEAD: the pull must leave it alone and say so, and the
# next send must publish it.
LEBARE="$WORK/lebare.git"; git init -q --bare -b main "$LEBARE"
LEA="$WORK/lerepoA"; git clone -q "$LEBARE" "$LEA" 2>/dev/null
LEAH="$WORK/lehomeA"; mkdir -p "$LEAH/hooks" "$LEAH/skills/reel"
echo '{"hooks":{}}' > "$LEAH/settings.json"
echo 'orig-script' > "$LEAH/skills/reel/push.py"
echo 'other-v1' > "$LEAH/hooks/other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
LEB="$WORK/lerepoB"; git clone -q "$LEBARE" "$LEB" 2>/dev/null
LEBH="$WORK/lehomeB"; mkdir -p "$LEBH"; echo '{"hooks":{}}' > "$LEBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts with the original script"   "grep -q orig-script '$LEBH/skills/reel/push.py'"
# B fixes the script locally; nothing sends it (the watcher is down).
echo 'MY-LOCAL-FIX' > "$LEBH/skills/reel/push.py"
# A changes an UNRELATED file and sends it up; B pulls.
echo 'other-v2' > "$LEAH/hooks/other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
out_le="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" pull 2>&1)"
check "the unrelated change still arrives"  "grep -q other-v2 '$LEBH/hooks/other.sh'"
check "the local edit is NOT reverted"      "grep -q MY-LOCAL-FIX '$LEBH/skills/reel/push.py'"
check "and the pull says it kept the edit"  "printf '%s' \"\$out_le\" | grep -qi 'kept'"
# The kept edit still reaches the repo on the next send, and the other Mac.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" send >/dev/null 2>&1
check "the next send publishes the edit"    "grep -q MY-LOCAL-FIX '$LEB/payload/skills/reel/push.py'"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
check "the edit round-trips to the other Mac" "grep -q MY-LOCAL-FIX '$LEAH/skills/reel/push.py'"

section "== a pull must not revert an unsent edit to a top-level rules file =="
# The keep-local-edits protection covered the mirrored subtrees only. Top-level
# rules files (CLAUDE.md, LESSONS.md, RTK.md and anything they import) take a
# separate plain-copy path that had no such guard, so a pull still mirrored the
# repo's older copy straight over an entry added here and never sent, leaving a
# .syncbak as the only evidence. Reproduced live on 2026-07-28: a pull run
# seconds after another session appended a lesson deleted it. These files carry
# the rules every session loads, which makes a silent revert here the most
# expensive one in the sync.
TFBARE="$WORK/tfbare.git"; git init -q --bare -b main "$TFBARE"
TFA="$WORK/tfrepoA"; git clone -q "$TFBARE" "$TFA" 2>/dev/null
TFAH="$WORK/tfhomeA"; mkdir -p "$TFAH/hooks"; echo '{"hooks":{}}' > "$TFAH/settings.json"
printf '# rules\n' > "$TFAH/CLAUDE.md"
printf -- '- L1. first lesson\n' > "$TFAH/LESSONS.md"
echo 'other-v1' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
TFB="$WORK/tfrepoB"; git clone -q "$TFBARE" "$TFB" 2>/dev/null
TFBH="$WORK/tfhomeB"; mkdir -p "$TFBH"; echo '{"hooks":{}}' > "$TFBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts with the shared lessons file" "grep -q 'first lesson' '$TFBH/LESSONS.md'"
# B appends a lesson. Nothing sends it (the watcher is down, or it is seconds old).
printf -- '- L2. MY-NEW-LESSON\n' >> "$TFBH/LESSONS.md"
# A changes something unrelated and publishes, so B's next pull has real work.
echo 'other-v2' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
out_tf="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "the unrelated change still arrives"      "grep -q other-v2 '$TFBH/hooks/tf-other.sh'"
check "the unsent lesson is NOT reverted"       "grep -q MY-NEW-LESSON '$TFBH/LESSONS.md'"
check "the earlier lesson is still there too"   "grep -q 'first lesson' '$TFBH/LESSONS.md'"
check "and the pull says it kept the edit"      "printf '%s' \"\$out_tf\" | grep -qi 'kept'"
check "and does not report overwriting it"      "! printf '%s' \"\$out_tf\" | grep -q 'updated .*LESSONS.md'"
# It must reach the repo on the next send, and the other Mac after that.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" send >/dev/null 2>&1
check "the next send publishes the lesson"      "grep -q MY-NEW-LESSON '$TFB/payload/LESSONS.md'"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
check "the lesson round-trips to the other Mac" "grep -q MY-NEW-LESSON '$TFAH/LESSONS.md'"
# Control: when the repo HAS changed the file since this Mac last applied, the
# other Mac's work must still arrive. It must not be possible to ignore the other
# Mac by editing locally.
# Superseded by #14: this used to assert that the incoming copy WON and the local
# copy was set aside, which is the loss #14 exists to stop. Both Macs appending a
# different entry is a merge, not a conflict, so both entries must now end up in
# the one file that sessions actually load.
printf -- '- L3. FROM-MAC-A\n' >> "$TFAH/LESSONS.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
printf -- '- L4. FROM-MAC-B-SAME-TIME\n' >> "$TFBH/LESSONS.md"
out_tfc="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "the other Mac's entry arrives"           "grep -q FROM-MAC-A '$TFBH/LESSONS.md'"
check "this Mac's entry is still in the file"   "grep -q FROM-MAC-B-SAME-TIME '$TFBH/LESSONS.md'"
check "so no conflict copy was needed"          "! ls '$TFBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "and the merge is reported"               "printf '%s' \"\$out_tfc\" | grep -qi 'MERGED'"

section "== a commit made outside send/sync must not wedge the watcher (#12) =="
# 2026-07-28: a session edited claude-sync itself and committed with plain git.
# .last-applied is written only by the apply step and by a clean send, so HEAD
# moved and the marker did not. The guard compared those two SHAs and read this
# Mac as behind ITS OWN commit, so every later edit was dropped with a "pull
# first, this Mac is behind" notification until a manual pull happened to reset
# the marker. A commit whose content is already here is not news arriving from
# the other Mac, whatever the SHAs say.
HCBARE="$WORK/hcbare.git"; git init -q --bare -b main "$HCBARE"
HCR="$WORK/hcrepo"; git clone -q "$HCBARE" "$HCR" 2>/dev/null
HCH="$WORK/hchome"; mkdir -p "$HCH/hooks"; echo '{"hooks":{}}' > "$HCH/settings.json"
echo base > "$HCH/hooks/hc-base.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" sync >/dev/null 2>&1
check "the hand-commit case starts in sync" \
  "[ \"\$(cat '$HCR/.last-applied')\" = \"\$(git -C '$HCR' rev-parse HEAD)\" ]"
# The tool itself is edited and committed by hand, exactly as a working session does.
echo '# an ordinary edit to the tool' >> "$HCR/README.md"
git -C "$HCR" add README.md
git -C "$HCR" -c user.name=t -c user.email=t@e commit -q -m "edit the tool by hand"
git -C "$HCR" push -q
HCREC="$WORK/hc-notify.rec"; HCN="$WORK/hc-notifier"
cat > "$HCN" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HCREC"
EOS
chmod +x "$HCN"
echo 'edited after the hand commit' > "$HCH/hooks/hc-after.sh"
out_hc="$(SYNC_NOTIFIER="$HCN" SYNC_NO_NOTIFY=0 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "the edit still reaches the repo"           "[ -f '$HCR/payload/hooks/hc-after.sh' ]"
check "send is not called behind its own commit"  "! printf '%s' \"\$out_hc\" | grep -qi 'not applied'"
check "and no behind-notification is fired"       "! grep -qi 'behind' '$HCREC' 2>/dev/null"

# `claude-sync push` commits the payload straight from THIS Mac's home and pushes,
# with no apply step, so it moves HEAD with payload changes whose content is
# already here and leaves the marker behind. Same wedge, and the SHAs cannot tell
# it apart from the other Mac's work arriving. Comparing the bytes can.
echo 'pushed-from-here' > "$HCH/hooks/hc-pushed.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" push >/dev/null 2>&1
echo 'edited after the push' > "$HCH/hooks/hc-after-push.sh"
out_hcp="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "an edit after a plain push still sends"    "[ -f '$HCR/payload/hooks/hc-after-push.sh' ]"
check "and is not called behind either"           "! printf '%s' \"\$out_hcp\" | grep -qi 'not applied'"

# Deciding by content only works over paths the apply actually writes to disk.
# settings.hooks.json is merged INTO settings.json and never lands as a file of
# its own, so comparing it byte for byte finds nothing to compare against and
# reports "behind" forever. Any hooks-config change followed by a plain push put
# this Mac in exactly that state, which is the original wedge wearing a new hat.
HCJ="$WORK/hcj-home"; HCJR="$WORK/hcj-repo"
HCJBARE="$WORK/hcjbare.git"; git init -q --bare -b main "$HCJBARE"
git clone -q "$HCJBARE" "$HCJR" 2>/dev/null
mkdir -p "$HCJ/hooks"; printf '#!/bin/sh\necho a\n' > "$HCJ/hooks/hcj.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}]}}\n' "$HCJ" > "$HCJ/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" sync >/dev/null 2>&1
# change the hooks CONFIG, so the merged fragment itself changes, then plain push
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}]}}\n' "$HCJ" "$HCJ" > "$HCJ/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" push >/dev/null 2>&1
check "the hooks fragment really did change" \
  "git -C '$HCJR' diff --name-only \"\$(cat '$HCJR/.last-applied')\" HEAD -- payload | grep -q settings.hooks.json"
echo 'edit after a hooks change' > "$HCJ/hooks/hcj-after.sh"
out_hcj="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" send 2>&1)"
check "a merged-only payload entry does not block sending" "[ -f '$HCJR/payload/hooks/hcj-after.sh' ]"
check "and it is not reported as unapplied"                "! printf '%s' \"\$out_hcj\" | grep -qi 'not applied'"

# A local commit not yet pushed leaves HEAD ahead of the server. Reading "differs
# from origin" as "behind" wedges sends in the one state where sending is exactly
# what would resolve it.
echo '# committed here, never pushed' >> "$HCR/README.md"
git -C "$HCR" add README.md
git -C "$HCR" -c user.name=t -c user.email=t@e commit -q -m "local only, unpushed"
echo 'edited while ahead' > "$HCH/hooks/hc-ahead.sh"
out_hca="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "being ahead of the server is not being behind" "[ -f '$HCR/payload/hooks/hc-ahead.sh' ]"
check "and reports no unapplied changes"              "! printf '%s' \"\$out_hca\" | grep -qi 'not applied'"

# Control: the guard is load-bearing. The other Mac pushing something this Mac has
# not even fetched must still stop the send, or a watcher firing here mirrors an
# older snapshot over their work.
HCR2="$WORK/hcrepo2"; git clone -q "$HCBARE" "$HCR2" 2>/dev/null
HCH2="$WORK/hchome2"; mkdir -p "$HCH2"; echo '{"hooks":{}}' > "$HCH2/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH2" SYNC_REPO="$HCR2" bash "$SCRIPT" pull >/dev/null 2>&1
# Their work is published from its own healthy clone via sync, which carries no
# send guard. Publishing it from a Mac this test has deliberately wedged would
# make the control depend on the very bug it is the control for.
HCR3="$WORK/hcrepo3"; git clone -q "$HCBARE" "$HCR3" 2>/dev/null
HCH3="$WORK/hchome3"; mkdir -p "$HCH3"; echo '{"hooks":{}}' > "$HCH3/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH3" SYNC_REPO="$HCR3" bash "$SCRIPT" pull >/dev/null 2>&1
echo 'THEIR-WORK' > "$HCH3/hooks/hc-theirs.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH3" SYNC_REPO="$HCR3" bash "$SCRIPT" sync >/dev/null 2>&1
check "their work really was published"            "[ -f '$HCR3/payload/hooks/hc-theirs.sh' ]"
hc2_commits="$(git -C "$HCR2" rev-list --count HEAD)"
echo 'mine while truly behind' > "$HCH2/hooks/hc-mine.sh"
out_hcb="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH2" SYNC_REPO="$HCR2" bash "$SCRIPT" send 2>&1)"
check "a real remote change still blocks the send" "[ ! -f '$HCR2/payload/hooks/hc-mine.sh' ]"
check "it makes no commit in that state"           "[ \"\$(git -C '$HCR2' rev-list --count HEAD)\" = \"\$hc2_commits\" ]"
check "and still says why it skipped"              "printf '%s' \"\$out_hcb\" | grep -qi 'not applied'"

section "== a pull says which received files only take effect in a NEW session =="
# Claude Code reads the rule files (CLAUDE.md and its @imports) once, at session
# start, and builds its list of available skills/agents/commands then too. So a
# pull can land a rule change or a brand-new skill that every already-running
# session keeps ignoring, with nothing on screen saying so. Hook scripts are the
# opposite: they are re-read from disk every time they fire, so naming them here
# would train the eye to ignore the notice.
NSBARE="$WORK/nsbare.git"; git init -q --bare "$NSBARE"
NSA="$WORK/nsrepoA"; git clone -q "$NSBARE" "$NSA"
NSAH="$WORK/nshomeA"; mkdir -p "$NSAH/hooks" "$NSAH/skills/rs-existing"
echo '{"hooks":{}}' > "$NSAH/settings.json"
echo '# rules v1' > "$NSAH/CLAUDE.md"
echo 'one' > "$NSAH/hooks/rs-hook.sh"
echo 'SKILL v1' > "$NSAH/skills/rs-existing/SKILL.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
NSB="$WORK/nsrepoB"; git clone -q "$NSBARE" "$NSB"
NSBH="$WORK/nshomeB"; mkdir -p "$NSBH"; echo '{"hooks":{}}' > "$NSBH/settings.json"
CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull >/dev/null 2>&1
# Mac A now changes a rule file, adds a whole new skill, edits an existing
# skill, and edits a hook, all in one push.
echo '# rules v2' > "$NSAH/CLAUDE.md"
mkdir -p "$NSAH/skills/rs-added"; echo 'SKILL new' > "$NSAH/skills/rs-added/SKILL.md"
echo 'SKILL v2' > "$NSAH/skills/rs-existing/SKILL.md"
echo 'two' > "$NSAH/hooks/rs-hook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
notice_ns="$(printf '%s\n' "$out_ns" | grep -i 'new Claude Code session' || true)"
check "pull tells you a new session is needed"   "[ -n \"\$notice_ns\" ]"
check "the notice names the changed rule file"   "printf '%s' \"\$notice_ns\" | grep -q 'CLAUDE.md'"
check "the notice names the newly added skill"   "printf '%s' \"\$notice_ns\" | grep -q 'rs-added'"
check "it does NOT name the edited hook script"  "! printf '%s' \"\$notice_ns\" | grep -q 'rs-hook'"
# It is one sentence a person reads at a glance, so it has to render as one: the
# first draft joined the last filename straight onto the next word.
check "the notice reads as a sentence"           "! printf '%s' \"\$notice_ns\" | grep -q '[A-Za-z0-9]('"
check "nor an edit to an existing skill"         "! printf '%s' \"\$notice_ns\" | grep -q 'rs-existing'"
# The whole point is that it stays quiet otherwise: a pull carrying only hook
# edits must not tell you to restart, or the notice becomes noise to scroll past.
echo three > "$NSAH/hooks/rs-hook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns2="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "hook-only pull still reports the change"  "printf '%s' \"\$out_ns2\" | grep -q 'updated .*hooks/rs-hook.sh'"
check "hook-only pull says nothing about restarting" "! printf '%s' \"\$out_ns2\" | grep -qi 'new Claude Code session'"
# A removed skill is gone from the running session's list just as wrongly as an
# added one is missing from it, so it earns the notice too.
rm -rf "$NSAH/skills/rs-added"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns3="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "a removed skill also earns the notice"    "printf '%s' \"\$out_ns3\" | grep -i 'new Claude Code session' | grep -q 'rs-added'"

section "== #13: an apply must not delete a hook registration this Mac has not sent yet =="
# Seen for real on 2026-07-29 (and once before, during the send-wedge): the hooks
# block was applied by REPLACING it wholesale, so a hook registered here since the
# last send vanished, silently, while its script file was correctly held back. The
# fix is a three-way merge against the fragment this Mac last applied: incoming
# wins, locally added entries survive, and a deliberate removal on the other Mac is
# still honored.
HK="$WORK/hkbare.git"; git init -q --bare -b main "$HK"
HKA="$WORK/hkrepoA"; git clone -q "$HK" "$HKA" 2>/dev/null
cp "$SCRIPT" "$HKA/claude-sync"
mkdir -p "$HKA/payload/hooks"; echo '#!/bin/sh' > "$HKA/payload/hooks/shared.sh"
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/shared.sh"}]}]}}
J
git -C "$HKA" checkout -q -b main 2>/dev/null || true
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$HKA" push -q -u origin main

HKBH="$WORK/hkhomeB"; mkdir -p "$HKBH/hooks"
echo '{"model":"opus","hooks":{}}' > "$HKBH/settings.json"
HKB="$WORK/hkrepoB"; git clone -q "$HK" "$HKB" 2>/dev/null
CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" SYNC_NO_NOTIFY=1 bash "$HKB/claude-sync" pull >/dev/null 2>&1
check "#13 baseline: the shared hook arrived on Mac B" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"

# Mac B registers a brand new hook of its own and has NOT sent it yet.
echo '#!/bin/sh' > "$HKBH/hooks/local-gate.sh"
jqtmp="$WORK/hk-tmp.json"
jq --arg c "$HKBH/hooks/local-gate.sh" \
   '.hooks.PreToolUse[0].hooks += [{"type":"command","command":$c}]' \
   "$HKBH/settings.json" > "$jqtmp" && mv "$jqtmp" "$HKBH/settings.json"
check "#13 setup: Mac B has its own hook registered locally" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"

# Mac A publishes an unrelated payload change: real news, fragment untouched.
echo '#!/bin/sh v2' > "$HKA/payload/hooks/shared.sh"
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "unrelated change" && git -C "$HKA" push -q
out_hk1="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 an unrelated pull keeps the unsent local hook" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 that pull still delivered the payload change" \
  "grep -q 'v2' '$HKBH/hooks/shared.sh'"
check "#13 the shared hook is still registered too" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"

# Now a true collision: Mac A registers a hook of its own in the fragment.
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/shared.sh"},{"type":"command","command":"__CLAUDE_HOME__/hooks/from-mac-a.sh"}]}]}}
J
echo '#!/bin/sh' > "$HKA/payload/hooks/from-mac-a.sh"
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds a hook" && git -C "$HKA" push -q
out_hk2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 both Macs' hooks coexist after the merge" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | (any(test(\"local-gate.sh\")) and any(test(\"from-mac-a.sh\")))' '$HKBH/settings.json' >/dev/null"
check "#13 the summary names the hook that arrived" \
  "printf '%s' \"\$out_hk2\" | grep -q 'from-mac-a.sh'"

# A deliberate removal on Mac A must still be honored, not resurrected from here.
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/from-mac-a.sh"}]}]}}
J
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "Mac A removes the shared hook" && git -C "$HKA" push -q
out_hk3="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 a removal on the other Mac is honored" \
  "! jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 the local hook still survives that removal" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 the summary names the hook that was removed" \
  "printf '%s' \"\$out_hk3\" | grep -q 'shared.sh'"
check "#13 machine-local settings are still untouched" \
  "jq -e '.model==\"opus\"' '$HKBH/settings.json' >/dev/null"
check "#13 no home-path token is left behind" \
  "! grep -q '__CLAUDE_HOME__' '$HKBH/settings.json'"

# Failure path: settings.json is not valid JSON, so the merge cannot run. It must
# say so loudly and leave the file byte for byte alone, never half write it.
HKC="$WORK/hkrepoC"; git clone -q "$HK" "$HKC" 2>/dev/null
HKCH="$WORK/hkhomeC"; mkdir -p "$HKCH/hooks"
printf '{ "hooks": { BROKEN' > "$HKCH/settings.json"
before_bad="$(shasum "$HKCH/settings.json" | awk '{print $1}')"
out_hkbad="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKCH" SYNC_REPO="$HKC" bash "$HKC/claude-sync" pull 2>&1)"
after_bad="$(shasum "$HKCH/settings.json" | awk '{print $1}')"
check "#13 an unmergeable settings.json is left untouched" "[ '$before_bad' = '$after_bad' ]"
check "#13 and it says so instead of failing silently" \
  "printf '%s' \"\$out_hkbad\" | grep -q 'could not merge the hooks block'"
check "#13 the rest of the pull still lands" "[ -f '$HKCH/hooks/from-mac-a.sh' ]"

section "== #14: rule files merge entry by entry instead of one Mac's copy winning =="
# Seen for real on 2026-07-29: both Macs had appended lessons, so the conflict path
# applied the other Mac's whole LESSONS.md and set this Mac's aside with a suffix.
# Two lessons that existed nowhere else vanished from the file every session loads,
# and the warning named the file but not the lessons. These are append-only lists,
# so the two sides almost always touch different lines and a real three-way merge
# keeps both.
RM="$WORK/rmbare.git"; git init -q --bare -b main "$RM"
RMA="$WORK/rmrepoA"; git clone -q "$RM" "$RMA" 2>/dev/null
cp "$SCRIPT" "$RMA/claude-sync"
mkdir -p "$RMA/payload/hooks"; echo '#!/bin/sh' > "$RMA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$RMA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$RMA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body one\n- **L2. two.** body two\n' > "$RMA/payload/LESSONS.md"
git -C "$RMA" checkout -q -b main 2>/dev/null || true
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RMA" push -q -u origin main

RMBH="$WORK/rmhomeB"; mkdir -p "$RMBH"; echo '{"hooks":{}}' > "$RMBH/settings.json"
RMB="$WORK/rmrepoB"; git clone -q "$RM" "$RMB" 2>/dev/null
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" pull >/dev/null 2>&1
check "#14 baseline: lessons arrived on Mac B" "grep -q 'L1. one' '$RMBH/LESSONS.md'"

# Both Macs append a DIFFERENT lesson, neither knowing about the other.
printf -- '- **L3. three.** written only on Mac B\n' >> "$RMBH/LESSONS.md"
printf -- '- **L4. four.** written only on Mac A\n' >> "$RMA/payload/LESSONS.md"
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds L4" && git -C "$RMA" push -q
out_rm1="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" bash "$RMB/claude-sync" pull 2>&1)"
check "#14 the other Mac's lesson arrives"        "grep -q 'L4. four' '$RMBH/LESSONS.md'"
check "#14 this Mac's unsent lesson survives"     "grep -q 'L3. three' '$RMBH/LESSONS.md'"
check "#14 the original lessons are still there"  "grep -q 'L1. one' '$RMBH/LESSONS.md' && grep -q 'L2. two' '$RMBH/LESSONS.md'"
check "#14 no conflict copy is left behind"       "[ ! -e '$RMBH/LESSONS.md.conflict-'* ] 2>/dev/null || ! ls '$RMBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "#14 the merge is reported, not silent"     "printf '%s' \"\$out_rm1\" | grep -qi 'merged'"
check "#14 the report names the file merged"      "printf '%s' \"\$out_rm1\" | grep -q 'LESSONS.md'"
check "#14 no conflict markers reach the file"    "! grep -q '<<<<<<<' '$RMBH/LESSONS.md'"

# Seen for real on 2026-08-06: this same pull merged three lessons into LESSONS.md and
# then printed "Already up to date: nothing on this Mac needed changing", with no
# restart notice. The merge recorded its write only in MERGED_RULE_FILES, never in the
# applied list that BOTH the change summary and the restart notice read, so the one
# path that rewrites a rule file was the one path invisible to the report about it.
# Two things follow, and the second is the one that costs something: a rule file is
# loaded at session start (LESSONS.md via CLAUDE.md), so a session that stays open
# keeps the pre-merge copy while the summary says there is nothing to pick up.
check "#14 a merge is never reported as nothing-changed" \
  "! printf '%s' \"\$out_rm1\" | grep -qi 'nothing on this Mac needed changing'"
check "#14 the merged file is listed as a received change" \
  "printf '%s' \"\$out_rm1\" | grep -qE '^ +merged +LESSONS\\.md'"
check "#14 a merged rule file earns the restart notice" \
  "printf '%s' \"\$out_rm1\" | grep -i 'new Claude Code session' | grep -q 'LESSONS.md'"

# The merged file must then reach the other Mac, or the lesson is still stranded.
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" push >/dev/null 2>&1
check "#14 the merged result is published upward" "grep -q 'L3. three' '$RMB/payload/LESSONS.md'"
check "#14 and it still carries the other side"   "grep -q 'L4. four' '$RMB/payload/LESSONS.md'"

# A genuine clash is both Macs REWRITING the same existing entry, not both adding
# at the end. That cannot be settled by any rule, so the old behavior stands, but
# the entries that exist ONLY on this Mac have to be named, not just the filename.
git -C "$RMB" pull -q 2>/dev/null
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" pull >/dev/null 2>&1
git -C "$RMA" pull -q --no-rebase 2>/dev/null
# Mac A rewrites L1's wording.
sed -i '' 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac A/' "$RMA/payload/LESSONS.md"
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A rewrites L1" && git -C "$RMA" push -q
# Mac B rewrites the SAME line differently, and also adds an entry of its own.
sed -i '' 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac B/' "$RMBH/LESSONS.md"
printf -- '- **L6. six.** only on Mac B\n' >> "$RMBH/LESSONS.md"
out_rm2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" bash "$RMB/claude-sync" pull 2>&1)"
check "#14 an unmergeable file still keeps a copy of yours" \
  "ls '$RMBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "#14 and it names the entry only you had" \
  "printf '%s' \"\$out_rm2\" | grep -q 'L6'"
check "#14 an unmergeable file never gets conflict markers" \
  "! grep -q '<<<<<<<' '$RMBH/LESSONS.md'"

section "== #15: duplicate lesson numbers must not be published or go unnoticed =="
# Numbers are assigned by hand, so two Macs working the same day both reach for the
# same one. On 2026-07-29 six lessons claimed three numbers, and a duplicate L43 had
# already sat in the file for a day. The file's own header promises the numbering is
# stable for reference, which a duplicate quietly breaks.
LN="$WORK/lnrepo"; mkdir -p "$LN/payload"
LNH="$WORK/lnhome"; mkdir -p "$LNH/hooks"
echo '{"hooks":{}}' > "$LNH/settings.json"
echo '#!/bin/sh' > "$LNH/hooks/keep-syncing.sh"
printf '# rules\n@LESSONS.md\n' > "$LNH/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body\n- **L2. two.** body\n' > "$LNH/LESSONS.md"
out_ln_ok="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push 2>&1)"; rc_ln_ok=$?
check "#15 a clean lessons file publishes normally" "[ \"\$rc_ln_ok\" -eq 0 ] && grep -q 'L1. one' '$LN/payload/LESSONS.md'"

# Now a duplicate number.
printf -- '- **L2. two again.** a different lesson with the same number\n' >> "$LNH/LESSONS.md"
out_ln_dup="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push 2>&1)"
check "#15 the duplicate is named, not silent"        "printf '%s' \"\$out_ln_dup\" | grep -q 'L2'"
check "#15 the file it is in is named"                "printf '%s' \"\$out_ln_dup\" | grep -q 'LESSONS.md'"
check "#15 the corrupt numbering is NOT published"    "! grep -q 'two again' '$LN/payload/LESSONS.md'"
check "#15 the previously published copy is intact"   "grep -q 'L1. one' '$LN/payload/LESSONS.md'"
# Blocking the whole sync over a numbering slip would stop hooks and skills moving
# between Macs, which is the wedge this tool has been bitten by twice. Only the
# affected file is held back.
check "#15 everything else still publishes"           "[ -f '$LN/payload/hooks/keep-syncing.sh' ]"

# The documented override still publishes it.
SYNC_SKIP_LESSON_CHECK=1 SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push >/dev/null 2>&1
check "#15 the override publishes it anyway"          "grep -q 'two again' '$LN/payload/LESSONS.md'"

# The helper that stops a number being picked by eye. Next means one past the
# highest, never a gap: a skipped number was skipped deliberately.
printf '# Lessons\n\n- **L1. one.** body\n- **L2. two.** body\n- **L5. five.** body\n' > "$LNH/LESSONS.md"
out_next="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" next-lesson 2>&1)"
check "#15 next-lesson reports one past the highest"  "printf '%s' \"\$out_next\" | grep -q 'L6'"
check "#15 next-lesson does not offer a gap"          "! printf '%s' \"\$out_next\" | grep -q 'L3'"

# next-lesson must survive a rule file that contains no lessons at all: under
# pipefail a grep matching nothing killed the whole command and printed nothing.
printf '# just rules, no lessons here\n' > "$LNH/RTK.md"
out_next2="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" next-lesson 2>&1)"; rc_next2=$?
check "#15 next-lesson survives a file with no lessons" "[ \"\$rc_next2\" -eq 0 ] && printf '%s' \"\$out_next2\" | grep -q 'L6'"

# The standalone check, usable as a gate before writing a lesson.
out_chk_ok="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_ok=$?
check "#15 check-lessons passes on sound numbering" "[ \"\$rc_chk_ok\" -eq 0 ]"
check "#15 check-lessons reports the next free number" "printf '%s' \"\$out_chk_ok\" | grep -q 'L6'"
printf -- '- **L5. five again.** duplicate\n' >> "$LNH/LESSONS.md"
out_chk_bad="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_bad=$?
check "#15 check-lessons fails on a duplicate" "[ \"\$rc_chk_bad\" -ne 0 ]"
check "#15 and names the number involved"      "printf '%s' \"\$out_chk_bad\" | grep -q 'L5'"

# A duplicate created by the #14 merge (both Macs choosing the same number) has to
# surface at apply time too, since by then it is already in the file.
LNM="$WORK/lnmbare.git"; git init -q --bare -b main "$LNM"
LNMA="$WORK/lnmA"; git clone -q "$LNM" "$LNMA" 2>/dev/null
cp "$SCRIPT" "$LNMA/claude-sync"
mkdir -p "$LNMA/payload/hooks"; echo '#!/bin/sh' > "$LNMA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$LNMA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$LNMA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body\n' > "$LNMA/payload/LESSONS.md"
git -C "$LNMA" checkout -q -b main 2>/dev/null || true
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$LNMA" push -q -u origin main
LNMBH="$WORK/lnmhomeB"; mkdir -p "$LNMBH"; echo '{"hooks":{}}' > "$LNMBH/settings.json"
LNMB="$WORK/lnmB"; git clone -q "$LNM" "$LNMB" 2>/dev/null
CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" SYNC_NO_NOTIFY=1 bash "$LNMB/claude-sync" pull >/dev/null 2>&1
# Both Macs independently write an L2. Mac A also has an L4, so the next free
# number is L5: the renumber must go one past every number in use, never just
# one past the collision.
printf -- '- **L2. mine.** written on Mac B\n  and its body cites L2 by its own number\n' >> "$LNMBH/LESSONS.md"
# A mention in ANOTHER synced rule file, written on this Mac: the tool cannot merge
# that file this pull, so it must be warned about, never rewritten.
printf -- 'see L2 for the rule\n' >> "$LNMBH/CLAUDE.md"
# Mac A's published side ALSO cites the contested number in a body line: that mention
# means Mac A's own L2 and must never be rewritten.
printf -- '- **L2. theirs.** written on Mac A\n- **L4. four.** also on Mac A\n  distinct from L2, which it cites\n' >> "$LNMA/payload/LESSONS.md"
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds its L2 and L4" && git -C "$LNMA" push -q
out_lnm="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" bash "$LNMB/claude-sync" pull 2>&1)"
section "== #17: a collision the merge creates is settled by renumbering the unsent entry =="
# The settled rule (see the 2026-08-05 note above): the published copy keeps the
# number, because the other Mac may already reference it, and the entry that has
# never left this Mac takes the next free number. The script already knows both
# facts at merge time, so doing the renumber by hand (seen again 2026-08-11) was
# pure toil, and until it was done the guard held the file back from every send.
check "#17 both lessons survive the merge"               "grep -q 'mine' '$LNMBH/LESSONS.md' && grep -q 'theirs' '$LNMBH/LESSONS.md'"
check "#17 the published entry keeps its number"         "grep -q '^- \*\*L2\. theirs' '$LNMBH/LESSONS.md'"
check "#17 the unsent entry takes the next free number"  "grep -q '^- \*\*L5\. mine' '$LNMBH/LESSONS.md'"
check "#17 the old number is no longer duplicated"       "[ \"\$(grep -c '^- \*\*L2\.' '$LNMBH/LESSONS.md')\" = 1 ]"
check "#17 the numbering is sound afterwards"            "SYNC_NO_GIT=1 CLAUDE_HOME='$LNMBH' SYNC_REPO='$LNMB' bash '$LNMB/claude-sync' check-lessons >/dev/null 2>&1"
check "#17 the renumber is reported, naming old and new" "printf '%s' \"\$out_lnm\" | grep -qi 'renumber' && printf '%s' \"\$out_lnm\" | grep -q 'L2' && printf '%s' \"\$out_lnm\" | grep -q 'L5'"
check "#17 the file is not reported as held back"        "! printf '%s' \"\$out_lnm\" | grep -qi 'held back'"
# A renumber must carry its body mentions with it. At merge time the tool DOES know
# which lesson a local mention meant: a line this Mac wrote (absent from the arriving
# published file) could only ever have meant this Mac's own entry, because the other
# Mac's entry did not exist here until this pull. So local mentions are rewritten to
# the new number, published mentions keep the old number (which now names the other
# Mac's entry), and a mention in a rule file the tool is not merging is warned about.
check "#17 a local body mention of the old number is rewritten" \
  "grep -q 'cites L5 by its own number' '$LNMBH/LESSONS.md'"
check "#17 the old local mention is gone" \
  "! grep -q 'cites L2 by its own number' '$LNMBH/LESSONS.md'"
check "#17 a published body mention keeps its number" \
  "grep -q 'distinct from L2, which it cites' '$LNMBH/LESSONS.md'"
check "#17 the rewrite is reported, naming old and new" \
  "printf '%s' \"\$out_lnm\" | grep -qi 'rewrote' && printf '%s' \"\$out_lnm\" | grep -q 'L2 to L5'"
check "#17 no go-and-check warning for the file it rewrote" \
  "! printf '%s' \"\$out_lnm\" | grep -qi 'still mentions'"
check "#17 a mention in another synced rule file is warned about" \
  "printf '%s' \"\$out_lnm\" | grep -q 'CLAUDE.md' && printf '%s' \"\$out_lnm\" | grep -qi 'also mentions L2'"
check "#17 that other file is never rewritten" \
  "grep -q 'see L2 for the rule' '$LNMBH/CLAUDE.md'"
# The renumbered file must publish on the very next send, which is the whole point.
CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" SYNC_NO_NOTIFY=1 bash "$LNMB/claude-sync" push >/dev/null 2>&1
check "#17 the renumbered entry publishes upward"        "grep -q '^- \*\*L5\. mine' '$LNMB/payload/LESSONS.md'"

# A collision that ARRIVES already published is NOT ours to settle: both entries
# are on the other Mac under those numbers, so renumbering either here would break
# references there. It applies as-is and the existing warning fires instead.
git -C "$LNMA" pull -q --no-rebase 2>/dev/null
printf -- '- **L6. six.** on Mac A\n- **L6. six again.** also on Mac A under the same number\n' >> "$LNMA/payload/LESSONS.md"
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A publishes a collision" && git -C "$LNMA" push -q
out_lnm2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" bash "$LNMB/claude-sync" pull 2>&1)"
check "#17 an arriving collision is applied untouched"   "[ \"\$(grep -c '^- \*\*L6\.' '$LNMBH/LESSONS.md')\" = 2 ]"
check "#17 and is warned about, not auto-renumbered"     "printf '%s' \"\$out_lnm2\" | grep -q 'used 2 times'"

# ---- repo hygiene: nothing already-committed slips past the rsync excludes ----
# The excludes above stop NEW bytecode being staged, but they cannot clean a file
# that was committed before they existed: three had been, and the apply-side
# exclude then hid them from every symptom. Assert the tracked set stays clean.
section "== repo hygiene =="
if git -C "$(dirname "$SCRIPT")" rev-parse --git-dir >/dev/null 2>&1; then
  tracked_bytecode="$(git -C "$(dirname "$SCRIPT")" ls-files | grep -cE '\.pyc$|__pycache__' || true)"
  check "no bytecode tracked in the sync repo" "[ '$tracked_bytecode' = '0' ]"
else
  ok "no bytecode tracked in the sync repo (skipped: not a git checkout)"
fi

section "== install-autosync installs the claudesync shell alias, idempotently =="
# Why: the /sync-config skill lives under skills/ so it reaches every Mac on the next
# push, but the `claudesync` terminal alias lives in ~/.zshrc which is deliberately NOT
# synced. So the alias had to be added by hand on each Mac while the skill arrived by
# itself. SYNC_ZSHRC redirects the target, so no test can reach the real ~/.zshrc.
ZDIR="$WORK/zsh"; mkdir -p "$ZDIR"
ALIAS_LINE="alias claudesync='"'"'$HOME/claude-config-sync/claude-sync pull'"'"'"

# 1. a zshrc with no alias gets one appended, and existing content is preserved
ZRC="$ZDIR/rc-plain"
printf 'export EDITOR=bbedit\n' > "$ZRC"
outZ="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "alias added when missing"        "grep -q 'alias claudesync=' '$ZRC'"
check "alias runs a pull"               "grep -q \"claude-sync' *pull\|claude-sync pull\" '$ZRC'"
check "alias line is commented"         "grep -q 'claude-config-sync: pull shared' '$ZRC'"
check "existing zshrc content kept"     "grep -q 'EDITOR=bbedit' '$ZRC'"
check "it says the alias was added"     "printf '%s' \"\$outZ\" | grep -qi 'alias'"

# 2. assume it runs twice: a second install must not append a duplicate
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "no duplicate alias on re-run"    "[ \"\$(grep -c 'alias claudesync=' '$ZRC')\" = 1 ]"
check "no duplicate comment on re-run"  "[ \"\$(grep -c 'claude-config-sync: pull shared' '$ZRC')\" = 1 ]"

# 3. an absent zshrc is created rather than skipped
ZRC2="$ZDIR/rc-absent"
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC2" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "absent zshrc is created"         "[ -f '$ZRC2' ]"
check "created zshrc has the alias"     "grep -q 'alias claudesync=' '$ZRC2'"

# 4. someone else's claudesync alias is LEFT ALONE and reported, never rewritten.
# This is the user's shell config: silently repointing a command they typed themselves
# is worse than telling them it differs.
ZRC3="$ZDIR/rc-conflict"
printf "alias claudesync='echo something else'\n" > "$ZRC3"
outZ3="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC3" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "a different alias is untouched"  "grep -q 'echo something else' '$ZRC3'"
check "no second alias appended"        "[ \"\$(grep -c 'alias claudesync=' '$ZRC3')\" = 1 ]"
check "the difference is reported"      "printf '%s' \"\$outZ3\" | grep -qi 'differ\|already\|points'"

# 5. `~` and the expanded home directory are the SAME path, so an alias written with a
# tilde (which is how it was added by hand on this Mac) must count as already installed
# rather than as somebody else's conflicting alias. A gate that cries wolf gets ignored.
ZRC4="$ZDIR/rc-tilde"
printf "alias claudesync='~/claude-config-sync/claude-sync pull'\n" > "$ZRC4"
outZ4="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC4" SYNC_SELF_DIR="$HOME/claude-config-sync" CLAUDE_HOME="$CA" \
  bash "$SCRIPT" install-autosync 2>&1)"
check "a tilde alias counts as installed"  "printf '%s' \"\$outZ4\" | grep -qi 'already installed'"
check "no duplicate for the tilde form"    "[ \"\$(grep -c 'alias claudesync=' '$ZRC4')\" = 1 ]"
check "the tilde form is not called a conflict" "! printf '%s' \"\$outZ4\" | grep -qi 'points somewhere else'"

section "== a lesson renumbered on the other Mac must not come back under its old number =="
# Seen for real on 2026-08-05, the third numbering collision. Both Macs had used L66
# and L67 for different lessons. The clash was settled in the shared repo the agreed
# way (published keeps the number, the unsent local one is renumbered), but the merge
# below is ADDITIVE: it kept this Mac's old-numbered copy alongside the arriving
# renumbered one, so the same lesson sat in the file twice, the duplicate numbers came
# straight back, and the duplicate guard then held the whole file back from every send
# with no wedge notification. The renumbering has to survive the merge that follows it.
RN="$WORK/rnbare.git"; git init -q --bare -b main "$RN"
RNA="$WORK/rnrepoA"; git clone -q "$RN" "$RNA" 2>/dev/null
cp "$SCRIPT" "$RNA/claude-sync"
mkdir -p "$RNA/payload/hooks"; echo '#!/bin/sh' > "$RNA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$RNA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$RNA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body one\n' > "$RNA/payload/LESSONS.md"
git -C "$RNA" checkout -q -b main 2>/dev/null || true
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RNA" push -q -u origin main

RNBH="$WORK/rnhomeB"; mkdir -p "$RNBH"; echo '{"hooks":{}}' > "$RNBH/settings.json"
RNB="$WORK/rnrepoB"; git clone -q "$RN" "$RNB" 2>/dev/null
CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" SYNC_NO_NOTIFY=1 bash "$RNB/claude-sync" pull >/dev/null 2>&1

# This Mac writes L2 and never gets to send it. The other Mac independently uses L2
# for something else and publishes it, then settles the clash by renumbering this
# Mac's entry to L3, exactly as the convention says.
# A second local lesson cites the doomed number: written on this Mac, it could only
# have meant this Mac's entry, so the drop must carry the mention to the new number.
printf -- '- **L2. mine.** written only on Mac B\n- **L8. other.** a local note pointing at L2\n' >> "$RNBH/LESSONS.md"
printf -- '- **L2. theirs.** published first by Mac A\n- **L3. mine.** written only on Mac B\n' >> "$RNA/payload/LESSONS.md"
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m "Mac A publishes L2 and renumbers B's to L3" && git -C "$RNA" push -q
out_rn="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" bash "$RNB/claude-sync" pull 2>&1)"

check "renumber: the other Mac's L2 arrives"        "grep -q 'L2. theirs' '$RNBH/LESSONS.md'"
check "renumber: this Mac's lesson survives"        "grep -q 'mine.\\*\\* written only on Mac B' '$RNBH/LESSONS.md'"
check "renumber: it survives under its NEW number"  "grep -q 'L3. mine' '$RNBH/LESSONS.md'"
check "renumber: the old-numbered copy is gone"     "! grep -q 'L2. mine' '$RNBH/LESSONS.md'"
check "renumber: the lesson appears exactly once"   "[ \"\$(grep -c 'written only on Mac B' '$RNBH/LESSONS.md')\" = 1 ]"
check "renumber: no duplicate numbers are created"  "! printf '%s' \"\$out_rn\" | grep -qi 'used twice\\|used 2 times'"
check "renumber: numbering passes its own check" \
  "CLAUDE_HOME='$RNBH' SYNC_REPO='$RNB' bash '$RNB/claude-sync' check-lessons >/dev/null 2>&1"
# The report has to name what was dropped and both numbers involved, or a silently
# vanished entry reads as a clean merge. Asserting only the word "renumber" would
# pass on the pre-existing duplicate warning, which is a different message entirely.
check "renumber: the drop names the old and new number" \
  "printf '%s' \"\$out_rn\" | grep -qi 'renumbered' && printf '%s' \"\$out_rn\" | grep -q 'L2' && printf '%s' \"\$out_rn\" | grep -q 'L3'"
# The other Mac's renumber of OUR entry must carry our local mentions with it, exactly
# as a renumber done here does: the local note meant our lesson, which is now L3.
check "renumber: a local mention follows the other Mac's renumber" \
  "grep -q 'a local note pointing at L3' '$RNBH/LESSONS.md'"
check "renumber: the old-numbered local mention is gone" \
  "! grep -q 'a local note pointing at L2' '$RNBH/LESSONS.md'"
check "renumber: the published entry keeps its own heading number" \
  "grep -q '^- \*\*L2\. theirs' '$RNBH/LESSONS.md'"
# And the file must still be sendable. A duplicate holds that ONE file back from every
# send, so prove it by sending something NEW: asserting the arriving L3 is still in the
# payload would pass either way, since the other Mac put it there.
printf -- '- **L4. later.** added on Mac B after the merge\n' >> "$RNBH/LESSONS.md"
CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" SYNC_NO_NOTIFY=1 bash "$RNB/claude-sync" push >/dev/null 2>&1
check "renumber: the file is not held back from sending" \
  "grep -q 'L4. later' '$RNB/payload/LESSONS.md'"

# The dangerous direction of the fix above is over-deleting: it removes an entry, so
# two entries that merely LOOK alike must never be collapsed. Only a pure renumber
# (identical text, different number) qualifies. Both Macs independently using one
# number for two DIFFERENT lessons is the ordinary collision, and both must survive:
# the published one under the contested number, the unsent one renumbered (#17).
printf -- '- **L9. same number.** but this text is only on Mac B\n' >> "$RNBH/LESSONS.md"
# Mac A has to take Mac B's published work first, or its own push is rejected and the
# scenario silently never happens (the assertions below would then pass vacuously).
git -C "$RNA" pull -q --no-rebase 2>/dev/null
printf -- '- **L9. same number.** and this different text is only on Mac A\n' >> "$RNA/payload/LESSONS.md"
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds a clashing L9" && git -C "$RNA" push -q
out_rn2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" bash "$RNB/claude-sync" pull 2>&1)"
check "renumber: a genuinely different entry is never dropped" \
  "grep -q 'only on Mac B' '$RNBH/LESSONS.md' && grep -q 'only on Mac A' '$RNBH/LESSONS.md'"
check "renumber: the published entry keeps the contested number" \
  "grep -q '^- \*\*L9\..*only on Mac A' '$RNBH/LESSONS.md'"
check "renumber: the unsent entry is renumbered, not left colliding" \
  "grep -q '^- \*\*L10\..*only on Mac B' '$RNBH/LESSONS.md'"
check "renumber: the settled collision is reported, not silent" \
  "printf '%s' \"\$out_rn2\" | grep -qi 'renumbered' && printf '%s' \"\$out_rn2\" | grep -q 'L10'"
check "renumber: no duplicate number remains afterwards" \
  "! printf '%s' \"\$out_rn2\" | grep -qi 'used twice\\|used 2 times'"
# A warning that cries wolf gets ignored: nothing in this file mentions L9 in
# body text, so neither a rewrite report nor a go-and-check warning may fire here.
check "renumber: no mention handling when nothing mentions the old number" \
  "! printf '%s' \"\$out_rn2\" | grep -qiE 'rewrote|also mentions|still mentions'"

section "== #16: a commit that does not touch payload must still be sent =="
# Found on 2026-08-06 while pushing a fix to this very script: push decided WHETHER to
# push from whether STAGING THE PAYLOAD had produced a commit. So a commit touching
# anything else in the repo (this script, this test file) was never sent, and push
# still printed "already up to date" over a branch that was ahead. Same shape as L78,
# one signal standing in for the whole state, except here what it silently withheld
# was the work itself. do_sync had it too, so the background daemon stranded them as
# well and the tool looked healthy the entire time.
UPB="$WORK/upbare.git"; git init -q --bare -b main "$UPB"
UPR="$WORK/uprepo"; git clone -q "$UPB" "$UPR" 2>/dev/null
cp "$SCRIPT" "$UPR/claude-sync"
echo '{"hooks":{}}' > "$UPR/payload/settings.hooks.json" 2>/dev/null || { mkdir -p "$UPR/payload"; echo '{"hooks":{}}' > "$UPR/payload/settings.hooks.json"; }
echo '# rules' > "$UPR/payload/CLAUDE.md"
git -C "$UPR" checkout -q -b main 2>/dev/null || true
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$UPR" push -q -u origin main
UPH="$WORK/uphome"; mkdir -p "$UPH"; echo '{"hooks":{}}' > "$UPH/settings.json"; echo '# rules' > "$UPH/CLAUDE.md"
# Settle first, so the run under test genuinely has nothing to stage. Without this the
# test could pass for the wrong reason: any incidental payload change makes push fire
# anyway, and the assertion would never exercise the bug.
CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
out_up0="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 precondition: a settled push has nothing to stage" \
  "printf '%s' \"\$out_up0\" | grep -qi 'already up to date'"

echo '# notes' > "$UPR/NOTES.md"
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m "edit outside payload"
out_up="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 push does not claim nothing changed while ahead" \
  "! printf '%s' \"\$out_up\" | grep -qi 'already up to date'"
# Captured, not piped straight into grep: under `set -o pipefail` grep -q exits on the
# first matching line, git takes SIGPIPE, and the pipeline reports failure over a log
# that DOES contain the commit. That false negative cost a debugging detour here.
bare_log_up="$(git -C "$UPB" log --oneline main 2>/dev/null || true)"
check "#16 the non-payload commit reaches the remote" \
  "printf '%s' \"\$bare_log_up\" | grep -q 'edit outside payload'"

# sync is what the background daemon runs, so the same hole there strands the commit
# with nobody watching at all.
echo '# more' >> "$UPR/NOTES.md"
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m "second edit outside payload"
CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
bare_log_up2="$(git -C "$UPB" log --oneline main 2>/dev/null || true)"
check "#16 sync also sends a non-payload commit" \
  "printf '%s' \"\$bare_log_up2\" | grep -q 'second edit outside payload'"

# And it must still stay quiet when there is genuinely nothing to do, or the line
# becomes noise and the real "already up to date" case stops meaning anything.
out_up2="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 a truly settled push still says so" \
  "printf '%s' \"\$out_up2\" | grep -qi 'already up to date'"

section "== a failed sync names the RIGHT cause (#22) =="
# do_sync had ONE message for every way `git pull --rebase` can fail, and it named a
# specific innocent cause: "both Macs changed the same config". On 2026-08-16 a two
# millisecond connection failure to github.com was reported that way, sending Dan to
# investigate a Mac that had been switched off for two days. Each outcome below is a
# state git can really be left in (all four were measured against real git, not assumed),
# and each must be told apart by git's own STATE rather than by the text of its message.
seed_pair(){   # $1 = tag -> sets PB/PA/PHA (bare, repo A, home A), all already in sync
  PB="$WORK/$1-bare.git"; git init -q --bare -b main "$PB"
  PA="$WORK/$1-repoA"; git clone -q "$PB" "$PA" 2>/dev/null
  git -C "$PA" checkout -q -b main 2>/dev/null || true
  # The real repo ignores .last-applied. Without this the fixture commits it, it lands
  # as an incoming tracked file on the other side, and it starts answering assertions
  # that were written about the file the test actually cares about.
  printf '.last-applied\n' > "$PA/.gitignore"
  git -C "$PA" add .gitignore
  git -C "$PA" -c user.name=t -c user.email=t@e commit -q -m "seed"
  git -C "$PA" push -q -u origin main
  PHA="$WORK/$1-homeA"; mkdir -p "$PHA/skills/s"
  echo 'one' > "$PHA/skills/s/SKILL.md"; echo '{"hooks":{}}' > "$PHA/settings.json"
  CLAUDE_HOME="$PHA" SYNC_REPO="$PA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
}

# 1) the remote cannot be REACHED. Uses a vanished local path, never a real host, so the
# suite is structurally unable to depend on the network being down to pass.
seed_pair unreach; UNR="$PA"; UNH="$PHA"
git -C "$UNR" remote set-url origin "$WORK/vanished.git"
echo 'two' > "$UNH/skills/s/SKILL.md"
out_unreach="$(CLAUDE_HOME="$UNH" SYNC_REPO="$UNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_unreach=$?
check "#22 an unreachable remote fails loudly" "[ $rc_unreach -ne 0 ]"
check "#22 an unreachable remote is NOT blamed on the other Mac" \
  "! printf '%s' \"\$out_unreach\" | grep -q 'both Macs changed the same config'"
check "#22 an unreachable remote says the repo could not be reached" \
  "printf '%s' \"\$out_unreach\" | grep -qi 'could not reach'"
check "#22 an unreachable remote still keeps this Mac's commit" \
  "[ -n \"\$(git -C '$UNR' log --oneline -1 2>/dev/null)\" ]"

# 2) a GENUINE two-Mac conflict: the one case the old message was actually about, so it
# must keep saying exactly that. Told apart by a rebase left half finished.
seed_pair conf; CFA="$PA"; CFHA="$PHA"; CFB_BARE="$PB"
CFR="$WORK/conf-repoB"; git clone -q "$CFB_BARE" "$CFR" 2>/dev/null
CFHB="$WORK/conf-homeB"; mkdir -p "$CFHB"; echo '{"hooks":{}}' > "$CFHB/settings.json"
CLAUDE_HOME="$CFHB" SYNC_REPO="$CFR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
echo 'A rewrote this line' > "$CFHA/skills/s/SKILL.md"
CLAUDE_HOME="$CFHA" SYNC_REPO="$CFA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
echo 'B rewrote this line' > "$CFHB/skills/s/SKILL.md"
out_conf="$(CLAUDE_HOME="$CFHB" SYNC_REPO="$CFR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_conf=$?
check "#22 a real two-Mac conflict fails" "[ $rc_conf -ne 0 ]"
check "#22 a real two-Mac conflict still names both Macs" \
  "printf '%s' \"\$out_conf\" | grep -q 'both Macs changed the same config'"
# --absolute-git-dir, not --git-path: the latter answers with a path relative to the
# repo, which `[ -d ]` then resolves against the SUITE's working directory, so this
# assertion was passing on a path that could never exist no matter what the code did.
check "#22 a real two-Mac conflict leaves no half finished rebase" \
  "[ ! -d \"\$(git -C '$CFR' rev-parse --absolute-git-dir)/rebase-merge\" ]"

# 3) the pull fails for a reason that is NEITHER: here an untracked file sits where the
# other Mac's commit adds one. Reachable, nothing conflicting, no rebase started. It must
# quote git rather than invent a cause (never default an unknown failure to a known one).
seed_pair other; OTA="$PA"; OTHA="$PHA"; OTBARE="$PB"
OTR="$WORK/other-repoB"; git clone -q "$OTBARE" "$OTR" 2>/dev/null
OTHB="$WORK/other-homeB"; mkdir -p "$OTHB"; echo '{"hooks":{}}' > "$OTHB/settings.json"
CLAUDE_HOME="$OTHB" SYNC_REPO="$OTR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
echo 'guide' > "$OTA/GUIDE.md"
git -C "$OTA" add GUIDE.md && git -C "$OTA" -c user.name=t -c user.email=t@e commit -q -m "A adds a guide" && git -C "$OTA" push -q
echo 'my own untracked copy' > "$OTR/GUIDE.md"
echo 'B edit' > "$OTHB/skills/s/SKILL.md"
out_other="$(CLAUDE_HOME="$OTHB" SYNC_REPO="$OTR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_other=$?
check "#22 an unrecognised pull failure fails loudly" "[ $rc_other -ne 0 ]"
check "#22 an unrecognised pull failure is NOT blamed on the other Mac" \
  "! printf '%s' \"\$out_other\" | grep -q 'both Macs changed the same config'"
# Deliberately asserts on claude-sync's OWN sentence, not just on the word `untracked`:
# git's stderr reaches this output whatever the tool does, so grepping only for git's
# wording passed against the old single-message code and proved nothing.
check "#22 an unrecognised pull failure is reported by the tool, not just by git" \
  "printf '%s' \"\$out_other\" | grep -q 'claude-sync:.*git said'"
check "#22 an unrecognised pull failure repeats git's own reason" \
  "printf '%s' \"\$out_other\" | grep -qi 'untracked'"

# 4) the pull EXITS ZERO and is still broken. Measured against real git: when re-applying
# the local edits it set aside conflicts, git prints "Successfully rebased", returns 0,
# leaves conflict markers in the working tree and parks the edits in a stash. Only
# payload/ is ever committed, so the file left with markers is the sync tool itself.
seed_pair stash; STA="$PA"; STHA="$PHA"; STBARE="$PB"
# NOTES.md has to be TRACKED on BOTH sides before they diverge. The first version of
# this fixture let A introduce it as a new file, which made it an UNTRACKED collision
# on B: the scenario quietly became case 3 above and its assertions passed on the wrong
# mechanism entirely.
echo 'shared tool notes' > "$STA/NOTES.md"
git -C "$STA" add NOTES.md && git -C "$STA" -c user.name=t -c user.email=t@e commit -q -m "tool notes" && git -C "$STA" push -q
STR="$WORK/stash-repoB"; git clone -q "$STBARE" "$STR" 2>/dev/null
STHB="$WORK/stash-homeB"; mkdir -p "$STHB"; echo '{"hooks":{}}' > "$STHB/settings.json"
CLAUDE_HOME="$STHB" SYNC_REPO="$STR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
echo 'tool notes rewritten by A' > "$STA/NOTES.md"
git -C "$STA" add NOTES.md && git -C "$STA" -c user.name=t -c user.email=t@e commit -q -m "A edits the tool" && git -C "$STA" push -q
echo 'tool notes rewritten by B, never committed' > "$STR/NOTES.md"
echo 'B edit' > "$STHB/skills/s/SKILL.md"
out_stash="$(CLAUDE_HOME="$STHB" SYNC_REPO="$STR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_stash=$?
check "#22 a conflicted autostash restore is not reported as a clean sync" "[ $rc_stash -ne 0 ]"
check "#22 a conflicted autostash restore does not announce success" \
  "! printf '%s' \"\$out_stash\" | grep -q 'Synced (sent local changes'"
check "#22 a conflicted autostash restore says the edits were parked" \
  "printf '%s' \"\$out_stash\" | grep -qi 'stash'"
check "#22 a conflicted autostash restore is not blamed on a payload conflict" \
  "! printf '%s' \"\$out_stash\" | grep -q 'both Macs changed the same config'"
check "#22 a conflicted autostash restore leaves the edits recoverable" \
  "[ -n \"\$(git -C '$STR' stash list 2>/dev/null)\" ]"

section "== status reports leftover conflict copies (#20) =="
# When both Macs change one file and it cannot be merged, apply_payload_to_local keeps
# this Mac's version as <file>.conflict-<hostname> and notifies ONCE. Nothing surfaced it
# after that: status never mentioned it, and *.conflict-* is excluded from syncing so the
# other Mac cannot see it either. A copy from 2026-07-29 sat in ~/.claude unnoticed for
# nearly three weeks that way. The copy is the only record of work that lost a merge, so
# the surface that reports state has to keep reporting it until it is gone.
CQH="$WORK/conflict-home"; CQR="$WORK/conflict-repo"
mkdir -p "$CQH/skills/beta" "$CQR/payload"
echo '{"hooks":{}}' > "$CQH/settings.json"
echo 'L1' > "$CQH/LESSONS.md"; echo 'SKILL' > "$CQH/skills/beta/SKILL.md"
CLAUDE_HOME="$CQH" SYNC_REPO="$CQR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
# Silence first: a status with nothing outstanding must not mention conflicts at all, or
# the line becomes noise and stops meaning anything when a real one appears.
out_noconf="$(CLAUDE_HOME="$CQH" SYNC_REPO="$CQR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#20 a clean status says nothing about conflicts" \
  "! printf '%s' \"\$out_noconf\" | grep -qi 'conflict'"
# Ages are pinned RELATIVE to now, never to a literal date: a fixture whose meaning is the
# gap between a stored time and the clock drifts into a different case as real time passes.
touch -t "$(date -v-9d +%Y%m%d%H%M)" "$CQH/LESSONS.md.conflict-OtherMac" 2>/dev/null || \
  touch -d '9 days ago' "$CQH/LESSONS.md.conflict-OtherMac"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CQH/skills/beta/SKILL.md.conflict-OtherMac" 2>/dev/null || \
  touch -d '2 days ago' "$CQH/skills/beta/SKILL.md.conflict-OtherMac"
out_conf20="$(CLAUDE_HOME="$CQH" SYNC_REPO="$CQR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#20 status names a top-level conflict copy" \
  "printf '%s' \"\$out_conf20\" | grep -q 'LESSONS.md.conflict-OtherMac'"
check "#20 status names a nested conflict copy" \
  "printf '%s' \"\$out_conf20\" | grep -q 'skills/beta/SKILL.md.conflict-OtherMac'"
check "#20 status says how old each copy is" \
  "printf '%s' \"\$out_conf20\" | grep -q '9 days'"
check "#20 status says what to do about them" \
  "printf '%s' \"\$out_conf20\" | grep -qi 'delete'"
# The copy must not be mistaken for ordinary config: it is excluded from staging, so a
# status that listed it as a pending change would be reporting a push that cannot happen.
check "#20 a conflict copy is still never staged for the other Mac" \
  "[ ! -e '$CQR/payload/LESSONS.md.conflict-OtherMac' ]"

section "== only one mutating run at a time (#21) =="
# The fswatch watcher fires a send on every edit, the launchd timer runs a full two-way
# sync, and either can overlap the other or a run started by hand. All three stage into the
# same payload and drive git in the same repo. Nothing serialized them.
LKH="$WORK/lock-home"; LKR="$WORK/lock-repo"; LOCK="$WORK/lock-dir"
mkdir -p "$LKH/skills/l" "$LKR/payload"
echo '{"hooks":{}}' > "$LKH/settings.json"; echo 'L' > "$LKH/skills/l/SKILL.md"
lockenv(){ echo "CLAUDE_HOME=$LKH SYNC_REPO=$LKR SYNC_LOCK=$LOCK SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_LOCK_WAIT=1"; }

# A LIVE holder blocks. The waiting run must decline rather than proceed, and must not have
# done any of the work.
sleep 60 & LIVE_PID=$!
mkdir -p "$LOCK"; printf '%s\n' "$LIVE_PID" > "$LOCK/pid"
out_lk="$(env $(lockenv) bash "$SCRIPT" push 2>&1)"; rc_lk=$?
check "#21 a run declines while another holds the lock" "[ $rc_lk -ne 0 ]"
check "#21 the refusal says another run has it"  "printf '%s' \"\$out_lk\" | grep -qi 'already running'"
check "#21 a blocked run does not stage anything" "[ ! -e '$LKR/payload/skills/l/SKILL.md' ]"

# status must NEVER be blocked: it is what the refusal tells you to run, and a diagnosis
# command that hangs on the very condition it diagnoses is worse than no diagnosis.
out_lkst="$(env $(lockenv) bash "$SCRIPT" status 2>&1)"; rc_lkst=$?
check "#21 status still runs while the lock is held" "[ $rc_lkst -eq 0 ]"
kill "$LIVE_PID" 2>/dev/null; wait "$LIVE_PID" 2>/dev/null

# A lock left by a run that CRASHED must be taken over, or the tool wedges permanently and
# every later sync is silently skipped.
DEAD_PID="$(bash -c 'echo $$')"          # a shell that has already exited
mkdir -p "$LOCK"; printf '%s\n' "$DEAD_PID" > "$LOCK/pid"
out_lkd="$(env $(lockenv) bash "$SCRIPT" push 2>&1)"; rc_lkd=$?
check "#21 a lock from a dead run is taken over" "[ $rc_lkd -eq 0 ]"
check "#21 the taken-over run does its work"     "[ -f '$LKR/payload/skills/l/SKILL.md' ]"

# Released on the way out, both ways. The failure path is the one that matters: if a run
# that dies keeps the lock, the FIRST network blip wedges syncing until someone notices.
check "#21 the lock is released after a run finishes" "[ ! -d '$LOCK' ]"
# The failing run has to be one that genuinely TAKES the lock and then dies inside it. An
# unknown command was the first attempt and proved nothing: it is rejected before any lock
# is taken, so the assertion passed against a lock that had never existed.
LKB="$WORK/lock-bare.git"; git init -q --bare -b main "$LKB"
LKGR="$WORK/lock-grepo"; git clone -q "$LKB" "$LKGR" 2>/dev/null
LKGH="$WORK/lock-ghome"; mkdir -p "$LKGH/skills/l"
echo 'L' > "$LKGH/skills/l/SKILL.md"; echo '{"hooks":{}}' > "$LKGH/settings.json"
CLAUDE_HOME="$LKGH" SYNC_REPO="$LKGR" SYNC_LOCK="$LOCK" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$LKGR" remote set-url origin "$WORK/lock-vanished.git"
echo 'edited' > "$LKGH/skills/l/SKILL.md"
out_lkf="$(CLAUDE_HOME="$LKGH" SYNC_REPO="$LKGR" SYNC_LOCK="$LOCK" SYNC_NO_NOTIFY=1 SYNC_LOCK_WAIT=1 bash "$SCRIPT" sync 2>&1)"; rc_lkf=$?
check "#21 a run that dies inside the lock still fails" "[ $rc_lkf -ne 0 ]"
check "#21 a run that dies does not keep the lock" "[ ! -d '$LOCK' ]"
# And the next run really is unblocked: with the lock retained this times out and dies.
git -C "$LKGR" remote set-url origin "$LKB"
out_lka="$(CLAUDE_HOME="$LKGH" SYNC_REPO="$LKGR" SYNC_LOCK="$LOCK" SYNC_NO_NOTIFY=1 SYNC_LOCK_WAIT=1 bash "$SCRIPT" sync 2>&1)"; rc_lka=$?
check "#21 the next run after a failure is not blocked" "[ $rc_lka -eq 0 ]"

section "== a brief outage is logged, a sustained one alerts (#22) =="
# An unreachable remote is now correctly told apart from a two-Mac conflict (#22's parent),
# but it still raised a desktop alert on the FIRST occurrence. A laptop changing networks
# produces a connection failure lasting milliseconds: the 2026-08-16 incident was exactly
# that. One benign instance and a real multi-hour GitHub outage arrive on the same path, so
# they have to be told apart by how LONG it has been failing, never by what kind of failure
# it is (L77). An alert that fires on every blip is an alert nobody reads, and it is the
# real outage that then goes unreported.
NOTED="$WORK/notified.log"
FAKENOTIFIER="$WORK/fake-notifier"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$NOTED" > "$FAKENOTIFIER"
chmod +x "$FAKENOTIFIER"
OUB="$WORK/outage-bare.git"; git init -q --bare -b main "$OUB"
OUR="$WORK/outage-repo"; git clone -q "$OUB" "$OUR" 2>/dev/null
OUH="$WORK/outage-home"; mkdir -p "$OUH/skills/o"
echo 'O' > "$OUH/skills/o/SKILL.md"; echo '{"hooks":{}}' > "$OUH/settings.json"
# NOTE: SYNC_NO_NOTIFY is deliberately NOT set for this section. Every other test disables
# notifications wholesale, which would make "did not alert" pass no matter what the code did.
# SYNC_NO_NOTIFY=0 is load-bearing and must be set explicitly: the suite exports
# SYNC_NO_NOTIFY=1 for everything at the top, so without this the notifier can never fire
# and "raises no alert" passes because alerts are switched off, not because the code chose
# to stay quiet. It did exactly that on the first run of this section.
ounotify(){ echo "CLAUDE_HOME=$OUH SYNC_REPO=$OUR SYNC_NOTIFIER=$FAKENOTIFIER SYNC_NO_NOTIFY=0"; }
env $(ounotify) bash "$SCRIPT" sync >/dev/null 2>&1
check "#22 a successful sync records when it last reached the repo" "[ -s '$OUR/.last-success' ]"

# A blip: the last success was moments ago, so this must be logged and must NOT alert.
git -C "$OUR" remote set-url origin "$WORK/outage-vanished.git"
echo 'edited' > "$OUH/skills/o/SKILL.md"
: > "$NOTED"
out_blip="$(env $(ounotify) SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync 2>&1)"; rc_blip=$?
check "#22 a brief outage still fails rather than reporting success" "[ $rc_blip -ne 0 ]"
check "#22 a brief outage raises no desktop alert" "[ ! -s '$NOTED' ]"
check "#22 a brief outage is still written to the log" \
  "printf '%s' \"\$out_blip\" | grep -qi 'could not reach'"

# The SAME failure, once it has been going on past the threshold, must alert. Only the age
# of the last success differs between this case and the one above.
: > "$NOTED"
out_sust="$(env $(ounotify) SYNC_OUTAGE_ALERT_AFTER=0 bash "$SCRIPT" sync 2>&1)"; rc_sust=$?
check "#22 a sustained outage fails too" "[ $rc_sust -ne 0 ]"
check "#22 a sustained outage does raise an alert" "[ -s '$NOTED' ]"
check "#22 a sustained outage says how long it has been failing" \
  "printf '%s' \"\$out_sust\" | grep -qi 'failing'"

# No recorded success at all cannot be called a brief blip, so it must alert rather than
# stay quiet: a message may claim only what its check actually measured (L11).
rm -f "$OUR/.last-success"; : > "$NOTED"
out_none="$(env $(ounotify) SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync 2>&1)"
check "#22 an outage with no recorded success alerts" "[ -s '$NOTED' ]"
check "#22 and says the duration is unknown rather than guessing" \
  "printf '%s' \"\$out_none\" | grep -qi 'no record'"

# A corrupt marker must not read as a recent success and silence a real outage (L50).
printf 'not-a-timestamp\n' > "$OUR/.last-success"; : > "$NOTED"
env $(ounotify) SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync >/dev/null 2>&1
check "#22 an unreadable marker does not silence the alert" "[ -s '$NOTED' ]"

# The watcher fires a SEND on every edit and never fetches, so if only the two-way sync
# stamps the clock, a Mac that is edited constantly but only syncs on its weekly timer reads
# as "last reached GitHub days ago" while its connection is perfectly fine, and the next
# harmless blip is then reported as a long outage. A successful push is equally good proof
# the repo was reachable, so it counts.
SNB="$WORK/send-clock-bare.git"; git init -q --bare -b main "$SNB"
SNR="$WORK/send-clock-repo"; git clone -q "$SNB" "$SNR" 2>/dev/null
SNH="$WORK/send-clock-home"; mkdir -p "$SNH/skills/s"
echo 'S' > "$SNH/skills/s/SKILL.md"; echo '{"hooks":{}}' > "$SNH/settings.json"
CLAUDE_HOME="$SNH" SYNC_REPO="$SNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
rm -f "$SNR/.last-success"        # so only the send under test can put it back
echo 'edited by the watcher' > "$SNH/skills/s/SKILL.md"
CLAUDE_HOME="$SNH" SYNC_REPO="$SNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send >/dev/null 2>&1
check "#22 a successful send also records that the repo was reachable" "[ -s '$SNR/.last-success' ]"
# The failure side: a send that never reaches the repo must record nothing, or the clock
# would be refreshed by the very outage it exists to measure.
git -C "$SNR" remote set-url origin "$WORK/send-clock-gone.git"
rm -f "$SNR/.last-success"
echo 'edited again' > "$SNH/skills/s/SKILL.md"
CLAUDE_HOME="$SNH" SYNC_REPO="$SNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send >/dev/null 2>&1 || true
check "#22 a send that cannot reach the repo records nothing" "[ ! -s '$SNR/.last-success' ]"

section "== verify says whether both Macs actually hold the same config (#23) =="
# Everything else in this tool reports on the PROCESS: whether a run reached the repo,
# whether a merge failed, whether a conflict copy is outstanding. Nothing reported the
# OUTCOME the product exists for, which is that the two Macs hold the same config, and the
# only evidence was that no error had appeared. .last-applied is gitignored, so the repo
# knew nothing about the other Mac at all: each Mac now PUBLISHES what it has applied.
VFB="$WORK/verify-bare.git"; git init -q --bare -b main "$VFB"
VFA="$WORK/verify-repoA"; git clone -q "$VFB" "$VFA" 2>/dev/null
VFHA="$WORK/verify-homeA"; mkdir -p "$VFHA/skills/v"
echo 'V1' > "$VFHA/skills/v/SKILL.md"; echo '{"hooks":{}}' > "$VFHA/settings.json"
CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#23 applying publishes a marker for this Mac" \
  "[ -s '$VFA/state/macA.applied' ]"
# The marker records the payload TREE, never HEAD. With HEAD the two Macs ping-pong for
# ever: A publishes a marker, which moves HEAD, so B sees a new commit, applies, publishes
# its own marker, which moves HEAD again. A marker-only commit leaves the payload tree
# untouched, so the exchange settles after one round.
check "#23 the marker records the payload tree, not the commit" \
  "grep -q \"\$(git -C '$VFA' rev-parse HEAD:payload)\" '$VFA/state/macA.applied'"
# The constraint the whole design turns on, found by bisecting 27 unrelated failures rather
# than by reasoning: a marker must never become a commit on the config branch. One that does
# is a commit the other Mac lacks, so the guard against publishing while behind reads it as
# behind and silently skips every send until somebody pulls.
check "#23 markers are never committed to the config branch" \
  "[ -z \"\$(git -C '$VFA' ls-files state)\" ]"
check "#23 markers do not add commits to the config branch" \
  "[ \"\$(git -C '$VFA' log --oneline -- state | wc -l | tr -d ' ')\" = 0 ]"
check "#23 the marker is published on its own ref instead" \
  "[ -n \"\$(git -C '$VFA' for-each-ref --format='%(refname)' refs/claude-sync-state)\" ]"

# A second Mac that has never applied must NOT be reported as being in agreement.
VFR="$WORK/verify-repoB"; git clone -q "$VFB" "$VFR" 2>/dev/null
VFHB="$WORK/verify-homeB"; mkdir -p "$VFHB"; echo '{"hooks":{}}' > "$VFHB/settings.json"
out_v1="$(CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1)"
check "#23 verify reports this Mac as up to date" \
  "printf '%s' \"\$out_v1\" | grep -qi 'up to date'"
# One Mac agreeing with itself is agreement with nobody, which is the same vacuous success
# the no-markers case exists to prevent. Caught on the REAL repo after shipping, where it
# printed "all 1 Mac(s) agree" while the second Mac had simply never published.
# Targets the VERDICT line, not the word "agree", which legitimately appears in the sentence
# explaining that agreement cannot be answered yet. The first version of this assertion
# banned the word and so failed on the correct message.
check "#23 a single published Mac gets no agreement verdict" \
  "! printf '%s' \"\$out_v1\" | grep -q 'Verified:'"
check "#23 a single published Mac says only itself has reported" \
  "printf '%s' \"\$out_v1\" | grep -qi 'only this Mac'"

# Now B applies too, and both must read as agreeing.
CLAUDE_HOME="$VFHB" SYNC_REPO="$VFR" SYNC_HOSTNAME=macB SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_v2="$(CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1)"
check "#23 verify names the other Mac"        "printf '%s' \"\$out_v2\" | grep -q 'macB'"
check "#23 verify says the two Macs agree"    "printf '%s' \"\$out_v2\" | grep -qi 'agree'"

# A changes the config and publishes. B has not applied it, so B is BEHIND, and verify must
# say so by name rather than reporting a clean bill of health.
echo 'V2 changed on A' > "$VFHA/skills/v/SKILL.md"
CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_v3="$(CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1)"
check "#23 verify reports the other Mac as behind"  "printf '%s' \"\$out_v3\" | grep -qi 'behind'"
# Asserts the NUMBER, not just the word: the count was first written as "commits since the
# marker's timestamp", which is a stand-in for the real quantity and goes wrong whenever the
# two Macs' clocks disagree. A test that only looked for the word "behind" passed on it.
check "#23 verify counts exactly one config change behind" \
  "printf '%s' \"\$out_v3\" | grep -q 'BEHIND by 1 config change'"
check "#23 a Mac that is behind is not called agreeing" \
  "! printf '%s' \"\$out_v3\" | grep -qi 'both Macs agree'"
check "#23 verify exits non-zero when they do not agree" \
  "! CLAUDE_HOME='$VFHA' SYNC_REPO='$VFA' SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash '$SCRIPT' verify >/dev/null 2>&1"

# No marker from anyone is UNKNOWN, never agreement. Finding nothing is the moment a clean
# verdict is most likely to be believed, and it is exactly when nothing has been checked.
# Built from a repo where nobody has EVER published, not by deleting local files: markers
# live on their own refs now, so a fresh clone re-fetches them and deleting the local copies
# proves nothing. The state being asserted is unchanged; only the way to reach it is.
VFCB="$WORK/verify-clean-bare.git"; git init -q --bare -b main "$VFCB"
VFC="$WORK/verify-repoC"; git clone -q "$VFCB" "$VFC" 2>/dev/null
git -C "$VFC" checkout -q -b main 2>/dev/null || true
mkdir -p "$VFC/payload/skills/v"; echo 'V' > "$VFC/payload/skills/v/SKILL.md"
git -C "$VFC" add -A
git -C "$VFC" -c user.name=t -c user.email=t@e commit -q -m "config with no marker ever published"
git -C "$VFC" push -q -u origin main
out_v4="$(CLAUDE_HOME="$VFHA" SYNC_REPO="$VFC" SYNC_HOSTNAME=macZ SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1 || true)"
check "#23 no markers at all does not claim agreement" \
  "! printf '%s' \"\$out_v4\" | grep -qi 'agree'"
check "#23 no markers at all says so plainly" \
  "printf '%s' \"\$out_v4\" | grep -qi 'no Mac has published'"

section "== outage decisions are recorded so the threshold can be judged (#24) =="
# The 3 hour cutoff deciding when a sync failure stops being logged quietly and starts
# alerting was chosen by judgement, not measurement, and both ways of being wrong are
# invisible: too low and it alerts on network blips until the alert is ignored, too high and
# a real outage sits unreported for most of a day. Recording which branch fired, and how long
# the outage had been running, is what makes the number answerable after real use.
OCB="$WORK/ocount-bare.git"; git init -q --bare -b main "$OCB"
OCR="$WORK/ocount-repo"; git clone -q "$OCB" "$OCR" 2>/dev/null
OCH="$WORK/ocount-home"; mkdir -p "$OCH/skills/o"
echo 'O' > "$OCH/skills/o/SKILL.md"; echo '{"hooks":{}}' > "$OCH/settings.json"
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$OCR" remote set-url origin "$WORK/ocount-gone.git"
echo 'edited' > "$OCH/skills/o/SKILL.md"
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync >/dev/null 2>&1 || true
check "#24 a quiet outage is recorded" "[ -s '$OCR/.outage-log' ]"
check "#24 the record says it stayed quiet" "grep -q 'quiet' '$OCR/.outage-log'"
echo 'edited again' > "$OCH/skills/o/SKILL.md"
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 SYNC_OUTAGE_ALERT_AFTER=0 bash "$SCRIPT" sync >/dev/null 2>&1 || true
check "#24 an alerting outage is recorded too" "grep -q 'alert' '$OCR/.outage-log'"
check "#24 the two decisions are kept apart" \
  "[ \"\$(grep -c 'quiet' '$OCR/.outage-log')\" = 1 ] && [ \"\$(grep -c 'alert' '$OCR/.outage-log')\" = 1 ]"
out_oc="$(CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#24 status reports the tally"     "printf '%s' \"\$out_oc\" | grep -qi 'outage'"
# The tally exists to judge the threshold, so it must not imply every record was judged under
# the CURRENT one. The two outages above were deliberately made under different thresholds
# (10800 then 0), so a summary quoting one number for all of them would be telling you
# something untrue about the data you are being asked to draw a conclusion from.
check "#24 each record carries the threshold it was judged under" \
  "grep -q ' 10800$' '$OCR/.outage-log' && grep -q ' 0$' '$OCR/.outage-log'"
check "#24 a mixed tally says the threshold changed" \
  "printf '%s' \"\$out_oc\" | grep -qi 'different threshold'"
check "#24 the tally names both counts"  "printf '%s' \"\$out_oc\" | grep -q '1 quiet' && printf '%s' \"\$out_oc\" | grep -q '1 alerted'"
# A run that reached the repo must not be recorded as an outage, or the tally that exists to
# judge the threshold is padded with every healthy sync and answers nothing.
git -C "$OCR" remote set-url origin "$OCB"
echo 'fine now' > "$OCH/skills/o/SKILL.md"
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#24 a healthy sync records no outage" \
  "[ \"\$(grep -c . '$OCR/.outage-log')\" = 2 ]"
# Failure path: a corrupt log must not crash status nor be silently reported as zero events.
printf 'garbage line with no fields\n' >> "$OCR/.outage-log"
out_ocbad="$(CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"; rc_ocbad=$?
check "#24 status survives a corrupt outage log"  "[ $rc_ocbad -eq 0 ]"
check "#24 and says a record could not be read"   "printf '%s' \"\$out_ocbad\" | grep -qi 'unreadable'"

section "== local state carried in from elsewhere is not trusted (#25) =="
# Four files now hold local state in the sync folder and none had a defined lifetime:
# .last-applied, .last-success, .outage-log and .sync-lock. All are gitignored, so a fresh
# clone starts without them, but a folder COPIED or RESTORED from a backup carries stale ones
# that are then trusted as current. Each drives a real decision, so a stale one is not
# cosmetic: a lock decides whether a run proceeds at all, and the clock decides whether a
# live outage is reported.
STB="$WORK/stale-bare.git"; git init -q --bare -b main "$STB"
STR2="$WORK/stale-repo"; git clone -q "$STB" "$STR2" 2>/dev/null
STH2="$WORK/stale-home"; mkdir -p "$STH2/skills/s"
echo 'S' > "$STH2/skills/s/SKILL.md"; echo '{"hooks":{}}' > "$STH2/settings.json"
CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1

# A lock whose recorded process is long gone AND which is older than any plausible run must
# not block. The pid could have been reused by an unrelated process on the machine the folder
# was restored onto, in which case the liveness test alone says "held" for ever.
STLOCK="$STR2/.sync-lock"; mkdir -p "$STLOCK"; printf '%s\n' "$$" > "$STLOCK/pid"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$STLOCK/pid" 2>/dev/null || touch -d '2 days ago' "$STLOCK/pid"
echo 'edited' > "$STH2/skills/s/SKILL.md"
out_st="$(CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NO_NOTIFY=1 SYNC_LOCK_WAIT=1 bash "$SCRIPT" sync 2>&1)"; rc_st=$?
check "#25 an ancient lock does not block a run" "[ $rc_st -eq 0 ]"
check "#25 and the run says it broke a stale lock" \
  "printf '%s' \"\$out_st\" | grep -qi 'stale lock'"

# The FUTURE is the hole, not the past. A clock that is merely old already alerts, because
# the gap exceeds the threshold by definition. A clock ahead of now produces a NEGATIVE gap,
# which is smaller than any threshold, so it reads as "synced moments ago" and silences the
# alert for as long as it stays ahead. A folder restored from a backup, or one carried off a
# machine whose clock was wrong, lands exactly there. The first version of this test aged the
# FILE while the code reads the timestamp written INSIDE it, so it passed for an unrelated
# reason and proved nothing; it is rewritten rather than kept.
git -C "$STR2" remote set-url origin "$WORK/stale-gone.git"
# Independent of the lock section above. Leaving that planted lock in place made every sync
# here die with "already running" and notify, so the clock checks were measuring the LOCK:
# the future-clock check passed for that reason, and only the control below revealed it.
rm -rf "$STR2/.sync-lock"
NOTED2="$WORK/notified2.log"; : > "$NOTED2"
FAKEN2="$WORK/fake-notifier2"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> "%s"\n' "$NOTED2" > "$FAKEN2"; chmod +x "$FAKEN2"
printf '%s\n' "$(( $(date +%s) + 86400 ))" > "$STR2/.last-success"   # a day in the future
echo 'edit again' > "$STH2/skills/s/SKILL.md"
out_fut="$(CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NOTIFIER="$FAKEN2" SYNC_NO_NOTIFY=0 \
  SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync 2>&1 || true)"
check "#25 a clock in the future does not silence an outage" "[ -s '$NOTED2' ]"
check "#25 and it says the record was not usable" \
  "printf '%s' \"\$out_fut\" | grep -qi 'no record'"
# Control, so the rule above cannot be satisfied by simply alerting on everything: an
# ordinary recent success must still keep a blip quiet.
: > "$NOTED2"
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$STR2/.last-success"
echo 'edit once more' > "$STH2/skills/s/SKILL.md"
CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NOTIFIER="$FAKEN2" SYNC_NO_NOTIFY=0 \
  SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync >/dev/null 2>&1 || true
check "#25 a genuinely recent success still keeps a blip quiet" "[ ! -s '$NOTED2' ]"

section "== a Mac that no longer exists does not hold verify hostage (#26) =="
# The markers are keyed on hostname, which is a MUTABLE string, so renaming or reinstalling
# a Mac does not move its marker, it mints a second one and abandons the first. Nothing ever
# removed the old one, so verify reported that ghost as behind for ever and the verdict could
# never be positive again. A check that can only ever say no stops being read.
GHB="$WORK/ghost-bare.git"; git init -q --bare -b main "$GHB"
GHR="$WORK/ghost-repo"; git clone -q "$GHB" "$GHR" 2>/dev/null
GHH="$WORK/ghost-home"; mkdir -p "$GHH/skills/g"
echo 'G' > "$GHH/skills/g/SKILL.md"; echo '{"hooks":{}}' > "$GHH/settings.json"
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
# A second Mac publishes, then goes away for good and never applies anything again.
GHR2="$WORK/ghost-repo2"; git clone -q "$GHB" "$GHR2" 2>/dev/null
GHH2="$WORK/ghost-home2"; mkdir -p "$GHH2"; echo '{"hooks":{}}' > "$GHH2/settings.json"
CLAUDE_HOME="$GHH2" SYNC_REPO="$GHR2" SYNC_HOSTNAME=macGone SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
echo 'G changed' > "$GHH/skills/g/SKILL.md"
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
# Age the departed Mac's marker past the point where it can mean anything.
GHREF="refs/claude-sync-state/macGone"
out_gh="$(CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 \
  SYNC_MAC_RETIRE_AFTER=0 bash "$SCRIPT" verify 2>&1 || true)"
check "#26 a long-silent Mac is called retired, not behind" \
  "printf '%s' \"\$out_gh\" | grep -qi 'retired'"
check "#26 a retired Mac is not counted as behind" \
  "! printf '%s' \"\$out_gh\" | grep -q 'macGone: BEHIND'"
check "#26 and it no longer blocks the verdict" \
  "CLAUDE_HOME='$GHH' SYNC_REPO='$GHR' SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 SYNC_MAC_RETIRE_AFTER=0 bash '$SCRIPT' verify >/dev/null 2>&1"
# Retired must NOT mean forgotten: it still has to be named, or a Mac that genuinely fell
# behind quietly disappears from the report that exists to notice exactly that.
check "#26 a retired Mac is still named"  "printf '%s' \"\$out_gh\" | grep -q 'macGone'"
# The control: with a normal retirement window that same Mac is simply behind, so the rule
# cannot be satisfied by calling every absent Mac retired.
out_gh2="$(CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1 || true)"
check "#26 a recently seen Mac is still reported as behind" \
  "printf '%s' \"\$out_gh2\" | grep -q 'macGone: BEHIND'"
# And a way to drop one deliberately, since a Mac you know is gone should not need a wait.
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" forget-mac macGone >/dev/null 2>&1
check "#26 forget-mac removes the marker" \
  "[ -z \"\$(git -C '$GHR' for-each-ref --format='%(refname)' '$GHREF')\" ]"
check "#26 forget-mac refuses to remove this Mac's own marker" \
  "! CLAUDE_HOME='$GHH' SYNC_REPO='$GHR' SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash '$SCRIPT' forget-mac macNow >/dev/null 2>&1"

section "== the suite can run one section at a time (#27) =="
# A full run takes over three minutes, so verifying a one line change cost the same as
# verifying a rewrite. That is not just slow, it changes how the tool gets built: on
# 2026-08-16 it forced about a dozen full runs and quietly encouraged reasoning in place of
# testing, which is where most of that session's defects came from.
# This section runs the suite as a SUBPROCESS, so it must never recurse: the child is given
# a filter that cannot match this section's own heading.
# NEVER spawn from inside a run that is itself a child. A filtered child carries
# SUITE_FILTERED in its environment, so its subrun would skip extraction, run the WHOLE
# suite, reach this section again and spawn further, without bound. That is not theoretical:
# it filled this Mac with runaway suite processes on 2026-08-17 and had to be killed by hand.
if [ -n "${SUITE_FILTERED:-}" ]; then
  echo "  skipped: #27 subruns (already inside a filtered run; spawning here would recurse)"
else
SUBOUT="$WORK/subrun.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL="sync (two-way) over a local fake remote" bash "$SCRIPT_SELF" > "$SUBOUT" 2>&1; rc_sub=$?
check "#27 a stopped-early run still reports a total" "grep -q '^PASS=' '$SUBOUT'"
check "#27 it reaches the named section"       "grep -q 'sync (two-way) over a local fake remote' '$SUBOUT'"
check "#27 it stops after it"                  "! grep -q 'install-autosync writes a receive-timer' '$SUBOUT'"
# The whole point is speed, so assert it did less rather than trusting that it did.
sub_total="$(grep -o 'PASS=[0-9]*' "$SUBOUT" | head -1 | cut -d= -f2)"
check "#27 a stopped-early run does less work" "[ \"\${sub_total:-99999}\" -lt 200 ]"
# And it must be HONEST: the sections build on each other, so a partial run that produced
# failures the code did not cause would be worse than the slow full run it replaces.
check "#27 a stopped-early run is still green" "[ $rc_sub -eq 0 ]"
# #34: the depth limit is only real if a real spawn site actually increments it. Asserted on a
# child this section was already paying for, and on the child SAYING so, because a limit whose
# counter never moves reads exactly like one that works (L3: built is not wired).
check "#34 a spawned run announces the depth it is running at" "grep -q 'depth 1' '$SUBOUT'"
# A name matching NOTHING is an error, never a silent green: a run that checked zero things
# and exits 0 is indistinguishable from one where everything passed.
SUBOUT2="$WORK/subrun2.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL=zzz-no-such-section bash "$SCRIPT_SELF" > "$SUBOUT2" 2>&1; rc_sub2=$?
check "#27 a name matching nothing fails"      "[ $rc_sub2 -ne 0 ]"
check "#27 and says it matched no section"     "grep -qi 'matched no section' '$SUBOUT2'"
# An extraction that produces invalid shell must REFUSE, not run the broken script and report
# its parse errors as failures of the code under test. Driven through a named seam rather
# than by racing a real breakage, so the refusal is proven instead of assumed.
SUBOUT3="$WORK/subrun3.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_EXTRACT_BREAK=1 SECTION_UNTIL="push" bash "$SCRIPT_SELF" > "$SUBOUT3" 2>&1; rc_sub3=$?
check "#27 an unparseable extraction refuses to run"  "[ $rc_sub3 -ne 0 ]"
check "#27 and blames the extractor, not the code"    "grep -qi 'bug in the section extractor' '$SUBOUT3'"
check "#27 and reports no test results at all"        "! grep -q '^PASS=' '$SUBOUT3'"
# The runner now sits between every future change and its test result, so a silent DROP is
# its worst failure: a green partial run that quietly omitted a section reads as proof and is
# not. Assert that every section heading up to the named one actually appears in the output,
# derived from the file itself rather than from a list somebody has to remember to update.
_want="$(awk '/^section "/{print; if (index($0, "sync (two-way) over a local fake remote")>0) exit}' "$SCRIPT_SELF" \
         | sed 's/^section "//; s/"$//')"
_missing=""
while IFS= read -r _h; do
  [ -n "$_h" ] || continue
  grep -qF -- "$_h" "$SUBOUT" || _missing="$_missing[$_h]"
done <<EOF
$_want
EOF
check "#27 it runs every section up to the named one, none skipped" "[ -z \"\$_missing\" ]"
check "#27 the completeness check had sections to check" \
  "[ \"\$(printf '%s' \"\$_want\" | grep -c .)\" -ge 3 ]"
# An assertion that a child SAYS it skipped was written here and removed: the child above
# stops before this section, so it never reaches the guard and the check could only ever
# fail. Asserting it properly needs a child that runs all the way to here, which is a near
# full suite inside a suite. The guard was instead verified by measurement: a filtered run
# reaching this section spawns one child and no grandchildren.
fi

section "== a pulled script that parses but cannot run is refused (#28) =="
# The self-update gate only checked that the pulled script PARSES. A script can parse and
# still die on its first real step: an unbound variable under `set -u`, a helper that was
# renamed, a command that is not on this Mac. That path then executes automatically on both
# Macs with nobody watching, and a bad version breaks the very thing that would deliver the
# fix. The 2026-08-16 lock change broke exactly this path and was caught only by luck.
SUBARE="$WORK/su-bare.git"; git init -q --bare -b main "$SUBARE"
SUA="$WORK/su-repoA"; git clone -q "$SUBARE" "$SUA" 2>/dev/null
cp "$SCRIPT" "$SUA/claude-sync"
mkdir -p "$SUA/payload/hooks"; echo '#!/bin/sh' > "$SUA/payload/hooks/dummy.sh"
git -C "$SUA" add -A && git -C "$SUA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$SUA" push -q -u origin main
SUB="$WORK/su-repoB"; git clone -q "$SUBARE" "$SUB" 2>/dev/null
SUBH="$WORK/su-homeB"; mkdir -p "$SUBH"; echo '{"hooks":{}}' > "$SUBH/settings.json"
cp "$SCRIPT" "$SUB/claude-sync"
# Valid shell that dies the moment it actually runs. Injected EARLY, before any work: the
# first attempt appended it after the dispatch, where the script did its entire job
# successfully and only failed on the last line, so the pull completed normally and the test
# would have demonstrated nothing. Verified separately: this version parses and exits 127.
awk 'NR==30{print "a_helper_that_does_not_exist_on_this_mac"} {print}' "$SCRIPT" > "$SUA/claude-sync"
git -C "$SUA" add claude-sync && git -C "$SUA" -c user.name=t -c user.email=t@e commit -q -m "push a runnable-looking but broken script" && git -C "$SUA" push -q
check "#28 the broken version really does still parse" "bash -n '$SUA/claude-sync' 2>/dev/null"
out_su="$(CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1 || true)"
check "#28 a pulled script that cannot run is refused" \
  "printf '%s' \"\$out_su\" | grep -qi 'cannot complete a run'"
# Distinct from the parse failure, which already had its own message. Two different faults
# reported identically would send the diagnosis to the wrong place.
check "#28 it is not reported as a parse failure" \
  "! printf '%s' \"\$out_su\" | grep -qi 'does not parse'"
check "#28 and it says the older copy is still in use" \
  "printf '%s' \"\$out_su\" | grep -qi 'kept the copy already running'"
# The control: a pulled script that is FINE must still be accepted, or the gate would be
# satisfied by refusing every update, which protects nothing and breaks syncing entirely.
SUC="$WORK/su-repoC"; git clone -q "$SUBARE" "$SUC" 2>/dev/null
SUCH="$WORK/su-homeC"; mkdir -p "$SUCH"; echo '{"hooks":{}}' > "$SUCH/settings.json"
cp "$SCRIPT" "$SUC/claude-sync"
git -C "$SUA" checkout -q -- claude-sync 2>/dev/null || cp "$SCRIPT" "$SUA/claude-sync"
cp "$SCRIPT" "$SUA/claude-sync"; printf '\n# a harmless comment\n' >> "$SUA/claude-sync"
git -C "$SUA" add claude-sync && git -C "$SUA" -c user.name=t -c user.email=t@e commit -q -m "a good script" && git -C "$SUA" push -q
out_suok="$(CLAUDE_HOME="$SUCH" SYNC_REPO="$SUC" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1 || true)"
check "#28 a healthy pulled script is still accepted" \
  "! printf '%s' \"\$out_suok\" | grep -qi 'cannot complete a run'"

section "== a clock jump must not break a live lock (#29) =="
# Of the eleven places the tool reads the clock, ten only affect what it SAYS. One changes
# what it DOES: the lock is broken when it looks older than the ceiling, so a clock jumping
# forward (a correction, a timezone change, a wake from sleep) makes a live lock look ancient
# and lets a second run start on top of a running one, which is the collision #21 exists to
# prevent. Wedging is now detectable, since #22 alerts after hours without a successful sync;
# a silent collision is not. So the safe direction is to refuse to break a lock this machine
# can still see running, no matter what the clock says.
CJH="$WORK/clockjump-home"; CJR="$WORK/clockjump-repo"; CJLOCK="$WORK/clockjump-lock"
mkdir -p "$CJH/skills/c" "$CJR/payload"
echo 'C' > "$CJH/skills/c/SKILL.md"; echo '{"hooks":{}}' > "$CJH/settings.json"
cjenv(){ echo "CLAUDE_HOME=$CJH SYNC_REPO=$CJR SYNC_LOCK=$CJLOCK SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_LOCK_WAIT=1"; }
# A lock held by a LIVE process on THIS machine, made to look ancient.
sleep 120 & CJ_LIVE=$!
mkdir -p "$CJLOCK"; printf '%s\n' "$CJ_LIVE" > "$CJLOCK/pid"
printf '%s\n' "$(hostname -s)" > "$CJLOCK/host"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CJLOCK/pid" 2>/dev/null || touch -d '2 days ago' "$CJLOCK/pid"
out_cj="$(env $(cjenv) bash "$SCRIPT" push 2>&1)"; rc_cj=$?
check "#29 an ancient lock whose owner is ALIVE here is not broken" "[ $rc_cj -ne 0 ]"
check "#29 and the run declines rather than proceeding" \
  "printf '%s' \"\$out_cj\" | grep -qi 'already running'"
kill "$CJ_LIVE" 2>/dev/null; wait "$CJ_LIVE" 2>/dev/null
# Control: the same ancient lock from ANOTHER machine must still be broken, or #25 regresses
# and a restored folder wedges syncing for good.
rm -rf "$CJLOCK"; mkdir -p "$CJLOCK"
sleep 120 & CJ_LIVE2=$!
printf '%s\n' "$CJ_LIVE2" > "$CJLOCK/pid"
printf '%s\n' "some-other-mac" > "$CJLOCK/host"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$CJLOCK/pid" 2>/dev/null || touch -d '2 days ago' "$CJLOCK/pid"
out_cj2="$(env $(cjenv) bash "$SCRIPT" push 2>&1)"; rc_cj2=$?
check "#29 an ancient lock from ANOTHER machine is still broken" "[ $rc_cj2 -eq 0 ]"
kill "$CJ_LIVE2" 2>/dev/null; wait "$CJ_LIVE2" 2>/dev/null
# Control: a dead owner on this machine is still broken promptly, with no waiting for age.
rm -rf "$CJLOCK"; mkdir -p "$CJLOCK"
printf '%s\n' "$(bash -c 'echo $$')" > "$CJLOCK/pid"
printf '%s\n' "$(hostname -s)" > "$CJLOCK/host"
rc_cj3=0; env $(cjenv) bash "$SCRIPT" push >/dev/null 2>&1 || rc_cj3=$?
check "#29 a dead owner on this machine is still broken at once" "[ $rc_cj3 -eq 0 ]"
# A check that the tool records the machine in its own lock was written here and removed: it
# read "no lock dir, or it has a host file", and the lock is always released by the time the
# run ends, so the first half was always true and it asserted nothing. The behaviour it stood
# for is already proven by the two checks above, which can only pass if the machine is
# recorded and consulted.

section "== the README documents every local state file (#30) =="
# Six things now hold state outside payload/, four of them added on 2026-08-17, and nothing
# named them in one place. Each drives a real decision (whether sending is safe, whether an
# outage alerts, whether a run proceeds at all), so anyone diagnosing odd behaviour had to
# read the whole script to learn what exists. The list is DERIVED from the code rather than
# kept by hand, or it silently drifts the first time somebody adds a seventh (L41).
_README="$(dirname "$SCRIPT")/README.md"
check "#30 the README has a state section" "grep -qi 'Local state' '$_README'"
# Derived from the code's OWN top-level definitions (any variable whose value lives under
# the repo), so adding a seventh is caught automatically. payload is excluded because it is
# the synced content itself, documented at length already, not local state.
_statepaths(){
  grep -E '^[A-Z_]+="[^"]*\$SYNC_REPO/' "$SCRIPT" \
    | grep -oE '\$SYNC_REPO/[^"}]*' | sed 's|\$SYNC_REPO/||' | grep -v '^payload$' | sort -u
  grep -oE 'refs/claude-sync-state' "$SCRIPT" | sort -u
}
_undocumented=""
while IFS= read -r _sv; do
  [ -n "$_sv" ] || continue
  grep -qF -- "$_sv" "$_README" || _undocumented="$_undocumented[$_sv]"
done <<EOF
$(_statepaths)
EOF
check "#30 every state file the code defines is documented" "[ -z \"\$_undocumented\" ]"
# The derivation must actually have found things, or the check above compares nothing against
# nothing and passes, which is the failure this session kept running into.
check "#30 the derivation found the state files to check" \
  "[ \"\$(_statepaths | grep -c .)\" -ge 5 ]"

section "== a suite run refuses to nest without bound (#34) =="
# #27 let the suite run itself as a subprocess and 45528c7 fixed one way that recursed without
# bound, by skipping subruns inside an already-filtered run. That protection was one flag read
# correctly, proven by a single observation, and its own check had to be removed because the
# child stopped before ever reaching the guard. The SHAPE stayed: anything running the suite
# from inside the suite can multiply, and a process explosion presents as slowness, so nobody
# investigates (seventeen of them were found by accident on 2026-08-17).
#
# A depth counter makes the whole class impossible instead of that one instance, and it is
# reachable in milliseconds: the refusal is at the TOP of the script, so proving it needs no
# suite inside a suite at all, which is what made the old check untestable.
#
# The child is given SECTION_UNTIL as well, and that is not decoration. Without it, a child that
# is NOT refused runs the whole suite, reaches this very section and spawns further, so the
# state this test exists to catch presents as a process explosion rather than as a red check.
# It did exactly that when this was first written. Bounded, an unrefused child instead runs one
# cheap section and exits 0, and every assertion below then fails in the ordinary way.
#
# It also pins WHERE the refusal has to live. SECTION_UNTIL re-executes the suite from a temp
# copy, so a depth guard placed after that handling would never be reached by a filtered run;
# a child refused while carrying a filter proves the guard sits ahead of it.
#
# SUITE_FILTERED is CLEARED for the child, and that is the sharpest edge here. This section can
# itself be reached inside a filtered run, and a filtered run exports that flag to everything it
# starts. A child inheriting it skips the section filter above, runs the WHOLE suite, arrives
# back at this section and spawns again, one level at a time, for ever. It is not a wide
# explosion that a process count would catch: it is a slow chain that looks exactly like a
# suite that is merely taking a while, which is the whole reason #31 and #34 both exist.
_deep(){ SUITE_DEPTH="$1" SUITE_FILTERED= SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1; }

_d2="$(_deep 2)"; _d2_rc=$?
check "#34 a run past the depth limit refuses to run at all" "[ '$_d2_rc' -ne 0 ]"
check "#34 the refusal says how deep it was asked to go" "printf '%s' \"\$_d2\" | grep -q 'depth 2'"
# It must refuse EARLY, not run the suite and complain afterwards: a refusal that still pays for
# a full run is not a limit on anything. A real run prints per-section headings and a PASS= line.
check "#34 it refuses before running any checks" "! printf '%s' \"\$_d2\" | grep -q '^PASS='"

# A value that cannot be compared must never land on the permissive side of a threshold (L50).
# `[ abc -gt 1 ]` is a shell ERROR, not a false, and this suite runs without `set -e`, so an
# unvalidated compare would let a garbage depth through as "not too deep" and the limit would be
# off precisely when the environment is wrong.
_dj="$(_deep abc)"; _dj_rc=$?
check "#34 a depth that is not a number is refused, not waved through" "[ '$_dj_rc' -ne 0 ]"
check "#34 the refusal names the value it could not read" "printf '%s' \"\$_dj\" | grep -q 'abc'"
_dn="$(_deep -1)"; _dn_rc=$?
check "#34 a negative depth is refused too" "[ '$_dn_rc' -ne 0 ]"

# Derived from the script rather than from a list of the spawn sites that were converted, so a
# NEW spawn site cannot arrive unnoticed (L96). The pattern is BUILT from pieces so the literal
# never appears in this file: a guard that matches its own assertion line is satisfied by itself.
_selfspawn_pat="bash \"\$SCRIPT""_SELF\""
_undeep=""
while IFS= read -r _sl; do
  [ -n "$_sl" ] || continue
  case "$_sl" in *SUITE_DEPTH=*) ;; *) _undeep="$_undeep[$_sl]" ;; esac
done <<EOF
$(grep -nF "$_selfspawn_pat" "$SCRIPT_SELF")
EOF
check "#34 every line that spawns the suite carries a depth" "[ -z \"\$_undeep\" ]"
# Or the loop above compares nothing against nothing and passes while every spawn is unguarded.
check "#34 the derivation found the spawn sites to check" \
  "[ \"\$(grep -cF \"\$_selfspawn_pat\" '$SCRIPT_SELF')\" -ge 3 ]"

section "== a run that hangs fails on a deadline instead of waiting (#31) =="
# A wait with no deadline cannot fail, it can only hang, and a hang is WORSE than a failure
# because it is indistinguishable from slowness (L110). This suite had no time bound at all, and
# on 2026-08-17 a stalled run went unexamined for eight minutes for exactly that reason. Twice
# more while this was being written: a recursing run looked simply slow both times.
#
# Driven through a named seam that hangs in a chosen section, rather than by waiting for a real
# stall, so the deadline is PROVEN rather than assumed. The child hangs in the very first
# section, so this costs about as long as the deadline it sets.
# Counted BEFORE anything is spawned, because this run has a watchdog of its own and an
# assertion that none exist at all can only ever fail. What has to be true is that the children
# below leave none of THEIRS behind.
_wd_before="$(pgrep -f suite-deadline-watchdog 2>/dev/null | wc -l | tr -d ' ')"
_t0="$(date +%s)"
_hang="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_FILTERED= SUITE_TIMEOUT=6 SUITE_HANG_IN=push bash "$SCRIPT_SELF" 2>&1)"; _hang_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
check "#31 a hung run ends instead of waiting for ever" "[ '$_hang_rc' -ne 0 ]"
# 30s against a 6s deadline. Deliberately not a tight bound: what this has to catch is the run
# taking as long as whatever it was sitting in, which is what happened when only the run itself
# was killed and its children were left holding the output open.
check "#31 it ends near its deadline rather than long after" "[ '$_elapsed' -lt 30 ]"
check "#31 it says plainly that it timed out"   "printf '%s' \"\$_hang\" | grep -q 'TIMED OUT'"
check "#31 it names the section it died in"     "printf '%s' \"\$_hang\" | grep -q 'push'"
# The whole point is that a hang stops reading as an ordinary run, so it must never leave behind
# the summary line that means everything passed.
check "#31 a hung run is never reported as green" "! printf '%s' \"\$_hang\" | grep -q 'FAIL=0'"

# The other half, and the one that would do real damage if it were wrong: a deadline that fires
# on a HEALTHY run turns every ordinary run into a false failure. A guard has to be seen not
# firing when it should not, not only firing when it should.
_okrun="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_FILTERED= SECTION_UNTIL=push SUITE_TIMEOUT=300 bash "$SCRIPT_SELF" 2>&1)"; _okrun_rc=$?
check "#31 a healthy run is not killed by its own deadline" "! printf '%s' \"\$_okrun\" | grep -q 'TIMED OUT'"
check "#31 and still reports its result"        "[ '$_okrun_rc' -eq 0 ]"

# A watchdog that outlives the run it watches is holding a process id that the system is free to
# hand to something else, and it kills what it finds there. Each one exits within a poll of its
# own run ending, so this waits a few seconds for that rather than reading the instant after.
_wd_now="$_wd_before"
_wd_wait=0
while [ "$_wd_wait" -lt 10 ]; do
  _wd_now="$(pgrep -f suite-deadline-watchdog 2>/dev/null | wc -l | tr -d ' ')"
  [ "$_wd_now" -le "$_wd_before" ] && break
  sleep 1; _wd_wait=$((_wd_wait + 1))
done
check "#31 the runs above left no watchdog of their own behind" "[ '$_wd_now' -le '$_wd_before' ]"

section "== only one suite run at a time (#32) =="
# Nothing stopped several copies of this suite running at once. Three did on 2026-08-17, competing
# for the same machine, and the only symptom was that output appeared to stall. It matters twice:
# every run gets slower, and the timings those runs produce are then used to reason about the code
# (the stale lock ceiling in #25 was set from a measured sync duration). A number measured while
# two other suites are running is not the number anyone thinks it is.
#
# Every fixture below points the run at a THROWAWAY lock path, so no test can take, break or wait
# on the lock a real run is using (L2). The planted locks are built here rather than by running a
# second suite, so each state is constructed exactly rather than raced for.
_lockdir="$WORK/locks"; mkdir -p "$_lockdir"
_mklock(){   # path pid host started-epoch
  rm -rf "$1"; mkdir -p "$1"
  printf '%s\n' "$2" > "$1/pid"; printf '%s\n' "$3" > "$1/host"; printf '%s\n' "$4" > "$1/started"
}
_try_lock(){ # lockpath [depth]
  SUITE_LOCK="$1" SUITE_DEPTH="${2:-0}" SUITE_FILTERED= SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1
}
_now="$(date +%s)"
_thishost="$(hostname)"

# Held by a process that is genuinely alive on this machine: this very suite. Refusing is what #32
# asks for, and refusing is only useful if it says WHO and for HOW LONG, or the person is told to
# wait for something they cannot find.
_mklock "$_lockdir/live" "$$" "$_thishost" "$((_now - 30))"
_t0="$(date +%s)"
_held="$(_try_lock "$_lockdir/live")"; _held_rc=$?
_held_elapsed=$(( $(date +%s) - _t0 ))
check "#32 a second run does not start while one is going" "[ '$_held_rc' -ne 0 ]"
check "#32 it names the run that holds the lock"  "printf '%s' \"\$_held\" | grep -q '$$'"
check "#32 it says how long that run has been going" "printf '%s' \"\$_held\" | grep -qE '[0-9]+s'"
# Refuse, never queue: a run that waits silently is the stall this issue was filed about.
check "#32 it refuses rather than queueing behind it" "[ '$_held_elapsed' -lt 20 ]"
check "#32 and runs none of the checks"           "! printf '%s' \"\$_held\" | grep -q '^PASS='"

# A crashed run must not wedge the suite for good. The owner being gone is the evidence, not the
# clock, because this lock only ever holds a process id from THIS machine.
_mklock "$_lockdir/dead" "99999999" "$_thishost" "$((_now - 5))"
_dead="$(_try_lock "$_lockdir/dead")"; _dead_rc=$?
check "#32 a lock whose owner is gone is taken over" "[ '$_dead_rc' -eq 0 ]"
check "#32 and says it took it over"                 "printf '%s' \"\$_dead\" | grep -qi 'took over'"

# A lock carried in from ELSEWHERE (a restored folder, a shared temp dir) records a process id that
# means nothing here, so age is the only evidence available. Same split as claude-sync #25 and #29.
_mklock "$_lockdir/foreign-old" "$$" "some-other-mac" "$((_now - 99999))"
_fold="$(_try_lock "$_lockdir/foreign-old")"; _fold_rc=$?
check "#32 an ancient lock from another machine is broken" "[ '$_fold_rc' -eq 0 ]"
_mklock "$_lockdir/foreign-new" "$$" "some-other-mac" "$((_now - 5))"
_fnew="$(_try_lock "$_lockdir/foreign-new")"; _fnew_rc=$?
check "#32 a fresh lock from another machine is respected" "[ '$_fnew_rc' -ne 0 ]"

# The one that would break everything if it were wrong. #27 runs the suite as a subprocess, so a
# nested run meeting its own parent's lock would refuse and every one of those checks would fail.
# Depth is what tells them apart, which is why #34 had to land first.
_nested="$(_try_lock "$_lockdir/live" 1)"; _nested_rc=$?
check "#32 a nested run does not fight its parent for the lock" "[ '$_nested_rc' -eq 0 ]"

# A run that finishes must not leave the lock standing, or the next one refuses for ever.
check "#32 a finished run releases its lock" "[ ! -d '$_lockdir/dead' ] || [ ! -f '$_lockdir/dead/pid' ]"

section "== status notices processes the tool left running (#33) =="
# Seventeen suite processes were running and spawning each other on 2026-08-17, found only because
# Dan asked an unrelated question about a monitor. Before that they had silently been making every
# run take about twice as long, and those timings were used to reason about the code. The symptom
# is indistinguishable from ordinary slowness, so nobody investigates.
#
# The process list comes through one seam so this never depends on, or reports, what happens to be
# running on the real machine (L2). A real watcher IS running here while these tests execute, and
# the empty-fixture case below is the control proving the seam is actually consulted rather than
# silently missed, which would leave every check passing against live processes (L143).
PSH="$WORK/ps-home"; PSR="$WORK/ps-repo"
mkdir -p "$PSH" "$PSR/payload"; echo '{"hooks":{}}' > "$PSH/settings.json"
_status_with(){ SYNC_PS_FIXTURE="$1" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1; }

# One watcher, with the helper it forks. This is the ordinary healthy machine and must be silent,
# or a line appears on every status and stops being read before a real pile-up ever shows up.
cat > "$WORK/ps-healthy" <<'PSEOF'
  501     1 03:11:02 /bin/bash /Users/x/claude-config-sync/claude-sync watch
  502   501 03:11:02 /bin/bash /Users/x/claude-config-sync/claude-sync watch
  777     1 00:00:04 /bin/bash /Users/x/claude-config-sync/tests/test-claude-sync.sh
PSEOF
_ps_ok="$(_status_with "$WORK/ps-healthy")"
check "#33 one watcher and one run are not reported" \
  "! printf '%s' \"\$_ps_ok\" | grep -qi 'left running\|stray'"

# Three separate watchers. A count alone would catch this one.
cat > "$WORK/ps-many" <<'PSEOF'
  501     1 03:11:02 /bin/bash /Users/x/claude-config-sync/claude-sync watch
  601     1 01:02:03 /bin/bash /Users/x/claude-config-sync/claude-sync watch
  701     1 00:09:00 /bin/bash /Users/x/claude-config-sync/claude-sync watch
PSEOF
_ps_many="$(_status_with "$WORK/ps-many")"
check "#33 several watchers are reported"        "printf '%s' \"\$_ps_many\" | grep -qi 'watcher'"
check "#33 and each one's age is given"          "printf '%s' \"\$_ps_many\" | grep -q '03:11:02'"
check "#33 and the process ids are named"        "printf '%s' \"\$_ps_many\" | grep -q '601'"

# The case a count CANNOT catch, and the reason this counts roots and depth instead. A run that
# spawned a run that spawned a run is one root nested deep, and the pile grows one process at a
# time: the real runaway peaked at seven and an alarm set at six never fired once.
cat > "$WORK/ps-chain" <<'PSEOF'
  800     1 00:20:00 /bin/bash /Users/x/claude-config-sync/tests/test-claude-sync.sh
  801   800 00:15:00 /bin/bash /Users/x/claude-config-sync/tests/test-claude-sync.sh
  802   801 00:10:00 /bin/bash /Users/x/claude-config-sync/tests/test-claude-sync.sh
  803   802 00:05:00 /bin/bash /Users/x/claude-config-sync/tests/test-claude-sync.sh
PSEOF
_ps_chain="$(_status_with "$WORK/ps-chain")"
check "#33 a run nested inside a run is reported" "printf '%s' \"\$_ps_chain\" | grep -qi 'test run'"
check "#33 and it says how deeply they are nested" "printf '%s' \"\$_ps_chain\" | grep -qi 'deep'"

# The control (L143): an EMPTY listing must report nothing even though this machine really does
# have a watcher running right now. If the seam were ignored, this check would fail against the
# live process table, which is the only thing that can tell a working stub from one that missed.
: > "$WORK/ps-none"
_ps_none="$(_status_with "$WORK/ps-none")"
check "#33 nothing running is reported as nothing" \
  "! printf '%s' \"\$_ps_none\" | grep -qi 'left running\|watcher\|test run'"

section "== the suite never touches a real shell rc =="
check "SYNC_ZSHRC is redirected suite-wide"  "[ \"\$SYNC_ZSHRC\" = '$WORK/zshrc-guard' ]"
check "the guard file stayed inside the temp dir" "[ ! -e \"\$HOME/.zshrc.claude-sync-test\" ]"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
