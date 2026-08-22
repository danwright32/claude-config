# Design record

The README says what this tool does. This says what was tried and rejected, and where the numbers
came from, so nobody rebuilds a design that was already measured and discarded.

It is not a changelog. Everything here cost real time to learn, and most of it was previously
recorded only in a commit message, which nothing links to and nobody reads.

## Rejected approaches

### Recording what each Mac has applied as commits on the config branch

Tried and reverted. A marker commit is a commit the other Mac does not have, and the guard that
stops a Mac publishing while it is behind reads that as behind and skips every send until somebody
pulls by hand. Committing markers alongside the payload turned 27 unrelated tests red for exactly
that reason.

That guard is also the last thing that should be taught a new exception: it dropped 81 minutes of
sends on 2026-07-28 when it was wrong in the other direction.

Markers now live on their own ref, one per Mac, so two Macs can never contend for the same one and
nothing lands on the branch the guard reads. See `publish_applied_marker` in `claude-sync`.

### Keying an applied marker on the branch tip rather than on the payload

Rejected during the same work. Publishing a marker moves the branch tip, so the other Mac sees a
new commit, applies it, publishes its own marker, and moves the tip again. The two Macs republish
at each other for ever.

The marker records the payload tree instead. A marker only commit does not change that tree, so the
exchange settles after one round and then writes nothing.

### Judging a stale lock by whether its process is alive, and nothing else

Shipped in #25, partly reversed two hours later in #29.

Liveness alone cannot work for a folder restored from a backup: the recorded process id belongs to
a machine that is not this one, and if anything here happens to hold that number the lock reads as
held for ever and syncing never resumes. So an age ceiling was added.

Age alone is worse. A clock jumping forward (a correction, a timezone change, a wake from sleep)
makes a live lock look ancient and lets a second run start on top of a running one, which is the
collision the lock exists to prevent.

The split that survived: a lock recording THIS machine is judged by whether its process is alive,
and the clock is never consulted. Age is the fallback only for a lock from elsewhere.

The tie was broken by detectability rather than by data, and that is worth stating plainly. There is
no measurement of whether a clock jump or a restored folder is likelier here. A wedged sync
surfaces, because a sustained outage alerts. A silent collision surfaces never.

### Stopping the suite recursing with a single flag

Shipped in 45528c7 after seventeen suite processes were found spawning each other, and replaced by
#34 the same day.

A run that was already a child skipped its own subruns. It worked, but it was one flag read
correctly, and its own check had to be deleted because the child in those tests stops before ever
reaching the guard, making the assertion one that could only ever fail.

Replaced by a depth counter carried in the environment. A run past the limit refuses to start,
which closes the class rather than the instance and is reachable in milliseconds, so it can
actually be tested.

The flag itself then turned out to be the trap. It is inherited by everything a run starts, so a
grandchild read it as being about itself and ignored the section limit it was given. That is
recorded as L169 and was fixed in #37.

### Clearing the inherited flag at each spawn site

Considered for #37 and rejected, which is what the issue itself proposed. Every spawn already had
to clear it by hand, and four of them did, which is the shape of a rule that protects only the
sites that remembered it: a site added later never saw the rule (L96).

The flag is un-exported once, ahead of every spawn, so it describes the current process and nothing
else. The four hand-written clears were then removed rather than left as reassurance, because a
second mechanism that cannot fire is indistinguishable from the one doing the work.

The skip that stood in for it is gone too. #27's subruns were skipped entirely inside a filtered
run, so `SECTION_UNTIL` at or past that section quietly ran none of its checks, which are the ones
anybody iterating on the section runner would want.

### Queueing behind a run that is already going

Considered for #32 and rejected. A run that waits without saying so is indistinguishable from the
stall the issue was filed about, which is how three concurrent runs went unnoticed on 2026-08-17.

A second run refuses and names the process holding the lock and how long it has been going. The
cost is real and was accepted knowingly: a push can now be rejected because of a lock rather than
because of the code. `SUITE_NO_LOCK=1` is the escape hatch.

### Detecting a runaway by counting processes

Rejected on evidence from the runaway itself. The pile grows one process at a time, because each
run spawns the next and waits for it, so the real event peaked at seven processes and an alarm set
at six never fired once.

`claude-sync status` counts how many started independently and how deeply they are nested. A chain
of four is one independent run nested three deep, which is unmistakable, where a count of four is
unremarkable.

### Reporting any nesting at all as a problem

The first version of that report flagged every healthy machine, because one watcher is a launcher
plus the subshell it forks, and both match. What counts as normal is now measured per family. A
line printed on every status stops being read long before a real pile up appears, which is how the
seventeen went unnoticed in the first place.

### Sweeping abandoned scratch by age

Rejected for #36, which is what the issue proposed. The issue reported, on 2026-08-17, 586 abandoned directories
holding 491 MB and read them all as the suite's, because a bare `mktemp -d` produces an anonymous
name and there is nothing else to go on.

Measured before building it, on 2026-08-17: of 579 anonymous `tmp.*` directories in that folder holding 508 MB,
only 37 were the suite's, holding 475 MB. The other 542 belonged to other tools on this Mac, and a
sweep of old temp directories would have deleted every one of them.

So the scratch is NAMED at the point it is created, and swept by name from a list this tool owns.
The age floor stayed, as the second line rather than the first. The 37 already on disk carry no
name and were removed by hand once, rather than teaching the sweep to recognise directories by
peering inside them, which is a rule that would then live for ever.

The other half of that 2026-08-17 measurement is why "older than a day" was not kept: all 37 were created
within one hour and 43 minutes of each other, so a day would have reclaimed nothing at all.

### Never reading the old flat scratch location again

Rejected for #116, and it is the obvious version of that change.

Scratch used to be created directly in the temp root, so the sweep had to read the whole of it.
Measured on this Mac: 113,912 entries, 25 of them ours. #115 cut six reads of that to one and took
`claude-sync status` from 1.74s to 0.36s, measured on 2026-08-21; the read left was most of what remained, paid 270 times
by a single suite run. The cost is set by how much other software puts in that directory, which
nothing here controls and which only grows.

Moving new scratch into `$TMPDIR/claude-sync` fixes that. The question is what happens to what is
already in the old location on every Mac that has run an earlier version, and to what an
un-upgraded copy writes there during a rollout. Reading the old location on every call gives the
whole saving back. Never reading it again abandons exactly what the feature exists to reclaim, and
does so invisibly, since a leftover nobody reports is a leftover nobody reclaims.

So it is read on an interval, stamped in the new directory, defaulting to a day, and
`reap-scratch` reads it every time whatever the stamp says. Every way of failing to answer whether
it is due lands on reading it: no stamp, an unreadable stamp, an unreadable interval. What that
buys is a cost paid once a day instead of 270 times a run. What it costs is stated rather than
hidden: something left in the old location can go unreported for up to a day, and `reap-scratch`
is the way back to it that does not wait.

A one-off migration that MOVED the old leftovers into the new directory was considered and adds
nothing: finding them to move them is the same expensive read, and it would still leave nothing
watching the location an un-upgraded copy keeps writing to.

### Keeping the test runner's boundary at one directory

Rejected for #120, and it is what the runner did for its whole life.

It discovered suites from disk rather than from a list, which is the right idea and is written into
its own header. It read ONE directory though, the one it lives in, so `tests/`, `tools/` and
`payload/skills/milestone/` were outside it. Three of those were run only because four hand written
steps in the CI workflow named them, and the fourth was named by nothing at all: 233 checks, written down
2026-08-21, that had never run anywhere, found by asking git which directories hold a `test-*.sh` rather than by
reading the workflow. The boundary WAS the hand maintained list, drawn one level up in a file
nobody opens when adding a test.

Keeping it and adding a fifth CI step was the cheap fix and it fixes nothing: the next suite is
exempt in exactly the same way. So the runner asks the repo. A directory it was told to read that
holds no suite is now a failure, because with several directories in play one of them going empty
loses a block of coverage while every remaining suite still reports green.

Two things had to come with it. A run of the whole repo now discovers the runner's OWN test suite,
which invokes the runner, so a bare re-entry is refused by name rather than by convention; without
that the first run recursed until it was killed by hand. And the score column had to read each
suite's tally rather than the last line containing the word "passed", because the sync suite prints
hundreds of per-check lines and reported its verdict as `ok: #105 even though every check inside it
passed`.

### Leaving a full test run reading its own file

Rejected for #121, and it was the state every unfiltered run was in.

Bash reads a script incrementally from a byte offset, so editing the suite while a run is in flight
makes the running shell resume at the wrong place. What comes out is not a crash: it is ordinary
looking failures in sections that are perfectly fine. Measured on 2026-08-21, three at once, in a
section unrelated to the edit, and the same run was green the moment nothing was being written.
Nothing in the output distinguishes those from real failures, and a full run takes minutes, which
is exactly the window somebody keeps working in.

The machinery already existed: a run given SECTION_ONLY or SECTION_UNTIL writes a copy into scratch
and executes that, because it has to extract sections anyway. So an unfiltered run does the same.
It sits after those two paths and before the lock, so the copy is the process that takes the lock
rather than one waiting on a parent holding it, and SCRIPT and SCRIPT_SELF are handed over
explicitly because several checks read their own source and a temp copy is not what they mean.

Doing it without a seam was considered and rejected: the two checks guarding this are only ever
seen passing, and a check nobody has watched fail is not a check. SUITE_FROM_COPY=1 skips the copy
and puts a run back in the old state, which is how both were watched going red.

### Reordering the pull failure classifier for newer git

Written, measured, and reverted the same hour, which is the reason this section exists.

When the suite first ran on a Linux runner with git 2.54, three checks about a conflicted autostash
restore failed, and the output showed the run blaming a two-Mac content conflict. The obvious
reading was that git had changed: that a conflicted autostash restore now FAILS and leaves a rebase
directory, so the content-conflict test, which comes first, had started answering for it. The fix
follows from that reading: ask the more specific question first, and read the stash before anything
aborts, since aborting destroys the evidence.

It was wrong. Measured on the runner directly, git 2.54 does exactly what the older git does: a
conflicted autostash restore prints "Applying autostash resulted in conflicts", exits ZERO, leaves
`stash@{0}: autostash` in place, and leaves NO rebase directory. Both branches of the classifier
behave identically on both versions, so the ordering could not have been the cause and the change
was reverted rather than kept as harmless.

What that leaves is the fixture, not the tool: on Linux the #22 scenario is not producing a
conflicted autostash at all, so its assertions are being answered by a different mechanism. That is
precisely the trap the fixture's own comment warns about, and it is still open.

The lesson worth keeping is the order of work. Three plausible causes were proposed and two were
acted on before anything was measured, and both were wrong: first that `claude-sync status` was
exiting non-zero and tripping the self-update gate, then that git had changed its autostash
reporting. A twenty line probe printing what git actually does settled it in one run.

### Running the suite in CI on a Mac, so it runs where it ships

Rejected for #38 on cost, after being chosen and then reversed on a measurement.

The argument for it is real: this tool only ever runs on macOS, so a Mac runner needs no porting
and tests the platform that actually matters. The argument against is arithmetic. GitHub bills
macOS minutes at 10x, the suite takes about two minutes, so a run costs roughly 25 billable
minutes. This repo took 265 commits in the fourteen days to 2026-08-17, about 19 a day, because the
watcher pushes every config edit within seconds of it happening. That is around 14,000 billable
minutes a month against a 2,000 minute allowance.

Filtering which pushes trigger a run does not save it either: at roughly 2 non-autosync commits a
day plus pull requests plus a periodic unfiltered run, it still lands near 2,250 a month, and the
filter itself is the thing L88 warns about, since the suite reads README.md and DESIGN.md and
checks every tracked file.

So the suite was made portable instead, which turned out to be two helpers and eleven call sites,
and it now runs on Linux on every push with no filter at all, for about 1,400 minutes a month at
the 1x rate, on the usage measured over 2026-08-17.

The port also found a real defect that had nothing to do with Linux. BSD `date -r ""` does not
fail: it succeeds and answers 1969-12-31. A Mac marker whose timestamp could not be read would
therefore have been reported as a confident date rather than as "an unknown date", which the
calling code already had ready and never got to use.

The GNU halves of both helpers are exercised on this Mac through stand-ins shaped like the GNU
tools, because a Mac otherwise never runs that code at all and the runner depends on it entirely.
The trap they exist for is specific: `stat -f %m FILE` on GNU means file system status, prints a
block about the filesystem and exits non-zero, so a plain `||` fallback concatenates that block
with the real answer rather than replacing it. A mutation to exactly that naive form is caught by
those stand-ins and by nothing else.

### Testing each synced file in turn for a lesson citation

Rejected for #53 on a measurement, having shipped that way with #43.

The renumber report has to say which other synced files cite a number that has just moved. The
first version walked the whole config and ran a text test plus a matcher on every file it found,
once per renumbered lesson. Against the real config on 2026-08-17 that is 800 files (747 of them
under `skills/`) at 8.4 seconds per lesson, roughly 2,400 processes. The 2026-08-17 collision
renumbered three lessons at once, so that pull would have spent about 25 seconds inside this alone,
and the watcher runs it in the background on every config edit.

One grep answers the same question: `grep -rIlE` over the same roots took 0.022 seconds. So the
scan now finds its candidates in one pass and runs the existing per-file count only on those, which
makes the cost proportional to how many files match rather than to how big `skills/` is. Measured
again after the change on the same config: 0.246 seconds against 3.235, same files, same counts.

Two things the fast path is careful about. It is deliberately a SUPERSET of what counts as a
citation, because the count strips each entry's own heading number before matching and the grep
does not, so a file whose only occurrence is its own `- **L2.` heading is a candidate and is then
correctly counted as zero. And the old walk is still reachable behind `SYNC_NO_CITATION_PREFILTER=1`
so the two can be run over one fixture and compared, rather than the fast path quietly becoming a
second definition of what a citation is (L107).

The test asserts how many files the scan OPENS, not how long it took: a wall-clock threshold on a
shared runner is noise, and a number that moved cannot say why.

### Recording an unresolved conflict as a marker under `state/`

Rejected for #45, which is what the issue itself proposed.

When a merge fails, the pull keeps your version as `<file>.conflict-<host>` and says so once. The
condition then persists and nothing says so again, because the live file matches the payload
exactly afterwards and every later check reports healthy. On 2026-08-17 that dropped a lesson out
of the loaded rules and it survived only because the one output line happened to be read.

A marker written at the moment of conflict records a judgement made then. It cannot notice the copy
being resolved by hand or deleted since, so it needs its own clearing rule, and a marker whose
clearing rule is wrong is worse than none: it either cries wolf for ever or goes quiet while the
content is still missing (L121).

So the answer is derived on every run instead, from the two files sitting on disk: what the copy
holds that the live file does not, computed by the same function that describes the conflict when
it happens (L16). The report stops the moment the entry is back in the live file or the copy is
deleted, and never before, with no state to keep in step. It costs one comparison per copy, and
there are normally none at all.

Status names both states separately rather than merely listing the file: one still holds something,
the other is safe to delete. "A conflict copy exists" says nothing about whether anything is at
stake in it (L11).
### Asking the shared repo for a number every time a lesson is written

Rejected for #44, which the issue offered as the alternative to bands.

It reads as the airtight answer, and it is not. The allocation would have to fetch, read, claim and
push while the person is mid sentence, which fails offline, fails while the repo is unreachable, and
still races: two Macs that fetch before either pushes both see the same highest number. It converts
a rare collision that the merge already settles into a network dependency on the one action that has
to work when nothing else does.

A band cannot race at all, because the number is decided by a claim made once, per Mac, in advance.
The cost is that numbers are no longer contiguous across the two Macs, which is only cosmetic: a
lesson number is an identifier, not a position.

### Deriving each Mac's band from its hostname

Considered for #44 and rejected. A hash of the hostname needs no file and no commit, and two
hostnames can land on the same band with nothing to notice it, which is the exact failure the issue
is about, arriving by a quieter route. It is also unverifiable by eye: nobody can look at a band and
say whether it is right.

The claim is a file per Mac instead, named after the Mac. One file per writer means two Macs can
never edit the same file, so a claim cannot produce a merge conflict of its own, and the whole
allocation is legible with `ls`.

Two Macs CAN still claim the same band, by claiming while unable to see each other. That is settled
on read by name order, so the rule gives the same answer wherever it runs and both Macs agree with
nobody arbitrating. The alternative, keying it on who claimed first, is not knowable: an offline
claim has no timestamp anyone else can trust.

### Letting a full band spill into the next one

Rejected while building #44. A band 500 wide is far past anything this will hold (174 lessons in
five months), so the case is remote, and that is exactly why silently spilling would be the worst
answer: it would put the collisions back with nothing saying so, years after anybody remembers the
mechanism. A full band refuses and names itself.

### Carrying plugin enablement in the payload

Rejected for #48, which named it as the real fix.

`enabledPlugins` lives in `~/.claude/settings.json`, and this tool carries only the `hooks` block out
of that file. Carrying the plugin block as well would mean this Mac's survey of which projects use
which plugin lands on a Mac holding different projects: Bidspoke, trypennie, Slate and
project-enrollment-tracker are not checked out here and were never surveyed, and at least one of them
is a plausible Vercel user. The fix would arrive there as a regression, which is exactly what the
issue warns about.

Project-scope enablement is the half that should travel, and it already does, in each project's own
repo. What is left per Mac is the user-scope list, so `claude-sync status` prints it: two Macs
diverging silently with nothing able to report it is the failure worth making visible, and the
README says plainly that this setting does not sync.

The enable direction was proven before anything was turned off, because the whole plan collapses
without it. In a real session on 2026-08-17, a directory whose project settings enable a plugin that
is off at user scope listed that plugin's skills, and a control directory without those settings did
not.

### Trimming LESSONS.md rather than splitting it

Rejected for #63. The obvious way to spend fewer tokens on 180 lessons is to write them shorter, and
it is the wrong one: the body of each entry is the evidence, and a rule without the failure it came
from is routinely too short to apply correctly. Several lessons exist BECAUSE a shortened version of
them was misread.

So nothing is trimmed. The session loads a generated index of one line per lesson, and the full
entry is read on demand, by `claude-sync lesson L174` or by opening the file. Measured through the
shipping code path on the real file: 117,050 bytes to 33,549, with all 180 lessons present.

Two things this had to avoid. `LESSONS.md` is no longer imported by `CLAUDE.md`, and the set of
files that sync is DERIVED from those imports, so dropping it could have stopped the lessons file
syncing at all, leaving a generated index as the only copy anywhere. It stays because
`TOP_FILES_SEED` names it, and a test asserts the whole file still travels. And the index is
regenerated on every send and every apply rather than maintained beside the file, because a copy
kept by hand next to its source drifts silently (L41). The renumber scan skips it for the same
reason: a number in a file that is rewritten in the same run is not something to go and check.

### Handing the freed budget to the last suite still running

Rejected for #147, which is what the issue proposed. A full run measured 84 seconds on an idle Mac
on 2026-08-21, and 37 of its 38 suites had finished by 39 seconds, so the longest suite held the
machine alone for 45 seconds with 4 of the 8 slots idle. A grant is fixed when a suite launches, so
using that idle half means the runner telling a RUNNING suite it may take more, and the suite
splitting into more shards than it was first granted and widening its own fan-out mid run.

Two things were measured wrong on the way to the answer, and both are recorded here because the
wrong ones are more instructive than the right one.

The first was reading the growth in total section time, 256 seconds across four shards against 392
across eight on 2026-08-21, as work the extra shards added. It is not. Taking only the sections that ran the same
number of times in both, the total still rose from 244 to 376 seconds: identical work, 54% slower,
which is 8 concurrent shards saturating a budget of 8. That is L209 exactly, a quantity measured
while a co-varying component moves attaching itself to the wrong variable. Repeating the prelude
costs about 1 second per shard, not the 34 that fit implied.

The second was treating a run that hands the long suite the whole budget from the start as the
upper bound on what a handover could do. It is not that either: it runs 8 sync shards alongside the
other suites' 4 lanes, 12 processes against a budget of 8, so it pays for oversubscription through
the whole first half. A handover would stay at 4 until the others finish. That arm is worse than a
handover, not better, so it bounds nothing.

What is left is a real opportunity, correctly sized: the suite took 82 seconds at four shards and
63 at eight when it was timed on 2026-08-21, so widening only once the slots are genuinely idle should put a full run near 70
seconds instead of 84. About 15%, for a cross process protocol between the runner and a running
suite plus a suite that can widen its own fan-out mid run, in two programs every other test in this
repo depends on being correct. Judged not worth the price.

The number to watch is the fraction of a run the last suite holds alone. It is over half today. If
it grows, the trade changes.

### Declaring the dependencies between suite sections rather than removing them

Considered for #105 and rejected, and it is what the issue itself proposed: give each section an
explicit declaration of what it depends on, so a filtered run can execute a section plus its
prerequisites. The plan that came out of it had a declaration syntax, a validator for it, a static
scanner, and an exhaustive sweep that ran every section in isolation and diffed the results.

Then the dependency graph got measured instead of designed around. Written down 2026-08-21, all 73 post-prelude sections
were run in isolation: 68 passed alone, and the five that did not each read one variable an earlier
section had set. Four of the five were accidents worth about fifteen lines between them. `PSH`/`PSR`
was two lines that three separate sections all wanted, and each reached for whichever of the three
happened to run first. Two other sections borrowed a fixture from the section immediately above
rather than building their own.

So the coupling was deleted rather than declared. One real dependency is left, #17 continuing the
git history #15 leaves on disk, and it carries a `# needs:` comment. A syntax, a validator and a
fifteen minute sweep to manage one edge is machinery standing in for an edit.

The declaration is a comment and not an argument to `section`, which was the other half of the
original plan. Three derivations in the suite parse the heading line by stripping one trailing
quote. #27's would have failed loudly, which is fine. #37's would have failed SILENTLY: its marker
would still have been non-empty and would simply never have matched, leaving the check that proves
a filtered child stops where it was told passing while checking nothing, and that check covers the
runaway that filled a Mac with suite processes on 2026-08-17.

Two things that were in the plan and are NOT here, deliberately. There is no static scanner: the
constructs in this file defeat one, sixteen phantom variables live in a single quoted heredoc and
real dependencies live inside `check` expressions that are evaluated later, so it would have been
both noisy and blind. And there is no shipped exhaustive sweep: it cannot run as a mode of the suite
without either raising the nesting limit, which breaks the three checks in #34 that prove a too-deep
run is refused, or disabling the lock, which breaks the checks in #32 that prove a second run is.
What replaced both is cheaper and runs on every push: each section the push CHANGED is run on its
own, which is the only run in which a missing prerequisite shows up at all.

## Measured numbers

Every threshold here is a multiple of something real, measured on the date given. None is a round
number chosen because it felt safe.

Each row also CITES the check that proves its justification, and the suite requires that citation to
name a section that exists. Where the justification rests on a MEASUREMENT rather than on the code,
the row says how to take it again: the suite deadline measures itself on every run, and the retire
window is re-derived by `tools/measure-sync-gaps.sh` in one command. That distinction is the whole
point. A figure nobody can cheaply re-take is a figure nobody re-takes. The number was verified against the code long before the sentence beside
it was, and a page carrying a passing freshness check gets read as verified in full: the depth row
below asserted for months that the suite "runs itself as a subprocess in one place" while nineteen
places did, and nothing noticed, because the check compared only the number (claude-config#112).

The `Set by` column is not decoration. Each number below is also a default in the code, and nothing
kept the two in step: a limit changed in one and not the other leaves this page confidently
defending a number that is no longer true, and the day it was written is the only day anybody would
ever check by hand (L32, L41). The suite now reads every one of these defaults out of the code and
requires a row here that names it and agrees with it, so a threshold that changes and a threshold
that is added both fail until this table is updated.

| Number | Set by | What it is | Measured against | Date |
| --- | --- | --- | --- | --- |
| 1 hour | `SYNC_LOCK_MAX_AGE=3600` | A lock is broken as stale | Re-checked 2026-08-21: the payload is 4.9MB, a fresh clone from origin takes 1 second and a whole-payload copy under 1, so the original 6 second figure is conservative and this is at least 600x the slowest real run, proved by #29 | 2026-08-21 |
| 60 days | `SYNC_MAC_RETIRE_AFTER=5184000` | A Mac counts as retired | Re-derived 2026-08-21 by `tools/measure-sync-gaps.sh`: the worst gap either Mac showed in the window is 6.79 days, so 8.8x the longest real absence, and a holiday cannot trip it, proved by #26 | 2026-08-21 |
| 1 hour | `SUITE_TIMEOUT=3600` | A suite run is killed after this much wall clock however well it is going | No longer the thing that catches a hang, which is why it is generous: SUITE_STALL_TIMEOUT does that. A full single process run measured 348 seconds idle and 1943 at load 160 to 188 on 2026-08-22, so the old 900 would have killed a healthy run on a busy Mac, proved by #152 | 2026-08-22 |
| 10 minutes | `SUITE_STALL_TIMEOUT=600` | A suite run is killed as hung after this long without reaching a new section | This is what actually catches a hang. The slowest single section measured 34 seconds on 2026-08-22, and about 190 if the whole machine runs five times slower as it did under load, so at least 3x the worst observed. Checked against the sections this run ACTUALLY took rather than against this sentence, proved by #152 | 2026-08-22 |
| 30 minutes | `SUITE_LOCK_MAX_AGE=1800` | A suite lock from another machine is broken | The same runs, so at least 6x the slowest observed, proved by #32 | 2026-08-21 |
| 4 hours | `SYNC_SCRATCH_MAX_AGE=14400` | Scratch counts as abandoned | 4x the 3600 second suite ceiling, so the longest permitted run is a quarter of the way to being swept, and 2400x the 6 second sync. It was 3600 against a 900 second ceiling, which was the same 4x, and #152 raised the ceiling alone and closed the margin to nothing. The two are now compared against each other by a check rather than by this sentence, proved by #160 | 2026-08-22 |
| 1 nested run | `SUITE_MAX_DEPTH=1` | The suite's own depth allowance | Every place the suite spawns itself is one level down and nothing in it legitimately needs a run nested two deep, proved by #34 | 2026-08-17 |
| 2 processes | not a setting | One healthy watcher | Observed directly as a launcher with one child (pid 13658 with 13702), proved by #33 | 2026-08-17 |

The two suite figures above were 123 seconds and "roughly 7x" for eleven days, written down
2026-08-21, when the suite had 726 checks. It now has 784, and the run time has been 123, then 267, then 191 seconds as
checks were added and one of them was made five times faster. Every one of those figures was true
when written and wrong within days, and nothing noticed, because the check beside this table
compares the SETTING and not the measurement the setting was derived from. So the suite measures
ITSELF and requires the deadline to be at least twice the run that just happened. That number
cannot go stale because it is not recorded anywhere.

The last row is the one exception, and it is stated rather than quietly left out: what a healthy
watcher looks like is passed straight to `report_process_family` as arguments, so there is no
default for the check to read. That makes it the only number here nothing verifies, which is worth
knowing when deciding how much to trust it.

Two of these are the ones where being wrong LOW is dangerous rather than merely annoying: the lock
ceiling starts a second run on top of a live one, and the retired window drops a Mac that is only
on holiday. Both are deliberately generous.

The deadline is the opposite. Being wrong low turns a contended machine into a false failure, and
an alarm that cries wolf stops being read, which would leave the suite worse off than with no
deadline at all.

## How much each guard is actually proven

Not all of these carry the same weight, and the difference matters when deciding what to trust.

**Proven by mutation**, meaning the code was broken on purpose and the right checks were watched
going red. The stale lock takeover: disabling it turns exactly the five checks covering it red and
nothing else, which is what makes the three that predated the lock into real guards rather than
decoration.

The scratch reaper, on five separate mutations, each turning red only the check written for it:
removing the age floor sweeps scratch a live run is using, widening the name list reaches another
tool's directory, adding the lock to that list deletes a lock, dropping a created name leaves it
unreclaimable for ever, and making the shared helper anonymous again hides every file it creates
from the sweep. Widening the name list ALONE does not reach the foreign directory, because the
check made immediately before the delete refuses it, which is the two independent rules doing what
they were separated for.

The un-export in #37 likewise: with it removed, the probe reports a child inheriting the flag and
that child runs the whole suite instead of the one section it was given.

**Proven by construction**, meaning the failure was manufactured through a named seam rather than
waited for. The suite deadline (a section that hangs deliberately), the depth limit (a run started
at a depth past the limit), the lock in every ownership state (locks planted live, dead, foreign
and ancient), and the process report (fixed process listings fed through a seam). Each was seen
failing before it passed.

**Proven by one observation**, meaning it was watched working once and nothing in the suite would
notice if it were removed. The original recursion flag was in this category, which is why #34
replaced it. Nothing else is currently here, and anything that lands in it should be treated as a
gap stated rather than a guard held.

**Deliberately not proven.** The retirement window's boundary is inclusive, so a window of 0
retires a marker recorded in the same second. Nothing on a Mac can show that: the marker is never
read in the same second it was written, so the previous exclusive comparison passes every check
here too. A check for it was written, watched passing against the defect, and removed rather than
kept as decoration. The evidence is the flakiness it caused instead, which is real but indirect:
the same commit produced one green run and one red run two seconds apart on a Linux runner, failing
exactly the three checks that depend on it. Proving it directly needs a seam for the clock, which
the tool does not have.

A control asserting that an empty process listing reports nothing
exists specifically because a real watcher is running while the suite executes. Without it, a
listing that failed to reach the code under test would pass quietly against the live machine, and a
stub that matched nothing is worse than no stub, because you believe the case is covered.

## Things known to be wrong and left that way

Markers are keyed on hostname, which is a mutable string. Renaming or reinstalling a Mac abandons
its marker rather than moving it. #26 sweeps up the orphans a rename leaves rather than carrying
the old marker forward, so renaming a Mac still loses its history, it just stops shouting about it.

A run killed by the deadline cannot release its lock, and nothing tries to on its behalf. The next
run finds a process that is gone and takes over saying so, which is the same path a crash needs and
is therefore the path worth having work.
