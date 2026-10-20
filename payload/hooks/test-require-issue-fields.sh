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

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

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

# The session a create comes from is read from the environment Claude Code gives the hook
# (claude-config#536). Cleared by default, so the three field rules below are judged the same
# inside a session and in CI, and set explicitly only where the session line is what is tested.
# PAYLOAD_CWD, when set, is the working directory Claude Code reports for the command (the payload's
# cwd), which a relative --body-file is read against (claude-config#1416).
run() {
  printf '%s' "$1" | PAYLOAD_CWD="${PAYLOAD_CWD:-}" python3 -c '
import os, sys, json
payload = {"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}
if os.environ.get("PAYLOAD_CWD"):
    payload["cwd"] = os.environ["PAYLOAD_CWD"]
json.dump(payload, sys.stdout)
' | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_BRIDGE_SESSION_ID ${SESSION_ENV:-} bash "$HOOK" 2>/dev/null
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

# Satisfy the other rules so the one under test is the only thing that can fire.
M='--milestone "Ungrouped"'
P='--label priority-p2'
C='--label bug'
# The body's Open questions section (#1279), a body of its own: gh takes the last --body, and the
# gate reads the whole command, so every case below that is not about the section carries one.
Q='--body "## Open questions

None"'
ALL="$M $P $C $Q"

# ============================ a complete create passes ============================
allows "all four present"            "gh issue create --title \"T\" --body \"B\" $ALL"
allows "several categories at once"   "gh issue create --title \"T\" $M $P --label accessibility --label tech-debt --label ux $Q"
allows "one comma list carries all"   'gh issue create --title "T" --milestone "Ungrouped" --label "bug,priority-p1"'" $Q"
allows "short flags throughout"       'gh issue create --title "T" -m "Ungrouped" -l priority-p2 -l bug'" $Q"
allows "attached short flag value"    'gh issue create --title "T" -m "Ungrouped" -lpriority-p2 -lbug'" $Q"
allows "equals forms"                 'gh issue create --title "T" --milestone=Ungrouped --label=priority-p2 --label=bug'" $Q"
allows "flags before the title"       "gh issue create $ALL --title \"T\""

# ============================ RULE: milestone ============================
denies "no milestone"                 "gh issue create --title \"T\" $P $C"
# gh takes the subcommand's flags in front of it, and rtk, env or sudo can stand in front of gh
# (claude-config#1188): each is the same create, judged the same.
denies "#1188 -R in front, no milestone"        "gh -R o/x issue create --title \"T\" $P $C"
denies "#1188 -R between issue and create"      "gh issue -R o/x create --title \"T\" $P $C"
denies "#1188 --repo=x in front, behind rtk"    "rtk gh --repo=o/x issue create --title \"T\" $M $P"
denies "#1188 behind env with a setting"        "env GH_TOKEN=x gh issue create --title \"T\" $M $C"
denies "#1188 behind sudo"                      "sudo gh issue create --title \"T\" $P $C"
allows "#1188 -R in front, all three present"   "gh -R o/x issue create --title \"T\" $ALL"
allows "#1188 its --help files nothing"         "gh -R o/x issue create --help"
denies "empty milestone value"        "gh issue create --title \"T\" --milestone \"\" $P $C"
denies "milestone flag with no value" "gh issue create --title \"T\" $P $C --milestone"
denies "milestone followed by a flag" "gh issue create --title \"T\" --milestone $P $C"
allows "milestone by number"          "gh issue create --title \"T\" --milestone 4 $P $C $Q"
denies "milestone in a later segment" "gh issue create --title \"T\" $P $C && echo --milestone Foo"
says   "names the milestone rule"     "a milestone" "gh issue create --title \"T\" $P $C"
says   "milestone fix names Ungrouped" "Ungrouped" "gh issue create --title \"T\" $P $C"
says   "milestone fix says FEATURE"   "FEATURE" "gh issue create --title \"T\" $P $C"
says   "milestone fix names the helper" "ensure-milestone.sh" "gh issue create --title \"T\" $P $C"
omits  "no priority advice when priority is fine" "priority-p3   nice to have" "gh issue create --title \"T\" $P $C"

# ============================ RULE: priority ============================
denies "no priority"                  "gh issue create --title \"T\" $M $C"
denies "other labels only"            "gh issue create --title \"T\" $M --label bug --label frontend"
allows "p0"                           "gh issue create --title \"T\" $M $C --label priority-p0 $Q"
allows "p1"                           "gh issue create --title \"T\" $M $C --label priority-p1 $Q"
allows "p3"                           "gh issue create --title \"T\" $M $C --label priority-p3 $Q"
allows "p4"                           "gh issue create --title \"T\" $M $C --label priority-p4 $Q"
allows "uppercase level"              "gh issue create --title \"T\" $M $C --label PRIORITY-P2 $Q"
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
allows "a label nobody has used"      "gh issue create --title \"T\" $M $P --label wobbly-gizmo-behaviour $Q"
allows "a label starting like a level" "gh issue create --title \"T\" $M $P --label priority-review $Q"
allows "an off-scale level is a category" "gh issue create --title \"T\" $M --label priority-p2 --label priority-p9 $Q"
allows "a label containing a space"   'gh issue create --title "T" --milestone "Ungrouped" --label priority-p2 --label "help wanted"'" $Q"
says   "names the category rule"      "a category label" "gh issue create --title \"T\" $M $P"
says   "category fix says read first" "gh label list" "gh issue create --title \"T\" $M $P"
says   "category fix says create one" "gh label create" "gh issue create --title \"T\" $M $P"
says   "category fix says many apply" "as many as genuinely apply" "gh issue create --title \"T\" $M $P"
says   "category fix says not fixed"  "not a fixed list" "gh issue create --title \"T\" $M $P"

# ============================ the combined message ============================
# The old design ran three gates, so a create missing everything reported whichever
# one happened to be seen first. One gate says all four rules at once.
says   "all four named together"      "a milestone, a priority label, a category label, an Open questions section" 'gh issue create --title "T"'
says   "counts one issue"             "file 1 issue" 'gh issue create --title "T"'
says   "counts two issues"            "file 2 issues" 'gh issue create --title "A" && gh issue create --title "B"'
says   "lists all four overrides"     "SKIP_MILESTONE_CHECK=1 / SKIP_PRIORITY_CHECK=1 / SKIP_CATEGORY_CHECK=1 / SKIP_OPEN_QUESTIONS_CHECK=1 <the same command>" 'gh issue create --title "T"'
says   "points at the shared rule"    "NAMING.md" 'gh issue create --title "T"'
says   "only the failing override"    "SKIP_CATEGORY_CHECK=1 <the same command>" "gh issue create --title \"T\" $M $P $Q"
omits  "no milestone advice when fine" "ensure-milestone.sh" "gh issue create --title \"T\" $M $P"

# ============================ overrides ============================
allows "milestone waived"             "SKIP_MILESTONE_CHECK=1 gh issue create --title \"T\" $P $C $Q"
allows "priority waived"              "SKIP_PRIORITY_CHECK=1 gh issue create --title \"T\" $M $C $Q"
allows "category waived"              "SKIP_CATEGORY_CHECK=1 gh issue create --title \"T\" $M $P $Q"
# Each override waives ONE rule. Sharing them would let a single skip hide everything.
denies "one override does not waive the rest" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "T"'
denies "the wrong override for the rule" "SKIP_CATEGORY_CHECK=1 gh issue create --title \"T\" $P $C"
allows "the three field rules waived together"    'SKIP_MILESTONE_CHECK=1 SKIP_PRIORITY_CHECK=1 SKIP_CATEGORY_CHECK=1 gh issue create --title "T"'" $Q"
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
denies "create on line 3 after a pipe" "gh issue list | awk 'NR <= 3'
echo checking
gh issue create --title \"T\" $P $C"
allows "backslash continuation, complete" 'gh issue create --title "T" \
  --milestone "Ungrouped" \
  --label priority-p2 --label bug'" $Q"
denies "backslash continuation, incomplete" 'gh issue create --title "T" \
  --label priority-p2 \
  --label bug'
allows "quoted multi-line body, complete" 'gh issue create --title "T" --body "line one
line two" --milestone "Ungrouped" --label priority-p2 --label bug'" $Q"
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
# The point of the refactor: a new rule is one entry, not another copy of the hook. The Open
# questions section (#1279) is the fourth, in the table like the rest.
rules_n="$(python3 -c "
import importlib.util, os
s = importlib.util.spec_from_file_location('g', '$DIR/issue_field_gate.py')
m = importlib.util.module_from_spec(s); os.environ['GATE_DIR'] = '$DIR'; s.loader.exec_module(m)
print(len(m.RULES))
print(all(set(r) >= {'name','check','fix','override'} for r in m.RULES))
")"
# A fifth since #1416: a body file the gate can read.
if [[ "$(printf '%s' "$rules_n" | awk 'NR <= 1')" = "5" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: expected 5 rules in the table, got $(printf '%s' "$rules_n" | awk 'NR <= 1')"; fi
if [[ "$(printf '%s' "$rules_n" | tail -1)" = "True" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: every rule needs a name, check, fix and override"; fi

# One process per Bash command, not three. This is why the refactor mattered beyond
# tidiness: the old design spawned three interpreters on EVERY command Claude ran.
# These two ask about the INSTALLED config on this machine, not about the code in this
# repository, so they can only be answered where a config is installed. On a CI runner there is
# no ~/.claude at all, and asserting there produced two failures that said nothing about the
# change under test. They SKIP with a reason rather than passing quietly, because a check that
# was never run must not be counted as one that passed (L98).
if [ -f "$HOME/.claude/settings.json" ]; then
hooks_registered="$(python3 -c "
import json
d = json.load(open('$HOME/.claude/settings.json'))
import os, re
# The issue gate and the three it replaced, by FILE NAME. A substring like 'issue' also matches
# every unrelated hook that merely has the word in its name (check-doc-issue-refs.sh arrived with
# #446 and turned this red on every Mac with a config installed, L178).
gate = re.compile(r'^require-(issue-fields|(milestone|priority|category)-on-issue)\\.sh$')
n = [h['command'] for e in d['hooks']['PreToolUse'] for h in e['hooks']
     if gate.match(os.path.basename(h['command'].split()[-1].strip('\"\\'')))]
print(len(n)); print(n[0] if n else '')
" 2>/dev/null)"
if [[ "$(printf '%s' "$hooks_registered" | awk 'NR <= 1')" = "1" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: exactly one issue gate should be registered, got $(printf '%s' "$hooks_registered" | awk 'NR <= 1')"; fi
if [[ "$(printf '%s' "$hooks_registered" | tail -1)" == *"require-issue-fields.sh" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: the registered gate should be require-issue-fields.sh, got $(printf '%s' "$hooks_registered" | tail -1)"; fi
else
  echo "SKIPPED (2 checks): there is no installed config at $HOME/.claude/settings.json, so which hooks are registered on this machine cannot be checked from here."
fi

# ---------------------------------------------------------------------------
# The Open questions section (#1279, Dan 2026-10-17): every issue's body holds one, listing what only
# Dan can decide, or None, so /sleep can ask each before the night begins. A heading is what counts:
# the words in a sentence are not a section.
# ---------------------------------------------------------------------------
denies "#1279 a body with no Open questions section is refused" "gh issue create --title t --body b $M $P $C"
says "#1279 naming what is missing" "an Open questions section" "gh issue create --title t --body b $M $P $C"
says "#1279 and saying None is enough" "write None under it" "gh issue create --title t --body b $M $P $C"
denies "#1279 a create with no body at all is refused" "gh issue create --title t $M $P $C"
allows "#1279 the section with None passes" "gh issue create --title t --body \"b

## Open questions

None\" $M $P $C"
allows "#1279 a section listing questions passes, at any heading level" "gh issue create --title t --body \"b

### Open questions
- [ ] Keep the old flag?\" $M $P $C"
denies "#1279 a heading that only starts with the words is another section (lessons review)" "gh issue create --title t --body \"b

## Open questions about the API
- [ ] Keep it?\" $M $P $C"
allows "#1279 the heading written in an ANSI quoted body passes" "gh issue create --title t --body \$'b\\n\\n## Open questions\\n\\nNone' $M $P $C"
denies "#1279 the words in a sentence are not a section" "gh issue create --title t --body \"b, with no open questions.\" $M $P $C"
allows "#1279 the section in a heredoc body passes" "gh issue create --title t $M $P $C --body \"\$(cat <<'EOF'
b

## Open questions

None
EOF
)\""
QF="$TMP_DIR/q-body.md"
printf 'b\n\n## Open questions\n\nNone\n' > "$QF"
allows "#1279 a body file holding the section passes" "gh issue create --title t --body-file $QF $M $P $C"
printf 'b\n' > "$QF"
denies "#1279 a body file without it is refused" "gh issue create --title t --body-file $QF $M $P $C"
allows "#1279 the section has its own visible override" "SKIP_OPEN_QUESTIONS_CHECK=1 gh issue create --title t --body b $M $P $C"
denies "#1279 and that override waives nothing else" "SKIP_OPEN_QUESTIONS_CHECK=1 gh issue create --title t --body b $M $C"

# #1320: a line inside a fenced code block is code, never the section's heading. Judged first on the
# one committed set of cases mod-kit's reader is held to as well (mods/mod-kit/tests/
# openquestions-fixtures.ts, L26), each body as a body file through the gate's own reader, then end to
# end on the ways a body is spelled in a command. The count first, so a set read as empty cannot pass.
FENCE_FIXTURES="$DIR/../mods/mod-kit/tests/openquestions-fixtures.ts"
fence_out="$(sed -n '/^export const FENCE_FIXTURES = /,$p' "$FENCE_FIXTURES" | sed '1s/^export const FENCE_FIXTURES = //' |
  GATE="$DIR/issue_field_gate.py" WORK="$TMP_DIR" python3 -c '
import importlib.util, json, os, sys
s = importlib.util.spec_from_file_location("gate", os.environ["GATE"])
g = importlib.util.module_from_spec(s)
s.loader.exec_module(g)
cases = json.load(sys.stdin)
print("COUNT %d" % len(cases))
for i, c in enumerate(cases):
    p = os.path.join(os.environ["WORK"], "fence%d.md" % i)
    with open(p, "w", newline="") as f:
        f.write(c["body"])
    got = g.has_open_questions(["--body-file", p], "gh issue create --body-file " + p)
    print("%s %s (found %s, expected %s)" % ("ok" if got == c["found"] else "BAD", c["name"], got, c["found"]))
' 2>&1)"
fence_count="$(printf '%s\n' "$fence_out" | sed -n 's/^COUNT //p')"
# Every case the file holds, counted from its text by a second route, so a read that drops some
# cannot pass (lessons review); and never none, so an empty file cannot either.
fence_cases="$(grep -c '"name":' "$FENCE_FIXTURES")"
if [[ "${fence_cases:-0}" -gt 0 && "${fence_count:-}" == "$fence_cases" ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: #1320 all ${fence_cases:-0} shared fence cases were read (got ${fence_count:-none}: $fence_out)"; fi
while IFS= read -r line; do
  case "$line" in
    ok\ *) pass=$((pass + 1)) ;;
    BAD\ *) fail=$((fail + 1)); echo "FAIL: #1320 shared case: ${line#BAD }" ;;
  esac
done <<<"$fence_out"

denies "#1320 a heredoc body whose only heading is fenced is refused" "gh issue create --title t $M $P $C --body \"\$(cat <<'EOF'
b

\`\`\`md
## Open questions
None
\`\`\`
EOF
)\""
allows "#1320 a heredoc body with a fenced example and the real section passes" "gh issue create --title t $M $P $C --body \"\$(cat <<'EOF'
b

\`\`\`md
## Open questions
\`\`\`

## Open questions

None
EOF
)\""
denies "#1320 an ANSI quoted body whose only heading is fenced is refused" "gh issue create --title t --body \$'b\\n\\n\`\`\`\\n## Open questions\\nNone\\n\`\`\`' $M $P $C"
denies "#1320 a double quoted body with escaped backtick fences is refused" "gh issue create --title t --body \"b

\\\`\\\`\\\`
## Open questions
None
\\\`\\\`\\\`\" $M $P $C"
# Lessons review: a body's last fenced line carries the closing quote (```' or ```"), so in the
# command text that fence never closes. Only what follows the body's closing quote is then read as
# code, which is no part of the body, and the other rules read the parsed arguments, so the verdict
# is unchanged: a real section before the closing fence still passes, and the other fields still count.
allows "#1320 an ANSI quoted body ending in a fenced block, its section before it, passes" "gh issue create --title t --body \$'b\\n\\n## Open questions\\n\\nNone\\n\\n\`\`\`\\nx\\n\`\`\`' $M $P $C"
allows "#1320 a double quoted body ending in a fenced block, its section before it, passes" "gh issue create --title t --body \"b

## Open questions

None

\\\`\\\`\\\`
x
\\\`\\\`\\\`\" $M $P $C"
denies "#1320 and a body ending in a fence still needs its milestone" "gh issue create --title t --body \$'b\\n\\n## Open questions\\n\\nNone\\n\\n\`\`\`\\nx\\n\`\`\`' $P $C"
allows "#1320 a section in a later argument, after a body ending in a fence, is still found in the parsed arguments" "gh issue create --title t --body \$'b\\n\`\`\`\\nx\\n\`\`\`' --body \"## Open questions

None\" $M $P $C"

# ---------------------------------------------------------------------------
# The session that filed it (claude-config#536). Three sessions worked one repo on 2026-09-21 and
# one sent a warning to the wrong session, because nothing on a filed issue says who filed it.
# Commits and pull requests already carry a Claude-Session line; a create now has to as well, and
# the refusal names the exact line, read from the environment Claude Code gives every hook.
# ---------------------------------------------------------------------------
ALL="$M $P $C $Q"
SESSION_ENV="CLAUDE_CODE_BRIDGE_SESSION_ID=session_01AbCdEf CLAUDE_CODE_SESSION_ID=11111111-2222-3333-4444-555555555555"
denies "#536 a create with no session line is refused inside a session" "gh issue create --title t --body b $ALL"
says "#536 and the refusal names the exact line, as a link" "Claude-Session: https://claude.ai/code/session_01AbCdEf" "gh issue create --title t --body b $ALL"
allows "#536 a body carrying the session line passes" "gh issue create --title t --body \"b

Claude-Session: https://claude.ai/code/session_01AbCdEf\" $ALL"
allows "#536 the line in a heredoc body passes too" "gh issue create --title t $ALL --body \"\$(cat <<'EOF'
b

Claude-Session: https://claude.ai/code/session_01AbCdEf
EOF
)\""
BODYF="$TMP_DIR/body.md"
printf 'b\n\nClaude-Session: https://claude.ai/code/session_01AbCdEf\n' > "$BODYF"
allows "#536 a body file carrying the line passes" "gh issue create --title t --body-file $BODYF $ALL"
printf 'b\n' > "$BODYF"
denies "#536 a body file without the line is refused" "gh issue create --title t --body-file $BODYF $ALL"
# A body file the same command writes (claude-config#1246). The gate runs before the command does, so
# the file is not there yet, or holds an older body, and reading the disk let #1242 through with no
# line. When the command writes the file from text it shows (a heredoc, echo, printf), that text is
# the body, and the line is in it only if it is somewhere in the command.
NEWF="$TMP_DIR/written-by-the-command.md"
denies "#1246 a heredoc written body file without the line is refused" "cat > $NEWF <<'EOF'
b
EOF
gh issue create --title t --body-file $NEWF $ALL"
allows "#1246 a heredoc written body file carrying the line passes" "cat > $NEWF <<'EOF'
b

Claude-Session: https://claude.ai/code/session_01AbCdEf
EOF
gh issue create --title t --body-file $NEWF $ALL"
denies "#1246 the redirect may follow the heredoc opener" "cat <<'EOF' > $NEWF
b
EOF
gh issue create --title t --body-file $NEWF $ALL"
denies "#1246 a body file written by printf without the line is refused" "printf 'b\n' > $NEWF && gh issue create --title t --body-file $NEWF $ALL"
denies "#1246 a body file written by echo without the line is refused" "echo b > \"$NEWF\"; gh issue create --title t -F $NEWF $ALL"
denies "#1246 a body file written by tee from a heredoc is refused" "tee $NEWF >/dev/null <<'EOF'
b
EOF
gh issue create --title t --body-file $NEWF $ALL"
printf 'b\n\nClaude-Session: https://claude.ai/code/session_01AbCdEf\n' > "$BODYF"
denies "#1246 an older body on disk does not answer for the one the command writes over it" "cat > $BODYF <<'EOF'
b
EOF
gh issue create --title t --body-file $BODYF $ALL"
allows "#1246 text appended to a body that carries the line keeps it" "echo more >> $BODYF && gh issue create --title t --body-file $BODYF $ALL"
printf 'b\n' > "$BODYF"
denies "#1246 text appended to a body without the line does not add it" "echo more >> $BODYF && gh issue create --title t --body-file $BODYF $ALL"
# What the gate cannot see the text of, it does not judge: the line can come from a script, a
# substitution or a variable, and a refusal there would be a false block.
allows "#1246 a body file a script writes is not judged" "bash make-body.sh > $NEWF && gh issue create --title t --body-file $NEWF $ALL"
allows "#1246 a heredoc that expands a substitution is not judged" "cat > $NEWF <<EOF
b

\$(bash ~/.claude/hooks/lib/claude-session-line.sh)
EOF
gh issue create --title t --body-file $NEWF $ALL"
allows "#1246 printf of a variable is not judged" "printf '%s\n' \"\$BODY\" > $NEWF && gh issue create --title t --body-file $NEWF $ALL"
# Reversed by claude-config#1416: a body file nothing in the command writes and the gate cannot read
# is refused, naming the path, rather than passed. gh cannot file from it either.
denies "#1416 a body file nothing in the command writes, and that does not exist, is refused" "gh issue create --title t --body-file $TMP_DIR/never-written.md $ALL"
# A body read from standard input is judged by the command text alone, as it always was: the
# line has to be in the text the command pipes or feeds in.
denies "#1246 a heredoc body on standard input without the line is refused" "gh issue create --title t -F - $ALL <<'EOF'
b
EOF"
denies "#1246 a body piped in from printf without the line is refused" "printf 'b\n' | gh issue create --title t --body-file - $ALL"
# The attached spellings name standard input too, and are judged the same way, not as a file
# called "-" that cannot be opened (lessons review of #1260).
denies "#1246 --body-file=- is standard input, judged by the command text" "printf 'b\n' | gh issue create --title t --body-file=- $ALL"
denies "#1246 -F- is standard input, judged by the command text" "printf 'b\n' | gh issue create --title t -F- $ALL"
allows "#1246 --body-file=- with the line in the piped text passes" "printf 'b\n\nClaude-Session: https://claude.ai/code/session_01AbCdEf\n' | gh issue create --title t --body-file=- $ALL"
allows "#1246 a heredoc body on standard input carrying the line passes" "gh issue create --title t -F - $ALL <<'EOF'
b

Claude-Session: https://claude.ai/code/session_01AbCdEf
EOF"
allows "#536 the line has its own visible override" "SKIP_SESSION_LINE_CHECK=1 gh issue create --title t --body b $ALL"
denies "#536 and that override waives nothing else" "SKIP_SESSION_LINE_CHECK=1 gh issue create --title t --body b $M $C"
# A session with no claude.ai link is named by its local id, which is what Claude Code gives every
# hook, measured 2026-09-23 on a headless run.
SESSION_ENV="CLAUDE_CODE_SESSION_ID=11111111-2222-3333-4444-555555555555"
says "#536 with no link the local session id is the line" "Claude-Session: local 11111111-2222-3333-4444-555555555555" "gh issue create --title t --body b $ALL"
# A value that is not the shape of an id is not repeated into a filed issue.
SESSION_ENV="CLAUDE_CODE_SESSION_ID=not-an-id"
allows "#536 with no usable session identity the rule stands down rather than guess" "gh issue create --title t --body b $ALL"
SESSION_ENV=""
allows "#536 outside a session (CI, a plain shell) the rule does not apply" "gh issue create --title t --body b $ALL"

# ---------------------------------------------------------------------------
# A body file the gate cannot read (claude-config#1416). Try-Pennie/slate#3924 and #3925 were filed
# with a body holding only the session line, from --body-file "$D/i7.md" in a Bash call where $D was
# never set (variables do not carry between calls), and the gate passed it because it fails open on
# a file it cannot open. A path naming a variable this command does not set, a file that does not
# exist, and an empty file are each refused now, naming the path as the gate saw it and why. The
# other three fields are satisfied and the body carries no section in the command, so a refusal here
# is the body file's.
# ---------------------------------------------------------------------------
FC="$M $P $C"
U='$ISSUE1416_UNSET_DIR'   # a variable nothing sets, written as the command spells it
mkdir -p "$TMP_DIR/sub"
GOOD="$TMP_DIR/good.md"
printf 'b\n\n## Open questions\n\nNone\n' > "$GOOD"
EMPTYF="$TMP_DIR/empty.md"
: > "$EMPTYF"
BLANKF="$TMP_DIR/blank.md"
printf '  \n\n' > "$BLANKF"
denies "#1416 a path through a variable this command never sets is refused" "gh issue create --title t --body-file \"$U/i7.md\" $FC"
says "#1416 naming the path as the gate saw it" "$U/i7.md" "gh issue create --title t --body-file \"$U/i7.md\" $FC"
says "#1416 and saying the variable is not set in this command" "ISSUE1416_UNSET_DIR is not set in this command" "gh issue create --title t --body-file \"$U/i7.md\" $FC"
says "#1416 in the one message beside the gate's other refusals" "a milestone, a body file it can read" "gh issue create --title t --body-file \"$U/i7.md\" $P $C"
denies "#1416 the braced spelling is the same variable" "gh issue create --title t --body-file \"\${ISSUE1416_UNSET_DIR}/i7.md\" $FC"
denies "#1416 --body-file=path is the same flag" "gh issue create --title t --body-file=\"$U/i7.md\" $FC"
denies "#1416 -F path is the same flag" "gh issue create --title t -F \"$U/i7.md\" $FC"
denies "#1416 -Fpath is the same flag" "gh issue create --title t -F\"$U/i7.md\" $FC"
# A variable the same command sets before the create is the value the shell will use.
allows "#1416 a variable set earlier in the same command is followed" "D=$TMP_DIR; gh issue create --title t --body-file \"\$D/good.md\" $FC"
allows "#1416 an exported one too" "export D=$TMP_DIR && gh issue create --title t --body-file \"\$D/good.md\" $FC"
allows "#1416 one set from another variable the command set" "A=$TMP_DIR; D=\"\$A\"; gh issue create --title t --body-file \"\$D/good.md\" $FC"
denies "#1416 a variable set earlier, naming a file that does not exist, is refused" "D=$TMP_DIR; gh issue create --title t --body-file \"\$D/missing.md\" $FC"
says "#1416 and says the file does not exist, with the path as the shell would read it" "$TMP_DIR/missing.md does not exist" "D=$TMP_DIR; gh issue create --title t --body-file \"\$D/missing.md\" $FC"
# The shell expands a create's arguments before an assignment in front of that create applies.
denies "#1416 an assignment prefixed to the create itself does not reach its arguments" "D=$TMP_DIR gh issue create --title t --body-file \"\$D/good.md\" $FC"
# An assignment in a subshell ends with it.
denies "#1416 an assignment inside a subshell does not outlive it" "(D=$TMP_DIR); gh issue create --title t --body-file \"\$D/good.md\" $FC"
# A variable set from something only running the command can tell, with no write here to judge.
denies "#1416 a variable set from a command substitution, file not written here, is refused" "D=\$(mktemp -d); gh issue create --title t --body-file \"\$D/b.md\" $FC"
says "#1416 and says the gate cannot read what it was set to" "D is set in this command from something the gate cannot read" "D=\$(mktemp -d); gh issue create --title t --body-file \"\$D/b.md\" $FC"
denies "#1416 a path holding a command substitution is refused" "gh issue create --title t --body-file \"\$(git rev-parse --show-toplevel)/b.md\" $FC"
# But a body file the command itself writes is still judged from the command (#1246), however its
# path is spelled, since the file is the one the command makes.
allows "#1416 a file under an unresolvable variable, written by this command from shown text, is judged from the text" "D=\$(mktemp -d); cat > \"\$D/b.md\" <<'EOF'
b

## Open questions

None
EOF
gh issue create --title t --body-file \"\$D/b.md\" $FC"
denies "#1416 and the same without the section is refused for the section, not the file" "D=\$(mktemp -d); cat > \"\$D/b.md\" <<'EOF'
b
EOF
gh issue create --title t --body-file \"\$D/b.md\" $FC"
omits "#1416 the file rule does not fire on a file the command writes" "a body file it can read" "D=\$(mktemp -d); cat > \"\$D/b.md\" <<'EOF'
b
EOF
gh issue create --title t --body-file \"\$D/b.md\" $FC"
# A variable the command fills in as it runs (a for or read loop's, a function's \$1) has no value
# the gate can know, but the files it could name can be looked for. Measured on 2026-10-20 across
# every past create with a body file in this Mac's transcripts: 4 of about 400 used one of these
# shapes, each a real filing loop. One of them passes while some non-empty file matches, and is
# refused when none could.
allows "#1416 a for loop's variable naming files that exist passes" "for k in good; do gh issue create --title t --body-file \"$TMP_DIR/\$k.md\" $FC; done"
allows "#1416 a read loop's variable too" "printf 'good\n' | while IFS=\$'\t' read -r k t; do gh issue create --title t --body-file \"$TMP_DIR/\$k.md\" $FC; done"
allows "#1416 a function's positional parameter too" "f() { gh issue create --title \"\$1\" --body-file \"$TMP_DIR/\$2.md\" $FC; }
f T good"
denies "#1416 a loop variable no file could match is refused" "for k in a b; do gh issue create --title t --body-file \"$TMP_DIR/nothing-\$k.md\" $FC; done"
says "#1416 and says no file matches, showing the pattern" "no file matches $TMP_DIR/nothing-*.md" "for k in a b; do gh issue create --title t --body-file \"$TMP_DIR/nothing-\$k.md\" $FC; done"
mkdir -p "$TMP_DIR/only-empty"
: > "$TMP_DIR/only-empty/e.md"
denies "#1416 a pattern only an empty file matches is refused" "for k in e; do gh issue create --title t --body-file \"$TMP_DIR/only-empty/\$k.md\" $FC; done"
# Home: ~ and \$HOME read as the shell would, from the environment the gate is given.
SESSION_ENV="HOME=$TMP_DIR"
allows "#1416 ~ is home" "gh issue create --title t --body-file ~/good.md $FC"
allows "#1416 \$HOME is home" "gh issue create --title t --body-file \"\$HOME/good.md\" $FC"
allows "#1416 \${HOME} is home" "gh issue create --title t --body-file \"\${HOME}/good.md\" $FC"
denies "#1416 a file missing from home is refused" "gh issue create --title t --body-file \"\$HOME/missing.md\" $FC"
SESSION_ENV=""
# Present but empty: gh would file a blank body.
denies "#1416 an empty body file is refused" "gh issue create --title t --body-file $EMPTYF $FC"
says "#1416 and says it is empty" "$EMPTYF is empty" "gh issue create --title t --body-file $EMPTYF $FC"
denies "#1416 a body file of only blank lines is refused as empty" "gh issue create --title t --body-file $BLANKF $FC"
says "#1416 a missing literal path says it does not exist" "$TMP_DIR/never-written.md does not exist" "gh issue create --title t --body-file $TMP_DIR/never-written.md $FC"
# A readable file holding the section passes, as it always did.
allows "#1416 a readable body file passes" "gh issue create --title t --body-file $GOOD $FC"
# Relative paths are read against the command's working directory, which Claude Code reports in the
# payload, and against any cd the command makes before the create.
PAYLOAD_CWD="$TMP_DIR"
allows "#1416 a relative path is read against the command's working directory" "gh issue create --title t --body-file good.md $FC"
allows "#1416 ./ too" "gh issue create --title t --body-file ./good.md $FC"
PAYLOAD_CWD="$TMP_DIR/sub"
denies "#1416 a relative path missing from the working directory is refused" "gh issue create --title t --body-file good.md $FC"
says "#1416 and names where it looked" "$TMP_DIR/sub/good.md does not exist" "gh issue create --title t --body-file good.md $FC"
allows "#1416 ../ from the working directory" "gh issue create --title t --body-file ../good.md $FC"
PAYLOAD_CWD="/"
allows "#1416 a cd earlier in the command moves where a relative path is read" "cd $TMP_DIR && gh issue create --title t --body-file good.md $FC"
allows "#1416 a relative cd from the working directory" "cd ${TMP_DIR#/} && gh issue create --title t --body-file good.md $FC"
allows "#1416 a cd through a variable the command set" "D=$TMP_DIR; cd \"\$D\"; gh issue create --title t --body-file good.md $FC"
denies "#1416 a cd to a directory without the file is refused" "cd $TMP_DIR/sub && gh issue create --title t --body-file good.md $FC"
denies "#1416 a cd inside a subshell does not move the create after it" "(cd $TMP_DIR) && gh issue create --title t --body-file good.md $FC"
denies "#1416 a cd the gate cannot follow leaves a relative path unresolved" "cd - && gh issue create --title t --body-file good.md $FC"
allows "#1416 an absolute path does not depend on a cd the gate cannot follow" "cd - && gh issue create --title t --body-file $GOOD $FC"
PAYLOAD_CWD=""
# Standard input is judged by the command text, as it always was (#1246), never as a file called -.
allows "#1416 -F - with the section on standard input still passes" "gh issue create --title t -F - $FC <<'EOF'
b

## Open questions

None
EOF"
omits "#1416 and standard input is never a body file it cannot read" "a body file it can read" "printf 'b\n' | gh issue create --title t --body-file=- $FC"
# Two creates in one command: each unreadable path is named once, in the one message.
says "#1416 both creates' paths are named" "$TMP_DIR/never-written.md does not exist" "gh issue create --title a --body-file \"$U/i7.md\" $FC && gh issue create --title b --body-file $TMP_DIR/never-written.md $FC"
says "#1416 and the first one too" "$U/i7.md" "gh issue create --title a --body-file \"$U/i7.md\" $FC && gh issue create --title b --body-file $TMP_DIR/never-written.md $FC"
# Its own visible override, waiving only this rule.
allows "#1416 the rule has its own visible override" "SKIP_BODY_FILE_CHECK=1 gh issue create --title t --body-file \"$U/i7.md\" $FC"
denies "#1416 and that override waives nothing else" "SKIP_BODY_FILE_CHECK=1 gh issue create --title t --body-file \"$U/i7.md\" $P $C"
# gh issue edit and gh pr create are not issue creates, and this gate has never judged them.
allows "#1416 gh issue edit is not judged here" "gh issue edit 5 --body-file \"$U/i7.md\""
allows "#1416 gh pr create is not judged here" "gh pr create --title t --body-file \"$U/i7.md\""

# The shared line maker, which the milestone and discussion scripts use too, so one spelling of the
# line exists (L41).
LINE_LIB="$DIR/lib/claude-session-line.sh"
got="$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_CODE_BRIDGE_SESSION_ID=session_01AbCdEf bash "$LINE_LIB" 2>/dev/null)"
[ "$got" = "Claude-Session: https://claude.ai/code/session_01AbCdEf" ] && pass=$((pass + 1)) || { fail=$((fail + 1)); echo "FAIL: #536 the line maker prints the link line (got [$got])"; }
env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_BRIDGE_SESSION_ID bash "$LINE_LIB" >/dev/null 2>&1 \
  && { fail=$((fail + 1)); echo "FAIL: #536 the line maker exits non zero with no session"; } || pass=$((pass + 1))
for script in "$DIR/../skills/milestone/create-milestone.sh" "$DIR/../skills/plan-council/post-discussion.sh"; do
  if grep -q 'claude-session-line.sh' "$script"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: #536 $(basename "$script") files issues without the session line"; fi
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
