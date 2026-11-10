"""Each session's notes folder, where a restart of the Mac cannot clear it (claude-config#2490).

A session's scratchpad is /private/tmp/claude-<uid>/<project>/<session>/scratchpad, and macOS empties
/private/tmp on restart. On 2026-11-09 a restart of the work MacBook took a session's handoff.md (the
note it re-reads after a compaction or a crash), a guide it had built, and a background agent's
working tree with an uncommitted fix. Everything in git survived.

So the handoff note, and the working folder of every agent a session dispatches, live in

    $CLAUDE_HOME/state/session-notes/<project>/<session>/

- ~/.claude/state is this Mac's own: claude-sync carries only the payload's folders (hooks, skills,
  mods and the rest) and the top level rule files, never state/, so a note naming work repositories
  never reaches the public repository. ~/.claude/projects was the other candidate and is not synced
  either, but Claude Code owns its layout and deletes what is in it after cleanupPeriodDays (30 days
  on this Mac, measured 2026-11-09: the oldest transcript left was 31 days old).
- <project> is the folder name Claude Code itself keys the session by, read from the transcript's
  own folder (~/.claude/projects/<project>/<session>.jsonl), so it is the same key the scratchpad
  carries, and the same from a worktree, whose cwd is a different path. With no transcript path the
  cwd is folded the way Claude Code folds it, every character that is not a letter or a digit to -.

This one module decides the folder. session-notes-folder.sh tells each session its folder at start,
and context_size.py names the handoff note's path at the context line. The status bar's compact tool
checks a note's path in TypeScript, which cannot import this, so it spells the root too, and
test-session-notes.sh holds the two spellings together.

Switching over: a session that wrote handoff.md in its scratchpad before this shipped has it copied
into the notes folder once, the first time the folder is ensured, and never over a note already
there. The scratchpad copy is left alone (L5).
"""

import json
import os
import re
import shutil
import sys

NAME = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
KEY = re.compile(r"^[A-Za-z0-9._-]+$")
ISSUE = "claude-config#2490"


def claude_home():
    return os.environ.get("CLAUDE_HOME") or os.path.expanduser("~/.claude")


def tmp_root():
    # Where Claude Code keeps per user temp folders; moved only by tests.
    return os.environ.get("SESSION_NOTES_TMP") or "/private/tmp"


def is_name(value):
    return isinstance(value, str) and bool(NAME.match(value)) and value not in (".", "..")


def project_key(d):
    t = d.get("transcript_path")
    if isinstance(t, str) and t:
        key = os.path.basename(os.path.dirname(t))
        # Claude Code's keys start with the - a leading / folds to, so not a plain name.
        if KEY.match(key) and key not in (".", ".."):
            return key
    cwd = d.get("cwd")
    if isinstance(cwd, str) and cwd.startswith("/"):
        return re.sub(r"[^A-Za-z0-9]", "-", cwd)
    return None


def notes_dir(d, home=None):
    """The session's notes folder, or None when the payload names no usable session."""
    session = d.get("session_id")
    key = project_key(d)
    if not is_name(session) or not key:
        return None
    return os.path.join(home or claude_home(), "state", "session-notes", key, session)


def scratchpad_of(d):
    session = d.get("session_id")
    key = project_key(d)
    if not is_name(session) or not key:
        return None
    return os.path.join(tmp_root(), "claude-%d" % os.getuid(), key, session, "scratchpad")


def ensure(d, home=None):
    """Make the folder and carry a scratchpad handoff note into it once.

    Returns {"dir", "note", "had_note", "carried", "error"}: carried is the scratchpad note's path
    when it was copied, error says why the folder could not be made (None when it was).
    """
    out = {"dir": notes_dir(d, home), "note": None, "had_note": False, "carried": None, "error": None}
    if out["dir"] is None:
        out["error"] = "the payload names no session id and project this folder could be keyed by"
        return out
    out["note"] = os.path.join(out["dir"], "handoff.md")
    try:
        os.makedirs(out["dir"], mode=0o700, exist_ok=True)
    except OSError as err:
        out["error"] = err.strerror or str(err)
        return out
    out["had_note"] = os.path.isfile(out["note"])
    old = scratchpad_of(d)
    old_note = os.path.join(old, "handoff.md") if old else None
    if not out["had_note"] and old_note and os.path.isfile(old_note):
        # Copied beside it, then linked into place: a link never replaces a file, so of two runs at
        # once only one lands, and a note written meanwhile is never overwritten.
        tmp = "%s.%d.tmp" % (out["note"], os.getpid())
        try:
            shutil.copy2(old_note, tmp)
            os.link(tmp, out["note"])
            out["carried"] = old_note
        except FileExistsError:
            pass
        except OSError as err:
            out["error"] = "the scratchpad's handoff.md could not be copied in (%s)" % (err.strerror or err)
        finally:
            try:
                os.unlink(tmp)
            except OSError:
                pass
    return out


def start_notice(d):
    """SessionStart's answer: (context for the session, message for Dan or "")."""
    r = ensure(d)
    if r["dir"] is None:
        msg = ("The session notes folder (%s) was not set up: %s. A handoff note written in the "
               "scratchpad is lost if this Mac restarts." % (ISSUE, r["error"]))
        return msg, msg
    if r["error"] and not os.path.isdir(r["dir"]):
        msg = ("The session notes folder %s could not be created (%s), so this session has nowhere a "
               "restart cannot clear: a handoff note written in the scratchpad is lost if this Mac "
               "restarts (%s)." % (r["dir"], r["error"], ISSUE))
        return msg, msg
    parts = [
        "This session's notes folder is %s (%s). It is on this Mac's disk and never synced, and a "
        "restart does not clear it, while the scratchpad under /private/tmp is emptied by every "
        "restart. Write handoff.md there, at %s, and give each agent you dispatch its own subfolder "
        "there for its working files. A worktree goes in the repository's own .claude/worktrees "
        "folder, never under /tmp." % (r["dir"], ISSUE, r["note"])
    ]
    if r["carried"]:
        parts.append("handoff.md was copied there from the scratchpad (%s), which a restart clears: "
                     "read it, and write it in the notes folder from now on." % r["carried"])
    elif r["had_note"]:
        parts.append("It holds handoff.md from earlier in this session: read it before picking up "
                     "where that left off.")
    system = ""
    if r["error"]:
        parts.append("But %s, so it is still only in the scratchpad." % r["error"])
        system = "Session notes: %s (%s)." % (r["error"], ISSUE)
    return " ".join(parts), system


def emit_start(ctx, system):
    out = {"hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ctx}}
    if system:
        out["systemMessage"] = system
    sys.stdout.write(json.dumps(out) + "\n")


def main(argv):
    raw = sys.stdin.buffer.read()
    try:
        d = json.loads(raw.decode("utf-8", "replace"))
        if not isinstance(d, dict):
            raise ValueError("the payload is not a JSON object")
    except ValueError as err:
        msg = ("The session notes folder (%s) was not set up: the SessionStart payload could not be "
               "read (%s)." % (ISSUE, err))
        emit_start(msg, msg)
        return 0
    if argv[1:] == ["start"]:
        emit_start(*start_notice(d))
    return 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    try:
        sys.exit(main(sys.argv))
    except Exception as err:  # a crash must never fail a session start
        emit_start("The session notes folder (%s) was not set up: %s." % (ISSUE, err),
                   "The session notes folder (%s) was not set up: %s." % (ISSUE, err))
        sys.exit(0)
