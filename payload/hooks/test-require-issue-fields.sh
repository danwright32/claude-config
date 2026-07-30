#!/usr/bin/env bash
# Tests for require-issue-fields.sh and issue_field_gate.py.
#
# The gate is pure string logic on the command about to run, so these tests need no
# network and no gh. Every case feeds a PreToolUse payload on stdin and asserts whether
# the hook denied.
#
# This replaced three suites (milestone, priority, category) that each re-tested the
# same command splitting. With one gate there is one place for that, so it is tested
# once here. Each RULE still gets its own isolated proof: in a rule's section the other
# two axes are satisfied, so only the rule under test can trigger a deny, and a failure
# names which rule broke rather than "something denied".
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-issue-fields.sh"

# A PATH holding a shell but no python3, used by the broken-gate test below.
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
mkdir -p "$TMP_DIR/bin"
for b in bash mktemp cat tr printf; do
  src="$(command -v "$b" 2>/dev/null)"
  [ -n "$src" ] && ln -sf "$src" "$TMP_DIR/bin/$b"
done
TMP_EMPTY_PATH="$TMP_DIR/bin"
TMP_ERR="$TMP_DIR/stderr.txt"

pass=0
fail=0

run() {
  printf '%s' "$1" | python3 -c '
import sys, json
json.dump({"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}, sys.stdout)
' | bash "$HOOK" 2>/dev/null
}
denies() {
  local out; out="$(run "$2")"
  if [[ "$out" == *'"deny"'* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (expected a deny, got: ${out:-<no output>})"; fi
}
allows() {
  local out; out="$(run "$2")"
  if [[ "$out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (expected no deny, got: $out)"; fi
}
says() { # says <description> <needle> <command>
  local out; out="$(run "$3")"
  if [[ "$out" == *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (message should contain '$2')"; fi
}
omits() { # omits <description> <needle> <command>
  local out; out="$(run "$3")"
  if [[ "$out" != *"$2"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1 (message should NOT contain '$2')"; fi
}

# Satisfy two axes so the third is the only thing that can fire.
M='--milestone "Ungrouped"'
P='--label priority-p2'
C='--label bug'
ALL="$M $P $C"

# ============================ a complete create passes ============================
allows "all three present"            "gh issue create --title \"T\" --body \"B\" $ALL"
allows "several categories at once"   "gh issue create --title \"T\" $M $P --label accessibility --label tech-debt --label ux"
allows "one comma list carries all"   'gh issue create --title "T" --milestone "Ungrouped" --label "bug,priority-p1"'
allows "short flags throughout"       'gh issue create --title "T" -m "Ungrouped" -l priority-p2 -l bug'
allows "attached short flag value"    'gh issue create --title "T" -m "Ungrouped" -lpriority-p2 -lbug'
allows "equals forms"                 'gh issue create --title "T" --milestone=Ungrouped --label=priority-p2 --label=bug'
allows "flags before the title"       "gh issue create $ALL --title \"T\""

# ============================ RULE: milestone ============================
denies "no milestone"                 "gh issue create --title \"T\" $P $C"
denies "empty milestone value"        "gh issue create --title \"T\" --milestone \"\" $P $C"
denies "milestone flag with no value" "gh issue create --title \"T\" $P $C --milestone"
denies "milestone followed by a flag" "gh issue create --title \"T\" --milestone $P $C"
allows "milestone by number"          "gh issue create --title \"T\" --milestone 4 $P $C"
denies "milestone in a later segment" "gh issue create --title \"T\" $P $C && echo --milestone Foo"
says   "names the milestone rule"     "a milestone" "gh issue create --title \"T\" $P $C"
says   "milestone fix names Ungrouped" "Ungrouped" "gh issue create --title \"T\" $P $C"
says   "milestone fix says FEATURE"   "FEATURE" "gh issue create --title \"T\" $P $C"
says   "milestone fix names the helper" "ensure-milestone.sh" "gh issue create --title \"T\" $P $C"
omits  "no priority advice when priority is fine" "priority-p3   nice to have" "gh issue create --title \"T\" $P $C"

# ============================ RULE: priority ============================
denies "no priority"                  "gh issue create --title \"T\" $M $C"
denies "other labels only"            "gh issue create --title \"T\" $M --label bug --label frontend"
allows "p0"                           "gh issue create --title \"T\" $M $C --label priority-p0"
allows "p1"                           "gh issue create --title \"T\" $M $C --label priority-p1"
allows "p3"                           "gh issue create --title \"T\" $M $C --label priority-p3"
allows "p4"                           "gh issue create --title \"T\" $M $C --label priority-p4"
allows "uppercase level"              "gh issue create --title \"T\" $M $C --label PRIORITY-P2"
denies "p5 is off the scale"          "gh issue create --title \"T\" $M $C --label priority-p5"
denies "double digit level"           "gh issue create --title \"T\" $M $C --label priority-p10"
denies "the bare word priority"       "gh issue create --title \"T\" $M --label priority"
denies "p2 without the prefix"        "gh issue create --title \"T\" $M --label p2"
denies "a level only in the title"    "gh issue create --title \"priority-p1 thing\" $M $C"
denies "a level only in the body"     "gh issue create --title \"T\" --body \"should be priority-p1\" $M $C"
says   "names the priority rule"      "a priority label" "gh issue create --title \"T\" $M $C"
says   "priority fix shows the scale" "broken now, drop everything" "gh issue create --title \"T\" $M $C"
says   "priority fix says who picks"  "AskUserQuestion" "gh issue create --title \"T\" $M $C"
says   "priority fix names the helper" "ensure-priority-labels.sh" "gh issue create --title \"T\" $M $C"
says   "priority fix retires severity" "sev-*" "gh issue create --title \"T\" $M $C"

# ============================ RULE: category ============================
denies "no category"                  "gh issue create --title \"T\" $M $P"
denies "priority only, equals form"   "gh issue create --title \"T\" $M --label=priority-p1"
denies "priority only, short flag"    "gh issue create --title \"T\" $M -l priority-p0"
denies "empty label value"            "gh issue create --title \"T\" $M $P --label \"\""
# The vocabulary is open, so the gate must accept a name it has never seen.
allows "a label nobody has used"      "gh issue create --title \"T\" $M $P --label wobbly-gizmo-behaviour"
allows "a label starting like a level" "gh issue create --title \"T\" $M $P --label priority-review"
allows "an off-scale level is a category" "gh issue create --title \"T\" $M --label priority-p2 --label priority-p9"
allows "a label containing a space"   'gh issue create --title "T" --milestone "Ungrouped" --label priority-p2 --label "help wanted"'
says   "names the category rule"      "a category label" "gh issue create --title \"T\" $M $P"
says   "category fix says read first" "gh label list" "gh issue create --title \"T\" $M $P"
says   "category fix says create one" "gh label create" "gh issue create --title \"T\" $M $P"
says   "category fix says many apply" "as many as genuinely apply" "gh issue create --title \"T\" $M $P"
says   "category fix says not fixed"  "not a fixed list" "gh issue create --title \"T\" $M $P"

# ============================ the combined message ============================
# The old design ran three gates, so a create missing everything reported whichever
# one happened to be seen first. One gate says it all at once.
says   "all three named together"     "a milestone, a priority label, a category label" 'gh issue create --title "T"'
says   "counts one issue"             "file 1 issue" 'gh issue create --title "T"'
says   "counts two issues"            "file 2 issues" 'gh issue create --title "A" && gh issue create --title "B"'
says   "lists all three overrides"    "SKIP_MILESTONE_CHECK=1 / SKIP_PRIORITY_CHECK=1 / SKIP_CATEGORY_CHECK=1" 'gh issue create --title "T"'
says   "points at the shared rule"    "NAMING.md" 'gh issue create --title "T"'
says   "only the failing override"    "SKIP_CATEGORY_CHECK=1 <the same command>" "gh issue create --title \"T\" $M $P"
omits  "no milestone advice when fine" "ensure-milestone.sh" "gh issue create --title \"T\" $M $P"

# ============================ overrides ============================
allows "milestone waived"             "SKIP_MILESTONE_CHECK=1 gh issue create --title \"T\" $P $C"
allows "priority waived"              "SKIP_PRIORITY_CHECK=1 gh issue create --title \"T\" $M $C"
allows "category waived"              "SKIP_CATEGORY_CHECK=1 gh issue create --title \"T\" $M $P"
# Each override waives ONE rule. Sharing them would let a single skip hide everything.
denies "one override does not waive the rest" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "T"'
denies "the wrong override for the rule" "SKIP_CATEGORY_CHECK=1 gh issue create --title \"T\" $P $C"
allows "all three waived together"    'SKIP_MILESTONE_CHECK=1 SKIP_PRIORITY_CHECK=1 SKIP_CATEGORY_CHECK=1 gh issue create --title "T"'
denies "override named only in the body" "gh issue create --title \"T\" --body \"SKIP_PRIORITY_CHECK=1\" $M $C"
# An override belongs to the ONE command it prefixes. Letting it cover the whole call
# is how a second unmilestoned create slipped past on 2026-07-29.
denies "override does not carry to the next segment" "SKIP_MILESTONE_CHECK=1 gh issue create --title \"A\" $P $C && gh issue create --title \"B\" $P $C"
denies "override on line 1 does not exempt line 3" "SKIP_MILESTONE_CHECK=1 gh issue create --title \"A\" $P $C
echo next
gh issue create --title \"B\" $P $C"

# ============================ commands that file nothing ============================
allows "help"                         'gh issue create --help'
allows "the short help flag"          'gh issue create -h'
allows "help after other flags"       'gh issue create --title "T" --help'
allows "help piped to a reader"       'gh issue create --help | grep label'
# --web hands off to the browser form, where the milestone and label pickers are on
# screen and a person completes the issue. gh files nothing itself.
allows "the browser form"             'gh issue create --web'
allows "the short web flag"           'gh issue create -w'
allows "web with prefilled flags"     'gh issue create --web --title "T" --body "B"'

# ============================ not an issue create ============================
allows "mention inside an echo"       'echo "then run gh issue create --title x"'
allows "mention inside a heredoc"     'cat > notes.md <<EOF
gh issue create --title "T"
EOF'
allows "quoted heredoc delimiter"     "cat > notes.md <<'EOF'
gh issue create --title \"T\"
EOF"
allows "issue edit"                   'gh issue edit 5 --add-label bug'
allows "issue list"                   'gh issue list --state open'
allows "pr create"                    'gh pr create --title "T" --body "B"'
allows "label create"                 'gh label create ux --color ededed'
allows "unrelated command"            'git status'
allows "empty command"                ''

# ============================ command splitting ============================
# One gate now, so this is tested once rather than three times.
denies "create via absolute path"     "/opt/homebrew/bin/gh issue create --title \"T\" $P $C"
denies "create after another command" "git status && gh issue create --title \"T\" $P $C"
allows "chained complete create"      "git status && gh issue create --title \"T\" $ALL"
denies "second of two creates"        "gh issue create --title \"A\" $ALL && gh issue create --title \"B\" $P $C"
denies "create on a later line"       "echo hello
gh issue create --title \"T\" $P $C"
allows "complete create on a later line" "echo hello
gh issue create --title \"T\" $ALL"
denies "create on line 3 after a pipe" "gh issue list | head -3
echo checking
gh issue create --title \"T\" $P $C"
allows "backslash continuation, complete" 'gh issue create --title "T" \
  --milestone "Ungrouped" \
  --label priority-p2 --label bug'
denies "backslash continuation, incomplete" 'gh issue create --title "T" \
  --label priority-p2 \
  --label bug'
allows "quoted multi-line body, complete" 'gh issue create --title "T" --body "line one
line two" --milestone "Ungrouped" --label priority-p2 --label bug'
denies "quoted multi-line body, incomplete" 'gh issue create --title "T" --body "line one
line two"'
denies "real create after a heredoc mentioning one" "cat > notes.md <<EOF
gh issue create --title \"documented example\"
EOF
gh issue create --title \"real one\" $P $C"
allows "heredoc mentioning a create, then an unrelated command" 'cat > notes.md <<EOF
gh issue create --title "T"
EOF
git status'

# ============================ failure paths ============================
for payload in 'not json at all' '{}' '{"tool_input":{}}'; do
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"
  if [[ "$out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: unreadable payload should fail quiet, got: $out"; fi
done
allows "unbalanced quotes are not ours to judge" 'gh issue create --title "unclosed'

# If the gate itself cannot run it must still let the command through, while making
# the gap visible: a gate that fails silently is indistinguishable from one that passed.
broken_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | PATH="$TMP_EMPTY_PATH" bash "$HOOK" 2>"$TMP_ERR")"
broken_err="$(cat "$TMP_ERR")"
if [[ "$broken_out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate should not block the command"; fi
if [[ "$broken_err" == *"ISSUE FIELD GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate should announce itself, got: ${broken_err:-<silence>}"; fi

# The gate and the scanner are separate files, so either can go missing on its own.
MOVED="$TMP_DIR/moved"; mkdir -p "$MOVED"
cp "$HOOK" "$MOVED/"
ns_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | bash "$MOVED/$(basename "$HOOK")" 2>"$TMP_ERR")"
ns_err="$(cat "$TMP_ERR")"
if [[ "$ns_out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing gate file should not block the command"; fi
if [[ "$ns_err" == *"ISSUE FIELD GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing gate file should announce itself, got: ${ns_err:-<silence>}"; fi

cp "$DIR/issue_field_gate.py" "$MOVED/"   # gate present, scanner still absent
nsc_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | bash "$MOVED/$(basename "$HOOK")" 2>"$TMP_ERR")"
nsc_err="$(cat "$TMP_ERR")"
if [[ "$nsc_out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing scanner should not block the command"; fi
if [[ "$nsc_err" == *"ISSUE FIELD GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing scanner should announce itself, got: ${nsc_err:-<silence>}"; fi

# ============================ the table is the extension point ============================
# The point of the refactor: a fourth rule is one entry, not a fourth copy of the hook.
rules_n="$(python3 -c "
import importlib.util, os
s = importlib.util.spec_from_file_location('g', '$DIR/issue_field_gate.py')
m = importlib.util.module_from_spec(s); os.environ['GATE_DIR'] = '$DIR'; s.loader.exec_module(m)
print(len(m.RULES))
print(all(set(r) >= {'name','check','fix','override'} for r in m.RULES))
")"
if [[ "$(printf '%s' "$rules_n" | head -1)" = "3" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: expected 3 rules in the table, got $(printf '%s' "$rules_n" | head -1)"; fi
if [[ "$(printf '%s' "$rules_n" | tail -1)" = "True" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: every rule needs a name, check, fix and override"; fi

# One process per Bash command, not three. This is why the refactor mattered beyond
# tidiness: the old design spawned three interpreters on EVERY command Claude ran.
hooks_registered="$(python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
n = [h['command'] for e in d['hooks']['PreToolUse'] for h in e['hooks'] if 'issue' in h['command']]
print(len(n)); print(n[0] if n else '')
" 2>/dev/null)"
if [[ "$(printf '%s' "$hooks_registered" | head -1)" = "1" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: exactly one issue gate should be registered, got $(printf '%s' "$hooks_registered" | head -1)"; fi
if [[ "$(printf '%s' "$hooks_registered" | tail -1)" == *"require-issue-fields.sh" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: the registered gate should be require-issue-fields.sh, got $(printf '%s' "$hooks_registered" | tail -1)"; fi

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
