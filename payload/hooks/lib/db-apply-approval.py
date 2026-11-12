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
writes a record of its own, so there is no record file a command could forge or leave behind; a
transcript that cannot be read covers nothing.

WHAT IT CANNOT SEE: the database itself. The pending list is what the dry run printed before the
picker; a change on the database between that dry run and the push is not reflected in it. Nor a
`supabase link` to another project between the dry run and the Apply in the same directory: the
CLI's own writes to supabase/.temp were not measured, so its files are not timed (#2829).

  covered(workdir, flags, session_id, transcript_path, file=None, dry_dir=None)
      (True, the sentence naming the Apply) or (False, why no Apply covers the run); file is None
      for a push, else the absolute path of the -f file a `db query` runs. dry_dir(command, cwd)
      is the directory a Bash command dry runs a push of, or None (db-write-calls dry_push_dir);
      without it no dry run is found, so no push is covered.
"""
import datetime
import hashlib
import json
import os
import re

SOURCE = "db-apply"
APPLY = "Apply"
# The push's own flags an Apply covers: a push of the linked project and nothing more. Any other
# (--db-url, --local, --include-seed, --include-roles, --include-all, --password) is asked about.
PUSH_FLAGS = {"--linked", "--yes", "--workdir", "--debug"}
# The same for the skill's ad hoc write, `supabase db query --linked --yes -f <file>`: the file and
# how the result is printed besides. --remote is --linked's name from CLI 3.0.0 on.
QUERY_FLAGS = {"--linked", "--remote", "--yes", "--workdir", "--debug", "-f", "--file", "-o", "--output"}
TRUE_WORDS = {"true", "1", "t"}
REF = re.compile(r"[A-Za-z0-9_-]{1,64}")
SHA = re.compile(r"[0-9a-f]{64}")


def _sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _answered_apply(ask, result, is_error):
    """Whether Dan himself chose Apply for this picker's one question."""
    if is_error or not isinstance(result, dict) or "afkTimeoutMs" in result:
        return False
    questions = ask.get("questions")
    answers = result.get("answers")
    if not isinstance(questions, list) or len(questions) != 1 or not isinstance(answers, dict) or len(answers) != 1:
        return False
    chosen = next(iter(answers.values()))
    return isinstance(chosen, str) and chosen.strip() == APPLY


def _stamp_ns(stamp):
    """A transcript entry's ISO timestamp in nanoseconds since the epoch, or None."""
    if not isinstance(stamp, str) or not stamp:
        return None
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
                    if (isinstance(uid, str) and uid and isinstance(meta, dict) and meta.get("source") == SOURCE
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
                    if pair is not None and _answered_apply(pair[0], e.get("toolUseResult"), item.get("is_error")):
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


def covered(workdir, flags, session_id, transcript_path, file=None, dry_dir=None):
    """(True, the sentence naming the Apply) when Dan's Apply in this session covers a run in
    workdir with flags [(name, written with =, value)]: a `db push` when file is None, else a
    `db query` running the statements of file, an absolute path. Else (False, why not). dry_dir
    reads which directory a Bash command dry runs a push of (module docstring)."""
    allowed, what = (PUSH_FLAGS, "a push") if file is None else (QUERY_FLAGS, "a run")
    extra = sorted({name for name, _, _ in flags} - allowed)
    if extra:
        return False, ("it carries " + ", ".join(extra) + ", and an Apply covers only " + what
                       + " to the linked project")
    for name, eq, value in flags:
        if name == "--linked" and eq and value.lower() not in TRUE_WORDS:
            return False, ("it carries " + name + "=" + value[:20] + ", and an Apply covers only " + what
                           + " to the linked project")
    if not isinstance(session_id, str) or not session_id:
        return False, "the call names no session, so no Apply in it could be found"
    if not isinstance(transcript_path, str) or not transcript_path:
        return False, "the call names no session transcript, where Dan's Apply would be"
    try:
        with open(os.path.join(workdir, "supabase", ".temp", "project-ref"), "rb") as f:
            # A ref that is not UTF-8 is no ref: refusing it is the decision.
            ref = f.read(200).decode("utf-8", "strict").strip()
    except (OSError, UnicodeDecodeError) as e:
        return False, ("the project it is linked to could not be read from supabase/.temp/project-ref ("
                       + type(e).__name__ + ")")
    if not REF.fullmatch(ref):
        return False, "supabase/.temp/project-ref does not hold a project ref"
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
