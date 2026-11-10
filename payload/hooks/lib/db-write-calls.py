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

Since #2660 it names one call that changes no database: a Supabase edge function deploy that turns
JWT verification off, which publishes a function the platform lets anyone call without signing in.

  mcp_finding(tool, tool_input, judge)   one MCP call other than the two #2521 named
  supabase_change(tool, tool_input)      the sentence for a call in SUPABASE_CHANGES, or None
  supabase_open_deploy(tool, tool_input) the sentence for a deploy with JWT verification off, or None
  named_as_database_call(tool)           whether a tool's name alone says it runs statements or
                                         is one of SUPABASE_CHANGES
  named_as_function_deploy(tool)         whether a tool's name alone says it deploys an edge function
  bash_findings(command, judge, sw)      one Bash command; sw is lib/shell-words.py, loaded
  is_open_deploy(finding)                whether a finding is about a deploy and not a database
  asked_words()                          every word a call must hold for this file to ask about it

Each finding is (why the call is asked about, the statement it is about or None).

EDGE FUNCTION DEPLOYS WITH JWT VERIFICATION OFF (claude-config#2660). #2632 left every deploy
unasked, as code and not a database. One is asked about since: a deploy that turns JWT verification
off, after which the platform checks no caller, so anyone holding the function's address can call
it unless its own code checks them.
  - deploy_edge_function on any server whose name holds supabase, when its verify_jwt is false (or
    the text false, or a no_verify_jwt that is true), with the function and project its input
    names. A verify_jwt that is neither true nor false (null, a number, the text true) is asked
    about as one that could not be read, since what a server makes of it was not measured.
    verify_jwt true is passed, and so is verify_jwt left out: the claude.ai connector's schema, read
    on 2026-11-10, declares it a boolean whose default is true (and requires it). That default was
    read from the schema and not measured on a deploy (L82), and another Supabase server's default
    was not read at all.
  - `supabase functions deploy` with --no-verify-jwt (`supabase functions deploy --help`, CLI
    2.75.0), unless every one given is =false, and with the --verify-jwt=false an older CLI took
    (2.75.0 refuses it as unknown). `functions serve --no-verify-jwt` runs on this Mac only and is
    passed.
Measured on the personal MacBook on 2026-11-10, over all 8,368 transcripts: 3 Bash commands ran
`supabase functions deploy`, none with the flag, and no session had called deploy_edge_function, so
this adds no question to anything run there.

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
(code and configuration, as `supabase functions deploy` is unasked in a shell; the secret's value,
by the tool's description, is typed in the Supabase dashboard and never passes through the
session), create_notebook (saved without being run; run_notebook is asked about), delete_notebook,
submit_feedback and delete_feedback. Since #2660 a deploy that turns JWT verification off is asked
about, in the section above; one that keeps it on is still left unasked.

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
  - a client run through CARRIERS (docker exec, ssh, npx, a secret runner) is read from the
    client's own name on, or from the quoted command line handed over.

WHAT IT DOES NOT SEE: a script file's commands (`bash change.sh`), a client run by a name held in a
variable, a program that opens a database itself (python, node, an ORM's own CLI), and a carrier
not on CARRIERS, which is a hand written list (L96). SUPABASE_CHANGES is one too: a tool Supabase
adds later that changes a database with no statement, and any other host's tool of that kind (a
Neon branch reset, say), is unasked until it is listed. Of a deploy with JWT verification off: one
whose setting is in the project's supabase/config.toml (`verify_jwt = false` under the function),
which a plain `supabase functions deploy` then applies with no flag in the command; a deploy
through a Supabase server whose name does not hold supabase; and a call to Supabase's own API
(curl, a script).
"""
import json
import re

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


class OpenDeploy(tuple):
    """A finding, (why, None), about an edge function deploy with JWT verification off. It is a
    finding like any other to whoever unpacks it, and db-write-ask.sh words its question by the
    type, since this one is not about a database."""
    __slots__ = ()


def is_open_deploy(finding):
    """Whether one of bash_findings()'s findings is about an edge function deploy that turns JWT
    verification off, and so not about a database."""
    return isinstance(finding, OpenDeploy)


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
SUPABASE_VALUED = {"--workdir", "--profile", "--output", "-o", "--dns-resolver", "--network-id",
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


def strip_redirects(s):
    """One command's text with each redirection written OUTSIDE quotes taken out, operator and
    target, so `sqlite3 app.db "select 1" > out.txt 2>&1` leaves the statement as its last word.
    One inside quotes is a word of the command and stays: `sqlite3 app.db '>' 'delete from t'`
    runs both words as statements."""
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
        if j == 0 or out[j - 1].isspace():
            del out[j:]
        i = m.end()
        while i < n and s[i] in " \t":
            i += 1
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


def _supabase(words, judge):
    """The findings for one run of the Supabase CLI: its db and migration subcommands, the
    branches and projects ones that change a database with no statement, and a functions deploy
    that turns JWT verification off."""
    path, flags = _supabase_words(words, SUPABASE_VALUED)
    # A dry run only while every --dry-run is bare or =true: --dry-run=false is a real push, and so
    # is a dry run undone by a later false. Any value but true counts as not dry.
    dry = None
    for name, eq, value in flags:
        if name == "--dry-run":
            dry = dry is not False and (not eq or value.lower() == "true")
    files = [value for name, _, value in flags if name in ("-f", "--file")]
    if {name for name, _, _ in flags} & {"--help", "-h"} or path[:1] == ["help"]:
        return []
    return _supabase_state(path) + _supabase_db(path, files, dry, judge) + _supabase_deploy(words)


def _supabase_deploy(words):
    """The finding for `supabase functions deploy` with JWT verification turned off
    (claude-config#2660), read on its own and added to what the other rules find. The words are
    read again with deploy's own valued flags, so `-j 2` is not taken for a function's name; the
    other rules keep their reading, which this must not change."""
    path, flags = _supabase_words(words, SUPABASE_VALUED | SUPABASE_DEPLOY_VALUED)
    at = next((k for k, w in enumerate(path) if w == "functions"), None)
    if at is None or path[at + 1:at + 2] == [] or path[at + 1] in SUPABASE_FUNCTIONS_OTHER:
        return []
    if "deploy" not in path[at + 1:]:
        return []
    # Each flag that turns verification off, and each whose value is no boolean. A bare boolean
    # flag is true. The last one given wins in the CLI; this asks if any one turns it off, so
    # --no-verify-jwt=false passes only when nothing beside it says otherwise.
    off, unclear = [], []
    for name, eq, value in flags:
        if name not in ("--no-verify-jwt", "--verify-jwt"):
            continue
        text = value.lower() if eq else "true"
        shown = name + ("=" + value[:VALUE_SHOWN] if eq else "")
        if text not in TRUE_WORDS | FALSE_WORDS:
            unclear.append(shown)
        elif (text in TRUE_WORDS) == (name == "--no-verify-jwt"):
            off.append(shown)
    if not off and not unclear:
        return []
    names = path[path.index("deploy", at + 1) + 1:]
    listed = ", ".join(names)
    if len(listed) > 2 * TARGET_SHOWN:
        listed = listed[:2 * TARGET_SHOWN] + " ... (" + str(len(names)) + " named in all)"
    project = next((value for name, _, value in reversed(flags) if name == "--project-ref" and value), None)
    what = ("supabase functions deploy " + " ".join(off or unclear) + " publishes "
            + ("every edge function in the project's functions folder" if not names
               else ("edge function " if len(names) == 1 else "edge functions ") + listed)
            + " on " + ("project " + project[:TARGET_SHOWN] if project else "the linked project"))
    if off:
        return [OpenDeploy((what + " with JWT verification off, " + _open_to_all(len(names) != 1), None))]
    return [OpenDeploy((what + ", and the flag's value is not a plain true or false, so whether JWT "
                        "verification stays on could not be told", None))]


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


def _supabase_db(path, files, dry, judge):
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
        return [] if dry else [(name + " applies the pending migrations to the database", None)]
    if sub == "reset":
        return [(name + " drops the database and builds it again from the migrations", None)]
    if sub != "query":
        return unknown
    if files:
        return [(name + " runs the statements in a file (" + ", ".join(files) + "), which this hook "
                 "does not read, so the call could not be classified as read only", None)]
    if not rest:
        return [(name + " is not provably read only (" + NO_STATEMENT + ")", None)]
    return _judged(name, rest, judge, shell=True)


def _run(words, judge, sw, depth):
    """The findings for one command's words, from the word that is its program on."""
    if not words:
        return []
    prog = _base(words[0])
    if prog in STATEMENT_CLIENTS:
        return _shell_client(prog, words, judge)
    if prog == "supabase":
        return _supabase(words, judge)
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


def _line(command, judge, sw, depth):
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
        out.extend(_run(sw.command_words(strip_redirects(rest)), judge, sw, depth))
    return out


def bash_findings(command, judge, sw):
    """Every (why, statement) one Bash command is asked about, in the order it runs them; [] when it
    runs no database client, or only statements judge() shows to be read only."""
    if not CLIENT_WORD.search(command):
        return []
    return _line(command, judge, sw, 0)
