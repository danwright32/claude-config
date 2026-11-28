#!/usr/bin/env bash
# Tests for the rule "One unchanged resend after no verdict" (claude-config#3224).
#
# Overnight sessions kept stopping on refusals in which Claude Code's auto mode safety check had
# given no verdict: it could not review the call, which is not a judgement that the call is unsafe.
# Measured on 2026-11-19 from the sleep notes of 23 nights: 1,199 such refusals, and on the one night
# with resends recorded 259 of 301 were sent again unchanged and ran, half within 6 seconds. Dan
# decided that day (his picker answer: "One unchanged resend (Recommended)") that a session may send
# the identical call once more, that a second refusal stops it and is recorded for him, and that a
# refusal that IS a verdict stays final exactly as before.
#
# claude-config#3822 adds two refusals that mean the same thing, a guard that could not review the
# call. Both are worded by Claude Code, and this repository only quotes them: a PreToolUse hook
# stopped at its registered timeout ("timed out; blocking because onFailure is"), and one mod's
# call to another mod left unanswered for 10 seconds ("did not answer within 10000ms"), which the
# refusing mod carries inside its own sentence. Counted on 2026-11-27 over every session record
# the personal MacBook held (32 days): 235 of the first and 31 of the second, 111 and 17 of them on
# 2026-11-26, when that Mac ran at a load of 100 to 350. Dan decided on 2026-11-26 (his picker
# answer: "2.2 Timed out gets one resend") that they get the same one unchanged resend. The words
# are narrow on purpose. This repository prints look-alikes of three kinds: a dialog Dan left
# unanswered ("Dan did not answer"), a merge gate that could not read GitHub ("GitHub did not answer
# within this hook's read budget"), and a guard out of time in its OWN words, which the rule does
# not cover (the design round guard's "could not check this call because it timed out", whose own
# sentence ends "This is not a refusal: try the same call again"). Section 2 holds the rule to
# quoting nothing found in those, and to quoting exactly the wordings this suite knows.
#
# The rule has ONE home (L83): one bullet of the global CLAUDE.md, the only rule file every kind of
# session loads (a main session, an overnight worker, a headless run and a dispatched agent alike).
# Everything else that says a refusal by the check is final points at that bullet by name, because
# two copies of a rule drift (L370) and a copy with no exception contradicts it.
#
# What this holds the files to:
#   1. the home exists exactly once and states all four parts: what no verdict looks like, in the
#      words a session is shown; the one identical resend; what a second refusal means and where it
#      is recorded; and that every other refusal stays final. It carries Dan's decision and date.
#      The four sentences that decide which refusals get a resend and how many sends there are
#      are held whole, since a phrase check passes a sentence that keeps the phrase and turns its
#      meaning round.
#   2. the words the home quotes are words Claude Code really writes, held against the refusal a
#      session received on 2026-11-19 (L48), and the rule asks nothing that message forbids. The
#      words for a hook out of time and an unanswered guard are held against refusals recorded on
#      2026-11-26, nothing the rule quotes is found in a look-alike this repository prints, and
#      the rule quotes exactly the wordings this suite knows, so a new one cannot be added unseen.
#   3. the rules every dispatched agent reads point at the home and keep their own rule: the
#      exception they add names the home and the issue, names the home's three refusals and no
#      other, and its own sentence on a second refusal sends it under item 6 of the report.
#   4. no other document states the absolute form bare. A scan by spelling (L564): it finds a line
#      that puts the check beside "is final" or "never retried". Such a line passes when it carries
#      the exception itself (it says "no verdict") or its file names the home.
#   5. the sleep rule an overnight worker is told on every prompt (WORKER_NOTE in the scope modes
#      mod's register.ts) is held by itself, on its own line: the sentence that calls a refusal
#      final names the rule, its home and the words no verdict. The scan alone would pass that file
#      on one pointer anywhere in it.
#
# NO_VERDICT_CLAUDE_MD and NO_VERDICT_AGENT_RULES point the suite at other copies, which is how a
# broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout, found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663).
# Empty for an installed copy, and then the scan of the payload says it was not measured.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
PAYLOAD=""
[ -n "$REPO" ] && PAYLOAD="$REPO/payload"
CLAUDE_MD="${NO_VERDICT_CLAUDE_MD:-$DIR/../CLAUDE.md}"
RULES="${NO_VERDICT_AGENT_RULES:-$DIR/../skills/orchestrate/agent-rules.md}"

# The home's name, the words every pointer quotes. Renaming it means changing every pointer, which
# checks 3 and 4 then enforce.
RULE_NAME="One unchanged resend after no verdict"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# ---- 1. the home exists once and says the whole rule ----
homes="$(grep -c -F -- "**$RULE_NAME**" "$CLAUDE_MD" 2>/dev/null)"
check "the global CLAUDE.md holds the rule exactly once" \
  "$([ "$homes" = "1" ] && echo ok || echo "found ${homes:-0} times in $CLAUDE_MD")"
# The rule is one bullet, so each part is looked for on that line and nowhere else: a phrase that
# sits in some other rule of the file must not pass for this one.
home_line="$(grep -m 1 -F -- "**$RULE_NAME**" "$CLAUDE_MD" 2>/dev/null)"
says() { # says <description> <fixed text>
  check "the rule $1" "$(grep -q -F -- "$2" <<< "$home_line" && echo ok || echo "no '$2' in the rule")"
}
# Part one: what no verdict looks like, quoted from the refusal a session is shown.
MARK_ONE='"gave no verdict"'
MARK_TWO='"This is not a judgment that the action is unsafe"'
says "quotes the words that mark a refusal with no verdict" "$MARK_ONE"
says "quotes the refusal saying it is not a judgement of safety" "$MARK_TWO"
says "names auto mode's safety check as the one whose refusal this is" "auto mode's safety check"
# The two refusals of a guard out of time (claude-config#3822), each by the words Claude Code
# writes for it. The first stops short of the setting's value, which Claude Code prints inside
# quotation marks of its own.
MARK_TIMED='"timed out; blocking because onFailure is"'
MARK_UNANSWERED='"did not answer within 10000ms"'
says "quotes the words that mark a hook stopped at its timeout" "$MARK_TIMED"
says "quotes the words that mark a guard another mod did not answer" "$MARK_UNANSWERED"
# Part two: the identical call, once.
says "allows the call once more" 'once more'
says "requires the call unchanged" 'exactly as it was'
says "sends it alone, where the check can review it" 'response of its own'
# Part three: the second refusal.
says "covers the second refusal" 'refused again'
says "forbids a third send" 'never a third send'
says "forbids another way to the same end after the second refusal" 'never another way'
says "records the second refusal where the end of turn review finds it" 'bash ~/.claude/hooks/lib/issue-spool.sh note . "'
# Part four: every other refusal.
says "says a refusal without those words is a verdict" 'is a verdict'
says "keeps a verdict final" 'stays final'
says "keeps a verdict from being retried" 'never retried'
says "keeps a verdict from being done another way" 'never done another way'
says "keeps a verdict from being done by another agent or the orchestrator" 'another agent or the orchestrator'
# A hook's or a guard's refusal in any other words is outside the rule (claude-config#3822).
says "gives a hook's or a guard's refusal in other words no resend" 'this rule gives it no resend'
# Dan's decision, quoted with its date and issue, the way the neighbouring rules carry his.
says "carries the date of Dan's decision" '2026-11-19'
says "carries the issue" 'claude-config#3224'
says "quotes Dan's answer" '"One unchanged resend"'
says "carries the date of Dan's decision on a guard out of time" '2026-11-26'
says "carries the issue of that decision" 'claude-config#3822'
says "quotes Dan's answer on a guard out of time" '"2.2 Timed out gets one resend"'
says "declares itself the one home" 'one home'
# The four sentences that decide WHICH refusals get a resend and HOW MANY sends there are, each held
# whole, from the full stop before its first word to its own full stop. A phrase check passes a
# sentence that keeps the phrase and turns its meaning round: on 2026-11-27 the review of pull
# request 3851 changed one sentence at a time on a scratch copy (a guard's time limit no longer said
# to fall before the call ran, "send it a second and a third time, then stop there", "is not its
# verdict; do not think this rule gives it no resend") and every phrase check above still passed.
# The wording is Dan's, so a change to one of these sentences changes its copy here in the same
# commit, on purpose. What this cannot hold: a whole new sentence added beside them.
whole() { # whole <line> <sentence>   ok when the line holds the sentence between two sentence ends
  case " $1 " in
    *". $2 "*) echo ok ;;
    *) echo "the rule does not hold this sentence whole: $2" ;;
  esac
}
SENTENCE_WHICH="The same is true of two refusals Claude Code words for a guard that ran out of time before the call could run: a hook stopped at its timeout ($MARK_TIMED) and a mod's guard that another mod left unanswered ($MARK_UNANSWERED)."
SENTENCE_SEND='Send that call once more, alone in a response of its own, exactly as it was, or with exactly the input the refusal quotes when a hook had rewritten the call.'
SENTENCE_AGAIN='If it is refused again, stop there: never a third send and never another way to the same end.'
SENTENCE_OTHER="A hook's or a guard's refusal in any other words is its verdict, and this rule gives it no resend."
check "the rule names the two refusals of a guard out of time, and only those, as falling before the call could run" \
  "$(whole "$home_line" "$SENTENCE_WHICH")"
check "the rule's sentence on the one resend is whole" "$(whole "$home_line" "$SENTENCE_SEND")"
check "the rule's sentence on a second refusal stops there, with no further send in it" \
  "$(whole "$home_line" "$SENTENCE_AGAIN")"
check "the rule's sentence on a hook's or a guard's refusal in other words is whole, not turned round" \
  "$(whole "$home_line" "$SENTENCE_OTHER")"
# Seen to fail (L1) on the changed sentences of that review, and to pass the sentence as it stands.
check "the whole sentence check fails a guard's time limit not said to fall before the call could run" \
  "$([ "$(whole "It is safe. The same is true of two refusals Claude Code words: a hook stopped at its timeout ($MARK_TIMED) and a mod's guard that another mod left unanswered ($MARK_UNANSWERED). Send it." "$SENTENCE_WHICH")" != ok ] && echo ok || echo "a sentence without 'before the call could run' passed")"
check "the whole sentence check fails a wording added after the two marks, quoted or not" \
  "$([ "$(whole "It is safe. ${SENTENCE_WHICH%.} or any refusal that says it ran out of time. Send it." "$SENTENCE_WHICH")" != ok ] && echo ok || echo "a sentence with a third wording after the two marks passed")"
check "the whole sentence check fails a second and a third send" \
  "$([ "$(whole 'Sent. If it is refused again, send it a second and a third time, then stop there: never a third send and never another way to the same end. Record it.' "$SENTENCE_AGAIN")" != ok ] && echo ok || echo "a sentence allowing a second and a third send passed")"
check "the whole sentence check fails the sentence turned round with its words kept" \
  "$([ "$(whole "Final. A hook's or a guard's refusal in any other words is not its verdict; do not think this rule gives it no resend. This is the home." "$SENTENCE_OTHER")" != ok ] && echo ok || echo "a negated sentence that keeps the checked words passed")"
check "the whole sentence check passes the sentence as it stands, last on the line too" \
  "$([ "$(whole "Sent. $SENTENCE_AGAIN" "$SENTENCE_AGAIN")" = ok ] && echo ok || echo "the sentence as it stands was failed")"

# ---- 2. the quoted words are the ones Claude Code writes ----
# The refusal a session received on 2026-11-19 on Claude Code 2.1.328, twice in one hour, for a Bash
# call sent beside another call in one response. Copied whole and unshaped (L48). The measurement
# on #3224 quotes the same sentences from an overnight transcript of 2026-11-18.
REAL_REFUSAL="The server-side auto mode classifier gave no verdict for Bash: another call in this response was changed after auto mode reviewed it, or could not be confirmed unchanged, so this call's review no longer applies. This is not a judgment that the action is unsafe. Issue the Bash call again in a response of its own, exactly as this conversation records it, after you have seen the results of the other calls. If it is denied again, do not retry; continue with other tasks and tell the user that auto mode could not evaluate it. Note: reading files, searching code, and other read-only operations do not require the classifier and can still be used."
# A second shape of it, received the same day for a Bash call whose input a hook had rewritten (the
# rtk rewrite puts rtk in front of a command) after the check reviewed it. Here Claude Code asks for
# the call with the input it quotes, not as it was first sent. Copied whole but for the quoted
# input, which held a path on the Mac it was received on and is left out where the mark stands.
REAL_REFUSAL_REWRITTEN="The server-side auto mode classifier gave no verdict for Bash: a hook changed this call's input after auto mode reviewed it, so the review does not cover what would run. This is not a judgment that the action is unsafe. The hook produced this input: [the input, left out]. In your next response, issue the Bash call once more with exactly that input so auto mode reviews it. Put nothing else in that response but other calls whose denial quoted an input like this one. If it is denied again, do not retry; continue with other tasks and tell the user that auto mode could not check this Bash call because a hook or plugin changes it, and that they can turn that hook or plugin off (or ask their administrator to) or switch out of auto mode to approve it themselves. Note: reading files, searching code, and other read-only operations do not require the classifier and can still be used."
in_text() { # in_text <description> <quoted text> <refusal>   the text between the quotes is in it
  local bare="${2#\"}"; bare="${bare%\"}"
  check "$1" "$(grep -q -F -- "$bare" <<< "$3" && echo ok || echo "the real refusal does not say: $bare")"
}
in_real() { in_text "$1" "$2" "$REAL_REFUSAL"; }
in_rewritten() { in_text "$1" "$2" "$REAL_REFUSAL_REWRITTEN"; }
in_real "the first quoted mark is in the refusal Claude Code writes" "$MARK_ONE"
in_real "the second quoted mark is in the refusal Claude Code writes" "$MARK_TWO"
in_rewritten "the first quoted mark is in the refusal of a call a hook rewrote" "$MARK_ONE"
in_rewritten "the second quoted mark is in the refusal of a call a hook rewrote" "$MARK_TWO"
# The rule and the message agree: the message asks for the call again in a response of its own and
# forbids a retry after a second denial, so a rule allowing two resends would contradict it.
in_real "Claude Code's message asks for the call again in a response of its own" '"again in a response of its own"'
in_real "Claude Code's message forbids a retry after a second denial" '"If it is denied again, do not retry"'
in_rewritten "Claude Code's message for a rewritten call forbids a retry after a second denial" '"If it is denied again, do not retry"'
# For a call a hook rewrote the message asks for the input it quotes, so a rule that allowed only
# the call as first sent would forbid what the message asks for.
in_rewritten "Claude Code's message for a rewritten call asks for the input it quotes" '"once more with exactly that input"'
says "allows the input the refusal quotes, where a hook rewrote the call" 'the input the refusal quotes'
check "the rule allows no second resend" \
  "$(grep -q -i -E 'twice more|two more|a second resend|up to (two|three|2|3)' <<< "$home_line" && echo "the rule allows more than one resend" || echo ok)"

# The two refusals of a guard out of time (claude-config#3822), each copied whole and unshaped from
# the record of a session on the personal MacBook on 2026-11-26, Claude Code 2.1.332 (L48). Both are
# worded by Claude Code and by nothing in this repository. The first is all a session is shown when
# Claude Code stops a PreToolUse hook at its registered timeout: the hook's own output is discarded
# (scanners-before-push.sh, "THE HARD STOP OVER THE WHOLE RUN"). In the second, the words inside the
# brackets are Claude Code failing the collision guard's call to another mod after 10 seconds
# (docs/mods-design.md, standing rule 4), and the sentence around them is the guard's own
# (mods/collision-guard/hooks/register.ts).
REAL_TIMED_OUT='PreToolUse:Bash hook error: [command hook 48]: timed out; blocking because onFailure is "block"'
REAL_UNANSWERED='Blocked: the collision guard could not check this call against the other sessions ($.sessions.list: session-registry did not answer within 10000ms), so it did not run. Try it again; if it fails the same way, tell Dan.'
in_text "the mark of a hook stopped at its timeout is in the refusal Claude Code writes" "$MARK_TIMED" "$REAL_TIMED_OUT"
in_text "the mark of an unanswered guard is in the refusal a session is shown" "$MARK_UNANSWERED" "$REAL_UNANSWERED"

# The marks are narrow on purpose. This repository's own guards print look-alike words when THEY
# refuse, and three are read here. Two are a question Dan left unanswered and a gate that could not
# read GitHub: a resend after "Dan did not answer" would put the same dialog in front of him again.
# The third is a guard out of time in its OWN words (the design round guard's, whose sentence ends
# "This is not a refusal: try the same call again"). It is neither a verdict nor a question for Dan.
# The rule covers only the two wordings Claude Code writes, so it quotes nothing from that one
# either, and whether such a refusal should get the resend is Dan's to decide (asked on pull
# request 3851), not this suite's. So nothing the rule quotes may be found in any of the three,
# which is what fails if a mark is ever shortened to "did not answer" or "timed out".
quotations() { # quotations <line>   prints each text the line holds between two double quotes
  local rest="$1" inside
  while [[ "$rest" == *'"'*'"'* ]]; do
    rest="${rest#*\"}"; inside="${rest%%\"*}"; rest="${rest#*\"}"
    [ -n "$inside" ] && printf '%s\n' "$inside"
  done
}
quoted_in() { # quoted_in <rule line> <refusal>   prints the first quotation of the rule found in the refusal
  local quoted q
  quoted="$(quotations "$1")"
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    if grep -q -F -- "$q" <<< "$2"; then printf '%s\n' "$q"; return 0; fi
  done <<QUOTED
$quoted
QUOTED
  return 0
}
# Each look-alike is read from the code that prints it, never typed here (L48), and a look-alike
# that is no longer there fails by name, where an empty one would pass by matching nothing (L100).
lookalike() { # lookalike <description> <fixed text of it> <file that prints it>
  local line hit
  line="$(grep -m 1 -F -- "$2" "$3" 2>/dev/null)"
  check "the look-alike refusal $1 is where this suite reads it" \
    "$([ -n "$line" ] && echo ok || echo "no '$2' in $3, so the look-alike was not read")"
  hit="$(quoted_in "$home_line" "$line")"
  check "the rule quotes nothing found in the look-alike refusal $1" \
    "$([ -z "$hit" ] && echo ok || echo "the rule's \"$hit\" is also in a refusal the rule does not cover: $2")"
}
lookalike "of a dialog Dan did not answer" 'Dan did not answer: the dialog closed by itself' "$DIR/../mods/area-check/hooks/register.ts"
lookalike "of a merge gate that could not read GitHub" "GitHub did not answer within this hook's read budget" "$DIR/check-closing-merge.sh"
lookalike "of the design round guard's own words for a check out of time" 'could not check this call because it timed out' "$DIR/../mods/design-round-guard/hooks/rules.ts"
# Seen to fail (L1): a rule quoting the bare words is caught, and the narrow words are passed.
DIALOG='Dan did not answer: the dialog closed by itself while he was away, so nothing is recorded.'
check "the look-alike check catches a rule that quotes the bare words did not answer" \
  "$([ "$(quoted_in 'A guard that "did not answer" gets one resend.' "$DIALOG")" = 'did not answer' ] && echo ok || echo "a rule quoting the bare words passed")"
check "the look-alike check catches a rule that quotes the bare words timed out" \
  "$([ "$(quoted_in 'A hook that "timed out" gets one resend.' 'could not check this call because it timed out (why)')" = 'timed out' ] && echo ok || echo "a rule quoting the bare words passed")"
check "the look-alike check passes a rule that quotes the narrow words" \
  "$([ -z "$(quoted_in 'A guard that "did not answer within 10000ms" gets one resend.' "$DIALOG")" ] && echo ok || echo "the narrow words were reported")"
check "the look-alike check reads every quotation on the line, not only the first" \
  "$([ "$(quotations 'One "first mark" and "second mark" here.' | tr '\n' '|')" = 'first mark|second mark|' ] && echo ok || echo "the quotations were read as: $(quotations 'One "first mark" and "second mark" here.' | tr '\n' '|')")"

# The rule quotes exactly the wordings this suite knows, in the order it writes them, and no other.
# The checks above ask that each known wording is PRESENT and that none is found in three chosen
# look-alikes, which a fourth quoted wording passes: on 2026-11-27 the review of pull request 3851
# added or says "it ran out of time" to a scratch copy, the words the mod kit puts in both of its
# refusals, the one for a mod's own tool included, where part of the call may already have run
# (mods/mod-kit/hooks/hold.ts), and all 76 checks passed. So the whole list is held: Dan's two
# answers, the two marks of a refusal with no verdict, the two of a guard out of time, the two
# placeholders of the recording command, and the first mark again where the rule says which
# refusal by the check is a verdict. A new wording, a dropped one or a reworded one fails here,
# and widening the rule then means changing this list in the same commit, on purpose.
unquoted() { local bare="${1#\"}"; printf '%s\n' "${bare%\"}"; }
KNOWN_QUOTATIONS="$(
  printf '%s\n' 'One unchanged resend' '2.2 Timed out gets one resend'
  unquoted "$MARK_ONE"; unquoted "$MARK_TWO"; unquoted "$MARK_TIMED"; unquoted "$MARK_UNANSWERED"
  printf '%s\n' "<what was refused, and the refusal's words>" '<who is reporting>'
  unquoted "$MARK_ONE"
)"
exact_quotations() { # exact_quotations <rule line> <known list>   prints ok, or what differs
  local found extra="" missing="" q
  found="$(quotations "$1")"
  if [ "$found" = "$2" ]; then echo ok; return 0; fi
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    grep -q -x -F -- "$q" <<< "$2" || extra="$extra \"$q\""
  done <<FOUND
$found
FOUND
  while IFS= read -r q; do
    [ -n "$q" ] || continue
    grep -q -x -F -- "$q" <<< "$found" || missing="$missing \"$q\""
  done <<KNOWN
$2
KNOWN
  if [ -n "$extra" ]; then echo "the rule quotes a wording this suite does not know:$extra"
  elif [ -n "$missing" ]; then echo "the rule no longer quotes:$missing"
  else echo "the rule quotes the known wordings in another order or number: $(tr '\n' '|' <<< "$found")"
  fi
}
check "the rule quotes exactly the known wordings and no other" "$(exact_quotations "$home_line" "$KNOWN_QUOTATIONS")"
# Seen to fail (L1): a fourth wording, a missing one and a repeated one, and the known list passes.
QUOTES_KNOWN='first mark
second mark'
check "the exact wordings check names a wording that was added" \
  "$([ "$(exact_quotations 'One "first mark" and "second mark" or says "it ran out of time".' "$QUOTES_KNOWN")" = 'the rule quotes a wording this suite does not know: "it ran out of time"' ] && echo ok || echo "a line with a third quotation gave: $(exact_quotations 'One "first mark" and "second mark" or says "it ran out of time".' "$QUOTES_KNOWN")")"
check "the exact wordings check names a wording that was dropped" \
  "$([ "$(exact_quotations 'Only "first mark" here.' "$QUOTES_KNOWN")" = 'the rule no longer quotes: "second mark"' ] && echo ok || echo "a line missing a quotation gave: $(exact_quotations 'Only "first mark" here.' "$QUOTES_KNOWN")")"
check "the exact wordings check fails a known wording quoted once more than the list has it" \
  "$([ "$(exact_quotations 'One "first mark" and "second mark" and "first mark".' "$QUOTES_KNOWN")" != ok ] && echo ok || echo "a repeated quotation passed")"
check "the exact wordings check passes the known list" \
  "$([ "$(exact_quotations 'One "first mark" and "second mark" here.' "$QUOTES_KNOWN")" = ok ] && echo ok || echo "the known list was failed")"

# ---- 3. the agent rules point at the home and keep their own rule ----
pointer="$(grep -m 1 -F -- "$RULE_NAME" "$RULES" 2>/dev/null)"
check "the agent rules name the rule" "$([ -n "$pointer" ] && echo ok || echo "no '$RULE_NAME' in $RULES")"
# The whole paragraph on refusals is ONE line of the agent rules, and its first sentence already
# says "under item 6 of your report" and names other issues. So everything asked of the exception
# is looked for in the exception's own words, the text after the rule's name on that line, never
# anywhere on the line.
exception="${pointer#*"$RULE_NAME"}"
[ "$exception" = "$pointer" ] && exception=""
check "the agent rules say where its home is" \
  "$(grep -q -F -- '~/.claude/CLAUDE.md' <<< "$exception" && echo ok || echo "the exception naming the rule does not name ~/.claude/CLAUDE.md")"
check "the agent rules carry the issue" \
  "$(grep -q -F -- 'claude-config#3224' <<< "$exception" && echo ok || echo "the exception naming the rule does not carry claude-config#3224")"
check "the agent rules still say a refused command is final" \
  "$(grep -q -F -- 'A refused command is final.' "$RULES" 2>/dev/null && echo ok || echo "the rule of #3028 is gone from $RULES")"
# The sentence that opens "Refused a second time", up to its full stop, is what must name item 6.
second_refusal() { # second_refusal <the exception's words>   prints ok, or what is missing
  local words="$1" sentence
  case "$words" in
    *'Refused a second time'*) ;;
    *) echo "the exception does not say what a second refusal means"; return 0 ;;
  esac
  sentence="${words#*Refused a second time}"
  sentence="${sentence%%.*}"
  case "$sentence" in
    *'item 6'*) echo ok ;;
    *) echo "the sentence on a second refusal does not send it under item 6: Refused a second time$sentence." ;;
  esac
}
check "the agent rules send a second refusal to the report" "$(second_refusal "$exception")"
# Seen to fail (L1): a line whose only "item 6" is in its first sentence, as the real line's first
# sentence has one, and a line whose exception stops before the second refusal.
dropped=" in \`~/.claude/CLAUDE.md\` (claude-config#3224). Refused a second time, it is final like any other. A later sentence names item 6."
check "the check of the second refusal fails when its own sentence drops item 6" \
  "$([ "$(second_refusal "$dropped")" != "ok" ] && echo ok || echo "a sentence with no item 6 passed because another sentence on the line has one")"
check "the check of the second refusal fails when the exception never mentions one" \
  "$([ "$(second_refusal " in \`~/.claude/CLAUDE.md\` (claude-config#3224).")" != "ok" ] && echo ok || echo "an exception with no second refusal passed")"
check "the check of the second refusal passes a sentence that names item 6" \
  "$([ "$(second_refusal " (claude-config#3224). Refused a second time, it is final: report it under item 6.")" = "ok" ] && echo ok || echo "a sentence naming item 6 was failed")"
# The agent rules restate none of the home: the marks and the count live in one place.
check "the agent rules do not restate what a second refusal is recorded with" \
  "$(grep -q -F -- 'issue-spool.sh note . "<what was refused' <<< "$exception" && echo "the exception restates the home's recording step" || echo ok)"
# claude-config#3822: the exception says which three refusals the home covers, so an agent knows to
# look there, and leaves the words that mark each of them to the home. The exception's own lead in
# is the text from "The third:" up to the rule's name.
lead="${pointer%%"$RULE_NAME"*}"
[ "$lead" = "$pointer" ] && lead=""
lead="${lead##*The third:}"
check "the agent rules' exception names a refusal with no verdict" \
  "$(grep -q -F -- 'gave no verdict' <<< "$lead" && echo ok || echo "the exception's lead in does not say gave no verdict")"
check "the agent rules' exception names a hook stopped at its timeout" \
  "$(grep -q -F -- 'stopped at its timeout' <<< "$lead" && echo ok || echo "the exception's lead in does not name a hook stopped at its timeout")"
check "the agent rules' exception names a guard another mod did not answer" \
  "$(grep -q -F -- 'no answer from another mod' <<< "$lead" && echo ok || echo "the exception's lead in does not name a guard that got no answer from another mod")"
# The lead in names those three and no other, so it is held whole. Three phrase checks pass a lead in
# that keeps the phrases and adds a fourth refusal: on 2026-11-27 the review of pull request 3851
# wrote "a hook was stopped at its timeout or refused the call for any reason" into a scratch copy
# and every check passed, which would have told every dispatched agent that any hook's refusal is
# not a verdict.
KNOWN_LEAD=" a refusal in which auto mode's safety check says it gave no verdict, a hook was stopped at its timeout, or a guard got no answer from another mod is not a verdict on the command, and which words mark each of the three and what to do then is \""
lead_is() { # lead_is <lead in>   ok when it is the known one, word for word
  if [ "$1" = "$KNOWN_LEAD" ]; then echo ok
  else echo "the exception's lead in is not the known one, so it may name a refusal the home does not cover. Found:$1"
  fi
}
check "the agent rules' exception names those three refusals and no other" "$(lead_is "$lead")"
# Seen to fail (L1) on the widened lead in of that review.
check "the lead in check fails a lead in that adds any refusal by a hook" \
  "$([ "$(lead_is "${KNOWN_LEAD/its timeout,/its timeout or refused the call for any reason,}")" != ok ] && echo ok || echo "a widened lead in passed")"
check "the agent rules carry the issue that added the two refusals" \
  "$(grep -q -F -- '#3822' <<< "$exception" && echo ok || echo "the exception naming the rule does not carry #3822")"
check "the agent rules leave the words that mark a hook out of time to the home" \
  "$(grep -q -F -- 'blocking because onFailure' "$RULES" 2>/dev/null && echo "the agent rules restate the home's words for a hook stopped at its timeout" || echo ok)"
check "the agent rules leave the words that mark an unanswered guard to the home" \
  "$(grep -q -F -- 'did not answer within' "$RULES" 2>/dev/null && echo "the agent rules restate the home's words for an unanswered guard" || echo ok)"

# ---- 4. no other document states the absolute form bare ----
# A line that puts the check beside "is final" or "never retried", either way round, in one
# sentence. Suites, the generated lessons files and dated audits record history, not rules.
ABSOLUTE='(auto mode|classifier|safety check)[^.]*(is final|are final|stays final|never retried|never a retry)|(is final|are final|stays final|never retried|never a retry)[^.]*(auto mode|classifier|safety check)'
bare_files() { # bare_files <home file> <root>...   prints each file with a bare absolute line, once
  local home="$1"; shift
  local hits
  # Read into a variable first, never through process substitution, whose child bash 3.2 never
  # waits for (L1035, claude-config#1989). One pass over the tree (L297).
  hits="$(grep -r -n -i -E "$ABSOLUTE" \
    --include='*.md' --include='*.ts' --include='*.tsx' --include='*.sh' --include='*.py' \
    --exclude='test-*' --exclude='*.test.ts' --exclude='*.test.tsx' --exclude='LESSONS*' \
    --exclude-dir=tests --exclude-dir=audits --exclude-dir=node_modules --exclude-dir=.git \
    "$@" 2>/dev/null)"
  # Every name this sets is declared, hit included: it is read through a subshell, where a name left
  # global is discarded on return (test-scan-subshell-globals.sh).
  local seen="" file rest text hit
  while IFS= read -r hit; do
    [ -n "$hit" ] || continue
    file="${hit%%:*}"; rest="${hit#*:}"; text="${rest#*:}"
    [ "$file" = "$home" ] && continue
    # A line that carries the exception itself is not the absolute form.
    grep -q -i -F -- 'no verdict' <<< "$text" && continue
    grep -q -F -- "$RULE_NAME" "$file" 2>/dev/null && continue
    case "$seen" in *"|$file|"*) continue ;; esac
    seen="$seen|$file|"
    printf '%s\n' "$file"
  done <<HITS
$hits
HITS
}

if [ -n "$PAYLOAD" ]; then
  roots=("$PAYLOAD")
  for extra in README.md DESIGN.md docs; do
    [ -e "$REPO/$extra" ] && roots+=("$REPO/$extra")
  done
  bare="$(bare_files "$PAYLOAD/CLAUDE.md" "${roots[@]}")"
  unpointed=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    unpointed="$unpointed ${f#"$REPO"/}"
  done <<BARE
$bare
BARE
  check "every other document that calls a refusal by the check final names the rule or carries its exception" \
    "$([ -z "$unpointed" ] && echo ok || echo "the absolute form with no pointer to '$RULE_NAME' in:$unpointed")"
  # The scan passes a whole file on one pointer anywhere in it, which is too loose for the one
  # sentence an overnight worker is told on every prompt: the sleep rule of the scope modes mod.
  # That sentence is the old rule's second copy, and overnight is where the refusals fell, so it is
  # held by itself: the line that says a refusal is final must name the rule and its home.
  WORKER_FILE="$PAYLOAD/mods/scope-modes/hooks/register.ts"
  worker_line="$(grep -m 1 -F -- 'by that list or by the auto mode classifier' "$WORKER_FILE" 2>/dev/null)"
  check "the sleep rule an overnight worker is told is where this suite looks for it" \
    "$([ -n "$worker_line" ] && echo ok || echo "no sentence about a refusal 'by that list or by the auto mode classifier' in $WORKER_FILE, so the worker's rule was not read")"
  check "the sleep rule names the rule on the line that calls a refusal final" \
    "$(grep -q -F -- "$RULE_NAME" <<< "$worker_line" && echo ok || echo "the worker is told a refusal is final with no '$RULE_NAME' beside it")"
  check "the sleep rule says where the rule's home is" \
    "$(grep -q -F -- '~/.claude/CLAUDE.md' <<< "$worker_line" && echo ok || echo "the worker's line does not name ~/.claude/CLAUDE.md")"
  check "the sleep rule tells the two refusals apart by the words no verdict" \
    "$(grep -q -i -F -- 'no verdict' <<< "$worker_line" && echo ok || echo "the worker's line does not say no verdict")"
  # The scan must have read the tree: the agent rules state the absolute form and name the home, so
  # a scan that cannot find their line would pass everything above by seeing nothing (L98).
  check "the scan reads the agent rules' own line" \
    "$(grep -q -i -E "$ABSOLUTE" "$PAYLOAD/skills/orchestrate/agent-rules.md" 2>/dev/null && echo ok || echo "the absolute form is not found in the agent rules, so the scan measured nothing")"
else
  echo "SUITE-PART-UNMEASURED $DIR/.. is not the payload of a claude-config checkout, so the payload was not scanned for a second copy of the rule"
fi

# The scan must be able to see a bare copy, and to pass a pointed one, or its silence measures
# nothing (L1).
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/no-verdict-rule.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
mkdir -p "$fixture_dir/bare" "$fixture_dir/pointed" "$fixture_dir/carries" "$fixture_dir/reversed" "$fixture_dir/other"
printf 'A refusal by the auto mode classifier is final: skip that issue.\n' > "$fixture_dir/bare/copy.md"
printf 'A refusal by the auto mode classifier is final. See "%s" in the global rules.\n' "$RULE_NAME" > "$fixture_dir/pointed/copy.md"
printf 'If the safety check refuses it, it is never retried; if it gets no verdict, send it once.\n' > "$fixture_dir/carries/copy.md"
printf 'It is never retried once the classifier has refused it.\n' > "$fixture_dir/reversed/copy.ts"
printf 'The upload is final. A later paragraph mentions the classifier.\n' > "$fixture_dir/other/copy.md"
seen="$(bare_files /nonexistent "$fixture_dir/bare")"
check "the scan finds a document stating the absolute form bare" \
  "$([ "$seen" = "$fixture_dir/bare/copy.md" ] && echo ok || echo "the scan returned '$seen'")"
seen="$(bare_files /nonexistent "$fixture_dir/reversed")"
check "the scan finds the absolute form written the other way round, in code" \
  "$([ "$seen" = "$fixture_dir/reversed/copy.ts" ] && echo ok || echo "the scan returned '$seen'")"
seen="$(bare_files /nonexistent "$fixture_dir/pointed")"
check "the scan passes a document that names the rule" "$([ -z "$seen" ] && echo ok || echo "the scan returned '$seen'")"
seen="$(bare_files /nonexistent "$fixture_dir/carries")"
check "the scan passes a line that carries the exception itself" "$([ -z "$seen" ] && echo ok || echo "the scan returned '$seen'")"
seen="$(bare_files /nonexistent "$fixture_dir/other")"
check "the scan passes two sentences that only share a line" "$([ -z "$seen" ] && echo ok || echo "the scan returned '$seen'")"
seen="$(bare_files "$fixture_dir/bare/copy.md" "$fixture_dir/bare")"
check "the scan never reports the home itself" "$([ -z "$seen" ] && echo ok || echo "the scan returned '$seen'")"

# ---- 5. the style rule: no em or en dash in the two rule files' lines ----
# One -e per character, never a \| alternation, which basic regex grep honours on some systems only.
dashes="$(grep -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' <<< "$home_line
$pointer")"
check "the rule and its pointer hold no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
