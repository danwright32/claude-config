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

# Where this suite keeps its OWN scratch, which is the same directory the tool keeps its own in
# (claude-config#116). The temp root belongs to the whole machine (113,912 entries measured on
# this Mac, 25 of them ours), and the sweep that reclaims abandoned scratch has to read whichever
# directory that scratch is in, so a suite writing beside all of it makes that read expensive for
# everything, 270 times in a single run. A root that cannot be written to falls back to the flat
# location, which is still swept: what that loses is the saving, not the scratch.
SUITE_SCRATCH_HOME="${SUITE_SCRATCH_HOME:-${TMPDIR:-/tmp}/claude-sync}"
mkdir -p "$SUITE_SCRATCH_HOME" 2>/dev/null || SUITE_SCRATCH_HOME="${TMPDIR:-/tmp}"

# ---- the one process-tree kill (claude-config#169) ----
# There were three: one here for #163, one in run-all-tests.sh for #165, and the watchdog's own
# since #31. All three carried the same non-obvious rule about confirming a child's parent
# immediately before killing it, and a correction would have had to reach three places or it
# reaches two (L30).
#
# A COMMAND rather than a sourced function, because the watchdog's copy lives inside an `sh -c`
# string handed to `exec -a` and can source nothing at all. A shared function would have
# consolidated the two easy ones and left the third, which is the one hardest to notice.
SUITE_KILL_TREE="$(cd "$(dirname "$SCRIPT")" && pwd)/payload/hooks/lib/kill-tree.sh"
if [ ! -f "$SUITE_KILL_TREE" ]; then
  # Said out loud rather than degraded to doing nothing. A cleanup that silently stops killing
  # anything looks exactly like a run that had nothing to clean up (L98), and that is the state
  # #163 and #165 exist to end.
  echo "test suite: no kill-tree helper at $SUITE_KILL_TREE, so an interrupted run will NOT be able to clean up the processes it started. Refusing rather than running with a cleanup that quietly does nothing." >&2
  exit 4
fi

# ---- which processes belong to this run (claude-config#166) ----
# A run killed with SIGKILL cannot run #163's cleanup, because nothing runs inside a process that
# has been killed outright, so its shards and its re-executed copy go on running and go on holding
# the machine. The only place a remedy can live is the run that takes the lock over afterwards, and
# that run needs to know WHICH processes were the dead one's.
#
# Not "every suite process that is not mine": this file starts nested runs constantly and that rule
# would kill the fixtures of every check in it. So the run registers its own processes in a file
# the lock names, and a takeover clears exactly what that file lists.
# ---- the registry is small on purpose (#170) ----
# The first version had EVERY run append itself, and this file starts hundreds of nested runs in a
# full pass, so the registry ended up holding several hundred numbers of which almost all belonged
# to processes that had finished long ago. A takeover then asked the system about every one of
# them, so the cost of recovering from a force-kill grew with how long the killed run had been
# going, which is backwards.
#
# What actually has to be listed is what SURVIVES the top-level being killed outright, and that is
# only the processes it started directly that carry on independently: the shards. Everything else a
# run makes is a descendant of one of those, or of the top-level itself, and the takeover walks the
# tree from each number it clears, so a nested run started by a shard is reached through the shard
# and does not need a line of its own.
#
# So a run registers itself when it is a SHARD, and the top-level registers itself when it takes the
# lock. A nested run neither registers nor is lost: it is reachable, which is the property that
# matters. That takes a full run's registry from several hundred entries to about five.
#
# Registered before anything else can fork, so a shard that dies early is still accounted for.
suite_register_self(){
  [ -n "${SUITE_RUN_REGISTRY:-}" ] || return 0
  [ -f "$SUITE_RUN_REGISTRY" ] || return 0
  printf '%s\n' "$$" >> "$SUITE_RUN_REGISTRY" 2>/dev/null || true
  return 0
}
[ -n "${SUITE_SHARD:-}" ] && suite_register_self || true

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

# ---- stop early rather than run one section alone (#27) ----
# The knob is SECTION_UNTIL, described where it is implemented further down. Default is a full
# run, so the pre-push gate is unaffected and nobody can narrow it by accident.
# `section` REPLACES the bare `echo "== ... =="` headings: every check that follows a heading
# belongs to it, and a skipped section's checks are never executed rather than executed and
# hidden, which would save no time at all and defeat the point.
# Also records where the run has got to, for the deadline below to name when it kills a hung run
# (#31), and carries the seam that makes that deadline testable. Both are inert until the
# deadline is armed further down, which is after the section runner has decided whether this
# process is the one that will actually execute the sections.
# ---- every section reports its size and how long it took (#107) ----
# A full run reported one number and nothing about where the minutes went, so "the suite is slow"
# named no section anybody could act on, and a section that became slow later had nothing to show
# up in.
#
# The count is derived by subtracting the running totals at the section's start from the totals at
# its end, so it cannot drift from what actually ran. The suite asserts the per-section counts SUM
# to the run's own total, which a plausible-looking number would not survive.
#
# SECONDS is a bash builtin, so the clock costs no process per section. Whole seconds is the right
# resolution deliberately: what a reader needs is which sections cost seconds, and a sub-second
# figure would cost a fork per section and perturb the thing being measured. Most sections
# legitimately read 0s, which is also why SUITE_SLOW_IN exists below: a timer that was simply
# broken would read 0s everywhere too, and that is indistinguishable from a fast suite (L182).
_SEC_TITLE=""; _SEC_T0=0; _SEC_P0=0; _SEC_F0=0; _SEC_PROFILE=""; _SEC_TARGET_N=0

# ---- every section run is the prelude, a target, or a repeat (#146) ----
# The headline total moved with how much of the machine the run was granted: 873 checks in one
# process and 1118 across eight shards, of the same file on 2026-08-21. A total that changes for
# reasons unrelated to the tests cannot be used to notice that checks were LOST, which is the one
# question a total exists to answer (L63).
#
# Two things repeated, not one. Every shard runs the PRELUDE, which is 33 of those checks. And a
# shard ran any section its own targets declared with `# needs:`, even when another shard owned it,
# so one 14 check section ran twice as well. Both are counted here as they happen, so the parent
# can report each section once and say separately how much was run over again.
#
# The second of the two is gone since #151: a section is now dealt to the same shard as the
# prerequisite it needs, so there is nothing left to borrow. The bucket stays, because it is what
# MEASURES that, and a count that can only ever read zero is still the thing that would notice the
# grouping breaking (L182 cuts the other way here: the zero is a live measurement, not a retired
# one).
#
# A run with no target list is a run where every section is its own target, which is what a full
# single process run is. That is the honest default rather than a special case: it makes the
# buckets add up to the same total either way.
_SEC_IN_PRELUDE=1
_SEC_PP=0; _SEC_PF=0; _SEC_TP=0; _SEC_TF=0; _SEC_RP=0; _SEC_RF=0

section_close(){
  [ -n "$_SEC_TITLE" ] || return 0
  local _n=$(( (PASS - _SEC_P0) + (FAIL - _SEC_F0) ))
  local _d=$(( SECONDS - _SEC_T0 ))
  # Which bucket this section's checks belong to (#146). Worked out HERE, from the running totals,
  # so it cannot drift from what actually ran, exactly as the per-section count above cannot.
  local _bp=$(( PASS - _SEC_P0 ))
  local _bf=$(( FAIL - _SEC_F0 ))
  if [ "${_SEC_IN_PRELUDE:-1}" -eq 1 ]; then
    _SEC_PP=$(( _SEC_PP + _bp )); _SEC_PF=$(( _SEC_PF + _bf ))
    # The boundary is named by its heading TEXT, and the prelude is everything up to and INCLUDING
    # it, so the switch happens after this section has been counted. Only ever tested when the
    # boundary is non-empty: `*""*` matches every title, which would end the prelude at the first
    # section and quietly put the whole run in the wrong bucket.
    if [ -n "${SUITE_PRELUDE_END:-}" ]; then
      case "$_SEC_TITLE" in *"$SUITE_PRELUDE_END"*) _SEC_IN_PRELUDE=0 ;; esac
    fi
  elif [ -z "${SUITE_TARGET_TITLES:-}" ]; then
    _SEC_TP=$(( _SEC_TP + _bp )); _SEC_TF=$(( _SEC_TF + _bf ))
  else
    case "
${SUITE_TARGET_TITLES}
" in
      *"
$_SEC_TITLE
"*) _SEC_TP=$(( _SEC_TP + _bp )); _SEC_TF=$(( _SEC_TF + _bf )) ;;
      *)  _SEC_RP=$(( _SEC_RP + _bp )); _SEC_RF=$(( _SEC_RF + _bf )) ;;
    esac
  fi
  local _w="checks"; [ "$_n" -eq 1 ] && _w="check"
  printf '  (section: %d %s, %ds)\n' "$_n" "$_w" "$_d"
  # SUITE_TARGET_SECTION names the section a filtered run was ASKED for. Recorded here so the tail
  # can tell "that section passed" from "the prelude passed and that section did nothing".
  [ "$_SEC_TITLE" = "${SUITE_TARGET_SECTION:-}" ] && _SEC_TARGET_N=$_n
  # Zero padded so a plain reverse sort is a numeric one, with no dependence on the locale's idea
  # of numeric ordering.
  _SEC_PROFILE="$_SEC_PROFILE$(printf '%06d\t%s' "$_d" "$_SEC_TITLE")
"
  _SEC_TITLE=""
  return 0
}

# Closes the last section of a run and prints the profile. Called from the bottom of this file AND
# from the tail the section extractor appends, because a filtered run stops at a section too and its
# last section would otherwise be the one section never reported (which is the one being worked on).
# Where each section's measured wall clock is kept between runs (claude-config#203). The same
# design as the runner's own suite store one level up (#144) and for the same reasons: NOT under
# the config directory, which mirrors itself to the other Mac within seconds, because a duration
# measured on this machine is not configuration and shipping it would make the other Mac deal its
# shards by numbers from hardware it does not have.
#
# `-` and not `:-`, so an empty value means OFF rather than default. A run that must leave no trace
# needs that, and so does CI until its cache is warm.
SUITE_SECTION_TIMINGS="${SUITE_SECTION_TIMINGS-${XDG_CACHE_HOME:-$HOME/.cache}/claude-config/section-timings}"

# A record is keyed on the section's TITLE, never its position. Sections are added and removed
# constantly and every index after the insertion point shifts, so an index keyed store would
# silently attribute one section's duration to its neighbour (L15). Only `/` and `%` are encoded,
# and both are, so two different titles cannot produce one file name.
# The title as `section` was CALLED with, from the raw `section "..."` line the heading scan keeps.
# The two must agree or the store is written under one name and read under another, which is not an
# error anywhere: every lookup simply misses and the run reports that nothing has been measured
# while the records sit there (L100).
suite_section_title(){   # suite_section_title <a raw `section "..."` line> -> the title
  local _st_t="${1:-}"
  _st_t="${_st_t#section \"}"
  printf '%s' "${_st_t%\"}"
}

suite_section_key(){   # suite_section_key <section title> -> the record's file name
  printf '%s' "${1:-}" | sed 's/%/%25/g; s#/#%2F#g'
}

# What that section was last measured at, or NOTHING. A record that is not a whole number of
# seconds is treated as no record rather than guessed at as a number: the store is a cache, and
# being wrong about it costs the shard balance and nothing else.
suite_section_seconds(){   # suite_section_seconds <section title> -> whole seconds, or nothing
  [ -n "$SUITE_SECTION_TIMINGS" ] || return 0
  [ -n "${1:-}" ] || return 0
  local _ss_v
  _ss_v="$(awk 'NR == 1 { print $1 }' "$SUITE_SECTION_TIMINGS/$(suite_section_key "$1")" 2>/dev/null)"
  case "$_ss_v" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_ss_v"
}

# What this run measured, written down for the next one. Called from suite_profile, so it happens
# once at the end rather than once per section, and a run that was killed records nothing at all.
#
# A run driven through the SLOW or HANG seams records NOTHING. Those seams pause and stall on
# purpose, so their durations measure the seam rather than the section, and a store holding them
# would deal every later run against a number nobody meant. That is #229 one level up, where a
# suite exiting at once because it refused its own lock was recorded as costing nothing and then
# led nothing, with the run reporting a measured order the whole time (L330).
suite_record_sections(){
  [ -n "$SUITE_SECTION_TIMINGS" ] || return 0
  [ -n "$_SEC_PROFILE" ] || return 0
  [ -z "${SUITE_SLOW_IN:-}" ] || return 0
  [ -z "${SUITE_HANG_IN:-}" ] || return 0
  mkdir -p "$SUITE_SECTION_TIMINGS" 2>/dev/null || {
    echo "test suite: could not create $SUITE_SECTION_TIMINGS, so nothing was recorded and the next run will deal its shards by counting sections. Set SUITE_SECTION_TIMINGS somewhere writable, or to empty to turn the record off." >&2
    return 0
  }
  local _sr_d _sr_t _sr_k _sr_tmp _sr_bad=0
  while IFS="$(printf '\t')" read -r _sr_d _sr_t; do
    [ -n "$_sr_t" ] || continue
    _sr_k="$(suite_section_key "$_sr_t")"
    _sr_tmp="$SUITE_SECTION_TIMINGS/.writing.$$.$_sr_k"
    # Written to a temporary name and renamed over the old one, so two runs at once cannot
    # interleave into a half written record. The shards of one run write disjoint sets of sections,
    # so they never contend for the same record at all.
    if printf '%s\n' "$((10#$_sr_d))" > "$_sr_tmp" 2>/dev/null && mv -f "$_sr_tmp" "$SUITE_SECTION_TIMINGS/$_sr_k" 2>/dev/null; then
      :
    else
      rm -f "$_sr_tmp" 2>/dev/null
      _sr_bad=$(( _sr_bad + 1 ))
    fi
  done <<SRPROFILE
$_SEC_PROFILE
SRPROFILE
  # Said out loud, never swallowed. A store that cannot be written leaves every future run dealing
  # by count while reading as though it dealt by measurement (L11, L98).
  [ "$_sr_bad" -eq 0 ] || echo "test suite: $_sr_bad section time(s) could not be written to $SUITE_SECTION_TIMINGS, so the next run will deal those by counting." >&2
  return 0
}

suite_profile(){
  section_close
  suite_record_sections
  [ -n "$_SEC_PROFILE" ] || return 0
  echo ""
  echo "slowest sections:"
  printf '%s' "$_SEC_PROFILE" | sort -r | head -5 | while IFS="$(printf '\t')" read -r _pd _pt; do
    [ -n "$_pt" ] || continue
    printf '  %ds %s\n' "$((10#$_pd))" "$_pt"
  done
  return 0
}

# The tail both filtered runs append. ONE implementation: two copies of "report, then decide the
# exit code" drift apart, and the rule below then holds for whichever knob happened to get it, which
# is not the one somebody reaches for (claude-config#110).
suite_filtered_tail(){   # $1 = how the run was scoped, for the summary   $2 = the resolved heading
  suite_profile
  echo ""
  echo "PASS=$PASS FAIL=$FAIL ($1, NOT a full run)"
  # How those checks were divided up (#146), so a parent putting shards back together can count
  # each section once. Its own total goes on the same line: without it the buckets could quietly
  # leave checks out and the parent would report the smaller number as if it were the whole thing
  # (L16). Printed BEFORE the result line, because that one has to stay the last thing said.
  printf 'SUITE-SECTIONS prelude_pass=%s prelude_fail=%s target_pass=%s target_fail=%s repeat_pass=%s repeat_fail=%s total_pass=%s total_fail=%s\n' \
    "$_SEC_PP" "$_SEC_PF" "$_SEC_TP" "$_SEC_TF" "$_SEC_RP" "$_SEC_RF" "$PASS" "$FAIL"
  # The machine readable line goes on a filtered run too, so a caller reading it never has to know
  # which knob the run was started with (claude-config#126).
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
  # A filtered run counts the PRELUDE's checks in that total, so a section that ran none of its own
  # still prints a healthy looking number underneath its own name. The total is then not evidence
  # about the thing it is printed beside, which is the same shape as a scan that read nothing
  # reporting a clean tree (L98).
  if [ "${_SEC_TARGET_N:-0}" -eq 0 ]; then
    echo "test suite: $2 ran NO checks of its own, so this run says nothing about it. The total above is the prelude's." >&2
    return 6
  fi
  [ "$FAIL" -eq 0 ]
}

section(){
  section_close
  echo "$1"
  _SEC_TITLE="$1"; _SEC_T0=$SECONDS; _SEC_P0=$PASS; _SEC_F0=$FAIL
  if [ -n "$SUITE_SECTION_MARK" ]; then printf '%s\n' "$1" > "$SUITE_SECTION_MARK"; fi
  # SUITE_SLOW_IN=<text> pauses deliberately in the first matching section, so the duration column
  # can be watched reporting a KNOWN number. Without it every section reads 0s on a fast machine and
  # a broken clock looks exactly like a fast suite (L1, L182).
  if [ -n "${SUITE_SLOW_IN:-}" ] && printf '%s' "$1" | grep -qi -- "$SUITE_SLOW_IN"; then
    echo "  (test seam: pausing deliberately in this section)"
    # The SAME unit the watchdog polls in (claude-config#206). These two numbers only mean anything
    # relative to each other: this pause exists to keep a run moving faster than the watchdog can
    # call it stopped, and holding them apart as two constants three hundred lines from each other
    # is how one gets changed alone.
    sleep "$SUITE_POLL_INTERVAL"
  fi
  # SUITE_HANG_IN=<text> stalls deliberately in the first matching section. A deadline can only
  # be trusted once it has been watched killing something (L1), and waiting for a real stall to
  # turn up is not a test.
  if [ -n "${SUITE_HANG_IN:-}" ] && printf '%s' "$1" | grep -qi -- "$SUITE_HANG_IN"; then
    echo "  (test seam: hanging deliberately in this section)"
    # Hung on a child it is WAITING for, not sitting in a foreground sleep. Bash defers a trapped
    # signal until the foreground command finishes, so a run stalled inside `sleep 60` cannot run
    # its own interrupt handler for up to a minute, and #163's cleanup could not be observed at all
    # (bash returns from `wait` immediately on a trapped signal, which is the difference). It is
    # also the shape a real hang has: a run blocked on something it started rather than on a timer.
    while :; do sleep 3600 & wait "$!" || true; done
  fi
  return 0
}
SUITE_SECTION_MARK=""

# SECTION_UNTIL=<text> runs from the beginning UP TO AND INCLUDING the matching section, then stops.
#
# This comment used to say that "only the matching section" was tried and rejected, because running
# one alone produced 24 failures that were purely missing setup, and a tool that reports failures
# the code did not cause is worse than a slow one. That finding was true and is no longer, so it is
# recorded here rather than quietly deleted (claude-config#105).
#
# What changed is the file, not the judgement. The coupling got MEASURED on 2026-08-20, over the
# 73 post-prelude sections the file held that day: 68 passed alone, and the five that did not each
# read one variable an earlier section had set. The file has grown since, and how many sections it
# has now is printed by every run (#138) rather than written down here (#140). Four of those five were accidents and were removed; the one real
# dependency is declared. So SECTION_ONLY exists now, below, and it does not report failures the
# code did not cause, because there is almost nothing left for it to get wrong.
#
# SECTION_UNTIL stays. It is still the right thing when you want everything up to a point rather
# than one section, and the two refuse to run together rather than one silently winning.
# ---- run ONE section, plus what it needs (#105) ----
# SECTION_UNTIL runs from the top UP TO a section, so reaching the last one costs a full run, and
# the last one is where new work lands. SECTION_ONLY runs the PRELUDE, plus one section, plus
# whatever that section declares it needs.
#
# The prelude is the preamble and every section up to and including SUITE_PRELUDE_END. That
# boundary is measured, not guessed: the only lines in this file that change shared state are
# `export CLAUDE_HOME="$CH2"` and `unset SYNC_NO_GIT`, both inside those first four sections, so
# everything after them runs in one fixed ambient state. Running all 73 later sections in isolation
# on 2026-08-20 put numbers on it: 68 passed alone with no mechanism at all.
#
# Named by its heading TEXT rather than by a count, so inserting a section cannot silently move the
# boundary, and asserted to match exactly one heading below, so renaming one cannot silently void it.
# How a heading line becomes a title, written ONCE and used everywhere it is needed, including by
# the check that proves it and by the section list the changed-section audit reads
# (claude-config#111, claude-config#114). Two sites used to trim one trailing quote, which assumes
# the line ends in exactly one. Neither broke, but #37 feeds its result into a NEGATED check, so a
# heading gaining a trailing comment would have turned the marker into a string nothing can find and
# the check would have passed while proving nothing (L159). Its companion only asserts the marker is
# non-empty, which a mangled string satisfies.
# Everything from the LAST quote onwards is dropped, so trailing text cannot corrupt the title.
# A function rather than a sed expression, because the callers are a mix of shell and pipelines and
# two spellings of one rule is the thing being removed, not added to.
section_title(){   # $1 = a `section "..."` line -> the heading text
  local _st="${1#section \"}"
  printf '%s' "${_st%\"*}"
}

SUITE_PRELUDE_END="sync (two-way) over a local fake remote"

# Both at once is a refusal, never a precedence rule: whichever won, the run would be doing
# something other than what the other knob asked for and nothing would say so.
if [ -n "${SECTION_ONLY:-}" ] && [ -n "${SECTION_UNTIL:-}" ]; then
  echo "test suite: SECTION_ONLY='$SECTION_ONLY' and SECTION_UNTIL='$SECTION_UNTIL' were both given. They ask for different runs, so this refuses rather than picking one and leaving you to discover which. Use one." >&2
  exit 2
fi

# Collected once, and used by BOTH filters. They used to resolve a name differently: SECTION_ONLY
# refused an ambiguous pattern and SECTION_UNTIL took the earliest match, which meant which rules
# applied depended on which knob you reached for (claude-config#110).
if { [ -n "${SECTION_ONLY:-}" ] || [ -n "${SECTION_UNTIL:-}" ] || [ -n "${SECTION_LIST:-}" ] || [ -n "${SUITE_SHARD:-}" ]; } && [ -z "${SUITE_FILTERED:-}" ]; then
  # Every heading, its line, and any `# needs:` lines directly beneath it. A declaration is a
  # COMMENT and deliberately not an argument to `section`: three derivations in this file parse
  # `^section "..."$` by stripping one trailing quote, and #37's `_late` would fail SILENTLY,
  # leaving the guard that proves a filtered child stops where it was told passing for the wrong
  # reason (L103).
  _so_i=0; _so_ln=0; _so_after=0; _so_all=""
  _so_titles=(); _so_starts=(); _so_needs=()
  while IFS= read -r _so_l; do
    _so_ln=$((_so_ln + 1))
    case "$_so_l" in
      'section "'*)
        _so_i=$((_so_i + 1))
        _so_titles[$_so_i]="$_so_l"
        _so_starts[$_so_i]=$_so_ln
        _so_needs[$_so_i]=""
        _so_all="$_so_all$_so_l
"
        _so_after=1
        ;;
      '# needs:'*)
        if [ "$_so_after" -eq 1 ] && [ "$_so_i" -gt 0 ]; then
          _so_needs[$_so_i]="${_so_needs[$_so_i]}${_so_l#\# needs:}
"
        fi
        ;;
      *) _so_after=0 ;;
    esac
  done < "$0"

  # Resolve a pattern to exactly one heading. Fixed string and case insensitive, matching what
  # SECTION_UNTIL already does, but the COUNT is what matters here: "run up to" has a natural
  # earliest answer and "run only" does not, so an ambiguous pattern must refuse rather than
  # silently run a section nobody asked for and report success under the text that was typed
  # (L100, L154).
  # SECTION_LIST=1 prints every heading with the line it starts on, then exits. It exists so that
  # nothing else has to work out where the sections are: the changed-section audit needs exactly
  # that answer, and deriving it a second time would put two implementations of one question in the
  # repo, with the audit being the half that decides whether a section can stand alone
  # (claude-config#114). Placed here, before the lock and the deadline, because listing is a
  # read-only question that should cost nothing and take nothing.
  if [ -n "${SECTION_LIST:-}" ]; then
    _sl_k=1
    while [ "$_sl_k" -le "$_so_i" ]; do
      printf '%s\t%s\n' "${_so_starts[$_sl_k]}" "$(section_title "${_so_titles[$_sl_k]}")"
      _sl_k=$((_sl_k + 1))
    done
    exit 0
  fi

  _so_hits=0; _so_idx=""; _so_list=""
  _sec_match(){
    local _m
    _m="$(printf '%s' "$_so_all" | grep -niF -- "$1" || true)"
    _so_hits="$(printf '%s' "$_m" | grep -c . || true)"
    case "$_so_hits" in ''|*[!0-9]*) _so_hits=0 ;; esac
    _so_idx="$(printf '%s' "$_m" | head -1 | cut -d: -f1)"
    _so_list="$(printf '%s' "$_m" | sed 's/^[0-9]*:/  /')"
    return 0
  }

  # The transitive closure of what a set of sections declares it needs, in _so_keep. ONE
  # implementation, called by the shard selector to work out what a shard would BORROW
  # (claude-config#151) and by the extractor further down to decide what is copied into the
  # filtered run. Deriving the same closure twice would put two answers to one question in this
  # file, and they would agree with each other rather than with what actually runs (L107).
  #
  # A declaration that resolves to nothing, to several, or to a LATER section is an error before
  # anything runs: each would leave the prerequisite out while the run went on to report a result
  # (L100, L151).
  _needs_closure(){   # _needs_closure "<section indices>" -> sets _so_keep
    local _nc_queue="$1" _nc_cur _nc_nd
    _so_keep=""
    while [ -n "$_nc_queue" ]; do
      _nc_cur="${_nc_queue%% *}"
      case "$_nc_queue" in *" "*) _nc_queue="${_nc_queue#* }" ;; *) _nc_queue="" ;; esac
      [ -n "$_nc_cur" ] || continue
      case " $_so_keep " in *" $_nc_cur "*) continue ;; esac
      _so_keep="$_so_keep $_nc_cur"
      # Nothing declared, nothing to resolve, and skipped BEFORE the heredoc below rather than by
      # letting it read an empty string (claude-config#204). Bash writes a heredoc to a temporary
      # file every time it runs one, and this runs once per section in the closure: a shard of
      # roughly a quarter of them, of which at most one declares anything, paid one per section.
      # `_so_keep` is appended
      # to on the line above, so the section is still kept, exactly as before. Measured 2026-08-30
      # with the grouping loop's own skip: the two together took a coverage launch from 1.1 seconds
      # to a quarter of one, with every shard of every count answering identically.
      [ -n "${_so_needs[$_nc_cur]}" ] || continue
      while IFS= read -r _nc_nd; do
        _nc_nd="$(printf '%s' "$_nc_nd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
        [ -n "$_nc_nd" ] || continue
        _sec_match "$_nc_nd"
        if [ "$_so_hits" -eq 0 ]; then
          echo "test suite: ${_so_titles[$_nc_cur]} declares '# needs: $_nc_nd', which matches no heading. A declaration that resolves to nothing would silently leave the prerequisite out and the run would report a result anyway." >&2
          exit 2
        fi
        if [ "$_so_hits" -gt 1 ]; then
          echo "test suite: ${_so_titles[$_nc_cur]} declares '# needs: $_nc_nd', which matches $_so_hits headings. Narrow it. The candidates are:" >&2
          printf '%s\n' "$_so_list" >&2
          exit 2
        fi
        if [ "$_so_idx" -ge "$_nc_cur" ]; then
          echo "test suite: ${_so_titles[$_nc_cur]} declares '# needs: $_nc_nd', which is not EARLIER in the file. A prerequisite that runs afterwards cannot have prepared anything." >&2
          exit 2
        fi
        _nc_queue="$_nc_queue $_so_idx"
      done <<SONEEDS
${_so_needs[$_nc_cur]}
SONEEDS
    done
  }

fi

if [ -n "${SECTION_UNTIL:-}" ] && [ -z "${SUITE_FILTERED:-}" ]; then
  _sec_match "$SECTION_UNTIL"
  if [ "$_so_hits" -eq 0 ]; then
    # A filter that matched no section is an ERROR, never a silent green run: a suite that checked
    # nothing and exits 0 is indistinguishable from one where everything passed.
    echo "test suite: SECTION_UNTIL='$SECTION_UNTIL' matched no section. Run without it, or check the spelling against the '==' headings." >&2
    exit 2
  fi
  if [ "$_so_hits" -gt 1 ]; then
    # It used to take the earliest match, on the grounds that "run up to" has a natural earliest
    # answer. It does, but the person did not ask for the earliest, they asked for a name, and a run
    # that stops somewhere other than where they asked while reporting success is a filter that
    # matched something else (L154, claude-config#110).
    echo "test suite: SECTION_UNTIL='$SECTION_UNTIL' matches $_so_hits sections, so where to stop is not decided. Narrow it. The candidates are:" >&2
    printf '%s\n' "$_so_list" >&2
    exit 2
  fi
  _su_name="$(section_title "${_so_titles[$_so_idx]}")"

  # Named for the same reason as everything else this suite creates: a run killed between writing
  # this copy and removing it leaves a file nothing can attribute afterwards (#36).
  _filtered="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  if [ "$_so_idx" -lt "$_so_i" ]; then
    _su_end=$(( ${_so_starts[$((_so_idx + 1))]} - 1 ))
  else
    _su_end='$'
  fi
  sed -n "1,${_su_end}p" "$0" > "$_filtered"

  # The pattern is echoed back in the summary, with the two characters that would break out of the
  # generated line removed rather than trusted.
  _su_pat="$(printf '%s' "$SECTION_UNTIL" | tr -d '"\\')"
  printf '\nsuite_filtered_tail "stopped after SECTION_UNTIL=%s, resolved to %s" "%s"; exit $?\n' "$_su_pat" "$_su_name" "$_su_name" >> "$_filtered"
  # The extracted file must PARSE before it is run. Cutting at section boundaries can land inside a
  # multi-line construct and produce invalid shell, and without this the broken script runs anyway
  # and its parse errors are reported as if the code under test failed. Found by a mutation that
  # dropped a section and produced exactly that. The seam exists so this refusal can be tested
  # rather than assumed.
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
  SUITE_FILTERED=1 SUITE_TARGET_SECTION="$_su_name" SUITE_DEPTH="$SUITE_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$_filtered"; _rc=$?
  rm -f "$_filtered"
  exit "$_rc"
fi

# SUITE_SHARD=i/n runs the prelude plus every n-th section from the i-th offset (claude-config#133).
# It shares the SECTION_ONLY extractor below rather than having one of its own: that code already
# takes a SET of sections, pulls in whatever they declare they need, and refuses a copy that does
# not parse, and a second implementation of any of that would drift from this one.
#
# Round robin rather than contiguous blocks, because the sections are wildly uneven: measured on
# this Mac on 2026-08-21, over the 82 sections it held then, the slowest five were 22s, 13s, 11s,
# 11s and 9s out of about 200s, so contiguous blocks would put several slow ones in the same shard
# and the whole run would wait for it. Interleaving spreads them without anybody maintaining a list
# of which are slow.
if [ -n "${SUITE_SHARD:-}" ] && [ -z "${SUITE_FILTERED:-}" ]; then
  case "$SUITE_SHARD" in
    [1-9]*/[1-9]*) ;;
    *) echo "test suite: SUITE_SHARD='$SUITE_SHARD' is not of the form i/n, for example 2/4. Refusing rather than guessing which sections to run, because a guess would report a result over a set nobody chose." >&2; exit 2 ;;
  esac
  _sh_i="${SUITE_SHARD%%/*}"; _sh_n="${SUITE_SHARD##*/}"
  case "$_sh_i$_sh_n" in *[!0-9]*) echo "test suite: SUITE_SHARD='$SUITE_SHARD' is not two whole numbers." >&2; exit 2 ;; esac
  if [ "$_sh_i" -lt 1 ] || [ "$_sh_i" -gt "$_sh_n" ]; then
    echo "test suite: SUITE_SHARD='$SUITE_SHARD' asks for shard $_sh_i of $_sh_n, which does not exist. Refusing rather than running an empty set and reporting it as a pass." >&2
    exit 2
  fi

  _sec_match "$SUITE_PRELUDE_END"
  if [ "$_so_hits" -ne 1 ]; then
    echo "test suite: the prelude boundary '$SUITE_PRELUDE_END' matches $_so_hits headings rather than exactly one, so which sections make up the prelude is not decided." >&2
    exit 2
  fi
  _so_pend="$_so_idx"

  # Every section after the prelude that falls in this shard.
  #
  # A section and the sections it declares it NEEDS are dealt out TOGETHER (claude-config#151).
  # They used to be dealt out one at a time, and the closure below then pulled a prerequisite into
  # whichever shard borrowed it, so that section ran in its own shard AND in the borrower: one
  # section worth 14 checks ran twice at two, four, six and eight shards, measured 2026-08-21.
  # #146 made that visible by reporting the repeats beside the headline rather than folding them
  # in, which is not the same as removing them.
  #
  # So the sections are grouped first, each with its prerequisites, and whole groups are dealt out.
  # A prerequisite is always EARLIER in the file, which the closure refuses to run without, so a
  # group is always a set of sections that can run in one shard in file order.
  #
  # Dealt to the shard carrying the FEWEST sections so far, ties to the lowest numbered one.
  # Pinning dependents to their prerequisite's shard can pile one shard up, and a shard carrying
  # far more than the others costs more wall clock than the duplicate it removed. With no
  # declarations at all every group is one section and this deals out exactly as the plain round
  # robin it replaces did.
  _sh_grp=(); _sh_size=(); _sh_load=(); _sh_of=(); _sh_weight=()
  _sh_k=$(( _so_pend + 1 ))
  while [ "$_sh_k" -le "$_so_i" ]; do _sh_grp[$_sh_k]=$_sh_k; _sh_k=$(( _sh_k + 1 )); done
  # Answers in a VARIABLE rather than on stdout, because every caller here read it through `$(...)`
  # and each of those forks a subshell (claude-config#204). Three loops over the sections plus one
  # over the declarations called it several hundred times per launch, and a coverage launch was
  # measured 2026-08-30 at 1.1 seconds of which 1.09 was this selection. Nothing about the answer
  # changes: what moves is how it gets back.
  _sh_root_out=""
  _sh_root(){   # _sh_root <section> -> sets _sh_root_out to the group it is in, named by its earliest member
    local _r="$1"
    while [ "${_sh_grp[$_r]}" -ne "$_r" ]; do _r="${_sh_grp[$_r]}"; done
    _sh_root_out="$_r"
  }
  # SUITE_SHARD_NO_GROUPING=1 deals the sections out one at a time, which is what this did before
  # #151. It exists so the borrowing can be WATCHED HAPPENING: with grouping in place no section is
  # ever borrowed, so an empty borrowed= field is equally what a working derivation and a
  # derivation that reports nothing at all would print, and the check would read as protection
  # while protecting nothing (L1, L159). Nothing sets it but that check.
  _sh_k=$(( _so_pend + 1 ))
  while [ "$_sh_k" -le "$_so_i" ] && [ -z "${SUITE_SHARD_NO_GROUPING:-}" ]; do
    # Sections with NO declaration are skipped before the loop below rather than fed an empty
    # string (claude-config#204). The heredoc that loop reads from is written to a temporary FILE,
    # once per turn, and this ran once per section whether that section declared anything or not:
    # measured 2026-08-30, 106 sections of which 4 carry a declaration, and the 102 empty ones were
    # 986ms of the 1.1 seconds a coverage launch cost. Reading an empty heredoc produces no lines,
    # so the loop body never ran for them and nothing about the answer changes.
    if [ -z "${_so_needs[$_sh_k]}" ]; then _sh_k=$(( _sh_k + 1 )); continue; fi
    while IFS= read -r _sh_nd; do
      _sh_nd="$(printf '%s' "$_sh_nd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$_sh_nd" ] || continue
      _sec_match "$_sh_nd"
      # A declaration that cannot be resolved is not diagnosed HERE. _needs_closure below refuses
      # the whole run over it, with the wording that says which declaration and why, and one
      # refusal in one place is what keeps the two from drifting apart (L11).
      [ "$_so_hits" -eq 1 ] || continue
      # A prerequisite inside the PRELUDE needs no grouping: every shard runs the prelude, so
      # nothing is ever borrowed to satisfy it.
      [ "$_so_idx" -gt "$_so_pend" ] || continue
      [ "$_so_idx" -lt "$_sh_k" ] || continue
      _sh_root "$_sh_k"; _sh_a="$_sh_root_out"; _sh_root "$_so_idx"; _sh_b="$_sh_root_out"
      if [ "$_sh_a" -ne "$_sh_b" ]; then
        if [ "$_sh_a" -lt "$_sh_b" ]; then _sh_grp[$_sh_b]=$_sh_a; else _sh_grp[$_sh_a]=$_sh_b; fi
      fi
    done <<SHNEEDS
${_so_needs[$_sh_k]}
SHNEEDS
    _sh_k=$(( _sh_k + 1 ))
  done
  # Each group's SIZE in sections and its WEIGHT in seconds (claude-config#203). Sections are not
  # the same size, so a deal balanced on how many of them a shard holds balances nothing: measured
  # 2026-08-29 over 463 seconds of section time, the slowest five sections were 52, 38, 27, 27 and
  # 24 seconds against a median under two, and four shards came out at 76, 165, 115 and 105 where
  # balanced is 116 each.
  #
  # A section nobody has measured is not invented a duration. It is counted, and what stands in for
  # it in the arithmetic is the MEDIAN of the sections that WERE measured, which is the one figure
  # here that is not made up: it is what a section of unknown size is most likely to cost. How many
  # of those there were is said out loud below, so a balance mostly made of stand-ins cannot read
  # as a measured one (L11, L192).
  _sh_secs=(); _sh_unk=()
  _sh_measured=0; _sh_total=0
  _sh_all_secs=""
  _sh_k=$(( _so_pend + 1 ))
  while [ "$_sh_k" -le "$_so_i" ]; do
    _sh_root "$_sh_k"; _sh_r="$_sh_root_out"
    _sh_size[$_sh_r]=$(( ${_sh_size[$_sh_r]:-0} + 1 ))
    _sh_total=$(( _sh_total + 1 ))
    _sh_sec="$(suite_section_seconds "$(suite_section_title "${_so_titles[$_sh_k]:-}")")"
    if [ -n "$_sh_sec" ]; then
      _sh_secs[$_sh_r]=$(( ${_sh_secs[$_sh_r]:-0} + _sh_sec ))
      _sh_measured=$(( _sh_measured + 1 ))
      _sh_all_secs="$_sh_all_secs$_sh_sec
"
    else
      _sh_unk[$_sh_r]=$(( ${_sh_unk[$_sh_r]:-0} + 1 ))
    fi
    _sh_k=$(( _sh_k + 1 ))
  done
  # The median of what was measured, or nothing at all when nothing was.
  _sh_median=0
  if [ "$_sh_measured" -gt 0 ]; then
    _sh_median="$(printf '%s' "$_sh_all_secs" | sort -n | awk -v n="$_sh_measured" 'NR == int((n + 1) / 2) { print; exit }')"
    case "$_sh_median" in ''|*[!0-9]*) _sh_median=0 ;; esac
  fi
  # Which rule this run is about to use, said before it deals, because a run that fell back to
  # counting reads exactly like one that balanced by time (L11).
  if [ "$_sh_measured" -eq 0 ]; then
    _sh_by_time=0
    echo "test suite: shards dealt by section count, because no section has a measured time here yet. Set SUITE_SECTION_TIMINGS, or run the suite once to record them."
  else
    _sh_by_time=1
    echo "test suite: shards dealt by measured section time for $_sh_measured of $_sh_total section(s), the rest at the median of those (${_sh_median}s)"
  fi
  # The weight a group is dealt on. With nothing measured this is exactly the section count the
  # deal used before #203, so the fallback is not a second scheme to keep working, it is this one
  # with every term equal (L263).
  _sh_k=$(( _so_pend + 1 ))
  while [ "$_sh_k" -le "$_so_i" ]; do
    _sh_root "$_sh_k"; _sh_r="$_sh_root_out"
    if [ "$_sh_by_time" -eq 1 ]; then
      _sh_weight[$_sh_r]=$(( ${_sh_secs[$_sh_r]:-0} + ${_sh_unk[$_sh_r]:-0} * _sh_median ))
      # A group NEVER weighs less than the number of sections in it. A section that measured zero
      # seconds still occupies a slot and still has to be spread, and without this floor a store in
      # which everything rounds to zero gives every group a weight of zero, no shard is ever
      # strictly less loaded than shard 1, and the whole suite is dealt to shard 1 while the others
      # are refused for holding nothing. Caught by the suite's own balance checks against a store
      # of very short sections.
      #
      # It is also exactly the fallback: where the seconds carry no information the count is the
      # best thing left, which is what the run says it is doing when it has no records at all.
      [ "${_sh_weight[$_sh_r]}" -ge "${_sh_size[$_sh_r]}" ] || _sh_weight[$_sh_r]="${_sh_size[$_sh_r]}"
    else
      _sh_weight[$_sh_r]="${_sh_size[$_sh_r]}"
    fi
    _sh_k=$(( _sh_k + 1 ))
  done
  _sh_k=1
  while [ "$_sh_k" -le "$_sh_n" ]; do _sh_load[$_sh_k]=0; _sh_k=$(( _sh_k + 1 )); done
  # The deal itself, which assigns EVERY group to a shard and only then keeps the ones belonging
  # to this one. That is worth saying because it is what makes the all-shards mode below almost
  # free: the expensive part is deciding the whole partition, and the partition is already decided
  # here for every shard whether one of them is asked for or all of them are.
  _sh_targets_for(){   # _sh_targets_for <shard number> -> its sections, space separated
    local _sf_i="$1" _sf_k _sf_r _sf_out=""
    _sf_k=$(( _so_pend + 1 ))
    while [ "$_sf_k" -le "$_so_i" ]; do
      _sh_root "$_sf_k"; _sf_r="$_sh_root_out"
      if [ "${_sh_of[$_sf_r]}" -eq "$_sf_i" ]; then _sf_out="$_sf_out $_sf_k"; fi
      _sf_k=$(( _sf_k + 1 ))
    done
    printf '%s' "$_sf_out"
  }
  # HEAVIEST FIRST, and that ordering is half of what makes this work (claude-config#203). Dealing
  # in file order to the least loaded shard is a greedy fit over an arbitrary sequence, and greedy
  # only balances when the big items go first: the largest section measured 2026-08-29 was 52
  # seconds, and one of those arriving last lands on a shard already even with the others and puts
  # it that far ahead of everything.
  #
  # Ties broken by the group's own root, so two groups of equal weight deal in the same order every
  # time. Without it the deal depends on how `sort` happens to order equal keys and two runs of the
  # same tree can produce different partitions, which nothing downstream could tell from a real
  # change (L228).
  _sh_order="$(
    _sh_k=$(( _so_pend + 1 ))
    while [ "$_sh_k" -le "$_so_i" ]; do
      _sh_root "$_sh_k"; _sh_r="$_sh_root_out"
      [ "$_sh_r" -eq "$_sh_k" ] && printf '%s\t%s\n' "${_sh_weight[$_sh_r]}" "$_sh_r"
      _sh_k=$(( _sh_k + 1 ))
    done | sort -t "$(printf '\t')" -k1,1nr -k2,2n
  )"
  while IFS="$(printf '\t')" read -r _sh_w _sh_r; do
    [ -n "$_sh_r" ] || continue
    _sh_pick=1; _sh_j=2
    while [ "$_sh_j" -le "$_sh_n" ]; do
      if [ "${_sh_load[$_sh_j]}" -lt "${_sh_load[$_sh_pick]}" ]; then _sh_pick=$_sh_j; fi
      _sh_j=$(( _sh_j + 1 ))
    done
    _sh_of[$_sh_r]=$_sh_pick
    _sh_load[$_sh_pick]=$(( ${_sh_load[$_sh_pick]} + _sh_w ))
  done <<SHORDER
$_sh_order
SHORDER
  _sh_targets="$(_sh_targets_for "$_sh_i")"
  # A shard holding no sections at all must REFUSE, never report a clean run: a suite that checked
  # nothing and exits 0 is indistinguishable from one where everything passed (L98).
  case "$_sh_targets" in
    *[![:space:]]*) ;;
    *) echo "test suite: shard $_sh_i of $_sh_n holds no sections at all, so nothing would be run. Use fewer shards than the $(( _so_i - _so_pend )) sections there are." >&2; exit 2 ;;
  esac
  # What this shard SELECTED, in the selector's own terms, so the parent can put the shards back
  # together and ask whether every section was somebody's target (#137). Without it each shard
  # reports only its own totals, and a shard that quietly selected fewer sections would produce a
  # smaller number that nothing anywhere could recognise as smaller than it should be (L98).
  #
  # The TARGETS, not everything that ends up running: a section pulled in because another declared
  # it `needs:` runs in that shard too, and counting those would make a legitimate second
  # appearance read as a duplicate, which is the one thing the parent treats as a defect.
  # And what it would BORROW: the sections it will run that it does not own (claude-config#151).
  # Grouping above is what makes this empty, and an empty field is a measurement rather than a
  # promise: it comes from the same closure that decides what actually runs, so a grouping that
  # stopped working would say so here rather than quietly cost a section's worth of checks twice.
  # One shard's coverage line, from the deal above. Pulled out into a function so the all-shards
  # mode below emits it through THIS code rather than through a second copy that would agree with
  # itself (L52, L107).
  _sh_coverage_line(){   # _sh_coverage_line <shard number> <its sections>
    local _cl_i="$1" _cl_targets="$2" _cl_borrowed="" _cl_x
    _needs_closure "$_cl_targets"
    for _cl_x in $_so_keep; do
      case " $_cl_targets " in *" $_cl_x "*) ;; *) _cl_borrowed="$_cl_borrowed,$_cl_x" ;; esac
    done
    # `seconds=` is what the shard was DEALT, in the unit the deal balanced on (claude-config#203).
    # Without it the balance can only be checked by counting sections, which is the very thing that
    # was measuring the wrong quantity, so a check written over these lines would go on passing
    # while the shards came out 76 and 165 (L63).
    #
    # Reported for the shard whatever rule dealt it: when nothing was measured this is the section
    # count, which is exactly what the load was, so the field never lies about what it is a total
    # of and the sentence printed above says which.
    printf 'SUITE-SHARD-COVERAGE shard=%s first=%s last=%s sections=%s seconds=%s borrowed=%s\n' \
      "$_cl_i" "$(( _so_pend + 1 ))" "$_so_i" "$(printf '%s' "${_cl_targets# }" | tr ' ' ',')" \
      "${_sh_load[$_cl_i]:-0}" "${_cl_borrowed#,}"
  }
  # EVERY shard's line, from this one launch (claude-config#204). The deal above decides the whole
  # partition, so the second and the eighth shard's answers are already sitting in _sh_of by the
  # time the first one is printed, and asking for them one process at a time paid for the same
  # decision N times over. Measured 2026-08-30: a coverage launch costs 1.1 seconds, of which 1.09
  # is this selection, and #151 was making 20 of them to ask about 2, 4, 6 and 8 shards.
  #
  # It runs the REAL selector, which is the whole point: a faster answer produced by a copy of this
  # logic would agree with itself and with nothing else (L52). #151 checks that directly, by
  # requiring the line this prints for a shard to be identical to the one a real single shard
  # launch prints for it.
  #
  # _needs_closure writes _so_keep, so each shard's line is computed in its own call and read
  # before the next overwrites it. That is why this is a loop of calls and not one pass.
  if [ -n "${SUITE_SHARD_COVERAGE_ALL:-}" ]; then
    _sh_j=1
    while [ "$_sh_j" -le "$_sh_n" ]; do
      _sh_coverage_line "$_sh_j" "$(_sh_targets_for "$_sh_j")"
      _sh_j=$(( _sh_j + 1 ))
    done
    exit 0
  fi
  _sh_coverage_line "$_sh_i" "$_sh_targets"
  # SUITE_SHARD_COVERAGE_ONLY=1 stops here, having said what this shard would run and run none of
  # it. The line is emitted by the real selector and the suite's own check reads four real ones,
  # which costs four file reads instead of four minutes. Placed after the emission and before the
  # extractor, so what the seam skips is the RUNNING and never the deciding.
  if [ -n "${SUITE_SHARD_COVERAGE_ONLY:-}" ]; then exit 0; fi
  # The closure the run itself needs, recomputed here because the line above consumed _so_keep for
  # its own shard and the value that must survive into the run is this one.
  _needs_closure "$_sh_targets"
  SECTION_ONLY=""
  _so_shard_mode=1
  _so_target="${_sh_targets##* }"
fi

if { [ -n "${SECTION_ONLY:-}" ] || [ -n "${_so_shard_mode:-}" ]; } && [ -z "${SUITE_FILTERED:-}" ]; then
  _sec_match "$SUITE_PRELUDE_END"
  if [ "$_so_hits" -ne 1 ]; then
    echo "test suite: the prelude boundary '$SUITE_PRELUDE_END' matches $_so_hits headings rather than exactly one, so which sections make up the prelude is not decided. Refusing rather than filtering against a boundary nobody can point at." >&2
    exit 2
  fi
  _so_pend="$_so_idx"

  if [ -z "${_so_shard_mode:-}" ]; then
    _sec_match "$SECTION_ONLY"
    if [ "$_so_hits" -eq 0 ]; then
      echo "test suite: SECTION_ONLY='$SECTION_ONLY' matched no section. Run without it, or check the spelling against the '==' headings." >&2
      exit 2
    fi
    if [ "$_so_hits" -gt 1 ]; then
      echo "test suite: SECTION_ONLY='$SECTION_ONLY' matches $_so_hits sections, so which one to run is not decided. Narrow it. The candidates are:" >&2
      printf '%s\n' "$_so_list" >&2
      exit 2
    fi
    _so_target="$_so_idx"
    _sh_targets="$_so_target"
  fi

  # What this run will actually execute: its targets plus everything they declare they need. The
  # same closure the shard selector uses, so what a shard REPORTS it would borrow and what a run
  # actually copies in can never be two different answers (L107).
  _needs_closure "$_sh_targets"

  _filtered="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  sed -n "1,$(( ${_so_starts[1]} - 1 ))p" "$0" > "$_filtered"
  _so_k=1
  while [ "$_so_k" -le "$_so_i" ]; do
    _so_want=0
    [ "$_so_k" -le "$_so_pend" ] && _so_want=1
    case " $_so_keep " in *" $_so_k "*) _so_want=1 ;; esac
    if [ "$_so_want" -eq 1 ]; then
      if [ "$_so_k" -lt "$_so_i" ]; then
        _so_end=$(( ${_so_starts[$((_so_k + 1))]} - 1 ))
      else
        _so_end='$'
      fi
      sed -n "${_so_starts[$_so_k]},${_so_end}p" "$0" >> "$_filtered"
    fi
    _so_k=$((_so_k + 1))
  done

  # The titles this run is actually the target OF (#146). A shard also runs whatever its targets
  # declare with `# needs:`, including sections another shard owns, so without this the child
  # cannot tell a section it is responsible for from one it is only borrowing, and the parent
  # would count that section twice in the headline.
  _so_titles_list=""
  for _so_t in $_sh_targets; do
    _so_titles_list="$_so_titles_list$(section_title "${_so_titles[$_so_t]}")
"
  done

  _so_name="$(section_title "${_so_titles[$_so_target]}")"
  if [ -n "${_so_shard_mode:-}" ]; then
    _so_how="shard $_sh_i of $_sh_n, $(printf '%s' "$_so_keep" | wc -w | tr -d ' ') section(s)"
  else
    _so_how="SECTION_ONLY resolved to $_so_name"
  fi
  printf '\nsuite_filtered_tail "%s" "%s"; exit $?\n' "$_so_how" "$_so_name" >> "$_filtered"

  # SECTION_ONLY drops a span out of the MIDDLE, which SECTION_UNTIL never does, so the seam that
  # proves the parse check works has to damage the middle too. An end-appended error would be a
  # different shape entirely and would prove nothing about this one (L165).
  if [ -n "${SUITE_EXTRACT_BREAK:-}" ]; then
    _so_mid="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
    _so_half=$(( $(grep -c '' "$_filtered") / 2 ))
    { sed -n "1,${_so_half}p" "$_filtered"; printf 'if then fi\n'; sed -n "$((_so_half + 1)),\$p" "$_filtered"; } > "$_so_mid"
    mv "$_so_mid" "$_filtered"
  fi
  if ! bash -n "$_filtered" 2>/dev/null; then
    rm -f "$_filtered"
    echo "test suite: running only '$SECTION_ONLY' produced a script that does not parse, so it was NOT run. This is a bug in the section extractor, not in the code under test. Run the full suite." >&2
    exit 3
  fi
  # SECTION_ONLY is handed on EMPTY, not merely relied on being ignored: the copy is the run that
  # spawns children, and a child seeing it set would filter itself, which is #37's defect exactly.
  # The run's own output is kept, because the result cannot be trusted without reading it. `set -u`
  # kills the whole shell on an unbound variable at TOP LEVEL, but only the SUBSHELL when the read
  # sits inside a command substitution, so a section missing a prerequisite can lose several tool
  # invocations, print nothing but ok lines, and exit 0. That is not hypothetical: one section in
  # this file was measured printing 54 ok lines and no failures, written down 2026-08-21, in exactly that
  # state, saved only by
  # a fifth read that happened to be at top level. pipefail is already set, and tee exits 0, so the
  # status here is still the run's own.
  _so_log="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  SUITE_FILTERED=1 SECTION_ONLY= SUITE_TARGET_SECTION="$_so_name" SUITE_TARGET_TITLES="$_so_titles_list" SUITE_DEPTH="$SUITE_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$_filtered" 2>&1 | tee "$_so_log"; _so_rc=$?
  rm -f "$_filtered"
  if grep -qE 'line [0-9]+: [A-Za-z_][A-Za-z0-9_]*: unbound variable' "$_so_log" 2>/dev/null; then
    rm -f "$_so_log"
    echo "" >&2
    echo "test suite: running only $_so_name hit an unbound variable, so it depends on something an earlier section sets and this run's result is NOT trustworthy: an unbound read inside a command substitution kills only that subshell, so a run in this state can print nothing but ok lines while tool invocations inside it produced nothing at all. Give the section its own fixture, or add a '# needs:' line naming the section that sets it." >&2
    exit 4
  fi
  rm -f "$_so_log"
  exit "$_so_rc"
fi

# ---- an unfiltered run executes from a copy too (#121) ----
# Bash reads a script incrementally from a byte offset, so editing THIS file while a run is in
# flight makes the running shell resume at the wrong place. Measured on 2026-08-21: inserting lines
# above one section made a run report three failures in a DIFFERENT section, every one of them
# fictional, and the same run passed once nothing was being edited. They name real sections and
# read exactly like real failures, and the only thing separating them is knowing what was happening
# at the time.
#
# The two filtered paths above already ran from a copy, as a side effect of having to extract
# sections. A plain full run did not, and a full run is the one people leave going for three
# minutes while they carry on editing. So it copies itself as well.
#
# It sits AFTER those paths (they exit, so this is reached only by an unfiltered run) and BEFORE
# the lock and the deadline below, so the copy is the process that takes the lock rather than one
# waiting on a parent that already holds it.
#
# SCRIPT and SCRIPT_SELF are handed over explicitly and still name the REAL files. Several checks
# in this suite read their own source, and a temp copy is not what they mean to be reading. The
# depth is passed through UNCHANGED for the same reason the SECTION_UNTIL path passes it through:
# this is the same logical run re-executed, not a run nested inside another (#34).
if [ -z "${SUITE_FROM_COPY:-}" ]; then
  _full_copy="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  cat "$0" > "$_full_copy"
  # It has to PARSE, for the same reason the extracted copies do: a copy that does not run at all
  # would report as the code under test failing. This one is a byte for byte copy so it can only
  # fail if the ORIGINAL is mid-edit right now, which is precisely the case being defended against,
  # and saying so is far more use than a screenful of syntax errors.
  if ! bash -n "$_full_copy" 2>/dev/null; then
    rm -f "$_full_copy"
    echo "test suite: the copy taken of this file does not parse, which means the file was being written while it was read. Nothing was run. Save your edits and start again." >&2
    exit 3
  fi
  SUITE_FROM_COPY=1 SUITE_DEPTH="$SUITE_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$_full_copy"
  _fc_rc=$?
  rm -f "$_full_copy"
  exit "$_fc_rc"
fi

# ---- the flag above describes THIS process only (#37) ----
# SUITE_FILTERED means "extraction already happened here, do not filter again". It arrives in the
# ENVIRONMENT, and bash hands an inherited variable to everything this run starts, so a child read
# it as being about ITSELF: it ignored the SECTION_UNTIL it was given, ran the WHOLE suite, reached
# a section that spawns, and started another. One process at a time rather than a burst, so no
# process count trips and it presents as a suite merely taking a while. It cost two runaways on
# 2026-08-17, and #34's depth limit bounds that damage without removing the trap (L169).
#
# `export -n` rather than `unset`: this process still needs the value (the #27 subruns below read
# it), and the only thing that has to stop is the inheritance. Done HERE, once, rather than at each
# spawn site, because a site added later cannot remember a rule it never saw (L30, L96).
#
# SUITE_NO_LOCK is on the list for a reason worth stating: inherited, it silently disables the very
# thing #32 is asserting. That section starts a second run and requires the lock to REFUSE it, so
# with the flag leaking through, the child took no lock, ran happily, and the checks that prove the
# lock works failed. Which means that before this, anybody running the suite with SUITE_NO_LOCK=1
# was running #32 against a lock nothing was testing (L169).
export -n SUITE_FILTERED SECTION_ONLY SECTION_LIST SUITE_FROM_COPY SUITE_SHARD SUITE_NO_LOCK SUITE_SHARD_NO_GROUPING 2>/dev/null || true

# SUITE_SPAWN_UNTIL=<text> starts ONE child with that section limit, says what a child of this run
# inherits, and exits with the child's status. It is the seam that makes the paragraph above
# provable from the outside: what matters is a run that RECEIVED the flag, and this stands a real
# run in that state for the cost of one section instead of a full suite. Placed ahead of the
# deadline and the lock, so a probe run takes neither.
# Its own value is cleared for the child, or the child spawns a probe too, which is the very shape
# being fixed here. Read into a variable of its own FIRST, and not passed straight from the one
# being cleared in the same prefix: the clear happens before the later assignment expands, so the
# child was handed an EMPTY section limit and ran the whole suite. It looked exactly like the
# inheritance bug this seam exists to catch, which is the one failure that would have been read as
# a real finding.
if [ -n "${SUITE_SPAWN_UNTIL:-}" ]; then
  _sp_until="$SUITE_SPAWN_UNTIL"
  echo "test suite: spawn probe; a child of this run inherits SUITE_FILTERED as: $(bash -c 'printf "%s" "${SUITE_FILTERED:-<unset>}"')"
  echo "test suite: spawn probe; a child of this run inherits SECTION_ONLY as: $(bash -c 'printf "%s" "${SECTION_ONLY:-<unset>}"')"
  SUITE_SPAWN_UNTIL= SUITE_DEPTH="$SUITE_CHILD_DEPTH" SECTION_UNTIL="$_sp_until" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF"; _sp_rc=$?
  echo "test suite: spawn probe; the child exited $_sp_rc"
  exit "$_sp_rc"
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
# Two numbers since #152, and the one that does the work is the SECOND.
#
# This used to be a single total, and the watchdog measured it by adding 2 to a counter once per
# `sleep 2`, so it counted ITERATIONS rather than time. Every iteration also forks `sleep` and a
# process check, and process launches are what a busy Mac is slowest at, so the counter ran far
# behind the clock: a full run measured at 1943s of wall clock on 2026-08-22 was never killed by
# its nominal 900s deadline, and the same loop asked for 60 seconds ran past 400 under load. The
# deadline silently meant somewhere between 900 and several thousand seconds depending on the mood
# of the machine (L82: the primitive's behaviour was the whole reason the guard was safe, and it
# had never been measured on the real target).
#
# Making it read a real clock is two lines, and on its own it would have KILLED that 1943s run,
# which was healthy and merely on a loaded machine. That is the false failure #149 exists to
# remove, arriving by another route. A wall clock total cannot tell a hung run from a slow one,
# which is the only distinction this deadline is for.
#
# So SUITE_STALL_TIMEOUT is what normally fires: how long the run may sit without reaching a new
# section. The run already records where it has got to, so a stopped run leaves that mark alone
# while a slow one keeps moving it, and a loaded machine moves it slowly rather than not at all.
# 1200s is comfortably longer than the slowest section this suite has, and the check at the end of
# the run compares it against what the sections ACTUALLY took rather than trusting this sentence to
# stay true. It was 600, chosen against a 34 second measurement, and the suite grew: on 2026-08-22
# the slowest section measured 44s idle, 62s with another full run competing, 88s with three, and
# once 208s, which put the 3x floor at 624 and turned the run red while nothing was wrong. The
# floor and the bound had met in the middle of the real spread (L172), so the bound moved rather
# than the floor: what the floor demands is the safety margin, and the margin was genuinely gone.
#
# SUITE_TIMEOUT stays as an absolute ceiling for a runaway that somehow keeps moving, and is now
# real wall clock. Raised to 3600 because it is no longer the thing that catches a hang: at 900 it
# would kill the 1943s run above, and being wrong LOW turns a contended machine into a false
# failure, which is how an alarm stops being read (L36).
#
# Either may be set to 0 to disable it. Both at 0 is a run with no bound at all, which is the state
# this exists to end, so it is refused.
SUITE_TIMEOUT="${SUITE_TIMEOUT:-3600}"
case "$SUITE_TIMEOUT" in
  ''|*[!0-9]*)
    echo "test suite: SUITE_TIMEOUT='$SUITE_TIMEOUT' is not a whole number of seconds. Refusing to run rather than running with no deadline at all, which is the state this exists to end." >&2
    exit 4 ;;
esac
SUITE_STALL_TIMEOUT="${SUITE_STALL_TIMEOUT:-1200}"
case "$SUITE_STALL_TIMEOUT" in
  ''|*[!0-9]*)
    echo "test suite: SUITE_STALL_TIMEOUT='$SUITE_STALL_TIMEOUT' is not a whole number of seconds. Refusing to run rather than running with no stall bound, which is what actually catches a hang." >&2
    exit 4 ;;
esac
# The GRANULARITY of everything above (claude-config#206). Both deadlines are read off a clock, so
# this changes no deadline; what it decides is the smallest stall this suite can STAGE, and that is
# a test property rather than a production one.
#
# It was two hard coded 2s sleeps that had to agree and were written three hundred lines apart: the
# watchdog's poll, and the pause SUITE_SLOW_IN puts in every section to make a run that is slow
# without ever stopping. A stall smaller than the larger of them cannot be staged at all, so the
# three sections that prove the deadline works had to spend real seconds doing it, and #152 alone
# cost 35 seconds of section time measured 2026-08-30.
#
# One unit, and the default is unchanged: a production run polls every 2 seconds exactly as before.
# The three sections set it to a tenth and scale their timeouts with it, which changes nothing
# about what they assert.
SUITE_POLL_INTERVAL="${SUITE_POLL_INTERVAL:-2}"
case "$SUITE_POLL_INTERVAL" in
  ''|*[!0-9.]*|.|*.*.*|0|0.0|0.00)
    echo "test suite: SUITE_POLL_INTERVAL='$SUITE_POLL_INTERVAL' is not a positive number of seconds. Refusing rather than guessing: zero would spin the watchdog against the clock with no sleep at all, and this decides how finely a stall can be noticed." >&2
    exit 4 ;;
esac
if [ "$SUITE_TIMEOUT" -eq 0 ] && [ "$SUITE_STALL_TIMEOUT" -eq 0 ]; then
  echo "test suite: SUITE_TIMEOUT and SUITE_STALL_TIMEOUT are both 0, so this run would have no bound of any kind. A wait with no deadline cannot fail, it can only hang, and a hang reads as an ordinary slow run (L110). Set at least one." >&2
  exit 4
fi
# Named from an explicit template, and not `mktemp -t`: the name is what lets an abandoned copy be
# attributed to this tool and reclaimed later (#36), and `-t` also means different things to BSD
# and GNU mktemp, which matters the moment this runs anywhere but a Mac.
SUITE_SECTION_MARK="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-section.XXXXXXXX")"
if [ "$SUITE_TIMEOUT" -gt 0 ] || [ "$SUITE_STALL_TIMEOUT" -gt 0 ]; then
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
    # Named with a TAG when one is given, so a run can find the watchdogs belonging to the runs IT
    # started rather than every watchdog on the machine (claude-config#159). The default run is
    # four shards and each has one of its own, so a global count moves for reasons that have
    # nothing to do with the runs being watched (L205, L134). Nothing sets this but the #31
    # section; a run with no tag is named exactly as before.
    exec -a "suite-deadline-watchdog${SUITE_WATCHDOG_TAG:+.$SUITE_WATCHDOG_TAG}" sh -c '
      # Both clocks are read from `date`, never accumulated from the sleeps (claude-config#152).
      # Each turn of this loop costs its sleep PLUS a fork of sleep and a process check, and on a
      # busy Mac that overhead is not small, so a counter built by adding the sleep length runs far
      # behind the clock and the deadline silently means whatever the machine felt like.
      ceiling="$2"; mark="$3"; stall="$4"; poll="$6"
      start="$(date +%s)"
      last="$(cat "$mark" 2>/dev/null || true)"
      moved="$start"
      why=""
      while :; do
        sleep "$poll"
        kill -0 "$1" 2>/dev/null || exit 0
        now="$(date +%s)"
        # Progress is the run reaching a NEW section. A stopped run leaves this alone; a slow one
        # keeps moving it, however slowly the machine is going.
        cur="$(cat "$mark" 2>/dev/null || true)"
        if [ "$cur" != "$last" ]; then last="$cur"; moved="$now"; fi
        if [ "$stall" -gt 0 ] && [ "$(( now - moved ))" -ge "$stall" ]; then why=stall; break; fi
        if [ "$ceiling" -gt 0 ] && [ "$(( now - start ))" -ge "$ceiling" ]; then why=ceiling; break; fi
      done
      where="$(cat "$mark" 2>/dev/null)"
      echo "" >&2
      # Two causes, two messages, because they need different remedies: a run that STOPPED is a
      # hang to diagnose, and a run that merely went on too long is a ceiling to raise (L11). Both
      # keep the words TIMED OUT and the section name, which is what anything reading this looks
      # for.
      if [ "$why" = stall ]; then
        echo "test suite: TIMED OUT: no progress for ${stall}s, still inside section: ${where:-<no section reached>}" >&2
        echo "It was killed rather than left waiting. A run that has stopped reaching new sections is hung, and a hang reads as an ordinary slow run (L110). A machine that is merely slow keeps moving between sections and is left alone, so raise SUITE_STALL_TIMEOUT only if one SECTION genuinely takes longer than that." >&2
      else
        echo "test suite: TIMED OUT: ${ceiling}s of wall clock, still inside section: ${where:-<no section reached>}" >&2
        echo "It was still making progress and simply ran past the absolute ceiling. Raise SUITE_TIMEOUT if this machine is genuinely that slow, or find what got slower." >&2
      fi
      # Kill the run AND everything it started. Killing only the run itself leaves its children
      # alive, and anything reading the run output then waits for THEM: a 6 second deadline
      # measured 60 on 2026-08-17, the length of the sleep the run happened to be sitting in. Its children are
      # also precisely what is still holding whatever the hung run acquired, which is half the
      # reason a hang is worse than a failure.
      # STOPPED FIRST, and that is the whole point (claude-config#174). A run that is still running
      # replaces what has just been killed underneath it: measured 2026-08-22, this run stalled in
      # `sleep 3600 & wait` had its sleep killed, its `wait` returned at once, and it started a new
      # one before the walk finished. Killing the run then left that replacement as an orphan
      # holding open the pipe its output was being read through, and the check reading that output
      # waited for an end of file that could never come.
      #
      # A stopped process cannot fork, so the window is closed rather than narrowed.
      #
      # The inline walk this replaces was measured in the SAME fixture and was clean without any
      # stop, so it did NOT have this race and the first version of this comment saying it did was
      # an inference that turned out to be wrong. Why the identical walk loses when it is called out
      # to a separate process is not established; stopping first removes the class either way.
      kill -STOP "$1" 2>/dev/null
      "$5" "$1" "" 2>/dev/null
      kill -9 "$1" 2>/dev/null
      rm -f "$3"    # the victim was killed outright and cannot clean up after itself
    ' suite-deadline-watchdog "$_suite_pid" "$SUITE_TIMEOUT" "$SUITE_SECTION_MARK" "$SUITE_STALL_TIMEOUT" "$SUITE_KILL_TREE" "$SUITE_POLL_INTERVAL"
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
# Everything this run started, killed from the leaves up (claude-config#163), through the one
# shared implementation (#169). Only ever DESCENDANTS: this must not reach the process that started
# the suite, and it must not reach the shell running it.
suite_kill_tree(){   # $1 = a pid whose descendants are to go   $2 = optional file to list them in
  bash "$SUITE_KILL_TREE" "$1" "${2:-}" 2>/dev/null || true
  return 0
}

# What a run killed OUTRIGHT left behind (claude-config#166). Read from that run's own registry,
# named by its lock, so this can only ever reach processes that run started.
#
# Every number is confirmed to still BE a run of this suite immediately before the kill. A registry
# is a list of numbers, numbers get reused, and killing whatever holds one now rather than what held
# it then is how somebody's unrelated work gets killed: a judgement formed before the act is not a
# judgement about the thing being acted on (L157).
suite_clear_registered_strays(){   # $1 = the lock directory of the run that is gone
  local reg p cmd n=0 stuck=""
  reg="$(cat "$1/registry" 2>/dev/null || true)"
  [ -n "$reg" ] || return 0
  [ -f "$reg" ] || return 0
  while IFS= read -r p; do
    case "$p" in ''|*[!0-9]*) continue ;; esac
    [ "$p" = "$$" ] && continue
    kill -0 "$p" 2>/dev/null || continue
    cmd="$(ps -o command= -p "$p" 2>/dev/null || true)"
    case "$cmd" in *"$SCRIPT_SELF"*) ;; *) continue ;; esac
    # Stopped before its tree is walked, for the reason spelt out in the watchdog above: a process
    # that is still running replaces what has just been killed underneath it (claude-config#174).
    kill -STOP "$p" 2>/dev/null
    suite_kill_tree "$p"
    # Woken again if the kill did not take. A stopped process that is never killed is WORSE than
    # the leftover this exists to clear: it uses nothing, it never exits, and it does not look
    # wrong in a process listing, so nobody finds it. A failure has to leave things as they were
    # rather than in a state this created (L5).
    #
    # And SAID. The first version of this woke it and moved on, so the report gave a count of what
    # it cleared and nothing at all about what it could not, which means the one case a reader has
    # to act on was the one case it went quiet on (L11, L98). SUITE_CLEAR_KILL_FAILS is the seam
    # that produces it: there is no process here this suite genuinely cannot kill, and arranging one
    # would be a fixture about permissions rather than about the report.
    if [ -n "${SUITE_CLEAR_KILL_FAILS:-}" ] || ! kill -9 "$p" 2>/dev/null; then
      kill -CONT "$p" 2>/dev/null
      kill -0 "$p" 2>/dev/null && stuck="$stuck $p"
      continue
    fi
    n=$(( n + 1 ))
  done < "$reg"
  # Consumed, or the next run over the same lock reports clearing the same processes again and the
  # count stops being a measurement of anything.
  rm -f "$reg"
  # Said only when it actually cleared something. A takeover that found nothing to clear and one
  # that cleared four are different facts, and a line printed either way is neither (L98, L11).
  [ "$n" -gt 0 ] && echo "test suite: and cleared $n process(es) that run left running. A run killed outright cannot clean up after itself, so this happens here rather than there, which means it is after the fact: anything it started that no longer names this suite is deliberately NOT touched." >&2
  # Separately, and named. A count of what was cleared says nothing about what was not, and these
  # are still going: they are left RUNNING rather than frozen, so they are at least visible in a
  # process listing, and this says which ones and what to do about them.
  [ -n "$stuck" ] && echo "test suite: and could not kill$stuck, which that run also left running. They are still going and this could not stop them, so end them yourself with: kill -9$stuck" >&2
  return 0
}

suite_cleanup(){
  [ -n "${SUITE_WATCHDOG_PID:-}" ] && kill "$SUITE_WATCHDOG_PID" 2>/dev/null
  # And everything else this run started, not only the watchdog (claude-config#163). On a run that
  # ends normally there is nothing left to find and this is a no-op; on one killed from outside it
  # is the whole point, because the re-executed copy and the shards are what go on running as
  # orphans and go on holding the lock.
  suite_kill_tree "$$"
  [ -n "${SUITE_SECTION_MARK:-}" ] && rm -f "$SUITE_SECTION_MARK"
  # Only a run that actually TOOK the lock releases it, or a run that refused would delete the
  # lock belonging to the run it just refused for.
  [ -n "${SUITE_LOCK_HELD:-}" ] && rm -rf "$SUITE_LOCK"
  # Only the run that CREATED it, or a nested run would delete the registry its parent is still
  # registering into and the parent's own leftovers would become unclearable.
  [ -n "${SUITE_RUN_REGISTRY_OWNED:-}" ] && [ -n "${SUITE_RUN_REGISTRY:-}" ] && rm -f "$SUITE_RUN_REGISTRY"
  [ -n "${WORK:-}" ] && rm -rf "$WORK"
  return 0
}
trap suite_cleanup EXIT
# And on the signals an interrupt actually arrives as, which EXIT alone does not cover in any way
# anybody should rely on (claude-config#163). Bash happens to run an EXIT trap on a fatal signal
# today, which is why the lock was already being released; nothing states that it must, the exit
# status it leaves is the run's last one rather than the signal, and HUP (a terminal closing) is a
# real way for a run in development to end. Said explicitly, one handler, each ending in the status
# its own signal means. The EXIT trap fires again on the way out, and everything the handler does
# is safe to do twice.
trap 'suite_cleanup; exit 130' INT
trap 'suite_cleanup; exit 143' TERM
trap 'suite_cleanup; exit 129' HUP

# A run killed by the deadline above cannot release its lock, and deliberately nothing tries to do
# it on the run's behalf: the next run finds a recorded process that is gone and takes over saying
# so, which is the same recovery a crash needs and is therefore the path worth having work.
# Both removals below are `rm -rf` on a path that arrives from the environment, so a typo naming
# somewhere real would delete it. Refused up front rather than relied on being caught by one of the
# ownership rules further down, which is where it happens to land today (L5, L9).
# Read through a default first. TMPDIR is always set on a Mac and is NOT set on a Linux runner, and
# `${TMPDIR%/}` under `set -u` is an error rather than an empty string, so the suite died on its
# second line there while every Mac ran it for months (L153: a location that happens to be true of
# one machine is not a fact about the environment).
_SUITE_TMPROOT="${TMPDIR:-/tmp}"
case "${SUITE_LOCK%/}" in
  ''|/|"${HOME%/}"|"${_SUITE_TMPROOT%/}")
    echo "test suite: SUITE_LOCK='$SUITE_LOCK' names a real directory rather than a lock of its own. Refusing, because taking over a stale lock removes the directory it is in." >&2
    exit 5 ;;
esac
# A directory holding no pid file was not written by this tool, whatever else it is, so it is never
# cleared. The two rules are separate on purpose: the one above catches a path that is obviously
# somewhere else, and this one catches everything else it could possibly be.
suite_lock_is_ours(){
  [ -f "$SUITE_LOCK/pid" ] || [ -z "$(ls -A "$SUITE_LOCK" 2>/dev/null)" ]
}
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
      # Its OWN, overriding anything inherited: a run that takes the lock is the top of a run, and
      # recording somebody else's registry in the lock would point a later takeover at processes
      # this run never started. Exported, so everything it starts from here lands in it: the shards
      # and the re-executed copy are exactly what survives a force-kill.
      SUITE_RUN_REGISTRY="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-run.XXXXXXXX")"
      SUITE_RUN_REGISTRY_OWNED=1
      export SUITE_RUN_REGISTRY
      printf '%s\n' "$$" > "$SUITE_RUN_REGISTRY"
      printf '%s\n' "$SUITE_RUN_REGISTRY" > "$SUITE_LOCK/registry"
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
        # What is holding it, how old it is, and the command that ends it (claude-config#163). A
        # pid on its own is not something anybody can act on: it has no visible connection to the
        # run they killed minutes ago, and a refusal naming only a number sent two separate
        # investigations looking for a bug in the suite (L80, L148). The orphan case is named
        # explicitly, because it is the commonest reason a live run is here that nobody expects.
        echo "test suite: another run is already going: a suite run, process $_lk_pid on $_lk_host, started ${_lk_age}s ago. Refusing rather than queueing behind it: two suites competing for this machine make each other slower and make every timing either of them reports wrong. Wait for it to finish. If you killed a run and this is the orphan it left behind, end it and everything it started with: pkill -9 -P $_lk_pid; kill -9 $_lk_pid. Or run with SUITE_NO_LOCK=1 if you know it is finished." >&2
        exit 5
      fi
      echo "test suite: took over a lock whose run is gone (process $_lk_pid is not running)." >&2
      # Before the lock directory is removed below, since that is where the registry is named.
      suite_clear_registered_strays "$SUITE_LOCK"
    else
      if [ "$_lk_age" -lt "${SUITE_LOCK_MAX_AGE:-1800}" ]; then
        # Deliberately NOT the message above. That one hands over a command to kill the holder,
        # and the holder here is a process on a DIFFERENT machine: the number means nothing on this
        # one, and a kill aimed at it would land on an unrelated local process. Distinct causes,
        # distinct remedies (L11, L111).
        echo "test suite: another run is already going: a suite run on $_lk_host, which is not this machine, process $_lk_pid there, started ${_lk_age}s ago. Refusing rather than queueing behind it. Nothing here can end it, and its process id means nothing on this machine, so wait for it, clear $SUITE_LOCK yourself if that machine is gone, or run with SUITE_NO_LOCK=1 if you know it is finished." >&2
        exit 5
      fi
      # 30 minutes against a full run, which was measured at 123 seconds on 2026-08-17 and at 243
      # seconds in a single process on 2026-08-21, so between 7x and 15x the real thing. It is the
      # one threshold where being wrong LOW starts a second run on top of a live one.
      echo "test suite: took over a lock from $_lk_host that is ${_lk_age}s old, older than any run can be." >&2
    fi
    if ! suite_lock_is_ours; then
      echo "test suite: $SUITE_LOCK exists but holds no record of a run, so it was not written by this tool. Refusing to remove it. Point SUITE_LOCK somewhere else, or clear that directory yourself if it really is a leftover lock." >&2
      exit 5
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

# ---- a full run fans its sections out across processes (#133) ----
# Measured on 2026-08-21, over the 82 sections it held then: about 200 seconds in all, and no
# single one dominating, the slowest five at 22s, 13s, 11s, 11s and 9s here. So there is nothing to
# speed up, only work to spread. Since #125 the whole repo's suites run side by side and this one
# is the single longest, which makes it the entire remaining wall clock.
#
# HERE, after the lock: the parent holds it and the shards run with SUITE_NO_LOCK=1, so this is one
# logical run holding one lock rather than N runs fighting over it. The depth is passed through
# UNCHANGED for the same reason the filtered paths pass it through: this is the same logical run
# re-executed, not a run nested inside one, and counting it would refuse the subruns that several
# sections start (#34).
#
# The shards' output is printed in shard order, never completion order, so two runs of the same
# tree produce the same page (#125).
#
# The total counts the PRELUDE once per shard, because every shard has to run it to have any
# fixtures at all. That is stated rather than hidden: the number is genuinely larger than a
# one-process run's and it is not a bug to chase.
# ---- the shards, between them, must have covered every section (#137) ----
# Reads the shards' coverage lines and answers whether every section after the prelude was the
# target of exactly one of them. Silent and 0 when it was; a complaint and 1 when it was not.
#
# A function rather than a few lines inside the fan-out, because the fan-out is the one place it
# would be exercised and a full run is minutes: every outcome enumerated below is produced by the
# suite against fabricated lines, and the real shards are then put through this same function, so
# the thing proven and the thing shipped are one implementation (L151, L52).
#
# The order of the complaints is deliberate. An unreadable line, or a shard that said nothing,
# leaves that shard's sections out of the union, so the gap message would fire too and would
# accuse the selector of the reader's problem. Those return first and alone (L11).
# Reads the shards' output files and puts the verdict over them. The reading is HERE rather than
# inline in the fan-out so that the file names and the pattern are exercised by the suite too: a
# grep that matches nothing looks exactly like a shard with nothing to say, and the fan-out is the
# one place it would otherwise run, which is a full run away (L100, L143).
shard_coverage_over_dir(){   # $1 = directory of <shard>.out files, $2 = shards expected
  local _cd_dir="$1" _cd_n="$2" _cd_i=1 _cd_all=""
  while [ "$_cd_i" -le "$_cd_n" ]; do
    _cd_all="$_cd_all$(grep -m1 '^SUITE-SHARD-COVERAGE ' "$_cd_dir/$_cd_i.out" 2>/dev/null)
"
    _cd_i=$((_cd_i + 1))
  done
  printf '%s\n' "$_cd_all" | shard_coverage_verdict "$_cd_n"
}

shard_coverage_verdict(){   # $1 = shards expected; coverage lines on stdin
  local _cv_n="${1:-}" _cv_line _cv_i _cv_f _cv_l _cv_s _cv_x _cv_k
  local _cv_first="" _cv_last="" _cv_seen=" " _cv_got=" "
  local _cv_bad="" _cv_dis="" _cv_dup="" _cv_gone="" _cv_miss="" _cv_extra="" _cv_say=""
  case "$_cv_n" in
    ''|*[!0-9]*|0) printf 'shard coverage: asked to check against "%s" shards, which is not a count of them.\n' "$_cv_n"; return 2 ;;
  esac
  while IFS= read -r _cv_line; do
    case "$_cv_line" in 'SUITE-SHARD-COVERAGE '*) ;; *) continue ;; esac
    _cv_i="${_cv_line#*shard=}";    _cv_i="${_cv_i%% *}"
    _cv_f="${_cv_line#*first=}";    _cv_f="${_cv_f%% *}"
    _cv_l="${_cv_line#*last=}";     _cv_l="${_cv_l%% *}"
    _cv_s="${_cv_line#*sections=}"; _cv_s="${_cv_s%% *}"
    # A field that is absent leaves the whole line in place of it, which is not a number, so this
    # catches a missing field and a mangled one by the same rule.
    # Kept on ONE line, brackets and all. The complaint has to be readable as a single fact
    # (which line, and that it could not be read), or a reader matching the wording finds it
    # beside a line from somewhere else entirely (#74, L178).
    case "$_cv_i$_cv_f$_cv_l" in ''|*[!0-9]*) _cv_bad="$_cv_bad [$_cv_line]"; continue ;; esac
    case "$_cv_s" in ''|*[!0-9,]*) _cv_bad="$_cv_bad [$_cv_line]"; continue ;; esac
    _cv_got="$_cv_got$_cv_i "
    if [ -z "$_cv_first" ]; then
      _cv_first="$_cv_f"; _cv_last="$_cv_l"
    elif [ "$_cv_f" != "$_cv_first" ] || [ "$_cv_l" != "$_cv_last" ]; then
      _cv_dis="$_cv_dis shard $_cv_i says $_cv_f to $_cv_l;"
    fi
    for _cv_x in $(printf '%s' "$_cv_s" | tr ',' ' '); do
      case "$_cv_seen" in
        *" $_cv_x "*) _cv_dup="$_cv_dup $_cv_x" ;;
        *) _cv_seen="$_cv_seen$_cv_x " ;;
      esac
    done
  done
  if [ -n "$_cv_bad" ]; then
    printf 'shard coverage: a coverage line could not be read, so what that shard selected is unknown and this run cannot claim the sections were covered:%s\n' "$_cv_bad"
    return 1
  fi
  _cv_k=1
  while [ "$_cv_k" -le "$_cv_n" ]; do
    case "$_cv_got" in *" $_cv_k "*) ;; *) _cv_gone="$_cv_gone $_cv_k" ;; esac
    _cv_k=$((_cv_k + 1))
  done
  if [ -n "$_cv_gone" ]; then
    printf 'shard coverage: shard(s)%s printed no coverage line, so which sections they selected is unknown. Treat this run as failed rather than as covered.\n' "$_cv_gone"
    return 1
  fi
  if [ -n "$_cv_dis" ]; then
    printf 'shard coverage: the shards disagree about which sections exist (%s to %s, but%s), so there is no set for them to have covered.\n' "$_cv_first" "$_cv_last" "$_cv_dis"
    return 1
  fi
  _cv_k="$_cv_first"
  while [ "$_cv_k" -le "$_cv_last" ]; do
    case "$_cv_seen" in *" $_cv_k "*) ;; *) _cv_miss="$_cv_miss $_cv_k" ;; esac
    _cv_k=$((_cv_k + 1))
  done
  for _cv_x in $_cv_seen; do
    if [ "$_cv_x" -lt "$_cv_first" ] || [ "$_cv_x" -gt "$_cv_last" ]; then _cv_extra="$_cv_extra $_cv_x"; fi
  done
  [ -z "$_cv_miss" ]  || _cv_say="$_cv_say section(s)$_cv_miss ran in no shard at all;"
  [ -z "$_cv_dup" ]   || _cv_say="$_cv_say section(s)$_cv_dup were selected by more than one shard;"
  [ -z "$_cv_extra" ] || _cv_say="$_cv_say section(s)$_cv_extra are outside the $_cv_first to $_cv_last the shards agreed on;"
  if [ -n "$_cv_say" ]; then
    printf 'shard coverage: the shards did not divide the sections between them:%s The numbers are positions in the section list, which SECTION_LIST=1 prints.\n' "$_cv_say"
    return 1
  fi
  return 0
}

# ---- the shards, between them, ran every section ONCE (#146) ----
# The headline used to be the sum of the shards' totals, which counted the prelude once per shard
# and any `# needs:` prerequisite once per borrowing shard, so it moved with how much of the
# machine the run was granted: 873 in one process and 1118 across eight, of the same file on
# 2026-08-21. A number that moves for reasons unrelated to the tests cannot answer the one question
# it exists for, which is whether checks were lost (L63).
#
# So each shard says what its checks were worth in three buckets and the headline is the prelude
# ONCE plus every shard's targets, which is every section exactly once, since #137 already proves
# the targets are divided between the shards with nothing missing and nothing doubled.
#
# One value getter, not eight, because eight copies of the same `${x#*key=}` would be eight places
# for one of them to name the wrong key and read a neighbouring number instead.
_fv_get(){   # _fv_get <line> <key> -> the value, or nothing if it is not a whole number
  case "$1" in *" $2="*) ;; *) return 0 ;; esac
  _fg="${1#*" $2="}"; _fg="${_fg%% *}"
  case "$_fg" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' "$_fg"
}

# Prints "<pass> <fail> <prelude pass> <prelude fail> <repeated pass> <repeated fail>" and returns
# 0 when the lines can carry a headline; otherwise prints why and returns non-zero.
#
# The order of the complaints matters. A line that cannot be read leaves that shard's targets out
# of the sum, so the totals would be wrong too and reporting both would send the reader looking for
# two faults where there is one (L11).
fan_totals_verdict(){   # $1 = shards expected; SUITE-SECTIONS lines on stdin
  _fv_n="$1"
  case "$_fv_n" in
    ''|*[!0-9]*|0) printf 'section totals: asked to check against "%s" shards, which is not a count of them.\n' "$_fv_n"; return 2 ;;
  esac
  _fv_seen=""; _fv_bad=""; _fv_pp=""; _fv_pf=""; _fv_dis=""
  _fv_tp=0; _fv_tf=0; _fv_rp=0; _fv_rf=0; _fv_short=""
  while IFS= read -r _fv_l; do
    case "$_fv_l" in 'SUITE-SECTIONS '*) ;; *) continue ;; esac
    _fv_i="$(_fv_get "$_fv_l" shard)"
    _fv_a="$(_fv_get "$_fv_l" prelude_pass)"; _fv_b="$(_fv_get "$_fv_l" prelude_fail)"
    _fv_c="$(_fv_get "$_fv_l" target_pass)";  _fv_d="$(_fv_get "$_fv_l" target_fail)"
    _fv_e="$(_fv_get "$_fv_l" repeat_pass)";  _fv_g="$(_fv_get "$_fv_l" repeat_fail)"
    _fv_h="$(_fv_get "$_fv_l" total_pass)";   _fv_j="$(_fv_get "$_fv_l" total_fail)"
    if [ -z "$_fv_i" ] || [ -z "$_fv_a" ] || [ -z "$_fv_b" ] || [ -z "$_fv_c" ] || [ -z "$_fv_d" ] \
       || [ -z "$_fv_e" ] || [ -z "$_fv_g" ] || [ -z "$_fv_h" ] || [ -z "$_fv_j" ]; then
      _fv_bad="$_fv_bad $(printf '%s' "$_fv_l" | cut -c1-60);"
      continue
    fi
    _fv_seen="$_fv_seen $_fv_i"
    # The buckets have to account for that shard's OWN total, or checks ran in no bucket at all and
    # the headline would leave them out while looking exactly like a correct one (L16).
    if [ "$(( _fv_a + _fv_c + _fv_e ))" -ne "$_fv_h" ] || [ "$(( _fv_b + _fv_d + _fv_g ))" -ne "$_fv_j" ]; then
      _fv_short="$_fv_short shard $_fv_i says $_fv_h passed and $_fv_j failed, but its buckets add up to $(( _fv_a + _fv_c + _fv_e )) and $(( _fv_b + _fv_d + _fv_g ));"
      continue
    fi
    if [ -z "$_fv_pp" ]; then
      _fv_pp="$_fv_a"; _fv_pf="$_fv_b"
    elif [ "$_fv_a" -ne "$_fv_pp" ] || [ "$_fv_b" -ne "$_fv_pf" ]; then
      _fv_dis="$_fv_dis shard $_fv_i says $_fv_a passed and $_fv_b failed;"
    fi
    _fv_tp=$(( _fv_tp + _fv_c )); _fv_tf=$(( _fv_tf + _fv_d ))
    _fv_rp=$(( _fv_rp + _fv_e )); _fv_rf=$(( _fv_rf + _fv_g ))
  done
  if [ -n "$_fv_bad" ]; then
    printf 'section totals: a line could not be read, so what that shard ran is unknown and this run cannot claim a total:%s\n' "$_fv_bad"
    return 1
  fi
  if [ -n "$_fv_short" ]; then
    printf 'section totals: a shard has checks that belong to no section at all, so a headline built from its buckets would leave them out:%s\n' "$_fv_short"
    return 1
  fi
  _fv_gone=""
  _fv_k=1
  while [ "$_fv_k" -le "$_fv_n" ]; do
    case " $_fv_seen " in *" $_fv_k "*) ;; *) _fv_gone="$_fv_gone $_fv_k" ;; esac
    _fv_k=$(( _fv_k + 1 ))
  done
  if [ -n "$_fv_gone" ]; then
    printf 'section totals: shard(s)%s said nothing about which sections their checks came from, so those checks are in no bucket and the total below would be missing them. Treat this run as failed rather than as counted.\n' "$_fv_gone"
    return 1
  fi
  if [ -n "$_fv_dis" ]; then
    printf 'section totals: the shards disagree about the prelude, which is the same sections in every one of them (%s passed and %s failed, but%s), so one of them ran something different and neither number can be subtracted.\n' "$_fv_pp" "$_fv_pf" "$_fv_dis"
    return 1
  fi
  # The prelude once, plus every target. The repeats are the prelude's other runs plus whatever was
  # borrowed through a needs: declaration, and they are reported, never folded in.
  printf '%s %s %s %s %s %s\n' \
    "$(( _fv_pp + _fv_tp ))" "$(( _fv_pf + _fv_tf ))" \
    "$_fv_pp" "$_fv_pf" \
    "$(( _fv_rp + (_fv_n - 1) * _fv_pp ))" "$(( _fv_rf + (_fv_n - 1) * _fv_pf ))"
  return 0
}

# Reads the shards' output files and puts the verdict over them. Here rather than inside the
# verdict for the same reason the coverage reader is: the verdict has to be drivable with lines
# this suite writes, and a grep that matches nothing looks exactly like a shard with nothing to
# say. The shard NUMBER is attached here, because the shard itself is a filtered run and does not
# know which of them it is.
fan_totals_over_dir(){   # $1 = directory of <shard>.out files, $2 = shards expected
  _fd_all=""
  _fd_i=1
  while [ "$_fd_i" -le "$2" ]; do
    _fd_l="$(grep -m1 '^SUITE-SECTIONS ' "$1/$_fd_i.out" 2>/dev/null)"
    [ -z "$_fd_l" ] || _fd_all="$_fd_all$_fd_l shard=$_fd_i
"
    _fd_i=$(( _fd_i + 1 ))
  done
  printf '%s\n' "$_fd_all" | fan_totals_verdict "$2"
}

#
# How many shards is a SHARE of one budget, not a number of its own (claude-config#136). The runner
# starts several suites at once and this one splits itself again, and the two numbers were set
# independently and compared nowhere, so a four core machine could carry a dozen heavy processes,
# each spawning git and python. It never went red. Oversubscription makes timing sensitive checks
# intermittently wrong instead, and this suite's own deadline guard was measured firing at 1192s
# against a normal 200 on a loaded Mac, written down 2026-08-21, which is the hardest kind of failure to
# attribute.
#
# So run-all-tests.sh hands down HOOK_TESTS_SLOTS, this suite's share of the whole run's budget,
# and that is the default. An explicit SUITE_JOBS still wins: a share is allocated to somebody, a
# value in the environment is somebody asking. 4 remains the answer when nothing granted anything,
# which is what a run started by hand looks like.
#
# An EMPTY grant is an absent one, matching what `:-` does for every other knob here. An
# unreadable one is REFUSED rather than guessed at, and it comes from another program, so guessing
# would leave that program wrong and nothing saying so (L50).
_sj_src="default"
_sj_default=4
if [ -n "${HOOK_TESTS_SLOTS:-}" ]; then
  case "$HOOK_TESTS_SLOTS" in
    *[!0-9]*|0)
      echo "test suite: HOOK_TESTS_SLOTS='$HOOK_TESTS_SLOTS' is not a positive whole number of processes this suite may take. Refusing rather than guessing: it arrives from run-all-tests.sh, so a value nobody can read means that is wrong, and running four shards anyway would hide it." >&2
      exit 2 ;;
  esac
  _sj_default="$HOOK_TESTS_SLOTS"
  _sj_src="HOOK_TESTS_SLOTS"
fi
[ -z "${SUITE_JOBS:-}" ] || _sj_src="SUITE_JOBS"
SUITE_JOBS="${SUITE_JOBS:-$_sj_default}"
case "$SUITE_JOBS" in
  ''|*[!0-9]*)
    echo "test suite: SUITE_JOBS='$SUITE_JOBS' is not a whole number of shards. Refusing rather than guessing, because it decides how many processes start. Use 1 to run in a single process." >&2
    exit 2 ;;
esac
# SUITE_PLAN_ONLY=1 says which number was chosen and where it came from, and runs nothing. The
# number decides what a run costs, and the only other way to see it is to pay that cost (L102).
# The SOURCE is part of the answer: a number that surprises somebody is only actionable once it
# says who chose it (L11).
if [ -n "${SUITE_PLAN_ONLY:-}" ]; then
  printf 'SUITE-PLAN jobs=%s source=%s\n' "$SUITE_JOBS" "$_sj_src"
  exit 0
fi
# ---- what this run COST, in a unit the rest of the machine cannot move (claude-config#149) ----
# Wall clock measures the machine's mood as much as the suite's size. Eight full runs on
# 2026-08-21, while Lightroom, Xcode and Backblaze had this Mac at load 38 to 103, made four
# different checks go red that all passed on the same tree at load 15, and the single process run
# that normally takes 243 seconds took 854. A red result that has to be re-run before it is
# believed stops being read, which is the exact failure the deadline it guards exists to avoid
# (L36), and the pre-push gate blocks on these, so a busy Mac blocked a correct push.
#
# Processor time does not move like that. Other software competing for the machine stretches how
# long this run WAITS; it does not make this run's own work cost more instructions. Measured on
# this Mac, all of it written down 2026-08-21: 202s of processor time for a single process run and
# 262s across four shards, against wall clocks of 348s and 160s over the same tree.
#
# `times` is a bash builtin, so asking costs no process. It reports this shell and everything it
# has WAITED for, which is the whole run: the shards are started here and waited for here, and a
# waited child's own children are already folded into its figure.
#
# Whole seconds, and a figure that cannot be read comes back as NOTHING rather than as zero. Zero
# is the most reassuring answer available: it would satisfy every headroom check for ever, and a
# broken reader would be indistinguishable from a suite that costs nothing (L90).
_cpu_field(){   # 0m12.34s -> whole seconds, or nothing
  local _cf_v="$1" _cf_m _cf_s
  case "$_cf_v" in *m*s) ;; *) return 0 ;; esac
  _cf_m="${_cf_v%%m*}"
  _cf_s="${_cf_v#*m}"; _cf_s="${_cf_s%s}"; _cf_s="${_cf_s%%.*}"
  case "$_cf_m$_cf_s" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s' $(( _cf_m * 60 + _cf_s ))
}
# Answers in a VARIABLE rather than on stdout, and is called directly rather than inside `$( )`.
# `times` reports the shell it runs in, and a command substitution is a fork: a subshell starts
# with both its own and its children's clocks at zero, so a reader that printed its answer would
# be reporting the cost of the subshell that was asked, which is a few milliseconds old. It read
# 0s for a run of any size. Redirecting a builtin to a file does NOT fork, so that is how the
# figure is got out (L196: a component that constructs its own context is beyond what the caller
# can see).
SUITE_CPU_SECONDS=""
# What the end of a full run says about the deadline's headroom, and whether that fails the run.
#
# A FUNCTION rather than a block at the end of the fan-out (claude-config#167). It has three things
# it can say and a silence, and while it sat inline the only way to reach any of them was a full
# unfiltered run on a machine in the right state, so the arm that FAILS a run had never run at all.
# A guard is only real once it has been watched failing (L1), and this is the one that decides
# whether the suite has outgrown its own deadline.
#
# The WALL CLOCK decides whether there is anything to say, because that is what runs out against the
# ceiling. The PROCESSOR time decides which of two different things is happening, and they need
# different remedies (L11): a run that filled its own clock with its own work has grown into its
# deadline and is worth failing over, while one that merely waited on a busy Mac is a fact about the
# machine, and "find what got slower" is not an action anybody can take on it (L112, L36).
#
# Measured on the same tree on 2026-08-22: 348s of wall clock idle, which is a tenth of the ceiling
# and says nothing at all, and 1943s at load 160 to 188 with only 262s of it this suite's own work.
suite_headroom_report(){   # $1 = wall clock seconds  $2 = processor seconds or empty  $3 = ceiling
  local elapsed="$1" cpu="$2" ceiling="$3"
  case "$ceiling" in ''|*[!0-9]*) return 0 ;; esac
  [ "$ceiling" -gt 0 ] || return 0
  case "$elapsed" in ''|*[!0-9]*) return 0 ;; esac
  # A reader that came back with NOTHING has measured nothing, and nothing must never be read as a
  # figure of zero: zero clears every headroom test there is, so a broken reader would be
  # indistinguishable from a suite that costs nothing at all (L90, L98). Said out loud rather than
  # skipped, because a check that silently measured nothing reads exactly like one that passed.
  case "$cpu" in
    ''|*[!0-9]*)
      echo "test suite: the processor time for this run could not be read, so what filled its ${elapsed}s of wall clock is not known and the deadline's headroom was NOT checked. The run itself is unaffected." >&2
      return 0 ;;
  esac
  [ "$ceiling" -lt $(( elapsed * 2 )) ] || return 0
  if [ $(( cpu * 2 )) -ge "$elapsed" ]; then
    echo "test suite: this run took ${elapsed}s of wall clock against a ${ceiling}s deadline, which is less than twice it, and ${cpu}s of that was the suite's own work. It has grown into its own deadline rather than waited on a busy machine. Raise SUITE_TIMEOUT, or find what got slower." >&2
    return 1
  fi
  echo "test suite: note, this run took ${elapsed}s of wall clock against a ${ceiling}s deadline, but only ${cpu}s of processor time, so the machine was busy with something else rather than the suite having grown. Not treated as a failure." >&2
  return 0
}

suite_cpu_read(){   # sets SUITE_CPU_SECONDS to whole seconds, or to nothing
  local _cs_f _cs_a _cs_b _cs_x _cs_n _cs_tot=0 _cs_any=0
  SUITE_CPU_SECONDS=""
  _cs_f="$SUITE_SCRATCH_HOME/claude-sync-suite-cpu.$$"
  times > "$_cs_f" 2>/dev/null || return 0
  while read -r _cs_a _cs_b; do
    for _cs_x in "$_cs_a" "$_cs_b"; do
      _cs_n="$(_cpu_field "$_cs_x")"
      [ -n "$_cs_n" ] || continue
      _cs_tot=$(( _cs_tot + _cs_n )); _cs_any=1
    done
  done < "$_cs_f"
  rm -f "$_cs_f"
  [ "$_cs_any" -eq 1 ] || return 0
  SUITE_CPU_SECONDS="$_cs_tot"
}

if [ "$SUITE_DEPTH" -eq 0 ] && [ -z "${SUITE_FILTERED:-}" ] && [ -z "${SUITE_SHARD:-}" ] && [ "$SUITE_JOBS" -gt 1 ]; then
  _fan_dir="$(mktemp -d "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  _fan_pids=""
  _fan_i=1
  while [ "$_fan_i" -le "$SUITE_JOBS" ]; do
    SUITE_SHARD="$_fan_i/$SUITE_JOBS" SUITE_NO_LOCK=1 SUITE_DEPTH="$SUITE_DEPTH"       SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF"       bash "$SCRIPT_SELF" > "$_fan_dir/$_fan_i.out" 2>&1 &
    _fan_pids="$_fan_pids $!"
    _fan_i=$((_fan_i + 1))
  done
  _fan_rc=0
  for _fan_p in $_fan_pids; do wait "$_fan_p" || _fan_rc=1; done

  _fan_pass=0; _fan_fail=0; _fan_missing=""
  _fan_i=1
  while [ "$_fan_i" -le "$SUITE_JOBS" ]; do
    echo ""
    echo "===== shard $_fan_i of $SUITE_JOBS ====="
    cat "$_fan_dir/$_fan_i.out" 2>/dev/null
    _fan_line="$(grep -E '^SUITE-RESULT passed=[0-9]+ failed=[0-9]+$' "$_fan_dir/$_fan_i.out" 2>/dev/null | tail -1)"
    if [ -n "$_fan_line" ]; then
      _fan_p2="${_fan_line#*passed=}"; _fan_p2="${_fan_p2%% *}"
      _fan_f2="${_fan_line#*failed=}"
      _fan_pass=$((_fan_pass + _fan_p2)); _fan_fail=$((_fan_fail + _fan_f2))
    else
      # A shard that printed no result line reported NOTHING, and a missing total must never be
      # added in as a zero: that reads as a shard where everything passed (L98, L90).
      _fan_missing="$_fan_missing $_fan_i"
      _fan_rc=1
    fi
    _fan_i=$((_fan_i + 1))
  done
  # Whether the shards, between them, ran every section (#137). Read before the directory goes.
  _fan_cov_say="$(shard_coverage_over_dir "$_fan_dir" "$SUITE_JOBS")" || {
    echo "test suite: $_fan_cov_say" >&2
    _fan_rc=1
  }
  # And how their checks divide up, so every section is counted once (#146). Read here, from the
  # same directory, before it goes.
  _fan_tot="$(fan_totals_over_dir "$_fan_dir" "$SUITE_JOBS")"; _fan_tot_rc=$?
  rm -rf "$_fan_dir"
  echo ""
  if [ -n "$_fan_missing" ]; then
    echo "test suite: shard(s)$_fan_missing produced no result line, so their checks are NOT in the total below. Treat this run as failed." >&2
  fi
  # The deadline's headroom, checked HERE, against the whole run. #112 asserts it too, but that
  # section now runs inside a shard, where the elapsed time is a quarter of the real thing, so it
  # passes trivially and the guard that was calibrated for a full run stopped biting on the only
  # run it was written for (L135: a check matched over the wrong span is answered by the wrong
  # thing). The shard's copy is still worth having for a one-process run; this is the one that
  # covers the default.
  #
  # Judged on the clock the ceiling actually USES, which is wall clock (claude-config#161). #149
  # moved this to processor time to stop a loaded Mac going red, and that was right for what the
  # ceiling was then: the thing that caught a hang. #152 took that job away and gave it to
  # SUITE_STALL_TIMEOUT, and raised the ceiling to 3600 at the same time, which left this
  # comparison with a margin of about 7x (262s of processor time across four shards on 2026-08-22
  # against a 3600s ceiling). It could not fire, and a check that cannot fire stops being read
  # while still occupying a line in this report (L182).
  #
  # So the wall clock decides whether there is anything to say, because that is what runs out
  # against the ceiling, and the processor time decides WHICH of the two things is happening. The
  # separation is the whole point of measuring both, and it is what #149 established: a run filling
  # its own wall clock with its own work has grown into its deadline and is worth failing over,
  # while one that is merely waiting on a busy Mac is a fact about the machine and "find what got
  # slower" is not an action anybody can take on it (L112). The two are worded differently, so a
  # reader can tell which one they are looking at (L11).
  #
  # Measured against both states of the same tree on 2026-08-22: 348s of wall clock idle, which is
  # a tenth of the ceiling and says nothing at all, and 1943s at load 160 to 188, which is over half
  # of it and gets the note, because only 262s of it was this suite's own work.
  _fan_elapsed=$SECONDS
  suite_cpu_read; _fan_cpu="$SUITE_CPU_SECONDS"
  suite_headroom_report "$_fan_elapsed" "$_fan_cpu" "$SUITE_TIMEOUT" || _fan_rc=1
  # The headline: every section once (#146). The sum of the shards' own totals is still worked out
  # above, and it is used here as a SECOND reading of the same run: the raw sum has to be the
  # headline plus everything that was run over again. The two are arrived at differently, one from
  # each shard's result line and one from its buckets, so an identity that fails means the shards
  # are contradicting themselves and neither number can be trusted (L70 is about the opposite
  # case, two sides of one lookup; these really are two lookups).
  _fan_note="$SUITE_JOBS shards in ${_fan_elapsed}s"
  if [ "$_fan_tot_rc" -eq 0 ] && [ -z "$_fan_missing" ]; then
    _fan_hp="$(printf '%s' "$_fan_tot" | awk '{print $1}')"
    _fan_hf="$(printf '%s' "$_fan_tot" | awk '{print $2}')"
    _fan_pre="$(printf '%s' "$_fan_tot" | awk '{print $3}')"
    _fan_prf="$(printf '%s' "$_fan_tot" | awk '{print $4}')"
    _fan_rp="$(printf '%s' "$_fan_tot" | awk '{print $5}')"
    _fan_rf="$(printf '%s' "$_fan_tot" | awk '{print $6}')"
    if [ "$(( _fan_hp + _fan_rp ))" -ne "$_fan_pass" ] || [ "$(( _fan_hf + _fan_rf ))" -ne "$_fan_fail" ]; then
      echo "test suite: the shards' result lines add up to $_fan_pass passed and $_fan_fail failed, but their own account of which sections those checks came from adds up to $(( _fan_hp + _fan_rp )) and $(( _fan_hf + _fan_rf )). Those are two readings of one run and they disagree, so neither total is trustworthy." >&2
      _fan_rc=1
    else
      _fan_note="$_fan_note; every section counted once, and $_fan_rp check(s) that ran again are not in it: the prelude's $_fan_pre in each of the other $(( SUITE_JOBS - 1 )) shard(s), plus anything a section needed from another shard"
      _fan_pass="$_fan_hp"; _fan_fail="$_fan_hf"
    fi
  else
    # No usable account of which sections the checks came from, so the raw sum is what there is.
    # It is REPORTED as the raw sum rather than dressed up as the headline, because a number that
    # counts the prelude once per shard is a different fact from one that counts it once (L11).
    [ "$_fan_tot_rc" -eq 0 ] || echo "test suite: $_fan_tot" >&2
    [ "$_fan_tot_rc" -eq 0 ] || _fan_rc=1
    _fan_note="$_fan_note; the prelude runs in each, so its checks are counted $SUITE_JOBS times in the total below"
  fi
  echo "PASS=$_fan_pass FAIL=$_fan_fail ($_fan_note)"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$_fan_pass" "$_fan_fail"
  [ "$_fan_fail" -eq 0 ] || _fan_rc=1
  exit "$_fan_rc"
fi

# ---- reclaim scratch a killed run left behind (#36) ----
# Here, and not earlier, because holding the lock is what makes it safe: at depth 0 with the lock
# held there is no other run of this suite in existence, so nothing matching these names can belong
# to something still using it. The age floor inside the reaper is the second line, for a run
# started with SUITE_NO_LOCK=1.
# It REPORTS what it reclaimed rather than tidying quietly, so a number that keeps growing is
# visible as a symptom (runs are being killed) instead of being absorbed every time.
if [ "$SUITE_DEPTH" -eq 0 ]; then
  bash "$SCRIPT" reap-scratch 2>&1 | sed 's/^claude-sync: /test suite: /'
fi

# The suite's own mtime reader. Deliberately NOT claude-sync's, though the two do the same thing:
# a test that measures with the code under test can only confirm that code agrees with itself, so
# a broken reader would move both sides of every comparison together and nothing would notice
# (L70). That the two agree is a separate and much weaker claim, and it is checked once, on its own.
_suite_mtime(){   # path -> unix timestamp, or nothing
  local m
  m="$(stat -f %m "$1" 2>/dev/null || true)"
  case "$m" in ''|*[!0-9]*) m="$(stat -c %Y "$1" 2>/dev/null || true)" ;; esac
  case "$m" in ''|*[!0-9]*) return 0 ;; esac
  printf '%s\n' "$m"
}

PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
# This file's `check` EVALS its second argument. payload/hooks/test-run-all-tests.sh defines a
# `check` of its own that COMPARES its second argument against the literal string `ok`. Same name,
# opposite meaning, one repo, and a shared name is read as evidence of shared behaviour so the two
# are never compared (L263).
#
# Walked into on 2026-08-30: a case block written in the runner suite's convention was pasted here,
# so `check "..." "out=$st_empty"` handed a page of captured suite output to `eval`. It RAN,
# produced a confusing failure inside an unrelated helper, and killed the run with
# `line 1906: $1: unbound variable`, which names the `bad()` helper rather than anything to do with
# the mistake. The failure mode of the paste is arbitrary execution of captured output, not a wrong
# answer, which is why this refuses rather than merely reporting.
#
# Refused by SHAPE, at the moment the mistake is written, rather than by renaming 1,300 call sites:
# the other convention's second argument is either the bare word `ok` or a failure message, and a
# message is overwhelmingly `something=value` or prose. Neither is ever how an expression starts.
check(){
  if ! check_expr_shape "$2"; then
    bad "$1 ($CHECK_SHAPE_WHY)"
    return 0
  fi
  if eval "$2"; then ok "$1"; else bad "$1 (expr: $2)"; fi
}

# Is this second argument shaped like an EXPRESSION this file can eval, rather than like the other
# suite's result argument? Sets CHECK_SHAPE_WHY and returns 1 when it is not.
#
# A predicate rather than inline, so the probes below can watch it give BOTH answers without
# failing the suite to do it (L1, L151).
#
# Refusing a leading `word=` was the first rule here and it was WRONG: an environment prefix is
# exactly that shape, and this file writes `check "..." "CLAUDE_HOME=... bash ... pull"`
# constantly. It rejected seven legitimate checks on the first full run. A rule that describes the
# mistake must not also describe the commonest correct form (L104: a filter is tested against what
# it has to PRESERVE, not only against what it has to catch).
#
# What is left is unambiguous, and it is the dangerous half: `eval` on captured output is arbitrary
# execution rather than a wrong answer.
CHECK_SHAPE_WHY=""
check_expr_shape(){   # $1 = the expression
  CHECK_SHAPE_WHY=""
  case "$1" in
    ok)
      CHECK_SHAPE_WHY="this file's check EVALS its second argument; 'ok' is test-run-all-tests.sh's convention. Write the expression itself, or use that suite's form there."
      return 1 ;;
  esac
  if ! bash -n -c "$1" 2>/dev/null; then
    CHECK_SHAPE_WHY="that is not a shell expression bash can parse, so it was NOT run. This file's check EVALS its second argument; test-run-all-tests.sh's compares it against 'ok'. If you pasted a captured message here, write the expression instead."
    return 1
  fi
  return 0
}

# ---- how old a scratch fixture has to be (#160) ----
# Two sections plant scratch and expect the sweep to reclaim it, and both aged it by a flat two
# hours. That is not a duration, it is a RELATIONSHIP with SYNC_SCRATCH_MAX_AGE, and it held only
# while that default was 3600. #160 raised the default to 14400 and every one of those fixtures
# silently became too young, so eight checks went red about a sweep behaving exactly as asked
# (L130: a fixture whose meaning is the relationship between a stored date and a threshold has to
# pin both ends). So the offset is DERIVED from the default the tool ships, with a margin over it,
# and there are no longer two copies of the number to keep in step (L41).
#
# The default is read here once. A pattern that stops matching, because somebody rewrote that
# assignment, must not leave the fixtures looking fresh and the sweep looking broken, so it is
# asserted where it is read rather than falling back to a guess.
scratch_default_age(){ sed -n 's/^SYNC_SCRATCH_MAX_AGE="\${SYNC_SCRATCH_MAX_AGE:-\([0-9][0-9]*\)}"$/\1/p' "$SCRIPT"; }
SCRATCH_DEFAULT_AGE="$(scratch_default_age)"
case "$SCRATCH_DEFAULT_AGE" in ''|*[!0-9]*) SCRATCH_DEFAULT_AGE="" ;; esac
# Twice the default and an hour on top, so a fixture is unambiguously past it however the default
# moves next. Written back as a whole number of seconds because `touch` takes a stamp, not an age.
SCRATCH_OLD_SECS=$(( ${SCRATCH_DEFAULT_AGE:-0} * 2 + 3600 ))
scratch_age_out(){   # $1 = a path to backdate past the sweep's default age
  touch -t "$(date -v-"${SCRATCH_OLD_SECS}"S +%Y%m%d%H%M 2>/dev/null)" "$1" 2>/dev/null \
    || touch -d "$SCRATCH_OLD_SECS seconds ago" "$1"
}

# ---- assert that ONE line carries several facts (#74) ----
# The correct form for an assertion over a command's whole output, made the SHORT form. Every
# family the #55 scan bans is a way of asking for several facts and accepting them from different
# places: two greps over one blob answered by two unrelated lines, a filename found in a change
# report that lists filenames anyway, a common word found in routine chatter. Narrowing line by
# line makes all three unwritable here.
#
# Two patterns MINIMUM. One pattern is the weak form itself, and letting it through a helper would
# hide it from the scan (which reads printf-and-grep segments), so the ceilings at zero would go on
# reading as clean while the shape came back through the front door. Patterns are ERE.
line_has(){   # $1 = captured output   $2.. = patterns that must ALL appear on ONE line
  local _lh_out="$1"; shift
  if [ "$#" -lt 2 ]; then
    echo "line_has: needs at least two patterns; one pattern is the weak form this exists to replace, use grep for that" >&2
    return 2
  fi
  # Empty output must REFUSE rather than pass by matching nothing (L98).
  [ -n "$_lh_out" ] || return 1
  local _lh_cur="$_lh_out" _lh_p
  for _lh_p in "$@"; do
    _lh_cur="$(printf '%s\n' "$_lh_cur" | grep -E -- "$_lh_p")" || return 1
    [ -n "$_lh_cur" ] || return 1
  done
  [ -n "$_lh_cur" ]
}
# out_lacks <captured output> <ERE> [i] : true when the output does NOT match.
#
# Two hazards in one helper, because the four call sites below had both.
#
# First, `printf %s "$out" | grep -q PATTERN` under `set -o pipefail` can report a
# failure that never happened: grep -q leaves on its first match, printf is killed by
# SIGPIPE, and the pipeline takes its status. Measured on this hardware by
# test-pipefail-shortcircuit.sh: exit 141 over a 3.7MB producer while a direct read of
# the same content found the match, clean at 64KB and firing at 256KB. A herestring
# has no producer process to kill, so there is nothing for SIGPIPE to reach.
#
# Second, and worse for a NEGATED check, empty output makes the match fail and the
# negation therefore succeed, so the assertion passes while proving nothing about a
# message that was never produced (L98). Empty output refuses here instead, and says
# so, because a vacuous pass on "no line claims X" is indistinguishable from the line
# genuinely being absent.
out_lacks(){   # $1 = captured output   $2 = ERE   $3 = "i" for case-insensitive
  local _ol_out="$1" _ol_pat="$2" _ol_ci="${3:-}"
  if [ -z "$_ol_out" ]; then
    echo "out_lacks: refusing to judge an empty capture against '$_ol_pat': nothing was produced, so 'it does not say this' is not a finding" >&2
    return 2
  fi
  if [ "$_ol_ci" = "i" ]; then
    grep -qiE -- "$_ol_pat" <<<"$_ol_out" && return 1
  else
    grep -qE -- "$_ol_pat" <<<"$_ol_out" && return 1
  fi
  return 0
}
# A skill the way a real one is shaped: a directory holding a SKILL.md whose frontmatter carries a
# name and a description. Fixtures used to write a single bare line, which is a shape that cannot
# occur in the real config and which the sync now declines to carry, so a test built on one would
# be asserting about an entry nothing can load (L48, #50). The body line is still whatever the
# caller passes, because several checks grep for it.
mkskill(){   # $1 = path to a SKILL.md  $2 = body line
  local dir; dir="$(dirname "$1")"
  mkdir -p "$dir"
  printf -- '---\nname: %s\ndescription: a fixture skill for the suite\n---\n%s\n' "$(basename "$dir")" "$2" > "$1"
}
# SUITE_DEBUG=1 prints tool output a scenario would otherwise throw away. It exists because a
# failure that only happens on a machine you cannot run has to be MEASURED there, and a check
# reports which assertion failed while saying nothing about what the tool actually did. Two wrong
# causes were shipped for the CI failures before anything printed the facts (L171, #52).
dbg(){ [ -n "${SUITE_DEBUG:-}" ] && printf '  [debug] %s\n' "$1"; return 0; }

# A `touch -t` stamp for N days ago, portable across the BSD and GNU date this repo runs on
# (L38). Used to AGE a fixture rather than waiting for one, so a test about an expiry is instant
# and pins both ends of the comparison instead of betting on the clock (L130, L290).
date_minus_days_stamp(){   # $1 = days
  date -v-"${1}"d '+%Y%m%d%H%M' 2>/dev/null || date -d "${1} days ago" '+%Y%m%d%H%M' 2>/dev/null
}

# By NAME since claude-config#233, not by position. The record grew twice by appending and every
# growth was read positionally, which puts every REMAINING field into the LAST name, so a record
# widened without widening the read reports the new field as part of the old one instead of
# failing. It happened once already, where the exit code came out as "3<tab>?<tab>?".
# Pure parameter expansion, no pipeline. `... | head -1` is a short circuiting consumer, and under
# this suite's pipefail that kills its producer and reports a failure that never happened (L183).
hd_field(){   # $1 = the record line  $2 = the field name
  local rest="$1" pair
  while [ -n "$rest" ]; do
    pair="${rest%%$'\t'*}"
    case "$pair" in "$2="*) printf '%s' "${pair#"$2="}"; return 0 ;; esac
    case "$rest" in *$'\t'*) rest="${rest#*$'\t'}" ;; *) rest="" ;; esac
  done
  return 0
}


# Named, not a bare `mktemp -d`. A run that is force-killed never reaches suite_cleanup, so this
# directory is abandoned, and an ANONYMOUS one cannot be attributed to this suite afterwards: the
# 37 found on this Mac on 2026-08-17, holding 475 MB, had to be identified by looking inside them,
# next to 542 belonging to other tools that a sweep by age alone would have deleted (#36).
WORK="$(mktemp -d "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
# The register of clones on this Mac (claude-config#189) is $HOME based by default, and every
# mutating run in this file would otherwise append its throwaway repo to the REAL one. Pointed
# somewhere unusable once, here, rather than at each of the hundreds of call sites, so no scenario
# can reach the live file by forgetting (L2).
#
# A path inside a directory that does not exist, not a real file: a register SHARED by every
# scenario in this file would hand each of them the others' fixture clones, and those hold records,
# so an unrelated section asserting that status says nothing would be answered by somebody else's
# failure. This way a run can neither read it nor write it, which is also the state a Mac is in
# before any clone has registered. The two sections that assert about clone discovery point it at a
# real file of their own.
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry"
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
# The send-side hook suite gate is ON in production and OFF for this suite, except in the one
# section that tests it, which unsets this and sets it again afterwards (claude-config#244, #220).
# Without it every git-backed section that happens to touch a hook would start launching real test
# suites inside this one, which is minutes of work proving nothing about the section it is in.
export SYNC_NO_SEND_TESTS=1
# ---- every file seam the tool honours, pointed inside WORK, once (claude-config#220) ----
# A test that seams SOME of a script's collaborators runs the rest for real, and the real ones are
# the slow and the dangerous ones (L52, L196). These two are new and they are FILES the tool writes
# outside every clone, so a section that forgets one does not fail: it quietly takes the machine's
# real marker, and the watcher guard would then refuse the live daemon, or the live daemon would
# refuse the test.
#
# The safe value is the DEFAULT here, and a section that needs its own points it at another
# throwaway file, exactly as SYNC_ZSHRC and the clone registry above already do.
#
# The watcher marker is keyed per SHARD as well. Shards are re-executions of this same run and
# share WORK, so a single path would have two of them refusing each other as duplicate watchers,
# which is the guard working correctly against a fixture that lied about being one machine.
export SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard.${SUITE_SHARD:-0}"
export SYNC_HOLD_FILE="$WORK/hold-guard"
# The desktop notifier, for the whole suite rather than at 379 of 397 call sites. terminal-notifier
# is installed on this Mac, so any failure-path call among the 65 that carried no seam would post a
# real notification on whoever's machine runs this. Measured 2026-08-29 those particular sections
# fired none, which is a sample that came back clean rather than a proof, and the next
# failure-flavoured section written without the seam changes the answer. The section that tests
# notifications sets it back and points SYNC_NOTIFIER at a stub of its own.
export SYNC_NO_NOTIFY=1
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
mkskill "$CH/skills/plan-council/SKILL.md" 'SKILL custom'
mkskill "$CH/skills/wrangler/SKILL.md" 'SKILL plugin-owned'   # should be EXCLUDED from sync
# A hook's instruction, in a SUBDIRECTORY of hooks/. The two Stop hooks keep their
# instruction in hooks/review/*.md and point at it by a path resolved at run time
# (claude-config#243), so an instruction that does not travel leaves the other Mac
# with a hook pointing at nothing. Nothing else in this suite carries a nested file
# under hooks/, and the mirror's excludes are a list nobody re-reads when adding one.
mkdir -p "$CH/hooks/review"
echo 'INSTRUCTION BODY' > "$CH/hooks/review/issue-review.md"
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

# A second, deliberately boring home and repo. Three later sections (#33, #38, #36) want nothing
# more than somewhere valid to point a status call, and each of them used to reach for the pair the
# FIRST of the three happened to create, which made two of them unable to run without it. Nothing
# accumulates here and no section mutates it, so one pair in the preamble serves all three and
# couples none of them (claude-config#105).
PSH="$WORK/ps-home"; PSR="$WORK/ps-repo"
mkdir -p "$PSH" "$PSR/payload"; echo '{"hooks":{}}' > "$PSH/settings.json"


section "== push =="
bash "$SCRIPT" push >/dev/null 2>&1
check "payload has the custom skill"        "[ -f '$REPO/payload/skills/plan-council/SKILL.md' ]"
check "payload EXCLUDES plugin skill"       "[ ! -e '$REPO/payload/skills/wrangler' ]"
check "payload has the hook script"         "[ -f '$REPO/payload/hooks/tdd-nudge.sh' ]"
check "payload has the nested hook instruction" "[ -f '$REPO/payload/hooks/review/issue-review.md' ]"
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
mkskill "$CH2/skills/wrangler/SKILL.md" 'PLUGIN-LOCAL'   # plugin skill present on Mac 2
cat > "$CH2/settings.json" <<JSON
{ "model": "opus", "effortLevel": "high",
  "permissions": { "allow": ["MAC2-ONLY-KEEP-ME"] },
  "hooks": {} }
JSON
export CLAUDE_HOME="$CH2"
bash "$SCRIPT" pull >/dev/null 2>&1
check "skill arrived on Mac 2"              "[ -f '$CH2/skills/plan-council/SKILL.md' ]"
check "hook script arrived on Mac 2"        "[ -f '$CH2/hooks/tdd-nudge.sh' ]"
check "nested hook instruction arrived on Mac 2" "[ -f '$CH2/hooks/review/issue-review.md' ]"
check "and it arrived with its content intact"   "grep -q 'INSTRUCTION BODY' '$CH2/hooks/review/issue-review.md'"
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
mkskill "$CA/skills/alpha/SKILL.md" 'ALPHA'
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
WC="$WORK/wchome"; mkdir -p "$WC/skills/zeta"; mkskill "$WC/skills/zeta/SKILL.md" 'Z'; echo '{"hooks":{}}' > "$WC/settings.json"
EMIT="$WORK/emit-fswatch"; printf '#!/usr/bin/env bash\necho 1\n' > "$EMIT"; chmod +x "$EMIT"
SYNC_FSWATCH="$EMIT" CLAUDE_HOME="$WC" SYNC_REPO="$WR" bash "$SCRIPT" watch >/dev/null 2>&1
check "watch pushed a commit on event"  "[ -n \"\$(git -C '$WR' log --oneline 2>/dev/null)\" ]"

section "== apply is idempotent (no-op sync must not rewrite settings.json -> no watch loop) =="
CI="$WORK/idem"; mkdir -p "$CI/skills/keep"; mkskill "$CI/skills/keep/SKILL.md" 'K'
echo '# rules' > "$CI/CLAUDE.md"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$CI/settings.json"
RI="$WORK/repoI"; mkdir -p "$RI"
# first pull-style apply establishes canonical form
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
before_mtime="$(_suite_mtime "$CI/settings.json")"
before_cl="$(_suite_mtime "$CI/CLAUDE.md")"
sleep 1
# second apply with identical payload must NOT touch settings.json or CLAUDE.md
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
after_mtime="$(_suite_mtime "$CI/settings.json")"
after_cl="$(_suite_mtime "$CI/CLAUDE.md")"
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
check "message names offending file"     "printf '%s' \"\$out\" | grep -q 'possible secret found in: hooks/leak\.sh'"
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
check "block names the new file"          "printf '%s' \"\$out3\" | grep -q 'possible secret found in: hooks/new\.sh'"

section "== send (watcher path) propagates a delete and never re-applies to home (issue #2) =="
SDBARE="$WORK/sdbare.git"; git init -q --bare "$SDBARE"
SDR="$WORK/sdrepo"; git clone -q "$SDBARE" "$SDR"
SDC="$WORK/sdhome"; mkdir -p "$SDC/skills/plan-council"; echo '{"hooks":{}}' > "$SDC/settings.json"
mkskill "$SDC/skills/plan-council/SKILL.md" 'the skill the nested file below belongs to'
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
mkskill "$WC11/skills/s/SKILL.md" 'the skill this file belongs to'
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
check "watch output logs the failure"     "printf '%s' \"\$wl_out\" | grep -qi 'watch: sync FAILED (exit 1)'"
check "logged failure names the file"     "line_has \"\$wl_out\" 'watch: sync FAILED' 'hooks/leak\.sh'"

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
mkdir -p "$RSA/payload/skills/ctrl"; mkskill "$RSA/payload/skills/ctrl/SKILL.md" 'x'
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
dbg "the resumed sync said: $out_sync_restart"
check "sync also restarts the watch daemon on a script change" "printf '%s' \"\$out_sync_restart\" | grep -qi 'watch daemon'"
check "the resumed sync still applies ordinary payload files" "[ -f '$RSCHOME/hooks/ordinary.sh' ]"
check "the resumed sync applies what only the NEW version syncs" "[ -f '$RSCHOME/RESUMED.md' ]"
check "the resumed sync still reports completion"             "printf '%s' \"\$out_sync_restart\" | grep -q 'Synced (sent local changes, pulled remote'"

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
# The four assertions below read rsync's itemize field, so they say WHICH kind of change was
# reported and not merely that a filename appeared (#69). The flag characters are rsync's to
# change, so only the ONE character carrying the meaning is pinned (`+` newly created, `c` checksum
# differs) and the rest of the field is any run of non-spaces: an rsync that sets one more
# attribute flag would otherwise fail these, and read as claude-sync mis-reporting rather than as a
# pattern that aged (#72, L103). Codes read from rsync 3.4.1 on macOS and 3.4.1 on the CI runner;
# the CI job prints its rsync version, see .github/workflows/tests.yml.
check "status names a hook missing from the payload" \
  "printf '%s' \"\$out_st_add\" | grep -q 'hooks: >f+[^ ]* added\.sh'"

# A file in the payload that is gone locally: --delete is in the command, so a
# working status must show the pending deletion. This is the exact case that
# proved the bug (rsync -an silent, rsync -ain printed '*deleting').
echo 'stale' > "$STREPO/payload/hooks/removed.sh"
out_st_del="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a payload file deleted locally" \
  "printf '%s' \"\$out_st_del\" | grep -q 'hooks: \*deleting  *removed\.sh'"

# An edit to an existing hook with the SAME byte count. -a quick-checks on size
# plus mtime, so without -c this edit is invisible even to an itemized rsync.
printf 'aaaa\n' > "$STHOME/hooks/edit.sh"
printf 'aaaa\n' > "$STREPO/payload/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh" "$STREPO/payload/hooks/edit.sh"
printf 'bbbb\n' > "$STHOME/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh"
out_st_edit="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a same-size same-mtime edit" \
  "printf '%s' \"\$out_st_edit\" | grep -q 'hooks: >fc[^ ]* edit\.sh'"

# status must report what a push would ACTUALLY do, so it has to honor the same
# exclude set as stage_local_to_payload. Some skills are git clones carrying
# their own .git, and a status that reports those as pending changes is noise
# describing work that will never happen. (#737)
# The payload's skills directory has to EXIST for this to test what it means to test.
# rsync reports files under a destination directory that is not there at all with the
# flags for "nothing about this differs" rather than "newly created", so the assertion
# below on `+` was reading an implementation detail of the missing destination and not
# claude-sync's report. It survived only because rsync 3.4.1, on the other Mac and on
# the CI runner, keeps the `+` in that case while the openrsync macOS ships does not,
# so the suite was red on one Mac and green on the other for a reason neither machine
# stated (#257 follow-up, L504: when the ambient environment is what separates a correct
# implementation from a wrong one, the test has to set it rather than inherit it).
mkdir -p "$STREPO/payload/skills"
mkdir -p "$STHOME/skills/cloned/.git/hooks"
echo 'ref: refs/heads/main' > "$STHOME/skills/cloned/.git/HEAD"
mkskill "$STHOME/skills/cloned/SKILL.md" 'SKILL'
echo 'junk' > "$STHOME/skills/cloned/.DS_Store"
out_st_ex="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status ignores nested .git the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.git/'"
check "status ignores .DS_Store the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.DS_Store'"
check "status still reports the real skill file next to them" \
  "printf '%s' \"\$out_st_ex\" | grep -q 'skills: >f+[^ ]* cloned/SKILL\.md'"

# A plugin-managed skill is excluded from the sync, so status must not offer it.
mkdir -p "$STHOME/skills/wrangler"
mkskill "$STHOME/skills/wrangler/SKILL.md" 'PLUGIN'
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
# This one failed once, on 2026-08-22, in a run competing with three other full runs, and has not
# been reproduced since (claude-config#180). The other two failures from that run had a real cause
# (a suite writing its working file beside itself, fixed by test-suite-scratch-isolation.sh); this
# one has no established cause at all, and a guess dressed as a diagnosis is worse than none.
#
# So rather than labelling it, it is made to PRINT the fact next time. A failure that reproduces
# only in a state you cannot summon has to carry its own evidence, or every occurrence starts the
# investigation from nothing (L177). The output is folded into the description, which is the line a
# failure prints, and it is empty on a pass so the passing line stays clean.
if line_has "$out_up" 'added' 'NOTES\.md'; then
  _up_why=""
else
  _up_why=" (the pull actually said: $(printf '%s' "$out_up" | tr '\n' '~'))"
fi
check "the self-updating pull still reports the change$_up_why" "[ -z \"\$_up_why\" ]"
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
check "the error names the missing file"             "printf '%s' \"\$out_imp\" | grep -q 'referenced but are not on this Mac: GONE\.md'"
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
check "a pull that writes a file names it"        "printf '%s' \"\$out_wr\" | grep -q 'added  *hooks/keep\.sh'"
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
check "status reports a referenced rules file differing" "printf '%s' \"\$out_dvst\" | grep -q 'EXTRA\.md: differs'"
# a nested reference that resolves nowhere must still fail loudly, not pass quietly
printf '@NOWHERE.md\n' > "$DVH/EXTRA.md"
if SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" push >/dev/null 2>&1; then rc_dv2=0; else rc_dv2=$?; fi
if out_dv3="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH2" SYNC_REPO="$DVR" bash "$SCRIPT" pull 2>&1)"; then rc_dv3=0; else rc_dv3=$?; fi
check "a dangling NESTED reference fails the pull"  "[ \"\$rc_dv3\" -ne 0 ]"
check "and the error names the missing file"        "printf '%s' \"\$out_dv3\" | grep -q 'referenced but are not on this Mac: NOWHERE\.md'"

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
# Its own pair, rather than the one the section above left behind. What this section needs is any
# home and repo a pull can run against, which is three lines, and inheriting one made it impossible
# to run this section on its own (claude-config#105).
TQH="$WORK/tq-home"; TQR="$WORK/tq-repo"
mkdir -p "$TQH/hooks" "$TQR/payload/hooks"; echo '{"hooks":{}}' > "$TQH/settings.json"
printf 'aaaa\n' > "$TQH/hooks/tiny.sh"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TQH" SYNC_REPO="$TQR" bash "$SCRIPT" push >/dev/null 2>&1
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$TQH" SYNC_REPO="$TQR" bash "$SCRIPT" pull >/dev/null 2>&1
# Asked about SCRATCH by NAME, not about everything in the directory it lives in. The tool keeps
# its scratch in a `claude-sync` directory inside the temp root (#116), and that directory, and the
# stamp recording when the old flat location was last swept, are both deliberately left there: they
# are created once, they are not scratch, and the sweep never removes them. Both locations are
# read, so a run that fell back to writing flat is still caught here.
_tq_litter(){ ls -A "$TMPD" "$TMPD/claude-sync" 2>/dev/null | grep '^claude-sync-' || true; }
check "a clean pull leaves no temp file behind" "[ -z \"\$(_tq_litter)\" ]"
# same on the failure path: a pull that dies must not litter either
printf '@NOPE.md\n' > "$TQR/payload/CLAUDE.md"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$TQH" SYNC_REPO="$TQR" bash "$SCRIPT" pull >/dev/null 2>&1
check "a failed pull leaves no temp file behind"  "[ -z \"\$(_tq_litter)\" ]"
# The control: this cannot pass by looking in the wrong place. A file planted in either location
# has to be reported, or both checks above are satisfied by a listing of nothing (L143, L159).
: > "$TMPD/claude-sync-work.PLANTED"
check "and the litter check can see one"          "[ -n \"\$(_tq_litter)\" ]"
rm -f "$TMPD/claude-sync-work.PLANTED"
mkdir -p "$TMPD/claude-sync"; : > "$TMPD/claude-sync/claude-sync-work.PLANTED"
check "including one inside the tool's own directory" "[ -n \"\$(_tq_litter)\" ]"
rm -f "$TMPD/claude-sync/claude-sync-work.PLANTED"
rm -f "$TQR/payload/CLAUDE.md" "$TQH/CLAUDE.md"

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
dbg "A's log before its sync: $(git -C "$UAA" log --oneline -4 2>&1 | tr '\n' ' | ')"
dbg "A's status before its sync: [$(git -C "$UAA" status --short 2>&1 | tr '\n' ' | ')]"
dbg "A's upstream before its sync: $(git -C "$UAA" rev-list --left-right --count HEAD...@{u} 2>&1) (ahead/behind)"
dbg "remote log: $(git -C "$UAA" log --oneline -4 @{u} 2>&1 | tr '\n' ' | ')"
_ua_syncA="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync 2>&1)"; _ua_rcA=$?
dbg "A's sync exited $_ua_rcA: $_ua_syncA"
dbg "A's repo holds: $(git -C "$UAA" log --oneline -1 2>&1)"
git -C "$UAB" pull -q --ff-only 2>&1 | while IFS= read -r _l; do dbg "B's test-side pull: $_l"; done
echo 'B-second' > "$UABH/hooks/b-two.sh"
_ua_syncB="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" sync 2>&1)"; _ua_rcB=$?
dbg "B's sync exited $_ua_rcB: $_ua_syncB"
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
check "the report names the file"                 "line_has \"\$out_cf\" 'could NOT be merged' 'hooks/x\.sh'"
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
mkskill "$LEAH/skills/reel/SKILL.md" 'the skill the script below belongs to'
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
check "local script edit: the unrelated change still arrives"  "grep -q other-v2 '$LEBH/hooks/other.sh'"
check "the local edit is NOT reverted"      "grep -q MY-LOCAL-FIX '$LEBH/skills/reel/push.py'"
check "local script edit: the pull says it kept it"  "line_has \"\$out_le\" 'would have reverted' 'skills/reel/push\.py'"
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
# The lesson fixtures below are in the CANONICAL `- **Lnnn. ...` form, which is what a real
# LESSONS.md holds. They used to be bare `- Lnnn.` lines, and every check here passed on them
# because the merge is a three way merge over lines and never looked at what an entry is. So these
# sections proved the merge preserves LINES, while claiming to prove it preserves LESSONS, and the
# entry-aware step that runs after the merge (dropping a local copy the other Mac has renumbered)
# was never reached at all (L48: a fixture that is not shaped like the real data answers a
# different question). Found when claude-config#164 started refusing the shape.
TFAH="$WORK/tfhomeA"; mkdir -p "$TFAH/hooks"; echo '{"hooks":{}}' > "$TFAH/settings.json"
printf '# rules\n' > "$TFAH/CLAUDE.md"
printf -- '- **L1. first lesson.** body\n' > "$TFAH/LESSONS.md"
echo 'other-v1' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
TFB="$WORK/tfrepoB"; git clone -q "$TFBARE" "$TFB" 2>/dev/null
TFBH="$WORK/tfhomeB"; mkdir -p "$TFBH"; echo '{"hooks":{}}' > "$TFBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts with the shared lessons file" "grep -q 'first lesson' '$TFBH/LESSONS.md'"
# B appends a lesson. Nothing sends it (the watcher is down, or it is seconds old).
printf -- '- **L2. MY-NEW-LESSON.** body\n' >> "$TFBH/LESSONS.md"
# A changes something unrelated and publishes, so B's next pull has real work.
echo 'other-v2' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
out_tf="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "unsent lesson: the unrelated change still arrives"  "grep -q other-v2 '$TFBH/hooks/tf-other.sh'"
check "the unsent lesson is NOT reverted"       "grep -q MY-NEW-LESSON '$TFBH/LESSONS.md'"
check "the earlier lesson is still there too"   "grep -q 'first lesson' '$TFBH/LESSONS.md'"
check "unsent lesson: the pull says it kept it"  "line_has \"\$out_tf\" 'would have reverted' 'LESSONS\.md'"
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
printf -- '- **L3. FROM-MAC-A.** body\n' >> "$TFAH/LESSONS.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
printf -- '- **L4. FROM-MAC-B-SAME-TIME.** body\n' >> "$TFBH/LESSONS.md"
out_tfc="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "the other Mac's entry arrives"           "grep -q FROM-MAC-A '$TFBH/LESSONS.md'"
check "this Mac's entry is still in the file"   "grep -q FROM-MAC-B-SAME-TIME '$TFBH/LESSONS.md'"
check "so no conflict copy was needed"          "! ls '$TFBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "and the merge is reported"               "line_has \"\$out_tfc\" 'entries were MERGED' 'LESSONS\.md'"

section "== a pull says what .syncbak copies it left behind (#158) =="
# Every merge writes the previous copy beside the file as `<name>.syncbak`, which is the right
# safety net, and then nothing else ever happens to it. Four were sitting on each Mac on
# 2026-08-22, one of them two days older than the other three, and no pull had ever mentioned any
# of them. An old backup is indistinguishable from a fresh one, so a restore reaches for a file of
# unknown vintage and can roll settings back by days without anybody noticing.
#
# The pull that writes one is the only moment their age is known, so that is when they are listed,
# with a date each. They are NOT deleted: an automatic retention policy is a product decision and
# not a silent default (L9, L116), and the whole point of the file is to still be there when
# somebody wants it (L5, L7).
SBBARE="$WORK/sbbare.git"; git init -q --bare -b main "$SBBARE"
SBA="$WORK/sbrepoA"; git clone -q "$SBBARE" "$SBA" 2>/dev/null
SBAH="$WORK/sbhomeA"; mkdir -p "$SBAH/hooks"; echo '{"hooks":{}}' > "$SBAH/settings.json"
printf '# rules\n' > "$SBAH/CLAUDE.md"
printf -- '- **L1. first lesson.** body\n' > "$SBAH/LESSONS.md"
echo 'sb-other-v1' > "$SBAH/hooks/sb-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBAH" SYNC_REPO="$SBA" bash "$SCRIPT" sync >/dev/null 2>&1
SBB="$WORK/sbrepoB"; git clone -q "$SBBARE" "$SBB" 2>/dev/null
SBBH="$WORK/sbhomeB"; mkdir -p "$SBBH"; echo '{"hooks":{}}' > "$SBBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBBH" SYNC_REPO="$SBB" bash "$SCRIPT" pull >/dev/null 2>&1

# The control first, and it is the half that decides whether any of this is worth having: a pull
# that wrote NO backup must not print the block at all, or the notice appears on every pull and
# becomes the noise it exists to cut through (L36, L159).
echo 'sb-other-v2' > "$SBAH/hooks/sb-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBAH" SYNC_REPO="$SBA" bash "$SCRIPT" sync >/dev/null 2>&1
out_sb_none="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBBH" SYNC_REPO="$SBB" bash "$SCRIPT" pull 2>&1)"
check "#158 the unrelated change arrived, so this pull really did work"  "grep -q sb-other-v2 '$SBBH/hooks/sb-other.sh'"
check "#158 a pull that left no previous copy says nothing about .syncbak" \
  "case \"\$out_sb_none\" in *syncbak*) false ;; *) true ;; esac"

# Now both Macs append to the same rules file, which is the merge that writes one.
printf -- '- **L3. SB-FROM-MAC-A.** body\n' >> "$SBAH/LESSONS.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBAH" SYNC_REPO="$SBA" bash "$SCRIPT" sync >/dev/null 2>&1
printf -- '- **L4. SB-FROM-MAC-B.** body\n' >> "$SBBH/LESSONS.md"
out_sb="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBBH" SYNC_REPO="$SBB" bash "$SCRIPT" pull 2>&1)"
# The fixture really did produce one, or every check below passes by having nothing to find (L98).
check "#158 the merge really did leave a previous copy behind" "[ -f '$SBBH/LESSONS.md.syncbak' ]"
check "#158 the pull lists the previous copies it left behind" \
  "line_has \"\$out_sb\" 'syncbak' 'LESSONS\.md'"
# A date for each, which is the entire point: without one an old copy and a fresh one read alike.
check "#158 and gives a date for each, not just a count" \
  "line_has \"\$out_sb\" 'LESSONS\.md\.syncbak' '[0-9]{4}-[0-9]{2}-[0-9]{2}'"
# #240 gave them an expiry, so the assertion that nothing removes them defended a promise this
# deliberately stopped making (L252). What the line still has to do is say what WILL happen to
# them and how to do it now, because a backup with no stated end is one nobody ever deletes.
check "#158 and says how long they are kept and how to remove them now" \
  "case \"\$out_sb\" in *clean-backups*) true ;; *) false ;; esac"
# And nothing was deleted, which is the promise the sentence above makes (L5).
check "#158 the previous copy is still on disk afterwards" "[ -f '$SBBH/LESSONS.md.syncbak' ]"
check "#158 and it still holds this Mac's pre-merge copy" \
  "grep -q SB-FROM-MAC-B '$SBBH/LESSONS.md.syncbak'"
# An OLDER copy beside a fresh one is named too, since telling those two apart is the whole reason
# the dates are printed. Made older by hand rather than by waiting.
# Older by only a few days on purpose: since #240 a copy past SYNC_BACKUP_KEEP_DAYS is swept, and
# dating this one months back would have it removed before the line that has to name it. The sweep
# has its own section.
printf 'stale\n' > "$SBBH/CLAUDE.md.syncbak"
sb_old_stamp="$(date_minus_days_stamp 3)"
touch -t "${sb_old_stamp:-202601011200}" "$SBBH/CLAUDE.md.syncbak"
printf -- '- **L5. SB-FROM-MAC-A-AGAIN.** body\n' >> "$SBAH/LESSONS.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBAH" SYNC_REPO="$SBA" bash "$SCRIPT" sync >/dev/null 2>&1
printf -- '- **L6. SB-FROM-MAC-B-AGAIN.** body\n' >> "$SBBH/LESSONS.md"
out_sb2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SBBH" SYNC_REPO="$SBB" bash "$SCRIPT" pull 2>&1)"
sb_old_date="$(printf '%s' "${sb_old_stamp:-202601011200}" | sed -E 's/^(....)(..)(..).*/\1-\2-\3/')"
check "#158 an older copy left from before is listed too" \
  "line_has \"\$out_sb2\" 'CLAUDE\.md\.syncbak' \"\$sb_old_date\""
check "#158 and the older one is not deleted either" "[ -f '$SBBH/CLAUDE.md.syncbak' ]"

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
mkskill "$NSAH/skills/rs-existing/SKILL.md" 'SKILL v1'
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
NSB="$WORK/nsrepoB"; git clone -q "$NSBARE" "$NSB"
NSBH="$WORK/nshomeB"; mkdir -p "$NSBH"; echo '{"hooks":{}}' > "$NSBH/settings.json"
CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull >/dev/null 2>&1
# Mac A now changes a rule file, adds a whole new skill, edits an existing
# skill, and edits a hook, all in one push.
echo '# rules v2' > "$NSAH/CLAUDE.md"
mkdir -p "$NSAH/skills/rs-added"; mkskill "$NSAH/skills/rs-added/SKILL.md" 'SKILL new'
mkskill "$NSAH/skills/rs-existing/SKILL.md" 'SKILL v2'
echo 'two' > "$NSAH/hooks/rs-hook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
notice_ns="$(printf '%s\n' "$out_ns" | grep -i 'new Claude Code session' || true)"
check "pull tells you a new session is needed"   "[ -n \"\$notice_ns\" ]"
check "the notice names the changed rule file"   "line_has \"\$notice_ns\" 'new Claude Code session' 'CLAUDE\.md'"
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

# A hook REGISTRATION added or removed is the same kind of change (claude-config#176). Claude Code
# takes its snapshot of the hooks block at session start, so a hook the pull just registered is
# inert in every session already running, and before this the pull said nothing at all: the
# 2026-08-22 pull registered project-list-nudge.sh in silence. The SCRIPTS stay excluded, because
# those really are re-read from disk on every fire; it is the registration that is read once.
cat > "$NSAH/settings.json" <<'NSHOOKS'
{"hooks":{"UserPromptSubmit":[{"matcher":"","hooks":[{"type":"command","command":"bash ~/.claude/hooks/rs-newhook.sh"}]}]}}
NSHOOKS
echo 'newhook' > "$NSAH/hooks/rs-newhook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns4="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "a newly registered hook earns the notice"  "line_has \"\$out_ns4\" 'new Claude Code session' 'rs-newhook'"
# It has to be the REGISTRATION that earned it and not the script arriving beside it, or this
# passes for the wrong reason on a pull that carried both.
check "and the script alone would not have"       "! line_has \"\$out_ns4\" 'new Claude Code session' 'rs-hook\.sh'"

# An edit that leaves the same hooks registered changes nothing a running session holds, so it
# stays quiet, exactly as an edit to an already listed skill does. Here the matcher changes and the
# command does not.
cat > "$NSAH/settings.json" <<'NSHOOKS2'
{"hooks":{"UserPromptSubmit":[{"matcher":"Edit","hooks":[{"type":"command","command":"bash ~/.claude/hooks/rs-newhook.sh"}]}]}}
NSHOOKS2
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns5="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "an edit to an already registered entry is reported" "line_has \"\$out_ns5\" 'updated' 'settings\.json \\(hooks section\\)'"
# And it is reported as a plain edit: the merge appends "registered" or "unregistered" to that
# label only when the set of commands actually moved, which is the same fact the notice is decided
# from, so its absence here is what makes the silence correct rather than merely observed.
check "and the label claims no registration moved" "! line_has \"\$out_ns5\" 'settings\.json' 'registered:'"
check "but earns no restart notice"               "! line_has \"\$out_ns5\" 'Start a new Claude Code session' 'pick these up'"

# And losing a registration is as wrong for a running session as gaining one, the same way a
# removed skill is.
echo '{"hooks":{}}' > "$NSAH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns6="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "an unregistered hook also earns the notice" "line_has \"\$out_ns6\" 'new Claude Code session' 'rs-newhook'"

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
  "printf '%s' \"\$out_hk2\" | grep -q 'added  *hooks/from-mac-a\.sh'"

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
  "printf '%s' \"\$out_hk3\" | grep -q 'unregistered: shared\.sh'"
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
check "#14 the merge is reported, not silent"     "printf '%s' \"\$out_rm1\" | grep -qi 'entries were MERGED and nothing was dropped'"
check "#14 the report names the file merged"      "printf '%s' \"\$out_rm1\" | grep -q 'merged  *LESSONS\.md'"
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
  "line_has \"\$out_rm1\" 'new Claude Code session' 'LESSONS\.md'"

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
perl -i -pe 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac A/' "$RMA/payload/LESSONS.md"
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A rewrites L1" && git -C "$RMA" push -q
# Mac B rewrites the SAME line differently, and also adds an entry of its own.
perl -i -pe 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac B/' "$RMBH/LESSONS.md"
printf -- '- **L6. six.** only on Mac B\n' >> "$RMBH/LESSONS.md"
out_rm2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" bash "$RMB/claude-sync" pull 2>&1)"
check "#14 an unmergeable file still keeps a copy of yours" \
  "ls '$RMBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "#14 and it names the entry only you had" \
  "printf '%s' \"\$out_rm2\" | grep -q 'only in yours: L6'"
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
check "#15 the duplicate is named, not silent"        "printf '%s' \"\$out_ln_dup\" | grep -q 'L2 used 2 times'"
check "#15 the file it is in is named"                "printf '%s' \"\$out_ln_dup\" | grep -q 'LESSONS\.md: L2 used 2 times'"
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
check "#15 next-lesson reports one past the highest"  "printf '%s' \"\$out_next\" | grep -q '^L6$'"
check "#15 next-lesson does not offer a gap"          "! printf '%s' \"\$out_next\" | grep -q 'L3'"

# next-lesson must survive a rule file that contains no lessons at all: under
# pipefail a grep matching nothing killed the whole command and printed nothing.
printf '# just rules, no lessons here\n' > "$LNH/RTK.md"
out_next2="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" next-lesson 2>&1)"; rc_next2=$?
check "#15 next-lesson survives a file with no lessons" "[ \"\$rc_next2\" -eq 0 ] && printf '%s' \"\$out_next2\" | grep -q '^L6$'"

# The standalone check, usable as a gate before writing a lesson.
out_chk_ok="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_ok=$?
check "#15 check-lessons passes on sound numbering" "[ \"\$rc_chk_ok\" -eq 0 ]"
check "#15 check-lessons reports the next free number" "printf '%s' \"\$out_chk_ok\" | grep -q 'next free: L6'"
printf -- '- **L5. five again.** duplicate\n' >> "$LNH/LESSONS.md"
out_chk_bad="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_bad=$?
check "#15 check-lessons fails on a duplicate" "[ \"\$rc_chk_bad\" -ne 0 ]"
check "#15 and names the number involved"      "printf '%s' \"\$out_chk_bad\" | grep -q 'L5 used 2 times'"

# A duplicate created by the #14 merge (both Macs choosing the same number) has to
# surface at apply time too, since by then it is already in the file.
LNM="$WORK/lnmbare.git"; git init -q --bare -b main "$LNM"
LNMA="$WORK/lnmA"; git clone -q "$LNM" "$LNMA" 2>/dev/null
cp "$SCRIPT" "$LNMA/claude-sync"
mkdir -p "$LNMA/payload/hooks"; echo '#!/bin/sh' > "$LNMA/payload/hooks/x.sh"
# A skill, so the scan below is exercised against a nested path and not only against the
# flat mirror dirs. skills/ is synced alongside hooks, agents and commands.
mkdir -p "$LNMA/payload/skills/demo"; printf -- '---\nname: demo\ndescription: a fixture skill for the suite\n---\nbody\n' > "$LNMA/payload/skills/demo/SKILL.md"
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
# The same mention again, but in files that live in SUBDIRECTORIES of the config rather
# than at the top level. hooks/, agents/, commands/ and skills/ all sync, and hooks cite
# lessons by number heavily: payload/hooks/lessons-advisory.sh alone carries sixteen such
# citations today. The scan only ever looked at CLAUDE_HOME/*.md, so a renumber left every
# one of them pointing silently at a different lesson and said nothing (#43).
printf -- 'see L2 for the rule\n' >> "$LNMBH/hooks/x.sh"
printf -- 'see L2 for the rule\n' >> "$LNMBH/skills/demo/SKILL.md"
# Mac A's published side ALSO cites the contested number in a body line: that mention
# means Mac A's own L2 and must never be rewritten.
printf -- '- **L2. theirs.** written on Mac A\n- **L4. four.** also on Mac A\n  distinct from L2, which it cites\n' >> "$LNMA/payload/LESSONS.md"
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds its L2 and L4" && git -C "$LNMA" push -q
out_lnm="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" bash "$LNMB/claude-sync" pull 2>&1)"
section "== a lesson entry no tool can read is a failure, not a silent skip (#164) =="
# The canonical form is `- **Lnnn. ...`, and every tool here reads only that: the duplicate
# checker, the number minter, the index generator, and `claude-sync lesson`. So an entry written
# any other way is invisible to ALL of them at once, and they all agree with each other while all
# being wrong. Two were found on 2026-08-22, a `### L511.` heading and a bare `- L511.` list item:
# absent from the generated index that loads into every session, unretrievable by `lesson`,
# uncounted by the duplicate checker, and holding a number `next-lesson` went on offering as free,
# so the next lesson added on either Mac would have collided with `check-lessons` still reporting
# sound.
#
# The defect is not the two entries, it is that a checker which only sees what it can parse
# reports success when it matches nothing, so it can never report this class at all (L100, L96).
LM="$WORK/lmrepo"; mkdir -p "$LM/payload"
LMH="$WORK/lmhome"; mkdir -p "$LMH/hooks"
echo '{"hooks":{}}' > "$LMH/settings.json"
echo '#!/bin/sh' > "$LMH/hooks/keep-syncing.sh"
printf '# rules\n@LESSONS.md\n' > "$LMH/CLAUDE.md"
_lm(){ SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LMH" SYNC_REPO="$LM" bash "$SCRIPT" "$@" 2>&1; }

# The control FIRST, and on a file that really does hold lessons: a check that fires on everything
# is as useless as one that fires on nothing, and this one has to stay quiet on the canonical form
# every rule file is written in (L104).
printf '# Lessons\n\n## Proof over green\n\n- **L1. one.** body\n- **L2. two.** body\n' > "$LMH/LESSONS.md"
_lm_ok="$(_lm check-lessons)"; _lm_ok_rc=$?
check "#164 canonical entries pass" "[ '$_lm_ok_rc' -eq 0 ]"
check "#164 and it still reports the next free number" \
  "case \"\$_lm_ok\" in *'next free: L3'*) true ;; *) false ;; esac"

# A heading. This is one of the two real shapes found.
printf -- '\n### L3. A test that times out names the assertion that was running.\n  body\n' >> "$LMH/LESSONS.md"
_lm_head="$(_lm check-lessons)"; _lm_head_rc=$?
# The line number is READ from the fixture, never written down beside it: a number typed here is
# right until somebody adds a line to the fixture above, and then this asserts about a line that
# holds something else while still looking like a precise check (L48, measured: it did).
_lm_head_ln="$(grep -n '^### L3\.' "$LMH/LESSONS.md" | cut -d: -f1)"
check "#164 an entry written as a heading is refused" "[ '$_lm_head_rc' -ne 0 ]"
check "#164 and the refusal names the file and the line (line $_lm_head_ln)" \
  "line_has \"\$_lm_head\" 'LESSONS\.md' ':$_lm_head_ln:'"
check "#164 and quotes the entry, so it can be found" \
  "case \"\$_lm_head\" in *'L3. A test that times out'*) true ;; *) false ;; esac"
# It must say what is WRONG with it, not merely that something is. A reader who cannot see the
# difference between their line and the canonical one has been told nothing they can act on (L11).
check "#164 and says what shape it should have been" \
  "case \"\$_lm_head\" in *'- **L'*) true ;; *) false ;; esac"

# The other shape: a list item with the bold left off. Told apart from the heading by nothing but
# its own text, which is why both are checked rather than one standing in for the other.
printf '# Lessons\n\n- **L1. one.** body\n- L4. A lookup that requires exactly one match must treat MANY matches as a refusal.\n' > "$LMH/LESSONS.md"
_lm_bare="$(_lm check-lessons)"; _lm_bare_rc=$?
check "#164 an entry with the bold left off is refused" "[ '$_lm_bare_rc' -ne 0 ]"
check "#164 and that one is named too" \
  "case \"\$_lm_bare\" in *'L4. A lookup that requires'*) true ;; *) false ;; esac"

# The number is CLAIMED even though no tool could read it. Without this the next lesson minted on
# either Mac takes it and the two collide, which is the consequence that actually costs something,
# and it has to hold even when the failure above is overridden.
_lm_next="$(SYNC_SKIP_LESSON_CHECK=1 _lm next-lesson)"
check "#164 a malformed entry's number is not offered as free" \
  "! case \"\$_lm_next\" in *L4*) true ;; *) false ;; esac"
check "#164 and the next number is one past it" \
  "case \"\$_lm_next\" in *L5*) true ;; *) false ;; esac"
# And two entries claiming one number are a duplicate however either of them is written, which the
# canonical-only scan could not see even when BOTH were malformed. Reported in the SAME run as the
# shape fault above rather than after it is fixed: an entry nobody can read is exactly the entry
# whose number gets claimed twice, so these two arrive together and reporting one at a time costs a
# second run to discover the second.
printf -- '\n### L4. same number, other shape.\n' >> "$LMH/LESSONS.md"
_lm_dup="$(_lm check-lessons)"
check "#164 two entries claiming one number are caught across shapes" \
  "case \"\$_lm_dup\" in *'L4 used 2 times'*) true ;; *) false ;; esac"
check "#164 and the shape fault is reported in the same run, not after it" \
  "case \"\$_lm_dup\" in *'not written as'*) true ;; *) false ;; esac"

# Held back from the send exactly as a duplicate is, and only that file. Failing the whole send
# would stop hooks and skills moving between Macs, which is the wedge this tool has been bitten by
# twice.
printf '# Lessons\n\n- **L1. one.** body\n- L9. no bold on this one.\n' > "$LMH/LESSONS.md"
_lm_push="$(_lm push)"
check "#164 a file holding one is NOT published"  "[ ! -f '$LM/payload/LESSONS.md' ] || ! grep -q 'no bold on this one' '$LM/payload/LESSONS.md'"
check "#164 and the send says which file and why" \
  "line_has \"\$_lm_push\" 'NOT publishing' 'LESSONS\.md'"
check "#164 while everything else still publishes" "[ -f '$LM/payload/hooks/keep-syncing.sh' ]"
SYNC_SKIP_LESSON_CHECK=1 _lm push >/dev/null 2>&1
check "#164 the documented override publishes it anyway" "grep -q 'no bold on this one' '$LM/payload/LESSONS.md'"

# `lesson` must not answer "not in this file" about a number the file plainly holds. That reading
# is what made the state believable: three tools agreeing, and the one that could have contradicted
# them saying the entry does not exist (L11).
_lm_look="$(_lm lesson L9)"; _lm_look_rc=$?
check "#164 looking one up does not deny it exists" "[ '$_lm_look_rc' -ne 0 ]"
check "#164 and says it is there but unreadable, naming the line" \
  "line_has \"\$_lm_look\" 'L9' ':4:'"
check "#164 and does not claim it is absent" \
  "! case \"\$_lm_look\" in *'is not in'*) true ;; *) false ;; esac"

# The false positive that would make this fire on every run: the generated index is a RENDERING of
# these entries and its own form is `- Lnnn.` with no bold, which is precisely the shape refused
# above. It is excluded by the predicate that already decides a file is derived, not by naming it
# again here (L41). Without this the check is red on every machine, for ever, about a file nobody
# writes by hand.
printf '# Lessons\n\n- **L1. one.** body\n- **L2. two.** body\n' > "$LMH/LESSONS.md"
printf '# Lessons index (generated, do not edit)\n\n- L1. one.\n- L2. two.\n' > "$LMH/LESSONS-INDEX.md"
_lm_idx="$(_lm check-lessons)"; _lm_idx_rc=$?
check "#164 the generated index is not judged by this rule" "[ '$_lm_idx_rc' -eq 0 ]"
check "#164 and the index really did hold the refused shape" \
  "grep -qE '^- L[0-9]+\.' '$LMH/LESSONS-INDEX.md'"

# An entry ARRIVING from the other Mac has to be reported when it LANDS, not only when the next
# send declines to publish it. This is the path the two real ones will come in on: both are on the
# other Mac, so the first thing that happens here is a pull, and until one runs there is nothing to
# hold back. The duplicate check beside this one already says so at once, for the reason recorded
# there: the L43 duplicate went unnoticed for a day because nothing ever looked (#15).
printf '# Lessons\n\n- **L1. one.** body\n' > "$LMH/LESSONS.md"
rm -f "$LMH/LESSONS-INDEX.md"
_lm_ab="$WORK/lmarrive.git"; git init -q --bare -b main "$_lm_ab"
_lm_aa="$WORK/lmarriveA"; git clone -q "$_lm_ab" "$_lm_aa" 2>/dev/null
cp "$SCRIPT" "$_lm_aa/claude-sync"
mkdir -p "$_lm_aa/payload"
printf '# rules\n@LESSONS.md\n' > "$_lm_aa/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body\n\n### L7. arrived unreadable.\n' > "$_lm_aa/payload/LESSONS.md"
echo '{"hooks":{}}' > "$_lm_aa/payload/settings.hooks.json"
git -C "$_lm_aa" checkout -q -b main 2>/dev/null || true
git -C "$_lm_aa" add -A && git -C "$_lm_aa" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$_lm_aa" push -q -u origin main
_lm_abh="$WORK/lmarrivehomeB"; mkdir -p "$_lm_abh"; echo '{"hooks":{}}' > "$_lm_abh/settings.json"
_lm_abr="$WORK/lmarriveB"; git clone -q "$_lm_ab" "$_lm_abr" 2>/dev/null
_lm_arr="$(CLAUDE_HOME="$_lm_abh" SYNC_REPO="$_lm_abr" SYNC_NO_NOTIFY=1 bash "$_lm_abr/claude-sync" pull 2>&1)"
check "#164 an unreadable entry arriving from the other Mac really did land" \
  "grep -q 'arrived unreadable' '$_lm_abh/LESSONS.md'"
check "#164 and the pull says so when it lands, not only on the next send" \
  "line_has \"\$_lm_arr\" 'LESSONS\.md' 'L7'"
check "#164 and the arrival report says what shape it should have been" \
  "case \"\$_lm_arr\" in *'- **L'*) true ;; *) false ;; esac"

section "== #17: a collision the merge creates is settled by renumbering the unsent entry =="
# needs: #15: duplicate lesson numbers must not be published or go unnoticed
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
# One line carrying the word and both numbers, never three greps over the whole pull output
# (#67). Split apart, this passed with the renumber report line deleted outright: another line
# of the same pull says "renumbered", and the CLAUDE.md warning below carries L2 and L5 together,
# so the three halves were answered by two unrelated lines and proved nothing (L135, L178).
check "#17 the renumber is reported, naming old and new" \
  "line_has \"\$out_lnm\" 'renumbered' 'L2 became L5'"
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
  "line_has \"\$out_lnm\" 'LESSONS\.md: rewrote' 'mention' 'of L2 to L5'"
check "#17 no go-and-check warning for the file it rewrote" \
  "! printf '%s' \"\$out_lnm\" | grep -qi 'still mentions'"
check "#17 a mention in another synced rule file is warned about" \
  "printf '%s' \"\$out_lnm\" | grep -q 'CLAUDE\.md also mentions L2'"
check "#17 that other file is never rewritten" \
  "grep -q 'see L2 for the rule' '$LNMBH/CLAUDE.md'"
# Or every assertion below is about files that were never delivered, and passes by
# reporting nothing about nothing (L143).
check "#43 the fixture's subdirectory files really did sync" \
  "[ -f '$LNMBH/hooks/x.sh' ] && [ -f '$LNMBH/skills/demo/SKILL.md' ]"
# Asserted as ONE line carrying both the path and the warning, never as two greps over the
# whole output. The first version of these two checks passed against unmodified code: the
# pull's own change report already names every file it applied, including hooks/x.sh and
# skills/demo/SKILL.md, and the CLAUDE.md warning already supplies "also mentions L2", so a
# pair of independent greps was satisfied by two unrelated lines and proved nothing (L135).
check "#43 a mention in a synced hooks file is warned about" \
  "printf '%s' \"\$out_lnm\" | grep -q 'hooks/x\.sh also mentions L2'"
check "#43 a mention in a synced skills file is warned about" \
  "printf '%s' \"\$out_lnm\" | grep -q 'skills/demo/SKILL\.md also mentions L2'"
# Named by the path it lives at, never by its basename: SKILL.md is the commonest
# filename in the whole config, so "SKILL.md also mentions L2" names nothing findable.
check "#43 a nested file is named by its path, not its basename" \
  "! printf '%s' \"\$out_lnm\" | grep -qE '(^|[^/])SKILL\.md also mentions'"
check "#43 neither subdirectory file is rewritten" \
  "grep -q 'see L2 for the rule' '$LNMBH/hooks/x.sh' && grep -q 'see L2 for the rule' '$LNMBH/skills/demo/SKILL.md'"
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
# Its own launchagents directory and fake fswatch. The pair it used to borrow belongs to the
# install-autosync section far above, which needs the fswatch binary ABSENT first and only creates
# it part way through, so borrowing it also meant depending on how far that section had got
# (claude-config#105).
ALDIR="$WORK/alias-la"; mkdir -p "$ALDIR"
ALFS="$WORK/alias-fswatch"; printf '#!/usr/bin/env bash\ntrue\n' > "$ALFS"; chmod +x "$ALFS"
ALIAS_LINE="alias claudesync='"'"'$HOME/claude-config-sync/claude-sync pull'"'"'"

# 1. a zshrc with no alias gets one appended, and existing content is preserved
ZRC="$ZDIR/rc-plain"
printf 'export EDITOR=bbedit\n' > "$ZRC"
outZ="$(SYNC_LAUNCHAGENTS="$ALDIR" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$ALFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "alias added when missing"        "grep -q 'alias claudesync=' '$ZRC'"
check "alias runs a pull"               "grep -q \"claude-sync' *pull\|claude-sync pull\" '$ZRC'"
check "alias line is commented"         "grep -q 'claude-config-sync: pull shared' '$ZRC'"
check "existing zshrc content kept"     "grep -q 'EDITOR=bbedit' '$ZRC'"
check "it says the alias was added"     "printf '%s' \"\$outZ\" | grep -qi 'Installed shell alias: claudesync'"

# 2. assume it runs twice: a second install must not append a duplicate
SYNC_LAUNCHAGENTS="$ALDIR" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$ALFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "no duplicate alias on re-run"    "[ \"\$(grep -c 'alias claudesync=' '$ZRC')\" = 1 ]"
check "no duplicate comment on re-run"  "[ \"\$(grep -c 'claude-config-sync: pull shared' '$ZRC')\" = 1 ]"

# 3. an absent zshrc is created rather than skipped
ZRC2="$ZDIR/rc-absent"
SYNC_LAUNCHAGENTS="$ALDIR" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$ALFS" \
  SYNC_ZSHRC="$ZRC2" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "absent zshrc is created"         "[ -f '$ZRC2' ]"
check "created zshrc has the alias"     "grep -q 'alias claudesync=' '$ZRC2'"

# 4. someone else's claudesync alias is LEFT ALONE and reported, never rewritten.
# This is the user's shell config: silently repointing a command they typed themselves
# is worse than telling them it differs.
ZRC3="$ZDIR/rc-conflict"
printf "alias claudesync='echo something else'\n" > "$ZRC3"
outZ3="$(SYNC_LAUNCHAGENTS="$ALDIR" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$ALFS" \
  SYNC_ZSHRC="$ZRC3" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "a different alias is untouched"  "grep -q 'echo something else' '$ZRC3'"
check "no second alias appended"        "[ \"\$(grep -c 'alias claudesync=' '$ZRC3')\" = 1 ]"
check "the difference is reported"      "printf '%s' \"\$outZ3\" | grep -qi 'differ\|already\|points'"

# 5. `~` and the expanded home directory are the SAME path, so an alias written with a
# tilde (which is how it was added by hand on this Mac) must count as already installed
# rather than as somebody else's conflicting alias. A gate that cries wolf gets ignored.
ZRC4="$ZDIR/rc-tilde"
printf "alias claudesync='~/claude-config-sync/claude-sync pull'\n" > "$ZRC4"
outZ4="$(SYNC_LAUNCHAGENTS="$ALDIR" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$ALFS" \
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
# As three greps over the whole output it did exactly that (#67): with the drop report
# deleted the assertion still passed, because the rewrite line below says "renumbered"
# and supplies both numbers. One line carrying the drop and both numbers is the test.
check "renumber: the drop names the old and new number" \
  "line_has \"\$out_rn\" 'dropped' 'L2 became L3'"
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
  "line_has \"\$out_rn2\" 'renumbered' 'L9 became L10'"
check "renumber: no duplicate number remains afterwards" \
  "! printf '%s' \"\$out_rn2\" | grep -qi 'used twice\\|used 2 times'"
# A warning that cries wolf gets ignored: nothing in this file mentions L9 in
# body text, so neither a rewrite report nor a go-and-check warning may fire here.
check "renumber: no mention handling when nothing mentions the old number" \
  "! printf '%s' \"\$out_rn2\" | grep -qiE 'rewrote|also mentions|still mentions'"

section "== #257: an exact duplicate is dropped, but must not be called a renumber =="
# Seen for real on Dans-MacBook-Pro, 2026-09-01. A by-hand rebase resolution had put the
# SAME entry, under the SAME number, into both this Mac's tree and the arriving payload.
# The additive merge kept both copies, drop_renumbered_duplicates correctly removed one,
# and then reported it as "L532 became L532": the tool's most safety critical message,
# the one that says an entry of yours was dropped, rendered with old and new identical.
# Two different situations reach that one line. `n != keep` is a real renumber; the
# `(s SUBSEP n) in taken` arm is a plain duplicate under the same number, where n == keep.
# Distinct causes get distinct messages (L11), and a false alarm on this path is what
# teaches a person to skim past the real one (L36), which the comment above
# preserve_local_conflicts already records happening once here.
DUP="$WORK/dupbare.git"; git init -q --bare -b main "$DUP"
DUPA="$WORK/duprepoA"; git clone -q "$DUP" "$DUPA" 2>/dev/null
cp "$SCRIPT" "$DUPA/claude-sync"
mkdir -p "$DUPA/payload/hooks"; echo '#!/bin/sh' > "$DUPA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$DUPA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$DUPA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body one\n' > "$DUPA/payload/LESSONS.md"
git -C "$DUPA" checkout -q -b main 2>/dev/null || true
git -C "$DUPA" add -A && git -C "$DUPA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$DUPA" push -q -u origin main

DUPBH="$WORK/duphomeB"; mkdir -p "$DUPBH"; echo '{"hooks":{}}' > "$DUPBH/settings.json"
DUPB="$WORK/duprepoB"; git clone -q "$DUP" "$DUPB" 2>/dev/null
CLAUDE_HOME="$DUPBH" SYNC_REPO="$DUPB" SYNC_NO_NOTIFY=1 bash "$DUPB/claude-sync" pull >/dev/null 2>&1

# Both Macs end up holding L2 with byte-identical text: no renumber happened anywhere.
# A local body mention of L2 rides along, because the equal-number line is also fed to
# settle_renumber_mentions, which counts MATCHES rather than changes and would report
# rewriting mentions of L2 to L2.
printf -- '- **L2. shared.** the very same sentence on both Macs\n- **L8. note.** a local note pointing at L2\n' >> "$DUPBH/LESSONS.md"
printf -- '- **L2. shared.** the very same sentence on both Macs\n- **L3. theirs.** only on Mac A\n' >> "$DUPA/payload/LESSONS.md"
git -C "$DUPA" add -A && git -C "$DUPA" -c user.name=t -c user.email=t@e commit -q -m "Mac A publishes the same L2" && git -C "$DUPA" push -q
out_dup="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DUPBH" SYNC_REPO="$DUPB" bash "$DUPB/claude-sync" pull 2>&1)"

# Precondition. Without the duplicate actually arising, every assertion below passes
# vacuously and the test proves nothing about the message it exists to check.
check "#257 precondition: the entry survives exactly once" \
  "[ \"\$(grep -c 'the very same sentence on both Macs' '$DUPBH/LESSONS.md')\" = 1 ]"
check "#257 precondition: the arriving entry keeps its number" \
  "grep -q '^- \*\*L2\. shared' '$DUPBH/LESSONS.md'"
check "#257 precondition: numbering passes its own check" \
  "CLAUDE_HOME='$DUPBH' SYNC_REPO='$DUPB' bash '$DUPB/claude-sync' check-lessons >/dev/null 2>&1"

# The defect itself: no line may claim a number became itself.
check "#257 no line says a number became itself" \
  "out_lacks \"\$out_dup\" '\\bL([0-9]+) became L\\1\\b'"
check "#257 the drop is not called a renumber" \
  "! line_has \"\$out_dup\" 'renumbered' 'L2'"
# Silence is not the fix either. An entry that vanishes with nothing said reads as a
# clean merge, which is the whole reason this report exists (#14).
check "#257 the duplicate drop is still reported, naming the entry" \
  "line_has \"\$out_dup\" 'duplicate' 'L2'"

# The downstream noise. With old and new equal there is nothing to rewrite and nothing
# for the reader to go and check, so neither may speak.
check "#257 no mention rewrite is reported for an unchanged number" \
  "out_lacks \"\$out_dup\" 'rewrote' i"
check "#257 no go-and-check warning for an unchanged number" \
  "out_lacks \"\$out_dup\" 'also mentions|still mentions' i"
check "#257 the local mention is left exactly as written" \
  "grep -q 'a local note pointing at L2' '$DUPBH/LESSONS.md'"

# A real renumber must still be reported as one: the fix must not silence the arm that
# works. Mac A takes B's work, then publishes a DIFFERENT lesson under L9 while B holds
# its own unsent L9, which is the ordinary collision that genuinely renumbers.
# B publishes the merge first. Without this its repo sits one commit ahead, Mac A's next
# push puts one the other way, and the second pull below refuses as a divergence instead
# of ever reaching the renumber: the assertions would then be judging an error message.
CLAUDE_HOME="$DUPBH" SYNC_REPO="$DUPB" SYNC_NO_NOTIFY=1 bash "$DUPB/claude-sync" push >/dev/null 2>&1
git -C "$DUPA" pull -q --no-rebase 2>/dev/null
printf -- '- **L9. clash.** this text is only on Mac B\n' >> "$DUPBH/LESSONS.md"
printf -- '- **L9. clash.** and this different text is only on Mac A\n' >> "$DUPA/payload/LESSONS.md"
git -C "$DUPA" add -A && git -C "$DUPA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds a clashing L9" && git -C "$DUPA" push -q
out_dup2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DUPBH" SYNC_REPO="$DUPB" bash "$DUPB/claude-sync" pull 2>&1)"
# The pull has to have RUN. A refusal (a divergence, a lock) prints a message and changes
# nothing, and every assertion below would then be reading that instead of a renumber.
check "#257 precondition: the second pull was not refused" \
  "out_lacks \"\$out_dup2\" 'diverged|NOTHING was received' i"
check "#257 a genuine renumber is still reported as one" \
  "line_has \"\$out_dup2\" 'renumbered' 'L9 became L10'"
check "#257 both clashing entries survive the genuine renumber" \
  "grep -q 'only on Mac B' '$DUPBH/LESSONS.md' && grep -q 'only on Mac A' '$DUPBH/LESSONS.md'"

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
# What `sync` SAID is kept, because a check that throws away the output of the command it is
# asserting about can only ever report that the thing did not happen, never why. This one failed
# once on a CI runner and there was nothing to look at: sync can decline quietly by design, since a
# short outage is deliberately not shouted about, so its silence is exactly what has to be readable
# here (L11, L148).
out_up2="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_up2=$?
bare_log_up2="$(git -C "$UPB" log --oneline main 2>/dev/null || true)"
check "#16 sync exited cleanly before its commit is looked for" \
  "[ '$rc_up2' -eq 0 ] || { echo \"    sync exited $rc_up2 and said: $out_up2\" >&2; false; }"
check "#16 sync also sends a non-payload commit" \
  "printf '%s' \"\$bare_log_up2\" | grep -q 'second edit outside payload' || { echo \"    sync exited $rc_up2 saying: $out_up2\" >&2; echo \"    the remote log holds: $bare_log_up2\" >&2; false; }"

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
  mkskill "$PHA/skills/s/SKILL.md" 'one'; echo '{"hooks":{}}' > "$PHA/settings.json"
  CLAUDE_HOME="$PHA" SYNC_REPO="$PA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
}

# 1) the remote cannot be REACHED. Uses a vanished local path, never a real host, so the
# suite is structurally unable to depend on the network being down to pass.
seed_pair unreach; UNR="$PA"; UNH="$PHA"
git -C "$UNR" remote set-url origin "$WORK/vanished.git"
mkskill "$UNH/skills/s/SKILL.md" 'two'
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
mkskill "$CFHA/skills/s/SKILL.md" 'A rewrote this line'
CLAUDE_HOME="$CFHA" SYNC_REPO="$CFA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
mkskill "$CFHB/skills/s/SKILL.md" 'B rewrote this line'
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
mkskill "$OTHB/skills/s/SKILL.md" 'B edit'
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
  "line_has \"\$out_other\" 'git said:' 'untracked working tree files'"

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
mkskill "$STHB/skills/s/SKILL.md" 'B edit'
out_stash="$(CLAUDE_HOME="$STHB" SYNC_REPO="$STR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync 2>&1)"; rc_stash=$?
check "#22 a conflicted autostash restore is not reported as a clean sync" "[ $rc_stash -ne 0 ]"
check "#22 a conflicted autostash restore does not announce success" \
  "! printf '%s' \"\$out_stash\" | grep -q 'Synced (sent local changes'"
check "#22 a conflicted autostash restore says the edits were parked" \
  "printf '%s' \"\$out_stash\" | grep -qi 'parked them in a stash and left conflict markers'"
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
echo 'L1' > "$CQH/LESSONS.md"; mkskill "$CQH/skills/beta/SKILL.md" 'SKILL'
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
  "printf '%s' \"\$out_conf20\" | grep -qE 'skills/beta/SKILL\.md\.conflict-OtherMac \([0-9]+ days old'"
check "#20 status says how old each copy is" \
  "printf '%s' \"\$out_conf20\" | grep -q '9 days'"
check "#20 status says what to do about them" \
  "printf '%s' \"\$out_conf20\" | grep -qi 'Compare each with the live file next to it, then delete the copy'"
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
echo '{"hooks":{}}' > "$LKH/settings.json"; mkskill "$LKH/skills/l/SKILL.md" 'L'
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
mkskill "$LKGH/skills/l/SKILL.md" 'L'; echo '{"hooks":{}}' > "$LKGH/settings.json"
CLAUDE_HOME="$LKGH" SYNC_REPO="$LKGR" SYNC_LOCK="$LOCK" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$LKGR" remote set-url origin "$WORK/lock-vanished.git"
mkskill "$LKGH/skills/l/SKILL.md" 'edited'
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
mkskill "$OUH/skills/o/SKILL.md" 'O'; echo '{"hooks":{}}' > "$OUH/settings.json"
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
mkskill "$OUH/skills/o/SKILL.md" 'edited'
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
  "printf '%s' \"\$out_sust\" | grep -qE 'Syncing has now been failing for (less than a minute|[0-9]+ (minute|hour|day|week|month)s?)'"
# The sub-minute case is the one that shows why (#77). Dividing seconds by 60 and printing the
# result told somebody their sync had been failing for "0 minutes", which is not a duration anybody
# can act on and reads as though nothing is wrong. A shared renderer has a word for it.
check "#77 a sub-minute outage is not reported as zero minutes" \
  "! line_has \"\$out_sust\" 'failing for' '0 minutes'"

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
mkskill "$SNH/skills/s/SKILL.md" 'S'; echo '{"hooks":{}}' > "$SNH/settings.json"
CLAUDE_HOME="$SNH" SYNC_REPO="$SNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
rm -f "$SNR/.last-success"        # so only the send under test can put it back
mkskill "$SNH/skills/s/SKILL.md" 'edited by the watcher'
CLAUDE_HOME="$SNH" SYNC_REPO="$SNR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send >/dev/null 2>&1
check "#22 a successful send also records that the repo was reachable" "[ -s '$SNR/.last-success' ]"
# The failure side: a send that never reaches the repo must record nothing, or the clock
# would be refreshed by the very outage it exists to measure.
git -C "$SNR" remote set-url origin "$WORK/send-clock-gone.git"
rm -f "$SNR/.last-success"
mkskill "$SNH/skills/s/SKILL.md" 'edited again'
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
mkskill "$VFHA/skills/v/SKILL.md" 'V1'; echo '{"hooks":{}}' > "$VFHA/settings.json"
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
check "#23 verify names the other Mac"        "printf '%s' \"\$out_v2\" | grep -q 'macB: up to date with the shared config'"
check "#23 verify says the two Macs agree"    "printf '%s' \"\$out_v2\" | grep -qi 'both Macs agree on the same config'"

# A changes the config and publishes. B has not applied it, so B is BEHIND, and verify must
# say so by name rather than reporting a clean bill of health.
mkskill "$VFHA/skills/v/SKILL.md" 'V2 changed on A'
CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_v3="$(CLAUDE_HOME="$VFHA" SYNC_REPO="$VFA" SYNC_HOSTNAME=macA SYNC_NO_NOTIFY=1 bash "$SCRIPT" verify 2>&1)"
check "#23 verify reports the other Mac as behind"  "printf '%s' \"\$out_v3\" | grep -qE 'macB: BEHIND by [0-9]+ config change'"
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
mkdir -p "$VFC/payload/skills/v"; mkskill "$VFC/payload/skills/v/SKILL.md" 'V'
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
mkskill "$OCH/skills/o/SKILL.md" 'O'; echo '{"hooks":{}}' > "$OCH/settings.json"
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$OCR" remote set-url origin "$WORK/ocount-gone.git"
mkskill "$OCH/skills/o/SKILL.md" 'edited'
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync >/dev/null 2>&1 || true
check "#24 a quiet outage is recorded" "[ -s '$OCR/.outage-log' ]"
check "#24 the record says it stayed quiet" "grep -q 'quiet' '$OCR/.outage-log'"
mkskill "$OCH/skills/o/SKILL.md" 'edited again'
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 SYNC_OUTAGE_ALERT_AFTER=0 bash "$SCRIPT" sync >/dev/null 2>&1 || true
check "#24 an alerting outage is recorded too" "grep -q 'alert' '$OCR/.outage-log'"
check "#24 the two decisions are kept apart" \
  "[ \"\$(grep -c 'quiet' '$OCR/.outage-log')\" = 1 ] && [ \"\$(grep -c 'alert' '$OCR/.outage-log')\" = 1 ]"
out_oc="$(CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#24 status reports the tally"     "printf '%s' \"\$out_oc\" | grep -qi 'outage decisions so far:'"
# The tally exists to judge the threshold, so it must not imply every record was judged under
# the CURRENT one. The two outages above were deliberately made under different thresholds
# (10800 then 0), so a summary quoting one number for all of them would be telling you
# something untrue about the data you are being asked to draw a conclusion from.
check "#24 each record carries the threshold it was judged under" \
  "grep -q ' 10800$' '$OCR/.outage-log' && grep -q ' 0$' '$OCR/.outage-log'"
check "#24 a mixed tally says the threshold changed" \
  "printf '%s' \"\$out_oc\" | grep -qi 'different threshold'"
check "#24 the tally names both counts" \
  "printf '%s' \"\$out_oc\" | grep -q '1 quiet, 1 alerted'"
# A run that reached the repo must not be recorded as an outage, or the tally that exists to
# judge the threshold is padded with every healthy sync and answers nothing.
git -C "$OCR" remote set-url origin "$OCB"
mkskill "$OCH/skills/o/SKILL.md" 'fine now'
CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#24 a healthy sync records no outage" \
  "[ \"\$(grep -c . '$OCR/.outage-log')\" = 2 ]"
# Failure path: a corrupt log must not crash status nor be silently reported as zero events.
printf 'garbage line with no fields\n' >> "$OCR/.outage-log"
out_ocbad="$(CLAUDE_HOME="$OCH" SYNC_REPO="$OCR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"; rc_ocbad=$?
check "#24 status survives a corrupt outage log"  "[ $rc_ocbad -eq 0 ]"
check "#24 and says a record could not be read"   "printf '%s' \"\$out_ocbad\" | grep -qE '[0-9]+ record\(s\) unreadable and not counted'"

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
mkskill "$STH2/skills/s/SKILL.md" 'S'; echo '{"hooks":{}}' > "$STH2/settings.json"
CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1

# A lock whose recorded process is long gone AND which is older than any plausible run must
# not block. The pid could have been reused by an unrelated process on the machine the folder
# was restored onto, in which case the liveness test alone says "held" for ever.
STLOCK="$STR2/.sync-lock"; mkdir -p "$STLOCK"; printf '%s\n' "$$" > "$STLOCK/pid"
touch -t "$(date -v-2d +%Y%m%d%H%M)" "$STLOCK/pid" 2>/dev/null || touch -d '2 days ago' "$STLOCK/pid"
mkskill "$STH2/skills/s/SKILL.md" 'edited'
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
mkskill "$STH2/skills/s/SKILL.md" 'edit again'
out_fut="$(CLAUDE_HOME="$STH2" SYNC_REPO="$STR2" SYNC_NOTIFIER="$FAKEN2" SYNC_NO_NOTIFY=0 \
  SYNC_OUTAGE_ALERT_AFTER=10800 bash "$SCRIPT" sync 2>&1 || true)"
check "#25 a clock in the future does not silence an outage" "[ -s '$NOTED2' ]"
check "#25 and it says the record was not usable" \
  "printf '%s' \"\$out_fut\" | grep -qi 'no record'"
# Control, so the rule above cannot be satisfied by simply alerting on everything: an
# ordinary recent success must still keep a blip quiet.
: > "$NOTED2"
printf '%s\n' "$(( $(date +%s) - 60 ))" > "$STR2/.last-success"
mkskill "$STH2/skills/s/SKILL.md" 'edit once more'
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
mkskill "$GHH/skills/g/SKILL.md" 'G'; echo '{"hooks":{}}' > "$GHH/settings.json"
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
# A second Mac publishes, then goes away for good and never applies anything again.
GHR2="$WORK/ghost-repo2"; git clone -q "$GHB" "$GHR2" 2>/dev/null
GHH2="$WORK/ghost-home2"; mkdir -p "$GHH2"; echo '{"hooks":{}}' > "$GHH2/settings.json"
CLAUDE_HOME="$GHH2" SYNC_REPO="$GHR2" SYNC_HOSTNAME=macGone SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
mkskill "$GHH/skills/g/SKILL.md" 'G changed'
CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
# Age the departed Mac's marker past the point where it can mean anything.
GHREF="refs/claude-sync-state/macGone"
out_gh="$(CLAUDE_HOME="$GHH" SYNC_REPO="$GHR" SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 \
  SYNC_MAC_RETIRE_AFTER=0 bash "$SCRIPT" verify 2>&1 || true)"
check "#26 a long-silent Mac is called retired, not behind" \
  "printf '%s' \"\$out_gh\" | grep -qi 'RETIRED, no sign of it since'"
check "#26 a retired Mac is not counted as behind" \
  "! printf '%s' \"\$out_gh\" | grep -q 'macGone: BEHIND'"
check "#26 and it no longer blocks the verdict" \
  "CLAUDE_HOME='$GHH' SYNC_REPO='$GHR' SYNC_HOSTNAME=macNow SYNC_NO_NOTIFY=1 SYNC_MAC_RETIRE_AFTER=0 bash '$SCRIPT' verify >/dev/null 2>&1"
# The boundary is NOT pinned here, and that is a gap stated rather than a guard held. A check that
# a zero window retires a marker written this second cannot fail on a Mac: the marker is never read
# in the same second it was written, so the old exclusive comparison satisfies it too. It was
# written, watched passing against the defect, and removed. The evidence for the inclusive
# comparison is the flakiness itself: the same commit, two runs two seconds apart, one green and
# one red on the three checks above. Proving it directly needs a seam for the clock, which the tool
# does not have.
# Retired must NOT mean forgotten: it still has to be named, or a Mac that genuinely fell
# behind quietly disappears from the report that exists to notice exactly that.
check "#26 a retired Mac is still named"  "printf '%s' \"\$out_gh\" | grep -q 'macGone: RETIRED'"
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
# These subruns used to be SKIPPED entirely inside a filtered run, because a filtered child
# inherited SUITE_FILTERED, skipped its own extraction, ran the WHOLE suite, reached this
# section again and spawned further, without bound. It filled this Mac with runaway suite
# processes on 2026-08-17 and had to be killed by hand.
# The flag is no longer inherited (#37), so the skip is gone with the reason for it. That also
# closes a hole the skip left behind: `SECTION_UNTIL` at or past this section silently ran none
# of the checks below, which are exactly the ones you would be iterating on.
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
_want=""
while IFS= read -r _wl; do
  [ -n "$_wl" ] || continue
  _want="$_want$(section_title "$_wl")
"
done <<WANTED
$(awk '/^section "/{print; if (index($0, "sync (two-way) over a local fake remote")>0) exit}' "$SCRIPT_SELF")
WANTED
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
# reaching this section spawns one child and no grandchildren. That measurement is now a check,
# in the #37 section below.

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
# Placed by what the line SAYS, not by its number. Pinned to NR==30 this broke the moment two
# lines were added to the usage header: the injected call landed ABOVE `set -e`, so its exit 127
# no longer stopped anything, the pull completed normally, and the two checks below failed
# describing the gate rather than the fixture (L237).
awk '{print} /^set -euo pipefail$/ && !done {print "a_helper_that_does_not_exist_on_this_mac"; done=1}' \
  "$SCRIPT" > "$SUA/claude-sync"
git -C "$SUA" add claude-sync && git -C "$SUA" -c user.name=t -c user.email=t@e commit -q -m "push a runnable-looking but broken script" && git -C "$SUA" push -q
check "#28 the broken version really does still parse" "bash -n '$SUA/claude-sync' 2>/dev/null"
# And that it actually DIES when run, which is the whole fixture. Parsing alone was true of the
# version that landed above `set -e` too, and that one proved nothing (L48, L1).
check "#28 and it really does fail on its first step" \
  "! bash '$SUA/claude-sync' help >/dev/null 2>&1"
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
mkskill "$CJH/skills/c/SKILL.md" 'C'; echo '{"hooks":{}}' > "$CJH/settings.json"
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
  # And state that lives OUTSIDE every clone, which claude-config#189 was the first of. Deriving
  # only from $SYNC_REPO made a new category of state file exempt from the very check written to
  # notice a new state file, and the exemption would have been invisible because it was correct for
  # everything that existed when it was written (L129, L96).
  # $HOME/.claude is excluded for the same reason payload is: it is the synced content itself,
  # documented at length elsewhere, not a record this tool keeps about this Mac.
  grep -E '^[A-Z_]+="[^"]*\$HOME/' "$SCRIPT" \
    | grep -oE '\$HOME/[^"}]*' | sed 's|\$HOME/||' | grep -v '^\.claude$' | sort -u
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
# Every spawn here used to clear SUITE_FILTERED by hand, and that was the sharpest edge in the
# section. This section can itself be reached inside a filtered run, which exported that flag to
# everything it started, so a child inheriting it skipped the section filter above, ran the WHOLE
# suite, arrived back here and spawned again, one level at a time, for ever. Not a wide explosion
# a process count would catch: a slow chain that looks exactly like a suite merely taking a while,
# which is the whole reason #31 and #34 both exist.
# The clearing is gone from the call sites because the flag is no longer exported at all (#37).
# A rule living at each site protects only the sites that remembered it, and a site added later
# never saw it (L96); the un-export sits ahead of all of them and is checked to.
_deep(){ SUITE_DEPTH="$1" SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1; }

_d2="$(_deep 2)"; _d2_rc=$?
check "#34 a run past the depth limit refuses to run at all" "[ '$_d2_rc' -ne 0 ]"
# Matched on the REFUSAL's own wording, not on the depth token. A run that is ALLOWED at depth 2
# announces itself from the line above as "running at depth 2 (the limit is 3)", which contains
# "depth 2", so the token alone is satisfied by a run that was never refused at all. That is not a
# theory: this check passed in a measured run where the child ran happily and its two neighbours
# correctly flipped to FAIL, which is the worst version, a section reporting a partial pass
# exactly where the guard is not working (L156, claude-config#109).
check "#34 the refusal says how deep it was asked to go" "printf '%s' \"\$_d2\" | grep -q 'refusing to run at depth 2'"

# And the two states are shown to be tellable apart, in the same fixture, or the wording above is
# just a different string nobody has watched failing to match (L159). A run inside the limit must
# announce and must NOT carry the refusal.
_d2ok="$(SUITE_DEPTH=2 SUITE_MAX_DEPTH=3 SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1)"
check "#34 a run inside the limit announces rather than refuses" "printf '%s' \"\$_d2ok\" | grep -q 'running at depth 2'"
check "#34 and an announcement does not read as a refusal" "! printf '%s' \"\$_d2ok\" | grep -q 'refusing to run at depth'"
# The old token, asked of the run that was NOT refused. It matches, which is the defect, and saying
# so here keeps the reason this check is worded the way it is attached to the evidence for it.
check "#34 the bare depth token would have passed on that run" "printf '%s' \"\$_d2ok\" | grep -q 'depth 2'"
# It must refuse EARLY, not run the suite and complain afterwards: a refusal that still pays for
# a full run is not a limit on anything. A real run prints per-section headings and a PASS= line.
check "#34 it refuses before running any checks" "! printf '%s' \"\$_d2\" | grep -q '^PASS='"

# A value that cannot be compared must never land on the permissive side of a threshold (L50).
# `[ abc -gt 1 ]` is a shell ERROR, not a false, and this suite runs without `set -e`, so an
# unvalidated compare would let a garbage depth through as "not too deep" and the limit would be
# off precisely when the environment is wrong.
_dj="$(_deep abc)"; _dj_rc=$?
check "#34 a depth that is not a number is refused, not waved through" "[ '$_dj_rc' -ne 0 ]"
check "#34 the refusal names the value it could not read" "printf '%s' \"\$_dj\" | grep -q 'SUITE_DEPTH=.abc. is not a whole number'"
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
# The runs below are TAGGED, so the watchdogs they leave can be told from every other watchdog on
# the machine (claude-config#159). It used to count `pgrep -f suite-deadline-watchdog` before and
# after and require the second number to be no larger: that count is global, the default run is
# four shards each with a watchdog of its own, and any of them starting a child inside that window
# raised it for reasons unrelated to these runs. It failed once in three full runs on 2026-08-22
# on an unchanged tree, and an intermittent red blocks a legitimate push (L205, L134).
#
# With a tag there is no window and no subtraction: nothing else on the machine can carry it, so
# the assertion is simply that none survive.
_wd_tag="wdtag$$-$SECONDS"
# The runs below poll in tenths (claude-config#206). While the watchdog polled every 2 seconds the
# deadline was noticed up to 2 seconds late, and that overshoot was the only slack this fixture
# had: the ceiling is measured from the START, so it has to outlast everything before `push`.
# Nothing chose that slack, it was a side effect of a constant three hundred lines away (L281).
#
# Measured instead. A child reaches `push` in 0.8 seconds, over three runs on 2026-08-30, so the
# ceiling is set at five times that rather than at a 6 nobody derived, and the poll no longer has
# to make up the difference.
_hang_poll=0.1
_hang_deadline=4
_t0="$(date +%s)"
_hang="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_TIMEOUT=$_hang_deadline SUITE_HANG_IN=push SUITE_POLL_INTERVAL=$_hang_poll SUITE_WATCHDOG_TAG="$_wd_tag" bash "$SCRIPT_SELF" 2>&1)"; _hang_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
check "#31 a hung run ends instead of waiting for ever" "[ '$_hang_rc' -ne 0 ]"
check "#31 it says plainly that it timed out"   "printf '%s' \"\$_hang\" | grep -q 'TIMED OUT'"
check "#31 it names the section it died in"     "printf '%s' \"\$_hang\" | grep -q 'still inside section: == push =='"
# The whole point is that a hang stops reading as an ordinary run, so it must never leave behind
# the summary line that means everything passed.
check "#31 a hung run is never reported as green" "! printf '%s' \"\$_hang\" | grep -q 'FAIL=0'"

# The other half, and the one that would do real damage if it were wrong: a deadline that fires
# on a HEALTHY run turns every ordinary run into a false failure. A guard has to be seen not
# firing when it should not, not only firing when it should.
# TIMED, because it is also the reference the hung run above is judged against (claude-config#149).
_ok_t0="$(date +%s)"
_okrun="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL=push SUITE_TIMEOUT=300 SUITE_POLL_INTERVAL=$_hang_poll SUITE_WATCHDOG_TAG="$_wd_tag" bash "$SCRIPT_SELF" 2>&1)"; _okrun_rc=$?
_ok_elapsed=$(( $(date +%s) - _ok_t0 ))
check "#31 a healthy run is not killed by its own deadline" "! printf '%s' \"\$_okrun\" | grep -q 'TIMED OUT'"
check "#31 and still reports its result"        "[ '$_okrun_rc' -eq 0 ]"

# How long the hung run took, judged against the HEALTHY one just measured rather than against a
# number written here (claude-config#149). It used to be "under 30 seconds", chosen not measured,
# and on 2026-08-21 a Mac at load 38 to 103 pushed an ordinary run of this past it: a red result
# that has to be re-run before it is believed stops being read (L36).
#
# The healthy run reaches the same section this one hangs in, so it is an upper bound on the work
# the hung run got through, and it stretches with the machine exactly as the hung run does. The
# slack over it is three of the hung run's OWN deadlines, which is a knob set on the line above
# rather than a constant that can age. What this has to catch is the run taking as long as
# whatever it was sitting in, which is what happened when only the run itself was killed and its
# children were left holding the output open.
_hang_max=$(( _ok_elapsed + 3 * _hang_deadline ))
check "#31 it ends near its deadline rather than long after (${_elapsed}s against a bound of ${_hang_max}s)" \
  "[ '$_elapsed' -le '$_hang_max' ]"
# The same comparison, asked of one second over that bound, so it has been watched REFUSING rather
# than only agreeing. Without it any bound large enough satisfies the check, which is every bound,
# and it would read as protection while protecting nothing (L1).
check "#31 and a run one second over that bound is refused" \
  "! [ $(( _hang_max + 1 )) -le '$_hang_max' ]"

# A watchdog that outlives the run it watches is holding a process id that the system is free to
# hand to something else, and it kills what it finds there. Each one exits within a poll of its
# own run ending, so this waits a few seconds for that rather than reading the instant after.
_wd_now=0
_wd_wait=0
while [ "$_wd_wait" -lt 10 ]; do
  _wd_now="$(pgrep -f "suite-deadline-watchdog.$_wd_tag" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${_wd_now:-0}" -eq 0 ] && break
  sleep 1; _wd_wait=$((_wd_wait + 1))
done
check "#31 the runs above left no watchdog of their own behind" "[ '${_wd_now:-0}' -eq 0 ]"
# The control, and it is what stops the check above passing by looking for something that could
# never exist. A pattern that matches nothing reads exactly like a clean answer (L98, L1), and a
# mistyped tag would give zero for ever. So the UNTAGGED pattern must still find at least one:
# this very run has a watchdog of its own whenever it has a deadline at all.
if [ "$SUITE_TIMEOUT" -gt 0 ]; then
  _wd_any="$(pgrep -f suite-deadline-watchdog 2>/dev/null | wc -l | tr -d ' ')"
  check "#31 and the search really can find a watchdog, so zero means zero" "[ '${_wd_any:-0}' -ge 1 ]"
else
  check "#31 this run has no deadline, so it has no watchdog to find" "[ '$SUITE_TIMEOUT' -eq 0 ]"
fi

section "== the deadline kills a run that STOPPED, not one that is merely slow (#152) =="
# The watchdog measured its deadline by adding 2 to a counter once per `sleep 2`, so it counted
# ITERATIONS and not time. Every iteration also forks `sleep` and a process check, and process
# launches are what a busy Mac is slowest at, so the counter ran far behind the clock: a full run
# measured at 1943s of wall clock on 2026-08-22 was never killed by its nominal 900s deadline, and
# the same loop asked for 60 seconds ran past 400 under load.
#
# Making it read a real clock is two lines, and on its own it would have KILLED that 1943s run,
# which was healthy and merely on a loaded machine. That is the false failure #149 exists to
# remove, arriving by another route. A wall clock total cannot tell a hung run from a slow one,
# which is the only distinction this deadline is for.
#
# So it watches PROGRESS. The run already records which section it has reached, which is how the
# timeout names where it died; a stopped run leaves that mark alone while a slow one keeps moving
# it. The total is kept as a generous ceiling for a runaway that somehow keeps moving, and both
# timers now read a real clock.
_st_tag="sttag$$-$SECONDS"

# Every run below sets SUITE_POLL_INTERVAL (claude-config#206). It is the granularity of the
# watchdog and of the pause SUITE_SLOW_IN puts in each section, and while it was two hard coded
# two second sleeps the smallest stall this section could STAGE was several seconds. It changes
# nothing about what is asserted: both deadlines are read off a clock either way, and the numbers
# below move together with it.
#
# What it cannot go below is the slowest section the run passes through, because the stall bound
# has to clear that or a healthy prelude trips it. Measured 2026-08-30, the run up to `apply is
# idempotent` is 7 sections and 9.6 seconds with no pauses at all, and its slowest single section
# is 3 seconds. So the bounds here are set against THAT rather than against the poll.
_st_poll=0.1

# Killed for stopping, with the ceiling set far away so what killed it is not in doubt. This run
# hangs in `push`, which a child reaches in 0.8 seconds measured 2026-08-30 over three runs, and
# the stall timer restarts at every section, so what the bound has to clear is the widest gap
# inside those 0.8 seconds and not the whole prelude. 4 is roughly five times the entire run up to
# that point, which leaves room for a runner several times slower than this Mac.
_st_t0="$(date +%s)"
_st_hang="$(SUITE_TIMEOUT=600 SUITE_STALL_TIMEOUT=4 SUITE_HANG_IN=push SUITE_POLL_INTERVAL=$_st_poll \
  SUITE_WATCHDOG_TAG="$_st_tag" SUITE_DEPTH=$SUITE_CHILD_DEPTH bash "$SCRIPT_SELF" 2>&1)"; _st_hang_rc=$?
_st_hang_elapsed=$(( $(date +%s) - _st_t0 ))
check "#152 a run that stopped making progress is killed" "[ '$_st_hang_rc' -ne 0 ]"
check "#152 and it says plainly that there was no progress" \
  "case \"\$_st_hang\" in *'no progress'*) true ;; *) false ;; esac"
check "#152 and still names the section it stopped in" \
  "case \"\$_st_hang\" in *'still inside section: == push =='*) true ;; *) false ;; esac"
# It was the STALL timer and not the ceiling. The ceiling was set a hundred times further away, so
# anything ending near the stall timeout can only have come from the stall timer. None of these
# three numbers is measured, they are the fixture's own: the bound separates the two settings from
# each other rather than being calibrated against how fast this Mac is, and twenty times the stall
# timeout is still nowhere near the ceiling (L172).
check "#152 and the ceiling 600s away was not what killed it (took ${_st_hang_elapsed}s)" \
  "[ '$_st_hang_elapsed' -lt 120 ]"

# The half that matters most, and the one the old total-time deadline got wrong: a run that keeps
# MOVING is left alone however long it takes. Every section is made to pause, so the run outlasts
# its own stall timeout several times over while never once stopping.
_st_t1="$(date +%s)"
# Far enough in that several sections run, since `push` is the FIRST one and a two section run
# cannot outlast anything. Every section pauses, so the run spends a few seconds in each and many
# times the stall timeout in total, without ever once stopping.
# This run needs BOTH things at once, and they pull against each other. Every gap between two
# sections must stay under the bound, or a healthy run is called stopped; and the whole run must
# exceed the bound, or the check below passes without ever testing anything. The pause is what
# supplies the second, so this run polls in whole seconds where the two above poll in tenths: at a
# tenth the pauses contributed 0.7 seconds to a run whose natural length varies between 5 and 10
# seconds on this Mac, and the control landed on exactly its own bound and went red.
#
# Measured 2026-08-30: 7 sections, 9.6 seconds with no pauses at all, widest single section 3
# seconds. So a 1 second pause makes the widest gap 4 against a bound of 6, and the total at least
# 12, which is both margins wider than the two second pause against a bound of 8 this replaces.
_st_slow_poll=1
_st_slow_stall=6
_st_slow="$(SUITE_TIMEOUT=600 SUITE_STALL_TIMEOUT=$_st_slow_stall SUITE_SLOW_IN='==' SUITE_POLL_INTERVAL=$_st_slow_poll \
  SECTION_UNTIL='apply is idempotent' SUITE_WATCHDOG_TAG="$_st_tag" SUITE_DEPTH=$SUITE_CHILD_DEPTH bash "$SCRIPT_SELF" 2>&1)"; _st_slow_rc=$?
_st_slow_elapsed=$(( $(date +%s) - _st_t1 ))
# The control for the fixture first: if it did not actually outlast the stall timeout, the check
# below passes by never having tested anything (L159, L101).
check "#152 the fixture really did outlast its own stall timeout (${_st_slow_elapsed}s against ${_st_slow_stall}s)" \
  "[ '$_st_slow_elapsed' -gt '$_st_slow_stall' ]"
check "#152 a run that keeps progressing is not killed, however long it takes" \
  "case \"\$_st_slow\" in *'TIMED OUT'*) false ;; *) true ;; esac"
check "#152 and it still reports its own result" "[ '$_st_slow_rc' -eq 0 ]"

# The ceiling still exists, for a runaway that somehow keeps moving. Its message must be DIFFERENT
# from the stall one, or the reader cannot tell a run that stopped from one that simply went on too
# long, and those need different remedies (L11).
# The ceiling is measured from the START of the run and not from the last section, so unlike the
# two above it has nothing to clear: whatever this run is doing when it fires, a ceiling that
# fires is what these three checks are about, and none of them names a section.
_st_ceil="$(SUITE_TIMEOUT=3 SUITE_STALL_TIMEOUT=600 SUITE_HANG_IN=push SUITE_POLL_INTERVAL=$_st_poll \
  SUITE_WATCHDOG_TAG="$_st_tag" SUITE_DEPTH=$SUITE_CHILD_DEPTH bash "$SCRIPT_SELF" 2>&1)"; _st_ceil_rc=$?
check "#152 the absolute ceiling still kills a run that reaches it" "[ '$_st_ceil_rc' -ne 0 ]"
check "#152 and says it was the ceiling" \
  "case \"\$_st_ceil\" in *'wall clock'*) true ;; *) false ;; esac"
check "#152 and that is worded differently from the no-progress message" \
  "case \"\$_st_ceil\" in *'no progress'*) false ;; *) true ;; esac"

# Neither of those runs may leave a watchdog behind, the same claim #31 makes and for the same
# reason: a watchdog outliving its run holds a process id the system may reuse.
# Polled finely rather than in whole seconds: this waits on a CONDITION, and the common case is
# that it is already true, so a one second granularity only ever costs the case where it is not
# (L290). The ceiling it gives up at is the same five seconds as before.
_st_wd=0; _st_wait=0
while [ "$_st_wait" -lt 25 ]; do
  _st_wd="$(pgrep -f "suite-deadline-watchdog.$_st_tag" 2>/dev/null | wc -l | tr -d ' ')"
  [ "${_st_wd:-0}" -eq 0 ] && break
  sleep 0.2; _st_wait=$((_st_wait + 1))
done
check "#152 none of those runs left a watchdog behind" "[ '${_st_wd:-0}' -eq 0 ]"

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
  SUITE_LOCK="$1" SUITE_DEPTH="${2:-0}" SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1
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
check "#32 and runs none of the checks"           "! printf '%s' \"\$_held\" | grep -q '^PASS='"

# A crashed run must not wedge the suite for good. The owner being gone is the evidence, not the
# clock, because this lock only ever holds a process id from THIS machine.
_mklock "$_lockdir/dead" "99999999" "$_thishost" "$((_now - 5))"
# TIMED, because it is the reference the refusal above is judged against (claude-config#149).
_dead_t0="$(date +%s)"
_dead="$(_try_lock "$_lockdir/dead")"; _dead_rc=$?
_dead_elapsed=$(( $(date +%s) - _dead_t0 ))
check "#32 a lock whose owner is gone is taken over" "[ '$_dead_rc' -eq 0 ]"
check "#32 and says it took it over"                 "printf '%s' \"\$_dead\" | grep -qi 'took over'"

# Refuse, never queue: a run that waits silently is the stall this issue was filed about. Judged
# against the run just above, which took the lock and went on to do the work, rather than against
# a fixed twenty seconds (claude-config#149). Both start the same suite the same way and only one
# of them proceeds, so a refusal that cost MORE than a run which did the work is the queueing this
# forbids, and both figures stretch together when the Mac is busy. The old constant did not: on
# 2026-08-21 a loaded Mac pushed an ordinary refusal past it and the check went red with the lock
# working perfectly.
# Twice that run, plus one second. Both figures are whole seconds off the same clock, so two
# genuinely equal durations can read a second apart and the floor is the instrument's resolution
# rather than an allowance for a slow machine. Twice, because both runs pay the same startup and
# only one of them then does the work, so the two land close together (2s against 2s, measured
# 2026-08-21) and a bound with no room is a coin toss. What it has to catch is not a second of
# drift: a run that QUEUED would sit here until its own deadline, which is 900 seconds away.
_held_max=$(( _dead_elapsed * 2 + 1 ))
check "#32 it refuses rather than queueing behind it (${_held_elapsed}s against a bound of ${_held_max}s)" \
  "[ '$_held_elapsed' -le '$_held_max' ]"
# And watched REFUSING, or the comparison is satisfied by any refusal fast enough, which is every
# refusal (L1).
check "#32 and a refusal one second over that bound would be caught" \
  "! [ $(( _held_max + 1 )) -le '$_held_max' ]"

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

# Breaking a stale lock is `rm -rf` on a path that comes from the environment, so a typo naming a
# real directory would delete it. A directory with no pid file in it is not a lock this tool wrote,
# whatever it is, and must be refused rather than cleared (L5, L9). It happens to be refused today
# for an unrelated reason (no recorded host, so it reads as a fresh lock from another machine),
# which is safe by accident, and safe by accident stops being true the moment the neighbouring
# rules change.
_notlock="$_lockdir/precious"; mkdir -p "$_notlock"
echo 'do not delete me' > "$_notlock/important.txt"
printf '%s\n' "$_thishost" > "$_notlock/host"     # would otherwise be judged ours, owner gone
_np="$(_try_lock "$_notlock")"; _np_rc=$?
check "#32 a directory that is not a lock is refused" "[ '$_np_rc' -ne 0 ]"
check "#32 and it is not deleted"                    "[ -f '$_notlock/important.txt' ]"
# A path naming somewhere real is refused before anything reads or removes it.
_hp="$(_try_lock "$HOME")"; _hp_rc=$?
check "#32 a lock path naming a real home directory is refused" "[ '$_hp_rc' -ne 0 ]"
check "#32 and that home directory still exists"                "[ -d '$HOME' ]"

section "== a run killed from outside cleans up after itself (#163) =="
# needs: only one suite run at a time
# `trap suite_cleanup EXIT` covers a run that ENDS. It does not cover one killed from OUTSIDE,
# which is how a run in development actually stops: a harness timeout, a Ctrl-C, a terminal
# closing. The re-executed copy and the shards then keep going as orphans and they keep holding the
# run lock, and every later run refuses naming a process id that means nothing to the reader.
#
# It cost two separate false failure investigations in one session on 2026-08-22: run-all-tests.sh
# reported this file as FAILED with no result line at all, twice in a row, and the cause both times
# was an orphan left by a load experiment somebody had killed minutes earlier.
#
# So a run is started, hung on purpose, and killed the way a harness kills one. The fixture is
# asserted to be REAL before the kill: a run that never took the lock, or that had no children to
# leave behind, would satisfy every assertion after it while proving nothing (L159, L98).
_int_lock="$_lockdir/interrupted"
rm -rf "$_int_lock"
_int_log="$WORK/interrupted.log"
# Its own deadline is left long and its stall bound switched off, so the only thing that ends this
# run is the signal below. A run its own watchdog killed would be cleaned up by the watchdog's
# kill_tree and would say nothing about the handler under test.
# All on ONE line, and not wrapped: #34 requires every line that spawns this suite to carry a
# depth, and it asks that of the line the spawn is on. Written over two lines the depth sits on the
# first and the spawn on the second, and the guard reports it, which is the guard being right about
# a per-line rule rather than something to route around (measured: it caught this).
SUITE_LOCK="$_int_lock" SUITE_DEPTH=0 SECTION_UNTIL=push SUITE_HANG_IN=push SUITE_TIMEOUT=300 SUITE_STALL_TIMEOUT=0 bash "$SCRIPT_SELF" > "$_int_log" 2>&1 &
_int_outer=$!
# The run that HOLDS the lock is the one to interrupt, and it names itself in the lock: a filtered
# run re-executes itself, so the process started above is a wrapper and killing it would test the
# wrapper. Read from the lock rather than worked out from the process table (L15).
# Polled in tenths, not in whole seconds (claude-config#206, L290). Every wait in this section is
# on a CONDITION with a deadline behind it, and the condition is normally true within a second: a
# child reaches `push` in 0.8 seconds, measured 2026-08-30. A one second granularity therefore
# rounded each of these three waits up to a whole second for nothing. The deadlines are unchanged
# in seconds, only their resolution moves.
_int_pid=""; _int_kids=""; _int_waited=0
while [ "$_int_waited" -lt 900 ]; do
  _int_pid="$(cat "$_int_lock/pid" 2>/dev/null || true)"
  case "$_int_pid" in ''|*[!0-9]*) _int_pid="" ;; esac
  if [ -n "$_int_pid" ] && grep -q 'hanging deliberately' "$_int_log" 2>/dev/null; then
    _int_kids="$(pgrep -P "$_int_pid" 2>/dev/null | tr '\n' ' ')"
    [ -n "$(printf '%s' "$_int_kids" | tr -d ' ')" ] && break
  fi
  sleep 0.1; _int_waited=$(( _int_waited + 1 ))
done
check "#163 a run was started, took its lock and reached the hang (${_int_waited} tenths)" \
  "[ -n '$_int_pid' ] && [ -f '$_int_lock/pid' ]"
check "#163 and it had children of its own to leave behind" \
  "[ -n \"\$(printf '%s' '$_int_kids' | tr -d ' ')\" ]"

kill -TERM "$_int_pid" 2>/dev/null || true
_int_gone=0
while [ "$_int_gone" -lt 300 ] && kill -0 "$_int_pid" 2>/dev/null; do sleep 0.1; _int_gone=$(( _int_gone + 1 )); done
# And then for the handler's own kills to LAND, which used to be a flat `sleep 1`: a fixed wait for
# something to finish is a bet on how loaded the machine is, and it is both too long when the
# machine is idle and too short when it is not (L290). Waited on instead, with the same ceiling: the
# handler releases the lock and takes its children, so the condition is that both have happened.
# It is not asserted here, only waited for. The checks below are what judge it, and they must be
# able to fail, so this gives up rather than looping until they would pass.
_int_settle=0
while [ "$_int_settle" -lt 300 ]; do
  _int_still=""
  for _int_k in $_int_kids; do kill -0 "$_int_k" 2>/dev/null && _int_still="$_int_still $_int_k"; done
  [ -z "$_int_still" ] && [ ! -e "$_int_lock/pid" ] && break
  sleep 0.1; _int_settle=$(( _int_settle + 1 ))
done
check "#163 the interrupted run itself is gone" "! kill -0 '$_int_pid' 2>/dev/null"
_int_alive=""
for _int_k in $_int_kids; do
  kill -0 "$_int_k" 2>/dev/null && _int_alive="$_int_alive $_int_k"
done
check "#163 and it took the children it started with it" "[ -z '$_int_alive' ]"
# The half that actually cost the investigations: an orphan holding the lock makes every later run
# refuse, and refuse about a run nobody can find.
check "#163 and it released the lock it was holding" "[ ! -e '$_int_lock/pid' ]"
# Whatever survived, cleared here rather than left for the machine: a test that leaks the process
# it was written about is the defect it is testing (L114).
for _int_k in $_int_kids; do kill -9 "$_int_k" 2>/dev/null || true; done
kill -9 "$_int_outer" 2>/dev/null || true
wait "$_int_outer" 2>/dev/null || true

# And the refusal itself, read as the person killing a run actually meets it (#163). A pid on its
# own is not something anybody can act on: it has no visible connection to the run they killed, and
# the message that carried only a pid sent two investigations looking for a bug in the suite. So it
# has to say WHAT is holding the lock and give the command that ends it.
_int_ref="$(_try_lock "$_lockdir/live")"
check "#163 the refusal says a suite run is what holds the lock" \
  "case \"\$_int_ref\" in *'a suite run'*) true ;; *) false ;; esac"
check "#163 and gives a command that would end it" \
  "case \"\$_int_ref\" in *'kill -9'*) true ;; *) false ;; esac"
check "#163 and names the process that command would act on" \
  "line_has \"\$_int_ref\" 'kill -9' '$$'"

section "== a force-killed run's leftovers are cleared by the next one (#166) =="
# needs: only one suite run at a time
# #163 traps the signals a run can be told about, so an interrupted run kills its own children.
# SIGKILL cannot be trapped by anything, so a force-killed run still leaves its re-executed copy
# and its shards going. The lock recovers correctly on its own (the next run finds a recorded
# process that is gone and takes over saying so), but those processes keep running and keep
# competing for the machine, which is the half that makes every timing the next run reports wrong.
#
# So the remedy lives in the run that TAKES OVER rather than in the one that died. That is weaker
# than #163 and it is the only place it can live: nothing runs inside a process that has been
# killed outright. It is after the fact, and the message says so rather than claiming the machine
# is now clean.
#
# What it must NOT do is kill a suite process belonging to something else. This file starts nested
# runs constantly, and a rule of "any suite process that is not mine" would kill the fixtures of
# every check in it. So a run registers its own processes in a file of its own, the lock names that
# file, and a takeover clears exactly what that dead run registered.
#
# The state is CONSTRUCTED here rather than raced for, the same way the planted locks above are: a
# force-killed run leaves a state that is awkward to reach on purpose and trivial to describe, and
# constructing it is what makes each part of the rule checkable on its own.
_or_lock="$_lockdir/orphans"
rm -rf "$_or_lock"
_or_reg="$WORK/orphan-registry"
# One process that still NAMES this suite, which is what a surviving shard looks like, and one that
# does not. Both are real processes of this test's own, so nothing here can reach anything else.
bash -c 'exec -a "bash '"$SCRIPT_SELF"' --orphan-fixture" sleep 600' &
_or_stray=$!
sleep 600 &
_or_bystander=$!
# Given a moment to become what they claim to be: `exec -a` replaces the process, and reading its
# command line before that has happened would test the shell that is about to be replaced.
_or_w=0
while [ "$_or_w" -lt 20 ]; do
  case "$(ps -o command= -p "$_or_stray" 2>/dev/null || true)" in *orphan-fixture*) break ;; esac
  sleep 1; _or_w=$(( _or_w + 1 ))
done
printf '%s\n%s\n' "$_or_stray" "$_or_bystander" > "$_or_reg"
_mklock "$_or_lock" "99999999" "$_thishost" "$((_now - 5))"
printf '%s\n' "$_or_reg" > "$_or_lock/registry"

# The fixture, asserted before anything acts on it. Two processes that are both alive, one of which
# reads as a run of this suite and one of which does not: without that the checks below are
# satisfied by a pair that was never running (L159).
check "#166 the fixture leaves a process that reads as this suite" \
  "kill -0 '$_or_stray' 2>/dev/null && case \"\$(ps -o command= -p '$_or_stray' 2>/dev/null)\" in *orphan-fixture*) true ;; *) false ;; esac"
check "#166 and one that does not"  "kill -0 '$_or_bystander' 2>/dev/null"

_or_take="$(_try_lock "$_or_lock")"; _or_take_rc=$?
sleep 1
check "#166 the next run takes the dead run's lock over" "[ '$_or_take_rc' -eq 0 ]"
check "#166 and says how many processes it cleared" \
  "line_has \"\$_or_take\" 'left running' '[0-9]+'"
check "#166 the leftover that named this suite is gone" "! kill -0 '$_or_stray' 2>/dev/null"
# The check that decides whether the idea is safe at all. A registry is a list of numbers, numbers
# are reused, and a takeover that kills whatever holds one NOW is a takeover that kills somebody's
# unrelated work. The number is confirmed to still be a run of this suite immediately before the
# kill, so a recycled one is left alone (L157, L15).
check "#166 and a number that is no longer this suite is left alone" \
  "kill -0 '$_or_bystander' 2>/dev/null"
# The registry is consumed, or the next run over the same lock reports clearing the same processes
# again and the count stops meaning anything.
check "#166 the dead run's registry is not left behind" "[ ! -f '$_or_reg' ]"

# A leftover it could NOT clear has to be said, not dropped (claude-config#174). The clearing pauses
# a process before killing it and wakes it again if the kill does not take, which is right, but the
# first version of that then skipped it silently: the report said how many it cleared and nothing
# at all about the one still running, so the single case a reader has to act on was the one case it
# went quiet on (L11, L98). Written while fixing a different silent failure three lines above.
#
# Driven through a seam rather than by finding a process this suite genuinely cannot kill, because
# there is no such process here and arranging one would be a fixture about permissions rather than
# about the report.
_or2_lock="$_lockdir/orphans-unkillable"
rm -rf "$_or2_lock"
_or2_reg="$WORK/orphan-registry-2"
bash -c 'exec -a "bash '"$SCRIPT_SELF"' --orphan-fixture-2" sleep 600' &
_or2_stray=$!
_or2_w=0
while [ "$_or2_w" -lt 20 ]; do
  case "$(ps -o command= -p "$_or2_stray" 2>/dev/null || true)" in *orphan-fixture-2*) break ;; esac
  sleep 1; _or2_w=$(( _or2_w + 1 ))
done
printf '%s
' "$_or2_stray" > "$_or2_reg"
_mklock "$_or2_lock" "99999997" "$_thishost" "$((_now - 5))"
printf '%s
' "$_or2_reg" > "$_or2_lock/registry"
check "#174 the unkillable fixture is running before anything acts on it" \
  "kill -0 '$_or2_stray' 2>/dev/null"
_or2_out="$(SUITE_CLEAR_KILL_FAILS=1 _try_lock "$_or2_lock")"
sleep 1
check "#174 a leftover that could not be killed is named, not dropped" \
  "line_has \"\$_or2_out\" 'could not' '$_or2_stray'"
check "#174 and it is left RUNNING rather than frozen where nobody finds it" \
  "kill -0 '$_or2_stray' 2>/dev/null && case \"\$(ps -o stat= -p '$_or2_stray' 2>/dev/null)\" in *T*) false ;; *) true ;; esac"
check "#174 and the count does not include it" \
  "! case \"\$_or2_out\" in *'cleared 1 process'*) true ;; *) false ;; esac"
kill -9 "$_or2_stray" 2>/dev/null || true

# And a takeover with NOTHING left to clear must not claim it cleared something, which is the same
# distinction the reaper draws between finding nothing and being switched off (L98, L11).
rm -rf "$_or_lock"
_mklock "$_or_lock" "99999998" "$_thishost" "$((_now - 5))"
_or_empty="$(_try_lock "$_or_lock")"
check "#166 a takeover with nothing to clear says nothing about clearing" \
  "! case \"\$_or_empty\" in *'left running'*) true ;; *) false ;; esac"
check "#166 and still reports the takeover itself" \
  "case \"\$_or_empty\" in *'took over a lock'*) true ;; *) false ;; esac"

# What goes IN the registry, and what deliberately does not (claude-config#170). Every run used to
# append itself, and this file starts hundreds of nested runs in a full pass, so the registry ended
# up holding several hundred numbers of processes that had finished long ago and a takeover asked
# the system about each one. What has to be listed is only what survives the top-level being killed
# outright and carries on independently, which is the shards; everything else is reached by walking
# the tree from one of those.
#
# Asked of a real run rather than by reading the code, and both ways round, because "it did not
# register" is also what a run that never started looks like (L159).
_rg_file="$WORK/registry-probe"
: > "$_rg_file"
SUITE_RUN_REGISTRY="$_rg_file" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SUITE_NO_LOCK=1 SECTION_ONLY=push bash "$SCRIPT_SELF" >/dev/null 2>&1
# `grep -c` prints 0 AND exits 1 when it counts nothing, so `|| echo 0` runs as well and the value
# becomes two lines. Every numeric test on it then fails while reading as if it had a number.
_rg_nested="$(grep -c . "$_rg_file" 2>/dev/null || true)"
case "$_rg_nested" in ''|*[!0-9]*) _rg_nested=0 ;; esac
: > "$_rg_file"
# One shard of ninety-nine, so it carries about one section: this is asking whether a shard
# REGISTERS, not what a shard costs, and a shard of one is the whole suite.
SUITE_RUN_REGISTRY="$_rg_file" SUITE_SHARD="1/99" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SUITE_NO_LOCK=1 bash "$SCRIPT_SELF" >/dev/null 2>&1
_rg_shard="$(grep -c . "$_rg_file" 2>/dev/null || true)"
case "$_rg_shard" in ''|*[!0-9]*) _rg_shard=0 ;; esac
check "#170 a shard registers itself, because it outlives a killed parent ($_rg_shard)" \
  "[ '${_rg_shard:-0}' -ge 1 ]"
check "#170 and a nested run does not, because it is reached through one ($_rg_nested)" \
  "[ '${_rg_nested:-0}' -eq 0 ]"

kill -9 "$_or_bystander" 2>/dev/null || true
kill -9 "$_or_stray" 2>/dev/null || true

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
check "#33 several watchers are reported"        "printf '%s' \"\$_ps_many\" | grep -qi 'watcher processes the tool left running'"
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
check "#33 and it says how deeply they are nested" "printf '%s' \"\$_ps_chain\" | grep -qE 'nested [0-9]+ deep inside another'"

# The control (L143): an EMPTY listing must report nothing even though this machine really does
# have a watcher running right now. If the seam were ignored, this check would fail against the
# live process table, which is the only thing that can tell a working stub from one that missed.
: > "$WORK/ps-none"
_ps_none="$(_status_with "$WORK/ps-none")"
check "#33 nothing running is reported as nothing" \
  "! printf '%s' \"\$_ps_none\" | grep -qi 'left running\|watcher\|test run'"

section "== a sync works where git has no identity of its own (#52) =="
# The tool passes its own name and address to the two commits it makes, so it does not depend on
# whoever's machine it is running on. It then left the rebase inside `pull --rebase` to find one
# ambiently, and a rebase writes commits too.
#
# No Mac can show this. Git on a Mac quietly invents user@hostname when nothing is configured, so
# the pull succeeds and the gap is invisible. A machine where git refuses to guess fails instead,
# and the failure is reported as "both Macs changed the same config", which is not what happened,
# names an innocent cause, and tells the person to reconcile a conflict that does not exist. It
# took six runs on a Linux runner to find, and it was the root of nine failing checks there.
#
# `user.useConfigOnly` is what makes it reproducible HERE: it tells git to refuse to invent an
# identity rather than deriving one from the machine, which is exactly the state the runner is in.
_NOID="$WORK/noid"; mkdir -p "$_NOID"
git init -q --bare "$_NOID/bare.git"
git clone -q "$_NOID/bare.git" "$_NOID/repo" 2>/dev/null
git -C "$_NOID/repo" checkout -q -b main 2>/dev/null || true
mkdir -p "$_NOID/repo/payload/hooks" "$_NOID/home/hooks"
echo '{"hooks":{}}' > "$_NOID/home/settings.json"
echo 'seed' > "$_NOID/repo/payload/hooks/seed.sh"
git -C "$_NOID/repo" add -A
git -C "$_NOID/repo" -c user.name=t -c user.email=t@e commit -q -m seed
git -C "$_NOID/repo" push -q -u origin main
# The other Mac moves the shared branch on, and this one has a commit of its own that is not there
# yet. That DIVERGENCE is the whole fixture: a pull with nothing to replay writes no commit and so
# needs no identity, which is why the first version of this section passed against the defect.
# -b main, or the clone comes up on the bare repo's default branch, which is not the one
# that was pushed: it checks out nothing, the write below fails, and the remote never moves.
git clone -q -b main "$_NOID/bare.git" "$_NOID/other" 2>/dev/null
echo 'from the other Mac' > "$_NOID/other/payload/hooks/theirs.sh"
git -C "$_NOID/other" add -A
git -C "$_NOID/other" -c user.name=o -c user.email=o@e commit -q -m theirs
git -C "$_NOID/other" push -q origin HEAD:main
echo 'from this Mac' > "$_NOID/repo/payload/hooks/ours.sh"
git -C "$_NOID/repo" add -A
git -C "$_NOID/repo" -c user.name=t -c user.email=t@e commit -q -m ours
# Now take the identity away, and forbid git from making one up.
git -C "$_NOID/repo" config user.useConfigOnly true
git -C "$_NOID/repo" config --unset user.name 2>/dev/null || true
git -C "$_NOID/repo" config --unset user.email 2>/dev/null || true
# The global config has to be taken out of view as well, not just the repo's own: unsetting the
# local name and address leaves git falling straight back to the one in the person's ~/.gitconfig,
# and useConfigOnly only stops git INVENTING one, it does not hide a real one. Without this the
# fixture looked correct and denied nothing.
_noid_env=(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null)
# Two controls, because each covers a different way this can assert nothing (L159). The first: git
# really does refuse an identity here.
_noid_probe="$("${_noid_env[@]}" git -C "$_NOID/repo" commit --allow-empty -m probe 2>&1 || true)"
check "#52 the fixture really does deny git an identity" \
  "printf '%s' \"\$_noid_probe\" | grep -qi 'Author identity unknown'"
# The second: there really is something for the pull to replay. With nothing to rebase, no commit
# is written, no identity is needed, and every check below passes against the defect untouched.
# BOTH directions. Ahead alone is not enough: with the remote unmoved the pull fast-forwards
# nothing, replays nothing, writes no commit and needs no identity, which is exactly how the first
# two versions of this fixture passed against the defect untouched.
git -C "$_NOID/repo" fetch -q origin main 2>/dev/null || true
_noid_ahead="$(git -C "$_NOID/repo" rev-list --count origin/main..HEAD 2>/dev/null || echo 0)"
_noid_behind="$(git -C "$_NOID/repo" rev-list --count HEAD..origin/main 2>/dev/null || echo 0)"
check "#52 and the two sides really have diverged" \
  "[ \"\${_noid_ahead:-0}\" -ge 1 ] && [ \"\${_noid_behind:-0}\" -ge 1 ]"

echo 'local edit' > "$_NOID/home/hooks/mine.sh"
_noid_out="$("${_noid_env[@]}" SYNC_NO_NOTIFY=1 SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$_NOID/home" SYNC_REPO="$_NOID/repo" bash "$SCRIPT" sync 2>&1)"; _noid_rc=$?
dbg "sync with no git identity exited $_noid_rc: $_noid_out"
check "#52 a sync completes where git has no identity"  "[ '$_noid_rc' -eq 0 ]"
# The half that names the damage. A wrong cause here sends the person to reconcile a conflict that
# does not exist, and there is no edit they can make that will clear it.
check "#52 and it is not blamed on a two-Mac conflict" \
  "! printf '%s' \"\$_noid_out\" | grep -q 'both Macs changed the same config'"
check "#52 and the local edit really was published" "[ -f '$_NOID/repo/payload/hooks/mine.sh' ]"

section "== nothing depends on a tool only BSD has (#38) =="
# The suite runs on every push now, on a Linux runner, so anything spelled the BSD way stops the
# whole gate rather than failing one check. The awkward part is that a wrong answer here does not
# look like an error: `stat -f %m FILE` on GNU means "file system status" and prints a multi-line
# block about the filesystem, so a naive fallback concatenates that block with the real number and
# every age comparison downstream then reads it as garbage.
_PORTABLE_HELPERS="$WORK/helpers.sh"
{ echo 'file_mtime(){ :; }'; sed -n '/^file_mtime(){/,/^}/p;/^date_from_epoch(){/,/^}/p' "$SCRIPT"; } > "$_PORTABLE_HELPERS"
# shellcheck disable=SC1090
. "$_PORTABLE_HELPERS"
echo 'x' > "$WORK/mtime-probe"
_pm="$(file_mtime "$WORK/mtime-probe")"
check "#38 the mtime helper returns a bare timestamp" "printf '%s' \"\$_pm\" | grep -qE '^[0-9]+$'"
# The claim that matters is not "it returns a number" but "it returns the RIGHT number", measured
# against the suite's own independent reader rather than against itself (L70).
check "#38 and it agrees with the suite's own reader" "[ \"\$_pm\" = \"\$(_suite_mtime '$WORK/mtime-probe')\" ]"
# Unreadable must be EMPTY, not a zero and not an error blob: every caller treats empty as "no
# evidence", and a 0 would read as 1970, which is old enough to trip every age threshold there is.
_pmiss="$(file_mtime "$WORK/no-such-file-at-all")"
check "#38 an unreadable path yields nothing at all" "[ -z \"\$_pmiss\" ]"
_pdate="$(date_from_epoch 1000000000 '+%Y-%m-%d')"
check "#38 the date helper formats a timestamp" "[ '$_pdate' = '2001-09-08' ] || [ '$_pdate' = '2001-09-09' ]"
_pdbad="$(date_from_epoch '' '+%Y-%m-%d')"
check "#38 and yields nothing for a timestamp it cannot read" "[ -z \"\$_pdbad\" ]"

# The GNU half of both helpers is the half this Mac never runs, so on a Mac it is unproven code
# that the runner is about to depend on entirely. Driven here through stand-ins that behave the way
# the GNU tools do, so the fallback is watched WORKING rather than assumed (L143: a fallback nothing
# exercises is indistinguishable from one that is broken).
_GNUBIN="$WORK/gnu-bin"; mkdir -p "$_GNUBIN"
cat > "$_GNUBIN/stat" <<'GNUSTAT'
#!/usr/bin/env bash
# GNU stat: -f means --file-system and prints a block about the filesystem, and the mtime format
# lives behind -c. This is the shape that makes a naive `||` fallback concatenate the two.
if [ "${1:-}" = "-f" ]; then shift; echo "  File: \"${*}\""; echo "    ID: 9a1f2b Namelen: 255  Type: apfs"; exit 1; fi
if [ "${1:-}" = "-c" ]; then fmt="${2:-}"; shift 2; [ "$fmt" = "%Y" ] || exit 1; exec perl -e 'print ((stat($ARGV[0]))[9], "\n")' "$1"; fi
exit 1
GNUSTAT
cat > "$_GNUBIN/date" <<'GNUDATE'
#!/usr/bin/env bash
# GNU date: -r takes a FILE, so a timestamp is not found; -d @N is the way to format an epoch.
if [ "${1:-}" = "-r" ]; then echo "date: cannot stat '${2:-}': No such file or directory" >&2; exit 1; fi
if [ "${1:-}" = "-d" ]; then
  spec="${2:-}"; fmt="${3:-+%Y-%m-%d}"
  case "$spec" in @*) exec perl -e 'use POSIX qw(strftime); my $f=$ARGV[1]; $f =~ s/^\+//; print strftime($f, localtime($ARGV[0])), "\n"' "${spec#@}" "$fmt" ;; esac
  exit 1
fi
exit 1
GNUDATE
chmod +x "$_GNUBIN/stat" "$_GNUBIN/date"
_gnu_mtime="$(PATH="$_GNUBIN:$PATH" bash -c ". '$_PORTABLE_HELPERS'; file_mtime '$WORK/mtime-probe'")"
check "#38 the mtime helper still answers with GNU-shaped tools" \
  "printf '%s' \"\$_gnu_mtime\" | grep -qE '^[0-9]+$'"
# The specific trap: the filesystem block must not be carried along with the number.
check "#38 and does not carry the filesystem block with it" \
  "[ \"\$_gnu_mtime\" = \"\$(_suite_mtime '$WORK/mtime-probe')\" ]"
check "#38 and the stand-in really was used" \
  "PATH='$_GNUBIN:'\$PATH command -v stat | grep -q gnu-bin"
_gnu_date="$(PATH="$_GNUBIN:$PATH" bash -c ". '$_PORTABLE_HELPERS'; date_from_epoch 1000000000 '+%Y-%m-%d'")"
check "#38 the date helper still answers with GNU-shaped tools" \
  "[ '$_gnu_date' = '2001-09-08' ] || [ '$_gnu_date' = '2001-09-09' ]"

# TMPDIR is always set on a Mac and is NOT set on a Linux runner, so anything reading it without a
# default is a landmine no Mac can step on. The suite died on exactly this the first time it ran on
# the runner, before a single check executed.
#
# Worth stating plainly, because it decides how much these two checks are worth: they CANNOT fail on
# a Mac. macOS ships bash 3.2, which expands `${TMPDIR%/}` to empty when TMPDIR is unset, while the
# bash on the runner treats it as an unbound variable and exits. So this pair is green here for a
# reason unrelated to the code (L159) and does its real work only in CI, which is the argument for
# having CI rather than an argument against the checks. A static sweep for the whole class, every
# environment variable expanded with an operator and no default, found this as the only instance.
_noTMPDIR="$(env -u TMPDIR SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL=push bash "$SCRIPT_SELF" 2>&1 || true)"
# The positive control first: without it, a child that died for some entirely different reason
# would satisfy the assertion below by never getting far enough to say "unbound variable" (L159).
check "#38 the suite runs with no TMPDIR set at all" "printf '%s' \"\$_noTMPDIR\" | grep -q '^PASS='"
check "#38 and names no unbound variable"            "! printf '%s' \"\$_noTMPDIR\" | grep -q 'unbound variable'"
# The tool itself too, and separately, because it is the half that runs unattended on both Macs.
_noTMPDIRtool="$(env -u TMPDIR SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" bash "$SCRIPT" status 2>&1 || true)"; _noTMPDIRrc=$?
check "#38 the tool runs with no TMPDIR set either"  "[ '$_noTMPDIRrc' -eq 0 ]"
check "#38 and it names no unbound variable"         "! printf '%s' \"\$_noTMPDIRtool\" | grep -q 'unbound variable'"

# Derived, so the port cannot quietly rot: one new `stat -f` anywhere outside the helper breaks
# every run on the runner, and the helper is the only place allowed to spell it that way. Comments
# are stripped first, or the paragraph above explaining the problem counts as an instance of it
# (L103). The helper bodies are excluded by name rather than by line number.
# The patterns are BUILT from pieces, so this file never contains the literals it searches for. A
# guard satisfied by its own assertion line reports the codebase as broken for ever and teaches
# everyone to ignore it, which is the same trap #34's spawn-site check had to be written around.
_bsdisms(){
  local a b c d e x
  a="stat"" -f"; b="date"" -r "; c="sed"" -i ''"; d="date"" -v"; e="mktemp"" -t"
  # A BSD spelling that carries its GNU fallback on the SAME joined line is portable, so it is
  # excluded by that SHAPE rather than by naming the helper it happens to sit in: written as a
  # name, the next such helper is unguarded and nobody notices (L362).
  #
  # ASSEMBLED from $d, never written out. Spelled literally, this line would itself hold the
  # banned token and the guard would report itself for ever, which is the guard working correctly
  # and is why every other pattern here is assembled too.
  x="$d"'.*\|\| *date -d'
  # Continuation lines are joined first, or a spelling whose GNU fallback sits on the NEXT line
  # reads as unguarded and this reports two false findings for ever, which is how a guard stops
  # being read (L36).
  sed 's/#.*//' "$SCRIPT" "$SCRIPT_SELF" \
    | sed -e :a -e '/\\$/N; s/\\\n//; ta' \
    | grep -nF -e "$a" -e "$b" -e "$c" -e "$d" -e "$e" \
    | grep -vF "$a %m \"\$1\"" | grep -vF "$b\"\$1\"" \
    | grep -vF "$a \"%m%t%N\"" \
    | grep -vE '\|\| +touch -d' \
    | grep -vE "$x" || true
}
check "#38 no BSD-only spelling survives outside the helpers that own them" "[ -z \"\$(_bsdisms)\" ]"
# And the helpers really are there to be excluded, or the check above passes by matching nothing
# at all in a file that has been emptied or renamed. file_mtimes is the batch form of file_mtime
# and holds the only other BSD spelling excluded above (claude-config#191); without this line that
# exclusion could outlive the helper it was written for and quietly cover a spelling anywhere.
check "#38 the portable helpers exist" \
  "grep -q '^file_mtime(){' '$SCRIPT' && grep -q '^file_mtimes(){' '$SCRIPT' && grep -q '^date_from_epoch(){' '$SCRIPT' && grep -q '^_suite_mtime(){' '$SCRIPT_SELF'"

section "== the design record's numbers still match the code (#41) =="
# DESIGN.md records every threshold as a MEASURED value with the reasoning behind it, and all of
# them are also defaults in the code. Nothing kept the two in step. The document's whole value is
# that its numbers are measured rather than guessed, so a limit changed in code and not in the
# prose leaves it confidently defending a number that is no longer true (L32), and they agreed on
# the day they were written, which is the only day anybody would ever check by hand.
#
# DERIVED from the code, in the code-to-document direction, so it catches both halves: a number
# that CHANGES, and a threshold that is ADDED and never written down. A list maintained by hand
# beside the thing it mirrors only ever covers what somebody remembered (L41, L96).
_DESIGN="$(dirname "$SCRIPT")/DESIGN.md"
_README="$(dirname "$SCRIPT")/README.md"
check "#41 the design record has a measured-numbers table" "grep -qi 'Measured numbers' '$_DESIGN'"

# Every row must CITE the check that proves its justification, and that citation must resolve to a
# real section. The comparison below covers the NUMBER; nothing covered the sentence beside it, and
# a page carrying a passing freshness check is read as verified in full, so the unchecked half is
# where the claim that matters lives (claude-config#112, L210). Measured: the depth row asserted the
# suite "runs itself as a subprocess in one place" while nineteen places did.
_rows="$(awk '/^\| Number \| Set by/{t=1; next} t && /^\| *--- /{next} t && /^\|/{print} t && !/^\|/{exit}' "$_DESIGN")"
check "#41 the measured-numbers table has rows to check" \
  "[ \"\$(printf '%s' \"\$_rows\" | grep -c .)\" -ge 5 ]"
_uncited=""; _badcite=""
# The section headings are read ONCE, into a variable, and matched with `case`. Written as
# `grep '^section "' "$SCRIPT_SELF" | grep -qF -- "($_cite)"` this was a pipeline whose consumer
# short circuits: `grep -q` exits on the first match, the producer is killed by SIGPIPE, and under
# `pipefail` the pipeline's status becomes that death. So a citation that WAS found could be
# recorded as missing, depending on nothing more than whether the producer had finished writing
# before the consumer left (L183). It behaved on this Mac and failed on the Linux runner, and it
# started failing there when this file grew by a few lines, which is how latent that was.
_sections="$(grep '^section "' "$SCRIPT_SELF")"
# A section can legitimately prove more than one row: #160's checks belong beside the sweep #36
# already owns, and demanding a heading of exactly "(#160)" would force either a duplicate section
# or a row citing a heading that does not hold its proof. So the citation is looked for INSIDE the
# heading's parenthesised list, and the closing delimiter is part of every pattern, or "#16" would
# be answered by a section named "(#160)".
#
# One definition of the question, taking the headings as an argument, so the probes below exercise
# this matcher rather than a second one written beside it that drifts (L107).
_cite_found(){   # $1 = a citation like "#160"   $2 = the section headings to look in
  case "$2" in
    *"($1)"*|*"($1,"*|*", $1)"*|*", $1,"*) return 0 ;;
  esac
  return 1
}
while IFS= read -r _row; do
  [ -n "$_row" ] || continue
  _cite="$(printf '%s' "$_row" | grep -oE 'proved by #[0-9]+' | head -1 | sed 's/.*#/#/')"
  if [ -z "$_cite" ]; then
    _uncited="$_uncited[$(printf '%s' "$_row" | cut -d'|' -f2 | sed 's/^ *//; s/ *$//')]"
    continue
  fi
  _cite_found "$_cite" "$_sections" || _badcite="$_badcite[$_cite]"
done <<DESIGNROWS
$_rows
DESIGNROWS
check "#41 every documented number cites the check that proves its justification" "[ -z \"\$_uncited\" ]"
# The failure NAMES the citation it could not find, and how many section headings it read looking
# for it. Asserted as a bare emptiness test, this said only that something was wrong, which is
# useless on a machine you cannot re-run by hand and is exactly where this one first failed
# (L11, claude-config#101).
_sec_seen="$(printf '%s\n' "$_sections" | grep -c . || true)"
check "#41 and every citation names a section that exists" \
  "[ -z \"\$_badcite\" ] || { echo \"    citations with no matching section: \$_badcite (read \$_sec_seen section headings in \$SCRIPT_SELF)\" >&2; false; }"
# Both halves of that need to be seen working, or an empty answer is the scan reading nothing rather
# than the table being right (L98, L1).
_cite_probe="$(printf '%s' '| 1 thing | `X=1` | y | because, proved by #99999 | 2026-01-01 |' | grep -oE 'proved by #[0-9]+' | sed 's/.*#/#/')"
check "#41 the citation scan finds a citation when there is one" "[ '$_cite_probe' = '#99999' ]"
check "#41 and a citation naming no section would be caught" \
  "! _cite_found '#99999' \"\$_sections\""
# The matcher itself, against headings built here, because the tree is allowed to stop containing
# a shared heading and this must go on being the thing that decides (L48).
# ASSEMBLED, never written whole, the same trick #34's spawn pattern needs. Spelt out, each probe
# line begins with the word this file uses to declare a heading, and two separate guards read them
# as headings of this file: the section extractor stops being able to parse a filtered run, and
# #138 counts two headings written that its reader cannot see. Both of those are those guards
# working correctly (measured: each caught this in turn), and the answer is to leave no literal for
# them to find. The shape is otherwise exactly what the real listing produces, which is what the
# matcher is being asked about.
_sec_word="sec""tion"
_cite_probes="$(printf '%s "== one issue (#41) =="\n%s "== two issues (#36, #160) =="\n' "$_sec_word" "$_sec_word")"
check "#41 the matcher finds a citation a heading names alone" "_cite_found '#41' \"\$_cite_probes\""
check "#41 and one a heading shares, in either position" \
  "_cite_found '#36' \"\$_cite_probes\" && _cite_found '#160' \"\$_cite_probes\""
# The delimiter is what stops a shorter number being answered by a longer one, so it is asserted
# rather than assumed: without the closing bracket and comma in every pattern, "#16" is found in a
# heading about #160 and the row reads as proved by a section that says nothing about it (L178).
check "#41 and does not answer a shorter number with a longer one" \
  "! _cite_found '#16' \"\$_cite_probes\" && ! _cite_found '#4' \"\$_cite_probes\""
check "#41 the heading scan really read the headings" "[ \"\$_sec_seen\" -ge 40 ]"
# Every default of the shape a threshold has, from BOTH files, as "NAME VALUE" pairs. Comments are
# stripped first, or prose quoting a number satisfies the check that the number is current, and a
# guard that is green on its own explanation is indistinguishable from one that works (L103).
# POLL_INTERVAL is in the list since #206. Both poll intervals are thresholds in every sense that
# matters here: each is a default in the code that this table describes, and each was a hard coded
# constant before it was a setting, which is the state the table exists to end. The value may now
# carry a decimal point, because one of them is a tenth of a second and an integer only pattern
# would have skipped it silently rather than reporting it as undocumented (L98).
#
# POLL_INTERVAL and not INTERVAL, and the reason is written here rather than left to be inferred
# (L233). Widening to INTERVAL also catches SYNC_INTERVAL, the receive timer's period, which is a
# product decision about how often to sync and not a multiple of anything anybody measured. Every
# row in this table states what its number is derived FROM, so a row for that one would have to
# invent a derivation. It is tracked separately as its own README accuracy question rather than
# being quietly exempt.
_thresholds(){
  sed 's/#.*//' "$SCRIPT" "$SCRIPT_SELF" \
    | grep -ohE '\$\{(SYNC|SUITE)_[A-Z_]*(MAX_AGE|TIMEOUT|MAX_DEPTH|RETIRE_AFTER|POLL_INTERVAL)[A-Z_]*:-[0-9]+(\.[0-9]+)?\}' \
    | sed 's/^\${//; s/}$//; s/:-/ /' | sort -u
}
_undocumented=""
_disagreeing=""
while IFS=' ' read -r _tn _tv; do
  [ -n "$_tn" ] || continue
  if ! grep -qF -- "$_tn" "$_DESIGN"; then _undocumented="$_undocumented[$_tn]"; continue; fi
  # Named AND agreeing. A row naming the variable while carrying a stale number is the exact
  # failure this exists to catch, so being mentioned at all is not enough.
  grep -qF -- "$_tn=$_tv" "$_DESIGN" || _disagreeing="$_disagreeing[$_tn is $_tv in the code]"
done <<EOF
$(_thresholds)
EOF
check "#41 every threshold in the code has a row in the design record" "[ -z \"\$_undocumented\" ]"
check "#41 and every row carries the number the code actually uses"    "[ -z \"\$_disagreeing\" ]"

# The README publishes several of these numbers too, in its own settings tables, and drifts for
# exactly the same reason. It is not held to documenting ALL of them, because two are internal and
# have no business in a usage guide; it is held to being right about the ones it does mention.
# The number has to appear on a line that NAMES the threshold, not merely somewhere in the file, so
# an unrelated 900 elsewhere cannot answer for the deadline (L135). Any such line will do, so a
# sentence mentioning a setting without repeating its value is fine as long as some row states it.
# WHICH HALF failed, not just that it did (claude-config#270). The single message
# "[<NAME> is <value> in the code]" reads as "the documented number is stale", and that is only
# one of the two ways this fires. On 2026-09-02 the number was correct and the setting name and
# its value had simply WRAPPED onto different lines, so the single-line grep found no line
# carrying both. The message sent the reader to check a number that was already right, and this
# pin fires on a documentation edit, which is the moment an author is least likely to read past
# the first sentence (L11, and the same family as #253).
#
# One definition, taking the file's text as an argument, so the probes below exercise the verdict
# the real loop uses rather than a second copy of it (L107).
_readme_verdict(){   # $1 = name  $2 = value  $3 = the prose -> prints a verdict word
  # Matched in the shell rather than through `| grep -q`, which is a short circuiting consumer:
  # under pipefail it kills its producer and the pipeline reports a failure that never happened,
  # depending on nothing but whether the producer had finished writing (L183).
  local rows re='(^|[^0-9])'"$2"'([^0-9]|$)'
  rows="$(printf '%s\n' "$3" | grep -F -- "$1" || true)"
  [ -n "$rows" ] || { printf 'unnamed'; return 0; }
  if [[ "$rows" =~ $re ]]; then printf 'agrees'; return 0; fi
  # The name is here and the value is here, just not together. That is a WRAP, and saying "the
  # number is stale" about it is a wrong diagnosis rather than a vague one.
  if [[ "$3" =~ $re ]]; then printf 'split'; return 0; fi
  printf 'stale'
}
# Watched giving each of its four answers before it is believed, against prose built here, because
# a verdict that has only ever been seen to say "agrees" is not yet a check (L1, L151: every
# outcome the contract enumerates gets a test that PRODUCES it).
_vp_name="SYNC""_PROBE_TIMEOUT"
check "#270 a threshold the README never names is reported as unnamed" \
  "[ \"\$(_readme_verdict '$_vp_name' 600 'nothing about it here')\" = unnamed ]"
check "#270 a line carrying both is reported as agreeing" \
  "[ \"\$(_readme_verdict '$_vp_name' 600 \"\`printf '%s=600 seconds' '$_vp_name'\`\")\" = agrees ]"
check "#270 a name and a value on DIFFERENT lines is reported as split, not stale" \
  "[ \"\$(_readme_verdict '$_vp_name' 600 \"\`printf '%s\\nis 600 seconds' '$_vp_name'\`\")\" = split ]"
check "#270 and a genuinely different number is still reported as stale" \
  "[ \"\$(_readme_verdict '$_vp_name' 600 \"\`printf '%s=900 seconds' '$_vp_name'\`\")\" = stale ]"

_readme_wrong=""
_readme_seen=0
_readme_prose="$(cat "$_README")"
while IFS=' ' read -r _tn _tv; do
  [ -n "$_tn" ] || continue
  case "$(_readme_verdict "$_tn" "$_tv" "$_readme_prose")" in
    unnamed) continue ;;
    agrees)  _readme_seen=$((_readme_seen + 1)) ;;
    split)   _readme_seen=$((_readme_seen + 1))
             _readme_wrong="$_readme_wrong[$_tn: the README carries $_tv and names $_tn, but on DIFFERENT lines. The number is right; this pin reads one line at a time, so put the value on the line that names the setting]" ;;
    stale)   _readme_seen=$((_readme_seen + 1))
             _readme_wrong="$_readme_wrong[$_tn: the README names it but no line carries $_tv, and $_tv appears nowhere in the file. The code uses $_tv]" ;;
  esac
done <<EOF
$(_thresholds)
EOF
check "#41 the README agrees about every threshold it names" "[ -z \"\$_readme_wrong\" ]"
check "#41 and it really did name some of them" "[ \"\$_readme_seen\" -ge 3 ]"
# Or both loops above compare nothing against nothing and pass while the table is entirely wrong,
# which is the state #30 had to be rescued from.
check "#41 the derivation found the thresholds to check" \
  "[ \"\$(_thresholds | grep -c .)\" -ge 6 ]"

section "== scratch a killed run left behind is reclaimed, and nothing else is (#36, #160) =="
# A run that is force-killed never reaches its cleanup, so its scratch directory is abandoned and
# nothing ever reclaimed one. 37 of them were measured on this Mac on 2026-08-17 holding 475 MB,
# from one day of interrupted runs, alongside 92 abandoned apply logs.
#
# The whole risk of the fix is on the other side: the same temp directory held 542 anonymous
# `tmp.*` directories belonging to OTHER tools that day, so a sweep written as "old directories in
# the temp folder" would have deleted them. Every fixture below therefore points at a THROWAWAY
# root (L2), and the checks that matter most are the ones asserting what SURVIVES.
_SCR="$WORK/scratch-root"; mkdir -p "$_SCR"
_scr_age(){ scratch_age_out "$1"; }
_scr_dir(){    # name mb
  mkdir -p "$_SCR/$1"
  dd if=/dev/zero of="$_SCR/$1/filler" bs=1048576 count="$2" 2>/dev/null
}
_reap(){ SYNC_SCRATCH_ROOT="$_SCR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1; }
# Every fixture in this section is planted in the FLAT root, which is where every earlier version
# wrote and where the sweep's rules (age, name, the lock, other tools' files) have to keep holding.
# That location is read on an interval now rather than on every call (#116), so these calls ask for
# it every time; the interval itself, and the directory scratch actually lives in today, have their
# own section below. `reap-scratch` reads it unconditionally, so only `status` needs saying.
_scr_status(){ SYNC_SCRATCH_LEGACY_EVERY=0 SYNC_SCRATCH_ROOT="$_SCR" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1; }

# The control first, and before anything is planted: an empty root must report NOTHING. Without
# it, every assertion below could be satisfied by a reaper that reports on the real temp directory
# rather than the one it was pointed at, which is a stub that matched nothing (L143).
_scr_empty="$(_scr_status)"
check "#36 an empty root reports no leftover scratch" \
  "! printf '%s' \"\$_scr_empty\" | grep -qi 'scratch the tool left behind'"
_scr_empty_reap="$(_reap)"
check "#36 and reaping it says plainly that it found nothing" \
  "printf '%s' \"\$_scr_empty_reap\" | grep -qi 'no abandoned scratch'"

_scr_dir "claude-sync-suite-work.OLDAAAA" 3     # a killed suite run
_scr_age "$_SCR/claude-sync-suite-work.OLDAAAA"
echo 'applied log' > "$_SCR/claude-sync-applied.OLDBBBB"   # a killed apply
_scr_age "$_SCR/claude-sync-applied.OLDBBBB"
_scr_dir "claude-sync-suite-work.NEWCCCC" 1     # a run that is still going
mkdir -p "$_SCR/claude-sync-suite.lock"; echo "$$" > "$_SCR/claude-sync-suite.lock/pid"
_scr_age "$_SCR/claude-sync-suite.lock"
_scr_dir "tmp.SOMEONEELSE" 2                    # another tool's scratch, the measured hazard
_scr_age "$_SCR/tmp.SOMEONEELSE"

_scr_rep="$(_scr_status)"
check "#36 status reports abandoned scratch"     "printf '%s' \"\$_scr_rep\" | grep -qi 'scratch the tool left behind'"
check "#36 and says how many there are"          "printf '%s' \"\$_scr_rep\" | grep -q '2 abandoned'"
# The size, not just the count: the count is what grows and the size is what actually hurts, and
# 2 items could be 2 KB or 2 GB.
check "#36 and how much space they hold"         "printf '%s' \"\$_scr_rep\" | grep -qE '[0-9]+ MB'"
check "#36 and names the command that reclaims them" "printf '%s' \"\$_scr_rep\" | grep -q 'reap-scratch'"

_scr_out="$(_reap)"
check "#36 the reaper says how many it reclaimed" "printf '%s' \"\$_scr_out\" | grep -q 'reclaimed 2'"
check "#36 and how much space it got back"        "printf '%s' \"\$_scr_out\" | grep -qE '[0-9]+ MB'"
# The scan reads the temp directory once per NAME, and on a real Mac that directory holds six
# figures of entries: measured 113,000 here on 2026-08-21, six passes, 1.28 seconds of every
# single `status` call
# (claude-config#115). Collapsing that to one pass is only safe if it still finds a name that does
# NOT share the others' prefix, because the obvious optimisation is to glob a hard-coded common
# prefix and that silently stops reporting anything outside it. A leftover nobody reports is a
# leftover nobody reclaims, and the whole feature is about noticing them (L96).
_SCRP="$WORK/scratch-prefix"; mkdir -p "$_SCRP"
: > "$_SCRP/claude-sync-work.SHAREDAA"
: > "$_SCRP/totally-different-name.ODDONEA"
touch -t 202001010000 "$_SCRP/claude-sync-work.SHAREDAA" "$_SCRP/totally-different-name.ODDONEA"
_scr_odd="$(SYNC_SCRATCH_NAMES='claude-sync-work. totally-different-name.' SYNC_SCRATCH_LEGACY_EVERY=0 SYNC_SCRATCH_ROOT="$_SCRP" SYNC_SCRATCH_MAX_AGE=60 CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#115 a scratch name sharing the common prefix is reported" \
  "printf '%s' \"\$_scr_odd\" | grep -q '2 abandoned'"
check "#115 the control: both fixtures were old enough to count" \
  "[ -e '$_SCRP/totally-different-name.ODDONEA' ] && [ -e '$_SCRP/claude-sync-work.SHAREDAA' ]"

check "#36 an abandoned suite directory is gone"  "[ ! -e '$_SCR/claude-sync-suite-work.OLDAAAA' ]"
check "#36 an abandoned apply log is gone"        "[ ! -e '$_SCR/claude-sync-applied.OLDBBBB' ]"
# The three that must SURVIVE, which is where the damage would be. Each is a different reason.
check "#36 scratch too young to be abandoned is kept" "[ -d '$_SCR/claude-sync-suite-work.NEWCCCC' ]"
# A lock is not scratch. Whether it may be removed is decided by its own ownership rules, and a
# reaper answering that question from outside is how a live lock gets deleted (L157).
check "#36 the suite lock is not treated as scratch"  "[ -d '$_SCR/claude-sync-suite.lock' ]"
# The one the measurement is about: 542 of these belonged to other tools on the day this was found.
check "#36 another tool's temp directory is left alone" "[ -d '$_SCR/tmp.SOMEONEELSE' ]"
check "#36 and its contents are untouched"             "[ -f '$_SCR/tmp.SOMEONEELSE/filler' ]"
# Run twice: there is nothing left to reclaim, and saying so is not the same as saying nothing.
_scr_again="$(_reap)"
check "#36 reaping again finds nothing and says so" \
  "printf '%s' \"\$_scr_again\" | grep -qi 'no abandoned scratch'"
check "#36 and status goes quiet once they are gone" \
  "! _scr_status | grep -qi 'scratch the tool left behind'"

# An automatic deletion policy is the user's decision, never a silent default (L9). Planted old,
# so a sweep that ignored the off switch would really remove them and the check cannot pass by
# there being nothing to delete.
_scr_dir "claude-sync-suite-work.OFFTEST" 1
_scr_age "$_SCR/claude-sync-suite-work.OFFTEST"
_scr_off="$(SYNC_SCRATCH_MAX_AGE=0 SYNC_SCRATCH_ROOT="$_SCR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1)"; _scr_off_rc=$?
check "#36 the sweep can be turned off"          "[ '$_scr_off_rc' -eq 0 ]"
check "#36 and says it is off rather than that it found nothing" \
  "printf '%s' \"\$_scr_off\" | grep -qi 'sweep is off'"
check "#36 and removes nothing while it is off"  "[ -d '$_SCR/claude-sync-suite-work.OFFTEST' ]"
_scr_off_st="$(SYNC_SCRATCH_MAX_AGE=0 SYNC_SCRATCH_ROOT="$_SCR" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#36 and status reports no leftovers while it is off" \
  "! printf '%s' \"\$_scr_off_st\" | grep -qi 'scratch the tool left behind'"
# An age that cannot be read must never land on the permissive side of an `rm -rf` (L50).
_scr_junk="$(SYNC_SCRATCH_MAX_AGE=soon SYNC_SCRATCH_ROOT="$_SCR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1)"; _scr_junk_rc=$?
check "#36 an unreadable age is refused, not guessed" "[ '$_scr_junk_rc' -ne 0 ]"
check "#36 and the refusal names the value"          "printf '%s' \"\$_scr_junk\" | grep -q 'SYNC_SCRATCH_MAX_AGE=.soon. is not a whole number'"
check "#36 and it removed nothing on the way out"    "[ -d '$_SCR/claude-sync-suite-work.OFFTEST' ]"

# A young path matching the LAST name the reaper looks for. This is not a corner: the last name is
# the suite's own section mark, and a run always has a live one, so this is the state EVERY call
# made during a suite run is in. The tool runs under `set -e`, so the sweep ending on a false age
# test returned 1, and both commands then printed nothing at all and exited 1. Six unrelated checks
# went red, four of them because the self-update gate reads a non-zero `status` as a pulled script
# that cannot run, and declares a good version broken.
rm -rf "$_SCR"/*; touch "$_SCR/claude-sync-suite-section.LIVE"
_scr_young="$(_reap)"; _scr_young_rc=$?
check "#36 a live section mark does not break the reaper" "[ '$_scr_young_rc' -eq 0 ]"
check "#36 and it still says what it found"       "printf '%s' \"\$_scr_young\" | grep -qi 'no abandoned scratch'"
_scr_status >/dev/null 2>&1; _scr_st_rc=$?
check "#36 and status still exits cleanly beside one" "[ '$_scr_st_rc' -eq 0 ]"
check "#36 and the live mark is still there"      "[ -f '$_SCR/claude-sync-suite-section.LIVE' ]"

# Derived from the code, because a sweep by name protects only the names somebody remembered, and
# a scratch path added later is exempt from the very check meant to reclaim it (L96). Any mktemp
# in either file that does not name itself is unattributable the moment its run is killed.
# It asks whether the template NAMES this tool, and no longer whether the line mentions TMPDIR.
# Those agreed while every scratch path was written out of TMPDIR directly; once the directory
# scratch lives in moved behind a helper (#116) the TMPDIR reading answered about the spelling of
# the line rather than about the property it exists to protect, and it would have reported every
# correctly named path as unnamed (L63).
# Comments are STRIPPED before matching, or the prose explaining this rule satisfies it, and a
# guard that is green on its own explanation is indistinguishable from one that works (L103). The
# first version of this check read `grep -n` output, whose line-number prefix defeated the comment
# filter entirely, so eight sentences about mktemp were reported as eight unnamed scratch paths.
# Lines that SPLICE a literal out of pieces are dropped as well as comments. Those are search
# patterns, not calls, and the splice exists precisely so a guard cannot match its own assertion.
# Without this, the #38 guard's pattern list reads to this one as an unnamed scratch path, and two
# derived checks that are each correct report a defect that exists in neither.
_scr_code(){ sed 's/#.*//' "$SCRIPT" "$SCRIPT_SELF" | grep -vF '""'; }
_scr_unnamed=""
while IFS= read -r _ml; do
  [ -n "$_ml" ] || continue
  case "$_ml" in *claude-sync-*) ;; *) _scr_unnamed="$_scr_unnamed[$_ml]" ;; esac
done <<EOF
$(_scr_code | grep -E '\bmktemp\b')
EOF
check "#36 every scratch path this tool creates is named" "[ -z \"\$_scr_unnamed\" ]"
check "#36 the derivation found mktemp calls to check" \
  "[ \"\$(_scr_code | grep -cE '\\bmktemp\\b')\" -ge 5 ]"
# And every name it creates must be one the reaper actually sweeps, or the naming is decoration.
# Read from the mktemp calls themselves rather than from every temp path in the file: the suite
# LOCK lives under the same directory with a name of the same shape, and it is deliberately not
# scratch, so a derivation over paths reported it as a name the reaper had forgotten.
_scr_names="$(_scr_code | grep -E '\bmktemp\b' | grep -oE '/claude-sync-[a-z-]+\.' | sed 's|^/||' | sort -u)"
_scr_unswept=""
while IFS= read -r _nm; do
  [ -n "$_nm" ] || continue
  case " $(grep -oE '^SYNC_SCRATCH_NAMES=.*' "$SCRIPT" | head -1) " in *"$_nm"*) ;; *) _scr_unswept="$_scr_unswept[$_nm]" ;; esac
done <<EOF
$_scr_names
EOF
check "#36 every name it creates is one the reaper sweeps" "[ -z \"\$_scr_unswept\" ]"
check "#36 the name derivation found names to check" \
  "[ \"\$(printf '%s' \"\$_scr_names\" | grep -c .)\" -ge 3 ]"

# ---- the sweep's age against the suite's own ceiling (#160) ----
# These are one setting living in two files, and #152 moved half of it. Until then the ceiling was
# 900 against an age of 3600, so a run's scratch was at most a quarter of the way to being swept.
# #152 raised the ceiling to 3600 for a good reason and the margin became zero: a run approaching
# its own deadline can have its working directory, its extracted copy and its section mark deleted
# out from under it by any concurrent claude-sync, and the scheduled sync is exactly such an
# invocation. What that produces is missing fixtures in unrelated sections, which read as real test
# failures rather than as a sweep, so it costs an investigation every time.
#
# So the ratio is CHECKED here rather than asserted in the design record, which is where it was
# living and which cannot notice either number moving (L210, L174). Four times, which is the margin
# that existed before #152 rather than a figure chosen now.
#
# Both numbers are read from the DEFAULTS in the two files, never from the variables this run
# carries. The run that gets swept is the scheduled sync, which carries no override at all, so
# comparing this run's environment would answer about a pair nobody ships.
# The age comes from the same reader the fixtures above are backdated with, so the number this
# compares is the number they were planted against (L107: one definition of the question).
_mg_age="$SCRATCH_DEFAULT_AGE"
_mg_ceil="$(sed -n 's/^SUITE_TIMEOUT="\${SUITE_TIMEOUT:-\([0-9][0-9]*\)}"$/\1/p' "$SCRIPT_SELF")"
# An extraction that came back with NOTHING has compared nothing, and nothing must never read as a
# pass: a pattern that stops matching because somebody rewrote the assignment would leave this
# green for ever while the margin it guards was gone (L98, L90). Two matches fail the same way,
# because the captured value then carries a newline.
case "$_mg_age" in
  ''|*[!0-9]*) check "#160 the sweep's age could be read from claude-sync" "false" ;;
  *)           check "#160 the sweep's age could be read from claude-sync" "true" ;;
esac
case "$_mg_ceil" in
  ''|*[!0-9]*) check "#160 the suite ceiling could be read from this file" "false" ;;
  *)           check "#160 the suite ceiling could be read from this file" "true" ;;
esac
case "$_mg_age$_mg_ceil" in
  ''|*[!0-9]*) ;;
  *)
    _mg_floor=$(( _mg_ceil * 4 ))
    check "#160 abandoned scratch is aged out at four times the suite ceiling (${_mg_age}s against ${_mg_ceil}s)" \
      "[ '$_mg_age' -ge '$_mg_floor' ]"
    # Watched refusing, or any age large enough satisfies it, which is every age, and it reads as
    # protection while protecting nothing (L1).
    check "#160 and an age one second under that floor is refused" \
      "! [ $(( _mg_floor - 1 )) -ge '$_mg_floor' ]"
    ;;
esac

section "== the tool's scratch lives in a directory of its own (#116) =="
# The sweep for abandoned scratch globs the temp root, and on a real Mac that root belongs to
# everything else on the machine: 113,912 entries measured here on 2026-08-21, 25 of them ours.
# #115 cut six reads of it to one, taking `status` from 1.74s to 0.36s, and the one read left is most of what
# remains, paid 270 times over by the suite. A directory of our own makes that read tens of
# entries instead of six figures, and the cost stops depending on a machine-wide quantity nothing
# here controls.
#
# The whole risk is on the migration side: scratch already sitting in the old flat location must
# still be found, or the change silently abandons exactly what the feature exists to reclaim
# (L173). So the flat location is still swept, on an interval rather than on every call, and
# `reap-scratch` always sweeps it whatever the interval says.
_SUB="$WORK/scratch-sub"; mkdir -p "$_SUB"
_sub_run(){    # $1... = arguments to claude-sync, with the scratch root pointed at the fixture
  SYNC_SCRATCH_ROOT="$_SUB" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
    bash "$SCRIPT" "$@" 2>&1
}
_sub_age(){ scratch_age_out "$1"; }

# ---- where a new scratch file is actually created ------------------------------------------
# Proved by making the intended directory unwritable and reading the path mktemp then names, and
# not by looking for the file afterwards: every one of these is removed on the way out, so an
# after-the-fact check would pass just as well against a tool that created nothing at all (L159).
_SUBRO="$WORK/scratch-ro"; mkdir -p "$_SUBRO/claude-sync"; chmod 500 "$_SUBRO/claude-sync"
# The control for the control. Run as a user who can write to it anyway (root on some CI images),
# the fixture cannot hold, and a check that cannot fail must say so rather than pass (L98).
if touch "$_SUBRO/claude-sync/probe" 2>/dev/null; then
  rm -f "$_SUBRO/claude-sync/probe"
  check "#116 the read-only fixture holds" "false"
else
  check "#116 the read-only fixture holds" "true"
  _ro_out="$(SYNC_SCRATCH_ROOT="$_SUBRO" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" cite-scan L1 2>&1 || true)"
  check "#116 a new scratch file is created inside the subdirectory" \
    "printf '%s' \"\$_ro_out\" | grep -q 'claude-sync/claude-sync-work'"
fi
chmod 700 "$_SUBRO/claude-sync"

# ---- and nothing is left beside other tools' files ------------------------------------------
_sub_run cite-scan L1 >/dev/null 2>&1 || true
check "#116 the run made the directory it keeps its scratch in" "[ -d '$_SUB/claude-sync' ]"
_sub_flat="$(ls -A "$_SUB" 2>/dev/null | grep -v '^claude-sync$' || true)"
check "#116 and left nothing flat in the temp root" "[ -z \"\$_sub_flat\" ]"

# ---- abandoned scratch in the new home is reported and reclaimed -----------------------------
mkdir -p "$_SUB/claude-sync/claude-sync-suite-work.OLDSUBA"
dd if=/dev/zero of="$_SUB/claude-sync/claude-sync-suite-work.OLDSUBA/filler" bs=1048576 count=2 2>/dev/null
_sub_age "$_SUB/claude-sync/claude-sync-suite-work.OLDSUBA"
mkdir -p "$_SUB/claude-sync/claude-sync-suite-work.NEWSUBB"
_sub_st="$(_sub_run status)"
check "#116 status reports scratch abandoned in the new home" \
  "printf '%s' \"\$_sub_st\" | grep -q '1 abandoned'"
_sub_reap="$(_sub_run reap-scratch)"
check "#116 and the reaper reclaims it"          "[ ! -e '$_SUB/claude-sync/claude-sync-suite-work.OLDSUBA' ]"
check "#116 and says so"                          "printf '%s' \"\$_sub_reap\" | grep -q 'reclaimed 1'"
check "#116 scratch too young to be abandoned is kept" \
  "[ -d '$_SUB/claude-sync/claude-sync-suite-work.NEWSUBB' ]"
# The container is not scratch. Sweeping it would take every live run's scratch with it, and it is
# the one path in the new layout whose name is closest to the ones being swept.
check "#116 the directory holding them is never swept" "[ -d '$_SUB/claude-sync' ]"

# ---- the old flat location is still reclaimed (the migration) --------------------------------
# This is what the change could silently abandon: everything already sitting in the old location
# on every Mac that has run an earlier version.
_SUBL="$WORK/scratch-legacy"; mkdir -p "$_SUBL"
_legacy_run(){ SYNC_SCRATCH_ROOT="$_SUBL" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" "$@" 2>&1; }
echo 'applied log' > "$_SUBL/claude-sync-applied.OLDFLAT"
_sub_age "$_SUBL/claude-sync-applied.OLDFLAT"
echo 'not ours' > "$_SUBL/tmp.SOMEONEELSE"
_sub_age "$_SUBL/tmp.SOMEONEELSE"
_leg_st="$(_legacy_run status)"
check "#116 a leftover in the old flat location is still reported" \
  "printf '%s' \"\$_leg_st\" | grep -q '1 abandoned'"
_leg_reap="$(_legacy_run reap-scratch)"
check "#116 and is still reclaimed"     "[ ! -e '$_SUBL/claude-sync-applied.OLDFLAT' ]"
check "#116 and another tool's file beside it is left alone" "[ -f '$_SUBL/tmp.SOMEONEELSE' ]"

# ---- and the old location is not read on every single call ------------------------------------
# Which is the entire point: reading it is what costs six figures of directory entries. Asserted
# by behaviour rather than by a stopwatch, because a timing check on a fixture holding tens of
# entries measures nothing the real directory does (L102).
_SUBI="$WORK/scratch-interval"; mkdir -p "$_SUBI"
_int_run(){ SYNC_SCRATCH_ROOT="$_SUBI" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" "$@" 2>&1; }
_int_run status >/dev/null 2>&1 || true      # the first call sweeps the old location and stamps it
check "#116 the first call records that it swept the old location" \
  "[ -f '$_SUBI/claude-sync/.legacy-swept' ]"
echo 'planted after the stamp' > "$_SUBI/claude-sync-applied.AFTERSTAMP"
_sub_age "$_SUBI/claude-sync-applied.AFTERSTAMP"
_int_quiet="$(_int_run status)"
check "#116 a later call inside the interval does not read the old location" \
  "! printf '%s' \"\$_int_quiet\" | grep -qi 'scratch the tool left behind'"
# But it is never abandoned. Two ways back to it, and both are checked, because one of them is
# what somebody is told to run and the other is what happens on its own.
_int_forced="$(_int_run reap-scratch)"
check "#116 reap-scratch reads the old location whatever the interval says" \
  "printf '%s' \"\$_int_forced\" | grep -q 'reclaimed 1'"
echo 'planted again' > "$_SUBI/claude-sync-applied.SECONDONE"
_sub_age "$_SUBI/claude-sync-applied.SECONDONE"
# Aged well past any interval, with a fixed date rather than an offset from now: the point is
# that the stamp is stale, and an offset that happens to be shorter than the default interval
# would leave this asserting nothing while reading as if it did.
touch -t 202001010000 "$_SUBI/claude-sync/.legacy-swept"
_int_due="$(_int_run status)"
check "#116 and once the interval is up the old location is read again" \
  "printf '%s' \"\$_int_due\" | grep -q '1 abandoned'"

# ---- the interval knob ------------------------------------------------------------------------
_int_zero="$(SYNC_SCRATCH_LEGACY_EVERY=0 SYNC_SCRATCH_ROOT="$_SUBI" CLAUDE_HOME="$PSH" SYNC_REPO="$PSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#116 an interval of zero reads the old location on every call" \
  "printf '%s' \"\$_int_zero\" | grep -q '1 abandoned'"
_int_junk="$(SYNC_SCRATCH_LEGACY_EVERY=daily SYNC_SCRATCH_ROOT="$_SUBI" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1 || true)"
_int_junk_rc=$?
check "#116 an unreadable interval is refused, not guessed" \
  "printf '%s' \"\$_int_junk\" | grep -q \"SYNC_SCRATCH_LEGACY_EVERY='daily' is not a whole number\""
check "#116 and it reclaimed nothing on the way out" "[ -f '$_SUBI/claude-sync-applied.SECONDONE' ]"

# ---- the directory name is half of an `rm -rf` pattern ------------------------------------------
# It decides both where the sweep reads and which paths the reaper is permitted to remove, so a
# value that is not a single component would point both at a directory nobody chose. An
# unparseable value must never land on the permissive side of a delete (L50).
_SUBN="$WORK/scratch-dirname"; mkdir -p "$_SUBN"
echo 'planted' > "$_SUBN/claude-sync-applied.NAMETEST"
_sub_age "$_SUBN/claude-sync-applied.NAMETEST"
for _dn in 'a/b' '..' '.'; do
  _dn_out="$(SYNC_SCRATCH_DIRNAME="$_dn" SYNC_SCRATCH_ROOT="$_SUBN" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1 || true)"
  check "#116 a scratch directory name of '$_dn' is refused" \
    "printf '%s' \"\$_dn_out\" | grep -q 'is not a single directory name'"
done
# Planted old, so this cannot pass by there being nothing to remove (L159).
check "#116 and none of those refusals removed anything" "[ -f '$_SUBN/claude-sync-applied.NAMETEST' ]"
# An empty value means UNSET, which is what `:-` does everywhere else in this tool, so it takes the
# default rather than being refused. Proved by the run working, not by it staying silent.
_dn_empty="$(SYNC_SCRATCH_DIRNAME= SYNC_SCRATCH_ROOT="$_SUBN" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" reap-scratch 2>&1 || true)"
check "#116 an empty directory name falls back to the default" \
  "printf '%s' \"\$_dn_empty\" | grep -q 'reclaimed 1'"


section "== every run executes from a copy, so editing the suite mid-run cannot corrupt it (#121) =="
# Bash reads a script incrementally from a byte offset. Editing this file while a run is in flight
# makes the running shell resume at the wrong place, and what comes out is not a crash: it is
# ordinary looking failures in sections that are perfectly fine. Measured on 2026-08-21, three of
# them at once, in a section unrelated to the edit, and the same run was green the moment nothing
# was being written. Nothing in the output says which kind of failure it is.
#
# So no run reads this file after it has started. The two filtered paths always copied themselves
# because they had to extract sections; an unfiltered run now does too, which is the run that is
# left going for minutes while somebody keeps working.
_fc_running="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
check "#121 this run is executing from a copy, not from the file in the repo" \
  "[ '$_fc_running' != '$SCRIPT_SELF' ]"
# Not merely somewhere else: in the tool's own scratch, under a name the sweep owns, so a run
# killed before it can clean up leaves something attributable rather than an anonymous file (#36).
check "#121 and the copy is scratch this tool owns" \
  "case '$_fc_running' in */claude-sync-suite-work.*) true ;; *) false ;; esac"
# The control, and it is the half worth having: the two paths above are satisfied by ANY $0 that
# is not the repo file, including one from a run started by hand against some other copy. These
# say the real files are still the ones every derivation in this suite reads.
check "#121 the real suite file is still what SCRIPT_SELF names" \
  "[ -f '$SCRIPT_SELF' ] && grep -q 'claude-sync-suite-section' '$SCRIPT_SELF'"
check "#121 and the tool under test is still the real one" \
  "[ -f '$SCRIPT' ] && grep -q 'scratch_leftovers' '$SCRIPT'"
# The seam that lets the two checks above be watched FAILING. Without it they are only ever seen
# passing, and a check nobody has seen fail is not a check (L1): running this file with
# SUITE_FROM_COPY=1 skips the copy, which is exactly the state every run was in before #121, and
# both of them go red. It is named in the suite's own documentation for that reason.
_fc_seam="SUITE_""FROM_COPY"
check "#121 the seam that puts a run back in the old state is still there" \
  "grep -q \"\$_fc_seam\" '$SCRIPT_SELF'"

section "== a full run fans out across shards, and refuses a set nobody chose (#133) =="
# Measured on 2026-08-21, over the 82 sections it held then: about 200 seconds in all and no
# single one dominating, so there is nothing to speed up and only work to spread. Since #125 every
# suite in the repo runs side by side and this one is the single longest, which makes it the whole
# remaining wall clock. Measured again after the change, the same day: 75 seconds across four
# shards.
#
# Every check here is a REFUSAL, and deliberately so. Running a real fan-out from inside a section
# would take minutes and would tell you what the run you are already in has told you. What cannot
# be learned that way is whether a shard spec nobody can read is refused rather than guessed at,
# and a guess would report a result over a set of sections nobody chose (L50, L98).
_sh_run(){ SUITE_SHARD="$1" SUITE_NO_LOCK=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" bash "$SCRIPT_SELF" 2>&1 | head -3; }
for _sh_bad in "0/4" "5/4" "abc" "2" "2/0" "-1/4"; do
  _sh_out="$(_sh_run "$_sh_bad")"
  check "#133 a shard spec of '$_sh_bad' is refused"     "printf '%s' \"\$_sh_out\" | grep -q \"SUITE_SHARD='$_sh_bad'\""
done
# The control: a WELL formed spec is not refused, or every check above is satisfied by a suite that
# refuses everything (L159). Asked for a shard count larger than the section count, which is the
# one well formed spec that still has to refuse, and for a real one, which must not.
_sh_ok="$(SUITE_SHARD=1/2 SUITE_NO_LOCK=1 SECTION_LIST=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" bash "$SCRIPT_SELF" 2>&1 | head -2)"
check "#133 the control: a well formed spec gets past the refusals"   "! printf '%s' \"\$_sh_ok\" | grep -q 'is not of the form'"

# A job count nobody can read decides how many processes start, so it is refused too.
for _sh_j in "two" "1.5" "-2"; do
  _sh_jo="$(SUITE_JOBS="$_sh_j" SUITE_NO_LOCK=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" bash "$SCRIPT_SELF" 2>&1 | head -3)"
  check "#133 a job count of '$_sh_j' is refused"     "printf '%s' \"\$_sh_jo\" | grep -q \"SUITE_JOBS='$_sh_j'\""
done
# An EMPTY job count means UNSET, which is what `:-` does everywhere else in this file, so it takes
# the default rather than being refused. Checked because the refusal above is a `case` and it would
# be natural to list the empty string in it, which would then refuse a value nobody ever sets.
_sh_je="$(SUITE_JOBS= SUITE_SHARD=1/2 SUITE_NO_LOCK=1 SECTION_LIST=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" bash "$SCRIPT_SELF" 2>&1 | head -2)"
check "#133 an empty job count falls back to the default rather than being refused" \
  "! printf '%s' \"\$_sh_je\" | grep -q 'SUITE_JOBS='"

# The two flags that make a shard work must not reach anything it starts. SUITE_SHARD leaking made
# every run a section spawns become a whole shard, which turned a 48 second shard, written down 2026-08-21,
# into 322 and failed four checks in the section that tests SECTION_ONLY. SUITE_NO_LOCK leaking is worse and
# was already true before sharding: it silently disabled the lock in every subrun, so #32 was
# asserting about a lock nothing was testing (L169). Derived from the file, so a flag added later
# to the same list is covered without anybody remembering this check.
_sh_exp="$(grep -m1 "^export"" -n SUITE_FILTERED" "$SCRIPT_SELF")"
for _sh_v in SUITE_SHARD SUITE_NO_LOCK; do
  check "#133 $_sh_v is un-exported, so nothing this run starts inherits it"     "printf '%s' \"\$_sh_exp\" | grep -q '$_sh_v'"
done

section "== the shards, between them, covered every section (#137) =="
# Each shard reports its own totals and the parent adds them up. Nothing recorded how many
# sections a full run SHOULD produce, so a change that made one shard select fewer sections would
# have produced a smaller number and passed. The total is no help as a reference point: it was
# 817, then 830, then 943, every one of them legitimate, so drift in it is invisible by design and
# a shard that read nothing is indistinguishable from a shard that found nothing wrong (L98).
#
# What is asserted is COVERAGE, not a count: every section after the prelude is the TARGET of
# exactly one shard. It is derived from the selector's own arithmetic rather than from a number
# written down beside it, so adding a section needs no maintenance here and there is no second
# definition to drift (L107).
#
# Two halves, and both are needed. The verdict is driven with fabricated coverage lines, so every
# outcome it can report is PRODUCED rather than merely reachable (L151). Then the real selector is
# run for real, four times, and its real answers go through the same verdict: a verdict proven
# only over lines this section wrote would say nothing about the shards anybody runs (L52, L159).
#
# What it cannot catch, said plainly: both sides read the section list through one parser, so a
# heading that parser cannot see is outside this check. Such a section is not lost, it travels
# with the one above it and still runs, which is why the gap worth closing is the arithmetic.
_cov_v(){ printf '%s\n' "$1" | shard_coverage_verdict "$2"; }   # 0 = covered, else the complaint

_cov_ok="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9
SUITE-SHARD-COVERAGE shard=2 first=5 last=10 sections=6,8,10"
check "#137 shards that between them name every section are accepted" \
  "_cov_v \"\$_cov_ok\" 2 >/dev/null"
# And it says NOTHING when it is happy. A verdict that always prints would make the parent's
# report carry a complaint on every clean run, which is how a real one stops being read (L36).
check "#137 and a covered run is silent about it" \
  "[ -z \"\$(_cov_v \"\$_cov_ok\" 2)\" ]"

# A gap: shard 2 stops one short, which is exactly what a slice that drops one looks like.
_cov_gap="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9
SUITE-SHARD-COVERAGE shard=2 first=5 last=10 sections=6,8"
_cov_gap_out="$(_cov_v "$_cov_gap" 2)"
check "#137 a section no shard ran fails the run" "! _cov_v \"\$_cov_gap\" 2 >/dev/null"
check "#137 and the gap is named, so it can be looked up" \
  "line_has \"\$_cov_gap_out\" 'no shard' ' 10'"

# A duplicate: two shards both claim one section. The run would still be green, and the arithmetic
# that produced it is wrong in a way that hides a gap somewhere else.
_cov_dup="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9
SUITE-SHARD-COVERAGE shard=2 first=5 last=10 sections=6,8,9,10"
_cov_dup_out="$(_cov_v "$_cov_dup" 2)"
check "#137 a section claimed by two shards fails the run" "! _cov_v \"\$_cov_dup\" 2 >/dev/null"
check "#137 and the doubled section is named" \
  "line_has \"\$_cov_dup_out\" 'more than one shard' ' 9'"

# A shard that said nothing at all. Its sections are missing from the union, so the gap message
# would fire too and would accuse the selector of the reader's problem. Distinct causes get
# distinct messages, and this one arrives ALONE (L11).
_cov_none="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9"
_cov_none_out="$(_cov_v "$_cov_none" 2)"
check "#137 a shard that reported no coverage at all fails the run" "! _cov_v \"\$_cov_none\" 2 >/dev/null"
check "#137 and it is named as a shard that said nothing" \
  "line_has \"\$_cov_none_out\" 'printed no coverage line' ' 2'"
check "#137 and that is the only thing said, not a gap the missing line caused" \
  "case \"\$_cov_none_out\" in *'no shard'*) false ;; *) true ;; esac"

# Shards disagreeing about where the sections are means there is no set to check against at all,
# and adding up two different answers would produce a coverage claim over neither.
_cov_dis="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9
SUITE-SHARD-COVERAGE shard=2 first=6 last=10 sections=6,8,10"
_cov_dis_out="$(_cov_v "$_cov_dis" 2)"
check "#137 shards disagreeing about which sections exist fails the run" "! _cov_v \"\$_cov_dis\" 2 >/dev/null"
check "#137 and the disagreement is reported as its own cause" \
  "line_has \"\$_cov_dis_out\" 'disagree' 'shard 2'"

# A line that cannot be read is not a shard with no sections. Reading it as one would report a
# tidy list of gaps for a shard that may well have run everything it was given.
_cov_bad="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9
SUITE-SHARD-COVERAGE shard=2 first=x last=10 sections=6,8,10"
_cov_bad_out="$(_cov_v "$_cov_bad" 2)"
check "#137 a coverage line that cannot be read fails the run" "! _cov_v \"\$_cov_bad\" 2 >/dev/null"
check "#137 and an unreadable line is reported as unreadable" \
  "line_has \"\$_cov_bad_out\" 'could not be read' 'shard=2'"

# A section index outside the range every shard agreed on. It means the selector and the boundary
# have parted company, which no gap or duplicate would say.
_cov_out="SUITE-SHARD-COVERAGE shard=1 first=5 last=10 sections=5,7,9,11
SUITE-SHARD-COVERAGE shard=2 first=5 last=10 sections=6,8,10"
_cov_out_out="$(_cov_v "$_cov_out" 2)"
check "#137 a section outside the agreed range fails the run" "! _cov_v \"\$_cov_out\" 2 >/dev/null"
check "#137 and the out of range section is named" \
  "line_has \"\$_cov_out_out\" 'outside' ' 11'"

# The real thing. SUITE_SHARD_COVERAGE_ONLY runs the real selector and stops the moment it has
# said what it selected, so four real shards cost four file reads instead of a full run. Every
# check above would pass over a suite whose shards never emit a line at all, and this is the half
# that cannot (L98, L159).
_cov_real=""
_cov_k=1
while [ "$_cov_k" -le 4 ]; do
  _cov_real="$_cov_real$(SUITE_SHARD="$_cov_k/4" SUITE_SHARD_COVERAGE_ONLY=1 SUITE_NO_LOCK=1 \
    SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)
"
  _cov_k=$((_cov_k + 1))
done
_cov_real_out="$(_cov_v "$_cov_real" 4)"
check "#137 the real selector's four shards cover every section between them" \
  "_cov_v \"\$_cov_real\" 4 >/dev/null"
check "#137 and it had four real coverage lines to say that over" \
  "[ \"\$(printf '%s\n' \"\$_cov_real\" | grep -c '^SUITE-SHARD-COVERAGE ')\" = 4 ]"
# And the reading the parent actually does: the shard output FILES, by the names the fan-out gives
# them. A pattern that matches nothing is indistinguishable from a shard with nothing to say, and
# the fan-out is the only other place this runs, which is a whole run away (L100, L143). The
# fixtures carry the surrounding chatter a real shard prints, so the pattern has something to pick
# the line out of.
# Made, never cleared: the two files below are written whole each time, and the reader only ever
# opens the shards it was told to expect, so there is no stale state to remove and no derived path
# handed to a recursive delete (L5).
_cov_dir="$WORK/shard-coverage"
mkdir -p "$_cov_dir"
printf '%s\n' "== a section ==" "  ok: something" "SUITE-SHARD-COVERAGE shard=1 first=5 last=8 sections=5,7" "SUITE-RESULT passed=9 failed=0" > "$_cov_dir/1.out"
printf '%s\n' "== a section ==" "  ok: something" "SUITE-SHARD-COVERAGE shard=2 first=5 last=8 sections=6,8" "SUITE-RESULT passed=9 failed=0" > "$_cov_dir/2.out"
check "#137 the parent reads the coverage out of the shards' own output files" \
  "shard_coverage_over_dir \"\$_cov_dir\" 2 >/dev/null"
# Then take that line away from one file, leaving the file itself intact and chatty. That is what
# a shard whose emission was lost looks like, and it must be caught by the reading rather than
# absorbed as a shard that covered nothing.
grep -v '^SUITE-SHARD-COVERAGE ' "$_cov_dir/2.out" > "$_cov_dir/2.tmp" && mv "$_cov_dir/2.tmp" "$_cov_dir/2.out"
_cov_dir_out="$(shard_coverage_over_dir "$_cov_dir" 2)"
check "#137 and a shard whose output carries no coverage line is caught by that reading" \
  "! shard_coverage_over_dir \"\$_cov_dir\" 2 >/dev/null"
check "#137 and the file that was silent is the one named" \
  "line_has \"\$_cov_dir_out\" 'printed no coverage line' ' 2'"

# The control on the control: the same real lines with one shard's removed must be REFUSED, or
# the check above is being satisfied by a verdict that accepts anything it is handed (L1).
_cov_real_less="$(printf '%s\n' "$_cov_real" | grep -v '^SUITE-SHARD-COVERAGE shard=3 ')"
check "#137 and dropping one of those real shards is refused" \
  "! _cov_v \"\$_cov_real_less\" 4 >/dev/null"

section "== the headline total counts every section once, whatever the shard count (#146) =="
# The suite reported a different number of checks depending on how much of the machine the run was
# granted. Measured on 2026-08-21 over one file: 873 checks in a single process, 920 across two
# shards, 986 across four, 1052 across six, 1118 across eight. Nothing was hidden, the summary
# line said the prelude was counted once per shard, but the headline still moved with the machine,
# and a total that changes for reasons unrelated to the tests cannot be used to notice that checks
# were LOST, which is the one question a total exists to answer (L63).
#
# Measured rather than reasoned about, because the prelude was not the whole story. Over those
# same runs the prelude is 33 checks and runs in every shard, and one 14 check section runs a
# SECOND time in a shard that did not target it, because a section there declares it with a
# `# needs:` line. 873 plus three preludes plus that one repeat is 986 exactly. Subtracting only
# the prelude would have left the headline still moving between 873 and 887, and the sentence
# promising otherwise would have been wrong with nothing to catch it (L210).
#
# So every section run is one of three things and each shard says what each was worth: the
# PRELUDE, which every shard runs; this shard's TARGETS, which #137 already proves are divided
# between the shards with nothing missing and nothing doubled; and REPEATS, any other section a
# shard ran to satisfy a `# needs:`. The headline is the prelude once plus every target, which is
# every section exactly once, and the repeats are reported beside it rather than folded into it.
#
# Driven with fabricated lines first, so every outcome the verdict can report is PRODUCED rather
# than merely reachable (L151). A real filtered run goes through the same function at the end,
# because a verdict proven only over lines this section wrote would say nothing about the shards
# anybody actually runs (L52).
_ft_v(){ printf '%s\n' "$1" | fan_totals_verdict "$2"; }   # 0 = usable, else the complaint

# Two shards. These are numbers this section made up, not measurements of anything: the prelude
# is 33 checks in both, the targets are 400 and 440 between them, and a section worth 14 checks was
# repeated to satisfy a needs: declaration.
_ft_two="SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=400 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=433 total_fail=0 shard=1
SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=440 target_fail=0 repeat_pass=14 repeat_fail=0 total_pass=487 total_fail=0 shard=2"
_ft_two_out="$(_ft_v "$_ft_two" 2)"
check "#146 shards that agree about the prelude produce a headline" "_ft_v \"\$_ft_two\" 2 >/dev/null"
check "#146 and it is the prelude once plus every target, not the sum of the shards" \
  "[ \"\$_ft_two_out\" = '873 0 33 0 47 0' ]"
# Reported BESIDE the headline rather than folded into it: one prelude run over again, plus the
# section worth 14 checks that the needs: declaration pulled into the other shard. Made up for the
# fixture above, not measured.
check "#146 and the repeated runs are counted and reported separately" \
  "[ \"\$(printf '%s' \"\$_ft_two_out\" | awk '{print \$5}')\" = 47 ]"

# The same suite sliced four ways instead of two: same prelude, same targets between them, same
# one repeat. The headline has to be the SAME number, which is the entire point of the issue.
_ft_four="SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=200 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=233 total_fail=0 shard=1
SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=200 target_fail=0 repeat_pass=14 repeat_fail=0 total_pass=247 total_fail=0 shard=2
SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=220 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=253 total_fail=0 shard=3
SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=220 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=253 total_fail=0 shard=4"
_ft_four_out="$(_ft_v "$_ft_four" 4)"
check "#146 the same sections sliced four ways give the same headline as two" \
  "[ \"\${_ft_four_out%% *}\" = \"\${_ft_two_out%% *}\" ]"
# And the repeat count is the half that MOVES, so a headline that stayed still because the verdict
# ignores its input would not survive this pair (L178).
check "#146 while the count of repeated runs rises with the shard count" \
  "[ \"\$(printf '%s' \"\$_ft_four_out\" | awk '{print \$5}')\" = 113 ]"

# Failures go through the same arithmetic. A failing prelude check counted once per shard reads as
# four broken checks where there is one, and the reader then looks for four (L11).
_ft_fail="SUITE-SECTIONS prelude_pass=32 prelude_fail=1 target_pass=200 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=232 total_fail=1 shard=1
SUITE-SECTIONS prelude_pass=32 prelude_fail=1 target_pass=200 target_fail=2 repeat_pass=0 repeat_fail=0 total_pass=232 total_fail=3 shard=2"
_ft_fail_out="$(_ft_v "$_ft_fail" 2)"
check "#146 a failing prelude check is counted once, not once per shard" \
  "[ \"\$_ft_fail_out\" = '432 3 32 1 32 1' ]"

# A shard that said nothing about its sections. Its checks are in no bucket, so the headline
# cannot be worked out, and a missing total must never be treated as a zero: that reads as a shard
# where everything passed (L98, L90).
_ft_gone="SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=400 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=433 total_fail=0 shard=1"
_ft_gone_out="$(_ft_v "$_ft_gone" 2)"
check "#146 a shard that declared nothing about its sections is refused" "! _ft_v \"\$_ft_gone\" 2 >/dev/null"
check "#146 and the silent shard is named" "line_has \"\$_ft_gone_out\" 'shard' ' 2'"

# Shards that disagree about the prelude. The prelude is the same sections in every shard, so a
# disagreement means one of them ran something different, and subtracting either number produces a
# headline that is simply wrong while looking exactly like a correct one.
_ft_dis="SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=400 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=433 total_fail=0 shard=1
SUITE-SECTIONS prelude_pass=31 prelude_fail=0 target_pass=440 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=471 total_fail=0 shard=2"
_ft_dis_out="$(_ft_v "$_ft_dis" 2)"
check "#146 shards that disagree about the prelude are refused" "! _ft_v \"\$_ft_dis\" 2 >/dev/null"
check "#146 and both numbers are named, so the disagreement can be looked at" \
  "line_has \"\$_ft_dis_out\" 'prelude' '33' '31'"

# The buckets have to account for the shard's OWN total. If they do not, checks ran in no bucket at
# all and the headline would quietly leave them out, which is the same defect one level down and
# the reason each shard reports its own total beside the buckets (L16).
_ft_short="SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=400 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=999 total_fail=0 shard=1
SUITE-SECTIONS prelude_pass=33 prelude_fail=0 target_pass=440 target_fail=0 repeat_pass=0 repeat_fail=0 total_pass=473 total_fail=0 shard=2"
_ft_short_out="$(_ft_v "$_ft_short" 2)"
check "#146 buckets that do not add up to the shard's own total are refused" "! _ft_v \"\$_ft_short\" 2 >/dev/null"
check "#146 and the shard whose checks went unattributed is named" \
  "line_has \"\$_ft_short_out\" 'shard 1' '999'"

# And the real thing. A shard IS a filtered run, so this proves the line is emitted by the code
# that ships rather than only by the fixtures above, and that its buckets add up on real numbers.
# One cheap section, so it costs the prelude and almost nothing else.
_ft_real="$(SECTION_ONLY='repo hygiene' SUITE_NO_LOCK=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" bash "$SCRIPT_SELF" 2>&1)"
_ft_line="$(printf '%s\n' "$_ft_real" | grep -m1 '^SUITE-SECTIONS ')"
dbg "#146 real filtered run reported: $_ft_line"
check "#146 a real filtered run says how its checks were divided up" "[ -n \"\$_ft_line\" ]"
check "#146 and a real line's buckets add up to what that run reported" \
  "printf '%s\n' \"\$_ft_line shard=1\" | fan_totals_verdict 1 >/dev/null"
# The prelude really is the bulk of what a one section run does, which is the fact the whole issue
# rests on. A run whose prelude bucket was zero would satisfy every arithmetic check above (L182).
_ft_prel="$(printf '%s' "$_ft_line" | sed -n 's/.*prelude_pass=\([0-9]*\).*/\1/p')"
check "#146 and its prelude bucket is the bulk of the checks, which is why repeating it mattered" \
  "[ \"\${_ft_prel:-0}\" -gt 10 ]"

section "== a section is never run twice to satisfy a needs declaration (#151) =="
# A shard ran any section its own targets declared with a `# needs:` line, including sections
# another shard owned, so that section ran in BOTH. Measured on 2026-08-21: one section worth 14
# checks ran twice at two, four, six and eight shards. #146 made the cost visible by reporting
# those repeats beside the headline instead of folding them in; it did not remove them.
#
# The fix is in the ASSIGNMENT rather than in the closure: a section is put in the same shard as
# the prerequisite it needs, so the closure finds nothing left to borrow. A prerequisite must be
# EARLIER in the file, which the selector already refuses to run without, so the grouping always
# has a direction to follow.
#
# Asserted from the selector's OWN answer. Each coverage line now says what that shard would
# BORROW: the sections it will run that it does not own. Deriving that here instead would be a
# second implementation of the closure, sitting beside the one that decides what actually runs,
# and it would agree with itself rather than with the run (L107).
# ONE launch for all of a count's shards, not one launch per shard (claude-config#204). The
# selector decides the whole partition in a single pass and only then keeps the sections belonging
# to the shard that was asked for, so asking N times paid for the same decision N times: measured
# 2026-08-30 a coverage launch costs 1.1 seconds and 1.09 of that IS the selection, and the four
# counts below were 20 launches and 22 seconds of it.
#
# It is the REAL selector either way. The equivalence is not assumed, it is checked below.
# The store every launch below reads, pinned once (claude-config#245).
#
# These helpers used to inherit the LIVE section timings store, which the OTHER shards of this same
# run are writing to while these launches happen. The partition is dealt from those measured times,
# so the one fast launch and the four slow ones read the store at five different moments and can be
# handed five different partitions. That is what made #204 fail three separate full runs on
# 2026-08-31 while passing every time it was run on its own: the variable it was actually measuring
# was what else the machine was doing (L134, L224, L205).
#
# ST_BW_LIVE stands in for the real cache so nothing here writes to it (L2), and ST_BW_PIN is the
# snapshot taken at ONE moment. Every launch reads the pin, so the comparison below is between two
# code paths rather than between two moments of a store that moves under it.
ST_BW_LIVE="$WORK/bw-live"; ST_BW_PIN="$WORK/bw-pin"
mkdir -p "$ST_BW_LIVE" "$ST_BW_PIN"
if [ -n "$SUITE_SECTION_TIMINGS" ] && [ -d "$SUITE_SECTION_TIMINGS" ]; then
  cp -R "$SUITE_SECTION_TIMINGS/." "$ST_BW_LIVE/" 2>/dev/null || true
fi
cp -R "$ST_BW_LIVE/." "$ST_BW_PIN/" 2>/dev/null || true
# The store moving under the run, standing for a sibling shard closing a section mid comparison.
#
# Every record is INVERTED rather than one being made large, and that is deliberate twice over.
# Naming a section to disturb would report success while matching nothing the moment that title is
# reworded (L100), and the first attempt did exactly that: it named a PRELUDE section, which is
# never dealt to a shard, so the disturbance changed no partition and the control passed by
# accident. Inverting turns the heaviest group into the lightest, and the deal is heaviest first,
# so the order it produces has to change.
#
# It answers with how many records it rewrote, so a store that turned out empty is a failure rather
# than a silent pass (L98).
_bw_disturb(){   # _bw_disturb <store dir> -> how many records it changed
  local _bd_f _bd_v _bd_n=0
  for _bd_f in "$1"/*; do
    [ -f "$_bd_f" ] || continue
    _bd_v="$(awk 'NR == 1 { print $1 }' "$_bd_f" 2>/dev/null)"
    case "$_bd_v" in ''|*[!0-9]*) continue ;; esac
    printf '%s\n' "$(( 9999 - _bd_v ))" > "$_bd_f" 2>/dev/null || continue
    _bd_n=$(( _bd_n + 1 ))
  done
  printf '%s' "$_bd_n"
}
_bw_lines(){   # _bw_lines <shards> [store] -> the real coverage lines for that many shards
  SUITE_SHARD="1/$1" SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 \
    SUITE_SECTION_TIMINGS="${2:-$ST_BW_PIN}" \
    SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1
}
# The one launch per shard form, kept for exactly one purpose: proving the form above answers the
# same. A fast path that is a COPY of the selector's logic would agree with itself and with
# nothing else, and the only way to tell the two apart is to run the slow path and compare (L52).
_bw_lines_one_at_a_time(){   # _bw_lines_one_at_a_time <shards> [store] -> the same, the expensive way
  local _bw_n="$1" _bw_store="${2:-$ST_BW_PIN}" _bw_k=1 _bw_all=""
  while [ "$_bw_k" -le "$_bw_n" ]; do
    _bw_all="$_bw_all$(SUITE_SHARD="$_bw_k/$_bw_n" SUITE_SHARD_COVERAGE_ONLY=1 SUITE_NO_LOCK=1 \
      SUITE_SECTION_TIMINGS="$_bw_store" \
      SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)
"
    _bw_k=$((_bw_k + 1))
  done
  printf '%s' "$_bw_all"
}
_bw_cov_only(){   # _bw_cov_only <text> -> just the coverage lines, in order
  printf '%s\n' "$1" | grep '^SUITE-SHARD-COVERAGE ' || true
}
_bw_borrowed(){   # _bw_borrowed <coverage lines> -> every borrowed section, space separated
  printf '%s\n' "$1" | grep '^SUITE-SHARD-COVERAGE ' \
    | sed -n 's/.* borrowed=\([^ ]*\).*/\1/p' | tr ',' ' ' | tr '\n' ' ' \
    | sed 's/  */ /g; s/^ //; s/ $//'
}
# The shard counts the repeat was measured at. Every one of them, not a sample: the borrowing
# depends on where the round robin happened to put two particular sections, so a count that
# happens not to separate them proves nothing about the ones that do (L147).
# The equivalence, at one count, against every shard launched on its own. One count and not four:
# what is in doubt is whether the two paths are the same CODE, which a single disagreement would
# settle and four would not settle any better, and the slow path is the thing being paid for here.
# Four shards, because that is the default a Mac actually runs.
# The control first, and it is the half that proves the rest is not vacuous (L159): two reads of a
# store that MOVES between them really do come back with different partitions. Two fast launches,
# not the five-launch pair, because all this has to establish is that the disturbance can change
# the answer at all.
_bw_before="$(_bw_cov_only "$(_bw_lines 4 "$ST_BW_LIVE")")"
_bw_moved="$(_bw_disturb "$ST_BW_LIVE")"
_bw_after="$(_bw_cov_only "$(_bw_lines 4 "$ST_BW_LIVE")")"
# Two halves, because they fail differently: that the disturbance reached real records at all, and
# that reaching them changed the answer. A control that quietly rewrote nothing would report the
# same agreement as a store nobody touched (L98).
check "#245 the control disturbed the records it meant to ($_bw_moved of them)" \
  "[ \"\$_bw_moved\" -gt 50 ]"
check "#245 the control: a timings store that moves between two reads really does repartition" \
  "[ -n \"\$_bw_before\" ] && [ \"\$_bw_before\" != \"\$_bw_after\" ]"

# And now the equivalence, with the live store disturbed in the middle exactly as a sibling shard
# would. Both paths read the pin, so it reaches neither, and any disagreement left is a real one.
_bw_fast4="$(_bw_cov_only "$(_bw_lines 4)")"
_bw_disturb "$ST_BW_LIVE" >/dev/null
_bw_slow4="$(_bw_cov_only "$(_bw_lines_one_at_a_time 4)")"
# Counted into plain variables first, so the expressions handed to `check` stay simple enough to
# read. Both halves matter: that the two paths agree, and that they agreed about four real lines
# rather than about two empty strings (L98).
_bw_fast_n="$(printf '%s\n' "$_bw_fast4" | grep -c 'SUITE-SHARD-COVERAGE' | tr -d ' ')"
_bw_slow_n="$(printf '%s\n' "$_bw_slow4" | grep -c 'SUITE-SHARD-COVERAGE' | tr -d ' ')"
if [ "$_bw_fast4" = "$_bw_slow4" ]; then _bw_same=1; else _bw_same=0; fi
check "#204 one launch answers for every shard exactly as launching each one does" \
  "[ '$_bw_same' -eq 1 ]"
check "#204 and that comparison read four real coverage lines from each ($_bw_fast_n and $_bw_slow_n)" \
  "[ '$_bw_fast_n' = '4' ] && [ '$_bw_slow_n' = '4' ]"

for _bw_n in 2 4 6 8; do
  _bw_out="$(_bw_lines "$_bw_n")"
  check "#151 the real selector's $_bw_n shards each print what they would borrow" \
    "[ \"\$(printf '%s\n' \"\$_bw_out\" | grep -c ' borrowed=')\" = $_bw_n ]"
  check "#151 and at $_bw_n shards no section is borrowed from another shard" \
    "[ -z \"\$(_bw_borrowed \"\$_bw_out\")\" ]"
  # Still a partition: pinning a dependent to its prerequisite's shard must not lose a section or
  # give one to two shards, which is exactly what #137 asks (L204).
  check "#151 and at $_bw_n shards the sections are still divided between them" \
    "printf '%s\\n' \"\$_bw_out\" | shard_coverage_verdict $_bw_n >/dev/null"
done

# The balance, measured rather than assumed. Pinning dependents to their prerequisite's shard can
# pile one shard up, and a shard carrying far more than the others costs more wall clock than the
# duplicate it removed, which would be a worse answer wearing a green tick (#151's own warning).
_bw_sizes(){   # _bw_sizes <coverage lines> -> one target count per line
  printf '%s\n' "$1" | grep '^SUITE-SHARD-COVERAGE ' \
    | sed -n 's/.* sections=\([^ ]*\).*/\1/p' \
    | awk -F, '{print NF}'
}
_bw8="$(_bw_lines 8)"
_bw_hi="$(_bw_sizes "$_bw8" | sort -n | tail -1)"
_bw_lo="$(_bw_sizes "$_bw8" | sort -n | awk 'NR==1')"
check "#151 the shard sizes could be read as numbers (high='$_bw_hi' low='$_bw_lo')" \
  "case \"\$_bw_hi\$_bw_lo\" in ''|*[!0-9]*) false ;; *) true ;; esac"
# There is deliberately NO bound on how far apart the section COUNTS are, and that is the point of
# #203. The deal balances SECONDS now, so a shard holding two long sections while another holds
# thirty short ones is the CORRECT answer, and the check that used to live here forbade exactly
# that: it bounded the difference at three, and with the real measurements in place the eight
# shard deal came out at 32 sections against 2 while every shard sat within four seconds of the
# mean (measured 2026-08-30).
#
# It was measuring a proxy for the thing that matters, and a guard holding a proxy flat while the
# real quantity drifts is worse than no guard, because it reads as protection (L63). Deleted
# rather than loosened: its whole content was the rejected rule, and a loosened version would
# still be defending it (L252).
#
# What replaced it is in #203, which bounds the SECONDS each shard is dealt, at several shard
# counts, against the seconds= field the deal now prints. The one count-based refusal that remains
# is the selector's own, which rejects a shard holding no sections at all.
#
# The two numbers above are still read and still checked for being numbers, because that is what
# proves the coverage lines could be parsed at all.

# The control, and the half that would do the damage if it were wrong: the closure still PULLS a
# prerequisite in when it genuinely has to. SECTION_ONLY on the dependent section runs one section
# that is not the prelude and not itself, so the borrowing machinery is watched working rather
# than only watched reporting nothing (L159, L1).
# `awk NR==1` rather than `head -1`, which leaves on its first line and can kill its own producer
# under pipefail (#132, L183).
_bw_dep="$(grep -n '^# needs: ' "$SCRIPT_SELF" | awk -F: 'NR==1 {print $1}')"
if [ -n "$_bw_dep" ]; then
  _bw_dep_title="$(awk -v n="$_bw_dep" 'NR < n && /^section "/ { last = $0 } NR == n { print last }' "$SCRIPT_SELF" \
    | sed 's/^section "//; s/"$//')"
  _bw_pre_title="$(sed -n "${_bw_dep}p" "$SCRIPT_SELF" | sed 's/^# needs: //')"
  check "#151 the file really does carry a needs declaration to test this over" \
    "[ -n \"\$_bw_dep_title\" ] && [ -n \"\$_bw_pre_title\" ]"
  _bw_only="$(SECTION_ONLY="$_bw_dep_title" SUITE_NO_LOCK=1 SCRIPT="$SCRIPT" \
    SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
  check "#151 running only the dependent section still pulls its prerequisite in" \
    "printf '%s' \"\$_bw_only\" | grep -qF -- \"\$_bw_pre_title\""
else
  # Said out loud rather than skipped. A file with no declaration left in it makes every check
  # above pass by having nothing to find, which reads exactly like the defect being fixed (L98).
  check "#151 the file carries a needs declaration for these checks to be about" \
    "false"
fi

# The control, and the one that decides whether any of the above means anything. An empty
# borrowed= field is what a working derivation prints AND what a derivation that reports nothing
# ever would print, so the two are told apart by dealing the sections out the way this did before
# #151 and watching a section be borrowed (L1, L159). It is the measured defect reproduced: at four
# shards, one section pulled into a shard that does not own it.
# One launch for all four, exactly as the grouped form above (claude-config#204). This was four
# processes spelt out one after another, each paying the whole selection over again to be told
# about one shard of a partition it had already worked out in full.
_bw_old="$(SUITE_SHARD_NO_GROUPING=1 SUITE_SHARD=1/4 SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 \
  SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
check "#151 dealt out the old way, a section really is borrowed by a shard that does not own it" \
  "[ -n \"\$(_bw_borrowed \"\$_bw_old\")\" ]"
# And the same four shards still divide the sections between them that way, so what the check
# above caught is the BORROWING and not a selector that fell over (L140).
check "#151 and that old dealing is otherwise a sound division too" \
  "printf '%s\\n' \"\$_bw_old\" | shard_coverage_verdict 4 >/dev/null"

section "== the receive path records how long its suite took, and how much room is left (#218) =="
# Every pull that lands a hook runs the whole suite on the receiving Mac and writes the verdict to
# .hook-tests as outcome, epoch, exit status, suites ran, suites not run. There was no DURATION in
# it. The only statement of how long that run costs was a comment beside the timeout quoting a
# range measured on 2026-08-22, which is a claim nothing re-measures (L32, L210), and the number of
# suites grew by a sixth in the fortnight after it was written.
#
# The failure that shape produces is a deadline arriving with no warning, reported as "the hook
# suite could NOT be completed here", which sends the reader to look for a HANG rather than for a
# suite that simply got longer (L11).
HDH="$WORK/headroom-home"; mkdir -p "$HDH/hooks"
echo '{"hooks":{}}' > "$HDH/settings.json"
HDR="$WORK/headroom-repo"; mkdir -p "$HDR/payload/hooks"
hd_arrive(){ printf '# marker %s\n' "$1" > "$HDR/payload/hooks/hd-marker.sh"; }
hd_runner(){ { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$1"; } > "$HDR/payload/hooks/run-all-tests.sh"; chmod +x "$HDR/payload/hooks/run-all-tests.sh"; }
hd_runner 'echo "ALL 3 SUITES PASSED"
exit 0'
hd_arrive one
CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
hd_rec="$(head -1 "$HDR/.hook-tests" 2>/dev/null || true)"
dbg "#218 the record a real receive wrote: $hd_rec"
# The record is READ field by field, not matched with a regex. `\t` inside a grep pattern is a
# backslash and a t to GNU grep and something else again to BSD grep, so a pattern written that way
# passes on a Mac and fails on the runner with the record perfectly correct: it did, twice, on
# 2026-08-30 (L38, the same BSD against GNU split the portable helpers exist for).
#
# Reading the fields is also the stronger check, because it says which field is wrong rather than
# that the line as a whole did not match.
hd_o="$(hd_field "$hd_rec" outcome)"; hd_w="$(hd_field "$hd_rec" at)"
hd_c="$(hd_field "$hd_rec" exit)";    hd_r="$(hd_field "$hd_rec" ran)"
hd_n="$(hd_field "$hd_rec" notrun)";  hd_d="$(hd_field "$hd_rec" seconds)"
dbg "#218 fields: outcome=$hd_o when=$hd_w code=$hd_c ran=$hd_r notrun=$hd_n took=$hd_d"
check "#233 a real receive writes its record as named fields" \
  "case \"\$hd_rec\" in *outcome=*seconds=*) true ;; *) false ;; esac"
check "#218 a real receive records the outcome, the counts and a duration (outcome=$hd_o ran=$hd_r notrun=$hd_n took=$hd_d)" \
  "[ \"\$hd_o\" = passed ] && [ \"\$hd_c\" = 0 ] && [ \"\$hd_r\" = 3 ] && [ \"\$hd_n\" = 0 ] && case \"\$hd_d\" in ''|*[!0-9]*) false ;; *) true ;; esac"
check "#218 and the epoch it was written at is a whole number (when=$hd_w)" \
  "case \"\$hd_w\" in ''|*[!0-9]*) false ;; *) true ;; esac"
# The duration is a MEASUREMENT taken from the clock, not a number parsed out of the runner's
# printed words. That distinction is the whole of L325: a figure that reaches its reader only by
# being printed disappears the moment the work moves behind a worker or a background lane, while
# the work itself goes on succeeding. The runner here prints no timing at all, so the only way a
# record can carry one is if this end timed it.
#
# Proved by making the runner take a KNOWN time and reading what was recorded. The instant stub
# above recorded 0, so a stub that takes two seconds recording at least 1 is the difference
# between a clock and a constant (L1, L159). The clock is whole seconds, so two seconds of real
# time reads as 1 or 2 and the bound is 1.
hd_runner 'sleep 2
echo "ALL 3 SUITES PASSED"
exit 0'
hd_arrive two
CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
hd_slow_d="$(hd_field "$(head -1 "$HDR/.hook-tests" 2>/dev/null || true)" seconds)"
dbg "#218 a runner made to take two seconds was recorded at ${hd_slow_d}s"
check "#218 and the duration is timed here, not parsed: a two second runner recorded ${hd_slow_d}s against the instant one's 0s" \
  "case \"\$hd_slow_d\" in ''|*[!0-9]*) false ;; *) [ \"\$hd_slow_d\" -ge 1 ] ;; esac"

# status SAYS it, with the verdict, including on a pass. This surface is quiet on a pass
# everywhere else by design, and speaks here because the headroom only ever shrinks: the moment it
# stops being reported is the moment the next timeout arrives with no warning.
hd_st="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#218 status reports the last run's duration beside its verdict" \
  "line_has \"\$hd_st\" 'hook suite: passed' 's of the' 's it is given'"

# A run past HALF its deadline says so, in words that name the consequence rather than the number.
# Driven through the record itself, which is what the reader actually reads.
hd_over="$WORK/headroom-over"; mkdir -p "$hd_over"
printf 'outcome=passed\tat=%s\texit=0\tran=44\tnotrun=0\tseconds=1200\n' "$(date +%s)" > "$hd_over/.hook-tests"
hd_st_over="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_over" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_HOOK_TESTS_TIMEOUT=1800 bash "$SCRIPT" status 2>&1)"
check "#218 a run over half its deadline is reported as running out of room" \
  "line_has \"\$hd_st_over\" 'hook suite: passed' 'over HALF'"
# And the control: one comfortably under it is NOT, or the warning is on every run and stops being
# read (L36, L159).
hd_under="$WORK/headroom-under"; mkdir -p "$hd_under"
printf 'outcome=passed\tat=%s\texit=0\tran=44\tnotrun=0\tseconds=200\n' "$(date +%s)" > "$hd_under/.hook-tests"
hd_st_under="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_under" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_HOOK_TESTS_TIMEOUT=1800 bash "$SCRIPT" status 2>&1)"
check "#218 and one well inside it is not" \
  "! line_has \"\$hd_st_under\" 'hook suite: passed' 'over HALF'"
check "#218 though it still says what it took and what it is given" \
  "line_has \"\$hd_st_under\" 'hook suite: passed' '200s of the 1800s'"

# A record with NO duration says so, distinctly. Every record written before this existed carries
# none, and reading that absence as comfortable is the reassuring default this refuses (L98, L11).
hd_none="$WORK/headroom-none"; mkdir -p "$hd_none"
printf 'outcome=passed\tat=%s\texit=0\tran=44\tnotrun=0\n' "$(date +%s)" > "$hd_none/.hook-tests"
hd_st_none="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_none" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#218 a record from before durations existed says none was recorded" \
  "line_has \"\$hd_st_none\" 'hook suite: passed' 'no duration recorded'"
check "#218 and that is not phrased as being within budget" \
  "! line_has \"\$hd_st_none\" 'no duration recorded' 'it is given'"

# A FAILED run carries its duration too. What is recorded is what the receive path cost this Mac,
# and a suite that failed after doing its work cost exactly what it did.
hd_fail="$WORK/headroom-failed"; mkdir -p "$hd_fail"
printf 'outcome=failed\tat=%s\texit=1\tran=?\tnotrun=?\tseconds=1500\n' "$(date +%s)" > "$hd_fail/.hook-tests"
hd_st_fail="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_fail" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_HOOK_TESTS_TIMEOUT=1800 bash "$SCRIPT" status 2>&1)"
check "#218 a failed run reports its duration and its headroom too" \
  "line_has \"\$hd_st_fail\" 'FAILED' 'over HALF'"
# #185's check that the reader stops at its own field is gone, because the shape it defended is
# gone: with named fields the question it asked cannot arise (L252). What replaces it is the
# property that made named fields worth having, watched directly.
#
# A field this reader has never heard of is IGNORED and changes nothing else. Positionally, an
# added field silently became part of the last one it did know.
hd_new="$WORK/headroom-newfield"; mkdir -p "$hd_new"
printf 'outcome=failed\tat=%s\texit=1\tran=?\tnotrun=?\tseconds=1500\tsomething_added_later=42\n' "$(date +%s)" > "$hd_new/.hook-tests"
hd_st_new="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_new" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_HOOK_TESTS_TIMEOUT=1800 bash "$SCRIPT" status 2>&1)"
check "#233 a field the reader has never heard of is ignored" \
  "line_has \"\$hd_st_new\" 'FAILED' 'over HALF'"
check "#233 and it does not leak into the field beside it" \
  "! line_has \"\$hd_st_new\" 'FAILED' 'something_added_later'"
# A record written in the OLD positional shape is still read, or shipping this would turn every
# record already on both Macs into an unreadable one (L214).
hd_legacy="$WORK/headroom-legacy"; mkdir -p "$hd_legacy"
printf 'passed\t%s\t0\t44\t0\t200\n' "$(date +%s)" > "$hd_legacy/.hook-tests"
hd_st_legacy="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_legacy" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_HOOK_TESTS_TIMEOUT=1800 bash "$SCRIPT" status 2>&1)"
check "#233 a record in the old positional shape is still read" \
  "line_has \"\$hd_st_legacy\" 'hook suite: passed' '200s of the 1800s'"

# ---- the suites that could not run are NAMED (#250) ----
# The line said "only 37 of its 40 suites could run on this Mac, so 3 of them are unverified
# here", which is a quotation of the wording rather than a measurement of anything, so the figures
# in it are not measured and cannot go stale. A count cannot say whether the ones that sat out are
# trivial or cover the most important behaviour, and nothing could notice the number growing (L98).
hd_runner 'echo "3 SUITE(S) COULD NOT RUN HERE: test-alpha.sh test-beta.sh test-gamma.sh"
echo "ALL 3 SUITES THAT COULD RUN PASSED, and 3 could not run here"
exit 0'
hd_arrive three
out_hd250="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "#250 pull whose runner skipped three: $out_hd250"
check "#250 the pull names the suites that could not run, not just how many" \
  "case \"\$out_hd250\" in *test-beta.sh*) true ;; *) false ;; esac"
check "#250 and the record keeps their names for status to read" \
  "grep -q 'notrun_names=test-alpha.sh,test-beta.sh,test-gamma.sh' '$HDR/.hook-tests'"
hd_st250="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#250 status names them too" \
  "line_has \"\$hd_st250\" 'hook suite: passed' 'test-gamma.sh'"
# A record from before the names were kept must say that, not read as none having been skipped.
hd_unnamed="$WORK/headroom-unnamed"; mkdir -p "$hd_unnamed"
printf 'outcome=passed\tat=%s\texit=0\tran=37\tnotrun=3\tseconds=200\n' "$(date +%s)" > "$hd_unnamed/.hook-tests"
hd_st_un="$(CLAUDE_HOME="$HDH" SYNC_REPO="$hd_unnamed" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#250 a record that does not carry the names says so rather than reading as none" \
  "line_has \"\$hd_st_un\" 'hook suite: passed' 'does not name them'"

section "== every workflow job carries a timeout, above this suite's own deadline (#210) =="
# A CI job with no `timeout-minutes` gets the platform default of six HOURS. A hang is worse than a
# failure because it is indistinguishable from slowness (L110), and on a metered runner it is also
# expensive: the 2026-08-29 audit found a job with no timeout in nine repositories out of nine, and
# on a macOS runner at the 10x multiplier a single six hour hang costs two months of a free
# account's whole allowance (L313).
#
# The job here does carry one. What nothing checked is that it still will, or that a SECOND
# workflow file could not arrive without one, which is the shape this repo keeps removing: a rule
# that holds because somebody remembered it is a rule that lives in a prompt (L27, L96).
#
# Both halves are checked. Present, and BIGGER than the deadline the suite sets for itself: a job
# timeout at or below it fires first, and the suite's own message, which names the section it died
# in, is the far more useful of the two (L11).
_wf_dir="$(cd "$(dirname "$SCRIPT")" && pwd)/.github/workflows"
_wf_files="$(ls "$_wf_dir"/*.yml "$_wf_dir"/*.yaml 2>/dev/null || true)"
_wf_n="$(printf '%s\n' "$_wf_files" | grep -c . || true)"
# A scan handed no files reports nothing and reads as a clean tree (L98).
check "#210 there are workflow files to check" "[ \"\${_wf_n:-0}\" -ge 1 ]"

# One reader, used by the real files and by the fixtures below, so the probes exercise THIS rule
# rather than a second one written beside it (L107). A job is a two-space key under `jobs:`, and
# its block runs to the next such key or the end of the file.
_WF_AWK="$WORK/workflow-timeouts.awk"
cat > "$_WF_AWK" <<'WFAWK'
function close_job() {
  if (job != "") printf "%s\t%s\t%s\n", FILENAME, job, (t == "" ? "NONE" : t)
  job = ""; t = ""
}
/^jobs:[[:space:]]*$/ { injobs = 1; next }
injobs && /^[^[:space:]#]/ { close_job(); injobs = 0 }
injobs && /^  [A-Za-z0-9_-]+:[[:space:]]*$/ {
  close_job()
  job = $1; sub(/:$/, "", job)
  next
}
injobs && job != "" && /^    timeout-minutes:[[:space:]]*[0-9]+[[:space:]]*$/ {
  t = $2
}
END { close_job() }
WFAWK
_wf_jobs(){   # _wf_jobs <file>... -> "<file>\t<job>\t<minutes or NONE>" per job
  for _wf_f in "$@"; do awk -f "$_WF_AWK" "$_wf_f"; done
}

# The deadline to compare against is the one THAT WORKFLOW will run under, never the one this
# process happens to be running under. A Mac uses the code's default of an hour and CI sets its
# own, so reading `$SUITE_TIMEOUT` from here would compare a workflow file against whatever
# machine the suite is on and report a different answer in the two places (L522).
#
# So: the value the file sets, if it sets one, and otherwise the default the code would supply.
# The default is read out of the code rather than repeated here, or this holds the workflow to a
# number that stopped being true (L41).
_wf_default="$(sed 's/#.*//' "$SCRIPT_SELF" | grep -oE '\$\{SUITE_TIMEOUT:-[0-9]+\}' | grep -oE '[0-9]+' | awk 'NR==1')"
case "$_wf_default" in ''|*[!0-9]*) _wf_default=3600 ;; esac
check "#210 the suite's own default deadline could be read from the code (${_wf_default}s)" \
  "[ "\${_wf_default:-0}" -gt 0 ]"
_wf_setting_in(){   # _wf_setting_in <file> <name> <default> -> the seconds that file sets, or the default
  local _wd
  _wd="$(grep -E "^[[:space:]]*$2:[[:space:]]*[0-9]+[[:space:]]*\$" "$1" 2>/dev/null | grep -oE '[0-9]+' | awk 'NR==1')"
  case "$_wd" in ''|*[!0-9]*) _wd="$3" ;; esac
  printf '%s' "$_wd"
}
_wf_deadline_for(){   # _wf_deadline_for <workflow file> -> the seconds that file's jobs run under
  _wf_setting_in "$1" SUITE_TIMEOUT "$_wf_default"
}

# The workflow's OWN two deadlines have to satisfy the same rule #112 enforces at runtime: the
# ceiling must be at least twice the stall bound, or the ceiling fires first and every real hang is
# reported as a run that merely went on too long, which sends the reader to raise a limit instead
# of to find the hang (L11).
#
# #112 checks the values the suite is RUNNING under, which on a Mac are the code's defaults. A
# workflow that sets bad ones is therefore invisible until the suite runs there, and that is
# exactly what happened on 2026-08-30: a ceiling only one and a half times its stall bound was
# written into the workflow, passed every local run, and went red on the next CI push. A rule that
# can only be checked in the environment it governs is a rule nobody can check before shipping
# (L88, L177).
_wf_stall_default="$(sed 's/#.*//' "$SCRIPT_SELF" | grep -oE '\$\{SUITE_STALL_TIMEOUT:-[0-9]+\}' | grep -oE '[0-9]+' | awk 'NR==1')"
case "$_wf_stall_default" in ''|*[!0-9]*) _wf_stall_default=1200 ;; esac
_wf_ratio_bad=""
for _wf_one in $_wf_files; do
  _wf_c="$(_wf_setting_in "$_wf_one" SUITE_TIMEOUT "$_wf_default")"
  _wf_s="$(_wf_setting_in "$_wf_one" SUITE_STALL_TIMEOUT "$_wf_stall_default")"
  [ "$_wf_c" -ge $(( _wf_s * 2 )) ] || _wf_ratio_bad="$_wf_ratio_bad [$(basename "$_wf_one"): ceiling ${_wf_c}s against a ${_wf_s}s stall]"
done
check "#210 a workflow's own ceiling is at least twice its stall bound$_wf_ratio_bad" \
  "[ -z \"\$_wf_ratio_bad\" ]"
# Seen to fail, on a fixture with the ratio the first version of this workflow actually shipped.
_WFX="$WORK/workflow-fixtures"; mkdir -p "$_WFX"
printf 'name: fixture\non: [push]\njobs:\n  j:\n    runs-on: ubuntu-latest\n    timeout-minutes: 30\n    steps:\n      - run: true\n        env:\n          SUITE_STALL_TIMEOUT: 600\n          SUITE_TIMEOUT: 900\n' > "$_WFX/bad-ratio.yml"
_wf_bad_c="$(_wf_setting_in "$_WFX/bad-ratio.yml" SUITE_TIMEOUT "$_wf_default")"
_wf_bad_s="$(_wf_setting_in "$_WFX/bad-ratio.yml" SUITE_STALL_TIMEOUT "$_wf_stall_default")"
check "#210 and a ceiling under twice the stall would be caught (${_wf_bad_c}s against ${_wf_bad_s}s)" \
  "! [ \"\$_wf_bad_c\" -ge \$(( _wf_bad_s * 2 )) ]"

_wf_missing=""; _wf_short=""; _wf_seen=0
while IFS="$(printf '\t')" read -r _wf_f _wf_j _wf_t; do
  [ -n "$_wf_j" ] || continue
  _wf_seen=$(( _wf_seen + 1 ))
  _wf_dl="$(_wf_deadline_for "$_wf_f")"
  _wf_dl_min=$(( (_wf_dl + 59) / 60 ))
  if [ "$_wf_t" = NONE ]; then
    _wf_missing="$_wf_missing [$(basename "$_wf_f"):$_wf_j]"
  elif [ "$_wf_t" -le "$_wf_dl_min" ]; then
    _wf_short="$_wf_short [$(basename "$_wf_f"):$_wf_j is ${_wf_t}m against a ${_wf_dl_min}m deadline]"
  fi
done <<WFJOBS
$(_wf_jobs $_wf_files)
WFJOBS
check "#210 the scan found jobs to check ($_wf_seen)" "[ \"\${_wf_seen:-0}\" -ge 1 ]"
check "#210 every workflow job carries a timeout$_wf_missing" "[ -z \"\$_wf_missing\" ]"
check "#210 and every one of them exceeds the suite's own deadline$_wf_short" "[ -z \"\$_wf_short\" ]"

# Both refusals, seen firing on a fixture built for them, or the two checks above are green because
# the repo happens to be clean today and would stay green if the rule stopped working (L1, L151).
cat > "$_WFX/no-timeout.yml" <<'WFNONE'
name: fixture
on: [push]
jobs:
  fine:
    runs-on: ubuntu-latest
    timeout-minutes: 90
    steps:
      - run: true
  careless:
    runs-on: ubuntu-latest
    steps:
      - run: true
WFNONE
_wf_probe="$(_wf_jobs "$_WFX/no-timeout.yml")"
check "#210 the scan reads both jobs of a fixture file" \
  "[ \"\$(printf '%s\n' \"\$_wf_probe\" | grep -c .)\" = 2 ]"
# Here-strings, not pipes. `printf | grep -q` leaves on its first match and can be killed by its
# own producer under pipefail, which is the class this repo ratchets down (#132, L183). `grep -c`
# above reads all of its input and is safe either way.
check "#210 and it reports the job with no timeout as NONE" \
  "grep -q '	careless	NONE' <<< \"\$_wf_probe\""
check "#210 and it reads the minutes of the job that has one" \
  "grep -q '	fine	90' <<< \"\$_wf_probe\""
# A timeout BELOW the deadline is its own failure, and a different one: the job is bounded, it is
# just bounded so tightly that the platform kills the run before the suite can say where it died.
cat > "$_WFX/short-timeout.yml" <<'WFSHORT'
name: fixture
on: [push]
jobs:
  tooshort:
    runs-on: ubuntu-latest
    timeout-minutes: 1
    steps:
      - run: true
WFSHORT
_wf_probe2="$(_wf_jobs "$_WFX/short-timeout.yml")"
check "#210 and a job whose timeout is below the deadline is read as a number, not as absent" \
  "grep -q '	tooshort	1' <<< \"\$_wf_probe2\""
# And the comparison itself fires on it, which is the half the two checks above cannot show.
_wf_short_probe=""
while IFS="$(printf '\t')" read -r _wf_f _wf_j _wf_t; do
  [ -n "$_wf_j" ] || continue
  [ "$_wf_t" = NONE ] && continue
  [ "$_wf_t" -le "$(( ($(_wf_deadline_for "$_wf_f") + 59) / 60 ))" ] && _wf_short_probe="$_wf_short_probe $_wf_j"
done <<WFSHORTP
$(_wf_jobs "$_WFX/short-timeout.yml")
WFSHORTP
check "#210 and the deadline comparison would catch it" \
  "[ -n \"\$_wf_short_probe\" ]"

section "== the shards are dealt by measured section time, not by counting them (#203) =="
# The selector grouped sections by `# needs:` and dealt whole groups round robin to the shard
# carrying the FEWEST SECTIONS so far. Sections are not the same size. Measured 2026-08-29 from a
# serial run of 463 seconds of section time, the slowest five were 52, 38, 27, 27 and 24 seconds
# against a median under two, so counting them balanced nothing: at two shards the split was 185s
# against 276s where a time balanced deal is 231 and 230, and at four it was 76, 165, 115 and 105
# where balanced is 116 each.
#
# The runner one level up already had this: it keeps what each suite was last measured at and
# launches longest first (#144). This is the same idea one level down, and it carries the same two
# obligations. A section nobody has measured must not be invented a duration for, and the run has
# to SAY which rule it used, because a run that fell back to counting reads exactly like one that
# balanced by time (L11).
ST_STORE="$WORK/section-timings"; mkdir -p "$ST_STORE"
st_seconds(){   # st_seconds <coverage lines> -> the seconds= field of each, space separated
  printf '%s\n' "$1" | grep '^SUITE-SHARD-COVERAGE ' \
    | sed -n 's/.* seconds=\([0-9]*\).*/\1/p' | tr '\n' ' ' | sed 's/ $//'
}
st_spread(){   # st_spread <seconds, space separated> -> highest minus lowest, or nothing
  printf '%s' "$1" | tr ' ' '\n' | sort -n | awk 'NR==1{lo=$1} {hi=$1} END{ if (NF || hi != "") print hi - lo }'
}

# An EMPTY store first. Nothing has been measured, so the deal falls back to counting and says so,
# and that sentence is the control for every check below: without it a run that balanced by time
# and a run that could not are told apart by nothing (L98).
ST_EMPTY="$WORK/section-timings-empty"; mkdir -p "$ST_EMPTY"
st_empty="$(SUITE_SHARD=1/4 SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_EMPTY" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
check "#203 with nothing measured the deal falls back to counting, and says so" \
  "case \"\$st_empty\" in *'dealt by section count'*) true ;; *) false ;; esac"
check "#203 and it still divides every section between the shards" \
  "printf '%s\n' \"\$st_empty\" | shard_coverage_verdict 4 >/dev/null"

# Now a store the SUITE ITSELF wrote, not one this file made up. A real filtered run records what
# its sections cost, and that is the record the selector reads: a fixture written here would prove
# only that the reader agrees with this file's idea of the format (L48, L52).
SECTION_UNTIL='apply is idempotent' SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_STORE" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" >/dev/null 2>&1
st_recs="$(ls "$ST_STORE" 2>/dev/null | grep -c . | tr -d ' ')"
check "#203 a run records what each of its sections cost (${st_recs:-0} record(s))" \
  "[ \"\${st_recs:-0}\" -ge 5 ]"
# Read the FIELD, not the whole file, so a second field added later cannot silently make every
# record unreadable (L255). `awk NR==1` rather than `head -1`, which leaves on its first line and
# can kill its own producer under pipefail (#132, L183).
st_one="$(ls "$ST_STORE" 2>/dev/null | awk 'NR==1')"
st_val="$(awk 'NR == 1 { print $1 }' "$ST_STORE/$st_one" 2>/dev/null)"
check "#203 and what it records is a whole number of seconds (the record for '$st_one' reads '$st_val')" \
  "case \"\$st_val\" in ''|*[!0-9]*) false ;; *) true ;; esac"
# And it is keyed on the section's TITLE, so a section that moves in the file keeps its record.
# Checked by NAME rather than by count, or a store keyed on position would satisfy the check above
# and be wrong about every section the day one is inserted (L15).
check "#203 and the record is keyed on the section's title, not its position" \
  "[ -f \"\$ST_STORE/== push ==\" ]"

# A run driven through the SLOW seam records nothing at all. SUITE_SLOW_IN pauses deliberately in
# every section, so those durations measure the seam and not the section, and a store holding them
# would deal every later run against a number nobody meant. That is #229 one level up, where a
# suite exiting at once because it refused its own lock was recorded as costing nothing and then
# led nothing, with the run reporting a measured order the whole time (L330).
ST_SEAM="$WORK/section-timings-seam"; mkdir -p "$ST_SEAM"
SECTION_UNTIL=push SUITE_SLOW_IN='==' SUITE_POLL_INTERVAL=0.1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_SEAM" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" >/dev/null 2>&1
st_seam_n="$(ls "$ST_SEAM" 2>/dev/null | grep -c . | tr -d ' ')"
check "#203 a run whose sections were slowed on purpose records nothing (${st_seam_n:-0} record(s))" \
  "[ \"\${st_seam_n:-0}\" -eq 0 ]"
# The control: the very same run WITHOUT the seam does record, or the check above is satisfied by a
# run that records nothing under any circumstances (L159, L1).
ST_CTRL="$WORK/section-timings-ctrl"; mkdir -p "$ST_CTRL"
SECTION_UNTIL=push SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_CTRL" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" >/dev/null 2>&1
st_ctrl_n="$(ls "$ST_CTRL" 2>/dev/null | grep -c . | tr -d ' ')"
check "#203 and the same run without the seam does record (${st_ctrl_n:-0} record(s))" \
  "[ \"\${st_ctrl_n:-0}\" -gt 0 ]"

# With records present the deal says it used them, and every shard's line carries the seconds it
# was dealt, so the balance can be READ rather than inferred (L63: a guard asserts the quantity it
# exists to protect, which here is seconds and not sections).
st_timed="$(SUITE_SHARD=1/4 SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_STORE" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
check "#203 with records present the deal says it used them" \
  "case \"\$st_timed\" in *'dealt by measured section time'*) true ;; *) false ;; esac"
st_secs="$(st_seconds "$st_timed")"
check "#203 and every shard's line carries the seconds it was dealt ($st_secs)" \
  "[ \"\$(printf '%s' \"\$st_secs\" | wc -w | tr -d ' ')\" = 4 ]"
check "#203 and it is still a partition of every section" \
  "printf '%s\n' \"\$st_timed\" | shard_coverage_verdict 4 >/dev/null"

# The balance itself, in SECONDS, which is the quantity the deal is for. This replaces the check
# that compared how many SECTIONS each shard held: that number is now expected to differ between
# shards, because balancing seconds means giving a shard fewer of the big ones, and holding it flat
# would forbid the very thing #203 asks for (L63).
#
# The bound is a FRACTION of the total rather than a fixed number of seconds, so it means the same
# thing on a fast machine and a slow one and does not need re-deriving when the suite grows (L224).
# A quarter of the mean shard: the greedy deal's worst case is one item of unusual size arriving
# last, and the heaviest section here is a large fraction of a shard, so anything tighter would be
# a check on which sections happen to exist rather than on the deal.
# The BALANCE is checked against a store whose numbers are known, not against whatever the machine
# happened to measure a moment ago. What is under test here is the deal's arithmetic, and a store
# built from a short filtered run holds a handful of sections that all round to a second or two, so
# the mean shard is about a second and any spread at all fails: that check would be reading the
# machine's mood rather than the rule (L224, L290).
#
# The store's FORMAT is not invented here. The checks above prove the suite writes exactly this
# shape, keyed this way, so what follows fills a store of the same shape with a deliberately uneven
# distribution: one section far larger than the rest, which is the case greedy gets wrong when it
# deals in file order rather than heaviest first.
ST_FIX="$WORK/section-timings-fixture"; rm -rf "$ST_FIX"; mkdir -p "$ST_FIX"
st_i=0
while IFS= read -r st_t; do
  [ -n "$st_t" ] || continue
  st_i=$(( st_i + 1 ))
  # One section in twenty is worth 40, the rest 2. The big ones are what a count based deal spreads
  # wrongly, and 40 against 2 is close to the real spread measured 2026-08-29, where the slowest
  # section was 52 seconds against a median under two.
  if [ $(( st_i % 20 )) -eq 0 ]; then st_w=40; else st_w=2; fi
  printf '%s\n' "$st_w" > "$ST_FIX/$(printf '%s' "$st_t" | sed 's/%/%25/g; s#/#%2F#g')"
done <<STFIXT
$(grep '^section "' "$SCRIPT_SELF" | sed 's/^section "//; s/"$//')
STFIXT
check "#203 the fixture store was written for every section in the file ($(ls "$ST_FIX" | grep -c . | tr -d ' ') of $st_i)" \
  "[ \"\$(ls '$ST_FIX' | grep -c . | tr -d ' ')\" = '$st_i' ]"

# At several shard counts, not one. The balance depends on how the biggest sections happen to fall
# against the number of shards, so a count that happens to divide them evenly proves nothing about
# the ones that do not (L147). These are the counts #151 already exercises.
for st_n in 2 4 8; do
  st_out="$(SUITE_SHARD="1/$st_n" SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_FIX" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
  st_s="$(st_seconds "$st_out")"
  st_total=0
  for st_x in $st_s; do st_total=$(( st_total + st_x )); done
  st_mean=$(( st_total / st_n ))
  st_allow=$(( st_mean / 4 ))
  [ "$st_allow" -ge 1 ] || st_allow=1
  st_gap="$(st_spread "$st_s")"
  check "#203 at $st_n shards the seconds are balanced (spread ${st_gap:-?}s of a ${st_mean}s mean, allowed ${st_allow}s)" \
    "[ \"\${st_gap:-99999}\" -le \"\$st_allow\" ]"
  # The bound is a FRACTION of the mean shard rather than a fixed number of seconds, so it means
  # the same thing on a fast machine and a slow one and needs no re-deriving as the suite grows
  # (L224). A quarter: greedy's worst case is one item of unusual size arriving last, and the
  # largest section here is a real fraction of a shard, so anything tighter would be a check on
  # which sections happen to exist rather than on the deal.
  check "#203 and at $st_n shards a spread one second wider would be caught" \
    "! [ \$(( st_allow + 1 )) -le \"\$st_allow\" ]"
done

# Every section measuring ZERO. This is not a hypothetical: a store built from a fast filtered run
# holds nothing but zeroes, and the first version of the deal gave every group a weight of zero, so
# no shard was ever strictly less loaded than shard 1, every group went to shard 1, and the selector
# refused the other three for holding no sections at all. A whole run, dealt to one shard, from a
# store that was working exactly as designed.
#
# A group now never weighs less than the number of sections in it, which is the same thing the deal
# falls back to when it has no records, so this degrades to the count deal rather than collapsing.
ST_ZERO="$WORK/section-timings-zero"; rm -rf "$ST_ZERO"; mkdir -p "$ST_ZERO"
while IFS= read -r st_t; do
  [ -n "$st_t" ] || continue
  printf '0\n' > "$ST_ZERO/$(printf '%s' "$st_t" | sed 's/%/%25/g; s#/#%2F#g')"
done <<STZEROT
$(grep '^section "' "$SCRIPT_SELF" | sed 's/^section "//; s/"$//')
STZEROT
st_zero="$(SUITE_SHARD=1/4 SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS="$ST_ZERO" SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
check "#203 a store in which every section measured zero still divides the sections between shards" \
  "printf '%s\n' \"\$st_zero\" | shard_coverage_verdict 4 >/dev/null"
check "#203 and it does not pile them all onto one shard" \
  "[ \"\$(st_spread \"\$(st_seconds \"\$st_zero\")\")\" -le 1 ]"

# The store switched off entirely, which is what a run that must leave no trace needs, and what CI
# has until its cache is warm.
ST_OFF="$WORK/section-timings-off"; mkdir -p "$ST_OFF"
st_off="$(SUITE_SHARD=1/4 SUITE_SHARD_COVERAGE_ALL=1 SUITE_NO_LOCK=1 SUITE_SECTION_TIMINGS= SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$SCRIPT_SELF" 2>&1)"
check "#203 an empty SUITE_SECTION_TIMINGS turns the record off and says so" \
  "case \"\$st_off\" in *'dealt by section count'*) true ;; *) false ;; esac"
st_off_n="$(ls "$ST_OFF" 2>/dev/null | grep -c . | tr -d ' ')"
check "#203 and with it off nothing is written anywhere" "[ \"\${st_off_n:-0}\" -eq 0 ]"

section "== the runner says how much of the machine this suite may take (#136) =="
# The runner starts several suites at once and this one splits itself into shards, and the two
# numbers were set independently: a four core runner could be running a dozen heavy processes, each
# spawning git and python of its own. It never went red, which is the difficulty. Oversubscription
# makes timing sensitive checks intermittently wrong, and this suite's own deadline guard was
# measured firing at 1192s against a normal 200 on a loaded Mac, written down 2026-08-21.
#
# So the runner hands down a share of one budget in HOOK_TESTS_SLOTS and this suite takes it as how
# many shards to run. An explicit SUITE_JOBS still wins, because that is somebody asking for a
# number rather than a share being allocated to them.
#
# SUITE_PLAN_ONLY answers with the number and runs nothing. Without it the only way to see which
# number was chosen is to run the whole suite, which is the very cost the number decides (L102).
# On ONE line, because #34's scan reads the depth off the line that spawns and a continuation
# would leave the spawn looking undepthed. And no `head`: a reader that leaves early kills the
# producer under pipefail and reports a failure that never happened (L183, #132).
_pl(){ SUITE_PLAN_ONLY=1 SUITE_NO_LOCK=1 SUITE_DEPTH="$SUITE_CHILD_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" env "$@" bash "$SCRIPT_SELF" 2>&1; }

# The grant is UNSET here rather than merely absent from the arguments: this suite is itself run by
# the runner, so it inherits a real grant, and a check that assumed nothing was set would be asking
# about a case that never occurs on the machine it runs on (L504).
_pl_def="$(_pl -u HOOK_TESTS_SLOTS -u SUITE_JOBS)"
check "#136 with no grant and nothing asked for, the suite picks its own default" \
  "line_has \"\$_pl_def\" 'SUITE-PLAN' 'jobs=4' 'source=default'"

_pl_grant="$(_pl -u SUITE_JOBS HOOK_TESTS_SLOTS=2)"
check "#136 a grant from the runner decides how many shards run" \
  "line_has \"\$_pl_grant\" 'jobs=2' 'source=HOOK_TESTS_SLOTS'"

# Asking outright wins over being allocated a share, and the answer says which it was, so a number
# that surprises somebody can be traced to whoever chose it (L11).
_pl_both="$(_pl HOOK_TESTS_SLOTS=2 SUITE_JOBS=3)"
check "#136 an explicit job count still wins over the runner's grant" \
  "line_has \"\$_pl_both\" 'jobs=3' 'source=SUITE_JOBS'"

# An EMPTY grant means unset, which is what every other knob in this file does with an empty value.
# Checked because the refusal below is a `case` and it would be natural to list the empty string in
# it, which would then refuse a value nobody ever sets deliberately.
_pl_empty="$(_pl -u SUITE_JOBS HOOK_TESTS_SLOTS=)"
check "#136 an empty grant falls back to the default rather than being refused" \
  "line_has \"\$_pl_empty\" 'jobs=4' 'source=default'"

# A grant nobody can read decides how many processes start, so it is refused rather than guessed at,
# exactly as SUITE_JOBS already is (L50). It comes from another program, so an unreadable one means
# that program is wrong, and running four shards anyway would hide it.
for _pl_bad in "two" "0" "-2" "1.5"; do
  _pl_out="$(_pl -u SUITE_JOBS HOOK_TESTS_SLOTS="$_pl_bad")"
  check "#136 a grant of '$_pl_bad' is refused rather than guessed at" \
    "line_has \"\$_pl_out\" 'HOOK_TESTS_SLOTS' \"$_pl_bad\""
done
# The control: a well formed grant is not refused, or every check above is satisfied by a suite
# that refuses everything it is handed (L159).
check "#136 the control: a readable grant is not refused" \
  "case \"\$_pl_grant\" in *Refusing*) false ;; *) true ;; esac"

section "== a grandchild is not told the filtering already happened (#37) =="
# A run started with SECTION_UNTIL re-executes itself from a temp copy carrying SUITE_FILTERED=1,
# which means "extraction already happened, do not filter again". It arrives in the ENVIRONMENT, so
# everything that copy starts inherited it and read it as being about itself: the child ignored the
# SECTION_UNTIL it was given, ran the WHOLE suite, reached a section that spawns, and started
# another. A chain rather than a burst, so no process count trips and it looks exactly like a suite
# taking a while, which is why it ran twice on 2026-08-17 before anyone noticed (L169).
#
# Proven from the outside rather than by reading the code for the fix: SUITE_SPAWN_UNTIL stands a
# real run in the state that matters, one that RECEIVED the flag, and has it start one real child.
_gc="$(SUITE_FILTERED=1 SUITE_DEPTH="$SUITE_DEPTH" SUITE_SPAWN_UNTIL=push SUITE_TIMEOUT=90 bash "$SCRIPT_SELF" 2>&1)"; _gc_rc=$?
# Said first, because every assertion below reads that child's output, and a probe that never
# started one would leave them all comparing against nothing at all (L98).
check "#37 the spawn probe actually started a child" \
  "printf '%s' \"\$_gc\" | grep -q 'the child exited'"
check "#37 a filtered run hands the flag to nothing it starts" \
  "printf '%s' \"\$_gc\" | grep -q 'inherits SUITE_FILTERED as: <unset>'"
check "#37 its child honours the section limit it was given" \
  "printf '%s' \"\$_gc\" | grep -q 'stopped after SECTION_UNTIL=push'"
# The other half, and the one that names the actual damage: not merely that the child stopped, but
# that it never ran on past its limit. The marker is taken from the file rather than typed, so a
# renamed section leaves this failing rather than quietly asserting nothing (L103).
_late="$(section_title "$(grep '^section "' "$SCRIPT_SELF" | sed -n '6p')")"
check "#37 the late-section marker was found" "[ -n \"\$_late\" ]"
check "#37 the child did not run on into the rest of the suite" \
  "! printf '%s' \"\$_gc\" | grep -qF -- \"\$_late\""
check "#37 and the child is green" "[ '$_gc_rc' -eq 0 ]"

# The class fix has to sit ahead of every spawn site, or a site above it is still handing the flag
# on. Derived from the file rather than asserted as a line number, and the pattern is built from
# pieces so this assertion cannot be satisfied by itself.
_expn_pat="export"" -n SUITE_FILTERED"
_spawn_pat="bash \"\$SCRIPT""_SELF\""
_expn_line="$(grep -nF "$_expn_pat" "$SCRIPT_SELF" | head -1 | cut -d: -f1)"
_spawn_first="$(grep -nF "$_spawn_pat" "$SCRIPT_SELF" | head -1 | cut -d: -f1)"
check "#37 the flag is un-exported before anything spawns a run" \
  "[ -n \"\$_expn_line\" ] && [ -n \"\$_spawn_first\" ] && [ \"\$_expn_line\" -lt \"\$_spawn_first\" ]"

section "== a set-aside rule file is reported until it is resolved (#45) =="
# When a merge fails, the pull applies the other Mac's version and keeps yours as
# <file>.conflict-<host>, printing ONE line naming what was only in yours. Nothing restores that
# content, and every later check reports healthy because the live file matches the payload exactly.
# On 2026-08-17 that dropped a lesson out of the loaded rules, and it survived only because the one
# output line happened to be read. A condition that persists cannot be reported by a message that
# does not (L148, L152).
#
# What is outstanding is DERIVED from the two files on each run, never from a marker written when
# the conflict happened: a marker records a judgement made then, and cannot notice the copy being
# resolved by hand or deleted since (L121).
CPH="$WORK/pending-home"; CPR="$WORK/pending-repo"
mkdir -p "$CPH/skills/beta" "$CPR/payload/skills/beta"
echo '{"hooks":{}}' > "$CPH/settings.json"
printf '# rules\n@LESSONS.md\n' > "$CPH/CLAUDE.md"
printf -- '- **L1. one.** body\n- **L2. two.** body\n' > "$CPH/LESSONS.md"
printf 'alpha\nbeta\n' > "$CPH/skills/beta/SKILL.md"
CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
# The state the 2026-08-17 sync left behind: the live file is exactly what arrived, and this Mac's
# own entry exists nowhere but the copy beside it.
printf -- '- **L1. one.** body\n- **L2. two.** body\n- **L174. a shortened retention window.** body\n' > "$CPH/LESSONS.md.conflict-OtherMac"
printf 'alpha\nbeta\ngamma\ndelta\n' > "$CPH/skills/beta/SKILL.md.conflict-OtherMac"
out_p45="$(CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "status with pending conflicts: $out_p45"
# ONE line carrying the path AND what is still only in it. Two greps over the whole output would be
# answered by the file listing and by any other sentence mentioning the entry (L172, #55).
check "#45 status says what a set-aside rule file still holds" \
  "printf '%s' \"\$out_p45\" | grep -qE 'LESSONS\.md\.conflict-OtherMac.*L174'"
check "#45 status says how much a set-aside plain file still holds" \
  "printf '%s' \"\$out_p45\" | grep -qE 'skills/beta/SKILL\.md\.conflict-OtherMac.*2 lines'"
# The pull is where the condition was reported once and then never again, so it is the surface that
# has to keep reporting it.
out_p45pull="$(CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with pending conflicts: $out_p45pull"
check "#45 a later pull says the copy is still unresolved" \
  "printf '%s' \"\$out_p45pull\" | grep -qE 'LESSONS\.md\.conflict-OtherMac.*L174'"
check "#45 and the pull says plainly that this is not news" \
  "printf '%s' \"\$out_p45pull\" | grep -qi 'set a copy of your version aside and it is STILL not resolved'"
# Resolved by putting the entry back into the live file, which is what a person does. The copy is
# still on disk, so a report keyed on the file EXISTING would cry wolf for ever, and a guard that
# fires when nothing is wrong is one nobody reads (L36).
printf -- '- **L174. a shortened retention window.** body\n' >> "$CPH/LESSONS.md"
# And sent, which is what the watcher does within seconds of the edit. Without it the pull below
# mirrors the payload back over the live file and undoes the resolution mid-test, so the assertion
# would be about a state nobody is ever in.
CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
out_p45done="$(CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
out_p45pull2="$(CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "status after resolving: $out_p45done"
dbg "second pull: $out_p45pull2"
check "#45 a resolved copy is no longer reported as outstanding by the pull" \
  "! printf '%s' \"\$out_p45pull2\" | grep -qE 'LESSONS\.md\.conflict-OtherMac.*L174'"
# Still listed by status, because the file is still on disk and only a person can decide to delete
# it, but named as safe rather than as work outstanding. A copy that says nothing about its own
# state is indistinguishable from one holding the last surviving version of a lesson (L11).
check "#45 status still lists the resolved copy, named as safe to delete" \
  "printf '%s' \"\$out_p45done\" | grep -qE 'LESSONS\.md\.conflict-OtherMac.*(nothing|safe)'"
# The other copy has NOT been resolved and must still be reported in the same run: a report that
# went quiet the moment one of them was dealt with would hide the rest.
check "#45 the copy that is still outstanding is still named" \
  "printf '%s' \"\$out_p45done\" | grep -qE 'skills/beta/SKILL\.md\.conflict-OtherMac.*2 lines'"
check "#45 and the pull still names it" \
  "printf '%s' \"\$out_p45pull2\" | grep -qE 'skills/beta/SKILL\.md\.conflict-OtherMac.*2 lines'"
rm -f "$CPH/LESSONS.md.conflict-OtherMac" "$CPH/skills/beta/SKILL.md.conflict-OtherMac"
out_p45gone="$(CLAUDE_HOME="$CPH" SYNC_REPO="$CPR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
check "#45 a pull with no copies left says nothing about conflicts" \
  "! printf '%s' \"\$out_p45gone\" | grep -qi 'conflict'"

section "== a set-aside copy is judged by its words, not its line breaks (#212) =="
# The report decided whether a `.conflict-*` copy still held content by comparing whole LINES
# against the live file. Re-flowing a paragraph keeps every word and changes every line boundary,
# so the copy was reported as holding content that is in fact already live.
#
# Observed 2026-08-29: `hooks/test-pipefail-shortcircuit.sh.conflict-Daniels-MacBook-Pro-2` was
# reported as 4 lines "still only there", and all four sentences were present verbatim in the live
# header, merely wrapped differently. This is the only report of content that exists in no loaded
# file, so a warning that fires on files needing no action is the one that trains the reader to
# skim it (L36), and L278 is the rule: compare in the unit the meaning lives in, not the unit the
# file happens to be stored in.
#
# Both directions are asserted in ONE fixture, because a check that only goes quiet proves nothing
# about whether it can still speak (L159): the re-wrapped copy must go quiet in the same run where
# the copy holding a genuinely deleted sentence is still named.
WWH="$WORK/wrap-home"; WWR="$WORK/wrap-repo"
mkdir -p "$WWH/hooks" "$WWR/payload/hooks"
echo '{"hooks":{}}' > "$WWH/settings.json"
printf '# rules\n@LESSONS.md\n' > "$WWH/CLAUDE.md"
printf -- '- **L1. one.** body\n' > "$WWH/LESSONS.md"
# The live file, wrapped one way.
printf '# the producer is killed by its consumer and the pipeline\n# reports a failure that never happened\nrun_it\n' \
  > "$WWH/hooks/wrapped.sh"
# A second file, to hold the case that must still be reported.
printf '# the producer is killed by its consumer\nrun_it\n' > "$WWH/hooks/lost.sh"
CLAUDE_HOME="$WWH" SYNC_REPO="$WWR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
# The set-aside copy: identical words, every line boundary different. Nothing is at stake in it.
printf '# the producer is killed by its consumer and\n# the pipeline reports a failure that\n# never happened\nrun_it\n' \
  > "$WWH/hooks/wrapped.sh.conflict-OtherMac"
# The set-aside copy that DOES hold a sentence the live file lost. Same re-wrap, plus one clause
# that exists nowhere else, so a fix that simply stops looking would take this one down with it.
printf '# the producer is killed by\n# its consumer and the hazard is live here\nrun_it\n' \
  > "$WWH/hooks/lost.sh.conflict-OtherMac"
out_212="$(CLAUDE_HOME="$WWH" SYNC_REPO="$WWR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "status with a re-wrapped conflict copy: $out_212"
# The one line each copy is named on, pulled out first and matched with `case`. A piped `grep -q`
# would be three more sites on the ratchet in the file that already carries the most of them, and
# the hazard it tracks is real on this Mac (L183). `sed -n` reads all of its input, so it cannot
# kill the producer.
line_212wrap="$(printf '%s\n' "$out_212" | sed -n '/wrapped\.sh\.conflict-OtherMac/p')"
line_212lost="$(printf '%s\n' "$out_212" | sed -n '/lost\.sh\.conflict-OtherMac/p')"
check "#212 a re-wrapped copy is named as safe rather than as work outstanding" \
  "case \"\$line_212wrap\" in *nothing*|*safe*) true ;; *) false ;; esac"
check "#212 and it is not reported as holding lines" \
  "[ -n \"\$line_212wrap\" ] && case \"\$line_212wrap\" in *' lines'*) false ;; *) true ;; esac"
check "#212 a copy holding a sentence the live file lost is still named in the same run" \
  "case \"\$line_212lost\" in *' lines'*) true ;; *) false ;; esac"
rm -f "$WWH/hooks/wrapped.sh.conflict-OtherMac" "$WWH/hooks/lost.sh.conflict-OtherMac"

section "== a renumber's citation scan opens only the files that match (#53) =="
# The scan walked every synced file and ran a text test plus a matcher on each of them, once per
# renumbered lesson, measured on 2026-08-17: 800 files (747 under skills/) at 8.4 seconds per
# lesson on the real config, roughly 2,400 processes, run in the background on every config edit.
# One grep answers the same question in 0.022 seconds.
#
# Asserted as the quantity being protected, how many files the scan OPENS, rather than as elapsed
# time (L63): a wall-clock threshold on a shared runner is noise, and a number that moved cannot
# say why. SYNC_NO_CITATION_PREFILTER=1 keeps the old whole-tree walk reachable, so both paths are
# run over one fixture and compared. Without that the fast path becomes a second definition of what
# counts as a citation, and the two would drift in the direction that flatters the optimisation
# (L107).
CSH="$WORK/citehome"; CSR="$WORK/citerepo"
mkdir -p "$CSH/hooks" "$CSH/skills/demo" "$CSH/skills/quiet" "$CSH/skills/bulk" \
         "$CSR/payload/hooks" "$CSR/payload/skills/demo" "$CSR/payload/skills/quiet"
printf '# rules\n@LESSONS.md\nsee L2 for the rule\n' > "$CSH/CLAUDE.md"
# A heading and nothing else. Each entry's own number is stripped before the count, so this file
# does not CITE L2 and neither path may name it: it is the case where the one-pass grep matches and
# the count that follows must still say no.
printf '# Lessons\n\n- **L2. two.** body carrying no citation\n' > "$CSH/LESSONS.md"
printf 'see L2 for the rule\n' > "$CSH/hooks/x.sh"
printf -- '---\nname: demo\n---\nsee L2 for the rule\n' > "$CSH/skills/demo/SKILL.md"
printf -- '---\nname: quiet\n---\nno citation here\n' > "$CSH/skills/quiet/SKILL.md"
# Byte soup run through the matcher produces counts nobody can act on, so a binary file is out of
# scope however many times its bytes happen to spell the number.
printf 'L2 \000\001\002 L2\n' > "$CSH/skills/quiet/logo.png"
# Cites the number and is NOT in the payload, so it is not this tool's to report on.
printf 'see L2 for the rule\n' > "$CSH/hooks/unsynced.sh"
# The bulk of a real config is skills/, and it is what made the old walk expensive. These exist
# only in the home: the payload test happens after the candidates are gathered, so what they prove
# is that the scan does not open a file it has no reason to.
for _i in $(seq 1 400); do printf 'nothing to see here\n' > "$CSH/skills/bulk/f$_i.md"; done
for _p in CLAUDE.md LESSONS.md hooks/x.sh skills/demo/SKILL.md skills/quiet/SKILL.md skills/quiet/logo.png; do
  cp "$CSH/$_p" "$CSR/payload/$_p"
done
cs_fast="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CSH" SYNC_REPO="$CSR" bash "$SCRIPT" cite-scan L2 2>"$WORK/cite-fast.err")"
cs_fast_err="$(cat "$WORK/cite-fast.err")"
cs_slow="$(SYNC_NO_CITATION_PREFILTER=1 SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CSH" SYNC_REPO="$CSR" bash "$SCRIPT" cite-scan L2 2>"$WORK/cite-slow.err")"
cs_slow_err="$(cat "$WORK/cite-slow.err")"
dbg "cite-scan fast: $cs_fast_err / $(printf '%s' "$cs_fast" | tr '\n' ';')"
dbg "cite-scan slow: $cs_slow_err / $(printf '%s' "$cs_slow" | tr '\n' ';')"
check "#53 the scan finds the citing files" \
  "[ \"\$(printf '%s\n' \"\$cs_fast\" | sort | tr '\n' ' ')\" = 'CLAUDE.md	1 hooks/x.sh	1 skills/demo/SKILL.md	1 ' ]"
check "#53 both paths report exactly the same files" \
  "[ \"\$(printf '%s' \"\$cs_fast\" | sort)\" = \"\$(printf '%s' \"\$cs_slow\" | sort)\" ]"
# The point of the change, stated as a number rather than as a feeling: five files opened out of a
# tree of over four hundred. Five and not three, because the one-pass grep matches raw text: the
# file whose only occurrence is its own heading and the one that is not synced are both candidates,
# and the count that follows is what says no to them. The old path is still there behind the seam
# and still opens all four hundred, which is what makes this assertion mean something.
check "#53 only the files that could match are opened" \
  "printf '%s' \"\$cs_fast_err\" | grep -qE 'examined 5 (candidate )?file'"
check "#53 the slow path opens the whole tree, so the comparison is real" \
  "[ \"\$(printf '%s' \"\$cs_slow_err\" | sed -nE 's/.*examined ([0-9]+).*/\1/p')\" -gt 400 ]"
check "#53 a binary file is never scanned"       "! printf '%s' \"\$cs_fast\" | grep -q 'logo.png'"
check "#53 a file that is not synced is out of scope" "! printf '%s' \"\$cs_fast\" | grep -q 'unsynced.sh'"
check "#53 a heading is not a citation of itself" "! printf '%s' \"\$cs_fast\" | grep -q 'LESSONS.md'"
check "#53 a synced file with no mention is not named" "! printf '%s' \"\$cs_fast\" | grep -q 'quiet/SKILL.md'"
# Report only, in both directions: the scan is a diagnostic and must never edit what it reads.
check "#53 the scan rewrites nothing"            "grep -q 'see L2 for the rule' '$CSH/hooks/x.sh' && grep -q 'see L2 for the rule' '$CSH/CLAUDE.md'"
# A number it cannot parse is refused, not scanned for: `cite-scan hooks` would otherwise grep the
# whole tree for the word and report every file that mentions hooks as a citation.
cs_bad_rc=0
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CSH" SYNC_REPO="$CSR" bash "$SCRIPT" cite-scan hooks >/dev/null 2>&1 || cs_bad_rc=$?
check "#53 something that is not a lesson number is refused" "[ \"\$cs_bad_rc\" -ne 0 ]"

section "== each Mac mints lesson numbers in its own band (#44) =="
# Both Macs allocated the next free number from their own copy of the rules, so any two lessons
# written between syncs claimed the same number BY CONSTRUCTION. It happened on 2026-07-29 (four
# renumbers) and again on 2026-08-17 (three). The merge settles it and loses nothing, but every
# renumber leaves references that no local tool can reach: a number quoted in a filed issue, a PR
# comment or a published line stays pointing at the entry that kept it.
#
# So the number is minted from a band this Mac owns. Two Macs cannot mint the same number however
# long they go without seeing each other, and the renumber path becomes the thing that never fires.
BDR="$WORK/band-repo"; BDA="$WORK/band-homeA"; BDB="$WORK/band-homeB"
mkdir -p "$BDR/payload" "$BDA" "$BDB"
printf '# rules\n@LESSONS.md\n' > "$BDA/CLAUDE.md"
printf -- '- **L1. one.** body\n- **L2. two.** body\n- **L3. three.** body\n' > "$BDA/LESSONS.md"
cp "$BDA/CLAUDE.md" "$BDB/CLAUDE.md"; cp "$BDA/LESSONS.md" "$BDB/LESSONS.md"
out_bd1="$(SYNC_HOSTNAME=MacOne SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDA" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
dbg "first Mac's claim: $out_bd1"
check "#44 the first Mac keeps counting from the numbers already in use" \
  "printf '%s' \"\$out_bd1\" | grep -q '^L4$'"
check "#44 its band is recorded where the other Mac can read it" \
  "[ \"\$(cat '$BDR/lesson-bands/MacOne' 2>/dev/null)\" = '1' ]"
check "#44 and the claim says which band it took" \
  "printf '%s' \"\$out_bd1\" | grep -qi 'had no lesson number band, so it claimed 1 to 500'"
# The whole point, and the case that used to collide: a second Mac holding the SAME rules file, at
# the same moment, must not offer the same number.
out_bd2="$(SYNC_HOSTNAME=MacTwo SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDB" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
dbg "second Mac's claim: $out_bd2"
check "#44 the second Mac mints from its own band instead" \
  "printf '%s' \"\$out_bd2\" | grep -q '^L501$'"
check "#44 and the two Macs are not offered the same number" \
  "[ \"\$(printf '%s' \"\$out_bd1\" | grep -oE 'L[0-9]+' | tail -1)\" != \"\$(printf '%s' \"\$out_bd2\" | grep -oE 'L[0-9]+' | tail -1)\" ]"
# A band is claimed once. Re-claiming on every call would walk up the bands for ever and make the
# number nobody can predict.
out_bd2b="$(SYNC_HOSTNAME=MacTwo SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDB" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
check "#44 asking twice gives the same answer"       "printf '%s' \"\$out_bd2b\" | grep -q '^L501$'"
check "#44 and does not claim a second band"          "[ \"\$(cat '$BDR/lesson-bands/MacTwo' 2>/dev/null)\" = '501' ]"
check "#44 an established Mac says nothing about claiming" \
  "! printf '%s' \"\$out_bd2b\" | grep -qi 'claimed'"
# The second Mac writes its lesson, and both Macs then hold each other's entries after a sync.
# Neither Mac's next number may move because of what the OTHER one wrote.
printf -- '- **L501. five hundred and one.** body\n' >> "$BDB/LESSONS.md"
printf -- '- **L501. five hundred and one.** body\n' >> "$BDA/LESSONS.md"
out_bd3="$(SYNC_HOSTNAME=MacTwo SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDB" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
out_bd4="$(SYNC_HOSTNAME=MacOne SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDA" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
check "#44 the Mac that wrote it moves on to the next in its band" "printf '%s' \"\$out_bd3\" | grep -q '^L502$'"
check "#44 the other Mac is unaffected by it"                      "printf '%s' \"\$out_bd4\" | grep -q '^L4$'"
# Numbering is still one namespace, so the duplicate check has to keep judging the whole file
# rather than one band: an arriving duplicate is exactly what it exists to catch.
printf -- '- **L501. a second entry under the same number.** body\n' >> "$BDA/LESSONS.md"
bd_dup_rc=0
SYNC_HOSTNAME=MacOne SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDA" SYNC_REPO="$BDR" bash "$SCRIPT" check-lessons >/dev/null 2>&1 || bd_dup_rc=$?
check "#44 a duplicate anywhere in the file is still caught" "[ \"\$bd_dup_rc\" -ne 0 ]"
# A band that runs out must REFUSE, never spill into the neighbouring Mac's numbers, which is the
# one failure that would put the collisions back without anything saying so.
BDC="$WORK/band-homeC"; mkdir -p "$BDC"
printf '# rules\n@LESSONS.md\n' > "$BDC/CLAUDE.md"
printf -- '- **L1000. the last one in the band.** body\n' > "$BDC/LESSONS.md"
printf '501\n' > "$BDR/lesson-bands/MacThree"
bd_full_rc=0
out_bdfull="$(SYNC_HOSTNAME=MacThree SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDC" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)" || bd_full_rc=$?
check "#44 a full band refuses instead of spilling into another Mac's" "[ \"\$bd_full_rc\" -ne 0 ]"
check "#44 and says which band ran out"                               "printf '%s' \"\$out_bdfull\" | grep -q '501'"
# Two Macs that claimed the same band while unable to see each other. There is nobody to arbitrate,
# so the rule has to give the same answer wherever it runs: the lower name keeps the band. Which
# Mac that is does not matter; that both agree without talking does.
rm -f "$BDR/lesson-bands/MacThree"            # the full-band fixture above, not part of this one
printf '501\n' > "$BDR/lesson-bands/MacTwo"   # restore, then hand a later-named Mac the same band
printf '501\n' > "$BDR/lesson-bands/MacZulu"
printf -- '- **L1. one.** body\n' > "$BDC/LESSONS.md"
# The Mac that KEEPS it runs first, and must not move: a rule that moved whichever Mac happened to
# run next would walk both of them up the bands for ever.
out_bdkeep="$(SYNC_HOSTNAME=MacTwo SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDB" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
check "#44 the Mac whose name sorts first keeps the band" \
  "[ \"\$(cat '$BDR/lesson-bands/MacTwo' 2>/dev/null)\" = '501' ]"
check "#44 and is told nothing, because nothing changed for it" \
  "! printf '%s' \"\$out_bdkeep\" | grep -qi 'moved'"
out_bdcol="$(SYNC_HOSTNAME=MacZulu SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDC" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
dbg "collided band: $out_bdcol"
check "#44 the other one moves to a free band" \
  "[ \"\$(cat '$BDR/lesson-bands/MacZulu' 2>/dev/null)\" -gt 501 ]"
check "#44 and it does not take a band anyone else holds" \
  "[ \"\$(cat '$BDR/lesson-bands/MacZulu' 2>/dev/null)\" != \"\$(cat '$BDR/lesson-bands/MacTwo' 2>/dev/null)\" ] && [ \"\$(cat '$BDR/lesson-bands/MacZulu' 2>/dev/null)\" != \"\$(cat '$BDR/lesson-bands/MacOne' 2>/dev/null)\" ]"
check "#44 the move is reported, not silent" \
  "printf '%s' \"\$out_bdcol\" | grep -qi 'moved to 1001 to 1500'"
check "#44 and it mints from the band it moved to" \
  "printf '%s' \"\$out_bdcol\" | grep -q \"L\$(cat '$BDR/lesson-bands/MacZulu')\""
# Settled for good: asking again neither moves it nor reports anything.
out_bdcol2="$(SYNC_HOSTNAME=MacZulu SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDC" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)"
check "#44 a settled collision stays settled" \
  "! printf '%s' \"\$out_bdcol2\" | grep -qi 'moved'"
# A band file that holds no number is not the same as having none: read as absent it would hand
# this Mac the whole range again, which is the collision the mechanism exists to prevent, and the
# only sign would be a number that happened to be taken (L50).
printf 'not a number\n' > "$BDR/lesson-bands/MacFive"
bd_junk_rc=0
out_bdjunk="$(SYNC_HOSTNAME=MacFive SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDA" SYNC_REPO="$BDR" bash "$SCRIPT" next-lesson 2>&1)" || bd_junk_rc=$?
check "#44 a band file with no number in it refuses"  "[ \"\$bd_junk_rc\" -ne 0 ]"
check "#44 and names the file to fix"                 "printf '%s' \"\$out_bdjunk\" | grep -q 'lesson-bands/MacFive holds no number'"
check "#44 and does not mint a number anyway"         "! printf '%s' \"\$out_bdjunk\" | grep -qE '^L[0-9]+$'"
rm -f "$BDR/lesson-bands/MacFive"

# A band is worth nothing to the other Mac until it can see it, and only a commit carries it.
BDG="$WORK/band-git"; git init -q -b main "$BDG" 2>/dev/null || { mkdir -p "$BDG"; git -C "$BDG" init -q; }
mkdir -p "$BDG/payload"; printf 'seed\n' > "$BDG/payload/seed.txt"
git -C "$BDG" add -A && git -C "$BDG" -c user.name=t -c user.email=t@e commit -q -m seed
SYNC_HOSTNAME=MacFour SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BDA" SYNC_REPO="$BDG" bash "$SCRIPT" next-lesson >/dev/null 2>&1
check "#44 a claim is committed, so it reaches the other Mac" \
  "git -C '$BDG' log --oneline -- lesson-bands | grep -q ."
check "#44 and the working tree is left clean" \
  "[ -z \"\$(git -C '$BDG' status --porcelain lesson-bands 2>/dev/null)\" ]"
section "== a skills entry that cannot load is not carried between Macs (#50) =="
# payload/skills/humanizer/ and payload/skills/stop-slop/ hold no SKILL.md, so nothing can ever
# load them, and two loose markdown files sat directly under skills/ where nothing reads them.
# All four synced between both Macs indefinitely with nothing reporting that they are inert: a
# skill that cannot load is indistinguishable from one that works until somebody invokes it.
BSH="$WORK/badskill-home"; BSR="$WORK/badskill-repo"
mkdir -p "$BSH/skills/good" "$BSH/skills/nofm" "$BSH/skills/empty" "$BSR/payload"
echo '{"hooks":{}}' > "$BSH/settings.json"
printf '# rules\n' > "$BSH/CLAUDE.md"
printf -- '---\nname: good\ndescription: a skill that can actually load\n---\nbody\n' > "$BSH/skills/good/SKILL.md"
printf -- '---\nname: nofm\n---\nno description in the frontmatter\n' > "$BSH/skills/nofm/SKILL.md"
printf 'loose markdown, not a skill\n' > "$BSH/skills/design-notes.md"
# A body line that looks like frontmatter. The frontmatter is a block at the top of the file, so a
# check that greps the whole file is answered by prose about the thing (L103, L135).
mkdir -p "$BSH/skills/bodyonly"
printf 'This skill has no frontmatter at all.\nname: bodyonly\ndescription: written in the body\n' > "$BSH/skills/bodyonly/SKILL.md"
out_bs="$(CLAUDE_HOME="$BSH" SYNC_REPO="$BSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
dbg "push with unloadable skills: $out_bs"
check "#50 a skill that can load is still sent"        "[ -f '$BSR/payload/skills/good/SKILL.md' ]"
check "#50 a directory with no SKILL.md is not sent"   "[ ! -e '$BSR/payload/skills/empty' ]"
check "#50 a bare file under skills/ is not sent"      "[ ! -e '$BSR/payload/skills/design-notes.md' ]"
check "#50 a SKILL.md with no description is not sent" "[ ! -e '$BSR/payload/skills/nofm' ]"
check "#50 frontmatter written in the body does not count" "[ ! -e '$BSR/payload/skills/bodyonly' ]"
# Named WITH the reason on one line: "four skills were skipped" sends nobody anywhere, and two
# separate greps over a push report that lists paths anyway prove nothing (L172, #55).
check "#50 the push names the empty directory and why"  "printf '%s' \"\$out_bs\" | grep -qE 'empty.*SKILL\.md'"
check "#50 the push names the loose file and why"       "printf '%s' \"\$out_bs\" | grep -qE 'design-notes\.md.*(not a skill|bare file)'"
check "#50 the push names the one missing a description" "printf '%s' \"\$out_bs\" | grep -qE 'nofm.*description'"
# Silence when everything can load, or the warning becomes furniture and stops being read.
BS2="$WORK/badskill-home2"; BSR2="$WORK/badskill-repo2"
mkdir -p "$BS2/skills/good" "$BSR2/payload"
echo '{"hooks":{}}' > "$BS2/settings.json"; printf '# rules\n' > "$BS2/CLAUDE.md"
printf -- '---\nname: good\ndescription: a skill that can actually load\n---\nbody\n' > "$BS2/skills/good/SKILL.md"
out_bsok="$(CLAUDE_HOME="$BS2" SYNC_REPO="$BSR2" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#50 a clean push says nothing about skills that cannot load" \
  "! printf '%s' \"\$out_bsok\" | grep -qi 'cannot load'"
# The other direction: junk already in the payload (all four of these have been syncing for
# months) must not be written onto this Mac either, and the pull has to say so.
BSD="$WORK/badskill-dest"; mkdir -p "$BSD"
echo '{"hooks":{}}' > "$BSD/settings.json"
mkdir -p "$BSR2/payload/skills/humanizer" "$BSR2/payload/skills/loose"
printf 'not a skill\n' > "$BSR2/payload/skills/stop-slop.md"
printf 'a directory holding no SKILL.md\n' > "$BSR2/payload/skills/humanizer/notes.md"
printf -- '---\nname: loose\ndescription: this one loads\n---\nbody\n' > "$BSR2/payload/skills/loose/SKILL.md"
out_bspull="$(CLAUDE_HOME="$BSD" SYNC_REPO="$BSR2" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with unloadable skills: $out_bspull"
check "#50 a skill that can load still arrives"      "[ -f '$BSD/skills/loose/SKILL.md' ]"
check "#50 a directory with no SKILL.md is not applied" "[ ! -e '$BSD/skills/humanizer' ]"
check "#50 a bare file in the payload is not applied"   "[ ! -e '$BSD/skills/stop-slop.md' ]"
check "#50 the pull names what it refused, and why"     "printf '%s' \"\$out_bspull\" | grep -qE 'humanizer.*SKILL\.md'"

section "== an empty skills folder in the payload is cleared, not reported for ever (#62) =="
# stop-slop/ and humanizer/ arrived in the payload as directories holding no files at all: both are
# git clones whose working trees are empty, and .git never syncs. Every pull on every Mac then
# printed a refusal line for each of them, which trains the reader to skim past exactly the warning
# that matters when a real skill breaks (L36). Git cannot carry the deletion of an empty directory,
# so hand-deleting it on one Mac leaves the other reporting it for ever.
#
# An entry that holds NO FILES has nothing to lose, so the payload copy is removed and the reports
# stop. An entry that holds files is refused and LEFT ALONE, however unloadable it is: refusing to
# carry something is not a reason to destroy it (L5).
EMH="$WORK/emptyskill-home"; EMR="$WORK/emptyskill-repo"
mkdir -p "$EMH/skills" "$EMR/payload/skills/hollow" "$EMR/payload/skills/haswork" "$EMR/payload/skills/fine"
echo '{"hooks":{}}' > "$EMH/settings.json"
printf 'notes nobody can load, but they are somebody work\n' > "$EMR/payload/skills/haswork/notes.md"
mkskill "$EMR/payload/skills/fine/SKILL.md" 'a skill that loads'
out_em="$(CLAUDE_HOME="$EMH" SYNC_REPO="$EMR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with an empty payload skill: $out_em"
check "#62 the empty folder is named once, with the reason" \
  "printf '%s' \"\$out_em\" | grep -qE 'hollow.*SKILL\.md'"
check "#62 and it is gone from the payload"        "[ ! -d '$EMR/payload/skills/hollow' ]"
check "#62 a folder holding files is refused, never deleted" \
  "[ -f '$EMR/payload/skills/haswork/notes.md' ]"
check "#62 and that one is still named"            "printf '%s' \"\$out_em\" | grep -qE 'haswork.*SKILL\.md'"
check "#62 a skill that loads is untouched"        "[ -f '$EMH/skills/fine/SKILL.md' ]"
# The point of clearing it: the next pull is quiet about it, so the warning that remains means
# something.
out_em2="$(CLAUDE_HOME="$EMH" SYNC_REPO="$EMR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
check "#62 the next pull says nothing about the empty one" \
  "! printf '%s' \"\$out_em2\" | grep -q 'hollow'"
check "#62 and still reports the one holding files"  "printf '%s' \"\$out_em2\" | grep -q 'skills/haswork: the directory holds no SKILL\.md'"
# The mirror runs with --delete, so an entry the payload does not carry is deleted from this Mac
# unless something protects it. Refusing to carry a half-built or broken skill folder therefore
# became "delete it from the other Mac" the moment that Mac pulled, which is the shape L5 is about,
# and the second pull is where it bit: the first one still had the payload copy to derive the
# protection from.
mkdir -p "$EMH/skills/half-built"
printf 'a draft nobody can load yet, but it is somebody work\n' > "$EMH/skills/half-built/notes.md"
CLAUDE_HOME="$EMH" SYNC_REPO="$EMR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
CLAUDE_HOME="$EMH" SYNC_REPO="$EMR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#62 a half-built skill here survives repeated pulls" "[ -f '$EMH/skills/half-built/notes.md' ]"
check "#62 and is still not carried to the other Mac"       "[ ! -e '$EMR/payload/skills/half-built' ]"

# Never in the home direction. A person's own half-built skill folder is theirs, and the sync has no
# business deleting it because it cannot carry it yet.
mkdir -p "$EMH/skills/mine-in-progress"
CLAUDE_HOME="$EMH" SYNC_REPO="$EMR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
check "#62 an empty folder on this Mac is left where it is" "[ -d '$EMH/skills/mine-in-progress' ]"
check "#62 and is still not sent"                           "[ ! -d '$EMR/payload/skills/mine-in-progress' ]"

section "== a skill provided by both a plugin and the local folder is caught (#49) =="
# Nine Cloudflare skills existed as byte identical copies in ~/.claude/skills/ AND inside the
# cloudflare plugin, so each was listed twice in every session and both copies were paid for.
# Nothing detected it: it was found by hand while auditing, and nothing would have caught the next
# one, which matters because installing any plugin can silently shadow a local skill of the same
# name (#49).
DSH="$WORK/dupskill-home"; DSR="$WORK/dupskill-repo"
mkdir -p "$DSH/skills/wrangler" "$DSH/skills/mine" "$DSR/payload"
echo '{"hooks":{}}' > "$DSH/settings.json"; printf '# rules\n' > "$DSH/CLAUDE.md"
mkskill "$DSH/skills/wrangler/SKILL.md" 'a local copy of a skill the plugin also provides'
mkskill "$DSH/skills/mine/SKILL.md" 'a skill only this Mac has'
# A plugin laid out the way the real ones are: installed_plugins.json names an install path, and
# the skills sit under it. Derived from the install record rather than from a list kept by hand,
# or the check only covers the plugins somebody remembered (L96).
DSP="$DSH/plugins/cache/cloudflare/cloudflare/1.0.0"
mkdir -p "$DSP/skills/wrangler" "$DSP/skills/durable-objects" "$DSH/plugins"
mkskill "$DSP/skills/wrangler/SKILL.md" 'the plugin version'
mkskill "$DSP/skills/durable-objects/SKILL.md" 'a plugin skill with no local twin'
cat > "$DSH/plugins/installed_plugins.json" <<PLUGJSON
{"version":2,"plugins":{"cloudflare@cloudflare":[{"scope":"user","installPath":"$DSP","version":"1.0.0"}]}}
PLUGJSON
ds_rc=0
out_ds="$(CLAUDE_HOME="$DSH" SYNC_REPO="$DSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" check-skills 2>&1)" || ds_rc=$?
dbg "check-skills: $out_ds"
check "#49 a name held by both a plugin and the skills folder fails the check" "[ \"\$ds_rc\" -ne 0 ]"
# One line carrying the skill AND the plugin providing it, or the report names a duplicate without
# saying which of the seven plugins to look in (L172).
check "#49 and names the skill and the plugin together" \
  "printf '%s' \"\$out_ds\" | grep -qE 'wrangler.*cloudflare'"
check "#49 a skill only this Mac has is not reported"     "! printf '%s' \"\$out_ds\" | grep -q 'mine'"
check "#49 a plugin skill with no local twin is not reported" "! printf '%s' \"\$out_ds\" | grep -q 'durable-objects'"
# The payload half: a plugin installed later can shadow a skill that syncs between the Macs, and
# that copy is on the other Mac too.
mkdir -p "$DSR/payload/skills/durable-objects"
mkskill "$DSR/payload/skills/durable-objects/SKILL.md" 'a synced skill a plugin now also provides'
out_ds2="$(CLAUDE_HOME="$DSH" SYNC_REPO="$DSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" check-skills 2>&1 || true)"
check "#49 a synced skill shadowed by a plugin is caught too" \
  "printf '%s' \"\$out_ds2\" | grep -qE 'durable-objects.*cloudflare'"
# Nothing to report must be a PASS that says so, not a silent zero: a check that prints nothing
# when it found nothing reads exactly like one that could not look (L98).
rm -rf "$DSH/skills/wrangler" "$DSR/payload/skills/durable-objects"
ds_ok_rc=0
out_dsok="$(CLAUDE_HOME="$DSH" SYNC_REPO="$DSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" check-skills 2>&1)" || ds_ok_rc=$?
check "#49 a clean config passes"                  "[ \"\$ds_ok_rc\" -eq 0 ]"
check "#49 and says how many plugin skills it read" "printf '%s' \"\$out_dsok\" | grep -qE '2 (plugin )?skill'"
# A Mac with no plugins at all cannot answer this question, and must say so rather than passing:
# zero plugin skills read is not the same as no duplicates found.
DSN="$WORK/dupskill-none"; mkdir -p "$DSN/skills"; echo '{"hooks":{}}' > "$DSN/settings.json"
out_dsnone="$(CLAUDE_HOME="$DSN" SYNC_REPO="$DSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" check-skills 2>&1 || true)"
check "#49 no plugins at all is reported as nothing to compare against" \
  "printf '%s' \"\$out_dsnone\" | grep -qiE 'no plugin|nothing to compare'"
# And the standing report, so a duplicate that arrives with a plugin install surfaces without
# anybody thinking to run the check (L148).
mkdir -p "$DSH/skills/wrangler"; mkskill "$DSH/skills/wrangler/SKILL.md" 'back again'
out_dsstatus="$(CLAUDE_HOME="$DSH" SYNC_REPO="$DSR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#49 status reports a duplicate without being asked" \
  "printf '%s' \"\$out_dsstatus\" | grep -qE 'wrangler.*cloudflare'"

section "== assertions that could pass on output the command prints anyway (#55) =="
# Many checks capture a command's whole output and grep that blob for a phrase. claude-sync's own
# change report already names every file it applied, so an assertion looking for a filename finds
# it whether or not the behaviour under test works. A check written as two greps over the same blob
# is worse: each half can be satisfied by a different, unrelated line, and the conjunction reads as
# stricter than either (L135, L172).
#
# Seen live on 2026-08-17 while writing #43: both new assertions passed against completely
# unmodified code, because the pull's change report supplied the two paths and a pre-existing
# warning supplied the wording. They were caught only because the fix was expected to be needed and
# the green looked wrong.
#
# Derived from the suite itself, and started as a ratchet rather than a ban, because there were
# existing instances and some looked legitimate (a filename really does seem to be the whole point
# of "the error names the missing file"). Both halves are now at ZERO and both are bans: the six
# double greps were rewritten under #67, the twenty-one bare paths under #69.
#
# The "legitimate" ones turned out not to exist. Every single bare path assertion could say
# something stronger, because the report it was reading always carried the file name next to the
# FACT about it: not "added.sh" but "added.sh reported as a new file", not "GONE.md" but "GONE.md
# is referenced and not on this Mac". The exemption marker the issue expected to need was never
# written, since nothing needed exempting.
#
# Taking that half to zero is what forced #68. A count of zero is not read the way a count of six
# is: six invites somebody to look, zero is taken as proof the shape cannot occur here (L182). It
# could only ever have meant "none written the ONE way the scanner recognised", so the scanner now
# counts every form this suite has for feeding a captured variable to a matcher, and a zero is
# backed by a positive control that plants an instance in a copy of the file being scanned and
# requires the count to move. A dead scanner was measured passing the ceiling and failing only that
# control, which is precisely the state the ceiling alone cannot tell from a clean suite.
WEAK_AWK="$WORK/weak-assertions.awk"
cat > "$WEAK_AWK" <<'WEAKAWK'
# Counts, into seen[], every captured variable the given regex feeds to a matcher. The regex is
# passed as a STRING: an awk function cannot take a /regex/ constant as an argument, it would be
# evaluated against $0 first and arrive as 0 or 1.
function tally(c, restr,   rest, m, v, rs, rl) {
  rest = c
  while (match(rest, restr)) {
    # RSTART and RLENGTH are GLOBAL and the inner match below overwrites them, so the outer
    # match's position is saved first. Without this the loop never advances past its first hit
    # and every single matcher is counted as several, which reads as the defect it hunts for.
    rs = RSTART; rl = RLENGTH
    m = substr(rest, rs, rl)
    if (match(m, /\$[A-Za-z_][A-Za-z0-9_]*/)) { v = substr(m, RSTART, RLENGTH); seen[v]++ }
    rest = substr(rest, rs + rl)
  }
}
# One logical check per line, continuations joined.
{
  line = $0
  while (sub(/\\$/, "", line) > 0) { if ((getline nxt) <= 0) break; sub(/^[[:space:]]+/, " ", nxt); line = line nxt }
  if (line !~ /^check "/) next
  total++
  name = line; sub(/^check "/, "", name); sub(/".*/, "", name)
  # The NAME is not part of the assertion, and one containing "! " would read as a negation.
  expr = line; sub(/^check "[^"]*"/, "", expr)

  # A: one captured output consumed by more than one POSITIVE matcher in one expression, counted
  # over EVERY form this suite has for feeding a captured variable to a matcher. A detector that
  # knows one spelling reports ZERO about all the others, and a zero is read as proof the shape
  # cannot occur rather than as a measurement of it (#68, L96, L182).
  delete seen
  ncl = split(expr, cl, /&&|\|\|/)
  for (ci = 1; ci <= ncl; ci++) {
    c = cl[ci]
    # A negated half is out of scope: an absence cannot be supplied by an unrelated line, so
    # "present AND not present" over one blob is sound rather than weak, and a ceiling of zero
    # that counted it would refuse a legitimate check. "!=" is not a negation, hence the space.
    if (c ~ /![[:space:]]/) continue
    tally(c, "\\$[A-Za-z_][A-Za-z0-9_]*\\\\?\"[[:space:]]*\\|")     # "$v" | grep, | awk, | wc
    tally(c, "<<<[[:space:]]*\\\\?\"?\\$[A-Za-z_][A-Za-z0-9_]*")      # grep ... <<< "$v"
    tally(c, "case[[:space:]]+\\\\?\"?\\$[A-Za-z_][A-Za-z0-9_]*")     # case "$v" in
    tally(c, "\\[\\[[[:space:]]+\\\\?\"?\\$[A-Za-z_][A-Za-z0-9_]*")   # [[ "$v" == * ]]
  }
  for (v in seen) if (seen[v] > 1) { ntwice++; print "twice\t" name "\t" v; break }

  # B: a POSITIVE assertion whose whole pattern is a path or a filename, matched against captured
  # output that lists paths anyway. A negated one is out of scope: there an over-broad pattern makes
  # the assertion stricter, not weaker.
  n = split(line, seg, /&&/)
  for (i = 1; i <= n; i++) {
    s = seg[i]
    if (s !~ /printf/ || s !~ /grep/) continue
    if (s ~ /![[:space:]]*printf/) continue
    if (match(s, /grep -[a-zA-Z]*q[a-zA-Z]*[[:space:]]+'[^']+'/) == 0) continue
    p = substr(s, RSTART, RLENGTH); sub(/^grep[^\047]*\047/, "", p); sub(/\047$/, "", p)
    if (p ~ /^[A-Za-z0-9_.\/\\-]+$/ && (p ~ /\// || p ~ /\.(sh|md|py|json|txt|js)$/)) {
      nbare++; print "bare\t" name "\t" p
      break
    }
  }

  # C: a POSITIVE assertion over captured output whose whole pattern is ONE BARE WORD. A command's
  # output carries ordinary words ("kept", "merged", "alert", "behind") for reasons that have
  # nothing to do with the behaviour under test, so the match is real and irrelevant, which is the
  # same illusion as the bare path family one pass up (#71, L135, L156, L178).
  #
  # Deliberately narrow, so it reports something a person can act on rather than a wall. It only
  # fires on an UNANCHORED pattern of nothing but letters and digits, matched against CAPTURED
  # OUTPUT: an anchored pattern (^PASS=) is precise, a regex is doing real work, and the same word
  # grepped from a FILE the fixture wrote is a planted sentinel that can only have come from the
  # thing under test.
  #
  # There is deliberately NO length rule. It shipped with one (12 characters, on the theory that
  # short words are generic and long ones specific) and that number was never measured against the
  # real spread, which is the thing L172 warns about. Once the 40 were rewritten it was inert: no
  # single-word pattern of ANY length was left, so the cap could not remove a finding, it could
  # only let a future one through. Length is not what makes a word generic anyway.
  nc = split(expr, segc, /&&/)
  for (ic = 1; ic <= nc; ic++) {
    sc = segc[ic]
    if (sc !~ /printf/ || sc !~ /grep/) continue
    if (sc ~ /![[:space:]]*printf/) continue
    if (match(sc, /grep -[a-zA-Z]*q[a-zA-Z]*[[:space:]]+'[^']+'/) == 0) continue
    pc = substr(sc, RSTART, RLENGTH); sub(/^grep[^\047]*\047/, "", pc); sub(/\047$/, "", pc)
    if (pc ~ /^[A-Za-z][A-Za-z0-9]*$/) {
      nword++; print "word\t" name "\t" pc
      break
    }
  }
}
END { printf "totals\t%d\t%d\t%d\t%d\n", total, ntwice+0, nbare+0, nword+0 }
WEAKAWK
# Proven on a file built to contain one of each, because a scanner run only over the real suite
# reports a number nobody can check, and a number is indistinguishable from a scanner that matched
# nothing at all (L1, L98).
WEAKFIX="$WORK/weak-fixture.sh"
# Every line is written with a leading @@ and the marker stripped on the way into the fixture, so
# none of them begins a line in THIS file: the scanner reads the suite as text, and a fixture
# written the obvious way is counted as that many more weak assertions in the very suite it is
# measuring. (It used to be a stack of nested printf calls, which was unreadable enough that
# nobody would add a case to it, and #68 needed four more.)
sed 's/^@@//' > "$WEAKFIX" <<'WEAKFIXTURE'
@@check "two greps over one blob"  "printf '%s' \"$out_x\" | grep -q 'alpha-1' && printf '%s' \"$out_x\" | grep -q 'beta-1'"
@@check "a bare path in the output"  "printf '%s' \"$out_y\" | grep -q 'hooks/thing.sh'"
@@check "a negated bare path is fine"  "! printf '%s' \"$out_z\" | grep -q 'hooks/thing.sh'"
@@check "one line carrying both"  "printf '%s' \"$out_w\" | grep -q 'hooks/thing.sh also mentions L2'"
@@check "two herestrings over one blob"  "grep -q 'alpha-1' <<<\"$out_h\" && grep -q 'beta-1' <<<\"$out_h\""
@@check "a case and a grep over one blob"  "case \"$out_c\" in *alpha-1*) true ;; *) false ;; esac && printf '%s' \"$out_c\" | grep -q 'beta-1'"
@@check "two double brackets over one blob"  "[[ \"$out_b\" == *alpha-1* ]] && [[ \"$out_b\" == *beta-1* ]]"
@@check "a positive and a negated match is fine"  "printf '%s' \"$out_n\" | grep -q 'alpha-1' && ! printf '%s' \"$out_n\" | grep -q 'beta-1'"
@@check "a bare word in the output"  "printf '%s' \"$out_v\" | grep -q 'kept'"
@@check "a negated bare word is fine"  "! printf '%s' \"$out_v2\" | grep -q 'kept'"
@@check "a word with what it is about"  "printf '%s' \"$out_v3\" | grep -q 'kept your edit to push.py'"
@@check "an anchored pattern is fine"  "printf '%s' \"$out_v4\" | grep -q '^PASS='"
@@check "a long bare word in the output"  "printf '%s' \"$out_v5\" | grep -q 'unregistering'"
WEAKFIXTURE
weak_fix="$(awk -f "$WEAK_AWK" "$WEAKFIX")"
dbg "weak scanner on the fixture: $weak_fix"
check "#55 the scanner reads every check in a file" \
  "[ \"\$(printf '%s' \"\$weak_fix\" | awk -F'\t' '\$1==\"totals\"{print \$2}')\" = '13' ]"
check "#55 it flags two greps over one captured output" \
  "printf '%s' \"\$weak_fix\" | grep -q 'twice.*two greps over one blob'"
check "#55 it flags a bare path matched in captured output" \
  "printf '%s' \"\$weak_fix\" | grep -q 'bare.*a bare path in the output'"
check "#55 a negated bare path is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'a negated bare path is fine'"
check "#55 an assertion carrying the path and the wording together is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'one line carrying both'"
# #68: the same defect written the other ways this suite can write it. A detector that knows one
# spelling reports zero about the rest, and a zero is read as proof the shape cannot occur (L182).
check "#68 it flags two herestrings over one captured output" \
  "printf '%s' \"\$weak_fix\" | grep -q 'twice.*two herestrings over one blob'"
check "#68 it flags a case and a grep over one captured output" \
  "printf '%s' \"\$weak_fix\" | grep -q 'twice.*a case and a grep over one blob'"
check "#68 it flags two double brackets over one captured output" \
  "printf '%s' \"\$weak_fix\" | grep -q 'twice.*two double brackets over one blob'"
# A negated half cannot be supplied by an unrelated line, so "present AND not present" over one
# blob is sound. Banning it at a ceiling of zero would refuse a legitimate check.
check "#68 a positive paired with a negated match is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'a positive and a negated match is fine'"
# #71: the third family. One bare word, matched against a whole captured output.
check "#71 it flags an assertion matching one bare word" \
  "printf '%s' \"\$weak_fix\" | grep -q 'word.*a bare word in the output'"
check "#71 a negated bare word is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'a negated bare word is fine'"
check "#71 a word carrying what it is about is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'a word with what it is about'"
check "#71 an anchored pattern is not flagged" \
  "! printf '%s' \"\$weak_fix\" | grep -q 'an anchored pattern is fine'"
# Length is not what makes a word generic. The cap this pass shipped with (12 characters) was a
# guess nobody measured, and it was inert the moment the 40 were rewritten, so the only thing it
# could ever do was let a future one through (#71, L172: do not ship a threshold you have not
# measured against the real spread).
check "#71 a long bare word is flagged too" \
  "printf '%s' \"\$weak_fix\" | grep -q 'word.*a long bare word in the output'"
# Now the real suite. The ceilings were first measured on 2026-08-17 (581 checks, 6 and 22); #67
# rewrote all six of the double-grep checks and #69 all twenty-one of the bare path ones, so both
# are 0. From here either shape fails the suite. Raising either is a decision somebody has to write
# down here, and there is no longer a queue of existing instances to justify it.
#
# Zero is not a number that can drift: from here any check that consumes one captured blob with two
# positive matchers fails the suite, which is what stops the six coming back one at a time. A
# negated half does not count, because an absence cannot be supplied by an unrelated line, so
# "present AND not present" over one blob is sound and must stay writable.
weak_real="$(awk -f "$WEAK_AWK" "$SCRIPT_SELF")"
weak_total="$(printf '%s' "$weak_real" | awk -F'\t' '$1=="totals"{print $2}')"
weak_twice="$(printf '%s' "$weak_real" | awk -F'\t' '$1=="totals"{print $3}')"
weak_bare="$(printf '%s' "$weak_real" | awk -F'\t' '$1=="totals"{print $4}')"
weak_word="$(printf '%s' "$weak_real" | awk -F'\t' '$1=="totals"{print $5}')"
echo "  (#55 weak assertions in this suite: $weak_twice grep the same output twice, $weak_bare match only a path, $weak_word match one bare word, out of $weak_total checks)"
printf '%s\n' "$weak_real" | grep -E '^(twice|bare|word)' | sed 's/^/    /'
check "#55 the scan really read this suite" "[ \"\${weak_total:-0}\" -ge 500 ]"
check "#55 no check greps one captured output twice" "[ \"\${weak_twice:-999}\" -le 0 ]"
check "#55 no check matches only a bare path" "[ \"\${weak_bare:-999}\" -le 0 ]"
# The third family (#71) started as a ratchet at the 40 measured when the pass was added, not a
# ban, because some were expected to be legitimate. None were: all 40 were read, and every one of
# them could name what the word was ABOUT, so this is 0 and a ban like the other two.
check "#71 no check matches only one bare word" "[ \"\${weak_word:-999}\" -le 0 ]"
# A POSITIVE CONTROL on ALL THREE zeros (#68, extended by #69 and again by #71 as each half
# reached zero; the check keeps its #69 name so it stays findable in the history). The
# fixture proves the scanner on a file built for it; this proves it on the file actually being
# scanned, in the same invocation, by planting one instance of each in a copy and requiring both
# counts to move to exactly 1. Exactly 1, not at least 1, so it says two things at once: the scanner
# is alive here, and the real file really did contribute none of either.
# Without it a scanner broken by any later edit reports 0 and reads as a clean suite (L98, L171).
WEAKPOS="$WORK/weak-positive-control.sh"
cp "$SCRIPT_SELF" "$WEAKPOS"
sed 's/^@@//' >> "$WEAKPOS" <<'WEAKPLANT'
@@check "planted: two greps over one blob"  "printf '%s' \"$out_p\" | grep -q 'alpha-1' && printf '%s' \"$out_p\" | grep -q 'beta-1'"
@@check "planted: a bare path in the output"  "printf '%s' \"$out_q\" | grep -q 'hooks/planted.sh'"
@@check "planted: one bare word in the output"  "printf '%s' \"$out_r\" | grep -q 'planted'"
WEAKPLANT
weak_pos="$(awk -f "$WEAK_AWK" "$WEAKPOS" | awk -F'\t' '$1=="totals"{print $3 " " $4 " " $5}')"
dbg "positive control on the real suite: planted 1 of each, scanner reports ${weak_pos:-<nothing>}"
check "#69 both zeros are live measurements, not a dead scanner" \
  "[ \"\${weak_pos:-x}\" = '1 1 1' ]"
rm -f "$WEAKPOS"

section "== every check names itself uniquely (#70) =="
# The runner prints the name and the expression on failure, and nothing else, so two checks sharing
# a name leave the reader searching the file to find out which scenario actually broke. That is the
# same defect this suite guards against everywhere else: a report that does not name which of
# several things it is about (L154, L11). Two names were used twice, one in the pull-must-not-revert
# pair, where the two scenarios differ only in whether the unsent edit was a script or a lesson.
#
# Derived from the suite text rather than maintained by hand, because a hand-kept list of known
# names is exempt from the very check it is supposed to drive (L96, L41).
DUPFIX="$WORK/dupname-fixture.sh"
# Same @@ marker as the #55 fixture, so none of these begins a line in THIS file and gets counted
# as a real check name by the scan two sections up.
sed 's/^@@//' > "$DUPFIX" <<'DUPFIXTURE'
@@check "alpha"  "true"
@@check "beta"   "true"
@@check "alpha"  "true"
DUPFIXTURE
dup_names(){ grep -o '^check "[^"]*"' "$1" | sort | uniq -d; }
# Proven on a file built to hold one repeat and one unique name, because a scan run only over the
# real suite reports an empty answer nobody can check, and empty is indistinguishable from a scan
# that matched nothing at all (L1, L98).
dup_fix="$(dup_names "$DUPFIX")"
dbg "duplicate-name scan on the fixture: $dup_fix"
check "#70 the scan finds a name used twice" \
  "printf '%s' \"\$dup_fix\" | grep -q 'check \"alpha\"'"
check "#70 and leaves a name used once alone" \
  "! printf '%s' \"\$dup_fix\" | grep -q 'beta'"
dup_real="$(dup_names "$SCRIPT_SELF")"
if [ -n "$dup_real" ]; then
  echo "  (#70 check names used more than once in this suite:)"
  printf '%s\n' "$dup_real" | sed 's/^/    /'
fi
check "#70 no check name is used twice in this suite" "[ -z \"\$dup_real\" ]"

section "== every setting named in a comment or the README exists (#73) =="
# This file documented a knob called section_filter (written lowercase here on purpose, see below)
# as running only the sections whose heading matched. It was implemented nowhere, and the knob that
# does exist (SECTION_UNTIL) deliberately does something different, for the reason written next to
# it: the sections build on each other, so running one alone produced 24 failures the code did not
# cause. The comment therefore named a setting that did not exist AND promised behaviour that had
# been considered and rejected.
#
# Lowercase because this scan reads UPPERCASE names, and a comment explaining the ban cannot spell
# the banned name without tripping it. That is the guard working, not a hole in it: it cannot tell
# the line describing the dead knob from the line promising it. Same trick as the style hook, where
# a rule about a forbidden character writes it as an escape rather than reaching for an override.
#
# It cost real time on 2026-08-17, used twice while working #67, producing a full run each time,
# with the results misread before anyone noticed. Deleting that one line is the instance; this is
# the class (L30, L32): a name that appears in prose and never in code fails the suite.
#
# Derived from the files themselves rather than a hand-kept list of known settings, because a list
# of the ones somebody remembered is exempt from the very check meant to catch the forgotten one
# (L96, L41).
mentioned_settings(){   # $1 = a shell file, comments only   $2 = optional prose file, all of it
  { grep -o '#.*' "$1"; [ -n "${2:-}" ] && cat "$2"; true; } \
    | grep -oE '(SUITE|SECTION)_[A-Z][A-Z0-9_]*' | sort -u
}
used_settings(){        # $@ = files whose NON-comment text counts as a real reference
  for _us_f in "$@"; do sed 's/#.*//' "$_us_f"; done \
    | grep -oE '(SUITE|SECTION)_[A-Z][A-Z0-9_]*' | sort -u
}
# Proven on a pair built to hold one real name and one invented one, because a comparison run only
# over the real files reports an empty answer nobody can check, and empty is indistinguishable from
# a scan that read nothing (L1, L98). The invented name is ASSEMBLED at runtime so the token never
# appears whole in this file: written out plainly it would be a comment naming a setting that does
# not exist, which is the exact thing being banned, and the guard would fail on itself.
_fake_setting="SUITE""_NOSUCHKNOB"
SETC="$WORK/settings-prose.txt"; SETK="$WORK/settings-code.sh"
printf '# %s and %s are both mentioned here\n' "$_fake_setting" "SECTION_UNTIL" > "$SETC"
printf '%s=1\n' "SECTION_UNTIL" > "$SETK"
set_fix="$(comm -23 <(mentioned_settings "$SETC") <(used_settings "$SETK"))"
dbg "setting-name scan on the fixture: $set_fix"
check "#73 the scan reports a name that only prose mentions" \
  "printf '%s' \"\$set_fix\" | grep -q \"\$_fake_setting\""
check "#73 and leaves a name the code really uses alone" \
  "! printf '%s' \"\$set_fix\" | grep -q 'SECTION_UNTIL'"
# Now the real files. The workflow counts as code: it is where several SUITE_* knobs are actually
# set, and treating it as prose would report every one of them as invented.
_repo_root="$(cd "$(dirname "$SCRIPT")" && pwd)"
_readme="$_repo_root/README.md"; _wf="$_repo_root/.github/workflows/tests.yml"
# Or the comparison silently has nothing on one side and passes by reading nothing (L98).
check "#73 the files this scan reads are all present" \
  "[ -f '$_readme' ] && [ -f '$_wf' ] && [ -f \"\$SCRIPT_SELF\" ] && [ -f \"\$SCRIPT\" ]"
set_missing="$(comm -23 <(mentioned_settings "$SCRIPT_SELF" "$_readme") <(used_settings "$SCRIPT_SELF" "$SCRIPT" "$_wf"))"
if [ -n "$set_missing" ]; then
  echo "  (#73 settings named in a comment or the README but never referenced by code:)"
  printf '%s\n' "$set_missing" | sed 's/^/    /'
fi
check "#73 every setting named in prose is referenced by code" "[ -z \"\$set_missing\" ]"

section "== one renderer turns a length of time into words (#77) =="
# The tool said how long ago something happened in four different ways: raw minutes in the outage
# message, raw whole days in the conflict copy list and again in the timer message, and plain words
# in the status header. The same span then read differently depending which part of the output you
# were in, and two of them produced sentences nobody can act on ("failing for 0 minutes", a copy
# made this morning reported as zero days). Derived rather than trusted, because a rule that only
# lives in a comment is a hope (L27, L30).
_dur_inline="$(awk '/^duration_in_words\(\)/{inh=1} inh && /^}/{inh=0; next} !inh && /\$\(\([^)]*\/ *(60|3600|86400|604800|2592000)/ {printf "%d:%s\n", NR, $0}' "$SCRIPT")"
if [ -n "$_dur_inline" ]; then
  echo "  (#77 places still turning seconds into a duration by hand:)"
  printf '%s\n' "$_dur_inline" | sed 's/^/    /'
fi
check "#77 nothing renders a duration by hand any more" "[ -z \"\$_dur_inline\" ]"
# And the scan must be able to SEE such a line, or the emptiness above is the scan reading nothing
# rather than the code being clean (L98, L1).
_dur_fixture="$WORK/duration-probe.sh"
printf 'echo "every $((interval/86400)) days"\n' > "$_dur_fixture"
check "#77 the scan does find one when there is one" \
  "[ -n \"\$(awk '/^duration_in_words\(\)/{inh=1} inh && /^}/{inh=0; next} !inh && /\\\$\\(\\([^)]*\/ *(60|3600|86400|604800|2592000)/ {print}' '$_dur_fixture')\" ]"

section "== one helper for the one-line assertion form (#74) =="
# #67, #69 and #71 rewrote 67 assertions and the scan holds all three weak shapes at zero. That is
# detection after the fact. Sixty-seven accumulated because the correct form is MORE typing than the
# weak one, so the weak one is what gets written. This flips that: line_has says "one line of this
# output carries all of these", which is the thing the three families each failed to do.
#
# It takes TWO patterns at minimum and refuses fewer, deliberately. A one-fact assertion does not
# need it, and allowing one would make the helper a hole straight through the scan: the scan reads
# printf-and-grep segments, so a single weak pattern hidden behind a helper call would be invisible
# and the two ceilings at zero would quietly stop meaning anything (L96, L182).
_lh_split="alpha here
beta there"
_lh_one="alpha and beta on one line"
check "#74 it accepts two facts on one line"          "line_has \"\$_lh_one\" 'alpha' 'beta'"
check "#74 it REFUSES two facts on different lines"   "! line_has \"\$_lh_split\" 'alpha' 'beta'"
check "#74 it refuses a fact that is absent"          "! line_has \"\$_lh_one\" 'alpha' 'gamma'"
check "#74 it takes an extended regex"                "line_has \"\$_lh_one\" '^alpha' 'on one line$'"
check "#74 and an anchor that does NOT hold is refused" \
  "! line_has \"\$_lh_one\" '^alpha' 'beta$'"
check "#74 it refuses one pattern, which is the weak form" \
  "! line_has \"\$_lh_one\" 'alpha'"
check "#74 it refuses no pattern at all"              "! line_has \"\$_lh_one\""
check "#74 it refuses empty output rather than passing vacuously" \
  "! line_has '' 'alpha' 'beta'"

section "== status says when this Mac last sent and last received (#75) =="
# status listed pending files with no way to tell whether the other Mac had been waiting on them
# for an hour or three weeks. Silent drift between the two Macs is the failure mode this tool
# exists to prevent, and status is the only place anybody would notice it, so a pending list that
# reads identically fresh or months old is the report failing at its one job (L148).
#
# The stamps mean "the last time something actually MOVED", not "the last time we looked". A stamp
# that advanced on every run would make a Mac that syncs hourly with nothing to do look permanently
# healthy, which is the exact reassurance that hides the drift (L106, L98).
STBARE="$WORK/stbare.git"; git init -q --bare -b main "$STBARE"
STA="$WORK/strepoA"; git clone -q "$STBARE" "$STA" 2>/dev/null
STAH="$WORK/sthomeA"; mkdir -p "$STAH/hooks"; echo '{"hooks":{}}' > "$STAH/settings.json"
echo 'v1' > "$STAH/hooks/st.sh"
STB="$WORK/strepoB"; STBH="$WORK/sthomeB"

# Nothing has happened yet on this clone, so both answers are "never", and never must not be
# dressed up as a date (L67).
out_st0="$(CLAUDE_HOME="$STAH" SYNC_REPO="$STA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#75 a clone that has never sent says so" \
  "line_has \"\$out_st0\" 'last sent' 'never'"
check "#75 a clone that has never received says so" \
  "line_has \"\$out_st0\" 'last received' 'never'"

# A send that actually publishes stamps the sent time.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$STAH" SYNC_REPO="$STA" bash "$SCRIPT" sync >/dev/null 2>&1
out_st1="$(CLAUDE_HOME="$STAH" SYNC_REPO="$STA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#75 a send that published stamps the sent time" \
  "! line_has \"\$out_st1\" 'last sent' 'never'"
check "#75 and the sent line carries an age in plain words" \
  "line_has \"\$out_st1\" 'last sent' '(just now|second|minute|hour|day|week|month)'"
check "#75 sending does not pretend anything was received" \
  "line_has \"\$out_st1\" 'last received' 'never'"

# The other Mac pulls: that one applies files, so its received time is stamped.
git clone -q "$STBARE" "$STB" 2>/dev/null
mkdir -p "$STBH"; echo '{"hooks":{}}' > "$STBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$STBH" SYNC_REPO="$STB" bash "$SCRIPT" pull >/dev/null 2>&1
out_st2="$(CLAUDE_HOME="$STBH" SYNC_REPO="$STB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#75 a pull that applied files stamps the received time" \
  "! line_has \"\$out_st2\" 'last received' 'never'"
check "#75 and that clone has still never sent" \
  "line_has \"\$out_st2\" 'last sent' 'never'"

# THE point of the feature: a pull with nothing to apply must NOT move the stamp, or a Mac that
# checks hourly and receives nothing reads as freshly in sync forever.
_st_before="$(cat "$STB/.last-received" 2>/dev/null || echo missing)"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$STBH" SYNC_REPO="$STB" bash "$SCRIPT" pull >/dev/null 2>&1
_st_after="$(cat "$STB/.last-received" 2>/dev/null || echo missing)"
check "#75 a pull that applied NOTHING leaves the received time alone" \
  "[ \"\$_st_before\" = \"\$_st_after\" ] && [ \"\$_st_before\" != missing ]"

# A stamp that cannot be read is its own state: reporting it as "never" would say this Mac has
# never sent, which is a different and wrong claim (L11).
printf 'not-a-timestamp\n' > "$STA/.last-sent"
out_st3="$(CLAUDE_HOME="$STAH" SYNC_REPO="$STA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#75 an unreadable stamp is not reported as never" \
  "! line_has \"\$out_st3\" 'last sent' 'never'"
check "#75 an unreadable stamp says it could not be read" \
  "line_has \"\$out_st3\" 'last sent' 'could not be read'"
check "#75 and status still exits cleanly on a corrupt stamp" \
  "CLAUDE_HOME='$STAH' SYNC_REPO='$STA' SYNC_NO_NOTIFY=1 bash '$SCRIPT' status >/dev/null 2>&1"

# #76: the third fact. Sent and received alone leave two very different situations reading the
# same. "Last sent three weeks ago, repo reachable throughout" means something is genuinely stuck
# and needs a person; "last sent three weeks ago, repo unreachable" is an outage already reported
# elsewhere. Without reachability the reader of a stale pending list cannot tell which (L11).
check "#76 a clone that has never reached the repo says so" \
  "line_has \"\$out_st0\" 'reachable' 'never'"
check "#76 status says when the repo was last reachable" \
  "! line_has \"\$out_st2\" 'reachable' 'never'"
# It moves on EVERY successful fetch, so it must not be read as config having crossed. The other
# two lines mean something moved; this one only means the door opened.
check "#76 and says plainly that reachable is not the same as moved" \
  "line_has \"\$out_st2\" 'reach' 'says nothing about whether anything crossed'"
printf 'not-a-timestamp\n' > "$STB/.last-success"
out_st4="$(CLAUDE_HOME="$STBH" SYNC_REPO="$STB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#76 an unreadable reachability stamp is not reported as never" \
  "! line_has \"\$out_st4\" 'reachable' 'never'"
check "#76 an unreadable reachability stamp says it could not be read" \
  "line_has \"\$out_st4\" 'reachable' 'could not be read'"

# The stamps are this Mac's own bookkeeping and must never travel, the way .last-applied does not.
check "#75 the stamps are not committed to the shared repo" \
  "! git -C '$STA' ls-files --error-unmatch .last-sent >/dev/null 2>&1 && ! git -C '$STA' ls-files --error-unmatch .last-received >/dev/null 2>&1"
# Asserted against the SHIPPED .gitignore rather than a fixture repo: the fixtures are bare repos
# built by the suite with no .gitignore at all, so every state file shows as untracked there and a
# check over one of them would be measuring the fixture, not the product.
_GI="$(dirname "$SCRIPT")/.gitignore"
check "#75 the shipped gitignore covers both stamps" \
  "grep -qx '\.last-sent' '$_GI' && grep -qx '\.last-received' '$_GI'"

section "== which plugins load is a per Mac setting, so status says what this Mac has (#48) =="
# Every plugin was enabled at user scope, so all seven loaded into every session in every project:
# roughly 7,700 tokens of Vercel, Figma and Stripe before any of it was used, plus a 53KB Vercel
# knowledge graph injected at session start in a directory with no code in it.
#
# The fix is per project enablement, and `enabledPlugins` lives in the part of settings.json that
# deliberately never syncs (model, effort and plugins stay private to each Mac). Carrying it would
# apply THIS Mac's project survey to a Mac holding different projects, which is the regression the
# issue warns about. So it stays per Mac and status SAYS SO, because two Macs quietly diverging with
# nothing able to report it is the failure mode that has to be visible (L148).
PGH="$WORK/plugins-home"; PGR="$WORK/plugins-repo"
mkdir -p "$PGH/skills" "$PGR/payload"
printf '# rules\n' > "$PGH/CLAUDE.md"
cat > "$PGH/settings.json" <<'PLUGSET'
{"hooks":{},"enabledPlugins":{"superpowers@superpowers-dev":true,"vercel-plugin@vercel-vercel-plugin":false,"cloudflare@cloudflare":true}}
PLUGSET
out_pg="$(CLAUDE_HOME="$PGH" SYNC_REPO="$PGR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "status with plugin settings: $out_pg"
check "#48 status names the plugins that load on this Mac" \
  "printf '%s' \"\$out_pg\" | grep -qE 'enabled.*(superpowers|cloudflare)'"
check "#48 and the ones that do not" \
  "printf '%s' \"\$out_pg\" | grep -qE 'off.*vercel-plugin|vercel-plugin.*off'"
check "#48 and says plainly that this is per Mac" \
  "printf '%s' \"\$out_pg\" | grep -qiE 'per Mac|this Mac only|never synced'"
# No setting at all is a real state with real consequences (every installed plugin loads
# everywhere), and it is the state this Mac was in. Saying nothing would report it as fine.
cat > "$PGH/settings.json" <<'PLUGSET2'
{"hooks":{}}
PLUGSET2
out_pg2="$(CLAUDE_HOME="$PGH" SYNC_REPO="$PGR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#48 a Mac with no plugin settings is told what that means" \
  "printf '%s' \"\$out_pg2\" | grep -qiE 'no plugin (enablement|settings)'"

section "== the lessons index is derived, and the full text is read on demand (#63) =="
# LESSONS.md is 179 entries and about 116 KB, imported in full into every session in every project.
# Each entry is written to be read closely, so the cost is attention as well as tokens. The session
# now loads an index (number, section, the rule sentence) and the full entry is read on demand.
#
# The index is DERIVED on every send and every apply, never maintained by hand beside the file it
# mirrors, or the two drift and the drift is silent (L41).
LXH="$WORK/lessonindex-home"; LXR="$WORK/lessonindex-repo"
mkdir -p "$LXH" "$LXR/payload"
echo '{"hooks":{}}' > "$LXH/settings.json"
printf '# rules\n@LESSONS-INDEX.md\n' > "$LXH/CLAUDE.md"
cat > "$LXH/LESSONS.md" <<'LESSONSEOF'
# Build-time lessons

## Proof over green

- **L1. A guard is only real once it has been seen to fail.** Mocked guards asserting their own
  mock sit green while protecting nothing.
  (someproject#11)
- **L2. A rule that wraps onto a second line is still one rule, so the whole sentence
  belongs in the index.** The body underneath it does not.
  (someproject#12)

## Data safety

- **L3. Never destroy good state before its replacement exists.** Write to temp and rename.
  (someproject#13)
LESSONSEOF
out_lx="$(CLAUDE_HOME="$LXH" SYNC_REPO="$LXR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
dbg "push with lessons: $out_lx"
check "#63 the index is written where the session loads it" "[ -f '$LXH/LESSONS-INDEX.md' ]"
check "#63 and it travels to the other Mac"                 "[ -f '$LXR/payload/LESSONS-INDEX.md' ]"
check "#63 every lesson has a line"        "[ \"\$(grep -c '^- L[0-9]' '$LXH/LESSONS-INDEX.md')\" = '3' ]"
check "#63 a rule that wraps is kept whole" "grep -q 'L2. A rule that wraps onto a second line is still one rule, so the whole sentence belongs in the index.' '$LXH/LESSONS-INDEX.md'"
check "#63 the sections are kept"           "grep -q 'Data safety' '$LXH/LESSONS-INDEX.md'"
check "#63 the bodies are left out"         "! grep -q 'Write to temp and rename' '$LXH/LESSONS-INDEX.md'"
check "#63 and so is the provenance"        "! grep -q 'someproject#13' '$LXH/LESSONS-INDEX.md'"
check "#63 the index says where the full text is" "grep -qi 'LESSONS.md' '$LXH/LESSONS-INDEX.md'"
# The whole file still syncs, even though CLAUDE.md no longer imports it. Losing that would be the
# worst outcome of this change: the index would be the only copy anywhere.
check "#63 the full lessons file still travels" "[ -f '$LXR/payload/LESSONS.md' ]"
check "#63 and the payload copy is the whole thing" "grep -q 'Write to temp and rename' '$LXR/payload/LESSONS.md'"
# Derived means derived: a hand-edited index is replaced, not trusted, and a new lesson appears
# without anybody touching the index.
printf 'this line was typed into the index by hand\n' >> "$LXH/LESSONS-INDEX.md"
printf -- '- **L4. A late lesson still reaches the index.** body\n  (someproject#14)\n' >> "$LXH/LESSONS.md"
CLAUDE_HOME="$LXH" SYNC_REPO="$LXR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
check "#63 a hand edit to the index is overwritten"  "! grep -q 'typed into the index by hand' '$LXH/LESSONS-INDEX.md'"
check "#63 a new lesson appears without touching it" "grep -q 'L4. A late lesson still reaches the index.' '$LXH/LESSONS-INDEX.md'"
# A no-op run must not rewrite it: CLAUDE.md and its imports are watched, and rewriting one on
# every sync re-triggers the watcher for ever.
lx_sum_before="$(cksum < "$LXH/LESSONS-INDEX.md")"
CLAUDE_HOME="$LXH" SYNC_REPO="$LXR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
check "#63 a second send leaves the index alone" "[ \"\$(cksum < '$LXH/LESSONS-INDEX.md')\" = \"\$lx_sum_before\" ]"
# Reading one in full, which is what the index sends you to.
out_lxl="$(CLAUDE_HOME="$LXH" SYNC_REPO="$LXR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" lesson L3 2>&1)"
dbg "lesson L3: $out_lxl"
check "#63 a lesson can be read in full on demand"   "printf '%s' \"\$out_lxl\" | grep -q 'Write to temp and rename'"
check "#63 with its provenance"                      "printf '%s' \"\$out_lxl\" | grep -q 'someproject#13'"
check "#63 and without the neighbouring entries"     "! printf '%s' \"\$out_lxl\" | grep -q 'Mocked guards'"
lx_miss_rc=0
out_lxmiss="$(CLAUDE_HOME="$LXH" SYNC_REPO="$LXR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" lesson L99 2>&1)" || lx_miss_rc=$?
check "#63 a number that is not there is refused"     "[ \"\$lx_miss_rc\" -ne 0 ]"
check "#63 rather than printing nothing and exiting 0" "printf '%s' \"\$out_lxmiss\" | grep -q 'L99 is not in'"

section "== a pull git refused must fail loudly, not report success (#78 #80 #81) =="
# `git pull --ff-only` ran with its exit status discarded, so a pull git ABORTED fell straight
# through to the reachability stamp, the apply and the closing "Pulled shared config onto this Mac"
# line. A Mac that received nothing because the pull FAILED then printed the same two sentences as
# a Mac with nothing to receive (L98, L184). Measured on 2026-08-18: seven commits behind, the pull
# aborted with "Not possible to fast-forward", and the session went on believing its rule files
# were current, which is the payload worst to be silently stale in.
#
# Three refusals, three messages, each proven here, because a single "the pull failed" names
# nothing anybody can act on (L11, L151): the repo could not be REACHED, the two Macs have
# DIVERGED, or git refused for a reason only git can describe.
unset SYNC_NO_GIT
DVB="$WORK/diverge-bare.git"; git init -q --bare "$DVB"
DVRA="$WORK/diverge-repoA"; git clone -q "$DVB" "$DVRA"
DVHA="$WORK/diverge-homeA"; mkdir -p "$DVHA/skills/dvfirst"
echo '{"model":"opus","hooks":{}}' > "$DVHA/settings.json"
mkskill "$DVHA/skills/dvfirst/SKILL.md" 'DIVERGE-FIRST'
CLAUDE_HOME="$DVHA" SYNC_REPO="$DVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
DVRB="$WORK/diverge-repoB"; git clone -q "$DVB" "$DVRB"
DVHB="$WORK/diverge-homeB"; mkdir -p "$DVHB"
echo '{"model":"opus","hooks":{}}' > "$DVHB/settings.json"
out_dvok="$(CLAUDE_HOME="$DVHB" SYNC_REPO="$DVRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "first pull into B: $out_dvok"
# The positive control, in the SAME fixture as the refusals below. Without it, every "did not
# arrive" and "did not say" assertion further down is satisfied by a fixture where a pull could
# never have worked at all (L159).
check "#81 the fixture can deliver a pull that works" "[ -f '$DVHB/skills/dvfirst/SKILL.md' ]"
check "#81 and that pull says so"  "line_has \"\$out_dvok\" 'Pulled shared config' 'memory/permissions'"

# The other Mac moves on, and this one holds a commit of its own that never went up. Different
# files on each side, so there is no content clash anywhere: the ONLY reason git refuses is that
# --ff-only cannot fast-forward, which is exactly the case that used to report success.
mkskill "$DVHA/skills/dvlater/SKILL.md" 'DIVERGE-LATER'
CLAUDE_HOME="$DVHA" SYNC_REPO="$DVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
mkdir -p "$DVRB/payload/agents"
printf 'an agent this Mac wrote and never sent\n' > "$DVRB/payload/agents/dvlocal.md"
git -C "$DVRB" add -A -- payload
git -C "$DVRB" -c user.name=suite -c user.email=suite@localhost commit -qm "local commit the repo has not seen"
rm -f "$DVRB/.last-success"
dv_rc=0
out_dv="$(CLAUDE_HOME="$DVHB" SYNC_REPO="$DVRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)" || dv_rc=$?
dbg "diverged pull: rc=$dv_rc $out_dv"
check "#78 a refused pull exits non zero"            "[ \"\$dv_rc\" -ne 0 ]"
check "#78 it does not claim to have pulled"         "! printf '%s' \"\$out_dv\" | grep -q 'Pulled shared config'"
check "#78 nor that there was nothing to receive"    "! printf '%s' \"\$out_dv\" | grep -q 'Already up to date'"
check "#81 nothing from the repo was applied"        "[ ! -e '$DVHB/skills/dvlater/SKILL.md' ]"
check "#80 the message names the divergence, both counts, and the command that resolves it" \
  "line_has \"\$out_dv\" 'diverged' '1 commit here' '[0-9]+ commits? there' 'claude-sync sync'"
# Reachability is a SEPARATE fact from whether the pull could be applied, and this run proved it
# by fetching. Suppressing the stamp here would make status report the repo as last reached days
# ago while it was reached seconds ago, which is a message claiming more than its check measured
# (L11). The outage clock is not what tells anybody about a divergence: the refusal above is.
check "#78 a refusal after a successful fetch still records the repo as reachable" \
  "[ -s '$DVRB/.last-success' ]"

# Unreachable: nothing was measured about divergence, so nothing may be claimed about it, and the
# reachability stamp must NOT be written by a run that never reached anything (#78).
DVRC="$WORK/diverge-repoC"; git clone -q "$DVB" "$DVRC"
DVHC="$WORK/diverge-homeC"; mkdir -p "$DVHC"
echo '{"model":"opus","hooks":{}}' > "$DVHC/settings.json"
git -C "$DVRC" remote set-url origin "$WORK/no-such-bare.git"
rm -f "$DVRC/.last-success"
dvoff_rc=0
out_dvoff="$(CLAUDE_HOME="$DVHC" SYNC_REPO="$DVRC" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)" || dvoff_rc=$?
dbg "unreachable pull: rc=$dvoff_rc $out_dvoff"
check "#78 a pull that cannot reach the repo exits non zero" "[ \"\$dvoff_rc\" -ne 0 ]"
check "#78 and does not claim to have pulled"                "! printf '%s' \"\$out_dvoff\" | grep -q 'Pulled shared config'"
check "#78 it records no reachability it did not observe"    "[ ! -s '$DVRC/.last-success' ]"
check "#78 and says the repo could not be reached, in git's words" \
  "line_has \"\$out_dvoff\" 'could not reach the shared repo' 'no-such-bare'"

# git's own refusal, neither of the two above. The catch-all has to be reachable and has to quote
# git, or a cause it cannot name is reported as one of the causes it can (#52 was exactly that).
DVRD="$WORK/diverge-repoD"; git clone -q "$DVB" "$DVRD"
DVHD="$WORK/diverge-homeD"; mkdir -p "$DVHD"
echo '{"model":"opus","hooks":{}}' > "$DVHD/settings.json"
mkskill "$DVHA/skills/dvfirst/SKILL.md" 'DIVERGE-FIRST-EDITED'
CLAUDE_HOME="$DVHA" SYNC_REPO="$DVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
printf 'an uncommitted edit inside the sync repo itself\n' >> "$DVRD/payload/skills/dvfirst/SKILL.md"
dvd_rc=0
out_dvd="$(CLAUDE_HOME="$DVHD" SYNC_REPO="$DVRD" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)" || dvd_rc=$?
dbg "refused pull (dirty repo): rc=$dvd_rc $out_dvd"
check "#78 a pull git refuses for its own reason exits non zero" "[ \"\$dvd_rc\" -ne 0 ]"
check "#78 that refusal does not claim to have pulled"           "! printf '%s' \"\$out_dvd\" | grep -q 'Pulled shared config'"
check "#78 it is not reported as a divergence"                   "! printf '%s' \"\$out_dvd\" | grep -q 'have diverged'"
check "#78 and it carries git's own words"                       "line_has \"\$out_dvd\" 'refused to fast-forward' 'local changes'"


section "== a send is stamped from what happened, not from which command ran (#79 #82) =="
# `record_sent` was called only from inside the two branches that themselves run a push, so a run
# that sent by any other route left `.last-sent` unwritten and status reported "last sent: never,
# nothing has gone up from this clone" over a branch provably level with origin. Measured on
# 2026-08-18: three commits pushed, `git ls-remote` confirming the remote head matched this Mac,
# and no stamp on disk. "Never sent" is also exactly what a genuinely wedged send looks like, so a
# real one-way outage was indistinguishable from this bookkeeping gap (L11, L98).
#
# The stamp is now decided by the finished state: this run was holding work to send, and by the
# end this clone holds nothing the repo does not have. `push` is deliberately the command under
# test, because it is one of the routes that never stamped.
unset SYNC_NO_GIT
STPB="$WORK/stamp-bare.git"; git init -q --bare "$STPB"
STPR="$WORK/stamp-repo"; git clone -q "$STPB" "$STPR"
STPH="$WORK/stamp-home"; mkdir -p "$STPH/skills/stampone"
echo '{"model":"opus","hooks":{}}' > "$STPH/settings.json"
mkskill "$STPH/skills/stampone/SKILL.md" 'STAMP-ONE'
CLAUDE_HOME="$STPH" SYNC_REPO="$STPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#79 the fixture's first sync stamps a send" "[ -s '$STPR/.last-sent' ]"
# Asked of the clone rather than assumed to be main. git's default branch name is still master
# where this runs, so a hardcoded name made every question below ask about a ref that does not
# exist: the positive control failed, and the last check PASSED on an error message rather than on
# a count (L156, L98). The tool itself derives the name the same way.
STPBR="$(git -C "$STPR" symbolic-ref --short HEAD 2>/dev/null || echo main)"
check "#79 the fixture's branch is known" "[ -n \"\$STPBR\" ]"

rm -f "$STPR/.last-sent"
mkskill "$STPH/skills/stamptwo/SKILL.md" 'STAMP-TWO'
out_stp="$(CLAUDE_HOME="$STPH" SYNC_REPO="$STPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
dbg "push: $out_stp"
stp_ahead="$(git -C "$STPR" rev-list --count "origin/$STPBR..HEAD" 2>/dev/null || echo unknown)"
stp_remote="$(git ls-remote "$STPB" "$STPBR" 2>/dev/null | awk '{print $1}')"
stp_head="$(git -C "$STPR" rev-parse HEAD 2>/dev/null)"
# The positive control, asked of the BARE repo rather than of this clone's own remote-tracking
# ref: that ref is written by the push itself, so believing it would only prove the push agrees
# with itself (L70). Without this, every stamp assertion below is satisfied by a fixture in which
# nothing was ever pushed at all (L159).
check "#79 the push really shipped this clone's commit" \
  "[ \"\$stp_ahead\" = '0' ] && [ -n \"\$stp_remote\" ] && [ \"\$stp_remote\" = \"\$stp_head\" ]"
check "#82 a push through a route that never stamped records the send" "[ -s '$STPR/.last-sent' ]"
stp_stamp="$(cat "$STPR/.last-sent" 2>/dev/null)"
stp_commit="$(git -C "$STPR" log -1 --format=%ct 2>/dev/null)"
stp_gap=$(( ${stp_stamp:-0} - ${stp_commit:-0} ))
[ "$stp_gap" -lt 0 ] && stp_gap=$(( 0 - stp_gap ))
dbg "stamp=$stp_stamp commit=$stp_commit gap=${stp_gap}s"
# Asserted against the commit that was pushed, not merely against "a file exists": a stamp left
# by the earlier sync would satisfy presence alone and say nothing about this run.
check "#82 and that stamp belongs to this push, not to an earlier one" "[ \"\$stp_gap\" -le 120 ]"

# A run that sent NOTHING must not stamp. Stamping on every run instead would make a Mac that
# syncs hourly with nothing to do look permanently fresh, which is the reassurance that hides a
# real stall (L106), and it is the opposite way of being wrong from the bug above.
rm -f "$STPR/.last-sent"
out_stpnoop="$(CLAUDE_HOME="$STPH" SYNC_REPO="$STPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
dbg "push with nothing to send: $out_stpnoop"
check "#79 a run with nothing to send records no send" "[ ! -e '$STPR/.last-sent' ]"
check "#79 and says there was nothing to send"        "line_has \"\$out_stpnoop\" 'Nothing changed' 'up to date'"

# A push that never reached the repo must not stamp either, and the commit it made must still be
# waiting. This is the failure the indicator exists to make visible, so it is the one case where a
# stamp would be actively misleading.
git -C "$STPR" remote set-url origin "$WORK/no-such-stamp-bare.git"
mkskill "$STPH/skills/stampthree/SKILL.md" 'STAMP-THREE'
rm -f "$STPR/.last-sent"
out_stpoff="$(CLAUDE_HOME="$STPH" SYNC_REPO="$STPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
dbg "push with an unreachable remote: $out_stpoff"
check "#82 a push that never reached the repo records no send" "[ ! -e '$STPR/.last-sent' ]"
stp_left="$(git -C "$STPR" rev-list --count "origin/$STPBR..HEAD" 2>/dev/null || echo unknown)"
# The count itself, not "anything other than zero": an unreadable ref answers with an error, and
# an error is not evidence that a commit is waiting (L50).
check "#82 and the commit it made is still unsent" "[ -n \"\$stp_left\" ] && [ \"\$stp_left\" -ge 1 ] 2>/dev/null"
section "== a generated index is never reported as a conflict (#83) =="
# LESSONS-INDEX.md is DERIVED from LESSONS.md and rebuilt on every send and every apply, and the
# code says so where it generates it. Conflict detection did not know that, so on 2026-08-18 a
# pull announced that both Macs had changed it, that it could NOT be merged, and that the local
# copy had been set aside. Nothing was at risk: the applied file was a strict superset of the
# preserved one, whose only unique line was a stale header count, and the apply regenerates the
# index from the merged lessons a few lines later regardless. That is a false alarm on the most
# safety critical message this tool prints, and false alarms are what teach a person to skim past
# a real one (L36). It also left a .conflict copy that status went on naming until it was deleted
# by hand.
unset SYNC_NO_GIT
IXB="$WORK/index-bare.git"; git init -q --bare "$IXB"
IXRA="$WORK/index-repoA"; git clone -q "$IXB" "$IXRA" 2>/dev/null
IXHA="$WORK/index-homeA"; mkdir -p "$IXHA"
echo '{"hooks":{}}' > "$IXHA/settings.json"
printf '# rules\n@LESSONS.md\n@LESSONS-INDEX.md\n' > "$IXHA/CLAUDE.md"
printf '# Lessons\n\n## Proof over green\n\n- **L1. one.** body one\n- **L2. two.** body two\n' > "$IXHA/LESSONS.md"
CLAUDE_HOME="$IXHA" SYNC_REPO="$IXRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#83 the index is generated and published" "[ -s '$IXRA/payload/LESSONS-INDEX.md' ]"

IXRB="$WORK/index-repoB"; git clone -q "$IXB" "$IXRB" 2>/dev/null
IXHB="$WORK/index-homeB"; mkdir -p "$IXHB"
echo '{"hooks":{}}' > "$IXHB/settings.json"
CLAUDE_HOME="$IXHB" SYNC_REPO="$IXRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#83 the other Mac receives lessons and index" \
  "grep -q 'L1. one' '$IXHB/LESSONS.md' && grep -q 'L1. one' '$IXHB/LESSONS-INDEX.md'"

# This Mac writes a lesson it has not sent. The apply regenerates the index from the LOCAL
# lessons file, so from here on this Mac's index legitimately differs from the repo's, which is
# the state the false alarm was made of.
# TWO of them, and one on the other side, so the generated header counts differ: 4 here, 3 there,
# 2 in the copy both were generated from. That header is a single line both sides rewrite, which
# is what makes the index unmergeable while the lessons underneath it merge perfectly well. With
# one lesson each the counts match, the header merges, and the false alarm never fires: the first
# version of this fixture made exactly that mistake and passed against the unfixed script (L1).
printf -- '- **L3. three.** written only on Mac B\n' >> "$IXHB/LESSONS.md"
printf -- '- **L5. five.** also written only on Mac B\n' >> "$IXHB/LESSONS.md"
CLAUDE_HOME="$IXHB" SYNC_REPO="$IXRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#83 this Mac's index carries its own unsent lessons" \
  "grep -q 'L3. three' '$IXHB/LESSONS-INDEX.md' && grep -q 'L5. five' '$IXHB/LESSONS-INDEX.md'"

# The other Mac adds a different lesson, so the lessons themselves merge cleanly and the two
# generated indexes are simply two correct renderings of two different inputs.
printf -- '- **L4. four.** written only on Mac A\n' >> "$IXHA/LESSONS.md"
CLAUDE_HOME="$IXHA" SYNC_REPO="$IXRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_ix="$(CLAUDE_HOME="$IXHB" SYNC_REPO="$IXRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with two generated indexes: $out_ix"
# The positive control: the lessons really did merge on this run, so the assertions below are
# about a pull that did the work, not one that never got that far (L159).
check "#83 the lessons themselves merged" \
  "grep -q 'L3. three' '$IXHB/LESSONS.md' && grep -q 'L4. four' '$IXHB/LESSONS.md' && grep -q 'L5. five' '$IXHB/LESSONS.md'"
check "#83 the index is not reported as an unmergeable clash" \
  "! line_has \"\$out_ix\" 'could NOT be merged' 'LESSONS-INDEX\.md'"
check "#83 and no set-aside copy of it is left behind" \
  "! ls '$IXHB'/LESSONS-INDEX.md.conflict-* >/dev/null 2>&1"
# What replaces the conflict is the regeneration that was always going to happen: the index on
# disk describes the MERGED lessons file, both sides included, with a header count that matches.
check "#83 the regenerated index carries both sides" \
  "grep -q 'L3. three' '$IXHB/LESSONS-INDEX.md' && grep -q 'L4. four' '$IXHB/LESSONS-INDEX.md'"
# `grep -c` prints 0 AND fails when it counts nothing, so `|| echo 0` runs too and the value is
# two lines (claude-config#172).
ix_count="$(grep -c '^- L[0-9]' "$IXHB/LESSONS-INDEX.md" 2>/dev/null || true)"
case "$ix_count" in ''|*[!0-9]*) ix_count=0 ;; esac
ix_header="$(grep -oE '[0-9]+ lessons' "$IXHB/LESSONS-INDEX.md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
ix_real="$(grep -c '^- \*\*L[0-9]' "$IXHB/LESSONS.md" 2>/dev/null || true)"
case "$ix_real" in ''|*[!0-9]*) ix_real=0 ;; esac
dbg "index entries=$ix_count header=$ix_header lessons=$ix_real"
# The header count is the line that was UNIQUE to the preserved copy in the real incident, so it
# is the one worth asserting: stale there, correct here, and derived from the merged file.
check "#83 every merged lesson has an index line" "[ \"\$ix_count\" = \"\$ix_real\" ] && [ \"\$ix_real\" = '5' ]"
check "#83 and the header count matches the merged file" "[ \"\$ix_header\" = \"\$ix_real\" ]"

# The exclusion is for the DERIVED file only. A rule file that genuinely clashes must still be
# preserved and still be reported, or this fix has quietly turned conflict detection off (L129).
printf 'rtk from A\n' > "$IXHA/RTK.md"
printf '# rules\n@LESSONS.md\n@LESSONS-INDEX.md\n@RTK.md\n' > "$IXHA/CLAUDE.md"
CLAUDE_HOME="$IXHA" SYNC_REPO="$IXRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$IXHB" SYNC_REPO="$IXRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
printf 'rtk rewritten on B\n' > "$IXHB/RTK.md"
printf 'rtk rewritten on A\n' > "$IXHA/RTK.md"
CLAUDE_HOME="$IXHA" SYNC_REPO="$IXRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_ix2="$(CLAUDE_HOME="$IXHB" SYNC_REPO="$IXRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with a real clash: $out_ix2"
check "#83 a file that really clashes is still kept and reported" \
  "line_has \"\$out_ix2\" 'could NOT be merged' 'RTK\.md'"
check "#83 and its copy is still set aside" "ls '$IXHB'/RTK.md.conflict-* >/dev/null 2>&1"


section "== a conflict whose local side holds nothing new resolves itself (claude-config#177) =="
# The 2026-08-22 pull declared three files unmergeable and wrote a .conflict copy of each. One of
# them, hooks/test-run-all-tests.sh, held ZERO lines the applied version did not already have: the
# incoming version was a strict superset. Every such conflict costs a manual line by line
# comparison to find out that nothing was at stake, and leaves a stale copy in ~/.claude/hooks that
# nobody remembers to delete.
#
# So containment is resolved automatically. It is NOT enough that the local side adds nothing: a
# local DELETION is also contained (the local file is the applied one minus a line) and discarding
# it would destroy work while reporting a clean resolution, which is the worst shape this tool
# could take (L5). The base, which is the version this Mac last applied, is what tells the two
# apart, and both directions are checked below.
unset SYNC_NO_GIT
CNB="$WORK/contain-bare.git"; git init -q --bare "$CNB"
CNRA="$WORK/contain-repoA"; git clone -q "$CNB" "$CNRA" 2>/dev/null
CNHA="$WORK/contain-homeA"; mkdir -p "$CNHA/hooks"
echo '{"hooks":{}}' > "$CNHA/settings.json"
printf 'alpha\nbravo\ncharlie\n' > "$CNHA/hooks/cn-shared.sh"
printf 'alpha\nbravo\ncharlie\n' > "$CNHA/hooks/cn-clash.sh"
printf 'alpha\nbravo\ncharlie\n' > "$CNHA/hooks/cn-deleted.sh"
CLAUDE_HOME="$CNHA" SYNC_REPO="$CNRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CNRB="$WORK/contain-repoB"; git clone -q "$CNB" "$CNRB" 2>/dev/null
CNHB="$WORK/contain-homeB"; mkdir -p "$CNHB"
echo '{"hooks":{}}' > "$CNHB/settings.json"
CLAUDE_HOME="$CNHB" SYNC_REPO="$CNRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#177 both Macs start from the same three files" \
  "[ -f '$CNHB/hooks/cn-shared.sh' ] && [ -f '$CNHB/hooks/cn-clash.sh' ] && [ -f '$CNHB/hooks/cn-deleted.sh' ]"

# This Mac's unsent edits. cn-shared gains a line the other Mac is about to add as well, so the
# arriving version will contain everything this one has. cn-clash gains a line the other Mac will
# never have. cn-deleted LOSES a line the other Mac keeps, which is the case that looks contained
# and is not.
printf 'alpha\nbravo\ncharlie\ndelta\n' > "$CNHB/hooks/cn-shared.sh"
printf 'alpha\nbravo\ncharlie\nonly on B\n' > "$CNHB/hooks/cn-clash.sh"
printf 'alpha\ncharlie\n' > "$CNHB/hooks/cn-deleted.sh"
# The other Mac's versions, published from its own healthy clone.
printf 'alpha\nbravo\ncharlie\ndelta\necho\n' > "$CNHA/hooks/cn-shared.sh"
printf 'alpha\nbravo\ncharlie\nonly on A\n' > "$CNHA/hooks/cn-clash.sh"
printf 'alpha\nbravo\ncharlie\necho\n' > "$CNHA/hooks/cn-deleted.sh"
CLAUDE_HOME="$CNHA" SYNC_REPO="$CNRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_cn="$(CLAUDE_HOME="$CNHB" SYNC_REPO="$CNRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with one contained side, one real clash and one local deletion: $out_cn"

# The contained one. The other Mac's version is applied, no copy is set aside, and the pull SAYS
# so: a file that did conflict and was decided in favour of the other Mac must not be settled in
# silence (L11).
check "#177 the contained file takes the other Mac's version" \
  "grep -q 'delta' '$CNHB/hooks/cn-shared.sh' && grep -q 'echo' '$CNHB/hooks/cn-shared.sh'"
check "#177 and no copy of it is set aside" \
  "! ls '$CNHB'/hooks/cn-shared.sh.conflict-* >/dev/null 2>&1"
check "#177 and the pull reports it as resolved" \
  "line_has \"\$out_cn\" 'nothing was set aside' 'cn-shared\.sh'"
check "#177 and does not call it unmergeable" \
  "! line_has \"\$out_cn\" 'could NOT be merged' 'cn-shared\.sh'"

# The real clash, which is the control: without it, a fix that simply stopped preserving anything
# would pass every check above (L1, L129).
check "#177 a file with a line of its own is still preserved" \
  "ls '$CNHB'/hooks/cn-clash.sh.conflict-* >/dev/null 2>&1"
check "#177 and is still reported as unmergeable" \
  "line_has \"\$out_cn\" 'could NOT be merged' 'cn-clash\.sh'"

# The local deletion. Its lines are all present in the arriving version, so line containment alone
# would throw it away and call that a clean resolution.
check "#177 a local deletion is NOT treated as contained" \
  "ls '$CNHB'/hooks/cn-deleted.sh.conflict-* >/dev/null 2>&1"
# The glob, not `ls ... | head -1`: a pipeline whose consumer exits first can kill its producer
# under pipefail and report a failure that never happened (L183, claude-config#122).
check "#177 and the deleted line is recoverable from the copy" \
  "! grep -q 'bravo' '$CNHB'/hooks/cn-deleted.sh.conflict-*"
check "#177 and it is reported as unmergeable too" \
  "line_has \"\$out_cn\" 'could NOT be merged' 'cn-deleted\.sh'"

# A second pull with nothing new must not repeat the resolution line: it describes what THIS pull
# decided, and a standing announcement about a file nobody is deciding anything about is the noise
# the conflict report already avoids.
out_cn2="$(CLAUDE_HOME="$CNHB" SYNC_REPO="$CNRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
check "#177 a later quiet pull does not repeat it" \
  "! line_has \"\$out_cn2\" 'nothing was set aside' 'cn-shared\.sh'"

section "== a resolved conflict leaves a copy that expires on its own (#183) =="
# #177 stopped writing a .conflict copy when this Mac's version held no line the arriving one
# lacked. That is right, and it leaves one path where a locally modified file is replaced with
# nothing kept anywhere: every other conflict outcome leaves the local version on disk. The
# containment judgement is guarded in both directions, but a guard is not a recovery, and a line in
# a terminal is not one either (L5).
#
# So the dropped version goes somewhere with a life of its own: outside the mirrored config, so it
# cannot become the stale file in ~/.claude/hooks that #177 exists to stop accumulating, and swept
# on age, so nobody has to remember to delete it.
unset SYNC_NO_GIT
RVB="$WORK/resolved-bare.git"; git init -q --bare "$RVB"
RVRA="$WORK/resolved-repoA"; git clone -q "$RVB" "$RVRA" 2>/dev/null
RVHA="$WORK/resolved-homeA"; mkdir -p "$RVHA/hooks"
echo '{"hooks":{}}' > "$RVHA/settings.json"
printf 'alpha\nbravo\n' > "$RVHA/hooks/rv-file.sh"
CLAUDE_HOME="$RVHA" SYNC_REPO="$RVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
RVRB="$WORK/resolved-repoB"; git clone -q "$RVB" "$RVRB" 2>/dev/null
RVHB="$WORK/resolved-homeB"; mkdir -p "$RVHB"
echo '{"hooks":{}}' > "$RVHB/settings.json"
CLAUDE_HOME="$RVHB" SYNC_REPO="$RVRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1

# This Mac adds a line the other Mac is about to add as well, so the arriving version contains
# everything this one has and the conflict resolves itself.
printf 'alpha\nbravo\nonly-here-for-now\n' > "$RVHB/hooks/rv-file.sh"
printf 'alpha\nbravo\nonly-here-for-now\nand-theirs\n' > "$RVHA/hooks/rv-file.sh"
CLAUDE_HOME="$RVHA" SYNC_REPO="$RVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_rv="$(CLAUDE_HOME="$RVHB" SYNC_REPO="$RVRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull resolving a contained conflict: $out_rv"
check "#183 the arriving version really was taken" "grep -q 'and-theirs' '$RVHB/hooks/rv-file.sh'"
check "#183 a copy of the dropped version is kept" \
  "ls '$RVRB'/.resolved/* >/dev/null 2>&1"
check "#183 and it holds what this Mac had"  "grep -rq 'only-here-for-now' '$RVRB/.resolved'"
# The copy must not carry the line the arriving version added, or it is a copy of the wrong side
# and would prove nothing on the day somebody needed it (L48).
check "#183 and not what the other Mac added"  "! grep -rq 'and-theirs' '$RVRB/.resolved'"
check "#183 the pull says where it went"       "line_has \"\$out_rv\" 'nothing was set aside' 'resolved'"
# Outside the mirrored config, or it becomes exactly the stale file in ~/.claude/hooks that #177
# was written to stop leaving behind.
check "#183 nothing is left in the config directory" \
  "! ls '$RVHB'/hooks/rv-file.sh.* >/dev/null 2>&1 && [ ! -d '$RVHB/.resolved' ]"

# It expires without anybody deleting it, and the sweep is watched keeping a recent one as well as
# removing an old one: a sweep that removed everything would satisfy the first half alone (L1).
mkdir -p "$RVRB/.resolved"
_rv_old="$RVRB/.resolved/rv-old-copy"
_rv_new="$RVRB/.resolved/rv-new-copy"
printf 'old\n' > "$_rv_old"; printf 'new\n' > "$_rv_new"
touch -t "$(date -v-30d +%Y%m%d%H%M)" "$_rv_old" 2>/dev/null || touch -d '30 days ago' "$_rv_old"
printf 'alpha\nbravo\nonly-here-for-now\nand-theirs\nlater\n' > "$RVHA/hooks/rv-file.sh"
CLAUDE_HOME="$RVHA" SYNC_REPO="$RVRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$RVHB" SYNC_REPO="$RVRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#183 a copy past its age is swept"      "[ ! -f '$_rv_old' ]"
check "#183 and a recent one is left alone"    "[ -f '$_rv_new' ]"

section "== every wait polls on one shared interval, and no deadline counts polls (#205) =="
# Three loops in claude-sync waited for something to end: the hook suite runner it had just
# started, and the sync lock, twice. Each had its own sleep, one of two seconds and two of one, and
# nothing recorded why they differed. In production the granularity is invisible beside a suite
# that runs for minutes. In THIS suite it was the whole cost: fifteen real pulls run against a stub
# runner that returns in milliseconds, each sitting in a two second sleep waiting for a process
# that had already gone. 59 seconds of section time, measured 2026-08-30, spent on nothing.
#
# So there is one setting, and the deadlines are measured against the CLOCK rather than by adding
# up the sleeps (L226). That distinction is the whole risk in this change: the lock's ceiling used
# to be counted in turns of its loop, so shortening the poll by twenty would have divided a 90
# second wait by twenty with nothing anywhere saying so.
PIH="$WORK/poll-home"; mkdir -p "$PIH/hooks"
echo '{"hooks":{}}' > "$PIH/settings.json"
PIR="$WORK/poll-repo"; mkdir -p "$PIR/payload/hooks"
# The suite only runs when a HOOK actually arrived, so every timed pull below has to land one.
# `pi_arrive` changes a hook in the repo, which is what puts a hooks/ line in the applied log and
# is the whole trigger. A pull that applied nothing would skip the wait entirely and every timing
# here would be measuring a code path that never ran (L101).
pi_arrive(){ printf '# marker %s\n' "$1" > "$PIR/payload/hooks/pi-marker.sh"; }
# The runner is installed BY the pull, like a real one, rather than placed in the home directory
# where the pull would treat it as a local file it has to remove. It returns AT ONCE: what is
# being measured is how long the caller takes to notice, so the work itself must cost nothing
# (L146).
pi_runner(){ # pi_runner <the body of the stub runner>
  { printf '#!/usr/bin/env bash\n'; printf '%s\n' "$1"; } > "$PIR/payload/hooks/run-all-tests.sh"
  chmod +x "$PIR/payload/hooks/run-all-tests.sh"
}
# It takes 50 milliseconds, not zero. A runner that has ALREADY exited by the time the caller
# first looks never reaches the sleep at all, so a zero cost stub measures the poll interval as
# nought whatever it is set to, and both a two second poll and a tenth of a second one pass (L165:
# a fixture that finishes before the case under test can occur).
pi_runner 'sleep 0.05
echo "ALL 1 SUITES PASSED"
exit 0'
# Milliseconds, because the whole claim is about a tenth of a second and `date +%s` cannot see it.
# perl rather than a newer date: BSD date has no %N, and CI already prints perl's version in the
# step that records what the suite is judged in.
pi_ms(){ perl -MTime::HiRes -e 'printf "%.0f", Time::HiRes::time()*1000'; }

# Timed with the same clock at both ends, and compared against a duration measured in this same
# run rather than against a constant, because a constant measures what else the machine is doing
# (L224). The reference is the SAME pull with the poll deliberately set long: everything except
# the interval is identical, so the difference between them is the interval and nothing else.
pi_run(){   # pi_run <poll interval> <marker> -> milliseconds that pull took
  local _pi_t0 _pi_t1
  pi_arrive "$2"
  _pi_t0="$(pi_ms)"
  CLAUDE_HOME="$PIH" SYNC_REPO="$PIR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
    SYNC_POLL_INTERVAL="$1" bash "$SCRIPT" pull > "$WORK/poll-out.txt" 2>&1
  _pi_t1="$(pi_ms)"
  printf '%s' "$(( _pi_t1 - _pi_t0 ))"
}
# The control that makes every number below mean anything: the timed pulls must actually REACH the
# wait. A pull that applied no hook skips it, costs nothing either way, and would satisfy a
# comparison of two identical zeroes (L98, L159).
pi_slow="$(pi_run 4 one)"
pi_reached="$(cat "$WORK/poll-out.txt" 2>/dev/null)"
check "#205 the timed pulls really do run the hook suite" \
  "line_has \"\$pi_reached\" 'Pulled shared config' 'hook suite passed here'"
# THREE fast samples, and the smallest of them is the one used (claude-config#245).
#
# A single sample of an elapsed time is a sample of what else the machine was doing at that instant,
# and this section was one of the three that failed three separate full runs on 2026-08-31 while
# passing every time it was run alone. The same run took 149s idle and 402s under load, which is the
# variable a single reading actually measures (L224).
#
# The smallest of several readings is the one least contaminated by a load spike, and the SPREAD
# between them is this machine's noise for this operation, right now, in this run. It is reported
# alongside the verdict so a failure says whether the machine was busy rather than leaving the
# reader to guess (L11).
pi_fast_a="$(pi_run 0.1 two)"
pi_fast_b="$(pi_run 0.1 two_b)"
pi_fast_c="$(pi_run 0.1 two_c)"
pi_fast="$pi_fast_a"
[ "$pi_fast_b" -lt "$pi_fast" ] && pi_fast="$pi_fast_b"
[ "$pi_fast_c" -lt "$pi_fast" ] && pi_fast="$pi_fast_c"
pi_spread_hi="$pi_fast_a"
[ "$pi_fast_b" -gt "$pi_spread_hi" ] && pi_spread_hi="$pi_fast_b"
[ "$pi_fast_c" -gt "$pi_spread_hi" ] && pi_spread_hi="$pi_fast_c"
pi_spread=$(( pi_spread_hi - pi_fast ))
dbg "#205 pull with a 4s poll took ${pi_slow}ms, with the default 0.1s poll took ${pi_fast_a}ms ${pi_fast_b}ms ${pi_fast_c}ms"
# The samples have to be real work, or the minimum of three zeroes would satisfy everything below
# it (L98). A pull that reached the wait cannot cost nothing.
check "#205 the fast samples measured real pulls (fastest ${pi_fast}ms, spread ${pi_spread}ms)" \
  "[ \"\$pi_fast\" -gt 0 ]"
# The setting is HONOURED, which is the only thing that makes the default meaningful. A four
# second poll against a runner that ends after the 50ms the stub above SETS (not measured: the
# fixture sleeps exactly that long) must cost at least two seconds more than a tenth of a second
# poll. Anything less means the sleep is not where the time goes and this whole section is
# measuring something else (L1, L159).
check "#205 the poll interval is honoured (4s poll took ${pi_slow}ms, 0.1s poll took ${pi_fast}ms)" \
  "[ \"\$(( pi_slow - pi_fast ))\" -ge 2000 ]"
# And the difference the issue was opened about, said as the number it promised: a runner that
# finishes in 50 milliseconds is noticed within a fifth of a second of doing so. Bounded against
# the SLOW run's own overhead rather than against a bare 200, because a pull does real work either
# way and only the wait is under test here (L146, L224).
pi_overhead=$(( pi_slow - 4000 ))
[ "$pi_overhead" -ge 0 ] || pi_overhead=0
check "#205 and a runner finishing in 50ms is noticed within 200ms of it (fastest ${pi_fast}ms, spread ${pi_spread}ms, of which ${pi_overhead}ms is the pull itself)" \
  "[ \"\$(( pi_fast - pi_overhead ))\" -le 200 ]"

# The deadline is against the CLOCK. A runner that never ends, and a ceiling of three seconds: if
# the deadline counted polls it would fire after three TENTHS of a second at the default interval,
# so a run that survives past one second proves the ceiling is time and not turns (L226, L1).
pi_runner 'while :; do sleep 3600 & wait "$!" || true; done'
pi_arrive three
# Two seconds is the SHORTEST ceiling this can be proved against, and the reason is the clock, not
# caution. claude-sync reads whole seconds, so a ceiling of N expires somewhere between N-1 and N
# seconds of real time, and a ceiling of 1 can therefore expire immediately. Two leaves a full
# second of separation to assert on, against the two polls a deadline counting them would take,
# which the interval below SETS at a fifth of a second rather than anything measuring it.
pi_h0="$(pi_ms)"
out_pih="$(CLAUDE_HOME="$PIH" SYNC_REPO="$PIR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
  SYNC_POLL_INTERVAL=0.1 SYNC_HOOK_TESTS_TIMEOUT=2 bash "$SCRIPT" pull 2>&1)"
pi_held=$(( $(pi_ms) - pi_h0 ))
dbg "#205 a runner that never ends, with a 2s ceiling and a 0.1s poll, was stopped after ${pi_held}ms"
# There WAS no test anywhere that this deadline fires. It is the error path of a wait that holds
# nothing and reports an unverified config, and an error path with no test is the half that ships
# broken (L1).
check "#205 a runner that never ends is stopped at its deadline" \
  "line_has \"\$out_pih\" 'could NOT be completed here' 'still running after 2s'"
check "#205 and the deadline is seconds, not polls (it survived ${pi_held}ms of a 2s ceiling)" \
  "[ '$pi_held' -ge 1000 ]"
check "#205 and it did not outlast the ceiling by more than the poll (${pi_held}ms against 2s)" \
  "[ '$pi_held' -le 8000 ]"

# The lock's ceiling is seconds too, and it is the one that was counting turns. A lock held by a
# live process on this machine is waited for, so a two second ceiling with a tenth of a second
# poll must take about two seconds rather than about a fifth of one.
PILOCK="$WORK/poll-lock"; rm -rf "$PILOCK"; mkdir -p "$PILOCK"
sleep 120 & PI_LIVE=$!
printf '%s\n' "$PI_LIVE" > "$PILOCK/pid"
printf '%s\n' "$(hostname)" > "$PILOCK/host"
pi_l0="$(pi_ms)"
CLAUDE_HOME="$PIH" SYNC_REPO="$PIR" SYNC_LOCK="$PILOCK" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
  SYNC_POLL_INTERVAL=0.1 SYNC_LOCK_WAIT=2 bash "$SCRIPT" sync >/dev/null 2>&1
pi_lwait=$(( $(pi_ms) - pi_l0 ))
kill "$PI_LIVE" 2>/dev/null || true
wait "$PI_LIVE" 2>/dev/null || true
rm -rf "$PILOCK"
dbg "#205 a contended lock with a 2s ceiling and a 0.1s poll waited ${pi_lwait}ms"
# Milliseconds, and a bound of one second rather than two, for the reason above: a whole second
# clock reading a two second ceiling expires anywhere in the second second, so `-ge 2` measured in
# whole seconds is a coin toss on its own boundary, while a second cannot be reached by a deadline
# counting the two polls the interval above SETS, not measures (L224, L290).
check "#205 the lock's wait is seconds, not turns of its loop (waited ${pi_lwait}ms of a 2s ceiling)" \
  "[ '$pi_lwait' -ge 1000 ]"
check "#205 and it gives up at that ceiling rather than waiting on (${pi_lwait}ms against 2s)" \
  "[ '$pi_lwait' -le 8000 ]"

# An unreadable interval is SAID, never silently swapped for the default: a setting that is
# ignored in silence reads exactly like one that is in force (L320, L11).
out_pib="$(CLAUDE_HOME="$PIH" SYNC_REPO="$PIR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
  SYNC_POLL_INTERVAL=every-so-often SYNC_HOOK_TESTS_TIMEOUT=3 bash "$SCRIPT" status 2>&1)"
check "#205 an interval that is not a number is named, and the default said" \
  "line_has \"\$out_pib\" \"SYNC_POLL_INTERVAL='every-so-often'\" 'default of 0.1'"
# The control: a well formed interval says nothing at all, or the check above is satisfied by a
# tool that complains about every value it is given (L159). Matched with `case` on a variable
# rather than a piped `grep -q`, which leaves on its first match and can be killed by its own
# producer under pipefail (#132, L183).
out_pig="$(CLAUDE_HOME="$PIH" SYNC_REPO="$PIR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 \
  SYNC_POLL_INTERVAL=0.5 bash "$SCRIPT" status 2>&1)"
case "$out_pig" in *SYNC_POLL_INTERVAL*) pi_quiet=0 ;; *) pi_quiet=1 ;; esac
check "#205 and a well formed interval is not complained about" "[ '$pi_quiet' -eq 1 ]"

section "== a pull runs the hook suite it just installed (#178) =="
# `claude-sync pull` printed its received-changes summary and ended with "Pulled shared config onto
# this Mac" without executing anything it had just installed. The 2026-08-22 pull landed a hook
# whose own suite failed on this Mac, and that was found only because somebody ran the tests by
# hand afterwards. Success reported without running anything is indistinguishable from success
# actually verified (L98).
#
# The runner under test here is a stub: what is being checked is how the pull READS it, and a stub
# is the only way to make it pass, fail, or be missing on demand. It records the environment it was
# given, because a pull that runs the suite while the suite's own fixtures run pulls would recurse
# without end, so the guard against that is part of the behaviour rather than a detail.
unset SYNC_NO_GIT
HTB="$WORK/hooktests-bare.git"; git init -q --bare "$HTB"
HTRA="$WORK/hooktests-repoA"; git clone -q "$HTB" "$HTRA" 2>/dev/null
# Named before the stub is written, not where it is cloned: the stub bakes this path in, and under
# set -u a name that does not exist yet aborts the heredoc and leaves no stub at all.
HTRB="$WORK/hooktests-repoB"
HTHA="$WORK/hooktests-homeA"; mkdir -p "$HTHA/hooks"
echo '{"hooks":{}}' > "$HTHA/settings.json"
printf '# rules v1\n' > "$HTHA/CLAUDE.md"
echo 'one' > "$HTHA/hooks/ht-one.sh"
# The stub carries Mac B's lock path even though Mac A writes it, because Mac B is where it runs:
# the point of the line is what the lock looks like from INSIDE the run (claude-config#181).
mkrunner(){   # mkrunner <exit status>  -> writes Mac A's stub runner
  cat > "$HTHA/hooks/run-all-tests.sh" <<HTRUNNER
#!/usr/bin/env bash
if [ -d "$HTRB/.sync-lock" ]; then _ht_lock=held; else _ht_lock=free; fi
printf '%s ran, SYNC_NO_HOOK_TESTS=%s, lock=%s\n' "\$(basename "\$0")" "\${SYNC_NO_HOOK_TESTS:-unset}" "\$_ht_lock" \
  >> "\$(dirname "\$0")/ht-ran.txt"
echo "ALL 1 SUITES PASSED"
echo "ht-detail: this line is what the runner had to say"
exit $1
HTRUNNER
}
mkrunner 0
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git clone -q "$HTB" "$HTRB" 2>/dev/null
HTHB="$WORK/hooktests-homeB"; mkdir -p "$HTHB"
echo '{"hooks":{}}' > "$HTHB/settings.json"
out_ht="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "first pull with a passing stub runner: $out_ht"
ht_ran(){ n="$(grep -c . "$HTHB/hooks/ht-ran.txt" 2>/dev/null || true)"; case "$n" in ''|*[!0-9]*) n=0 ;; esac; printf '%s' "$n"; }
check "#178 the hook suite the pull installed is the one it runs" "[ \"\$(ht_ran)\" = '1' ]"
check "#178 and the closing line carries its verdict" \
  "line_has \"\$out_ht\" 'Pulled shared config' 'hook suite passed here'"
# The recursion guard. The suite's own fixtures run pulls, so a pull that runs the suite must tell
# the suite not to run it again, and that has to be in the environment the runner receives rather
# than a rule somebody remembers to follow (L27).
check "#178 the suite is told not to run itself again" \
  "line_has \"\$(cat '$HTHB/hooks/ht-ran.txt')\" 'run-all-tests\.sh ran' 'SYNC_NO_HOOK_TESTS=1'"
# And it runs with the sync lock RELEASED (claude-config#181). The suite is minutes of work, and
# holding the lock for it means every watch daemon pull starting in that window refuses rather than
# queueing, so the job whose whole purpose is keeping this Mac current is starved by the step that
# checks this Mac is current. The config is already applied and on disk by the time this runs, so
# there is nothing left for the lock to protect.
check "#181 the suite runs with the sync lock released" \
  "line_has \"\$(cat '$HTHB/hooks/ht-ran.txt')\" 'run-all-tests\.sh ran' 'lock=free'"
# The fixture can tell the two apart, or "free" would mean only that it never looked (L1, L159).
check "#181 and the stub can tell a held lock from a free one" \
  "mkdir -p '$HTRB/.sync-lock' && bash '$HTHB/hooks/run-all-tests.sh' >/dev/null 2>&1; _ht_probe=\$?; rmdir '$HTRB/.sync-lock' 2>/dev/null; line_has \"\$(cat '$HTHB/hooks/ht-ran.txt')\" 'run-all-tests\.sh ran' 'lock=held'"

# Judged by its EXIT CODE and by nothing else (L184). This stub prints the runner's own success
# line and exits 1, which is the pair a reader of the last line of output gets wrong.
mkrunner 1
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_ht2="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull with a runner that prints success and exits 1: $out_ht2"
check "#178 a failing suite is reported as failed" \
  "line_has \"\$out_ht2\" 'Pulled shared config' 'hook suite FAILED here'"
check "#178 and its printed success line does not decide it" \
  "! line_has \"\$out_ht2\" 'Pulled shared config' 'hook suite passed here'"

# A suite that could not be run AT ALL is its own outcome, never folded into failed: one says a
# check on this config does not pass, the other says nothing checked it, and sending a reader to
# look for a fault that is not there is its own defect (L11, L98).
rm -f "$HTHA/hooks/run-all-tests.sh"
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_ht3="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull that removed the runner: $out_ht3"
check "#178 hooks arriving with no runner says so" \
  "line_has \"\$out_ht3\" 'Pulled shared config' 'hook suite could NOT be run here'"
check "#178 and does not call that a failure" \
  "! line_has \"\$out_ht3\" 'Pulled shared config' 'hook suite FAILED here'"

# Cost. The suite is minutes of work, so a pull that landed no hook must not pay it: there is
# nothing newly installed for it to check.
mkrunner 0
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
ht_before="$(ht_ran)"
printf '# rules v2\n' > "$HTHA/CLAUDE.md"
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_ht4="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull carrying only a rule file: $out_ht4"
check "#178 a pull that landed the rule file really applied it" \
  "grep -q 'rules v2' '$HTHB/CLAUDE.md'"
check "#178 but a pull with no hook in it does not run the suite" "[ \"\$(ht_ran)\" = \"\$ht_before\" ]"
check "#178 and says nothing about a suite it did not run" \
  "! line_has \"\$out_ht4\" 'Pulled shared config' 'hook suite'"

# And the off switch, for a run that must not pay the cost at all.
echo 'two' > "$HTHA/hooks/ht-one.sh"
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
ht_before2="$(ht_ran)"
out_ht5="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1)"
check "#178 the hook really arrived on that pull"  "grep -q 'two' '$HTHB/hooks/ht-one.sh'"
check "#178 SYNC_NO_HOOK_TESTS=1 skips the suite"  "[ \"\$(ht_ran)\" = \"\$ht_before2\" ]"

# The verdict has to outlive the pull that produced it (claude-config#182). A pull from the watch
# daemon has no terminal, so the closing line goes nowhere a person will ever see and the
# notification is gone as soon as it is dismissed. Config landed unattended, its own checks do not
# pass, and a minute later there was no way to find that out. A failure reason written only to a
# surface that dies with the attempt leaves somebody facing the same state with no way to learn why
# (L148).
mkrunner 1
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
out_st1="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "status after a failing suite: $out_st1"
check "#182 status still names the failure after the pull has ended" \
  "line_has \"\$out_st1\" 'hook suite' 'FAILED'"
check "#182 and says how long ago it was run" \
  "line_has \"\$out_st1\" 'hook suite' '(just now|ago)'"
# The runner's own words are kept WITH the record rather than in scratch, which is swept on a
# schedule of its own and would be gone before anybody came looking (L202).
check "#182 and the record keeps what the runner said" \
  "grep -q 'ht-detail' '$HTRB/.hook-tests'"

# It goes quiet on its own once a later run actually passes, the same way the conflict report does.
mkrunner 0
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
out_st2="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#182 a later passing run clears the report" "! line_has \"\$out_st2\" 'hook suite' 'FAILED'"

# A suite that could NOT be run keeps its own wording here too, or the record collapses the two
# outcomes the closing line was careful to keep apart (L11).
rm -f "$HTHA/hooks/run-all-tests.sh"
CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
out_st3="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#182 a suite that could not run is reported as that" \
  "line_has \"\$out_st3\" 'hook suite' 'could NOT be run'"
check "#182 and is not reported as a failure"  "! line_has \"\$out_st3\" 'hook suite' 'FAILED'"

# And a record nothing can read is said to be unreadable, never treated as a pass: a file restored
# from a backup or half written by a killed run is exactly when this matters (L98).
printf 'not a record at all\n' > "$HTRB/.hook-tests"
out_st4="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#182 an unreadable record is reported as unreadable" \
  "line_has \"\$out_st4\" 'hook suite' 'unreadable'"
rm -f "$HTRB/.hook-tests"
out_st5="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#182 and no record at all says nothing" "! line_has \"\$out_st5\" 'hook suite' '(FAILED|unreadable|could NOT)'"

section "== a passing pull says how much of the suite actually ran (#185) =="
# needs: a pull runs the hook suite it just installed
# "the hook suite passed here" was printed whenever the runner exited 0. run-all-tests.sh exits 0
# when suites merely COULD NOT RUN, and it says so itself: six of them audit the repository and
# declare SUITE-NOT-RUN anywhere else, which is every deployed Mac. So the most reassuring line the
# pull can print covered materially less than it sounded like, which is the fold this tool refuses
# everywhere else: a check that did not run must not read as one that passed (L98).
#
# What DECIDES the outcome is still the exit code and nothing else (L184). This is about what the
# sentence CLAIMS, and the count is read from the runner's own report rather than derived a second
# time here, so the two cannot drift (L107).
#
# The three readings are asserted separately, because a coverage figure that could only ever be
# read one way would be satisfied by a parser that matched nothing and reported the pleasant
# default (L98, L215): a runner that ran everything, one that could not run some of it, and one
# whose report this cannot read at all each get their own words.
mkrunner_v(){   # mkrunner_v <exit status> <the verdict line it prints> -> Mac A's stub runner
  cat > "$HTHA/hooks/run-all-tests.sh" <<HTRUNNERV
#!/usr/bin/env bash
printf 'ran\n' >> "\$(dirname "\$0")/ht-ran.txt"
echo "$2"
exit $1
HTRUNNERV
}
# Each call writes a DIFFERENT verdict line into the runner, which is itself a hook, so every
# scenario below genuinely lands a hook on Mac B and genuinely triggers the suite. A fixture that
# changed nothing would leave the pull with no hook to check and the closing line would say nothing
# at all, which reads exactly like a coverage clause that was never written.
ht_cover(){   # ht_cover <exit> <verdict line> -> Mac B's whole closing output
  mkrunner_v "$1" "$2"
  CLAUDE_HOME="$HTHA" SYNC_REPO="$HTRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
  CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1
}
ht_field(){   # ht_field <name> -> that named field of Mac B's recorded verdict
  # By NAME since claude-config#233. Positionally, the record could be widened without widening
  # the read and the last field would silently absorb the new one.
  hd_field "$(head -1 "$HTRB/.hook-tests" 2>/dev/null || true)" "$1"
}

out_cv1="$(ht_cover 0 'ALL 12 SUITES PASSED')"
dbg "pull whose runner ran everything: $out_cv1"
check "#185 a pass that covered the whole suite says so" \
  "line_has \"\$out_cv1\" 'Pulled shared config' 'hook suite passed here' 'all 12 of its suites'"
check "#185 and records the counts it reported" \
  "[ \"\$(ht_field ran)\" = '12' ] && [ \"\$(ht_field notrun)\" = '0' ]"

out_cv2="$(ht_cover 0 'ALL 6 SUITES THAT COULD RUN PASSED, and 4 could not run here')"
dbg "pull whose runner could not run some of itself: $out_cv2"
check "#185 a pass with suites that could not run says how many" \
  "line_has \"\$out_cv2\" 'Pulled shared config' 'hook suite passed here' 'only 6 of its 10 suites could run' '4 are unverified'"
# The negative control, in the same fixture. "all N of its suites" is the reassuring reading, and a
# clause that printed it here would be the exact defect this section exists to end (L159).
check "#185 and does not claim the whole suite was covered" \
  "! line_has \"\$out_cv2\" 'Pulled shared config' 'all 6 of its suites'"
check "#185 and records what could not run" \
  "[ \"\$(ht_field ran)\" = '6' ] && [ \"\$(ht_field notrun)\" = '4' ]"

out_cv3="$(ht_cover 0 'the suite is happy, honestly')"
dbg "pull whose runner said nothing this can count: $out_cv3"
check "#185 a report this cannot read says the coverage is unknown" \
  "line_has \"\$out_cv3\" 'Pulled shared config' 'hook suite passed here' 'did not say how many of its suites ran'"
check "#185 and still reports the pass it was told about" \
  "line_has \"\$out_cv3\" 'Pulled shared config' 'hook suite passed here'"
check "#185 and records the counts as unread rather than as zero" \
  "[ \"\$(ht_field ran)\" = '?' ] && [ \"\$(ht_field notrun)\" = '?' ]"

# The record grew two fields, and status reads it positionally. A reader that took the rest of the
# line as the exit code would report "it exited 3\t?\t?", which is the shape a widened record
# breaks its own reader in (claude-config#182 wrote three fields).
out_cv4="$(ht_cover 3 '2 of 5 SUITES FAILED: alpha bravo')"
dbg "pull whose runner failed: $out_cv4"
out_cv5="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "status reading the widened record: $out_cv5"
check "#185 a failure still reports its exit code and nothing after it" \
  "line_has \"\$out_cv5\" 'hook suite' 'FAILED' 'it exited 3\)'"
# A record written by the older three-field version must still be read, or the first status after
# an update reports every outstanding failure as unreadable and clears a real report (L105).
printf 'failed\t%s\t9\n' "$(date +%s)" > "$HTRB/.hook-tests"
out_cv6="$(CLAUDE_HOME="$HTHB" SYNC_REPO="$HTRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
check "#185 and a record from before the counts existed is still read" \
  "line_has \"\$out_cv6\" 'hook suite' 'FAILED' 'it exited 9\)'"
rm -f "$HTRB/.hook-tests"

section "== every receive path runs the suite it installed, not only pull (#184) =="
# #178 runs the suite after a pull that landed a hook, and #181 moved it outside the lock. Both
# hung off do_pull. do_sync applies the payload through apply_payload_to_local and never reached
# that code, so config arriving by SYNC was installed with nothing checking it.
#
# That matters because of which job takes which path. The scheduled receive timer runs `pull`, so
# it was covered. The watch daemon runs `send`, which falls through to do_sync whenever this Mac is
# behind, and `sync` is what the timer's own reconcile does. One of the two unattended receive paths
# verified what it installed and the other did not, which is the hole #178 exists to close, still
# open on the path nobody watches.
#
# So the verdict is flushed from with_lock, once, after the lock is released, rather than added to
# each command that receives. A rule that every future receive path must remember to call it is a
# rule living in somebody's head (L27), and this is exactly the class where the one that forgot was
# the one running unattended.
#
# Its own fixture rather than the #178 pair, and its counter lives OUTSIDE both homes: `sync` mirrors
# the home upward, so a tally kept under hooks/ would travel to the other Mac and be overwritten by
# it, and the count would then measure the sync rather than the suite.
unset SYNC_NO_GIT
SYB="$WORK/synctests-bare.git"; git init -q --bare "$SYB"
SYRA="$WORK/synctests-repoA"; git clone -q "$SYB" "$SYRA" 2>/dev/null
# Named before the stub is written: the stub bakes this path in, and under set -u a name that does
# not exist yet aborts the heredoc and leaves no stub at all.
SYRB="$WORK/synctests-repoB"
SYRAN="$WORK/synctests-ran.txt"
SYHA="$WORK/synctests-homeA"; mkdir -p "$SYHA/hooks"
echo '{"hooks":{}}' > "$SYHA/settings.json"
printf '# rules v1\n' > "$SYHA/CLAUDE.md"
echo 'one' > "$SYHA/hooks/sy-one.sh"
# Each version differs, because the runner IS a hook: a stub rewritten to the same bytes lands
# nothing, and a scenario that installed nothing would report no verdict for the honest reason,
# which reads exactly like a verdict that was never written (L159).
mksyrunner(){   # mksyrunner <exit status> <version marker> -> Mac A's stub runner
  cat > "$SYHA/hooks/run-all-tests.sh" <<SYRUNNER
#!/usr/bin/env bash
# v$2
if [ -d "$SYRB/.sync-lock" ]; then _sy_lock=held; else _sy_lock=free; fi
# The home is read from the ENVIRONMENT, not derived from \$0 with pwd: the temp root here is
# reached through a symlink, so pwd answers with the resolved path and never matches the name
# the fixture holds, which reads as a suite that never ran (L215).
printf 'lock=%s norun=%s home=%s\n' "\$_sy_lock" "\${SYNC_NO_HOOK_TESTS:-unset}" \
  "\${CLAUDE_HOME:-none}" >> "$SYRAN"
echo "ALL 4 SUITES PASSED"
echo "sy-detail: what the runner had to say"
exit $1
SYRUNNER
}
mksyrunner 0 1
CLAUDE_HOME="$SYHA" SYNC_REPO="$SYRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git clone -q "$SYB" "$SYRB" 2>/dev/null
SYHB="$WORK/synctests-homeB"; mkdir -p "$SYHB"
echo '{"hooks":{}}' > "$SYHB/settings.json"
syB(){ CLAUDE_HOME="$SYHB" SYNC_REPO="$SYRB" SYNC_NO_NOTIFY=1 SYNC_NO_LAUNCHCTL=1 bash "$SCRIPT" "$@" 2>&1; }
syA(){ CLAUDE_HOME="$SYHA" SYNC_REPO="$SYRA" SYNC_NO_NOTIFY=1 SYNC_NO_LAUNCHCTL=1 bash "$SCRIPT" "$@" >/dev/null 2>&1; }
sy_ran(){   # how many times the suite has run in Mac B's home
  n="$(grep -c "home=$SYHB\$" "$SYRAN" 2>/dev/null || true)"
  case "$n" in ''|*[!0-9]*) n=0 ;; esac
  printf '%s' "$n"
}

mksyrunner 0 2; syA sync
sy_before1="$(sy_ran)"
out_sy1="$(syB sync)"
dbg "sync that landed a hook: $out_sy1"
check "#184 a sync that landed a hook runs the suite" "[ \"\$(sy_ran)\" -gt \"\$sy_before1\" ]"
check "#184 and its closing line carries the verdict" \
  "line_has \"\$out_sy1\" 'Synced \(' 'hook suite passed here'"
check "#184 and the suite is told not to run itself again" \
  "line_has \"\$(grep \"home=$SYHB\\\$\" '$SYRAN')\" 'norun=1' 'home='"
# Outside the locked region, for the reason #181 measured: the suite is minutes of work, and holding
# the lock for it starves the daemon whose whole job is keeping this Mac current.
check "#184 and it runs with the sync lock released" \
  "line_has \"\$(grep \"home=$SYHB\\\$\" '$SYRAN')\" 'lock=free' 'home='"
check "#184 and the stub can tell a held lock from a free one" \
  "mkdir -p '$SYRB/.sync-lock' && CLAUDE_HOME='$SYHB' bash '$SYHB/hooks/run-all-tests.sh' >/dev/null 2>&1; rmdir '$SYRB/.sync-lock' 2>/dev/null; line_has \"\$(cat '$SYRAN')\" 'lock=held' 'home='"

# Cost, the same rule the pull path follows: a sync that landed no hook has installed nothing this
# runner checks, so it must not pay minutes for it.
printf '# rules v2\n' > "$SYHA/CLAUDE.md"; syA sync
sy_before2="$(sy_ran)"
out_sy2="$(syB sync)"
check "#184 a sync carrying only a rule file really applied it" "grep -q 'rules v2' '$SYHB/CLAUDE.md'"
check "#184 but does not run the suite" "[ \"\$(sy_ran)\" = \"\$sy_before2\" ]"
check "#184 and says nothing about a suite it did not run" \
  "! line_has \"\$out_sy2\" 'Synced \(' 'hook suite'"

# A failure on this path has to reach the same durable record, or a sync from the daemon leaves the
# fault in a line nobody was there to read (#182, L148).
mksyrunner 1 3; syA sync
out_sy3="$(syB sync)"
dbg "sync whose suite failed: $out_sy3"
check "#184 a failing suite is reported as failed on a sync" \
  "line_has \"\$out_sy3\" 'Synced \(' 'hook suite FAILED here'"
out_sy3s="$(syB status)"
check "#184 and status still names it after the sync has ended" \
  "line_has \"\$out_sy3s\" 'hook suite' 'FAILED'"
check "#184 and the record keeps what the runner said" "grep -q 'sy-detail' '$SYRB/.hook-tests'"

mksyrunner 0 4; syA sync
sy_before4="$(sy_ran)"
out_sy4="$(CLAUDE_HOME="$SYHB" SYNC_REPO="$SYRB" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" sync 2>&1)"
check "#184 the hook really arrived on that sync" "grep -q '# v4' '$SYHB/hooks/run-all-tests.sh'"
check "#184 SYNC_NO_HOOK_TESTS=1 skips the suite on a sync too" "[ \"\$(sy_ran)\" = \"\$sy_before4\" ]"

# The resume point after claude-sync updates itself mid-sync. It applies the payload and is the only
# thing that does on that run, so a verdict that lived in do_sync would be lost exactly when the tool
# has just changed underneath the Mac, which is when it is most worth having.
mksyrunner 0 5; syA sync
git -C "$SYRB" pull -q --ff-only 2>/dev/null
sy_before5="$(sy_ran)"
out_sy5="$(syB apply-only)"
dbg "apply-only resuming after a hand-off: $out_sy5"
check "#184 apply-only runs the suite it applied" "[ \"\$(sy_ran)\" -gt \"\$sy_before5\" ]"
check "#184 and carries the verdict in its closing line" \
  "line_has \"\$out_sy5\" 'Synced \(' 'hook suite passed here'"

# The watch daemon's own path. `send` has no apply step, so it refuses while this Mac is behind and
# falls through to a full reconcile when its push is rejected. .last-applied absent is the state the
# refusal is deliberately switched off in (a fresh clone, or the first run of a new version), which
# is what makes the fall-through reachable here rather than only in a race.
mksyrunner 0 6; syA sync
rm -f "$SYRB/.last-applied"
mkdir -p "$SYHB/agents"; printf 'a local edit\n' > "$SYHB/agents/sy-local.md"
sy_before6="$(sy_ran)"
out_sy6="$(syB send)"
dbg "send that fell through to a reconcile: $out_sy6"
check "#184 a send that fell through to a reconcile really received the hook" \
  "grep -q '# v6' '$SYHB/hooks/run-all-tests.sh'"
check "#184 and ran the suite on what it installed" "[ \"\$(sy_ran)\" -gt \"\$sy_before6\" ]"
check "#184 and carried the verdict in its closing line" \
  "line_has \"\$out_sy6\" 'Synced \(' 'hook suite passed here'"

section "== status sees a verdict the other clone on this Mac recorded (#187) =="
# .hook-tests lives in $SYNC_REPO, so it belongs to whichever clone did the work. This Mac has two
# on purpose: ~/claude-config-sync, which the scheduled job and the watch daemon run from, and the
# development checkout, which holds none of that state. Running status from the development checkout
# therefore could not see a failure the scheduled clone had recorded, and the scheduled clone is the
# one that pulls unattended, so its failures are exactly the ones nobody is watching for.
#
# The other clone is found from the launch agent plists, which NAME the script each job runs, and
# the fixture below writes them with the tool's own installer rather than by hand: a list of clones
# maintained beside the thing it describes checks only what somebody remembered to put in it (L41,
# L96), and a hand written plist would be a second opinion about a format only one writer produces.
#
# Whichever clone a record came from is SAID, because a reader who cannot tell which clone was
# verified cannot tell which config was verified either.
CLB="$WORK/clone-scheduled"; mkdir -p "$CLB/payload"
cp "$SCRIPT" "$CLB/claude-sync"
CLD="$WORK/clone-dev"; mkdir -p "$CLD/payload"
CLLA="$WORK/clone-agents"; mkdir -p "$CLLA"
CLH="$WORK/clone-home"; mkdir -p "$CLH/hooks"
echo '{"hooks":{}}' > "$CLH/settings.json"
# Written by the copy that lives in the scheduled clone, so the plist names THAT script, which is
# how the real pair is arranged.
SYNC_LAUNCHAGENTS="$CLLA" SYNC_NO_LAUNCHCTL=1 bash "$CLB/claude-sync" install-schedule >/dev/null 2>&1
# The temp root here is reached through a symlink, so the plist records the path it was GIVEN while
# the discovery resolves it, and the two spellings differ. Each assertion below therefore uses the
# spelling of whichever side it is reading: the plist holds the one the fixture named, and the line
# a reader is shown holds the resolved one (L215 in miniature, since comparing the wrong spelling
# would report a clone that WAS found as one that was not).
CLB_REAL="$(cd "$CLB" && pwd -P)"
CLB_ASWRITTEN="$(cd "$CLB" && pwd)"
check "#187 the fixture's plist really names the other clone" \
  "grep -q '$CLB_ASWRITTEN/claude-sync' '$CLLA/com.claudesync.pull.plist'"
# Its own register, deliberately empty and deliberately not the suite-wide one: this section is
# about what the LAUNCH AGENTS find, and a register shared with every other scenario in this file
# would answer for them (claude-config#189).
CLREG="$WORK/clone-registry-187"
clstatus(){   # status, run from the DEVELOPMENT clone, with the fixture's launch agents
  SYNC_LAUNCHAGENTS="${1:-$CLLA}" SYNC_CLONE_REGISTRY="$CLREG" CLAUDE_HOME="$CLH" SYNC_REPO="$CLD" \
    SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1
}

printf 'failed\t%s\t4\t?\t?\n' "$(date +%s)" > "$CLB/.hook-tests"
out_cl1="$(clstatus)"
dbg "status from the dev clone with a failure in the scheduled one: $out_cl1"
check "#187 status names a failure the other clone recorded" \
  "line_has \"\$out_cl1\" 'hook suite' 'FAILED' 'it exited 4\)'"
check "#187 and says which clone recorded it" \
  "line_has \"\$out_cl1\" 'hook suite' 'another clone on this Mac' '$CLB_REAL'"
# The label is the whole point: without it the reader is told a suite failed and cannot tell which
# config was checked, which is worse than being told nothing (L11).
check "#187 and does not present it as this clone's own record" \
  "! line_has \"\$out_cl1\" '^hook suite: ' 'FAILED'"

# This clone's own record still comes first and still reads as its own. Both at once is the real
# arrangement, and a reader has to be able to tell the two apart by their exit codes alone.
printf 'failed\t%s\t7\t?\t?\n' "$(date +%s)" > "$CLD/.hook-tests"
out_cl2="$(clstatus)"
dbg "status with a failure in each clone: $out_cl2"
check "#187 this clone's own failure is still reported as its own" \
  "line_has \"\$out_cl2\" '^hook suite: ' 'FAILED' 'it exited 7\)'"
check "#187 and the other clone's is reported beside it" \
  "line_has \"\$out_cl2\" 'another clone on this Mac' 'FAILED' 'it exited 4\)'"
rm -f "$CLD/.hook-tests"

# Quiet on a pass over there too, for the same reason it is quiet on one here: status reports what
# needs attention, and a pass does not.
printf 'passed\t%s\t0\t9\t0\n' "$(date +%s)" > "$CLB/.hook-tests"
out_cl3="$(clstatus)"
check "#187 a pass in the other clone says nothing" \
  "! line_has \"\$out_cl3\" 'hook suite' '(FAILED|unreadable|could NOT)'"

# A record nothing can read over there is said to be unreadable, and still labelled, or a half
# written file in the clone that pulls unattended reads as a clean Mac (L98).
printf 'not a record at all\n' > "$CLB/.hook-tests"
out_cl4="$(clstatus)"
check "#187 an unreadable record in the other clone is reported as such" \
  "line_has \"\$out_cl4\" 'hook suite' 'unreadable' '$CLB_REAL'"

# The negative control. With no launch agent naming another clone there is no other clone, and a
# discovery that reported one anyway would be inventing the thing it exists to find (L1, L159).
CLLA_EMPTY="$WORK/clone-agents-empty"; mkdir -p "$CLLA_EMPTY"
printf 'failed\t%s\t4\t?\t?\n' "$(date +%s)" > "$CLB/.hook-tests"
out_cl5="$(clstatus "$CLLA_EMPTY")"
check "#187 with no launch agent there is no other clone to report" \
  "! line_has \"\$out_cl5\" 'hook suite' 'another clone'"

# And a plist naming THIS clone is not a second clone. The scheduled job's own Mac runs status from
# the same directory the job runs from, and a record reported twice, once as its own and once as a
# stranger's, is a reader's problem rather than a checker's.
CLLA_SELF="$WORK/clone-agents-self"; mkdir -p "$CLLA_SELF"
cp "$SCRIPT" "$CLD/claude-sync"
SYNC_LAUNCHAGENTS="$CLLA_SELF" SYNC_NO_LAUNCHCTL=1 bash "$CLD/claude-sync" install-schedule >/dev/null 2>&1
printf 'failed\t%s\t7\t?\t?\n' "$(date +%s)" > "$CLD/.hook-tests"
out_cl6="$(clstatus "$CLLA_SELF")"
dbg "status whose only launch agent names its own clone: $out_cl6"
check "#187 that clone's own record is still reported" \
  "line_has \"\$out_cl6\" '^hook suite: ' 'FAILED' 'it exited 7\)'"
check "#187 and a plist naming this very clone is not reported as another one" \
  "! line_has \"\$out_cl6\" 'hook suite' 'another clone'"
rm -f "$CLD/.hook-tests"

section "== the coverage figures agree with the real runner's own words (#188) =="
# claude-config#185 reads how much of the suite ran out of the verdict line run-all-tests.sh prints,
# and it matches two exact sentences. Nothing held the two in step: reworded on either side, the
# reader matches neither shape and every pass reports its coverage as unknown from then on. That
# fails honestly rather than lying, which is why it was built that way, but it fails PERMANENTLY and
# silently, and a Mac that has stopped reporting coverage looks exactly like one whose runner is
# simply older (L41: a value that must mirror another source is derived from it, never written out
# beside it and hoped over).
#
# So both sentences are produced by the REAL runner here, and read by the REAL reader, over a
# fixture whose answer is known from how it was built. The runner is copied to a directory with NO
# repository above it, because that is the only state in which a suite may legitimately say it could
# not run, and it is the state every deployed Mac is in.
#
# Each scenario also asks the runner DIRECTLY what it said, in the same fixture. That control is the
# point: if the wording moves, the control fails and names the side that moved, rather than leaving
# a reader with a coverage figure that went quiet for no stated reason (L11, L159).
unset SYNC_NO_GIT
AGB="$WORK/agree-bare.git"; git init -q --bare "$AGB"
AGRA="$WORK/agree-repoA"; git clone -q "$AGB" "$AGRA" 2>/dev/null
AGRB="$WORK/agree-repoB"
AGHA="$WORK/agree-homeA"; mkdir -p "$AGHA/hooks"
echo '{"hooks":{}}' > "$AGHA/settings.json"
AGRUN="$WORK/agree-runner"; mkdir -p "$AGRUN"
cp "$(dirname "$SCRIPT")/payload/hooks/run-all-tests.sh" "$AGRUN/run-all-tests.sh"
cp -R "$(dirname "$SCRIPT")/payload/hooks/lib" "$AGRUN/lib" 2>/dev/null || true
AGSUITES="$WORK/agree-suites"; mkdir -p "$AGSUITES"
check "#188 the runner under test is the repo's own, not a stand-in" \
  "cmp -s '$(dirname "$SCRIPT")/payload/hooks/run-all-tests.sh' '$AGRUN/run-all-tests.sh'"
# No repository above it, asserted rather than assumed: with one there, the runner correctly calls a
# suite that claims it cannot run a FAILURE, and the partial-coverage shape could never be produced.
check "#188 and it sits where a suite may legitimately say it could not run" \
  "! git -C '$AGRUN' rev-parse --show-toplevel >/dev/null 2>&1"

mk_ag_suite(){    # a suite that runs and passes
  printf '#!/usr/bin/env bash\nprintf "SUITE-RESULT passed=1 failed=0\\n"\nexit 0\n' > "$AGSUITES/test-$1.sh"
  chmod +x "$AGSUITES/test-$1.sh"
}
mk_ag_notrun(){   # a suite that declares it cannot run here
  printf '#!/usr/bin/env bash\nprintf "SUITE-NOT-RUN it audits a repository and there is none here\\n"\nexit 2\n' > "$AGSUITES/test-$1.sh"
  chmod +x "$AGSUITES/test-$1.sh"
}
# The hook Mac B installs. It is a hook, so writing a new version of it is what makes a pull carry
# one and run the suite at all.
mk_ag_wrapper(){   # $1 = version marker
  printf '#!/usr/bin/env bash\n# v%s\nexec bash "%s/run-all-tests.sh" "%s"\n' "$1" "$AGRUN" "$AGSUITES" \
    > "$AGHA/hooks/run-all-tests.sh"
}
ag_field(){ hd_field "$(head -1 "$AGRB/.hook-tests" 2>/dev/null || true)" "$1"; }

rm -f "$AGSUITES"/test-*.sh
mk_ag_suite alpha; mk_ag_suite gamma
mk_ag_wrapper 1
CLAUDE_HOME="$AGHA" SYNC_REPO="$AGRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
git clone -q "$AGB" "$AGRB" 2>/dev/null
AGHB="$WORK/agree-homeB"; mkdir -p "$AGHB"
echo '{"hooks":{}}' > "$AGHB/settings.json"
ag_direct1="$(bash "$AGRUN/run-all-tests.sh" "$AGSUITES" 2>&1)"
dbg "the runner, asked directly, with everything runnable: $(printf '%s' "$ag_direct1" | tail -1)"
check "#188 the runner still says a full pass in the shape the reader matches" \
  "line_has \"\$ag_direct1\" '^ALL 2 SUITES PASSED\$' 'SUITES'"
out_ag1="$(CLAUDE_HOME="$AGHB" SYNC_REPO="$AGRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull whose runner ran everything: $out_ag1"
check "#188 and the closing line reads the same two suites out of it" \
  "line_has \"\$out_ag1\" 'Pulled shared config' 'hook suite passed here' 'all 2 of its suites'"
check "#188 and records both suites as having run" "[ \"\$(ag_field ran)\" = '2' ] && [ \"\$(ag_field notrun)\" = '0' ]"

rm -f "$AGSUITES"/test-*.sh
mk_ag_suite alpha; mk_ag_notrun beta
mk_ag_wrapper 2
CLAUDE_HOME="$AGHA" SYNC_REPO="$AGRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
ag_direct2="$(bash "$AGRUN/run-all-tests.sh" "$AGSUITES" 2>&1)"
dbg "the runner, asked directly, with one suite unable to run: $(printf '%s' "$ag_direct2" | tail -1)"
check "#188 the runner still says a partial pass in the shape the reader matches" \
  "line_has \"\$ag_direct2\" '^ALL 1 SUITES THAT COULD RUN PASSED, and 1 could not run here\$' 'PASSED'"
out_ag2="$(CLAUDE_HOME="$AGHB" SYNC_REPO="$AGRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull whose runner could not run one of its suites: $out_ag2"
check "#188 and the closing line reads the same counts out of it" \
  "line_has \"\$out_ag2\" 'Pulled shared config' 'hook suite passed here' 'only 1 of its 2 suites could run' '1 are unverified'"
check "#188 and records the one that ran and the one that could not" "[ \"\$(ag_field ran)\" = '1' ] && [ \"\$(ag_field notrun)\" = '1' ]"
# The failure this whole section exists to make loud: a reader that could not match either sentence
# still reports a pass, and says the coverage is unknown. Asserted here so the two scenarios above
# cannot both be satisfied by a reader that always answers unknown (L159).
check "#188 neither scenario was answered with the unknown fallback" \
  "! line_has \"\$out_ag1\$(printf '\\n')\$out_ag2\" 'Pulled shared config' 'did not say how many of its suites ran'"

section "== the scratch sweep reads every mtime in one call (#191) =="
# scratch_in_dir asked file_mtime for each matching entry, which is a stat PROCESS each.
# claude-config#115 removed the six full directory reads and left this behind. Measured 2026-08-23
# with 963 entries in the tool's own scratch directory after a day of interrupted runs: status took
# 6.5 seconds, of which the sweep was 5.6 and everything else 0.8 (SYNC_SCRATCH_MAX_AGE=0 isolates
# it). The cost grows with exactly the condition the report exists to describe, so the worse the
# leftovers, the slower the command that tells you about them, and status is the command a person
# is told to run.
#
# Which reading actually ran is COUNTED, through a stat that records its own calls, rather than
# inferred from how long the run took: a threshold on elapsed time is a threshold on what else the
# machine is doing (L224). And the two readings are required to AGREE on the same directory, which
# is what makes a batch answering with nothing a failure here rather than a directory that looks
# swept: an empty answer and no leftovers are indistinguishable otherwise (L215).
_BSROOT="$WORK/batch-scratch"; mkdir -p "$_BSROOT/claude-sync"
_BSH="$WORK/batch-home"; mkdir -p "$_BSH"; echo '{"hooks":{}}' > "$_BSH/settings.json"
_BSREPO="$WORK/batch-repo"; mkdir -p "$_BSREPO/payload"
_BSBIN="$WORK/batch-bin"; mkdir -p "$_BSBIN"
_BSCOUNT="$WORK/batch-stat-calls.txt"
_bs_real_stat="$(command -v stat)"
cat > "$_BSBIN/stat" <<BSSTAT
#!/usr/bin/env bash
printf 'call\n' >> "$_BSCOUNT"
exec "$_bs_real_stat" "\$@"
BSSTAT
chmod +x "$_BSBIN/stat"
_BS_AGED=40
_bs_i=1
while [ "$_bs_i" -le "$_BS_AGED" ]; do
  mkdir -p "$_BSROOT/claude-sync/claude-sync-suite-work.BATCH$_bs_i"
  scratch_age_out "$_BSROOT/claude-sync/claude-sync-suite-work.BATCH$_bs_i"
  _bs_i=$(( _bs_i + 1 ))
done
# Young ones too, so a reading that simply listed everything it found would not agree with a
# reading that judged the age (L146: the difference is what carries the information).
mkdir -p "$_BSROOT/claude-sync/claude-sync-suite-work.YOUNGA" "$_BSROOT/claude-sync/claude-sync-suite-work.YOUNGB"
_bs_run(){   # claude-sync, with the scratch root and the counting stat in front of it
  SYNC_SCRATCH_ROOT="$_BSROOT" CLAUDE_HOME="$_BSH" SYNC_REPO="$_BSREPO" \
    SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 PATH="$_BSBIN:$PATH" bash "$SCRIPT" "$@" 2>&1
}
# Called with no flags on purpose: the shim records whatever it is asked, and every FLAGGED
# spelling of stat is BSD-only or GNU-only, which the guard on portable spellings correctly refuses
# to see written outside the two helpers that own them (#38).
check "#191 the counting stat really is the one that gets run" \
  "rm -f '$_BSCOUNT'; PATH=\"$_BSBIN:\$PATH\" stat '$_BSROOT' >/dev/null 2>&1; [ -s '$_BSCOUNT' ]"

: > "$_BSCOUNT"
_bs_batch="$(_bs_run status | grep 'abandoned' || true)"
_bs_calls_batch="$(grep -c . "$_BSCOUNT" 2>/dev/null || true)"
case "$_bs_calls_batch" in ''|*[!0-9]*) _bs_calls_batch=0 ;; esac
: > "$_BSCOUNT"
_bs_each="$(SYNC_NO_BATCH_STAT=1 _bs_run status | grep 'abandoned' || true)"
_bs_calls_each="$(grep -c . "$_BSCOUNT" 2>/dev/null || true)"
case "$_bs_calls_each" in ''|*[!0-9]*) _bs_calls_each=0 ;; esac
dbg "batch reading said [$_bs_batch] in $_bs_calls_batch stat call(s); per entry said [$_bs_each] in $_bs_calls_each"

check "#191 the sweep counted the aged scratch and left the young alone" \
  "line_has \"\$_bs_batch\" '$_BS_AGED abandoned' 'holding'"
check "#191 and reading it one entry at a time reaches the same answer" \
  "[ -n \"\$_bs_batch\" ] && [ \"\$_bs_batch\" = \"\$_bs_each\" ]"
# Compared against the OTHER reading's count, measured in the same run, never against a number
# written here: what "few" means is set by how many entries the fixture holds (L224 in spirit).
check "#191 the per-entry reading really does ask once per entry" \
  "[ \"\$_bs_calls_each\" -ge \"$_BS_AGED\" ]"
check "#191 and the default reading asks a small fraction of that" \
  "[ \"\$_bs_calls_batch\" -gt 0 ] && [ \$(( _bs_calls_batch * 4 )) -lt \"\$_bs_calls_each\" ]"
# The fallback has to be reachable, and it has to be reached by every way the batch can fail to
# answer, not only by the switch that turns it off (L173). A stat that answers with something of
# the wrong SHAPE is the real one: GNU stat reads -f as "file system status" rather than as a
# format, so it answers that spelling with plenty of output that is not a list of mtimes, and a
# non-empty answer is not the same as a usable one (L156).
cat > "$_BSBIN/stat" <<BSSTAT2
#!/usr/bin/env bash
printf 'call\n' >> "$_BSCOUNT"
# Only the BATCH forms are broken, which are the two whose format names the path (%N or %n).
# Breaking every form would break the fallback as well, and the check would then pass because
# nothing worked at all rather than because the fallback ran (L178).
case "\$2" in
  *%N|*%n|*%N*|*%n*) printf '  File: "%s"\n  ID: 0 Namelen: 255\n' "\$3"; exit 0 ;;
esac
exec "$_bs_real_stat" "\$@"
BSSTAT2
chmod +x "$_BSBIN/stat"
_bs_shape="$(_bs_run status | grep 'abandoned' || true)"
check "#191 a batch answering in the wrong shape falls back rather than reporting nothing" \
  "[ \"\$_bs_shape\" = \"\$_bs_each\" ]"
cat > "$_BSBIN/stat" <<BSSTAT3
#!/usr/bin/env bash
printf 'call\n' >> "$_BSCOUNT"
exec "$_bs_real_stat" "\$@"
BSSTAT3
chmod +x "$_BSBIN/stat"

section "== a clone registers itself so a sibling can find its verdict (#189) =="
# claude-config#187 finds another clone from the launch agent plists, and those name only the clone
# a background job runs from, so discovery ran in ONE direction: status from the development
# checkout saw the scheduled clone, and status from the scheduled clone saw nothing at all.
#
# A clone now writes itself down the first time it takes the lock, which is the first time it can
# hold a verdict at all, so the list is derived from what has actually RUN rather than from what
# somebody remembered to name (L41, L96). Registering from a read-only command was deliberately not
# done: status changes nothing, and a clone that has only ever been asked questions has no record
# for anybody to find.
RGREG="$WORK/reg-registry"
RGH="$WORK/reg-home"; mkdir -p "$RGH"; echo '{"hooks":{}}' > "$RGH/settings.json"
RGA="$WORK/reg-cloneA"; mkdir -p "$RGA/payload"; cp "$SCRIPT" "$RGA/claude-sync"
RGB="$WORK/reg-cloneB"; mkdir -p "$RGB/payload"; cp "$SCRIPT" "$RGB/claude-sync"
# Deliberately empty. No launch agent names either clone here, so anything found is found by the
# register and by nothing else.
RGLA="$WORK/reg-agents"; mkdir -p "$RGLA"
rgstatus(){   # status, run from the clone named
  SYNC_CLONE_REGISTRY="$RGREG" SYNC_LAUNCHAGENTS="$RGLA" CLAUDE_HOME="$RGH" SYNC_REPO="$1" \
    SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1
}
rgpull(){     # a run that takes the lock, from the clone named
  SYNC_CLONE_REGISTRY="$RGREG" SYNC_LAUNCHAGENTS="$RGLA" CLAUDE_HOME="$RGH" SYNC_REPO="$1" \
    SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
}
RGA_REAL="$(cd "$RGA" && pwd -P)"

printf 'failed\t%s\t5\t?\t?\n' "$(date +%s)" > "$RGA/.hook-tests"
# Before anything has registered, there is nothing to find. Without this the checks below would be
# satisfied by a discovery that reported every directory it could think of (L1, L159).
out_rg0="$(rgstatus "$RGB")"
check "#189 nothing is found before any clone has recorded itself" \
  "! line_has \"\$out_rg0\" 'hook suite' 'another clone'"

rgpull "$RGA"
check "#189 a run that took the lock wrote its clone down" "grep -qxF '$RGA_REAL' '$RGREG'"
out_rg1="$(rgstatus "$RGB")"
dbg "status from the sibling once clone A had registered: $out_rg1"
check "#189 and the sibling now reports the record it holds" \
  "line_has \"\$out_rg1\" 'hook suite' 'another clone on this Mac' 'it exited 5\)'"
check "#189 and names the clone it came from" \
  "line_has \"\$out_rg1\" 'hook suite' 'another clone on this Mac' '$RGA_REAL'"

rgpull "$RGA"
check "#189 registering twice adds one line, not two" \
  "[ \"\$(grep -cxF '$RGA_REAL' '$RGREG')\" = '1' ]"

# A clone must not read its OWN record as a stranger's, or the same failure is reported twice and a
# reader cannot tell how many clones are actually in trouble.
out_rg2="$(rgstatus "$RGA")"
check "#189 the registered clone still reads its own record as its own" \
  "line_has \"\$out_rg2\" '^hook suite: ' 'it exited 5\)'"
check "#189 and not also as another clone's" \
  "! line_has \"\$out_rg2\" 'hook suite' 'another clone'"

# A register entry outlives the clone it names, because nothing prunes it. The reader has to notice,
# or a deleted clone becomes a permanent report about a verdict nobody can go and look at.
mv "$RGA/claude-sync" "$RGA/claude-sync.gone"
out_rg3="$(rgstatus "$RGB")"
check "#189 an entry naming a clone that has gone is skipped" \
  "! line_has \"\$out_rg3\" 'hook suite' 'another clone'"
mv "$RGA/claude-sync.gone" "$RGA/claude-sync"
out_rg4="$(rgstatus "$RGB")"
check "#189 and comes back when the clone does" \
  "line_has \"\$out_rg4\" 'hook suite' 'another clone on this Mac' 'it exited 5\)'"

# The default has to be per Mac and outside every clone, or the feature describes the wrong machine.
# Read off the script rather than asserted from memory, so moving it has to move this too (L41).
check "#189 the register lives outside every clone by default" \
  "grep -q 'CLONE_REGISTRY=\"\${SYNC_CLONE_REGISTRY:-\$HOME/.claude-sync-clones}\"' '$SCRIPT'"

section "== one Mac's home path never travels inside a synced file (#87) =="
# tok/detok existed, and were wired to settings.hooks.json alone. Every other payload file was
# copied verbatim, so an absolute home path inside one was simply wrong on whichever Mac did not
# author it: #86 found eight, and the failure is invisible on the machine that wrote the line.
# Two of them cannot be fixed by writing a tilde, because they are scriptPath values handed to the
# Workflow tool, which expands neither a tilde nor a variable, so they were left carrying a
# placeholder the model has to substitute at call time. That is a rule living only in a prompt
# (L27). Substituting on send and on apply makes it a property of the file instead.
unset SYNC_NO_GIT
TKB="$WORK/token-bare.git"; git init -q --bare "$TKB"
TKRA="$WORK/token-repoA"; git clone -q "$TKB" "$TKRA" 2>/dev/null
TKHA="$WORK/token-homeA"; mkdir -p "$TKHA/hooks" "$TKHA/skills/tokskill"
echo '{"model":"opus","hooks":{}}' > "$TKHA/settings.json"
printf '#!/usr/bin/env bash\nbash "%s/hooks/helper.sh" --run\n' "$TKHA" > "$TKHA/hooks/tokhook.sh"
chmod +x "$TKHA/hooks/tokhook.sh"
mkskill "$TKHA/skills/tokskill/SKILL.md" "scriptPath: $TKHA/skills/tokskill/panel.workflow.js"
# A binary, because the substitution is a text rewrite and corrupting one would be invisible: it
# would still be a file, still the right name, and nothing would report a problem (L104).
printf 'BIN\000\001\002\003ARY\000end' > "$TKHA/skills/tokskill/logo.bin"
tk_bin_sum="$(cksum < "$TKHA/skills/tokskill/logo.bin")"
CLAUDE_HOME="$TKHA" SYNC_REPO="$TKRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#87 the published hook carries the token"     "grep -q '__CLAUDE_HOME__/hooks/helper.sh' '$TKRA/payload/hooks/tokhook.sh'"
check "#87 and not the home that wrote it"           "! grep -q '$TKHA' '$TKRA/payload/hooks/tokhook.sh'"
check "#87 a skill's path is tokenized too"          "grep -q '__CLAUDE_HOME__/skills/tokskill' '$TKRA/payload/skills/tokskill/SKILL.md'"
check "#87 a binary travels byte for byte"           "[ \"\$(cksum < '$TKRA/payload/skills/tokskill/logo.bin')\" = \"\$tk_bin_sum\" ]"

TKRB="$WORK/token-repoB"; git clone -q "$TKB" "$TKRB" 2>/dev/null
TKHB="$WORK/token-homeB"; mkdir -p "$TKHB"
echo '{"model":"opus","hooks":{}}' > "$TKHB/settings.json"
CLAUDE_HOME="$TKHB" SYNC_REPO="$TKRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#87 the other Mac gets its OWN home in the hook" "grep -q '$TKHB/hooks/helper.sh' '$TKHB/hooks/tokhook.sh'"
check "#87 no token is left behind in it"              "! grep -q '__CLAUDE_HOME__' '$TKHB/hooks/tokhook.sh'"
check "#87 and the author's home is nowhere in it"     "! grep -q '$TKHA' '$TKHB/hooks/tokhook.sh'"
check "#87 the skill's path points at this Mac"        "grep -q '$TKHB/skills/tokskill/panel.workflow.js' '$TKHB/skills/tokskill/SKILL.md'"
check "#87 the hook is still executable here"          "[ -x '$TKHB/hooks/tokhook.sh' ]"
check "#87 the binary arrived unharmed"                "[ \"\$(cksum < '$TKHB/skills/tokskill/logo.bin')\" = \"\$tk_bin_sum\" ]"

# The one that decides whether this is safe to ship. A tokenized file NEVER equals its payload
# copy byte for byte, so a comparison that does not know about the token reads every one of them
# as locally ahead, holds it back on every apply, and the other Mac's edits to it stop arriving
# for good. Nothing announces that: the pull reports success and the file simply never changes.
printf '#!/usr/bin/env bash\nbash "%s/hooks/helper.sh" --run --verbose\n' "$TKHA" > "$TKHA/hooks/tokhook.sh"
CLAUDE_HOME="$TKHA" SYNC_REPO="$TKRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
out_tk="$(CLAUDE_HOME="$TKHB" SYNC_REPO="$TKRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "pull of an edited tokenized hook: $out_tk"
check "#87 an edit to a tokenized file still reaches the other Mac" \
  "grep -q -- '--run --verbose' '$TKHB/hooks/tokhook.sh'"
check "#87 rewritten for this Mac, again"  "grep -q '$TKHB/hooks/helper.sh' '$TKHB/hooks/tokhook.sh'"
check "#87 and the pull reports it as a received change" "line_has \"\$out_tk\" 'updated' 'hooks/tokhook\.sh'"

# ...and the other way round: a pull with nothing new must report nothing. The substitution makes
# the payload copy differ from the local copy by construction, so a comparison done on raw bytes
# would report every tokenized file as updated on EVERY pull. A change report that names files
# nothing changed is a change report nobody reads (L36).
out_tk2="$(CLAUDE_HOME="$TKHB" SYNC_REPO="$TKRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull 2>&1)"
dbg "second pull, nothing changed: $out_tk2"
check "#87 a pull with nothing new says so"        "printf '%s' \"\$out_tk2\" | grep -q 'Already up to date'"
check "#87 and names no file as received"          "! printf '%s' \"\$out_tk2\" | grep -q 'tokhook\.sh'"

# Nor may a send invent a commit out of the substitution. If the payload were rewritten to
# something different every time, the watcher would push a commit per run for ever.
tk_head_before="$(git -C "$TKRB" rev-parse HEAD 2>/dev/null)"
CLAUDE_HOME="$TKHB" SYNC_REPO="$TKRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
tk_head_after="$(git -C "$TKRB" rev-parse HEAD 2>/dev/null)"
check "#87 a send with nothing to say makes no commit" "[ -n \"\$tk_head_before\" ] && [ \"\$tk_head_before\" = \"\$tk_head_after\" ]"
check "#87 and the payload still holds the token"      "grep -q '__CLAUDE_HOME__/hooks/helper.sh' '$TKRB/payload/hooks/tokhook.sh'"

# The round trip in the other direction: this Mac writes an absolute path of its own, and the
# first Mac must receive it pointing at ITS home, not at the author's.
printf '#!/usr/bin/env bash\nbash "%s/hooks/second.sh"\n' "$TKHB" > "$TKHB/hooks/tokback.sh"
chmod +x "$TKHB/hooks/tokback.sh"
CLAUDE_HOME="$TKHB" SYNC_REPO="$TKRB" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
check "#87 a path written here is tokenized on the way up" \
  "grep -q '__CLAUDE_HOME__/hooks/second.sh' '$TKRB/payload/hooks/tokback.sh'"
CLAUDE_HOME="$TKHA" SYNC_REPO="$TKRA" SYNC_NO_NOTIFY=1 bash "$SCRIPT" pull >/dev/null 2>&1
check "#87 and lands on the other Mac as its own home" "grep -q '$TKHA/hooks/second.sh' '$TKHA/hooks/tokback.sh'"
check "#87 with no trace of the Mac that wrote it"     "! grep -q '$TKHB' '$TKHA/hooks/tokback.sh'"


section "== the suite can run ONE section, and what it needs (#105) =="
# SECTION_UNTIL runs from the top UP TO a section, so reaching the last section costs a full run,
# and the last section is where new work lands. SECTION_ONLY runs the PRELUDE plus one section plus
# anything that section declares it needs.
#
# The prelude is the preamble and the first four sections. That boundary is not a guess: the only
# lines in the whole file that change shared state are `export CLAUDE_HOME="$CH2"` and
# `unset SYNC_NO_GIT`, both inside those four, so every section after them runs in one fixed
# ambient state. Measured on 2026-08-20 by running all 73 later sections in isolation: 68 passed
# alone with no mechanism at all, and the five that did not needed a variable an earlier section
# had set.
#
# Four of those five were accidents and are gone (see the fixtures hoisted into the preamble). What
# is left is declared as a `# needs:` COMMENT on the line after the heading, deliberately NOT as an
# argument to `section`: three separate derivations in this file parse `^section "..."$` by
# stripping one trailing quote, and one of them (#37's `_late`) would fail SILENTLY, leaving the
# guard that proves a filtered child does not run past its limit passing for the wrong reason.

_pe_hits="$(grep '^section "' "$SCRIPT_SELF" | grep -cF -- "$SUITE_PRELUDE_END")"
check "#105 the prelude boundary names exactly one heading" "[ '$_pe_hits' -eq 1 ]"

# A late, cheap section, run entirely on its own.
_SO1="$WORK/so-one.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_ONLY="one renderer turns a length of time into words" bash "$SCRIPT_SELF" > "$_SO1" 2>&1; _so1_rc=$?
dbg "#105 one-section run: $(tail -c 300 "$_SO1" | tr '\n' '|')"
check "#105 a late section can be run on its own" "[ '$_so1_rc' -eq 0 ]"
check "#105 and it ran the section asked for" "grep -q 'one renderer turns a length of time into words' '$_SO1'"
check "#105 the prelude ran with it" "grep -q '^== push ==' '$_SO1'"
check "#105 but the sections in between did not" "! grep -q 'repo hygiene' '$_SO1'"
check "#105 the summary names the heading it resolved and says NOT a full run" \
  "line_has \"\$(cat '$_SO1')\" 'SECTION_ONLY' 'one renderer' 'NOT a full run'"

# Ambiguity. SECTION_UNTIL gets away with first-match-wins because "run up to" has a natural
# earliest answer; "run only" does not, and silently running a section nobody asked for while
# reporting success under the typed pattern is a filter that matched the wrong thing (L100, L154).
_SO2="$WORK/so-amb.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_ONLY="pull" bash "$SCRIPT_SELF" > "$_SO2" 2>&1; _so2_rc=$?
check "#105 an ambiguous pattern is refused" "[ '$_so2_rc' -ne 0 ]"
check "#105 the ambiguity refusal says how many it matched" "line_has \"\$(cat '$_SO2')\" 'SECTION_ONLY' 'matches [0-9]+ sections'"
check "#105 an ambiguous pattern runs nothing at all" "! grep -q '^PASS=' '$_SO2'"

_SO3="$WORK/so-none.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_ONLY=zzz-no-such-section bash "$SCRIPT_SELF" > "$_SO3" 2>&1; _so3_rc=$?
check "#105 a pattern matching no section is refused" "[ '$_so3_rc' -ne 0 ]"
check "#105 and says it matched none" "grep -qi 'matched no section' '$_SO3'"

# Both filters at once is a refusal, not a precedence rule: whichever won, the run would be doing
# something other than what one of the two knobs asked for, and nothing would say so.
_SO4="$WORK/so-both.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_ONLY=push SECTION_UNTIL=push bash "$SCRIPT_SELF" > "$_SO4" 2>&1; _so4_rc=$?
check "#105 asking for both filters at once is refused" "[ '$_so4_rc' -ne 0 ]"
check "#105 the both-filters refusal names both" "line_has \"\$(cat '$_SO4')\" 'SECTION_ONLY' 'SECTION_UNTIL'"

# The one real dependency left in the file, declared and honoured.
_SO5="$WORK/so-needs.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_ONLY="#17: a collision the merge creates" bash "$SCRIPT_SELF" > "$_SO5" 2>&1; _so5_rc=$?
check "#105 a section that declares a prerequisite runs green on its own" "[ '$_so5_rc' -eq 0 ]"
check "#105 and its prerequisite ran with it" "grep -q 'duplicate lesson numbers' '$_SO5'"
check "#105 while the sections it does not need stayed out" "! grep -q 'repo hygiene' '$_SO5'"

# A declaration that resolves to nothing is an error before anything runs. Tested on a COPY with the
# declaration corrupted, because the real file has to stay correct (L151: every outcome the contract
# enumerates needs a test that produces it).
_SOBAD="$WORK/so-badneeds.sh"
sed 's/^# needs: .*/# needs: zzz-no-such-prerequisite/' "$SCRIPT_SELF" > "$_SOBAD"
_sobad_n="$(grep -c '^# needs: zzz-no-such-prerequisite' "$_SOBAD")"
check "#105 the corrupted copy really carries a bad declaration" "[ '$_sobad_n' -ge 1 ]"
_SO6="$WORK/so-badneeds.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SCRIPT="$SCRIPT" SCRIPT_SELF="$_SOBAD" SECTION_ONLY="#17: a collision the merge creates" bash "$_SOBAD" > "$_SO6" 2>&1; _so6_rc=$?
check "#105 a declaration naming no section is refused" "[ '$_so6_rc' -ne 0 ]"
check "#105 and the refusal names the text it could not resolve" "grep -q 'zzz-no-such-prerequisite' '$_SO6'"

# A section that is missing a prerequisite must not be able to report green. This is the failure
# mode that makes the whole mechanism dangerous rather than merely wrong: `set -u` kills the SHELL
# on an unbound variable at top level, but only the SUBSHELL when the read is inside $( ), so a
# section can lose four tool invocations to a missing fixture, print nothing but ok lines, and exit
# 0. Measured on this file, written down 2026-08-21: one section did exactly that, 54 ok lines and no
# failures, and the only
# reason it did not report success was that a fifth read happened to sit at top level.
#
# Proven against a REAL dependency rather than a planted one: the copy has the genuine `# needs:`
# declaration stripped, so the section really does lose its prerequisite (L48, L159).
_SOUB="$WORK/so-noneeds.sh"
grep -v '^# needs: ' "$SCRIPT_SELF" > "$_SOUB"
_soub_n="$(grep -c '^# needs: ' "$_SOUB" || true)"
check "#105 the stripped copy really has no declarations left" "[ '$_soub_n' -eq 0 ]"
_SO7="$WORK/so-unbound.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SCRIPT="$SCRIPT" SCRIPT_SELF="$_SOUB" SECTION_ONLY="#17: a collision the merge creates" bash "$_SOUB" > "$_SO7" 2>&1; _so7_rc=$?
check "#105 a section run without its prerequisite does not report success" "[ '$_so7_rc' -ne 0 ]"
check "#105 and says the run's result cannot be trusted" "line_has \"\$(cat '$_SO7')\" 'unbound variable' 'NOT trustworthy'"
check "#105 and names the section it was running" "grep -q 'a collision the merge creates' '$_SO7'"

# The case that makes the guard necessary rather than tidy: a read that happens ONLY inside a
# command substitution, where set -u kills the subshell and nothing else, so every check still
# passes. No section in this file has that shape today, so it is CONSTRUCTED. A guard whose
# dangerous case cannot be produced has not been watched doing the thing it exists for (L151, L159).
_SOSUB="$WORK/so-subshell.sh"
awk '/^suite_profile$/ && !ins { print "section \"== zzz a constructed subshell only dependency ==\""; print "_zz_out=\"$(printf %s \"$ZZ_NO_SUCH_FIXTURE\")\""; print "check \"zzz this check passes regardless\" \"true\""; ins=1 } { print }' "$SCRIPT_SELF" > "$_SOSUB"
check "#105 the constructed copy carries a subshell only read" "grep -q 'ZZ_NO_SUCH_FIXTURE' '$_SOSUB'"
_SO8="$WORK/so-subshell.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SCRIPT="$SCRIPT" SCRIPT_SELF="$_SOSUB" SECTION_ONLY="zzz a constructed subshell only dependency" bash "$_SOSUB" > "$_SO8" 2>&1; _so8_rc=$?
check "#105 a run that loses only a subshell is refused too" "[ '$_so8_rc' -ne 0 ]"
check "#105 even though every check inside it passed" "grep -q 'FAIL=0' '$_SO8'"

# The filter must not be inherited. SUITE_FILTERED had exactly this defect and it cost two runaways
# on 2026-08-17 (#37): a child read the flag as being about ITSELF. Proven the same way #37 proves
# its own, from the outside, with a real run that RECEIVED the value starting a real child.
_SOG="$(SUITE_FILTERED=1 SUITE_DEPTH="$SUITE_DEPTH" SECTION_ONLY=push SUITE_SPAWN_UNTIL=push SUITE_TIMEOUT=90 bash "$SCRIPT_SELF" 2>&1)"
check "#105 the spawn probe for that started a child" "printf '%s' \"\$_SOG\" | grep -q 'the child exited'"
check "#105 a child does not inherit the one-section filter" \
  "printf '%s' \"\$_SOG\" | grep -q 'inherits SECTION_ONLY as: <unset>'"

# The title derivation, proved on the shape that would have broken it (claude-config#111). It uses
# the one expression the real derivations use, not a copy written beside them, or the check could
# pass while the code did something else (L107).
_hd_trail="$(section_title 'section "== a heading ==" # and a trailing comment')"
check "#111 a heading carrying trailing text still derives just its title" "[ \"\$_hd_trail\" = '== a heading ==' ]"
_hd_plain="$(section_title 'section "== a heading =="')"
check "#111 and an ordinary heading is unchanged by it" "[ \"\$_hd_plain\" = '== a heading ==' ]"
# The old expression, asked of the same trailing-text line. It mangles it, which is the defect, and
# keeping the evidence next to the fix is what stops somebody reverting it as noise.
_hd_old="$(printf '%s\n' 'section "== a heading ==" # and a trailing comment' | sed 's/^section "//; s/"$//')"
check "#111 the old expression would have mangled it" "[ \"\$_hd_old\" != '== a heading ==' ]"

# SECTION_UNTIL is held to the same rules, because two knobs sitting beside each other with
# different rules means which rules apply depends on which one you happened to reach for
# (claude-config#110).
_SU1="$WORK/su-amb.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL="pull" bash "$SCRIPT_SELF" > "$_SU1" 2>&1; _su1_rc=$?
check "#110 an ambiguous SECTION_UNTIL is refused too" "[ '$_su1_rc' -ne 0 ]"
check "#110 and it lists the candidates" "line_has \"\$(cat '$_SU1')\" 'SECTION_UNTIL' 'matches [0-9]+ sections'"
check "#110 an ambiguous SECTION_UNTIL runs nothing" "! grep -q '^PASS=' '$_SU1'"

# A filtered run reports the PRELUDE's checks in its total as well, so a section that ran none of
# its own still shows a healthy looking number under its name. That is the same shape as a scan
# that read nothing reporting a clean tree (L98). Constructed, because no section in this file has
# no checks, and the point is that the total is NOT evidence about the section named.
_SONC="$WORK/so-nochecks.sh"
awk '/^suite_profile$/ && !ins { print "section \"== zzz a section with no checks of its own ==\""; print "echo \"nothing is asserted here\""; ins=1 } { print }' "$SCRIPT_SELF" > "$_SONC"
check "#110 the constructed copy carries a section that checks nothing" "grep -q 'zzz a section with no checks' '$_SONC'"
_SO9="$WORK/so-nochecks.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SCRIPT="$SCRIPT" SCRIPT_SELF="$_SONC" SECTION_ONLY="zzz a section with no checks" bash "$_SONC" > "$_SO9" 2>&1; _so9_rc=$?
check "#110 a run whose target checked nothing is refused" "[ '$_so9_rc' -ne 0 ]"
check "#110 and says the section itself ran none" "grep -q 'ran NO checks of its own' '$_SO9'"
check "#110 even though the run as a whole reported no failures" "grep -q 'FAIL=0' '$_SO9'"

# And the un-export has to sit ahead of every spawn site, or a site above it still hands it on.
# Derived, and the pattern assembled from pieces so the check cannot be satisfied by its own line.
_soexp_pat="export"" -n SUITE_FILTERED SECTION_ONLY SECTION_LIST"
_soexp_line="$(grep -nF "$_soexp_pat" "$SCRIPT_SELF" | head -1 | cut -d: -f1)"
_sospawn_first="$(grep -nF "bash \"\$SCRIPT""_SELF\"" "$SCRIPT_SELF" | head -1 | cut -d: -f1)"
check "#105 the filter is un-exported before anything spawns a run" \
  "[ -n \"\$_soexp_line\" ] && [ -n \"\$_sospawn_first\" ] && [ \"\$_soexp_line\" -lt \"\$_sospawn_first\" ]"

section "== every heading this file writes is one its own reader can see (#138) =="
# The collector recognises exactly one shape: a `section` call at column zero whose title is a
# literal string, and it takes the title by dropping everything from the last quote. A heading
# written any other way still RUNS in a full run, which is what makes it invisible rather than
# lost: it travels with the section above it, so SECTION_ONLY cannot reach it, the changed-section
# audit never runs it alone, and #137's coverage check cannot see it either, because both sides of
# that check read the list through this one parser. Every count in the file goes on agreeing with
# every other count while one section has quietly stopped being independently testable.
#
# So the headings written ANY way are counted here, the ones the reader can see are asked of the
# READER (SECTION_LIST, the same answer the changed-section audit reads), and a difference is
# refused. Deliberately not a second parser written beside the first: it would drift from it, and
# it would be the half deciding whether a section is independently testable (L107).
_hd_any(){    # _hd_any <file> -> every line that calls section, however it is written
  grep -nE '^[[:blank:]]*section[[:blank:]]' "$1" || true
}
_hd_reader(){ # _hd_reader <file> -> the headings that file's own reader can see, one per line
  # Taken by the RECORD SHAPE the listing prints, a line number, a tab and the title, never by
  # "every line the child said". A child started from inside a run announces its depth on stdout,
  # and that notice counted as a heading: the reader appeared to see one MORE heading than the file
  # writes, which is the failure this section exists to report, arriving from the harness rather
  # than from the file (L156).
  SUITE_DEPTH=$SUITE_CHILD_DEPTH SCRIPT="$SCRIPT" SCRIPT_SELF="$1" SECTION_LIST=1 bash "$1" 2>/dev/null \
    | grep -E '^[0-9]+'"$(printf '\t')" || true
}
_hd_calls="$(_hd_any "$SCRIPT_SELF" | grep -c . || true)"
_hd_list="$(_hd_reader "$SCRIPT_SELF")"
_hd_seen="$(printf '%s' "$_hd_list" | grep -c . || true)"
echo "  (#138 headings written: $_hd_calls, headings the reader can see: $_hd_seen)"
# The floor first, and it is a floor rather than today's count: both numbers are read from the same
# file, and two zeros agree with each other perfectly, so a scan that read nothing would satisfy
# the comparison below and report a clean file (L98).
check "#138 both readings really read this suite" \
  "[ \"\${_hd_calls:-0}\" -ge 80 ] && [ \"\${_hd_seen:-0}\" -ge 80 ]"
check "#138 every heading written is a heading the reader can see" "[ \"\$_hd_calls\" -eq \"\$_hd_seen\" ]"
# Named, not counted. A count tells you a heading is invisible; the line tells you which one, and
# finding it by hand means reading every heading in the file (L11).
[ "$_hd_calls" -eq "$_hd_seen" ] || _hd_any "$SCRIPT_SELF" | grep -v ':section "' | sed 's/^/    invisible to the reader: /'
# Listed is not the same as REACHABLE. A title assembled from a variable IS collected, and the
# string the reader derives for it is the unexpanded text, which no pattern anybody types can
# match, so the section is listed and still cannot be run alone.
# Counted rather than matched with `grep -q`, which leaves on its first hit and can kill its own
# producer under pipefail (#132, L183), and the offenders are NAMED for the same reason as above.
_hd_built="$(printf '%s' "$_hd_list" | grep '[$`]' || true)"
check "#138 and every title the reader derived is literal, so a pattern can reach it" \
  "[ -z \"\$_hd_built\" ]"
[ -z "$_hd_built" ] || printf '%s\n' "$_hd_built" | sed 's/^/    listed, but no pattern can reach it: /'

# The positive control, on the file actually being scanned rather than on a fixture built for it.
# There are no unreadable headings today, and a zero is read as proof the shape cannot occur rather
# than as a measurement (L182), so one of each shape is planted in a COPY and both halves are
# required to move by exactly the planted amount. Exactly, not at least, so it says two things at
# once: both readings are alive here, and the real file really did contribute none of either.
# Without it a reading broken by a later edit reports the two numbers equal and reads as clean
# (L98, L171).
_HDPOS="$WORK/heading-positive-control.sh"
cp "$SCRIPT_SELF" "$_HDPOS"
# Prefixed and stripped, so the plants live in this file without the scan above finding them: a
# control whose fixture is caught by the scan it is testing would fire on itself.
sed 's/^@@//' >> "$_HDPOS" <<'HDPLANT'
@@  section "== zzz planted, indented past the only column the reader looks at =="
@@section "== zzz planted, assembled from $HD_NO_SUCH_VARIABLE =="
HDPLANT
_hdp_calls="$(_hd_any "$_HDPOS" | grep -c . || true)"
_hdp_list="$(_hd_reader "$_HDPOS")"
_hdp_seen="$(printf '%s' "$_hdp_list" | grep -c . || true)"
dbg "#138 control: calls $_hd_calls -> $_hdp_calls, reader $_hd_seen -> $_hdp_seen"
check "#138 the planted copy really carries both shapes" "[ \"\$_hdp_calls\" -eq \$(( _hd_calls + 2 )) ]"
check "#138 an indented heading is one the reader cannot see, and the comparison notices" \
  "[ \"\$_hdp_seen\" -eq \$(( _hd_seen + 1 )) ]"
_hdp_built="$(printf '%s' "$_hdp_list" | grep -c 'HD_NO_SUCH_VARIABLE' || true)"
check "#138 an assembled heading is listed, and its title is one nothing can match" \
  "[ \"\${_hdp_built:-0}\" -eq 1 ]"
rm -f "$_HDPOS"

# The one count about this file that a check CAN derive, derived (#140). Two comments say the
# prelude is the first four sections, and the boundary is named by its heading TEXT so that
# inserting a section cannot move it. Nothing checked that the two agree, so moving the boundary
# would leave both sentences wrong and every run green. Asked of the reader's own list, which is
# the same answer everything else about section order is taken from.
_hd_prelude_n="$(printf '%s' "$_hd_list" | grep -nF -- "$SUITE_PRELUDE_END" | awk -F: 'NR==1{print $1}')"
check "#140 the prelude really is the first four sections, as two comments say" \
  "[ \"\${_hd_prelude_n:-0}\" -eq 4 ]"

section "== a comment that quotes a measured number says when it was measured (#140, #145) =="
# Six comments and one CI step quoted how many sections this suite has, and every number was from
# an earlier week. Each had been measured to justify a decision (where the prelude ends, whether
# sharding was worth it, how long the changed-section audit costs), so a stale one makes the
# reasoning beside it read as current when it is not, and a passing suite makes those sentences
# MORE trusted rather than less (L210).
#
# #140 covered ONE kind of number, a count of this suite's sections, and the same comments quoted
# durations and counts of other things that are just as perishable and had no reviewer at all
# (#145, L129). So the rule is the same and the scope is wider: a comment block that quotes a
# measured quantity says WHEN, and the date is one date anywhere in the same BLOCK, which is the
# unit a reader takes in and the reason the block rather than the line is scanned. These sentences
# wrap, and the number and its date routinely sit on different lines of one paragraph.
#
# What counts as a measured quantity, and what does not, because a regex cannot tell a number
# somebody MEASURED from a number somebody CHOSE and pretending otherwise would put dates on
# settings that never go stale:
#
#   a duration           200 seconds, 1192s, 8.4 seconds, 3 hours
#   a count of the       38 suites, 82 sections, 233 checks, 800 files, 6500 lines
#     things this repo
#     is made of
#
# and two ways out, both of them visible at the site rather than in a list somewhere else:
#
#   a date              anywhere in the block, in the form 2026-08-21
#   "not measured"      for a number the code SETS, which cannot go stale because the code beside
#     or "not a           it is the authority. A deadline of 900s, a 90s cooldown and a size a
#     measurement"        fixture builds are facts about the program, not observations of it.
#
# A number inside a code span is code and not a claim, so `head -20 file` is left alone.
#
# Zero is not a measurement of anything. Sections legitimately read 0s, and a broken timer reads 0s
# everywhere too, which is why SUITE_SLOW_IN exists; dating those sentences would say nothing.
#
# What it still cannot see, said plainly: a quantity written in words rather than digits, and a
# count of something this list does not name. It narrows how a perishable number can be written
# down rather than proving nobody can write one (L11).
#
# Markdown needs a different block rule, because the rule here is "a run of lines beginning with
# #" and in markdown that character starts a HEADING. It has one, further down (#148), and this
# part reads shell and workflows only.
_SC_MEASURED='(^|[^#[:alnum:]=.])[1-9][0-9]*(,[0-9][0-9][0-9])*([.][0-9]+)? *(s|ms|secs?|seconds?|mins?|minutes?|hours?)([^A-Za-z=]|$)|(^|[^#[:alnum:]=.])[1-9][0-9]*(,[0-9][0-9][0-9])* +([a-z-]+ +)?(sections?|suites?|checks?|files?|lines?|director(y|ies))([^A-Za-z=]|$)|(^|[^#[:alnum:]=.])[0-9]+ +(after|before) +the +prelude'
_SC_AWK="$WORK/stale-counts.awk"
cat > "$_SC_AWK" <<'SCAWK'
function flush() {
  t = buf
  gsub(/`[^`]*`/, " ", t)
  if (t != "" && t ~ COUNT && t !~ /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && t !~ /not( a)? measure/) printf "%s:%d: %s\n", FILENAME, start, buf
  buf = ""; start = 0
}
/^[[:space:]]*#/ {
  line = $0
  sub(/^[[:space:]]*#[[:space:]]?/, "", line)
  if (buf == "") { start = FNR; buf = line } else { buf = buf " " line }
  next
}
{ flush() }
END { flush() }
SCAWK
# One file per invocation, deliberately. A block is ended by the first line that is not a comment,
# so two files read in one pass can have the tail of one joined to the head of the next, and the
# report would name a line in the wrong file.
_sc_scan(){   # _sc_scan <file>... -> the undated measurements, one block per line
  for _sc_f in "$@"; do awk -v COUNT="$_SC_MEASURED" -f "$_SC_AWK" "$_sc_f"; done
}
_sc_root="$(cd "$(dirname "$SCRIPT")" && pwd)"
# Every shell script and workflow the repo TRACKS, asked of git rather than named here. #140 read
# three files, chosen because they were the three that talked about this suite's sections. That is
# the hand written list this repo keeps removing: a file missing from it is exempt from the very
# check meant to catch it, and the numbers #145 was opened about were in a fourth file nobody had
# added (L96, L41).
_sc_files="$(git -C "$_sc_root" ls-files '*.sh' '*.yml' '*.yaml' 2>/dev/null)"
_sc_n_files="$(printf '%s' "$_sc_files" | grep -c . || true)"
# A scan handed no files reports nothing and reads as a clean tree (L98). The floor is a real
# count rather than "more than zero", because one file coming back would also read as clean.
check "#145 the scan has the repo's shell and workflow files to read" \
  "[ \"\${_sc_n_files:-0}\" -gt 30 ]"
# And the files the rule was WRITTEN about are actually among them, so a pathspec that quietly
# stopped matching workflows could not leave the scan looking healthy (L100).
for _sc_want in tests/test-claude-sync.sh .github/workflows/tests.yml tests/audit-changed-sections.sh payload/hooks/run-all-tests.sh; do
  check "#145 and $_sc_want is one of them" \
    "printf '%s\n' \"\$_sc_files\" | grep -qx '$_sc_want'"
done
_sc_bad="$(printf '%s\n' "$_sc_files" | while IFS= read -r _sc_one; do
  [ -n "$_sc_one" ] || continue
  _sc_scan "$_sc_root/$_sc_one"
done)"
if [ -n "$_sc_bad" ]; then
  echo "  (#145 comment blocks quoting a measured number without saying when:)"
  printf '%s\n' "$_sc_bad" | cut -c1-160 | sed 's/^/    /'
  echo "    Either say when it was measured, or say it is not measured if the code sets it."
fi
check "#145 no comment quotes a measured number without saying when" "[ -z \"\$_sc_bad\" ]"

# Both directions, on a fixture built for it: the scan has to LEAVE the dated, the set and the
# quoted-as-code alone as well as catch the undated. A scan that reported everything would also
# report nothing wrong once the files were clean, and the two are told apart only by the half that
# must stay silent (L104, L159).
_SCFIX="$WORK/stale-counts-fixture.txt"
{
  printf '# a dated block: measured on 2026-01-02, when the file held 12 sections\n'
  printf 'this line is not a comment, so it ends the block\n'
  printf '# an undated block: the file has 12 sections, of which 3 are slow\n'
  printf 'and this one ends that block\n'
  printf '# a third block: 12 after the prelude, the other spelling, undated\n'
  printf 'ends it\n'
  printf '# an undated duration: the whole thing took 200 seconds\n'
  printf 'ends it\n'
  printf '# a duration written against the number: it fired at 1192s\n'
  printf 'ends it\n'
  printf '# an undated count of another thing: the repo holds 38 suites\n'
  printf 'ends it\n'
  printf '# a number this code sets: it gives up after 900s, not measured\n'
  printf 'ends it\n'
  printf '# a number quoted as code: run `head -20 file` to see the frontmatter\n'
  printf 'ends it\n'
  printf '# a degenerate reading: most sections read 0s and a broken timer reads 0s too\n'
} > "$_SCFIX"
_sc_fix="$(_sc_scan "$_SCFIX")"
dbg "#145 fixture scan: $(printf '%s' "$_sc_fix" | tr '\n' '|')"
# Counted, not matched with `grep -q`: that leaves on its first hit and can kill its own producer
# under pipefail (#132, L183).
for _sc_hit in 3 5 7 9 11; do
  check "#145 the scan catches the undated block on line $_sc_hit" \
    "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c ':$_sc_hit:' | tr -d ' ')\" = 1 ]"
done
for _sc_quiet in 1 13 15 17; do
  check "#145 and leaves the block on line $_sc_quiet alone" \
    "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c ':$_sc_quiet:' | tr -d ' ')\" = 0 ]"
done
# And nothing else at all, so a scan that reported every block would fail here even though each
# check above passed (L178).
check "#145 and reports those five and nothing else" \
  "[ \"\$(printf '%s' \"\$_sc_fix\" | grep -c . | tr -d ' ')\" = 5 ]"

# And on a real file, because a scanner alive on a fixture it was handed can still be blind to the
# files it actually reads: the zero above is only a measurement if planting one moves it (L182,
# L171). Prefixed and stripped so the plant lives here without the scan finding it.
_SCPOS="$WORK/stale-counts-positive-control.sh"
cp "$SCRIPT_SELF" "$_SCPOS"
sed 's/^@@//' >> "$_SCPOS" <<'SCPLANT'
@@echo "zzz this line ends whatever block came before it"
@@# zzz planted: this run took 999 seconds and nothing here says when
SCPLANT
_sc_self_n="$(_sc_scan "$SCRIPT_SELF" | grep -c . || true)"
_sc_pos="$(_sc_scan "$_SCPOS" | grep -c . || true)"
dbg "#145 control: the real file reports $_sc_self_n, the planted copy reports $_sc_pos"
# One MORE than the same file unplanted, never a flat 1: written as an absolute it would also fail
# whenever the file really did carry an undated measurement, and a run reporting two failures for
# one defect makes the reader look for two (L11).
check "#145 the count above is a live measurement, not a scan reading nothing" \
  "[ \"\${_sc_pos:-0}\" -eq \$(( _sc_self_n + 1 )) ]"
rm -f "$_SCPOS"

# ---- the same rule over this repo's own markdown (#148) ----
# #145 read shell and workflows and left markdown out, because the block rule there is a run of
# lines beginning with #, and in markdown that character starts a HEADING: every heading would
# read as a one line block and every paragraph as the thing that ends one. The exemption was named
# rather than left silent (L129), and this is it being closed.
#
# Markdown needs its own idea of a block, and it is not the same idea:
#
#   a paragraph      a run of non-blank lines, ended by a blank one
#   a table row      its own block, because a table is not a paragraph and a date in one row says
#                    nothing about the row under it
#   a list item      its own block, continuing over the lines that wrap it
#   a fenced block   skipped entirely, for the same reason a code span is: it is code, not a claim
#
# Scoped to markdown at the REPO ROOT, which is this repo's own documentation. Everything under
# payload/ is content this repo FERRIES to other machines rather than writes, and most of it is
# third party skills whose numbers are somebody else's claims to date or not: measured on
# 2026-08-21, 76 blocks across the tracked markdown, 52 of them in vendored skills. LESSONS.md is
# deliberately outside it too, and for a better reason than volume: every lesson carries the issue
# it came from, which is provenance a date cannot improve on.
_SC_MD_AWK="$WORK/stale-counts-md.awk"
cat > "$_SC_MD_AWK" <<'SCMDAWK'
function flush() {
  t = buf
  gsub(/`[^`]*`/, " ", t)
  if (t != "" && t ~ COUNT && t !~ /20[0-9][0-9]-[0-9][0-9]-[0-9][0-9]/ && t !~ /not( a)? measure/) printf "%s:%d: %s\n", FILENAME, start, buf
  buf = ""; start = 0
}
/^[[:space:]]*```/ { flush(); fence = !fence; next }
fence { next }
/^[[:space:]]*$/ { flush(); next }
/^[[:space:]]*[|]/ { flush(); start = FNR; buf = $0; flush(); next }
/^[[:space:]]*([-*+]|[0-9]+[.])[[:space:]]/ { flush(); start = FNR; buf = $0; next }
{ if (buf == "") { start = FNR; buf = $0 } else { buf = buf " " $0 } }
END { flush() }
SCMDAWK
_sc_md_scan(){   # _sc_md_scan <file>... -> the undated measurements, one block per line
  for _sc_mf in "$@"; do awk -v COUNT="$_SC_MEASURED" -f "$_SC_MD_AWK" "$_sc_mf"; done
}
# Root level markdown, asked of git and filtered by having no directory in its path, so a document
# added beside README.md is covered on the day it lands and nothing here needs maintaining.
_sc_md_files="$(git -C "$_sc_root" ls-files '*.md' 2>/dev/null | grep -v /)"
_sc_md_n="$(printf '%s' "$_sc_md_files" | grep -c . || true)"
check "#148 the markdown scan has this repo's own documents to read" \
  "[ \"\${_sc_md_n:-0}\" -ge 3 ]"
for _sc_md_want in README.md DESIGN.md SETUP.md; do
  check "#148 and $_sc_md_want is one of them" \
    "printf '%s\n' \"\$_sc_md_files\" | grep -qx '$_sc_md_want'"
done
_sc_md_bad="$(printf '%s\n' "$_sc_md_files" | while IFS= read -r _sc_md_one; do
  [ -n "$_sc_md_one" ] || continue
  _sc_md_scan "$_sc_root/$_sc_md_one"
done)"
if [ -n "$_sc_md_bad" ]; then
  echo "  (#148 markdown blocks quoting a measured number without saying when:)"
  printf '%s\n' "$_sc_md_bad" | cut -c1-160 | sed 's/^/    /'
fi
check "#148 no document quotes a measured number without saying when" "[ -z \"\$_sc_md_bad\" ]"

# Both directions again, on a fixture shaped like markdown rather than like shell, because the
# block rule is the thing that changed and the shell fixture says nothing about it.
_SCMDFIX="$WORK/stale-counts-md-fixture.md"
{
  printf '# A heading\n\n'
  printf 'A dated paragraph: measured on 2026-01-02, the run took 200 seconds.\n\n'
  printf 'An undated paragraph, wrapped the way these actually are, saying the run\n'
  printf 'took 200 seconds and nothing about when.\n\n'
  printf '| setting | default | what it does |\n'
  printf '| --- | --- | --- |\n'
  printf '| `A` | `1` | dated: on 2026-01-02 a full run took 30 seconds |\n'
  printf '| `B` | `2` | undated: a full run took 30 seconds |\n\n'
  printf -- '- a list item that is dated: 2026-01-02, 12 sections\n'
  printf -- '- a list item that is not: 12 sections\n\n'
  printf 'A number this code sets: it gives up after 900s, not measured.\n\n'
  printf '```\n'
  printf 'inside a fence: the run took 200 seconds with no date anywhere\n'
  printf '```\n'
} > "$_SCMDFIX"
_sc_md_fix="$(_sc_md_scan "$_SCMDFIX")"
dbg "#148 markdown fixture scan: $(printf '%s' "$_sc_md_fix" | tr '\n' '|')"
for _sc_md_hit in 5 11 14; do
  check "#148 the markdown scan catches the undated block on line $_sc_md_hit" \
    "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c ':$_sc_md_hit:' | tr -d ' ')\" = 1 ]"
done
for _sc_md_quiet in 3 10 13 16 19; do
  check "#148 and leaves the block on line $_sc_md_quiet alone" \
    "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c ':$_sc_md_quiet:' | tr -d ' ')\" = 0 ]"
done
# A table row dated in ONE row must not excuse the row beneath it, which is the whole reason a row
# is its own block. Asserted by the pair above and by the count here: three and no more.
check "#148 and reports those three and nothing else" \
  "[ \"\$(printf '%s' \"\$_sc_md_fix\" | grep -c . | tr -d ' ')\" = 3 ]"

# And on a real document, so the zero above is a measurement rather than a scan reading nothing
# (L182, L171). README.md is the one every other check in this file already depends on being read.
_SCMDPOS="$WORK/stale-counts-md-positive-control.md"
cp "$_sc_root/README.md" "$_SCMDPOS"
printf '\nzzz planted: this run took 999 seconds and nothing here says when\n' >> "$_SCMDPOS"
_sc_md_self="$(_sc_md_scan "$_sc_root/README.md" | grep -c . || true)"
_sc_md_pos="$(_sc_md_scan "$_SCMDPOS" | grep -c . || true)"
dbg "#148 control: README.md reports $_sc_md_self, the planted copy reports $_sc_md_pos"
check "#148 the markdown count above is a live measurement, not a scan reading nothing" \
  "[ \"\${_sc_md_pos:-0}\" -eq \$(( _sc_md_self + 1 )) ]"
rm -f "$_SCMDPOS"

section "== every section reports its size and how long it took (#107) =="
# A full run reported one number, PASS, and nothing about where the minutes went. So "the suite is
# slow" could not be acted on: the slow sections were unknown, and a section that became slow later
# had nothing to show up in. Every section now closes with its own check count and duration.
#
# The count is the STRONG half. It is derived by subtracting the running totals at the section's
# start from the totals at its end, so it cannot drift from what actually ran, and the checks below
# assert the per-section counts SUM to the run's own total: a check attributed to no section, or to
# two, breaks that sum. A per-section number that merely looks plausible would not.
#
# The duration needs a positive control or it is worthless. Whole seconds means most sections read
# 0s quite legitimately, and a timer that was simply broken would ALSO read 0s everywhere, which is
# indistinguishable from a fast suite (L182, L1). SUITE_SLOW_IN=<text> stalls a chosen section for a
# known couple of seconds, and the check below requires that section's line to report at least that.
_PFO="$WORK/profile-child.txt"
SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_SLOW_IN="apply is idempotent" SECTION_UNTIL="apply is idempotent" bash "$SCRIPT_SELF" > "$_PFO" 2>&1
dbg "#107 child output: $(head -c 400 "$_PFO" | tr '\n' '|')"

check "#107 a section closes with its check count and duration" \
  "grep -qE '^  \(section: [0-9]+ checks?, [0-9]+s\)' '$_PFO'"

# Derived: every heading the child printed must be followed by one of those lines. A format that
# appears once and then stops would satisfy a bare grep.
_pf_heads="$(grep -c '^== ' "$_PFO")"
_pf_lines="$(grep -cE '^  \(section: [0-9]+ checks?, [0-9]+s\)' "$_PFO")"
check "#107 every section that ran got one, not just the first" "[ '$_pf_heads' -eq '$_pf_lines' ]"
check "#107 the comparison had sections to compare" "[ '$_pf_heads' -ge 3 ]"

# The sum. This is what makes the per-section counts real rather than decorative.
_pf_sum=0
while IFS= read -r _pfn; do
  [ -n "$_pfn" ] || continue
  _pf_sum=$((_pf_sum + _pfn))
done <<PFEOF
$(grep -oE '^  \(section: [0-9]+' "$_PFO" | grep -oE '[0-9]+')
PFEOF
_pf_pass="$(grep -oE '^PASS=[0-9]+' "$_PFO" | head -1 | cut -d= -f2)"
_pf_fail="$(grep -oE 'FAIL=[0-9]+' "$_PFO" | head -1 | cut -d= -f2)"
case "$_pf_pass" in ''|*[!0-9]*) _pf_pass=-1 ;; esac
case "$_pf_fail" in ''|*[!0-9]*) _pf_fail=-1 ;; esac
check "#107 the per section counts add up to the run's own total" \
  "[ '$_pf_sum' -eq \"\$((_pf_pass + _pf_fail))\" ] && [ '$_pf_sum' -gt 0 ]"

# The positive control: the deliberately slowed section must REPORT being slow. Paired with its
# own heading rather than searched for anywhere, or any slow section in the run would satisfy it.
_pf_slow="$(awk '/^== apply is idempotent/{f=1;next} f && /^  \(section:/{print;exit}' "$_PFO" \
            | grep -oE '[0-9]+s\)' | grep -oE '[0-9]+')"
case "$_pf_slow" in ''|*[!0-9]*) _pf_slow=-1 ;; esac
check "#107 a section made slow on purpose reports the time it took" "[ '$_pf_slow' -ge 2 ]"

# And the run ends with the slowest sections named, which is the thing somebody reads.
check "#107 the run ends with a profile of the slowest sections" \
  "grep -qi 'slowest sections' '$_PFO'"
check "#107 the profile names a section and a duration on one line" \
  "line_has \"\$(cat '$_PFO')\" '^ +[0-9]+s ' 'apply is idempotent'"

section "== a busy Mac does not turn a timing check red (#149) =="
# Eight full runs on 2026-08-21, while Lightroom, Xcode and Backblaze had this Mac at load 38 to
# 103: four different checks went red, and every one of them passed on the same tree at load 15.
# The single process run that normally takes 243 seconds took 854. A red result that has to be
# re-run before it is believed stops being read, which is the exact failure the deadline those
# checks guard exists to avoid (L36), and the pre-push gate blocks on them, so a busy Mac blocked
# a correct push.
#
# The remedy is not a bigger threshold. A threshold moved to survive load stops catching the thing
# it was set for (L172). What changed is the REFERENCE: a check that compared elapsed time against
# a number written here now compares it against something measured in the same run, and the
# deadline's headroom is judged on the suite's own PROCESSOR time, which other software competing
# for the Mac does not move.
#
# What is checked here is the reader and the comparison, which is this file's own code. That
# processor time is load immune is a property of the operating system, measured and written into
# the comment beside the reader rather than asserted here, because a check that tries to slow its
# own machine down passes or fails on whether the machine happened to be busy (L102).
suite_cpu_read; _cpu_before="$SUITE_CPU_SECONDS"
case "$_cpu_before" in
  ''|*[!0-9]*) check "#149 the processor time this run has used reads as a whole number" \
                 "false" ;;
  *) check "#149 the processor time this run has used reads as a whole number" "true" ;;
esac
# It counts what CHILDREN cost, not only this shell. That is the whole reason it can stand in for
# a run: nearly everything this suite costs is spent in git, in python and in the shards, none of
# which run in this process. A reader that saw only this shell would report a figure near zero for
# a run of any size, and near zero satisfies every headroom check there is (L90).
_cpu_burn(){   # a fixed amount of work, done in a CHILD, costing about a second of processor time
  bash -c 'i=0; while [ "$i" -lt 500000 ]; do i=$((i + 1)); done'
}
_cpu_burn
suite_cpu_read; _cpu_after="$SUITE_CPU_SECONDS"
case "$_cpu_before$_cpu_after" in
  ''|*[!0-9]*) check "#149 and it rises when a child does real work" "false" ;;
  *) check "#149 and it rises when a child does real work" \
       "[ '$_cpu_after' -gt '$_cpu_before' ]" ;;
esac

# The headroom comparison, watched REFUSING. A deadline one second under twice the processor time
# just measured has to be refused, or the check in #112 is satisfied by any deadline large enough,
# which is every deadline, and it reads as protection while protecting nothing (L1).
_cpu_floor=$(( ${_cpu_after:-0} * 2 ))
check "#149 a deadline one second under twice that is refused" \
  "! [ $(( _cpu_floor - 1 )) -ge '$_cpu_floor' ]"
check "#149 while the deadline this run is using clears it" \
  "[ \"\$SUITE_TIMEOUT\" -eq 0 ] || [ \"\$SUITE_TIMEOUT\" -ge '$_cpu_floor' ]"

# A reader that comes back with NOTHING has measured nothing, and nothing must never read as a
# figure of zero: zero clears every headroom check for ever, and a broken reader would then be
# indistinguishable from a suite that costs nothing at all (L90, L98).
check "#149 a field it cannot parse is read as nothing, never as zero" \
  "[ -z \"\$(_cpu_field 'not-a-time')\" ]"
check "#149 the control: a field it CAN parse is read as its seconds" \
  "[ \"\$(_cpu_field '1m5.230s')\" = 65 ]"

section "== the two bounds on a run leave room for each other (#112) =="
# What sat here was a floor on SUITE_TIMEOUT of twice the processor time the run had just used. It
# is retired, and this says so where it sat rather than disappearing quietly, because #112 is cited
# in DESIGN.md and because a check nobody can find the remains of is a check nobody can argue with
# (claude-config#161).
#
# It was right for a ceiling whose job was catching a hang. #152 took that job away and gave it to
# SUITE_STALL_TIMEOUT, then raised the ceiling from 900 to 3600 precisely because it is no longer
# what catches one. The floor went from 1.7x to about 7x in a single change: 262 seconds of
# processor time across four shards on 2026-08-22 against a 3600 second ceiling. The suite would
# have to grow sevenfold before it said anything. It was not wrong, it simply could not fire, and a
# check that cannot fire stops being read while still occupying a line in the report and a reader's
# attention (L182). Its actual job, noticing that the suite has grown into its own deadline, is done
# by the fan-out's copy, which now judges the wall clock the ceiling really bounds and uses the
# processor time to tell growth from load.
#
# What is here instead is the one thing about the ceiling that nothing was checking, and that this
# section is the right place for: the two bounds have to leave room for EACH OTHER. A run is judged
# hung when it has not reached a new section for SUITE_STALL_TIMEOUT, so a ceiling that expires
# first means the stall can never be reached: the watchdog's hang message, and the diagnosis in it,
# can never be spoken, and every real hang is reported as "still making progress and simply ran past
# the absolute ceiling", which sends the reader to raise a number rather than to find a hang (L109,
# L11).
#
# Twice, not merely more: a stall beginning after the run is already past half the ceiling would be
# reported as a ceiling overrun even when the ordering holds, so the ceiling needs room for a whole
# stall window beyond the point one can start. At the shipped 3600 against 600 that is 6x.
#
# Both are SETTINGS, so this says the same thing in a shard as in a full run, which the retired
# check did not: it ran inside a shard whose elapsed time is a quarter of the real thing, so it
# passed trivially in exactly the run the deadline exists for (L135, L220).
if [ "$SUITE_TIMEOUT" -gt 0 ] && [ "$SUITE_STALL_TIMEOUT" -gt 0 ]; then
  _hr_min=$(( SUITE_STALL_TIMEOUT * 2 ))
  check "#112 the ceiling leaves room for the stall bound to fire (${SUITE_TIMEOUT}s against ${SUITE_STALL_TIMEOUT}s)" \
    "[ '$SUITE_TIMEOUT' -ge '$_hr_min' ]"
  # Watched REFUSING, or the check above is satisfied by any ceiling large enough, which is every
  # ceiling, and it reads as protection while protecting nothing (L1).
  check "#112 and a ceiling one second under that floor is refused" \
    "! [ $(( _hr_min - 1 )) -ge '$_hr_min' ]"
elif [ "$SUITE_TIMEOUT" -gt 0 ]; then
  # One of them off is not a state this comparison is about, and saying so is not the same as
  # checking it (L98). The setting is asserted, so neither branch can pass by silence.
  check "#112 the stall bound was deliberately disabled for this run" "[ '$SUITE_STALL_TIMEOUT' -eq 0 ]"
else
  check "#112 the ceiling was deliberately disabled for this run" "[ '$SUITE_TIMEOUT' -eq 0 ]"
fi

# And the bound that actually catches a hang (claude-config#152). The stall timeout is only
# meaningful while it is longer than the longest SECTION: the run is judged to have stopped when it
# has not reached a new one, so a single section growing past it would make the watchdog kill
# healthy runs. Compared against what the sections in THIS run really took, never against the
# sentence in DESIGN.md that says the same thing, because that sentence cannot notice a section
# getting slower (L210, and #149's rule that the reference be measured in the same run).
#
# In a filtered run this sees only that shard's sections, which is the right answer rather than a
# weaker one: whichever shard holds the slowest section is the shard that checks it.
_hr_longest="$(printf '%s' "$_SEC_PROFILE" | sort -r | awk -F"$(printf '\t')" 'NR==1 {print $1+0}')"
case "$_hr_longest" in ''|*[!0-9]*) _hr_longest=0 ;; esac
# The margin as a NUMBER every run prints, not only as a pass or a fail (claude-config#179).
#
# The bound was 600 against a floor of 3x, so it went red the moment the slowest section passed 200
# seconds, and the slowest section is around 200 seconds on a busy Mac already: measured here on
# 2026-08-22 at 44s idle, 62s with one other full run competing, 88s with three, and once at 208s,
# which failed while nothing was wrong. A threshold sitting inside the spread of the thing it
# judges turns its own verdict into noise, and a suite that goes red on busy afternoons is one
# people learn to skim (L172, L36).
#
# Raising it is half the fix. The other half is that the margin is now REPORTED on every run rather
# than only being discovered on the day it runs out, so the next time it shrinks somebody sees it
# coming. The ratio is in tenths because this shell has no decimals, and it REFUSES when no section
# was measured: a margin over nothing would print as an enormous number and read as the safest run
# ever taken (L98).
_hr_margin(){   # $1 = the bound  $2 = the slowest section  -> the ratio in tenths
  [ "${2:-0}" -gt 0 ] || return 1
  printf '%s' "$(( $1 * 10 / $2 ))"
}
check "#179 the margin derivation reports a known pair" "[ \"\$(_hr_margin 1200 100)\" = '120' ]"
# The real incident, kept as a fixture: measured 2026-08-22, 600 against a 208 second section is
# 2.8x, under the 3.0x floor, which is exactly the run that failed.
check "#179 and reports the pair that failed on 2026-08-22 as under the floor" \
  "[ \"\$(_hr_margin 600 208)\" = '28' ]"
check "#179 and refuses when no section was measured" "! _hr_margin 1200 0"
if [ "$SUITE_STALL_TIMEOUT" -gt 0 ]; then
  _hr_m="$(_hr_margin "$SUITE_STALL_TIMEOUT" "$_hr_longest" 2>/dev/null || true)"
  if [ -n "$_hr_m" ]; then
    echo "  (#179 the stall bound is ${SUITE_STALL_TIMEOUT}s, which is $(( _hr_m / 10 )).$(( _hr_m % 10 ))x this run's slowest section (${_hr_longest}s))"
  fi
  check "#152 the stall timeout is at least three times the slowest section this run had (${_hr_longest}s)" \
    "[ '$SUITE_STALL_TIMEOUT' -ge $(( _hr_longest * 3 )) ]"
  # Watched refusing, or any stall timeout large enough satisfies it, which is every one (L1).
  check "#152 and a stall timeout one second under that floor is refused" \
    "! [ $(( _hr_longest * 3 - 1 )) -ge $(( _hr_longest * 3 )) ]"
else
  check "#152 the stall bound was deliberately disabled for this run" "[ '$SUITE_STALL_TIMEOUT' -eq 0 ]"
fi

section "== the end-of-run headroom report, watched saying each thing it can say (#167) =="
# #161 changed what the end of a full run judges: the ceiling bounds WALL CLOCK, so that is what
# decides whether there is anything to say, and the processor time decides WHICH of two things is
# happening. It has three outcomes and a silence, and only the silence was ever produced, because
# the code sat inline at the end of a fan-out and the only way to reach it was a full run on a
# machine that was already fine. A guard is real once it has been watched failing (L1), and the arm
# that FAILS a run is the one that had never run at all.
#
# So the decision is a function, and it is asked here with numbers rather than by arranging a slow
# machine. The numbers are the ones actually measured on 2026-08-22 rather than convenient ones:
# 348 seconds of wall clock idle, and 1943 under load 160 to 188 with only 262 of those seconds the
# suite's own work (L48).
_hd_say(){ suite_headroom_report "$1" "$2" "$3" 2>&1; }
_hd_rc(){ suite_headroom_report "$1" "$2" "$3" >/dev/null 2>&1; }

# Idle, against the shipped ceiling. Nothing to say, and saying nothing has to be an outcome this
# can actually reach, or every check below is about a function that always speaks.
_hd_idle="$(_hd_say 348 262 3600)"; _hd_rc 348 262 3600; _hd_idle_rc=$?
check "#167 a run with real headroom says nothing" "[ -z \"\$_hd_idle\" ]"
check "#167 and a run with headroom does not fail" "[ '$_hd_idle_rc' -eq 0 ]"

# The same tree, on a busy Mac. This is the case #149 was filed about: it is a fact about the
# machine, "find what got slower" is not an action anybody can take on it, and treating it as a
# failure is how an alarm stops being read (L112, L36).
_hd_load="$(_hd_say 1943 262 3600)"; _hd_rc 1943 262 3600; _hd_load_rc=$?
check "#167 a run that WAITED is reported as a note" \
  "case \"\$_hd_load\" in *'note,'*) true ;; *) false ;; esac"
check "#167 and it names the load rather than blaming the suite" \
  "line_has \"\$_hd_load\" '1943' '262'"
check "#167 and does NOT fail the run"             "[ '$_hd_load_rc' -eq 0 ]"

# The arm that had never fired: the same wall clock, but the suite's own work is what filled it.
_hd_grown="$(_hd_say 1943 1500 3600)"; _hd_rc 1943 1500 3600; _hd_grown_rc=$?
check "#167 a run that GREW into its deadline fails" "[ '$_hd_grown_rc' -ne 0 ]"
check "#167 and says so in different words from the note" \
  "! case \"\$_hd_grown\" in *'note,'*) true ;; *) false ;; esac"
check "#167 and names both figures and the ceiling" \
  "line_has \"\$_hd_grown\" '1943' '1500' '3600'"
# The two arms are told apart by ONE thing, so it is asked at the boundary rather than only where
# the answer is obvious: at exactly half the wall clock the run's own work is what filled it.
_hd_rc 1943 971 3600; _hd_edge_lo=$?
_hd_rc 1943 972 3600; _hd_edge_hi=$?
check "#167 just under half the wall clock is the machine's fault, not the suite's" "[ '$_hd_edge_lo' -eq 0 ]"
check "#167 and just over it is the suite's"                                        "[ '$_hd_edge_hi' -ne 0 ]"

# A reader that came back with nothing has measured nothing, and nothing must never read as a
# figure of zero: zero clears every headroom test there is, so a broken reader would be
# indistinguishable from a suite that costs nothing (L90, L98).
_hd_none="$(_hd_say 1943 '' 3600)"; _hd_rc 1943 '' 3600; _hd_none_rc=$?
check "#167 an unreadable processor time is said out loud" \
  "case \"\$_hd_none\" in *'NOT checked'*) true ;; *) false ;; esac"
check "#167 and is not treated as a run that grew" "[ '$_hd_none_rc' -eq 0 ]"
check "#167 and is not silently read as zero seconds" \
  "! case \"\$_hd_none\" in *'0s of processor'*) true ;; *) false ;; esac"

# A ceiling that is switched off has no headroom to report, and must not produce a figure about one.
_hd_off="$(_hd_say 99999 99999 0)"; _hd_rc 99999 99999 0; _hd_off_rc=$?
check "#167 a disabled ceiling reports nothing"   "[ -z \"\$_hd_off\" ]"
check "#167 and does not fail the run"            "[ '$_hd_off_rc' -eq 0 ]"

# And the report the fan-out actually prints is THIS function, not a second copy of the rule that
# drifts beside it (L107). Read from the file, because the fan-out only runs on a full unfiltered
# run and this section is reached inside a shard.
check "#167 the fan-out asks this function rather than repeating the rule" \
  "[ \"\$(grep -c 'suite_headroom_report ' '$SCRIPT_SELF')\" -ge 2 ]"

section "== a send runs the suites covering the hooks it is about to publish (#244) =="
# The pre push test gate is a Claude Code PreToolUse hook on `git push`, so it only fires for a
# push a session makes by hand. The watcher mirrors ~/.claude into the payload and commits and
# pushes on its own, and nothing in that path asked whether the change carried a test.
#
# Not hypothetical: on 2026-08-31 commit f094409 pushed a 41 line change to hooks/lib/issue-spool.sh
# with no test at all. The test for it had been written in ~/.claude at the same time, failed to
# merge on the next pull, and was set aside as a .conflict copy, so it reached nobody. Code written
# directly in the live config is exactly the code that governs every session in every project, and
# it was the one path with no coverage requirement on it.
#
# Which suites are RELEVANT is derived the same way test-hook-coverage.sh derives coverage: a suite
# covers a hook when the suite's text names it. Written twice, the two would drift, and the send
# would verify a different set from the one the ratchet calls covered (L263, L41).
unset SYNC_NO_SEND_TESTS
SDB="$WORK/sendtest-bare.git"; git init -q --bare "$SDB"
SDR="$WORK/sendtest-repo"; git clone -q "$SDB" "$SDR"
SDH="$WORK/sendtest-home"; mkdir -p "$SDH/hooks"
echo '{"hooks":{}}' > "$SDH/settings.json"
printf '# rules\n' > "$SDH/CLAUDE.md"
printf '#!/usr/bin/env bash\necho demo\n' > "$SDH/hooks/demo.sh"
# The suite for it, named so the derivation finds it and passing so the first send goes through.
printf '#!/usr/bin/env bash\n# covers demo.sh\necho "SUITE-RESULT passed=1 failed=0"\nexit 0\n' \
  > "$SDH/hooks/test-demo.sh"
out_244a="$(CLAUDE_HOME="$SDH" SYNC_REPO="$SDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#244 first send: $out_244a"
check "#244 a hook whose suite passes is published" \
  "[ -f '$SDR/payload/hooks/demo.sh' ] && [ -n \"\$(git -C '$SDR' log --oneline 2>/dev/null)\" ]"

# Now the hook changes and its suite fails. The send must NOT commit it.
printf '#!/usr/bin/env bash\necho demo changed\n' > "$SDH/hooks/demo.sh"
printf '#!/usr/bin/env bash\n# covers demo.sh\necho "FAIL: demo.sh is broken"\necho "SUITE-RESULT passed=0 failed=1"\nexit 1\n' \
  > "$SDH/hooks/test-demo.sh"
sd_head_before="$(git -C "$SDR" rev-parse HEAD 2>/dev/null)"
out_244b="$(CLAUDE_HOME="$SDH" SYNC_REPO="$SDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"; rc_244b=$?
dbg "#244 send with a failing suite: $out_244b"
# #269 reversed the OTHER half of this deliberately, so the assertion that defended it is gone
# rather than adjusted (L252). A total refusal stopped rule files, skills and lessons crossing
# too, which is the more expensive failure; what #244 asked for, and what still holds, is that
# the unverified hook itself is not published.
check "#244 a hook whose suite fails is not published" \
  "! grep -q 'demo changed' '$SDR/payload/hooks/demo.sh'"
check "#244 and the send delivers the rest rather than failing whole (#269)" "[ $rc_244b -eq 0 ]"
# Naming the SUITE is the whole point: "a test failed" sends the reader to run all of them, which
# is the cost this exists to save (L11, L80).
check "#244 and it names the suite that failed" \
  "case \"\$out_244b\" in *test-demo.sh*) true ;; *) false ;; esac"

# The edit is still on disk and still unsent, so the next send retries it. A refusal that also
# discarded the work would be worse than the defect (L5).
check "#244 the local edit is untouched by the refusal" \
  "grep -q 'demo changed' '$SDH/hooks/demo.sh'"

# And once the suite passes again, the same edit goes out. A gate that cannot be satisfied is a
# gate that gets turned off (L109).
printf '#!/usr/bin/env bash\n# covers demo.sh\necho "SUITE-RESULT passed=1 failed=0"\nexit 0\n' \
  > "$SDH/hooks/test-demo.sh"
out_244c="$(CLAUDE_HOME="$SDH" SYNC_REPO="$SDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
check "#244 the same edit is published once its suite passes" \
  "grep -q 'demo changed' '$SDR/payload/hooks/demo.sh'"

# A hook NO suite mentions is not silently published as verified. The ratchet is what gates an
# uncovered hook; this has to say plainly that it verified nothing, or a send that ran no suite
# reads exactly like one whose suites all passed (L98).
printf '#!/usr/bin/env bash\necho naked\n' > "$SDH/hooks/naked.sh"
out_244d="$(CLAUDE_HOME="$SDH" SYNC_REPO="$SDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#244 send of an uncovered hook: $out_244d"
check "#244 an uncovered hook is still published" "[ -f '$SDR/payload/hooks/naked.sh' ]"
# Both facts on ONE line, so a sentence elsewhere naming the file and a different sentence saying
# "no suite" cannot answer between them (L178).
line_244d="$(printf '%s\n' "$out_244d" | sed -n '/naked\.sh/p')"
check "#244 and the send says outright that no suite covers it" \
  "case \"\$line_244d\" in *'NO SUITE'*|*'no suite'*) true ;; *) false ;; esac"

# The control, and it is what keeps the cost honest: a send that touches no hook runs nothing.
printf 'a skill\n' > "$SDH/CLAUDE.md"
out_244e="$(CLAUDE_HOME="$SDH" SYNC_REPO="$SDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#244 send with no hook change: $out_244e"
check "#244 a send that changes no hook runs no suite" \
  "case \"\$out_244e\" in *suite*|*SUITE*) false ;; *) true ;; esac"
SYNC_NO_SEND_TESTS=1


section "== a red suite holds back the hooks it covers, not the whole send (#269) =="
# #244 made a send run the suites covering the hooks it is about to publish, and refuse to COMMIT
# when one fails. The refusal was total for that send, so an unrelated red suite stopped rule
# files, skills and lessons reaching the other Mac too, and #196 already records that a watcher
# which has stopped sending is hard to notice from the outside. Holding back everything is the
# more expensive failure of the two, and the send path already held back a single malformed rule
# file rather than failing whole, which is the shape copied here.
#
# The second half is cost. The watcher fires do_send on every event, so while a suite is red the
# same suite is re-run on every save for as long as it stays red, with the sync lock held
# throughout. A verdict is therefore remembered against a digest of the staged hooks, and reused
# while nothing they depend on has changed.
unset SYNC_NO_SEND_TESTS
HDB="$WORK/holdback-bare.git"; git init -q --bare "$HDB"
HDR="$WORK/holdback-repo"; git clone -q "$HDB" "$HDR"
HDH="$WORK/holdback-home"; mkdir -p "$HDH/hooks"
echo '{"hooks":{}}' > "$HDH/settings.json"
printf '# rules\n' > "$HDH/CLAUDE.md"
# How many times each suite has actually been launched. A count, not a flag, because the thing
# being measured is repetition and a flag cannot tell one run from twenty (#269's second half).
HD_RUNS="$WORK/holdback-runs"; : > "$HD_RUNS"
hd_write_suite(){   # $1 = covered hook basename  $2 = exit code
  local pass=1 fail=0
  [ "$2" -eq 0 ] || { pass=0; fail=1; }
  {
    printf '#!/usr/bin/env bash\n'
    printf '# covers %s\n' "$1"
    printf 'printf "%s\\n" >> "%s"\n' "$1" "$HD_RUNS"
    printf 'echo "SUITE-RESULT passed=%s failed=%s"\n' "$pass" "$fail"
    printf 'exit %s\n' "$2"
  } > "$HDH/hooks/test-${1%.sh}.sh"
}
hd_runs_for(){ grep -cxF "$1" "$HD_RUNS" 2>/dev/null || true; }

printf '#!/usr/bin/env bash\necho alpha\n' > "$HDH/hooks/alpha.sh"
printf '#!/usr/bin/env bash\necho beta\n'  > "$HDH/hooks/beta.sh"
hd_write_suite alpha.sh 0
hd_write_suite beta.sh  0
out_269a="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#269 first send: $out_269a"
check "#269 both hooks publish while both suites pass" \
  "[ -f '$HDR/payload/hooks/alpha.sh' ] && [ -f '$HDR/payload/hooks/beta.sh' ]"

# Now both hooks change, one suite goes red, and an unrelated rule file changes with them. The
# red suite must cost beta.sh its trip and nothing else theirs.
printf '#!/usr/bin/env bash\necho alpha changed\n' > "$HDH/hooks/alpha.sh"
printf '#!/usr/bin/env bash\necho beta changed\n'  > "$HDH/hooks/beta.sh"
printf '# rules changed\n' > "$HDH/CLAUDE.md"
hd_write_suite beta.sh 1
: > "$HD_RUNS"
out_269b="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"; rc_269b=$?
dbg "#269 send with one red suite: $out_269b"
check "#269 the unrelated rule file still reaches the repo" \
  "grep -q 'rules changed' '$HDR/payload/CLAUDE.md'"
check "#269 the hook whose suite passed still reaches the repo" \
  "grep -q 'alpha changed' '$HDR/payload/hooks/alpha.sh'"
check "#269 the hook whose suite failed is held back" \
  "! grep -q 'beta changed' '$HDR/payload/hooks/beta.sh'"
check "#269 and the send delivers rather than failing whole" "[ $rc_269b -eq 0 ]"
# Both facts on ONE line: a sentence naming the suite and a different sentence naming the file
# cannot answer between them about which hook is waiting (L178).
line_269b="$(printf '%s\n' "$out_269b" | sed -n '/test-beta\.sh/p')"
check "#269 one line names both the red suite and the hook it held back" \
  "case \"\$line_269b\" in *beta.sh*) case \"\$line_269b\" in *test-beta.sh*) true ;; *) false ;; esac ;; *) false ;; esac"
check "#269 the held-back edit is untouched in the live config" \
  "grep -q 'beta changed' '$HDH/hooks/beta.sh'"

# The cost half. Nothing beta's verdict rests on has changed, so a second send must reuse it
# rather than pay for the suite again, and it must still hold beta back.
hd_before_269="$(hd_runs_for beta.sh)"
printf '# rules changed twice\n' > "$HDH/CLAUDE.md"
out_269c="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#269 second send while still red: $out_269c"
check "#269 a red suite is not re-run while its inputs are unchanged" \
  "[ \"\$(hd_runs_for beta.sh)\" = '$hd_before_269' ]"
check "#269 and the hook it covers is still held back" \
  "! grep -q 'beta changed' '$HDR/payload/hooks/beta.sh'"
check "#269 and the send says the verdict was reused rather than measured" \
  "case \"\$out_269c\" in *reus*|*remember*|*unchanged*) true ;; *) false ;; esac"
check "#269 the rest of that send still went out" \
  "grep -q 'rules changed twice' '$HDR/payload/CLAUDE.md'"

# The control for the line above, and it is the one that matters: a remembered verdict that
# survives a change to its inputs is not a cache, it is a permanent refusal (L336, L159).
hd_write_suite beta.sh 0
out_269d="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#269 send once the suite is green again: $out_269d"
check "#269 the suite runs again once its inputs change" \
  "[ \"\$(hd_runs_for beta.sh)\" != '$hd_before_269' ]"
check "#269 and the held-back edit publishes on that send" \
  "grep -q 'beta changed' '$HDR/payload/hooks/beta.sh'"

# A hook whose name is a SUFFIX of another hook's name must not be answered for by the suites that
# name the longer one (claude-config#268). `grep -lF` made `spool.sh` look covered by every suite
# mentioning `issue-spool.sh`, so a send would run five irrelevant suites and report the hook as
# checked. The send and the coverage ratchet ask this question in the same shape on purpose, and
# each proves the suffix case separately, because a shared name is read as evidence of shared
# behaviour and nothing otherwise compares them (L263).
printf '#!/usr/bin/env bash\necho long\n' > "$HDH/hooks/issue-spool.sh"
hd_write_suite issue-spool.sh 0
CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send >/dev/null 2>&1
printf '#!/usr/bin/env bash\necho short\n' > "$HDH/hooks/spool.sh"
out_269f="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#268 send of a hook whose name is a suffix of another: $out_269f"
line_269f="$(printf '%s\n' "$out_269f" | sed -n '/spool\.sh/p')"
check "#268 a hook no suite names is reported uncovered, not covered by the longer name" \
  "case \"\$line_269f\" in *'NO SUITE'*) true ;; *) false ;; esac"

# A hook the repo has never seen must not be published by the hold-back either. Restoring "the
# version already committed" has no version to restore, and the branch that gets that wrong
# publishes exactly the file the red suite refused (L214).
printf '#!/usr/bin/env bash\necho gamma\n' > "$HDH/hooks/gamma.sh"
hd_write_suite gamma.sh 1
out_269e="$(CLAUDE_HOME="$HDH" SYNC_REPO="$HDR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" send 2>&1)"
dbg "#269 send of a brand new hook whose suite is red: $out_269e"
check "#269 a new hook whose suite is red is not published at all" \
  "[ ! -e '$HDR/payload/hooks/gamma.sh' ]"
check "#269 and the repo is not left holding a staged copy of it" \
  "! git -C '$HDR' ls-files --error-unmatch payload/hooks/gamma.sh >/dev/null 2>&1"
SYNC_NO_SEND_TESTS=1


section "== a burst of edits is one send, and a session can hold the watcher off (#262) =="
# Two costs with one cause: the watcher commits and pushes on every fswatch event. It takes the
# commit message out of a session's hands (twice on 2026-09-02 a change was written up with its
# reasoning and the watcher had already committed the same files as "sync from <host>", so
# `git commit` found a clean tree and the explanation survives only in code comments), and it
# cancels CI (six consecutive commits on 2026-09-02, five runs cancelled by cancel-in-progress,
# one survivor, so during active work there is no build signal at all).
#
# The debounce is measured through the watch loop's own send step rather than through a real
# do_send, because what is under test is the SHAPE of the loop: how many times it acts on a burst.
WT="$WORK/watch-debounce"; mkdir -p "$WT"
WT_FS="$WT/fake-fswatch"; WT_HITS="$WT/hits"
# A burst: one event, then four more that arrive WHILE the first send is being handled. That
# separation is what makes this a test of the drain rather than of end-of-input, because with all
# five already sitting in the pipe a loop with no debounce at all would read them together.
#
# It waits on the CONDITION (the first send has happened, so the loop is now in its drain window)
# rather than on a fixed pause. A `sleep 0.3` here would have been a bet that the machine gets
# round to the send inside the drain window, which is a bet about load, and it is judged hardest
# exactly when the machine is busiest (L290).
cat > "$WT_FS" <<'FSEOF'
#!/usr/bin/env bash
echo one
# Poll granularity, not a wait for a duration: the loop below ends the moment the send lands.
while [ ! -s "$WT_HITS" ]; do sleep 0.02; done
echo two
echo three
echo four
echo five
FSEOF
chmod +x "$WT_FS"
export WT_HITS
WT_HOME="$WT/home"; mkdir -p "$WT_HOME/hooks"
: > "$WT_HITS"
SYNC_FSWATCH="$WT_FS" SYNC_WATCH_SEND="printf 'x\n' >> '$WT_HITS'" \
  CLAUDE_HOME="$WT_HOME" SYNC_REPO="$WORK/watch-repo-unused" SYNC_NO_NOTIFY=1 \
  bash "$SCRIPT" watch >/dev/null 2>&1 || true
wt_burst="$(grep -c . "$WT_HITS" 2>/dev/null || true)"
dbg "#262 sends for a five event burst: $wt_burst"
# One send for the event that woke the loop, and ONE more covering everything that arrived while
# it was running. Never five, and never one: dropping the drained events would lose the last edit,
# which is a worse defect than the one being fixed (L368).
check "#262 a five event burst becomes two sends, not five" "[ \"\$wt_burst\" = '2' ]"

# The control. A debounce that costs an extra send on every single event has moved the cost rather
# than removed it, and the count above cannot tell that apart from a working drain.
cat > "$WT_FS" <<'FSEOF'
#!/usr/bin/env bash
echo only
FSEOF
chmod +x "$WT_FS"
: > "$WT_HITS"
SYNC_FSWATCH="$WT_FS" SYNC_WATCH_SEND="printf 'x\n' >> '$WT_HITS'" \
  CLAUDE_HOME="$WT_HOME" SYNC_REPO="$WORK/watch-repo-unused" SYNC_NO_NOTIFY=1 \
  bash "$SCRIPT" watch >/dev/null 2>&1 || true
check "#262 a single event is still exactly one send" \
  "[ \"\$(grep -c . '$WT_HITS' 2>/dev/null || true)\" = '1' ]"

# ---- the hold ----
# The marker lives outside every clone on purpose: the watcher runs from a different clone than the
# one a session works in, so a file inside either of them reaches only itself.
HOLD="$WT/hold-marker"
HRB="$WORK/hold-bare.git"; git init -q --bare "$HRB"
HRR="$WORK/hold-repo"; git clone -q "$HRB" "$HRR"
HRH="$WORK/hold-home"; mkdir -p "$HRH/hooks"
echo '{"hooks":{}}' > "$HRH/settings.json"
printf '# held rules\n' > "$HRH/CLAUDE.md"
# Through `env`, so a caller can add its OWN assignment in front of the command. A bare "$@" runs
# a leading VAR=1 as a command name rather than as an assignment, which fails silently enough to
# look like the behaviour under test: the send never runs, nothing is committed, and the check
# that nothing was committed passes for the wrong reason (L159).
hold_env(){ CLAUDE_HOME="$HRH" SYNC_REPO="$HRR" SYNC_HOLD_FILE="$HOLD" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 env "$@"; }
out_262h="$(hold_env bash "$SCRIPT" hold 5 "committing by hand" 2>&1)"
dbg "#262 hold: $out_262h"
check "#262 hold writes a marker" "[ -f '$HOLD' ]"
check "#262 and says how long it lasts" \
  "case \"\$out_262h\" in *minute*) true ;; *) false ;; esac"

out_262w="$(hold_env SYNC_IN_WATCH=1 bash "$SCRIPT" send 2>&1)"
dbg "#262 watcher send while held: $out_262w"
check "#262 the watcher does not commit while a hold is in force" \
  "[ -z \"\$(git -C '$HRR' log --oneline 2>/dev/null)\" ]"
check "#262 and it says why, naming how to lift it" \
  "case \"\$out_262w\" in *release*) true ;; *) false ;; esac"

# A hold silences the AUTOMATIC send only. A person who asks for one explicitly is not the thing
# being held off, and a command that refuses the person who set the hold is a dead control (L109).
out_262e="$(hold_env bash "$SCRIPT" send 2>&1)"
dbg "#262 explicit send while held: $out_262e"
check "#262 an explicit send is not blocked by the hold" \
  "[ -n \"\$(git -C '$HRR' log --oneline 2>/dev/null)\" ]"

# Captured, then matched. `status | grep -q` is a short-circuiting consumer under pipefail, so the
# producer is killed and the pipeline reports a failure that never happened (L183).
out_262s="$(hold_env bash "$SCRIPT" status 2>&1)"
check "#262 status reports the hold while it is live" \
  "case \"\$out_262s\" in *'watcher hold'*) true ;; *) false ;; esac"
out_262r="$(hold_env bash "$SCRIPT" release 2>&1)"
check "#262 release clears the marker" "[ ! -f '$HOLD' ]"

# An expiry, and it has to fail OPEN: a hold that outlives the session that took it silently stops
# the sync, which is the failure #196 exists to make visible, and a suppression set by hand needs
# an expiry and somewhere visible to be listed (L523).
printf '%s %s %s hand written and long expired\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 3600 ))" "somehost" > "$HOLD"
printf '# held rules again\n' > "$HRH/CLAUDE.md"
out_262x="$(hold_env SYNC_IN_WATCH=1 bash "$SCRIPT" send 2>&1)"
dbg "#262 watcher send with an expired hold: $out_262x"
check "#262 an expired hold is cleared" "[ ! -f '$HOLD' ]"
check "#262 and the watcher sends again" \
  "grep -q 'held rules again' '$HRR/payload/CLAUDE.md'"
check "#262 and it says the hold expired rather than staying silent" \
  "case \"\$out_262x\" in *expired*) true ;; *) false ;; esac"

# A marker nothing can read is neither "no hold" nor "held for ever". Reading it as a hold stops
# the sync until somebody finds the file; reading it as absent hides that somebody meant to stop it.
printf 'this is not a marker\n' > "$HOLD"
printf '# held rules a third time\n' > "$HRH/CLAUDE.md"
out_262u="$(hold_env SYNC_IN_WATCH=1 bash "$SCRIPT" send 2>&1)"
dbg "#262 watcher send with an unreadable hold: $out_262u"
check "#262 an unreadable hold marker is cleared rather than obeyed" "[ ! -f '$HOLD' ]"
check "#262 and it is reported in its own words, not as an expiry" \
  "case \"\$out_262u\" in *'could not be read'*) true ;; *) false ;; esac"


section "== the index generator, against the wrap shapes it actually meets (#192, #194, #195) =="
# LESSONS-INDEX.md is imported by CLAUDE.md into every session in every project, and the generator
# that writes it had no test of its own. #192's word-gluing defect was found by reading the awk by
# eye, not by anything failing, and it had already shipped into the generated index: L517 rendered
# as "across everycombination of inputs".
#
# The mechanism was `sub(/^[[:space:]]+/, " ", nxt)` followed by `rest = rest nxt`. That replaces
# LEADING whitespace with a single space, so it does the right thing for an INDENTED continuation
# line and nothing at all for an unindented one, which then joins with no separator. That is why
# it was intermittent: it depended on how each author happened to wrap.
LWH="$WORK/lesswrap-home"; LWR="$WORK/lesswrap-repo"
mkdir -p "$LWH" "$LWR/payload"
echo '{"hooks":{}}' > "$LWH/settings.json"
printf '# rules\n' > "$LWH/CLAUDE.md"
# Every shape that actually occurs in the file, including the two the old code told apart by
# accident. The unindented wrap is the one that must fail before the fix and pass after (L1).
cat > "$LWH/LESSONS.md" <<'LWEOF'
# Build-time lessons

## Proof over green

- **L1. A one line rule.** Its body.
  (someproject#1)
- **L2. A rule wrapping with an indented
  continuation line.** Its body.
  (someproject#2)
- **L3. A rule wrapping with an unindented
continuation line.** Its body.
  (someproject#3)

## Data safety

- **L4. A rule whose bold marker never closes and runs to the end of the entry.
  (someproject#4)
- **L5. The rule after the unclosed one still gets its own line.** Its body.
  (someproject#5)
LWEOF
CLAUDE_HOME="$LWH" SYNC_REPO="$LWR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
LWI="$LWH/LESSONS-INDEX.md"
dbg "#194 generated index: $(cat "$LWI" 2>/dev/null)"
check "#194 a one line rule is carried whole" \
  "grep -qF -- '- L1. A one line rule.' '$LWI'"
check "#194 an indented wrap joins with exactly one space" \
  "grep -qF -- '- L2. A rule wrapping with an indented continuation line.' '$LWI'"
# The defect. Written out in full rather than as "no double space anywhere", because the failure
# is two WORDS fused and a check on spacing in general would pass on a line that lost a word.
check "#192 an UNINDENTED wrap joins with a space rather than gluing the words" \
  "grep -qF -- '- L3. A rule wrapping with an unindented continuation line.' '$LWI'"
check "#192 and the glued form is not what it wrote" \
  "! grep -qF -- 'unindentedcontinuation' '$LWI'"
check "#194 every entry gets a line, including the one after an unclosed marker" \
  "[ \"\$(grep -c '^- L[0-9]' '$LWI')\" = '5' ]"
check "#194 the section headings are carried" \
  "grep -q '^## Data safety' '$LWI'"
check "#194 and the bodies are not" "! grep -q 'Its body' '$LWI'"

# ---- the index and the lessons file are checked against each other (#195) ----
# Every failure path in write_lesson_index returns 0 silently, so a generation that failed or
# truncated left whatever stale index was already on disk and every session went on loading it.
# An index that is stale and one that is correct look identical to a reader (L98). The check reads
# the two FILES rather than trusting the writer, because a check living only inside the writer
# cannot see an index that was right when written and has gone stale since (L225).
printf -- '- **L6. A lesson the index has never been told about.** body\n  (someproject#6)\n' >> "$LWH/LESSONS.md"
# The index is made unwritable, so the rewrite CANNOT land and the disagreement is real rather
# than staged by editing the index into a shape the generator would never produce.
chmod 444 "$LWI"
out_lw195="$(CLAUDE_HOME="$LWH" SYNC_REPO="$LWR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1 || true)"
chmod 644 "$LWI"
dbg "#195 push with an unwritable index: $out_lw195"
check "#195 an index that does not match its lessons file is reported" \
  "case \"\$out_lw195\" in *LESSONS-INDEX*) true ;; *) false ;; esac"
# It has to name the numbers, or the reader is told the two disagree and has to diff them by hand
# to learn which lesson is missing (L11, L80).
check "#195 and it names the lesson the index is missing" \
  "case \"\$out_lw195\" in *L6*) true ;; *) false ;; esac"

# The control, and it is what keeps the check from being a permanent complaint: a healthy pair
# says nothing at all. A warning printed on every run is one nobody reads (L36).
out_lw195b="$(CLAUDE_HOME="$LWH" SYNC_REPO="$LWR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1 || true)"
dbg "#195 push once the index can be written: $out_lw195b"
check "#195 a matching pair is silent" \
  "case \"\$out_lw195b\" in *'does not match'*|*'disagree'*) false ;; *) true ;; esac"
check "#195 and the missing lesson is in the index now" \
  "grep -qF -- '- L6. A lesson the index has never been told about.' '$LWI'"


section "== an unreadable lesson entry is reported where it IS, not where it came from (#248, #249) =="
# The message said "a lesson entry that ARRIVED is not written as ...", and the comment above it
# stated the assumption outright: "this is the path such an entry actually arrives on, since the
# other Mac is where somebody wrote it". On 2026-08-31 a pull on Dans-MacBook-Pro reported L530
# that way, and git history shows L530 was never in the shared payload: it was written on that
# same Mac and had been held back unsent. Anyone acting on the message goes and investigates a
# Mac that had nothing wrong with it.
#
# It was also reported only on the sync paths, so a locally written entry was invisible until one
# happened to run: absent from the index that loads into every session, unreachable by
# `claude-sync lesson`, by the duplicate check and by the number minter, with nothing saying so
# (#249). There is ONE reporter now, called from the place that regenerates the index, so it
# speaks whenever the lessons file is next read at all and says all three consequences at once.
MLB="$WORK/mallesson-bare.git"; git init -q --bare -b main "$MLB"
MLA="$WORK/mallesson-A"; git clone -q "$MLB" "$MLA" 2>/dev/null
MLHA="$WORK/mallesson-homeA"; mkdir -p "$MLHA"
echo '{"hooks":{}}' > "$MLHA/settings.json"
printf '# rules\n' > "$MLHA/CLAUDE.md"
printf '# Lessons\n\n## Proof over green\n\n- **L1. A readable one.** body\n' > "$MLHA/LESSONS.md"

# Mac A publishes a clean file, Mac B receives it, and then B writes a bad entry of its OWN and
# pulls. That is the exact shape of the 2026-08-31 report: the entry is local and unsent, and the
# PULL is what reported it, claiming it arrived.
CLAUDE_HOME="$MLHA" SYNC_REPO="$MLA" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send >/dev/null 2>&1
MLBB="$WORK/mallesson-B"; git clone -q "$MLB" "$MLBB" 2>/dev/null
MLHB="$WORK/mallesson-homeB"; mkdir -p "$MLHB"
echo '{"hooks":{}}' > "$MLHB/settings.json"
CLAUDE_HOME="$MLHB" SYNC_REPO="$MLBB" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull >/dev/null 2>&1
printf -- '- L2. Written on this Mac in a shape nothing can read.\n' >> "$MLHB/LESSONS.md"
out_ml_local="$(CLAUDE_HOME="$MLHB" SYNC_REPO="$MLBB" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#248 pull with a locally written bad entry: $out_ml_local"
check "#248 an entry written here is reported" \
  "case \"\$out_ml_local\" in *'LESSONS.md'*) true ;; *) false ;; esac"
check "#248 and it is NOT described as having arrived" \
  "case \"\$out_ml_local\" in *ARRIVED*) false ;; *) true ;; esac"
check "#248 and it says the entry was written on this Mac" \
  "case \"\$out_ml_local\" in *'ON THIS MAC'*) true ;; *) false ;; esac"
# All three consequences in the one message, because they have one remedy and three separate
# sentences in three places is how the same fault gets fixed once and reported twice (#249, L11).
check "#249 and it says the entry is missing from the index every session loads" \
  "case \"\$out_ml_local\" in *index*) true ;; *) false ;; esac"

# Now the other direction, which is the case the old wording assumed was the only one. The bad
# entry goes up from A with the check overridden, exactly as a real one would if somebody used the
# documented escape hatch, and then lands on B.
printf '# Lessons\n\n## Proof over green\n\n- **L1. A readable one.** body\n' > "$MLHB/LESSONS.md"
printf -- '- L3. Published from the other Mac in a shape nothing can read.\n' >> "$MLHA/LESSONS.md"
CLAUDE_HOME="$MLHA" SYNC_REPO="$MLA" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 SYNC_SKIP_LESSON_CHECK=1 bash "$SCRIPT" send >/dev/null 2>&1
out_ml_arrived="$(CLAUDE_HOME="$MLHB" SYNC_REPO="$MLBB" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#248 pull that received a bad entry: $out_ml_arrived"
check "#248 an entry that really did arrive is reported as having arrived" \
  "case \"\$out_ml_arrived\" in *ARRIVED*) true ;; *) false ;; esac"
check "#248 and it names the entry" \
  "case \"\$out_ml_arrived\" in *L3.*) true ;; *) false ;; esac"
# The mirror of the check above. Without it "arrived" could be a word the message always carries,
# which is exactly what it was, and a check for its presence would pass on the broken version too
# (L159).
check "#248 and it does not also call that one locally written" \
  "case \"\$out_ml_arrived\" in *'ON THIS MAC'*) false ;; *) true ;; esac"

# The control. A readable file says nothing at all, or the message is printed on every run and
# stops being read (L36).
printf '# Lessons\n\n## Proof over green\n\n- **L1. A readable one.** body\n' > "$MLHB/LESSONS.md"
out_ml_clean="$(CLAUDE_HOME="$MLHB" SYNC_REPO="$MLBB" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send 2>&1 || true)"
check "#248 a readable lessons file is silent" \
  "case \"\$out_ml_clean\" in *'nothing can read'*) false ;; *) true ;; esac"


section "== the kept-edits line says what it measured, and old backups expire (#227, #240) =="
# The pull printed "kept local edits the shared repo has not seen yet ... they go up on the next
# send" with a file list, and the sentence reads as the COMPLETE set of what is waiting to be
# sent. On 2026-08-30 it named three files while a status dry run moments later showed five
# differing, including two skills, which change behaviour in every session. What it actually
# measures is narrower and deliberately so: the paths this apply would otherwise have reverted.
# So it says that, and points at the command that does answer the wider question (L287, L11).
KEH="$WORK/keptline-home"; KER="$WORK/keptline-repo"
KEB="$WORK/keptline-bare.git"; git init -q --bare -b main "$KEB"
git clone -q "$KEB" "$KER" 2>/dev/null
mkdir -p "$KEH/hooks"
echo '{"hooks":{}}' > "$KEH/settings.json"
printf '# rules\n' > "$KEH/CLAUDE.md"
CLAUDE_HOME="$KEH" SYNC_REPO="$KER" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send >/dev/null 2>&1
printf '# rules edited locally\n' > "$KEH/CLAUDE.md"
out_ke="$(CLAUDE_HOME="$KEH" SYNC_REPO="$KER" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#227 pull holding back a local edit: $out_ke"
ke_line="$(printf '%s\n' "$out_ke" | sed -n '/would have reverted/p')"
check "#227 the line still names the file it held back" \
  "case \"\$ke_line\" in *CLAUDE.md*) true ;; *) false ;; esac"
# Both facts on ONE line, because a sentence naming the files and a different sentence somewhere
# else saying where to get the full set cannot answer between them (L178).
check "#227 and the same line points at status for the whole pending set" \
  "case \"\$ke_line\" in *status*) true ;; *) false ;; esac"

# ---- backups expire on their own (#240) ----
# Every pull that overwrites a file leaves a .syncbak, and every later run reminded the user about
# all of them for ever, in the words "Nothing here removes them, so an old one stays until you do".
# The safety net is right and the only exit was deleting files by hand, so the reminder became
# permanent noise: two backups from 2026-08-31 were still being announced on every pull.
KEO="$KEH/CLAUDE.md.syncbak"; printf 'an old backup\n' > "$KEO"
KEN="$KEH/settings.json.syncbak"; printf 'a fresh backup\n' > "$KEN"
# Aged by SETTING its mtime rather than by waiting, so the test is instant and pins both ends of
# the comparison rather than betting on the clock (L130, L290).
touch -t "$(date_minus_days_stamp 120)" "$KEO" 2>/dev/null || touch -t 202501010000 "$KEO"
out_ke240="$(CLAUDE_HOME="$KEH" SYNC_REPO="$KER" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_BACKUP_KEEP_DAYS=30 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#240 pull with one aged backup: $out_ke240"
check "#240 a backup past the age is removed" "[ ! -f '$KEO' ]"
check "#240 and its removal is announced rather than silent" \
  "case \"\$out_ke240\" in *CLAUDE.md.syncbak*) true ;; *) false ;; esac"
check "#240 a backup inside the age is kept" "[ -f '$KEN' ]"

# The command, for the person who wants them gone now rather than in a month.
out_ke240b="$(CLAUDE_HOME="$KEH" SYNC_REPO="$KER" SYNC_NO_NOTIFY=1 bash "$SCRIPT" clean-backups 2>&1 || true)"
dbg "#240 clean-backups: $out_ke240b"
check "#240 clean-backups removes the rest" "[ ! -f '$KEN' ]"
check "#240 and says how many it removed" \
  "case \"\$out_ke240b\" in *1*) true ;; *) false ;; esac"
# Run again with nothing to do. "Removed none" and "removed some" must not read the same (L98).
out_ke240c="$(CLAUDE_HOME="$KEH" SYNC_REPO="$KER" SYNC_NO_NOTIFY=1 bash "$SCRIPT" clean-backups 2>&1 || true)"
check "#240 and a run with nothing to remove says so in its own words" \
  "case \"\$out_ke240c\" in *'no '*|*none*) true ;; *) false ;; esac"


section "== status, the checkout's position, and one watcher (#258, #266, #196, #251) =="
# ---- #258: a payload subtree that does not exist yet ----
# The dry run reports every file under a MISSING destination as `>f.......`, whose flags mean
# nothing about this file differs, on the openrsync macOS ships. rsync 3.4.1, which the other Mac
# and the CI runner have, marks the same files `>f+++++++`, newly created. A whole directory that
# is new in the payload is exactly the case where every file in it is new, and that is the run
# where status can describe them as unchanged. status must NOT create the directory to make rsync
# happy: it is an inspection command and creating anything in the payload from it is L206.
# ONE status, carrying both answers. The fixture has two subtrees locally and only one of them in
# the payload, so the line has to name the missing one and leave the present one alone, and both
# facts come from the same measurement rather than from two runs that could differ for reasons
# nothing here controls (L159).
STH="$WORK/statusnew-home"; mkdir -p "$STH/hooks" "$STH/agents"
echo '{"hooks":{}}' > "$STH/settings.json"
printf '#!/usr/bin/env bash\n' > "$STH/hooks/brand-new.sh"
printf 'an agent\n' > "$STH/agents/already-there.md"
STR="$WORK/statusnew-repo"; mkdir -p "$STR/payload/agents"
out_258="$(CLAUDE_HOME="$STH" SYNC_REPO="$STR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" status 2>&1)"
dbg "#258 status with no payload/hooks: $out_258"
check "#258 status says the payload has no such subtree yet" \
  "case \"\$out_258\" in *'the payload has no hooks yet'*) true ;; *) false ;; esac"
check "#258 and it did not create the directory to find that out" \
  "[ ! -d '$STR/payload/hooks' ]"
# The control, from the same run: a subtree that IS there must not carry the line, or it is
# printed on every status and stops being read (L36).
check "#258 and it says nothing about a subtree that is already there" \
  "case \"\$out_258\" in *'the payload has no agents yet'*) false ;; *) true ;; esac"

# ---- #266: the development checkout's position, reported by the pull ----
# `pull` reports what changed under ~/.claude, and nothing reported that the checkout the config
# is actually EDITED in had fallen behind. On 2026-09-02 it was 40 commits behind immediately
# after a pull. An edit made in a stale checkout looks correct locally, and pushing it builds on
# work already in the shared repo but absent there.
dbg "#266 starting"
CKB="$WORK/checkout-bare.git"; git init -q --bare -b main "$CKB"
CKA="$WORK/checkout-A"; git clone -q "$CKB" "$CKA" 2>/dev/null
CKHA="$WORK/checkout-homeA"; mkdir -p "$CKHA/hooks"
echo '{"hooks":{}}' > "$CKHA/settings.json"
printf '# rules\n' > "$CKHA/CLAUDE.md"
CKENV="SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1"
CLAUDE_HOME="$CKHA" SYNC_REPO="$CKA" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send >/dev/null 2>&1
# The stale checkout: a second clone taken now, then left behind while A publishes more.
CKDEV="$WORK/checkout-dev"; git clone -q "$CKB" "$CKDEV" 2>/dev/null
printf '# rules again\n' > "$CKHA/CLAUDE.md"
CLAUDE_HOME="$CKHA" SYNC_REPO="$CKA" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send >/dev/null 2>&1
CKB2="$WORK/checkout-B"; git clone -q "$CKB" "$CKB2" 2>/dev/null
CKHB="$WORK/checkout-homeB"; mkdir -p "$CKHB"
echo '{"hooks":{}}' > "$CKHB/settings.json"
CKREG="$WORK/checkout-clones"; printf '%s\n%s\n' "$CKB2" "$CKDEV" > "$CKREG"
dbg "#266 about to pull"
out_266="$(CLAUDE_HOME="$CKHB" SYNC_REPO="$CKB2" SYNC_CLONE_REGISTRY="$CKREG" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#266 pull with a stale checkout registered: $out_266"
# Both facts on ONE line: the path and how far behind it is. A count with no path, or a path with
# no count, sends the reader to work out the other half (L178, L80).
line_266="$(printf '%s\n' "$out_266" | sed -n "\|$CKDEV|p" | sed -n '/behind/p')"
check "#266 the pull says the other checkout is behind, and by how much" \
  "case \"\$line_266\" in *'1 commit'*) true ;; *) false ;; esac"
# The control. A checkout that is level says nothing, or the line is on every pull (L36).
git -C "$CKDEV" pull -q 2>/dev/null || true
out_266b="$(CLAUDE_HOME="$CKHB" SYNC_REPO="$CKB2" SYNC_CLONE_REGISTRY="$CKREG" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
check "#266 a checkout that is level is not reported" \
  "case \"\$out_266b\" in *\"$CKDEV is\"*) false ;; *) true ;; esac"
# A registered clone that has GONE is unresolvable, not up to date (L98).
CKREG2="$WORK/checkout-clones2"; printf '%s\n%s\n' "$CKB2" "$WORK/checkout-that-left" > "$CKREG2"
out_266c="$(CLAUDE_HOME="$CKHB" SYNC_REPO="$CKB2" SYNC_CLONE_REGISTRY="$CKREG2" SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
check "#266 a clone that has gone is reported as unanswerable, not as up to date" \
  "case \"\$out_266c\" in *'is not there any more'*) true ;; *) false ;; esac"

# ---- #196: every send outcome reaches the log, not only the failures ----
# Local config changes sat unsent for 29 hours on 2026-08-23 while the watch daemon was running,
# and nothing reported it. The watch loop wrote a line ONLY when a send failed, so the log could
# not tell a watcher sending normally from one that had stopped: in 22 KB covering weeks there was
# exactly one line, a network blip. That is L98 exactly.
WOB="$WORK/watchout-bare.git"; git init -q --bare -b main "$WOB"
WOR="$WORK/watchout-repo"; git clone -q "$WOB" "$WOR" 2>/dev/null
WOH="$WORK/watchout-home"; mkdir -p "$WOH/hooks"
echo '{"hooks":{}}' > "$WOH/settings.json"
printf '# rules\n' > "$WOH/CLAUDE.md"
out_196="$(CLAUDE_HOME="$WOH" SYNC_REPO="$WOR" SYNC_IN_WATCH=1 SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 env bash "$SCRIPT" send 2>&1)"
dbg "#196 a watcher send that published: $out_196"
check "#196 a send that published says so in a shape the watcher can read" \
  "case \"\$out_196\" in *'SEND-OUTCOME sent'*) true ;; *) false ;; esac"
out_196b="$(CLAUDE_HOME="$WOH" SYNC_REPO="$WOR" SYNC_IN_WATCH=1 SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 env bash "$SCRIPT" send 2>&1)"
check "#196 and a send with nothing to publish says THAT, distinctly" \
  "case \"\$out_196b\" in *'SEND-OUTCOME nothing'*) true ;; *) false ;; esac"
# The control, and it is the reason the marker is conditional: a person running send by hand has
# the sentences and does not need a token in their output.
out_196c="$(CLAUDE_HOME="$WOH" SYNC_REPO="$WOR" SYNC_NO_NOTIFY=1 SYNC_NO_SEND_TESTS=1 bash "$SCRIPT" send 2>&1)"
check "#196 and a send run by hand carries no marker" \
  "case \"\$out_196c\" in *SEND-OUTCOME*) false ;; *) true ;; esac"

# ---- #251: one watcher at a time ----
# status showed THREE watch processes on 2026-08-31 where one is expected, one started
# independently and nested two deep. They all react to the same edit, which is a concurrency
# hazard rather than clutter, and the report told the reader to fix it by hand.
WPID="$WORK/watch-pid"
WFS="$WORK/watch-fake-fswatch"
printf '#!/usr/bin/env bash\necho one\n' > "$WFS"; chmod +x "$WFS"
# A LIVE process whose command line really does look like a watcher, because the guard confirms
# what the pid IS rather than trusting the number: a stale pid is reused constantly, and a guard
# that trusts it refuses to start because something unrelated inherited it (L237, L70).
WFAKE="$WORK/claude-sync"
# A single foreground sleep, deliberately: a `while :; do sleep 3600 & wait; done` body leaves an
# hour long orphan behind the moment the parent is killed, and this suite is not allowed to leave
# processes on the machine. Its own sleep bounds it, so even a run that never reaches the kill
# below cannot leave anything for long.
printf '#!/usr/bin/env bash\nsleep 120\n' > "$WFAKE"; chmod +x "$WFAKE"
bash "$WFAKE" watch >/dev/null 2>&1 &
w_pid=$!
printf '%s\n' "$w_pid" > "$WPID"
out_251="$(CLAUDE_HOME="$WOH" SYNC_REPO="$WOR" SYNC_FSWATCH="$WFS" SYNC_WATCH_PID_FILE="$WPID" SYNC_NO_NOTIFY=1 SYNC_WATCH_SEND=true bash "$SCRIPT" watch 2>&1 || true)"
dbg "#251 a second watcher: $out_251"
check "#251 a second watcher refuses to start while one is live" \
  "case \"\$out_251\" in *'already running'*) true ;; *) false ;; esac"
check "#251 and it names the process so it can be ended" \
  "case \"\$out_251\" in *$w_pid*) true ;; *) false ;; esac"
# SIGKILL, which nothing can block, and then `wait` only to reap it. The process-tree helper was
# tried here and the run hung: it stops a process before walking it, and a wait on a process the
# walk did not finish killing blocks for ever, which is a worse failure than the one under test
# (L110). There is one process to end here and no tree to walk.
kill -9 "$w_pid" 2>/dev/null || true
wait "$w_pid" 2>/dev/null || true
# The control, and it is what stops the guard being a way to never start at all: a pid file left
# by a watcher that has GONE must not refuse the next one (L214).
printf '%s\n' "$w_pid" > "$WPID"
out_251b="$(CLAUDE_HOME="$WOH" SYNC_REPO="$WOR" SYNC_FSWATCH="$WFS" SYNC_WATCH_PID_FILE="$WPID" SYNC_NO_NOTIFY=1 SYNC_WATCH_SEND=true bash "$SCRIPT" watch 2>&1 || true)"
check "#251 a pid file left by a watcher that has gone does not refuse the next one" \
  "case \"\$out_251b\" in *'already running'*) false ;; *) true ;; esac"


section "== a pull with nothing pending names nothing, and the audits travel (#238, #224, #220) =="
# The kept-edits line is the one that protects an edit made on one Mac from being silently reverted
# by the other, so a false positive is expensive: it fires on every pull, teaches the reader to
# skip it, and the one time it names a genuinely unsent edit it reads the same as all the noise
# (L36). On 2026-08-30 it named LESSONS.md and LESSONS-INDEX.md with nothing pending.
UPB="$WORK/untouched-bare.git"; git init -q --bare -b main "$UPB"
UPA="$WORK/untouched-A"; git clone -q "$UPB" "$UPA" 2>/dev/null
UPHA="$WORK/untouched-homeA"; mkdir -p "$UPHA/hooks" "$UPHA/audits/2026-01-01-an-audit"
echo '{"hooks":{}}' > "$UPHA/settings.json"
# CLAUDE.md IMPORTS them, because that is what puts a file in the synced top level set at all: the
# list is derived from the imports rather than from a fixed list, so a fixture whose CLAUDE.md
# imports nothing never exercises the top level comparison and the check passes by reading nothing
# (L98). Found exactly that way: the first version of this section passed with the fix removed.
printf '# rules\n@LESSONS.md\n@LESSONS-INDEX.md\n' > "$UPHA/CLAUDE.md"
printf '# Lessons\n\n## Proof over green\n\n- **L1. A readable one.** body\n' > "$UPHA/LESSONS.md"
printf 'the evidence a lesson cites\n' > "$UPHA/audits/2026-01-01-an-audit/findings.md"
CLAUDE_HOME="$UPHA" SYNC_REPO="$UPA" SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" send >/dev/null 2>&1
UPB2="$WORK/untouched-B"; git clone -q "$UPB" "$UPB2" 2>/dev/null
UPHB="$WORK/untouched-homeB"; mkdir -p "$UPHB"
echo '{"hooks":{}}' > "$UPHB/settings.json"
CLAUDE_HOME="$UPHB" SYNC_REPO="$UPB2" SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull >/dev/null 2>&1
# The SECOND pull is the one under test: everything has landed, nothing has been edited here, so
# there is nothing this apply could have reverted and nothing to name.
out_238="$(CLAUDE_HOME="$UPHB" SYNC_REPO="$UPB2" SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#238 a pull with an untouched tree: $out_238"
check "#238 a pull with nothing pending names nothing as held back" \
  "case \"\$out_238\" in *'would have reverted'*) false ;; *) true ;; esac"
# Specifically the derived index, and this is the case that actually occurred: it is regenerated
# from LESSONS.md independently on each Mac, so the two copies differ whenever the lessons differ
# or the generators do, with no work at risk. The comparison runs BEFORE the apply regenerates it,
# so a differing index was named on every such pull. Staged by making the local index differ,
# which is what a merge, or the other Mac running an older generator, produces.
printf 'a line only this Mac has\n' >> "$UPHB/LESSONS-INDEX.md"
out_238i="$(CLAUDE_HOME="$UPHB" SYNC_REPO="$UPB2" SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
dbg "#238 a pull whose local index differs: $out_238i"
# Matched on the LINE that holds both, not on the file name anywhere in the output: the index is
# legitimately named by the received-changes summary in the same run, and a check that cannot tell
# those two apart is answered by the wrong one (L135, L178).
check "#238 a derived index that differs is not named as an unsent edit" \
  "! line_has \"\$out_238i\" 'would have reverted' 'LESSONS-INDEX'"
# And it was REBUILT rather than left, which is the other half of why naming it would be wrong.
check "#238 and it was regenerated from the lessons file instead" \
  "! grep -q 'a line only this Mac has' '$UPHB/LESSONS-INDEX.md'"
# The control, in the same fixture: a real local edit IS still named, or this would have been
# fixed by making the message unable to say anything (L159).
printf '# rules edited here\n@LESSONS.md\n@LESSONS-INDEX.md\n' > "$UPHB/CLAUDE.md"
out_238b="$(CLAUDE_HOME="$UPHB" SYNC_REPO="$UPB2" SYNC_NO_HOOK_TESTS=1 bash "$SCRIPT" pull 2>&1 || true)"
check "#238 a real unsent edit is still named" \
  "case \"\$out_238b\" in *'would have reverted'*CLAUDE.md*) true ;; *) false ;; esac"

# ---- the audits travel with the lessons that cite them (#224) ----
# LESSONS.md cites audits/ as the full provenance for two batches of lessons, and the directory was
# not synced, so on the other Mac those pointers named files that do not exist and a lesson's
# evidence could not be read there at all.
check "#224 an audit reaches the other Mac" \
  "[ -f '$UPHB/audits/2026-01-01-an-audit/findings.md' ]"
check "#224 and it is the whole file, not a placeholder" \
  "grep -q 'the evidence a lesson cites' '$UPHB/audits/2026-01-01-an-audit/findings.md'"

# ---- every seam the tool honours is either set here or tested somewhere (#220) ----
# A test that seams SOME of a script's collaborators runs the rest for real, and the real ones are
# the slow and the dangerous ones (L52, L196). The list is DERIVED from the tool rather than kept
# by hand beside it, or the next seam added is exempt from the very rule this checks (L96, L41).
_seams(){ grep -ohE 'SYNC_NO_[A-Z_]+' "$SCRIPT" | sort -u; }
_seam_unset=""
while IFS= read -r _sm; do
  [ -n "$_sm" ] || continue
  # Set for the whole suite by the prelude, or named by a section that deliberately exercises its
  # OFF state. Either is fine; neither is not.
  case "$(eval "printf '%s' \"\${$_sm:-}\"")" in
    [1-9]*) continue ;;
  esac
  grep -q "$_sm" "$SCRIPT_SELF" || _seam_unset="$_seam_unset[$_sm never mentioned]"
done <<SEAMS
$(_seams)
SEAMS
check "#220 the seam list was actually derived" "[ \"\$(_seams | grep -c .)\" -ge 4 ]"
check "#220 every seam the tool reads is set here or exercised by a section" \
  "[ -z \"\$_seam_unset\" ] || { echo \"    \$_seam_unset\" >&2; false; }"
# And the two the prelude sets are really set, or the check above passes by reading nothing (L98).
check "#220 the notifier seam is on for the whole suite" "[ \"\$SYNC_NO_NOTIFY\" = 1 ]"
check "#220 and the watcher marker points inside this run's own directory" \
  "case \"\$SYNC_WATCH_PID_FILE\" in \"$WORK\"/*) true ;; *) false ;; esac"

section "== this file's check cannot be handed the other suite's argument (#231) =="
# tests/test-claude-sync.sh defines `check <description> <expression>` and EVALS the second
# argument. payload/hooks/test-run-all-tests.sh defines `check <description> <result>` and compares
# it against the literal `ok`. Same name, opposite meaning, one repo, and a shared name is read as
# evidence of shared behaviour so the two are never compared (L263).
#
# Walked into on 2026-08-30: a case block written in the runner suite's convention was pasted here,
# so a page of captured suite output went to `eval`. It RAN, produced a confusing failure inside an
# unrelated helper, and killed the run with an unbound variable error naming the `bad` helper
# rather than anything to do with the mistake. The failure mode is arbitrary execution of captured
# output, not a wrong answer, which is why this refuses rather than merely reporting.
#
# Watched giving BOTH answers, through the predicate `check` itself uses, so the probes exercise
# the shipped rule rather than a second copy of it (L107, L151).
check_expr_shape "[ 1 = 1 ]" \
  && check "#231 an ordinary expression is accepted" "true" \
  || check "#231 an ordinary expression is accepted" "false"
# The commonest correct form in this file, and the one the first version of this rule REJECTED:
# an environment prefix is a leading assignment, and a rule that refuses those refuses seven real
# checks (L104).
check_expr_shape "CLAUDE_HOME=/tmp/x SYNC_REPO=/tmp/y bash /bin/echo hi" \
  && check "#231 an environment prefixed command is still accepted" "true" \
  || check "#231 an environment prefixed command is still accepted" "false"
check_expr_shape "ok" \
  && check "#231 the other suite's 'ok' is refused" "false" \
  || check "#231 the other suite's 'ok' is refused" "true"
# A captured failure message, which is what was actually pasted. It is refused because bash cannot
# parse it, and being refused is what stops it reaching eval.
check_expr_shape "out=SUITE-RESULT passed=3 failed=1 (unbalanced" \
  && check "#231 an unparseable captured message is refused" "false" \
  || check "#231 an unparseable captured message is refused" "true"
# And the refusal SAYS which convention it thinks you used, or the reader is told their expression
# is bad without being told what to write instead (L11, L111).
# Copied out FIRST: `check` calls the predicate itself, which resets the reason before the
# expression is evaluated, so reading the live variable inside a check always finds it empty.
check_expr_shape "ok" || true
_231_why="$CHECK_SHAPE_WHY"
check "#231 and the refusal names the other suite" \
  "case \"\$_231_why\" in *test-run-all-tests.sh*) true ;; *) false ;; esac"

section "== the suite never touches a real shell rc =="
check "SYNC_ZSHRC is redirected suite-wide"  "[ \"\$SYNC_ZSHRC\" = '$WORK/zshrc-guard' ]"
check "the guard file stayed inside the temp dir" "[ ! -e \"\$HOME/.zshrc.claude-sync-test\" ]"

suite_profile
echo ""
echo "PASS=$PASS FAIL=$FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
