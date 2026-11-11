#!/usr/bin/env bash
#
# read-only-query-allow.sh
# Claude Code PreToolUse(mcp__claude_ai_Supabase__execute_sql|mcp__claude_ai_SFDC_-_Read_Only__(find|getObjectSchema|getRelatedRecords|getUserInfo|listRecentSobjectRecords|soqlQuery)|Bash) hook: approve a read only query by itself, so auto mode does not refuse it (claude-config#2343).
#
# On 2026-11-05 auto mode's classifier refused a plain select against a production database, with
# the reason "[Production Reads]": its default soft deny list carries that category, and nothing
# exempted a read. The same statement ran once Dan typed that reads were fine. Reads are meant to run
# without asking (Dan, 2026-11-05: "you should be allowed to do reads"), and an unattended overnight
# session has nobody there to say so.
#
# This hook only ever APPROVES or says NOTHING. It never refuses. Saying nothing leaves the call to
# the usual permission check (in auto mode, the classifier), exactly as before this hook existed, so
# a statement this hook cannot prove is a read loses nothing but the shortcut. An approval from a
# PreToolUse hook skips the prompt and the auto mode classifier, measured on Claude Code 2.1.304 on
# 2026-10-21 (the note in rtk-rewrite.sh, claude-config#1455); a deny rule in settings still wins.
#
# WHAT IS APPROVED
#   1. The six tools of the claude.ai Salesforce connection named "Read Only", by exact name. That
#      connection cannot write. A tool added to it later is NOT approved until it is named here, so
#      a write tool arriving on it is never approved by default. The writable Salesforce connection
#      is never approved, its query tool included.
#   2. execute_sql when its query is ONE statement that can be shown to be a read, judged on the raw
#      text by judge() in lib/sql-read-only.py. That file is the one predicate for "read only", and
#      db-write-ask.sh loads it too, to ask Dan about every database call this hook does not approve
#      (claude-config#2521). Any one of these leaves it to the usual check (and so to that question):
#        - it does not start with select, with, explain or show;
#        - it holds a semicolon anywhere but at the very end (several statements);
#        - it holds a comment, since a comment between a function name and its bracket still calls it;
#        - it holds any character outside plain ASCII;
#        - any word in it is one of WRITE_WORDS, wherever it sits, a string literal included, which
#          covers a write hidden in a with, select into, a row lock, and explain analyze of a write;
#        - any bracket in it follows a name that is not on PURE_FUNCS or the syntax words, a quoted
#          name, or a schema qualified name: a call to a function that may write.
#      The text is never parsed, so a string or a name that merely looks like a write can only cost
#      an approval, never win one.
#   3. Since #2763, a Bash command that is one Supabase CLI run and nothing else but cd, when it
#      changes nothing: a `supabase db query` whose every statement, in its words or in a -f file
#      it reads, the same judge() shows to be a read, or a `supabase db push --dry-run`. Which
#      commands those are is cli_read_approval() in lib/db-write-calls.py, the library
#      db-write-ask.sh reads the same command with, so a call approved here is never asked about
#      there. A command holding anything else (a pipe, a redirection, a second command, a flag this
#      does not know) is left to the usual check.
#
# WHAT IT CANNOT SEE: the database's own definitions. A select that reads a view whose definition
# calls a function that writes, uses an operator or cast the database defined, calls a function on
# a table's row type through column notation (t.some_function), or reaches a function the database
# defined under the same name as one on PURE_FUNCS, can still write. The project is never read
# either: a read is approved against any project, production included, which is the point.
#
# Fails toward the usual check on a payload it cannot read, and says so in a systemMessage
# (lib/hook-notice.sh), since Claude Code discards a PreToolUse hook's stderr on exit 0 (#1906).

set -uo pipefail

payload="$(cat 2>/dev/null || true)"

# It runs on every Bash call since #2763, and approves only a Supabase CLI read, so a Bash payload
# that never names supabase leaves before anything is loaded. Matched under LC_ALL=C too, so a byte
# that is not UTF-8 hides no word after it (claude-config#1885).
payload_match() { [[ $1 =~ $2 ]] && return 0; local LC_ALL=C; [[ $1 =~ $2 ]]; }
if payload_match "$payload" '"tool_name"[[:space:]]*:[[:space:]]*"Bash"' && ! payload_match "$payload" 'supabase'; then
  exit 0
fi

# Its own folder cut from its path in bash, never by dirname (claude-config#2081, #2130).
case "${BASH_SOURCE[0]}" in */*) HOOK_DIR="${BASH_SOURCE[0]%/*}" ;; *) HOOK_DIR=. ;; esac
HOOK_DIR="$(cd "${HOOK_DIR:-/}" && pwd)"
# shellcheck source=lib/hook-notice.sh
. "$HOOK_DIR/lib/hook-notice.sh" 2>/dev/null || hook_allow_notice() {  # the library is missing
  printf '%s\n' "$1" >&2
  printf '{"systemMessage": "%s (lib/hook-notice.sh is missing beside this hook)"}\n' "${1//[^A-Za-z0-9 .,:;()\/_=+#-]/}"; exit 0; }

# Cleaned by the shared reader before python3 parses it (claude-config#1944). Without the library
# the payload is read as it came.
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null && payload="$(ps_clean_payload "$payload")"

verdict="$(printf '%s' "$payload" | python3 -I -B -c '
import importlib.util, json, sys
sys.stdout.reconfigure(errors="replace")

try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if not isinstance(tool, str):
    print("leave\t"); sys.exit()
def load(name, file):
    """A library beside the hook, loaded by its path, never by name."""
    spec = importlib.util.spec_from_file_location(name, sys.argv[1] + "/lib/" + file)
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    return lib
# The one predicate for "read only", shared with db-write-ask.sh, which asks Dan about every
# database call this does not approve (claude-config#2521).
try:
    ro = load("sql_read_only_shared", "sql-read-only.py")
except Exception as e:
    print("nolib\tsql-read-only.py, " + type(e).__name__); sys.exit()
if tool == "Bash":
    # A read through the Supabase CLI (claude-config#2763), read by the library db-write-ask.sh
    # reads it with, so a call approved here is one that hook does not ask about.
    ti = d.get("tool_input")
    command = ti.get("command") if isinstance(ti, dict) else None
    if not isinstance(command, str):
        print("leave\t"); sys.exit()
    try:
        calls = load("db_write_calls_shared", "db-write-calls.py")
        sw = load("shell_words_shared", "shell-words.py")
    except Exception as e:
        print("nolib\tdb-write-calls.py or shell-words.py, " + type(e).__name__); sys.exit()
    ok, why = calls.cli_read_approval(command, d.get("cwd"), ro.judge, sw)
    print(("allow\t" if ok else "leave\t") + why); sys.exit()
ok, why = ro.read_only_approval(tool, d.get("tool_input"))
print(("allow\t" if ok else "leave\t") + why)
' "$HOOK_DIR" 2>&1)"

case "$verdict" in
  allow$'\t'*)
    reason="read-only-query-allow.sh approved it: ${verdict#*$'\t'} (claude-config#2343)"
    printf '{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "allow", "permissionDecisionReason": "%s"}}\n' "${reason//[^A-Za-z0-9 .,:;()\/_=+#-]/}"
    exit 0
    ;;
  leave$'\t'*)
    exit 0
    ;;
  unreadable$'\t'*)
    hook_allow_notice "READ ONLY QUERY APPROVAL DID NOT RUN: read-only-query-allow.sh could not read the hook payload (${verdict#*$'\t'}), so this call goes to the usual permission check instead of being approved as a read."
    ;;
  nolib$'\t'*)
    hook_allow_notice "READ ONLY QUERY APPROVAL DID NOT RUN: read-only-query-allow.sh could not load a library beside it (lib/${verdict#*$'\t'}), so this call goes to the usual permission check instead of being approved as a read."
    ;;
  *)
    hook_allow_notice "READ ONLY QUERY APPROVAL DID NOT RUN: read-only-query-allow.sh failed (${verdict//$'\n'/ }), so this call goes to the usual permission check instead of being approved as a read."
    ;;
esac
