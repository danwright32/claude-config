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
# The read hook never approves any of these, so the two hooks still cannot disagree about one.
for p in "$(tool_payload mcp__acme_warehouse__run_sql '{"sql": "select 1"}')" "$(bash_payload 'psql -c "select 1"')" "$(tool_payload mcp__supabase__execute_sql '{"query": "select 1"}')"; do
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
        "Bash", "mcp__supabase__execute_sql", "mcp__acme_warehouse__run_sql", "mcp__claude_ai_Supabase__query_logs"]
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
