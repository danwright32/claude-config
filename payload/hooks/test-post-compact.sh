#!/usr/bin/env bash
# Tests for post-compact.sh, which re-injects the project's CLAUDE.md after the context is
# compacted (claude-config#124).
#
# When it works, the session keeps its project rules across a compaction. When it does not, the
# session carries on with no rules and NOTHING says so, which is the failure this repo keeps
# meeting: the reassuring half of a pair is the one that gets believed (L98). It had no test.
set -uo pipefail

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

payload() { python3 -c 'import json,sys; print(json.dumps({"cwd":sys.argv[1]}))' "$1"; }
context_of() { python3 -c 'import json,sys; print((json.load(sys.stdin).get("hookSpecificOutput") or {}).get("additionalContext",""))' 2>/dev/null; }

# ---------------------------------------------------------------------------
# A project WITH rules: the rules themselves have to come through, not just a mention of them.
# ---------------------------------------------------------------------------
P1="$TMPROOT/HasRules"; mkdir -p "$P1"
printf '# Rules\n\nNEVER-PUSH-ON-FRIDAY-MARKER\n' > "$P1/CLAUDE.md"
out1="$(payload "$P1" | bash "$H" 2>/dev/null)"
printf '%s' "$out1" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "it answers with valid JSON" ok \
  || check "it answers with valid JSON" "out=$out1"
ctx1="$(printf '%s' "$out1" | context_of)"
printf '%s' "$ctx1" | grep -q 'NEVER-PUSH-ON-FRIDAY-MARKER' \
  && check "the project's actual rules come through, not just their name" ok \
  || check "the project's actual rules come through, not just their name" "ctx=$ctx1"
printf '%s' "$ctx1" | grep -q 'HasRules' \
  && check "and it says which project they belong to" ok \
  || check "and it says which project they belong to" "ctx=$ctx1"
printf '%s' "$ctx1" | grep -qi 'compact' \
  && check "and that a compaction is why it is saying so" ok \
  || check "and that a compaction is why it is saying so" "ctx=$ctx1"

# ---------------------------------------------------------------------------
# A project with NO rules is a different answer, and has to say so rather than going quiet: a
# silent hook and a project with no rules look identical from the session's side (L11).
# ---------------------------------------------------------------------------
P2="$TMPROOT/NoRules"; mkdir -p "$P2"
out2="$(payload "$P2" | bash "$H" 2>/dev/null)"
ctx2="$(printf '%s' "$out2" | context_of)"
[ -n "$ctx2" ] \
  && check "a project with no CLAUDE.md still gets an answer" ok \
  || check "a project with no CLAUDE.md still gets an answer" "it said nothing"
printf '%s' "$ctx2" | grep -qi 'no CLAUDE.md' \
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

# ---------------------------------------------------------------------------
# The awkward inputs. A project name and a rules file are both text somebody else chose, and this
# hook pastes them into JSON, so the answer has to survive characters that would otherwise end a
# string. An answer that stops parsing is an answer nothing reads, and nothing reports that.
# ---------------------------------------------------------------------------
P3="$TMPROOT/Quote\"And'Brace{"; mkdir -p "$P3"
printf 'a rule with a "double quote" and a backslash \\ in it\n' > "$P3/CLAUDE.md"
out3="$(payload "$P3" | bash "$H" 2>/dev/null)"
printf '%s' "$out3" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null \
  && check "a project name and rules holding quotes still produce parseable JSON" ok \
  || check "a project name and rules holding quotes still produce parseable JSON" "out=$out3"
printf '%s' "$out3" | context_of | grep -q 'double quote' \
  && check "and the rules still come through intact" ok \
  || check "and the rules still come through intact" "out=$out3"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
