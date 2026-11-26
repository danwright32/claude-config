#!/usr/bin/env bash
# Tests for the builder model rule (claude-config#1961).
#
# Dan decided on 2026-11-01 that a builder agent's model is set by a written rule by kind of task,
# and that the orchestrator may suggest an override for one brief saying why. On 2026-11-09, with
# Fable his default model, he split it into three tiers (claude-config#2547): Sonnet for a few
# mechanical kinds, Fable for design, security and compliance work, Opus for everything else. On
# 2026-11-19 he narrowed Sonnet to work that needs no judgement (claude-config#3290). On
# 2026-11-24 he narrowed Fable to a change to what a design, security or compliance control decides
# or shows, and reviews of one, after a sample of 50 Fable briefs found 16% were follow on work that
# changed neither (claude-config#3393). On 2026-11-26 he took writing or rewording a message that
# code posts to Slack out of design and put it on Opus (claude-config#3757). The
# running agent cap is held by test-agent-cap.sh since #2546. The rule has ONE home, the "Which
# model a builder runs on" section of the orchestrate skill, beside the dispatch board whose Model column it fills (L83).
# Everything else that dispatches builders points at that section by name rather than restating the
# kinds, because two copies of a list drift (L370).
#
# What this holds the files to:
#   1. the home exists, exactly once, and puts each kind on its tier, with Opus the default;
#   2. the board carries a Model column and the wave is sent with each row's model;
#   3. the global CLAUDE.md points builders at the home;
#   4. any other payload document that sets a model on an Agent call names the home, so a second
#      copy of the rule cannot arrive unnoticed. This is a scan by spelling (L564): it finds a copy
#      written with the Agent tool's own parameter, which is how a dispatch rule is written.
#
# BUILDER_RULE_HOME and BUILDER_RULE_CLAUDE_MD point the suite at other copies, which is how a
# broken copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The checkout, found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663).
# Empty for an installed copy in ~/.claude/skills or a copy inside some other repository, and then
# the checks that read the payload say they were not measured rather than judging other files.
REPO="$(bash "$DIR/../../hooks/lib/checkout-root.sh" "$DIR/../.." 2>/dev/null || true)"
PAYLOAD=""
[ -n "$REPO" ] && PAYLOAD="$REPO/payload"
HOME_FILE="${BUILDER_RULE_HOME:-$DIR/SKILL.md}"
CLAUDE_MD="${BUILDER_RULE_CLAUDE_MD:-${PAYLOAD:+$PAYLOAD/CLAUDE.md}}"

# The home's name, the words every pointer quotes. Renaming it means changing every pointer, which
# check 4 then enforces.
RULE_NAME="Which model a builder runs on"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# ---- 1. the home exists once and says the whole rule ----
homes="$(grep -c -x -F "### $RULE_NAME" "$HOME_FILE" 2>/dev/null)"
check "the orchestrate skill holds the rule's section exactly once" \
  "$([ "$homes" = "1" ] && echo ok || echo "found ${homes:-0} times in $HOME_FILE")"

# The section runs from its heading to the next heading of any level.
section="$(awk -v h="### $RULE_NAME" '
  $0 == h { on = 1; next }
  on && /^#/ { exit }
  on { print }
' "$HOME_FILE" 2>/dev/null)"
has() { # has <description> <fixed text>   checks the section, case insensitive
  check "the rule $1" "$(grep -q -i -F -- "$2" <<< "$section" && echo ok || echo "no '$2' in the section")"
}
has "passes the model on the Agent call for Sonnet" 'model: "sonnet"'
has "passes the model on the Agent call for Fable" 'model: "fable"'
has "passes the model on the Agent call for Opus" 'model: "opus"'
has "lists renames" 'rename'
has "lists filling in tests" 'filling in tests'
has "carries Dan's three tier decision date" '2026-11-09'
# Sonnet only for work that needs no judgement (Dan, 2026-11-19, claude-config#3290): "a fix for a
# review comment" sent logic changing review fixes to Sonnet, so the tier is named by what it is for.
has "carries Dan's no judgement decision date" '2026-11-19'
has "carries the no judgement decision's issue" '#3290'
has "quotes Dan's words on what Sonnet is fine for" 'any idiot could do'
# Three tiers, each on its own bullet (Dan, 2026-11-09, claude-config#2547): Fable for design,
# security and compliance work, Opus for everything else.
# Judged per bullet, so a word sitting on the wrong tier's line fails rather than passing because
# it appears somewhere in the section.
bullet() { awk -v t="$1" '/^- / && index(tolower($0), tolower(t)) { print; exit }' <<< "$section"; }
fable_line="$(bullet 'model: "fable"')"
opus_line="$(bullet 'model: "opus"')"
sonnet_line="$(bullet 'model: "sonnet"')"
on_line() { # on_line <description> <line> <fixed text>
  check "the rule $1" "$(grep -q -i -F -- "$3" <<< "$2" && echo ok || echo "no '$3' on: ${2:-the missing bullet}")"
}
on_line "puts design work on Fable" "$fable_line" 'design'
on_line "puts security work on Fable" "$fable_line" 'security'
on_line "puts compliance work on Fable" "$fable_line" 'compliance'
# Narrowed to what a control decides or shows (Dan, 2026-11-24, claude-config#3393): of 50 Fable
# briefs sampled, 8 were follow on work on a security item that changed neither, sent to Fable
# because the bullet tied the model to the item, "even when it is also one of the kinds above".
on_line "narrows Fable to a change to what a control decides or shows" "$fable_line" 'changes what a design, security or compliance control decides or shows'
on_line "keeps reviews of such a change on Fable" "$fable_line" 'reviews of such a change'
on_line "sends follow on work that changes neither to Opus or Sonnet" "$fable_line" 'changes neither'
on_line "names Opus for that follow on work" "$fable_line" 'runs on Opus, or on Sonnet where it needs no judgement'
on_line "gives a red check as follow on work" "$fable_line" 'a red check'
on_line "gives a test flake as follow on work" "$fable_line" 'a test flake'
on_line "gives finishing a merge or a push as follow on work" "$fable_line" 'finishing a merge or a push'
on_line "counts a guard that enforces process or quality as a security control" "$fable_line" 'enforces process or quality'
on_line "names the design round guard as one" "$fable_line" 'design round guard'
on_line "names the area check as one" "$fable_line" 'area check'
on_line "carries Dan's narrowing decision date" "$fable_line" '2026-11-24'
on_line "carries the narrowing decision's issue" "$fable_line" '#3393'
on_line "quotes Dan's choice" "$fable_line" 'Narrow to what a guard decides'
# The old sentence tied the model to the item, which contradicts the follow on clause, so it is
# gone. What survives of it: a Sonnet kind that does change what a control shows (a wording fix to
# a guard's message) still runs on Fable, because what the change does decides the tier.
check "the Fable bullet no longer ties the model to the item whatever the change" \
  "$(grep -q -i -F 'even when it is also one of the kinds above' <<< "$fable_line" && echo "on: $fable_line" || echo ok)"
on_line "says what the change does decides the tier, not its kind" "$fable_line" 'what the change does decides the tier'
# A guard that posts its message to Slack fitted both this example and the Slack sentence below, so
# Dan scoped the example to messages shown outside Slack (2026-11-26, claude-config#3757: "Add
# 'outside Slack' to the guard line"). Rewording a guard's Slack message runs on Opus.
on_line "keeps a guard's message on Fable only outside Slack" "$fable_line" 'the message a guard shows a person outside Slack runs on Fable'
# The classes the sample used, fixed before it was read, so every orchestrator classes alike.
has "defines security by who or what may act" 'who or what may act'
has "counts secrets and private data as security" 'secrets or private data'
has "leaves a gate's speed, timing or test runs out of security" "speed, timing or test runs"
has "defines compliance as an obligation set outside the codebase" 'obligation set outside the codebase'
has "defines design by how a person uses it" 'how a person uses it'
has "classes a brief by its main task" 'by its main task'
# Wording on a screen stays design, and so on Fable when it is the main task: Dan chose the narrow
# sentence below over sending all wording to Opus (2026-11-26, claude-config#3757).
has "keeps wording a person reads as design when it is the main task" 'wording a person reads included when that wording is the main task'
# Slack message wording runs on Opus (Dan, 2026-11-26, claude-config#3757): an alert rewording job
# went to Fable under the design definition above, and two of its agents each used about 460,000
# tokens, while the slack-alerts skill and its checker already hold the standard. Dan approved this
# sentence word for word, so it is held whole, and inside the paragraph that defines the classes,
# where a reader classing a brief looks.
SLACK_SENTENCE='Writing or rewording a message that code posts to Slack (an alert, an all clear, a reminder, a report) is not design under this rule and runs on Opus: the `slack-alerts` skill and its checker hold the standard (Dan, 2026-11-26).'
classes_line="$(awk 'index($0, "What counts as each") == 1 { print; exit }' <<< "$section")"
check "the rule sends Slack message wording to Opus, in Dan's approved sentence, in the paragraph defining the classes" \
  "$(grep -q -F -- "$SLACK_SENTENCE" <<< "$classes_line" && echo ok || echo "the approved sentence is not on: ${classes_line:-the missing What counts as each paragraph}")"
# The sentence hands the standard to a skill and its checker, so both must be there to hand it to.
if [ -n "$PAYLOAD" ]; then
  check "the slack-alerts skill the sentence names exists, with its checker" \
    "$([ -f "$PAYLOAD/skills/slack-alerts/SKILL.md" ] && [ -f "$PAYLOAD/skills/slack-alerts/check_alert.py" ] && echo ok || echo "no skills/slack-alerts/SKILL.md and check_alert.py under $PAYLOAD")"
else
  echo "SUITE-PART-UNMEASURED $DIR/../.. is not the payload of a claude-config checkout, so the slack-alerts skill the rule names was not looked for"
fi
on_line "makes Opus the default for anything not listed" "$opus_line" 'everything else'
check "the Opus bullet no longer claims design, security or compliance" \
  "$(grep -q -i -E 'design|security|compliance' <<< "$opus_line" && echo "on: $opus_line" || echo ok)"
on_line "describes Sonnet by what it is for" "$sonnet_line" 'needs no judgement'
on_line "lists comment and wording fixes on Sonnet" "$sonnet_line" 'comment or wording fix'
on_line "lists renames on Sonnet" "$sonnet_line" 'rename or move that changes no behaviour'
on_line "lists filling in tests on Sonnet" "$sonnet_line" 'filling in tests for code that already exists'
on_line "sends a review fix that changes logic or behaviour to Opus" "$sonnet_line" 'review finding that changes logic or behaviour runs on Opus'
on_line "or to Fable where it changes what a control decides or shows" "$sonnet_line" 'Fable where it changes what a design, security or compliance control decides or shows'
check "the Sonnet bullet no longer offers any fix for a review comment" \
  "$(grep -q -i -F 'fix for a review comment' <<< "$sonnet_line" && echo "on: $sonnet_line" || echo ok)"
has "says a fork ignores the model" 'fork ignores'
has "lets the orchestrator suggest an override, saying why" 'suggest it to Dan with the reason'
has "carries Dan's decision date" '2026-11-01'
has "declares itself the one home" "one home"

# ---- 2. the board and the dispatch use it ----
check "the dispatch board has a Model column" \
  "$(grep -q -F '| Agent | Model |' "$HOME_FILE" 2>/dev/null && echo ok || echo "no Model column in the board")"
check "each Agent call in a wave carries its row's model" \
  "$(grep -q -F 'carrying the `model` its board row shows' "$HOME_FILE" 2>/dev/null && echo ok || echo "the wave line does not pass the model")"

# ---- 3. the global CLAUDE.md points at the rule ----
# The running agent cap is no longer held here: it is a number per Mac, and test-agent-cap.sh holds
# it beside its one home, hooks/agent-cap.sh (claude-config#2546).
if [ -n "$CLAUDE_MD" ]; then
  pointer_lines="$(grep -F "$RULE_NAME" "$CLAUDE_MD" 2>/dev/null)"
  case "$pointer_lines" in
    *skills/orchestrate/SKILL.md*) pointer_found=ok ;;
    *) pointer_found="no pointer in $CLAUDE_MD" ;;
  esac
  check "the global CLAUDE.md points builders at the rule's section" "$pointer_found"
  # Its one line summary names the three tiers, so a reader who stops at the pointer is not told
  # that design work runs on Opus (#2547).
  check "the pointer's summary names all three models" \
    "$(grep -q -F 'Sonnet' <<< "$pointer_lines" && grep -q -F 'Fable' <<< "$pointer_lines" && grep -q -F 'Opus' <<< "$pointer_lines" && echo ok || echo "the pointer line does not name Sonnet, Fable and Opus")"
  # And its Fable summary is the narrowed one, so a reader who stops there does not send a red
  # check on a security item to Fable (#3393).
  check "the pointer's summary narrows Fable to what a control decides or shows" \
    "$(grep -q -F 'what a design, security or compliance control decides or shows' <<< "$pointer_lines" && echo ok || echo "the pointer line still sends all design, security and compliance work to Fable")"
else
  echo "SUITE-PART-UNMEASURED $DIR/../.. is not the payload of a claude-config checkout, so the pointer in its CLAUDE.md was not read"
fi

# ---- 4. any other document setting an Agent model names the home ----
# Generated lessons files and dated audits record history, not dispatch rules.
scan() { # scan <root>   prints every markdown file under root that sets an Agent model
  grep -r -l -E 'model: "(sonnet|opus|haiku|fable)"' --include='*.md' "$1" 2>/dev/null
}
if [ -n "$PAYLOAD" ]; then
  # Read into a variable first, never through process substitution, whose child bash 3.2 never
  # waits for (L1035, claude-config#1989).
  setters="$(scan "$PAYLOAD")"
  unpointed=""
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    case "$f" in
      "$HOME_FILE"|*/LESSONS*|*/audits/*) continue ;;
    esac
    grep -q -F "$RULE_NAME" "$f" || unpointed="$unpointed $f"
  done <<SETTERS
$setters
SETTERS
  check "every other document that sets an Agent model names the rule's section" \
    "$([ -z "$unpointed" ] && echo ok || echo "no pointer in:$unpointed")"
else
  echo "SUITE-PART-UNMEASURED $DIR/../.. is not the payload of a claude-config checkout, so the payload was not scanned for a second copy of the rule"
fi

# The scan must be able to see a copy, or its silence measures nothing (L1).
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/builder-model-rule.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
printf 'Dispatch the builder with model: "sonnet".\n' > "$fixture_dir/copy.md"
seen="$(scan "$fixture_dir")"
check "the scan finds a document that sets a model" \
  "$([ "$seen" = "$fixture_dir/copy.md" ] && echo ok || echo "the scan returned '$seen'")"
mkdir -p "$fixture_dir/fable"
printf 'Dispatch the security builder with model: "fable".\n' > "$fixture_dir/fable/copy.md"
seen_fable="$(scan "$fixture_dir/fable")"
check "the scan finds a document that sets the Fable model" \
  "$([ "$seen_fable" = "$fixture_dir/fable/copy.md" ] && echo ok || echo "the scan returned '$seen_fable'")"

# ---- 5. the style rule: no em or en dash in the skill ----
# One -e per character, never a \| alternation, which basic regex grep honours on some systems only.
dashes="$(grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' "$HOME_FILE" 2>/dev/null)"
check "the orchestrate skill holds no em or en dash" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
