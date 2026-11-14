---
name: verification-guides
description: Use in a project that has, or should have, a `.claude/verification/areas.json`. CREATE writes the project's areas, ownership rules and one verification guide per area; MAINTAIN settles a failing check as a guide fault or a code fault; RUN, before a pull request merges, has one fresh agent serve the PR head locally, drive the touched areas through the project's drive helper, stop serve and post a machine readable run record on the PR.
---

# verification-guides

A verification guide says how a person would check one area of a product by hand: who to be, how
to get there, what state to set up, three to six judgment checks, and what has fooled a checker
before. A run executes the guides an area's changes touch, against the pull request's own head,
and leaves a record on the PR that the merge check (claude-config#1529) reads.

A project opts in only through its own `.claude/verification/areas.json`. This repository keeps no
list of projects, and a project without that file is never touched.

Everything that reads these files goes through one module, [scripts/verification.py](scripts/verification.py):
the skill and the merge check share it, so neither parses a format by hand. The harness that
starts and stops serve is [scripts/run_session.py](scripts/run_session.py). Both print
`verification: <kind>: <message>` for every refusal, and each cause has its own kind.

## The files

`.claude/verification/areas.json` (schema `verification-areas/1`):

| Key | What it holds |
|---|---|
| `schema` | `"verification-areas/1"` |
| `mode` | `"warn"` or `"block"`: how the merge check treats a missing or failing record. Start at `warn`. |
| `url` | Where serve listens. Only `http://127.0.0.1`, `http://localhost` or `http://[::1]`, any port: a run never drives a deployment. Optional with serve and ready when every area is native (below). |
| `commands.serve` | Builds and serves the app in the foreground, from the checkout root. A production build, never a dev server, with no URL or key pointing at production (L719). |
| `commands.ready` | Exits 0 once serve answers. Retried every `ready_interval_s` until `ready_s`. |
| `commands.stop` | The project's own cleanup (containers, a seeded database). Run before serve's process group is stopped. |
| `commands.drive` | The project's drive helper. Called with the arguments the runner passes, and with `VERIFICATION_URL` (when the run serves), `VERIFICATION_AREA`, `VERIFICATION_WORKTREE` and `VERIFICATION_RECEIPT_DIR` set; it saves screenshots into `VERIFICATION_RECEIPT_DIR`. |
| `commands.stamp` | Optional. Prints the commit the SERVED build reports (a `/__build` route, a footer). Recorded as the receipt's `build_stamp`; the merge check wants it to equal the head SHA. |
| `commands.native_shot` | Required when any screen is native, else absent. Runs the offscreen test that photographs one native screen, from the checkout root, with the shot named in `VERIFICATION_SHOT_*` (below). |
| `timeouts` | Optional seconds: `ready_s` 300, `ready_interval_s` 2, `max_run_s` 3600 (the run's deadline, longer than `ready_s`), `stop_s` 60, `egress_s` 30 (how long the egress monitor's canary may take to show up, at the start and at the end). |
| `egress` | Optional `{"allow": [<host>, ...]}`: the hosts serve and the drive helper may reach during a run, as bare host names or IP addresses (no scheme, port, path or wildcard). `127.0.0.1`, `localhost` and `::1` are always allowed, and by default nothing else is. A run's egress verdict is `clean` only when nothing outside this list was reached. |
| `areas` | A list of `{"name", "guide", "owns", "screens"}`: a lower case hyphenated name, the guide's repository path, the glob patterns of the files the area owns, and optionally the screens its pull requests are pictured at (below). |
| `exempt` | A list of `{"glob", "why"}`: files no area verifies, each with its reason. |
| `seeds` | Optional `{<name>: {"synthetic": true or false, "why": <one line>}}`: the data each screen is shot with. `synthetic` true declares it made up, the only data a PUBLIC repository may show pictures of. |
| `screenshots` | Optional `{"mode": "warn" or "block"}`, default `warn`: how the merge check treats a UI pull request whose body lacks its pictures, apart from `mode` above. |

A screen is `{"name", "path", "seed", "rows", "min_rows"}`: a name, the route on the served app
(starting with `/`), a seed from `seeds`, and optionally a CSS selector and the count of matches the
screen must show before it is shot, so it is pictured at the production count (L606). A pull request
is UI when it touches an area with screens; each such screen is shot on the base build and the head
build, at 1440 and 1280 wide, in light and dark: eight pictures (claude-config#2516). No area
declaring screens is reported as unmeasured, never as passed.

A native screen (claude-config#2696) is `{"name", "test", "frame", "seed", "min_rows"}`: in place of
a route, the offscreen test that photographs it (`Target`, `Target/Suite` or
`Target/Suite/function()`) and the name of the frame that test draws, with optionally the count of
rows the frame must report drawing. A screen gives a `path` or a `test`, never both, and a native
one has no CSS selector. Its pictures are the same eight under the same names, so publish, render
and the merge check treat the two alike. What the native app's test must do is under Screenshots.

`url`, `commands.serve` and `commands.ready` are what a run needs to serve the app
(claude-config#2951). A project whose areas are all native (at least one native screen and no web
screen; an area with no screens is neither) has nothing to serve, so it may leave all three out, or
give all three when it does serve something; a partial set is refused as `areas-serve-incomplete`,
naming what is missing. Any other project needs all three: one with a native screen and a web one
is refused as `areas-web-needs-serve`, naming the web area and each missing setting, and one with no
native screen (web screens only, or none) as `areas-missing-key`, as before. A run with nothing to serve starts no serve and
waits for no ready command; its supervisor still runs the egress monitor around every drive call
and ends the run on `stop` or the deadline, its receipt records `url`, `serve_pid` and `serve_pgid`
as null, and the drive helper gets no `VERIFICATION_URL`.

Ownership: every file in the repository lands in EXACTLY one bucket, an area or `exempt`. A file
in none is unowned and a file in two is ambiguous, and both are refusals, never guesses. Patterns
are repository relative: `*` and `?` stay inside one path segment, `**` as a whole segment spans
any number of them, and brackets and braces are refused (list each pattern instead).
`verification.py bucket <areas.json>` is the areas command: changed paths on stdin, the bucket of
each and the touched areas out, exit 7 on any unowned or ambiguous file.

A guide, `.claude/verification/guides/<area>.md`, follows [guide-template.md](guide-template.md):
the sections Roles, Reach, State setup, Checks and Known traps, with three to six checks written
`- [C1] <one sentence>`. `verification.py guide check <guide>` refuses any other shape.

The run record is one fenced block per area in the run's PR comment, under a table a person reads.
It is rendered by `verification.py record render`, never typed. Render also keeps a fingerprint of
each record it wrote in `rendered.jsonl` beside the receipt, and the merge check refuses a posted
record that matches none of them, so post the rendered comment unchanged: an edit after render, to a
result, a note or a check's text, is refused as `record-edited` (claude-config#1572).

````
```verification-run
{
  "schema": "verification-run/1",
  "area": "invoices",
  "head_sha": "<the PR head, 40 hex>",
  "receipt_id": "20261022T230000Z-0123456-a1b2c3",
  "machine": "<short host name>",
  "runner_agent_id": "<the runner's agent id>",
  "checks": [{"id": "C1", "text": "<from the guide>", "result": "pass", "note": "<one line>"},
             {"id": "C2", "text": "...", "result": "fail", "note": "...", "blame": "code"}],
  "done_when": [{"id": "D1", "text": "<from the PR body>", "result": "pass", "note": "..."}],
  "screenshots": ["invoices-C1-list.png"],
  "guide_edits": [{"check_id": "C3", "old": "<from the guide>", "new": "...", "why": "..."}]
}
```
````

`verification.py record parse [--sha <head>]` reads a comment body on stdin and returns every
valid record, with `passed` derived (every check and every done when item passed), each malformed
block with its problems, and with `--sha` the records made at that head. Exit 3 means no record,
4 a malformed one, 6 none at that SHA. Keys it does not know are ignored, so a later additive
field never breaks it; a different major schema is refused by name.

The receipt is written only by `run_session.py`, at
`~/.claude-verification/receipts/<receipt id>/receipt.json` (`VERIFICATION_HOME` moves it). It is
outside `~/.claude` on purpose: the sync mirrors `~/.claude` into a public repository, and a
receipt folder holds screenshots of private apps. Beside it are the screenshots, `serve.log`,
`drives.jsonl` (every drive call, its area, arguments and exit), `rendered.jsonl` (the fingerprint
of every record `record render` wrote from this run, which the merge check matches the posted
record against), and the copies of areas.json and the guides the run used. It records the machine, the head and the commit checked out, when serve
started, became ready and stopped and why (`stop`, `ready_failed`, `serve_exited`, `deadline`,
`recovered`, `start_failed`, `start_error`, `start_interrupted`, `supervisor_error`), the build
stamp, and `egress` (below). The three `start_` reasons mean setup failed before serve started, and
`worktree_removed` says whether the worktree went: `start_failed` a named refusal, `start_error` any other error (a full disk, a
failed copy), `start_interrupted` an interrupt. `stop_detail` carries the error itself and any
cleanup step that also failed, which `start` reports too, as `start-cleanup-failed`.

The receipt's `egress` is the verdict of the egress monitor, [scripts/egress.py](scripts/egress.py),
which the run's supervisor starts before serve and settles after serve's whole process group is
gone. Serve and every drive call run under macOS's `sandbox-exec` with a profile that blocks
nothing but reports each connection to an address other than loopback; `log stream` reads the
reports (no password), and `lsof` names each one's remote address the moment it arrives. A
canary connection, a UDP connect to the reserved address 198.51.100.1 that sends no packet,
proves the stream live at the start and again at the end. The field holds `verdict`, `why`,
`allowed_hosts`, `destinations` (each `{address, port, reports, processes, allowed}`) and
`unnamed` (connections whose address was never read, each with `name_error`: null when the
connection closed before lsof could read it, else why lsof could not). `clean` means the monitor
was proved live for the whole run and every destination was allowed; `not-clean` names what was
reached, and an unnamed connection is never clean; `unmeasured` gives the reason the monitor could
not see (not a Mac, `sandbox-exec` missing or refused, the canary never reported, the supervisor
killed). A request body or header is never recorded: the monitor never sees one. Two limits,
stated: a serve or drive helper that applies its own macOS sandbox fails under this one, which
shows as serve stopping, and the kernel collapses repeated reports, so `reports` is a lower bound.
`egress.jsonl` beside the receipt is the monitor's own log of every report as it arrived.

## CREATE

For a project that has no `.claude/verification/areas.json` yet.

1. Derive the areas from the code, not from memory. List every route the app serves (the router's
   own files: `app/` or `pages/` in Next.js, `src/routes` in SvelteKit, the router config in a
   React app, the screens of a native app) and every backend entry point (API handlers, workers,
   scheduled jobs, webhook receivers, queue consumers), each with its files. Group them into areas
   by what a person would check together; an area is one guide.
2. Propose ownership rules for each area and the exemptions with their reasons, then prove them
   against every tracked file: `git ls-files | python3 ~/.claude/skills/verification-guides/scripts/verification.py bucket .claude/verification/areas.json`
   must exit 0. Fix the rules until it does.
3. Settle the commands. Serve must be a local production build reading no production credential;
   read its env before writing it down. A project whose areas are all native leaves out serve,
   ready and url unless it has something to serve. If the project has no drive helper, building one (a
   headless browser script or request sender the project owns) is its own issue in that project:
   the runner may never drive through the Playwright tools. Add `stamp` if the build can report
   its commit, and say so if it cannot.
4. Show Dan the areas, their ownership rules and the exemptions as a picker before writing
   anything: these rules decide which runs his merges need.
5. Write each guide from [guide-template.md](guide-template.md). Checks are judgments a person
   makes from what is on screen or in a response, three to six of them, never a restatement of a
   unit test. Run `verification.py guide check` on each.
6. Write areas.json with `"mode": "warn"`, run `verification.py areas validate .claude/verification/areas.json`,
   and land it all in one pull request in that project.

## MAINTAIN

A failing check is settled by the runner, not the builder. The runner saw the screen, so it
decides whether the code is wrong or the guide is, and records that as the check's `blame`:

- `blame: code`: the guide stands. The builder fixes the code and runs again. The guide is not
  touched to make the check pass.
- `blame: guide`: the check itself is wrong (a cache it did not allow for, a renamed control, a
  route that moved). The runner writes the replacement check and why in the record's
  `guide_edits`; the rendered comment shows the old check, the new check and why, side by side.
  The builder applies exactly that text to the guide in the same pull request, puts the same old
  check, new check and why in the PR body, and runs again at the new head. The failing record stays
  failing; only a new run at the new head can pass.

A check keeps its number when it is edited, a new check takes the next free number, and retiring a
check is a pull request of its own saying why. When code moves, its area's `owns` patterns move
with it in the same pull request, proved again with `bucket`. When a runner is fooled, the trap
goes under Known traps.

## RUN

Before a pull request in an opted in project merges. One run covers every area the PR touches and
dispatches ONE agent, which is paid: say so when proposing it.

The main session:

1. Read the BASE copy of areas.json, so the PR cannot change what judges it:
   `git -C <checkout> show origin/<base>:.claude/verification/areas.json > <scratch>/areas.json`.
2. Find the touched areas: `gh pr diff <n> --name-only | python3 ~/.claude/skills/verification-guides/scripts/verification.py bucket <scratch>/areas.json`.
   An unowned or ambiguous file stops the run: fix the ownership rules first (MAINTAIN).
3. Read the head SHA (`gh pr view <n> --json headRefOid --jq .headRefOid`) and make a nonce
   (`verification.py nonce`). Dispatch the runner from the MAIN session, never from a subagent: the
   runner proves its agent id from its own transcript, by the nonce in its brief.
4. Brief it with the text below, filled in. Read its hand back; for each failing check, act on its
   blame as MAINTAIN says.

The runner's brief:

> You are the verification runner for PR #<n> in <owner/repo>, checkout <path>, head <sha>,
> areas <a,b>. Nonce <nonce>. Follow the subagent rules in payload/CLAUDE.md (installed as
> ~/.claude/CLAUDE.md): never call a Playwright tool (the Playwright gate refuses a subagent's
> call, and the browser belongs to the main session), keep your files in
> `<scratchpad>/verify-<n>/`, run plain commands with literal paths, and hand back a report rather
> than ending your turn to wait on anything. Do not edit, commit or push anything in the checkout.
>
> 1. Start: `python3 ~/.claude/skills/verification-guides/scripts/run_session.py start --repo <path> --sha <sha> --areas <a,b>`.
>    It serves the head in a detached worktree and prints the receipt id and receipt folder. If it
>    refuses, report its line word for word and stop: nothing is running.
> 2. Read each area's guide from `<receipt folder>/guides/<area>.md`, and the PR's `## Done when`
>    (`gh pr view <n> --json body --jq .body > <scratchpad>/verify-<n>/body.md`).
> 3. Drive only through `python3 ~/.claude/skills/verification-guides/scripts/run_session.py drive <receipt id> --area <area> -- <helper arguments>`.
>    Set up the guide's state, reach the area, and judge each check yourself from what you see.
>    Name screenshots `<area>-C<n>-<word>.png`.
> 4. A failing check gets a blame: `code` when the product is wrong, `guide` when the check is.
>    For `guide`, write the new check and why. Judge every done when item too.
> 5. Stop, always, also when something above failed:
>    `python3 ~/.claude/skills/verification-guides/scripts/run_session.py stop <receipt id>`.
> 6. Write the draft `{"receipt_id", "nonce", "areas": [{"area", "checks": [{"id", "result", "note", "blame"}], "done_when": [{"id", "result", "note"}], "screenshots", "guide_edits": [{"check_id", "new", "why"}]}]}`
>    to `<scratchpad>/verify-<n>/draft.json`, render it with
>    `python3 ~/.claude/skills/verification-guides/scripts/verification.py record render --pr-body <scratchpad>/verify-<n>/body.md < <scratchpad>/verify-<n>/draft.json > <scratchpad>/verify-<n>/comment.md`,
>    and post it: `gh pr comment <n> --repo <owner/repo> --body-file <scratchpad>/verify-<n>/comment.md`.
>    Render refuses a running receipt, a check list that is not the guide's, done when items that
>    are not the PR's, a missing screenshot and a guide blame with no edit; fix the draft, never
>    the guide.
> 7. Hand back: the receipt id, the comment's URL, and each failing check with its blame and note.

### Screenshots, when a touched area declares screens

[scripts/screenshots.py](scripts/screenshots.py) takes, publishes and renders them; the runner does
this in the same run, before step 5 stops the head run:

1. Shoot the head: `python3 ~/.claude/skills/verification-guides/scripts/screenshots.py shoot <receipt id> --side head --areas-file <scratch>/areas.json`,
   with the BASE areas.json the main session read. It calls the drive helper once a picture as
   `screenshot <path> <width> <light|dark> <file.png> <rows selector or -> <min rows>`, through
   `run_session.py drive`, and the helper saves the file into `VERIFICATION_RECEIPT_DIR`.
   [scripts/shoot_web.mjs](scripts/shoot_web.mjs) is a helper that does exactly that with the
   Playwright library, so a web project's helper can hand `screenshot` to it. A native screen is
   called as `screenshot-native <test> <frame> <width> <light|dark> <file.png> <min rows>`, and
   [scripts/shoot_native.py](scripts/shoot_native.py) does exactly that: it runs
   `commands.native_shot` in the worktree with `VERIFICATION_SHOT_TEST`, `_FRAME`, `_WIDTH`,
   `_HEIGHT` (900), `_THEME`, `_FILE`, `_ROWS_FILE` and `_MIN_ROWS` set, each also with the
   `TEST_RUNNER_` prefix xcodebuild passes into a test. The app's test draws that frame offscreen
   (a window ordered back outside every display, never front, as Ovation's `OffscreenShot.swift`
   does), writes the PNG to `_FILE` and the rows it drew to `_ROWS_FILE`, and FAILS on a frame it
   does not know. The picture is kept only when the test exited 0, wrote a PNG the asked width at a
   scale of 1, 2 or 3, and reported at least the minimum rows; a run of zero tests passes, so the
   picture is the proof. A SwiftPM command needs `--disable-sandbox`, since the run's own sandbox
   already wraps it.
2. Shoot the base: `run_session.py start` at the PR's `baseRefOid` (fetch it first), `shoot ... --side base`,
   then `run_session.py stop`. One run at a time per project, so the base run follows the head run's stop.
3. Publish: `screenshots.py publish --areas-file <scratch>/areas.json --repo <owner/repo> --pr <n> --base-receipt <id> --head-receipt <id> > <scratchpad>/verify-<n>/shots.json`.
   It refuses a missing picture by area, screen, side, width and theme before uploading anything.
   In a public repository whose screens all use a seed declared synthetic, it adds the pictures to
   the orphan `pr-screenshots` branch through GitHub's git data API (no push), under
   `pr-<n>/<head sha>/`, linked by the commit that added them, keeping everything already there:
   nothing is ever pruned (Dan, 2026-11-10). Anywhere else it refuses
   `screenshots-need-private-link`: publish the pictures to a private Artifact page and run it again
   with `--link <that page>`, which uploads nothing. A private repository takes the link too until
   inline images there are measured to render (`PRIVATE_REPO_IMAGES`, claude-config#2699).
4. Render: `screenshots.py render --manifest <scratchpad>/verify-<n>/shots.json --body <scratchpad>/verify-<n>/body.md > <scratchpad>/verify-<n>/new-body.md`,
   then `gh pr edit <n> --body-file <scratchpad>/verify-<n>/new-body.md`. The `## Screenshots`
   block is replaced in place, so rendering again leaves one block, and its fingerprint is kept in
   `rendered-screenshots.jsonl` beside the head receipt: a block edited by hand is refused.

If the runner ends without stopping, `run_session.py stop <receipt id>` from the main session
stops serve, runs the project's stop command and removes the worktree; the run's deadline does the
same unattended.

## The merge check

`hooks/require-verification-run.sh` (claude-config#1529) judges every merge in a repository whose
pull request's BASE commit holds `.claude/verification/areas.json`, through
[scripts/merge_check.py](scripts/merge_check.py), which reads everything through
`verification.py`. It reads areas.json and the guides from the base commit, so a pull request
cannot change what judges it: a new file needs an owner merged first, and a guide the pull request
edits counts only once it has merged. A merge passes when every changed file lands in exactly one
bucket and each touched area's newest record at the head (or at an earlier commit whose later
changes, in the pull request's own files, leave the area alone) passes every check and done when
item, with its receipt on the merging machine showing serve stopped, a clean egress verdict, a
build stamp equal to the record's commit, and a successful drive call for the area, and the record
exactly as `record render` wrote it from that receipt (its fingerprint in `rendered.jsonl`). The
merge must pin that head with `--match-head-commit`.

In `mode: warn` every merge is allowed, the full verdict reaches the session, and it is added to a
tally per pull request under `~/.claude-verification/merge-tally/`. Each time the tally has grown by
`TALLY_ASK_EVERY` pull requests (set in `verification.py`), `hooks/verification-tally-notice.sh` asks Dan in the main session whether to switch
the repository to `block`. The override is `ALLOW_UNVERIFIED_MERGE=1 <the same command>`.

The same check judges the pictures (claude-config#2516), under `screenshots.mode` rather than
`mode`. For a UI pull request it names, by area, screen, side, width and theme, every picture the
body's `## Screenshots` block lacks, and refuses a block that is missing, malformed, edited after
render, stale (taken before a later change to a pictured area), linking a file the branch does not
hold, or showing pictures of a seed not declared synthetic in a public repository. In `warn` the
merge is allowed and the verdict reaches the session even when the run records pass in `block`;
the screenshot kinds are added to the warn tally. The block switch is present and off: a project
moves to `"screenshots": {"mode": "block"}` once warn has been seen working for a week
(claude-config#2697; the first project is claude-config#2698). Its own
override is `ALLOW_NO_SCREENSHOTS=1 <the same command>`, which lifts the pictures check alone.

## Not built yet

These are what the merge check expects that nothing here can supply yet, said rather than faked:

- **Build stamp.** Recorded only when the project's `stamp` command prints one; otherwise
  `build_stamp_source` is `none`.
- **Drive helpers.** Each project supplies its own; only the screenshot verbs ship here
  (shoot_web.mjs for a route, shoot_native.py for a native screen).
- **Inline pictures in a private repository.** Unmeasured, so private repositories get the private
  link until it is measured (claude-config#2699).
- **The native app's camera.** Each native app's test supplies its own offscreen camera and frame
  list; none ships here.
