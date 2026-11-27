#!/usr/bin/env bash
# Tests for the code comment standard (claude-config#3857).
#
# The standard lives in the "Code comments" entry under "## Code Standards" in the global
# CLAUDE.md, and the item of lib/ai-review-prompt.txt about a description that no longer matches
# the code asks each push's review for it. This suite holds both files to it:
#   1. the entry is in the file once, inside the Code Standards section, and states each rule;
#   2. that item of the review prompt keeps its number and what it already asked, and also asks for
#      a comment the change adds that tells the history of the change or states a count or a list
#      of other code as fact;
#   3. the entry and that item hold no em or en dash (the rest of each file is not scanned here);
#   4. the readers below report a copy that breaks each of those, so their silence on the real
#      files is a measurement.
#
# CODE_COMMENT_RULE_CLAUDE_MD and CODE_COMMENT_RULE_PROMPT point the suite at other copies.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_MD="${CODE_COMMENT_RULE_CLAUDE_MD:-$DIR/../CLAUDE.md}"
PROMPT="${CODE_COMMENT_RULE_PROMPT:-$DIR/lib/ai-review-prompt.txt}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

# One -e per character, never a \| alternation, which basic regex grep honours on some systems only.
has_dash() { grep -q -e $'\xe2\x80\x94' -e $'\xe2\x80\x93' <<< "$1"; }

# The entry as it sits in one copy of the rules: its lead bullet and the indented bullets under it,
# read only from inside the Code Standards section, so the same words under another heading do not
# pass for it.
entry_of() { # $1 = a copy of the global CLAUDE.md
  awk '
    /^## / { inside = ($0 == "## Code Standards") }
    inside && /^- \*\*Code comments\*\*/ { open = 1; print; next }
    open && /^  - / { print; next }
    { open = 0 }
  ' "$1" 2>/dev/null
}

# Each prints one line per thing a copy lacks, and nothing for a copy that carries it all.
missing_from_rules() { # $1 = a copy of the global CLAUDE.md
  local file="$1" homes entry what phrase
  homes="$(grep -c -e '^- \*\*Code comments\*\*' "$file" 2>/dev/null)"
  [ "$homes" = "1" ] || echo "the Code comments entry is in the file ${homes:-0} times, not once"
  entry="$(entry_of "$file")"
  if [ -z "$entry" ]; then
    echo "no Code comments entry inside the Code Standards section"
    return 0
  fi
  while IFS='|' read -r what phrase; do
    grep -q -F -- "$phrase" <<< "$entry" || echo "the entry does not say $what: no '$phrase'"
  done <<'PHRASES'
whose decision it is and when|Dan, 2026-11-27
which issue it came from|claude-config#3857
that it covers new and changed code|new and changed code only
that old comments are not swept|no cleanup sweep
what earns a comment|the code cannot show
to leave the history out|leave out the story
what the history is|the bug, the task, the fix, the date, who asked
that one issue number may point at a past failure|One issue number
to cite only what a reader can look up|cannot look up from the repository
that this covers lesson ids in app code|lesson ids in app code
to state no count or list of other code|a count or a list of other code as fact
that a comment putting work off names its issue|names its issue
when that comment goes|deleted when the work is done or dropped
that code is not left commented out|No commented out code
that a comment changes with its code|in the same change
to leave comments on unchanged code alone|code you did not change
to keep a comment that gives a reason|never delete a comment that gives a reason
what a file header says|what callers can rely on
that a file header holds no history|holds no history
where a test says its behaviour|the test name
PHRASES
  has_dash "$entry" && echo "the entry holds an em or en dash"
  return 0
}

missing_from_prompt() { # $1 = a copy of the review prompt
  local file="$1" item what phrase
  item="$(grep -m 1 -e '^11\. A description that no longer matches the code' "$file" 2>/dev/null)"
  if [ -z "$item" ]; then
    echo "no item 11 about a description that no longer matches the code"
    return 0
  fi
  while IFS='|' read -r what phrase; do
    grep -q -F -- "$phrase" <<< "$item" || echo "item 11 does not ask for $what: no '$phrase'"
  done <<'PHRASES'
every description of one behaviour at once, as before|every other place that describes the same behaviour
a comment the change adds|a comment the change ADDS
one that tells the history|tells the history of the change
what the history is|the bug, the task, the date, who asked
one that states a count or a list of other code|a count or a list of other code as fact
PHRASES
  has_dash "$item" && echo "item 11 holds an em or en dash"
  return 0
}

# ---- 1 to 3. the real files ----
gaps="$(missing_from_rules "$CLAUDE_MD")"
check "the global CLAUDE.md carries the code comment standard under Code Standards" \
  "$([ -z "$gaps" ] && echo ok || printf '%s: %s' "$CLAUDE_MD" "$gaps")"
gaps="$(missing_from_prompt "$PROMPT")"
check "item 11 of the review prompt asks for an added comment that tells history or states a count" \
  "$([ -z "$gaps" ] && echo ok || printf '%s: %s' "$PROMPT" "$gaps")"

# ---- 4. the readers report a broken copy ----
fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/code-comment-rule.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT
reports() { # reports <description> <what the reader printed> <words it must have printed>
  check "$1" "$(grep -q -F -- "$3" <<< "$2" && echo ok || echo "the reader printed '$2'")"
}

# The entry lifted out of its section and set down under another heading.
{ awk '
    /^- \*\*Code comments\*\*/ { open = 1; next }
    open && /^  - / { next }
    { open = 0; print }
  ' "$CLAUDE_MD" 2>/dev/null
  printf '\n## Somewhere else\n\n'
  entry_of "$CLAUDE_MD"
} > "$fixture_dir/moved.md"
reports "an entry outside the Code Standards section is reported" \
  "$(missing_from_rules "$fixture_dir/moved.md")" "no Code comments entry inside the Code Standards section"

grep -v -F -- 'No commented out code' "$CLAUDE_MD" > "$fixture_dir/one-rule-short.md" 2>/dev/null
reports "an entry missing one rule is reported by that rule" \
  "$(missing_from_rules "$fixture_dir/one-rule-short.md")" "no 'No commented out code'"

{ cat "$CLAUDE_MD" 2>/dev/null; printf '\n- **Code comments** said a second time.\n'; } > "$fixture_dir/twice.md"
reports "a second entry is reported" \
  "$(missing_from_rules "$fixture_dir/twice.md")" "times, not once"

printf '## Code Standards\n\n- **Code comments** (Dan, 2026-11-27). Give the reason \xe2\x80\x94 and leave out the story.\n' > "$fixture_dir/dash.md"
reports "an em dash in the entry is reported" \
  "$(missing_from_rules "$fixture_dir/dash.md")" "holds an em or en dash"

reports "a rules file that is not there is reported" \
  "$(missing_from_rules "$fixture_dir/absent.md")" "no Code comments entry inside the Code Standards section"

sed 's/^11\. /12. /' "$PROMPT" > "$fixture_dir/renumbered.txt" 2>/dev/null
reports "a renumbered item is reported" \
  "$(missing_from_prompt "$fixture_dir/renumbered.txt")" "no item 11 about a description"

# What the item asked before, with nothing about an added comment.
printf '11. A description that no longer matches the code: a comment that still describes what the change replaced. Search for every other place that describes the same behaviour.\n' > "$fixture_dir/old-item.txt"
old_gaps="$(missing_from_prompt "$fixture_dir/old-item.txt")"
reports "an item that asks only for a stale description is reported for the history" \
  "$old_gaps" "no 'tells the history of the change'"
reports "and for the count or list" \
  "$old_gaps" "no 'a count or a list of other code as fact'"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
