#!/usr/bin/env bash
# send-gate: scans settings.hooks.json
# Tests for the hook that asks Dan before any database SQL call that is not read only
# (claude-config#2521), before a Supabase tool that changes a database with no SQL (#2632), and
# before an edge function deploy that turns JWT verification off (#2660).
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
# A call naming no database client or tool gets nothing from it: this Bash command holds SQL
# words but runs no client, so the hook, which now reads every Bash call, has nothing to ask.
expect "a Bash command with SQL words but no database client gets no decision" none "$(tool_payload Bash '{"command": "update t set a = 1"}')"
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

# --- any other database tool, and database clients run in a shell (claude-config#2536) ----------
# #2521 asked only about the claude.ai Supabase connector's two SQL tools, so a write through any
# other database tool, or through psql and its like in a Bash call, still went unasked. The same hook
# now reads those too, with the one read only rule (lib/sql-read-only.py), and asks about anything
# it cannot classify. The tool names are the ones measured on the personal MacBook on 2026-11-10
# (settings, ~/.claude.json and every transcript), plus invented ones for a connector not yet seen.
bash_payload() {  # bash_payload <command>
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "cwd": "/tmp", "tool_name": "Bash", "tool_input": {"command": sys.argv[1], "description": "d"}}))' "$1"
}
expect_bash() { expect "Bash [$3]: $1" "$2" "$(bash_payload "$3")"; }  # <label> <want> <command>
reason_of() { field "$(run "$HOOK" "$EMPTY_HOME" "$1")" reason; }

# The cases the issue names.
PSQL_UPDATE='psql "$DATABASE_URL" -c "update workflows set note = note where false"'
expect_bash "a psql -c update is asked about" ask "$PSQL_UPDATE"
reason="$(reason_of "$(bash_payload "$PSQL_UPDATE")")"
case "$reason" in *"update workflows set note = note where false"*) check "the question about a psql update names the statement" ok ;; *) check "the question about a psql update names the statement" "reason: ${reason:0:300}" ;; esac
expect_bash "a psql -c select is not" none 'psql "$DATABASE_URL" -c "select id, name from workflows where active = true"'
UNKNOWN_WRITE="$(tool_payload mcp__acme_warehouse__run_sql '{"sql": "update orders set total = 0"}')"
expect "an unknown database tool's write is asked about" ask "$UNKNOWN_WRITE"
expect "an unknown database tool's read is not" none "$(tool_payload mcp__acme_warehouse__run_sql '{"sql": "select id from orders"}')"
reason="$(reason_of "$UNKNOWN_WRITE")"
case "$reason" in *mcp__acme_warehouse__run_sql*"update orders set total = 0"*) check "the question about an unknown tool names the tool and the statement" ok ;; *) check "the question about an unknown tool names the tool and the statement" "reason: ${reason:0:300}" ;; esac
# A statement it cannot classify is asked about, never passed.
expect_bash "a statement that does not parse is asked about" ask 'psql -c "selec t frm (( where"'
expect_bash "a statement held in a shell variable is asked about" ask 'psql -c "$QUERY"'
expect_bash "a select with a shell variable inside it is asked about" ask 'psql -c "select * from runs where id = $ID"'
expect_bash "statements in a file are asked about" ask 'psql "$url" -X -1 -v ON_ERROR_STOP=1 -f change.sql'
expect_bash "statements on its input (a heredoc) are asked about" ask $'psql "$url" <<SQL\nupdate runs set note = 1;\nSQL'
expect_bash "statements piped into it are asked about" ask 'echo "update runs set note = 1" | psql'
expect_bash "an option the hook does not know is asked about" ask 'psql --no-such-option -c "select 1"'
expect_bash "a psql variable in the statement is asked about" ask 'psql -v cond="1; delete from runs" -c "select :cond"'
expect "an unknown SQL tool with no statement it can find is asked about" ask "$(tool_payload mcp__acme_warehouse__run_sql '{"text": "update orders set total = 0"}')"
expect "an unknown SQL tool whose statement is not text is asked about" ask "$(tool_payload mcp__acme_warehouse__run_sql '{"sql": 7}')"
expect "an unknown SQL tool whose input is not an object is asked about" ask "$(python3 -c 'import json; print(json.dumps({"tool_name": "mcp__acme_warehouse__run_sql", "tool_input": "update t set a = 1"}))')"
expect "a list of statements holding one write is asked about" ask "$(tool_payload mcp__acme_warehouse__run_sql '{"statements": ["select 1", "delete from orders"]}')"
expect "a list of read only statements is not" none "$(tool_payload mcp__acme_warehouse__run_sql '{"statements": ["select 1", "select 2"]}')"

# psql in the shapes a command really takes.
expect_bash "bundled options ending in -c, a select" none 'psql "$U" -XAtc "select count(*) from runs"'
expect_bash "bundled options ending in -c, a delete" ask 'psql "$U" -XAtc "delete from runs"'
expect_bash "--command= with a select, its output redirected and piped" none 'psql --command="select 1" 2>/dev/null > out.txt | head -5'
expect_bash "two -c, the second a write" ask 'psql -c "select 1" -c "truncate runs"'
expect_bash "an assignment, cd and sudo in front" ask 'cd /srv && PGPASSWORD=x sudo -u postgres psql -c "drop table runs"'
expect_bash "inside bash -c" ask "bash -c 'psql -c \"delete from runs\"'"
expect_bash "inside a substitution" ask 'n="$(psql -Atc "delete from runs returning 1")"'
expect_bash "after then, in an if" ask 'if true; then psql -c "alter table runs add column x int"; fi'
expect_bash "through docker exec, a write" ask 'docker exec -i supabase_db psql -U postgres -c "update runs set note = 1"'
expect_bash "through docker exec, a select" none 'docker exec -i supabase_db psql -U postgres -c "select 1"'
expect_bash "through ssh, in one quoted string" ask "ssh db.example.com \"psql -c 'delete from runs'\""
expect_bash "through npx" ask 'npx supabase db push'
expect_bash "a psql meta command is not provably a read" ask 'psql -c "\copy runs from stdin"'
expect_bash "psql --version runs nothing" none 'psql --version'
expect_bash "psql --help runs nothing" none 'psql --help'
expect_bash "psql -l only lists" none 'psql -l'
expect_bash "a wrapper the hook cannot read that names a client" ask 'eval "$RUNNER psql -c \"delete from runs\""'
# A mention is not a run.
expect_bash "a search for the word" none 'grep -n psql notes.txt'
expect_bash "a message naming it" none 'echo "psql is not installed, so nothing ran"'
expect_bash "asking whether it is installed" none 'if ! command -v psql >/dev/null; then echo missing; fi'
expect_bash "which" none 'which psql sqlite3 mysql'
expect_bash "a commit message" none 'git commit -m "psql -c update wrapper"'
expect_bash "a heredoc body" none $'cat > notes.md <<EOF\npsql -c "delete from runs"\nEOF'
expect_bash "a script named after it" none 'bash scripts/psql-backup.sh'
# Both measured in the 30 days of Bash calls to 2026-11-10: eval of what a read prints (10 calls),
# and a note handed to a script as data (1).
expect_bash "eval of what a read only client command prints" none 'eval "$(supabase status -o env | grep API_URL)"'
expect_bash "a script handed the word as data" none 'bash ~/.claude/hooks/lib/issue-spool.sh note . "psql was slow to start" "2536 agent"'
expect_bash "a command with no client in it" none 'ls -la'

# mysql, mariadb and sqlite3.
expect_bash "mysql -e, an update" ask 'mysql -uroot -psecret shop -e "update orders set total = 0"'
expect_bash "mysql -e, a select" none 'mysql -uroot -psecret -NBe "select count(*) from orders" shop'
expect_bash "mysql --execute=, a drop" ask 'mysql --execute="drop table orders"'
expect_bash "mysql with nothing to run reads its input" ask 'mysql shop < dump.sql'
expect_bash "mariadb -e, a delete" ask 'mariadb -e "delete from orders"'
expect_bash "sqlite3, a select" none 'sqlite3 app.db "select id, name from shows"'
expect_bash "sqlite3 -readonly with options, a select, redirected" none 'sqlite3 -readonly -header -separator "|" app.db "select id from shows" > out.txt 2>&1'
expect_bash "sqlite3, a delete" ask 'sqlite3 app.db "delete from shows"'
expect_bash "sqlite3, two statement words, the second a write" ask 'sqlite3 app.db "select 1" "drop table shows"'
expect_bash "sqlite3, a dot command" ask 'sqlite3 app.db ".read change.sql"'
expect_bash "sqlite3 with no statement reads its input" ask 'sqlite3 app.db'
expect_bash "sqlite3 -cmd holds a statement too" ask 'sqlite3 -cmd "delete from shows" app.db "select 1"'
# A statement that only runs BEFORE the client reads its input does not stand in for that input.
expect_bash "sqlite3 -cmd with a select still reads the write piped into it" ask 'echo "delete from shows" | sqlite3 -cmd "select 1" app.db'
expect_bash "mysql --init-command with a select still reads the file given as its input" ask 'mysql --init-command="select 1" shop < dump.sql'
expect_bash "a quoted > is a statement word, never a redirection" ask "sqlite3 app.db '>' 'delete from shows'"
expect_bash "sqlite3 -version runs nothing" none 'sqlite3 -version'

# The Supabase CLI's database subcommands (the routes /db-apply uses).
expect_bash "supabase db query, a select" none 'supabase db query --linked "select count(*) from runs"'
expect_bash "supabase db query, an update" ask 'supabase db query --linked --yes "update runs set note = 1"'
expect_bash "supabase db query from a file" ask 'supabase db query --linked --yes -f change.sql'
expect_bash "supabase db query asking only for help" none 'supabase db query --linked --file /dev/null --help'
expect_bash "supabase db push" ask 'supabase db push --yes'
expect_bash "supabase db push --dry-run changes nothing" none 'supabase db push --dry-run'
expect_bash "supabase db push --dry-run=true changes nothing" none 'supabase db push --dry-run=true'
# A dry run flag set to anything but true is a real push (lessons review, fc56bfb).
expect_bash "supabase db push --dry-run=false is a real push" ask 'supabase db push --dry-run=false'
expect_bash "supabase db push --dry-run=0 is a real push" ask 'supabase db push --dry-run=0'
expect_bash "a dry run flag undone by a later false is a real push" ask 'supabase db push --dry-run --dry-run=false'
expect_bash "supabase db reset" ask 'supabase db reset --linked'
expect_bash "supabase migration up" ask 'supabase migration up --linked'
expect_bash "supabase migration list only reads" none 'supabase migration list'
expect_bash "supabase db diff only reads" none 'supabase db diff --linked'
expect_bash "a supabase db subcommand the hook does not know" ask 'supabase db nosuchcmd'
expect_bash "supabase status" none 'supabase status -o env'
# The CLI's own branch and project subcommands change a database with no statement, as the
# connector's tools further down do, so asking about one route and not the other would leave the
# unasked one as the way round (claude-config#2632, L450). Names from the CLI's help (2.75.0).
expect_bash "supabase branches delete" ask 'supabase branches delete preview-1'
expect_bash "supabase branches create" ask 'supabase branches create preview-1 --project-ref abcdefgh'
expect_bash "supabase branches pause" ask 'supabase branches pause preview-1'
expect_bash "supabase branches unpause" ask 'supabase branches unpause preview-1'
expect_bash "supabase branches update" ask 'supabase branches update preview-1 --persistent'
expect_bash "supabase branches behind a project ref" ask 'supabase --project-ref abcdefgh branches delete preview-1'
expect_bash "supabase branches list only reads" none 'supabase branches list'
expect_bash "supabase branches get only reads" none 'supabase branches get preview-1'
expect_bash "a supabase branches subcommand the hook does not know" ask 'supabase branches nosuchcmd'
expect_bash "supabase projects delete" ask 'supabase projects delete abcdefgh'
expect_bash "supabase projects create" ask 'supabase projects create shop --org-id exampleorg --region us-east-1'
expect_bash "supabase projects list only reads" none 'supabase projects list'
expect_bash "supabase projects api-keys only reads" none 'supabase projects api-keys --project-ref abcdefgh'
expect_bash "supabase projects --help runs nothing" none 'supabase projects --help'
expect_bash "supabase branches delete --help runs nothing" none 'supabase branches delete --help'
# A deploy with JWT verification off publishes a function the platform lets anyone call without
# signing in, which is not a change to a database and is asked about all the same
# (claude-config#2660). In a shell the setting can sit in the project's supabase/config.toml, where
# no flag shows it and the hook never reads, so Dan decided on 2026-11-10 ("Ask on every shell
# deploy") that every `supabase functions deploy` is asked about, whatever its flags. That reverses
# #2632's "supabase functions deploy changes no database", which this check held as a pass. The
# flag and the subcommands are from `supabase functions deploy --help` and `supabase functions
# --help`, CLI 2.75.0.
expect_bash "a plain function deploy, naming no function" ask 'supabase functions deploy'
expect_bash "a function deploy naming its function" ask 'supabase functions deploy hello'
expect_bash "a function deploy with --no-verify-jwt" ask 'supabase functions deploy hello --no-verify-jwt'
expect_bash "--no-verify-jwt before the function's name" ask 'supabase functions deploy --no-verify-jwt hello'
expect_bash "--no-verify-jwt with no function named, which deploys them all" ask 'supabase functions deploy --no-verify-jwt'
expect_bash "--no-verify-jwt=true" ask 'supabase functions deploy hello --no-verify-jwt=true'
expect_bash "--no-verify-jwt behind a project ref" ask 'supabase --project-ref abcdefgh functions deploy hello --no-verify-jwt'
expect_bash "--no-verify-jwt behind a deploy flag that takes a value" ask 'supabase functions -j 2 deploy hello --no-verify-jwt'
expect_bash "--no-verify-jwt through npx" ask 'npx supabase functions deploy hello --no-verify-jwt'
expect_bash "--no-verify-jwt in the second command of a line" ask 'cd app && supabase functions deploy hello --no-verify-jwt'
expect_bash "--no-verify-jwt set to false and then given bare" ask 'supabase functions deploy hello --no-verify-jwt=false --no-verify-jwt'
expect_bash "--no-verify-jwt with a value that is neither true nor false" ask 'supabase functions deploy hello --no-verify-jwt=maybe'
expect_bash "an older CLI's --verify-jwt=false" ask 'supabase functions deploy hello --verify-jwt=false'
expect_bash "a deploy with --no-verify-jwt=false is asked about as any deploy is" ask 'supabase functions deploy hello --no-verify-jwt=false'
expect_bash "a deploy with --verify-jwt=true is asked about as any deploy is" ask 'supabase functions deploy hello --verify-jwt=true'
expect_bash "a deploy with its other flags" ask 'supabase functions deploy hello --project-ref abcdefgh --use-api -j 4 --import-map ./import_map.json'
expect_bash "a plain deploy through npx" ask 'npx supabase functions deploy hello'
expect_bash "a plain deploy behind a workdir" ask 'supabase --workdir app functions deploy hello'
expect_bash "a deploy --no-verify-jwt --help runs nothing" none 'supabase functions deploy --no-verify-jwt --help'
expect_bash "a deploy --help runs nothing" none 'supabase functions deploy --help'
expect_bash "a mention of a deploy runs nothing" none 'echo "then run supabase functions deploy hello"'
expect_bash "supabase functions new only writes a file here" none 'supabase functions new hello'
expect_bash "supabase functions download" none 'supabase functions download hello'
expect_bash "supabase functions serve --no-verify-jwt runs on this Mac only" none 'supabase functions serve --no-verify-jwt'
expect_bash "supabase functions serve of a function named deploy" none 'supabase functions serve deploy --no-verify-jwt'
expect_bash "supabase functions list" none 'supabase functions list --project-ref abcdefgh'
expect_bash "a db reset is still asked about with the flag beside it" ask 'supabase db reset --no-verify-jwt'
OPEN_DEPLOY='supabase functions deploy hello --no-verify-jwt --project-ref abcdefgh'
reason="$(reason_of "$(bash_payload "$OPEN_DEPLOY")")"
case "$reason" in
  *"asks before this edge function deploy"*"edge function hello"*"project abcdefgh"*"JWT verification off"*"without signing in"*"claude-config#2660"*) check "the question about a --no-verify-jwt deploy names the function, the project and what is turned off" ok ;;
  *) check "the question about a --no-verify-jwt deploy names the function, the project and what is turned off" "reason: ${reason:0:400}" ;;
esac
case "$reason" in *"database call"*) check "the question about a --no-verify-jwt deploy does not call it a database call" "reason: ${reason:0:400}" ;; *) check "the question about a --no-verify-jwt deploy does not call it a database call" ok ;; esac
reason="$(reason_of "$(bash_payload 'supabase functions deploy --no-verify-jwt')")"
case "$reason" in
  *"all functions"*"the linked project"*"JWT verification off"*) check "a --no-verify-jwt deploy naming no function or project says all functions and the linked project" ok ;;
  *) check "a --no-verify-jwt deploy naming no function or project says all functions and the linked project" "reason: ${reason:0:400}" ;;
esac
# A deploy whose flags do not turn verification off says where the setting it cannot see is kept,
# and never says verification is off or on.
reason="$(reason_of "$(bash_payload 'supabase functions deploy')")"
case "$reason" in
  *"JWT verification off"*) check "a plain deploy naming no function says all functions and where the setting is kept" "it says verification is off: ${reason:0:400}" ;;
  *"asks before this edge function deploy"*"supabase functions deploy publishes all functions"*"the linked project"*"config.toml"*"claude-config#2660"*) check "a plain deploy naming no function says all functions and where the setting is kept" ok ;;
  *) check "a plain deploy naming no function says all functions and where the setting is kept" "reason: ${reason:0:400}" ;;
esac
reason="$(reason_of "$(bash_payload 'supabase functions deploy hello --project-ref abcdefgh')")"
case "$reason" in
  *"JWT verification off"*) check "a plain deploy naming its function names it, the project and where the setting is kept" "it says verification is off: ${reason:0:400}" ;;
  *"asks before this edge function deploy"*"edge function hello"*"project abcdefgh"*"config.toml"*"claude-config#2660"*) check "a plain deploy naming its function names it, the project and where the setting is kept" ok ;;
  *) check "a plain deploy naming its function names it, the project and where the setting is kept" "reason: ${reason:0:400}" ;;
esac
case "$reason" in *"database call"*) check "the question about a plain deploy does not call it a database call" "reason: ${reason:0:400}" ;; *) check "the question about a plain deploy does not call it a database call" ok ;; esac
reason="$(reason_of "$(bash_payload 'supabase functions deploy hello --no-verify-jwt=false')")"
case "$reason" in
  *"JWT verification off"*) check "a deploy with --no-verify-jwt=false names the flag and does not say verification is off" "it says verification is off: ${reason:0:400}" ;;
  *"--no-verify-jwt=false"*"edge function hello"*"config.toml"*) check "a deploy with --no-verify-jwt=false names the flag and does not say verification is off" ok ;;
  *) check "a deploy with --no-verify-jwt=false names the flag and does not say verification is off" "reason: ${reason:0:400}" ;;
esac
reason="$(reason_of "$(bash_payload 'supabase functions deploy hello world -j 2 --no-verify-jwt')")"
case "$reason" in
  *"edge functions hello, world "*) check "a --no-verify-jwt deploy of two functions names both, and not the value of -j" ok ;;
  *) check "a --no-verify-jwt deploy of two functions names both, and not the value of -j" "reason: ${reason:0:400}" ;;
esac
# One command line holding a database write and an open deploy is one question about both.
reason="$(reason_of "$(bash_payload 'supabase db reset && supabase functions deploy hello --no-verify-jwt')")"
case "$reason" in
  *"database call and edge function deploy"*"supabase db reset"*"JWT verification off"*"claude-config#2536"*"claude-config#2660"*) check "a db reset and a --no-verify-jwt deploy in one command are both in the question" ok ;;
  *) check "a db reset and a --no-verify-jwt deploy in one command are both in the question" "reason: ${reason:0:400}" ;;
esac
# The branch and project rule is added to the db and migration one, never read in its place, so no
# command asked about before #2632 lost its question to a branches or projects word beside it.
expect_bash "a db reset is asked about whatever stands before it" ask 'supabase projects list db reset'
expect_bash "a project delete is asked about whatever its ref is" ask 'supabase projects delete db'
case "$(reason_of "$(bash_payload 'supabase projects delete abcdefgh')")" in
  *"supabase projects delete deletes a project and its database"*) check "the question about supabase projects delete says what it does" ok ;;
  *) check "the question about supabase projects delete says what it does" "$(reason_of "$(bash_payload 'supabase projects delete abcdefgh')")" ;;
esac
# A client whose statements the hook does not read is asked about whenever it runs.
expect_bash "pgcli" ask 'pgcli "$DATABASE_URL"'
expect_bash "pg_restore" ask 'pg_restore -d shop dump.tar'
expect_bash "dropdb" ask 'dropdb shop'
expect_bash "pgcli --help runs nothing" none 'pgcli --help'
# A help or version word counts only when it is the whole command: in these clients -h is the HOST,
# so a word that reads as help elsewhere in a real run must not let it pass (lessons review, 5cb8288).
expect_bash "dropdb -h names the host, so it is asked about" ask 'dropdb -h prod.example.com shop'
expect_bash "pgcli -h names the host, so it is asked about" ask 'pgcli -h prod.example.com shop'
expect_bash "a version word beside a real restore is asked about" ask 'pg_restore --version -d shop dump.tar'
expect_bash "dropdb --version alone runs nothing" none 'dropdb --version'

# Other database tools, by the names measured on this Mac and by invented ones.
expect "the project level Supabase server's execute_sql, a write" ask "$(tool_payload mcp__supabase__execute_sql '{"query": "update runs set note = 1"}')"
expect "the project level Supabase server's execute_sql, a select" none "$(tool_payload mcp__supabase__execute_sql '{"query": "select 1"}')"
expect "the project level Supabase server's apply_migration" ask "$(tool_payload mcp__supabase__apply_migration '{"name": "n", "query": "select 1"}')"
expect "query_logs with a select over logs" none "$(tool_payload mcp__claude_ai_Supabase__query_logs '{"project_id": "p", "sql": "select count(*) from logs"}')"
expect "query_logs with a write" ask "$(tool_payload mcp__claude_ai_Supabase__query_logs '{"project_id": "p", "sql": "insert into logs values (1)"}')"
expect "run_notebook, whose statements are in the notebook" ask "$(tool_payload mcp__claude_ai_Supabase__run_notebook '{"project_id": "p", "notebook_id": "n", "expected_updated_at": "t"}')"
expect "a database server's query tool, a delete" ask "$(tool_payload mcp__postgres__query '{"query": "delete from runs"}')"
expect "a database server's query tool, a select" none "$(tool_payload mcp__postgres__query '{"query": "select 1"}')"
expect "a database server's tool that carries no statement" none "$(tool_payload mcp__postgres__list_tables '{"schema": "public"}')"
expect "a camel case SQL tool" ask "$(tool_payload mcp__acme__executeSql '{"sqlQuery": "drop table runs"}')"
# Measured names that are no database execution: none of them may be asked about.
while IFS=$'\t' read -r t input; do
  [ -n "$t" ] || continue
  expect "$t is not asked about" none "$(tool_payload "$t" "$input")"
done <<'TOOLS'
mcp__claude_ai_SFDC_USE__soqlQuery	{"q": "SELECT Id FROM Account LIMIT 5"}
mcp__claude_ai_SFDC_-_Read_Only__soqlQuery	{"q": "SELECT Id FROM Account LIMIT 5"}
mcp__claude_ai_Claude_Docs__query	{"object": "utterance", "payload": "update the plan"}
mcp__claude_ai_Supabase__search_docs	{"graphql_query": "{ searchDocs(query: \"delete rows\") { nodes { title } } }"}
mcp__claude_ai_Supabase__list_tables	{"project_id": "p"}
mcp__posthog__exec	{"command": "call execute-sql {\"query\": \"select 1\"}", "context": "c"}
mcp__claude_ai_Slack__slack_search_channels	{"query": "update on the migration"}
mcp__sentry__search_issues	{"query": "is:unresolved delete"}
mcp__wix__ExecuteWixAPI	{"url": "https://example.com/query", "method": "POST"}
mcp__plugin_cloudflare_cloudflare-docs__migrate_pages_to_workers_guide	{}
mcp__job-watcher__keep_job	{"id": "sql"}
Edit	{"file_path": "/tmp/x.sql", "old_string": "select", "new_string": "delete from runs"}
TOOLS

# --- the Supabase tools that change a database with no statement (claude-config#2632) ----------
# merge_branch, reset_branch and rebase_branch carry no SQL, so nothing above saw them, and each
# changes a database. The payloads are in the shape the tool schemas declare (read 2026-11-10):
# merge_branch, rebase_branch and delete_branch take branch_id, reset_branch branch_id and an
# optional migration_version, create_branch project_id and name, pause_project and restore_project
# project_id, create_project name, region and organization_id. Every id is invented.
# expect_change <label> <payload> <text the question must hold>...
expect_change() {
  local label="$1" r got reason w missing=""
  r="$(run "$HOOK" "$EMPTY_HOME" "$2")"; shift 2
  got="$(decision "$r")"; reason="$(field "$r" reason)"
  for w in "$@"; do case "$reason" in *"$w"*) ;; *) missing="$missing [$w]" ;; esac; done
  if [ "$got" = "ask rc=0" ] && [ -z "$missing" ]; then check "$label" ok
  else check "$label" "wanted ask rc=0, got $got; the question lacks:${missing:- nothing}; it reads: ${reason:0:240}"; fi
}
SB="mcp__claude_ai_Supabase__"
expect_change "merge_branch is asked about, naming the tool, the branch and production" "$(tool_payload "${SB}merge_branch" '{"branch_id": "examplebranch1"}')" "${SB}merge_branch" "branch examplebranch1" "production" "claude-config#2632"
expect_change "reset_branch is asked about, naming the branch and what is lost" "$(tool_payload "${SB}reset_branch" '{"branch_id": "examplebranch1"}')" "${SB}reset_branch" "branch examplebranch1" "to its migrations" "is lost" "claude-config#2632"
expect_change "reset_branch to a version names the version" "$(tool_payload "${SB}reset_branch" '{"branch_id": "examplebranch1", "migration_version": "20261101120000"}')" "branch examplebranch1" "migration version 20261101120000" "is lost"
expect_change "rebase_branch is asked about, naming the branch" "$(tool_payload "${SB}rebase_branch" '{"branch_id": "examplebranch1"}')" "${SB}rebase_branch" "branch examplebranch1" "migrations" "claude-config#2632"
expect_change "delete_branch is asked about, naming the branch" "$(tool_payload "${SB}delete_branch" '{"branch_id": "examplebranch1"}')" "${SB}delete_branch" "branch examplebranch1" "database"
expect_change "create_branch is asked about, naming the branch and its project" "$(tool_payload "${SB}create_branch" '{"project_id": "exampleprodproject", "name": "develop"}')" "${SB}create_branch" "named develop" "project exampleprodproject" "billed"
expect_change "create_project is asked about, naming the project and its organization" "$(tool_payload "${SB}create_project" '{"name": "shop", "region": "us-east-1", "organization_id": "exampleorg"}')" "${SB}create_project" "named shop" "organization exampleorg" "bill"
expect_change "pause_project is asked about, naming the project" "$(tool_payload "${SB}pause_project" '{"project_id": "exampleprodproject"}')" "${SB}pause_project" "project exampleprodproject" "offline"
expect_change "restore_project is asked about, naming the project" "$(tool_payload "${SB}restore_project" '{"project_id": "exampleprodproject"}')" "${SB}restore_project" "project exampleprodproject"
# The same tools on any other Supabase server, and written in camel case.
expect_change "the project level Supabase server's merge_branch" "$(tool_payload mcp__supabase__merge_branch '{"branch_id": "examplebranch1"}')" "mcp__supabase__merge_branch" "branch examplebranch1"
expect_change "a plugin's Supabase server's delete_branch" "$(tool_payload mcp__plugin_supabase_supabase__delete_branch '{"branch_id": "examplebranch1"}')" "branch examplebranch1"
expect_change "a camel case resetBranch on a Supabase server" "$(tool_payload mcp__supabase__resetBranch '{"branch_id": "examplebranch1"}')" "branch examplebranch1" "is lost"
# A target the call does not name, or names as something other than text, is said to be so: the
# question never reads as though it named one.
expect_change "merge_branch naming no branch says none is named" "$(tool_payload "${SB}merge_branch" '{}')" "branch (none named)"
expect_change "merge_branch with an empty branch says none is named" "$(tool_payload "${SB}merge_branch" '{"branch_id": ""}')" "branch (none named)"
expect_change "merge_branch whose branch is not text says so" "$(tool_payload "${SB}merge_branch" '{"branch_id": ["examplebranch1"]}')" "branch (not text)"
expect_change "merge_branch whose input is not an object says none is named" "$(tool_payload "${SB}merge_branch" 'null')" "branch (none named)"
long_id="$(printf 'b%.0s' $(seq 1 300))"
r="$(run "$HOOK" "$EMPTY_HOME" "$(tool_payload "${SB}delete_branch" "{\"branch_id\": \"$long_id\"}")")"
reason="$(field "$r" reason)"
case "$(decision "$r")|$reason" in
  *"$long_id"*) check "a very long branch id is cut in the question, with its length said" "the whole 300 characters are in the question" ;;
  "ask rc=0|"*"300 characters in all"*) check "a very long branch id is cut in the question, with its length said" ok ;;
  *) check "a very long branch id is cut in the question, with its length said" "$(decision "$r") ${reason:0:240}" ;;
esac
r="$(cd "$WORK" && printf '{"tool_name": "mcp__claude_ai_Supabase__merge_branch", "tool_input": {"branch_id": "examplebr' | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
case "$(decision "$r")|$(field "$r" reason)" in
  "ask rc=0|"*merge_branch*) check "a cut short payload naming merge_branch is asked about, naming it" ok ;;
  *) check "a cut short payload naming merge_branch is asked about, naming it" "$(decision "$r") $(field "$r" reason)" ;;
esac
# Every tool in the library's table goes through the hook, so an entry added later is exercised on
# the day it lands and one whose sentence leaves a placeholder unfilled fails here (L96).
change_tools="$(python3 -I -B - "$DIR/lib/db-write-calls.py" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("db_write_calls_shared", sys.argv[1])
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
    print(" ".join(sorted(m.SUPABASE_CHANGES)))
except Exception as e:
    print("ERROR:" + type(e).__name__)
PY
)"
case "$change_tools" in
  *merge_branch*reset_branch*) check "the library lists the Supabase tools that change a database with no statement" ok ;;
  *) check "the library lists the Supabase tools that change a database with no statement" "got: ${change_tools:-nothing}" ;;
esac
for t in $change_tools; do
  case "$t" in ERROR:*) continue ;; esac
  r="$(run "$HOOK" "$EMPTY_HOME" "$(tool_payload "${SB}$t" '{"branch_id": "b9", "project_id": "p9", "name": "n9", "organization_id": "o9"}')")"
  reason="$(field "$r" reason)"
  case "$(decision "$r")|$reason" in
    *"{"*|*"}"*) check "$t from the library's table is asked about, its sentence filled in" "a placeholder is left in: ${reason:0:240}" ;;
    "ask rc=0|"*"${SB}$t "*"9"*) check "$t from the library's table is asked about, its sentence filled in" ok ;;
    *) check "$t from the library's table is asked about, its sentence filled in" "$(decision "$r") ${reason:0:240}" ;;
  esac
done

# --- an edge function deploy with JWT verification off (claude-config#2660) ---------------------
# deploy_edge_function with verify_jwt false publishes a function the platform lets anyone call
# without signing in. #2632 left every deploy unasked, as code and not a database; this one case is
# asked about, naming the function and the project. The payloads are in the shape the connector's
# schema declares (read 2026-11-10): project_id, name, entrypoint_path, verify_jwt and files, all
# required, verify_jwt a boolean whose default is true. Every id is invented.
DEPLOY="${SB}deploy_edge_function"
BODY='"entrypoint_path": "index.ts", "files": [{"name": "index.ts", "content": "Deno.serve(() => new Response(1))"}]'
deploy_payload() {  # deploy_payload <tool> <the fields before the entrypoint and files>
  tool_payload "$1" "{$2, $BODY}"
}
expect_change "a deploy with verify_jwt false is asked about, naming the function and the project" "$(deploy_payload "$DEPLOY" '"project_id": "exampleprodproject", "name": "hello", "verify_jwt": false')" "asks before this edge function deploy" "$DEPLOY" "edge function hello" "project exampleprodproject" "JWT verification off" "without signing in" "claude-config#2660"
reason="$(reason_of "$(deploy_payload "$DEPLOY" '"project_id": "exampleprodproject", "name": "hello", "verify_jwt": false')")"
case "$reason" in *"database call"*) check "the question about an open deploy does not call it a database call" "reason: ${reason:0:400}" ;; *) check "the question about an open deploy does not call it a database call" ok ;; esac
expect_change "the project level Supabase server's deploy with verify_jwt false" "$(deploy_payload mcp__supabase__deploy_edge_function '"project_id": "p", "name": "hello", "verify_jwt": false')" "mcp__supabase__deploy_edge_function" "edge function hello" "JWT verification off"
expect_change "a camel case deployEdgeFunction with verifyJwt false" "$(deploy_payload mcp__supabase__deployEdgeFunction '"project_id": "p", "name": "hello", "verifyJwt": false')" "edge function hello" "JWT verification off"
expect_change "a deploy with no_verify_jwt true" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "no_verify_jwt": true')" "JWT verification off"
expect_change "a deploy whose verify_jwt is the text false" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": "false"')" "JWT verification off"
expect_change "a deploy with verify_jwt true and no_verify_jwt true" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": true, "no_verify_jwt": true')" "JWT verification off"
# A value that is neither true nor false is asked about as one that could not be read, never
# passed: what the server makes of it was not measured.
expect_change "a deploy whose verify_jwt is null" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": null')" "edge function hello" "could not be told"
expect_change "a deploy whose verify_jwt is 0" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": 0')" "could not be told"
expect_change "a deploy whose verify_jwt is the text true" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": "true"')" "could not be told"
expect_change "a deploy whose verify_jwt is a list" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": [false]')" "could not be told"
expect_change "a deploy whose input is not an object" "$(tool_payload "$DEPLOY" 'null')" "$DEPLOY" "could not be told" "claude-config#2660"
expect_change "an open deploy naming no function or project says none is named" "$(tool_payload "$DEPLOY" '{"verify_jwt": false}')" "edge function (none named)" "project (none named)"
r="$(run "$HOOK" "$EMPTY_HOME" "$(deploy_payload "$DEPLOY" "\"project_id\": \"p\", \"name\": \"$long_id\", \"verify_jwt\": false")")"
reason="$(field "$r" reason)"
case "$(decision "$r")|$reason" in
  *"$long_id"*) check "a very long function name is cut in the question, with its length said" "the whole 300 characters are in the question" ;;
  "ask rc=0|"*"300 characters in all"*) check "a very long function name is cut in the question, with its length said" ok ;;
  *) check "a very long function name is cut in the question, with its length said" "$(decision "$r") ${reason:0:240}" ;;
esac
r="$(cd "$WORK" && printf '{"tool_name": "mcp__claude_ai_Supabase__deploy_edge_function", "tool_input": {"name": "hello", "verify_jwt": fal' | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
case "$(decision "$r")|$(field "$r" reason)" in
  "ask rc=0|"*deploy_edge_function*"JWT verification"*"claude-config#2660"*) check "a cut short payload naming deploy_edge_function is asked about, naming it" ok ;;
  *) check "a cut short payload naming deploy_edge_function is asked about, naming it" "$(decision "$r") $(field "$r" reason)" ;;
esac
# A deploy that keeps verification on is passed, as before #2660: verify_jwt true, and verify_jwt
# left out, since the schema's default is true. So is one whose own code mentions the setting, a
# tool that only reads a function, and the same tool name on a server that is not Supabase's.
while IFS=$'\t' read -r t input; do
  [ -n "$t" ] || continue
  expect "$t keeping JWT verification on is not asked about" none "$(tool_payload "$t" "$input")"
done <<'TOOLS'
mcp__claude_ai_Supabase__deploy_edge_function	{"project_id": "p", "name": "hello", "entrypoint_path": "index.ts", "files": [{"name": "index.ts", "content": "Deno.serve(() => new Response(1))"}]}
mcp__supabase__deploy_edge_function	{"project_id": "p", "name": "hello", "entrypoint_path": "index.ts", "verify_jwt": true, "files": [{"name": "index.ts", "content": "Deno.serve(() => new Response(1))"}]}
mcp__supabase__deployEdgeFunction	{"project_id": "p", "name": "hello", "verifyJwt": true, "noVerifyJwt": false}
mcp__claude_ai_Supabase__deploy_edge_function	{"project_id": "p", "name": "hello", "entrypoint_path": "index.ts", "verify_jwt": true, "files": [{"name": "config.toml", "content": "[functions.hello]\nverify_jwt = false"}, {"name": "index.ts", "content": "// \"verify_jwt\": false\nDeno.serve(() => new Response(1))"}]}
mcp__claude_ai_Supabase__get_edge_function	{"project_id": "p", "function_slug": "hello"}
mcp__claude_ai_Supabase__list_edge_functions	{"project_id": "p"}
mcp__acme_hosting__deploy_edge_function	{"name": "hello", "verify_jwt": false, "note": "moved from supabase"}
TOOLS
rm -rf "$WORK/part"; mkdir -p "$WORK/part/hooks"
cp "$HOOK" "$WORK/part/hooks/"; cp -R "$DIR/lib" "$WORK/part/hooks/lib"; rm -f "$WORK/part/hooks/lib/db-write-calls.py"
r="$(run "$WORK/part/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": false')")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with lib/db-write-calls.py missing, an open deploy is asked about" ok || check "with lib/db-write-calls.py missing, an open deploy is asked about" "$(decision "$r")"
rm -rf "$WORK/part"

# Decided in #2632 as no change to a database, so none of them may be asked about: an edge function
# deploy that keeps JWT verification on (one that turns it off is asked about, above) and its
# secret change code and configuration, a notebook is saved without being run (run_notebook is
# asked about, always), feedback goes to Supabase, and the rest only read. And the same tool names
# on a server that is not Supabase's are another product's branches.
while IFS=$'\t' read -r t input; do
  [ -n "$t" ] || continue
  expect "$t is not asked about" none "$(tool_payload "$t" "$input")"
done <<'TOOLS'
mcp__claude_ai_Supabase__deploy_edge_function	{"project_id": "p", "name": "hello", "entrypoint_path": "index.ts", "verify_jwt": true, "files": [{"name": "index.ts", "content": "Deno.serve(() => new Response('ok'))"}]}
mcp__claude_ai_Supabase__create_edge_function_secret	{"project_id": "p", "name": "API_KEY"}
mcp__claude_ai_Supabase__create_notebook	{"project_id": "p", "name": "n", "content": {"cells": [{"type": "database", "sql": "delete from runs", "row_limit": 10}]}}
mcp__claude_ai_Supabase__delete_notebook	{"project_id": "p", "notebook_id": "n"}
mcp__claude_ai_Supabase__submit_feedback	{"feedback": "merge_branch gave no result", "project_id": "p"}
mcp__claude_ai_Supabase__delete_feedback	{"delete_token": "t1", "project_id": "p"}
mcp__claude_ai_Supabase__list_branches	{"project_id": "p"}
mcp__claude_ai_Supabase__get_project	{"id": "p"}
mcp__github__create_branch	{"owner": "o", "repo": "supabase-app", "branch": "fix"}
mcp__github__merge_branch	{"owner": "o", "repo": "supabase-app", "base": "main", "head": "fix"}
mcp__linear__delete_branch	{"note": "the supabase reset_branch tool"}
TOOLS
# The read hook never approves any of these, so the two hooks still cannot disagree about one.
for p in "$(tool_payload mcp__acme_warehouse__run_sql '{"sql": "select 1"}')" "$(bash_payload 'psql -c "select 1"')" "$(tool_payload mcp__supabase__execute_sql '{"query": "select 1"}')" "$(tool_payload mcp__claude_ai_Supabase__merge_branch '{"branch_id": "examplebranch1"}')" "$(deploy_payload "$DEPLOY" '"project_id": "p", "name": "hello", "verify_jwt": false')"; do
  a="$(decision "$(run "$READ_HOOK" "$EMPTY_HOME" "$p")")"
  [ "$a" = "none rc=0" ] && check "the read hook gives no decision on a call outside its own tools" ok || check "the read hook gives no decision on a call outside its own tools" "$a"
done

# Payloads it cannot read, and its own parts missing: asked about, never passed.
expect "a Bash call whose command is not text, naming a client" ask "$(tool_payload Bash '{"command": ["psql", "-c", "delete from runs"]}')"
r="$(cd "$WORK" && printf '{"tool_name": "Bash", "tool_input": {"command": "psql -c \\"delete from runs' | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
[ "$(decision "$r")" = "ask rc=0" ] && check "a cut short Bash payload naming a client is asked about" ok || check "a cut short Bash payload naming a client is asked about" "$(decision "$r")"
r="$(cd "$WORK" && printf '{"tool_name": "mcp__acme_warehouse__run_sql", "tool_input": {"sql": "update t' | env -u CLAUDE_HOME HOME="$EMPTY_HOME" bash "$HOOK" 2>/dev/null; printf '\nrc=%s' "$?")"
[ "$(decision "$r")" = "ask rc=0" ] && check "a cut short payload naming an unknown SQL tool is asked about" ok || check "a cut short payload naming an unknown SQL tool is asked about" "$(decision "$r")"
for missing in db-write-calls.py shell-words.py sql-read-only.py; do
  rm -rf "$WORK/part"; mkdir -p "$WORK/part/hooks"
  cp "$HOOK" "$WORK/part/hooks/"; cp -R "$DIR/lib" "$WORK/part/hooks/lib"; rm -f "$WORK/part/hooks/lib/$missing"
  r="$(run "$WORK/part/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(bash_payload 'psql -c "select 1"')")"
  case "$(decision "$r")|$(field "$r" reason)" in
    "ask rc=0|"*"$missing"*) check "with lib/$missing missing, even a psql select is asked about, naming the file" ok ;;
    *) check "with lib/$missing missing, even a psql select is asked about, naming the file" "$(decision "$r") $(field "$r" reason)" ;;
  esac
done
rm -rf "$WORK/part"; mkdir -p "$WORK/part/hooks"
cp "$HOOK" "$WORK/part/hooks/"; cp -R "$DIR/lib" "$WORK/part/hooks/lib"; rm -f "$WORK/part/hooks/lib/db-write-calls.py"
r="$(run "$WORK/part/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(tool_payload mcp__acme_warehouse__run_sql '{"sql": "select 1"}')")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with lib/db-write-calls.py missing, an unknown SQL tool's select is asked about" ok || check "with lib/db-write-calls.py missing, an unknown SQL tool's select is asked about" "$(decision "$r")"
r="$(run "$WORK/part/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(bash_payload 'ls -la')")"
[ "$(decision "$r")" = "none rc=0" ] && check "with lib/db-write-calls.py missing, a command naming nothing of a database is still passed" ok || check "with lib/db-write-calls.py missing, a command naming nothing of a database is still passed" "$(decision "$r")"
# With no python3, a database client in a shell is asked about too, and a plain command is not.
if ! npp_reaches_python3 "$NOPY"; then
  r="$(run_nopy "$(bash_payload 'psql -c "select 1"')")"
  case "$(decision "$r")|$(field "$r" reason)" in
    "ask rc=0|"*"python3 is not on PATH"*) check "with no python3, a psql select is asked about, naming python3" ok ;;
    *) check "with no python3, a psql select is asked about, naming python3" "$(decision "$r") $(field "$r" reason)" ;;
  esac
  r="$(run_nopy "$(bash_payload 'ls -la')")"
  [ "$(decision "$r")" = "none rc=0" ] && check "with no python3, a command naming nothing of a database is passed" ok || check "with no python3, a command naming nothing of a database is passed" "$(decision "$r")"
fi

# The hook leaves early, before python3 starts, on a payload holding none of its screen words, so
# every word the classifier can ask about must hold one of them or that call would never be read.
screen="$(sed -n 's/^DB_SCREEN_WORDS="\(.*\)"$/\1/p' "$HOOK")"
[ -n "$screen" ] && check "the hook declares its screen words" ok || check "the hook declares its screen words" "no DB_SCREEN_WORDS line"
unscreened="$(python3 -I -B - "$DIR/lib/db-write-calls.py" "$screen" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("db_write_calls_shared", sys.argv[1])
m = importlib.util.module_from_spec(spec)
try:
    spec.loader.exec_module(m)
except Exception as e:
    print("lib/db-write-calls.py did not load: " + type(e).__name__); sys.exit()
words = sys.argv[2].split()
print(" ".join(sorted(w for w in m.asked_words() if not any(s in w.lower() for s in words))))
PY
)"
[ -z "$unscreened" ] && check "every client, tool and key the classifier knows holds a screen word" ok || check "every client, tool and key the classifier knows holds a screen word" "not screened: $unscreened"

# --- one Apply covers one migration (claude-config#2763) -----------------------------------------
# Applying one migration through /db-apply was a dry run, a push and a read back, each asked about
# after Dan had already answered the skill's own Apply or Cancel picker. Now: a dry run and a read
# from a file are approved by the read hook and never asked about; a push of the migration Dan's
# Apply names, to the project it names, unchanged since, in the session he gave it in, is let
# through; anything else is asked about as before. Dan, 2026-11-11: one Apply stays good for its
# migration file and project until the session ends. His answer is read from the session's own
# transcript, where Claude Code writes the picker's input and his choice. Every id is invented.
APPLY="$WORK/apply"
PROJ="$APPLY/proj"
mkdir -p "$PROJ/supabase/migrations" "$PROJ/supabase/.temp" "$APPLY/elsewhere"
printf 'create table a (id int);\n' > "$PROJ/supabase/migrations/001_first.sql"
printf 'alter table a add column note text;\n' > "$PROJ/supabase/migrations/002_note.sql"
printf 'exampleprojectref000' > "$PROJ/supabase/.temp/project-ref"
printf 'select count(*) from a;\n' > "$APPLY/readback.sql"
printf 'update a set note = 1;\n' > "$APPLY/write.sql"
cp "$APPLY/readback.sql" "$PROJ/readback.sql"
MIG="$PROJ/supabase/migrations/002_note.sql"
sha_of() { python3 -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"; }
# transcript <file> <session id> <migration> <sha256> <project ref> <answer> [prefilled]: a session
# transcript holding one /db-apply picker and Dan's answer, in the shape Claude Code writes them
# (read from this Mac's transcripts on 2026-11-11: the picker's input on an assistant entry, his
# choice in toolUseResult.answers on the user entry that carries its tool_result). The picker's
# "pending" is the dry run's list of migrations it would push: by default the one migration named,
# PENDING="a.sql,b.sql" sets another list, and PENDING=none leaves the key out.
# Before the picker it holds the dry run the skill runs first (#2829), as its own Bash call with a
# tool_use entry stamped as it was sent and a tool_result: by default the skill's own dry run, run
# in $PROJ, stamped as the transcript is written. DRY_CWD, DRY_CMD and DRY_AT (an ISO time, from
# now_iso) set its directory, command and stamp; DRY_ERR=1 makes it fail, DRY=none leaves it out,
# and DRY=after puts it after Dan's answer instead.
now_iso() { python3 -c 'import datetime; print(datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="milliseconds").replace("+00:00", "Z"))'; }
transcript() {
  DRY_CWD="${DRY_CWD-$PROJ}" python3 - "$@" <<'PY'
import datetime, json, os, sys
path, sid, mig, sha, ref, answer = sys.argv[1:7]
prefilled = len(sys.argv) > 7
q = "Apply migration 002_note.sql to project " + ref + "?"
ask = {"questions": [{"question": q, "header": "Migration", "multiSelect": False,
                      "options": [{"label": "Apply", "description": "Run it"}, {"label": "Cancel", "description": "Do not"}]}],
       "metadata": {"source": "db-apply", "migration": mig, "sha256": sha, "project_ref": ref}}
pending = os.environ.get("PENDING")
if pending is None:
    ask["metadata"]["pending"] = [os.path.basename(mig)]
elif pending != "none":
    ask["metadata"]["pending"] = [p for p in pending.split(",") if p]
if prefilled:
    ask["answers"] = {q: "Apply"}
stamp = os.environ.get("DRY_AT") or datetime.datetime.now(datetime.timezone.utc).isoformat(
    timespec="milliseconds").replace("+00:00", "Z")
dry_cmd = os.environ.get("DRY_CMD") or "supabase db push --dry-run"
dry = [
    {"type": "assistant", "sessionId": sid, "timestamp": stamp, "cwd": os.environ["DRY_CWD"], "message": {
        "role": "assistant", "content": [
            {"type": "tool_use", "id": "toolu_dry1", "name": "Bash", "input": {"command": dry_cmd, "description": "d"}}]}},
    {"type": "user", "sessionId": sid, "timestamp": stamp, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_dry1", "content": "Would push these migrations:\n 002_note.sql",
         "is_error": os.environ.get("DRY_ERR") == "1"}]}},
]
lines = [
    {"type": "user", "sessionId": sid, "message": {"role": "user", "content": "apply the migration"}},
    {"type": "assistant", "sessionId": sid, "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": "toolu_apply1", "name": "AskUserQuestion", "input": ask}]}},
    {"type": "user", "sessionId": sid, "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": "toolu_apply1", "content": "answered"}]},
     "toolUseResult": {"questions": ask["questions"], "answers": {q: answer}, "annotations": {}}},
]
where = os.environ.get("DRY")
if where == "after":
    lines += dry
elif where != "none":
    lines[1:1] = dry
with open(path, "w") as f:
    for l in lines:
        f.write(json.dumps(l) + "\n")
PY
}
# apply_payload <command> <cwd> <session id> <transcript>: a Bash call as Claude Code sends it.
apply_payload() {
  python3 -c 'import json, sys; print(json.dumps({"session_id": sys.argv[3], "transcript_path": sys.argv[4], "hook_event_name": "PreToolUse", "cwd": sys.argv[2], "tool_name": "Bash", "tool_input": {"command": sys.argv[1], "description": "d"}}))' "$@"
}
NONE_T="$APPLY/no-apply.jsonl"
printf '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n' > "$NONE_T"
GOOD_T="$APPLY/apply.jsonl"
transcript "$GOOD_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both() {  # both <label> <want read hook> <want this hook> <payload>
  local a b
  a="$(decision "$(run "$READ_HOOK" "$EMPTY_HOME" "$4")")"
  b="$(decision "$(run "$HOOK" "$EMPTY_HOME" "$4")")"
  [ "$a|$b" = "$2 rc=0|$3 rc=0" ] && check "$1" ok || check "$1" "wanted read hook $2, this hook $3; got read hook $a, this hook $b"
}
PUSH='supabase db push --linked --yes'

# The issue's set, through both hooks.
both "a dry run is approved and never asked about" allow none "$(apply_payload 'supabase db push --linked --dry-run' "$PROJ" s1 "$NONE_T")"
both "a select in a file is approved and never asked about" allow none "$(apply_payload "supabase db query --linked -f $APPLY/readback.sql" "$PROJ" s1 "$NONE_T")"
both "a select in a file named from the directory it runs in" allow none "$(apply_payload 'supabase db query --linked -f readback.sql' "$PROJ" s1 "$NONE_T")"
both "a select in a file, after a cd to its directory" allow none "$(apply_payload "cd $PROJ && supabase db query --linked -f readback.sql" "$APPLY/elsewhere" s1 "$NONE_T")"
both "a write in a file is asked about" none ask "$(apply_payload "supabase db query --linked --yes -f $APPLY/write.sql" "$PROJ" s1 "$NONE_T")"
both "a push with no Apply on record is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$NONE_T")"
both "a push of the migration Dan applied, to his project, is let through" none allow "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")"
both "the same push from a cd to the project is let through" none allow "$(apply_payload "cd $PROJ && $PUSH" "$APPLY/elsewhere" s1 "$GOOD_T")"
both "the same push named by --workdir is let through" none allow "$(apply_payload "supabase db push --linked --yes --workdir $PROJ" "$APPLY/elsewhere" s1 "$GOOD_T")"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")")" reason)"
case "$reason" in *002_note.sql*exampleprojectref000*) check "the release names the migration and the project" ok ;; *) check "the release names the migration and the project" "reason: ${reason:0:300}" ;; esac
# It lets the push through again in the same session (until the session ends, Dan's answer).
both "the Apply still covers a second push in the same session" none allow "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")"

# What the Apply does not cover is asked about, saying why.
OTHER_T="$APPLY/other-file.jsonl"
transcript "$OTHER_T" s1 "$PROJ/supabase/migrations/001_first.sql" "$(sha_of "$PROJ/supabase/migrations/001_first.sql")" exampleprojectref000 Apply
both "a push after an Apply for a different migration file is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$OTHER_T")"
PROJ_T="$APPLY/other-project.jsonl"
transcript "$PROJ_T" s1 "$MIG" "$(sha_of "$MIG")" otherprojectref00000 Apply
both "a push to a different project than the Apply named is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$PROJ_T")"
EDIT_T="$APPLY/edited.jsonl"
transcript "$EDIT_T" s1 "$MIG" "$(printf 'alter table a add column other text;\n' | python3 -c 'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())')" exampleprojectref000 Apply
both "a push of a migration edited since the Apply is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$EDIT_T")"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$PROJ" s1 "$EDIT_T")")" reason)"
case "$reason" in *"applies the pending migrations"*changed*) check "the question says the file changed since the Apply" ok ;; *) check "the question says the file changed since the Apply" "reason: ${reason:0:400}" ;; esac
both "an Apply from another session (lapsed) is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s2 "$GOOD_T")"
CANCEL_T="$APPLY/cancel.jsonl"
transcript "$CANCEL_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Cancel
both "a push after Dan answered Cancel is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$CANCEL_T")"
FILLED_T="$APPLY/prefilled.jsonl"
transcript "$FILLED_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply prefilled
both "a picker whose answer was filled in by the caller records nothing" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$FILLED_T")"
both "a transcript that cannot be read is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$APPLY/missing.jsonl")"
both "a push with --include-seed is asked about" none ask "$(apply_payload "supabase db push --linked --yes --include-seed" "$PROJ" s1 "$GOOD_T")"
both "a push with --db-url is asked about" none ask "$(apply_payload 'supabase db push --yes --db-url postgresql://x' "$PROJ" s1 "$GOOD_T")"
both "a push chained to another command is asked about" none ask "$(apply_payload "$PUSH && rm -f note.txt" "$PROJ" s1 "$GOOD_T")"
both "a push after a command that could rewrite the migration is asked about" none ask "$(apply_payload "cp $PROJ/supabase/migrations/001_first.sql $MIG; $PUSH" "$PROJ" s1 "$GOOD_T")"
both "a push from a directory held in a variable is asked about" none ask "$(apply_payload 'cd "$P" && supabase db push --linked --yes' "$PROJ" s1 "$GOOD_T")"
# A migration added after the Apply would be pushed with it, so it is asked about.
printf 'drop table a;\n' > "$PROJ/supabase/migrations/003_later.sql"
both "a push with a migration newer than the applied one is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")"
rm -f "$PROJ/supabase/migrations/003_later.sql"
# A push sends every migration the database has not had, so the Apply records the dry run's list of
# pending migrations, and covers the push only when that list is the one migration Dan applied
# (Dan held #2800 for this, 2026-11-11). An older migration never applied would otherwise go with it.
OLDER_T="$APPLY/older-pending.jsonl"
PENDING="001_first.sql,002_note.sql" transcript "$OLDER_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both "a push whose dry run also listed an older pending migration is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$OLDER_T")"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$PROJ" s1 "$OLDER_T")")" reason)"
case "$reason" in *001_first.sql*) check "the question names the other pending migration" ok ;; *) check "the question names the other pending migration" "reason: ${reason:0:400}" ;; esac
NOLIST_T="$APPLY/no-pending.jsonl"
PENDING=none transcript "$NOLIST_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both "a push whose Apply recorded no pending list is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$NOLIST_T")"
EMPTYLIST_T="$APPLY/empty-pending.jsonl"
PENDING="" transcript "$EMPTYLIST_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both "a push whose Apply recorded an empty pending list is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$EMPTYLIST_T")"
WRONGLIST_T="$APPLY/other-pending.jsonl"
PENDING="001_first.sql" transcript "$WRONGLIST_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both "a push whose recorded pending migration is not the one applied is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$WRONGLIST_T")"
PATHLIST_T="$APPLY/path-pending.jsonl"
PENDING="$MIG" transcript "$PATHLIST_T" s1 "$MIG" "$(sha_of "$MIG")" exampleprojectref000 Apply
both "a pending list naming the applied migration by its full path covers the push" none allow "$(apply_payload "$PUSH" "$PROJ" s1 "$PATHLIST_T")"

# The pending list is only what the dry run printed when it ran, so the Apply covers the push only
# while the migrations folder is as that dry run found it (#2829): the dry run ran in this session
# before the Apply, as its own call, on this project's folder, and succeeded, and no migration in
# the folder has been written, renamed or added since. Each case is in a project of its own, so
# what it changes reaches nothing else in this file.
fresh_proj() {  # fresh_proj <dir> <ref>: a linked project holding 001_first.sql and 002_note.sql
  mkdir -p "$1/supabase/migrations" "$1/supabase/.temp"
  printf 'create table a (id int);\n' > "$1/supabase/migrations/001_first.sql"
  printf 'alter table a add column note text;\n' > "$1/supabase/migrations/002_note.sql"
  printf '%s' "$2" > "$1/supabase/.temp/project-ref"
}
dry_case() {  # dry_case <label> <want> <project> [transcript env...]: an Apply for <project>'s 002_note.sql
  local label="$1" want="$2" p="$3" t="$APPLY/dry-$RANDOM$RANDOM.jsonl" sha
  shift 3
  sha="$(sha_of "$p/supabase/migrations/002_note.sql")"
  ( if [ $# -gt 0 ]; then export "$@"; fi; PROJ="$p"; transcript "$t" s1 "$p/supabase/migrations/002_note.sql" "$sha" exampleprojectref000 Apply )
  both "$label" none "$want" "$(apply_payload "$PUSH" "$p" s1 "$t")"
  DRY_LAST_T="$t"
}
P_SAME="$APPLY/dry-same"; fresh_proj "$P_SAME" exampleprojectref000
dry_case "an unchanged migration whose dry run came before the Apply is let through" allow "$P_SAME"
dry_case "a dry run named by a cd to the project counts" allow "$P_SAME" DRY_CWD="$APPLY/elsewhere" DRY_CMD="cd $P_SAME && supabase db push --linked --dry-run"
dry_case "an Apply with no dry run before it in the session is asked about" ask "$P_SAME" DRY=none
dry_case "an Apply whose dry run came only after it is asked about" ask "$P_SAME" DRY=after
dry_case "an Apply whose dry run failed is asked about" ask "$P_SAME" DRY_ERR=1
dry_case "a dry run of the local database does not count for the linked project" ask "$P_SAME" DRY_CMD="supabase db push --local --dry-run"
# Another project: the dry run Dan saw listed what project B would get, and the push goes to A.
P_B="$APPLY/dry-other-b"; fresh_proj "$P_B" otherprojectref00000
P_A="$APPLY/dry-other-a"; fresh_proj "$P_A" exampleprojectref000
dry_case "an Apply whose dry run ran on another project is asked about" ask "$P_A" DRY_CWD="$P_B"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$P_A" s1 "$DRY_LAST_T")")" reason)"
case "$reason" in *"dry run"*) check "the question says no dry run of this project came before the Apply" ok ;; *) check "the question says no dry run of this project came before the Apply" "reason: ${reason:0:400}" ;; esac
# Edited after the dry run, before the Apply: the Apply names the edited file's sha256, so the
# sha256 check alone passes it, but the dry run never saw that content.
P_EDIT="$APPLY/dry-edited"; fresh_proj "$P_EDIT" exampleprojectref000
at="$(now_iso)"
printf 'alter table a add column note text;\ndrop table a;\n' > "$P_EDIT/supabase/migrations/002_note.sql"
dry_case "a migration edited after the dry run is asked about" ask "$P_EDIT" DRY_AT="$at"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$P_EDIT" s1 "$DRY_LAST_T")")" reason)"
case "$reason" in *002_note.sql*"after the dry run"*) check "the question names the migration changed after the dry run" ok ;; *) check "the question names the migration changed after the dry run" "reason: ${reason:0:400}" ;; esac
# Renamed after the dry run: an applied migration given a new name is a new version the database
# never had, and the push would send it again.
P_REN="$APPLY/dry-renamed"; fresh_proj "$P_REN" exampleprojectref000
at="$(now_iso)"
mv "$P_REN/supabase/migrations/001_first.sql" "$P_REN/supabase/migrations/001a_first.sql"
dry_case "a migration renamed after the dry run is asked about" ask "$P_REN" DRY_AT="$at"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$P_REN" s1 "$DRY_LAST_T")")" reason)"
case "$reason" in *001a_first.sql*"after the dry run"*) check "the question names the migration renamed after the dry run" ok ;; *) check "the question names the migration renamed after the dry run" "reason: ${reason:0:400}" ;; esac
# Added after the dry run under an older version than the applied one: not the newest, so the
# newest file rule cannot see it, and not on the dry run's list (the gap #2800 recorded).
P_OLD="$APPLY/dry-older"; fresh_proj "$P_OLD" exampleprojectref000
at="$(now_iso)"
printf 'drop table a;\n' > "$P_OLD/supabase/migrations/001b_extra.sql"
dry_case "a migration added after the dry run with an older version is asked about" ask "$P_OLD" DRY_AT="$at"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$P_OLD" s1 "$DRY_LAST_T")")" reason)"
case "$reason" in *001b_extra.sql*) check "the question names the migration added after the dry run" ok ;; *) check "the question names the migration added after the dry run" "reason: ${reason:0:400}" ;; esac
# The control for the three above: the same stamp, taken before nothing changed, lets it through.
P_CTL="$APPLY/dry-control"; fresh_proj "$P_CTL" exampleprojectref000
at="$(now_iso)"
dry_case "the same dry run stamp with nothing changed after it is let through" allow "$P_CTL" DRY_AT="$at"
mv "$PROJ/supabase/.temp/project-ref" "$PROJ/supabase/.temp/project-ref.away"
both "a push whose linked project cannot be read is asked about" none ask "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")"
mv "$PROJ/supabase/.temp/project-ref.away" "$PROJ/supabase/.temp/project-ref"

# The skill's ad hoc write path (`supabase db query --linked --yes -f change.sql`) is covered by
# the same Apply, keyed the same way: the session, the file by path and sha256, and the project
# (Dan, 2026-11-11, folded into #2763).
CHANGE="$PROJ/change.sql"
printf 'do $$ begin update a set note = 1 where id = 7; end $$;\n' > "$CHANGE"
CHANGE_T="$APPLY/change.jsonl"
transcript "$CHANGE_T" s1 "$CHANGE" "$(sha_of "$CHANGE")" exampleprojectref000 Apply
WRITE_Q='supabase db query --linked --yes -f change.sql'
both "an ad hoc write from the file Dan applied, to his project, is let through" none allow "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$CHANGE_T")"
both "the same write named by its full path after a cd is let through" none allow "$(apply_payload "cd $PROJ && supabase db query --linked --yes -f $CHANGE" "$APPLY/elsewhere" s1 "$CHANGE_T")"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$CHANGE_T")")" reason)"
case "$reason" in *change.sql*exampleprojectref000*) check "the release of a write names the file and the project" ok ;; *) check "the release of a write names the file and the project" "reason: ${reason:0:300}" ;; esac
both "an ad hoc write with no Apply on record is asked about" none ask "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$NONE_T")"
both "an ad hoc write after an Apply for the migration, not this file, is asked about" none ask "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$GOOD_T")"
CHANGE_PROJ_T="$APPLY/change-other-project.jsonl"
transcript "$CHANGE_PROJ_T" s1 "$CHANGE" "$(sha_of "$CHANGE")" otherprojectref00000 Apply
both "an ad hoc write to a different project than the Apply named is asked about" none ask "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$CHANGE_PROJ_T")"
both "an ad hoc write from another session (lapsed) is asked about" none ask "$(apply_payload "$WRITE_Q" "$PROJ" s2 "$CHANGE_T")"
both "an ad hoc write with --db-url is asked about" none ask "$(apply_payload "supabase db query --yes --db-url postgresql://x -f change.sql" "$PROJ" s1 "$CHANGE_T")"
both "an ad hoc write with a statement beside the file is asked about" none ask "$(apply_payload "$WRITE_Q 'delete from a'" "$PROJ" s1 "$CHANGE_T")"
printf 'do $$ begin delete from a; end $$;\n' > "$CHANGE"
both "an ad hoc write from a file edited since the Apply is asked about" none ask "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$CHANGE_T")"
reason="$(field "$(run "$HOOK" "$EMPTY_HOME" "$(apply_payload "$WRITE_Q" "$PROJ" s1 "$CHANGE_T")")" reason)"
case "$reason" in *"delete from a"*changed*|*changed*"delete from a"*) check "the question about an edited write names the statement and says the file changed" ok ;; *) check "the question about an edited write names the statement and says the file changed" "reason: ${reason:0:400}" ;; esac

# The commands the skill itself tells a session to run, read from its text, so the skill cannot
# drift into a shape the hooks never let through (L562).
SKILL_MD="$DIR/../skills/db-apply/SKILL.md"
skill_cmd() { grep -m 1 -E "^[[:space:]]*$1\$" "$SKILL_MD" | sed 's/^[[:space:]]*//'; }
printf 'do $$ begin update a set note = 1 where id = 7; end $$;\n' > "$CHANGE"
transcript "$CHANGE_T" s1 "$CHANGE" "$(sha_of "$CHANGE")" exampleprojectref000 Apply
for want in 'supabase db push --dry-run|allow|none|NONE_T' 'supabase db push --yes|none|allow|GOOD_T' 'supabase db query --linked --yes -f change\.sql|none|allow|CHANGE_T'; do
  IFS='|' read -r pat ra rb tv <<< "$want"
  c="$(skill_cmd "$pat")"
  if [ -z "$c" ]; then check "the skill documents a command matching $pat" "none found in SKILL.md"; continue; fi
  both "the skill's own [$c] after its Apply" "$ra" "$rb" "$(apply_payload "$c" "$PROJ" s1 "${!tv}")"
done
# The picker metadata the skill documents must carry every key the approval library reads, so a key
# added there (such as "pending", #2800) cannot leave the skill writing pickers that cover nothing.
skill_meta="$(grep -m 1 -E '^\{"source": "db-apply"' "$SKILL_MD")"
lib_keys="$(grep -oE 'meta\.get\("[a-z_]+"\)' "$DIR/lib/db-apply-approval.py" | sed -E 's/.*"([a-z_]+)".*/\1/' | sort -u | tr '\n' ' ')"
missing="$(python3 -c 'import json, sys
try:
    m = json.loads(sys.argv[1])
except ValueError:
    print("no metadata JSON line in SKILL.md"); sys.exit()
print(" ".join(k for k in sys.argv[2].split() if k not in m))' "$skill_meta" "$lib_keys")"
case "$lib_keys" in *pending*) check "the approval library reads the pending list" ok ;; *) check "the approval library reads the pending list" "keys read: $lib_keys" ;; esac
[ -z "$missing" ] && check "the skill's documented picker metadata names every key the approval reads" ok || check "the skill's documented picker metadata names every key the approval reads" "missing: $missing"

# A -f file that cannot be read is asked about, as is one the same command could write first.
both "a -f file that does not exist is asked about" none ask "$(apply_payload "supabase db query --linked -f $APPLY/nosuch.sql" "$PROJ" s1 "$NONE_T")"
mkdir -p "$APPLY/a-folder.sql"
both "a -f path that is a folder is asked about" none ask "$(apply_payload "supabase db query --linked -f $APPLY/a-folder.sql" "$PROJ" s1 "$NONE_T")"
both "a -f file written by the same command is asked about" none ask "$(apply_payload "echo 'delete from a;' > $APPLY/readback.sql; supabase db query --linked -f $APPLY/readback.sql" "$PROJ" s1 "$NONE_T")"
both "a relative -f file with --workdir is asked about" none ask "$(apply_payload "supabase db query --linked --workdir $PROJ -f readback.sql" "$APPLY" s1 "$NONE_T")"
both "a read from a file with a redirection is read by neither hook, so it is asked about" none ask "$(apply_payload "supabase db query --linked -f $APPLY/readback.sql > $APPLY/out.txt" "$PROJ" s1 "$NONE_T")"
# With the predicate missing, a read from a file is asked about too.
r="$(run "$WORK/nolib/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(apply_payload "supabase db query --linked -f $APPLY/readback.sql" "$PROJ" s1 "$NONE_T")")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with lib/sql-read-only.py missing, a select in a file is asked about" ok || check "with lib/sql-read-only.py missing, a select in a file is asked about" "$(decision "$r")"
# Without lib/db-apply-approval.py beside it, an Applied push is asked about, naming the library.
mkdir -p "$WORK/noapply/hooks/lib"
cp "$HOOK" "$WORK/noapply/hooks/"
for f in "$DIR"/lib/*; do case "$f" in */db-apply-approval.py) ;; *) cp -R "$f" "$WORK/noapply/hooks/lib/" ;; esac; done
r="$(run "$WORK/noapply/hooks/db-write-ask.sh" "$EMPTY_HOME" "$(apply_payload "$PUSH" "$PROJ" s1 "$GOOD_T")")"
[ "$(decision "$r")" = "ask rc=0" ] && check "with lib/db-apply-approval.py missing, an Applied push is asked about" ok || check "with lib/db-apply-approval.py missing, an Applied push is asked about" "$(decision "$r")"
case "$(field "$r" reason)" in *db-apply-approval.py*) check "the question names the missing approval library" ok ;; *) check "the question names the missing approval library" "$(field "$r" reason)" ;; esac
# apply_migration and the branch and project tools are still asked about, Apply or not (#2632).
expect "apply_migration is still asked about" ask "$(payload "$MIG_TOOL" "alter table a add column note text")"
expect "merge_branch is still asked about" ask "$(tool_payload "${SB}merge_branch" '{"branch_id": "b9"}')"

# --- the settings run it for Bash and every MCP tool, and refuse the call if it fails -----------
wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
hits = [(e.get("matcher", ""), h) for e in d.get("hooks", {}).get("PreToolUse", [])
        for h in e.get("hooks", []) if h.get("command", "").endswith("/hooks/db-write-ask.sh")]
if len(hits) != 1:
    print("registered %d times" % len(hits)); sys.exit()
m, h = hits[0]
want = ["mcp__claude_ai_Supabase__execute_sql", "mcp__claude_ai_Supabase__apply_migration"] + [
        "mcp__claude_ai_SFDC_USE__" + t for t in ("createSobjectRecord", "updateSobjectRecord", "deleteSobjectRecord")] + [
        # Since #2536: Bash, for psql and its like, and every MCP tool, since a database tool on a
        # connector not yet seen can only be told by its name or its input once the hook runs.
        "Bash", "mcp__supabase__execute_sql", "mcp__acme_warehouse__run_sql", "mcp__claude_ai_Supabase__query_logs",
        # Since #2632: the Supabase tools that change a database with no statement.
        "mcp__claude_ai_Supabase__merge_branch", "mcp__claude_ai_Supabase__reset_branch",
        "mcp__claude_ai_Supabase__rebase_branch", "mcp__supabase__delete_branch",
        # Since #2660: an edge function deploy, asked about when it turns JWT verification off.
        "mcp__claude_ai_Supabase__deploy_edge_function", "mcp__supabase__deployEdgeFunction"]
never = ["Edit", "Write", "Read", "Monitor", "Agent"]
bad = [t for t in want if not re.fullmatch(m, t)] + ["also " + t for t in never if re.search(m, t)]
if h.get("onFailure") != "block":
    bad.append("onFailure is not block, so a crash or a timeout would let a write through unasked")
print("ok" if not bad else "matcher %s: %s" % (m, ", ".join(bad)))
PY
)"
check "the settings run the hook for Bash and every MCP tool, blocking on failure" "$wiring"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
