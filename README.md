# claude-config-sync

Two-way sync of selected `~/.claude` config between my Macs.

This file says what the tool does. [DESIGN.md](DESIGN.md) says what was tried and rejected, where
every threshold's number came from, and how much each guard is actually proven. Read it before
changing a design decision, so an approach that was already measured and discarded does not come
back.

## What syncs

- `payload/hooks/` — automation scripts
- `payload/skills/` — custom + installed skills (plugin-managed skills excluded, see below)
- `payload/agents/` — the `plan-*` agents
- `payload/commands/` — slash commands
- `payload/settings.hooks.json`: **only** the `hooks` block of `settings.json`
- `payload/CLAUDE.md` and `payload/RTK.md` — your global rules files, synced verbatim (standing cross-project instructions travel here)

Every mirrored file (hooks, skills, agents, commands) and the hooks fragment are stored with this
Mac's config directory written as `__CLAUDE_HOME__`, and expanded to each Mac's own on the way in,
so an absolute path inside one is correct on both machines. The top-level rules files are the
exception: they are merged entry by entry, so their bytes are left exactly as written, and a path
in one of them should be a `~` path. `hooks/check-home-paths.sh` enforces that split.

One consequence, worth knowing before writing a synced file that talks about the sync: the
placeholder is expanded wherever it appears, and nothing can tell a line that MEANS the
placeholder from a line that means a path. A file naming it in prose, or running a shell
substitution over it, has its own text rewritten into one machine's home directory, which is
how a healthcheck came to report a path made of two homes glued together. Assemble it from
pieces in those files. The same guard refuses it anywhere it is not standing in front of a path.
(This README is not synced, so it can spell it out.)

## What NEVER syncs (stays private to each Mac)

Memory store, session history, caches, the rest of `settings.json` (model / effort / plugins),
and the local permission list (`settings.local.json`). A `pull` cannot overwrite any of these.

Plugin-managed skills are excluded so plugin updates don't cause churn:
`agents-sdk, cloudflare, cloudflare-email-service, durable-objects, sandbox-sdk,
turnstile-spin, web-perf, workers-best-practices, wrangler, plannotator-compound`
(edit `PLUGIN_SKILLS` in `claude-sync` to change this).

## Use

```bash
./claude-sync push              # send this Mac's config up
./claude-sync pull              # bring shared config down
./claude-sync sync              # two-way: send local, then receive remote
./claude-sync status            # show differences, no changes
./claude-sync cite-scan L2      # which synced files cite that lesson number
./claude-sync reap-scratch      # reclaim scratch a killed run left behind
./claude-sync install-autosync  # background auto-sync (see below)
```

## Automatic sync

`install-autosync` sets up two launchd agents (and retires older ones), and installs
the `claudesync` shell alias:

- **`com.claudesync.watch`** — an fswatch process that runs a two-way `sync` on
  every change to a synced folder, however deep, so edits push within seconds.
  Requires fswatch: `brew install fswatch` (then re-run `install-autosync`).
- **`com.claudesync.timer`** — a periodic two-way `sync` (default weekly,
  `SYNC_INTERVAL=<seconds>`) so the other Mac's changes arrive even when this Mac
  makes no local edits.

It also adds this to `~/.zshrc`, so the shortcut arrives with the rest of the setup
instead of being added by hand on each Mac (`~/.zshrc` is deliberately not synced):

    alias claudesync='<repo>/claude-sync pull'

That step is idempotent: it never appends a second copy, it treats a `~` and the
expanded home directory as the same path, and if a `claudesync` alias already exists
pointing somewhere else it leaves your line alone and tells you rather than rewriting
your shell config. Override the target file with `SYNC_ZSHRC=<path>`.

Sending is automatic on change; receiving is automatic on the timer. A no-op sync
writes nothing (idempotent), so the watcher never re-triggers itself. On a merge
conflict the background job stops and fires a desktop notification.

## Lessons: an index in context, the full text on demand

`CLAUDE.md` imports `LESSONS-INDEX.md`, one line per lesson (the rule, without its body or
provenance). `LESSONS.md` still syncs and still holds everything; it is simply not loaded into every
session. Measured on the real file: 117,050 bytes down to 33,549, with all 180 lessons present.

Read one in full with `./claude-sync lesson L174`, or open the entry in `~/.claude/LESSONS.md`. The
body is where the failure behind the rule is described, so read it whenever a rule is about to
decide something.

The index is generated from `LESSONS.md` on every send and every apply, never maintained beside it.
A hand edit to it is overwritten on the next run, which is the point: a list kept by hand next to
the thing it mirrors drifts, and the drift is silent.

## When a merge cannot be done

The other Mac's version is applied and yours is kept beside it as `<file>.conflict-<host>`, with one
line naming what was only in yours. That copy is then the ONLY place that content exists, so every
later apply keeps reporting it, and `claude-sync status` lists it too, naming what it still holds
that the live file does not.

Both reports go quiet on their own: as soon as the content is back in the live file, or the copy is
deleted, there is nothing outstanding to report. A copy whose content is already in the live file is
still listed by `status`, named as safe to delete, because only you can decide to remove it.
## Lesson numbers

Each Mac mints lesson numbers from a band it owns, so two lessons written between syncs can never
claim the same number. `claude-sync next-lesson` prints the next free number in this Mac's band, and
`check-lessons` fails on a duplicate anywhere in the file.

A Mac claims its band the first time it asks for a number: the first Mac gets 1 to 500, the next 501
to 1000, and so on. The claim is one file per Mac under `lesson-bands/` in the repo, committed so the
other Mac can see it, and one file per writer means a claim can never produce a merge conflict. Two
Macs that claim while unable to see each other are settled by name order, the same way on either
Mac, and the one that moves says so. A band that fills up refuses rather than spilling into the next
Mac's numbers (`SYNC_LESSON_BAND_SIZE` widens it).

## Skills that cannot load

A skill is a directory holding a `SKILL.md` whose frontmatter carries a name and a description.
Anything else under `skills/` is inert, so it is not carried in either direction: a push does not
send it and a pull does not write it onto this Mac. The run names each one and says why, rather than
skipping it quietly, because an entry that cannot load is indistinguishable from one that works
until somebody tries to invoke it.

Measured against the real config on 2026-08-17, this refuses exactly four entries (two directories
holding no `SKILL.md` and two loose markdown files) and every one of the 43 real skills passes.

## Which plugins load (per Mac, and it does not sync)

Plugins are enabled per project rather than everywhere. A plugin that is off at user scope is turned
back on by `enabledPlugins` in that project's own `.claude/settings.json`, which travels with the
project's repo. Proven in a real session on 2026-08-17, with a control: a directory whose project
settings enable a user-scope-disabled plugin sees its skills, and a directory without those settings
does not.

`enabledPlugins` in `~/.claude/settings.json` is deliberately NOT carried between Macs, along with
the rest of that file. Each Mac has different projects checked out, so exporting one Mac's survey
would turn a fix here into a regression there. Set it on each Mac by hand, and read
`claude-sync status`, which prints what this Mac has on and off so the two can be compared.

## A skill provided twice

`claude-sync check-skills` fails when a skill name is provided by an installed plugin AND by
`~/.claude/skills/` or the synced payload, because both copies are then listed in every session and
both are paid for. `status` reports the same thing without being asked, so a duplicate that arrives
with a plugin install surfaces on its own.

The plugin side is read from the install record (`~/.claude/plugins/installed_plugins.json`), so a
plugin installed later is covered without anybody adding it to a list. A Mac where no plugin skills
can be found is told exactly that, rather than passing: nothing to compare against is not the same
answer as nothing wrong.

## Secret scan

Every push/sync scans the payload and aborts if it finds a credential shape.
Accept a known string by adding the sha256 of the matched text to
`.secret-allowlist`, or bypass once with `SYNC_SKIP_SECRET_SCAN=1`.

## Tests

```bash
bash tests/test-claude-sync.sh
```

Every push and pull request also runs the suite on a Linux runner
(`.github/workflows/tests.yml`). No path filter: the suite reads `README.md` and `DESIGN.md` as
well as the code, and checks every tracked file for Python bytecode, so filtering by where the code
lives would skip precisely the change that breaks it.

Run ONE section while iterating, which is the fast path:

```bash
SECTION_ONLY="lessons index is derived" bash tests/test-claude-sync.sh
```

That runs the preamble, the first four sections, and the one you named: under four seconds against
roughly six minutes for the whole suite. The first four sections are the only place in the file
that changes shared state, so everything after them runs in one fixed setting and can be run on its
own. All 73 of them can, measured by running each in isolation.

Where one section genuinely does continue another, it says so in a comment directly under its
heading, and that prerequisite is pulled in too:

```
section "== #17: a collision the merge creates is settled by renumbering the unsent entry =="
# needs: #15: duplicate lesson numbers must not be published or go unnoticed
```

There is exactly one of those in the file. It is a comment rather than an argument to `section`
because three separate checks in the suite read the heading line by stripping one trailing quote,
and one of them would have gone on passing silently while checking nothing.

A pattern matching nothing is an error, and so is one matching SEVERAL sections: it lists the
candidates rather than running the first and reporting success under the text you typed. Asking for
`SECTION_ONLY` and `SECTION_UNTIL` together is refused rather than one quietly winning.

If a section turns out to depend on something an earlier one set, the run is refused outright
rather than reported. That matters more than it sounds: an unbound variable inside a command
substitution kills only that subshell, so a section missing a fixture can lose several tool
invocations, print nothing but `ok` lines, and exit 0.

Every push also runs each section the push CHANGED on its own
(`tests/audit-changed-sections.sh`), which is the only run in which a missing prerequisite shows up.
A push that does not touch the suite costs nothing there.

The older knob still exists for when you want everything up to a point rather than one section:

```bash
SECTION_UNTIL="conflict copies" bash tests/test-claude-sync.sh
```

Every section closes with how many checks it ran and how long it took, and a run ends naming the
five slowest, so "the suite is slow" names a section somebody can act on. The counts are derived by
subtraction and the suite asserts they add up to its own total.

The suite also scans itself for assertions that could pass on output the command prints anyway: two
greps over one captured blob, or a match on nothing but a path, in output that lists paths already.
It prints what it found with a count and holds the numbers to a ceiling, so nothing new is added
while the existing ones are worked through.

It looks for three shapes, and all three are now at ZERO, so any of them fails the suite. The six
double greps were rewritten to require one line carrying both facts. The twenty-one bare path
assertions now name the file next to the fact about it: not `added.sh` but `added.sh reported as a
new file`, not `GONE.md` but `GONE.md is referenced and not on this Mac`. The forty that matched one
bare word now name what the word was about: not `kept` but `kept local edits ... skills/reel/push.py`,
not `retired` but `RETIRED, no sign of it since`. In none of the three families did the legitimate
case the ratchet was left open for actually exist.

Because a zero is read as proof rather than as a measurement, the scan counts every form this suite
has for feeding a captured output to a matcher (a pipe, a herestring, a `case`, a `[[ ]]`), and all
three zeros are backed by a positive control: one instance of each is planted in a copy of the file
being scanned and all three counts have to move to exactly one. Each pass was deliberately broken in
turn and measured passing its ceiling while failing only that control. A negated half never counts,
since an absence cannot be supplied by an unrelated line, and neither does an anchored pattern, a
regex doing real work, or a word grepped from a file the fixture wrote.

`claude-sync status` opens with when config last moved in each direction and when the repo was last
reachable, so a pending list can be read against all three: four files waiting means one thing an
hour after the last send and something very different three weeks after. The first two are the last
time something actually moved, not the last time a sync ran, because a stamp that advanced on every
run would make a Mac with nothing to do look permanently healthy. Reachability is the one that tells
a stuck Mac from an offline one, and it is deliberately labelled as saying nothing about whether
anything crossed.

It also scans itself for check names used more than once. A failure prints the name and the
expression and nothing else, so two checks sharing a name leave you searching the file for which
scenario actually broke.

For writing new checks there is `line_has "$output" 'fact one' 'fact two'`, which passes only when
ONE line carries every fact. That is the form all three bans exist to enforce, so the correct thing
is now the shortest thing to write. It takes two patterns minimum and refuses one, because a single
pattern is the weak form itself and hiding it behind a helper would put it out of the scan's sight.

And it scans itself for settings named in a comment or in this README that the code never
references. One of those had been sitting there describing a way to run a single section that was
never built, under a name that does not exist, and it cost two wasted runs before anyone noticed.

One run at a time, and none of them open ended:

| Setting | Default | What it does |
| --- | --- | --- |
| `SUITE_TIMEOUT` | `900` | Seconds before a stalled run is killed and told which section it died in. Full runs measured 191 to 267 seconds on a Mac and 110 on the Linux runner on 2026-08-21, so this is at least 3x the slowest observed. The suite checks that headroom against its own elapsed time, so the ratio cannot go stale. `0` disables it. |
| `SUITE_LOCK` | `$TMPDIR/claude-sync-suite.lock` | Where the one run at a time lock lives. A second run REFUSES, naming the process that holds it and how long it has been going, rather than queueing. |
| `SUITE_NO_LOCK` | unset | Run without taking the lock. For when you know the run it names has finished. |
| `SUITE_LOCK_MAX_AGE` | `1800` | Seconds after which a lock from ANOTHER machine is broken. A lock from this machine is judged by whether its process is alive, never by the clock, so a clock jump cannot break a live one. |
| `SUITE_MAX_DEPTH` | `1` | How deeply a run may be nested inside another. The suite runs itself as a subprocess in many places, every one of them one level down, and past this it refuses to start rather than multiplying. |
| `SECTION_ONLY` | unset | Run the preamble, the first four sections, and the one named, plus anything it declares it needs. Refuses an ambiguous or unmatched name. |
| `SECTION_UNTIL` | unset | Run from the start up to and including the section named. Refuses to be combined with `SECTION_ONLY`. |
| `SUITE_SLOW_IN` | unset | Pause deliberately in the section named. It exists so the duration column can be watched reporting a known number: most sections legitimately read 0s, and a broken clock would read 0s everywhere too. |

## Scratch left behind by a killed run

The suite and every apply create scratch in `$TMPDIR/claude-sync` and remove it on the way out. A
run that is force-killed never gets there. `claude-sync status` reports what has been abandoned
(how many, and how much space), the suite reclaims it at the start of each run, and
`claude-sync reap-scratch` does it on demand.

Only paths carrying this tool's own names are ever touched, never "old directories in the temp
folder": on the day this was measured that same directory held 542 anonymous ones belonging to
other tools. Nothing younger than `SYNC_SCRATCH_MAX_AGE` is removed either, so scratch a live run
is still using is safe. The directory holding them is not scratch and is never swept.

Scratch used to be created directly in the temp root, and the sweep therefore had to read the
whole of it: 113,912 entries on this Mac, 25 of them ours, which was most of what a
`claude-sync status` call cost. Everything an earlier version left there is still reclaimed, but
that location is now read on an interval rather than on every call, and `claude-sync reap-scratch`
reads it every time whatever the interval says.

| Setting | Default | What it does |
| --- | --- | --- |
| `SYNC_SCRATCH_ROOT` | `$TMPDIR` | The temp root. Scratch is created in the `claude-sync` directory inside it, and the sweep looks there and, on an interval, in the root itself. |
| `SYNC_SCRATCH_DIRNAME` | `claude-sync` | The name of that directory. It is half of the pattern deciding what `reap-scratch` may remove, so anything that is not a single directory name is refused. |
| `SYNC_SCRATCH_MAX_AGE` | `3600` | Seconds before scratch counts as abandoned. A suite run cannot outlive its own 15 minute deadline and a sync takes 6 seconds, so this is 4x the longest run the tool permits. The cost is that a burst of interrupted runs is not reclaimed until an hour after the last of them. `0` turns the sweep off entirely, and a value that is not a whole number is refused rather than guessed at. |
| `SYNC_SCRATCH_LEGACY_EVERY` | `86400` | Seconds between reads of the old flat location in the temp root. Reading it is what costs six figures of directory entries, so it is not done on every call. The cost is stated: something left there can go unreported for up to this long, though `reap-scratch` always reads it. `0` reads it every call, and a value that is not a whole number is refused. |

`claude-sync status` also reports watcher processes and test runs the tool left behind, counting
how many started independently and how deeply they are nested. It stays silent for one watcher
and one run, which is what a healthy machine looks like.

## Local state (per Mac, never synced)

Eight things hold state outside `payload/` and belong to the Mac that wrote them. All are gitignored,
so a fresh clone starts without them. (`lesson-bands/` also sits outside `payload/` and is the one
exception: it is tracked and shared on purpose, because a band nobody else can see cannot stop
anybody else claiming it. See Lesson numbers above.) A folder COPIED or RESTORED from a backup carries stale ones, which is why each has a
defined answer for being absent or untrustworthy.

| File | Written by | Read by | Missing or stale |
| --- | --- | --- | --- |
| `.last-applied` | every apply | the guard that blocks sending while behind | absent means nothing is protected yet, so sending is allowed |
| `.last-success` | a successful pull, fetch or push | the outage clock | absent, unparseable, or dated in the FUTURE all mean "no record", which alerts rather than staying quiet |
| `.last-sent` | a push that went through | `claude-sync status` | absent means nothing has ever gone up from this clone, which is said in those words rather than shown as a date; a value that will not parse is reported as unreadable, never as never |
| `.last-received` | an apply that wrote at least one file | `claude-sync status` | same three answers as `.last-sent`. It does not move for an apply that only rebuilt the hooks block, since that is regenerated from whatever payload is present, including one this Mac just staged itself |
| `.outage-log` | every outage decision | `claude-sync status` | absent means no decisions yet, and a line that will not parse is counted and reported as unreadable rather than skipped |
| `.sync-lock/` | any mutating run | every mutating run | a lock from THIS Mac whose process is alive is respected whatever its age; one from another Mac, or with no Mac recorded, is broken once older than an hour |
| `state/` | every apply | nothing reads the local copy; it exists so a marker is only republished when it changes | absent just means the next apply republishes |
| `refs/claude-sync-state` | every apply, pushed per Mac | `claude-sync verify` | nothing published means "cannot be answered", never agreement; a Mac silent for 60 days is reported as retired |

None of this travels between Macs except the published refs, and those deliberately never
land on the config branch: a marker commit there is a commit the other Mac does not have,
which the send guard correctly reads as being behind, and every send is then skipped.
