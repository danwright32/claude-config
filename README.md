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

A file whose version here holds no line the arriving one lacks is not kept beside it at all. The
arriving version already contains everything this Mac had, so it is taken, no copy is written, and
the pull names the files it settled that way rather than passing over them in silence. A local
DELETION is not treated as contained even though its lines are all present in the arriving version:
the deleted line is work too, and the version this Mac last applied is what tells the two apart.

Both reports go quiet on their own: as soon as the content is back in the live file, or the copy is
deleted, there is nothing outstanding to report. A copy whose content is already in the live file is
still listed by `status`, named as safe to delete, because only you can decide to remove it.
## A pull checks what it just installed

A pull that lands anything under `hooks/` runs `~/.claude/hooks/run-all-tests.sh` before it reports,
and folds the verdict into its closing line. A pull is the moment config arrives that has never
executed on this Mac, and success reported without running any of it says exactly what a verified
success says.

The verdict is also recorded in `.hook-tests`, with the runner's own words beside it, so a pull from
the background daemon (which has no terminal, and whose notification is gone once dismissed) can
still be asked about afterwards. `claude-sync status` reports it while it is outstanding and goes
quiet once a later run passes.

The verdict comes from the runner's exit code, never from a line of its output, and there are three
outcomes rather than two: the suite passed, the suite FAILED (the config is on disk and a check on it
does not pass), or the suite could NOT be run or completed at all (nothing checked it). The last one
is deliberately not folded into the second, since they send a reader to different places.

It runs with the sync lock RELEASED, after the config is already applied and on disk, so a pull
starting while it works is not refused. Holding the lock for it would starve the watch daemon,
whose only purpose is keeping this Mac current, with the very step that checks this Mac is current.

It runs only when a hook actually arrived, because the suite is minutes of work and the watch daemon
pulls constantly: a pull carrying a rule file has installed nothing this runner checks. Set
`SYNC_NO_HOOK_TESTS=1` to skip it outright, and `SYNC_HOOK_TESTS_TIMEOUT` (default `1800` seconds)
bounds how long the pull will wait before stopping it and saying nothing was verified. The runner is
told `SYNC_NO_HOOK_TESTS=1` in its own environment, because the test suite runs pulls of its own and
a pull that runs the suite would otherwise recurse without end.

## Lesson numbers

Each Mac mints lesson numbers from a band it owns, so two lessons written between syncs can never
claim the same number. `claude-sync next-lesson` prints the next free number in this Mac's band, and
`check-lessons` fails on a duplicate anywhere in the file.

An entry has to be written as `- **Lnnn. ...` to be a lesson at all. Everything here reads only that
form, so one written any other way (a heading, a list item with the bold left off) is invisible to
all of it at once: absent from the generated index that loads into every session, unretrievable by
`claude-sync lesson`, uncounted by the duplicate check, and holding a number `next-lesson` goes on
offering as free. `check-lessons` now refuses one, naming the file and the line, and a file holding
one is held back from the send the same way a collided number is. The number it claims is counted
whatever shape it is in, so even with the refusal overridden it cannot be handed out twice. The
generated index is exempt, since its own form is `- Lnnn.` and it is a rendering rather than a place
lessons live.

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
bash payload/hooks/run-all-tests.sh
```

That is everything: it asks git which directories in the repo hold a `test-*.sh` and reads all of
them, so a suite added anywhere is picked up on the day it lands. Naming directories runs only
those (`bash payload/hooks/run-all-tests.sh tests tools`). A directory it was told to read that
holds no suite is a failure, not a quiet pass, because reading nothing and reading everything green
look identical otherwise.

The suites run several at a time, since they are independent. Measured on this Mac on 2026-08-21 over the hook
suites: 128 seconds one at a time, 29 seconds in parallel, with byte identical reports. The whole
repo, 38 suites, ran in 84 seconds on an idle Mac and 115 on a busy one, both measured on
2026-08-21, the spread being whatever else the Mac is doing. That floor is `test-claude-sync.sh`, which takes most of it
on its own: the wall clock cannot go below the single longest suite, so making that one faster is
the only thing left that would move this number.

How much of the machine a run may take is ONE number (#136). The runner starts several suites at
once and one of those suites splits ITSELF into shards, so what is actually in flight used to be
the product of two numbers set independently and compared nowhere: a four core runner could carry a
dozen heavy processes, each spawning git and python of its own. That never went red. It makes
timing sensitive checks intermittently wrong instead, which is the hardest kind of failure to
attribute, and the sync suite's own deadline guard was measured firing at 1192s against a normal
200 on a loaded Mac, written down 2026-08-21. So the budget below is divided between the suites running at once, each suite
is told its share, and the product is printed at the top of every run.

| Setting | Default | What it does |
| --- | --- | --- |
| `HOOK_TESTS_BUDGET` | CPUs, capped at 8 | How many processes the whole run may have in flight. Everything else is derived from it. A value that is not a positive whole number is refused rather than guessed at. |
| `HOOK_TESTS_JOBS` | half the budget, but never fewer than 2 and never more than the budget | How many suites run at once. The floor of 2 is for the small machine: the CI runner has two cores, half of two is one, and every suite would have run strictly one after another while a second slot sat reserved. `1` runs them one at a time, which is what to reach for when a suite only fails alongside others. A value that is not a positive whole number is refused rather than guessed at, because it decides how many processes start. |
| `HOOK_TESTS_TIMINGS` | `~/.cache/claude-config/suite-timings` | Where each suite's measured wall clock is kept between runs, one small file per suite, keyed on the suite's path inside the repo. It is what the launch order is built from. Set it to empty to turn the record off, so a run reads nothing and writes nothing. Deliberately outside the config directory: a duration measured on this machine is not configuration, and mirroring it would make the other Mac order its runs by numbers from hardware it does not have. |
| `HOOK_TESTS_SLOTS` | set BY the runner | Each suite's share of the budget, which is the budget divided by how many suites are running at once. A suite that splits itself, which today is `test-claude-sync.sh`, reads it as how many of its own processes it may start. Point the runner at one directory holding one suite and that suite is handed the whole budget, so running the long suite on its own is as fast as it ever was. |

What the budget costs, measured on this Mac on 2026-08-21 as one pair of runs back to back: 124 seconds against
88 seconds for the same 38 suites run the old way (8 suites at once, each splitting itself four ways). The machine was 183% busy
under the budget and 319% busy without it, which is the oversubscription this removes. 36 seconds
is the price of every timing sensitive check in the repo being measured on a machine that is not
fighting itself.

Results are collected and printed in the order the suites were FOUND, never the order they
finished, so two runs of the same tree produce the same page and a difference between them is a
difference in the suites rather than in the machine's mood. Suites are launched longest first,
judged by what each one was last MEASURED to cost: every run records each suite's wall clock and
the next run orders by it. Lane 1 carries the largest share of the budget and lane 1 is whatever
launches first, so this is what decides which suite the machine is spent on.

A suite nobody has measured yet, which means a first run or a newly added suite, falls back to
file size and follows the measured ones. Size is a heuristic and bytes are not seconds, so the
run prints which of the two it used and for how many suites. Being wrong about the order costs
some wall clock and nothing else, because every result is collected and reported the same way
regardless.

Every suite ends with one machine readable line, and that is what the runner reads:

```
SUITE-RESULT passed=29 failed=0
```

The human readable summary stays exactly as it was; this is the line for code. Suites used to write
their totals five different ways and the runner had to work out which line was the score, which it
got wrong twice: it printed a per-check line where a verdict belongs, and it read `PASS=805 FAIL=0`
as 805 failures. A suite that prints no result line is still run and still judged, its score
guessed from its prose, and the runner NAMES it at the end rather than falling back quietly.

The main suite on its own:

```bash
bash tests/test-claude-sync.sh
```

It fans its sections out across four processes. Measured on 2026-08-21, 87 sections taking 82
seconds that way and 243 in a single process, with no single section dominating (the slowest five
were 22s, 13s, 11s, 11s and 9s), so there was nothing to speed up, only work to spread. The parent holds the one run at a time lock and the
shards run under it, so this is still one logical run.

| Setting | Default | What it does |
| --- | --- | --- |
| `SUITE_JOBS` | the runner's grant, or `4` | How many shards a full run splits into. Under `run-all-tests.sh` it defaults to `HOOK_TESTS_SLOTS`, this suite's share of that run's budget; started by hand it is 4. Setting it wins over the grant, because that is somebody asking rather than a share being allocated. `1` runs the whole thing in one process, which is what to reach for when a section only fails alongside others. A value that is not a whole number is refused, and so is a grant that cannot be read. |
| `SUITE_PLAN_ONLY` | unset | Prints `SUITE-PLAN jobs=<n> source=<where it came from>` and runs nothing. The number decides what a run costs, and the only other way to see which one was chosen is to pay that cost. |
| `SUITE_SHARD_COVERAGE_ONLY` | unset | Prints the shard's `SUITE-SHARD-COVERAGE` line, which names the sections it would run, and runs none of them. |
| `SUITE_SHARD` | unset | `i/n` runs the prelude plus every n-th section from the i-th offset, for running one slice by hand or on another machine. A spec that is not `i/n`, or that names a shard outside the range, or that would hold no sections at all, is refused rather than reporting a pass over a set nobody chose. |

The shards' totals are added up, and separately their COVERAGE is checked: every section after the
prelude has to be the target of exactly one shard (#137). Each shard prints what it selected and
the parent puts them back together, so a gap, a section claimed twice, a shard that said nothing,
and shards disagreeing about which sections exist each fail the run with their own message. The
totals cannot do that job: 817, then 830, then 943, every one of them legitimate, so a shard that
quietly selected fewer sections would just print a smaller number.

Sections are interleaved rather than cut into contiguous blocks, because their durations are
uneven and blocks would put several slow ones together.

The reported total counts every section ONCE, whatever the shard count (#146). It used to be the
sum of the shards' own totals, which moved with how much of the machine the run was granted:
measured on 2026-08-21, 873 checks in a single process, 920 across two shards, 986 across four and
1118 across eight, all of one file. Two things repeat, not one. Every shard runs the prelude, and
a shard also runs any section its own targets declare with a `# needs:` line even when another
shard owns it. So each shard now reports what its checks were worth in three buckets, the prelude,
its own targets, and anything it borrowed, and the headline is the prelude once plus every target.
The repeated runs are counted and reported beside it rather than folded in.

Two readings have to agree: the sum of the shards' result lines must equal that headline plus
everything that ran again. They are arrived at differently, one from each shard's result line and
one from its buckets, so a run where they disagree reports neither number as trustworthy. A shard
that says nothing about its sections, or shards that disagree about the prelude, fail the run with
their own message rather than being folded into a total that would silently be missing them.

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

Every run copies this file into the tool's scratch and runs the copy, then removes it. Bash reads a
script incrementally, so editing the suite while a run is in flight makes the running shell resume
at the wrong place, and what comes out is ordinary looking failures in sections that are perfectly
fine. `SUITE_FROM_COPY=1` skips the copy and puts a run back in that state, which is how the checks
guarding it are watched failing.

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
| `SUITE_TIMEOUT` | `3600` | Seconds of wall clock before a run is killed however well it is going. Since #152 this is only an absolute ceiling for a runaway, not what catches a hang: `SUITE_STALL_TIMEOUT` does that. Generous on purpose, because a full single process run measured 348 seconds idle and 1943 at load 160 to 188 on 2026-08-22, so a tighter one kills a healthy run on a busy Mac. It also has a floor of twice `SUITE_STALL_TIMEOUT`, checked by the suite: a ceiling that expires first means the stall bound can never fire, and every real hang is then reported as a run that simply went on too long. At the end of a full run the suite says whether the ceiling still has room over the wall clock that run took, and uses the run's own processor time to tell a suite that has grown from a machine that was busy. `0` disables it. |
| `SUITE_STALL_TIMEOUT` | `1200` | Seconds a run may go without reaching a new section before it is killed as hung and told which section it stopped in. This is what actually catches a hang, and a machine that is merely slow keeps moving between sections and is left alone. Re-measured 2026-08-22 across four loads: the slowest single section was 44 seconds idle, 88 under three competing full runs, and 208 once, so this is at least 5.7x the worst observed. It was 600, which at a 3x floor left no room at all once the suite had grown, and a busy afternoon turned the run red with nothing wrong. The suite checks that ratio against the sections the run really took rather than against this sentence, and prints the margin it achieved on every run so a shrinking one is visible before it fails. `0` disables it. Both this and `SUITE_TIMEOUT` at `0` is refused, since that is a run with no bound at all. |
| `SUITE_LOCK` | `$TMPDIR/claude-sync-suite.lock` | Where the one run at a time lock lives. A second run REFUSES, naming the process that holds it and how long it has been going, rather than queueing. |
| `SUITE_NO_LOCK` | unset | Run without taking the lock. For when you know the run it names has finished. |
| `SUITE_LOCK_MAX_AGE` | `1800` | Seconds after which a lock from ANOTHER machine is broken. A lock from this machine is judged by whether its process is alive, never by the clock, so a clock jump cannot break a live one. |
| `SUITE_MAX_DEPTH` | `1` | How deeply a run may be nested inside another. The suite runs itself as a subprocess in many places, every one of them one level down, and past this it refuses to start rather than multiplying. |
| `SECTION_ONLY` | unset | Run the preamble, the first four sections, and the one named, plus anything it declares it needs. Refuses an ambiguous or unmatched name. |
| `SECTION_UNTIL` | unset | Run from the start up to and including the section named. Refuses to be combined with `SECTION_ONLY`. |
| `SUITE_FROM_COPY` | unset | Set to `1` to run this file in place rather than from a copy. It exists so the checks that guard the copy can be watched failing, and it puts a run back in the state where editing the suite mid-run corrupts it. |
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
| `SYNC_SCRATCH_MAX_AGE` | `14400` | Seconds before scratch counts as abandoned. Four times the suite's own 3600 second ceiling, so the longest run the tool permits is a quarter of the way to being swept, and 2400x the 6 second sync timed on 2026-08-17. The ratio against the ceiling is checked by the suite rather than stated here, because these are one setting living in two files and #152 moved half of it. The cost is that a burst of interrupted runs is not reclaimed until four hours after the last of them. `0` turns the sweep off entirely, and a value that is not a whole number is refused rather than guessed at. |
| `SYNC_SCRATCH_LEGACY_EVERY` | `86400` | Seconds between reads of the old flat location in the temp root. Reading it is what costs six figures of directory entries, so it is not done on every call. The cost is stated: something left there can go unreported for up to this long, though `reap-scratch` always reads it. `0` reads it every call, and a value that is not a whole number is refused. |

`claude-sync status` also reports watcher processes and test runs the tool left behind, counting
how many started independently and how deeply they are nested. It stays silent for one watcher
and one run, which is what a healthy machine looks like.

## Local state (per Mac, never synced)

Nine things hold state outside `payload/` and belong to the Mac that wrote them. All are gitignored,
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
| `.hook-tests` | a pull that reached a verdict on the hook suite it installed | `claude-sync status` | absent means no pull has verified anything here yet and status says nothing, since it reports what needs attention. A record that will not parse is reported as unreadable, never as a pass. A pass is silent; every other outcome keeps its own wording, so a suite that FAILED and one that could NOT be run stay apart |
| `.outage-log` | every outage decision | `claude-sync status` | absent means no decisions yet, and a line that will not parse is counted and reported as unreadable rather than skipped |
| `.sync-lock/` | any mutating run | every mutating run | a lock from THIS Mac whose process is alive is respected whatever its age; one from another Mac, or with no Mac recorded, is broken once older than an hour |
| `state/` | every apply | nothing reads the local copy; it exists so a marker is only republished when it changes | absent just means the next apply republishes |
| `refs/claude-sync-state` | every apply, pushed per Mac | `claude-sync verify` | nothing published means "cannot be answered", never agreement; a Mac silent for 60 days is reported as retired |

None of this travels between Macs except the published refs, and those deliberately never
land on the config branch: a marker commit there is a commit the other Mac does not have,
which the send guard correctly reads as being behind, and every send is then skipped.
