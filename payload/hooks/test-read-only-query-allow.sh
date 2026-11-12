#!/usr/bin/env bash
# send-gate: scans settings.hooks.json
# Tests for the hook that approves a read only database query by itself, so auto mode does not
# refuse it (claude-config#2343).
#
# On 2026-11-05 auto mode's classifier refused a plain select against a production database with
# "[Production Reads]", and the read ran only once Dan typed that reads were fine. Reads are meant to
# run without asking (Dan, 2026-11-05: "you should be allowed to do reads"). execute_sql can also
# write, so the tool cannot be allowed whole: this suite proves BOTH sides. Every read shape the
# issue names is approved, and every write shape it names (insert, update, delete, alter, drop,
# truncate, create, grant, a call to a function that may write), a write hidden inside a with, and
# several statements joined by semicolons, gets NO decision from the hook, so it goes on to the
# classifier exactly as it did before.
#
# The payloads are in the shape the tool schemas declare (read 2026-11-06): execute_sql takes
# project_id and query, the read only Salesforce soqlQuery takes q. The project id is invented.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/read-only-query-allow.sh"
. "$DIR/lib/settings-file.sh" 2>/dev/null || { echo "FAIL: lib/settings-file.sh is missing beside this suite"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
SETTINGS="$(hook_settings_file "$DIR/..")" || SETTINGS=""

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "test-read-only-query-allow: there is no read-only-query-allow.sh beside this suite at $DIR." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs read-only-query-allow.sh beside it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

# The settings run it by its path, never through bash, so a hook that is not executable never runs.
[ -x "$HOOK" ] && check "the hook is executable, as the settings run it by its path" ok || check "the hook is executable, as the settings run it by its path" "mode lacks x"

SQL_TOOL="mcp__claude_ai_Supabase__execute_sql"
SF_PREFIX="mcp__claude_ai_SFDC_-_Read_Only__"

# The hook's answer for one payload, as one word: allow, deny, ask, none (no decision at all), or
# badjson. The exit code travels with it, since a defer must exit 0 and never refuse.
answer() {
  local out rc
  out="$(printf '%s' "$1" | bash "$HOOK" 2>/dev/null)"; rc=$?
  printf '%s' "$out" | python3 -c '
import json, sys
t = sys.stdin.read().strip()
if not t:
    print("none"); sys.exit()
try:
    d = json.loads(t)
except Exception:
    print("badjson"); sys.exit()
h = d.get("hookSpecificOutput") if isinstance(d, dict) else None
print((h or {}).get("permissionDecision", "none"))'
  printf 'rc=%s\n' "$rc"
}
sql_payload() {
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": {"project_id": "exampleprodproject", "query": sys.argv[2]}}))' "$SQL_TOOL" "$1"
}
tool_payload() {
  python3 -c 'import json, sys; print(json.dumps({"session_id": "s1", "hook_event_name": "PreToolUse", "tool_name": sys.argv[1], "tool_input": json.loads(sys.argv[2])}))' "$1" "$2"
}
expect_allow() {  # $1 label, $2 payload
  local a; a="$(answer "$2")"
  [ "$a" = $'allow\nrc=0' ] && check "$1 is approved" ok || check "$1 is approved" "${a//$'\n'/ }"
}
expect_defer() {  # $1 label, $2 payload: no decision, exit 0, so the usual permission check judges it
  local a; a="$(answer "$2")"
  [ "$a" = $'none\nrc=0' ] && check "$1 is left to the usual check" ok || check "$1 is left to the usual check" "${a//$'\n'/ }"
}
read_ok() { expect_allow "the read [$1]" "$(sql_payload "$1")"; }
write_left() { expect_defer "the statement [$1]" "$(sql_payload "$1")"; }

# The read shapes the issue names: select, with, explain, show.
read_ok "select name, version from workflows where active = true order by name"
read_ok "SELECT count(*) FROM orders;"
read_ok "  select id, created_at::date from runs where created_at > now() - interval '1 day' limit 50  "
read_ok "with recent as (select id, status from runs where created_at > now() - interval '7 days') select status, count(*) from recent group by status"
read_ok "explain select * from runs where id = 7"
read_ok "show search_path"
read_ok "select coalesce(max(version), 0) as latest, lower(name) from workflows group by lower(name)"
read_ok "select w.name from workflows w where exists (select 1 from runs r where r.workflow_id = w.id) and w.id in (1, 2, 3)"
read_ok "select jsonb_build_object('a', 1), to_char(now(), 'YYYY-MM-DD'), row_number() over (partition by kind order by id) from events"
read_ok "select id from workflows where name = 'nightly report'"
read_ok "explain (analyze, buffers) select kind, count(*) filter (where ok) over (partition by kind) from events"
# over and filter are clauses only right after a call's closing bracket; elsewhere they name a function.
write_left "select filter(1)"
write_left "select over(1)"

# Each write keyword the issue lists stays with the classifier.
write_left "insert into workflows (name) values ('x')"
write_left "update workflows set version = 2 where id = 1"
write_left "delete from workflows where id = 1"
write_left "alter table workflows add column note text"
write_left "drop table workflows"
write_left "truncate workflows"
write_left "create table copy_of_runs as select * from runs"
write_left "grant select on workflows to anon"
# A call to a function that may write: any function not on the hook's known pure list, a schema
# qualified one, a quoted one, the server's own side effecting ones, and the call statement.
write_left "select archive_old_runs(30)"
write_left "select public.archive_old_runs(30)"
write_left "select \"archive_old_runs\"(30)"
write_left "select nextval('runs_id_seq')"
write_left "select set_config('app.mode', 'x', false)"
write_left "select pg_terminate_backend(123)"
write_left "select * from dblink('host=elsewhere', 'delete from t') as t(x int)"
write_left "call archive_old_runs(30)"
# A comment between a function name and its bracket is still a call, so any comment is left alone.
write_left "select archive_old_runs/**/(30)"
write_left "select 1 -- trailing note"
# A write hidden inside a with: a data modifying common table expression.
write_left "with gone as (delete from runs where id = 1 returning id) select count(*) from gone"
write_left "with changed as (update runs set status = 'x' returning id) select * from changed"
write_left "with added as (insert into runs (id) values (9) returning id) select * from added"
# Several statements joined by semicolons, whatever the first one is.
write_left "select 1; delete from runs"
write_left "select 1; select 2"
write_left "select 1;; "
# Reads that write all the same.
write_left "select * into runs_backup from runs"
write_left "select * from runs where id = 1 for update"
write_left "select * from runs where id = 1 for share"
write_left "explain analyze delete from runs where id = 1"
write_left "explain analyze execute some_prepared_statement"
# A keyword inside a string literal is refused too: the hook reads the raw text, never a parse, so a
# string can only ever cost an approval, never win one.
write_left "select 'drop table runs' as note"
# Anything that does not START as a read.
write_left "begin"
write_left "do \$\$ begin delete from runs; end \$\$"
write_left "/* note */ select 1"
write_left "copy runs to stdout"
write_left "vacuum runs"
write_left ""

# The read only Salesforce connection's tools are approved outright: it cannot write.
for t in find getObjectSchema getRelatedRecords getUserInfo listRecentSobjectRecords; do
  expect_allow "$SF_PREFIX$t" "$(tool_payload "$SF_PREFIX$t" '{}')"
done
expect_allow "${SF_PREFIX}soqlQuery" "$(tool_payload "${SF_PREFIX}soqlQuery" '{"q": "SELECT Id, Name FROM Account LIMIT 5"}')"
# Nothing else: the writable Salesforce connection, even its query tool, another tool on the read
# only connection that is not on the list, Supabase's other tools, and every other tool.
expect_defer "mcp__claude_ai_SFDC_USE__updateSobjectRecord" "$(tool_payload mcp__claude_ai_SFDC_USE__updateSobjectRecord '{"sobjectType": "Account", "id": "001", "fields": {}}')"
expect_defer "mcp__claude_ai_SFDC_USE__soqlQuery" "$(tool_payload mcp__claude_ai_SFDC_USE__soqlQuery '{"q": "SELECT Id FROM Account"}')"
expect_defer "a tool on the read only connection not on the list" "$(tool_payload "${SF_PREFIX}someNewTool" '{}')"
expect_defer "mcp__claude_ai_Supabase__apply_migration" "$(tool_payload mcp__claude_ai_Supabase__apply_migration '{"project_id": "exampleprodproject", "name": "m", "query": "select 1"}')"
expect_defer "Bash" "$(tool_payload Bash '{"command": "select 1"}')"
# An execute_sql call whose query is missing or not text.
expect_defer "execute_sql with no query" "$(tool_payload "$SQL_TOOL" '{"project_id": "exampleprodproject"}')"
expect_defer "execute_sql with a query that is not text" "$(tool_payload "$SQL_TOOL" '{"project_id": "exampleprodproject", "query": ["select 1"]}')"

# A payload it cannot read approves nothing and refuses nothing, and says the hook did not run.
out="$(printf 'not json' | bash "$HOOK" 2>/dev/null)"; rc=$?
[ "$rc" = 0 ] && check "an unreadable payload exits 0" ok || check "an unreadable payload exits 0" "rc=$rc"
case "$out" in *permissionDecision*) check "an unreadable payload approves nothing" "out=$out" ;; *) check "an unreadable payload approves nothing" ok ;; esac
case "$out" in *systemMessage*"DID NOT RUN"*) check "an unreadable payload says the hook did not run" ok ;; *) check "an unreadable payload says the hook did not run" "out=$out" ;; esac

# The settings run the hook for exactly these tools. Claude Code tests a matcher as a regular
# expression, so a tool must match it in full to be approved, and the tools it must not reach are
# checked with an unanchored search, the looser reading.
wiring="$(python3 - "$SETTINGS" <<'PY'
import json, re, sys
d = json.load(open(sys.argv[1]))
ms = [e.get("matcher", "") for e in d.get("hooks", {}).get("PreToolUse", [])
      if any(h.get("command", "").endswith("/hooks/read-only-query-allow.sh") for h in e.get("hooks", []))]
if len(ms) != 1:
    print("registered %d times" % len(ms)); sys.exit()
m = ms[0]
want = ["mcp__claude_ai_Supabase__execute_sql"] + ["mcp__claude_ai_SFDC_-_Read_Only__" + t for t in
        ("find", "getObjectSchema", "getRelatedRecords", "getUserInfo", "listRecentSobjectRecords", "soqlQuery")] + [
        # Since #2763: Bash, for a read through the Supabase CLI, judged by the same predicate.
        "Bash"]
never = ["mcp__claude_ai_Supabase__apply_migration", "mcp__claude_ai_SFDC_USE__soqlQuery",
         "mcp__claude_ai_SFDC_USE__updateSobjectRecord", "mcp__claude_ai_SFDC_USE__find", "Edit", "Write"]
bad = [t for t in want if not re.fullmatch(m, t)] + ["also " + t for t in never if re.search(m, t)]
print("ok" if not bad else "matcher %s: %s" % (m, ", ".join(bad)))
PY
)"
check "the settings run the hook for execute_sql, the six read only Salesforce tools and Bash, and nothing else" "$wiring"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
