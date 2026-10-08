---
name: tracker
description: Add a row to my personal Google Sheet project tracker from any project. Use when the user wants to log a project update, record progress, or "add to the tracker".
trigger: /tracker
---

# /tracker

Append a row to the personal project-tracker Google Sheet
(`1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w`) without leaving the terminal.

Writes go through a Google Apps Script web app bound to the sheet (a token-guarded
POST endpoint), so no Google credentials are stored locally and the skill works from
any project on any machine.

## Usage

```
/tracker                                  # gather the update conversationally, then append a row
/tracker finished the auth flow for Bidspoke, still need tests
/tracker --setup                          # one-time setup (deploy the web app, save config)
/tracker --rotate                         # replace the token (see "Rotating the token")
/tracker --headers                        # just print the sheet's column names
```

## First run / setup (`--setup`)

If `config.local.json` is missing, the skill is not configured. The token that guards writes
lives ONLY in `config.local.json`: never write it into this file, a commit, a command, or the
chat. Walk the user through this once:

1. Run `bash tracker.sh new-token`. It creates `config.local.json` from `config.example.json`
   and writes a fresh random token into it, printing only the file's path, never the token.
2. Tell the user BBEdit is about to come forward, then open the file for them:
   `/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window ~/.claude/skills/tracker/config.local.json`
3. Open the sheet, then **Extensions, Apps Script**.
4. Delete any boilerplate and paste the entire contents of `apps-script.gs` (in this skill dir).
5. In the pasted code, replace `REPLACE_WITH_A_LONG_RANDOM_STRING` with the `token` value from
   `config.local.json` in BBEdit, keeping the single quotes around it.
6. Click **Deploy, New deployment, Web app**.
   - *Execute as*: **Me**
   - *Who has access*: **Anyone** (the token guards writes; without it requests are rejected)
7. Authorize when prompted, then copy the **Web app URL** (ends in `/exec`) and paste it over
   the `url` placeholder in `config.local.json`, then save.

Then verify with `bash tracker.sh headers`: it should print the sheet's column names. Until
both values are filled in, `tracker.sh` refuses and names the one still missing or still a
placeholder.

> If the user later changes the script, they must **Deploy, Manage deployments, Edit,
> New version** for changes to take effect. The `/exec` URL stays the same.

## Rotating the token

When the token may have been seen (it was once committed to this public repository,
claude-config#675), replace it in both places:

1. Run `bash tracker.sh new-token`. It keeps the `url` already in `config.local.json` and
   replaces only the token.
2. Tell the user BBEdit is about to come forward, then open `config.local.json` with the
   command in setup step 2.
3. In the sheet's **Extensions, Apps Script**, replace the value inside the quotes on the
   `const TOKEN = '...';` line with the new `token` from `config.local.json`, and save.
4. **Deploy, Manage deployments**, the pencil (Edit), **Version: New version**, **Deploy**.
   The `/exec` URL stays the same.
5. Verify with `bash tracker.sh headers`. A `bad token` answer means the script and the file
   still disagree, or the new version was not deployed.

`config.local.json` is per Mac and never synced, so a second Mac needs the same file: copy it
across by hand (AirDrop), never through the repository.

## Appending a row (default)

1. **Read config**: confirm `config.local.json` exists. If not, run setup above. If
   `tracker.sh` refuses because a value is missing or still a placeholder, finish setup rather
   than working around it.
2. **Discover columns**: run `bash tracker.sh headers`. This returns the sheet's actual
   header row, always use these as the source of truth; don't assume column names.
3. **Build the row** from the user's message + the current project context (repo name, what
   was just worked on). Map values onto the real headers.
   - **Date Started: do NOT default to today.** Determine when the project actually began by
     looking back, in this order: (a) the earliest conversation/session about this project,
     (b) the repo's first commit (`git log --reverse --format=%ad --date=short | head -1`),
     (c) ask the user. Only use today if the project genuinely started today.
   - **Date Completed: leave blank (`""`) unless the project is actually finished.** Pass it
     explicitly as an empty string so it isn't auto-dated.
   - Warning: the script auto-fills *any* empty `date`/`timestamp`/`added`/`updated`/`created`
     column with today. Because this sheet has both *Date Started* and *Date Completed*,
     always set both explicitly (computed start date; `""` for completed-if-unfinished) so
     neither gets a wrong "today".
   - If a column that clearly needs a value (e.g. Project Name, Problem/Goal) can't be
     inferred, ask the user one short question rather than guessing.
   - **Skills Used, never "Claude Code".** This column is for resume-grade skills: the actual
     technologies, languages, frameworks, and competencies demonstrated (e.g. TypeScript,
     Next.js, Cloudflare Workers, Supabase/Postgres, system architecture, REST API design).
     Claude Code is the tool used to do the work, not a skill to list.
   - **Link: default to the project's repo URL.** Use the current repo's remote
     (`git remote get-url origin`, stripped of a trailing `.git`) as the Link value. Only leave
     it blank or use something else if the project has no git remote or the user specifies a
     different URL (e.g. a deploy/dashboard link).
4. **Show for approval first (required).** Before appending, render the full proposed row to the
   user (a table or key:value list of every column) and ask them to approve or tweak it. Do NOT
   append until they confirm. Apply any edits they give, then re-show if the changes are
   substantial. Only call `append` once they've signed off.
5. **Append**: pass a JSON object keyed by header name (case-insensitive). Current columns are
   *Project Name, Date Started, Date Completed, Problem/Goal, My Actions, Outcome/Results,
   When to Check Results, Skills Used, Link*, but always re-read via `headers` in case they change.
   ```
   bash tracker.sh append '{"Project Name":"Bidspoke","Date Started":"2026-05-20","Date Completed":"","Problem/Goal":"Ship auth flow","My Actions":"Built login + session handling","Outcome/Results":"Flow works, tests pending","Skills Used":"Claude Code"}'
   ```
6. **Confirm**: the script returns `{"ok":true,"rowNumber":N,"row":[...]}`. Tell the user the
   row was added and summarize what went in. If `ok` is false, surface the `error`.

## Notes

- `config.local.json` holds the deployment URL and the token. It is gitignored and left out of
  claude-sync's mirror (every `*.local.json` is), so it stays on the Mac that wrote it. Never
  commit it, never print the token in chat, and never put the token in a command: `tracker.sh`
  reads it from the file itself.
- The column mapping is by header name, so the skill keeps working if the user reorders or
  renames columns, just re-read headers.
