#!/usr/bin/env bash
#
# db-write-ask.sh
# Claude Code PreToolUse(Bash|Edit|Write|MultiEdit|mcp__.*)
# hook: ask Dan before any database SQL call that is not read only (claude-config#2521, #2536),
# and before an edge function deploy that turns JWT verification off, or may (#2660).
# Also run as `db-write-ask.sh --ran` under PostToolUse(Bash), where it decides nothing and only
# learns that a commit it asked about ran (#3023, below).
#
# On 2026-11-09 #2356's live checks sent `update <table> set <column> = <column> where false` to a
# production database through the claude.ai Supabase connector's execute_sql, on both Macs, and
# nothing stood in its way: auto mode's classifier judged it harmless itself, no hook saw it and no
# settings rule asked. read-only-query-allow.sh approves reads; nothing stood between a session and a
# real write. Dan decided that day that a hook asks him first, naming the statement and the project.
#
# WHAT IS ASKED ABOUT (permissionDecision "ask", which puts the call in front of Dan)
#   - execute_sql whose call read-only-query-allow.sh would not approve. Both hooks load the one
#     predicate, lib/sql-read-only.py (L342: they ask the same question), so a statement the read
#     hook approves is never asked about, and every other one is. test-db-write-ask.sh runs one set
#     of statements through both hooks and checks exactly one of them decides each (L721).
#   - apply_migration, always: a migration changes the database whatever its text.
#   - Since #2536, a write through any other database tool or through a database client in a
#     shell, which #2521 left unasked. lib/db-write-calls.py says which calls those are and which
#     statements they carry (an MCP tool whose name or input marks it as running SQL or applying a
#     migration; psql, mysql, mariadb, sqlite3 and the Supabase CLI's db and migration subcommands
#     in a Bash command, however wrapped), and each statement goes to the same one predicate. Its
#     header holds the rules and the tool names and counts they were calibrated on.
#   - Since #2632, the Supabase tools that change a database with no statement in the call, which
#     nothing above could see: merge_branch, reset_branch, rebase_branch, delete_branch,
#     create_branch, create_project, pause_project and restore_project, on any Supabase server,
#     always. The question names the tool, what it does, and the branch or project its input
#     names. The list, and why the connector's other tools are left out, is in
#     lib/db-write-calls.py. The Supabase CLI's branches and projects subcommands that do the same
#     in a shell (create, delete, pause, unpause, update) are asked about with them.
#   - Since #2660, one kind of call that changes no database: a Supabase edge function deploy that
#     turns JWT verification off, or may, which publishes a function the platform lets anyone call
#     without signing in. deploy_edge_function with verify_jwt false on any Supabase server, with
#     the function and the project named; a verify_jwt that is neither true nor false is asked
#     about too, and one that is true or left out is passed, since the connector's schema gives
#     true as its default. And every `supabase functions deploy` in a shell, whatever its flags
#     (Dan, 2026-11-10: "Ask on every shell deploy"), since the setting can sit in the project's
#     supabase/config.toml, which no flag shows and this hook never reads. lib/db-write-calls.py
#     says where each of these was read, and what this cannot see.
#   - Fail closed: a call this cannot classify is asked about, never passed. That covers a missing
#     or non text query, a payload it cannot read whose raw text names a database tool, and
#     lib/sql-read-only.py failing to load (then even a select is asked about, naming the file),
#     and python3 missing from PATH (asked the same way, naming python3). For a shell client it
#     also covers statements in a file or on its input, an option it does not know, a shell
#     variable in a statement, and lib/db-write-calls.py or lib/shell-words.py failing to load.
#     The registration carries onFailure block, so a crash or a timeout refuses the call rather than
#     letting a write through unasked.
#
# WHAT IT LETS THROUGH (permissionDecision "allow"), since #2763: one `supabase db push` that Dan has
# already answered Apply for in the /db-apply skill's picker, in this session, for that migration
# file unchanged and that project, with the migrations folder as the dry run before his Apply found
# it (#2829; lib/db-apply-approval.py says exactly when), in a command that
# is that push and nothing else but cd. One decision, apply this migration, had been put to him up
# to four times. The skill's ad hoc write, a `supabase db query -f <file>` that writes, is let
# through the same way when his Apply named that file and project (Dan, 2026-11-11). Every other
# push or write is asked about, the question saying why no Apply covers it. In
# the same kind of command a `db query -f` file is read and judged by the one predicate, so a
# read back from a file is not asked about either (lib/db-write-calls.py, "ONE SUPABASE RUN").
# Since #2952 neither is a command that writes its own -f files from heredocs and then runs them,
# when every text each file can hold is a read and the command does nothing else
# (lib/db-write-calls.py, "A COMMAND THAT WRITES ITS OWN FILES").
# Since #2643, a `supabase db query -f <file>` write alone in its command (cd aside) passes with no
# Apply, no reason and no notice when the project its directory is linked to is listed in that
# directory's .claude/supabase-test-projects (Dan, 2026-11-14: a per project file, passing silently).
# A list missing, unreadable or holding a line that is not a ref asks as before, as do an inline
# write, a push, and any flag naming another target (lib/db-apply-approval.py, "A TEST PROJECT").
# The list counts only as git has committed it, and an Edit, Write or MultiEdit of it is asked about
# like a database write, which is why the hook is registered for those three tools too. Since #2989
# a shell command that writes the list, or names it where no command of it can be read (a heredoc, a
# string), is asked about too, as is a `git commit` that would add a line other than a blank or a
# comment to any list in its checkout; one only removing lines passes (lib/db-apply-approval.py,
# list_shell_change).
# Since #3023 a line of the list counts only when a commit that passed that ask put it there. A line
# reached HEAD with no question through a git alias for commit, git commit-tree, a merge, a cherry
# pick, a rebase or a pull, and naming git commands could never end that. So the question about a
# commit notes the lines it names, the hook runs again once a Bash call has run (`--ran`, registered
# under PostToolUse, which only a call that was let through reaches) and puts the lines HEAD now
# holds on this Mac's record, and a write passes only for a project whose line is in HEAD and on that
# record, whatever route carried it there (lib/db-apply-approval.py, "A LINE COUNTS ONLY WHEN").
#
# THE SCREEN. The hook now runs on every Bash and MCP call, and since #2643 every Edit, Write and
# MultiEdit, so it leaves before python3 starts unless the payload holds one of DB_SCREEN_WORDS, which
# every word lib/db-write-calls.py can ask about holds (test-db-write-ask.sh checks that), as does the
# name of the test project list, or names a Salesforce write tool, or, since #2989, is a Bash call
# holding the words git and commit (commit_call, which is no database call).
#
# WHAT A COMMIT COSTS (claude-config#3023) is measured in the README, beside this hook's section,
# with what was cut and the largest cost left alone.
#
# THE SALESFORCE NOTICE. On the work MacBook ~/.claude/settings.local.json pre-allowed the writable
# Salesforce connection's createSobjectRecord, updateSobjectRecord and deleteSobjectRecord, which let
# those writes skip auto mode entirely. That file is not synced and no session edits it, so the fix is
# a step on that Mac. This hook says so in a systemMessage whenever one of those three tools is called
# while such an allow (the tool by name, or the whole server) is in the file on the Mac it runs on, and
# on every database question it asks. It gives those calls no decision of its own.
#
# A payload naming none of these tools is passed in silence, as is an empty one (#1922's decision).
# Every path exits 0.

set -uo pipefail

# AFTER A BASH CALL (--ran, claude-config#3023). Nearly every call finds no question waiting and
# leaves here, before anything else starts. The payload is still read off the pipe first, so
# Claude Code is never left writing a large one to a hook that has gone.
RAN=0
if [ "${1:-}" = "--ran" ]; then
  RAN=1
  set -- "${CLAUDE_HOME:-${HOME:-}/.claude}/state/supabase-test-projects/pending"/*.json
  [ -e "${1:-}" ] || { cat >/dev/null 2>&1; exit 0; }
fi

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

# Every word this hook prints is built by lib/hook-notice.sh, valid whatever the statement holds
# (#1906). Without the library it still asks, keeping only characters that need no escaping.
load_notice() {
  # shellcheck source=lib/hook-notice.sh
  . "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || {  # the library is missing
    hook_ask_json() {
      local n="${2:-}"
      if [ -n "$n" ]; then printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "%s (lib/hook-notice.sh is missing beside this hook)"}, "systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}" "${n//[^A-Za-z0-9 .,:;()\/_=+#-]/}"
      else printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "%s (lib/hook-notice.sh is missing beside this hook)"}}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; fi; }
    hook_notice_json() { printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; }
  }
}

if [ "$RAN" = 1 ]; then
  # A question is waiting. A call that names no commit answers none; one that does is handed to
  # lib/db-apply-approval.py's commit_ran, which approves the lines its question named and prints
  # nothing, or says why Dan's yes could not be recorded. This gives no decision: the call has run.
  case "$payload" in *commit*) ;; *) exit 0 ;; esac
  command -v python3 >/dev/null 2>&1 || exit 0
  note="$(printf '%s' "$payload" | python3 -I -B -S -c '
import importlib.util, json, sys
sys.stdout.reconfigure(errors="replace")
try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception:
    sys.exit()
ti = d.get("tool_input") if isinstance(d, dict) else None
command = ti.get("command") if isinstance(ti, dict) else None
if d.get("tool_name") != "Bash" or not isinstance(command, str):
    sys.exit()
spec = importlib.util.spec_from_file_location("db_apply_approval_shared", sys.argv[1] + "/lib/db-apply-approval.py")
ap = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ap)
sys.stdout.write((ap.commit_ran(d.get("session_id"), command) or "").replace("\x00", ""))
' "$HOOK_DIR" 2>/dev/null)" || note="db-write-ask.sh could not check whether this command was a commit Dan said yes to, because its check (python3) failed. A line it added to a test project list is not trusted, so a write on its project is asked about (claude-config#3023)"
  if [ -n "$note" ]; then load_notice; hook_notice_json "$note"; fi
  exit 0
fi

# The screen: a payload holding none of these words, in any case, names no database call.
DB_SCREEN_WORDS="sql quer statement migration notebook supabase mariadb pgcli mycli litecli duckdb clickhouse cockroach mongo redis-cli pg_restore dropdb createdb dropuser createuser"
db_call=0
sf_call=0
# A Bash call naming git and a commit is read for one adding a project to a test project list
# (#2989). It is no database call, so when python3 fails or is missing it is asked about as a commit
# (#3023: the question about a commit is how a line comes to be trusted, so it is never skipped).
commit_call=0
shopt -s nocasematch
for w in $DB_SCREEN_WORDS; do
  case "$payload" in *"$w"*) db_call=1; break ;; esac
done
case "$payload" in *sobjectrecord*) sf_call=1 ;; esac
shopt -u nocasematch
# Only a payload whose tool is Bash, by its tool_name and not by the word Bash anywhere in it (an
# Edit whose text held both words was read as a commit, #3023), and only one holding both words: a
# command with no git in it runs no git commit this hook could read.
case "$payload" in
  *commit*)
    case "$payload" in
      *git*)
        bash_tool='"tool_name"[[:space:]]*:[[:space:]]*"Bash"'
        if [[ "$payload" =~ $bash_tool ]]; then commit_call=1; fi ;;
    esac ;;
esac
[ "$db_call$sf_call$commit_call" != 000 ] || exit 0

load_notice

# Cleaned by the shared reader before python3 parses it (claude-config#1944). Without the library
# the payload is read as it came, and python3 is looked for directly.
if . "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null; then
  payload="$(ps_clean_payload "$payload")"
else
  ps_reader_missing() { ! command -v "$1" >/dev/null 2>&1; }
fi

[ -n "$payload" ] || exit 0

# The classifier is python3. Without it no statement can be judged read only, so every database
# call is asked about, a select included, naming what is missing (#486). A Salesforce write gets no
# decision from this hook either way.
if ps_reader_missing python3; then
  [ "$db_call" = 1 ] && hook_ask_json "db-write-ask.sh asks before this database call because python3 is not on PATH, and it is what classifies a statement as read only, so nothing could be. Install python3 (claude-config#2521)"
  [ "$db_call$commit_call" = 01 ] && hook_ask_json "db-write-ask.sh asks before this commit because python3 is not on PATH, so whether it adds a project to a test project list could not be told. Install python3 (claude-config#3023)"
  exit 0
fi

# -S: the hook uses the standard library only, and the site module was 5.2 ms of every start
# (the personal MacBook, 2026-11-15, claude-config#3023).
out="$(printf '%s' "$payload" | python3 -I -B -S -c '
import importlib.util, json, os, re, sys
sys.stdout.reconfigure(errors="replace")

DB_SQL = "mcp__claude_ai_Supabase__execute_sql"
DB_MIGRATION = "mcp__claude_ai_Supabase__apply_migration"
SF_SERVER = "mcp__claude_ai_SFDC_USE"
SF_WRITES = [SF_SERVER + "__" + t for t in ("createSobjectRecord", "updateSobjectRecord", "deleteSobjectRecord")]
WATCHED = [DB_SQL, DB_MIGRATION] + SF_WRITES
STATEMENT_SHOWN = 600
# How many database commands of one Bash call a question spells out; the rest are counted.
FINDINGS_SHOWN = 5

raw = sys.stdin.buffer.read().decode("utf-8", "replace")

def part(name, file):
    """(a library beside the hook, None), or (None, a clause naming the one that did not load).
    Loaded by its path, never by name, so no module in the working directory can stand in for it."""
    try:
        spec = importlib.util.spec_from_file_location(name, sys.argv[1] + "/lib/" + file)
        lib = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lib)
        return lib, None
    except Exception as e:
        return None, "lib/" + file + " could not be loaded beside the hook (" + type(e).__name__ + ")"

def mac_name():
    import socket  # here, not at the top: only a question names the Mac (1.3 ms, 2026-11-15, #3023)
    host = socket.gethostname().split(".")[0]
    if host.startswith("Daniels-MacBook-Pro-2"):
        return "the personal MacBook"
    if host.startswith("Dans-MacBook-Pro"):
        return "the work MacBook"
    return "this Mac (" + host + ")"

def sf_notice():
    """A sentence naming the pre-allowed Salesforce write tools on this Mac, or None."""
    home = os.environ.get("CLAUDE_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
    path = os.path.join(home, "settings.local.json")
    if not os.path.exists(path):
        return None
    try:
        with open(path, "rb") as f:
            allow = json.loads(f.read().decode("utf-8", "replace"))["permissions"]["allow"]
        if not isinstance(allow, list):
            raise ValueError("permissions.allow is not a list")
    except KeyError:
        return None
    except Exception as e:
        return ("db-write-ask.sh could not read " + path + " (" + type(e).__name__ + ") on " + mac_name()
                + ", so it could not check whether Salesforce writes are pre-allowed there (claude-config#2521).")
    hits = [r for r in allow if isinstance(r, str) and (r in SF_WRITES or r in (SF_SERVER, SF_SERVER + "__*"))]
    if not hits:
        return None
    return ("SALESFORCE WRITES SKIP AUTO MODE on " + mac_name() + ": " + path + " pre-allows "
            + ", ".join(hits) + ", so those Salesforce writes run with no check at all. Remove "
            + ("that rule" if len(hits) == 1 else "those rules") + " from that file on that Mac; it is not synced, "
            "so no session or sync removes it (claude-config#2521).")

def release(reason):
    """Let the call through: Dan has already answered for it (claude-config#2763)."""
    sys.stdout.write("allow\x1f" + reason.replace("\x1f", " ").replace("\x00", ""))
    sys.exit()

def emit(decision_reason=None, message=None):
    """Hand the verdict to the shell, which builds the JSON through lib/hook-notice.sh: "ask", the
    reason and the notice, or "note" and the notice, split by the unit separator, which is taken
    out of both texts first (as is NUL, which a shell variable cannot hold)."""
    def plain(t):
        return (t or "").replace("\x1f", " ").replace("\x00", "")
    if decision_reason is not None:
        sys.stdout.write("ask\x1f" + plain(decision_reason) + "\x1f" + plain(message))
    elif message:
        sys.stdout.write("note\x1f" + plain(message))
    sys.exit()

DATABASE_CALL = "database call"
# The one kind of call asked about that changes no database: an edge function deploy that turns
# JWT verification off, or may (claude-config#2660).
DEPLOY = "edge function deploy"

def ask(why, issue="2521", what=DATABASE_CALL):
    """Ask, saying which kind of call it is and the issue that decided it; issue may name two,
    for a command that holds both kinds."""
    emit("db-write-ask.sh asks before this " + what + ": " + why + " (claude-config#" + issue + ")", sf_notice())

try:
    d = json.loads(raw)
except Exception:
    d = None
tool = d.get("tool_name") if isinstance(d, dict) else None

# Which other calls reach a database, and which statements they carry (claude-config#2536). A Bash
# call the screen found no database word in (the second argument) is here only as a commit, and a
# commit check needs this library just to take a redirection out of a command, so it is loaded
# then and not before: 7 ms of every commit (the personal MacBook, 2026-11-15, claude-config#3023).
COMMIT_ONLY = tool == "Bash" and sys.argv[2:3] == ["0"]
calls, calls_why = None, None
def load_calls():
    global calls, calls_why
    if calls is None and calls_why is None:
        calls, calls_why = part("db_write_calls_shared", "db-write-calls.py")
if not COMMIT_ONLY:
    load_calls()
if not isinstance(tool, str):
    # A payload it cannot read is judged by its raw text: one naming a database tool is asked about.
    named = [t for t in WATCHED if t in raw]
    m = re.search(r"\"tool_name\"\s*:\s*\"([^\"\\\\]*)\"", raw)
    said = m.group(1) if m else ""
    if not named and said.startswith("mcp__") and calls is not None and calls.named_as_function_deploy(said):
        # An edge function deploy whose verify_jwt cannot be read (claude-config#2660).
        ask("the hook payload could not be read as a tool call, and its text names " + said
            + ", so whether the deploy keeps JWT verification on could not be told", "2660", DEPLOY)
    if not named and said.startswith("mcp__") and (calls is None or calls.named_as_database_call(said)):
        named = [said]
    if not named and said == "Bash" and (calls is None or calls.CLIENT_WORD.search(raw)):
        named = ["Bash and a database client"]
    if named:
        ask("the hook payload could not be read as a tool call, and its text names " + ", ".join(named)
            + ", so the call could not be classified as read only")
    sys.exit()

if tool in SF_WRITES:
    emit(None, sf_notice())
# An Edit, Write or MultiEdit of the list of test Supabase projects of a checkout, whose file runs pass
# unasked, is held like a database write (claude-config#2643). Anything else they write is passed.
if tool in ("Edit", "Write", "MultiEdit"):
    ap, ap_why = part("db_apply_approval_shared", "db-apply-approval.py")
    if ap is None:
        ti = d.get("tool_input")
        fp = ti.get("file_path") if isinstance(ti, dict) else None
        if isinstance(fp, str) and "supabase-test-projects" in fp:
            ask(ap_why + ", so whether " + fp + " is a test project list could not be told", "2643",
                "edit of a test project list")
        sys.exit()
    try:
        listed = ap.is_test_list(tool, d.get("tool_input"))
    except Exception as e:
        listed = "the file (" + type(e).__name__ + " reading its path)"
    if listed is not None:
        ask(tool + " writes " + listed + ", the list of the test Supabase projects of this checkout, whose "
            "supabase db query -f runs pass without asking", "2643", "edit of a test project list")
    # The record of the list lines Dan approved is held the same way (claude-config#3023): only a
    # commit he answered yes to may add to it.
    try:
        recorded = ap.is_list_record(tool, d.get("tool_input"))
    except Exception as e:
        recorded = "the file (" + type(e).__name__ + " reading its path)"
    if recorded is not None:
        ask(tool + " writes " + recorded + ", in the record this hook keeps of the test project lines Dan "
            "approved, which only a commit he answered yes to adds to", "3023",
            "edit of the record of approved test project lines")
    sys.exit()
# A shell command that writes that list, and a commit that adds a line to one, are held the same way
# (claude-config#2989). lib/db-apply-approval.py says which commands those are.
if tool == "Bash":
    bti = d.get("tool_input")
    bcmd = bti.get("command") if isinstance(bti, dict) else None
    if isinstance(bcmd, str) and ("supabase-test-projects" in bcmd.lower() or "commit" in bcmd):
        ap, ap_why = part("db_apply_approval_shared", "db-apply-approval.py")
        bsw, bsw_why = part("shell_words_shared", "shell-words.py")
        def strip(s, found=None):
            # Every redirection strip_redirects takes out holds < or >, so text holding neither
            # is its own answer (test-db-write-ask-approved-lines.sh holds that of the library).
            if calls is None and "<" not in s and ">" not in s:
                return s
            load_calls()
            return calls.strip_redirects(s, found)
        missing = ap_why or bsw_why or calls_why
        if missing:
            ask(missing + ", so whether this command writes the test project list of a checkout, or commits a "
                "project onto one, could not be told", "2989", "change to a test project list")
        try:
            change = ap.list_shell_change(bcmd, d.get("cwd"), bsw, strip, d.get("session_id"))
        except Exception as e:
            change = ((calls_why or "the command could not be read (" + type(e).__name__ + ")") + ", so whether "
                      "it writes a test project list of a checkout, or commits a project onto one, could not be told")
        if change is not None:
            ask(change, "2989, claude-config#3023", "change to a test project list")
if COMMIT_ONLY:
    # Nothing else to read: the screen found no word a database call could hold.
    sys.exit()
if tool not in (DB_SQL, DB_MIGRATION) and tool != "Bash" and not tool.startswith("mcp__"):
    sys.exit()

ti = d.get("tool_input")
project = ti.get("project_id") if isinstance(ti, dict) else None
query = ti.get("query") if isinstance(ti, dict) else None
where = "project " + (project if isinstance(project, str) and project else "(none named)")

def said(q):
    """The statement as the question shows it, cut at STATEMENT_SHOWN characters."""
    if not isinstance(q, str):
        return "Statement: (no text query in the call)"
    shown = q.strip()
    if len(shown) > STATEMENT_SHOWN:
        shown = shown[:STATEMENT_SHOWN] + " ... (" + str(len(q)) + " characters in all)"
    return "Statement: " + (shown or "(empty)")

stmt = said(query)

if tool == DB_MIGRATION:
    ask("apply_migration always changes the database, on " + where + ". " + stmt)

# The one predicate for read only, which read-only-query-allow.sh approves by.
ro, ro_why = part("sql_read_only_shared", "sql-read-only.py")
if tool == DB_SQL:
    if ro is None:
        ask(ro_why + ", so no statement can be classified as read only, on " + where + ". " + stmt)
    ok, why = ro.read_only_approval(tool, ti)
    if ok:
        sys.exit()
    ask("execute_sql is not provably read only (" + why + "), on " + where + ". " + stmt)

# Any other database tool, and a database client in a Bash command (claude-config#2536). Which
# calls those are is lib/db-write-calls.py; whether a statement is read only stays the predicate.
if calls is None:
    ask(calls_why + ", so whether this call reaches a database could not be told", "2536")

def judge(q):
    if ro is None:
        return ro_why + ", so no statement can be classified as read only"
    return ro.judge(q)

if tool == "Bash":
    command = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(command, str):
        if calls.CLIENT_WORD.search(raw):
            ask("the Bash call holds no text command and its payload names a database client, so the "
                "call could not be classified as read only", "2536")
        sys.exit()
    if not calls.CLIENT_WORD.search(command):
        sys.exit()
    sw, sw_why = part("shell_words_shared", "shell-words.py")
    if sw is None:
        ask(sw_why + ", so the command, which names a database client, could not be read", "2536")
    cwd = d.get("cwd")
    try:
        found = calls.bash_findings(command, judge, sw, cwd if isinstance(cwd, str) else "")
    except Exception as e:
        ask("the command names a database client and could not be read (" + type(e).__name__
            + "), so the call could not be classified as read only", "2536")
    if not found:
        sys.exit()
    # A `supabase db push`, or a `supabase db query` write from a -f file, that is the whole of its
    # command is let through when the Apply Dan answered in the /db-apply picker in this session
    # covers it, and asked about, saying why, when none does (claude-config#2763). A finding is
    # Applicable only in a command that holds nothing else but cd, so letting it through lets
    # nothing else through with it.
    pushes = [f for f in found if calls.is_applicable(f)]
    if pushes:
        ap, ap_why = part("db_apply_approval_shared", "db-apply-approval.py")
        kept, released = [], []
        for f in found:
            if not calls.is_applicable(f):
                kept.append(f)
                continue
            # A `db query -f` run on a project its checkout marks as test needs no Apply, and passes
            # with nothing said (claude-config#2643). Any doubt about the list falls through to the
            # Apply, then to the question, which says why neither covers it.
            test_why = None
            if f.file is not None:
                if ap is None:
                    test_why = ap_why
                else:
                    try:
                        is_test, test_why = ap.on_test_project(f.workdir, f.flags)
                    except Exception as e:
                        is_test, test_why = False, "whether its project is a test one could not be checked (" + type(e).__name__ + ")"
                    if is_test:
                        continue
            if ap is None:
                ok, why = False, ap_why
            else:
                try:
                    ok, why = ap.covered(f.workdir, f.flags, d.get("session_id"), d.get("transcript_path"), f.file,
                                         lambda c, w: calls.dry_push_dir(c, sw, w))
                except Exception as e:
                    ok, why = False, "whether Dan applied it could not be checked (" + type(e).__name__ + ")"
            if ok:
                released.append(why)
            else:
                kept.append((f[0] + ", and no /db-apply Apply covers it: " + why
                             + ("" if test_why is None else "; nor a test project: " + test_why), f[1]))
        if not kept and not released:
            sys.stdout.write("pass\x1f")
            sys.exit()
        if not kept:
            release("db-write-ask.sh lets this through: " + "; ".join(released) + " (claude-config#2763)")
        found = kept
    shown = [why + ("" if s is None else ". " + said(s)) for why, s in found[:FINDINGS_SHOWN]]
    more = len(found) - len(shown)
    # An edge function deploy is not a database call, so the question says which of the two the
    # command holds, or both, and names the issue behind each (claude-config#2660).
    deploys = [f for f in found if calls.is_function_deploy(f)]
    kinds = ([DATABASE_CALL] if len(deploys) < len(found) else []) + ([DEPLOY] if deploys else [])
    issues = ((["2536"] if len(deploys) < len(found) else []) + (["2660"] if deploys else [])
              + (["2763"] if pushes else []))
    ask("; ".join(shown) + ("; and " + str(more) + " more in the same command" if more else ""),
        ", claude-config#".join(issues), " and ".join(kinds))

# A Supabase tool that changes a database with no statement to judge: a branch merge, reset, rebase
# or delete, a new branch or project, a pause or a restore (claude-config#2632). The library builds
# the whole sentence, the branch or project the input names included.
try:
    change = calls.supabase_change(tool, ti)
except Exception as e:
    change = (tool + " could not be read (" + type(e).__name__ + "), so whether it changes a database "
              "could not be told")
if change is not None:
    ask(change, "2632")

# A Supabase edge function deploy with JWT verification off, which publishes a function the
# platform lets anyone call without signing in (claude-config#2660). It changes no database, and
# is the one deploy asked about: one that keeps verification on is passed. The library builds the
# sentence, with the function and the project the input names.
try:
    deploy = calls.supabase_open_deploy(tool, ti)
except Exception as e:
    deploy = (tool + " could not be read (" + type(e).__name__ + "), so whether the deploy keeps JWT "
              "verification on could not be told")
if deploy is not None:
    ask(deploy, "2660", DEPLOY)

try:
    found = calls.mcp_finding(tool, ti, judge)
except Exception as e:
    found = (tool + " could not be read (" + type(e).__name__ + "), so the call could not be classified "
             "as read only", None)
if found is None:
    sys.exit()
why, s = found
ask(why + (", on " + where if isinstance(project, str) and project else "")
    + ("" if s is None else ". " + said(s)), "2536")
' "$HOOK_DIR" "$db_call" 2>/dev/null)"
rc=$?

US=$'\x1f'
if [ "$rc" -eq 0 ]; then
  case "$out" in
    '') exit 0 ;;
    "ask$US"*)
      rest="${out#ask$US}"
      hook_ask_json "${rest%%"$US"*}" "${rest#*"$US"}"
      exit 0 ;;
    "note$US"*)
      hook_notice_json "${out#note$US}"
      exit 0 ;;
    "allow$US"*)
      # Dan's /db-apply Apply covers this push (claude-config#2763). The reason keeps only
      # characters that need no escaping, as read-only-query-allow.sh's approval does.
      reason="${out#allow$US}"
      printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "%s"}}\n' "${reason//[^A-Za-z0-9 .,:;()\/_=+#-]/}"
      exit 0 ;;
    "pass$US"*)
      # A file run on a project its checkout marks as test (claude-config#2643): let through with
      # no reason and no notice, as Dan chose (2026-11-14).
      printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow"}}\n'
      exit 0 ;;
  esac
fi
# python3 itself failed, or printed something that is not a verdict: fail closed for anything the
# screen let through as a database call, by the raw text, since nothing parsed it.
[ "$db_call" = 1 ] && hook_ask_json "db-write-ask.sh asks before this database call because its classifier (python3) failed, so the statement could not be classified as read only (claude-config#2521)"
[ "$db_call$commit_call" = 01 ] && hook_ask_json "db-write-ask.sh asks before this commit because its classifier (python3) failed, so whether it adds a project to a test project list could not be told (claude-config#2989)"
exit 0
