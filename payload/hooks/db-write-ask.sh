#!/usr/bin/env bash
#
# db-write-ask.sh
# Claude Code PreToolUse(mcp__claude_ai_Supabase__(execute_sql|apply_migration)|mcp__claude_ai_SFDC_USE__(createSobjectRecord|updateSobjectRecord|deleteSobjectRecord))
# hook: ask Dan before any database SQL call that is not read only (claude-config#2521).
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
#   - Fail closed: a call this cannot classify is asked about, never passed. That covers a missing
#     or non text query, a payload it cannot read whose raw text names a database tool, and
#     lib/sql-read-only.py failing to load (then even a select is asked about, naming the file),
#     and python3 missing from PATH (asked the same way, naming python3).
#     The registration carries onFailure block, so a crash or a timeout refuses the call rather than
#     letting a write through unasked.
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

payload="$(cat 2>/dev/null || true)"
# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"

# Every word this hook prints is built by lib/hook-notice.sh, valid whatever the statement holds
# (#1906). Without the library it still asks, keeping only characters that need no escaping.
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || {  # the library is missing
  hook_ask_json() { printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "ask", "permissionDecisionReason": "%s (lib/hook-notice.sh is missing beside this hook)"}}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; }
  hook_notice_json() { printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; }
}

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
  case "$payload" in
    *mcp__claude_ai_Supabase__execute_sql*|*mcp__claude_ai_Supabase__apply_migration*)
      hook_ask_json "db-write-ask.sh asks before this database call because python3 is not on PATH, and it is what classifies a statement as read only, so nothing could be. Install python3 (claude-config#2521)" ;;
  esac
  exit 0
fi

out="$(printf '%s' "$payload" | python3 -I -c '
import importlib.util, json, os, socket, sys
sys.stdout.reconfigure(errors="replace")

DB_SQL = "mcp__claude_ai_Supabase__execute_sql"
DB_MIGRATION = "mcp__claude_ai_Supabase__apply_migration"
SF_SERVER = "mcp__claude_ai_SFDC_USE"
SF_WRITES = [SF_SERVER + "__" + t for t in ("createSobjectRecord", "updateSobjectRecord", "deleteSobjectRecord")]
WATCHED = [DB_SQL, DB_MIGRATION] + SF_WRITES
STATEMENT_SHOWN = 600

raw = sys.stdin.buffer.read().decode("utf-8", "replace")

def mac_name():
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

def ask(why):
    emit("db-write-ask.sh asks before this database call: " + why + " (claude-config#2521)", sf_notice())

try:
    d = json.loads(raw)
except Exception:
    d = None
tool = d.get("tool_name") if isinstance(d, dict) else None
if not isinstance(tool, str):
    # A payload it cannot read is judged by its raw text: one naming a database tool is asked about.
    named = [t for t in WATCHED if t in raw]
    if named:
        ask("the hook payload could not be read as a tool call, and its text names " + ", ".join(named)
            + ", so the call could not be classified as read only")
    sys.exit()

if tool in SF_WRITES:
    emit(None, sf_notice())
if tool not in (DB_SQL, DB_MIGRATION):
    sys.exit()

ti = d.get("tool_input")
project = ti.get("project_id") if isinstance(ti, dict) else None
query = ti.get("query") if isinstance(ti, dict) else None
where = "project " + (project if isinstance(project, str) and project else "(none named)")
if isinstance(query, str):
    shown = query.strip()
    if len(shown) > STATEMENT_SHOWN:
        shown = shown[:STATEMENT_SHOWN] + " ... (" + str(len(query)) + " characters in all)"
    stmt = "Statement: " + (shown or "(empty)")
else:
    stmt = "Statement: (no text query in the call)"

if tool == DB_MIGRATION:
    ask("apply_migration always changes the database, on " + where + ". " + stmt)

lib = sys.argv[1] + "/lib/sql-read-only.py"
try:
    spec = importlib.util.spec_from_file_location("sql_read_only_shared", lib)
    ro = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(ro)
except Exception as e:
    ask("lib/sql-read-only.py could not be loaded beside the hook (" + type(e).__name__
        + "), so no statement can be classified as read only, on " + where + ". " + stmt)

ok, why = ro.read_only_approval(tool, ti)
if ok:
    sys.exit()
ask("execute_sql is not provably read only (" + why + "), on " + where + ". " + stmt)
' "$HOOK_DIR" 2>/dev/null)"
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
  esac
fi
# python3 itself failed, or printed something that is not a verdict: fail closed for a database
# tool, by the raw text, since nothing parsed it.
case "$payload" in
  *mcp__claude_ai_Supabase__execute_sql*|*mcp__claude_ai_Supabase__apply_migration*)
    hook_ask_json "db-write-ask.sh asks before this database call because its classifier (python3) failed, so the statement could not be classified as read only (claude-config#2521)" ;;
esac
exit 0
