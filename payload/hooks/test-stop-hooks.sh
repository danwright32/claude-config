#!/usr/bin/env bash
# Tests for the Stop hooks' "did this turn change anything" gating.
# session-reflection.sh and feature-issue-review.sh must both:
#   - stay SILENT on chat-only turns
#   - stay SILENT on read-only turns (Read/Grep/WebFetch only)
#   - FIRE on turns that used a mutating tool (Edit/Write/Bash/Agent/...)
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFLECT="$DIR/session-reflection.sh"
REVIEW="$DIR/feature-issue-review.sh"

WORK="$(mktemp -d)"
# Refused rather than trusted, because everything this suite deletes is built from it and a
# mktemp that came back empty would aim those deletions at / instead. The same guard the sibling
# suites take, and it is here because this suite now removes directories between cases rather than
# only at the end.
case "${WORK%/}" in
  ''|/|"${HOME%/}")
    echo "FAIL: $(basename "$0"): refusing to run: the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT

make_transcript() {
  # $1 = path, $2 = tool name to use in the assistant turn ("" = chat only)
  local path="$1" tool="${2:-}"
  {
    printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
    if [ -n "$tool" ]; then
      printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"%s","id":"t1","input":{}}]}}\n' "$tool"
      printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
    fi
    printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
  } > "$path"
}

pass=0
fail=0

run_hook() {
  # $1 = hook script, $2 = transcript path; unique project dir defeats the
  # issue-review cooldown stamp between cases.
  local hook="$1" transcript="$2"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$transcript" | \
    CLAUDE_PROJECT_DIR="$(mktemp -d "$WORK/proj.XXXXXX")" bash "$hook"
}

expect_silent() {
  local label="$1" hook="$2" transcript="$3" out
  out="$(run_hook "$hook" "$transcript")"
  if [ -z "$out" ]; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $label should be silent, got output"; fi
}

expect_fires() {
  local label="$1" hook="$2" transcript="$3" out
  out="$(run_hook "$hook" "$transcript")"
  if printf '%s' "$out" | grep -q '"decision"'; then pass=$((pass+1)); else fail=$((fail+1)); echo "FAIL: $label should fire, got nothing"; fi
}

t_chat="$WORK/chat.jsonl";  make_transcript "$t_chat" ""
t_read="$WORK/read.jsonl";  make_transcript "$t_read" "Read"
t_grep="$WORK/grep.jsonl";  make_transcript "$t_grep" "Grep"
t_edit="$WORK/edit.jsonl";  make_transcript "$t_edit" "Edit"
t_bash="$WORK/bash.jsonl";  make_transcript "$t_bash" "Bash"
t_agent="$WORK/agent.jsonl"; make_transcript "$t_agent" "Agent"
t_slack_send="$WORK/slack-send.jsonl"; make_transcript "$t_slack_send" "mcp__claude_ai_Slack__slack_send_message"
t_slack_read="$WORK/slack-read.jsonl"; make_transcript "$t_slack_read" "mcp__claude_ai_Slack__slack_read_thread"
t_click="$WORK/click.jsonl";  make_transcript "$t_click" "mcp__playwright__browser_click"
t_snap="$WORK/snap.jsonl";    make_transcript "$t_snap" "mcp__playwright__browser_snapshot"
t_dblist="$WORK/dblist.jsonl"; make_transcript "$t_dblist" "mcp__supabase__list_tables"
t_dbmig="$WORK/dbmig.jsonl";  make_transcript "$t_dbmig" "mcp__supabase__apply_migration"

expect_silent "reflection/chat-only"  "$REFLECT" "$t_chat"
expect_silent "reflection/read-only"  "$REFLECT" "$t_read"
expect_silent "reflection/grep-only"  "$REFLECT" "$t_grep"
expect_fires  "reflection/edit"       "$REFLECT" "$t_edit"
expect_fires  "reflection/bash"       "$REFLECT" "$t_bash"
expect_fires  "reflection/agent"      "$REFLECT" "$t_agent"

# Connected apps: writes/sends/clicks are work, reads/snapshots/lists are not.
expect_fires  "reflection/mcp-slack-send"  "$REFLECT" "$t_slack_send"
expect_silent "reflection/mcp-slack-read"  "$REFLECT" "$t_slack_read"
expect_fires  "reflection/mcp-browser-click" "$REFLECT" "$t_click"
expect_silent "reflection/mcp-browser-snapshot" "$REFLECT" "$t_snap"
expect_silent "reflection/mcp-db-list"     "$REFLECT" "$t_dblist"
expect_fires  "reflection/mcp-db-migrate"  "$REFLECT" "$t_dbmig"

expect_silent "issue-review/chat-only" "$REVIEW" "$t_chat"
expect_silent "issue-review/read-only" "$REVIEW" "$t_read"
expect_fires  "issue-review/edit"      "$REVIEW" "$t_edit"


# ---------------------------------------------------------------------------
# WITH NO PYTHON3 (claude-config#490). All three end of turn hooks run their "did this turn do
# real work" filter under python3, and every one of them answered EMPTY, failed the comparison
# against "yes", and exited 0. So on a machine with no python3 there is no reflection, no issue
# review and no memory write, ever, and quiet is indistinguishable from nothing to say (L98, L11).
# session-reflection.sh even carries a static fallback payload further down that can never be
# reached, because the hook has already exited by then.
#
# These were deliberately left out of claude-config#486, which covered the hooks standing BETWEEN
# an action and its effect. A Stop hook refuses nothing, so losing one is a lost nudge rather than
# an open gate: a smaller fault needing a different message, and one that must NOT block on every
# turn, because a Stop hook that blocks every turn is worse than one that is quiet.
# ---------------------------------------------------------------------------
NOTICE_DIR="$WORK/notices"

nopython_bin() {  # prints a bin directory holding everything these hooks need EXCEPT python3
  local out="$WORK/nopython" t p
  [ -d "$out" ] && { printf '%s' "$out"; return 0; }
  mkdir -p "$out"
  for t in bash sh jq git grep sed awk tr cat cut head tail sort uniq dirname basename env date \
           mkdir rm mv ln touch printf test stat find wc id hostname shasum; do
    p="$(command -v "$t" 2>/dev/null)" || continue
    [ -n "$p" ] && ln -s "$p" "$out/$t" 2>/dev/null
  done
  printf '%s' "$out"
}

run_nopython() {  # $1 = hook, $2 = transcript  -> the hook run with no python3 on PATH
  local hook="$1" transcript="$2"
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$transcript" | \
    PATH="$(nopython_bin)" \
    CLAUDE_PROJECT_DIR="$(mktemp -d "$WORK/proj.XXXXXX")" \
    STOP_HOOK_NOTICE_DIR="$NOTICE_DIR" \
    bash "$hook" 2>&1
}

# The control this whole block rests on: the stripped PATH really does reach no python3. Without
# it every assertion below is satisfied by a fixture in which the thing under test could not have
# happened anyway (L159).
if PATH="$(nopython_bin)" bash -c 'command -v python3 >/dev/null 2>&1'; then
  fail=$((fail+1)); echo "FAIL: the stripped PATH still reaches a python3, so nothing below measures its absence"
else
  pass=$((pass+1))
fi
# And that the stripped PATH is not so bare that the hooks die for an unrelated reason: jq is what
# two of them read their payload with, and it has to still be there.
if PATH="$(nopython_bin)" bash -c 'command -v jq >/dev/null 2>&1'; then
  pass=$((pass+1))
else
  fail=$((fail+1)); echo "FAIL: the stripped PATH lost jq too, so a refusal below would not be about python3"
fi

# Each hook, met with a FRESH marker directory, speaks rather than going quiet.
for _h in "$REFLECT:reflection" "$REVIEW:issue-review" "$DIR/checkpoint-save.sh:checkpoint"; do
  _hook="${_h%%:*}"; _name="${_h##*:}"
  rm -rf "$NOTICE_DIR"
  _out="$(run_nopython "$_hook" "$t_edit")"
  case "$_out" in
    *python3*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: $_name with no python3 said nothing about the interpreter, got: ${_out:-<silence>}" ;;
  esac
  # It has to reach Claude, and through Claude the person, rather than dying on a stream nobody
  # reads: for a Stop hook that means decision:block, whose reason Claude Code prints verbatim.
  case "$_out" in
    *'"decision"'*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: $_name with no python3 did not reach Claude at all, got: ${_out:-<silence>}" ;;
  esac
  # And it names the hook that lost its work, so the reader knows what did not happen rather than
  # only that something did not (L11).
  case "$_out" in
    *"$(basename "$_hook")"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: $_name with no python3 did not name itself, got: $_out" ;;
  esac
done

# ONCE. A Stop hook blocking on every turn is worse than one that is quiet, so the second turn on
# the same machine is silent. The marker is written before the notice is printed, so a notice
# cannot repeat itself if anything after it fails.
rm -rf "$NOTICE_DIR"
_first="$(run_nopython "$REFLECT" "$t_edit")"
_second="$(run_nopython "$REFLECT" "$t_edit")"
if [ -n "$_first" ] && [ -z "$_second" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: the no-python3 notice repeated itself (first=${_first:-<silence>} second=${_second:-<silence>})"; fi

# The marker is SHARED between the three, because the cause is one cause and three blocks in one
# turn is the noise that gets a hook switched off (L36). So a second hook in the same turn is
# silent too.
rm -rf "$NOTICE_DIR"
_r1="$(run_nopython "$REFLECT" "$t_edit")"
_r2="$(run_nopython "$REVIEW" "$t_edit")"
if [ -n "$_r1" ] && [ -z "$_r2" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: a second Stop hook in the same turn spoke as well (r1=${_r1:-<silence>} r2=${_r2:-<silence>})"; fi
# Which makes the wording load bearing: whichever one speaks has to name the others, or the reader
# is told about one lost nudge and silently loses three.
rm -rf "$NOTICE_DIR"
_names="$(run_nopython "$REFLECT" "$t_edit")"
for _other in feature-issue-review.sh checkpoint-save.sh; do
  case "$_names" in
    *"$_other"*) pass=$((pass+1)) ;;
    *) fail=$((fail+1)); echo "FAIL: the single notice does not name $_other, whose work is lost for the same reason" ;;
  esac
done

# It cannot deduplicate what it cannot record, and a Stop hook that blocks without being able to
# deduplicate blocks for ever: the continuation it causes arrives as another Stop. So where the
# marker cannot be written it stays SILENT rather than looping. That is a real loss, and it is the
# deliberate one of the two (L93).
rm -rf "$NOTICE_DIR"
mkdir -p "$NOTICE_DIR"
chmod 500 "$NOTICE_DIR"
_ro="$(run_nopython "$REFLECT" "$t_edit")"
chmod 700 "$NOTICE_DIR"
if [ -z "$_ro" ]; then pass=$((pass+1)); else
  fail=$((fail+1)); echo "FAIL: it blocked without being able to record that it had, which loops: $_ro"; fi

# And the whole thing is inert where python3 IS present: no marker, and the ordinary behaviour.
rm -rf "$NOTICE_DIR"
_with="$(STOP_HOOK_NOTICE_DIR="$NOTICE_DIR" run_hook "$REFLECT" "$t_edit")"
case "$_with" in
  *python3*) fail=$((fail+1)); echo "FAIL: it complained about python3 on a machine that has one" ;;
  *) pass=$((pass+1)) ;;
esac
if [ -e "$NOTICE_DIR/stop-hooks-no-python3" ]; then
  fail=$((fail+1)); echo "FAIL: it left a no-python3 marker on a machine that has python3"
else
  pass=$((pass+1))
fi

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
