#!/usr/bin/env bash
# Tests for require-priority-on-issue.sh.
#
# The gate is pure string logic on the command about to run, so these tests need
# no network and no gh. Every case feeds a PreToolUse payload on stdin and asserts
# whether the hook denied.
#
# The command-splitting cases here deliberately repeat the milestone gate's, since
# both gates read the same shared scanner: a regression in the scanner has to show
# up in both suites, not just one.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-priority-on-issue.sh"

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

# run <command-string> -> prints the hook's stdout
run() {
  printf '%s' "$1" | python3 -c '
import sys, json
json.dump({"tool_name": "Bash", "tool_input": {"command": sys.stdin.read()}}, sys.stdout)
' | bash "$HOOK" 2>/dev/null
}

denies() { # denies <description> <command>
  local out
  out="$(run "$2")"
  if [[ "$out" == *'"deny"'* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected a deny, got: ${out:-<no output>})"
  fi
}

allows() { # allows <description> <command>
  local out
  out="$(run "$2")"
  if [[ "$out" != *'"deny"'* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 (expected no deny, got: $out)"
  fi
}

# --- the core rule: a create with no priority label is blocked ---
denies "bare create" 'gh issue create --title "Fix thing" --body "why"'
denies "create with a milestone but no priority" 'gh issue create --title "T" --milestone "Accessibility"'
denies "create with other labels only" 'gh issue create --title "T" --label bug --label frontend'
denies "create via absolute path to gh" '/opt/homebrew/bin/gh issue create --title "T"'

# --- every level counts, and every flag form is understood ---
allows "p0 long flag" 'gh issue create --title "T" --label priority-p0'
allows "p1 long flag" 'gh issue create --title "T" --label priority-p1'
allows "p2 long flag" 'gh issue create --title "T" --label priority-p2'
allows "p3 long flag" 'gh issue create --title "T" --label priority-p3'
allows "p4 long flag" 'gh issue create --title "T" --label priority-p4'
allows "equals form" 'gh issue create --title "T" --label=priority-p2'
allows "short flag" 'gh issue create --title "T" -l priority-p2'
allows "short flag attached value" 'gh issue create --title "T" -lpriority-p2'
allows "comma list, priority last" 'gh issue create --title "T" --label "bug,frontend,priority-p1"'
allows "comma list with spaces" 'gh issue create --title "T" --label "bug, priority-p1"'
allows "repeated label flags" 'gh issue create --title "T" --label bug --label priority-p3 --label ux'
allows "priority before the title" 'gh issue create --label priority-p0 --title "T"'
allows "uppercase label" 'gh issue create --title "T" --label PRIORITY-P2'

# --- near misses are not a priority label ---
# The point of the scale is that the level is readable at a glance. A label the
# gate accepts but GitHub shows as something else would defeat that.
denies "p5 is off the scale" 'gh issue create --title "T" --label priority-p5'
denies "no digit" 'gh issue create --title "T" --label priority'
denies "bare p2 without the prefix" 'gh issue create --title "T" --label p2'
denies "priority word in the title only" 'gh issue create --title "priority-p1 thing is broken"'
denies "priority mentioned in the body" 'gh issue create --title "T" --body "should be priority-p1"'
denies "empty label value" 'gh issue create --title "T" --label ""'
denies "label flag with no value at end" 'gh issue create --title "T" --label'
denies "label flag followed by another flag" 'gh issue create --label --title "T"'
denies "double digit level" 'gh issue create --title "T" --label priority-p10'

# --- the label must belong to the create, not a neighbouring command ---
denies "priority in a later segment" 'gh issue create --title "T" && echo --label priority-p1'
denies "priority on a piped command" 'gh issue create --title "T" | grep -- priority-p1'

# --- things that are not an issue create are left alone ---
allows "mention inside an echo" 'echo "then run gh issue create --title x"'
allows "mention inside a heredoc write" 'cat > notes.md <<EOF
gh issue create --title "T"
EOF'
allows "issue edit adding a label" 'gh issue edit 5 --add-label "priority-p1"'
allows "issue list" 'gh issue list --state open'
allows "pr create" 'gh pr create --title "T" --body "B"'
allows "label create" 'gh label create priority-p0 --color b60205'
allows "unrelated command" 'git status'
allows "empty command" ''

# --- reading the help is not filing an issue ---
# A live false positive on 2026-07-30: `gh issue create --help` was blocked, which is
# absurd (it files nothing) and it teaches the override habit the gates are designed
# to avoid. Fixed in the shared scanner, so all three gates get it.
allows "asking for help on the create command" 'gh issue create --help'
allows "the short help flag" 'gh issue create -h'
allows "help after other flags" 'gh issue create --title "T" --help'
allows "help piped to a reader" 'gh issue create --help | grep label'

# --- chained creates ---
denies "create after another command" 'git status && gh issue create --title "T"'
allows "chained create that carries a priority" 'git status && gh issue create --title "T" --label priority-p2'
denies "two creates where only the first has a priority" 'gh issue create --title "A" --label priority-p1 && gh issue create --title "B"'

# --- multi-line commands: a newline starts a new command ---
denies "create on a later line" 'echo hello
gh issue create --title "T" --body "B"'
allows "later-line create that carries a priority" 'echo hello
gh issue create --title "T" --label priority-p2'

# Flags spread over continuation lines belong to the same command.
allows "backslash continuation, priority last" 'gh issue create --title "T" \
  --body "B" \
  --label priority-p2'
denies "backslash continuation, no priority" 'gh issue create --title "T" \
  --body "B" \
  --label bug'
allows "priority after a quoted multi-line body" 'gh issue create --title "T" --body "line one
line two" --label priority-p1'
denies "quoted multi-line body, no priority" 'gh issue create --title "T" --body "line one
line two"'

# --- the documented override ---
allows "inline override" 'SKIP_PRIORITY_CHECK=1 gh issue create --title "T" --body "B"'
denies "override mentioned but not set" 'gh issue create --title "SKIP_PRIORITY_CHECK=1 in body"'
denies "override on line 1 does not exempt a create on line 3" 'SKIP_PRIORITY_CHECK=1 gh issue create --repo a/b --title "A"
echo next
gh issue create --repo a/b --title "B"'
denies "override on an earlier segment does not carry over" 'SKIP_PRIORITY_CHECK=1 gh issue create --title "A" && gh issue create --title "B"'
# The two gates have separate overrides: skipping one must never skip the other.
denies "the milestone override does not skip this gate" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "T"'

# --- heredoc bodies are data, not commands ---
allows "heredoc body containing a create, with a real command after" 'cat > notes.md <<EOF
gh issue create --title "T"
EOF
git status'
denies "real bare create after a heredoc that mentions one" 'cat > notes.md <<EOF
gh issue create --title "documented example"
EOF
gh issue create --title "real one"'

# --- the deny message has to be actionable, and read correctly ---
msg="$(run 'gh issue create --title "T"')"
if [[ "$msg" == *"file 1 issue with no priority"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: single-issue message should read 'file 1 issue', got: $msg"
fi
msg2="$(run 'gh issue create --title "A" && gh issue create --title "B"')"
if [[ "$msg2" == *"file 2 issues with no priority"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: two-issue message should read 'file 2 issues', got: $msg2"
fi
# The message is the only place the model sees the scale at the moment it is
# blocked, so every level and its meaning has to be in it, along with the rule
# about who chooses and the override.
for want in "priority-p0" "priority-p1" "priority-p2" "priority-p3" "priority-p4" \
            "broken now" "do next" "normal" "nice to have" "someday" \
            "AskUserQuestion" "ensure-priority-labels.sh" "SKIP_PRIORITY_CHECK=1"; do
  if [[ "$msg" == *"$want"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: deny message should mention '$want'"
  fi
done

# --- failure path: a payload the hook cannot parse must not block work ---
out_bad="$(printf 'not json at all' | bash "$HOOK" 2>/dev/null)"
if [[ "$out_bad" != *'"deny"'* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: unparseable payload should fail quiet, got: $out_bad"
fi

out_empty="$(printf '{}' | bash "$HOOK" 2>/dev/null)"
if [[ "$out_empty" != *'"deny"'* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: payload with no command should fail quiet, got: $out_empty"
fi

out_unbalanced="$(run 'gh issue create --title "unclosed')"
if [[ "$out_unbalanced" != *'"deny"'* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: unbalanced quotes should fail quiet, got: $out_unbalanced"
fi

# --- failure path: if the gate itself cannot run, it says so out loud ---
# Without python3 the check is impossible. It must still allow the command through
# (it is a completeness gate, not a safety gate) while making the gap visible,
# because a gate that fails silently is indistinguishable from a gate that passed.
broken_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | PATH="$TMP_EMPTY_PATH" bash "$HOOK" 2>"$TMP_ERR")"
broken_err="$(cat "$TMP_ERR")"
if [[ "$broken_out" != *'"deny"'* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a broken gate should not block the command"
fi
if [[ "$broken_err" == *"PRIORITY GATE DID NOT RUN"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a broken gate should announce itself on stderr, got: ${broken_err:-<silence>}"
fi

# --- failure path: a missing shared scanner is loud, not silent ---
# The scanner is a separate file now, so it can go missing on its own (a half
# finished sync, a rename). That must read as a broken gate, not a clean pass.
MOVED_DIR="$TMP_DIR/moved"
mkdir -p "$MOVED_DIR"
cp "$HOOK" "$MOVED_DIR/"
noscanner_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | bash "$MOVED_DIR/$(basename "$HOOK")" 2>"$TMP_ERR")"
noscanner_err="$(cat "$TMP_ERR")"
if [[ "$noscanner_out" != *'"deny"'* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a missing scanner should not block the command"
fi
if [[ "$noscanner_err" == *"PRIORITY GATE DID NOT RUN"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a missing scanner should announce itself, got: ${noscanner_err:-<silence>}"
fi

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
