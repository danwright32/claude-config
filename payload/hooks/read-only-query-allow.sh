#!/usr/bin/env bash
#
# read-only-query-allow.sh
# Claude Code PreToolUse(mcp__claude_ai_Supabase__execute_sql|mcp__claude_ai_SFDC_-_Read_Only__(find|getObjectSchema|getRelatedRecords|getUserInfo|listRecentSobjectRecords|soqlQuery)) hook: approve a read only query by itself, so auto mode does not refuse it (claude-config#2343).
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
#   2. execute_sql when its query is ONE statement that this file can show is a read, judged on the
#      raw text in judge() below. Any one of these leaves it to the usual check:
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

verdict="$(printf '%s' "$payload" | python3 -c '
import json, re, sys
sys.stdout.reconfigure(errors="replace")

SQL_TOOL = "mcp__claude_ai_Supabase__execute_sql"
SF_PREFIX = "mcp__claude_ai_SFDC_-_Read_Only__"
# The read only Salesforce tools, by exact name (tool schemas read 2026-11-06). Keep in step with
# the matcher in the header above and in settings.hooks.json.
SF_TOOLS = {"find", "getObjectSchema", "getRelatedRecords", "getUserInfo",
            "listRecentSobjectRecords", "soqlQuery"}
READ_START = {"select", "with", "explain", "show"}
# Words that make a statement starting like a read write all the same, plus every write keyword the
# issue lists. A column of one of these names costs only the approval.
WRITE_WORDS = {"insert", "update", "delete", "merge", "alter", "drop", "truncate", "create",
               "grant", "revoke", "into", "share", "execute", "declare", "call", "copy"}
# Functions built into Postgres that read and never write. A function not here is not approved.
PURE_FUNCS = {
    "count", "sum", "avg", "min", "max", "lower", "upper", "length", "char_length",
    "octet_length", "btrim", "ltrim", "rtrim", "substr", "replace", "split_part", "concat",
    "concat_ws", "left", "right", "strpos", "lpad", "rpad", "initcap", "starts_with", "format",
    "regexp_replace", "regexp_match", "regexp_matches", "regexp_split_to_array", "md5",
    "array_agg", "string_agg", "json_agg", "jsonb_agg", "json_build_object", "jsonb_build_object",
    "json_build_array", "jsonb_build_array", "json_object_agg", "jsonb_object_agg",
    "json_array_elements", "json_array_elements_text", "jsonb_array_elements",
    "jsonb_array_elements_text", "jsonb_each", "jsonb_each_text", "jsonb_object_keys",
    "jsonb_typeof", "jsonb_array_length", "jsonb_pretty", "jsonb_extract_path",
    "jsonb_extract_path_text", "to_json", "to_jsonb", "row_to_json", "unnest", "array_length",
    "array_to_string", "cardinality", "generate_series", "date_trunc", "date_part", "now", "age",
    "to_char", "to_date", "to_timestamp", "to_number", "make_interval", "make_date", "abs",
    "round", "floor", "ceil", "ceiling", "mod", "power", "sqrt", "trunc", "sign", "row_number",
    "rank", "dense_rank", "percent_rank", "cume_dist", "lag", "lead", "first_value",
    "last_value", "nth_value", "ntile", "percentile_cont", "percentile_disc", "mode", "bool_and",
    "bool_or", "every", "pg_typeof",
}
# Syntax words a bracket may follow. Each is a Postgres keyword that cannot name a function (a
# reserved word, or a special form like coalesce, cast or a type with a length), so a bracket after
# it is never a call.
SYNTAX_WORDS = {
    "select", "from", "where", "and", "or", "not", "in", "exists", "any", "all", "some", "as",
    "on", "using", "values", "array", "row", "case", "when", "then", "else", "between",
    "distinct", "union", "intersect", "except", "lateral", "with", "limit", "offset", "order",
    "group", "having", "window", "join", "is", "like", "ilike", "similar", "cast", "extract",
    "interval", "coalesce", "nullif", "greatest", "least", "position", "substring", "trim",
    "overlay", "grouping", "varchar", "char", "character", "numeric", "decimal", "timestamp",
    "time", "bit",
}
WORD_CHAR = re.compile(r"[a-z0-9_$]")
SPACE = " \t\n\r\f"

def judge(q):
    """None when q is one read only statement, else the reason it is left to the usual check."""
    if not isinstance(q, str):
        return "its query is not text"
    if any(ord(c) > 126 or (ord(c) < 32 and c not in SPACE) for c in q):
        return "it holds a character outside plain ASCII"
    s = q.lower()
    if "/*" in s or "--" in s:
        return "it holds a comment"
    body = s.strip(SPACE)
    if body.endswith(";"):
        body = body[:-1].strip(SPACE)
    if ";" in body:
        return "it holds more than one statement"
    m = re.match(r"[a-z_]+", body)
    first = m.group(0) if m else ""
    if first not in READ_START or (len(body) > len(first) and WORD_CHAR.match(body[len(first)])):
        return "it does not start with select, with, explain or show"
    hit = sorted(set(re.findall(r"[a-z_][a-z0-9_$]*", body)) & WRITE_WORDS)
    if hit:
        return "it holds " + ", ".join(hit)
    for i, ch in enumerate(body):
        if ch != "(":
            continue
        j = i - 1
        while j >= 0 and body[j] in SPACE:
            j -= 1
        if j < 0:
            continue
        if body[j] == "\"":
            return "it calls a quoted name"
        if not WORD_CHAR.match(body[j]):
            continue
        k = j
        while k >= 0 and WORD_CHAR.match(body[k]):
            k -= 1
        word = body[k + 1:j + 1]
        if k >= 0 and body[k] == ".":
            return "it calls " + word + " by a qualified name"
        if word in PURE_FUNCS or word in SYNTAX_WORDS:
            continue
        # A window or filter clause follows the bracket that closes a call; explain takes its
        # options in brackets right at the start.
        before = k
        while before >= 0 and body[before] in SPACE:
            before -= 1
        if word in ("over", "filter") and before >= 0 and body[before] == ")":
            continue
        if word == "explain" and k < 0:
            continue
        return "it calls " + word
    return None

try:
    d = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except Exception as e:
    print("unreadable\t" + type(e).__name__); sys.exit()
if not isinstance(d, dict):
    print("unreadable\tthe payload is not a JSON object"); sys.exit()
tool = d.get("tool_name")
if not isinstance(tool, str):
    print("leave\t"); sys.exit()
if tool.startswith(SF_PREFIX) and tool[len(SF_PREFIX):] in SF_TOOLS:
    print("allow\tthe read only Salesforce connection cannot write"); sys.exit()
if tool != SQL_TOOL:
    print("leave\t"); sys.exit()
ti = d.get("tool_input")
why = judge(ti.get("query") if isinstance(ti, dict) else None)
if why is None:
    print("allow\tone read only statement (select, with, explain or show) with no write word and no call outside the known pure functions")
else:
    print("leave\t" + why)
' 2>&1)"

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
  *)
    hook_allow_notice "READ ONLY QUERY APPROVAL DID NOT RUN: read-only-query-allow.sh failed (${verdict//$'\n'/ }), so this call goes to the usual permission check instead of being approved as a read."
    ;;
esac
