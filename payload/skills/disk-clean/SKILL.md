---
name: disk-clean
description: Clears space on the Mac when Dan types /disk-clean. A read only scan of what can go, one review page where he ticks what goes, one confirm, then removal through disk-remove.sh with the result verified by df. For working out why a disk is full, use disk-full.
disable-model-invocation: true
---

# disk-clean

Dan starts this by typing /disk-clean; Claude never starts it on its own, because it ends in removing
things. The flow is six steps, in order, and nothing is removed before step 4. Every script it
calls says what happened by its exit code, and each step below says what to tell Dan for every code
that script can return (`test-disk-clean-skill.sh` derives the codes from the scripts and fails
when one is missing here). Judge each run by its exit code, never by its last line (L184).

## Before starting

- `<folder>` below is `disk-clean` inside the scratchpad directory this session's system prompt
  names, written out as a full path. Every file of one run goes there: the review page, its nonce,
  the pasted selection and the plan.
- Nothing is ever removed by hand: no `rm`, `mv` or `trash` typed by Claude. Removal is
  `disk-remove.sh`, which refuses sync and cloud stores, app packages, Mail and Messages, keys and
  anything under /Applications or /System, judges each item again just before it goes, and checks it
  really went.
- Claude never runs `sudo` itself. Anything that needs Dan's password is handed to him as one
  command in step 6.

## 1. Scan

Tell Dan the scan has started, that it removes nothing, and that it can take several minutes. Run it
with `run_in_background` and wait for its notification, since each kind is bounded at ten minutes
and the walk of the home folder at fifteen, longer than a foreground call is allowed:

```bash
bash ~/.claude/skills/disk-clean/scan.sh
```

Report what it printed, in plain words, in this order:

1. The Full Disk Access result, first, because it decides how far every figure after it can be
   trusted. Granted needs one line. Not granted means every folder macOS protects was read as
   permission denied rather than as its size, so the figures are short: tell Dan he can turn it on
   in System Settings, Privacy & Security, Full Disk Access, for the app Claude Code runs in, then
   quit and reopen that app and type /disk-clean again. Unmeasured means there was no Mail folder to
   try, so it is not known; say that.
2. Each kind's total: what can go, with its item count, keeping "at least" wherever the scan said
   it, because then part of the kind could not be measured and the figure is a lower bound. A kind
   with nothing in it says nothing was found.
3. Every kind the scan could not measure, by name, stated as unmeasured with the reason it printed
   (timed out, a tool missing, Docker not running), never as zero and never left out, since an
   unmeasured kind may be the large one. A walk that was partial or unmeasured is said the same way,
   with the kinds that read it (build folders, worktrees, runaway logs, forgotten tools and large
   files).

- **Exit 0**: the scan was written, unmeasured kinds included. Report it as above and go on to step 2.
- **Exit 2**: it refused, or its record could not be written, so there is nothing to review. Tell
  Dan the reason it printed and stop.
- **Exit 75**: a removal is running now, and a new scan would replace the record it is working from,
  so nothing was scanned. Tell Dan, and scan again once that removal has finished.

## 2. Open the review page

Render the page for this scan, clearing the clipboard first so a selection copied from an earlier
page cannot be the one pasted:

```bash
bash ~/.claude/skills/disk-clean/review-page.sh --out <folder> --clear-clipboard
```

Then tell Dan, in the same message, that focus is about to move to Chrome, and open it:

```bash
open -a "Google Chrome" <folder>/disk-clean-review.html
```

Tell him: everything starts unticked; tick what should go, press Copy selection, and paste it here.
Greyed rows are what the scan will not remove, each with its reason. The selection must be
confirmed within an hour of the scan, after which disk-remove refuses it and the scan has to be run
again.

- **Exit 0**: the page and its nonce are written. Open it as above.
- **Exit 3**: the page is written but the clipboard could not be cleared. Open it anyway, and tell
  Dan an older selection may still be on his clipboard, so he should copy from this page before
  pasting; the checker refuses an old one by its nonce.
- **Exit 2**: no page was written. Tell Dan the reason it printed. When it says there is no scan
  record or the record is cut short, go back to step 1; otherwise stop.

## 3. Check the selection and confirm

When Dan pastes his selection, write exactly what he pasted to `<folder>/selection.json` with the
Write tool, never through a shell command, which would expand anything in it that looks like a
variable (L229). Then check it against the scan:

```bash
bash ~/.claude/skills/disk-clean/review-check.sh --out <folder> --payload <folder>/selection.json --plan <folder>/plan.txt
```

- **Exit 0**: the plan is written, and it printed each kind's count and total, then every item by
  path with its size and marks. Build the confirm picker below from that output.
- **Exit 2**: the selection could not be checked (not what the page copies, or no scan or page to
  check it against). Tell Dan the reason in plain words and ask him to press Copy selection on the
  page again and paste it; when it says there is no scan record, go back to step 1.
- **Exit 3**: a newer scan has replaced the one he reviewed. Nothing was planned. Go back to step 2,
  which renders the page for the newer scan.
- **Exit 4**: the selection came from an older copy of the page, or was left on the clipboard from
  an earlier run. Nothing was planned. Ask him to copy from the page open now.
- **Exit 5**: the count does not match the items listed, so some were lost between the page and the
  chat. Nothing was planned. Ask him to copy and paste again.
- **Exit 6**: some chosen items cannot be removed now (kept, unmeasured, already removed, or not in
  the scan). Nothing was planned. Name each one with the reason it printed, and ask him to untick
  those and copy again, or to start again from step 1.
- **Exit 7**: nothing was ticked, so nothing will be removed. Say so and stop.

Then put up one AskUserQuestion confirm picker, the only picker in this flow. Its question names
what will go, taken from the checker's output and never retyped from memory: each kind with its
count and total, and under the Trash, Large personal files and Tools not used in 180 days every item
by path, with its size and any mark it carries (Holds a credential, Removes it from iCloud on every
device). Say how each goes: Trash entries are deleted for good; Large personal files and Tools not
used in 180 days are moved to the Trash, which frees nothing until it is emptied; everything else is
deleted because it regenerates, or, for a log a program holds open, emptied in place. Two options:
remove them, or keep everything. On keep everything, say nothing was removed and stop.

## 4. Remove

Read the free space just before, and keep the figure:

```bash
df -m /System/Volumes/Data
```

Then run the plan the checker wrote:

```bash
bash ~/.claude/hooks/lib/disk-remove.sh --plan <folder>/plan.txt
```

It prints one line per item (removed, trashed, truncated, skipped with the reason, or failed with
the error), then the verified totals.

- **Exit 0**: every item went. Go on to step 5.
- **Exit 5**: at least one item was skipped or failed, or the scan record could not be marked with
  what went. Name each skipped or failed item with its reason in plain words; a failure that says
  Permission denied goes to step 6. Then go on to step 5 for what did go.
- **Exit 2**: it refused before touching anything (a plan or record it cannot use). Nothing was
  removed. Tell Dan the reason it printed and stop.
- **Exit 3**: the scan is more than an hour old, so what it measured may have changed. Nothing was
  removed. Start again from step 1.
- **Exit 4**: the plan is for a scan that is no longer the last one. Nothing was removed. Start
  again from step 1.
- **Exit 75**: another removal is running now. Nothing was removed. Once it finishes, run the same
  command again, if the scan is still under an hour old; otherwise start again from step 1.

## 5. Report the verified result

Read the free space again, just after:

```bash
df -m /System/Volumes/Data
```

Report three things, never on `du` alone, which overstates anything holding clones or hard links:

- What disk-remove verified: each item's own size, measured just before it went and checked gone
  after, summed.
- What moved to the Trash apart from that, since it frees nothing until the Trash is emptied; the
  next /disk-clean offers it under the Trash.
- What df says was freed: the free space before and after, in GB with one decimal. Other programs
  write to the disk too, so this is context, but a gain far below the verified total is worth
  saying, with the local Time Machine snapshots disk-remove named, which keep removed files until
  they expire.

## 6. Anything that needs Dan's password

Claude never runs `sudo` itself. An item that failed in step 4 with Permission denied is owned by
another user, usually root, and only Dan can remove the rest of it. Collect those paths from the
failed lines (each already passed disk-remove's own checks and Dan's confirm), and hand Dan one
command for all of them, in its own code block, each path absolute and in single quotes, never a
glob, shaped like this:

```bash
sudo rm -rf '/Users/dan/Library/Caches/com.example.helper'
```

A failure that says Operation not permitted is macOS protecting the folder, which `sudo` does not
get past; say so rather than handing a command. A trashed item that failed is for Dan to move to
the Trash in Finder, which asks for his password itself. Once he says he ran it, check each path is
gone with `ls -d` and read `df -m /System/Volumes/Data` again for the gain.

The macOS symbol cache, which can reach hundreds of gigabytes, is root only and not part of the
scan; when the totals do not explain a full disk, the disk-full skill's step 6 has its commands.
