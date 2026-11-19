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
# The rule has ONE home (L83): one bullet of the global CLAUDE.md, the only rule file every kind of
# session loads (a main session, an overnight worker, a headless run and a dispatched agent alike).
# Everything else that says a refusal by the check is final points at that bullet by name, because
# two copies of a rule drift (L370) and a copy with no exception contradicts it.
#
# What this holds the files to:
#   1. the home exists exactly once and states all four parts: what no verdict looks like, in the
#      words a session is shown; the one identical resend; what a second refusal means and where it
#      is recorded; and that every other refusal stays final. It carries Dan's decision and date.
#   2. the words the home quotes are words Claude Code really writes, held against the refusal a
#      session received on 2026-11-19 (L48), and the rule asks nothing that message forbids.
#   3. the rules every dispatched agent reads point at the home and keep their own rule.
#   4. no other document states the absolute form bare. A scan by spelling (L564): it finds a line
#      that puts the check beside "is final" or "never retried". Such a line passes when it carries
#      the exception itself (it says "no verdict") or its file names the home.
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
# Dan's decision, quoted with its date and issue, the way the neighbouring rules carry his.
says "carries the date of Dan's decision" '2026-11-19'
says "carries the issue" 'claude-config#3224'
says "quotes Dan's answer" '"One unchanged resend"'
says "declares itself the one home" 'one home'

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

# ---- 3. the agent rules point at the home and keep their own rule ----
pointer="$(grep -m 1 -F -- "$RULE_NAME" "$RULES" 2>/dev/null)"
check "the agent rules name the rule" "$([ -n "$pointer" ] && echo ok || echo "no '$RULE_NAME' in $RULES")"
check "the agent rules say where its home is" \
  "$(grep -q -F -- '~/.claude/CLAUDE.md' <<< "$pointer" && echo ok || echo "the line naming the rule does not name ~/.claude/CLAUDE.md")"
check "the agent rules carry the issue" \
  "$(grep -q -F -- 'claude-config#3224' <<< "$pointer" && echo ok || echo "the line naming the rule does not carry claude-config#3224")"
check "the agent rules still say a refused command is final" \
  "$(grep -q -F -- 'A refused command is final.' "$RULES" 2>/dev/null && echo ok || echo "the rule of #3028 is gone from $RULES")"
check "the agent rules send a second refusal to the report" \
  "$(grep -q -F -- 'Refused a second time' <<< "$pointer" && grep -q -F -- 'item 6' <<< "$pointer" && echo ok || echo "the line naming the rule does not say a second refusal goes under item 6")"
# The agent rules restate none of the home: the marks and the count live in one place.
check "the agent rules do not restate what a second refusal is recorded with" \
  "$(grep -q -F -- 'issue-spool.sh note . "<what was refused' <<< "$pointer" && echo "the pointer line restates the home's recording step" || echo ok)"

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
  local seen="" file rest text
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

# One file still states the absolute form bare and is listed here rather than failed: the sleep rule
# an overnight worker is told on every prompt, and the comment over the handler that notes a
# refusal. The mods folder belonged to another change while this rule was written, so its two lines
# get the pointer in a follow on under claude-config#3224, which stays open until they have it. An
# entry here that no longer needs to be here fails, so the list cannot outlive its reason (L129).
AWAITING="mods/scope-modes/hooks/register.ts"

if [ -n "$PAYLOAD" ]; then
  roots=("$PAYLOAD")
  for extra in README.md DESIGN.md docs; do
    [ -e "$REPO/$extra" ] && roots+=("$REPO/$extra")
  done
  bare="$(bare_files "$PAYLOAD/CLAUDE.md" "${roots[@]}")"
  unpointed=""
  awaited=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    rel="${f#"$PAYLOAD"/}"
    case " $AWAITING " in
      *" $rel "*) awaited="$awaited $rel" ;;
      *) unpointed="$unpointed ${f#"$REPO"/}" ;;
    esac
  done <<BARE
$bare
BARE
  check "every other document that calls a refusal by the check final names the rule or carries its exception" \
    "$([ -z "$unpointed" ] && echo ok || echo "the absolute form with no pointer to '$RULE_NAME' in:$unpointed")"
  for a in $AWAITING; do
    case " $awaited " in
      *" $a "*) echo "NOTE: payload/$a still states the absolute form with no pointer to the rule; it is awaited under claude-config#3224." ;;
      *) check "the awaited list holds only files that still need it" "payload/$a no longer states the absolute form bare, so take it out of AWAITING" ;;
    esac
  done
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
