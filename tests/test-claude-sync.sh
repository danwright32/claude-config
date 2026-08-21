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

section_close(){
  [ -n "$_SEC_TITLE" ] || return 0
  local _n=$(( (PASS - _SEC_P0) + (FAIL - _SEC_F0) ))
  local _d=$(( SECONDS - _SEC_T0 ))
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
suite_profile(){
  section_close
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
    sleep 2
  fi
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

# SECTION_UNTIL=<text> runs from the beginning UP TO AND INCLUDING the matching section, then stops.
#
# This comment used to say that "only the matching section" was tried and rejected, because running
# one alone produced 24 failures that were purely missing setup, and a tool that reports failures
# the code did not cause is worse than a slow one. That finding was true and is no longer, so it is
# recorded here rather than quietly deleted (claude-config#105).
#
# What changed is the file, not the judgement. The coupling got MEASURED: all 73 post-prelude
# sections were run in isolation, 68 passed alone, and the five that did not each read one variable
# an earlier section had set. Four of those five were accidents and were removed; the one real
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
# put numbers on it: 68 passed alone with no mechanism at all.
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
if { [ -n "${SECTION_ONLY:-}" ] || [ -n "${SECTION_UNTIL:-}" ] || [ -n "${SECTION_LIST:-}" ]; } && [ -z "${SUITE_FILTERED:-}" ]; then
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

if [ -n "${SECTION_ONLY:-}" ] && [ -z "${SUITE_FILTERED:-}" ]; then
  _sec_match "$SUITE_PRELUDE_END"
  if [ "$_so_hits" -ne 1 ]; then
    echo "test suite: the prelude boundary '$SUITE_PRELUDE_END' matches $_so_hits headings rather than exactly one, so which sections make up the prelude is not decided. Refusing rather than filtering against a boundary nobody can point at." >&2
    exit 2
  fi
  _so_pend="$_so_idx"

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

  # The transitive closure of what the target declares it needs. A declaration that resolves to
  # nothing, to several, or to a LATER section is an error before anything runs: each would leave
  # the prerequisite out while the run went on to report a result (L100, L151).
  _so_keep=""
  _so_queue="$_so_target"
  while [ -n "$_so_queue" ]; do
    _so_cur="${_so_queue%% *}"
    case "$_so_queue" in *" "*) _so_queue="${_so_queue#* }" ;; *) _so_queue="" ;; esac
    case " $_so_keep " in *" $_so_cur "*) continue ;; esac
    _so_keep="$_so_keep $_so_cur"
    while IFS= read -r _so_nd; do
      _so_nd="$(printf '%s' "$_so_nd" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      [ -n "$_so_nd" ] || continue
      _sec_match "$_so_nd"
      if [ "$_so_hits" -eq 0 ]; then
        echo "test suite: ${_so_titles[$_so_cur]} declares '# needs: $_so_nd', which matches no heading. A declaration that resolves to nothing would silently leave the prerequisite out and the run would report a result anyway." >&2
        exit 2
      fi
      if [ "$_so_hits" -gt 1 ]; then
        echo "test suite: ${_so_titles[$_so_cur]} declares '# needs: $_so_nd', which matches $_so_hits headings. Narrow it. The candidates are:" >&2
        printf '%s\n' "$_so_list" >&2
        exit 2
      fi
      if [ "$_so_idx" -ge "$_so_cur" ]; then
        echo "test suite: ${_so_titles[$_so_cur]} declares '# needs: $_so_nd', which is not EARLIER in the file. A prerequisite that runs afterwards cannot have prepared anything." >&2
        exit 2
      fi
      _so_queue="$_so_queue $_so_idx"
    done <<SONEEDS
${_so_needs[$_so_cur]}
SONEEDS
  done

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

  _so_name="$(section_title "${_so_titles[$_so_target]}")"
  printf '\nsuite_filtered_tail "SECTION_ONLY resolved to %s" "%s"; exit $?\n' "$_so_name" "$_so_name" >> "$_filtered"

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
  # this file was measured printing 54 ok lines and no failures in exactly that state, saved only by
  # a fifth read that happened to be at top level. pipefail is already set, and tee exits 0, so the
  # status here is still the run's own.
  _so_log="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
  SUITE_FILTERED=1 SECTION_ONLY= SUITE_TARGET_SECTION="$_so_name" SUITE_DEPTH="$SUITE_DEPTH" SCRIPT="$SCRIPT" SCRIPT_SELF="$SCRIPT_SELF" bash "$_filtered" 2>&1 | tee "$_so_log"; _so_rc=$?
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
export -n SUITE_FILTERED SECTION_ONLY SECTION_LIST SUITE_FROM_COPY 2>/dev/null || true

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
SUITE_TIMEOUT="${SUITE_TIMEOUT:-900}"
case "$SUITE_TIMEOUT" in
  ''|*[!0-9]*)
    echo "test suite: SUITE_TIMEOUT='$SUITE_TIMEOUT' is not a whole number of seconds. Refusing to run rather than running with no deadline at all, which is the state this exists to end." >&2
    exit 4 ;;
esac
# Named from an explicit template, and not `mktemp -t`: the name is what lets an abandoned copy be
# attributed to this tool and reclaimed later (#36), and `-t` also means different things to BSD
# and GNU mktemp, which matters the moment this runs anywhere but a Mac.
SUITE_SECTION_MARK="$(mktemp "$SUITE_SCRATCH_HOME/claude-sync-suite-section.XXXXXXXX")"
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
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expr: $2)"; fi; }

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

# Named, not a bare `mktemp -d`. A run that is force-killed never reaches suite_cleanup, so this
# directory is abandoned, and an ANONYMOUS one cannot be attributed to this suite afterwards: the
# 37 found on this Mac on 2026-08-17, holding 475 MB, had to be identified by looking inside them,
# next to 542 belonging to other tools that a sweep by age alone would have deleted (#36).
WORK="$(mktemp -d "$SUITE_SCRATCH_HOME/claude-sync-suite-work.XXXXXXXX")"
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
mkskill "$CH/skills/plan-council/SKILL.md" 'SKILL custom'
mkskill "$CH/skills/wrangler/SKILL.md" 'SKILL plugin-owned'   # should be EXCLUDED from sync
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
check "the self-updating pull still reports the change" "printf '%s' \"\$out_up\" | grep -q 'added  *NOTES\.md'"
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
check "local script edit: the pull says it kept it"  "line_has \"\$out_le\" 'kept local edits' 'skills/reel/push\.py'"
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
check "unsent lesson: the unrelated change still arrives"  "grep -q other-v2 '$TFBH/hooks/tf-other.sh'"
check "the unsent lesson is NOT reverted"       "grep -q MY-NEW-LESSON '$TFBH/LESSONS.md'"
check "the earlier lesson is still there too"   "grep -q 'first lesson' '$TFBH/LESSONS.md'"
check "unsent lesson: the pull says it kept it"  "line_has \"\$out_tf\" 'kept local edits' 'LESSONS\.md'"
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
check "and the merge is reported"               "line_has \"\$out_tfc\" 'entries were MERGED' 'LESSONS\.md'"

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
# Counted BEFORE anything is spawned, because this run has a watchdog of its own and an
# assertion that none exist at all can only ever fail. What has to be true is that the children
# below leave none of THEIRS behind.
_wd_before="$(pgrep -f suite-deadline-watchdog 2>/dev/null | wc -l | tr -d ' ')"
_t0="$(date +%s)"
_hang="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SUITE_TIMEOUT=6 SUITE_HANG_IN=push bash "$SCRIPT_SELF" 2>&1)"; _hang_rc=$?
_elapsed=$(( $(date +%s) - _t0 ))
check "#31 a hung run ends instead of waiting for ever" "[ '$_hang_rc' -ne 0 ]"
# 30s against a 6s deadline. Deliberately not a tight bound: what this has to catch is the run
# taking as long as whatever it was sitting in, which is what happened when only the run itself
# was killed and its children were left holding the output open.
check "#31 it ends near its deadline rather than long after" "[ '$_elapsed' -lt 30 ]"
check "#31 it says plainly that it timed out"   "printf '%s' \"\$_hang\" | grep -q 'TIMED OUT'"
check "#31 it names the section it died in"     "printf '%s' \"\$_hang\" | grep -q 'still inside section: == push =='"
# The whole point is that a hang stops reading as an ordinary run, so it must never leave behind
# the summary line that means everything passed.
check "#31 a hung run is never reported as green" "! printf '%s' \"\$_hang\" | grep -q 'FAIL=0'"

# The other half, and the one that would do real damage if it were wrong: a deadline that fires
# on a HEALTHY run turns every ordinary run into a false failure. A guard has to be seen not
# firing when it should not, not only firing when it should.
_okrun="$(SUITE_DEPTH=$SUITE_CHILD_DEPTH SECTION_UNTIL=push SUITE_TIMEOUT=300 bash "$SCRIPT_SELF" 2>&1)"; _okrun_rc=$?
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
  local a b c d e
  a="stat"" -f"; b="date"" -r "; c="sed"" -i ''"; d="date"" -v"; e="mktemp"" -t"
  # Continuation lines are joined first, or a spelling whose GNU fallback sits on the NEXT line
  # reads as unguarded and this reports two false findings for ever, which is how a guard stops
  # being read (L36).
  sed 's/#.*//' "$SCRIPT" "$SCRIPT_SELF" \
    | sed -e :a -e '/\\$/N; s/\\\n//; ta' \
    | grep -nF -e "$a" -e "$b" -e "$c" -e "$d" -e "$e" \
    | grep -vF "$a %m \"\$1\"" | grep -vF "$b\"\$1\"" \
    | grep -vE '\|\| +touch -d' || true
}
check "#38 no BSD-only spelling survives outside the two helpers" "[ -z \"\$(_bsdisms)\" ]"
# And the helpers really are there to be excluded, or the check above passes by matching nothing
# at all in a file that has been emptied or renamed.
check "#38 the portable helpers exist" \
  "grep -q '^file_mtime(){' '$SCRIPT' && grep -q '^date_from_epoch(){' '$SCRIPT' && grep -q '^_suite_mtime(){' '$SCRIPT_SELF'"

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
while IFS= read -r _row; do
  [ -n "$_row" ] || continue
  _cite="$(printf '%s' "$_row" | grep -oE 'proved by #[0-9]+' | head -1 | sed 's/.*#/#/')"
  if [ -z "$_cite" ]; then
    _uncited="$_uncited[$(printf '%s' "$_row" | cut -d'|' -f2 | sed 's/^ *//; s/ *$//')]"
    continue
  fi
  case "$_sections" in
    *"($_cite)"*) ;;
    *) _badcite="$_badcite[$_cite]" ;;
  esac
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
  "case \"\$_sections\" in *'(#99999)'*) false ;; *) true ;; esac"
check "#41 the heading scan really read the headings" "[ \"\$_sec_seen\" -ge 40 ]"
# Every default of the shape a threshold has, from BOTH files, as "NAME VALUE" pairs. Comments are
# stripped first, or prose quoting a number satisfies the check that the number is current, and a
# guard that is green on its own explanation is indistinguishable from one that works (L103).
_thresholds(){
  sed 's/#.*//' "$SCRIPT" "$SCRIPT_SELF" \
    | grep -ohE '\$\{(SYNC|SUITE)_[A-Z_]*(MAX_AGE|TIMEOUT|MAX_DEPTH|RETIRE_AFTER)[A-Z_]*:-[0-9]+\}' \
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
_readme_wrong=""
_readme_seen=0
while IFS=' ' read -r _tn _tv; do
  [ -n "$_tn" ] || continue
  _row="$(grep -F -- "$_tn" "$_README" || true)"
  [ -n "$_row" ] || continue
  _readme_seen=$((_readme_seen + 1))
  printf '%s' "$_row" | grep -qE "(^|[^0-9])$_tv([^0-9]|\$)" || _readme_wrong="$_readme_wrong[$_tn is $_tv in the code]"
done <<EOF
$(_thresholds)
EOF
check "#41 the README agrees about every threshold it names" "[ -z \"\$_readme_wrong\" ]"
check "#41 and it really did name some of them" "[ \"\$_readme_seen\" -ge 3 ]"
# Or both loops above compare nothing against nothing and pass while the table is entirely wrong,
# which is the state #30 had to be rescued from.
check "#41 the derivation found the thresholds to check" \
  "[ \"\$(_thresholds | grep -c .)\" -ge 6 ]"

section "== scratch a killed run left behind is reclaimed, and nothing else is (#36) =="
# A run that is force-killed never reaches its cleanup, so its scratch directory is abandoned and
# nothing ever reclaimed one. 37 of them were measured on this Mac on 2026-08-17 holding 475 MB,
# from one day of interrupted runs, alongside 92 abandoned apply logs.
#
# The whole risk of the fix is on the other side: the same temp directory held 542 anonymous
# `tmp.*` directories belonging to OTHER tools that day, so a sweep written as "old directories in
# the temp folder" would have deleted them. Every fixture below therefore points at a THROWAWAY
# root (L2), and the checks that matter most are the ones asserting what SURVIVES.
_SCR="$WORK/scratch-root"; mkdir -p "$_SCR"
_scr_age(){    # path
  touch -t "$(date -v-2H +%Y%m%d%H%M)" "$1" 2>/dev/null || touch -d '2 hours ago' "$1"
}
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
# figures of entries: measured 113,000 here, six passes, 1.28 seconds of every single `status` call
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

section "== the tool's scratch lives in a directory of its own (#116) =="
# The sweep for abandoned scratch globs the temp root, and on a real Mac that root belongs to
# everything else on the machine: 113,912 entries measured here, 25 of them ours. #115 cut six
# reads of it to one, taking `status` from 1.74s to 0.36s, and the one read left is most of what
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
_sub_age(){ touch -t "$(date -v-2H +%Y%m%d%H%M)" "$1" 2>/dev/null || touch -d '2 hours ago' "$1"; }

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

section "== a renumber's citation scan opens only the files that match (#53) =="
# The scan walked every synced file and ran a text test plus a matcher on each of them, once per
# renumbered lesson: 800 files (747 under skills/) at 8.4 seconds per lesson on the real config,
# roughly 2,400 processes, run in the background on every config edit. One grep answers the same
# question in 0.022 seconds.
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
ix_count="$(grep -c '^- L[0-9]' "$IXHB/LESSONS-INDEX.md" 2>/dev/null || echo 0)"
ix_header="$(grep -oE '[0-9]+ lessons' "$IXHB/LESSONS-INDEX.md" 2>/dev/null | grep -oE '[0-9]+' | head -1)"
ix_real="$(grep -c '^- \*\*L[0-9]' "$IXHB/LESSONS.md" 2>/dev/null || echo 0)"
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
# ambient state. Measured by running all 73 later sections in isolation: 68 passed alone with no
# mechanism at all, and the five that did not needed a variable an earlier section had set.
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
# 0. Measured on this file: one section did exactly that, 54 ok lines and no failures, and the only
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

section "== the deadline still has real headroom over a run (#112) =="
# The deadline is only meaningful as a MULTIPLE of a real run, and that multiple was written down
# once and then went stale in silence: the design record said 123 seconds and "roughly 7x" for
# eleven days while this Mac grew to 225 seconds, which is 4x. Nothing caught it, because the check
# beside that table compares the SETTING and never the measurement the setting was derived from
# (claude-config#112, L210).
#
# So the ratio is measured rather than recorded. There is no number here that can age: the run times
# itself and requires the deadline to be at least twice what it just took.
#
# Calibrated against both machines this runs on rather than guessed, because a floor sitting inside
# the normal range turns ordinary variation into a failure and an alarm that cries wolf stops being
# read (L172, L36): 225 seconds on this Mac and 110 on the Linux runner, against a 900 second
# deadline, so the floor is crossed only when the suite has genuinely grown into its own deadline.
#
# In a FILTERED run this passes trivially, because the run is shorter. That is said out loud rather
# than hidden: it bites on a full run, which is the run the deadline exists for.
_hr_elapsed=$SECONDS
_hr_min=$(( _hr_elapsed * 2 ))
if [ "$SUITE_TIMEOUT" -gt 0 ]; then
  check "#112 the deadline is at least twice the run it just watched" "[ '$SUITE_TIMEOUT' -ge '$_hr_min' ]"
else
  # A run with the deadline disabled has no headroom to check, and saying so is not the same as
  # checking it (L98). The setting is asserted instead, so this branch cannot pass by silence.
  check "#112 the deadline was deliberately disabled for this run" "[ '$SUITE_TIMEOUT' -eq 0 ]"
fi
# The same comparison, asked of a deadline one second under the floor, so it has been watched
# REFUSING rather than only agreeing (L1). Without this the check above is satisfied by any deadline
# large enough, which is every deadline, and it would read as protection while protecting nothing.
_hr_toosmall=$(( _hr_min - 1 ))
check "#112 a deadline one second under that floor is refused" "! [ '$_hr_toosmall' -ge '$_hr_min' ]"

section "== the suite never touches a real shell rc =="
check "SYNC_ZSHRC is redirected suite-wide"  "[ \"\$SYNC_ZSHRC\" = '$WORK/zshrc-guard' ]"
check "the guard file stayed inside the temp dir" "[ ! -e \"\$HOME/.zshrc.claude-sync-test\" ]"

suite_profile
echo ""
echo "PASS=$PASS FAIL=$FAIL"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
