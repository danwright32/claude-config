#!/usr/bin/env bash
#
# test-gate-payload-reader.sh: a scan over the hooks that can refuse, so the next one written
# cannot repeat claude-config#480 or claude-config#486 (L490, L613, L621).
#
# ONE FAULT, TWO PLACES IT LANDS. A hook reaches for an interpreter it never asked for, gets
# nothing back, tests that nothing, finds no reason to refuse, and exits 0. Nothing is said, and a
# run that measured nothing is indistinguishable from a clean one (L42, L98).
#
#   THE PAYLOAD (claude-config#480). The gate parsed its hook payload with jq or python3. Without
#   one, the payload came back empty and the gate could not even tell WHICH command it was looking
#   at: block-red-merge.sh allowed every merge, check-add-scope.sh allowed every unscoped add,
#   payload-write-gate.sh allowed every write under payload/.
#
#   THE DETECTOR (claude-config#486). The payload was legible and what could not run was the
#   hook's own rule. check-style-guide.sh scans the diff with python3: with none, the scan returned
#   an empty string and every push read as style clean. Nine more did the same, including the two
#   PostToolUse checks that judge an edit the moment it is written.
#
# So a hook is IN SCOPE when it CAN REFUSE (a deny decision, a block decision, or exit 2) and it
# reaches for an interpreter, by either route:
#   payload    the hook's own stdin piped straight into jq or python3, rather than through the
#              shared reader ps_parse_payload, which takes jq OR python3 and reports when it could
#              read neither
#   detector   any other python3 invocation: a scan, a lib/*.py, a JSON answer it builds
#
# and it satisfies this scan by NAMING the reader when it is absent, in the shapes this repo
# already speaks in:
#   ps_reader_missing / mt_reader_missing   it refuses, saying which tool is missing
#   command -v python3                      accepted for a DETECTOR only, never for a payload read,
#                                             because a detector's stand down is the hook's own
#                                             sentence and the payload rule needs the shared one
#   a "DID NOT RUN" notice                  it stands down loudly, saying so on stderr. This one
#                                             counts wherever it sits, because it is written to
#                                             handle the reader's OWN failure and so comes after it
#
# The ORDER is half the rule, not decoration. require-changelog-tag.sh carried a `command -v jq`
# check while being broken by exactly this defect, because the check sat BELOW the parse it was
# meant to protect and the gate had already exited on the empty command by the time anything
# reached it. A check present somewhere in a file says nothing about the region it was meant to
# guard (L135, L667).
#
# THE POPULATION IS DERIVED, never a list kept here, because a list checks only what somebody
# remembered to add to it (L96). It is the UNION of two derivations, because neither alone is the
# set of hooks that can refuse:
#   every hook any event in payload/settings.hooks.json registers, not only PreToolUse: the fault
#       reached PostToolUse (deferral-edit-check.sh, lesson-entry-check.sh) and TeammateIdle
#       (teammate-challenge-gate.sh), and a scan reading one event would have called those exempt
#   every *.sh in the hooks directory that is not a suite: a hook written but not yet registered,
#       and a guard that is run rather than registered, are both in this class and neither appears
#       in any settings file
#
# What this scan proves is the SHAPE, that the question is asked at all. Whether each hook refuses
# or speaks in the right direction is proved by its own suite, with the real hook driven under a
# PATH holding no reader.
#
# Seams, for the self test below: GATE_READER_SETTINGS and GATE_READER_HOOKS point at a fixture.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

# The hooks a settings file registers, on EVERY event, as basenames, one per line. Read with
# python3, which this suite may use freely: it is asking about a repository, not standing in for a
# machine with no interpreter.
#
# Every event, not only PreToolUse: claude-config#486 reached PostToolUse and TeammateIdle hooks,
# and a scan reading one event would have reported those three as exempt while they were the ones
# going silent (L96, L247).
registered_hooks() {  # $1 = a settings json file
  SETTINGS="$1" python3 -c '
import json, os, sys
try:
    with open(os.environ["SETTINGS"]) as fh:
        d = json.load(fh)
except Exception as exc:
    sys.stderr.write("could not read the settings file: %s\n" % exc)
    sys.exit(1)
seen = []
for event, matchers in ((d.get("hooks") or {}).items()):
    for matcher in matchers or []:
        for hook in matcher.get("hooks") or []:
            cmd = hook.get("command") or ""
            for word in cmd.split():
                if word.endswith(".sh"):
                    name = word.rsplit("/", 1)[-1]
                    if name not in seen:
                        seen.append(name)
print("\n".join(seen))
'
}

# The events this scan is about: the ones where a hook stands BETWEEN an action and its effect,
# which is what makes going silent an open gate rather than a lost nudge.
#
#   PreToolUse     refuses the tool call before it runs
#   PostToolUse    judges what was just written and holds the model there until it is dealt with
#   TeammateIdle   decides whether a teammate may stop working
#
# A Stop or SubagentStop hook is deliberately NOT one of these, and the reason is the exclusion
# rather than a list of files (L362): its turn's work is already done and its decision:block is a
# continuation instruction to Claude, so it refuses nothing. Going quiet there loses a nudge, not
# a gate, which is a real fault and a smaller one with a different message and a different shape:
# it must be said ONCE, because a Stop hook that blocks on every turn is worse than one that is
# quiet. That was claude-config#490 and it is done, in lib/stop-hook-python-notice.sh, covered by
# test-stop-hooks.sh. Stop stays out of this list rather than joining it now that it is handled,
# because what this scan means is the standing between an action and its effect, and widening it
# to cover a different fault would leave the name describing neither.
GATE_EVENTS="PreToolUse PostToolUse TeammateIdle"

# The events a settings file registers one hook on, one per line, or nothing when it names it on
# none.
events_of() {  # $1 = settings json file  $2 = hook basename
  SETTINGS="$1" NAME="$2" python3 -c '
import json, os, sys
try:
    with open(os.environ["SETTINGS"]) as fh:
        d = json.load(fh)
except Exception:
    sys.exit(0)
want = os.environ["NAME"]
out = []
for event, matchers in (d.get("hooks") or {}).items():
    for matcher in matchers or []:
        for hook in matcher.get("hooks") or []:
            for word in (hook.get("command") or "").split():
                if word.rsplit("/", 1)[-1] == want and event not in out:
                    out.append(event)
print("\n".join(out))
'
}

# True when this hook is one of the kinds above. A hook the settings name is judged by the events
# they name it on. One they do not name at all is judged by its own header line, which every hook
# here carries and lib/hook-registration.py already reads; with no header it is treated as IN
# scope, because the safe side of an unknown is being checked (L72).
stands_between_action_and_effect() {  # $1 = settings file  $2 = hook basename  $3 = the file
  local ev found=0
  while IFS= read -r ev; do
    [ -n "$ev" ] || continue
    found=1
    case " $GATE_EVENTS " in *" $ev "*) return 0 ;; esac
  done < <(events_of "$1" "$2")
  [ "$found" -eq 1 ] && return 1
  grep -Eqi '^#.*\b(Stop|SubagentStop) hook' "$3" && return 1
  return 0
}

# The population: what the settings register, plus every hook file sitting in the directory. A
# settings file cannot name a hook that is not registered yet, and a directory listing cannot name
# one installed from elsewhere, so neither derivation is the set on its own (L96, L582).
#
# Suites are excluded, because a suite's whole job is to talk about these shapes and it refuses
# nothing; so is the runner. Both by name, which is the one exemption here, and it is the reason
# rather than a list of files (L362).
in_scope_files() {  # $1 = settings file (may be missing)  $2 = hooks directory
  {
    [ -f "$1" ] && registered_hooks "$1"
    for f in "$2"/*.sh; do [ -f "$f" ] && basename "$f"; done
  } | sort -u
}

# The line number of the first line matching a pattern, or nothing. Comment lines are excluded on
# both sides: a comment DESCRIBING a reader check is not one, and a comment quoting the parse shape
# is not a parse.
#
# One awk reading the file directly, rather than a grep piped into head: a reader that leaves on
# its first match kills the producer, and under this suite's pipefail that death becomes the answer
# (L183). The patterns below are written with bracket expressions rather than backslash escapes,
# because a backslash inside a pattern handed to awk reads differently between the one the Mac
# ships and gawk, and neither errors (L434).
first_line() {  # $1 = file, $2 = an extended regular expression
  awk -v re="$2" '
    /^[[:space:]]*#/ { next }
    $0 ~ re { print NR; exit }
  ' "$1" 2>/dev/null
}

# True when a non-comment line of the file matches. The comment exclusion matters on BOTH sides:
# a file that only DESCRIBES refusing (lessons-advisory.sh's header says it deliberately does not
# emit permissionDecision) is not a gate, and a comment quoting a parse is not a parse.
has_code_line() {  # $1 = file, $2 = an extended regular expression
  awk -v re="$2" '
    /^[[:space:]]*#/ { next }
    $0 ~ re { found = 1; exit }
    END { exit(found ? 0 : 1) }
  ' "$1" 2>/dev/null
}

# One offender per line: "<hook>: <what it is missing>". Nothing on stdout is a clean scan.
scan_gates() {  # $1 = settings file, $2 = hooks directory
  local name file parse_at check_at det_at det_check_at loud
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    case "$name" in test-*|run-all-tests.sh) continue ;; esac
    file="$2/$name"
    # A hook the settings file names and the directory does not hold is a different fault, and
    # test-hook-coverage.sh is where it is reported. Nothing here can read a file that is not there.
    [ -f "$file" ] || continue

    # Does it stand between an action and its effect at all? See GATE_EVENTS above.
    stands_between_action_and_effect "$1" "$name" "$file" || continue

    # Can it refuse? A deny decision, a block decision, or exit 2. A hook that can only ever say
    # something is an advisory one, and an advisory that goes quiet is a different and smaller
    # fault than a gate that opens.
    has_code_line "$file" '(permissionDecision|"decision":[[:space:]]*"block"|exit 2)' || continue

    # A loud stand down satisfies BOTH rules below wherever it sits: a DID NOT RUN notice is
    # written to handle the reader's OWN failure, so it necessarily comes after it, and it names
    # the reader either way.
    loud=0
    grep -q 'DID NOT RUN' "$file" && loud=1

    # RULE ONE, the payload (claude-config#480). Does it parse the payload ITSELF, the hook's own
    # stdin piped straight into a parser? A read through ps_parse_payload does not match, which is
    # the point of having it.
    parse_at="$(first_line "$file" '"[$](payload|input)"[[:space:]]*[|][[:space:]]*(jq|python3)')"
    if [ -n "$parse_at" ] && [ "$loud" -eq 0 ]; then
      # The question has to be asked BEFORE the answer is used. Asked anywhere in the file is not
      # enough: require-changelog-tag.sh carried a jq check BELOW the jq parse it was meant to
      # protect, and the gate exited on the empty command long before reaching it (L135, L667).
      # A bare `command -v jq` is not accepted here: only the shared predicate carries the sentence
      # that names the reader to the person (L400).
      check_at="$(first_line "$file" '(ps_reader_missing|mt_reader_missing)')"
      if [ -z "$check_at" ]; then
        printf '%s: parses the hook payload itself and can refuse, but never asks whether the reader is installed\n' "$name"
      elif [ "$check_at" -gt "$parse_at" ]; then
        printf '%s: parses the hook payload at line %s, above the reader check at line %s, so the gate has already answered by the time the check is reached\n' \
          "$name" "$parse_at" "$check_at"
      fi
    fi

    # RULE TWO, the detector (claude-config#486). Any python3 invocation at all: the scan that
    # holds the rule, the lib/*.py it hands the work to, the JSON answer it builds. The payload
    # parse above is one of these too, so a hook satisfying rule one satisfies this one with the
    # same check; the two are separate because their remedies and their messages differ (L11).
    det_at="$(first_line "$file" 'python3')"
    [ -n "$det_at" ] || continue
    [ "$loud" -eq 1 ] && continue
    # `command -v python3` counts HERE and not above. A detector's stand down is the hook's own
    # sentence about its own rule, which is why check-duplication.sh and check-public-assets.sh
    # were already right; a payload read has no sentence of its own and has to use the shared one.
    det_check_at="$(first_line "$file" '(ps_reader_missing|mt_reader_missing|command -v python3)')"
    if [ -z "$det_check_at" ]; then
      printf '%s: runs its detector through python3 at line %s and can refuse, but never asks whether python3 is installed\n' "$name" "$det_at"
    elif [ "$det_check_at" -gt "$det_at" ]; then
      printf '%s: reaches for python3 at line %s, above the check at line %s, so it has already answered by the time the check is reached\n' \
        "$name" "$det_at" "$det_check_at"
    fi
  done < <(in_scope_files "$1" "$2")
}

echo "gate payload reader: the scan itself"

# The scan is seen to FIRE before it is believed about anything (L1). A fixture repository with one
# gate of each kind, so a clean answer over the real tree further down means the scan looked.
FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gate-payload-reader.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/hooks"
cat > "$FIX/settings.json" <<'JSON'
{"hooks": {
  "PreToolUse": [
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/silent-gate.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/refusing-gate.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/saying-gate.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/shared-reader-gate.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/late-check-gate.sh"}]},
    {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/advisory.sh"}]}
  ],
  "PostToolUse": [
    {"matcher": "Edit", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/silent-detector-post.sh"}]}
  ],
  "Stop": [
    {"hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/silent-detector-stop.sh"}]}
  ]
}}
JSON
# Parses the payload itself, can refuse, and says nothing about a reader: the fault.
cat > "$FIX/hooks/silent-gate.sh" <<'SH'
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
case "$cmd" in *danger*) echo "no" >&2; exit 2 ;; esac
SH
# The same shape, refusing by name.
cat > "$FIX/hooks/refusing-gate.sh" <<'SH'
payload="$(cat)"
ps_reader_missing jq python3 && { echo "no reader" >&2; exit 2; }
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
case "$cmd" in *danger*) echo "no" >&2; exit 2 ;; esac
SH
# The same shape, standing down loudly instead.
cat > "$FIX/hooks/saying-gate.sh" <<'SH'
payload="$(cat)"
cmd="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("x",""))')" \
  || { echo "GATE DID NOT RUN: no python3" >&2; exit 0; }
case "$cmd" in *danger*) echo "no" >&2; exit 2 ;; esac
SH
# Reads through the shared reader, which answers for both tools and reports when it could read
# neither, so it is not the shape this scan is about.
cat > "$FIX/hooks/shared-reader-gate.sh" <<'SH'
payload="$(cat)"
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
case "$parsed" in *danger*) echo "no" >&2; exit 2 ;; esac
SH
# Asks the question, but below the parse whose answer it was meant to guard: the gate has already
# exited on the empty command by then. This is the shape that made require-changelog-tag.sh look
# protected while being broken.
cat > "$FIX/hooks/late-check-gate.sh" <<'SH'
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
case "$cmd" in *danger*) ;; *) exit 0 ;; esac
ps_reader_missing jq && { echo "no reader" >&2; exit 2; }
echo "no" >&2; exit 2
SH
# Parses the payload itself and can only ever say something. Not a gate, so not in scope. Its
# header also TALKS about refusing, which is what lessons-advisory.sh's does: a comment saying a
# hook deliberately emits no permissionDecision must not make it one (L103).
cat > "$FIX/hooks/advisory.sh" <<'SH'
# This hook deliberately does NOT emit permissionDecision and never uses exit 2.
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
case "$cmd" in *danger*) echo "you might want to look at that" >&2 ;; esac
exit 0
SH
# --- the DETECTOR half (claude-config#486) ------------------------------------
# The payload is read through the shared reader, so rule one has nothing to say, and the hook's
# own RULE runs through python3 with nothing asking whether it is there. This is check-style-guide
# before this change: the scan returns an empty string and every push reads as clean.
cat > "$FIX/hooks/silent-detector-gate.sh" <<'SH'
payload="$(cat)"
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
findings="$(printf '%s' "$parsed" | python3 -c 'import sys; print(sys.stdin.read().count("danger") or "")')"
[ -n "$findings" ] || exit 0
echo "no" >&2; exit 2
SH
# The same shape with the question asked above the detector: cleared.
cat > "$FIX/hooks/checked-detector-gate.sh" <<'SH'
payload="$(cat)"
ps_reader_missing python3 && { echo "no detector" >&2; exit 2; }
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
findings="$(printf '%s' "$parsed" | python3 -c 'import sys; print(sys.stdin.read().count("danger") or "")')"
[ -n "$findings" ] || exit 0
echo "no" >&2; exit 2
SH
# And with a plain `command -v python3`, which is accepted for a detector and not for a payload
# read: the hook's stand down is its own sentence about its own rule (check-duplication.sh).
cat > "$FIX/hooks/command-v-detector-gate.sh" <<'SH'
payload="$(cat)"
command -v python3 >/dev/null 2>&1 || { echo "skipped: no python3, so nothing was compared" >&2; exit 0; }
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
findings="$(printf '%s' "$parsed" | python3 -c 'import sys; print(sys.stdin.read().count("danger") or "")')"
[ -n "$findings" ] || exit 0
echo "no" >&2; exit 2
SH
# The check present but BELOW the detector it was meant to guard: the hook has already answered.
cat > "$FIX/hooks/late-detector-gate.sh" <<'SH'
payload="$(cat)"
parsed="$(ps_parse_payload "$payload" raw)" || exit 0
findings="$(printf '%s' "$parsed" | python3 -c 'import sys; print(sys.stdin.read().count("danger") or "")')"
[ -n "$findings" ] || exit 0
command -v python3 >/dev/null 2>&1 || { echo "no python3" >&2; exit 2; }
echo "no" >&2; exit 2
SH
# A PostToolUse hook that BLOCKS with a decision rather than an exit code, and runs its rule
# through python3 unasked: lesson-entry-check.sh before this change. Registered on PostToolUse in
# the settings above, so this also proves the population is not read from PreToolUse alone.
cat > "$FIX/hooks/silent-detector-post.sh" <<'SH'
payload="$(cat)"
target="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_input"]["file_path"])')"
[ -n "$target" ] || exit 0
printf '{"decision": "block", "reason": "no"}\n'
exit 0
SH
# A hook that reaches for python3 and can refuse NOTHING: an advisory, out of scope here, and the
# reason the two halves of this scan share the can-refuse question.
cat > "$FIX/hooks/detector-advisory.sh" <<'SH'
payload="$(cat)"
printf '%s' "$payload" | python3 -c 'import sys; sys.stdout.write(sys.stdin.read())'
exit 0
SH
# Byte for byte the same shape as silent-detector-post.sh, on Stop instead. It refuses nothing:
# the turn's work is already done and its block is a continuation instruction. Out of scope, and
# the PostToolUse twin above is what proves the exclusion is the EVENT and not the shape (L159).
cat > "$FIX/hooks/silent-detector-stop.sh" <<'SH'
payload="$(cat)"
target="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_input"]["file_path"])')"
[ -n "$target" ] || exit 0
printf '{"decision": "block", "reason": "no"}\n'
exit 0
SH
# The same again, registered on NO event at all, saying in its own header what it is. A hook the
# settings do not name is judged by that line, or the directory half of the population would drag
# every Stop hook back in through the other door (L173).
cat > "$FIX/hooks/unregistered-stop.sh" <<'SH'
# Global Stop hook: it says so here because nothing registers it in this fixture.
payload="$(cat)"
target="$(printf '%s' "$payload" | python3 -c 'import json,sys; print(json.load(sys.stdin)["tool_input"]["file_path"])')"
[ -n "$target" ] || exit 0
printf '{"decision": "block", "reason": "no"}\n'
exit 0
SH

found="$(scan_gates "$FIX/settings.json" "$FIX/hooks")"
case "$found" in
  *silent-gate.sh*) check "the scan reports a gate that parses the payload and names no reader" ok ;;
  *) check "the scan reports a gate that parses the payload and names no reader" "it reported: ${found:-nothing}" ;;
esac
case "$found" in
  *late-check-gate.sh*) check "the scan reports a reader check that sits below the parse" ok ;;
  *) check "the scan reports a reader check that sits below the parse" "it reported: ${found:-nothing}" ;;
esac
case "$found" in
  *silent-detector-gate.sh*) check "the scan reports a gate whose DETECTOR runs through python3 unasked" ok ;;
  *) check "the scan reports a gate whose DETECTOR runs through python3 unasked" "it reported: ${found:-nothing}" ;;
esac
case "$found" in
  *late-detector-gate.sh*) check "the scan reports a detector check that sits below the detector" ok ;;
  *) check "the scan reports a detector check that sits below the detector" "it reported: ${found:-nothing}" ;;
esac
# The population is not read from PreToolUse alone: this one is registered on PostToolUse and
# refuses with a block decision rather than an exit code (L96, L247).
case "$found" in
  *silent-detector-post.sh*) check "the scan reaches a PostToolUse hook that blocks with a decision" ok ;;
  *) check "the scan reaches a PostToolUse hook that blocks with a decision" "it reported: ${found:-nothing}" ;;
esac
# And each way of satisfying it clears, or the scan is one that fails on everything and proves
# nothing by firing (L159).
for cleared in refusing-gate.sh saying-gate.sh shared-reader-gate.sh advisory.sh \
               checked-detector-gate.sh command-v-detector-gate.sh detector-advisory.sh \
               silent-detector-stop.sh unregistered-stop.sh; do
  case "$found" in
    *"$cleared"*) check "$cleared is not reported" "the scan reported it too" ;;
    *) check "$cleared is not reported" ok ;;
  esac
done

# A hook the SETTINGS never name is still in scope, because the directory is read too: a hook
# written but not registered yet, and a guard that is run rather than registered, are both in this
# class (L96). silent-detector-gate.sh above is exactly that: nothing in the settings names it.
case "$(registered_hooks "$FIX/settings.json")" in
  *silent-detector-gate.sh*) check "the unregistered fixture really is absent from the settings" "the settings name it, so the directory half proves nothing" ;;
  *) check "the unregistered fixture really is absent from the settings" ok ;;
esac

echo "gate payload reader: every hook in this repo that can refuse"

SETTINGS="${GATE_READER_SETTINGS:-$DIR/../settings.hooks.json}"
HOOKS="${GATE_READER_HOOKS:-$DIR}"
if [ ! -f "$SETTINGS" ]; then
  echo "test-gate-payload-reader: there is no settings file at $SETTINGS, so no gate could be enumerated." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hooks, and there is none at $SETTINGS"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# The population is worth asserting on its own: a settings file this could not read, or a hooks
# directory it could not list, would answer "no hooks" and read exactly like a clean scan (L98).
gates="$(registered_hooks "$SETTINGS" | wc -l | tr -d ' ')"
if [ "${gates:-0}" -ge 5 ]; then
  check "the settings file really names a set of hooks" ok
else
  check "the settings file really names a set of hooks" "it named $gates, so this scan read almost nothing"
fi
population="$(in_scope_files "$SETTINGS" "$HOOKS" | wc -l | tr -d ' ')"
if [ "${population:-0}" -gt "${gates:-0}" ]; then
  check "and the directory adds hooks the settings do not name, so both halves are read" ok
else
  check "and the directory adds hooks the settings do not name, so both halves are read" \
    "the union is $population against $gates registered, so the directory half added nothing"
fi

offenders="$(scan_gates "$SETTINGS" "$HOOKS")"
if [ -z "$offenders" ]; then
  check "no hook that can refuse reaches for a reader without naming it when it is absent" ok
else
  check "no hook that can refuse reaches for a reader without naming it when it is absent" "$(printf '%s' "$offenders" | tr '\n' ';')"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
