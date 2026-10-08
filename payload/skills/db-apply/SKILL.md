---
name: db-apply
description: Apply database changes (migrations, backfills, ad-hoc SQL) directly instead of relaying SQL through the user. Use whenever SQL needs to run against a project's database, including when the Supabase MCP connection is read-only. Ends the copy-paste round trip where the user runs SQL and pastes back the result.
---

# db-apply

Dan is not a human clipboard. When SQL needs to run, find a way to run it yourself with a confirmation gate, and only fall back to handing it over when no write path exists.

The Supabase tools below are named by their bare tool name. The full name carries a server prefix that depends on how Supabase is connected in that session (`mcp__claude_ai_Supabase__` for the claude.ai connector on 2026-10-08, something else for a locally configured server), so look for the tool whose name ENDS in the bare name.

## 1. Schema first, always

Before writing any SQL, read the real schema of every table involved: the Supabase MCP `list_tables` tool with `verbose: true` (it takes the project id, which `list_projects` gives; match it to the project ref in the project's Supabase URL), or the project's cached schema reference if one exists in project memory. Never guess a column name. If this project has no cached schema reference yet, save one to project memory after reading it.

## 2. Find the write path (first run per project: discover, then cache)

Try in order, and record which one works in the project's memory so future sessions skip the discovery.

**Never put a database password or connection string in a command, and never print one.** No `--db-url`, no `--password`, no pasted `postgresql://` string, no `cat` or `echo` of an env file. Every command lands in the transcript.

1. **Migrations, in a project with a `supabase/migrations` folder:** write the migration as a file there, then from the project directory preview what would apply, and apply it with the prompt answered up front so nothing waits on a y/n:

   ```bash
   supabase db push --dry-run
   ```

   ```bash
   supabase db push --yes
   ```

   Both push to the linked project. If either asks for a database password, the project is not linked with a saved one: stop, and hand Dan `supabase link` to run in his own terminal, where he types the password himself. Never pass it with `--password`.

2. **Ad hoc SQL (backfills, one off fixes, reads):** the Supabase MCP `execute_sql` tool, with the project id. It needs no local tools. When it refuses a write because the connection is read only (an error saying the statement cannot run in a read only transaction), go to the next path. For a schema change in a project with no `supabase/migrations` folder, `apply_migration` is the same tool for DDL and records the change in the database's migration history; in a project that has the folder, use path 1 instead, so the history and the repository agree.

3. **psql, only where it is installed** (it was not on Daniels-MacBook-Pro-2 on 2026-10-08). Write the SQL to a file, then run it with the connection string read from the project's env file inside the command, so the command text never holds it. Use the variable name and env file the project actually uses (`DATABASE_URL` in `.env.local` here; `.dev.vars` and other names exist):

   ```bash
   if ! command -v psql >/dev/null; then echo "psql is not installed, so nothing ran"; false; elif url="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?DATABASE_URL=//p' .env.local | head -n 1 | tr -d "\"'")"; [ -z "$url" ]; then echo "DATABASE_URL is not set in .env.local, so nothing ran"; false; else psql "$url" -X -1 -v ON_ERROR_STOP=1 -f change.sql; fi
   ```

   `-1` runs the file as one transaction and `ON_ERROR_STOP=1` stops at the first error, so a failure leaves nothing half applied. An empty connection string is refused before psql starts, because psql given an empty one connects to its default local database instead. The connection string is still visible to other processes on this Mac while psql runs; it never reaches the transcript.

4. **No write path exists:** hand Dan exactly one copy-paste block per statement, following the hand-off rules in the global CLAUDE.md, and the SQL must print its own result (counts, RETURNING) so he has something concrete to paste back.

## 3. Confirmation gate for live data

Before any data-modifying statement (INSERT, UPDATE, DELETE, ALTER, migration) against a real database, show the exact SQL, the target project and tables, and the expected effect, then confirm via AskUserQuestion (Apply / Cancel). Exception: a step Dan already approved in a plan this session does not need a second confirmation.

## 4. Row counts, always

Every data-modifying statement reports how many rows it affected (RETURNING, `GET DIAGNOSTICS`, or the client's row count). "Done" without a count is not done. Read-only verification queries after a change are encouraged and need no confirmation.

## 5. Verify

After a migration: confirm it shows as applied (`supabase migration list`, or the Supabase MCP `list_migrations` tool) before declaring success. After a backfill: run a read-back query proving the data landed as intended.
