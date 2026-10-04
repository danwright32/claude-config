---
name: disk-full
description: Use when the Mac is out of disk space or close to it, when Bash calls start failing with ENOSPC or "cannot create temp file", when a hook fails for no apparent reason and the disk is suspect, or when the low free space warning fires. Holds the measured triage sequence, read only apart from one clearing command for Dan to run, in the order that finds the cause fastest.
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

Two readings, several minutes apart, never one. A rate is the whole diagnosis: 19 GB an hour is
something actively staging files, and no amount of deleting will keep up with it until it is
stopped.

```bash
df -k /System/Volumes/Data | awk 'NR == 2 { print strftime("%H:%M:%S"), $4 / 1048576 " GB free" }'
```

Run it, wait five minutes, run it again, and subtract. The session's own low space warning keeps a
rolling history and reports this rate itself, so if it has already fired, read its sentence rather
than measuring again.

### 3. Where the weight is

```bash
du -x -d 2 -g ~ 2>/dev/null | sort -rn | head -30
```

`-x` keeps it on one filesystem, so it does not wander into a mounted volume or a network share
and report their sizes as yours. `-g` is gigabytes, which is the unit the answer is in. It is slow
on a large home directory; let it finish rather than narrowing too early.

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

**Backblaze.**

```bash
sudo du -x -d 1 -g /Library/Backblaze.bzpkg/bzdata 2>/dev/null | sort -rn | head
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
it is large. This is the one command in the sequence that deletes anything, and it is for Dan to
run, never for Claude. The folder carries no SIP restricted flag, so `sudo` can empty it. `find
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
disk; a folder growing between two readings is.

## Deleting anything

Everything above is read only on purpose, except the one clearing command in step 5, which is
Dan's to run once he has seen the size. Before removing anything:

- Say what you propose to delete, how much it frees, and what regenerates it.
- Stop the thing that is writing first. Deleting under an active writer frees space that is
  reclaimed within minutes and hides the cause.
- Never delete from a sync or backup client's own store to free space. Change its scope or pause it
  in its own interface, because its store is the client's record of what it has done and removing
  it by hand leaves the client repairing itself, which writes more.
