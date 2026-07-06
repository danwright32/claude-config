---
name: db-apply
description: Apply database changes (migrations, backfills, ad-hoc SQL) directly instead of relaying SQL through the user. Use whenever SQL needs to run against a project's database, including when the Supabase MCP connection is read-only. Ends the copy-paste round trip where the user runs SQL and pastes back the result.
---

# db-apply

Dan is not a human clipboard. When SQL needs to run, find a way to run it yourself with a confirmation gate, and only fall back to handing it over when no write path exists.

## 1. Schema first, always

Before writing any SQL, read the real schema of every table involved: `mcp__supabase__list_tables`, or the project's cached schema reference if one exists in project memory. Never guess a column name. If this project has no cached schema reference yet, save one to project memory after reading it.

## 2. Find the write path (first run per project: discover, then cache)

Try in order, and record which one works in the project's memory so future sessions skip the discovery:

1. **Migrations:** from the project directory, `supabase db push` (requires the project to be linked; check `supabase/config.toml` or `supabase projects list`). Non-interactive flags only; never leave a y/n prompt hanging.
2. **Ad-hoc SQL:** `psql "$DATABASE_URL"` (or the connection string found in `.env.local` / `.dev.vars` / project docs). Run with `-c` or a temp file, never interactively.
3. **No write path exists:** hand Dan exactly one copy-paste block per statement, following the hand-off rules in the global CLAUDE.md, and the SQL must print its own result (counts, RETURNING) so he has something concrete to paste back.

## 3. Confirmation gate for live data

Before any data-modifying statement (INSERT, UPDATE, DELETE, ALTER, migration) against a real database, show the exact SQL, the target project and tables, and the expected effect, then confirm via AskUserQuestion (Apply / Cancel). Exception: a step Dan already approved in a plan this session does not need a second confirmation.

## 4. Row counts, always

Every data-modifying statement reports how many rows it affected (RETURNING, `GET DIAGNOSTICS`, or the client's row count). "Done" without a count is not done. Read-only verification queries after a change are encouraged and need no confirmation.

## 5. Verify

After a migration: confirm it shows as applied (`supabase migration list`) before declaring success. After a backfill: run a read-back query proving the data landed as intended.
