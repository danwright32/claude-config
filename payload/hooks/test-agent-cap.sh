#!/usr/bin/env bash
# Tests for agent-cap.sh, the SessionStart hook that is the one home of the running agent cap per
# Mac (claude-config#2546).
#
# Dan asked on 2026-11-09 for seven agents per session on the work MacBook, a new 18 core machine,
# while the personal MacBook stays at four. The global CLAUDE.md is one file both Macs load, so the
# number cannot live there: it lives in agent-cap.sh, which says this Mac's number in one line at
# every session start, and CLAUDE.md says the cap is that announced number, falling back to the
# default when no line arrived. Before this the number was written out as four in eight documents
# and held there by two suites, so raising it meant finding every copy (L613).
#
# What this holds:
#   1. the hook gives the named Mac its number, any other Mac the default, and a Mac whose name
#      cannot be read the default while saying so, never a silent guess (L11);
#   2. the line is short, since it is re-sent on every request of every session, and dash free;
#   3. it is wired at SessionStart;
#   4. the global CLAUDE.md points at the announced line, and its fallback is the hook's default;
#   5. no other payload document writes a cap out by hand, by a scan seen to fail on planted copies
#      first (L1). A dated quotation of Dan's is the record of a decision, not a restatement, so
#      text inside double quotes is not read.
#
# AGENT_CAP_CLAUDE_MD and AGENT_CAP_SETTINGS point the suite at other copies, which is how a broken
# copy is shown to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/agent-cap.sh"
# The checkout, found by the one shared test, lib/checkout-root.sh (claude-config#1567, #1663).
# Empty for an installed copy, and then the checks that read the payload say they were not measured.
REPO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
PAYLOAD=""
[ -n "$REPO" ] && PAYLOAD="$REPO/payload"
CLAUDE_MD="${AGENT_CAP_CLAUDE_MD:-$DIR/../CLAUDE.md}"
SETTINGS="${AGENT_CAP_SETTINGS:-$DIR/../settings.hooks.json}"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

fixture_dir="$(mktemp -d "${TMPDIR:-/tmp}/agent-cap.XXXXXX")"
trap 'rm -rf "$fixture_dir"' EXIT

# ---- 1. the number per Mac ----
[ -x "$HOOK" ]
check "the hook is there and executable" "$([ -x "$HOOK" ] && echo ok || echo "$HOOK")"

work="$(AGENT_CAP_HOST=Dans-MacBook-Pro "$HOOK" 2>&1)"; work_rc=$?
check "the hook exits 0 on the work MacBook" "$([ "$work_rc" -eq 0 ] && echo ok || echo "exit $work_rc")"
check "the work MacBook is announced at seven" \
  "$(grep -q -F 'At most 7 subagents running at once' <<< "$work" && echo ok || echo "said: $work")"
check "and the line names the Mac it judged" \
  "$(grep -q -F 'Dans-MacBook-Pro' <<< "$work" && echo ok || echo "said: $work")"
dotted="$(AGENT_CAP_HOST=Dans-MacBook-Pro.local "$HOOK" --number 2>&1)"
check "a hostname answering with .local is judged by its short name" \
  "$([ "$dotted" = "7" ] && echo ok || echo "said: $dotted")"

default="$(AGENT_CAP_HOST=no-such-mac "$HOOK" --number 2>&1)"
check "--number prints a bare whole number for a Mac not named" \
  "$(grep -q -x -E '[1-9][0-9]*' <<< "$default" && echo ok || echo "said: $default")"
check "the default is four" "$([ "$default" = "4" ] && echo ok || echo "said: $default")"
personal="$(AGENT_CAP_HOST=Daniels-MacBook-Pro-2 "$HOOK" 2>&1)"
check "the personal MacBook gets the default" \
  "$(grep -q -F "At most $default subagents running at once" <<< "$personal" && echo ok || echo "said: $personal")"
check "and the line says it is the default" \
  "$(grep -q -F 'default' <<< "$personal" && grep -q -F 'Daniels-MacBook-Pro-2' <<< "$personal" && echo ok || echo "said: $personal")"

# A name that cannot be read is said as that, never guessed (L11, L98). Set and empty stands for it.
unread="$(AGENT_CAP_HOST= "$HOOK" 2>&1)"; unread_rc=$?
check "an unreadable hostname still exits 0" "$([ "$unread_rc" -eq 0 ] && echo ok || echo "exit $unread_rc")"
check "an unreadable hostname gets the default" \
  "$(grep -q -F "At most $default subagents running at once" <<< "$unread" && echo ok || echo "said: $unread")"
check "and says it could not tell which Mac this is" \
  "$(grep -q -F 'could not be read' <<< "$unread" && echo ok || echo "said: $unread")"
# The real lookup failing, not only the stand in: a hostname command that prints nothing and fails.
mkdir -p "$fixture_dir/bin"
printf '#!/bin/sh\nexit 1\n' > "$fixture_dir/bin/hostname"
chmod +x "$fixture_dir/bin/hostname"
failed="$(env -u AGENT_CAP_HOST PATH="$fixture_dir/bin:/usr/bin:/bin" "$HOOK" 2>&1)"
check "a failing hostname command is said as an unreadable name" \
  "$(grep -q -F 'could not be read' <<< "$failed" && grep -q -F "At most $default " <<< "$failed" && echo ok || echo "said: $failed")"

# The table itself: every entry a short hostname and a whole number, so a typo cannot pass as a cap.
table="$("$HOOK" --table 2>&1)"
bad_rows="$(printf '%s\n' "$table" | awk 'NF && !($1 ~ /^[A-Za-z0-9-]+$/ && $2 ~ /^[1-9][0-9]*$/ && NF == 2)')"
check "the table has at least one Mac" "$([ -n "$(printf '%s' "$table" | tr -d '[:space:]')" ] && echo ok || echo "--table printed nothing")"
check "the table names the work MacBook" "$(grep -q -x -F 'Dans-MacBook-Pro 7' <<< "$table" && echo ok || echo "table: $table")"
check "every table row is a short hostname and a whole number" "$([ -z "$bad_rows" ] && echo ok || echo "bad rows: $bad_rows")"

# ---- 2. one short line, every request ----
for out in "$work" "$personal" "$unread"; do
  lines="$(printf '%s\n' "$out" | grep -c .)"
  len="$(printf '%s' "$out" | wc -c | tr -d ' ')"
  check "the announcement is one line (${out:0:40})" "$([ "$lines" -eq 1 ] && echo ok || echo "$lines lines")"
  check "the announcement is at most 140 characters (${out:0:40})" "$([ "$len" -le 140 ] && echo ok || echo "$len characters")"
  check "the announcement starts with its tag (${out:0:40})" "$([[ "$out" == '[Agent cap] '* ]] && echo ok || echo "said: $out")"
done
dashes="$(printf '%s\n%s\n%s\n' "$work" "$personal" "$unread" | grep -n -e $'\xe2\x80\x94' -e $'\xe2\x80\x93')"
check "no em or en dash in the announcement" "$([ -z "$dashes" ] && echo ok || echo "$dashes")"

# ---- 3. wired at SessionStart ----
wired="$(python3 - "$SETTINGS" <<'PY' 2>&1
import json, sys
d = json.load(open(sys.argv[1]))
cmds = [h.get("command", "") for g in d.get("hooks", {}).get("SessionStart", []) for h in g.get("hooks", [])]
print("ok" if any(c.endswith("/hooks/agent-cap.sh") for c in cmds) else "not registered: " + ", ".join(cmds))
PY
)"
check "the hook is registered at SessionStart" "$wired"

# ---- 4. the global CLAUDE.md points at the announced number ----
cap_line="$(grep -F '[Agent cap]' "$CLAUDE_MD" 2>/dev/null | head -n 1)"
check "the global CLAUDE.md cap rule names the [Agent cap] line" "$([ -n "$cap_line" ] && echo ok || echo "no [Agent cap] in $CLAUDE_MD")"
check "and names the hook that is the number's home" \
  "$(grep -q -F 'hooks/agent-cap.sh' <<< "$cap_line" && echo ok || echo "no hooks/agent-cap.sh on the line")"
# Its fallback, the one number the static file must state, is the hook's default (L41).
word="$(grep -o -E '(one|two|three|four|five|six|seven|eight|nine|ten) when no such line arrived' <<< "$cap_line" | head -n 1)"
word="${word%% *}"
case "$word" in
  one) n=1 ;; two) n=2 ;; three) n=3 ;; four) n=4 ;; five) n=5 ;; six) n=6 ;; seven) n=7 ;; eight) n=8 ;; nine) n=9 ;; ten) n=10 ;; *) n="" ;;
esac
check "the CLAUDE.md fallback for no announcement is the hook's default ($default)" \
  "$([ -n "$n" ] && [ "$n" = "$default" ] && echo ok || echo "read '${word:-nothing}' before 'when no such line arrived'")"
check "the plan-council and plan-lite panel exemption is still there" \
  "$(grep -q -F 'which Dan starts on purpose, is exempt and runs at full width (Dan, 2026-10-16)' <<< "$cap_line" && echo ok || echo "the exemption sentence changed")"
check "Dan's two dated decisions are both quoted" \
  "$(grep -q -F '2026-10-16: "only ever have 4 agents running at a time"' <<< "$cap_line" && grep -q -F '2026-11-09' <<< "$cap_line" && grep -q -F '"raise the session subagent limit to 7 agents each"' <<< "$cap_line" && echo ok || echo "a dated quote is missing")"

# ---- 5. no hand written copy of a cap anywhere else in the payload ----
# By spelling (L564): a number, written as digits or a word, sitting where a cap on agents is said.
# "one at a time" is a different rule (serial work), so the numbers start at two.
NUM='([2-9]|[1-9][0-9]|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve|sixteen)'
NOUN='(agents?|subagents?|auditors|refuters|explorers|builders|investigators|reviewers)'
B='(^|[^a-z0-9_])'
PATS=(
  -e "${B}(at most|more than|up to|capped at|a cap of|limit of) $NUM ([a-z]+ )?$NOUN[^.]{0,40}(at once|at a time|running|in flight|concurrent|in parallel|same time)"
  -e "${B}$NUM ([a-z]+ )?$NOUN ([a-z]+ )?(at a time|at once|in flight)"
  -e "${B}$NOUN[^.]{0,30}[^a-z0-9]$NUM (at a time|at once)"
  -e "${B}at most $NUM (running|at once|at a time)"
  -e "most urgent $NUM([^a-z0-9]|$)"
  -e "(MAX_AGENTS|AGENT_CAP|AGENTS_AT_ONCE)[A-Z_]* *= *[0-9]"
)
# The one other place a number must be written: the production audit workflow cannot run a shell or
# read a file, so its fallback for a run started with no agentCap is a literal, held to the hook's
# default by test-production-audit.sh, which runs it.
EXEMPT_RE='production-audit\.workflow\.js:[0-9]+:const AGENT_CAP_FALLBACK = [0-9]+$'
scan() { # scan <root>   prints file:line:text for every hand written cap under root
  local hits
  hits="$(grep -r -n -i -E "${PATS[@]}" --include='*.md' --include='*.js' --include='*.cjs' --include='*.mjs' \
    --exclude='LESSONS*' --exclude-dir=audits --exclude-dir=node_modules "$1" 2>/dev/null)"
  [ -n "$hits" ] || return 0
  # Quoted text is a record of what somebody said, so it is removed before the line is judged again.
  printf '%s\n' "$hits" | while IFS= read -r hit; do
    stripped="$(printf '%s' "$hit" | sed -E 's/"[^"]*"//g')"
    printf '%s\n' "$stripped" | grep -q -i -E "${PATS[@]}" || continue
    printf '%s\n' "$hit" | grep -q -E "$EXEMPT_RE" && continue
    printf '%s\n' "$hit"
  done
}

# Seen to fail first (L1): each way a cap has been written in this payload, planted in a fixture.
plant="$fixture_dir/plant"; mkdir -p "$plant/skills/x"
printf 'Never have more than four subagents running at the same time.\n' > "$plant/a.md"
printf 'Wave 1 is the most urgent four: live harm first.\n' > "$plant/b.md"
printf 'run 19 domain auditors, four at a time, then verify.\n' > "$plant/c.md"
printf '## 3. Explore (at most 4 agents at a time)\n' > "$plant/d.md"
printf 'one agent per shape, at most seven running at once; tell Dan\n' > "$plant/e.md"
printf 'const MAX_AGENTS_AT_ONCE = 7\n' > "$plant/skills/x/f.js"
printf 'Dan said "only ever have 4 agents running at a time" on that day.\n' > "$plant/quoted.md"
printf 'Ask the questions one at a time, and at most 4 options per picker.\n' > "$plant/clean.md"
printf 'x\n' > "$plant/LESSONS.md"; printf 'At most four agents running at once.\n' >> "$plant/LESSONS.md"
seen="$(scan "$plant")"
for f in a.md b.md c.md d.md e.md skills/x/f.js; do
  check "the scan finds a planted cap in $f" "$(grep -q -F "$plant/$f:" <<< "$seen" && echo ok || echo "not found; scan said: $seen")"
done
check "the scan leaves a dated quotation alone" "$(grep -q -F 'quoted.md' <<< "$seen" && echo "flagged" || echo ok)"
check "the scan leaves one at a time and picker options alone" "$(grep -q -F 'clean.md' <<< "$seen" && echo "flagged" || echo ok)"
check "the scan leaves the lessons record alone" "$(grep -q -F 'LESSONS.md' <<< "$seen" && echo "flagged" || echo ok)"

if [ -n "$PAYLOAD" ]; then
  copies="$(scan "$PAYLOAD")"
  check "no payload document writes the agent cap out by hand (point at the [Agent cap] line instead)" \
    "$([ -z "$copies" ] && echo ok || printf 'found:\n%s' "$copies")"
else
  echo "SUITE-PART-UNMEASURED $DIR/.. is not the payload of a claude-config checkout, so the payload was not scanned for a hand written cap"
fi

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
