#!/usr/bin/env bash
# Tests for checkpoint-save.sh, the Stop hook that asks the session to persist anything memorable
# into the CURRENT project's memory store (claude-config#124).
#
# It decides three things and had no test for any of them: whether the turn did real work, WHICH
# project's memory store to name, and whether to fire at all. Naming the wrong store writes one
# project's facts where another project recalls them, and that is invisible until somebody reads a
# memory that makes no sense where it is. Not firing is invisible full stop.
#
# It also refuses in two specific cases that exist because of real incidents: a detached headless
# run, which once left a memory file in Overture authored by a run only ever asked to read pages,
# and its own continuation, which would otherwise loop.
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
H="$DIR/checkpoint-save.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-checkpoint-save: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.checkpoint.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-checkpoint-save: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

user_line() { python3 -c 'import json,sys; print(json.dumps({"type":"user","message":{"content":sys.argv[1]}}))' "$1"; }
tool_line() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"tool_use","name":sys.argv[1],"input":{}}]}}))' "$1"; }
text_line() { python3 -c 'import json,sys; print(json.dumps({"type":"assistant","message":{"content":[{"type":"text","text":sys.argv[1]}]}}))' "$1"; }

transcript() { # transcript <path> <lines...>
  local f="$1"; shift
  mkdir -p "$(dirname "$f")"
  : > "$f"
  local l; for l in "$@"; do printf '%s\n' "$l" >> "$f"; done
}
run() { # run <transcript path> [extra payload fields, as a JSON object]
  local extra="${2:-}"
  [ -n "$extra" ] || extra='{}'
  python3 -c 'import json,sys; d={"transcript_path": sys.argv[1]}; d.update(json.loads(sys.argv[2])); print(json.dumps(d))' "$1" "$extra" > "$TMPROOT/in.json"
  bash "$H" < "$TMPROOT/in.json" 2>/dev/null
}
reason_of() { python3 -c 'import json,sys
raw = sys.stdin.read().strip()
if not raw:
    sys.exit(0)
try:
    print(json.loads(raw).get("reason", ""))
except Exception:
    sys.exit(0)'; }

PROJDIR="$TMPROOT/home/.claude/projects/-Users-someone-Apps-Widget"
T_WORKED="$PROJDIR/sessions/worked.jsonl"
transcript "$T_WORKED" "$(user_line 'fix the retry')" "$(tool_line Edit)" "$(text_line 'done')"

# ---------------------------------------------------------------------------
# A turn that did work asks for a save, and names the right store.
# ---------------------------------------------------------------------------
out_worked="$(run "$T_WORKED")"
grep -q '"decision": *"block"' <<< "$out_worked" \
  && check "a turn that did work asks the session to save" ok \
  || check "a turn that did work asks the session to save" "out=${out_worked:0:200}"
reason="$(printf '%s' "$out_worked" | reason_of)"
grep -qF "$PROJDIR/memory" <<< "$reason" \
  && check "and names THIS project's memory store, derived from the transcript path" ok \
  || check "and names THIS project's memory store, derived from the transcript path" "reason=${reason:0:300}"
grep -qi 'silent' <<< "$reason" \
  && check "and says to do it without narrating, which is the whole point of it" ok \
  || check "and says to do it without narrating, which is the whole point of it" "reason=${reason:0:300}"

# A DIFFERENT project gets a different store, or the check above is satisfied by one hard coded
# path that happens to match (L70: two sides from one lookup only prove the lookup is consistent).
OTHERDIR="$TMPROOT/home/.claude/projects/-Users-someone-Apps-Gadget"
T_OTHER="$OTHERDIR/sessions/worked.jsonl"
transcript "$T_OTHER" "$(user_line 'fix it')" "$(tool_line Write)"
reason_other="$(run "$T_OTHER" | reason_of)"
grep -qF "$OTHERDIR/memory" <<< "$reason_other" \
  && check "a transcript from another project names that project's store instead" ok \
  || check "a transcript from another project names that project's store instead" "reason=${reason_other:0:300}"
[ "$reason" != "$reason_other" ] \
  && check "and the two are genuinely different" ok \
  || check "and the two are genuinely different" "both named the same store"

# ---------------------------------------------------------------------------
# Turns it must NOT fire on.
# ---------------------------------------------------------------------------
T_CHAT="$PROJDIR/sessions/chat.jsonl"
transcript "$T_CHAT" "$(user_line 'thanks')" "$(text_line 'you are welcome')"
[ -z "$(run "$T_CHAT")" ] \
  && check "a turn with no tools at all does not fire" ok \
  || check "a turn with no tools at all does not fire" "it fired"

T_ASK="$PROJDIR/sessions/ask.jsonl"
transcript "$T_ASK" "$(user_line 'which one')" "$(tool_line AskUserQuestion)"
[ -z "$(run "$T_ASK")" ] \
  && check "a turn that only asked a question does not fire" ok \
  || check "a turn that only asked a question does not fire" "it fired"

T_PREV="$PROJDIR/sessions/prev.jsonl"
transcript "$T_PREV" "$(user_line 'do the work')" "$(tool_line Edit)" "$(user_line 'now just tell me something')" "$(text_line 'here you go')"
[ -z "$(run "$T_PREV")" ] \
  && check "work in an EARLIER turn does not fire this one" ok \
  || check "work in an EARLIER turn does not fire this one" "it fired"

# ---------------------------------------------------------------------------
# The two refusals that exist because of real incidents.
# ---------------------------------------------------------------------------
out_detached="$(python3 -c 'import json,sys; print(json.dumps({"transcript_path": sys.argv[1]}))' "$T_WORKED" > "$TMPROOT/in.json"; CLAUDE_DETACHED_RUN=1 bash "$H" < "$TMPROOT/in.json" 2>/dev/null)"
[ -z "$out_detached" ] \
  && check "a detached headless run does not teach the next session anything" ok \
  || check "a detached headless run does not teach the next session anything" "it fired"

out_loop="$(run "$T_WORKED" '{"stop_hook_active": true}')"
[ -z "$out_loop" ] \
  && check "its own continuation does not fire it again" ok \
  || check "its own continuation does not fire it again" "it fired, which is a loop"

# ---------------------------------------------------------------------------
# Ways of being handed nothing usable. Each must exit cleanly and stay quiet, and none may crash:
# this is a Stop hook, so a crash lands on the end of every turn.
# ---------------------------------------------------------------------------
out_gone="$(run "$TMPROOT/never-written.jsonl")"; code_gone=$?
[ -z "$out_gone" ] && [ "$code_gone" -eq 0 ] \
  && check "a transcript that is not there is quiet and clean" ok \
  || check "a transcript that is not there is quiet and clean" "out=$out_gone exit=$code_gone"
printf 'not json at all' > "$TMPROOT/in.json"
out_junk="$(bash "$H" < "$TMPROOT/in.json" 2>/dev/null)"; code_junk=$?
[ -z "$out_junk" ] && [ "$code_junk" -eq 0 ] \
  && check "a payload that does not parse is quiet and clean" ok \
  || check "a payload that does not parse is quiet and clean" "out=$out_junk exit=$code_junk"
T_BROKEN="$PROJDIR/sessions/broken.jsonl"
printf 'not json\n{"type":"assistant"\n' > "$T_BROKEN"
out_broken="$(run "$T_BROKEN")"; code_broken=$?
[ -z "$out_broken" ] && [ "$code_broken" -eq 0 ] \
  && check "a transcript whose lines do not parse is quiet and clean" ok \
  || check "a transcript whose lines do not parse is quiet and clean" "out=$out_broken exit=$code_broken"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
