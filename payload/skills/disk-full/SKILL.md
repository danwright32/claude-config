---
name: disk-full
description: Use when the Mac is out of disk space or close to it, when Bash calls start failing with ENOSPC or "cannot create temp file", when a hook fails for no apparent reason and the disk is suspect, or when the low free space warning fires. Holds the measured triage sequence, read only apart from two clearing commands that run on Dan's decision (one, the Xcode build cache sweep, he has let the low space warning run on its own), in the order that finds the cause fastest.
---

# disk-full

A full disk is the one state where the tool that would diagnose it cannot run. On 2026-09-10 the
boot volume hit zero, and the first sign inside Claude Code was `hooks/check-project-list.sh`
failing with `cannot create temp file for here document`, followed by every Bash call failing with
ENOSPC before it could run. Reaching the actual cause took about forty minutes, most of it
rediscovering the sequence below. It is written down so it does not have to be found again.

On 2026-10-04 the disk fell from 25 GB to 8 GB free more than once while several Overture agent
sessions built and crash tested. Neither the low space warning, nor this sequence, nor Overture's
DerivedData reclaim could see why, because the cause is a root only folder that no command here
could read: `/System/Library/Caches/com.apple.coresymbolicationd`, macOS's symbol cache, at 194 GB.
Dan's cleaner app found it. That is step 5.

## Before anything else

**If Bash itself cannot write its output file**, no command here will run. Ask Dan to type the
command himself with the `!` prefix, which runs it in the session and puts the output straight into
the conversation. Say that plainly rather than retrying a command that cannot work.

**Free space first, and never guess a cause from a single number.** A static size says the disk is
full. It does not say what is filling it, and the difference decides what to do: something still
writing needs stopping, while something that already wrote needs deleting. Take two readings.

## The sequence

### 1. How much is left, and on which volume

```bash
df -h /System/Volumes/Data /
```

`/System/Volumes/Data` is where a Mac's home directory actually lives. `/` is the read only system
snapshot and reports headroom that has nothing to do with anybody's files, so a reading taken from
`/` alone can look healthy while the disk is full.

### 2. Whether it is still falling, and how fast

Two readings, ten or more minutes apart, never one. A rate is the whole diagnosis: 19 GB an hour
is something actively staging files, and no amount of deleting will keep up with it until it is
stopped.

The session's low space warning already takes a reading on every prompt and keeps the last six
hours of them, so ask it rather than measuring a second way:

```bash
bash ~/.claude/hooks/check-free-space.sh --report; echo "exit $?"
```

It adds a reading to that history and says how much is left, then either the rate and how long
until zero, or why it states no rate yet (the first reading, readings too close together, free
space having gone back up, or not falling at all). Judge it by the exit code, not the wording:
0 means there is room and no fall reaching zero within six hours was measured (with no rate stated, nothing about the trend was measured yet), 3 under the 20 GB floor, 4 falling fast
enough to reach zero within six hours, and 2 that it could not measure, which is not the same as
fine. When it says no rate yet, take the next reading on a later turn, ten or more minutes on,
rather than waiting inside a command.

### 3. Where the weight is

```bash
du -x -d 2 -g ~ 2>/dev/null | sort -rn | head -30
```

`-x` keeps it on one filesystem, so it does not wander into a mounted volume or a network share
and report their sizes as yours. `-g` is gigabytes, which is the unit the answer is in. It is slow
on a large home directory; let it finish rather than narrowing too early.

**A `du` figure is an upper bound on what a folder costs, never a measurement of it.** `du` adds up
the size of every file it reaches. On APFS a file can be a clone, a copy that shares every block
with its original until one of them is written, and `du` counts each clone at its full size although
it costs the disk almost nothing. A hard linked file is counted once inside one `du` run, but in
full again by every separate run that reaches it, so two `du` commands over neighbouring folders
can each claim the same bytes. Deleting a clone or one link of a file frees almost nothing.

So a folder growing between two `du` readings is real growth only when `df`'s free space (step 1)
fell by about the same amount over the same interval. When `du` says a folder grew by tens of
gigabytes and `df` says the disk did not lose them, the folder is not the cause, however neatly its
timing fits.

**A known false lead: Chrome's code signing clones.** Chrome makes a clone of its whole app bundle
under `/var/folders/*/*/X/com.google.Chrome.code_sign_clone` (the per user folder
`getconf DARWIN_USER_CACHE_DIR` names, with `X` in place of its last `C`) each time it
launches, and a Chrome that is force quit leaves its clone behind. On 2026-10-08 `du` counted 114 of them at about 1.5 GB
each, apparently 60 GB of growth in five hours; deleting 90 of them freed 0 bytes by `df`. They are
clones of Chrome.app, so they cost almost no real space. Rule this folder out rather than in. Most
of those came from design rounds' headless Chrome, which since claude-config#988 is told not to make
one (`--disable-features=MacAppCodeSignClone`, in `skills/design-rounds/headless-dom.sh`). Of the
288 found from 2026-10-20 to 22, every one whose launcher was traced (19, in two full suite runs on
2026-10-22) came from the design score's Playwright runs, which since claude-config#1537 start
Chrome through that same file.

### 4. The sync and backup clients, before anything else you find

These are the ones that fill a disk while looking idle, and they are the first place to look
whatever step 3 said, because their staging areas are often outside the home directory and often
newer than anything `du` ranks highly.

**Synology Drive.** The 2026-09-10 cause: a backup task with the whole home folder in scope,
staging at about 19 GB an hour.

```bash
du -x -d 1 -g ~/Library/Application\ Support/SynologyDrive 2>/dev/null | sort -rn | head
```

Its session list, which says what each task has in scope:

```bash
sqlite3 -readonly ~/Library/Application\ Support/SynologyDrive/data/db/sys.sqlite "select * from session_table;" 2>/dev/null
```

The staging area, which is what actually grows:

```bash
du -x -d 2 -g ~/Library/Application\ Support/SynologyDrive/data/session 2>/dev/null | sort -rn | head
```

**Backblaze.** Its data folder was readable without a password on Daniels-MacBook-Pro-2 on
2026-10-08 (it is world readable), so this runs as it is. Errors are left showing on purpose: a
"Permission denied" line means the total below it is short, and then the full size needs Dan to run
the same command with `sudo` in front, which is his to run, never Claude's.

```bash
du -x -d 1 -g /Library/Backblaze.bzpkg/bzdata | sort -rn | head
```

**iCloud.** Files evicted from local storage still show in Finder. What matters is what is
downloaded:

```bash
brctl quota 2>/dev/null; du -x -d 1 -g ~/Library/Mobile\ Documents 2>/dev/null | sort -rn | head
```

### 5. The macOS symbol cache, which only an administrator can measure

`/System/Library/Caches/com.apple.coresymbolicationd` is filled by `coresymbolicationd` whenever a
crash report is written or a process is sampled (`sample`, spindump, Instruments). It keeps symbols
per build, so every fresh build of an app that crashes or is sampled adds another copy, and a day of
agents building and crash testing can put well over a hundred gigabytes there. It lives on the data
volume, not the read only system snapshot, so it counts against the free space step 1 reports.

It is owned by root with no access for anyone else, so `du` without `sudo` reads nothing, and step 3
never sees it. Say that plainly rather than reporting it as small or absent. What can be read
without a password is when a file was last added to it or removed from it, which says it is in use
and nothing about its size:

```bash
ls -ld /System/Library/Caches/com.apple.coresymbolicationd
```

Its size needs Dan's password, so hand him the command rather than running it:

```bash
sudo du -sh /System/Library/Caches/com.apple.coresymbolicationd
```

It is a cache macOS rebuilds on demand, so clearing it costs only the time to symbolicate the next
crash reports. Clearing it is Dan's call, as every deletion is, and only once the size above shows
it is large. This command is for Dan to run, never for Claude. The folder carries no SIP restricted flag, so `sudo` can empty it. `find
-mindepth 1 -delete` empties it, hidden files included, and keeps the folder and its root only
permissions; it needs no glob, which Dan's zsh would refuse before `sudo` ran because his user
cannot list the folder:

```bash
sudo find /System/Library/Caches/com.apple.coresymbolicationd -mindepth 1 -delete
```

The low space warning names this folder and both commands itself when its verdict is low or falling
and the folder exists, so if it has already fired that way, those are the same ones.

### 6. The usual large caches, once the above are ruled out

```bash
du -x -d 1 -g ~/Library/Caches ~/Library/Containers ~/Library/Developer 2>/dev/null | sort -rn | head -20
```

Xcode's `~/Library/Developer/Xcode/DerivedData` and `~/Library/Developer/CoreSimulator` are the two
that reach tens of gigabytes without anybody noticing.

DerivedData leaks for a known reason: Xcode keeps one build cache per project path, every agent
worktree, scratch copy and temporary gate tree is a new path, and nothing removes the cache when the
path is deleted. On 2026-10-19 that was 30 folders, about 48.6 GB, all keyed to paths that no longer
existed. A `du` of the folder cannot tell those from caches still in use, so list them with the
sweep, which reads each folder's recorded project path and deletes nothing:

```bash
bash ~/.claude/hooks/derived-data-sweep.sh
```

It groups every folder by what it decided: orphaned (the project path is gone, with size, last
modified date and the path it recorded), orphaned but kept because something in it was written in
the last hour or a running `xcodebuild` names it, no `info.plist` (nothing can say whose it is, so
never deleted), a project on a volume that is not mounted (an unplugged drive, never deleted), and
still in use.

Dan decided on 2026-10-20 (#1369) that the orphans may be deleted on its own: when the low space
warning fires it starts a sweep in the background that removes only the orphans nothing is using,
and the next warning says what that sweep deleted, the `df` gain it measured, or that it failed. So
if the warning has fired, read what the last sweep did before deleting anything by hand:

```bash
bash ~/.claude/hooks/derived-data-sweep.sh --last
```

On a Mac where Dan has set `FREE_SPACE_DERIVED_DATA_AUTO_DELETE=0` the warning only counts them,
and deleting is Dan's decision each time, as every deletion is. When Dan has said to, this removes
only the orphans nothing is using, judging each again just before removing it, and reports the
`df -m` gain beside the `du` figure:

```bash
bash ~/.claude/hooks/derived-data-sweep.sh --delete
```

### 7. Snapshots, which `du` cannot see at all

Space held by local Time Machine snapshots does not appear in any directory listing, so a disk can
be full with nothing to find.

```bash
tmutil listlocalsnapshots / 2>/dev/null
```

## Reporting it

Say the rate before the size, and name what is growing rather than what is big. "Synology Drive is
staging about 19 GB an hour into its session folder, which is why deleting things is not helping"
is actionable. "The disk is full and Caches is 40 GB" is not, because Caches was 40 GB last week
too.

Name no cause you have not measured. A folder being large is not evidence it is the one filling the
disk; a folder growing between two readings is, once `df` shows the disk lost about the same amount
over the same interval (step 3 says why `du`'s growth alone can be no growth at all).

## Deleting anything

Everything above is read only on purpose, except two deleting commands: the clearing command in
step 5, which is Dan's to run once he has seen the size, and the sweep's `--delete` in step 6, which
the low space warning runs on its own (Dan's decision of 2026-10-20) and which by hand runs only
once Dan has decided to clear the orphaned Xcode caches it listed. Before removing anything:

- Say what you propose to delete, how much you predict it frees, and what regenerates it. The
  prediction is a claim about `df`, not about `du`, which overstates anything holding clones or
  hard links (step 3).
- Stop the thing that is writing first. Deleting under an active writer frees space that is
  reclaimed within minutes and hides the cause.
- Never delete from a sync or backup client's own store to free space. Change its scope or pause it
  in its own interface, because its store is the client's record of what it has done and removing
  it by hand leaves the client repairing itself, which writes more.

Then confirm the gain. Take this reading just before the delete and again just after, and compare
the difference with the prediction. It is in megabytes because whole gigabytes cannot tell a gain
of 1.5 GB from none at all:

```bash
df -m /System/Volumes/Data
```

A gain far below the prediction means the diagnosis was wrong. Stop and go back to the readings
rather than deleting more of the same thing: on 2026-10-08 ninety deletions went ahead on a `du`
figure before anyone checked that the first had freed nothing.
