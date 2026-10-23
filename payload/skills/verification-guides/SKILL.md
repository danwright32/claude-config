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
| `url` | Where serve listens. Only `http://127.0.0.1`, `http://localhost` or `http://[::1]`, any port: a run never drives a deployment. |
| `commands.serve` | Builds and serves the app in the foreground, from the checkout root. A production build, never a dev server, with no URL or key pointing at production (L719). |
| `commands.ready` | Exits 0 once serve answers. Retried every `ready_interval_s` until `ready_s`. |
| `commands.stop` | The project's own cleanup (containers, a seeded database). Run before serve's process group is stopped. |
| `commands.drive` | The project's drive helper. Called with the arguments the runner passes, and with `VERIFICATION_URL`, `VERIFICATION_AREA`, `VERIFICATION_WORKTREE` and `VERIFICATION_RECEIPT_DIR` set; it saves screenshots into `VERIFICATION_RECEIPT_DIR`. |
| `commands.stamp` | Optional. Prints the commit the SERVED build reports (a `/__build` route, a footer). Recorded as the receipt's `build_stamp`; the merge check wants it to equal the head SHA. |
| `timeouts` | Optional seconds: `ready_s` 300, `ready_interval_s` 2, `max_run_s` 3600 (the run's deadline, longer than `ready_s`), `stop_s` 60. |
| `areas` | A list of `{"name", "guide", "owns"}`: a lower case hyphenated name, the guide's repository path, and the glob patterns of the files the area owns. |
| `exempt` | A list of `{"glob", "why"}`: files no area verifies, each with its reason. |

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
It is rendered by `verification.py record render`, never typed:

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
`drives.jsonl` (every drive call, its area, arguments and exit), and the copies of areas.json and
the guides the run used. It records the machine, the head and the commit checked out, when serve
started, became ready and stopped and why (`stop`, `ready_failed`, `serve_exited`, `deadline`,
`recovered`, `start_failed`, `start_error`, `start_interrupted`, `supervisor_error`), the build
stamp, and `egress`. The three `start_` reasons mean setup failed before serve started, and
`worktree_removed` says whether the worktree went: `start_failed` a named refusal, `start_error` any other error (a full disk, a
failed copy), `start_interrupted` an interrupt. `stop_detail` carries the error itself and any
cleanup step that also failed, which `start` reports too, as `start-cleanup-failed`.

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
   read its env before writing it down. If the project has no drive helper, building one (a
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
build stamp equal to the record's commit, and a successful drive call for the area. The merge must
pin that head with `--match-head-commit`.

In `mode: warn` every merge is allowed, the full verdict reaches the session, and it is added to a
tally per pull request under `~/.claude-verification/merge-tally/`. Each time the tally has grown by
`TALLY_ASK_EVERY` pull requests (set in `verification.py`), `hooks/verification-tally-notice.sh` asks Dan in the main session whether to switch
the repository to `block`. The override is `ALLOW_UNVERIFIED_MERGE=1 <the same command>`.

## Not built yet

These are what the merge check expects that nothing here can supply yet, said rather than faked:

- **Egress.** Every receipt says `"egress": {"verdict": "unmeasured"}`: no monitor shows that a
  served app reached nothing outside this machine during a run. The bug-bash skill's egress rule
  blocks one named host for a read only run against a deployment; it is not a verdict on a local
  run. A merge check that requires a clean egress verdict refuses every record until one exists.
- **Build stamp.** Recorded only when the project's `stamp` command prints one; otherwise
  `build_stamp_source` is `none`.
- **Drive helpers.** Each project supplies its own; none ships here.
