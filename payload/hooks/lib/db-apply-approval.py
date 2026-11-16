"""Whether Dan's Apply in the /db-apply picker covers one `supabase db push` (claude-config#2763).

Applying one migration through /db-apply was a dry run, a push and a read back, and db-write-ask.sh
asked about each after Dan had already answered the skill's own Apply or Cancel picker for that
migration, so one decision was put to him up to four times. This file says whether his answer
covers a push, so db-write-ask.sh can let that push through instead of asking again.

WHAT COVERS A PUSH. An AskUserQuestion picker in this session whose metadata names it:

    {"source": "db-apply", "migration": "<absolute path of the migration file>",
     "sha256": "<the file's sha256>", "project_ref": "<the linked project's ref>",
     "pending": ["<each migration the skill's dry run said the push would apply>"]}

answered Apply by Dan. It covers a push when all of these hold, and each failure is said:
  - the picker was in the session making the push: its transcript entry carries the payload's
    session id. One Apply stays good for its migration and project until the session ends (Dan,
    2026-11-11, the issue's open question), so a new session asks again.
  - the answer came from Dan: the picker's input carried no answers of its own (a caller can fill
    them in, and the dialog then returns them without asking), the dialog did not close by itself
    while he was away, and the one question's answer is exactly Apply.
  - the push goes to the project the Apply named: the ref in the push's working directory's
    supabase/.temp/project-ref, where `supabase link` keeps it (read on the personal MacBook on
    2026-11-11, CLI 2.75.0), and the push names no other target (no --db-url, no --local).
  - the migration is that project's, unchanged: it sits in the working directory's
    supabase/migrations, and its sha256 now is the one the Apply named, so an edit after the Apply
    is asked about again.
  - nothing else would go with it. The push applies every migration the database has not had,
    and this cannot ask the database which those are, so it reads two things instead:
      * "pending", the dry run's list the skill copied onto the picker and showed Dan, must be
        exactly one entry, the applied migration (compared by file name, so a full path counts).
        A missing, empty, longer or different list is asked about, and the question names the
        other migrations listed (Dan held #2800 for this, 2026-11-11), so an older migration the
        database never got cannot ride along on an Apply for a newer one.
      * the migration is the newest file in the folder (migrations are named by a leading
        version, so the newest sorts last). One written after the dry run would be pushed with it
        and is not on its list, so it is asked about.
  - the folder is as the dry run Dan saw found it (claude-config#2829). The pending list is only
    what that dry run printed, and the sha256 only what the file held when the picker was built, so
    each holds only while nothing in supabase/migrations changes after the dry run. So the session
    must hold a dry run before the Apply: a Bash call that is one `supabase db push --dry-run` of
    the linked project (lib/db-write-calls.py dry_push_dir()), on this push's directory, that
    succeeded. A dry run of another project's folder, one only after the Apply, or one that failed
    covers nothing. And no .sql file in the folder may have a status change time (st_ctime, which
    a write, a rename or a new file sets, and which no command can set back) at or after the moment
    that dry run was sent (its tool_use entry's timestamp, stamped before the command runs). That
    asks again about a migration edited, renamed or added after the dry run, an older version
    added under the newest included (the gap #2800 recorded), and a dry run of the other project's
    folder used for this one.

THE AD HOC WRITE (Dan, 2026-11-11, folded into #2763). The skill's path 3, `supabase db query
--linked --yes -f <file>` running a write, is covered by the same Apply when "migration" names that
file: same session, same project, the file unchanged. No newest-migration rule applies to it, since
it runs that one file and nothing else.

WHERE DAN'S ANSWER IS READ. From the session transcript Claude Code writes (transcript_path in the
hook payload): the picker's input on the assistant entry holding its tool_use, and his choice in
toolUseResult.answers on the user entry carrying its tool_result, keyed by the question's text.
That shape was read from this Mac's transcripts on 2026-11-11, metadata included. Nothing here
writes a record of an Apply, so there is no record file a command could forge or leave behind for
one; a transcript that cannot be read covers nothing. (The one record this file writes is of the
test project lines Dan approved, under A LINE COUNTS ONLY WHEN DAN HIMSELF APPROVED IT, below.)

WHAT IT CANNOT SEE: the database itself. The pending list is what the dry run printed before the
picker; a change on the database between that dry run and the push is not reflected in it. Nor a
`supabase link` to another project between the dry run and the Apply in the same directory: the
CLI's own writes to supabase/.temp were not measured, so its files are not timed (#2829).

  covered(workdir, flags, session_id, transcript_path, file=None, dry_dir=None)
      (True, the sentence naming the Apply) or (False, why no Apply covers the run); file is None
      for a push, else the absolute path of the -f file a `db query` runs. dry_dir(command, cwd)
      is the directory a Bash command dry runs a push of, or None (db-write-calls dry_push_dir);
      without it no dry run is found, so no push is covered.

A TEST PROJECT (claude-config#2643). In a work repository every owner step on its test Supabase
project is a SQL file its scripts write, and each run was asked about (four times for one flow
version on 2026-11-10), with no Apply to cover it. Dan, 2026-11-14: the test refs live in a per
project file the hook reads, and a run on one passes silently, with no notice. So a `supabase db
query -f <file>` that is the whole of its command, with only the flags QUERY_FLAGS allows, passes
when the project its directory is linked to (supabase/.temp/project-ref) is listed in that
directory's .claude/supabase-test-projects. It needs no Apply, and covers no push and no inline
statement. Fails closed: a list missing, unreadable, not text, or holding any line that is neither a
ref nor a comment marks nothing, so the run is asked about as before. What it cannot see: whether a
ref on the list really is a test project. The list is the checkout's own word, so a ref written
into it by mistake is trusted like any other once Dan has approved its line (A LINE COUNTS ONLY
WHEN DAN HIMSELF APPROVED IT, below); one a session wrote is not, until he has.

The list is trusted only as git has committed it (the coordinator's review of #2643): its bytes must
be what `git show HEAD:<it>` gives, so an uncommitted or untracked edit, a live ref added by any shell
command included, is asked about until it is committed. And db-write-ask.sh holds an Edit, Write or
MultiEdit of the list (is_test_list) as it holds a database write, and since #2989 a shell command
that writes it, or a `git commit` that would add a line to one (list_shell_change): before that, a
session that appended a ref with a shell command and then committed it was trusted once the commit
landed.

A LINE COUNTS ONLY WHEN DAN HIMSELF APPROVED IT (claude-config#3023). Asking about `git commit` left
every other way a line reaches HEAD unasked: a git alias for commit, `git commit-tree`, a merge, a
cherry pick, a rebase, a pull. Naming git commands could never end that, so the list is judged
where it is used. When a write runs, its project's line must be in HEAD (above) and approved by
Dan, and whatever route carried a line to HEAD, one he has not approved marks nothing.
  - HIS APPROVAL IS A PICKER, read as his Apply is (WHERE DAN'S ANSWER IS READ, above): an
    AskUserQuestion picker in this session, of one question, that he answered TRUST (`Trust`), not
    one that timed out, failed or came with its answer filled in, whose metadata names the line:
        {"source": "db-test-project", "list": "<absolute path of the list>",
         "project_ref": "<the ref on that line>"}
  - THE RECORD keeps it past the session: <record>/approved, where <record> is
    $CLAUDE_HOME/state/supabase-test-projects on this Mac only (the state folder is never synced).
    One sha256 per line, of the clone (its git common directory, so every worktree of it counts and
    another clone does not), the list's path in it and the ref; no ref is written out. A hook run
    that reads Dan's picker for a line writes it there (at a write on its project, or at a commit
    adding it), unless the call is a subagent's (the payload carries agent_id): a subagent's call
    passes on his picker and writes nothing. When the record cannot take a line, the main
    session's call is not trusted on his picker either: it is asked about, the question naming the
    record and the error (claude-config#3058), since a line the record did not keep is asked about
    again in the next session. Once the record can be written, the same picker counts.
WHY NOT THE HOOK'S OWN QUESTION. The first build of #3023 took a commit that ran after the hook's
question as Dan's yes. What answers that question was measured on Claude Code 2.1.325 (2026-11-15):
with nobody there, in auto mode, under a permission rule allowing the commit, and from a subagent,
it was refused each time, so neither the classifier nor a rule answers it. But sleep mode
(payload/mods/scope-modes, #834) approves Claude Code's permission prompts for an overnight worker,
so a prompt can be answered with Dan asleep, and a commit having run proves nothing. Sleep mode
never answers a question, and a subagent has no picker to ask with. (That build also paired the
call after a commit with its question by the command's text, which the rtk hook rewrites before
the call runs: the payload after carried `rtk git commit ...`. Nothing here reads a call after.)
A commit adding a line Dan has not approved is still asked about (#2989); its question says a yes
approves nothing and how he approves the line. One whose every added line he approved passes.
The record is held like the list: a shell command naming it (its path holds the list's name) and an
Edit, Write or MultiEdit under it (is_list_record) are asked about.
WHAT THE RECORD CANNOT SEE: a line approved once stays approved for that list in that clone, so one
taken out and put back by a route nobody asked about is trusted again. A line carried here by a
pull, or committed before #3023, is on no record: its write is asked about, the question saying how
Dan approves it. And a script that writes the record under a name built at run time is not seen,
nor is one that writes a picker into the transcript, which the Apply shares.

  on_test_project(workdir, flags, session_id=None, transcript_path=None, agent=True)
      (True, the ref) or (False, why the run's project is not one its checkout marks as test).
      agent is whether the call is a subagent's, which writes nothing on the record.
  is_test_list(tool, tool_input)
      The path an Edit, Write or MultiEdit writes when it is a checkout's TEST_LIST, else None.
  list_shell_change(command, cwd, sw, strip, session_id=None, transcript_path=None, agent=True)
      None, or why a Bash command may write a TEST_LIST or commit a line added to one (#2989).
  is_list_record(tool, tool_input)
      The path an Edit, Write or MultiEdit writes when it is under the record of approved lines.
"""
# datetime and hashlib are imported where they are used: a commit check, which every `git commit`
# pays for, needs neither (2.6 ms of the two on the personal MacBook, 2026-11-15, #3023).
import json
import os
import re
import subprocess
import time

SOURCE = "db-apply"
APPLY = "Apply"
# The picker by which Dan approves one line of a test project list, and the word he chooses.
TRUST_SOURCE = "db-test-project"
TRUST = "Trust"
# The push's own flags an Apply covers: a push of the linked project and nothing more. Any other
# (--db-url, --local, --include-seed, --include-roles, --include-all, --password) is asked about.
PUSH_FLAGS = {"--linked", "--yes", "--workdir", "--debug"}
# The same for the skill's ad hoc write, `supabase db query --linked --yes -f <file>`: the file and
# how the result is printed besides. --remote is --linked's name from CLI 3.0.0 on.
QUERY_FLAGS = {"--linked", "--remote", "--yes", "--workdir", "--debug", "-f", "--file", "-o", "--output"}
TRUE_WORDS = {"true", "1", "t"}
REF = re.compile(r"[A-Za-z0-9_-]{1,64}")
# The checkout's list of its test Supabase projects (claude-config#2643): one ref per line, blank
# lines and lines starting with # ignored, read from beside the supabase folder the run uses.
TEST_LIST = os.path.join(".claude", "supabase-test-projects")
TEST_LIST_BYTES = 64 * 1024
# How long any one run of git may take: showing the committed list, naming the clone, listing a
# checkout or diffing it. The runs of one check share COMMIT_SECONDS besides (_git), so a check ends
# inside the hook's own limit of 10 seconds however many times it runs git.
GIT_SECONDS = 4
# The edits of that list an Edit, Write or MultiEdit makes are held like a database write.
EDIT_TOOLS = ("Edit", "Write", "MultiEdit")
SHA = re.compile(r"[0-9a-f]{64}")


def _sha256(path):
    import hashlib
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _answered(ask, result, is_error, word):
    """Whether Dan himself chose word (APPLY, TRUST) for this picker's one question."""
    if is_error or not isinstance(result, dict) or "afkTimeoutMs" in result:
        return False
    questions = ask.get("questions")
    answers = result.get("answers")
    if not isinstance(questions, list) or len(questions) != 1 or not isinstance(answers, dict) or len(answers) != 1:
        return False
    chosen = next(iter(answers.values()))
    return isinstance(chosen, str) and chosen.strip() == word


def _stamp_ns(stamp):
    """A transcript entry's ISO timestamp in nanoseconds since the epoch, or None."""
    if not isinstance(stamp, str) or not stamp:
        return None
    import datetime
    try:
        t = datetime.datetime.fromisoformat(stamp.replace("Z", "+00:00"))
    except ValueError:
        return None
    if t.tzinfo is None:
        return None
    # Whole seconds plus microseconds, so no float rounding moves the moment later.
    return int(t.timestamp()) * 1_000_000_000 + t.microsecond * 1000


def applies(transcript_path, session_id):
    """(metadata, dry runs) for every /db-apply picker Dan answered Apply in this session, oldest
    first. The dry runs are every Bash call naming --dry-run that had finished without error before
    the picker was put, as (sent at, in ns; the session's directory then; its command), oldest
    first; covered() decides which are dry runs of a push. Raises when the transcript cannot be read."""
    return _pickers(transcript_path, session_id, SOURCE, APPLY)


def _pickers(transcript_path, session_id, source, word):
    """applies(), for the pickers of one source that Dan answered with one word."""
    found, asked, dries, dry_sent = [], {}, [], {}
    with open(transcript_path, "rb") as f:
        for raw in f:
            use = b"AskUserQuestion" in raw or b"dry-run" in raw
            waiting = list(asked) + list(dry_sent)
            if not use and not (waiting and b"tool_result" in raw and any(k in raw for k in waiting)):
                continue
            try:
                e = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            if not isinstance(e, dict) or e.get("sessionId") != session_id:
                continue
            message = e.get("message")
            content = message.get("content") if isinstance(message, dict) else None
            if not isinstance(content, list):
                continue
            for item in content:
                if not isinstance(item, dict):
                    continue
                uid = item.get("id")
                if item.get("type") == "tool_use" and item.get("name") == "AskUserQuestion":
                    ask = item.get("input")
                    meta = ask.get("metadata") if isinstance(ask, dict) else None
                    if (isinstance(uid, str) and uid and isinstance(meta, dict) and meta.get("source") == source
                            and not ask.get("answers")):
                        asked[uid.encode("utf-8", "surrogatepass")] = (ask, list(dries))
                elif item.get("type") == "tool_use" and item.get("name") == "Bash":
                    ti = item.get("input")
                    command = ti.get("command") if isinstance(ti, dict) else None
                    sent = _stamp_ns(e.get("timestamp"))
                    if (isinstance(uid, str) and uid and isinstance(command, str) and "dry-run" in command
                            and sent is not None and isinstance(e.get("cwd"), str)):
                        dry_sent[uid.encode("utf-8", "surrogatepass")] = (sent, e["cwd"], command)
                elif item.get("type") == "tool_result" and isinstance(item.get("tool_use_id"), str):
                    key = item["tool_use_id"].encode("utf-8", "surrogatepass")
                    dry = dry_sent.pop(key, None)
                    if dry is not None and not item.get("is_error"):
                        dries.append(dry)
                    pair = asked.pop(key, None)
                    if pair is not None and _answered(pair[0], e.get("toolUseResult"), item.get("is_error"), word):
                        found.append((pair[0]["metadata"], pair[1]))
    return found


def _pending_why_not(pending, name):
    """None when the dry run's list of pending migrations, recorded on the Apply, is exactly the one
    migration named name, else why not. A push sends every migration the database has not had, so
    an older one never applied would otherwise go with the one Dan applied (Dan, 2026-11-11, #2800)."""
    if not isinstance(pending, list) or not all(isinstance(p, str) and p.strip() for p in pending):
        return ("Dan's Apply recorded no list of the migrations the dry run would push, so what else this "
                "push would send is unknown")
    if not pending:
        return "Dan's Apply recorded an empty list of the migrations the dry run would push"
    names = [os.path.basename(p.strip()) for p in pending]
    if len(names) > 1:
        shown = ", ".join(n[:120] for n in names[:20]) + (", and more" if len(names) > 20 else "")
        return ("the dry run Dan saw would push " + str(len(names)) + " migrations (" + shown
                + "), and an Apply covers a push of the one he applied, " + name)
    if names[0] != name:
        return ("the dry run Dan saw would push " + names[0][:120] + ", not " + name
                + ", the migration he applied")
    return None


def _dry_run_why_not(dries, workdir, folder, names, dry_dir):
    """None when a dry run of workdir's migrations came before the Apply, and nothing in folder
    (holding the .sql files names) has changed since it was sent, else why not (claude-config#2829).
    The latest such dry run is the one judged: the list on the picker was copied from it."""
    here = os.path.realpath(workdir)
    sent, unread = None, None
    for at, cwd, command in dries:
        try:
            d = dry_dir(command, cwd) if dry_dir is not None else None
        except Exception as e:
            d, unread = None, type(e).__name__
        if d is not None and os.path.realpath(d) == here:
            sent = at
    if sent is None and unread is not None:
        return ("a command naming --dry-run before Dan's Apply could not be read (" + unread
                + "), so whether it was a dry run of this project could not be told")
    if sent is None:
        return ("no dry run of this project's migrations finished in this session before Dan's Apply, "
                "so the list of what the push would send was never shown to him")
    changed = []
    for n in names:
        try:
            if os.stat(os.path.join(folder, n)).st_ctime_ns >= sent:
                changed.append(n)
        except OSError as e:
            return n + " could not be read (" + type(e).__name__ + ")"
    if changed:
        shown = ", ".join(n[:120] for n in changed[:20]) + (", and more" if len(changed) > 20 else "")
        return (shown + (" was" if len(changed) == 1 else " were") + " written, renamed or added after "
                "the dry run Dan saw, so the push could send what that dry run did not list")
    return None


def _why_not(meta, dries, ref, folder, names, file, workdir, dry_dir):
    """None when this Apply covers the run, else why not: for a push (file None) of folder's
    migrations, names its .sql files in order; for a `db query` write, of file. Both to project
    ref; dries are the dry runs that finished before the Apply (applies())."""
    newest = names[-1]
    mig, sha, aref = meta.get("migration"), meta.get("sha256"), meta.get("project_ref")
    if not (isinstance(mig, str) and os.path.isabs(mig) and isinstance(sha, str) and SHA.fullmatch(sha.lower())
            and isinstance(aref, str) and aref):
        return "Dan's Apply does not name a file by its absolute path, its sha256 and a project ref"
    name = os.path.basename(mig)
    if aref != ref:
        return "Dan's Apply named project " + aref[:64] + ", and this goes to project " + ref
    if file is not None:
        if os.path.realpath(mig) != os.path.realpath(file):
            return "Dan's Apply named " + mig[:300] + ", not " + file[:300]
    elif os.path.realpath(os.path.dirname(mig)) != os.path.realpath(folder):
        return "Dan's Apply named " + mig[:300] + ", which is not in this project's supabase/migrations"
    elif name != newest:
        return ("Dan's Apply named " + name + ", and " + newest + " is a newer migration this push would "
                "apply too")
    else:
        why = _pending_why_not(meta.get("pending"), name) or _dry_run_why_not(dries, workdir, folder, names, dry_dir)
        if why is not None:
            return why
    try:
        now = _sha256(mig)
    except OSError as e:
        return name + " could not be read (" + type(e).__name__ + ")"
    if now != sha.lower():
        return name + " has changed since Dan's Apply"
    return None


def _flags_why_not(flags, allowed, covers):
    """None when flags [(name, written with =, value)] name only the linked project and flags in
    allowed, else why not, ending with covers ("an Apply covers only a push")."""
    extra = sorted({name for name, _, _ in flags} - allowed)
    if extra:
        return "it carries " + ", ".join(extra) + ", and " + covers + " to the linked project"
    for name, eq, value in flags:
        if name == "--linked" and eq and value.lower() not in TRUE_WORDS:
            return "it carries " + name + "=" + value[:20] + ", and " + covers + " to the linked project"
    return None


def _linked_ref(workdir):
    """(the ref of the project workdir is linked to, None), or (None, why it could not be read)."""
    try:
        with open(os.path.join(workdir, "supabase", ".temp", "project-ref"), "rb") as f:
            # A ref that is not UTF-8 is no ref: refusing it is the decision.
            ref = f.read(200).decode("utf-8", "strict").strip()
    except (OSError, UnicodeDecodeError) as e:
        return None, ("the project it is linked to could not be read from supabase/.temp/project-ref ("
                      + type(e).__name__ + ")")
    if not REF.fullmatch(ref):
        return None, "supabase/.temp/project-ref does not hold a project ref"
    return ref, None


def is_test_list(tool, tool_input):
    """The file_path an Edit, Write or MultiEdit writes when it names a .claude/supabase-test-projects
    (by its last two parts, so a relative path counts too), else None."""
    if tool not in EDIT_TOOLS or not isinstance(tool_input, dict):
        return None
    path = tool_input.get("file_path")
    if not isinstance(path, str):
        return None
    parts = os.path.normpath(path.replace("\\", "/")).split("/")
    return path if parts[-2:] == TEST_LIST.split(os.sep) else None


def is_list_record(tool, tool_input):
    """The file_path an Edit, Write or MultiEdit writes when it is under the record of the list
    lines Dan approved (a state/supabase-test-projects folder, wherever it sits), else None."""
    if tool not in EDIT_TOOLS or not isinstance(tool_input, dict):
        return None
    path = tool_input.get("file_path")
    if not isinstance(path, str):
        return None
    parts = os.path.normpath(path.replace("\\", "/")).lower().split("/")
    held = list(RECORD_PARTS)
    return path if any(parts[i:i + len(held)] == held for i in range(len(parts))) else None


def _uncommitted(path, raw, deadline):
    """None when raw, the bytes of the file at path, are what git has committed for it at HEAD,
    else why not. Only a committed list is trusted, so a session that adds a live ref to it, which
    it can do with any shell command, is asked about until the change is committed."""
    folder, name = os.path.split(path)
    r, why = _git(folder, ["show", "HEAD:./" + name], deadline)
    if r is None:
        return "could not be compared with what git has committed: " + why
    if r.returncode != 0:
        return "is not committed in git, and only a committed list is trusted"
    if r.stdout != raw:
        return "differs from what git has committed, and only a committed list is trusted"
    return None


# THE RECORD OF APPROVED LINES (claude-config#3023; the header says how it is written and why).
# Where it sits under the Claude home, in parts. Its last part is the list's own file name, so any
# shell command naming the record names the list, and is asked about by list_shell_change.
RECORD_PARTS = ("state", TEST_LIST.split(os.sep)[-1])
# How many added lines one question about a commit names. Its answer approves none of them: only
# Dan's picker approves a line (HOW_TO_TRUST).
LINES_SHOWN = 8


def _record_dir():
    home = os.environ.get("CLAUDE_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(home, *RECORD_PARTS)


def _digest(*parts):
    import hashlib
    return hashlib.sha256("\0".join(parts).encode("utf-8", "surrogateescape")).hexdigest()


def _clone(folder, deadline):
    """(the clone folder is a checkout of, folder's path inside the checkout, None), or (None, None,
    why git could not say). The clone is its git common directory, resolved, which every worktree
    of one clone shares and no other clone does; the path is "" at the top, else ends with a slash."""
    r, why = _git(folder, ["rev-parse", "--git-common-dir", "--show-prefix"], deadline)
    if r is None:
        return None, None, why
    if r.returncode != 0:
        return None, None, "git rev-parse failed (exit " + str(r.returncode) + ")"
    out = r.stdout.decode("utf-8", "surrogateescape").split("\n")
    if not out[0]:
        return None, None, "git named no clone"
    return os.path.realpath(os.path.join(folder, out[0])), (out[1] if len(out) > 1 else ""), None


def _on_record():
    """(the lines on this Mac's record of approved lines, None), or (None, why it could not be
    read). No record yet is an empty one."""
    record = os.path.join(_record_dir(), "approved")
    try:
        with open(record, "rb") as f:
            return set(f.read().decode("ascii", "replace").split()), None
    except FileNotFoundError:
        return set(), None
    except OSError as e:
        return None, ("the record of the lines Dan approved, " + record + ", could not be read ("
                      + type(e).__name__ + "), so no line is trusted")


def _put_on_record(keys):
    """Add lines Dan approved in a picker to the record: None once they are on it, else why not. A
    caller trusts no line whose write failed and says why in its question (claude-config#3058).
    Before, the failure was swallowed: his picker let the call through, nothing was kept, and the
    next session asked him to approve the same line again with no reason given."""
    folder = _record_dir()
    record = os.path.join(folder, "approved")
    try:
        # A key is a hex digest, so strict is the decision: a key holding anything else is refused
        # before the record is opened, and never written as a line that would trust nothing. The
        # leading newline ends any fragment an earlier short write left, so the first key here is
        # never fused onto it; the record is read by whitespace, so a blank line costs nothing.
        data = ("\n" + "\n".join(keys) + "\n").encode("ascii", "strict")
    except UnicodeError as e:
        return ("the record of the lines Dan approved, " + record + ", was not written: a key for it was not "
                "a hex digest (" + type(e).__name__ + ")")
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(record, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            written = os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as e:
        return ("the record of the lines Dan approved, " + record + ", could not be written ("
                + type(e).__name__ + (": " + e.strerror if e.strerror else "") + ")")
    if written != len(data):
        return ("the record of the lines Dan approved, " + record + ", took only " + str(written) + " of the "
                + str(len(data)) + " bytes written to it")
    return None


# What a question adds when the record could not take a line Dan approved in a picker, after why.
UNKEPT = (", so his approval was not kept and does not count yet. Once the record can be written, the "
          "same picker counts, with no new one asked (claude-config#3058)")


def _trusted_by_dan(session_id, transcript_path):
    """({(a list's resolved path, a ref)} for every picker of this session Dan answered TRUST, None),
    or (nothing, why his pickers could not be looked for). Fails closed: no transcript, one that
    cannot be read, or a picker naming no absolute list path or no ref gives nothing. The reason is
    kept apart so no question says he approved a line in no picker when none was read (L11)."""
    if not isinstance(transcript_path, str) or not transcript_path or not isinstance(session_id, str) or not session_id:
        return set(), "the call named no session transcript"
    try:
        found = _pickers(transcript_path, session_id, TRUST_SOURCE, TRUST)
    except (OSError, ValueError) as e:
        return set(), "this session's transcript could not be read (" + type(e).__name__ + ")"
    lines = set()
    for meta, _ in found:
        listed, ref = meta.get("list"), meta.get("project_ref")
        if isinstance(listed, str) and listed.startswith("/") and isinstance(ref, str) and REF.fullmatch(ref):
            lines.add((os.path.realpath(listed), ref))
    return lines, None


def _unlooked(unread):
    """What a question adds, of lines the record does not hold, when Dan's pickers could not be
    looked for (unread, from _trusted_by_dan)."""
    return ", and " + unread + ", so a picker of his in this session could not be looked for"


# How Dan approves a line, said by every question about one he has not.
HOW_TO_TRUST = ("To have it trusted, the main session asks Dan with an AskUserQuestion picker of one question whose "
                "options are labelled exactly `" + TRUST + "` and `Cancel`, carrying the metadata {\"source\": \""
                + TRUST_SOURCE + "\", \"list\": \"<absolute path of the list>\", \"project_ref\": \"<the ref>\"}, "
                "with no answers filled in (claude-config#3023)")
LIST_PATH = "/".join(TEST_LIST.split(os.sep))


def _unapproved(workdir, ref, deadline, session_id=None, transcript_path=None, agent=True):
    """None when Dan approved ref's line of workdir's TEST_LIST: it is on this Mac's record, or this
    session's transcript holds his picker for it, which is then put on the record unless the call
    is a subagent's (agent). Else why the line is not trusted. Fails closed: a clone git cannot
    name, a record that cannot be read, and one that cannot take his picker approve nothing."""
    clone, prefix, why = _clone(workdir, deadline)
    if why is not None:
        return "whether Dan approved that line could not be told: " + why
    approved, why = _on_record()
    if why is not None:
        return why
    key = _digest("1", clone, prefix + LIST_PATH, ref)
    if key in approved:
        return None
    dan, unread = _trusted_by_dan(session_id, transcript_path)
    if (os.path.realpath(os.path.join(workdir, TEST_LIST)), ref) in dan:
        why = None if agent else _put_on_record([key])
        if why is None:
            return None
        return "Dan approved that line in a picker in this session, but " + why + UNKEPT
    if unread is not None:
        return ("that line is not on this Mac's record of the lines Dan approved" + _unlooked(unread)
                + ". A line counts only once he has approved it, whatever "
                "commit, merge, pull, rebase or cherry pick carried it to HEAD. " + HOW_TO_TRUST)
    return ("Dan has approved that line in no picker, on this Mac's record or in this session, and a line counts "
            "only once he has, whatever commit, merge, pull, rebase or cherry pick carried it to HEAD. " + HOW_TO_TRUST)


def _not_approved(folder, added, deadline, session_id, transcript_path, agent):
    """(the lines of added, as _list_additions gives them for a commit in folder, that Dan has not
    approved; what the question says of them, reading after "which"). One his picker in this
    session covers is put on the record unless the call is a subagent's. Fails closed: when the
    clone, the record or the top of the checkout cannot be read, every line is unapproved, and the
    question says what could not be read, as it does of a transcript (L11); and when the record
    cannot take the lines his picker covers, they are unapproved too, the question saying why
    (claude-config#3058)."""
    clone, prefix, why = _clone(folder, deadline)
    approved, record_why = _on_record()
    r, top_why = _git(folder, ["rev-parse", "--show-toplevel"], deadline)
    if why is not None or record_why is not None or r is None or r.returncode != 0:
        unread = why or record_why or top_why or "git rev-parse failed (exit " + str(r.returncode) + ")"
        return added, "could not be checked against the lines Dan approved: " + unread
    top_dir = r.stdout.decode("utf-8", "surrogateescape").rstrip("\n")
    dan, unread, left, keys = None, None, [], []
    for p, line, top in added:
        # A list git does not track yet is named from folder; the record names every list from the top.
        rel = p if top else os.path.normpath(prefix + p).replace(os.sep, "/")
        if not REF.fullmatch(line) or rel.startswith(".."):
            left.append((p, line, top))
            continue
        key = _digest("1", clone, rel, line)
        if key in approved:
            continue
        if dan is None:
            dan, unread = _trusted_by_dan(session_id, transcript_path)
        if (os.path.realpath(os.path.join(top_dir, rel)), line) in dan:
            keys.append((key, (p, line, top)))
        else:
            left.append((p, line, top))
    said = ("Dan has approved in no picker" if unread is None
            else "this Mac's record of the lines Dan approved does not hold" + _unlooked(unread))
    failed = _put_on_record([k for k, _ in keys]) if keys and not agent else None
    if failed is None:
        return left, said
    unkept = "Dan approved in a picker in this session, but " + failed + UNKEPT
    return left + [a for _, a in keys], (said + ", or which " + unkept if left else unkept)


def on_test_project(workdir, flags, session_id=None, transcript_path=None, agent=True):
    """(True, the ref) when a `supabase db query -f` run in workdir with flags goes to a project its
    checkout marks as test (TEST_LIST, claude-config#2643), else (False, why not). Fails closed: a
    list missing, unreadable, not text, larger than TEST_LIST_BYTES, other than what git has committed
    for it, or holding any line that is not a ref or a comment marks nothing, and nor does a line
    Dan has not approved in a picker (_unapproved, claude-config#3023), read from this Mac's record
    or from the transcript of session_id; agent is whether the call is a subagent's."""
    why = _flags_why_not(flags, QUERY_FLAGS, "a test project's list covers only a run")
    if why is not None:
        return False, why
    ref, why = _linked_ref(workdir)
    if ref is None:
        return False, why
    path = os.path.join(workdir, TEST_LIST)
    try:
        with open(path, "rb") as f:
            raw = f.read(TEST_LIST_BYTES + 1)
    except OSError as e:
        return False, "project " + ref + " is not marked as test: " + TEST_LIST + " could not be read (" + type(e).__name__ + ")"
    if len(raw) > TEST_LIST_BYTES:
        return False, "project " + ref + " is not marked as test: " + TEST_LIST + " is larger than a list of refs"
    deadline = time.monotonic() + COMMIT_SECONDS
    why = _uncommitted(path, raw, deadline)
    if why is not None:
        return False, "project " + ref + " is not marked as test: " + TEST_LIST + " " + why
    try:
        text = raw.decode("utf-8", "strict")
    except UnicodeDecodeError:
        return False, "project " + ref + " is not marked as test: " + TEST_LIST + " is not text"
    refs = set()
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if not REF.fullmatch(line):
            return False, ("project " + ref + " is not marked as test: " + TEST_LIST
                           + " holds a line that is not a project ref, so none of it is read")
        refs.add(line)
    if ref not in refs:
        return False, "project " + ref + " is not marked as test in " + TEST_LIST
    # In HEAD is not enough: the line counts only when Dan himself approved it, whatever route
    # carried it here (claude-config#3023).
    why = _unapproved(workdir, ref, deadline, session_id, transcript_path, agent)
    if why is not None:
        return False, "project " + ref + " is on " + TEST_LIST + " as committed, but is not trusted as test: " + why
    return True, ref


# A shell command naming the list passes only when it is one of these, reading it (#2989), with no
# redirection writing anywhere but /dev/null. Each takes no option that writes the file it names.
# A pager (less, more) is left out: its own commands can run a shell.
LIST_READERS = {"cat", "head", "tail", "grep", "egrep", "fgrep", "wc", "ls", "stat", "file", "diff",
                "cmp", "md5", "shasum", "sha256sum", "test", "["}
# And the git subcommands that only read, apart from a --output option.
GIT_LIST_READS = {"diff", "show", "log", "status", "blame", "ls-files", "cat-file", "grep"}
# The git subcommands that may come before a commit in its own command, when the checkout holds a
# list: none of them can write a list the command does not name.
GIT_BEFORE_COMMIT = GIT_LIST_READS | {"add", "rm"}
# The whole of the git one check runs: every commit check in one command, one test project check,
# or the approvals one Bash call earned. The hook's own limit is 10 seconds.
COMMIT_SECONDS = 6
EMPTY_TREE = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"


def _list_name():
    return TEST_LIST.split(os.sep)[-1]


def _shown(text, most=160):
    t = " ".join(text.split())
    return t if len(t) <= most else t[:most] + " ..."


def _words_of(text, sw, strip, found=None):
    return sw.command_words(strip(sw.command_rest(text)[0], found))


# Git options that write a file or run a command: --output writes its file, git grep -O runs one on
# the files it matched, --ext-diff runs the configured diff program, and -c in front sets any
# config, a pager or an external diff among them. -O in git diff only reads an order file, and is
# refused with the rest rather than told apart.
GIT_ACTING = ("--output", "-O", "--open-files-in-pager", "--ext-diff")


def _only_reads(text, sw, strip, subs, also=()):
    """Whether one simple command reads and writes nothing: a reader from LIST_READERS, a word in
    also, or git with a subcommand in subs and none of GIT_ACTING, every redirection an input, a
    descriptor copy or /dev/null."""
    found = []
    words = _words_of(text, sw, strip, found)
    for op, target in found:
        if ">" not in op:
            continue
        if target == "/dev/null" or (op.endswith("&") and re.fullmatch(r"\d+|-", target)):
            continue
        return False
    if not words:
        return False
    if os.path.basename(words[0]) in LIST_READERS or words[0] in also:
        return True
    g = sw.git_read(words)
    return (bool(g) and g[0] in subs and "-c" not in g[1]
            and not any(w.startswith(GIT_ACTING) for w in words))


def _git(folder, args, deadline):
    """(the CompletedProcess, None) or (None, why git could not be run in folder before deadline)."""
    left = deadline - time.monotonic()
    if left <= 0:
        return None, "git took longer than " + str(COMMIT_SECONDS) + " seconds"
    env = dict(os.environ, GIT_OPTIONAL_LOCKS="0", GIT_TERMINAL_PROMPT="0")
    try:
        return subprocess.run(["git", "-C", folder, "-c", "core.quotepath=off"] + args, capture_output=True,
                              timeout=min(GIT_SECONDS, left), env=env, stdin=subprocess.DEVNULL), None
    except (OSError, subprocess.SubprocessError) as e:
        return None, "git could not be run (" + type(e).__name__ + ")"


def _counts(line):
    s = line.strip()
    return bool(s) and not s.startswith("#")


def _list_additions(folder, deadline, untracked=True):
    """(lists, added, None) for the checkout folder is in: whether it holds any list, tracked or
    not ignored, and each (path, line, whether the path is as git diff names it, from the top of
    the checkout) a commit there could add to one, from the index or the working tree (which `git
    commit -a`, or an add in the same command, stages), a blank line or a comment aside. ([], [],
    None) when folder is in no checkout; (None, None, why) when git fails.

    untracked False leaves the files git does not track out, for a commit nothing in its command
    comes before but a cd or a read: no commit can take a file that was never added, and listing
    them has git walk the whole working tree, which was over half of what git cost a commit here
    (14.3 ms against 6.7, medians of 15 in this repository on 2026-11-15, claude-config#3023)."""
    spec = ":(top,glob,icase)**/" + "/".join(TEST_LIST.split(os.sep))
    listing = ["ls-files", "-z", "-t", "-c"] + (["-o", "--exclude-standard"] if untracked else [])
    r, why = _git(folder, listing + ["--", spec], deadline)
    if r is None:
        return None, None, why
    if r.returncode != 0:
        if b"not a git repository" in r.stderr:
            return [], [], None
        return None, None, "git ls-files failed (exit " + str(r.returncode) + ")"
    entries = [e.decode("utf-8", "replace") for e in r.stdout.split(b"\0") if e]
    lists = sorted({e[2:] for e in entries})
    added = []
    for e in entries:
        if e.startswith("? "):
            # Not tracked, so all of it would be new: read it as the commit would take it.
            try:
                with open(os.path.join(folder, e[2:]), "rb") as f:
                    text = f.read(TEST_LIST_BYTES).decode("utf-8", "replace")
            except OSError as err:
                return None, None, e[2:] + " could not be read (" + type(err).__name__ + ")"
            added.extend((e[2:], l.strip(), False) for l in text.splitlines() if _counts(l))
    if len(lists) == len([e for e in entries if e.startswith("? ")]):
        return lists, added, None
    r, why = _git(folder, ["rev-parse", "-q", "--verify", "HEAD^{commit}"], deadline)
    if r is None:
        return None, None, why
    base = "HEAD" if r.returncode == 0 else EMPTY_TREE
    for cached in (["--cached"], []):
        r, why = _git(folder, ["diff"] + cached + [base, "--text", "--unified=0", "--no-color", "--no-ext-diff",
                               "--no-textconv", "--src-prefix=a/", "--dst-prefix=b/", "--", spec], deadline)
        if r is None:
            return None, None, why
        if r.returncode != 0:
            return None, None, "git diff failed (exit " + str(r.returncode) + ")"
        path = None
        for line in r.stdout.decode("utf-8", "replace").splitlines():
            if line.startswith("+++ "):
                path = line[6:] if line.startswith("+++ b/") else None
            elif line.startswith("+") and _counts(line[1:]):
                added.append((path or "a test project list", line[1:].strip(), path is not None))
    return lists, added, None


def _named_thing(text):
    """What a command naming the list's file name names: the record of approved lines when the name
    comes under a state folder, else the list."""
    if "/".join(RECORD_PARTS) in text.lower().replace("\\", "/"):
        return "this hook's record of the test project lines Dan approved (" + "/".join(RECORD_PARTS) + ")"
    return TEST_LIST + ", the list of the test Supabase projects of a checkout,"


def list_shell_change(command, cwd, sw, strip, session_id=None, transcript_path=None, agent=True):
    """None when a Bash command neither writes a checkout's TEST_LIST nor commits a line added to
    one (claude-config#2989), else why it may. Before this, an `echo <ref> >>` into the list and
    then `git commit` made the project trusted with no question.

    A WRITE: any command naming the list (its file name, in any case, since macOS matches either)
    that is not one only reading it (_only_reads), and a command that names it where no simple
    command of it does (a heredoc body, a string it cannot read). A COMMIT: a `git commit` whose
    checkout could add a line, other than a blank or a comment, to any list in it, from the index or
    the working tree; one only removing lines passes. In a checkout holding a list, a commit after
    any command other than cd, a reader or a git add, rm or read in the same call is asked about too,
    since that command could write the list, by a glob or a variable, before the commit stages it.
    A commit whose checkout cannot be told (a variable, --git-dir, GIT_DIR) is asked about.

    A yes to a question here approves no line (claude-config#3023): a line is trusted only once
    Dan approved it in a picker (_unapproved). So a commit is asked about only for the added lines
    he has not approved (_not_approved, reading the record and the transcript of session_id), the
    question naming up to LINES_SHOWN of them and how he approves one; agent is whether the call is
    a subagent's, which writes nothing on the record. A list one of these commands cannot see being
    committed (a script, a name built at run time, an alias, `git commit-tree`, a merge, a cherry
    pick, a pull) is not a gap any more: its lines reach HEAD with no question, are approved by
    nobody, and so mark nothing. sw is lib/shell-words.py and strip
    db-write-calls' strip_redirects, which with found lists the redirections it took out."""
    name = _list_name()
    named = name in command.lower()
    if not named and "commit" not in command:
        return None
    here = cwd if isinstance(cwd, str) and cwd.startswith("/") else ""
    records = sw.every_command(command, here)
    rest = command
    before = []
    deadline = time.monotonic() + COMMIT_SECONDS
    staged = None
    for d, text, _, why, _ in records:
        if name in text.lower():
            if why or not _only_reads(text, sw, strip, GIT_LIST_READS):
                held = ("the command `" + _shown(text) + "` names " + _named_thing(text)
                        + " and is not one that only reads it")
                # A git add or rm of the list only stages it, so its question waits for the end: a
                # commit after it in the same command is asked about first, by the question that
                # names the lines and says how Dan approves them (claude-config#3023).
                if why or not _only_reads(text, sw, strip, GIT_BEFORE_COMMIT):
                    return held
                staged = staged or held
            rest = rest.replace(text, "", 1)
        words = _words_of(text, sw, strip)
        g = sw.git_read(words) if words else None
        if not g or g[0] != "commit":
            before.append((text, why))
            continue
        front, assigns = g[1], sw.command_rest(text)[1]
        if any(w.startswith(("--git-dir", "--work-tree")) for w in front) or re.search(r"\bGIT_(DIR|WORK_TREE)=", assigns):
            return ("the command `" + _shown(text) + "` commits with git pointed at a checkout this hook "
                    "cannot read, so whether it adds a project to a " + TEST_LIST + " could not be told")
        where = sw.git_dir(sw.command_rest(text)[0])
        folder = where if where.startswith("/") else os.path.join(d or here, where) if (d or here) else ""
        if not folder.startswith("/") or "$" in folder or "`" in folder:
            return ("the command `" + _shown(text) + "` commits in a checkout this hook cannot tell, so "
                    "whether it adds a project to a " + TEST_LIST + " could not be told")
        # Nothing before this commit but a cd or a read: it can take no file git does not track.
        alone = all(not unread and _only_reads(t, sw, strip, GIT_LIST_READS, ("cd",)) for t, unread in before)
        lists, added, why = _list_additions(folder, deadline, untracked=not alone)
        if why is not None:
            return ("the command `" + _shown(text) + "` commits, and whether it adds a project to a "
                    + TEST_LIST + " could not be told: " + why)
        if added:
            # Each line once, though the index and the working tree may both hold it.
            added, unapproved = _not_approved(folder, list(dict.fromkeys(added)), deadline, session_id,
                                              transcript_path, agent)
        if added:
            shown = ", ".join("the line " + _shown(l, 80) + " added to " + _shown(p, 120)
                              for p, l, _ in added[:LINES_SHOWN])
            return ("the command `" + _shown(text) + "` would commit " + shown
                    + (", and more" if len(added) > LINES_SHOWN else "")
                    + ", which " + unapproved + ". A project on a committed " + TEST_LIST + " has its "
                    "supabase db query -f runs pass without asking only once he has approved its line, so "
                    "answering yes here approves nothing: the line will mark no project as test. " + HOW_TO_TRUST)
        if lists:
            for t, unread in before:
                # cd, a reader, or a git add, rm or read, writing nothing by a redirection or option.
                if not unread and _only_reads(t, sw, strip, GIT_BEFORE_COMMIT, ("cd",)):
                    continue
                return ("the command commits in a checkout holding " + ", ".join(_shown(p, 120) for p in lists[:3])
                        + " after `" + _shown(t) + "`, which could write the list before the commit stages it")
        before.append((text, why))
    if staged is not None:
        return staged
    if named and name in rest.lower():
        return ("the command names " + TEST_LIST + ", the list of the test Supabase projects of a "
                "checkout, where this hook cannot tell whether it writes it (a heredoc, or a string it "
                "cannot read)")
    return None


def covered(workdir, flags, session_id, transcript_path, file=None, dry_dir=None):
    """(True, the sentence naming the Apply) when Dan's Apply in this session covers a run in
    workdir with flags [(name, written with =, value)]: a `db push` when file is None, else a
    `db query` running the statements of file, an absolute path. Else (False, why not). dry_dir
    reads which directory a Bash command dry runs a push of (module docstring)."""
    why = _flags_why_not(flags, PUSH_FLAGS if file is None else QUERY_FLAGS, "an Apply covers only "
                         + ("a push" if file is None else "a run"))
    if why is not None:
        return False, why
    if not isinstance(session_id, str) or not session_id:
        return False, "the call names no session, so no Apply in it could be found"
    if not isinstance(transcript_path, str) or not transcript_path:
        return False, "the call names no session transcript, where Dan's Apply would be"
    ref, why = _linked_ref(workdir)
    if ref is None:
        return False, why
    folder, names = os.path.join(workdir, "supabase", "migrations"), [None]
    if file is None:
        try:
            names = sorted(n for n in os.listdir(folder) if n.endswith(".sql"))
        except OSError as e:
            return False, "its supabase/migrations folder could not be read (" + type(e).__name__ + ")"
        if not names:
            return False, "its supabase/migrations folder holds no migration"
    try:
        given = applies(transcript_path, session_id)
    except OSError as e:
        return False, ("the session's transcript, where Dan's Apply would be, could not be read ("
                       + type(e).__name__ + ")")
    if not given:
        return False, "Dan has answered no /db-apply Apply in this session"
    why = None
    for meta, dries in reversed(given):
        why = _why_not(meta, dries, ref, folder, names, file, workdir, dry_dir)
        if why is None:
            what = "migration " + names[-1] if file is None else os.path.basename(file)
            return True, ("Dan answered Apply for " + what + " on project " + ref
                          + " in this session, and the file is unchanged since")
    return False, why
