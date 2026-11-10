"""The one predicate for "this database call is read only" (claude-config#2343, #2521).

Two hooks ask the SAME question of it (L342): read-only-query-allow.sh approves a call when
read_only_approval() says it is read only, and db-write-ask.sh asks Dan before any database SQL call
it does not say so of. Because both load this file, there is no statement one of them approves that
the other asks about, and none that both let through in silence; test-db-write-ask.sh runs one set of
statements through BOTH hooks and checks exactly one of them decides each, so a change to either
hook's wiring that opened a gap between them fails there (L721: the check reads the two hooks'
outputs, never this function).

Loaded by its path (importlib's spec_from_file_location), never imported by name: the folder name holds no package, and a
module named sql_read_only in the working directory must never be the one that runs.

WHAT IS READ ONLY
  1. The six tools of the claude.ai Salesforce connection named "Read Only", by exact name. That
     connection cannot write. A tool added to it later is NOT read only until it is named here.
  2. execute_sql when its query is ONE statement that judge() can show is a read, judged on the raw
     text. Any one of these makes it not provably read only:
       - it does not start with select, with, explain or show;
       - it holds a semicolon anywhere but at the very end (several statements);
       - it holds a comment, since a comment between a function name and its bracket still calls it;
       - it holds any character outside plain ASCII;
       - any word in it is one of WRITE_WORDS, wherever it sits, a string literal included, which
         covers a write hidden in a with, select into, a row lock, and explain analyze of a write;
       - any bracket in it follows a name that is not on PURE_FUNCS or the syntax words, a quoted
         name, or a schema qualified name: a call to a function that may write.
     The text is never parsed, so a string or a name that merely looks like a write can only cost
     an approval, never win one.

WHAT IT CANNOT SEE: the database's own definitions. A select that reads a view whose definition
calls a function that writes, uses an operator or cast the database defined, calls a function on a
table's row type through column notation (t.some_function), or reaches a function the database
defined under the same name as one on PURE_FUNCS, can still write.
"""
import re

SQL_TOOL = "mcp__claude_ai_Supabase__execute_sql"
SF_PREFIX = "mcp__claude_ai_SFDC_-_Read_Only__"
# The read only Salesforce tools, by exact name (tool schemas read 2026-11-06). Keep in step with
# the matcher in read-only-query-allow.sh's header and in settings.hooks.json.
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
    """None when q is one read only statement, else the reason it is not provably one."""
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


def read_only_approval(tool, tool_input):
    """(True, why) when the call is read only, else (False, why it is not provably read only)."""
    if not isinstance(tool, str):
        return False, "it names no tool"
    if tool.startswith(SF_PREFIX) and tool[len(SF_PREFIX):] in SF_TOOLS:
        return True, "the read only Salesforce connection cannot write"
    if tool != SQL_TOOL:
        return False, "it is not one of the read only tools"
    why = judge(tool_input.get("query") if isinstance(tool_input, dict) else None)
    if why is None:
        return True, ("one read only statement (select, with, explain or show) with no write word "
                      "and no call outside the known pure functions")
    return False, why
