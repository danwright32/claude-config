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

   The dry run comes first, then the Apply picker in section 3, then the push. The picker carries the migration's metadata and the dry run's list of the migrations it would apply, so his one answer covers the push and nothing asks him again (claude-config#2763). A push applies every migration the database has not had, so when the dry run lists more than the one you wrote, the picker names them all, and the push is asked about again unless that list is exactly the one migration. Run each of these as a command of its own, with nothing in the same Bash call but a `cd` to the project directory written out in full: no pipe, no redirection, no second command. The hooks read only a command like that, and the dry run and a read back from a file are then approved without a question. A dry run listing any other migration, a migration written after the Apply, an edit to the file, a push to another project, or a new session means the push is asked about again.

2. **Ad hoc SQL (backfills, one off fixes, reads):** the Supabase MCP `execute_sql` tool, with the project id. It needs no local tools. When it refuses a write because the connection is read only (an error saying the statement cannot run in a read only transaction), go to the next path. For a schema change in a project with no `supabase/migrations` folder, `apply_migration` is the same tool for DDL and records the change in the database's migration history; in a project that has the folder, use path 1 instead, so the history and the repository agree.

3. **Ad hoc writes in a linked project: `supabase db query --linked`.** When the project directory has been linked with `supabase link`, this sends the SQL through the cached link and the Supabase Management API. No password or connection string is in the command and no env file is read, which is why it runs on the work MacBook, where a hook refuses any command that reads `.env.local`. That hook is right: never read, print or source an env file to get past it, and never route around it. Write the SQL to a file, then from the project directory check the CLI can take the command, in one Bash call:

   ```bash
   if ! command -v supabase >/dev/null; then echo "the supabase CLI is not installed, so nothing ran"; false; elif ! supabase db query --linked --file /dev/null --help >/dev/null 2>&1; then v="$(supabase --version 2>/dev/null | head -n 1)"; echo "this supabase CLI is version ${v:-unknown}, which does not accept db query --linked: that needs 2.79.0 or later, before 4.0. Nothing ran"; false; else echo "this supabase CLI takes db query --linked"; fi
   ```

   and only when that exits 0, after Dan's Apply in section 3, run the change in a Bash call of its own, with nothing else in it but a `cd` to the project directory (the hooks let it through on his Apply only when it stands alone, claude-config#2763):

   ```bash
   supabase db query --linked --yes -f change.sql
   ```

   `--yes` answers the confirmation a hosted database asks for, so nothing waits on a prompt. The check's middle test asks the CLI for the exact command and flags the change uses, and asks only for their help: a CLI that has them prints it and exits 0, and one that lacks any of them exits non zero. It never carries `--yes` or the change file, so even a CLI that ignored `--help` would be sent an empty file and refuse it at the hosted confirmation. A bare `supabase db query --help` cannot be the test, because a CLI without the command prints the parent `db` help and exits 0 (measured on 2.75.0).

   Versions, from Supabase's own records: `db query` arrived in 2.79.0 (release notes, 2026-03-16: "add `supabase db query` command for executing SQL"), with `--linked` and `-f`/`--file` from the start and `--yes` a global flag. In 3.0.0 (2026-11-02) `--linked` still works but is deprecated: it prints a warning naming `--remote`, and the CLI docs say it is "removed in v4". The two commands keep `--linked` because it is the only form that runs on both 2.79.0 and later 2.x and on 3.x, while `--remote` exists only from 3.0.0. When either Mac reaches 4.0 the middle test refuses, naming the version; then change `--linked` to `--remote` in the check and in the change command, and put `--remote` last if the command ever gains an argument. The check, the same test as the one line it was split from, was checked against 2.75.0 on the personal MacBook on 2026-11-04, which refuses, and against the 3.0.0 source and docs.

   - **The CLI is older than 2.79.0, is 4.0 or later, or is not installed:** the check refuses, naming the version it found, and the change is not run. Go to path 4 where it can run, otherwise path 5, and tell Dan in one line that `brew upgrade supabase` would open this path. Never upgrade it yourself.
   - **The project is not linked:** the CLI exits non zero asking for a project ref or saying no project is linked, and nothing is sent. Stop and hand Dan `supabase link` to run in his own terminal, as in path 1. Never pass `--password` or `--db-url`.

   **This command reports no row count for a write**, so section 4 is kept by the SQL itself. Wrap every data modifying statement in one `do` block that reads the count and raises when it is not exactly what was expected. A `do` block is one statement, so the raise rolls back everything inside it; put every write of one change in the same block, each with its own check, so a wrong count on any of them undoes all of them:

   ```sql
   do $$
   declare n bigint;
   begin
     delete from public.example_table where id = any (array[101, 102, 103]);
     get diagnostics n = row_count;
     if n <> 3 then
       raise exception 'expected 3 rows deleted from example_table, got %; nothing was changed', n;
     end if;
   end $$;
   ```

   The expected count comes from a select of the same `where` clause, run first and shown at the confirmation gate in section 3. A run that exits 0 proves the count matched; an exit with the raised message proves nothing changed. Then read it back: run a select that proves the data landed (the rows are gone, the new values are there), through the Supabase MCP `execute_sql` tool, or through this same path with `--read-only` added where the CLI has it, and report the count it shows. Schema changes do not take this path: they go through path 1 or `apply_migration`.

4. **psql, only where it is installed** (it was not on Daniels-MacBook-Pro-2 on 2026-10-08). Write the SQL to a file, then run it with the connection string read from the project's env file inside the command, so the command text never holds it. Use the variable name and env file the project actually uses (`DATABASE_URL` in `.env.local` here; `.dev.vars` and other names exist):

   ```bash
   if ! command -v psql >/dev/null; then echo "psql is not installed, so nothing ran"; false; elif [ ! -f .env.local ]; then echo "there is no .env.local here, so nothing ran"; false; elif url="$(sed -n -E 's/^[[:space:]]*(export[[:space:]]+)?DATABASE_URL=//p' .env.local | head -n 1 | tr -d "\"'")"; [ -z "$url" ]; then echo "DATABASE_URL is not set in .env.local, so nothing ran"; false; else psql "$url" -X -1 -v ON_ERROR_STOP=1 -f change.sql; fi
   ```

   `-1` runs the file as one transaction and `ON_ERROR_STOP=1` stops at the first error, so a failure leaves nothing half applied. An empty connection string is refused before psql starts, because psql given an empty one connects to its default local database instead. The connection string is still visible to other processes on this Mac while psql runs; it never reaches the transcript.

5. **No write path exists:** hand Dan exactly one copy-paste block per statement, following the hand-off rules in the global CLAUDE.md, and the SQL must print its own result (counts, RETURNING) so he has something concrete to paste back.

## 3. Confirmation gate for live data

Before any data-modifying statement (INSERT, UPDATE, DELETE, ALTER, migration) against a real database, show the exact SQL, the target project and tables, and the expected effect, then confirm via AskUserQuestion (Apply / Cancel). Exception: a step Dan already approved in a plan this session does not need a second confirmation.

For a migration on path 1, or a change file on path 3, the picker is one question whose options are labelled exactly `Apply` and `Cancel`, and it carries this metadata, filled in from the files themselves just before asking (never typed from memory):

```json
{"source": "db-apply", "migration": "<absolute path of the migration or change file>", "sha256": "<its sha256>", "project_ref": "<the linked project ref>", "pending": ["<each migration file name the dry run listed>"]}
```

`pending` is for a migration on path 1 only: copy the file names the `supabase db push --dry-run` output lists as the migrations it would push, in its order, from that output itself, never from the folder or from memory, and write the same list into the question (for example "Apply 002_note.sql to project abc? The dry run would push: 002_note.sql"). Leave it out for a change file on path 3.

The sha256 is the first word `shasum -a 256 <file>` prints, and the project ref is the text of `supabase/.temp/project-ref` in the project directory. Never fill in `answers` yourself. `hooks/db-write-ask.sh` lets the push (path 1) or the `supabase db query --linked --yes -f <file>` run (path 3) through on that answer, in this session, while the file is unchanged and the run goes to that project; a push also needs `pending` to be exactly that one migration and the migration to be the newest file in `supabase/migrations` (`hooks/lib/db-apply-approval.py`). A missing, empty or longer list, or one naming another file, is asked about, and the question names the other migrations. Run it as a command of its own, with only a `cd` to the project directory before it. Anything else is asked about, saying why.

## 4. Row counts, always

Every data-modifying statement reports how many rows it affected (RETURNING, `GET DIAGNOSTICS`, or the client's row count). On path 3, which prints no count for a write, that is the `do` block's checked count plus the read-back. "Done" without a count is not done. Read-only verification queries after a change are encouraged and need no confirmation.

## 5. Verify

After a migration: confirm it shows as applied (`supabase migration list`, or the Supabase MCP `list_migrations` tool) before declaring success. After a backfill: run a read-back query proving the data landed as intended.
