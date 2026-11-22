#!/usr/bin/env python3
"""Run this before any count that reads the session records under ~/.claude/projects (claude-config#3413).

Why: the daily keep rules job (payload/hooks/lib/keep_rules.py, #3235) removes agent records and
worktree and /private/tmp run records once last written more than its TRANSCRIPT_DAYS ago, and
Claude Code removes Dan's own after 30 days. A count that says "the last N days" therefore reads
fewer days than it says once N passes either age, and a recount hours later reads a different set
(#3230 read 4,545 files and then 4,275, L487). So this says how far back each kind of record really
reaches, refuses a window longer than that, and copies the records in the window to a folder that
outlives the session, which the count and any recount then read.

The kinds are the keep rules' own: transcript_files() in keep_rules.py sorts every record, and this
imports it rather than copying the rule (L342, L370).
  own    Dan's own sessions: <project>/<session>.jsonl in a project folder that is not a run's
  agent  agent records: <project>/<session>/subagents/**/agent-*.jsonl and agent-*.meta.json
  run    worktree and temporary folder runs: every record in a project folder keyed to a worktree
         (-claude-worktrees-) or to a run under /private/tmp
A record is in a window of N days when it was last written at most N days before now.

Modes, so the one that writes cannot be mistaken for the one that looks (L206):
  report --days N [--kinds own,agent,run] [--accept-shorter]
      Per kind, the files in the window and the oldest record present. Writes nothing.
  copy --days N --label NAME [--kinds own,agent,run] [--accept-shorter] [--keep-free-gb G]
      Copies the records in the window to ~/.claude/state/record-copies/<NAME>-<YYYYMMDD-HHMMSS>/,
      under projects/ at the paths they had, each with its own time, the folders readable only by
      this user (0700) and the files too (0600). Then prints how many files and which dates the
      copy holds, and writes the same to COPY.txt beside them. Point the count's reader at
      <copy>/projects, or run this script's report with CLAUDE_HOME=<copy> to recount.
Both refuse (exit 3, nothing copied) when the window asked for reaches further back than the oldest
record of a kind asked for, unless --accept-shorter, when they go on and state the window each kind
really has. copy also refuses when the copy would leave under G GB free on the disk (default 5).

WHERE THE COPY LIVES, and why there (#3413): ~/.claude/state/record-copies.
  - The session notes folder is not a place for it: keep_rules.py removes the bulky folders and tar
    files of an ended session's notes.
  - Nothing removes anything under state/ but its own folder: keep_rules.py walks only
    state/session-notes and projects/; disk-clean offers nothing in state/ besides session notes
    folders the keep rules list (categories/claude-records.sh) and disk-remove.sh refuses the rest.
  - The config sync never carries state/: it mirrors hooks, agents, commands, audits, mods and
    skills plus the top level rule files (MIRROR_DIRS in claude-sync, lib/synced-trees.sh).
  The records hold everything typed in every session, so the copy is kept to this user.
  Nothing here, or anywhere else, removes a copy. When the count is finished, delete it with the
  rm -rf line this prints; whether copies should go by themselves is Dan's decision (L9).

Time is handed in with --now (seconds since the epoch), so a test sets the clock rather than waiting
for it. CLAUDE_HOME names the config folder (default ~/.claude), as for keep_rules.py.
Exit codes: 0 done, 1 failed (said why), 2 not a valid call, 3 refused (said why, nothing copied).
"""

import sys

sys.dont_write_bytecode = True

import math
import os
import re
import shutil
import stat
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "..", "payload", "hooks", "lib"))
import keep_rules  # noqa: E402

DAY = keep_rules.DAY
# Each kind a count can ask for, its name in what this prints, and the keep rules' kinds in it.
KINDS = [
    ("own", "Dan's own sessions", (keep_rules.OWN_SESSION,)),
    ("agent", "agent records", (keep_rules.SUBAGENT_KIND,)),
    ("run", "worktree and temporary folder runs", (keep_rules.WORKTREE_KIND, keep_rules.TMP_KIND)),
]
LABEL = re.compile(r"^[A-Za-z0-9._-]+$")
GB = 1024 ** 3


def when(t):
    return time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(t))


def day_of(t):
    return time.strftime("%Y-%m-%d", time.localtime(t))


def days_text(d):
    """A window asked for, as it was asked: 14 days, or 2.5 days."""
    return "%d days" % d if d == int(d) else "%.1f days" % d


def reach_text(r):
    """How far back records really reach, always to a tenth of a day, so 8.0 never reads as a round ask."""
    return "%.1f days" % r


class Kind:
    def __init__(self, key, name):
        self.key, self.name = key, name
        self.oldest = None   # the earliest time any record of this kind was last written
        self.files = []      # (path, lstat) of the records in the window

    def reach(self, now):
        """How many days back this kind's records reach, or None when there are none."""
        return None if self.oldest is None else (now - self.oldest) / DAY


def measure(home, now, days, wanted):
    root = os.path.join(home, "projects")
    st = keep_rules.lst(root)
    if st is None:
        return None, "there is no records folder at %s, so there is nothing to count" % root
    if stat.S_ISLNK(st.st_mode):
        return None, "the records folder %s is a link, and a link is never followed, so nothing was counted" % root
    if not keep_rules.is_dir(st):
        return None, "%s is not a folder, so there is no records folder to count" % root
    kinds = [Kind(k, n) for k, n, _ in KINDS if k in wanted]
    of = {}
    for k in kinds:
        for rule_kind in next(r for key, _, r in KINDS if key == k.key):
            of[rule_kind] = k
    start = now - days * DAY
    unread = []
    for p, pst, rule_kind in keep_rules.transcript_files(root, unread):
        k = of.get(rule_kind)
        if k is None:
            continue
        if k.oldest is None or pst.st_mtime < k.oldest:
            k.oldest = pst.st_mtime
        if pst.st_mtime >= start:
            k.files.append((p, pst))
    if unread:
        # Read as empty, a folder that cannot be listed would make every count beneath it short and
        # say nothing, so it stops the count instead (L11).
        return None, ("%d folder(s) of records could not be read, so any count would leave out what they hold: %s"
                      % (len(unread), "; ".join(unread[:5]) + ("; and %d more" % (len(unread) - 5) if len(unread) > 5 else "")))
    return kinds, None


def short_kinds(kinds, now, days):
    return [k for k in kinds if k.reach(now) is None or k.reach(now) < days]


def refusal(short, now, days):
    lines = []
    for k in short:
        if k.oldest is None:
            lines.append("Refused: there are no %s at all, so a count of them would read nothing." % k.name)
        else:
            lines.append("Refused: the window asked for is %s, but %s reach back only %s (the oldest was last "
                         "written %s), so a count over %s would silently read %s of them."
                         % (days_text(days), k.name, reach_text(k.reach(now)), when(k.oldest),
                            days_text(days), reach_text(k.reach(now))))
    reaches = [k.reach(now) for k in short if k.oldest is not None]
    empty = [k for k in short if k.oldest is None]
    ways = []
    if reaches:
        ways.append("ask for %d days or fewer" % int(min(reaches)))
    if empty:
        ways.append("leave out %s with --kinds" % " and ".join(k.key for k in empty))
    ways.append("run again with --accept-shorter to go on, and the window each kind really has is stated")
    lines.append("To count anyway, %s. Nothing was copied." % ", or ".join(ways))
    return "\n".join(lines)


def real_window(k, now, days):
    r = k.reach(now)
    if r is None:
        return "there are none at all"
    if r < days:
        return "the window it really has is %s (%s asked)" % (reach_text(r), days_text(days)[:-len(" days")])
    return "the window it really has is %s" % days_text(days)


def report_text(home, kinds, now, days):
    out = ["Session records under %s, as of %s. Window asked for: %s, from %s."
           % (os.path.join(home, "projects"), when(now), days_text(days), when(now - days * DAY))]
    for k in kinds:
        if k.oldest is None:
            out.append("  %s: none at all." % k.name)
            continue
        out.append("  %s: %d files in the window; the oldest was last written %s (%s back); %s."
                   % (k.name, len(k.files), when(k.oldest), reach_text(k.reach(now)),
                      real_window(k, now, days)))
    return "\n".join(out)


def make_private_dir(path):
    os.mkdir(path, 0o700)
    os.chmod(path, 0o700)


def do_copy(home, kinds, now, days, label, keep_free):
    total = sum(st.st_size for k in kinds for _, st in k.files)
    base = os.path.join(home, "state", "record-copies")
    state = os.path.join(home, "state")
    probe = base if os.path.isdir(base) else (state if os.path.isdir(state) else home)
    try:
        free = shutil.disk_usage(probe).free
    except OSError as e:
        print("record-copy: could not read the free space at %s (%s), so whether the copy fits is not known. "
              "Nothing was copied." % (probe, e))
        return 1
    if total > free - keep_free * GB:
        print("record-copy: refused: the copy is %.1f GB and %.1f GB is free, so it would leave under %s GB free. "
              "Free some space or ask for a shorter window. Nothing was copied."
              % (total / GB, free / GB, keep_free))
        return 3
    os.umask(0o077)
    name = "%s-%s" % (label, time.strftime("%Y%m%d-%H%M%S", time.localtime(now)))
    dest = os.path.join(base, name)
    work = dest + ".incomplete"
    try:
        os.makedirs(state, mode=0o700, exist_ok=True)
        if not os.path.isdir(base) or os.path.islink(base):
            make_private_dir(base)
        # Tighten a folder somebody loosened, never loosen one: read only stays read only.
        os.chmod(base, stat.S_IMODE(os.lstat(base).st_mode) & 0o700)
        if os.path.lexists(dest):
            raise FileExistsError("%s already exists" % dest)
        make_private_dir(work)
    except OSError as e:
        print("record-copy: could not make the copy folder %s: %s. Nothing was copied and nothing was counted."
              % (work if os.path.isdir(base) else base, e.strerror or e))
        return 1
    root = os.path.join(home, "projects")
    by_day = {}
    copied = 0
    for k in kinds:
        for p, st in k.files:
            rel = os.path.relpath(p, root)
            to = os.path.join(work, "projects", rel)
            try:
                # Under the 077 umask set above, every folder made here is 0700.
                os.makedirs(os.path.dirname(to), mode=0o700, exist_ok=True)
                shutil.copyfile(p, to, follow_symlinks=False)
                os.chmod(to, 0o600)
                os.utime(to, (st.st_atime, st.st_mtime))
            except OSError as e:
                print("record-copy: could not copy %s: %s. The copy at %s is not whole and must not be counted "
                      "from; %d of the records were copied. Delete it with:\n  rm -rf '%s'"
                      % (p, e.strerror or e, work, copied, work))
                return 1
            copied += 1
            by_day[day_of(st.st_mtime)] = by_day.get(day_of(st.st_mtime), 0) + 1
    lines = ["Copied %d record files (%.1f MB) to %s, readable only by you." % (copied, total / 1048576.0, dest),
             "Window asked for: %s, from %s to %s." % (days_text(days), when(now - days * DAY), when(now))]
    for k in kinds:
        if k.files:
            first = min(st.st_mtime for _, st in k.files)
            last = max(st.st_mtime for _, st in k.files)
            lines.append("  %s: %d files, last written %s to %s; %s."
                         % (k.name, len(k.files), day_of(first), day_of(last), real_window(k, now, days)))
        else:
            lines.append("  %s: no files in the window; %s." % (k.name, real_window(k, now, days)))
    lines.append("Files by the day they were last written:")
    for d in sorted(by_day):
        lines.append("  %s  %d" % (d, by_day[d]))
    lines.append("Count from %s, not from ~/.claude/projects, so a recount reads the same records." % os.path.join(dest, "projects"))
    lines.append("Nothing removes this copy. When the count is finished, delete it with:\n  rm -rf '%s'" % dest)
    text = "\n".join(lines) + "\n"
    try:
        fd = os.open(os.path.join(work, "COPY.txt"), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8", errors="backslashreplace") as fh:
            fh.write(text)
        os.rename(work, dest)
    except OSError as e:
        print("record-copy: could not finish the copy at %s: %s. It is not whole and must not be counted from. "
              "Delete it with:\n  rm -rf '%s'" % (work, e.strerror or e, work))
        return 1
    sys.stdout.write(text)
    return 0


def usage(why):
    print("record-copy.py: %s. Nothing was done.\n"
          "usage: record-copy.py report --days N [--kinds own,agent,run] [--accept-shorter] [--now EPOCH]\n"
          "       record-copy.py copy --days N --label NAME [--kinds own,agent,run] [--accept-shorter] "
          "[--keep-free-gb G] [--now EPOCH]" % why, file=sys.stderr)
    return 2


def main(argv):
    sys.stdout.reconfigure(errors="backslashreplace")
    sys.stderr.reconfigure(errors="backslashreplace")
    mode = argv[1] if len(argv) > 1 else ""
    if mode not in ("report", "copy"):
        return usage("the first word is report or copy, not %r" % mode)
    now, days, label, wanted, accept, keep_free = time.time(), None, None, [k for k, _, _ in KINDS], False, 5.0
    i = 2
    try:
        while i < len(argv):
            a = argv[i]
            if a == "--accept-shorter":
                accept, i = True, i + 1
                continue
            if i + 1 >= len(argv):
                return usage("%s needs a value" % a)
            v = argv[i + 1]
            if a == "--now":
                now = float(v)
                if not math.isfinite(now):
                    return usage("--now takes seconds since the epoch, not %r" % v)
            elif a == "--days":
                days = float(v)
                if not math.isfinite(days) or days <= 0:
                    return usage("--days takes a number of days above 0, not %r" % v)
                days = int(days) if days == int(days) else days
            elif a == "--label" and mode == "copy":
                if not LABEL.match(v):
                    return usage("--label takes letters, digits, dots, dashes and underscores, not %r" % v)
                label = v
            elif a == "--kinds":
                wanted = [w.strip() for w in v.split(",") if w.strip()]
                bad = [w for w in wanted if w not in [k for k, _, _ in KINDS]]
                if bad or not wanted:
                    return usage("%r is not a kind of record; the kinds there are: own, agent, run" % ",".join(bad or [v]))
            elif a == "--keep-free-gb" and mode == "copy":
                keep_free = float(v)
            else:
                return usage("%r is not an option of %s" % (a, mode))
            i += 2
    except ValueError:
        return usage("%s takes a number, not %r" % (argv[i], argv[i + 1]))
    if days is None:
        return usage("--days is needed: the window the count reads")
    if mode == "copy" and label is None:
        return usage("copy needs --label, naming the count the copy is for (an issue number, say)")
    home = keep_rules.claude_home()
    kinds, why = measure(home, now, days, wanted)
    if kinds is None:
        print("record-copy: %s. Nothing was copied." % why)
        return 1
    short = short_kinds(kinds, now, days)
    if mode == "report":
        print(report_text(home, kinds, now, days))
        if short and not accept:
            print(refusal(short, now, days))
            return 3
        return 0
    if short and not accept:
        print(refusal(short, now, days))
        return 3
    return do_copy(home, kinds, now, days, label, keep_free)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
