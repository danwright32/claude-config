#!/usr/bin/env bash
#
# test-gate-payload-reader.sh: a scan over the gates that can refuse a tool call, so the next one
# written cannot repeat claude-config#480 (L490, L613, L621).
#
# The fault, three times over: a gate parsed its hook payload with jq or with python3 and never
# asked whether that tool was installed. On a machine without it the payload came back EMPTY, and
# every question a gate asks of an empty payload answers that there is nothing here to refuse, so
# the gate exited 0 on exactly the command it exists to stop, with nothing said. block-red-merge.sh
# allowed every merge, check-add-scope.sh allowed every unscoped add, and payload-write-gate.sh
# allowed every write under payload/, each of them looking exactly like a clean run (L42, L98).
#
# The population is DERIVED, never a list kept here, because a list checks only what somebody
# remembered to add to it (L96): the hooks registered on PreToolUse in payload/settings.hooks.json
# are the ones that can refuse a tool call before it runs, and this asks each of them.
#
# A hook is IN SCOPE when it does both of these:
#   it can refuse          (it builds a deny decision, or it exits 2)
#   it parses the payload itself, rather than through the shared reader ps_parse_payload, which
#                          takes jq OR python3 and reports when it could read neither
#
# and it satisfies this scan by NAMING the reader when it is absent, in one of the two shapes this
# repo already speaks in:
#   ps_reader_missing / mt_reader_missing   it refuses, saying which tool is missing, and the check
#                                             sits ABOVE the parse it protects
#   a "DID NOT RUN" notice                  it stands down loudly, saying so on stderr. This one
#                                             counts wherever it sits, because it is written to
#                                             handle the parse's OWN failure and so comes after it
#
# The ORDER is half the rule, not decoration. require-changelog-tag.sh carried a `command -v jq`
# check while being broken by exactly this defect, because the check sat BELOW the parse it was
# meant to protect and the gate had already exited on the empty command by the time anything
# reached it. A check present somewhere in a file says nothing about the region it was meant to
# guard (L135, L667). A bare `command -v jq` is not accepted at all, for the same reason plus one
# more: only the two shapes above carry the sentence that names the reader to the person (L400).
#
# What this scan proves is the SHAPE, that the question is asked at all. Whether each gate refuses
# in the right direction is proved by its own suite, with the real hook driven under a PATH holding
# no reader.
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

# The hooks a settings file registers on PreToolUse, as basenames, one per line. Read with python3,
# which this suite may use freely: it is asking about a repository, not standing in for a machine
# with no interpreter.
registered_pretooluse() {  # $1 = a settings json file
  SETTINGS="$1" python3 -c '
import json, os, sys
try:
    with open(os.environ["SETTINGS"]) as fh:
        d = json.load(fh)
except Exception as exc:
    sys.stderr.write("could not read the settings file: %s\n" % exc)
    sys.exit(1)
seen = []
for matcher in (d.get("hooks") or {}).get("PreToolUse") or []:
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

# One offender per line: "<hook>: <what it is missing>". Nothing on stdout is a clean scan.
scan_gates() {  # $1 = settings file, $2 = hooks directory
  local name file parse_at check_at
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    file="$2/$name"
    # A hook the settings file names and the directory does not hold is a different fault, and
    # test-hook-coverage.sh is where it is reported. Nothing here can read a file that is not there.
    [ -f "$file" ] || continue

    # Can it refuse a tool call? A hook that can only ever say something is an advisory one, and
    # an advisory that goes quiet is a different and smaller fault than a gate that opens.
    grep -Eq '(permissionDecision|exit 2)' "$file" || continue

    # Does it parse the payload ITSELF, the hook's own stdin piped straight into a parser? A read
    # through ps_parse_payload does not match, which is the point of having it.
    parse_at="$(first_line "$file" '"[$](payload|input)"[[:space:]]*[|][[:space:]]*(jq|python3)')"
    [ -n "$parse_at" ] || continue

    # A loud stand down satisfies it wherever it sits: a DID NOT RUN notice is written to handle
    # the parse's OWN failure, so it necessarily comes after it, and it names the reader either way.
    grep -q 'DID NOT RUN' "$file" && continue

    # Otherwise the question has to be asked BEFORE the answer is used. Asked anywhere in the file
    # is not enough: require-changelog-tag.sh carried a jq check BELOW the jq parse it was meant to
    # protect, and the gate exited on the empty command long before reaching it (L135, L667).
    check_at="$(first_line "$file" '(ps_reader_missing|mt_reader_missing)')"
    if [ -z "$check_at" ]; then
      printf '%s: parses the hook payload itself and can refuse, but never asks whether the reader is installed\n' "$name"
    elif [ "$check_at" -gt "$parse_at" ]; then
      printf '%s: parses the hook payload at line %s, above the reader check at line %s, so the gate has already answered by the time the check is reached\n' \
        "$name" "$parse_at" "$check_at"
    fi
  done < <(registered_pretooluse "$1")
}

echo "gate payload reader: the scan itself"

# The scan is seen to FIRE before it is believed about anything (L1). A fixture repository with one
# gate of each kind, so a clean answer over the real tree further down means the scan looked.
FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/gate-payload-reader.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"' EXIT
mkdir -p "$FIX/hooks"
cat > "$FIX/settings.json" <<'JSON'
{"hooks": {"PreToolUse": [
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/silent-gate.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/refusing-gate.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/saying-gate.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/shared-reader-gate.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/late-check-gate.sh"}]},
  {"matcher": "Bash", "hooks": [{"type": "command", "command": "__CLAUDE_HOME__/hooks/advisory.sh"}]}
]}}
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
# Parses the payload itself and can only ever say something. Not a gate, so not in scope.
cat > "$FIX/hooks/advisory.sh" <<'SH'
payload="$(cat)"
cmd="$(printf '%s' "$payload" | jq -r '.tool_input.command // ""')"
case "$cmd" in *danger*) echo "you might want to look at that" >&2 ;; esac
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
# And each way of satisfying it clears, or the scan is one that fails on everything and proves
# nothing by firing (L159).
for cleared in refusing-gate.sh saying-gate.sh shared-reader-gate.sh advisory.sh; do
  case "$found" in
    *"$cleared"*) check "$cleared is not reported" "the scan reported it too" ;;
    *) check "$cleared is not reported" ok ;;
  esac
done

echo "gate payload reader: every PreToolUse gate in this repo"

SETTINGS="${GATE_READER_SETTINGS:-$DIR/../settings.hooks.json}"
HOOKS="${GATE_READER_HOOKS:-$DIR}"
if [ ! -f "$SETTINGS" ]; then
  echo "test-gate-payload-reader: there is no settings file at $SETTINGS, so no gate could be enumerated." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the settings file that registers the hooks, and there is none at $SETTINGS"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# The population is worth asserting on its own: a settings file this could not read would answer
# "no gates" and read exactly like a clean scan (L98).
gates="$(registered_pretooluse "$SETTINGS" | wc -l | tr -d ' ')"
if [ "${gates:-0}" -ge 5 ]; then
  check "the settings file really names a set of PreToolUse hooks" ok
else
  check "the settings file really names a set of PreToolUse hooks" "it named $gates, so this scan read almost nothing"
fi

offenders="$(scan_gates "$SETTINGS" "$HOOKS")"
if [ -z "$offenders" ]; then
  check "no PreToolUse gate parses its payload without naming the reader" ok
else
  check "no PreToolUse gate parses its payload without naming the reader" "$(printf '%s' "$offenders" | tr '\n' ';')"
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
