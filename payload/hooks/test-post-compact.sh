#!/usr/bin/env bash
# Tests for post-compact.sh, which re-injects the project's CLAUDE.md after the context is
# compacted (claude-config#124).
#
# When it works, the session keeps its project rules across a compaction. When it does not, the
# session carries on with no rules and NOTHING says so, which is the failure this repo keeps
# meeting: the reassuring half of a pair is the one that gets believed (L98). It had no test.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/post-compact.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.postcompact.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-post-compact: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

# The payload Claude Code really sends: a SessionStart whose source says a compaction is why
# (claude-config#478). The source is passed separately so a suite can drive the other sources too.
payload() { python3 -c 'import json,sys; d={"cwd":sys.argv[1],"hook_event_name":"SessionStart"}; d.update({"source":sys.argv[2]} if len(sys.argv)>2 else {}); print(json.dumps(d))' "$@"; }
context_of() { python3 -c 'import json,sys; print((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext",""))' 2>/dev/null; }
event_of() { python3 -c 'import json,sys; print((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("hookEventName",""))' 2>/dev/null; }
# The accepted shape lives in lib/hook-output.py, the same table the tree wide scan judges every
# hook against, so this suite asks the question once rather than keeping a second copy of the
# platform's answer beside it (L41, L370).
accepted_by_claude_code() { python3 "$DIR/lib/hook-output.py" --payload; }

# ---------------------------------------------------------------------------
# A project WITH rules: the rules themselves have to come through, not just a mention of them.
# ---------------------------------------------------------------------------
P1="$TMPROOT/HasRules"; mkdir -p "$P1"
printf '# Rules\n\nNEVER-PUSH-ON-FRIDAY-MARKER\n' > "$P1/CLAUDE.md"
out1="$(payload "$P1" compact | bash "$H" 2>/dev/null)"
printf '%s' "$out1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "it answers with valid JSON" ok \
  || check "it answers with valid JSON" "out=$out1"
ctx1="$(printf '%s' "$out1" | context_of)"
grep -q 'NEVER-PUSH-ON-FRIDAY-MARKER' <<< "$ctx1" \
  && check "the project's actual rules come through, not just their name" ok \
  || check "the project's actual rules come through, not just their name" "ctx=$ctx1"
grep -q 'HasRules' <<< "$ctx1" \
  && check "and it says which project they belong to" ok \
  || check "and it says which project they belong to" "ctx=$ctx1"
grep -qi 'compact' <<< "$ctx1" \
  && check "and that a compaction is why it is saying so" ok \
  || check "and that a compaction is why it is saying so" "ctx=$ctx1"

# ---------------------------------------------------------------------------
# The answer has to be one Claude Code ACCEPTS, which is a separate question from whether it holds
# the right words (claude-config#478). Until 2026-09-19 it named no event at all, so the platform
# rejected the whole payload with "Hook JSON output validation failed", the rules never reached the
# session, and every assertion above still passed: the hook's own output was never compared against
# what the platform takes (L3).
# ---------------------------------------------------------------------------
ev1="$(printf '%s' "$out1" | event_of)"
[ "$ev1" = "SessionStart" ] \
  && check "#478 the answer names the event Claude Code injects context from" ok \
  || check "#478 the answer names the event Claude Code injects context from" "hookEventName=[$ev1]"
why1="$(printf '%s' "$out1" | accepted_by_claude_code 2>&1)"; ok1=$?
[ "$ok1" -eq 0 ] \
  && check "#478 the whole payload is one Claude Code accepts" ok \
  || check "#478 the whole payload is one Claude Code accepts" "it said: [$why1]"

# ---------------------------------------------------------------------------
# A project with NO rules is a different answer, and has to say so rather than going quiet: a
# silent hook and a project with no rules look identical from the session's side (L11).
# ---------------------------------------------------------------------------
P2="$TMPROOT/NoRules"; mkdir -p "$P2"
out2="$(payload "$P2" compact | bash "$H" 2>/dev/null)"
ctx2="$(printf '%s' "$out2" | context_of)"
ev2="$(printf '%s' "$out2" | event_of)"
[ "$ev2" = "SessionStart" ] \
  && check "#478 and that answer names the event too, since a rejected one says nothing either" ok \
  || check "#478 and that answer names the event too, since a rejected one says nothing either" "hookEventName=[$ev2]"
[ -n "$ctx2" ] \
  && check "a project with no CLAUDE.md still gets an answer" ok \
  || check "a project with no CLAUDE.md still gets an answer" "it said nothing"
grep -qi 'no CLAUDE.md' <<< "$ctx2" \
  && check "and the answer says there were none to re-inject" ok \
  || check "and the answer says there were none to re-inject" "ctx=$ctx2"
[ "$ctx1" != "$ctx2" ] \
  && check "the two answers are not the same sentence" ok \
  || check "the two answers are not the same sentence" "both said: $ctx1"

# ---------------------------------------------------------------------------
# Payloads it must not act on.
# ---------------------------------------------------------------------------
out_nocwd="$(printf '{}' | bash "$H" 2>/dev/null)"; code_nocwd=$?
[ -z "$out_nocwd" ] && [ "$code_nocwd" -eq 0 ] \
  && check "a payload with no working directory says nothing and exits cleanly" ok \
  || check "a payload with no working directory says nothing and exits cleanly" "out=$out_nocwd exit=$code_nocwd"
out_junk="$(printf 'not json' | bash "$H" 2>/dev/null)"; code_junk=$?
[ -z "$out_junk" ] && [ "$code_junk" -eq 0 ] \
  && check "a payload that does not parse says nothing and exits cleanly" ok \
  || check "a payload that does not parse says nothing and exits cleanly" "out=$out_junk exit=$code_junk"

# A session that STARTED is not a session that was compacted. Claude Code loads the project rules
# itself at startup, and this hook's sentence says a compaction happened, so running it on any
# other source would restate the rules and say something untrue about why (L680).
for other in startup resume clear fork; do
  out_other="$(payload "$P1" "$other" | bash "$H" 2>/dev/null)"; code_other=$?
  [ -z "$out_other" ] && [ "$code_other" -eq 0 ] \
    && check "#478 a SessionStart whose source is $other says nothing and exits cleanly" ok \
    || check "#478 a SessionStart whose source is $other says nothing and exits cleanly" "out=$out_other exit=$code_other"
done

# ---------------------------------------------------------------------------
# The awkward inputs. A project name and a rules file are both text somebody else chose, and this
# hook pastes them into JSON, so the answer has to survive characters that would otherwise end a
# string. An answer that stops parsing is an answer nothing reads, and nothing reports that.
# ---------------------------------------------------------------------------
P3="$TMPROOT/Quote\"And'Brace{"; mkdir -p "$P3"
printf 'a rule with a "double quote" and a backslash \\ in it\n' > "$P3/CLAUDE.md"
out3="$(payload "$P3" compact | bash "$H" 2>/dev/null)"
printf '%s' "$out3" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "a project name and rules holding quotes still produce parseable JSON" ok \
  || check "a project name and rules holding quotes still produce parseable JSON" "out=$out3"
printf '%s' "$out3" | context_of | grep -q 'double quote' \
  && check "and the rules still come through intact" ok \
  || check "and the rules still come through intact" "out=$out3"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
