#!/usr/bin/env bash
# The pointer contract both Stop hooks share (claude-config#243).
#
# feature-issue-review.sh and session-reflection.sh each keep their instruction in a
# file under hooks/review/ and emit a short pointer to it. This suite covers what has
# to hold for BOTH of them, because a property tested on one hook and not the other is
# a property the second hook does not have.
#
# The relocation case is the one worth explaining. This config is synced between two
# Macs, and Dan asked for the pointer to "handle multiple machines gracefully". The
# hooks are not the same path on both, and CLAUDE_HOME is not necessarily ~/.claude
# either, so the pointer is resolved from the hook's OWN location at run time rather
# than written down anywhere. The test proves that by running a COPY of the hooks tree
# from a different directory and requiring the reason to name the copy. A hook that
# hardcoded a path, or read one from the environment, passes every other test here and
# fails this one, which is the whole point.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-review-instr.XXXXXX")" || exit 2
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'." >&2; exit 2 ;;
esac
# Normalised, because $TMPDIR on macOS ends in a slash and mktemp hands back a
# path holding a double one. Every hook below resolves its own directory through
# `cd ... && pwd`, which collapses it, so an un-normalised fixture path compares
# unequal to the identical directory and the relocation test fails on punctuation.
WORK="$(cd "$WORK" && pwd)"
trap 'rm -rf "$WORK"' EXIT

# Every run of every hook below is pinned to a throwaway spool. A suite that can
# reach ~/.claude-issue-spool can write a fake finding into the real one, and one
# did exactly that 120 times before anyone noticed (L2).
export CLAUDE_ISSUE_SPOOL_DIR="$WORK/spool"
mkdir -p "$CLAUDE_ISSUE_SPOOL_DIR"

pass=0
fail=0
check() { # check <description> <ok|why-not>
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

# A transcript holding one mutating tool use, which is what makes a Stop hook speak.
TRANSCRIPT="$WORK/transcript.jsonl"
{
  printf '%s\n' '{"type":"user","message":{"role":"user","content":"do the thing"}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","name":"Edit","id":"t1","input":{}}]}}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"done"}]}}'
} > "$TRANSCRIPT"

# Each call gets a fresh project directory, so the per project cooldown stamp of one
# case cannot silence the next.
run_hook() { # run_hook <hook path>
  printf '{"transcript_path":"%s","stop_hook_active":false}' "$TRANSCRIPT" | \
    CLAUDE_PROJECT_DIR="$(mktemp -d "$WORK/proj.XXXXXX")" bash "$1"
}

reason_of() { # reason_of <payload json>
  printf '%s' "$1" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("NO PAYLOAD AT ALL")
    sys.exit(0)
try:
    p = json.loads(raw)
except Exception as exc:
    print("PAYLOAD DOES NOT PARSE: %s" % exc)
    sys.exit(0)
if p.get("decision") != "block":
    print("DECISION IS NOT BLOCK: %r" % p.get("decision"))
    sys.exit(0)
print(p.get("reason") or "")
'
}

# The budget. Both reasons are printed to Dan verbatim, and the whole change is that
# they stopped being thousands of characters long. Held well above what the pointers
# actually measure so an added sentence is not a failing test, and far below what the
# instructions themselves cost.
BUDGET=1500
emdash="$(printf '\xe2\x80\x94')"
endash="$(printf '\xe2\x80\x93')"

for hook in feature-issue-review session-reflection; do
  out="$(run_hook "$DIR/$hook.sh")"
  reason="$(reason_of "$out")"

  [[ "$reason" != *"NO PAYLOAD"* && "$reason" != *"DOES NOT PARSE"* && "$reason" != *"NOT BLOCK"* ]] \
    && check "$hook emits a valid block payload" ok \
    || check "$hook emits a valid block payload" "$reason"

  len="${#reason}"
  [ "$len" -le "$BUDGET" ] \
    && check "$hook's reason stays under $BUDGET characters" ok \
    || check "$hook's reason stays under $BUDGET characters" "it is $len characters"

  # The instruction it points at has to BE there. A pointer at a path that does not
  # exist is worse than the old wall of text: the review simply stops happening and
  # nothing says so.
  named="$(printf '%s' "$reason" | python3 -c '
import re, sys
m = re.search(r"(/[^ ]*review/[A-Za-z0-9._-]+\.md)", sys.stdin.read())
print(m.group(1) if m else "")
')"
  [ -n "$named" ] \
    && check "$hook's reason names an instruction file" ok \
    || check "$hook's reason names an instruction file" "no path found in: [$reason]"
  [ -f "$named" ] \
    && check "$hook's instruction file exists at the path it names" ok \
    || check "$hook's instruction file exists at the path it names" "no file at [$named]"

  # Both instructions tell Claude never to use dashes as punctuation, and the
  # reflection's used 17 em dashes doing so until it moved into a file and the pre
  # push style gate finally saw it. A rule contradicted by the prose around it loses
  # to the demonstration (L270), so it is checked here for both. The characters are
  # BUILT rather than written, because a file holding one literally is what that same
  # gate blocks, and it cannot tell a line banning the character from a line using it.
  if [ -f "$named" ]; then
    body="$(cat "$named")"
    if [[ "$body" != *"$emdash"* && "$body" != *"$endash"* ]]; then
      check "$hook's instruction carries no em or en dash" ok
    else
      check "$hook's instruction carries no em or en dash" "it does, and it tells Claude not to"
    fi
  fi

  # And the instruction must not be inlined, which is the regression this suite exists
  # to catch. Measured against the file's real size rather than a guessed string.
  if [ -f "$named" ]; then
    isize="$(wc -c < "$named" | tr -d ' ')"
    [ "$isize" -gt "$BUDGET" ] \
      && check "$hook's instruction is genuinely bigger than the budget" ok \
      || check "$hook's instruction is genuinely bigger than the budget" "it is only $isize characters, so the budget proves nothing"
  fi
done

# ---------------------------------------------------------------------------
# RELOCATION: the same hooks, run from somewhere else, must point at THEMSELVES.
# This is the two Macs case, and a copy at a different path is the only way to
# tell a resolved pointer from a hardcoded one that happens to be right here.
# ---------------------------------------------------------------------------
COPY="$WORK/elsewhere/hooks"
mkdir -p "$(dirname "$COPY")"
cp -R "$DIR" "$COPY"

for hook in feature-issue-review session-reflection; do
  reason="$(reason_of "$(run_hook "$COPY/$hook.sh")")"
  [[ "$reason" == *"$COPY/review/"* ]] \
    && check "$hook relocated points at its own copy of the instruction" ok \
    || check "$hook relocated points at its own copy of the instruction" "[$reason]"
  [[ "$reason" != *"$DIR/review/"* ]] \
    && check "$hook relocated does not point back at the original tree" ok \
    || check "$hook relocated does not point back at the original tree" "it named $DIR"
done

# ---------------------------------------------------------------------------
# A MISSING instruction file is loud. This is a half applied sync: the hook
# arrived and its instruction did not. Silence here is indistinguishable from a
# turn with nothing to review, and an ordinary pointer would send Claude to a
# file that is not there.
# ---------------------------------------------------------------------------
BROKEN="$WORK/broken/hooks"
mkdir -p "$(dirname "$BROKEN")"
cp -R "$DIR" "$BROKEN"
rm -rf "$BROKEN/review"

for hook in feature-issue-review session-reflection; do
  out="$(run_hook "$BROKEN/$hook.sh")"
  reason="$(reason_of "$out")"
  [ -n "$out" ] \
    && check "$hook with no instruction file still says something" ok \
    || check "$hook with no instruction file still says something" "it stayed silent"
  [[ "$reason" == *"missing"* ]] \
    && check "$hook with no instruction file reports it as missing" ok \
    || check "$hook with no instruction file reports it as missing" "[$reason]"
  [[ "$reason" == *"claude-sync pull"* ]] \
    && check "$hook with no instruction file names the remedy" ok \
    || check "$hook with no instruction file names the remedy" "[$reason]"
done

# ---------------------------------------------------------------------------
# The helper failing must not take the review with it. Losing the pointer's
# detail is a nuisance; losing the review is the thing the old code went out of
# its way to avoid, and that property has to survive the rewrite.
# ---------------------------------------------------------------------------
for hook in feature-issue-review session-reflection; do
  out="$(printf '{"transcript_path":"%s","stop_hook_active":false}' "$TRANSCRIPT" | \
    CLAUDE_PROJECT_DIR="$(mktemp -d "$WORK/proj.XXXXXX")" \
    CLAUDE_REVIEW_REASON_FORCE_FAIL=1 bash "$DIR/$hook.sh")"
  reason="$(reason_of "$out")"
  [[ "$reason" != *"NO PAYLOAD"* && "$reason" != *"DOES NOT PARSE"* && "$reason" != *"NOT BLOCK"* ]] \
    && check "$hook still emits a valid payload when the helper fails" ok \
    || check "$hook still emits a valid payload when the helper fails" "$reason"
  [[ "$reason" == *"review/"* ]] \
    && check "$hook's fallback still says where the instruction lives" ok \
    || check "$hook's fallback still says where the instruction lives" "[$reason]"
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
