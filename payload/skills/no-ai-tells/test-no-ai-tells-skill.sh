#!/usr/bin/env bash
# Tests for what the no-ai-tells skill says about reading the list and writing drafts (claude-config#3060).
#
# On 2026-11-16 the skill said to fetch the Wikipedia list of AI writing signs and nothing more. The
# page is about 250,000 characters, one WebFetch reads 100,000, and the first call ended with a note
# that 151,549 characters were unread, so a run checked a draft against about 40% of the list and
# reported it clean. The unread part held the promotional vocabulary, the summary endings and the em
# dash section. The skill also said "Suggestions only" and "Never rewrite the full text", while the
# global rules and the prose hook call it to correct a draft that is then shown and saved word for
# word, so every such run went against the skill's own text.
#
# What this holds the skill to, each a fixed phrase it must carry:
#   0. a message to another Claude session is not checked, said before the first step so no page is
#      fetched for one (claude-config#3238);
#   1. it reads on with the offset each result gives, until no part is left unread;
#   2. it confirms the end of the list was reached, rather than trusting a missing note;
#   3. a partial read is never reported as clean;
#   4. on a session's own draft it writes the corrected draft in full, which is the text shown and saved;
#   5. on text Dan pastes in it suggests edits only;
#   6. it never sends, posts or saves anything itself;
#   7. the unconditional "suggestions only" lines that contradicted the callers are gone;
#   8. no em or en dash in the skill;
#   9. a reply that reports checking or work opens with the verdict in one sentence, and the recap of
#      what was checked comes out (see below);
#  10. a reply in a thread is held to four steps: cut what the thread already gave the reader, shape
#      the first line and each ask, match the writer's earlier messages, and put back any fact an ask
#      needs (see below).
# A control then removes one required phrase and confirms the check reports it, so a check that can
# never fail is caught here rather than trusted.
#
# On 2026-11-17 a run read the whole list, checked a Slack reply and passed its opening, which listed
# what the session had checked, said it all matched, and gave a deploy time and a pass count. Dan read
# that opening as AI writing. The Wikipedia list is about articles and has no sign for a reply that
# recaps the writer's own work, and the skill's own questions had none either, so nothing in the run
# could have caught it.
#
# The rule written for that covered only the text before the first ask. Measured the same day on
# five fresh runs of it: three reported that the cut had also removed a fact the reader needed, and
# nothing in the skill reached a sentence inside an item that told the reader what they had written.
# The skill checked sentence by sentence, and each such sentence reads fine alone.
#
# NO_AI_TELLS_SKILL points the suite at another copy, which is how a broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL="${NO_AI_TELLS_SKILL:-$DIR/SKILL.md}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
# ok when the text holds the words exactly, else what is missing. Matched with case, never a pipe into
# grep -q, which can stop reading early and fail the pipeline under pipefail. No ${x,,}: macOS ships
# bash 3.2, which has no case conversion.
holds() { # holds <text> <fixed words>
  case "$1" in *"$2"*) echo ok ;; *) echo "missing: $2" ;; esac
}
lacks() { # lacks <text> <fixed words>
  case "$1" in *"$2"*) echo "still says: $2" ;; *) echo ok ;; esac
}

if [ -r "$SKILL" ]; then text="$(cat "$SKILL")"; else text=""; check "the no-ai-tells skill is readable" "cannot read $SKILL"; fi

# ---- 0. a message between Claude sessions is not checked (claude-config#3238) ----
# Dan's choice on 2026-11-18 was "1.1 File: exempt them". The prompt hook sees only the words Dan
# typed, so it cannot tell a message to another session from one to a person; the session writing
# the text knows where it goes, so the exemption is in the skill. It has to come BEFORE the first
# step, or the session reads the 250,000 character page before learning it need not have.
check "the skill exempts a message to another Claude session" "$(holds "$text" "A message to another Claude session is not checked")"
check "the exemption quotes Dan's choice with its date" "$(holds "$text" '2026-11-18: "1.1 File: exempt them"')"
exempt_line="$(awk 'index($0, "A message to another Claude session is not checked") { print NR; exit }' "$SKILL" 2>/dev/null)"
first_step_line="$(awk 'index($0, "## MANDATORY FIRST STEP") { print NR; exit }' "$SKILL" 2>/dev/null)"
[ -n "$exempt_line" ] && [ -n "$first_step_line" ] && [ "$exempt_line" -lt "$first_step_line" ] \
  && check "the exemption comes before the first step, so no page is fetched for it" ok \
  || check "the exemption comes before the first step, so no page is fetched for it" "exemption at line ${exempt_line:-none}, first step at line ${first_step_line:-none}"

# ---- 1. read on with the offset until nothing is left unread ----
check "the skill says one fetch is never the whole list" "$(holds "$text" "one call is never the whole list")"
check "the skill reads on with the offset each result gives" "$(holds "$text" 'with the `offset` that result gives')"
check "the skill repeats until no part is left unread" "$(holds "$text" "Repeat until a result has no such note")"

# ---- 2. the end of the list is confirmed, not inferred from a missing note ----
check "the skill confirms the read reached the page's See also heading" "$(holds "$text" 'reaches the page'"'"'s "See also" heading')"
check "the skill does not trust a missing note alone" "$(holds "$text" "rather than trusting the absence of a note")"

# ---- 3. a partial read is never reported clean ----
check "a partial read is never reported as clean" "$(holds "$text" "never report the text clean")"
check "a partial read is named as partial" "$(holds "$text" "say the check was partial")"

# ---- 4. a session's own draft comes back corrected, in full ----
check "the skill has a mode for a session's own draft" "$(holds "$text" "**A session's own draft.**")"
check "on its own draft the session gets the corrected draft in full" "$(holds "$text" "write the corrected draft in full")"
check "the corrected draft is the text shown and saved as the Slack draft" "$(holds "$text" "exactly the text saved as the draft")"
check "the skill runs before the text is shown or offered in a picker" "$(holds "$text" "before the text is shown or offered in a picker")"

# ---- 5. text Dan pastes in gets suggestions only ----
check "the skill has a mode for text Dan pastes in" "$(holds "$text" "**Text Dan pastes in.**")"
check "pasted text gets suggestions, never a rewrite" "$(holds "$text" "Text Dan pastes in is never rewritten in full")"

# ---- 6. the skill never sends, posts or saves ----
check "the skill never sends, posts or saves anything itself" "$(holds "$text" "never sends, posts or saves anything")"

# ---- 7. the lines that contradicted the callers are gone ----
check "the unconditional 'never rewrite the full text' rule is gone" "$(lacks "$text" "**Never rewrite the full text.**")"
check "the unconditional 'suggestions only' line is gone" "$(lacks "$text" "Do **not** output a rewritten version of the text. Suggestions only.")"
check "the description no longer limits the skill to suggestions" "$(lacks "$text" "description: Reviews writing and suggests specific edits")"

# ---- 8. the style rule: no em or en dash in the skill ----
dashes="$(grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$SKILL" 2>/dev/null)"
check "the no-ai-tells skill holds no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

# ---- 9. a reply that reports checking or work opens with the verdict, not a recap ----
check "the question list asks whether the opening recaps the writer's own work" "$(holds "$text" "Does the opening recap the writer's own work")"
check "the skill has a section for a reply that reports checking or work" "$(holds "$text" "## A reply that reports checking or work")"
check "the opening is the verdict in one sentence" "$(holds "$text" "The verdict, in one sentence")"
check "the rule covers everything before the first ask" "$(holds "$text" "Everything before the first thing asked of the reader")"
check "the recap is cut, never moved further down" "$(holds "$text" "cut from the message, never moved further down")"
check "pass counts are named as part of the recap" "$(holds "$text" "pass counts")"
check "the skill says why the Wikipedia list cannot catch it" "$(holds "$text" "has no sign for a reply that recaps the writer's own work")"

# ---- 10. a reply in a thread: cut, shape, match, put back ----
check "the question list sends a reply to the thread steps" "$(holds "$text" "Is the draft a reply in a thread")"
check "the skill has a section for a reply in a thread" "$(holds "$text" "## A reply in a thread")"
check "the thread is read before the steps run" "$(holds "$text" "read the thread first")"
check "each sentence gives the reader something the thread has not" "$(holds "$text" "something they do not have from the thread")"
check "the reasoning kept is what would change the reader's answer" "$(holds "$text" "would change whether the reader agrees or what they do")"
check "the first line stands alone" "$(holds "$text" "The first line stands alone")"
check "each item opens with what is asked" "$(holds "$text" "opens with what is asked")"
check "the draft matches the writer's earlier messages" "$(holds "$text" "Match the writer's earlier messages")"
check "earlier messages decide only what the list and the steps leave open" "$(holds "$text" "they decide what the sign list and these steps leave open")"
check "a sign stays a finding when the earlier messages show it too" "$(holds "$text" "is still a finding when their earlier messages show it too")"
check "the mention of the person addressed stays" "$(holds "$text" "A mention of the person the draft addresses stays")"
check "a fact an ask needs is put back" "$(holds "$text" "Put back any fact an ask needs")"
check "the fact goes back beside the ask it serves" "$(holds "$text" "beside that ask")"
check "the change list names each fact put back and each left out" "$(holds "$text" "name each fact put back and each left out")"
check "a reply that asks nothing has an anchor" "$(holds "$text" "When the reply asks nothing")"
check "the sources of the thread steps are credited" "$(holds "$text" "blader/humanizer")"

# ---- control: the checks above can fail ----
no_put_back="$(grep -v -F 'Put back any fact an ask needs' <<< "$text")"
check "control: a copy without the put back step is caught" \
  "$([ "$(holds "$no_put_back" "Put back any fact an ask needs")" != ok ] && echo ok || echo "the check passed a copy that lacks the phrase")"
no_recap_rule="$(grep -v -F 'The verdict, in one sentence' <<< "$text")"
check "control: a copy without the verdict rule is caught" \
  "$([ "$(holds "$no_recap_rule" "The verdict, in one sentence")" != ok ] && echo ok || echo "the check passed a copy that lacks the phrase")"
# The same check run on the skill with its offset line removed must report it missing. Without this a
# helper that always printed ok would pass every check above on any text at all.
broken="$(grep -v -F 'offset' <<< "$text")"
check "control: a copy without the offset instruction is caught" \
  "$([ "$(holds "$broken" 'with the `offset` that result gives')" != ok ] && echo ok || echo "the check passed a copy that lacks the phrase")"
check "control: a copy that still says suggestions only is caught" \
  "$([ "$(lacks "Do **not** output a rewritten version of the text. Suggestions only." "Do **not** output a rewritten version of the text. Suggestions only.")" != ok ] && echo ok || echo "the check passed a copy that holds the phrase")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
