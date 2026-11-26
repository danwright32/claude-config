#!/usr/bin/env bash
# test-db-approval-picker-check.sh: the database apply approval and the test project approval take
# Dan's answer only from a picker he could read as written (claude-config#3321).
#
# Both approvals are read by lib/db-apply-approval.py from the session's transcript, and before
# this his Apply or Trust counted whatever the picker held: a question longer than the dialog shows
# whole, a character he cannot see, markup a surface hides. The check of that is one function,
# askFault in payload/mods/mod-kit/hooks/shown.ts, and Python cannot call it, so it has one command
# line entry, lib/picker-check.mjs, which the reader runs under node (Dan, 2026-11-21: "One check,
# called"). No rule of the check is written a second time in Python.
#
# Proved here: the entry answers with mod-kit's own verdicts, at mod-kit's own limits; the reader
# drops a picker the check refuses and says why; and when the entry cannot run (no node, a node
# that hangs, an answer that cannot be read) no picker is taken and the reason is said, so the
# write is asked about and never refused. A session with no picker of either kind never starts node.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENTRY="$DIR/lib/picker-check.mjs"
SHOWN="$DIR/../mods/mod-kit/hooks/shown.ts"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
finish() {
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
}

if [ ! -f "$ENTRY" ]; then
  echo "FAIL: there is no lib/picker-check.mjs beside this suite at $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the shared check's command line entry could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

WORK="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

MAX="$(sed -n 's/^export const MAX_QUESTION = \([0-9][0-9]*\)$/\1/p' "$SHOWN")"
case "$MAX" in ''|*[!0-9]*) check "mod-kit's limit on a question's length can be read from shown.ts" "got: $MAX" ;; *) check "mod-kit's limit on a question's length can be read from shown.ts" ok ;; esac

# asks <kind>...: a JSON object {"asks": [...]} of one picker per kind. plain is readable; hidden
# holds a zero width space, made from its code point and never written here; long is one unit over
# mod-kit's limit and atlimit exactly at it; beside is readable with a field beside the question
# that holds the hidden character.
asks() {
  python3 - "$MAX" "$@" <<'PY'
import json, sys
most, kinds = int(sys.argv[1]), sys.argv[2:]
zw = chr(0x200b)
def picker(kind):
    q = "Apply migration 002_note.sql to project exampleprojectref000?"
    ask = {"questions": [{"question": q, "header": "Migration", "multiSelect": False,
                          "options": [{"label": "Apply", "description": "Run it"}, {"label": "Cancel", "description": "Do not"}]}],
           "metadata": {"source": "db-apply"}}
    if kind == "hidden":
        ask["questions"][0]["question"] = q.replace("migration", "migration" + zw)
    if kind == "long":
        ask["questions"][0]["question"] = ("word " * most)[:most + 1]
    if kind == "atlimit":
        ask["questions"][0]["question"] = ("word " * most)[:most - 1] + "?"
    if kind == "beside":
        ask["title"] = "Apply" + zw
    return ask
print(json.dumps({"asks": [picker(k) for k in kinds]}))
PY
}
entry() { node --experimental-strip-types --no-warnings "$ENTRY"; }

# --- the entry: mod-kit's verdicts, one per picker, in order -------------------------------------
out="$(asks plain | entry)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"faults":[null]}' ] && check "a picker Dan would read as written has no fault" ok || check "a picker Dan would read as written has no fault" "exit=$rc out=${out:0:300}"
out="$(asks hidden | entry)"; rc=$?
case "$rc|$out" in '0|{"faults":[{"what":"The question","fault":"character '*'U+200B'*) check "a character he cannot see is the question's fault, named by its code point" ok ;; *) check "a character he cannot see is the question's fault, named by its code point" "exit=$rc out=${out:0:300}" ;; esac
out="$(asks long | entry)"; rc=$?
case "$rc|$out" in "0|"*"it is $((MAX + 1)) UTF-16 code units"*"only up to $MAX"*) check "a question one unit over mod-kit's limit is refused, at mod-kit's own number" ok ;; *) check "a question one unit over mod-kit's limit is refused, at mod-kit's own number" "exit=$rc out=${out:0:300}" ;; esac
out="$(asks atlimit | entry)"; rc=$?
case "$rc|$out" in "0|"*"UTF-16 code units"*) check "a question exactly at mod-kit's length limit is not refused for its length" "exit=$rc out=${out:0:300}" ;; "0|"*) check "a question exactly at mod-kit's length limit is not refused for its length" ok ;; *) check "a question exactly at mod-kit's length limit is not refused for its length" "exit=$rc out=${out:0:300}" ;; esac
out="$(asks beside | entry)"; rc=$?
case "$rc|$out" in '0|{"faults":[{"what":"Field \"title\"",'*) check "a field sent beside the question is judged too" ok ;; *) check "a field sent beside the question is judged too" "exit=$rc out=${out:0:300}" ;; esac
out="$(asks plain hidden plain | entry)"; rc=$?
case "$rc|$out" in '0|{"faults":[null,{"what":"The question",'*'},null]}') check "several pickers get one verdict each, in the order sent" ok ;; *) check "several pickers get one verdict each, in the order sent" "exit=$rc out=${out:0:300}" ;; esac
out="$(printf '{"asks": []}' | entry)"; rc=$?
[ "$rc" = 0 ] && [ "$out" = '{"faults":[]}' ] && check "no pickers gives no verdicts" ok || check "no pickers gives no verdicts" "exit=$rc out=${out:0:300}"

# What it cannot read is an error with its own exit code, never a verdict (L11).
for bad in 'not json' '{"asks": "x"}' '{"asks": [1]}' '[]' ''; do
  out="$(printf '%s' "$bad" | entry 2>"$WORK/err")"; rc=$?
  [ "$rc" = 2 ] && [ -z "$out" ] && [ -s "$WORK/err" ] && check "input the entry cannot read ($bad) exits 2 with no verdict" ok || check "input the entry cannot read ($bad) exits 2 with no verdict" "exit=$rc out=${out:0:200} err=$(head -c 200 "$WORK/err")"
done

# One implementation: the entry takes the check from mod-kit's file and the reader holds no rule.
grep -qF "from '../../mods/mod-kit/hooks/shown.ts'" "$ENTRY" && check "the entry takes the check from mod-kit's shown.ts" ok || check "the entry takes the check from mod-kit's shown.ts" "no such import in $ENTRY"
if grep -nE "UTF-16|0x200|\\\\u200|MAX_QUESTION|$MAX" "$DIR/lib/db-apply-approval.py" >"$WORK/copy" 2>/dev/null; then
  check "the Python reader holds no limit or character class of the check" "it spells one: $(head -n 2 "$WORK/copy" | cut -c1-160)"
else
  check "the Python reader holds no limit or character class of the check" ok
fi

# --- the reader: his answer is taken only from a picker the check passes --------------------------
# talk <file> <source> <word> <kind>...: a transcript of session s1 holding one answered picker per
# kind, in the shape Claude Code writes them (the picker's input on the assistant entry holding its
# tool_use, his choice in toolUseResult.answers on the user entry carrying its tool_result).
talk() {
  local file="$1" source="$2" word="$3"
  shift 3
  asks "$@" | python3 -c '
import json, sys
path, source, word = sys.argv[1:4]
with open(path, "w") as f:
    for n, ask in enumerate(json.load(sys.stdin)["asks"]):
        q = ask["questions"][0]["question"]
        ask["metadata"] = {"source": source, "list": "/tmp/checkout/.claude/supabase-test-projects", "project_ref": "ref%d" % n, "n": n}
        uid = "toolu_pick%d" % n
        f.write(json.dumps({"type": "assistant", "sessionId": "s1", "message": {"role": "assistant", "content": [
            {"type": "tool_use", "id": uid, "name": "AskUserQuestion", "input": ask}]}}) + "\n")
        f.write(json.dumps({"type": "user", "sessionId": "s1", "message": {"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": uid, "content": "answered"}]},
            "toolUseResult": {"questions": ask["questions"], "answers": {q: word}, "annotations": {}}}) + "\n")
' "$file" "$source" "$word"
}
# reader <transcript> <what>: what the reader makes of the transcript, as one printed line.
#   applies  the n of each Apply taken, then each reason a picker was not
#   trusted  the refs Dan trusted, then why his pickers could not all be taken
reader() {
  python3 -I -B - "$DIR/lib" "$1" "$2" "${3:-}" "${4:-}" <<'PY'
import importlib.util, sys, time
spec = importlib.util.spec_from_file_location("ap", sys.argv[1] + "/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
if sys.argv[4]:
    ap.PICKER_CHECK_SECONDS = float(sys.argv[4])
t = time.monotonic()
if sys.argv[3] == "applies":
    unread = []
    found = ap.applies(sys.argv[2], "s1", unread)
    print("taken=%s unread=%s" % ([m["n"] for m, _ in found], [(kept[0]["n"], why) for kept, why in unread]))
else:
    # The fifth argument, when given, is the seconds left of the hook's shared deadline.
    if sys.argv[5]:
        lines, why, untaken = ap._trusted_by_dan("s1", sys.argv[2], t + float(sys.argv[5]))
    else:
        lines, why, untaken = ap._trusted_by_dan("s1", sys.argv[2])
    print("trusted=%s why=%s untaken=%s" % (sorted(r for _, r in lines), why, sorted((r, w) for (_, r), w in untaken.items())))
print("took %.1f" % (time.monotonic() - t))
PY
}

talk "$WORK/plain.jsonl" db-apply Apply plain
got="$(reader "$WORK/plain.jsonl" applies 2>&1)"
case "$got" in "taken=[0] unread=[]"*) check "an Apply in a picker Dan could read is taken" ok ;; *) check "an Apply in a picker Dan could read is taken" "got: ${got:0:400}" ;; esac
talk "$WORK/hidden.jsonl" db-apply Apply hidden
got="$(reader "$WORK/hidden.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"would not have reached him as written"*"The question"*"U+200B"*) check "an Apply in a picker holding a character he cannot see is not taken, and why is said" ok ;; *) check "an Apply in a picker holding a character he cannot see is not taken, and why is said" "got: ${got:0:400}" ;; esac
talk "$WORK/long.jsonl" db-apply Apply long
got="$(reader "$WORK/long.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"UTF-16 code units"*) check "an Apply in a picker longer than the dialog shows whole is not taken" ok ;; *) check "an Apply in a picker longer than the dialog shows whole is not taken" "got: ${got:0:400}" ;; esac
talk "$WORK/beside.jsonl" db-apply Apply beside
got="$(reader "$WORK/beside.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*'Field \"title\"'*|"taken=[] unread=["*'Field "title"'*) check "an Apply whose picker carried an unreadable field beside the question is not taken" ok ;; *) check "an Apply whose picker carried an unreadable field beside the question is not taken" "got: ${got:0:400}" ;; esac
talk "$WORK/mixed.jsonl" db-apply Apply plain hidden plain
got="$(reader "$WORK/mixed.jsonl" applies 2>&1)"
case "$got" in "taken=[0, 2] unread=[(1, "*"U+200B"*) check "of several Applies only the unreadable one is dropped" ok ;; *) check "of several Applies only the unreadable one is dropped" "got: ${got:0:400}" ;; esac

talk "$WORK/trust.jsonl" db-test-project Trust plain hidden
got="$(reader "$WORK/trust.jsonl" trusted 2>&1)"
case "$got" in "trusted=['ref0'] why=None untaken=[('ref1', "*"would not have reached him as written"*) check "a Trust in a readable picker is taken, and one in an unreadable picker is not, with why" ok ;; *) check "a Trust in a readable picker is taken, and one in an unreadable picker is not, with why" "got: ${got:0:400}" ;; esac
talk "$WORK/trust-plain.jsonl" db-test-project Trust plain
got="$(reader "$WORK/trust-plain.jsonl" trusted 2>&1)"
case "$got" in "trusted=['ref0'] why=None untaken=[]"*) check "a Trust in a readable picker gives no reason" ok ;; *) check "a Trust in a readable picker gives no reason" "got: ${got:0:400}" ;; esac

# --- when the entry cannot run: nothing is taken, the reason is said, nothing raises -------------
# No node on PATH: a folder holding python3 alone, then the system's own folders. Where those hold
# a node this Mac cannot make the state, and the cases say they were not measured (L411).
mkdir -p "$WORK/pyonly"
ln -s "$(command -v python3)" "$WORK/pyonly/python3"
BARE="$WORK/pyonly:/usr/bin:/bin"
if PATH="$BARE" command -v node >/dev/null 2>&1; then
  echo "NOT MEASURED: a node is in /usr/bin or /bin, so a PATH without one cannot be made here"
else
  got="$(PATH="$BARE" reader "$WORK/plain.jsonl" applies 2>&1)"
  case "$got" in "taken=[] unread=["*"could not be checked"*"node is not on PATH"*) check "with no node, an Apply is not taken and the reason names node" ok ;; *) check "with no node, an Apply is not taken and the reason names node" "got: ${got:0:400}" ;; esac
  got="$(PATH="$BARE" reader "$WORK/trust-plain.jsonl" trusted 2>&1)"
  case "$got" in "trusted=[] why=None untaken=[('ref0', "*"could not be checked"*"node is not on PATH"*) check "with no node, a Trust is not taken and the reason names node" ok ;; *) check "with no node, a Trust is not taken and the reason names node" "got: ${got:0:400}" ;; esac
fi
# fakenode <name> <script body>: a folder holding a node that is the given shell script.
fakenode() { mkdir -p "$WORK/$1"; printf '#!/bin/sh\n%s\n' "$2" > "$WORK/$1/node"; chmod +x "$WORK/$1/node"; }
fakenode hang 'exec sleep 5'
got="$(PATH="$WORK/hang:$PATH" reader "$WORK/plain.jsonl" applies 0.3 2>&1)"
case "$got" in "taken=[] unread=["*"could not be checked"*"did not answer"*"took 0."*) check "a node that hangs is given up on at the limit, and the Apply is not taken" ok ;; *) check "a node that hangs is given up on at the limit, and the Apply is not taken" "got: ${got:0:400}" ;; esac
fakenode old 'echo "node: bad option: --experimental-strip-types" >&2; exit 9'
got="$(PATH="$WORK/old:$PATH" reader "$WORK/plain.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"could not be checked"*"exited 9"*"bad option"*) check "a node too old to run the entry is said with its exit code and first line" ok ;; *) check "a node too old to run the entry is said with its exit code and first line" "got: ${got:0:400}" ;; esac
fakenode garbage 'cat >/dev/null; echo "not json"'
got="$(PATH="$WORK/garbage:$PATH" reader "$WORK/plain.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"could not be checked"*"could not be read"*) check "an answer that is not JSON takes no Apply" ok ;; *) check "an answer that is not JSON takes no Apply" "got: ${got:0:400}" ;; esac
fakenode short 'cat >/dev/null; echo "{\"faults\":[]}"'
got="$(PATH="$WORK/short:$PATH" reader "$WORK/plain.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"could not be checked"*) check "an answer with a verdict missing takes no Apply (a passing verdict is never assumed)" ok ;; *) check "an answer with a verdict missing takes no Apply (a passing verdict is never assumed)" "got: ${got:0:400}" ;; esac
fakenode allnull 'cat >/dev/null; echo "{\"faults\":[\"fine\"]}"'
got="$(PATH="$WORK/allnull:$PATH" reader "$WORK/plain.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=["*"could not be checked"*) check "a verdict in a shape the entry never gives takes no Apply" ok ;; *) check "a verdict in a shape the entry never gives takes no Apply" "got: ${got:0:400}" ;; esac
# The check shares the hook's deadline with the git runs before it, so the hook's own limit (set in
# settings, not measured) is never passed: with less time left than the check's own limit it waits only that long,
# and with none left it is not started, and the Trust is not taken, with the reason.
got="$(PATH="$WORK/hang:$PATH" reader "$WORK/trust-plain.jsonl" trusted "" 0.3 2>&1)"
case "$got" in "trusted=[] why=None untaken=[('ref0', "*"could not be checked"*"took 0."*) check "with less of the hook's time left than the check's own limit, the check is given up on when that time runs out" ok ;; *) check "with less of the hook's time left than the check's own limit, the check is given up on when that time runs out" "got: ${got:0:400}" ;; esac
fakenode spent "touch '$WORK/spent-ran'; exit 1"
got="$(PATH="$WORK/spent:$PATH" reader "$WORK/trust-plain.jsonl" trusted "" 0 2>&1)"
case "$got" in "trusted=[] why=None untaken=[('ref0', "*"could not be checked"*"no time was left"*) [ ! -e "$WORK/spent-ran" ] && check "with none of the hook's time left, the check is never started and the Trust is not taken, with why" ok || check "with none of the hook's time left, the check is never started and the Trust is not taken, with why" "node was run" ;; *) check "with none of the hook's time left, the check is never started and the Trust is not taken, with why" "got: ${got:0:400}" ;; esac

# --- the cost: no picker of the source, no node --------------------------------------------------
fakenode marker "touch '$WORK/node-ran'; exit 1"
printf '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n' > "$WORK/none.jsonl"
got="$(PATH="$WORK/marker:$PATH" reader "$WORK/none.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=[]"*) [ ! -e "$WORK/node-ran" ] && check "a session with no Apply picker never starts node" ok || check "a session with no Apply picker never starts node" "node was run" ;; *) check "a session with no Apply picker never starts node" "got: ${got:0:400}" ;; esac
talk "$WORK/cancel.jsonl" db-apply Cancel plain
got="$(PATH="$WORK/marker:$PATH" reader "$WORK/cancel.jsonl" applies 2>&1)"
case "$got" in "taken=[] unread=[]"*) [ ! -e "$WORK/node-ran" ] && check "a picker Dan answered Cancel is never sent to the check" ok || check "a picker Dan answered Cancel is never sent to the check" "node was run" ;; *) check "a picker Dan answered Cancel is never sent to the check" "got: ${got:0:400}" ;; esac

# --- the measure: whether a question is past the dialog's size (claude-config#3583) ----------------
# A gate that must choose between a question showing every line and a shorter one asks the entry,
# with "sizes": true, rather than counting rows itself. The measure is held here to the verdict:
# at mod-kit's own limits a question is large exactly when the check refuses it for its size.
MAXROWS="$(sed -n 's/^export const MAX_QUESTION_ROWS = \([0-9][0-9]*\)$/\1/p' "$SHOWN")"
COLUMNS_AT="$(sed -n 's/^export const QUESTION_COLUMNS = \([0-9][0-9]*\)$/\1/p' "$SHOWN")"
case "$MAXROWS:$COLUMNS_AT" in *[!0-9:]*|:*|*:) check "mod-kit's row limit and width can be read from shown.ts" "got: $MAXROWS:$COLUMNS_AT" ;; *) check "mod-kit's row limit and width can be read from shown.ts" ok ;; esac
# sized <lines> [units]: one picker whose question is that many one word lines, or one line of
# that many units, sent with "sizes": true; prints "<fault or none>|large=<..>|rows=<..>|units=<..>|limits=<..>".
SIZED_PRINT='import json, sys; o = json.load(sys.stdin); f = o["faults"][0]; s = o["sizes"][0]; print("%s|large=%s|rows=%d|units=%d|limits=%d,%d,%d" % ("none" if f is None else f["fault"][:60], str(s["large"]).lower(), s["rows"], s["units"], s["maxRows"], s["maxUnits"], s["columns"]))'
sized() {
  python3 - "${1:-0}" "${2:-0}" <<'PY' | entry | python3 -c "$SIZED_PRINT"
import json, sys
lines, units = int(sys.argv[1]), int(sys.argv[2])
q = "\n".join(["word"] * lines) if lines else ("word " * units)[:units - 1] + "?"
print(json.dumps({"sizes": True, "asks": [{"questions": [{"question": q, "header": "Lessons", "multiSelect": False,
    "options": [{"label": "Yes", "description": "Go on"}, {"label": "No", "description": "Stop"}]}]}]}))
PY
}
got="$(sized "$MAXROWS")"
case "$got" in "none|large=false|rows=$MAXROWS|"*"|limits=$MAXROWS,$MAX,$COLUMNS_AT") check "a question exactly at mod-kit's row limit is not large, and the check passes it" ok ;; *) check "a question exactly at mod-kit's row limit is not large, and the check passes it" "got: $got" ;; esac
got="$(sized "$((MAXROWS + 1))")"
case "$got" in "it takes $((MAXROWS + 1)) rows"*"|large=true|rows=$((MAXROWS + 1))|"*) check "a question one row over is large, and the check refuses it for its rows" ok ;; *) check "a question one row over is large, and the check refuses it for its rows" "got: $got" ;; esac
got="$(sized 0 "$MAX")"
case "$got" in "none|large=false|"*"|units=$MAX|"*) check "a question exactly at mod-kit's length limit is not large" ok ;; *) check "a question exactly at mod-kit's length limit is not large" "got: $got" ;; esac
got="$(sized 0 "$((MAX + 1))")"
case "$got" in "it is $((MAX + 1)) UTF-16 code units"*"|large=true|"*"|units=$((MAX + 1))|"*) check "a question one unit over is large, and the check refuses it for its length" ok ;; *) check "a question one unit over is large, and the check refuses it for its length" "got: $got" ;; esac
out="$(asks hidden | python3 -c 'import json,sys; o=json.load(sys.stdin); o["sizes"]=True; print(json.dumps(o))' | entry)"
case "$out" in *'"fault":"character '*'"large":false'*) check "a short question the check refuses for a character is not large" ok ;; *) check "a short question the check refuses for a character is not large" "out=${out:0:300}" ;; esac
if grep -nE "= *[0-9]{2,}|[<>] *[0-9]" "$ENTRY" >"$WORK/numbers" 2>/dev/null; then
  check "the entry holds no limit of its own" "it spells a number: $(head -n 2 "$WORK/numbers" | cut -c1-160)"
else
  check "the entry holds no limit of its own" ok
fi
# The reader hands the measure on, and a measure that cannot be read is no verdict.
measure() {  # measure [a node folder]: picker_faults with sizes, over one plain picker
  PATH="${1:+$1:}$PATH" python3 - "$DIR/lib/db-apply-approval.py" <<'PY' 2>&1
import importlib.util, sys
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("a", sys.argv[1]); a = importlib.util.module_from_spec(spec); spec.loader.exec_module(a)
ask = {"questions": [{"question": "May it go on?", "header": "Lessons", "multiSelect": False,
                      "options": [{"label": "Yes", "description": "Go on"}, {"label": "No", "description": "Stop"}]}]}
sizes = []
try:
    print("faults=%r large=%r rows=%r" % (a.picker_faults([ask], sizes=sizes), sizes[0]["large"], sizes[0]["rows"]))
except a.PickerCheckFailed as e:
    print("failed: %s" % e)
PY
}
got="$(measure)"
case "$got" in "faults=[None] large=False rows=1") check "the reader hands the entry's measure to a caller that asks for it" ok ;; *) check "the reader hands the entry's measure to a caller that asks for it" "got: ${got:0:300}" ;; esac
fakenode nosizes 'cat >/dev/null; echo "{\"faults\":[null]}"'
got="$(measure "$WORK/nosizes")"
case "$got" in "failed: the check's measure of the question could not be read") check "an answer with no measure is no verdict for a caller that asked for one" ok ;; *) check "an answer with no measure is no verdict for a caller that asked for one" "got: ${got:0:300}" ;; esac
fakenode oddsizes 'cat >/dev/null; echo "{\"faults\":[null],\"sizes\":[{\"large\":\"no\",\"rows\":1}]}"'
got="$(measure "$WORK/oddsizes")"
case "$got" in "failed: the check's measure of the question could not be read") check "a measure in a shape the entry never gives is no verdict" ok ;; *) check "a measure in a shape the entry never gives is no verdict" "got: ${got:0:300}" ;; esac

finish
