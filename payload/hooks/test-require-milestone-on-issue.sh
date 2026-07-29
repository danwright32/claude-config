#!/usr/bin/env bash
# Tests for require-milestone-on-issue.sh.
#
# The gate is pure string logic on the command about to run, so these tests need
# no network and no gh. Every case feeds a PreToolUse payload on stdin and asserts
# whether the hook denied.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-milestone-on-issue.sh"

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

# --- the core rule: a create with no milestone is blocked ---
denies "bare create" 'gh issue create --title "Fix thing" --body "why"'
denies "create with labels but no milestone" 'gh issue create --title "T" --body "B" --label bug'
denies "create via absolute path to gh" '/opt/homebrew/bin/gh issue create --title "T"'
denies "create with --repo" 'gh issue create --repo acme/widgets --title "T" --body "B"'

# --- a create that names a milestone passes ---
allows "long flag with value" 'gh issue create --title "T" --body "B" --milestone "Onboarding revamp"'
allows "long flag equals form" 'gh issue create --title "T" --milestone=Onboarding'
allows "short flag" 'gh issue create --title "T" -m "Onboarding revamp"'
allows "milestone first" 'gh issue create --milestone "Onboarding" --title "T"'
allows "milestone by number" 'gh issue create --title "T" --milestone 4'

# --- an empty or absent value is not a milestone ---
denies "empty double-quoted value" 'gh issue create --title "T" --milestone ""'
denies "empty equals form" 'gh issue create --title "T" --milestone='
denies "flag with no value at end" 'gh issue create --title "T" --milestone'
denies "flag followed by another flag" 'gh issue create --milestone --title "T"'

# --- the milestone must belong to the create, not a neighbouring command ---
denies "milestone in a later segment" 'gh issue create --title "T" && echo --milestone Foo'
denies "milestone on a piped command" 'gh issue create --title "T" | grep -- --milestone'

# --- things that are not an issue create are left alone ---
allows "mention inside an echo" 'echo "then run gh issue create --title x"'
allows "mention inside a heredoc write" 'cat > notes.md <<EOF
gh issue create --title "T"
EOF'
allows "issue edit adding a milestone" 'gh issue edit 5 --add-milestone "Onboarding"'
allows "issue list" 'gh issue list --state open'
allows "pr create" 'gh pr create --title "T" --body "B"'
allows "unrelated command" 'git status'
allows "empty command" ''

# --- chained creates ---
denies "create after another command" 'git status && gh issue create --title "T"'
allows "chained create that carries a milestone" 'git status && gh issue create --title "T" --milestone "Q3"'
denies "two creates where only the first has a milestone" 'gh issue create --title "A" --milestone "Q3" && gh issue create --title "B"'

# --- multi-line commands: a newline starts a new command ---
# This was a live miss on 2026-07-29: the gate saw only the first line, because a
# plain newline is whitespace to the tokenizer and nothing marked a new command.
denies "create on a later line" 'echo hello
gh issue create --title "T" --body "B"'
denies "create on line 3 after an unrelated pipe" 'gh issue list | head -3
echo checking
gh issue create --title "T"'
allows "later-line create that carries a milestone" 'echo hello
gh issue create --title "T" --milestone "Q3"'

# Flags spread over continuation lines belong to the same command, so a milestone
# on a later physical line still counts.
allows "backslash continuation, milestone last" 'gh issue create --title "T" \
  --body "B" \
  --milestone "Q3"'
denies "backslash continuation, no milestone" 'gh issue create --title "T" \
  --body "B" \
  --label bug'
allows "milestone after a quoted multi-line body" 'gh issue create --title "T" --body "line one
line two" --milestone "Q3"'
denies "quoted multi-line body, no milestone" 'gh issue create --title "T" --body "line one
line two"'

# --- the documented override ---
allows "inline override" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "T" --body "B"'
denies "override mentioned but not set" 'gh issue create --title "SKIP_MILESTONE_CHECK=1 in body"'
# An override belongs to the one command it prefixes. Letting it cover the whole
# call is how the 2026-07-29 live miss slipped a second, unmilestoned create past.
denies "override on line 1 does not exempt a create on line 3" 'SKIP_MILESTONE_CHECK=1 gh issue create --repo a/b --title "A"
echo next
gh issue create --repo a/b --title "B"'
denies "override on an earlier segment does not carry over" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "A" && gh issue create --title "B"'

# --- heredoc bodies are data, not commands ---
allows "heredoc body containing a create, with a real command after" 'cat > notes.md <<EOF
gh issue create --title "T"
EOF
git status'
denies "real bare create after a heredoc that mentions one" 'cat > notes.md <<EOF
gh issue create --title "documented example"
EOF
gh issue create --title "real one"'
allows "quoted heredoc delimiter" "cat > notes.md <<'EOF'
gh issue create --title \"T\"
EOF"

# --- the deny message has to be actionable, and read correctly ---
msg="$(run 'gh issue create --title "T"')"
if [[ "$msg" == *"file 1 issue with no milestone"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: single-issue message should read 'file 1 issue', got: $msg"
fi
msg2="$(run 'gh issue create --title "A" && gh issue create --title "B"')"
if [[ "$msg2" == *"file 2 issues with no milestone"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: two-issue message should read 'file 2 issues', got: $msg2"
fi
for want in "milestone" "SKIP_MILESTONE_CHECK=1"; do
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
if [[ "$broken_err" == *"MILESTONE GATE DID NOT RUN"* ]]; then
  pass=$((pass + 1))
else
  fail=$((fail + 1))
  echo "FAIL: a broken gate should announce itself on stderr, got: ${broken_err:-<silence>}"
fi

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
