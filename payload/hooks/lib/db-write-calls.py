"""Which calls reach a database, and which of them db-write-ask.sh asks about (claude-config#2536).

#2521 asked Dan before a write through the claude.ai Supabase connector's two SQL tools and nothing
else, so the same write through any other database tool, or through psql and its like in a Bash
call, went unasked. This file reads those calls. It decides only two things: whether a call runs
statements against a database, and which statements. Whether a statement is read only is never
decided here: every statement found is handed to judge(), which is lib/sql-read-only.py's, the one
rule read-only-query-allow.sh approves by (L342), so the two hooks cannot disagree about one.
Anything that runs statements this file cannot find, or cannot read, is asked about.

Since #2632 it also names the Supabase tools that change a database with no statement at all
(SUPABASE_CHANGES), which the rules above could not see because there is nothing to judge.

Since #2660 it names one kind of call that changes no database: a Supabase edge function deploy
that turns JWT verification off, or that may, which publishes a function the platform lets anyone
call without signing in.

  mcp_finding(tool, tool_input, judge)   one MCP call other than the two #2521 named
  supabase_change(tool, tool_input)      the sentence for a call in SUPABASE_CHANGES, or None
  supabase_open_deploy(tool, tool_input) the sentence for a deploy with JWT verification off, or None
  named_as_database_call(tool)           whether a tool's name alone says it runs statements or
                                         is one of SUPABASE_CHANGES
  named_as_function_deploy(tool)         whether a tool's name alone says it deploys an edge function
  bash_findings(command, judge, sw, cwd) one Bash command; sw is lib/shell-words.py, loaded; cwd
                                         the session's directory, from the hook payload
  is_function_deploy(finding)            whether a finding is about a deploy and not a database
  is_applicable(finding)                 whether a finding is one Dan's /db-apply Apply can cover
                                         (claude-config#2763): a `db push`, or a `db query` write
                                         from a -f file; it carries .workdir, .flags and .file for
                                         lib/db-apply-approval.py
  cli_read_approval(command, cwd, judge, sw)
                                         (True, why) when a Bash command is one Supabase CLI read,
                                         or reads only from files it writes itself from heredocs
                                         (scripted_queries()), for read-only-query-allow.sh; else
                                         (False, why not)
  scripted_queries(command, sw, cwd)     the `db query` runs of a command that writes their -f
                                         files from heredocs, with every text each file can hold
                                         when read; None when the command is not that shape (#2952)
  dry_push_dir(command, sw, cwd)         the directory whose migrations a Bash command previews,
                                         when it is one `supabase db push --dry-run` of the linked
                                         project, else None; lib/db-apply-approval.py reads the
                                         session's dry runs with it (claude-config#2829). It raises
                                         UnsureLine, or CannotAsk, for a command it reads as that
                                         dry run but cannot vouch for (claude-config#3472)
  is_second_reading(finding)             whether a finding is one only the second reading of the
                                         command accounts for (claude-config#3472)
  asked_reading(sw, read)                what read() gives by the reading sw gives a caller that
                                         asks which lines it is unsure of, or why it gives none
  second_reading(command, sw, cwd, first, read)
                                         the same for a caller whose read() is costly, run again
                                         only when the two readings of the command differ
  unsure_why(fault, untold)              one of asked_reading()'s faults as a sentence
  unsure_fix(told)                       how to write a command so that the reader names no line in
                                         it, for a fault or a finding about a line it named, else
                                         None; db-write-ask.sh refuses on it
  asked_words()                          every word a call must hold for this file to ask about it

A Bash command is judged by two readings of it since #3472, the reader's own and the one it gives a
caller that asks (asking()), whatever the command holds: a # the reader cannot tell from a comment
is one line it names, and a heredoc it cannot find the end of, which holds no #, is another.
bash_findings(), dry_push_dir() and cli_read_approval() each say how they put the two together, and
UNSURE holds what is said of each mark.

Each finding is (why the call is asked about, the statement it is about or None).

EDGE FUNCTION DEPLOYS WITH JWT VERIFICATION OFF (claude-config#2660). #2632 left every deploy
unasked, as code and not a database. Since #2660 a deploy is asked about when it turns JWT
verification off, or when this file cannot tell that it does not: with it off the platform checks
no caller, so anyone holding the function's address can call it unless its own code checks them.
  - deploy_edge_function on any server whose name holds supabase, when its verify_jwt is false (or
    the text false, or a no_verify_jwt that is true), with the function and project its input
    names. A verify_jwt that is neither true nor false (null, a number, the text true) is asked
    about as one that could not be read, since what a server makes of it was not measured.
    verify_jwt true is passed, and so is verify_jwt left out: the claude.ai connector's schema, read
    on 2026-11-10, declares it a boolean whose default is true (and requires it). That default was
    read from the schema and not measured on a deploy (L82), and another Supabase server's default
    was not read at all.
  - every `supabase functions deploy` in a shell, whatever its flags, with the functions it names
    (or "all functions" when it names none) and its --project-ref or the linked project. In a
    shell the setting can sit in the project's supabase/config.toml (`verify_jwt = false` under the
    function), which a plain deploy applies with no flag in the command, and this file never reads
    a file's text. So Dan decided on 2026-11-10, in a picker, relayed by the session that ran this
    work: "Ask on every shell deploy". The question says JWT verification is off when a
    --no-verify-jwt is given as anything but =false (`supabase functions deploy --help`, CLI
    2.75.0) or the --verify-jwt=false an older CLI took is (2.75.0 refuses it as unknown), says it
    could not be told when a flag's value is no boolean, and otherwise says where the setting is
    kept. `functions serve --no-verify-jwt` runs on this Mac only and is passed, as are new, list,
    delete and download.
Measured on the personal MacBook on 2026-11-10, over all 8,368 transcripts: 3 Bash commands ran
`supabase functions deploy`, none with --no-verify-jwt, and no session had called
deploy_edge_function. So the shell rule would have asked 3 times in everything run there, and the
connector rule never.

SUPABASE TOOLS WITH NO STATEMENT (claude-config#2632), decided from the claude.ai connector's tool
descriptions as read on 2026-11-10. None had been called on the personal MacBook by then, so the
questions were measured as costing nothing there. Asked about on every call, on any server whose
name holds supabase, with the branch or project the input names:
  - merge_branch (a branch's migrations and edge functions go to production), reset_branch (data
    and schema outside a migration are lost), rebase_branch (production's newer migrations run on
    the branch) and delete_branch (the branch's database goes);
  - create_branch and create_project, each a new database that is billed, as createdb is asked
    about in a shell. The connector says it confirms the cost itself, which was not measured (L82);
  - pause_project (the database goes offline) and restore_project (a database somebody paused
    comes back into service and into the bill).
Left unasked, since none changes a database: deploy_edge_function and create_edge_function_secret
(code and configuration; the secret's value, by the tool's description, is typed in the Supabase
dashboard and never passes through the session), create_notebook (saved without being run;
run_notebook is asked about), delete_notebook, submit_feedback and delete_feedback. Since #2660 a
deploy_edge_function that turns JWT verification off is asked about, and so is every `supabase
functions deploy` in a shell, both in the section above; a deploy_edge_function that keeps
verification on is still left unasked.

MCP TOOLS, calibrated on every tool name on the personal MacBook on 2026-11-10 (settings,
~/.claude.json, and the 185 names in its transcripts). A tool is read as running statements when:
  - its name holds the word sql (execute_sql, run_sql, executeSql), on any server;
  - its input has a field named for SQL (sql, sql_query, sqlQuery, raw_sql), as the Supabase
    connector's query_logs has;
  - its server or its name holds a database's name (DB_WORDS) and its input has a field named
    query, queries, statement or statements;
  - it applies a migration (a name holding migration and one of RUN_WORDS), asked about always;
  - it is run_notebook on the claude.ai Supabase connector, whose statements are saved in the
    notebook and not in the call, asked about always.
A tool matching none of these gets nothing, which keeps what was measured as no database execution
out of it: soqlQuery (its field is q, and SOQL cannot write), the Claude Docs query tool, Supabase's
search_docs (graphql_query), a search tool's query on a server that is no database, PostHog's exec
(its command is a string of its own, and its execute-sql runs HogQL, which only reads).

SHELL CLIENTS, read from the commands lib/shell-words.py finds, so one in a `bash -c` string, a
substitution, an if or behind sudo, env or an assignment is read, and a mention (a grep pattern, an
echo, a commit message, a heredoc body, `command -v psql`) is not.
  - psql, mysql, mariadb and sqlite3: every statement in the command's words is judged (-c, -e,
    sqlite3's words after the database file and its -cmd). Statements in a file or on its input,
    an option this file does not know, a shell variable or substitution in a statement, and a psql
    variable in one, cannot be classified and are asked about. A file's text is never read: the
    same command can write it first, so what was read would not be what runs (L64).
  - the Supabase CLI: `db query` by its statement, `db push` (unless --dry-run), `db reset`, and
    `migration up`, `down`, `repair` and `squash`. Measured as the write routes in use here: 76
    sqlite3 runs, 8 `supabase db query`, 2 `db push` and 1 `migration up` in 107,120 Bash calls
    over the 30 days to 2026-11-10, and no psql or mysql in command position at all. Since #2632
    also `branches create`, `delete`, `pause`, `unpause` and `update` and `projects create` and
    `delete` (SUPABASE_STATE_GROUPS), the shell route to what SUPABASE_CHANGES names, so that one
    is not the way round the other (L450). No transcript on the personal MacBook had run one.
  - UNREAD_CLIENTS (pgcli, pg_restore, dropdb, mongosh and the rest): asked about whenever one
    runs, since this file does not read their statements.
  - ONE SUPABASE RUN, since #2763. When the whole Bash command is one Supabase CLI run, with
    nothing before it but cd (plain_supabase()), nothing in the command can write a file before
    that run reads it, so its `db query -f` file IS read and each statement judged, the same as
    execute_sql; L64 is why a file is read in no other command, but one whose only writes are its
    own heredocs (the next item). A file that cannot be read
    (missing, a folder, not a regular file, not UTF-8, too large, named relative to a --workdir)
    is asked about. Such a `db push`, and such a `db query` write from a file it read, is
    Applicable, which db-write-ask.sh lets through when Dan's /db-apply Apply covers it
    (lib/db-apply-approval.py). cli_read_approval() is what
    read-only-query-allow.sh approves a CLI call by: a `db query` whose every statement judge()
    shows to be read only, or a `db push --dry-run`.
  - A COMMAND THAT WRITES ITS OWN FILES, since #2952. A read only investigation in a work
    repository was asked about on every query, because it wrote each query from a heredoc and ran
    it, often in a for loop over days, and L64 kept every such -f file unread. Since every
    statement that command can run is in its own text, scripted_queries() reads it, when it holds
    nothing but literal assignments, for loops over literal words, cd, `cat > /abs/path <<EOF`
    writes, `supabase db query` runs (behind timeout too, with only 2>&1 or 2>/dev/null) and,
    piped from a run, SCRIPT_FILTERS or a python3 -c that _python_reads_only(). The loops are
    unrolled and each $NAME filled in from the command's own values, so each file a run reads is
    judged with every text its one heredoc write can have put there, and with its present text,
    which a write that fails or is skipped leaves. A write must name a .sql file in full that a
    run reads before anything writes it again, so an approved command can only replace a .sql
    file that was missing or held one read only statement, with another a run then reads.
    Anything else (another command, a file no heredoc or two heredocs write, a relative path, a
    substitution or an unset variable anywhere, an unquoted glob, a background job, a compound
    command other than for, a run reading no file the command wrote, a variable name
    _script_name_ok() refuses) leaves the command to the readings above, which ask. A write found
    there is asked about, never Applicable: an Apply covers only a run that stands alone.
    python3 -c puts its directory first on the import path, so a json.py where it runs would be
    imported in place of the standard one: the folder the step runs in, followed through each cd,
    must hold no module or package Python could import (_python_finds_nothing_in), or the step must
    be python3 -I -c, which never puts it on the path (#2969).
  - a client run through CARRIERS (docker exec, ssh, npx, a secret runner) is read from the
    client's own name on, or from the quoted command line handed over.

WHAT IT DOES NOT SEE: a script file's commands (`bash change.sh`), a client run by a name held in a
variable, a program that opens a database itself (python, node, an ORM's own CLI), and a carrier
not on CARRIERS, which is a hand written list (L96). SUPABASE_CHANGES is one too: a tool Supabase
adds later that changes a database with no statement, and any other host's tool of that kind (a
Neon branch reset, say), is unasked until it is listed. Of a deploy with JWT verification off: a
deploy through a Supabase server whose name does not hold supabase, and a call to Supabase's own
API (curl, a script). The setting in supabase/config.toml is never read; the shell deploy that
would apply it is asked about whatever its flags.
"""
import contextlib
import json
import os
import re
import stat

SUPABASE = "mcp__claude_ai_Supabase__"
# Asked about whatever the call holds: its statements are not in it.
ALWAYS_ASKED = {
    SUPABASE + "run_notebook": "run_notebook runs the statements saved in a notebook, which are not in the call",
}
# The Supabase tools that change a database and carry no statement (claude-config#2632), each with
# what it does, after its own description (read 2026-11-10). A {field} is filled from the
# call's input by supabase_change(); {reset_to} is the migration version a reset names, or its
# migrations. Asked about on every call, on any Supabase server.
SUPABASE_CHANGES = {
    "merge_branch": "applies the migrations and edge functions of branch {branch_id} to its production project",
    "reset_branch": ("resets branch {branch_id} to {reset_to}, and any data or schema change outside "
                     "a migration is lost"),
    "rebase_branch": "runs production's newer migrations on branch {branch_id}",
    "delete_branch": "deletes branch {branch_id} and the database it holds",
    "create_branch": "creates a branch named {name} of project {project_id}, a new database billed by the hour",
    "create_project": ("creates a project named {name} in organization {organization_id}, a new database "
                       "that can add to the bill"),
    "pause_project": "takes project {project_id} and its database offline until it is restored",
    "restore_project": "brings paused project {project_id} and its database back into service",
}
SUPABASE_CHANGE_FIELDS = ("branch_id", "project_id", "name", "organization_id")
# How much of a branch, project or organization name a question shows.
TARGET_SHOWN = 80
# The Supabase tool that deploys an edge function, and the input fields that say whether the
# platform checks a caller's JWT before running it (claude-config#2660): verify_jwt is the
# connector's, read 2026-11-10, and no_verify_jwt is the CLI's flag as a field, in case a server
# names it so. Both are matched by their words, so verifyJwt is verify_jwt.
SUPABASE_DEPLOY = "deploy_edge_function"
VERIFY_JWT = "verify_jwt"
NO_VERIFY_JWT = "no_verify_jwt"
# What true and false look like written as text, in a tool's input or after a flag's = sign,
# compared in lower case. They are the ones Go's strconv.ParseBool takes, which reads the CLI's.
TRUE_WORDS = {"true", "t", "1"}
FALSE_WORDS = {"false", "f", "0"}
# How much of a verify_jwt value that is neither true nor false a question shows.
VALUE_SHOWN = 40
STATEMENT_KEYS = {"query", "queries", "statement", "statements"}
# What may stand beside sql in a field's name for the field to hold a statement: sql_query, raw_sql.
SQL_KEY_WORDS = {"query", "queries", "statement", "statements", "text", "string", "raw", "command",
                 "commands", "stmt", "code", "script"}
MIGRATION_WORDS = {"migration", "migrations"}
RUN_WORDS = {"apply", "run", "execute", "exec", "push", "up"}
DB_WORDS = {
    "sql", "db", "database", "databases", "postgres", "postgresql", "pg", "pgsql", "psql", "mysql",
    "mariadb", "sqlite", "supabase", "snowflake", "bigquery", "redshift", "clickhouse", "neon",
    "duckdb", "motherduck", "mssql", "sqlserver", "oracle", "cockroach", "cockroachdb", "planetscale",
    "turso", "libsql", "databricks", "athena", "trino", "presto", "timescale", "tidb", "singlestore",
    "aurora", "rds",
}
MAX_DEPTH = 4
# The largest `db query -f` file read (#2763); a larger one is asked about unread. A read back is a
# line or two; the hook has ten seconds in all.
STATEMENT_FILE_MAX = 1 << 20
NO_STATEMENT = "its statements are not in the command, so it reads them from its input"
SHELL_VALUE = "it holds a shell variable or a substitution, known only as it runs"
# A psql variable (:name, :'name', :"name"), which psql fills in before the statement runs. A cast
# (::text) and a time ('12:30') are not one.
PSQL_VARIABLE = re.compile(r"""(?<!:):[A-Za-z_'"]""")
# One word of a tool, server or field name, however it is cased: execute_sql, executeSql, runSQL.
NAME_WORD = re.compile(r"[A-Z]+(?![a-z])|[A-Z]?[a-z]+|[0-9]+")


def tokens(name):
    """The lower case words of a tool, server or field name: execute_sql, executeSql and runSQL all
    hold sql, and soqlQuery holds soql and query, never sql."""
    return {t.lower() for t in NAME_WORD.findall(name)}


def mcp_parts(tool):
    """(server, tool) of an mcp__server__tool name."""
    server, sep, name = tool[len("mcp__"):].partition("__")
    return (server, name) if sep else ("", server)


def named_as_database_call(tool):
    """Whether an MCP tool's NAME alone says it runs statements, applies a migration or is one of
    SUPABASE_CHANGES: what is left to go on when its payload cannot be read."""
    if tool in ALWAYS_ASKED or _supabase_change_name(tool):
        return True
    nt = tokens(mcp_parts(tool)[1])
    return "sql" in nt or bool(nt & MIGRATION_WORDS and nt & RUN_WORDS)


class FunctionDeploy(tuple):
    """A finding, (why, None), about an edge function deploy. It is a finding like any other to
    whoever unpacks it, and db-write-ask.sh words its question by the type, since this one is
    not about a database."""
    __slots__ = ()


def is_function_deploy(finding):
    """Whether one of bash_findings()'s findings is about an edge function deploy, and so not
    about a database."""
    return isinstance(finding, FunctionDeploy)


class Applicable(tuple):
    """A finding about a Supabase CLI run that is the whole of its command (claude-config#2763),
    which Dan's /db-apply Apply can cover: a `db push` (.file None) or a `db query` running the
    statements of one -f file (.file its absolute path). It carries the directory the run works in
    (.workdir) and its flags (.flags), so db-write-ask.sh can ask lib/db-apply-approval.py."""

    def __new__(cls, finding, workdir, flags, file=None):
        self = tuple.__new__(cls, finding)
        self.workdir, self.flags, self.file = workdir, list(flags), file
        return self


def is_applicable(finding):
    """Whether one of bash_findings()'s findings is one an Apply can cover."""
    return isinstance(finding, Applicable)


def _open_to_all(several=False):
    """What a deploy with JWT verification off means for whoever answers the question, said of
    one function or of several."""
    return ("so the platform lets anyone call " + ("them" if several else "it") + " without signing "
            "in, unless " + ("their" if several else "its") + " own code checks the caller")


def _words(name):
    """A tool's or a field's name as its lower case words joined by _, so resetBranch is
    reset_branch and verifyJwt is verify_jwt."""
    return "_".join(t.lower() for t in NAME_WORD.findall(name))


def _supabase_tool(tool):
    """The name, as its words, of an MCP tool on a Supabase server, or None on any other. The
    server is everything before the tool's last __, and any server whose name holds supabase
    counts (the claude.ai connector, a project's own server, a plugin's), since each offers these
    same tools. Another product's merge_branch is not one."""
    head, sep, name = tool.rpartition("__")
    if not sep or not head.startswith("mcp__") or "supabase" not in head.lower():
        return None
    return _words(name)


def _supabase_change_name(tool):
    """The SUPABASE_CHANGES key an MCP tool answers to, or None."""
    snake = _supabase_tool(tool)
    return snake if snake in SUPABASE_CHANGES else None


def named_as_function_deploy(tool):
    """Whether an MCP tool's NAME alone says it deploys a Supabase edge function: what is left to
    go on when its payload, and so its verify_jwt, cannot be read."""
    return _supabase_tool(tool) == SUPABASE_DEPLOY


def _jwt_checked(field, value):
    """What one field of a deploy says about JWT verification: "on", "off", or "unclear" for a
    value that is neither true nor false. Text that reads as off is taken as off; text that reads
    as on is unclear, since only a real true was read from the schema as keeping verification on."""
    said = value if isinstance(value, bool) else None
    if isinstance(value, str):
        text = value.strip().lower()
        said = True if text in TRUE_WORDS else False if text in FALSE_WORDS else None
    if said is None:
        return "unclear"
    if said != (field == VERIFY_JWT):
        return "off"
    return "on" if isinstance(value, bool) else "unclear"


def supabase_open_deploy(tool, ti):
    """None unless an MCP call deploys a Supabase edge function with JWT verification off, or with
    a setting this cannot read; else the sentence the question shows: the tool, the function and
    the project its input names, and what the setting was. A deploy that leaves verify_jwt out is
    passed, since the schema's default is true (the header says where that was read)."""
    if _supabase_tool(tool) != SUPABASE_DEPLOY:
        return None
    if not isinstance(ti, dict):
        return (tool + " deploys an edge function and its input is not an object, so whether JWT "
                "verification stays on could not be told")
    what = "edge function " + _target(ti, "name") + " on project " + _target(ti, "project_id")
    off, unclear = [], []
    for key, value in ti.items():
        field = _words(key) if isinstance(key, str) else ""
        if field not in (VERIFY_JWT, NO_VERIFY_JWT):
            continue
        shown = json.dumps(value)
        if len(shown) > VALUE_SHOWN:
            shown = shown[:VALUE_SHOWN] + " ..."
        state = _jwt_checked(field, value)
        if state != "on":
            (off if state == "off" else unclear).append(key + " is " + shown)
    if off:
        return (tool + " publishes " + what + " with JWT verification off (" + ", ".join(off) + "), "
                + _open_to_all())
    if unclear:
        return (tool + " publishes " + what + ", and " + ", ".join(unclear) + ", not a plain true or "
                "false, so whether JWT verification stays on could not be told")
    return None


def _target(ti, key):
    """What a call names in one of its input fields, as the question shows it: cut at
    TARGET_SHOWN characters, and said to be missing or not text when it is."""
    v = ti.get(key) if isinstance(ti, dict) else None
    if v is None or v == "":
        return "(none named)"
    if not isinstance(v, str):
        return "(not text)"
    shown = " ".join(v.split())
    if len(shown) > TARGET_SHOWN:
        shown = shown[:TARGET_SHOWN] + " ... (" + str(len(v)) + " characters in all)"
    return shown or "(none named)"


def supabase_change(tool, ti):
    """None unless an MCP call is one of SUPABASE_CHANGES; else the sentence the question shows:
    the tool, what it does, and the branch or project its input names."""
    name = _supabase_change_name(tool)
    if name is None:
        return None
    named = {k: _target(ti, k) for k in SUPABASE_CHANGE_FIELDS}
    version = ti.get("migration_version") if isinstance(ti, dict) else None
    named["reset_to"] = "its migrations" if version is None or version == "" else (
        "migration version " + _target(ti, "migration_version"))
    return tool + " " + SUPABASE_CHANGES[name].format_map(named)


def _judged(subject, statements, judge, shell=False, psql=False):
    """A finding for each statement judge() does not show to be read only. shell says the statement
    was a word of a shell command, where a $ or a backquote is filled in only as the command runs."""
    out = []
    for s in statements:
        if shell and ("$" in s or "`" in s):
            why = SHELL_VALUE
        elif psql and PSQL_VARIABLE.search(s):
            why = "it holds a psql variable, filled in as it runs"
        else:
            why = judge(s)
        if why is not None:
            out.append((subject + " is not provably read only (" + why + ")", s))
    return out


def mcp_finding(tool, ti, judge):
    """None when an MCP call runs no statement this file can tell of, or only read only ones; else
    (why it is asked about, the statement or None)."""
    if tool in ALWAYS_ASKED:
        return ALWAYS_ASKED[tool], None
    server, name = mcp_parts(tool)
    st, nt = tokens(server), tokens(name)
    fields = ti.items() if isinstance(ti, dict) else ()
    sql_keys = [(k, v) for k, v in fields if isinstance(k, str) and "sql" in tokens(k)
                and tokens(k) - {"sql"} <= SQL_KEY_WORDS]
    plain_keys = [(k, v) for k, v in fields if isinstance(k, str) and k.lower() in STATEMENT_KEYS]
    if nt & MIGRATION_WORDS and nt & RUN_WORDS:
        first = next((v for _, v in sql_keys + plain_keys if isinstance(v, str)), None)
        return tool + " applies a migration, which changes the database whatever its text", first
    if "sql" in nt:
        carried = sql_keys + plain_keys
        if not carried:
            return (tool + " runs SQL and its statement is in no field this hook knows, so the call "
                    "could not be classified as read only"), None
    elif sql_keys:
        carried = sql_keys + plain_keys
    elif (st | nt) & DB_WORDS and plain_keys:
        carried = plain_keys
    else:
        return None
    statements = []
    for k, v in carried:
        if isinstance(v, str):
            statements.append(v)
        elif isinstance(v, list) and v and all(isinstance(x, str) for x in v):
            statements.extend(v)
        else:
            return (tool + " holds a " + k + " that is not text, so the call could not be classified "
                    "as read only"), None
    found = _judged(tool, statements, judge)
    return found[0] if found else None


# ---- shell clients ------------------------------------------------------------------------------
# Each client's options, from its own help (psql 16, mysql 8.0 and mariadb 11, sqlite3 3.43). An
# option on neither list is asked about, since whether it takes the next word decides which word
# is the statement. kind: "stmt" holds a statement the client runs INSTEAD of reading its input
# (psql -c, mysql -e), "before" one it runs and then reads its input all the same (sqlite3 -cmd,
# mysql --init-command), "file" names a file of them, None anything else.
PSQL = {
    "flags": set("abeEnqsSAtxHz0wWX1lV?"),
    "valued": {"c": "stmt", "f": "file", "d": None, "h": None, "p": None, "U": None, "v": None,
               "L": None, "o": None, "F": None, "P": None, "R": None, "T": None},
    "long_flags": {"--echo-all", "--echo-errors", "--echo-queries", "--echo-hidden", "--no-readline",
                   "--quiet", "--single-step", "--single-line", "--no-align", "--tuples-only",
                   "--expanded", "--html", "--field-separator-zero", "--record-separator-zero",
                   "--no-password", "--password", "--no-psqlrc", "--single-transaction", "--csv",
                   "--list", "--version", "--help"},
    "long_valued": {"--command": "stmt", "--file": "file", "--dbname": None, "--host": None,
                    "--port": None, "--username": None, "--set": None, "--variable": None,
                    "--log-file": None, "--output": None, "--field-separator": None, "--pset": None,
                    "--record-separator": None, "--table-attr": None},
    # Each prints or lists and runs no statement of the command's.
    "quiet": {"-V", "--version", "-?", "--help", "-l", "--list"},
    "attached": set(),
    "words_are_statements": False,
}
MYSQL = {
    "flags": set("NBsrtvEHXAfqCnwbicGLoUI?V"),
    "valued": {"e": "stmt", "h": None, "u": None, "P": None, "D": None, "S": None},
    "long_flags": {"--skip-column-names", "--batch", "--silent", "--raw", "--table", "--verbose",
                   "--vertical", "--html", "--xml", "--no-auto-rehash", "--force", "--quick",
                   "--compress", "--unbuffered", "--wait", "--no-beep", "--ignore-spaces", "--comments",
                   "--named-commands", "--skip-line-numbers", "--one-database", "--safe-updates",
                   "--help", "--version", "--ssl", "--skip-ssl", "--column-type-info", "--reconnect",
                   "--skip-reconnect", "--show-warnings", "--binary-as-hex", "--no-defaults",
                   "--password", "--column-names", "--line-numbers"},
    "long_valued": {"--execute": "stmt", "--init-command": "before", "--host": None, "--user": None,
                    "--port": None, "--database": None, "--socket": None, "--protocol": None,
                    "--default-character-set": None, "--defaults-file": None,
                    "--defaults-extra-file": None, "--defaults-group-suffix": None,
                    "--login-path": None, "--ssl-mode": None, "--ssl-ca": None, "--ssl-cert": None,
                    "--ssl-key": None, "--delimiter": None, "--connect-timeout": None,
                    "--max-allowed-packet": None, "--pager": None, "--tee": None, "--prompt": None},
    "quiet": {"-V", "--version", "-?", "-I", "--help"},
    # -p takes its password only as the rest of its own word; alone, it prompts.
    "attached": {"p"},
    "words_are_statements": False,
}
# sqlite3 writes its options with one dash, takes them with two as well, and bundles none.
SQLITE = {
    "flags": set(),
    "valued": {},
    "long_flags": {"-readonly", "-header", "-noheader", "-csv", "-json", "-column", "-line", "-list",
                   "-box", "-table", "-markdown", "-html", "-quote", "-tabs", "-ascii", "-batch",
                   "-bail", "-echo", "-interactive", "-safe", "-stats", "-nofollow", "-version",
                   "-help"},
    "long_valued": {"-cmd": "before", "-init": "file", "-separator": None, "-newline": None,
                    "-nullvalue": None, "-vfs": None, "-maxsize": None, "-mmap": None},
    "quiet": {"-version", "-help"},
    "attached": set(),
    # Every word after the database file is a statement or a dot command.
    "words_are_statements": True,
}
STATEMENT_CLIENTS = {"psql": PSQL, "mysql": MYSQL, "mariadb": MYSQL, "sqlite3": SQLITE}
# Clients this file does not read the statements of: asked about whenever one runs.
UNREAD_CLIENTS = {
    "pgcli", "mycli", "litecli", "usql", "sqlcmd", "sqlplus", "snowsql", "duckdb", "clickhouse-client",
    "cockroach", "mongosh", "mongo", "redis-cli", "pg_restore", "dropdb", "createdb", "dropuser",
    "createuser", "mysqladmin", "mysqlimport", "mariadb-admin",
}
# A client whose statements are not read runs nothing only when asked for help or its version, and
# only by the long forms: their -h is a host and -V varies between them.
UNREAD_HELP_WORDS = {"--help", "--version"}
CLIENTS = set(STATEMENT_CLIENTS) | UNREAD_CLIENTS | {"supabase"}
# A client's name where a command's word would be: not part of a longer name, a path's last part.
CLIENT_WORD = re.compile(r"(?<![A-Za-z0-9_.-])(?:" + "|".join(
    re.escape(c) for c in sorted(CLIENTS, key=len, reverse=True)) + r")(?![A-Za-z0-9_.-])")
# Programs that run the command in their words somewhere else. The value is the words one of which
# must come first (docker pull mysql names an image and runs no client), or None for none.
CARRIERS = {
    "docker": {"exec", "run"}, "podman": {"exec", "run"}, "nerdctl": {"exec", "run"},
    "docker-compose": {"exec", "run"}, "kubectl": {"exec", "run"}, "oc": {"exec", "run"},
    "ssh": None, "npx": None, "bunx": None, "pnpx": None, "op": None, "doppler": None,
    "dotenv": None, "dotenvx": None, "infisical": None, "aws-vault": None, "chamber": None,
    "su": None, "runuser": None, "chroot": None, "nsenter": None,
}
# The Supabase CLI's flags that take the next word, so that word is no subcommand.
# --output-format is db query's own (#2952): its value was being judged as a statement.
SUPABASE_VALUED = {"--workdir", "--profile", "--output", "-o", "--output-format", "--dns-resolver", "--network-id",
                   "--db-url", "--password", "-p", "--schema", "-s", "--project-ref", "--version",
                   "--file", "-f"}
SUPABASE_DB_READS = {"pull", "diff", "dump", "lint", "start", "stop", "test"}
SUPABASE_MIGRATION_READS = {"list", "new", "fetch"}
SUPABASE_MIGRATION_WRITES = {"up", "down", "repair", "squash"}
# The CLI's subcommands that change a branch or a project with no statement, the shell route to
# what SUPABASE_CHANGES names (claude-config#2632): group -> (those that only read, those that
# change something and what). From `supabase branches --help` and `supabase projects --help`, CLI
# 2.75.0; any other subcommand of these groups is asked about as unknown.
SUPABASE_STATE_GROUPS = {
    "branches": ({"get", "list"}, {
        "create": "creates a preview branch, a new database that is billed",
        "delete": "deletes a preview branch and the database it holds",
        "pause": "takes a preview branch and its database offline",
        "unpause": "brings a paused preview branch and its database back into service",
        "update": "changes a preview branch's name, git branch, persistence or status",
    }),
    "projects": ({"list", "api-keys"}, {
        "create": "creates a project, a new database that can add to the bill",
        "delete": "deletes a project and its database",
    }),
}
# `supabase functions deploy`'s own flags that take the next word, and the functions subcommands
# that publish nothing (claude-config#2660). From `supabase functions deploy --help` and `supabase
# functions --help`, CLI 2.75.0. serve takes --no-verify-jwt too, and runs on this Mac only.
SUPABASE_DEPLOY_VALUED = {"--import-map", "-j", "--jobs"}
SUPABASE_FUNCTIONS_OTHER = {"serve", "new", "list", "delete", "download"}
REDIRECT = re.compile(r"&>>?|<<<|<<-?|<>|[<>]&|>>|>\||<|>")


def asked_words():
    """Every word one of which a call must hold for this file to ask about it. db-write-ask.sh
    leaves before python3 starts on a payload holding none of its screen words, so each of these
    must hold one (test-db-write-ask.sh checks it), or the call would never be read."""
    return (set(CLIENTS) | STATEMENT_KEYS | {"sql", "migration", "migrations"}
            | {t[len("mcp__"):] for t in ALWAYS_ASKED}
            # SUPABASE_CHANGES are told by their server's name, which holds this word.
            | {"supabase"})


def strip_redirects(s, found=None):
    """One command's text with each redirection written OUTSIDE quotes taken out, operator and
    target, so `sqlite3 app.db "select 1" > out.txt 2>&1` leaves the statement as its last word.
    One inside quotes is a word of the command and stays: `sqlite3 app.db '>' 'delete from t'`
    runs both words as statements. found, a list, is given each one taken out as (its operator with
    any descriptor number written against it, its target as written), in order (#2952)."""
    out, i, n, quote = [], 0, len(s), None
    while i < n:
        ch = s[i]
        if quote:
            out.append(ch)
            if ch == "\\" and quote == '"' and i + 1 < n:
                out.append(s[i + 1])
                i += 1
            elif ch == quote:
                quote = None
            i += 1
            continue
        if ch == "\\" and i + 1 < n:
            out.append(s[i:i + 2])
            i += 2
            continue
        if ch in "'\"":
            quote = ch
            out.append(ch)
            i += 1
            continue
        m = REDIRECT.match(s, i)
        if not m:
            out.append(ch)
            i += 1
            continue
        # A descriptor number written against the operator is part of it: 2>/dev/null.
        j = len(out)
        while j > 0 and out[j - 1].isdigit():
            j -= 1
        number = ""
        if j == 0 or out[j - 1].isspace():
            number = "".join(out[j:])
            del out[j:]
        operator = number + m.group(0)
        i = m.end()
        while i < n and s[i] in " \t":
            i += 1
        target = i
        if i < n and s[i] == "(":
            depth = 0
            while i < n:
                depth += (s[i] == "(") - (s[i] == ")")
                i += 1
                if depth == 0:
                    break
        else:
            inner = None
            while i < n:
                c = s[i]
                if inner:
                    if c == inner:
                        inner = None
                elif c in "'\"":
                    inner = c
                elif c == "\\" and i + 1 < n:
                    i += 1
                elif c.isspace() or c in ";|&<>()":
                    break
                i += 1
        if found is not None:
            found.append((operator, s[target:i]))
        out.append(" ")
    return "".join(out)


def _base(word):
    return word.rsplit("/", 1)[-1]


def _shell_client(prog, words, judge):
    """The findings for one run of psql, mysql, mariadb or sqlite3, from its words."""
    spec = STATEMENT_CLIENTS[prog]
    statements, before, files, seen, positional = [], [], [], set(), []
    unknown = None

    def take(kind, name, value):
        if kind == "stmt":
            statements.append(value)
        elif kind == "before":
            before.append(value)
        elif kind == "file":
            files.append(value)

    i, n = 1, len(words)
    while i < n and unknown is None:
        w = words[i]
        i += 1
        if w == "--" and not spec["words_are_statements"]:
            positional.extend(words[i:])
            break
        if not w.startswith("-") or w == "-":
            positional.append(w)
            continue
        if spec["words_are_statements"] and w.startswith("--"):
            w = w[1:]
        if w.startswith("--") or spec["words_are_statements"]:
            name, eq, value = w.partition("=")
            seen.add(name)
            if name in spec["long_valued"]:
                if not eq:
                    if i >= n:
                        unknown = name + ", which has no value after it"
                        break
                    value = words[i]
                    i += 1
                take(spec["long_valued"][name], name, value)
            elif name not in spec["long_flags"]:
                unknown = name
            continue
        letters = w[1:]
        for k, ch in enumerate(letters):
            seen.add("-" + ch)
            if ch in spec["flags"]:
                continue
            if ch in spec["attached"]:
                break
            if ch in spec["valued"]:
                value = letters[k + 1:]
                if not value:
                    if i >= n:
                        unknown = "-" + ch + ", which has no value after it"
                        break
                    value = words[i]
                    i += 1
                take(spec["valued"][ch], "-" + ch, value)
                break
            unknown = "-" + ch
            break
    if unknown is not None:
        return [(prog + " has an option this hook does not know (" + unknown + "), so which word is "
                 "its statement could not be told and the call could not be classified as read only", None)]
    if spec["words_are_statements"]:
        statements.extend(positional[1:])
    if files:
        return [(prog + " runs the statements in a file (" + ", ".join(files) + "), which this hook "
                 "does not read, so the call could not be classified as read only", None)]
    if not statements:
        # A statement that runs before the client reads its input does not stand in for that
        # input: `echo "delete from shows" | sqlite3 -cmd "select 1" app.db` runs the delete.
        if seen & spec["quiet"]:
            return []
        return [(prog + " is not provably read only (" + NO_STATEMENT + ")", None)]
    return _judged(prog, before + statements, judge, shell=True, psql=(prog == "psql"))


def _supabase_words(words, valued):
    """One Supabase CLI run's words as (the words that are no flag, each flag as (name, whether it
    was written with =, its value)). A flag in `valued` written without = takes the next word."""
    path, flags = [], []
    i, n = 1, len(words)
    while i < n:
        w = words[i]
        i += 1
        if not w.startswith("-") or w == "-":
            path.append(w)
            continue
        name, eq, value = w.partition("=")
        if not eq and name in valued and i < n:
            value = words[i]
            i += 1
        flags.append((name, bool(eq), value))
    return path, flags


def _dry(flags):
    """Whether a push's flags make it a dry run: only while every --dry-run is bare or =true.
    --dry-run=false is a real push, and so is a dry run undone by a later false. Any value but true
    counts as not dry."""
    dry = None
    for name, eq, value in flags:
        if name == "--dry-run":
            dry = dry is not False and (not eq or value.lower() == "true")
    return bool(dry)


def _supabase(words, judge, here=None):
    """The findings for one run of the Supabase CLI: its db and migration subcommands, the
    branches and projects ones that change a database with no statement, and a functions deploy
    that turns JWT verification off. here is the directory it runs in when it is the whole of its
    command (plain_supabase()), else None."""
    path, flags = _supabase_words(words, SUPABASE_VALUED)
    files = [value for name, _, value in flags if name in ("-f", "--file")]
    if {name for name, _, _ in flags} & {"--help", "-h"} or path[:1] == ["help"]:
        return []
    return (_supabase_state(path) + _supabase_db(path, files, _dry(flags), judge, here, flags)
            + _supabase_deploy(words))


def _supabase_deploy(words):
    """The finding for `supabase functions deploy` (claude-config#2660): every one, whatever its
    flags, since the setting that turns JWT verification off can sit in the project's
    supabase/config.toml, which no flag shows and this never reads. It is read on its own and
    added to what the other rules find. The words are read again with deploy's own valued flags,
    so `-j 2` is not taken for a function's name; the other rules keep their reading, which this
    must not change."""
    path, flags = _supabase_words(words, SUPABASE_VALUED | SUPABASE_DEPLOY_VALUED)
    at = next((k for k, w in enumerate(path) if w == "functions"), None)
    if at is None or path[at + 1:at + 2] == [] or path[at + 1] in SUPABASE_FUNCTIONS_OTHER:
        return []
    if "deploy" not in path[at + 1:]:
        return []
    # What each verification flag says: off, on, or a value that is no boolean. A bare boolean
    # flag is true. The last one given wins in the CLI; the question says off if any one says off.
    off, unclear, on = [], [], []
    for name, eq, value in flags:
        if name not in ("--no-verify-jwt", "--verify-jwt"):
            continue
        text = value.lower() if eq else "true"
        shown = name + ("=" + value[:VALUE_SHOWN] if eq else "")
        if text not in TRUE_WORDS | FALSE_WORDS:
            unclear.append(shown)
        elif (text in TRUE_WORDS) == (name == "--no-verify-jwt"):
            off.append(shown)
        else:
            on.append(shown)
    names = path[path.index("deploy", at + 1) + 1:]
    listed = ", ".join(names)
    if len(listed) > 2 * TARGET_SHOWN:
        listed = listed[:2 * TARGET_SHOWN] + " ... (" + str(len(names)) + " named in all)"
    project = next((value for name, _, value in reversed(flags) if name == "--project-ref" and value), None)
    given = off or unclear or on
    what = ("supabase functions deploy " + (" ".join(given) + " " if given else "") + "publishes "
            + ("all functions in the project's functions folder" if not names
               else ("edge function " if len(names) == 1 else "edge functions ") + listed)
            + " on " + ("project " + project[:TARGET_SHOWN] if project else "the linked project"))
    if off:
        why = what + " with JWT verification off, " + _open_to_all(len(names) != 1)
    elif unclear:
        why = (what + ", and the flag's value is not a plain true or false, so whether JWT "
               "verification stays on could not be told")
    else:
        why = (what + ". Whether the platform checks a caller's JWT can be set in the project's "
               "supabase/config.toml, which this hook does not read")
    return [FunctionDeploy((why, None))]


def _supabase_state(path):
    """The finding for a branches or projects subcommand (SUPABASE_STATE_GROUPS). It is read on
    its own and added to what the db and migration rule finds, never in its place, so a command
    that rule asked about before #2632 is still asked about whatever else its words hold."""
    at = next((k for k, w in enumerate(path) if w in SUPABASE_STATE_GROUPS), None)
    if at is None or at + 1 >= len(path):
        return []
    group, sub = path[at], path[at + 1]
    name = "supabase " + group + " " + sub
    reads, changes = SUPABASE_STATE_GROUPS[group]
    if sub in reads:
        return []
    if sub in changes:
        return [(name + " " + changes[sub], None)]
    return [(name + " is not a subcommand this hook knows, so whether it changes a database could "
             "not be told", None)]


def _workdir(here, flags):
    """The directory a plain Supabase run works in: its last --workdir, read against here, or
    here itself; None when that cannot be told."""
    given = [value for name, _, value in flags if name == "--workdir"]
    if not given:
        return here
    w = given[-1]
    if not w or "$" in w or "`" in w or w.startswith("~"):
        return None
    return os.path.normpath(os.path.join(here, w))


def read_statement_file(here, name, flags):
    """(the text of a `db query -f` file, None), or (None, the clause saying why it could not be
    read). Read only for a plain Supabase run, where nothing in the command writes it first."""
    if not name or "$" in name or "`" in name:
        return None, "its name is filled in only as the command runs"
    if not os.path.isabs(name):
        if any(n == "--workdir" for n, _, _ in flags):
            return None, "it is named relative to a --workdir, which this hook does not resolve"
        name = os.path.join(here, name)
    try:
        if not stat.S_ISREG(os.stat(name).st_mode):
            return None, "it is not a regular file"
        with open(name, "rb") as f:
            data = f.read(STATEMENT_FILE_MAX + 1)
    except OSError as e:
        return None, "it could not be read (" + type(e).__name__ + ")"
    if len(data) > STATEMENT_FILE_MAX:
        return None, "it is larger than " + str(STATEMENT_FILE_MAX) + " bytes"
    try:
        # A file that is not UTF-8 is asked about rather than judged: refusing is the decision.
        return data.decode("utf-8", "strict"), None
    except UnicodeDecodeError:
        return None, "it is not UTF-8 text"


def _file_statements(name, files, here, flags, judge):
    """The findings for the files of one `db query`: each read and its statement judged when the
    run is plain (here is its directory), else asked about unread."""
    if here is None:
        return [(name + " runs the statements in a file (" + ", ".join(files) + "), which this hook "
                 "does not read, so the call could not be classified as read only. It reads one only "
                 "when the command is that one Supabase run and nothing else", None)]
    out = []
    for f in files:
        text, why = read_statement_file(here, f, flags)
        if text is None:
            out.append((name + " runs the statements in a file (" + f + "), which " + why
                        + ", so the call could not be classified as read only", None))
        else:
            # A write from a file Dan's Apply can cover, the skill's ad hoc write path (#2763).
            workdir = _workdir(here, flags)
            full = os.path.normpath(f if os.path.isabs(f) else os.path.join(here, f))
            out.extend(x if workdir is None else Applicable(x, workdir, flags, full)
                       for x in _judged(name + " -f " + f, [text], judge))
    return out


def _supabase_db(path, files, dry, judge, here=None, flags=()):
    """The findings for the db or migration subcommand among a Supabase CLI run's words."""
    at = next((k for k, w in enumerate(path) if w in ("db", "migration", "migrations")), None)
    if at is None or at + 1 >= len(path):
        return []
    group, sub, rest = path[at], path[at + 1], path[at + 2:]
    name = "supabase " + ("db" if group == "db" else "migration") + " " + sub
    unknown = [(name + " is not a subcommand this hook knows, so the call could not be classified as "
                "read only", None)]
    if group != "db":
        if sub in SUPABASE_MIGRATION_READS:
            return []
        if sub in SUPABASE_MIGRATION_WRITES:
            return [(name + " changes the migrations applied to the database", None)]
        return unknown
    if sub in SUPABASE_DB_READS:
        return []
    if sub == "push":
        if dry:
            return []
        finding = (name + " applies the pending migrations to the database", None)
        workdir = None if here is None else _workdir(here, flags)
        # Only a push that is the whole of its command can be covered by an Apply (#2763).
        return [finding if workdir is None else Applicable(finding, workdir, flags)]
    if sub == "reset":
        return [(name + " drops the database and builds it again from the migrations", None)]
    if sub != "query":
        return unknown
    if files:
        return _file_statements(name, files, here, flags, judge) + _judged(name, rest, judge, shell=True)
    if not rest:
        return [(name + " is not provably read only (" + NO_STATEMENT + ")", None)]
    return _judged(name, rest, judge, shell=True)


def _run(words, judge, sw, depth, here=None):
    """The findings for one command's words, from the word that is its program on. here is the
    directory a plain Supabase run works in (plain_supabase()), else None."""
    if not words:
        return []
    prog = _base(words[0])
    if prog in STATEMENT_CLIENTS:
        return _shell_client(prog, words, judge)
    if prog == "supabase":
        return _supabase(words, judge, here)
    if prog in UNREAD_CLIENTS:
        # Only a call that is nothing but a help or version request runs nothing. In these clients -h
        # is the host and -V can be anything, so a short flag never counts, and a help word beside a
        # real run (pg_restore --version -d shop) does not excuse the run.
        if len(words) > 1 and set(words[1:]) <= UNREAD_HELP_WORDS:
            return []
        return [(prog + " is a database client whose statements this hook does not read, so the call "
                 "could not be classified as read only", None)]
    if prog not in CARRIERS:
        return []
    need, out = CARRIERS[prog], []
    for k in range(1, len(words)):
        if need and not need & set(words[1:k]):
            continue
        w = words[k]
        if _base(w) in CLIENTS:
            # The client's own words from its name on: docker exec -i db psql -c "..."
            return out + _run(words[k:], judge, sw, depth)
        if depth < MAX_DEPTH and len(w.split()) > 1 and CLIENT_WORD.search(w):
            # A command line handed over whole: ssh host "psql -c '...'"
            out.extend(_line(w, judge, sw, depth + 1))
    return out


def _line(command, judge, sw, depth, plain=None):
    out = []
    for _, text, wrapper, why, _ in sw.every_command(command):
        if why:
            # A string handed to a shell or eval that cannot be read (`eval "$RUNNER psql ..."`) is
            # asked about when it names a client in its own words. A client inside a substitution
            # is a command of its own, read below (`eval "$(supabase status -o env)"`, 10 of the
            # calls measured), and a script file is given its arguments as data (`bash
            # issue-spool.sh note . "psql was slow"`), its own commands being in the file.
            if not sw.script_file(why) and CLIENT_WORD.search(sw.bare(text)):
                out.append(("a database client is named in a command this hook cannot read (" + why
                            + "), so the call could not be classified as read only", None))
            continue
        passed = []
        rest = sw.command_rest(text, passed)[0]
        # `command -v psql` asks whether psql is installed and runs nothing.
        if any(name == "command" for name, _ in passed) and re.search(r"(?:^|\s)command\s+-[A-Za-z]*[vV]", text):
            continue
        here = plain[0] if plain is not None and depth == 0 and text == plain[1] else None
        out.extend(_run(sw.command_words(strip_redirects(rest)), judge, sw, depth, here))
    return out


def plain_supabase(command, sw, cwd):
    """(the directory it runs in, its text) when the whole Bash command is one Supabase CLI run
    with nothing before it but cd, else None (claude-config#2763). Then nothing in the command can
    write a file before the run reads it, or run anything else an approval would let through. A cd
    to a directory held in a variable or to `-`, a redirection anywhere, a wrapper, a shell variable
    or substitution in the run's words, and a session directory that is not absolute all make it
    None, as does a reading of the command that fails."""
    if not isinstance(cwd, str) or not cwd.startswith("/"):
        return None
    try:
        records = sw.every_command(command, cwd)
    except Exception:
        return None
    found = None
    for d, text, wrapper, why, depth in records:
        if why or wrapper or depth or REDIRECT.search(text):
            return None
        if sw.cd_target(text) is not None:
            continue
        words = sw.command_words(text)
        if (found is not None or not words or _base(words[0]) != "supabase"
                or any("$" in w or "`" in w for w in words)
                or not d.startswith("/") or "$" in d or "`" in d):
            return None
        found = (os.path.normpath(d), text)
    return found


# The flags a CLI read may carry and still be approved by read-only-query-allow.sh (#2763): where to
# send it, how to print it, and the confirmation a hosted database asks for. Any other (a password,
# a connection string, a support ticket) leaves it to the usual check.
READ_QUERY_FLAGS = {"--linked", "--remote", "--local", "--yes", "-f", "--file", "-o", "--output", "--output-format",
                    "--workdir", "--debug", "--read-only"}
DRY_PUSH_FLAGS = {"--dry-run", "--linked", "--local", "--yes", "--workdir", "--debug", "--include-all",
                  "--include-roles", "--include-seed"}


# ---- a command that writes its own `db query -f` files from heredocs, then runs them (#2952) ----
#
# The shape: assignments of literal values, for loops over literal words, cd, `cat > <file> <<EOF`
# writes, `supabase db query` runs of those files, and read only text processing piped from a run.
# Every statement such a command can run is in its text, so it is judged; any other command, or
# anything this cannot settle to literal text, leaves the command to the usual reading, which asks.
SCRIPT_FILTERS = {"grep", "egrep", "fgrep", "head", "tail", "cut", "wc", "tr", "jq"}
SCRIPT_PYTHONS = {"python3", "python"}
SCRIPT_QUIET = {("2>&", "1"), ("2>", "/dev/null")}
SCRIPT_TIMEOUTS = {"timeout", "gtimeout"}
SCRIPT_DURATION = re.compile(r"[0-9]+(?:\.[0-9]+)?[smhd]?\Z")
SCRIPT_MAX_STEPS = 400
# A value put into an unquoted word must stay one word that globs to nothing.
SCRIPT_SAFE = re.compile(r"[A-Za-z0-9_./:@%+,=-]+\Z")
SCRIPT_QUOTED_BAD = re.compile(r'["\\$`\n]')
SCRIPT_VARIABLE = re.compile(r"\$(?:([A-Za-z_][A-Za-z0-9_]*)|\{([A-Za-z_][A-Za-z0-9_]*)\})")
# Names whose value changes what the shell, cd, python or the Supabase CLI does.
SCRIPT_DENIED_NAMES = {"PATH", "IFS", "CDPATH", "HOME", "ENV", "PWD", "OLDPWD", "SHELLOPTS", "BASHOPTS",
                       "GLOBIGNORE", "PS4"}
SCRIPT_DENIED_PREFIXES = ("BASH", "LD_", "DYLD_", "PYTHON", "SUPABASE", "PG")


def _script_name_ok(name):
    """Whether the command may set a shell variable of this name. An assignment to a name already
    exported changes the environment of every program after it, and exported names are, by
    convention, upper case: so only a single letter or a name with a lower case letter in it, never
    one naming a proxy (http_proxy is lower case too), and never one listed above."""
    return (name not in SCRIPT_DENIED_NAMES and not name.startswith(SCRIPT_DENIED_PREFIXES)
            and "proxy" not in name.lower() and (len(name) == 1 or name != name.upper()))
SCRIPT_RESERVED = {"do", "done", "then", "else", "elif", "fi", "if", "while", "until", "case", "esac",
                   "select", "function", "time", "!", "{", "}", "(", ")"}
# python3 -c, read only: these modules, imported under their own names; sys only for its streams,
# argv and exit; no name or attribute starting with an underscore (the way back to open and
# __import__); none of PY_BANNED (type, called on a stream, is a class that opens any file); and no
# module reached through an allowed one, by attribute or by import (statistics.sys, json.codecs),
# which is checked against the real modules.
PY_MODULES = {"json", "sys", "csv", "collections", "datetime", "decimal", "re", "math", "statistics",
              "itertools", "functools", "textwrap"}
PY_SYS = {"stdin", "stdout", "stderr", "argv", "exit", "maxsize"}
PY_BANNED = {"open", "exec", "eval", "compile", "getattr", "setattr", "delattr", "globals", "locals",
             "vars", "breakpoint", "input", "help", "type", "super", "object"}


def _python_finds_nothing_in(folder):
    """Whether a python3 -c run in folder can import nothing from it (#2969). -c puts the folder it
    runs in first on the import path, so a json.py there would run in place of the standard json, and
    a module only an allowed one imports (fractions, under statistics) the same. So the folder must
    hold no file Python imports as a module (any suffix this Python's import machinery loads) and no
    package (a folder holding such an __init__), and PYTHONPATH and PYTHONHOME, which put folders of
    their own ahead of the standard library, must be unset. False when folder is None (a cd this
    cannot follow) or cannot be listed. python3 -I never puts the folder on the path, so it is not
    asked this."""
    import importlib.machinery
    if folder is None or os.environ.get("PYTHONPATH") or os.environ.get("PYTHONHOME"):
        return False
    suffixes = tuple(importlib.machinery.all_suffixes())
    try:
        for name in os.listdir(folder):
            if name.endswith(suffixes):
                return False
            path = os.path.join(folder, name)
            if os.path.isdir(path) and any(
                    inner.startswith("__init__.") and inner.endswith(suffixes) for inner in os.listdir(path)):
                return False
    except OSError:
        return False
    return True


def _python_reads_only(code):
    """Whether a python3 -c program can do nothing but read its input and print: it imports only
    PY_MODULES, each under its own name, touches sys only for PY_SYS, reaches no module through
    another, and names nothing in PY_BANNED or starting with _."""
    import ast
    import types
    # The real modules each chain is looked up on, imported by name from the standard library.
    import collections, csv, datetime, decimal, functools, itertools, math, statistics, sys, textwrap
    real = {m.__name__: m for m in (collections, csv, datetime, decimal, functools, itertools, json,
                                    math, re, statistics, sys, textwrap)}
    try:
        tree = ast.parse(code)
    except (SyntaxError, ValueError):
        return False
    parent, modules = {}, set()
    for node in ast.walk(tree):
        for child in ast.iter_child_nodes(node):
            parent[child] = node
        if isinstance(node, ast.Import):
            # A name on PY_MODULES missing from real fails closed (test-db-write-ask.sh checks they agree).
            if any(a.name not in PY_MODULES or a.name not in real or a.asname for a in node.names):
                return False
            modules.update(a.name for a in node.names)
        elif isinstance(node, ast.ImportFrom):
            if node.level or node.module not in PY_MODULES or node.module not in real:
                return False
            found = real[node.module]
            for a in node.names:
                if (a.name == "*" or a.name.startswith("_") or (node.module == "sys" and a.name not in PY_SYS)
                        or not hasattr(found, a.name) or isinstance(getattr(found, a.name), types.ModuleType)):
                    return False
    for node in ast.walk(tree):
        if isinstance(node, ast.Name):
            if node.id.startswith("_") or node.id in PY_BANNED:
                return False
            if node.id not in modules:
                continue
            # A module's name stands only at the root of an attribute chain, each step of which is
            # looked up on the real module and must be there and be no module itself.
            up, value, first = parent.get(node), real[node.id], True
            if not (isinstance(up, ast.Attribute) and up.value is node):
                return False
            while isinstance(up, ast.Attribute):
                if (up.attr.startswith("_") or (node.id == "sys" and first and up.attr not in PY_SYS)
                        or not hasattr(value, up.attr)):
                    return False
                value, first = getattr(value, up.attr), False
                if isinstance(value, types.ModuleType):
                    return False
                above = parent.get(up)
                up = above if isinstance(above, ast.Attribute) and above.value is up else None
        elif isinstance(node, ast.Attribute) and node.attr.startswith("_"):
            return False
    return True


def _script_expand(text, env, heredoc=False):
    """text with each $NAME or ${NAME} filled in from env, as the shell would: not inside single
    quotes, and in a heredoc body with only \\$, \\`, \\\\ and a backslashed line break read as
    escapes. None when anything is left the shell fills in only as it runs (another variable, a
    substitution, a backquote) or, outside a heredoc, an unquoted glob, brace or tilde, or a value
    that would not stay the one word it is written as."""
    out, i, n, quote = [], 0, len(text), None
    while i < n:
        c = text[i]
        if quote == "'":
            out.append(c)
            i += 1
            if c == "'":
                quote = None
            continue
        if c == "\\" and i + 1 < n:
            nxt = text[i + 1]
            if not heredoc:
                out.append(c + nxt)
            elif nxt in "$`\\":
                out.append(nxt)
            elif nxt != "\n":
                out.append(c + nxt)
            i += 2
            continue
        if not heredoc:
            if c == "'" and quote is None:
                quote = "'"
                out.append(c)
                i += 1
                continue
            if c == '"':
                quote = None if quote == '"' else '"'
                out.append(c)
                i += 1
                continue
            if quote is None and c in "*?[]{}~":
                return None
        if c == "`":
            return None
        if c == "$":
            m = SCRIPT_VARIABLE.match(text, i)
            name = m and (m.group(1) or m.group(2))
            if not name or name not in env:
                return None
            value = env[name]
            if not heredoc and (SCRIPT_QUOTED_BAD.search(value) if quote == '"' else not SCRIPT_SAFE.match(value)):
                return None
            out.append(value)
            i = m.end()
            continue
        out.append(c)
        i += 1
    return None if quote else "".join(out)


def _script_tree(command, sw, cwd):
    """The command as a list of nodes, ("for", text, body nodes) and ("cmd", text, how, heredoc,
    after a pipe), or None when it holds anything but simple commands and for loops at its top
    level: a subshell, a substitution, a background job, another compound command."""
    hd, parts, spans = [], [], []
    try:
        cmds = sw.commands(command, cwd, heredocs=hd, parts=parts, spans=spans)
    except Exception:
        return None
    if len(hd) != len(spans) or len(parts) != len(cmds):
        return None
    body_at = {span[0]: k for k, span in enumerate(spans)}
    root, stack, want_do, prev_how = [], [], False, ""
    stack.append(root)
    for (_, text), part in zip(cmds, parts):
        if tuple(part["scope"]) != (0,) or part["inner"] or part["how"] in ("&", ")", "case"):
            return None
        how, openers = part["how"], part["openers"]
        if len(openers) > 1 or (openers and openers[0][0] not in body_at):
            return None
        heredoc = hd[body_at[openers[0][0]]] if openers else None
        t = text.strip()
        head = t.split(None, 1)[0] if t else ""
        if want_do:
            if head != "do":
                return None
            want_do = False
            t = t[2:].strip()
            if not t:
                if heredoc is not None or how == "|":
                    return None
                continue
            head = t.split(None, 1)[0]
        piped = prev_how == "|"
        prev_how = how
        if head == "for":
            if how != ";" or heredoc is not None or piped:
                return None
            node = ("for", t, [])
            stack[-1].append(node)
            stack.append(node[2])
            want_do = True
            continue
        if head == "done":
            if t != "done" or len(stack) == 1 or heredoc is not None or piped or how == "|":
                return None
            stack.pop()
            continue
        if not t or head in SCRIPT_RESERVED or head in sw.RESERVED:
            return None
        stack[-1].append(("cmd", t, how, heredoc, piped))
    if len(stack) != 1 or want_do:
        return None
    return root


def scripted_queries(command, sw, cwd):
    """The `supabase db query` runs of a command that writes their -f files itself, from heredocs,
    as a list of (subject, {file: the texts it can hold when read}, the statements in its words);
    None when the command is not that shape (claude-config#2952). A file's texts are every heredoc
    text its one write can have put there before that read, each loop value put in, and the file's
    present text, which a write that fails or is skipped leaves in place. Every file a run reads
    must be named by an absolute path that exactly one heredoc write in the command names, every
    file written must be a .sql file a run reads before it is written again, and at least one run
    must read such a file."""
    if not isinstance(cwd, str) or not cwd.startswith("/") or "supabase" not in command:
        return None
    tree = _script_tree(command, sw, cwd)
    if tree is None:
        return None
    env, source, texts, disk, runs, unread = {}, {}, {}, {}, {}, set()
    steps = [0]
    pipe = [None]
    # The folder the command is in at each step, None once a cd goes where this cannot follow (#2969).
    here = [os.path.normpath(cwd)]

    def step(node):
        _, raw, how, heredoc, piped = node
        steps[0] += 1
        if steps[0] > SCRIPT_MAX_STEPS:
            return False
        expanded = _script_expand(raw, env)
        if expanded is None:
            return False
        found = []
        try:
            words = sw.shell_split(strip_redirects(expanded, found))
            redirects = []
            for op, target in found:
                target_words = sw.shell_split(target)
                if len(target_words) != 1:
                    return False
                redirects.append((op, target_words[0]))
        except ValueError:
            return False
        if not words:
            return False
        if piped != (pipe[0] is not None):
            return False
        if piped:
            # A member after the first: text processing that only reads the run's output.
            if heredoc is not None or not set(redirects) <= SCRIPT_QUIET or not pipe[0]:
                return False
            if _base(words[0]) in SCRIPT_PYTHONS:
                isolated = len(words) == 4 and words[1:3] == ["-I", "-c"]
                plain = len(words) == 3 and words[1] == "-c"
                ok = (isolated or plain) and _python_reads_only(words[-1]) and (
                    isolated or _python_finds_nothing_in(here[0]))
            else:
                ok = words[0] in SCRIPT_FILTERS
            if not ok:
                return False
            if how != "|":
                pipe[0] = None
            return True
        if all(sw.ASSIGNMENT.match(w) for w in words):
            if redirects or heredoc is not None or how == "|":
                return False
            for w in words:
                name, _, value = w.partition("=")
                if not _script_name_ok(name):
                    return False
                env[name] = value
            return True
        if words[0] == "cd":
            if len(words) != 2 or redirects or heredoc is not None or how == "|":
                return False
            # Followed as the shell's cd does by default, logically: `..` after a link is the link's
            # parent, so the path is normalised as written, never resolved through its links.
            to = words[1]
            if to.startswith("/"):
                here[0] = os.path.normpath(to)
            elif to == "-" or to.startswith("~") or here[0] is None:
                here[0] = None
            else:
                here[0] = os.path.normpath(os.path.join(here[0], to))
            return True
        if words == ["cat"] and heredoc is not None:
            ops = sorted(op for op, _ in redirects)
            target = [t for op, t in redirects if op in (">", ">|")]
            if how == "|" or len(redirects) != 2 or ops[0] not in ("<<", "<<-") or ops[1] not in (">", ">|"):
                return False
            # Only a .sql file, named in full, which a run then reads before anything writes it
            # again: so every text written is judged, and so is what the file held before.
            key = os.path.realpath(target[0])
            if not target[0].startswith("/") or not key.endswith(".sql") or key in unread:
                return False
            quoted, _, body = heredoc
            text = body if quoted else _script_expand(body, env, heredoc=True)
            if text is None:
                return False
            if source.setdefault(key, id(node)) != id(node):
                return False
            texts.setdefault(key, []).append(text)
            unread.add(key)
            return True
        if words[0] in SCRIPT_TIMEOUTS and len(words) > 2 and SCRIPT_DURATION.match(words[1]):
            words = words[2:]
        if _base(words[0]) != "supabase" or heredoc is not None or not set(redirects) <= SCRIPT_QUIET:
            return False
        path, flags = _supabase_words(words, SUPABASE_VALUED)
        if path[:2] != ["db", "query"] or not {name for name, _, _ in flags} <= READ_QUERY_FLAGS:
            return False
        files, statements = runs.setdefault(id(node), ({}, []))
        for name, _, value in flags:
            if name not in ("-f", "--file"):
                continue
            if not value.startswith("/"):
                return False
            key = os.path.realpath(value)
            if key not in texts:
                return False
            unread.discard(key)
            if key not in disk:
                disk[key] = None
                if os.path.lexists(key):
                    present, _ = read_statement_file("/", key, ())
                    if present is None:
                        return False
                    disk[key] = present
            held = files.setdefault(value, [])
            for t in texts[key] + ([disk[key]] if disk[key] is not None else []):
                if t not in held:
                    held.append(t)
        statements.extend(s for s in path[2:] if s not in statements)
        if not files and not statements:
            return False
        if how == "|":
            pipe[0] = True
        return True

    def walk(nodes):
        for node in nodes:
            if node[0] == "cmd":
                if not step(node):
                    return False
                continue
            steps[0] += 1
            expanded = _script_expand(node[1], env)
            try:
                words = sw.shell_split(expanded) if expanded is not None else []
            except ValueError:
                return False
            if (len(words) < 3 or words[0] != "for" or words[2] != "in"
                    or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", words[1])
                    or not _script_name_ok(words[1])):
                return False
            for value in words[3:]:
                env[words[1]] = value
                if not walk(node[2]):
                    return False
        return True

    # A command whose runs read no file it wrote is not this shape, and is read as before.
    if not walk(tree) or pipe[0] is not None or unread or not any(files for files, _ in runs.values()):
        return None
    return [("supabase db query", files, statements) for files, statements in runs.values()]


def _scripted_findings(queries, judge):
    """The findings for scripted_queries()'s runs: each text a file can hold, and each statement
    word, judged by the one predicate."""
    out = []
    for name, files, statements in queries:
        for f, held in files.items():
            out.extend(_judged(name + " -f " + f, held, judge))
        out.extend(_judged(name, statements, judge, shell=True))
    return out


class UnsureLine(Exception):
    """A reading named a line it cannot vouch for: a # it took for a comment without knowing that
    the shell does, or a heredoc it cannot find the end of."""


class CannotAsk(Exception):
    """The reader's commands() has no `unsure` to ask for, so it cannot say which lines those are."""


# What is said of a line the reader named, by the mark it named the line with, and how to write the
# command so that the reader names nothing in it (claude-config#3472). The reader names a # it took
# for a comment without knowing that the shell does (#3464, #3481) and a heredoc it cannot find the
# end of (#3492, #3566), and one sentence for all of them, about a #, sent whoever read it looking
# for a # in a command that held none. Each sentence is true of its own mark and claims nothing of
# another, each fact in it is one lib/shell-words.py measured (commands(), heredoc_close() and
# heredoc_opener() say where and when), and test-db-write-ask-unsure-line.sh holds a case per mark.
# The %s is the line the mark stands in.
UNSURE = {
    # The reading reached its end, so the # is one the reader took for a comment where it cannot
    # tell which the shell does: after a ) whose kind it does not know, or inside backquotes.
    "comment": ("the command holds a # the shared reader cannot tell from a comment, in the line %s: a shell "
                "reads a # inside a word where a closing parenthesis stands right before it, or inside "
                "backquotes, and then runs the rest of that line, so what runs after it on that line could "
                "not be read",
                "Write that # inside quotes, or put the comment on a line of its own"),
    # The reading gave up: the # may be one every shell reads inside a word, which the reader read
    # on past as the shell does, and then could not read the text to its end.
    "unread": ("the command holds a #, in the line %s, past which the shared reader could not read the text "
               "to its end: a shell reads a # inside a word where a backslash or a closing parenthesis "
               "stands right before it, and then runs the rest of that line, so what runs after it could "
               "not be read",
               "Write that # inside quotes, or put the comment on a line of its own"),
    # An unquoted heredoc the shells end somewhere other than its first marker line, or nowhere.
    "close": ("the command opens a heredoc the shared reader cannot find the end of, in the line %s: its end "
              "marker is not quoted, and either a later line ends in a backslash, which a shell joins to "
              "the next line, marker or not, or no line ends the heredoc while a $ or a backquote follows. "
              "A shell that keeps the heredoc open runs every $( ) in the rest of the text, in single "
              "quotes or not, so what runs after that line could not be read",
              "End the heredoc with its marker alone on a line that follows no backslash, or quote the "
              "marker (<<'EOF') where nothing in the body is to be expanded"),
    "joined": ("the command opens a heredoc on a line that ends in a backslash before the heredoc's end marker "
               "is whole, the line %s: a shell joins that line to the next, so the end marker is the word "
               "the two lines make, and where the heredoc ends, and so what runs after it, could not be read",
               "Write the << and its whole end marker on one line"),
    "split": ("the command opens a heredoc whose end marker is quoted and holds a line break, in the line %s: "
              "no line of the text can be that marker, so bash and zsh never end the heredoc and feed the "
              "rest of the text to its command, where dash and ksh end it at the lines that spell the "
              "marker, so what runs after it could not be read",
              "Write the end marker as one word on the line that opens the heredoc"),
    "dollar": ("the command opens a heredoc whose end marker holds a dollar quote, in the line %s: dash reads "
               "the $ as a character of the marker, and bash and zsh differ on some of what such quotes "
               "hold, so no such heredoc ends at the same line in every shell, and what runs after it could "
               "not be read",
               "Write the end marker as a plain word, or in single quotes (<<'EOF') where nothing in the "
               "body is to be expanded"),
    "one line": ("the command opens a heredoc in a text with no line break, %s: typed on one line no shell "
                 "gives a heredoc a body, and every shell runs the commands after it on that line, which the "
                 "shared reader took for its body, so what runs there could not be read",
                 "Put the heredoc's body and its end marker on lines of their own after the line that "
                 "opens it"),
    # A heredoc named for a reason this file cannot tell (heredoc_opener() could not be asked).
    "heredoc": ("the command opens a heredoc whose end the shared reader cannot vouch for, in the line %s, so "
                "what runs after it could not be read",
                "Write the heredoc with a plain word for its end marker, alone on its closing line"),
    # A mark the reader may come to name that is neither: nothing is claimed of it but that.
    "line": ("the command holds a line the shared reader is unsure of, %s, so what runs on it could not be read",
             "Write that line more plainly"),
}
# How much of the line a sentence shows.
LINE_SHOWN = 120


class Unsure(str):
    """One of asked_reading()'s faults: the sentence for a line the reader named, true of the mark
    it named the line with (UNSURE). .kind is which mark, and .fix how to write the command so that
    the reader names nothing there, for a caller that refuses the command (unsure_fix())."""

    def __new__(cls, kind, line):
        what, fix = UNSURE[kind]
        self = str.__new__(cls, what % ("`" + line + "`"))
        self.kind, self.fix = kind, fix
        return self


def _mark(sw, s, at, ended):
    """Which of UNSURE's marks the reader named at s[at], in a reading of s that reached its end
    (ended) or gave up. A heredoc is named by its <<, and which kind it is comes from the reader's
    own heredoc_opener(), asked as commands() asks it."""
    if s.startswith("#", at):
        return "comment" if ended else "unread"
    if not s.startswith("<<", at):
        return "line"
    joins, doubts = [], []
    try:
        opener = sw.heredoc_opener(s, at, joins=joins, doubts=doubts)
    except Exception:
        return "heredoc"
    if joins:
        return "joined"
    if doubts:
        return "dollar"
    if "\n" not in s:
        return "one line"
    if not opener:
        return "heredoc"
    if "\n" in opener[0]:
        return "split" if opener[2] else "heredoc"
    return "heredoc" if opener[2] else "close"


def _unsure(sw, s, at, ended):
    """The Unsure for the mark the reader named at s[at]. Never raises: it runs as a reading ends,
    where a failure of its own would stand in for the reading's."""
    try:
        start = s.rfind("\n", 0, at) + 1
        end = s.find("\n", at)
        return Unsure(_mark(sw, s, at, ended), s[start:len(s) if end < 0 else end].strip()[:LINE_SHOWN])
    except Exception:
        return Unsure("line", "")


@contextlib.contextmanager
def asking(sw):
    """Inside the block, every reading sw's commands() makes asks the reader which lines it cannot
    vouch for (its `unsure`): a # it took for a comment without being sure the shell does
    (claude-config#3464), and a heredoc it cannot find the end of (#3492, #3566). A reading that
    names one raises UnsureLine, whether it reached its end or gave up, as the Slack drafts gate's
    readings do. A caller that asks is also given the rest of the line read as commands wherever
    every shell reads the # inside a word (claude-config#3481), so nothing on such a line is left
    out. The block is given the list of every line named, each as the Unsure that says which mark
    it was named with. A reader with no `unsure` to ask for raises CannotAsk before the block
    starts, so a caller that cannot ask never passes for one that asked and was told nothing. sw
    reads as it did once the block ends."""
    plain, named = sw.commands, []
    # Whether commands() takes `unsure` is read from its own code object, which a function written
    # in Python has: importing the inspect module to ask cost every call that loads this file 8 ms
    # (python3 -X importtime, the personal MacBook, 2026-11-24). A callable with no code object of
    # its own cannot be asked.
    code = getattr(plain, "__code__", None)
    if code is None or "unsure" not in code.co_varnames[:code.co_argcount + code.co_kwonlyargcount]:
        raise CannotAsk()

    def commands(*args, **asked):
        if asked.get("unsure") is not None:
            return plain(*args, **asked)
        marks, ended = [], False
        try:
            got = plain(*args, unsure=marks, **asked)
            ended = True
            return got
        finally:
            if marks:
                s = args[0] if args else asked.get("s", "")
                named.extend(_unsure(sw, s if isinstance(s, str) else "", mark[0], ended) for mark in marks)
                raise UnsureLine(marks[0][0])

    sw.commands = commands
    try:
        yield named
    finally:
        sw.commands = plain


UNREAD_LINE = ("the command holds a # the shell reads inside a word, and read that way, with the rest "
               "of its line, the command is not one this hook approves")
CANNOT_SAY = "lib/shell-words.py cannot say which lines it is unsure of (its commands() takes no `unsure`)"
CANNOT_ASK = CANNOT_SAY + ", so no command read through it is approved"


def asked_reading(sw, read):
    """(what read() gives, None) when read() is run by the reading sw gives a caller that asks
    which lines it is unsure of (asking()), every one of its readings being of commands with no
    line named. (None, an Unsure) when a reading named a line, whatever read() then made of the
    part it was given: the sentence for the first line named, true of the mark it was named with.
    (None, CANNOT_SAY) when the reader cannot be asked. Any other failure of read() is raised.
    This is the one place a caller turns a reading into "sure, and this is it" or "not sure, and
    why" (claude-config#3472): cli_read_approval() approves by it, bash_findings() and
    dry_push_dir() decide by it, and db-write-ask.sh reads a commit by it. The reader is asked
    whatever the command holds: a heredoc it cannot find the end of needs no #, so a caller that
    asked only about a command holding one never heard of those."""
    try:
        with asking(sw) as named:
            try:
                got = read()
            except Exception:
                # A reading that named a line and then failed is the unsure line's doing.
                if not named:
                    raise
                got = None
    except CannotAsk:
        return None, CANNOT_SAY
    if named:
        return None, named[0]
    return got, None


def second_reading(command, sw, cwd, first, read):
    """asked_reading()'s answer for a caller whose read() is costly and that already holds first,
    what read() gave by the reader's own reading: (first, None) without running read() again when
    the reader gives a caller that asks the very commands it gives one that does not
    (every_command(), every wrapped string and substitution among them), since read() would then
    be told nothing new; else asked_reading(sw, read). db-write-ask.sh reads a commit this way,
    whose read() has git look at the checkout (claude-config#3472). The two readings are compared
    whatever the command holds: it was skipped for one holding no #, and a heredoc the reader
    cannot find the end of holds none."""
    plain = sw.every_command(command, cwd)
    same, fault = asked_reading(sw, lambda: sw.every_command(command, cwd) == plain)
    if fault is not None:
        return None, fault
    if same:
        return first, None
    return asked_reading(sw, read)


def cli_read_approval(command, cwd, judge, sw):
    """(True, why) when the whole Bash command is one Supabase CLI run that changes nothing: a `db
    query` whose every statement, in its words or its -f files, judge() shows to be read only, or a
    `db push --dry-run`; or, since #2952, a command whose `db query` runs read files it writes
    itself from heredocs (scripted_queries()), when every text those files can hold and every
    statement in the runs' words judge() shows to be read only. Else (False, why not).
    db-write-ask.sh asks about none of these, by the same reading (bash_findings()), so the two
    hooks cannot disagree about one (L342).

    Since #3472 the command must be one of those by two readings: the reader's own, and the one it
    gives a caller that asks which lines it is unsure of (asking()). The reader took a # for a
    comment by a rule the shell does not follow, so a command on the rest of that line was left out
    of the first reading, and a write there was approved along with the read in front of it. Read
    the second way such a line is read as the shell runs it, and a line the reader cannot vouch
    for is named, a # it cannot tell from a comment or a heredoc it cannot find the end of, which
    approves nothing, and why says which in the words for that mark (UNSURE). Both must approve,
    so nothing is approved now that was not before."""
    ok, why = _cli_read_approval(command, cwd, judge, sw)
    if not ok:
        return ok, why
    try:
        sure, fault = asked_reading(sw, lambda: _cli_read_approval(command, cwd, judge, sw))
    except Exception as e:
        return False, ("the command could not be read a second time, asking the reader which lines it "
                       "is unsure of (%s)" % type(e).__name__)
    if fault is not None:
        return False, CANNOT_ASK if fault is CANNOT_SAY else fault
    if not sure[0]:
        return False, UNREAD_LINE
    return ok, why


def _cli_read_approval(command, cwd, judge, sw):
    """cli_read_approval()'s answer by one reading of the command, whichever sw gives."""
    plain = plain_supabase(command, sw, cwd)
    if plain is None:
        scripted = scripted_queries(command, sw, cwd)
        if scripted is None:
            return False, "the command is not one Supabase CLI run"
        found = _scripted_findings(scripted, judge)
        if found:
            return False, found[0][0]
        return True, ("supabase db query runs only statements that read, from files the command "
                      "writes itself from heredocs")
    here, text = plain
    path, flags = _supabase_words(sw.command_words(text), SUPABASE_VALUED)
    names = {name for name, _, _ in flags}
    if path == ["db", "push"]:
        if _dry(flags) and names <= DRY_PUSH_FLAGS:
            return True, "supabase db push --dry-run prints the migrations it would apply and applies none"
        return False, "it is not a dry run with flags this hook knows"
    if path[:2] != ["db", "query"] or not names <= READ_QUERY_FLAGS:
        return False, "it is not a supabase db query with flags this hook knows"
    files = [value for name, _, value in flags if name in ("-f", "--file")]
    if not files and len(path) < 3:
        return False, NO_STATEMENT
    found = _supabase_db(path, files, False, judge, here, flags)
    if found:
        return False, found[0][0]
    return True, "supabase db query runs only statements that read"


# The flags a dry run may carry and still preview what an Applied push would send: the push's own
# (lib/db-apply-approval.py PUSH_FLAGS) and --dry-run. --local or --db-url previews another database,
# and --include-all, --include-seed or --include-roles a different set of changes.
DRY_RUN_FLAGS = {"--dry-run", "--linked", "--yes", "--workdir", "--debug"}


def dry_push_dir(command, sw, cwd):
    """The directory whose supabase/migrations a Bash command previews, when the whole command is
    one `supabase db push --dry-run` of the linked project (plain_supabase(), so nothing else in it
    could change the folder), else None (claude-config#2829).

    Since #3472 a command must be that dry run, of that directory, by both readings: the reader's
    own, and the one it gives a caller that asks (asked_reading()). One the shell reads on past a #
    is no dry run of it (None), and one holding a line the reader names, a # it cannot tell from a
    comment or a heredoc it cannot find the end of, raises UnsureLine (CannotAsk when the reader
    cannot be asked), which the Apply check reports as a command it could not read, so no push is
    let through on the strength of it. The second reading is made whatever the command holds."""
    here = _dry_push_dir(command, sw, cwd)
    if here is None:
        return here
    sure, fault = asked_reading(sw, lambda: _dry_push_dir(command, sw, cwd))
    if fault is not None:
        raise (CannotAsk if fault is CANNOT_SAY else UnsureLine)(fault)
    return here if sure == here else None


def _dry_push_dir(command, sw, cwd):
    """dry_push_dir()'s answer by one reading of the command, whichever sw gives."""
    plain = plain_supabase(command, sw, cwd)
    if plain is None:
        return None
    here, text = plain
    path, flags = _supabase_words(sw.command_words(text), SUPABASE_VALUED)
    if path != ["db", "push"] or not _dry(flags) or not {name for name, _, _ in flags} <= DRY_RUN_FLAGS:
        return None
    if any(name == "--linked" and eq and value.lower() not in ("true", "1", "t") for name, eq, value in flags):
        return None
    return _workdir(here, flags)


class SecondReading(tuple):
    """A finding, (why, statement), that is what it is because the command was read a second time,
    as the reader gives it to a caller that asks (claude-config#3472): that it could not be read
    that way (a line the reader names, which is an UnsureFinding, or a reader that cannot be asked), or that
    a run the first reading took for the whole of its command is not that. It is a finding like any
    other to whoever unpacks it, and db-write-ask.sh names the issue by the type."""
    __slots__ = ()


def is_second_reading(finding):
    """Whether one of bash_findings()'s findings is one only the second reading of the command
    accounts for (SecondReading)."""
    return isinstance(finding, SecondReading)


def unsure_why(fault, untold):
    """One of asked_reading()'s faults and what it leaves untold, as one sentence."""
    return fault + (" and " if isinstance(fault, Unsure) else ", so ") + untold


class UnsureFinding(SecondReading):
    """The SecondReading finding for a line the reader named (an Unsure): (why, None), with .fix,
    how to write the command so that the reader names nothing there. db-write-ask.sh refuses a
    command with such a finding as one it could not check, where it asks about every other."""

    def __new__(cls, fault, untold):
        self = tuple.__new__(cls, (unsure_why(fault, untold), None))
        self.fix = fault.fix
        return self


def unsure_fix(told):
    """How to write a command so that the reader names no line in it, when told, one of
    asked_reading()'s faults or one of bash_findings()'s findings, is about a line the reader
    named; else None. A caller refuses on it and says this, where a reader that cannot be asked
    (CANNOT_SAY) has no such rewriting and is asked about (claude-config#3472)."""
    return told.fix if isinstance(told, (Unsure, UnsureFinding)) else None


READ_ON = (", in a command where the shell reads a # inside a word and runs the rest of that line, so it is "
           "not the one run of the whole command that an Apply or a test project list could cover")


def _not_whole(finding):
    """An Applicable finding as one nothing covers, saying why."""
    return SecondReading((finding[0] + READ_ON, finding[1]))


def _same_run(finding):
    """What makes an Applicable finding of one reading the same run as one of the other."""
    return tuple(finding), finding.workdir, tuple(tuple(flag) for flag in finding.flags), finding.file


def bash_findings(command, judge, sw, cwd=""):
    """Every (why, statement) one Bash command is asked about, in the order it runs them; [] when it
    runs no database client, or only statements judge() shows to be read only. cwd is the session's
    directory, which a plain Supabase run is read against.

    Since #3472 a command is read twice: by the reader's own reading, as it always was, and by the
    one the reader gives a caller that asks which lines it is unsure of (asked_reading()). The
    reader took a # for a comment by a rule the shell does not follow, so a write on the rest of
    that line was in no finding, and a push with such a line was Applicable, which let the line
    through with it. Now:

    - what the first reading finds is still found, in the same words and the same order, so nothing
      asked about before stops being asked about;
    - what only the second reading finds, a write on a line the shell reads on into, is added;
    - a line the reader names, a # it cannot tell from a comment or a heredoc it cannot find the
      end of, is a finding of its own, the first (an UnsureFinding, in the words for that mark,
      which db-write-ask.sh refuses the command on), as is a reader that cannot be asked, since
      nobody can say such a command holds no write, and no finding beside it is Applicable;
    - a finding is Applicable only when both readings find that same run, the whole of its command,
      so an Apply or a test project list covers nothing the second reading shows beside it; one
      that only one reading finds so says why nothing covers it (is_second_reading()).

    The second reading was made only of a command holding a #, on the ground that the reader's
    `unsure` was a list of them. It has named heredocs too since #3492, which hold none, so a
    write the shell runs out of one of those was in no finding (reproduced at the hook for each
    kind, test-db-write-ask-unsure-line.sh). Every command naming a database client is now read
    both ways."""
    if not CLIENT_WORD.search(command):
        return []
    found = _bash_findings(command, judge, sw, cwd)
    sure, fault = asked_reading(sw, lambda: _bash_findings(command, judge, sw, cwd))
    if fault is not None:
        untold = "the call could not be classified as read only"
        return ([UnsureFinding(fault, untold) if isinstance(fault, Unsure)
                 else SecondReading((unsure_why(fault, untold), None))]
                + [tuple(f) if is_applicable(f) else f for f in found])
    whole = {_same_run(f) for f in sure if is_applicable(f)}
    out = [_not_whole(f) if is_applicable(f) and _same_run(f) not in whole else f for f in found]
    first = {(tuple(f), is_function_deploy(f)) for f in found}
    for f in sure:
        if (tuple(f), is_function_deploy(f)) not in first:
            out.append(_not_whole(f) if is_applicable(f) else f)
    return out


def _bash_findings(command, judge, sw, cwd):
    """bash_findings()'s answer by one reading of the command, whichever sw gives."""
    scripted = scripted_queries(command, sw, cwd)
    if scripted is not None:
        return _scripted_findings(scripted, judge)
    return _line(command, judge, sw, 0, plain_supabase(command, sw, cwd))
