#!/usr/bin/env bash
# Tests for the builder model rule (claude-config#1961).
#
# Dan decided on 2026-11-01 that a builder agent's model is set by a written rule by kind of task,
# and that the orchestrator may suggest an override for one brief saying why. On 2026-11-09, with
# Fable his default model, he split it into three tiers (claude-config#2547): Sonnet for three
# mechanical kinds, Fable for design, security and compliance work, Opus for everything else. The
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
has "lists fixes for review comments" 'review comment'
has "carries Dan's three tier decision date" '2026-11-09'
# Three tiers, each on its own bullet (Dan, 2026-11-09, claude-config#2547): Fable for design,
# security and compliance work even when it is also a mechanical kind, Opus for everything else.
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
on_line "keeps Fable for them even when they are one of the mechanical kinds" "$fable_line" 'even when'
on_line "makes Opus the default for anything not listed" "$opus_line" 'everything else'
check "the Opus bullet no longer claims design, security or compliance" \
  "$(grep -q -i -E 'design|security|compliance' <<< "$opus_line" && echo "on: $opus_line" || echo ok)"
on_line "keeps the three mechanical kinds on Sonnet" "$sonnet_line" 'three kinds'
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
