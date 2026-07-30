#!/usr/bin/env bash
# Tests for require-category-on-issue.sh.
#
# Every issue says what it is about, and an issue can be about several things at once,
# so the rule is "at least one label that is not the priority". The vocabulary is
# deliberately NOT restricted: this gate checks that a category exists, never which
# one it is.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/require-category-on-issue.sh"

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

# --- the core rule: no category label is a block ---
denies "bare create" 'gh issue create --title "T" --body "B"'
denies "milestone and priority but no category" 'gh issue create --title "T" --milestone "Ungrouped" --label priority-p2'
denies "priority only, equals form" 'gh issue create --title "T" --label=priority-p1'
denies "priority only, short flag" 'gh issue create --title "T" -l priority-p0'
denies "every level still counts as no category" 'gh issue create --title "T" --label priority-p4'
denies "a comma list holding only a priority" 'gh issue create --title "T" --label "priority-p3"'
denies "empty label value" 'gh issue create --title "T" --label ""'
denies "label flag with no value" 'gh issue create --title "T" --label'

# --- any non-priority label satisfies it, whatever it is called ---
# The vocabulary is not restricted, so the gate must accept a name it has never seen.
allows "a type label" 'gh issue create --title "T" --label bug --label priority-p2'
allows "an area label" 'gh issue create --title "T" --label accessibility --label priority-p1'
allows "a repo specific label" 'gh issue create --title "T" --label canvas --label priority-p2'
allows "a label nobody has ever used before" 'gh issue create --title "T" --label wobbly-gizmo-behaviour --label priority-p2'
allows "a comma list with both" 'gh issue create --title "T" --label "tech-debt,priority-p2"'
allows "several categories at once" 'gh issue create --title "T" --label accessibility --label tech-debt --label ux --label priority-p2'
allows "category with no priority at all" 'gh issue create --title "T" --label bug'
allows "category before the priority" 'gh issue create --title "T" --label bug --label priority-p2 --milestone "Ungrouped"'
allows "attached short flag value" 'gh issue create --title "T" -lbug'
allows "a label that merely starts like a priority" 'gh issue create --title "T" --label priority-review --label priority-p2'
allows "an off-scale priority name counts as a category" 'gh issue create --title "T" --label priority-p9'

# --- not an issue create, or not ours to judge ---
allows "issue edit adding a label" 'gh issue edit 5 --add-label bug'
allows "issue list" 'gh issue list --state open'
allows "pr create" 'gh pr create --title "T"'
allows "label create" 'gh label create ux --color ededed'
allows "unrelated command" 'git status'
allows "empty command" ''
allows "mention inside an echo" 'echo "run gh issue create --title x"'
allows "mention inside a heredoc" 'cat > n.md <<EOF
gh issue create --title "T"
EOF'

# --- reading the help is not filing an issue ---
# A live false positive on 2026-07-30: `gh issue create --help` was blocked, which is
# absurd (it files nothing) and it teaches the override habit the gates are designed
# to avoid. Fixed in the shared scanner, so all three gates get it.
allows "asking for help on the create command" 'gh issue create --help'
allows "the short help flag" 'gh issue create -h'
allows "help after other flags" 'gh issue create --title "T" --help'
allows "help piped to a reader" 'gh issue create --help | grep label'

# --- the label must belong to the create itself ---
denies "category in a later segment" 'gh issue create --title "T" --label priority-p2 && echo --label bug'
denies "create after another command" 'git status && gh issue create --title "T" --label priority-p2'
allows "chained create carrying a category" 'git status && gh issue create --title "T" --label bug'
denies "two creates where only the first has a category" 'gh issue create --title "A" --label bug && gh issue create --title "B" --label priority-p2'
denies "create on a later line" 'echo hi
gh issue create --title "T" --label priority-p2'
allows "later-line create carrying a category" 'echo hi
gh issue create --title "T" --label bug'
allows "backslash continuation, category last" 'gh issue create --title "T" \
  --label priority-p2 \
  --label accessibility'
denies "backslash continuation, priority only" 'gh issue create --title "T" \
  --label priority-p2'

# --- the documented override, separate from the other two gates ---
allows "inline override" 'SKIP_CATEGORY_CHECK=1 gh issue create --title "T"'
denies "the priority override does not skip this gate" 'SKIP_PRIORITY_CHECK=1 gh issue create --title "T" --label priority-p2'
denies "the milestone override does not skip this gate" 'SKIP_MILESTONE_CHECK=1 gh issue create --title "T" --label priority-p2'
denies "override on an earlier segment does not carry over" 'SKIP_CATEGORY_CHECK=1 gh issue create --title "A" && gh issue create --title "B" --label priority-p2'

# --- the deny message has to be actionable ---
msg="$(run 'gh issue create --title "T" --label priority-p2')"
if [[ "$msg" == *"file 1 issue with no category"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: single-issue message should read 'file 1 issue', got: $msg"; fi
msg2="$(run 'gh issue create --title "A" --label priority-p1 && gh issue create --title "B" --label priority-p2')"
if [[ "$msg2" == *"file 2 issues with no category"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: two-issue message should read 'file 2 issues', got: $msg2"; fi
# The message must make clear the vocabulary is open and that several labels are fine,
# or it will read as "pick one from a fixed list", which is the opposite of the rule.
for want in "gh label list" "as many" "not a fixed list" "gh label create" "NAMING.md" "SKIP_CATEGORY_CHECK=1" "bug" "accessibility"; do
  if [[ "$msg" == *"$want"* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: deny message should mention '$want'"; fi
done

# --- failure paths: never block work we cannot read ---
for payload in 'not json at all' '{}'; do
  out="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"
  if [[ "$out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: unreadable payload should fail quiet, got: $out"; fi
done
out_unbalanced="$(run 'gh issue create --title "unclosed')"
if [[ "$out_unbalanced" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: unbalanced quotes should fail quiet"; fi

# --- if the gate cannot run, it says so out loud ---
broken_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | PATH="$TMP_EMPTY_PATH" bash "$HOOK" 2>"$TMP_ERR")"
broken_err="$(cat "$TMP_ERR")"
if [[ "$broken_out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate should not block the command"; fi
if [[ "$broken_err" == *"CATEGORY GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a broken gate should announce itself, got: ${broken_err:-<silence>}"; fi

MOVED_DIR="$TMP_DIR/moved"
mkdir -p "$MOVED_DIR"
cp "$HOOK" "$MOVED_DIR/"
ns_out="$(printf '{"tool_input":{"command":"gh issue create --title T"}}' \
  | bash "$MOVED_DIR/$(basename "$HOOK")" 2>"$TMP_ERR")"
ns_err="$(cat "$TMP_ERR")"
if [[ "$ns_out" != *'"deny"'* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing scanner should not block the command"; fi
if [[ "$ns_err" == *"CATEGORY GATE DID NOT RUN"* ]]; then pass=$((pass + 1)); else
  fail=$((fail + 1)); echo "FAIL: a missing scanner should announce itself, got: ${ns_err:-<silence>}"; fi

echo
echo "passed: $pass, failed: $fail"
[[ "$fail" -eq 0 ]]
