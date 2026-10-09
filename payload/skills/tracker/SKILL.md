---
name: tracker
description: Add a row to my personal Google Sheet project tracker from any project. Use when the user wants to log a project update, record progress, or "add to the tracker".
trigger: /tracker
---

# /tracker

Append a row to the personal project-tracker Google Sheet, **Dan Work Project Tracker**
(https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w/edit,
owned by Dan's personal Google account), without leaving the terminal. Drive also holds
a second sheet named "Dan Work Project Tracker", and it is not the one: always open the sheet
by this link, never by searching Drive for the name (Dan confirmed this one on 2026-10-08).

Writes go through a Google Apps Script web app bound to the sheet (a token-guarded
POST endpoint, the token always in the request body, never the address), so no Google
credentials are stored locally and the skill works from any project on any machine.

## Usage

```
/tracker                                  # gather the update conversationally, then append a row
/tracker finished the auth flow for Bidspoke, still need tests
/tracker --setup                          # one-time setup (deploy the web app, save config)
/tracker --rotate                         # replace the token (see "Rotating the token")
/tracker --headers                        # just print the sheet's column names
```

Rows can also be changed in place by their Link (`tracker.sh update`, see "Updating a row in
place"), once the deployed script has update ("Turning on update").

## First run / setup (`--setup`)

If `config.local.json` is missing, the skill is not configured. The token that guards writes
lives ONLY in `config.local.json`: never write it into this file, a commit, a command, or the
chat. Walk the user through this once:

1. Run `bash tracker.sh new-token`. It creates `config.local.json` from `config.example.json`
   and writes a fresh random token into it, printing only the file's path, never the token.
2. Tell the user BBEdit is about to come forward, then open the file for them:
   `/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window ~/.claude/skills/tracker/config.local.json`
3. Open the sheet, **Dan Work Project Tracker**, by its link (not the other sheet of the same
   name): https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w/edit
   Then **Extensions, Apps Script**.
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

## Turning on update (one time, after claude-config#1031)

`tracker.sh update` needs the deployed script to be the current `apps-script.gs`, which has the
`update` action. A deployment made before #1031 does not, and refuses every update with
`nothing to append` (it changes nothing; `tracker.sh` then says the script predates update).
Do this once, on one Mac; the `/exec` URL and the token stay the same:

1. Open the sheet, **Dan Work Project Tracker**, by its link (not the other sheet of the same
   name): https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w/edit
   Then **Extensions, Apps Script**.
2. Select all the code there and paste the entire contents of the current `apps-script.gs`
   over it.
3. Tell the user BBEdit is about to come forward, then open `config.local.json` with the
   command in setup step 2. In the pasted code, replace `REPLACE_WITH_A_LONG_RANDOM_STRING`
   with the `token` value from that file, keeping the single quotes around it, and save.
4. **Deploy, Manage deployments**, the pencil (Edit), **Version: New version**, **Deploy**.
5. Check it, without changing anything, by asking to update a Link no row has:
   `bash tracker.sh update 'https://example.invalid/check-update' 'Check' '{"My Actions":"x"}'`
   The answer `no row has the Link https://example.invalid/check-update; nothing was changed`
   means update is live. `the deployed web app predates update` means step 4 did not deploy a
   new version. `bad token` or `token not set` means the TOKEN line does not hold the token from
   `config.local.json`: set it as in step 3 and deploy a new version again.

## Rotating the token

When the token may have been seen (it was once committed to this public repository,
claude-config#675), replace it in both places:

1. Run `bash tracker.sh new-token`. It keeps the `url` already in `config.local.json` (or
   creates the file from the example) and replaces only the token.
2. Tell the user BBEdit is about to come forward, then open `config.local.json` with the
   command in setup step 2.
3. Open the sheet, **Dan Work Project Tracker**, by its link (not the other sheet of the same
   name): https://docs.google.com/spreadsheets/d/1aFt8ks89lkzLVUF0pf4Aj8Pi9B5TOcqCj-8WkUQsN3w/edit
   In its **Extensions, Apps Script**, replace the value inside the quotes on the
   `const TOKEN = '...';` line with the new `token` from `config.local.json`, and save. If the
   deployed script predates claude-config#675 (it reads the key from the address, and its body
   field is `token`), paste the whole current `apps-script.gs` first, then set the line: this
   skill speaks only to the current script, and the two refuse each other with `bad token`.
4. **Deploy, Manage deployments**, the pencil (Edit), **Version: New version**, **Deploy**.
   The `/exec` URL stays the same; if `config.local.json` has no `url` yet, copy it from this
   dialog into the file and save.
5. Verify with `bash tracker.sh headers`. A `bad token` answer means the script and the file
   still disagree, or the new version was not deployed. A `token not set` answer means the
   deployed script still holds the placeholder: it refuses everything until the TOKEN line is
   changed.

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
   - Every text value is stored as literal text, exactly as sent: a value starting `=`, `+`,
     `-` or `@` never becomes a formula, and a date sent as `"2026-05-20"` stays that text
     (written `yyyy-mm-dd`, it still sorts by date).
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
   bash tracker.sh append '{"Project Name":"Bidspoke","Date Started":"2026-05-20","Date Completed":"","Problem/Goal":"Ship auth flow","My Actions":"Built login + session handling","Outcome/Results":"Flow works, tests pending","Skills Used":"TypeScript, Next.js, Supabase/Postgres, session auth"}'
   ```
6. **Confirm**: the script returns `{"ok":true,"rowNumber":N,"row":[...]}`. Tell the user the
   row was added and summarize what went in. If `ok` is false, surface the `error`.

## Updating a row in place

`tracker.sh update '<link>' '<project name>' '<json of header:value>'` changes only the named
cells of the one row whose Link is `<link>`. Every other cell in that row (When to Check
Results, any column added later) is never written. Pass the Link and Project Name exactly as
the sheet shows them; the web app refuses, changing nothing, when:

- no row, or more than one row, has that Link;
- the row with that Link has a different Project Name;
- the sheet changed between finding the row and writing it (a sort, an inserted row or column,
  an edit to that row's Link or Project Name): read the sheet again and retry;
- a header in the JSON is not a column of the sheet, or is named twice;
- another request is writing the sheet at that moment (`busy`): try again.

Always get approval first, as for an append:

1. Run the same command with `--preview` (shown below). It finds and checks the row exactly as
   the update will, writes nothing, and answers
   `{"ok":true,"action":"update","preview":true,"rowNumber":N,"before":{...},"row":[...]}`,
   where `before` holds what each named cell holds now.
2. Show the user the old value (from `before`) and the new value of every cell, and get
   approval or edits.
3. Run it without `--preview`, adding the preview's `before` as a fourth argument. The update
   then writes only while every one of those cells still holds what the user approved over; if
   someone edited one since, it refuses (`now holds ...`) and nothing changes: preview again.
   The answer, `{"ok":true,"action":"update","rowNumber":N,"before":{...},"restore":{...},
   "row":[...]}`, carries in `before` what each changed cell held just before the write, and in
   `restore` the exact values that put each one back.

Every text value is written as literal text: a value starting `=`, `+`, `-` or `@` stays that
text and never becomes a formula, and date or number shaped text stays as typed. A JSON number
or true or false is written as itself. (Append does the same.)

To undo, run `update --restore` with the answer's `restore` as the cells and, as the fourth
argument, the values the update wrote (what the cells hold now). In `restore` a formula comes as
`{"formula":"=..."}` and a date as `{"date":"2026-11-01"}`; restore is the only write that
accepts those, and puts them back as a live formula and a real date. Text stays literal even
then. It refuses unless every cell still holds what the fourth argument says.

```
bash tracker.sh update --preview 'https://github.com/example-owner/bidspoke' 'Bidspoke' '{"Outcome/Results":"Auth flow shipped, tests passing","My Actions":"Built login, session handling and its tests"}'
bash tracker.sh update 'https://github.com/example-owner/bidspoke' 'Bidspoke' '{"Outcome/Results":"Auth flow shipped, tests passing","My Actions":"Built login, session handling and its tests"}' '{"Outcome/Results":"Flow works, tests pending","My Actions":"Built login and session handling"}'
bash tracker.sh update --restore 'https://github.com/example-owner/bidspoke' 'Bidspoke' '{"Outcome/Results":"Flow works, tests pending","My Actions":"Built login and session handling"}' '{"Outcome/Results":"Auth flow shipped, tests passing","My Actions":"Built login, session handling and its tests"}'
```

Needs the one time redeploy in "Turning on update" above.

## Notes

- `config.local.json` holds the deployment URL and the token. It is gitignored and left out of
  claude-sync's mirror (every `*.local.json` is), so it stays on the Mac that wrote it. Never
  commit it, never print the token in chat, and never put the token in a command: `tracker.sh`
  reads it from the file itself.
- The column mapping is by header name, so the skill keeps working if the user reorders or
  renames columns, just re-read headers.
