#!/usr/bin/env bash
# Tests for feature-discovery-nudge.sh (claude-config#124).
#
# It adds one standing instruction to each session (SessionStart, since 2026-10-15), and its whole
# design is that it does NOT try to detect a feature request: the instruction is conditional and the
# model self filters. So there is little behaviour to check and exactly one way it fails, which is by
# printing nothing, or printing something that is no longer an instruction, in every session for as
# long as nobody looks.
# Nothing would report that.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/feature-discovery-nudge.sh"
N="$DIR/tdd-nudge.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

out="$(printf '{"prompt":"add a saved views feature"}' | bash "$H" 2>/dev/null)"; code=$?
[ "$code" -eq 0 ] \
  && check "it exits cleanly" ok || check "it exits cleanly" "exit=$code"
[ -n "$out" ] \
  && check "it prints something, which is the only thing it does" ok \
  || check "it prints something, which is the only thing it does" "it printed nothing"
grep -qi 'feature-discovery' <<< "$out" \
  && check "and what it prints names the skill it is pointing at" ok \
  || check "and what it prints names the skill it is pointing at" "out=$out"
printf '%s' "$out" | grep -qi 'no-op\|no op' \
  && check "and says when it does not apply, which is what stops it firing on everything" ok \
  || check "and says when it does not apply, which is what stops it firing on everything" "out=$out"

# The point of its design: it does NOT look at the prompt. A version that started grepping for
# keywords would be a different hook, and the tell is that a prompt about nothing in particular
# gets the same text.
out_other="$(printf '{"prompt":"what time is it"}' | bash "$H" 2>/dev/null)"
[ "$out_other" = "$out" ] \
  && check "the same text goes out whatever the prompt says" ok \
  || check "the same text goes out whatever the prompt says" "it varied by prompt"
out_empty="$(printf '' | bash "$H" 2>/dev/null)"; code_empty=$?
[ "$out_empty" = "$out" ] && [ "$code_empty" -eq 0 ] \
  && check "and with no payload at all, so it cannot be broken by a payload change" ok \
  || check "and with no payload at all, so it cannot be broken by a payload change" "out=$out_empty exit=$code_empty"

# The skill it names has to exist, or the instruction sends the session after nothing (L111: a
# message telling somebody how to recover must name something that is actually there).
SKILLDIR="$DIR/../skills/feature-discovery"
[ -f "$SKILLDIR/SKILL.md" ] \
  && check "the skill it points at is really in the payload" ok \
  || check "the skill it points at is really in the payload" "no SKILL.md at $SKILLDIR"

# It is deliberately the same shape as tdd-nudge.sh. Checked because the two are meant to stay one
# pattern, and a divergence is the kind that is only noticed when one of them stops working.
if [ -f "$N" ]; then
  out_tdd="$(printf '' | bash "$N" 2>/dev/null)"
  [ -n "$out_tdd" ] && [ "$out_tdd" != "$out" ] \
    && check "its sibling nudge still works the same way and says something different" ok \
    || check "its sibling nudge still works the same way and says something different" "tdd-nudge said: [$out_tdd]"
else
  check "its sibling nudge still works the same way and says something different" "tdd-nudge.sh is gone"
fi


# ONCE PER SESSION, not on every prompt (hook trim, 2026-10-15). On UserPromptSubmit this line was
# copied into the transcript once per prompt, so a session of P prompts carried P copies, each
# re-read by every later request: 558K characters in Slate sessions, Oct 1 to 15 2026. On
# SessionStart it arrives once at the start, once after /clear and once after each compaction,
# which is when the earlier copy is gone. Read from the settings this repository installs.
# In the repository the hooks block is payload/settings.hooks.json; installed under ~/.claude it is
# the "hooks" key of settings.json, the file Claude Code actually reads. claude-sync runs these suites
# from the installed copy after every pull, where the repo's spelling does not exist, so naming it
# alone reported "registered under: nothing" on both Macs. The same two candidates, in the same
# order, as test-check-free-space.sh and test-check-gh-watch-interval.sh.
SETTINGS_FILE=""
_settings_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
for _settings_candidate in "$_settings_dir/settings.hooks.json" "$_settings_dir/settings.json"; do
  if [ -f "$_settings_candidate" ]; then SETTINGS_FILE="$_settings_candidate"; break; fi
done
# Neither being there is its own failure, not "registered under nothing" (L11).
[ -n "$SETTINGS_FILE" ] \
  && check "a settings file holding the hooks block is beside the hooks" ok \
  || check "a settings file holding the hooks block is beside the hooks" "neither settings.hooks.json nor settings.json in $_settings_dir"
# With no settings file the registration was not checked, and the line above already says why,
# so it is not reported a second time as "registered under nothing".
if [ -n "$SETTINGS_FILE" ]; then
  events="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))["hooks"]
pat = re.compile(r"/hooks/" + re.escape(sys.argv[2]) + r"(?![A-Za-z0-9_.-])")
print(" ".join(sorted({ev for ev, ms in d.items() for m in ms for h in m.get("hooks", []) if pat.search(h.get("command", ""))})))
' "$SETTINGS_FILE" "feature-discovery-nudge.sh" 2>/dev/null)"
  [ "$events" = "SessionStart" ] \
    && check "it is registered under SessionStart only" ok \
    || check "it is registered under SessionStart only" "registered under: ${events:-nothing}"
fi
# A headless run started by an app has nobody to nudge, and its prompt is a job, not a request
# to write code.
out_detached="$(printf '{}' | CLAUDE_DETACHED_RUN=1 "$H" 2>/dev/null)"
[ -z "$out_detached" ] \
  && check "it says nothing in a detached headless run" ok \
  || check "it says nothing in a detached headless run" "out=$out_detached"
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
