#!/usr/bin/env python3
"""The two keep rules Dan set for what Claude Code leaves on disk (claude-config#3235).

Dan, 2026-11-18, each from a picker recorded on #3235:
  - Session notes: "Drop bulky leftovers, keep notes". Once a session has ended, its bulky leftovers
    go and its written notes stay.
  - Transcripts: "Shorten only agent and test runs", kept "7 days". His own sessions stay at Claude
    Code's own 30 days.
  - How it runs: "By itself, with a log". `claude-sync remove-leftovers` runs `remove` once a day from
    the launch agent com.claudesync.leftovers, and says so only when a run fails or is missed.

THE NOTES RULE, as a reader can check it against a folder:
  A session folder is ~/.claude/state/session-notes/<project>/<session id>/. Anything else under the
  notes root (a folder not named like a session id, a file, a link) is never touched.
  The session has ENDED when both hold, read from two different sources so neither can end a live
  session alone (L345):
    1. the session registry (~/.claude/state/sessions, the session-registry mod's) can be read and
       does not show it open, read by lib/session_registry.py, the one reading of that rule (L261);
    2. no file anywhere in its notes folder has been written for QUIET_DAYS (3) days (read from files
       and links, never from a folder's own time, which this job's own removals move).
  In an ended session, BULKY LEFTOVERS are removed:
    - a folder inside a task folder (<session>/<task>/<folder>) taking 1 MB or more on disk, unless
      it is a git checkout (a .git file or folder at its top: it may hold commits or edits that exist
      nowhere else; a task folder that is itself a checkout is kept whole) or more than half its bytes are images or documents (.jpg, .png, .pdf,
      .html, .md, .txt and the like: somebody may have looked at them or read them, and whether they
      are leftovers is Dan's call, not this rule's);
    - a tar file (.tar, .tgz, .tar.gz) directly in the session folder or in a task folder;
    - a folder an earlier run had begun removing (.keep-rules-removing.*), whatever its size.
  Everything else is a WRITTEN NOTE and stays: every other file directly in the session folder or in
  a task folder (handoff.md, evidence.md, tests.txt, pr-body.md, logs, corpora), every folder under
  1 MB, and every link, which is never followed and never removed.

THE TRANSCRIPTS RULE, under ~/.claude/projects/<project>/:
  Removed once last written more than TRANSCRIPT_DAYS (7) days ago:
    - a subagent transcript, <project>/<session>/subagents/**/agent-*.jsonl, and its agent-*.meta.json,
      in every project;
    - in a project folder Claude Code keyed to a worktree (its name holds -claude-worktrees-) or to a
      headless run under /private/tmp (its name is -private-tmp or starts -private-tmp-): the session
      transcript <session>.jsonl and every file in the session's own folder <session>/.
  A memory folder is never touched, and nothing else in Dan's own project folders is.

Modes, so the one that removes cannot be mistaken for the one that looks (L206):
  would-remove [--now EPOCH] [--report FILE]   lists what `remove` would remove, with sizes, and
                                               what it keeps and why. Writes nothing but FILE.
  remove [--now EPOCH]                         removes it, one log line per item with its size.

Time is handed in with --now (seconds since the epoch), so a test sets the clock rather than
waiting for it. CLAUDE_HOME names the config folder (default ~/.claude).

It assumes it can run twice or die half way: a second run waits for nobody (a lock held by another
run makes it stop and say so), a folder is renamed to .keep-rules-removing.<name> before it is
removed so a run killed mid removal is finished by the next one whatever is left of it, and every
decision is read again from disk on each run.

The last line printed is the summary claude-sync records:
  KEEP-RULES-SUMMARY <TAB> ok|failed|busy <TAB> items <TAB> bytes <TAB> first failure or -
busy means another run held the lock, so this one removed nothing and records nothing. A log that
cannot be written stops the run before its next removal and fails it.
"""

import sys

sys.dont_write_bytecode = True

import errno
import fcntl
import os
import re
import shutil
import stat
import time

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import session_registry  # noqa: E402

QUIET_DAYS = 3
TRANSCRIPT_DAYS = 7
BULKY_BYTES = 1024 * 1024
LOG_ROTATE_BYTES = 5 * 1024 * 1024
MARK = ".keep-rules-removing."
SESSION_DIR = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$")
SESSION_FILE = re.compile(r"^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jsonl$")
SUBAGENT_FILE = re.compile(r"^agent-[A-Za-z0-9_-]+\.(jsonl|meta\.json)$")
TARS = (".tar", ".tgz", ".tar.gz")
READABLE = (".jpg", ".jpeg", ".png", ".heic", ".tif", ".tiff", ".dng", ".gif", ".webp", ".cr3", ".nef", ".arw",
            ".pdf", ".html", ".htm", ".md", ".txt", ".csv", ".docx", ".rtf")
DAY = 86400


def claude_home():
    return os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")


def lst(path):
    try:
        return os.lstat(path)
    except OSError:
        return None


def is_dir(st):
    return st is not None and stat.S_ISDIR(st.st_mode)


def is_file(st):
    return st is not None and stat.S_ISREG(st.st_mode)


def size_of(st):
    return st.st_blocks * 512


def entries(path):
    try:
        return sorted(os.listdir(path))
    except OSError:
        return []


def walk(top, unread=None):
    """(path, lstat) for everything under top, never following a link. A folder that cannot be read
    is added to `unread`, so a caller judging age or size can refuse rather than read it as empty."""
    stack = [top]
    while stack:
        d = stack.pop()
        try:
            names = sorted(os.listdir(d))
        except OSError:
            if unread is not None:
                unread.append(d)
            continue
        for n in names:
            p = os.path.join(d, n)
            st = lst(p)
            if st is None:
                continue
            yield p, st
            if is_dir(st):
                stack.append(p)


def mb(b):
    return "%.1f MB" % (b / 1048576.0)


def run_folder(project):
    return "-claude-worktrees-" in project or project == "-private-tmp" or project.startswith("-private-tmp-")


class Plan:
    def __init__(self):
        self.remove = []   # (kind, path, bytes, is_dir)
        self.keep = []     # (reason, path, bytes)
        self.failures = []
        self.kept_notes = [0, 0]        # files, bytes of written notes in ended sessions
        self.kept_transcripts = [0, 0]  # files, bytes of transcripts this rule left


def plan_notes(home, now, plan):
    root = os.path.join(home, "state", "session-notes")
    rst = lst(root)
    if rst is None:
        return
    if not is_dir(rst):
        plan.failures.append("the notes folder %s is not a folder (a link is never followed), so the notes rule did not run" % root)
        return
    registry = session_registry.Registry(os.path.join(home, "state", "sessions"), int(now * 1000))
    if registry.missing:
        plan.failures.append("%s, so no session could be told to have ended and the notes rule removed nothing" % registry.missing)
        return
    for project in entries(root):
        pp = os.path.join(root, project)
        pst = lst(pp)
        if not is_dir(pst):
            plan.keep.append(("not a project folder", pp, 0))
            continue
        for sess in entries(pp):
            sp = os.path.join(pp, sess)
            sst = lst(sp)
            if not is_dir(sst) or not SESSION_DIR.match(sess):
                plan.keep.append(("not a session folder", sp, 0))
                continue
            plan_session(sp, sess, registry, now, plan)


def plan_session(sp, sess, registry, now, plan):
    state, why = registry.session(sess)
    # Newest WRITE, read from files and links only: a folder's own time moves whenever something in
    # it is removed, so this job's own removals would otherwise make an ended session look written to.
    total, newest, unread = 0, None, []
    for _, st in walk(sp, unread):
        if is_file(st):
            total += size_of(st)
        if not is_dir(st):
            newest = st.st_mtime if newest is None else max(newest, st.st_mtime)
    if newest is None:
        newest = lst(sp).st_mtime
    if unread:
        # A folder nobody can list may hold the newest write, so quiet cannot be measured.
        plan.keep.append(("a folder in it cannot be read (%s), so whether it was written to lately cannot be told" % unread[0], sp, total))
        return
    if state == "open":
        plan.keep.append(("live session: the session registry shows it open", sp, total))
        return
    if state != "gone":
        plan.keep.append(("the session registry cannot say whether it ended (%s)" % why, sp, total))
        return
    idle = now - newest
    if idle < QUIET_DAYS * DAY:
        plan.keep.append(("not ended: a file in it was written within the %d days this waits" % QUIET_DAYS, sp, total))
        return
    for name in entries(sp):
        p = os.path.join(sp, name)
        st = lst(p)
        if is_dir(st):
            plan_task(p, plan)
        else:
            plan_loose(p, st, plan)


def plan_loose(p, st, plan):
    """A file or link directly in the session folder or in a task folder."""
    if st is None:
        return
    if stat.S_ISLNK(st.st_mode):
        plan.keep.append(("a link, never followed", p, 0))
    elif is_file(st) and p.lower().endswith(TARS):
        plan.remove.append(("notes: tar file", p, size_of(st), False))
    elif is_file(st):
        plan.kept_notes[0] += 1
        plan.kept_notes[1] += size_of(st)


def plan_task(tp, plan):
    if lst(os.path.join(tp, ".git")) is not None:
        # The task folder is itself a checkout: removing its folders would gut uncommitted work.
        plan.keep.append(("is a git checkout, which may hold work that exists nowhere else", tp, 0))
        return
    for name in entries(tp):
        p = os.path.join(tp, name)
        st = lst(p)
        if not is_dir(st):
            plan_loose(p, st, plan)
            continue
        total = readable = 0
        # Only a checkout AT the folder's top counts: test fixtures hold many small repositories
        # of their own, and those are exactly the leftovers this rule is for.
        git = lst(os.path.join(p, ".git")) is not None
        for q, qst in walk(p):
            if is_file(qst):
                total += size_of(qst)
                if q.lower().endswith(READABLE):
                    readable += size_of(qst)
        if name.startswith(MARK):
            plan.remove.append(("notes: folder an earlier run began removing", p, total, True))
        elif git:
            plan.keep.append(("is a git checkout, which may hold work that exists nowhere else", p, total))
        elif total < BULKY_BYTES:
            plan.keep.append(("folder under 1 MB, kept as written notes", p, total))
        elif readable * 2 > total:
            plan.keep.append(("mostly images or documents, which somebody may have looked at or read", p, total))
        else:
            plan.remove.append(("notes: folder in a task folder", p, total, True))


def plan_transcripts(home, now, plan):
    root = os.path.join(home, "projects")
    rst = lst(root)
    if rst is None:
        return
    if not is_dir(rst):
        plan.failures.append("the transcripts folder %s is not a folder (a link is never followed), so the transcripts rule did not run" % root)
        return
    cutoff = now - TRANSCRIPT_DAYS * DAY
    for project in entries(root):
        pp = os.path.join(root, project)
        if not is_dir(lst(pp)):
            continue
        runs = run_folder(project)
        kind = "transcripts: worktree run" if "-claude-worktrees-" in project else "transcripts: /private/tmp run"
        for name in entries(pp):
            p = os.path.join(pp, name)
            st = lst(p)
            if name == "memory" or st is None:
                continue
            if is_file(st) and runs and SESSION_FILE.match(name):
                old_file(p, st, cutoff, kind, plan)
            elif is_dir(st) and SESSION_DIR.match(name):
                for q, qst in walk(p):
                    if not is_file(qst):
                        continue
                    if runs:
                        old_file(q, qst, cutoff, kind, plan)
                    elif os.sep + "subagents" + os.sep in q[len(p):] and SUBAGENT_FILE.match(os.path.basename(q)):
                        old_file(q, qst, cutoff, "transcripts: subagent", plan)


def old_file(p, st, cutoff, kind, plan):
    if st.st_mtime < cutoff:
        plan.remove.append((kind, p, size_of(st), False))
    else:
        plan.kept_transcripts[0] += 1
        plan.kept_transcripts[1] += size_of(st)


def make_plan(home, now):
    plan = Plan()
    plan_notes(home, now, plan)
    plan_transcripts(home, now, plan)
    return plan


def report(plan, home, now):
    out = []
    when = time.strftime("%Y-%m-%d %H:%M %Z", time.localtime(now))
    total = sum(r[2] for r in plan.remove)
    out.append("keep rules, would-remove, as of %s, for %s. Nothing was removed." % (when, home))
    out.append("")
    out.append("WOULD REMOVE: %d items, %s" % (len(plan.remove), mb(total)))
    kinds = {}
    for k, _, b, _ in plan.remove:
        n, s = kinds.get(k, (0, 0))
        kinds[k] = (n + 1, s + b)
    for k in sorted(kinds):
        out.append("  %-46s %6d items  %s" % (k, kinds[k][0], mb(kinds[k][1])))
    out.append("")
    out.append("THE LARGEST TEN")
    for k, p, b, _ in sorted(plan.remove, key=lambda r: -r[2])[:10]:
        out.append("  %10s  %s  %s" % (mb(b), k, p))
    out.append("")
    out.append("WOULD KEEP")
    out.append("  written notes in ended sessions: %d files, %s" % (plan.kept_notes[0], mb(plan.kept_notes[1])))
    out.append("  agent and test run transcripts written within the last %d days: %d files, %s (Dan's own session transcripts are not counted here)" % (TRANSCRIPT_DAYS, plan.kept_transcripts[0], mb(plan.kept_transcripts[1])))
    reasons = {}
    for r, _, b in plan.keep:
        n, s = reasons.get(r, (0, 0))
        reasons[r] = (n + 1, s + b)
    for r in sorted(reasons, key=lambda x: -reasons[x][1]):
        out.append("  %s: %d, %s" % (r, reasons[r][0], mb(reasons[r][1])))
    if plan.failures:
        out.append("")
        out.append("COULD NOT DECIDE")
        for f in plan.failures:
            out.append("  " + f)
    out.append("")
    out.append("EVERY ITEM IT WOULD REMOVE")
    for k, p, b, _ in plan.remove:
        out.append("  remove\t%s\t%d\t%s" % (k, b, p))
    out.append("")
    out.append("EVERY FOLDER OR SESSION IT WOULD KEEP, AND WHY")
    for r, p, b in plan.keep:
        out.append("  keep\t%s\t%d\t%s" % (r, b, p))
    return "\n".join(out) + "\n"


def stamp(now):
    return time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime(now))


class Log:
    """The removal log. A write that fails sets `error`, and the run stops removing, since an item
    removed with no line saying so is exactly what Dan asked the log to prevent."""

    def __init__(self, path):
        self.path, self.fh, self.error = path, None, None
        try:
            if os.path.getsize(path) > LOG_ROTATE_BYTES:
                os.replace(path, path + ".1")
        except OSError:
            pass
        try:
            self.fh = open(path, "a", encoding="utf-8", errors="backslashreplace")
        except OSError as e:
            self.error = "the log %s could not be opened (%s)" % (path, e.strerror or e)

    def line(self, *fields):
        if self.fh is None:
            return False
        try:
            self.fh.write("\t".join(str(f) for f in fields) + "\n")
            self.fh.flush()
            return True
        except OSError as e:
            self.error = self.error or "the log %s could not be written (%s)" % (self.path, e.strerror or e)
            return False


def remove_dir(p):
    """Rename first, so a run killed half way leaves a name the next run finishes whatever its size."""
    st = lst(p)
    if st is None:
        raise FileNotFoundError(errno.ENOENT, "already gone")
    if not is_dir(st):
        raise OSError(errno.ENOTDIR, "no longer a folder (a link is never followed)")
    base = os.path.basename(p)
    if not base.startswith(MARK):
        target = os.path.join(os.path.dirname(p), MARK + base)
        if os.path.lexists(target):
            target = "%s.%d" % (target, os.getpid())
        os.rename(p, target)
        p = target
    shutil.rmtree(p)


def remove_file(p):
    st = lst(p)
    if st is None:
        raise FileNotFoundError(errno.ENOENT, "already gone")
    if not is_file(st):
        raise OSError(errno.EINVAL, "no longer a plain file (a link is never followed)")
    os.unlink(p)


def prune_empty(home, removed):
    """Only the folders THIS run emptied of transcripts: from each removed file's folder upward, while
    empty, stopping at the session folder in Dan's own projects and at the projects folder in a run
    project. An empty folder this run did not empty (a live session's fresh one) is never touched."""
    root = os.path.join(home, "projects")
    for p in removed:
        rel = os.path.relpath(p, root).split(os.sep)
        if len(rel) < 2 or rel[0] in (os.curdir, os.pardir):
            continue
        stop = os.path.join(root) if run_folder(rel[0]) else os.path.join(root, rel[0], rel[1])
        d = os.path.dirname(p)
        while d != stop and d.startswith(stop + os.sep):
            try:
                os.rmdir(d)
            except OSError:
                break
            d = os.path.dirname(d)


def do_remove(home, now):
    state = os.path.join(home, "state", "keep-rules")
    os.makedirs(state, exist_ok=True)
    lock = open(os.path.join(state, ".lock"), "w", errors="strict")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except OSError:
        print("keep rules: another run is removing right now, so this one removed nothing and left it to that run.")
        print("KEEP-RULES-SUMMARY\tbusy\t0\t0\t-")
        return 0
    plan = make_plan(home, now)
    log = Log(os.path.join(state, "removed.log"))
    items = done_bytes = 0
    failures = list(plan.failures)
    removed = []
    for f in plan.failures:
        log.line(stamp(now), "failed", "-", 0, "-", f)
    for kind, p, b, isdir in plan.remove:
        if log.error:
            break
        try:
            if isdir:
                remove_dir(p)
            else:
                remove_file(p)
        except FileNotFoundError:
            continue
        except OSError as e:
            why = "%s could not be removed: %s" % (p, e.strerror or e)
            failures.append(why)
            log.line(stamp(now), "failed", kind, b, p, e.strerror or e)
            continue
        items += 1
        done_bytes += b
        if not isdir:
            removed.append(p)
        if not log.line(stamp(now), "removed", kind, b, p):
            # Said in the summary, which claude-sync records whatever the log can take.
            failures.append("%s was removed, %d bytes, and %s" % (p, b, log.error))
    prune_empty(home, [p for p in removed if p.startswith(os.path.join(home, "projects") + os.sep)])
    if log.error and not any(log.error in f for f in failures):
        failures.append("%s, so nothing was removed" % log.error if items == 0 else log.error)
    outcome = "failed" if failures else "ok"
    log.line(stamp(now), "run", outcome, done_bytes, "%d items" % items, failures[0] if failures else "-")
    print("keep rules: removed %d items, %s; %s" % (items, mb(done_bytes), ("%d could not be removed or decided, the first: %s" % (len(failures), failures[0])) if failures else "nothing failed"))
    print("KEEP-RULES-SUMMARY\t%s\t%d\t%d\t%s" % (outcome, items, done_bytes, (failures[0] if failures else "-").replace("\t", " ")))
    return 1 if failures else 0


def main(argv):
    # A name that is not valid UTF-8 is listed escaped, so one such name never stops a listing or a
    # run half way, after items were already removed.
    sys.stdout.reconfigure(errors="backslashreplace")
    sys.stderr.reconfigure(errors="backslashreplace")
    mode = argv[1] if len(argv) > 1 else ""
    now, report_to, i = time.time(), None, 2
    while i < len(argv):
        if argv[i] == "--now" and i + 1 < len(argv):
            try:
                now = float(argv[i + 1])
            except ValueError:
                print("keep_rules.py: --now takes seconds since the epoch, not %r. Nothing was done." % argv[i + 1], file=sys.stderr)
                return 2
            i += 2
        elif argv[i] == "--report" and i + 1 < len(argv) and mode == "would-remove":
            report_to, i = argv[i + 1], i + 2
        else:
            print("keep_rules.py: %r is not an option of %s. Nothing was done." % (argv[i], mode or "this script"), file=sys.stderr)
            return 2
    home = claude_home()
    if mode == "would-remove":
        text = report(make_plan(home, now), home, now)
        if report_to:
            with open(report_to, "w", encoding="utf-8", errors="backslashreplace") as fh:
                fh.write(text)
        else:
            sys.stdout.write(text)
        return 0
    if mode == "remove":
        return do_remove(home, now)
    print("usage: keep_rules.py would-remove [--now EPOCH] [--report FILE]   (lists, removes nothing)\n"
          "       keep_rules.py remove [--now EPOCH]                         (removes, and logs each item)", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
