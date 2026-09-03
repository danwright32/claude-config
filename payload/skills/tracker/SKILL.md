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
/tracker --headers                        # just print the sheet's column names
```

## First run / setup (`--setup`)

If `config.local.json` is missing, the skill is not configured. Walk the user through this once:

1. Open the sheet → **Extensions → Apps Script**.
2. Delete any boilerplate, paste the entire contents of `apps-script.gs` (in this skill dir).
3. In the pasted code, replace `REPLACE_WITH_A_LONG_RANDOM_STRING` with this token:
   `tjtHU0Mi9PiIFsnduIQzGKa2B2EQAK9WuYgOnkjZ`
   (it must match the `token` in `config.local.json`).
4. Click **Deploy → New deployment → Web app**.
   - *Execute as*: **Me**
   - *Who has access*: **Anyone** (the token guards writes; without it requests are rejected)
5. Authorize when prompted, then copy the **Web app URL** (ends in `/exec`).
6. Create `config.local.json` in this skill dir by copying `config.example.json` and pasting
   the URL. The token is already filled in.

Then verify with `bash tracker.sh headers` — it should print the sheet's column names.

> If the user later changes the script, they must **Deploy → Manage deployments → Edit →
> New version** for changes to take effect. The `/exec` URL stays the same.

## Appending a row (default)

1. **Read config**: confirm `config.local.json` exists. If not, run setup above.
2. **Discover columns**: run `bash tracker.sh headers`. This returns the sheet's actual
   header row — always use these as the source of truth; don't assume column names.
3. **Build the row** from the user's message + the current project context (repo name, what
   was just worked on). Map values onto the real headers.
   - **Date Started — do NOT default to today.** Determine when the project actually began by
     looking back, in this order: (a) the earliest conversation/session about this project,
     (b) the repo's first commit (`git log --reverse --format=%ad --date=short | head -1`),
     (c) ask the user. Only use today if the project genuinely started today.
   - **Date Completed — leave blank (`""`) unless the project is actually finished.** Pass it
     explicitly as an empty string so it isn't auto-dated.
   - ⚠️ The script auto-fills *any* empty `date`/`timestamp`/`added`/`updated`/`created`
     column with today. Because this sheet has both *Date Started* and *Date Completed*,
     always set both explicitly (computed start date; `""` for completed-if-unfinished) so
     neither gets a wrong "today".
   - If a column that clearly needs a value (e.g. Project Name, Problem/Goal) can't be
     inferred, ask the user one short question rather than guessing.
   - **Skills Used — never "Claude Code".** This column is for resume-grade skills: the actual
     technologies, languages, frameworks, and competencies demonstrated (e.g. TypeScript,
     Next.js, Cloudflare Workers, Supabase/Postgres, system architecture, REST API design).
     Claude Code is the tool used to do the work, not a skill to list.
   - **Link — default to the project's repo URL.** Use the current repo's remote
     (`git remote get-url origin`, stripped of a trailing `.git`) as the Link value. Only leave
     it blank or use something else if the project has no git remote or the user specifies a
     different URL (e.g. a deploy/dashboard link).
4. **Show for approval first (required).** Before appending, render the full proposed row to the
   user (a table or key:value list of every column) and ask them to approve or tweak it. Do NOT
   append until they confirm. Apply any edits they give, then re-show if the changes are
   substantial. Only call `append` once they've signed off.
5. **Append**: pass a JSON object keyed by header name (case-insensitive). Current columns are
   *Project Name, Date Started, Date Completed, Problem/Goal, My Actions, Outcome/Results,
   When to Check Results, Skills Used, Link* — but always re-read via `headers` in case they change.
   ```
   bash tracker.sh append '{"Project Name":"Bidspoke","Date Started":"2026-05-20","Date Completed":"","Problem/Goal":"Ship auth flow","My Actions":"Built login + session handling","Outcome/Results":"Flow works, tests pending","Skills Used":"Claude Code"}'
   ```
6. **Confirm**: the script returns `{"ok":true,"rowNumber":N,"row":[...]}`. Tell the user the
   row was added and summarize what went in. If `ok` is false, surface the `error`.

## Notes

- `config.local.json` holds the deployment URL + token and is gitignored — never commit it or
  print the token in chat.
- The column mapping is by header name, so the skill keeps working if the user reorders or
  renames columns — just re-read headers.
