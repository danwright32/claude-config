"""Whether Dan approved the exact wording of an announcement (claude-config#3666).

A pull request labelled changelog/announce carries the post for agents under `## Announcement`, and
once it is live that post is drafted in the announcements channel. Dan's words for this feature: "it
should ask me before applying the label". So the wording is approved by him, in a picker, after it
was opened in front of him, and this file says whether a given wording is one he approved. The merge
gate (require-changelog-tag.sh) asks it for every announce pull request, and announce-label-ask.sh
asks it before the label goes on one.

HOW DAN IS ASKED. The session writes the post to a file, runs /no-ai-tells on it, opens it in BBEdit
with the front window flag, and asks ONE AskUserQuestion picker of one question, naming the pull
request or feature and the channel, with the options `Approve the wording` and `Not yet`, and this
metadata:

    {"source": "changelog-announce", "repo": "<owner/name>", "file": "<absolute path>"}

He may edit the file before he answers. A picker cannot hold the post itself: it shows about 20 rows
and refuses labelled links (payload/mods/mod-kit/hooks/shown.ts).

WHAT COUNTS AS HIS APPROVAL. A picker of that source in the session making the call, answered
`Approve the wording` by Dan himself. "Himself" is lib/db-apply-approval.py's rule, called and not
copied: one question, no answer filled in by the caller, not closed by its own timeout, read from
the session's own transcript, and a picker he could read as written (its _answered and
_read_by_dan). Then, all of these, each failure said in its own words:
  - the file was OPENED IN FRONT OF HIM before the picker was put: the transcript holds a Bash call
    that is nothing but a BBEdit open of that path (`bbedit_tool --front-window <file>`, or `open -a
    BBEdit <file>`), which finished without error before he answered.
  - nothing of the session's touched the file between that open and his answer: no Edit, Write,
    MultiEdit or NotebookEdit of it, no Bash command naming its file name (which may write it), no
    agent sent a prompt naming it. So what he was shown is what he answered about.
  - the file has not changed since he answered: its status change time (st_ctime, which a write, a
    rename or a replacement sets and no command sets back) is before the moment his answer was
    recorded. Between the open and the answer the file may change, because that is Dan editing it.
  - no later picker about the same file ended any other way (`Not yet`, a timeout): the last word
    on a file is the one that counts.
  - the file holds wording, and it can be hashed.

WHAT IS HASHED. The FILE as it stands, never a hash the session supplies: a hash in the metadata
is not read at all. The hash is lib/changelog-entry.js's announcementHash, the sha256 of its one
normalised form (line endings, spaces at the ends of lines, blank lines), asked through its
announcement-hash command line, so the file here and the block GitHub holds are hashed by one
function and this file normalises nothing itself.

THE RECORD keeps an approval past the session: <record>/record.jsonl, where <record> is
$ANNOUNCE_APPROVALS_DIR when set (the tests) and else $CLAUDE_HOME/state/announce-approvals, on this
Mac only (the state folder is never synced, as the record of approved test project lines is kept).
One JSON object a line, each carrying its repository:
    {"kind": "approved", "repo": "<owner/name>", "hash": "<sha256>", "at": "<when>", "session": "<id>"}
    {"kind": "used", "repo": ..., "hash": ..., "pr": <number>, "closes": [...], "unread": ..., "at": ...}
A hook run that reads his Approve writes the approved line, unless the call is a subagent's (the
payload carries agent_id): a subagent's call counts his picker for that call and writes nothing. When
the record cannot take a line, the main session's call still counts his picker and the failed save
is said beside it, as lib/db-apply-approval.py does for a line he approved (Dan, 2026-11-16).

A `used` line is written by the merge gate when it lets an announce pull request through: which pull
request took the wording, and, for the later check that a feature Dan said yes to announcing does
not finish under another label, each issue that pull request closes with its milestone. It is
written BEFORE the merge runs, so it says the gate let the merge go ahead, never that GitHub merged
it: a reader that needs "merged" asks GitHub about the pull request. It grants nothing, so it is
written whoever makes the call, and a hash stays approved after it is used.

WHAT IT CANNOT SEE. A write to the file, between the open and his answer, by something the
transcript does not name it in (a script building the name at run time, a subagent's own tools).
Whether the picker's question named the right channel. A record line written by hand: the record is
guarded by announce-label-ask.sh, which refuses an edit under it and a shell command naming it that
is not one only reading it, but a script that builds the path at run time is not seen. And an
approval given on one Mac is unknown to the other, which asks again.

  check(repo, digest, payload)
      {"approved": bool, "why": str, "how": HOW_TO_ASK, "notes": [str]}: whether digest, an
      announcementHash, is wording Dan approved for repo, after reading this session's pickers.
      payload is the hook payload (session_id, transcript_path, agent_id).
  mark_used(repo, digest, pr, closes, unread)   None, or why the line could not be written.
  hash_of(data, body=False)                     (announcement-hash's answer, None) or (None, why).
  is_record_path(path)                          whether a path is the record or under it.

Command lines, each printing JSON and exiting 0 when it could answer:
  announce-approval.py check --repo <owner/name> --hash <sha256>     the hook payload on standard input
  announce-approval.py used --repo <owner/name> --hash <sha256> --pr <number> [--closes <json>] [--unread <why>]
  announce-approval.py list                                          the record, as it reads
"""
import importlib.util
import json
import os
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True

SOURCE = "changelog-announce"
APPROVE = "Approve the wording"
RECORD_NAME = "announce-approvals"
RECORD_FILE = "record.jsonl"
SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9._-]+")
SHA = re.compile(r"[0-9a-f]{64}")
# The wording file's name is looked for in the transcript's raw lines, so it must read there as it
# is written: a name holding a character JSON escapes would never be found.
PLAIN_NAME = re.compile(r"[A-Za-z0-9._-]+")
WORDING_BYTES = 256 * 1024
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
# A tool that hands the file's name to something that may write it.
SENDING_TOOLS = ("Agent", "Task")
HASH_SECONDS = 5
CHECK_SECONDS = 12
HERE = os.path.dirname(os.path.abspath(__file__))

HOW_TO_ASK = (
    "To ask him: write the post to a file, run /no-ai-tells on it, open it in a command of its own with "
    "`/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window <file>`, then ask ONE AskUserQuestion "
    "picker of one question naming the pull request or feature and the channel, with the options `" + APPROVE
    + "` and `Not yet` and the metadata {\"source\": \"" + SOURCE + "\", \"repo\": \"<owner/name>\", \"file\": "
    "\"<absolute path>\"}. Leave the file alone once it is open (he may edit it before he answers), and make the "
    "pull request's Announcement block that file's text.")


def _part(name, file):
    """A library beside this file, loaded by its path, never by name."""
    spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
    lib = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(lib)
    return lib


def record_dir():
    named = os.environ.get("ANNOUNCE_APPROVALS_DIR")
    if named:
        return named
    home = os.environ.get("CLAUDE_HOME") or os.path.join(os.path.expanduser("~"), ".claude")
    return os.path.join(home, "state", RECORD_NAME)


def record_path():
    return os.path.join(record_dir(), RECORD_FILE)


def is_record_path(path):
    """Whether path is the record's folder or anything under it, however it is spelled."""
    if not isinstance(path, str) or not path:
        return False
    folder = os.path.realpath(record_dir())
    real = os.path.realpath(path)
    return real == folder or real.startswith(folder + os.sep)


def repo_key(repo):
    """A repository as the record names it, or None for text that is no owner/name."""
    if isinstance(repo, str) and SLUG.fullmatch(repo.strip()):
        return repo.strip().lower()
    return None


def read_record():
    """(the record's lines that read, oldest first, None), or (None, why it could not be read). No
    record yet is an empty one. A line that is not a JSON object is passed over: it approves nothing."""
    path = record_path()
    try:
        with open(path, "rb") as f:
            raw = f.read().decode("utf-8", "replace")
    except FileNotFoundError:
        return [], None
    except OSError as e:
        return None, ("the record of the wording Dan approved, " + path + ", could not be read ("
                      + type(e).__name__ + ")")
    out = []
    for line in raw.split("\n"):
        if not line.strip():
            continue
        try:
            entry = json.loads(line)
        except ValueError:
            continue
        if isinstance(entry, dict):
            out.append(entry)
    return out, None


def _on_record(entries, repo, digest, kind="approved"):
    return any(e.get("kind") == kind and e.get("repo") == repo and e.get("hash") == digest for e in entries)


def _append(entries):
    """Add lines to the record: None once they are on it, else why not."""
    folder, path = record_dir(), record_path()
    # The leading newline ends any fragment an earlier short write left, so the first line here is
    # never fused onto it; a blank line costs the reader nothing.
    data = ("\n" + "\n".join(json.dumps(e, sort_keys=True) for e in entries) + "\n").encode("utf-8")
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            written = os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as e:
        return ("the record of the wording Dan approved, " + path + ", could not be written ("
                + type(e).__name__ + (": " + e.strerror if e.strerror else "") + ")")
    if written != len(data):
        return ("the record of the wording Dan approved, " + path + ", took only " + str(written) + " of the "
                + str(len(data)) + " bytes written to it")
    return None


def _now():
    import datetime
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def hash_of(data, body=False, deadline=None):
    """lib/changelog-entry.js's announcement-hash of data, bytes: ({found, hash, lines}, None), or
    (None, why it could not be asked). body says data is a pull request description, hashed by its
    Announcement block; without it data is the wording itself."""
    import shutil
    limit = HASH_SECONDS
    if deadline is not None:
        limit = min(limit, deadline - time.monotonic())
        if limit <= 0:
            return None, "no time was left in the hook to hash the wording"
    node = shutil.which("node")
    if node is None:
        return None, "node is not on PATH, and lib/changelog-entry.js, which hashes the wording, runs under it"
    args = [node, os.path.join(HERE, "changelog-entry.js"), "announcement-hash"] + (["--body"] if body else [])
    try:
        r = subprocess.run(args, input=data, capture_output=True, timeout=limit)
    except subprocess.TimeoutExpired:
        return None, "lib/changelog-entry.js did not hash the wording in " + ("%.1f" % limit) + " seconds"
    except OSError as e:
        return None, "lib/changelog-entry.js could not be started (" + type(e).__name__ + ")"
    try:
        answer = json.loads(r.stdout.decode("utf-8", "replace"))
    except ValueError:
        answer = None
    if (r.returncode != 0 or not isinstance(answer, dict) or not isinstance(answer.get("hash"), str)
            or not isinstance(answer.get("found"), bool) or (answer["hash"] and not SHA.fullmatch(answer["hash"]))):
        return None, "lib/changelog-entry.js gave no hash that could be read (exit " + str(r.returncode) + ")"
    return answer, None


def _bbedit_open(command, cwd, target, sw):
    """Whether a Bash command is nothing but a BBEdit open of target that puts it in front: the
    helper with its front window flag, or `open -a BBEdit`. One simple command, no redirection, no
    second command, so nothing else in the call can write the file."""
    here = cwd if isinstance(cwd, str) and cwd.startswith("/") else ""
    try:
        records = sw.every_command(command, here)
    except Exception:  # noqa: BLE001  a command nobody can read is not an open
        return False
    # The helper is run by its path, which the reader marks as running a file ("direct"): that one
    # record is still the whole command. Any other wrapper (a shell's string, eval) is not an open.
    if len(records) != 1 or records[0][2] not in ("", "direct") or (records[0][3] and not records[0][2]):
        return False
    try:
        words = sw.command_words(sw.command_rest(records[0][1])[0])
    except Exception:  # noqa: BLE001
        return False
    if words[:2] == ["rtk", "proxy"]:
        words = words[2:]
    elif words[:1] == ["rtk"]:
        words = words[1:]
    if not words:
        return False

    def names_target(word):
        path = os.path.expanduser(word)
        if not os.path.isabs(path):
            if not here:
                return False
            path = os.path.join(here, path)
        return os.path.realpath(path) == target

    program, rest = os.path.basename(words[0]), words[1:]
    if program in ("bbedit_tool", "bbedit"):
        return (len(rest) == 2 and "--front-window" in rest
                and names_target(rest[1] if rest[0] == "--front-window" else rest[0]))
    if program == "open":
        return (len(rest) == 3 and rest[0] == "-a" and os.path.basename(rest[1].rstrip("/")).lower() in ("bbedit", "bbedit.app")
                and names_target(rest[2]))
    return False


def _entries(transcript_path, session_id, wanted):
    """The session's transcript entries whose raw line wanted(raw) takes, as (line number, entry)."""
    with open(transcript_path, "rb") as f:
        for n, raw in enumerate(f):
            if not wanted(raw):
                continue
            try:
                e = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                continue
            if isinstance(e, dict) and e.get("sessionId") == session_id:
                yield n, e


def _items(entry):
    message = entry.get("message")
    content = message.get("content") if isinstance(message, dict) else None
    return [i for i in content if isinstance(i, dict)] if isinstance(content, list) else []


def _asked(transcript_path, session_id):
    """Every picker of SOURCE the session put that came back, oldest first, as a dict: ask (its
    input), result, is_error, sent and answered (line numbers) and stamp (when the answer was
    recorded, as written)."""
    waiting, out = {}, []

    def wanted(raw):
        if b"AskUserQuestion" in raw and SOURCE.encode() in raw:
            return True
        return bool(waiting) and b"tool_result" in raw and any(k in raw for k in waiting)

    for n, e in _entries(transcript_path, session_id, wanted):
        for item in _items(e):
            uid = item.get("id")
            if item.get("type") == "tool_use" and item.get("name") == "AskUserQuestion":
                ask = item.get("input")
                meta = ask.get("metadata") if isinstance(ask, dict) else None
                # One that came with its answers filled in was never put to him: the dialog returns
                # them without asking (lib/db-apply-approval.py's rule), so it is no picker at all.
                if (isinstance(uid, str) and uid and isinstance(meta, dict) and meta.get("source") == SOURCE
                        and not ask.get("answers")):
                    waiting[uid.encode("utf-8", "surrogatepass")] = (ask, n)
            elif item.get("type") == "tool_result" and isinstance(item.get("tool_use_id"), str):
                pair = waiting.pop(item["tool_use_id"].encode("utf-8", "surrogatepass"), None)
                if pair is not None:
                    out.append({"ask": pair[0], "sent": pair[1], "answered": n, "stamp": e.get("timestamp"),
                                "result": e.get("toolUseResult"), "is_error": item.get("is_error")})
    return out


def _file_events(transcript_path, session_id, targets, sw):
    """What the session did with each wording file, {its path: (opens, touches)}: opens as (line
    sent, line it finished without error), touches as the line of each call that wrote the file or
    may have (module docstring). targets is {a file's real path: its file name}."""
    names = {name.encode(): path for path, name in targets.items()}
    opening = {}
    found = {path: ([], []) for path in targets}

    def wanted(raw):
        if any(name in raw for name in names):
            return True
        return bool(opening) and b"tool_result" in raw and any(k in raw for k in opening)

    for n, e in _entries(transcript_path, session_id, wanted):
        cwd = e.get("cwd")
        for item in _items(e):
            uid = item.get("id")
            if item.get("type") == "tool_result" and isinstance(item.get("tool_use_id"), str):
                was = opening.pop(item["tool_use_id"].encode("utf-8", "surrogatepass"), None)
                if was is not None and not item.get("is_error"):
                    found[was[0]][0].append((was[1], n))
                continue
            if item.get("type") != "tool_use" or not isinstance(item.get("input"), dict):
                continue
            tool, ti = item.get("name"), item["input"]
            for path, name in targets.items():
                if tool == "Bash":
                    command = ti.get("command")
                    if not isinstance(command, str) or name not in command:
                        continue
                    if isinstance(uid, str) and uid and _bbedit_open(command, cwd, path, sw):
                        opening[uid.encode("utf-8", "surrogatepass")] = (path, n)
                    else:
                        found[path][1].append(n)
                elif tool in EDIT_TOOLS:
                    written = ti.get("file_path") or ti.get("notebook_path")
                    if isinstance(written, str) and written:
                        if not os.path.isabs(written) and isinstance(cwd, str):
                            written = os.path.join(cwd, written)
                        if os.path.realpath(written) == path:
                            found[path][1].append(n)
                elif tool in SENDING_TOOLS:
                    if name in json.dumps(ti):
                        found[path][1].append(n)
    return found


def approvals(session_id, transcript_path, deadline=None):
    """(approved, untaken, None) for this session's pickers, or ([], [], why they could not be looked
    for). approved is [{repo, hash, file}] for each wording Dan approved that counts (module
    docstring); untaken is [{repo, file, why}] for each Approve of his that does not, so a refusal
    can say what stood in the way of the very approval the session thinks it holds."""
    if not isinstance(transcript_path, str) or not transcript_path or not isinstance(session_id, str) or not session_id:
        return [], [], "the call named no session transcript, so a picker of his in this session could not be looked for"
    try:
        asked = _asked(transcript_path, session_id)
    except OSError as e:
        return [], [], ("this session's transcript could not be read (" + type(e).__name__
                        + "), so a picker of his in this session could not be looked for")
    if not asked:
        return [], [], None
    ap = _part("db_apply_approval_shared", "db-apply-approval.py")
    sw = _part("shell_words_shared", "shell-words.py")

    # The last word on each file: a later picker about it that ended any other way takes an earlier
    # Approve back.
    last, untaken = {}, []
    for p in asked:
        meta = p["ask"]["metadata"]
        repo, file = repo_key(meta.get("repo")), meta.get("file")
        mine = p["ask"] if isinstance(p["ask"], dict) else {}
        said = ap._answered(mine, p["result"], p["is_error"], APPROVE)
        if said and (repo is None or not isinstance(file, str) or not file.startswith("/")):
            untaken.append({"repo": repo or "", "file": file if isinstance(file, str) else "",
                            "why": "its metadata does not name the repository as owner/name and the wording file by "
                                   "its absolute path"})
            continue
        if repo is None or not isinstance(file, str) or not file.startswith("/"):
            continue
        p.update(repo=repo, file=os.path.realpath(file), said=said)
        last[(repo, p["file"])] = p
    candidates = []
    for p in last.values():
        if not p["said"]:
            continue
        if not PLAIN_NAME.fullmatch(os.path.basename(p["file"])):
            untaken.append({"repo": p["repo"], "file": p["file"],
                            "why": "the wording file's name holds a character other than letters, digits, dot, dash "
                                   "and underscore, so the commands that named it cannot be found in the transcript"})
            continue
        candidates.append(p)
    if not candidates:
        return [], untaken, None

    # Read by Dan as written, by the one check of text a person approves in a picker.
    unread = []
    shown = []
    for p in candidates:
        got = p["result"].get("questions")
        shown.append((dict(p["ask"], questions=got) if isinstance(got, list) and got else p["ask"], p))
    readable = ap._read_by_dan(shown, APPROVE, unread, deadline)
    for p, why in unread:
        untaken.append({"repo": p["repo"], "file": p["file"], "why": why})
    if not readable:
        return [], untaken, None

    try:
        events = _file_events(transcript_path, session_id,
                              {p["file"]: os.path.basename(p["file"]) for p in readable}, sw)
    except OSError as e:
        return [], untaken, ("this session's transcript could not be read (" + type(e).__name__
                             + "), so whether the wording was opened in front of him could not be told")
    approved = []
    for p in readable:
        why = _not_shown(p, events[p["file"]], ap)
        digest = None
        if why is None:
            digest, why = _file_hash(p["file"], deadline)
        if why is not None:
            untaken.append({"repo": p["repo"], "file": p["file"], "why": why})
        else:
            approved.append({"repo": p["repo"], "hash": digest, "file": p["file"]})
    return approved, untaken, None


def _not_shown(p, events, ap):
    """None when the file Dan approved is the one that was in front of him and has not changed since,
    else why not."""
    opens, touches = events
    before = [sent for sent, done in opens if sent < p["sent"] and done < p["answered"]]
    if not before:
        return ("the file was not opened in front of him before the picker: no Bash call in this session is "
                "nothing but a BBEdit open of it with the front window flag that finished without error")
    opened = max(before)
    if any(opened < t < p["answered"] for t in touches):
        return ("after the file was opened for him and before he answered, this session wrote it, or ran a "
                "command or sent an agent a prompt naming it, so what he had in front of him may not be what is "
                "in it")
    answered = ap._stamp_ns(p["stamp"])
    if answered is None:
        return "the transcript does not say when he answered, so whether the file changed afterwards could not be told"
    try:
        changed = os.stat(p["file"]).st_ctime_ns
    except OSError as e:
        return "the file could not be read (" + type(e).__name__ + "), so the wording he approved cannot be hashed"
    if changed >= answered:
        return "the file has changed since he answered, so it no longer holds the wording he approved"
    return None


def _file_hash(path, deadline):
    try:
        with open(path, "rb") as f:
            data = f.read(WORDING_BYTES + 1)
    except OSError as e:
        return None, "the file could not be read (" + type(e).__name__ + "), so the wording he approved cannot be hashed"
    if len(data) > WORDING_BYTES:
        return None, "the file is larger than " + str(WORDING_BYTES // 1024) + " KB, which is no announcement"
    answer, why = hash_of(data, False, deadline)
    if why is not None:
        return None, why
    if not answer["hash"]:
        return None, "the file holds no wording"
    return answer["hash"], None


def check(repo, digest, payload):
    """Whether digest is wording Dan approved for repo (module docstring)."""
    out = {"approved": False, "why": "", "how": HOW_TO_ASK, "notes": []}
    key = repo_key(repo)
    if key is None:
        out["why"] = "the repository could not be told as owner/name, so no approval of Dan's could be looked up for it"
        return out
    if not isinstance(digest, str) or not SHA.fullmatch(digest):
        out["why"] = "the announcement gave no hash, so there is no wording to look an approval up for"
        return out
    payload = payload if isinstance(payload, dict) else {}
    deadline = time.monotonic() + CHECK_SECONDS
    found, untaken, unlooked = approvals(payload.get("session_id"), payload.get("transcript_path"), deadline)
    entries, unreadable = read_record()
    agent = bool(payload.get("agent_id"))
    if found and not agent:
        fresh = [f for f in found if entries is None or not _on_record(entries, f["repo"], f["hash"])]
        if fresh:
            failed = _append([{"kind": "approved", "repo": f["repo"], "hash": f["hash"], "at": _now(),
                               "session": payload.get("session_id")} for f in fresh])
            if failed:
                out["notes"].append(
                    "Dan approved the wording in " + ", ".join(sorted({f["file"] for f in fresh})) + " in a picker in "
                    "this session, but that approval could not be saved: " + failed + ". His picker still counts for "
                    "this call, but a later session will ask him again until that record can be written.")
    if any(f["repo"] == key and f["hash"] == digest for f in found) or (entries and _on_record(entries, key, digest)):
        out["approved"] = True
        return out
    why = ["Dan has not approved this wording for " + key + ": no approval on this Mac's record, and none in this "
           "session, is of the announcement as it reads here"]
    if unreadable:
        why.append(unreadable)
    if unlooked:
        why.append(unlooked)
    for f in found:
        if f["repo"] == key:
            why.append("the wording he approved in " + f["file"] + " is not this wording (they differ once "
                       "normalised), so make the Announcement block that file's text, or ask him again")
    for u in untaken:
        if u["repo"] in (key, ""):
            why.append("his Approve for " + (u["file"] or "a file it did not name") + " does not count: " + u["why"])
    out["why"] = ". ".join(w.rstrip(".") for w in why) + "."
    return out


def mark_used(repo, digest, pr, closes=None, unread=None):
    """Record that the merge gate let pull request pr of repo through on digest: None, or why the
    line could not be written. closes is [{issue, milestone}] for the issues it closes, or None with
    unread saying why they could not be read. Written once for one pull request and one wording."""
    key = repo_key(repo)
    if key is None or not isinstance(digest, str) or not SHA.fullmatch(digest) or not isinstance(pr, int):
        return "the used line names no repository as owner/name, no hash or no pull request number"
    entries, why = read_record()
    if entries is None:
        return why
    if any(e.get("kind") == "used" and e.get("repo") == key and e.get("hash") == digest and e.get("pr") == pr
           and e.get("closes") is not None for e in entries):
        return None
    return _append([{"kind": "used", "repo": key, "hash": digest, "pr": pr, "closes": closes,
                     "unread": unread or None, "at": _now()}])


def _flag(args, name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def main(argv):
    command, args = (argv[1] if len(argv) > 1 else ""), argv[2:]
    if command == "check":
        try:
            payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
        except ValueError:
            payload = {}
        json.dump(check(_flag(args, "--repo"), _flag(args, "--hash"), payload), sys.stdout)
        return 0
    if command == "used":
        pr, closes = _flag(args, "--pr"), _flag(args, "--closes")
        try:
            closes = json.loads(closes) if closes else None
        except ValueError:
            closes = None
        why = mark_used(_flag(args, "--repo"), _flag(args, "--hash"), int(pr) if pr and pr.isdigit() else None,
                        closes if isinstance(closes, list) else None, _flag(args, "--unread"))
        json.dump({"written": why is None, "why": why or ""}, sys.stdout)
        return 0
    if command == "list":
        entries, why = read_record()
        json.dump({"record": record_path(), "entries": entries, "why": why or ""}, sys.stdout)
        return 0
    sys.stderr.write("Usage: announce-approval.py check --repo <owner/name> --hash <sha256>, with the hook payload on "
                     "standard input | used --repo <owner/name> --hash <sha256> --pr <number> [--closes <json>] "
                     "[--unread <why>] | list\n")
    return 2


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
