#!/usr/bin/env bash
# send-gate: scans settings.hooks.json
# Tests for the hook that asks Dan before any database SQL call that is not read only
# (claude-config#2521).
#
# On 2026-11-09 #2356's live checks sent `update <table> set <column> = <column> where false` to a
# production database through the claude.ai Supabase connector's execute_sql on both Macs, and auto
# mode, every hook and every prompt let it through. Dan decided that day: a hook asks him before any
# such call that is not read only. "Read only" is read-only-query-allow.sh's answer, from the one
# predicate both load (lib/sql-read-only.py), so this suite also runs one set of statements through
# BOTH hooks and checks that exactly one of them decides each: the read hook approves it, or this
# hook asks. That compares the two hooks' outputs, never the predicate itself (L721).
#
# The payloads are in the shape the tool schemas declare (read 2026-11-06): execute_sql and
# apply_migration take project_id and query. The project id is invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/db-write-ask.sh"
READ_HOOK="$DIR/read-only-query-allow.sh"
. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS=""

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no db-write-ask.sh beside this suite at $DIR"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
[ -x "$HOOK" ] && check "the hook is executable, as the settings run it by its path" ok || check "the hook is executable, as the settings run it by its path" "mode lacks x"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
# A HOME of its own, so the Mac's real settings.local.json is never read; CLAUDE_HOME cleared too.
EMPTY_HOME="$WORK/empty-home"
mkdir -p "$EMPTY_HOME"

SQL_TOOL="mcp__claude_ai_Supabase__execute_sql"
MIG_TOOL="mcp__claude_ai_Supabase__apply_migration"
SF_WRITE="mcp__claude_ai_SFDC_USE__"

# run <hook> <home> <payload>: the hook's stdout, its exit code on the last line.
run() {
  local out rc
  out="$(cd "$WORK" && printf '%s' "$3" | env -u CLAUDE_HOME HOME="$2" bash "$1" 2>/dev/null)"; rc=$?
  printf '%s\nrc=%s\n' "$out" "$rc"
}
# decision <run output>: allow, deny, ask, none, or badjson, then " rc=N".
decision() {
  local rc="${1##*rc=}" body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
if not t:
    print("none", end=""); sys.exit()
try:
    d = json.loads(t)
except Exception:
    print("badjson", end=""); sys.exit()
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print((h or {}).get("permissionDecision", "none"), end="")'
  printf ' rc=%s' "$rc"
}
field() {  # field <run output> <reason|message>
  local body="${1%$'\n'rc=*}"
  printf '%s' "$body" | python3 -c '
import json, sys
try:
    d = json.loads(sys.stdin.read())
except Exception:
    sys.exit()
if sys.argv[1] == "reason":
    print((d.get("hookSpecificOutput") or {}).get("permissionDecisionReason", ""))
else:
    print(d.get("systemMessage", ""))' "$2"
}
payload() {  # payload <tool> <query>
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": {"project_id": "exampleprodproject", "query": sys.argv[2]}}))' "$1" "$2"
}
tool_payload() {
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))' "$1" "$2"
}
expect() {  # expect <label> <want decision> <payload> [home]
  local got; got="$(decision "$(run "$HOOK" "${4:-$EMPTY_HOME}" "$3")")"
  [ "$got" = "$2 rc=0" ] && check "$1" ok || check "$1" "wanted $2 rc=0, got $got"
}

# --- the cases the issue names ----------------------------------------------------------------
STMT="update workflows set note = note where false"
expect "a WHERE false update is asked about" ask "$(payload "$SQL_TOOL" "$STMT")"
r="$(run "$HOOK" "$EMPTY_HOME" "$(payload "$SQL_TOOL" "$STMT")")"
reason="$(field "$r" reason)"
case "$reason" in *"$STMT"*) check "the question names the statement" ok ;; *) check "the question names the statement" "reason: ${reason:0:300}" ;; esac
case "$reason" in *exampleprodproject*) check "the question names the project" ok ;; *) check "the question names the project" "reason: ${reason:0:300}" ;; esac
expect "a select passes untouched" none "$(payload "$SQL_TOOL" "select id, name from workflows where active = true")"
expect "a CTE wrapping an update is asked about" ask "$(payload "$SQL_TOOL" "with changed as (update runs set status = 'x' returning id) select * from changed")"
expect "an unparseable statement is asked about" ask "$(payload "$SQL_TOOL" "selec t frm (( where")"
expect "an empty statement is asked about" ask "$(payload "$SQL_TOOL" "")"
expect "a statement with a comment is asked about" ask "$(payload "$SQL_TOOL" "select 1 -- note")"
expect "two statements are asked about" ask "$(payload "$SQL_TOOL" "select 1; delete from runs")"
expect "a call to a function that may write is asked about" ask "$(payload "$SQL_TOOL" "select archive_old_runs(30)")"
expect "execute_sql with no query is asked about" ask "$(tool_payload "$SQL_TOOL" '{"project_id": "exampleprodproject"}')"
expect "execute_sql with a query that is not text is asked about" ask "$(tool_payload "$SQL_TOOL" '{"project_id": "exampleprodproject", "query": ["update", "t"]}')"
expect "execute_sql whose input is not an object is asked about" ask "$(python3 -c 'import json; print(json.dumps({"tool_name": "'"$SQL_TOOL"'", "tool_input": "update t set a = 1"}))')"
# A migration changes the database by definition, whatever its text.
expect "apply_migration is asked about even for a select" ask "$(payload "$MIG_TOOL" "select 1")"
expect "apply_migration of a table is asked about" ask "$(payload "$MIG_TOOL" "create table t (id int)")"
# Tools it does not watch get nothing from it.
expect "Bash gets no decision" none "$(tool_payload Bash '{"command": "update t set a = 1"}')"
expect "another Supabase tool gets no decision" none "$(tool_payload mcp__claude_ai_Supabase__list_tables '{"project_id": "p"}')"

# --- payloads it cannot read: fail closed when the raw text names a database tool ---------------
r="$(cd "$WORK" && printf '{"tool_name": "%s", "tool_input": {"query": "update t' "$SQL_TOOL" | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
got="$(decision "$r")"
[ "$got" = "ask rc=0" ] && check "a cut short execute_sql payload is asked about" ok || check "a cut short execute_sql payload is asked about" "$got"
case "$(field "$r" reason)" in *payload*) check "the question about an unreadable payload says the payload could not be read" ok ;; *) check "the question about an unreadable payload says the payload could not be read" "$(field "$r" reason)" ;; esac
expect "a payload that is a list naming execute_sql is asked about" ask "[$(payload "$SQL_TOOL" "select 1")]"
r="$(cd "$WORK" && printf '{"tool_name": "Bash", "tool_input": {"command": "ls' | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
got="$(decision "$r")"
[ "$got" = "none rc=0" ] && check "a cut short payload naming no database tool is passed" ok || check "a cut short payload naming no database tool is passed" "$got"
expect "an empty payload is passed, as it names nothing" none ""

# --- the predicate library missing: every database call is asked about -------------------------
mkdir -p "$WORK/nolib/hooks/lib"
cp "$HOOK" "$WORK/nolib/hooks/"
for f in "$DIR"/lib/*; do case "$f" in */sql-read-only.py) ;; *) cp -R "$f" "$WORK/nolib/hooks/lib/" ;; esac; done
r="$(run "$WORK/nolib/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(payload "$SQL_TOOL" "select 1")")"
got="$(decision "$r")"
[ "$got" = "ask rc=0" ] && check "with lib/sql-read-only.py missing, even a select is asked about" ok || check "with lib/sql-read-only.py missing, even a select is asked about" "$got"
case "$(field "$r" reason)" in *sql-read-only.py*) check "the question names the missing library" ok ;; *) check "the question names the missing library" "$(field "$r" reason)" ;; esac
# And the read hook, without it, approves nothing and says it did not run.
cp "$READ_HOOK" "$WORK/nolib/hooks/"
r="$(run "$WORK/nolib/hooks/read-only-query-allow.sh" "$EMPTY_HOME" "$(payload "$SQL_TOOL" "select 1")")"
got="$(decision "$r")"
[ "$got" = "none rc=0" ] && check "with lib/sql-read-only.py missing, the read hook approves nothing" ok || check "with lib/sql-read-only.py missing, the read hook approves nothing" "$got"
case "$(field "$r" message)" in *"DID NOT RUN"*sql-read-only.py*) check "the read hook says it did not run, naming the library" ok ;; *) check "the read hook says it did not run, naming the library" "$(field "$r" message)" ;; esac

# --- both hooks load the one predicate ----------------------------------------------------------
for h in "$HOOK" "$READ_HOOK"; do
  grep -q 'lib/sql-read-only.py' "$h" && check "$(basename "$h") loads lib/sql-read-only.py" ok || check "$(basename "$h") loads lib/sql-read-only.py" "it does not name it"
done
grep -q -E '^def judge|WRITE_WORDS *=' "$READ_HOOK" && check "the read hook holds no copy of the predicate" "it still defines judge or WRITE_WORDS" || check "the read hook holds no copy of the predicate" ok

# --- reconciliation: exactly one of the two hooks decides every execute_sql statement -----------
# A statement the read hook approves is never asked about, and one it does not approve always is.
# Read from the two hooks' outputs, never from the predicate (L721).
total=0
while IFS= read -r q; do
  total=$((total + 1))
  p="$(payload "$SQL_TOOL" "$q")"
  a="$(decision "$(run "$READ_HOOK" "$EMPTY_HOME" "$p")")"
  b="$(decision "$(run "$HOOK" "$EMPTY_HOME" "$p")")"
  case "$a|$b" in
    "allow rc=0|none rc=0"|"none rc=0|ask rc=0") check "exactly one hook decides [$q]" ok ;;
    "allow rc=0|ask rc=0") check "exactly one hook decides [$q]" "the read hook approves it AND this hook asks" ;;
    *) check "exactly one hook decides [$q]" "read hook: $a, this hook: $b" ;;
  esac
done <<'SQL'
select name, version from workflows where active = true order by name
SELECT count(*) FROM orders;
with recent as (select id, status from runs) select status, count(*) from recent group by status
explain select * from runs where id = 7
show search_path
select jsonb_build_object('a', 1), to_char(now(), 'YYYY-MM-DD') from events
explain (analyze, buffers) select kind, count(*) filter (where ok) over (partition by kind) from events
select filter(1)
insert into workflows (name) values ('x')
update workflows set note = note where false
delete from workflows where id = 1
alter table workflows add column note text
drop table workflows
truncate workflows
create table copy_of_runs as select * from runs
grant select on workflows to anon
select archive_old_runs(30)
select public.archive_old_runs(30)
select nextval('runs_id_seq')
call archive_old_runs(30)
with gone as (delete from runs where id = 1 returning id) select count(*) from gone
select 1; select 2
select * into runs_backup from runs
select * from runs where id = 1 for update
explain analyze delete from runs where id = 1
select 'drop table runs' as note
begin
do $$ begin delete from runs; end $$
/* note */ select 1
vacuum runs
selec t frm (( where
SQL
[ "$total" -ge 30 ] && check "the reconciliation ran every statement" ok || check "the reconciliation ran every statement" "ran $total"

# --- the pre-allowed Salesforce write tools on this Mac -----------------------------------------
SF_HOME="$WORK/sf-home"
mkdir -p "$SF_HOME/.claude"
printf '%s\n' '{"permissions": {"allow": ["Bash(ls:*)", "mcp__claude_ai_SFDC_USE__createSobjectRecord", "mcp__claude_ai_SFDC_USE__deleteSobjectRecord"]}}' > "$SF_HOME/.claude/settings.local.json"
SFP="$(tool_payload "${SF_WRITE}createSobjectRecord" '{"sobjectType": "Account", "fields": {}}')"
r="$(run "$HOOK" "$SF_HOME" "$SFP")"
got="$(decision "$r")"; msg="$(field "$r" message)"
[ "$got" = "none rc=0" ] && check "a pre-allowed Salesforce write is given no decision by the hook" ok || check "a pre-allowed Salesforce write is given no decision by the hook" "$got"
case "$msg" in *settings.local.json*createSobjectRecord*deleteSobjectRecord*) check "the hook says which Salesforce write tools are pre-allowed and where" ok ;; *) check "the hook says which Salesforce write tools are pre-allowed and where" "message: ${msg:0:300}" ;; esac
case "$msg" in *updateSobjectRecord*) check "the notice names only the tools actually allowed" "it names updateSobjectRecord, which is not allowed" ;; *) check "the notice names only the tools actually allowed" ok ;; esac
# The notice rides on a database question too.
r="$(run "$HOOK" "$SF_HOME" "$(payload "$SQL_TOOL" "$STMT")")"
case "$(decision "$r")|$(field "$r" message)" in "ask rc=0|"*createSobjectRecord*) check "a database question carries the Salesforce notice" ok ;; *) check "a database question carries the Salesforce notice" "$(decision "$r") $(field "$r" message)" ;; esac
# But never on a read it passes in silence.
r="$(run "$HOOK" "$SF_HOME" "$(payload "$SQL_TOOL" "select 1")")"
[ -z "${r%$'\n'rc=*}" ] && check "a passed select prints nothing, notice included" ok || check "a passed select prints nothing, notice included" "${r:0:200}"
# A whole server wildcard allows the write tools too.
printf '%s\n' '{"permissions": {"allow": ["mcp__claude_ai_SFDC_USE__*"]}}' > "$SF_HOME/.claude/settings.local.json"
case "$(field "$(run "$HOOK" "$SF_HOME" "$SFP")" message)" in *"mcp__claude_ai_SFDC_USE__*"*) check "a server wildcard allow is reported" ok ;; *) check "a server wildcard allow is reported" "no notice" ;; esac
printf '%s\n' '{"permissions": {"allow": ["mcp__claude_ai_SFDC_USE"]}}' > "$SF_HOME/.claude/settings.local.json"
case "$(field "$(run "$HOOK" "$SF_HOME" "$SFP")" message)" in *settings.local.json*) check "a bare server allow is reported" ok ;; *) check "a bare server allow is reported" "no notice" ;; esac
# No allow, or no file: silence.
printf '%s\n' '{"permissions": {"allow": ["mcp__claude_ai_SFDC_USE__soqlQuery"]}}' > "$SF_HOME/.claude/settings.local.json"
r="$(run "$HOOK" "$SF_HOME" "$SFP")"
[ -z "${r%$'\n'rc=*}" ] && check "a settings file with no Salesforce write allow says nothing" ok || check "a settings file with no Salesforce write allow says nothing" "${r:0:200}"
r="$(run "$HOOK" "$EMPTY_HOME" "$SFP")"
[ -z "${r%$'\n'rc=*}" ] && check "no settings.local.json says nothing" ok || check "no settings.local.json says nothing" "${r:0:200}"
# A settings file it cannot read is said, never taken as no allow.
printf '%s\n' '{"permissions": ' > "$SF_HOME/.claude/settings.local.json"
r="$(run "$HOOK" "$SF_HOME" "$SFP")"
case "$(decision "$r")|$(field "$r" message)" in "none rc=0|"*"could not"*settings.local.json*) check "an unreadable settings.local.json is said" ok ;; *) check "an unreadable settings.local.json is said" "$(decision "$r") $(field "$r" message)" ;; esac

# --- with no python3 the hook still asks, and says python3 is what is missing (#486, #2521) -------
# The classifier is python3, so on a machine without it no statement can be judged read only: every
# database call is asked about, a select included, and the question names the missing reader rather
# than reading as a crash.
. "$DIR/lib/no-python-path.sh"
NOPY="$WORK/nopy/bin"
npp_build_bin "$NOPY"
if npp_reaches_python3 "$NOPY"; then
  check "the bare directory reaches no python3" "it found one, so nothing below measures its absence"
else
  run_nopy() { local out rc; out="$(cd "$WORK" && printf '%s' "$1" | env -u CLAUDE_HOME HOME="$EMPTY_HOME" PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>/dev/null)"; rc=$?; printf '%s\nrc=%s\n' "$out" "$rc"; }
  for q in "select 1" "$STMT"; do
    r="$(run_nopy "$(payload "$SQL_TOOL" "$q")")"
    case "$(decision "$r")|$(field "$r" reason)" in
      "ask rc=0|"*"python3 is not on PATH"*) check "with no python3, [$q] is asked about, naming python3" ok ;;
      *) check "with no python3, [$q] is asked about, naming python3" "$(decision "$r") $(field "$r" reason)" ;;
    esac
  done
  r="$(run_nopy "$(payload "$MIG_TOOL" "create table t (a int)")")"
  [ "$(decision "$r")" = "ask rc=0" ] && check "with no python3 a migration is asked about" ok || check "with no python3 a migration is asked about" "$(decision "$r")"
  r="$(run_nopy "$SFP")"
  [ "$(decision "$r")" = "none rc=0" ] && check "with no python3 a Salesforce write is given no decision" ok || check "with no python3 a Salesforce write is given no decision" "$(decision "$r")"
fi

# --- with lib/hook-notice.sh missing beside it, the hook still asks, in valid JSON --------------
NOLIB="$WORK/nolib"
mkdir -p "$NOLIB"
cp "$HOOK" "$NOLIB/db-write-ask.sh"
cp -R "$DIR/lib" "$NOLIB/lib"
rm -f "$NOLIB/lib/hook-notice.sh"
r="$(run "$NOLIB/db-write-ask.sh" "$EMPTY_HOME" "$(payload "$SQL_TOOL" "update t set a = 'x' where \"b\" = 1")")"
case "$(decision "$r")|$(field "$r" reason)" in
  "ask rc=0|"*"lib/hook-notice.sh is missing"*) check "with lib/hook-notice.sh missing, a write is still asked about and says why" ok ;;
  *) check "with lib/hook-notice.sh missing, a write is still asked about and says why" "$(decision "$r") $(field "$r" reason)" ;;
esac
printf '%s\n' '{"permissions": {"allow": ["mcp__claude_ai_SFDC_USE__createSobjectRecord"]}}' > "$SF_HOME/.claude/settings.local.json"
r="$(run "$NOLIB/db-write-ask.sh" "$SF_HOME" "$SFP")"
case "$(decision "$r")|$(field "$r" message)" in
  "none rc=0|"*createSobjectRecord*"lib/hook-notice.sh is missing"*) check "with lib/hook-notice.sh missing, the Salesforce notice is still said" ok ;;
  *) check "with lib/hook-notice.sh missing, the Salesforce notice is still said" "$(decision "$r") $(field "$r" message)" ;;
esac
r="$(run "$NOLIB/db-write-ask.sh" "$SF_HOME" "$(payload "$SQL_TOOL" "$STMT")")"
case "$(decision "$r")|$(field "$r" message)" in
  "ask rc=0|"*createSobjectRecord*) check "with lib/hook-notice.sh missing, a database question still carries the Salesforce notice" ok ;;
  *) check "with lib/hook-notice.sh missing, a database question still carries the Salesforce notice" "$(decision "$r") $(field "$r" message)" ;;
esac

# --- the settings run it for exactly these tools, and refuse the call if it fails ---------------
wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
hits = [(e.get("matcher", ""), h) for e in d.get("hooks", {}).get("PreToolUse", [])
        for h in e.get("hooks", []) if h.get("command", "").endswith("/hooks/db-write-ask.sh")]
if len(hits) != 1:
    print("registered %d times" % len(hits)); sys.exit()
m, h = hits[0]
want = ["mcp__claude_ai_Supabase__execute_sql", "mcp__claude_ai_Supabase__apply_migration"] + [
        "mcp__claude_ai_SFDC_USE__" + t for t in ("createSobjectRecord", "updateSobjectRecord", "deleteSobjectRecord")]
never = ["mcp__claude_ai_Supabase__list_tables", "mcp__claude_ai_SFDC_USE__soqlQuery",
         "mcp__claude_ai_SFDC_-_Read_Only__soqlQuery", "Bash", "Edit"]
bad = [t for t in want if not re.fullmatch(m, t)] + ["also " + t for t in never if re.search(m, t)]
if h.get("onFailure") != "block":
    bad.append("onFailure is not block, so a crash or a timeout would let a write through unasked")
print("ok" if not bad else "matcher %s: %s" % (m, ", ".join(bad)))
PY
)"
check "the settings run the hook for the two Supabase SQL tools and the three Salesforce write tools, blocking on failure" "$wiring"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
