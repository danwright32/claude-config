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

### Leaving the applied marker alone on a manual push

Rejected for #511, where it was the defect rather than a choice anybody made. `.last-applied`
records which commit's payload is on this Mac, and everything that publishes upward compares
against it to tell an edit somebody made from a Mac that is simply behind. `do_send` has always
recorded it after a successful push, on the grounds that a commit made from this Mac's own
`~/.claude` is applied here by construction. `do_push` never did.

So a manual push committed, HEAD moved, the marker stayed where it was, and every path in that
commit then read as changed by the repo and not applied here. The next push held exactly those
paths back, and the repair that would have cleared it compares bytes, so a lesson written in
between made the answer no and the state became permanent. Measured on 2026-09-20: three lessons
sat unpublished across repeated pushes, each one reporting a clean send.

The record is written after a successful push, and CONDITIONALLY, which is the one place this
differs from `do_send`. That command refuses to send at all while the repo holds unapplied
commits; `push` has no such guard in front of it, so recording unconditionally would tell a clone
that really is behind that its payload is applied, and the next push would mirror this Mac's older
copy over the other Mac's newer one. The condition is `payload_fully_applied`, the same question
the marker's own repair asks, shared rather than written twice. `do_send`'s unconditional record is left
alone here, and #514 asked whether it is a hazard: it is not, because the behind check in front of
that command reconciles before the record is ever written, so the claim is true when it is made. A
file held back for a publish fault is not in that commit at all. The suite pins both, and the
section goes red if the behind check is ever removed.

### A send that keeps a file back says so

The staging holds back any path the repo has changed since this Mac last applied, and that is
right: the repo's copy is newer and mirroring upward over it reverts the other Mac. Until #511 it
said nothing. The copy loop skipped the path, nothing was staged, and `push` printed the words it
prints when there was nothing to send, so a Mac whose lessons had stopped publishing looked exactly
like a Mac with nothing to publish.

It names them now, with the remedy, and only where this Mac's copy really differs: a path the repo
moved that is byte for byte what is here has nothing waiting behind it, and naming it would put a
line on every send from a Mac that is merely behind.

It does not NOTIFY, and that is deliberate. The watcher sends on every save and this state lasts
until the next pull, so a notification here is one per keystroke for a condition the next pull
clears. The suite already held that line: the #25 control asserting an ordinary sync fires nothing
went red the moment this notified, which is the check doing its job.

### Designing the spill state out rather than refusing it

Considered for #513 and not done. Two refusals on the lesson minting path had no caller that could
reach them: the one that stops a number being handed out from outside its band, and the merge
declining to renumber when no number came back. Removing the states they guard, by having the
minting path always resolve its own band, would make both impossible rather than refused.

It is rejected on risk. The merge's band handling is the most delicate code here, and the same
day's work had already produced a corruption in it: a refusal swallowed by a command substitution
renumbered an entry to nothing. Keeping a fail closed refusal and proving it fires is the smaller
claim and the safer one, and it costs nothing that the design would gain.

So they are DRIVEN instead. The suite sources the tool in a subshell and calls the two functions,
using `help`, the one command that prints and changes nothing. No seam was added to the product to
make that possible, deliberately: a seam that exists only for a test is a second way for the real
path to be wrong, and the thing under test would no longer be the thing that ships.

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

A second run refuses and names what is holding the lock, how long it has been going, and the
command that ends it. That last part is #163: the message carried only a process id for months, and
a bare pid has no visible connection to the run somebody killed minutes earlier, so an orphan
holding the lock read as a bug in the suite and cost two separate false failure investigations in
one session. A run killed from outside now kills its own children and releases the lock on the way
out, so the orphan is rarer as well as easier to recognise. The cost is real and was accepted
knowingly: a push can now be rejected because of a lock rather than because of the code.
`SUITE_NO_LOCK=1` is the escape hatch.

### Detecting a runaway by counting processes

Rejected on evidence from the runaway itself. The pile grows one process at a time, because each
run spawns the next and waits for it, so the real event peaked at seven processes and an alarm set
at six never fired once.

`claude-sync status` counts how many started independently and how deeply they are nested. A chain
of four is one independent run nested three deep, which is unmistakable, where a count of four is
unremarkable.

### A suite killing its own children from a TERM handler

Considered for #444 and rejected on a measurement. The pile of 2026-09-18 was reproduced the same
day: test-run-all-tests.sh stopped by a TERM to its own pid, which is what a caller's deadline
sends, left its runner and three fixture suites looping `sleep 3600` at zero CPU. The runner already
answers the same gap with a TERM handler, so the obvious fix was one in the suite too.

It does not work for a suite, and the reason is not obvious. The runner is sitting in `wait` when
the signal comes, which a trapped signal interrupts. A suite is sitting in a command substitution,
which it does not: bash holds the signal until the command returns. Measured while building the fix:
with a TERM trap, and equally with only the EXIT trap every suite here already has for its scratch,
the suite went on running with its child for as long as the child lived. So the handler would have
turned a suite that dies and orphans its children into one that ignores the signal outright.

What replaced it lives outside the suite: `lib/suite-deadline.sh` starts a watchdog that remembers
what the suite has started and kills whatever of it outlives the suite, and that stops the suite at
its own deadline by killing the tree under the blocked command, which is the only thing that
releases it. The fixtures that could hang for ever now hang only while the suite that made them is
alive. Both halves were watched failing before they passed.

Every suite in the repo arms it, and `test-suite-deadline.sh` fails on one that does not, listing
the suites from the runner's own discovery so the scan and the runner cannot disagree about what a
suite is (claude-config#465). Arming was left to each suite for one release and only the reproduced
suite had it, which is the shape L621 describes: a behaviour each site has to opt into is a
convention until something fails on the site that did not. A fixture that copies a suite into a
throwaway tree now carries `lib/suite-deadline.sh` and `lib/kill-tree.sh` with it, because the copy
refuses to run unbounded exactly as the original does.

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

Rejected while building #44 and still rejected. Spilling would put the collisions back with nothing
saying so, years after anybody remembers the mechanism.

What changed on 2026-09-20 (#512) is what happens instead. The refusal was justified by a premise:
"a band 500 wide is far past anything this will hold (174 lessons in five months), so the case is
remote". That premise expired inside a month. This Mac claimed band 1 on 2026-08-17 and had used all
500 numbers by 2026-09-20, about ten a day, and the refusal then meant no lesson could be numbered at
all until somebody hand edited a file in the sync repo. A rate measured once is not a rate (L316).

So a full band ROLLS OVER: it claims the next free band and mints from there. That spills into
nobody, needs no network, cannot race, and is the same claim the mechanism already makes once per
Mac. It costs a gap in the numbers, which this design already calls cosmetic: a lesson number is an
identifier, not a position.

The rollover skips any band that has no room, rather than taking the next free one blind. A band
NOBODY claims can still hold numbers: a Mac that moved off a band after a collision leaves its
entries behind under those numbers, and they arrive here on the next sync. The walk needs no cap,
because a band starting above every number in the tree is empty by construction.

The refusal is kept as the backstop, in the one function that hands out a number, and it no longer
names a person: every caller resolves its band through `lesson_band_with_room`, so reaching it means
a caller asked with a band it had not checked.

### Widening SYNC_LESSON_BAND_SIZE to make room

Rejected for #512, and now refused by the tool. It was what the old full-band refusal TOLD somebody
to do, and it was the one remedy that would have caused the collisions the bands exist to prevent.

The size is global and the bands are contiguous, so widening does not extend one band, it moves every
band over the one above it. With this Mac on 1 and the other on 501, a size of 1000 gives this Mac 1
to 1000 and the other 501 to 1500: this Mac would then mint L501, a number the other Mac published
weeks ago. Nothing refused, because the collision check compared band STARTS, and two overlapping
bands do not start at the same number.

Overlap is now judged on ranges, and it refuses on BOTH Macs rather than moving one. Moving is the
right settlement for two Macs that claimed the same start, because neither has minted anything the
other could not also mint. It is the wrong one here: a number already minted inside the overlap
cannot be un-minted, so the only safe answer is to stop until the size is put back (L42).

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

### One index file per section rather than one file for all of them

Adopted for #473, on the belief that both limits governing a file loaded into every session are
PER FILE: the 140,000 byte budget in `hooks/test-rule-file-budget.sh` and the platform's own
large-memory-files banner at 150,000 characters. That was half right, corrected by #541 below the
next paragraph. The single index measured 100,899 characters over 702 lessons on 2026-09-19 and
was growing about 1,130 a day, so it was roughly a month from the budget. Rendering one file per
section of `LESSONS.md` put the largest at 27,713, a fifth of the budget, and every file is still
imported by `CLAUDE.md`, so every lesson still loads into every session. It saves no tokens, which
is the point: the file size problem is separated from the token cost question, which is #474.

**The banner also has a TOTAL, and neither figure is a constant** (#541, read out of the 2.1.281
binary on 2026-09-23). The per file limit is the model's context window times 0.05 times a model
factor of 3 or 4, with a floor of 40,000; the total is the larger of 120,000 and that per file limit,
summed over the loaded instruction files that are not already over the per file limit on their own.
The memory index and a few other named files count toward neither. The 150,000 seen here is the per
file figure for a 1M window; a 200,000 window model gets the 40,000 floor and a 120,000 total. So
splitting the index into sections got every file under the per file banner and did nothing for the
total: `CLAUDE.md`, `RTK.md` and the twelve index files came to 144,957 characters on 2026-09-23,
already over the 120,000 floor and within about 5,000 of the 1M window's 150,000. What the banner
does NOT do is drop anything. A nonce probe on 2026-09-23 loaded 250,000 characters of instruction
files and every code planted at the start, middle and end arrived, so crossing either figure costs a
warning on screen and the context it takes, never a rule.

Three things this had to get right. The set of files is a LIST that changes whenever a section is
added, renamed or removed, so `CLAUDE.md` gets its import block generated from the same list rather
than maintained beside it (a file nothing imports neither loads nor travels, since the synced set is
derived from those imports). A file whose section has gone is deleted by the generator in the tree
it writes, and the payload is mirrored against `~/.claude` in the staging, so the deletion travels.
And whether a path is derived is decided by its NAME SHAPE rather than by the current section list,
because the file that turns up in a rebase conflict is exactly the sibling no current section
produces.

The single `LESSONS-INDEX.md` was retired rather than kept beside the sections. Kept, it would have
been a second copy of every rule that nothing imports, so nothing would have carried it to the other
Mac or kept it current there, and a stale index reads exactly like a correct one (L98).

### Refusing a lessons file refuses everything rendered from it

Adopted for #483. The publish gate holds `LESSONS.md` back when it carries a duplicate number, an
entry nothing can read, a line over the index cap or any of the other faults it walks. It used to
hold back only that file and copy the generated index files beside it, so the payload carried an
index naming a lesson the payload's own `LESSONS.md` did not hold, and a rendered index line is what
a session on the other Mac loads as a rule that exists (L46, L11).

The set held back is now the source plus everything rendered from it, assembled in one place and
read both by the copy loop and by the message that says what waited, so a reader cannot be told
about a different set from the one held (L679). The generated files are enumerated by name shape
rather than from the current section list, for the reason the shape rule already gives: a sibling
from a section this Mac no longer produces is still a rendering of that source. `CLAUDE.md` joins
them only when its generated list of imports would disagree with the index files the payload holds,
which is written as the condition rather than as a broader "a lessons fault holds `CLAUDE.md` too"
(L615): a name the payload has no file for makes the other Mac's pull refuse outright, and a file
the list stops naming stops loading there while its lessons are still in that Mac's `LESSONS.md`.
The sweep that removes a payload file this Mac no longer produces is skipped on the same run,
because deleting a sibling while the payload keeps a `LESSONS.md` that still has that section is the
same partial state read the other way round.

The staleness hold back counts as well as the gate. This Mac can be holding an unsent lesson while
the repo has changed `LESSONS.md` since the last apply, and then the source is left alone as stale
while the index rendered from it, unsent lesson and all, would be copied over the repo's.

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
| 1 hour on a Mac, 30 minutes on CI | `SUITE_TIMEOUT=3600`, set to 1800 in `.github/workflows/tests.yml` | A suite run is killed after this much wall clock however well it is going | No longer the thing that catches a hang, which is why it is generous: SUITE_STALL_TIMEOUT does that. A full single process run measured 348 seconds idle and 1943 at load 160 to 188 on 2026-08-22, so the old 900 would have killed a healthy run on a busy Mac, proved by #152. It is now bounded from below as well, at twice the stall bound, or the stall can never be reached and every real hang is reported as a ceiling overrun instead, which #112 checks. The RUNNER sets its own, and it was raised from 960 to 1800 on 2026-09-19: the run also fails when its wall clock is more than half the ceiling and its own processor time is what filled it, so 960 put that refusal at 480 seconds, and the sync suite measured 470 on main that day and 485 on a branch adding one section. Main was about ten seconds from red with nothing having changed, and the workflow's own comment still recorded the run as "roughly 200 seconds" from 2026-08-30 (L210, L244). 1800 is roughly 3.7x the measured 485, which puts the refusal back at 900, about 1.9x the real run, and leaves 840 seconds over the 480 second stall bound where 960 sat exactly on its floor. The raise did not hide that growth: #492 tracked the runtime and closed on 2026-09-19 by adding a section time budget that scales with the ceiling (#501), so the section times are now totalled undivided and held to a fraction of whatever ceiling a machine was given, which speaks long before this wall clock number does. The suite itself is not faster, and the budget is what watches it, proved by #167 | 2026-09-19 |
| 20 minutes | `SUITE_STALL_TIMEOUT=1200` | A suite run is killed as hung after this long without reaching a new section | This is what actually catches a hang. Re-measured 2026-08-22 across four loads on this Mac: the slowest single section was 44s idle, 62s with another full run competing, 88s with three of them, and once 208s, so this is at least 5.7x the worst observed and 13x the heaviest load that could be reproduced. It was 600 against a 34 second measurement, and at 3x that floor sat at 624 while the real spread reached 208, so the bound and its floor had met in the middle of the distribution they judge and a busy afternoon turned the run red with nothing wrong (L172). The bound moved rather than the floor, since the floor is the safety margin and the margin was the thing that had gone. Checked against the sections this run ACTUALLY took rather than against this sentence, and every run now PRINTS the margin it achieved so the next shrinkage is seen before it fails, proved by #152 and #179 | 2026-08-22 |
| 30 minutes | `SUITE_LOCK_MAX_AGE=1800` | A suite lock from another machine is broken | The same runs, so at least 6x the slowest observed, proved by #32 | 2026-08-21 |
| 4 hours | `SYNC_SCRATCH_MAX_AGE=14400` | Scratch counts as abandoned | 4x the 3600 second suite ceiling, so the longest permitted run is a quarter of the way to being swept, and 2400x the 6 second sync. It was 3600 against a 900 second ceiling, which was the same 4x, and #152 raised the ceiling alone and closed the margin to nothing. The two are now compared against each other by a check rather than by this sentence, proved by #160 | 2026-08-22 |
| 30 minutes | `SYNC_HOOK_TESTS_TIMEOUT=1800` | A run that received config stops waiting for the hook suite it just installed and reports that nothing was verified | Measured 2026-08-22: the full hook suite took between 220 and 441 seconds on this Mac, the slowest of those while forty other suites competed for it, so this is at least 4x the worst observed. Generous on purpose in the other direction too: this wait holds the sync lock, and a deadline that fires on a loaded Mac would report a healthy run as an unverified one on exactly the days the machine is busy, proved by #178 | 2026-08-22 |
| 10 minutes | `SYNC_SEND_TESTS_TIMEOUT=600` | A send stops one of the suites covering the hooks it is about to publish, with everything it started, holds back the hooks it covers, and says the suite did not finish in time | Bounded against the suites this gate can actually launch rather than against the whole set, because it runs only the suites naming a changed hook. Measured 2026-09-02 on this Mac, the slowest single suite in the tree is `test-claude-sync.sh` at 135s idle and 211s under a full parallel run, so this is roughly 3x the worst single suite observed. It cannot be the 1800s the full-suite deadline uses: this wait holds the sync lock on every hook edit rather than once per pull, and a send that hangs for half an hour blocks delivery in both directions, proved by #244 | 2026-09-02 |
| 10 seconds | `SYNC_SUITE_STOP_GRACE=10` | A suite stopped at `SYNC_SEND_TESTS_TIMEOUT` or `SYNC_HOOK_TESTS_TIMEOUT`, whose tree has already been killed, is killed outright if it has still not ended | Its tree is killed BEFORE it is asked to end, so all that is left for it is its own EXIT trap, which in every suite here removes scratch. Measured 2026-09-19 on this Mac with the #464 fixture (an EXIT trap, blocked in a command substitution with a child of its own): the whole stop, from the 1 second deadline to the send returning, took 1457ms, so the suite ended well under a second after being asked. 10 seconds is over 10x that, and it stays small on purpose because this wait holds the sync lock; a suite that runs out of it loses only its own scratch cleanup, which `reap-scratch` sweeps anyway, proved by #464 | 2026-09-19 |
| 2 weeks | `SYNC_RESOLVED_MAX_AGE=1209600` | A copy of a version dropped by an automatic conflict resolution is swept | Twice the longest real gap between one Mac's syncs, re-derived 2026-08-21 by `tools/measure-sync-gaps.sh` as 6.79 days, so a Mac away for the worst absence ever measured still comes back to find the copy there. It expires rather than being reported until somebody deletes it, because a standing report about a file nothing is at stake in is the nag #177 removed, proved by #183 | 2026-08-22 |
| 2 seconds | `SUITE_POLL_INTERVAL=2` | How finely the suite's watchdog notices a run has stopped, and how long the SUITE_SLOW_IN seam pauses in a section | One number rather than two, because these only mean anything relative to each other: the pause exists to keep a run moving faster than the watchdog can call it stopped, and they were two constants three hundred lines apart. Neither deadline is affected, both being read off a clock, so what this sets is the smallest stall the suite can STAGE. Unchanged from the constants it replaces, so a production run polls exactly as it did. The three sections that prove the deadlines set it to a tenth and scale their bounds with it, which took #152 from 35 to 13 seconds of section time measured 2026-08-30, proved by #152 | 2026-08-30 |
| 0.1 seconds | `SYNC_POLL_INTERVAL=0.1` | How finely claude-sync notices that the hook suite runner it started has ended, and that a held sync lock has been released | Beside a hook suite measured between 220 and 441 seconds, the difference between this and the two seconds it replaces is invisible, and the granularity was never load bearing. It is the whole cost in the test suite, where real pulls run against a stub runner that returns in milliseconds: measured 2026-08-30, a pull noticed such a runner 306ms after it finished against 4,203ms at a four second poll. No deadline moves with it, both being measured against the clock, which had to be made true of the lock's own ceiling in the same change because that one was counting turns of its loop, proved by #205 | 2026-08-30 |
| 1 nested run | `SUITE_MAX_DEPTH=1` | The suite's own depth allowance | Every place the suite spawns itself is one level down and nothing in it legitimately needs a run nested two deep, proved by #34 | 2026-08-17 |
| 20 minutes | `SUITE_WALL_DEFAULT=1200` in hooks/lib/suite-deadline.sh, the limit every suite arms with, overridden for one run by `SUITE_WALL_TIMEOUT` | Any suite, started directly or by the runner, is stopped as hung, and everything it started is killed | One number for all of them, derived from the slowest suite that takes it. Measured 2026-09-18 on this Mac: test-run-all-tests.sh, the slowest of those, took 89 seconds alone at load 6 and 70 to 76 seconds with three copies at once at load 25. Re-read 2026-09-19 from the runner's own timings store (~/.cache/claude-config/suite-timings), where the slowest suite armed with this default is test-run-all-tests.sh at 90 seconds and the next is test-subagent-issue-harvest.sh at 62, so every other suite has more headroom still. The worst slowdown on record is 5.6x, the sync suite's 348 seconds idle against 1943 at load 160 to 188 on 2026-08-22, which would put the slowest of these near 500 seconds, so the limit is 13x its idle time and 2.4x that worst case. Before this only one suite had a bound at all, and 152 copies of that one were found at zero CPU the day it was measured, the oldest seven hours old. tests/test-claude-sync.sh is the one suite that does NOT take this default: it legitimately runs for 1943 seconds under load, so it arms at its own `SUITE_TIMEOUT` plus 60 seconds, which is 30 of its watchdog's 2 second polls, so the watchdog that can name the section it stopped in is always the one that speaks at the ceiling, proved by #444 | 2026-09-19 |
| 30 seconds | `SYNC_SCRATCH_DU_TIMEOUT=30` | A `du` sizing abandoned scratch is stopped and the size is reported as not known | Measured 2026-09-18 on this Mac: one `du` over 792 flat scratch items holding 950 MB in 12,124 entries took 0.2 seconds, so this is 150x that, and the 1,139 items and 1.4 GB the pile left would be under a second at the same rate. A `du` still going at 30 seconds is reading a tree something is writing, and the four found that day had run 23 to 51 minutes, proved by #444 | 2026-09-18 |
| 1 hour | `SYNC_SUITE_MAX_AGE=3600` | `status` and the per prompt notice report a suite process of this repo as left running, and name it for `kill -9` | Equal to `SUITE_TIMEOUT`, the ceiling of the slowest suite there is, which is the longest any suite is allowed to run at all. The slowest real run on record is that suite's 1943 seconds at load 160 to 188 on 2026-08-22, so a healthy run never reaches it. The pile of 2026-09-18 had 354 processes past 40 minutes and one at seven hours, proved by #444 | 2026-09-18 |
| 8 runs | `SYNC_SUITE_MAX_ROOTS=8` | `status` and the per prompt notice report this repo's suites as a pile when more than this many were started independently | The runner's own ceiling on what one whole run has in flight, `HOOK_TESTS_BUDGET`, which is the cores capped at 8. A whole run of the runner is ONE independent start, since everything under it is nested. Measured 2026-09-18: three suites started directly at once read as three, so this leaves room for a few agents each running a suite or two, proved by #444 | 2026-09-18 |
| 10 minutes | `SYNC_SUITE_PILE_REARM=600` | The per prompt notice that this repo's suites have piled up treats a pile as a new stretch, and says it again in a session, only after this long without one | A chosen number, not a measurement: long enough that suites starting and finishing around the breadth limit read as one stretch, short enough that a pile killed and rebuilt the same afternoon is said again. The notice runs on every prompt in every project, so its cost was measured with it, 2026-09-19 on this Mac at 944 processes and load 5: 58ms median, 60ms p90 and 162ms max over 200 prompts with no pile, of which `ps` alone is 37ms median; with a 559 process pile added to that table as a fixture, 32ms median and 43ms max over 100 (no `ps`). Both are far inside the hook's 5 second timeout, proved by #466 | 2026-09-19 |
| 2 processes | not a setting | One healthy watcher | Observed directly as a launcher with one child (pid 13658 with 13702), proved by #33 | 2026-08-17 |

The two suite figures above were 123 seconds and "roughly 7x" for eleven days, written down
2026-08-21, when the suite had 726 checks. It now has 784, and the run time has been 123, then 267, then 191 seconds as
checks were added and one of them was made five times faster. Every one of those figures was true
when written and wrong within days, and nothing noticed, because the check beside this table
compares the SETTING and not the measurement the setting was derived from. So the suite measures
ITSELF at the end of every full run and says whether the ceiling still has room over what that run
actually took. That number cannot go stale because it is not recorded anywhere.

What that self-measurement judges changed in #161. It was a floor of twice the run's own PROCESSOR
time, which was right while the ceiling was what caught a hang. #152 moved that job to
SUITE_STALL_TIMEOUT and raised the ceiling fourfold in the same change, and the floor went from
1.7x to about 7x: 262 seconds of processor time against a 3600 second ceiling, so the suite would
have had to grow sevenfold before it said anything. It was not wrong, it just could not fire, and
a check that cannot fire stops being read. The measurement now judges the WALL CLOCK, which is what
the ceiling actually bounds, and uses the processor time to say which of two different things is
happening: a run filling its own clock with its own work has grown into its deadline and fails,
while one merely waiting on a busy Mac gets a note naming the load. Both were measured on the same
tree on 2026-08-22, at 348 seconds idle and 1943 under load with only 262 of those seconds its own.

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

## Config waits for CI before it installs itself on the other Mac

Decided 2026-09-03 (#221), by Dan, from three options.

The automatic receive used to integrate whatever was on the shared repo as soon as it had a reason
to, which is before anything had judged it. 32 of 233 CI runs in the 30 days to 2026-08-29 were
red, almost all on direct pushes to main, so config that fails CI installed itself on the other Mac
FIRST and was caught only by the suite that runs after installation. Three pushes in one session on
2026-09-03 were green on a Mac and red on the Linux runner, and every one of them would have landed
there.

**The rule.** The fswatch WATCHER integrates a commit only when its checks are green. A `pull` or
`sync` typed by a person is not gated, which is the escape hatch, so there is no flag to remember
and no way to be stuck. Neither is the weekly receive timer, deliberately: a CI wait of a few
minutes is noise against a week.

**How the gate is turned on, since this paragraph said otherwise for a week.** It said the timer
was gated too, by a plist carrying `SYNC_AUTOMATIC`. Nothing writes that variable and nothing reads
it: `writeplist` puts only `PATH` in a plist's environment, and the gate turns on because
`watch_tick` sets `SYNC_IN_WATCH` itself, inside whichever `claude-sync` the job runs. The sentence
sat beside numbers that were checked and re-measured, which made it more trusted rather than less
(L210, L244), and claude-config#280 was filed on it: a whole issue about a per Mac divergence that
could not happen, because an old PLIST is not the thing that carries the gate.

What CAN diverge is which `claude-sync` a job runs. A plist records an absolute path and this Mac
has more than one clone, so a job pointed at a clone that has not been updated runs a copy with no
gate. `claude-sync status` now says which of the two launch agents are installed, which copy each
one runs, and whether that copy has the gate, so the question is answered by running one read-only
command on each Mac rather than by opening a plist. Red, still running, cancelled and unreadable each get their own sentence and their own
`SEND-OUTCOME` marker in the watcher's log, because they need different remedies: a run still going
resolves itself, a cancelled one never will, and unreadable is about `gh` on the receiving Mac
rather than about the commit.

It fails closed. Unreadable and "no check at all" skip the pull and say so, because a control that
protects somebody fails closed rather than open (L42), and because green and "nobody could tell"
must never be the same answer (L98).

**The premise, in a form that can be re-measured** rather than believed (L316). The wait this buys
is one CI run:

    gh run list --limit 20 --json startedAt,updatedAt

which priced at about four minutes on 2026-09-03, against a red commit being live on the other Mac
for the three to four minutes until its own suite says so, and longer if nobody reads the
notification. The red rate is:

    gh run list --limit 200 --json conclusion --jq '[.[].conclusion] | group_by(.) | map({(.[0]//"running"): length}) | add'

If CI becomes slow enough that the wait costs more than the exposure, or the red rate falls far
enough that there is nothing to protect against, this is the trade to look at again. Re-measure
those two numbers rather than re-reading this paragraph.

**A commit with no check at all** is not a failure, it is nothing to fail, and it is applied
(Dan, 2026-09-03). The catch is that "no run yet" and "no run ever" are the same empty answer for
the first minute of a commit's life, and reading the young one as green would defeat this gate in
exactly the common case: a push whose run has not been created yet. So a commit is read as unjudged
only once it is older than `SYNC_CI_GRACE`, ten minutes by default, and until then it waits. Being
applied unjudged is said out loud in the watcher's log rather than passing silently.

**What is deliberately NOT gated.** The weekly receive timer only gets the gate once
`install-autosync` has been re-run on a Mac, because the marker lives in the plist it writes. A
four minute CI wait is noise against a week, so an old plist is not worth chasing. And the gate
asks about the head of the branch, not about each commit between: a red commit followed by a green
one is applied with the green one, which is what a person pulling by hand would get.

## The hooks block is merged in BOTH directions, against the same base

`settings.json` is not mirrored like the rest of the config. Its `hooks` block is extracted into
`payload/settings.hooks.json` on the way out and merged back into `settings.json` on the way in, so
it is REGENERATED at both ends rather than copied. That puts it outside every protection the
mirrored files get, including the locally-ahead hold-back, and the protection has to be written
again for each direction.

The rule, in one function both callers use: the result is the PRIMARY side, plus every entry in the
SECONDARY side that is in neither primary nor the BASE. The base is the hooks block of the commit
this Mac last applied. An entry missing from primary but present in base was deliberately removed
and stays removed; one missing from both is something the other side has not seen yet and is kept.
With no base at all, keep, in both directions.

On the way IN, primary is what is arriving. That half was written in #13, after replacing the block
wholesale silently unregistered a hook added here since the last send: the hook script itself was
held back as locally ahead, but the line that activates it was not, so the hook shipped inert.

On the way OUT, primary is what is registered here. That half was missing until #300, and it failed
in exactly the mirror image. `stage_local_to_payload` rebuilt the payload's copy wholesale from
`~/.claude/settings.json`, and it runs BEFORE the apply, so anything the payload already held that
this Mac had not applied was destroyed. Traced on 2026-09-03: `eb6ce56` registered
`payload-revert-warning.sh`, and `f0cd3c7`, a sync commit, deleted exactly those five lines and
touched nothing else. The hook and its test both travelled; only the registration was lost.

`send` alone was already safe, because it refuses outright when the repo holds changes this Mac has
not applied. `sync` cannot refuse, because reconciling is what it is for, and its send half runs
first. That is why the merge belongs in the staging rather than in a guard above it.

## A conflict in a file this tool GENERATES is not a conflict

The lessons index is derived: it is rebuilt from `LESSONS.md` on every send and every apply. When it
was one file its header carried a lesson count, and both Macs rewrote that one line, so any two
sided lesson addition made the generated files differ and git stopped, even when the lessons
themselves merged perfectly well. The split into one file per section (claude-config#473) took the
count away, so a conflict now needs both Macs to have moved the same section, which is an ordinary
week rather than a certainty.

There are two defences, and the second exists because the first cannot always be in place.

The clone is told never to combine these files, with a `merge=ours` rule written to
`.git/info/attributes`. That is per clone and never travels, which is deliberate (it is in force on
the first run on a clone rather than only once a committed file has arrived), and it is also the
limitation: a clone that has not yet run a version of this tool that writes it does not have it,
and not every rebase backend consults it.

So when the conflict happens anyway, the rebase is not abandoned. If EVERY conflicted path is a
derived file, each is regenerated from the source sitting beside it in the working tree, staged,
and the rebase continued, and the run says it did that. One conflicted path that nobody generates
and none of this happens: continuing then would commit whichever side git happened to leave, so the
stand down is no broader than its reason (L324). A rebase stopped with no conflicted path at all is
refused too, because that is not this.

The regeneration rebuilds EVERY generated file, and before anything is staged each conflicted path
is read for a leftover conflict marker and the whole recovery refuses if one is there. That guard
is the reason this survived the split into one file per section: the old code regenerated exactly
one file and then staged every conflicted path, which was safe only while exactly one path was ever
generated. A second conflicted sibling would have been committed carrying its markers into a file
that loads into every session in every project.

Measured 2026-09-03: five new lessons here against twenty commits there, `payload/LESSONS.md`
merged cleanly, `payload/LESSONS-INDEX.md` was the only conflicted path, and the sync died telling
Dan to reconcile by hand, which is not something he can act on. `SYNC_DERIVED_MERGE_RULE=0` turns
the first defence off, which is the only way to reach the second one in a test.

### And when the lessons file itself conflicts

The day after, the other shape turned up: L396 appended at the end of "Proof over green" on one Mac
against L588 appended at the end of the same section on the other. `payload/LESSONS.md` is a
source, not a derived file, so both defences above stood down and the sync died the same way.

Two appended entries carrying different numbers never contradict each other, so the recovery now
combines them: it takes the three sides git holds mid rebase, unions them, drops an entry both Macs
wrote identically, and refuses if the result uses one number for two different entries. That last
case is not a merge failure and is not something to reconcile: it says which number clashed and
tells Dan to renumber, which is a remedy he can act on.

There is deliberately NO union merge rule in `.git/info/attributes` for the lessons file, and that
is the whole reason the work happens in the recovery. A rule resolves the file inside the rebase,
which is before anything can look at the result, so the one case that must stop the sync would be
committed and pushed as two entries under one number, past the stage time duplicate check, which by
then has nothing left to refuse. Doing it in the recovery keeps the union and the refusal in the
same place, at the moment the rebase can still be abandoned, and it needs no per clone config, so
it is in force on a clone that has never run it and under every rebase backend.

## A merge has to reach the repo before the sync says it worked

Measured 2026-09-04. A reconcile merged `LESSONS.md` and printed both "nothing was dropped" and
"Synced (sent local changes, pulled remote)". Both sentences were true about the live copy under
`~/.claude`, which held 472 lessons, while the copy committed in the repo held 468. Four entries
existed on one machine only, so the other Mac would never have received them and anything
overwriting that file would have destroyed them. The regenerated index made it worse by sitting in
three states at once: 463 committed, 468 uncommitted in the payload, and 472 live.

The mechanism is the order rather than the merge. Staging holds back a path this Mac has not
applied yet, so the local entry is not published; the pull brings the other Mac's version; and the
apply merges the two into the live file, which by then nothing sends.

So the sync path stages and pushes what the merge produced, through the one path that publishes
anything, and then reads the repo back and refuses its closing line until the entries are there.
The comparison is on entry labels rather than whole lines, because re-wrapping a paragraph changes
every line boundary and loses no words (L278). Committed but not pushed is reported as its own
state, because the next send carries it and calling that published would be the same false success
one level along. The pull path does not send, so it says the merge is local until the next send
rather than leaving that to be inferred.

## Editing the payload in the development checkout is reverted by the daemon

Measured 2026-09-03, the hard way. Most of a day's work on the payload was made in the development
checkout and pushed to GitHub. At 11:03 the watch daemon on the SAME Mac mirrored its `~/.claude`
up into the payload and reverted 84 files in one commit: a whole style sweep, two finished issues,
part of a third, and `lib/match-open-issues.py` was DELETED, because a file that exists only in the
repo is a file the mirror has never heard of and the mirror runs with `--delete`.

The mechanism is not a bug. `~/.claude` is the source and `payload/` is its mirror, and the daemon's
job is to make the second match the first. A change made in the mirror is not merged with the
source, it is overwritten by it, silently, with no conflict to notice: this is not the two Mac
merge, and none of the machinery that protects against THAT applies, because both copies are on one
machine and only one of them is the source.

**So: edit `~/.claude`, or hold the daemon.** `claude-sync hold 120 "why"` stops the automatic send
for two hours and `claude-sync release` ends it early. A session that is going to edit the payload
in the checkout should take a hold first, and afterwards make `~/.claude` match, or the next send
reverts it again. What makes this worth writing down rather than remembering is that the failure is
silent in both directions: nothing warns before the revert, and afterwards the tests pass, because
the tests were reverted along with the code they covered.

**And now something says it.** The paragraph above was, for a week, a rule in prose, which is a
hope (L27). `payload/hooks/payload-revert-warning.sh` runs on UserPromptSubmit and speaks when all
of it is true at once: the prompt came from a directory inside a clone of this tool, a watch daemon
is live, that daemon is not running from this clone, and no hold is in force. It names the
checkout, the clone the daemon runs from, the hold command, and the part a hold does not solve,
which is that `~/.claude` still has to be made to match afterwards. The state it speaks about
includes the hold, so a hold that EXPIRES while a session is still editing brings the notice back:
that is the same loss with a delay on it, and nothing else would report it.

It WARNS rather than refusing, which is a decision and not the easier option. Every PreToolUse hook
in this config matches Bash, and the edits here are made through Bash, where a refusal would have
to parse shell text or refuse a whole category of command, and the second deadlocks the moment the
remedy is itself a command (L362). A notice on the prompt arrives before any edit route, costs a
`ps` and two small file reads, and addresses what was actually lost, which was a day of work rather
than one edit.

The recovery, if it happens again: find the sync commit (`git log --author=claude-config-sync`),
take the file list it touched, and check those paths out of the commit BEFORE it, keeping
`LESSONS.md` and its index, which carry the other Mac's real additions.

## The hygiene guards judge what a push adds, never a stored baseline

Decided 2026-09-18 (#428 to #433), against the shape the issues themselves proposed.

The issues asked for a copy and paste detector (jscpd) with a per repo ratchet baseline. Both were
dropped. A dependency the guard installs on first run is a network fetch inside a push gate, and a
baseline is a file inside somebody's project that has to be written, committed and kept, which is
the "something to remember" Dan ruled out. So every guard but one compares the pushed tree against
its merge-base and fails only on what the push introduced. The cost is stated in each header: a
change that edits every copy of an existing duplicate identically reads as new content, and a
stale doc sentence is only re-judged when its file is touched.

The bundle budget is the exception, because a build output is not in git and has no base to diff
against. Its record lives under `~/.claude/state/bundle-budget/`, keyed by the remote URL, on the
Mac that measured it. The record only ever moves down or is explicitly accepted, so growth inside
the margin cannot creep the budget up one push at a time.

### The advisory review is detached, and reads whole files

A review through `claude -p` measured 130 to 193 seconds on 2026-09-18. Run inside the push hook that is a two
to three minute wait on every push, which is the wait Dan refused; run as a blocking gate it
teaches people to set the skip variable. So the PostToolUse hook writes a pending marker, starts
the runner in its own process group and returns; a UserPromptSubmit hook prints the finished
review once per session. The first real run answered "No issues found." on a fixture where a
function's twin had been left unchanged, correctly, because a diff never shows the unchanged
sibling. The input is now the diff followed by the full text of each changed file while a 300 KB
budget lasts, and the same fixture is then caught.

### What the thresholds measured

Each is in its hook header with the date; the two that decided a design are here because they cut
against the issue text. The duplication floor of 160 characters for a block leaves Slate's day
header cell (131 characters) uncaught, because 130 refuses 10 of the last 40 real pushes and 160
refuses 4, all genuine. The deferral list dropped "later" (362 hits across Slate, at most two
deferrals), "not yet" (32, none) and "eventually" (25, none), and narrowed "deferred" to "deferred
to", "deferred until" and "deferred pending" because Slate uses the bare word for work handed off
after a response. The doc reference guard anchors every phrase to the issue number and vetoes a
past tense verb, because a first draft matching the phrase anywhere in the sentence named 50
issues of which 44 were closed and about 10 were genuine pending claims.

## What native path scoped rules do at user level

Measured on 2026-09-19 against Claude Code 2.1.278, because #394 wanted instructions that load only
when they are relevant, and the hook that would have delivered them is capped at 10,000 characters
(`PJr=1e4` in the binary), past which the output is written to a file and replaced by a preview.
Claude Code ships the same idea natively: a markdown file under `~/.claude/rules/` carrying a
`paths:` frontmatter list loads only when Claude reads a file matching one of its globs. The open
question was whether that holds for USER level rules rather than a project's own `.claude/rules/`,
since the documentation puts user level rules and path scoped rules in separate subsections and
never says the first is subject to the second. #474 answered it.

The method was two instruments, so that neither the model's judgment nor the transcript alone had to
carry a result. Throwaway rules went in `~/.claude/rules/`, each asking for a distinct token in the
reply, and headless `claude -p` sessions read fixture files in a scratch directory. The
`InstructionsLoaded` hook, configured through a `--settings` file so nothing permanent changed,
fires with a `load_reason` of `path_glob_match` and names the rule file, which is a signal no model
can refuse; the session transcript under `~/.claude/projects/` stores the injected text verbatim,
which is how the delivered size was read. The rules were deleted and the directory removed after.

**Path scoped rules are honoured at user level.** Reading the matching fixture logged
`path_glob_match` on the canary in `~/.claude/rules/` and the reply carried its token. Reading only
a non matching fixture in the same project logged nothing, so the negative control separates the
rule firing from the rule merely existing.

**Patterns resolve against the project root, anchored, and an absolute path matches nothing.** A
pattern of `src/api/**/*.ts` fired on `src/api/service.ts` and did not fire on
`deep/src/api/nested.ts`, so it is anchored at the root rather than matched as a suffix anywhere in
the tree. A rule whose `paths:` entry was the fixture's full absolute path never fired at all, while
a `**/*.ts` rule fired on that same file in the same session, which is the control that makes the
absolute result a fact about the pattern and not about the file. The consequence for user level
rules is the useful one: a rule in `~/.claude/rules/` cannot be scoped to one project by path,
because the only patterns that work are repo relative and therefore mean the same shape of file in
every project on the machine.

**A rule reaches a subagent, triggered by the subagent's own read.** The parent was told to read
nothing and to delegate; the subagent read the matching file, the hook logged `path_glob_match`, the
subagent's own sidechain transcript under `<session>/subagents/` holds the injected reminder, and
the subagent's report back carried both tokens. This is the one that was least predictable from the
documentation, which describes what a subagent inherits at startup and says nothing about a rule
armed by a read inside it.

**A rule does not survive compaction, and re-arms on the next matching read.** After a manual
`/compact` of a session that had loaded the rule, a turn that read no file logged no rule load and
carried no token, even though the model still recalled from the summary which file it had read. The
next turn in the same session re-read the matching file, and the rule loaded again. So the rule is
attached to the read, not to the session, which is the behaviour wanted here: nothing has to be
re-injected after a compaction, it comes back by itself the next time it is relevant.

**There is no truncation at the hook's cap.** A canary rule of 169,464 bytes, 900 filler lines
long, arrived whole on 2026-09-19: the transcript holds a single reminder of 169,533 characters,
every filler line present, and the instruction written at the very end of the file intact and
quoted back by the model. The 10,000 character cap that governs hook output does not apply to
rules. The documented limits are different and much higher: a file over 4 MiB is skipped, and the
guidance to stay under 200 lines is about adherence and context cost rather than a cut.

Two cautions came out of it that the documentation does not mention. The rule arrives mid session as
a `<system-reminder>` reading `Contents of <path>:` followed by the body with the frontmatter
stripped, attached to the Read result; because it appears without warning and claims to be file
contents, a rule asking for something arbitrary can be read as a prompt injection and refused, which
happened in two of the runs and not in the others. A rule whose instructions are ordinary domain
guidance does not invite that, but the arrival of a rule is reliable in a way that compliance with
it is not. And the `InstructionsLoaded` hook is the only honest way to tell the two apart, because a
reply missing the token cannot distinguish a rule that never loaded from one that loaded and was
disregarded.

The lessons sections looked like a candidate for this, with the caveat above about scope: a rule
keyed on `**/*.tsx` loads the UI lessons in every project, which is what is wanted, and a rule
cannot be narrowed to one checkout.

**Moving the lessons to path scoped rules was planned and REJECTED on 2026-09-23** (the plan-lite
red team and lessons audit behind milestone 16, recorded by #541 so nobody rebuilds it). Three more
facts decided it, measured on 2.1.281. A path scoped rule arms only on the Read tool: `cat` through
Bash, Grep, and a Write of a new file never arm it, and Edit does only because it reads the file
first. `InstructionsLoaded` carries no `agent_id`, so a hook cannot tell which agent a rule reached.
And the saving was not there: coding sessions would still have loaded 81 to 94 percent of the
lessons, while sessions driven through Bash or an MCP server, which open files without the Read
tool, would have lost the lessons entirely. Interactive sessions therefore keep every lesson, and the saving is taken where nothing
reads them: the headless runs hooks start, which switch the global config off or say why they keep
it, enforced by `hooks/test-headless-claude-config.sh` (#538).

## Things known to be wrong and left that way

Markers are keyed on hostname, which is a mutable string. Renaming or reinstalling a Mac abandons
its marker rather than moving it. #26 sweeps up the orphans a rename leaves rather than carrying
the old marker forward, so renaming a Mac still loses its history, it just stops shouting about it.

A run killed by the deadline cannot release its lock, and nothing tries to on its behalf. The next
run finds a process that is gone and takes over saying so, which is the same path a crash needs and
is therefore the path worth having work.
