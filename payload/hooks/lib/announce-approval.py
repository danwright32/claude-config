"""Whether Dan approved the exact wording of an announcement (claude-config#3666).

A pull request labelled changelog/announce carries the post for agents under `## Announcement`, and
once it is live that post is drafted in the announcements channel. Dan's words for this feature: "it
should ask me before applying the label". So the wording is approved by him, in a picker, after it
was opened in front of him, and this file says whether a given wording is one he approved. The merge
gate (require-changelog-tag.sh) asks it for every announce pull request, and announce-label-ask.sh
asks it before the label goes on one.

HOW DAN IS ASKED. The session writes the post to a file, runs /no-ai-tells on it, opens it in BBEdit
with the front window flag, and asks ONE AskUserQuestion picker of one question, naming the pull
request or feature and the channel and ending `Save the file before you answer.`, with the options
`Approve the wording` and `Not yet`, and this metadata:

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
  - that open was the session's LAST TOOL CALL before the picker (claude-config#3742): no call of
    any tool, naming the file or not, stands between the two in the transcript. The picker shows
    him no file name, so with two wording files open his answer about the first was given with the
    second in front. Any call between may have opened another window, and none is read to find
    out. The refusal names the call and says to open the file again and ask in the next call.
  - THE QUESTION TELLS HIM TO SAVE (claude-config#3742): the question he was shown holds the
    sentence `Save the file before you answer.` (SAVE_FIRST), word for word. He may edit the file in
    the window before he answers, and an edit he does not save is not in the file, so it is not in
    the wording that is hashed: he would approve one text and another would merge. Nothing here can
    ask BBEdit whether a window holds unsaved changes, so the question says it, and a picker whose
    question does not approves nothing. The refusal gives the sentence to add.
  - the file has not changed since he answered: its status change time (st_ctime, which a write, a
    rename or a replacement sets and no command sets back) is before the moment his answer was
    recorded. Between the open and the answer the file may change, because that is Dan editing it.
  - HE TYPED NOTHING BESIDE IT (claude-config#3742): the picker lets him type words beside the
    option he chooses, and hands them back beside his answer (toolUseResult.annotations, keyed by
    the question, as {"notes": "<his words>"}; read from pickers he answered that way, in real
    transcripts, 2026-11-26). "approve, but fix line 2" used to count as his approval of the
    wording as it stood, and the words were read by nothing. Dan, by picker on 2026-11-26, asked
    what should happen then: "Refuse and ask again". So an Approve that comes with words of his
    approves nothing: it is an answer of his that is no approval, exactly as `Not yet` is (it
    takes back an earlier approval of that wording, below), and the refusal gives his words, says
    they approve nothing, and says to fix the wording and ask him again. White space is no words,
    and neither is the chosen option's own preview, which the dialog hands back in the same
    place. Anything there in a form this file does not read is taken as words of his. An answer
    he typed in place of choosing an option was never an Approve, and is `words of his own` below.
  - no later picker about the same file ended any other way (`Not yet`, a timeout): the last word
    on a file is the one that counts.
  - the file holds wording, and it can be hashed.
  - the file holds no run of more than two blank lines with wording below it (claude-config#3703).
    Blank lines are dropped before the hash, so a file holding the post, a long run of blank lines
    and then more text hashes the same as those lines written together, while the window it was
    opened in showed him the post and then white space. The refusal says how long the run is, the
    line it starts at, and what to change. Blank lines after the last line hide nothing and pass.

WHAT IS HASHED. The FILE as it stands, never a hash the session supplies: a hash in the metadata
is not read at all. The hash is lib/changelog-entry.js's announcementHash, the sha256 of its one
normalised form (line endings, spaces at the ends of lines, blank lines), asked through its
announcement-hash command line, so the file here and the block GitHub holds are hashed by one
function and this file normalises nothing itself.

THE RECORD keeps an approval past the session: <record>/record.jsonl, where <record> is
$ANNOUNCE_APPROVALS_DIR when set (the tests) and else $CLAUDE_HOME/state/announce-approvals, on this
Mac only (the state folder is never synced, as the record of approved test project lines is kept).
One JSON object a line, each carrying its repository:
    {"kind": "approved", "repo": "<owner/name>", "hash": "<sha256>", "at": "<when>", "session": "<id>",
     "picker": "<the picker's tool_use id>", "file": "<the wording file>", "answered": "<when he answered>"}
    {"kind": "withdrawn", "repo": ..., "hash": "<sha256, or null>", "file": ..., "session": ..., "picker": ...,
     "answered": ..., "why": "<why there is no hash, or null>", "at": ...}
    {"kind": "settled", ...the same fields, for a picker that came back with no answer of his, and,
     with no repository and no file, for a noted picker that is none of this record's (below)}
    {"kind": "used", "repo": ..., "hash": ..., "pr": <number>, "claim": true, "closes": null, ...}
    {"kind": "used", "repo": ..., "hash": ..., "pr": <number>, "closes": [...], "unread": ..., "at": ...}
A hook run that reads his Approve writes the approved line, unless the call is a subagent's (the
payload carries agent_id): a subagent's call counts his picker for that call and writes nothing. When
the record cannot take a line, the main session's call still counts his picker and the failed save
is said beside it, as lib/db-apply-approval.py does for a line he approved (Dan, 2026-11-16).

HIS LAST ANSWER ON A WORDING DECIDES, on the record as in the session (claude-config#3742). An
approval on the record used never to be taken back: he approved, the approval was recorded, the
session asked again about the same unchanged file, he answered `Not yet`, and the merge still went
through on the recorded approval. So a hook run that reads a picker of this source he answered
with anything but Approve alone (`Not yet`, words of his own, or an Approve with words typed
beside it) writes a `withdrawn` line: the
repository, when he answered, and the hash of the wording he answered about, which is the hash
noted when he answered, else the file's while it has not changed since. An approval of that
repository and wording that he gave BEFORE that answer no longer counts, whichever session or file
it came from, and one he gives after it does. When the wording he answered about cannot be hashed
any more (no note, and the file changed since), the line names the file alone and takes back his
earlier approvals that name that file. A picker that came back with no answer of his (in error, or
closed by its own timeout) takes nothing back from the record: it gets a `settled` line, so that a
noted session whose pickers all have an outcome on the record is not read back again. A subagent's
call counts these for that call and writes nothing, as with his Approve.

EVERY PICKER IS NOTED WHEN HE ANSWERS IT (claude-config#3742, #3789). An approval used to reach the
record only when a later hook read the session's transcript: the label hook, on a command putting
the label on, or the merge gate, on a typed merge. The merge helper (lib/merge-when-ready.sh) hands
the gates a payload naming no transcript and a session id that is no session's, so on any flow where
neither followed his answer (the wording revised after the label went on, the label put on in
GitHub's page) the merge was refused, told to ask him, and asking him again changed nothing. So
announce-answer-note.sh runs after every picker is answered and asks note_answer() here, which
writes, for every picker a main session put, whatever it asked:
    {"kind": "answered", "session": "<id>", "transcript": "<its path>", "picker": "<tool_use id>",
     "held": <whether the transcript held the picker's line then: true, false, or null when it
     could not be read>, "at": "<when>"}
The hook cannot tell what a picker asked, which is why it notes them all. As first built (#3780) it
noted only a picker it could tell was of this source, and said a notice for one it could not tell.
Measured on the installed hook on 2026-11-26, for two pickers, one sent with metadata naming a
source: no line of the session's transcript held the picker's id when the hook ran, and the hook's
own copy of the picker carried no metadata, while the transcript read afterwards held both pickers
as the session sent them. So the hook told nothing, spoke after every picker in every session, and
noted none, an approval picker included (#3789). An earlier reading of another session (#3742) had
found the transcript ending at the call's tool_use when its PostToolUse hook ran, so the line may
be there or not, and `held` records which on every note: it decides nothing. The size of the
transcript is not why: a reader of one built to the measured size (20 MB, 10,000 lines) finds the
picker in hundredths of a second (hooks/test-announce-answer-note.sh).

When the hook can already tell the picker is of this source (the transcript holds it, or failing
that its own copy carries the metadata) and names a repository and a file, the note also carries
     "repo": "<owner/name>", "file": "<the wording file>", "hash": "<sha256, or null>", "why": "<why
     there is no hash, or null>", "changed": <the file's status change time then, in ns>

A NOTE IS NOT AN APPROVAL, and it is not his answer. It names no answer at all. The payload the
hook is handed does carry his answer, and it is not read: a payload is what the caller hands over,
and a run of the hook by hand could say anything. Nothing that reads the record takes a note for an
approval: an approval is an `approved` line, which only a judge writes. Whoever next asks with a
payload (a hook: the label hook, the merge gate typed or through the helper) reads each noted
session's transcript, in ONE pass for all of that session's noted pickers the record holds no
outcome for, and judges each from what the transcript holds:
  - a picker of this source, by every rule above, unchanged: answered Approve by him, the file
    opened in front of him, nothing of the session touching it in between. It gets its `approved`,
    `withdrawn` or `settled` line as any picker read from a session's transcript does.
  - a picker that names no source this record reads (NOTED_SOURCES): a `settled` line naming no
    repository and no file, so it is read once and never again. It approves nothing and takes
    nothing back, whatever he answered it.
  - a picker of this source that can never count (its metadata names no repository and file, or
    the session sent it with its answer filled in): settled the same way once it has been read
    and, for an Approve, said. With no note such a picker is passed over; a note left with no
    outcome would have its session read back on every later call.
  - a picker the transcript does not hold yet: left as it is, and looked for again.
  - a picker noted by its ids alone whose session's transcript is gone: settled the same way,
    since what it asked can never be read.
THE WORDING HE ANSWERED ABOUT is taken from the note only when the note holds a hash, for the same
repository and file as the transcript's picker: then the hash and the file's change time noted,
which must be before his answer, are the ones judged, so a write to the file afterwards neither
loses his approval nor rides on it, and a note taken later than his answer, over a file changed
since, approves nothing. A note that holds no hash, which is every note by ids alone, gives no
wording: the picker is judged exactly as one with no note is, by the file as it stands, which must
not have changed since his answer was recorded. Where it has, his Approve does not count and the
refusal says to open the file and ask him again. So a note by ids alone lets nothing through that
the same picker, read from its own session's transcript with no note at all, would not.

A picker's first note is the one kept. A subagent's picker is not noted, and nothing is said of
it. Neither is one whose transcript is kept where no picker is ever read from (transcripts_dir).
The hook says something only when the note itself could not be written (the record cannot be read
or appended to, or the hook was not handed the session, its transcript and the picker's id): that
is the one case where an approval would be lost, so it says what to do if the picker was an
announcement's. One call reads back NOTED_SESSIONS sessions, the ones whose newest unjudged note is
newest. The record is only ever added to: a picker costs it one `answered` line and, once judged,
one line more.

READING AND WRITING ARE SEPARATE (claude-config#3703). A review found that the check command read a
session's pickers from whatever transcript its standard input named and wrote what it found, so a
made up transcript left a line saying Dan approved wording he never saw. So:
  - the command line a session can run, `list` and `check` without --claim, reads the record and
    nothing else: no standard input, no transcript, no picker, and it writes nothing.
  - an approval is written only when a hook asks: the merge gate through `check --claim`, with the
    payload Claude Code handed it, and the label hook in process (check() with a payload). The hook
    that notes his answer (`answered`) writes a note and never an approval.
  - whoever asks, a picker counts only from a session transcript (.jsonl) under the projects folder
    Claude Code keeps them in, beside the state folder the record is in (transcripts_dir). A
    transcript anywhere else is not read, and the answer names it and that folder.
  - announce-label-ask.sh refuses a session's Bash command that runs this file in any form but
    the two that only read.

ONE APPROVAL COVERS ONE PULL REQUEST (Dan, 2026-11-25, by picker: "One approval, one pull request").
An approval is one answer of his in one picker, so it is counted by the picker it came from, under
whichever session id its lines are found (_approval_keys; claude-config#3742), once however many
lines say it (two hook runs at once can each write it). A `used` line
names a pull request that used one. For a wording and a repository, the first pull requests to use
it, as many as there are approvals, are the ones covered. So:
  - an approval nobody has used covers whichever pull request reaches the merge gate first, which
    is how an approval given before the pull request exists is used;
  - the pull request that used it may try its merge again without asking him;
  - a different pull request carrying the same wording is not approved, and asks him again;
  - a `used` line approves nothing by itself: with no approval behind it, it covers nothing.
The merge gate asks with claim: holding a lock on the record (flock, which a holder that dies
releases), it reads the record again, decides, and writes the pull request's claim, a `used` line
with "claim": true, in that same hold, so of two pull requests reaching the gate at once on one
approval exactly one is let through. When the claim cannot be written the merge is REFUSED, saying
what could not be written and where (Dan, 2026-11-25, by picker: "Refuse the merge"): the next pull
request with the same wording could not be told from this one. The claim is written whoever makes
the call, a subagent included, since a merge by anyone uses the approval. The label hook asks
without claim and writes no use: it passes the pull request's number when the command names one,
and a command naming none (a create) is approved only while an approval is unused.

After the claim the merge gate reads the issues the pull request closes and adds a `used` line
naming each with its milestone, for the later check that a feature Dan said yes to announcing does
not finish under another label (or one saying why they could not be read). These lines are written
BEFORE the merge runs, so they say the gate let the merge go ahead, never that GitHub merged it: a
reader that needs "merged" asks GitHub about the pull request.

WHAT IT CANNOT SEE. A write to the file, between the open and his answer, by something the
transcript does not name it in (a script building the name at run time, a subagent's own tools).
Whether the picker's question named the right channel. A record line written by hand: the record is
guarded by announce-label-ask.sh, which refuses an edit under it and a shell command naming it that
is not one only reading it, but a script that builds the path at run time is not seen. A transcript
forged in the folder Claude Code keeps them in, and this file reached without being named (a script
file, a path built at run time, a hook run by hand with a payload of the caller's): the record and
the transcripts are files on a Mac the session can write, so a session that sets out to forge them
is not stopped here. And an approval given on one Mac is unknown to the other, which asks again.

  check(repo, digest, payload, pr=None, claim=False)
      {"approved": bool, "state": str, "why": str, "how": str, "notes": [str]}: whether digest, an
      announcementHash, is wording Dan approved for repo that pull request pr may use. payload is
      the hook payload (session_id, transcript_path, agent_id): this session's pickers are read,
      and so are the pickers the record notes in other sessions and holds no outcome for, the
      NOTED_SESSIONS sessions with the newest of them, each from its own session's transcript, and an approval found is written. payload None is the question that only reads the record:
      no picker is read and nothing is written. state says which answer it is, so a caller words its own first sentence truly:
      "approved"; "unapproved" (he approved no such wording; how says how to ask him); "used" (he
      did, and other pull requests used every approval; how says how to ask him again);
      "unrecorded" (he did, and the claim could not be written; how says what to put right).
  note_answer(payload)                          (noted, why): the note of a picker just answered.
  mark_used(repo, digest, pr, closes, unread)   None, or why the line could not be written.
  hash_of(data, body=False)                     (announcement-hash's answer, None) or (None, why).
  is_record_path(path)                          whether a path is the record or under it.
  transcripts_dir()                             the folder a transcript must be under, or None.

Command lines, each printing JSON and exiting 0 when it could answer. The first two only read, and
are a session's to run; the others write, and are the merge gate's and, the last, the hook's that
notes his answer:
  announce-approval.py list                                          the record, as it reads
  announce-approval.py check --repo <owner/name> --hash <sha256> [--pr <number>]
                                                                     the record's answer; standard input is not read
  announce-approval.py check --repo <owner/name> --hash <sha256> --pr <number> --claim
                                                                     the hook payload on standard input
  announce-approval.py used --repo <owner/name> --hash <sha256> --pr <number> [--closes <json>] [--unread <why>]
  announce-approval.py answered                                      the PostToolUse payload on standard input
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
# The most blank lines in a row a wording file may hold above its last line of wording. A post
# separates its paragraphs with one, and two leaves room for a habit; a longer run pushes whatever
# follows it down the window the file was opened in. Chosen (claude-config#3703), not measured.
BLANK_RUN = 2
EDIT_TOOLS = ("Edit", "Write", "MultiEdit", "NotebookEdit")
# A tool that hands the file's name to something that may write it.
SENDING_TOOLS = ("Agent", "Task")
HASH_SECONDS = 5
CHECK_SECONDS = 12
# How long a claim waits for the record's lock. Its holder reads the record and writes one line, so
# a wait this long means something is wrong, and the merge is refused saying so. Chosen, not measured.
CLAIM_LOCK_SECONDS = 3
# The sources whose pickers a note is read back for. Every main session picker is noted
# (claude-config#3789), and one whose call the transcript shows names none of these is settled, so
# it is read once. A second source is added here, with its own judge of its pickers.
NOTED_SOURCES = (SOURCE,)
# How many sessions' noted pickers one call reads back: the sessions whose newest unjudged note is
# newest. Each is one pass over that session's transcript, inside CHECK_SECONDS, however many
# pickers of it are noted. The number is chosen, not measured. One pass is measured: 0.009 seconds
# for a 20 MB, 10,005 line transcript, three runs alike, on 2026-11-26, with the file just written
# and so in the disk cache (hooks/test-announce-answer-note.sh builds it and prints the time).
NOTED_SESSIONS = 5
# How long the hook that notes a picker may take: one pass over the transcript and, for a picker it
# can already tell is an announcement's, one stat either side of one hash.
NOTE_SECONDS = 8
# Seams: the wait between two tries for the lock, and the clock that bounds them (L524).
_sleep = time.sleep
_clock = time.monotonic
HERE =os.path.dirname(os.path.abspath(__file__))

# The sentence the picker's question must hold, word for word (THE QUESTION TELLS HIM TO SAVE, module
# docstring). One constant, so the rule, the refusal and the how to ask text cannot drift apart.
SAVE_FIRST = "Save the file before you answer."
# What a refusal gives in place of words typed beside an answer that came back in no form this file
# reads, and how many characters of his words one refusal carries.
TYPED_UNREAD = "(something came back beside his answer in a form that could not be read)"
TYPED_SHOWN = 600

HOW_TO_ASK = (
    "To ask him: write the post to a file, run /no-ai-tells on it, open it in a command of its own with "
    "`/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window <file>`, then, as the very next tool call "
    "(with any other call between the two his answer does not count), ask ONE AskUserQuestion "
    "picker of one question naming the pull request or feature and the channel, and ending with the sentence `"
    + SAVE_FIRST + "` (without it his answer does not count), with the options `" + APPROVE
    + "` and `Not yet` and the metadata {\"source\": \"" + SOURCE + "\", \"repo\": \"<owner/name>\", \"file\": "
    "\"<absolute path>\"}. Leave the file alone once it is open (he may edit it before he answers), and make the "
    "pull request's Announcement block that file's text.")
# What the command line without --claim says beside "not approved", so a session that has just asked
# him is not told his answer does not exist.
RECORD_ONLY = ("this command reads the record only: a picker of his in this session is read, and written to the "
               "record, when a hook asks, which is when the label goes on or the merge runs")


_PARTS = {}


def _part(name, file):
    """A library beside this file, loaded by its path, never by name, once for one run."""
    if name not in _PARTS:
        spec = importlib.util.spec_from_file_location(name, os.path.join(HERE, file))
        lib = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(lib)
        _PARTS[name] = lib
    return _PARTS[name]


def claude_home():
    return os.environ.get("CLAUDE_HOME") or os.path.join(os.path.expanduser("~"), ".claude")


def record_dir():
    named = os.environ.get("ANNOUNCE_APPROVALS_DIR")
    if named:
        return named
    return os.path.join(claude_home(), "state", RECORD_NAME)


def record_path():
    return os.path.join(record_dir(), RECORD_FILE)


def _own_claude():
    """This user's own .claude folder, under the home the account database gives. HOME and
    CLAUDE_HOME are not asked: a command can set either, and this is the one answer it cannot move."""
    try:
        import pwd
        home = pwd.getpwuid(os.getuid()).pw_dir
    except (ImportError, KeyError, OSError):
        home = ""
    return os.path.join(home or os.path.expanduser("~"), ".claude")


def _same_place(folder, own):
    """Whether folder is the record's folder own, however it is spelled or linked: the same path
    once links are followed, in any letter case (is_record_path says why), or a folder whose record
    file is the same file on disk."""
    if os.path.realpath(folder).casefold() == os.path.realpath(own).casefold():
        return True
    try:
        return os.path.samefile(os.path.join(folder, RECORD_FILE), os.path.join(own, RECORD_FILE))
    except OSError:
        return False


def transcripts_dir():
    """The folder a session's transcript must be under for a picker in it to count, or None when a
    transcript may be anywhere (claude-config#3703).

    Claude Code keeps every session's transcript under the projects folder of its own folder, beside
    the state folder the record is in. A picker is read only from a transcript there, so a file
    shaped like a transcript and kept anywhere else approves nothing, whoever hands it over.

    The tests keep their record in a folder ANNOUNCE_APPROVALS_DIR names, and build their transcripts
    beside it: a record named that way takes a transcript from anywhere. That is safe only while the
    folder named is not the one this Mac's hooks read, so a variable naming this user's own record
    changes nothing, and neither does CLAUDE_HOME beside it."""
    own = _own_claude()
    if _same_place(record_dir(), os.path.join(own, "state", RECORD_NAME)):
        return os.path.join(own, "projects")
    if os.environ.get("ANNOUNCE_APPROVALS_DIR"):
        return None
    return os.path.join(claude_home(), "projects")


def _misplaced(transcript_path):
    """None when transcript_path is a session transcript where Claude Code keeps them (or the record
    is a test's), else why no picker is read from it."""
    root = transcripts_dir()
    if root is None:
        return None
    real, folder = os.path.realpath(transcript_path), os.path.realpath(root)
    if real.casefold().startswith(folder.casefold() + os.sep) and real.endswith(".jsonl"):
        return None
    return ("the transcript this call named, " + transcript_path + ", is not a session transcript under " + root
            + ", where Claude Code keeps them, so no picker was read from it: his approval is read only from the "
            "transcript of the session that asked him")


def is_record_path(path):
    """Whether path is the record's folder or anything under it, however it is spelled."""
    if not isinstance(path, str) or not path:
        return False
    # Compared without letter case: a Mac's disk reads STATE/Announce-Approvals as this folder, and
    # realpath keeps the capitals it was given. On a disk that tells the two apart this also refuses
    # a folder that is not the record, which costs a rename and risks nothing.
    folder = os.path.realpath(record_dir()).casefold()
    real = os.path.realpath(path).casefold()
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


def _text(value):
    return value if isinstance(value, str) and value else None


def _when(line):
    """When the answer a line records was given, in nanoseconds: his answer's own time where the line
    carries it (answered), else when the line was written (at), else 0, the oldest there is."""
    stamp_ns = _part("db_apply_approval_shared", "db-apply-approval.py")._stamp_ns
    return stamp_ns(line.get("answered")) or stamp_ns(line.get("at")) or 0


def _approval_keys(entries, found, repo, digest, closed=()):
    """(keys, back). keys is each approval of digest for repo that stands, once: the picker it came
    from, on the record or found in a session's transcript and not yet on it. A picker's id is
    Claude Code's own for the one call and is the same under every session id, so a picker is one
    approval whichever session its lines are found under (claude-config#3742: a resumed or forked
    session may carry an earlier session's lines under its own id, and keyed by session and picker
    the one answer counted twice). A line naming no picker is one approval with every other such
    line of its session, so a line repeated is never a second approval.

    HIS LAST ANSWER ON A WORDING DECIDES (module docstring): an approval older than a `withdrawn`
    line of the same repository and wording does not stand. A withdrawal that could not be hashed
    names the file instead, and takes back the older approvals that name that file. closed is the
    withdrawals found in a session's transcript and not yet on the record. back is the newest
    withdrawal that took an approval of this wording back, or None."""
    given = {}
    for e in list(entries or []) + list(found):
        if e.get("kind") == "approved" and e.get("repo") == repo and e.get("hash") == digest:
            picker = _text(e.get("picker"))
            key = (None, picker) if picker is not None else (_text(e.get("session")), None)
            if key not in given or _when(e) > given[key][0]:
                given[key] = (_when(e), _text(e.get("file")))
    backs = [(_when(w), w) for w in list(entries or []) + list(closed)
             if w.get("kind") == "withdrawn" and w.get("repo") == repo]
    keys, back = set(), None
    for key, (when, file) in given.items():
        took = [(at, w) for at, w in backs if at > when and (
            w.get("hash") == digest or (w.get("hash") is None and file is not None and w.get("file") == file))]
        if not took:
            keys.add(key)
            continue
        newest = max(took, key=lambda pair: pair[0])
        if back is None or newest[0] > back[0]:
            back = newest
    return keys, (back[1] if back else None)


def _users(entries, repo, digest):
    """The pull requests `used` lines name for digest in repo, each once, in the order they used it."""
    out = []
    for e in entries or []:
        pr = e.get("pr")
        if (e.get("kind") == "used" and e.get("repo") == repo and e.get("hash") == digest
                and isinstance(pr, int) and not isinstance(pr, bool) and pr not in out):
            out.append(pr)
    return out


def _covers(count, users, pr):
    """Whether count approvals cover pull request pr, given the pull requests that used them: one
    that used one is covered when it is among the first count to, and any other (or a command naming
    none) only while an approval is unused."""
    if isinstance(pr, int) and pr in users:
        return pr in users[:count]
    return count > len(users)


def _unwritable(path, e):
    return ("the record of the wording Dan approved, " + path + ", could not be written ("
            + type(e).__name__ + (": " + e.strerror if e.strerror else "") + ")")


def _append(entries):
    """Add lines to the record: None once they are on it, else why not."""
    folder, path = record_dir(), record_path()
    # The leading newline ends any fragment an earlier short write left, so the first line here is
    # never fused onto it; a blank line costs the reader nothing.
    data = ("\n" + "\n".join(json.dumps(e, sort_keys=True) for e in entries) + "\n").encode("utf-8", "replace")
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
        try:
            written = os.write(fd, data)
        finally:
            os.close(fd)
    except OSError as e:
        return _unwritable(path, e)
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


def _asked(transcript_path, session_id, sought=(), other=None):
    """Every picker of SOURCE the session put that came back, oldest first, as a dict: ask (its
    input), result, is_error, sent and answered (line numbers), stamp (when the answer was
    recorded, as written) and prefilled (the session sent it with its answers filled in, so it is
    no picker at all, and is kept only so a refusal can say so).

    sought is the ids of pickers the record notes and nothing has judged yet (EVERY PICKER IS NOTED,
    module docstring). The same pass looks for each: one the transcript holds as a picker naming
    none of NOTED_SOURCES is added to other, a set, and one it holds as a picker of SOURCE is judged
    with the rest. So a session's noted pickers cost one pass, however many there are."""
    waiting, out = {}, []
    source = SOURCE.encode("utf-8", "replace")
    seeking = {uid.encode("utf-8", "surrogatepass") for uid in sought if isinstance(uid, str) and uid}

    def wanted(raw):
        # A picker's call is on a line holding the tool's name, so only those are searched for an id.
        if b"AskUserQuestion" in raw and (source in raw or any(k in raw for k in seeking)):
            return True
        return bool(waiting) and b"tool_result" in raw and any(k in raw for k in waiting)

    for n, e in _entries(transcript_path, session_id, wanted):
        for item in _items(e):
            uid = item.get("id")
            if item.get("type") == "tool_use" and item.get("name") == "AskUserQuestion":
                ask = item.get("input")
                meta = ask.get("metadata") if isinstance(ask, dict) else None
                named = meta.get("source") if isinstance(meta, dict) else None
                if other is not None and isinstance(uid, str) and uid in sought and named not in NOTED_SOURCES:
                    other.add(uid)
                # One that came with its answers filled in was never put to him: the dialog returns
                # them without asking (lib/db-apply-approval.py's rule), so it is no picker at all.
                # It is marked, and approvals() takes nothing from it but the reason to give.
                if isinstance(uid, str) and uid and isinstance(meta, dict) and meta.get("source") == SOURCE:
                    waiting[uid.encode("utf-8", "surrogatepass")] = (ask, n)
            elif item.get("type") == "tool_result" and isinstance(item.get("tool_use_id"), str):
                pair = waiting.pop(item["tool_use_id"].encode("utf-8", "surrogatepass"), None)
                if pair is not None:
                    out.append({"ask": pair[0], "sent": pair[1], "answered": n, "stamp": e.get("timestamp"),
                                "picker": item["tool_use_id"], "prefilled": bool(pair[0].get("answers")),
                                "result": e.get("toolUseResult"), "is_error": item.get("is_error")})
    return out


def _not_his_approve(p):
    """Why picker p, which holds APPROVE as its answer, is not an answer of Dan's, or None when it
    holds no such answer or is one. The session can see that Approve in its own transcript, so a
    refusal that did not say why it does not count sent it to ask again the same way."""
    result = p["result"] if isinstance(p["result"], dict) else {}
    answers = p["ask"].get("answers") if p.get("prefilled") else result.get("answers")
    if not isinstance(answers, dict) or not any(isinstance(c, str) and c.strip() == APPROVE for c in answers.values()):
        return None
    if p.get("prefilled"):
        return ("the session sent that picker with its answer already filled in, so it was never put to him. Ask it "
                "with no answers of its own")
    if p["is_error"]:
        return "that picker came back in error, so the answer on it is not taken as his. Ask him again"
    if "afkTimeoutMs" in result:
        return "that picker was closed by its own timeout, so the answer on it is not his. Ask him again"
    questions = p["ask"].get("questions")
    if not isinstance(questions, list) or len(questions) != 1 or len(answers) != 1:
        return ("that picker did not ask one question with one answer, and his approval is read from a picker that "
                "asks about the wording alone. Ask ONE picker of one question")
    return None


def _typed_beside(result):
    """The words Dan typed beside the option he chose, as one line, or None when he typed none (HE
    TYPED NOTHING BESIDE IT, module docstring). The dialog hands them back in the result's
    annotations, keyed by the question: {"<question>": {"notes": "<his words>"}}, with the chosen
    option's "preview" beside them when it has one, which is none of his words. Anything there in a
    form that cannot be read as his words or as their absence is taken as words of his, so a form
    nobody has seen never passes as nothing typed: those two keys are the only ones known, and any
    other key holding a value is such a form."""
    notes = result.get("annotations") if isinstance(result, dict) else None
    if not notes:
        return None
    if not isinstance(notes, dict):
        return TYPED_UNREAD
    words = []
    for about in notes.values():
        typed = about.get("notes") if isinstance(about, dict) else about
        if isinstance(about, dict) and any(v for k, v in about.items() if k not in ("notes", "preview")):
            words.append(TYPED_UNREAD)
        if isinstance(typed, str):
            words.append(" ".join(typed.split()))
        elif typed:
            words.append(TYPED_UNREAD)
    words = " / ".join(w for w in words if w)
    if len(words) > TYPED_SHOWN:
        words = words[:TYPED_SHOWN] + " (cut here: the rest is in the picker's result)"
    return words or None


def _typed_why(words):
    """Why his Approve with those words typed beside it does not count, with the words."""
    return ("he chose `" + APPROVE + "` and typed words beside it, and an Approve that comes with words of his "
            "approves nothing: the words are a change he wants. What he typed: \"" + words
            + "\". Read it, fix the wording, then open the file for him again and ask him again")


def _file_events(transcript_path, session_id, targets, sw):
    """What the session did with each wording file, {its path: (opens, touches)}: opens as (line
    sent, line it finished without error, the call's id), touches as the line of each call that
    wrote the file or may have (module docstring). targets is {a file's real path: its file name}."""
    names = {name.encode("utf-8", "replace"): path for path, name in targets.items()}
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
                    found[was[0]][0].append((was[1], n, item["tool_use_id"]))
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


def _calls_on(transcript_path, session_id, first, last):
    """The name of every tool call the session made on transcript lines first to last, as (its id,
    its name), in order. Only those lines are parsed, so a long transcript costs one read of it. A
    line there that holds a call and cannot be parsed is a call nobody can name, and is counted."""
    out = []
    with open(transcript_path, "rb") as f:
        for n, raw in enumerate(f):
            if n > last:
                break
            if n < first or b"tool_use" not in raw:
                continue
            try:
                e = json.loads(raw.decode("utf-8", "replace"))
            except ValueError:
                out.append((None, "one on a line that could not be read"))
                continue
            if not isinstance(e, dict) or e.get("sessionId") != session_id:
                continue
            for item in _items(e):
                if item.get("type") == "tool_use":
                    name = item.get("name")
                    out.append((item.get("id"), name if isinstance(name, str) and name else "one with no name"))
    return out


def note_answer(payload, deadline=None):
    """What announce-answer-note.sh asks once a picker is answered (EVERY PICKER IS NOTED, module
    docstring): (True, None) once the record holds the picker's note, (False, None) for a call that
    is not noted and loses nothing by it (no picker, a subagent's, one whose transcript no picker is
    ever read from), and (False, why) only when the note itself could not be written, which is the
    one case where an approval of his would be lost.

    payload is what Claude Code hands a PostToolUse hook. Of it, which picker this is and where its
    session's transcript is are read (session_id, transcript_path, tool_use_id), and those three are
    the note. What the picker asked decides nothing here: the note of an ordinary picker and of an
    announcement's are written the same way, and whoever reads the note judges the picker from the
    transcript. What he answered is NOT read from the payload, here or later: a payload is whatever
    the caller hands over, and his answer is read from the transcript.

    One thing more is noted when it can be: for a picker this run can already tell is an
    announcement's (_wording_noted), the hash of its wording file as it stands, which is what lets
    his approval outlast a later write to the file."""
    lost = "The picker Dan just answered could not be noted on this Mac's record: "
    if not isinstance(payload, dict):
        return False, lost + "what Claude Code handed the hook was not a JSON object"
    if payload.get("tool_name") != "AskUserQuestion" or payload.get("agent_id"):
        # No picker, or a subagent's: nothing is written and nothing is said, whatever it asked.
        return False, None
    session, transcript, picker = (_text(payload.get(k)) for k in ("session_id", "transcript_path", "tool_use_id"))
    if session is None or transcript is None or picker is None:
        return False, lost + "the hook was not told the session, its transcript and the picker's id"
    if _misplaced(transcript) is not None:
        # No picker is ever read from a transcript kept anywhere else (transcripts_dir), by a note
        # or without one, so a note of this one could approve nothing and nothing is lost without
        # it. A hook that is asked about wording says why, naming the transcript and that folder.
        return False, None
    entries, unreadable = read_record()
    if entries is None:
        return False, lost + unreadable
    if any(e.get("kind") == "answered" and e.get("session") == session and e.get("picker") == picker for e in entries):
        # The first note of a picker is the one kept. A second run for the same picker, which is
        # never Claude Code's, changes nothing.
        return True, None
    # held records one fact and decides nothing: whether the transcript held the picker's line when
    # this hook ran (true or false), or could not be read then (null). It is what tells the two
    # measurements in the module docstring apart on the first real picker after an install.
    try:
        ask = _ask_of(transcript, session, picker)
        held = ask is not None
    except OSError:
        ask, held = None, None
    note = {"kind": "answered", "session": session, "transcript": transcript, "picker": picker, "held": held, "at": _now()}
    note.update(_wording_noted(ask if held else payload.get("tool_input"), bool(held), deadline))
    failed = _append([note])
    if failed:
        return False, lost + failed
    return True, None


def _wording_noted(ask, sent, deadline):
    """What a note carries beside its ids for a picker that can already be told to be an
    announcement's when its hook runs: {repo, file, hash, why, changed}, or {} for any other. ask is
    the picker's input, from the transcript when it holds the picker (sent) and else the hook's own
    copy. A second source's picker is noted by adding what its own note carries here.

    These fields approve nothing. Whoever reads the note judges the picker from the transcript, and
    takes the hash only when the transcript's picker names the same repository and file
    (_note_for), so a copy the hook was handed that names another is not believed."""
    meta = ask.get("metadata") if isinstance(ask, dict) else None
    if not isinstance(meta, dict) or meta.get("source") != SOURCE:
        return {}
    if sent and ask.get("answers"):
        # The session sent it with its answers filled in, so it was never put to him.
        return {}
    repo, file = repo_key(meta.get("repo")), meta.get("file")
    if repo is None or not isinstance(file, str) or not file.startswith("/"):
        return {}
    file = os.path.realpath(file)
    # The file's change time is read either side of the hash, so the hash noted is of the file as
    # it stood at the change time noted beside it.
    digest, why, changed = None, None, None
    try:
        changed = os.stat(file).st_ctime_ns
    except OSError as e:
        why = "the file could not be read (" + type(e).__name__ + "), so the wording he answered about cannot be hashed"
    if why is None:
        digest, why = _file_hash(file, deadline)
    if why is None:
        try:
            after = os.stat(file).st_ctime_ns
        except OSError:
            after = None
        if after != changed:
            digest, why = None, "the file changed while it was being hashed, so the wording he answered about could not be told"
    return {"repo": repo, "file": file, "hash": digest, "why": why, "changed": changed}


def _ask_of(transcript_path, session_id, picker):
    """The input of the AskUserQuestion call picker names, as the session's transcript holds it, or
    None when it holds no such call."""
    uid = picker.encode("utf-8", "surrogatepass")
    for _, e in _entries(transcript_path, session_id, lambda raw: uid in raw):
        for item in _items(e):
            if (item.get("type") == "tool_use" and item.get("id") == picker and item.get("name") == "AskUserQuestion"
                    and isinstance(item.get("input"), dict)):
                return item["input"]
    return None


def _noted(entries):
    """The pickers the record notes, {session: (its transcript, {picker: the note})}, each picker's
    first note only. A note names what its picker asked only when its hook could tell (repo, file,
    hash): one by its ids alone names nothing, and is of whatever the transcript shows."""
    out = {}
    for e in entries or []:
        session, transcript, picker = _text(e.get("session")), _text(e.get("transcript")), _text(e.get("picker"))
        if e.get("kind") != "answered" or session is None or transcript is None or picker is None:
            continue
        out.setdefault(session, (transcript, {}))[1].setdefault(picker, e)
    return out


def _note_for(p, noted):
    """The note of picker p's answer, when the record holds one about the same repository and file."""
    note = (noted or {}).get(p["picker"])
    if note is not None and note.get("repo") == p["repo"] and note.get("file") == p["file"]:
        return note
    return None


def _his_other(result, is_error):
    """Whether a picker came back with an answer of Dan's that is not APPROVE alone: `Not yet`, words
    of his own, or an Approve with words typed beside it. One that came back in error, or closed on its own timeout, is no answer of his."""
    if is_error or not isinstance(result, dict) or "afkTimeoutMs" in result:
        return False
    answers = result.get("answers")
    if not isinstance(answers, dict) or not answers:
        return False
    if _typed_beside(result) is not None:
        # An Approve with words of his typed beside it is an answer of his, and no approval.
        return True
    return any(not (isinstance(chosen, str) and chosen.strip() == APPROVE) for chosen in answers.values())


def _closed(p, session_id, ap, noted, deadline):
    """The record's line for a picker that came back as anything but his Approve (HIS LAST ANSWER ON
    A WORDING DECIDES, module docstring): `withdrawn` for an answer of his, with the hash of the
    wording he answered about, and `settled` for one that was no answer of his."""
    line = {"repo": p["repo"], "file": p["file"], "session": session_id, "picker": p["picker"],
            "answered": _text(p["stamp"]), "hash": None, "why": None}
    if not _his_other(p["result"], p["is_error"]):
        return dict(line, kind="settled", why="the picker came back with no answer of his: in error, closed by its "
                                              "own timeout, or not one question with one answer")
    # The wording he answered about: the hash noted when he answered, else the file's while it has
    # not changed since. Neither, and the line names the file alone.
    note = _note_for(p, noted)
    digest = note.get("hash") if note is not None else None
    if not (isinstance(digest, str) and SHA.fullmatch(digest)):
        digest, answered = None, ap._stamp_ns(p["stamp"])
        try:
            unchanged = answered is not None and os.stat(p["file"]).st_ctime_ns < answered
        except OSError:
            unchanged = False
        if unchanged:
            digest = _file_hash(p["file"], deadline)[0]
    if digest is None:
        line["why"] = ("the wording he answered about could not be hashed (no note of his answer holds it, and the "
                       "file has changed since or cannot be hashed), so this takes back his earlier approvals of "
                       "that file")
    return dict(line, kind="withdrawn", hash=digest)


def _settled_other(session_id, picker, why):
    """The record's line for a noted picker that is no picker of a source in NOTED_SOURCES, or whose
    session's transcript is gone: settled, so it is not read back again. It names no repository and
    no file, takes nothing back, and approves nothing."""
    return {"kind": "settled", "repo": None, "file": None, "session": session_id, "picker": picker, "answered": None,
            "hash": None, "why": why}


def _gone(transcript_path):
    """Whether a noted session's transcript is not there any more. One that is there and cannot be
    read is not gone: that may pass, and is said by whoever tries to read it."""
    try:
        os.stat(transcript_path)
    except FileNotFoundError:
        return True
    except OSError:
        return False
    return False


def approvals(session_id, transcript_path, deadline=None, noted=None, settled=(), sought=()):
    """(approved, untaken, closed, None) for this session's pickers, or ([], [], [], why they could
    not be looked for). approved is [{kind, repo, hash, file, picker, session, answered}] for each
    wording Dan approved that counts (module docstring); untaken is [{repo, file, why}] for each
    Approve of his that does not, so a refusal can say what stood in the way of the very approval
    the session thinks it holds. closed is the record's line for each picker that came back as
    anything but his Approve (_closed), leaving out the pickers settled names, which the record
    already holds one for. noted is {picker: the note taken when he answered it} (note_answer): a
    picker whose note holds a hash for the same repository and file is judged by the hash and the
    change time noted then, and any other, one noted by its ids alone included, by the file as it
    stands. sought is the ids of this session's noted pickers nothing has judged yet: closed also
    holds a `settled` line for each of those the transcript shows is no picker of a source this
    record reads (_asked), found in the same pass."""
    if not isinstance(transcript_path, str) or not transcript_path or not isinstance(session_id, str) or not session_id:
        return [], [], [], "the call named no session transcript, so a picker of his in this session could not be looked for"
    misplaced = _misplaced(transcript_path)
    if misplaced is not None:
        return [], [], [], misplaced
    other = set()
    try:
        asked = _asked(transcript_path, session_id, sought, other)
    except OSError as e:
        return [], [], [], ("this session's transcript could not be read (" + type(e).__name__
                            + "), so a picker of his in this session could not be looked for")
    ordinary = [_settled_other(session_id, uid, "the transcript shows it is no picker of a source this record reads ("
                                                + ", ".join(NOTED_SOURCES) + "), so it approves nothing and is not read again")
                for uid in sorted(other)]
    if not asked:
        return [], [], ordinary, None
    ap = _part("db_apply_approval_shared", "db-apply-approval.py")
    sw = _part("shell_words_shared", "shell-words.py")

    # The last word on each file: a later picker about it that ended any other way takes an earlier
    # Approve back.
    # nothis is, for each file, why the newest picker about it that holds an Approve is not an
    # answer of his (_not_his_approve), until a later picker about the file ends any other way.
    last, untaken, ended, nothis = {}, [], [], {}
    # A noted picker of this source that can never count (it names no repository and file, or was
    # sent with its answer filled in) is settled once it has been read, where one with no note is
    # passed over: a note left with no outcome has its session read back on every later call.
    never = []

    def never_counts(p, why):
        if p["picker"] in sought:
            never.append(_settled_other(session_id, p["picker"], why + ", so it approves nothing and is not read again"))

    for p in asked:
        meta = p["ask"]["metadata"]
        repo, file = repo_key(meta.get("repo")), meta.get("file")
        mine = p["ask"] if isinstance(p["ask"], dict) else {}
        chose = not p["prefilled"] and ap._answered(mine, p["result"], p["is_error"], APPROVE)
        # HE TYPED NOTHING BESIDE IT (module docstring): his Approve with words typed beside it is
        # an answer of his that is no approval, so it ends the picker as his `Not yet` does.
        typed = _typed_beside(p["result"]) if chose else None
        said = chose and typed is None
        if repo is None or not isinstance(file, str) or not file.startswith("/"):
            never_counts(p, "its metadata does not name the repository as owner/name and the wording file by its "
                            "absolute path")
        if said and (repo is None or not isinstance(file, str) or not file.startswith("/")):
            untaken.append({"repo": repo or "", "file": file if isinstance(file, str) else "",
                            "why": "its metadata does not name the repository as owner/name and the wording file by "
                                   "its absolute path"})
            continue
        if repo is None or not isinstance(file, str) or not file.startswith("/"):
            continue
        where = (repo, os.path.realpath(file))
        not_his = None if said else _typed_why(typed) if typed is not None else _not_his_approve(p)
        if not_his is None:
            nothis.pop(where, None)
        else:
            nothis[where] = not_his
        if p["prefilled"]:
            # No picker at all: it is the last word on nothing, and takes nothing back.
            never_counts(p, "the session sent it with its answer filled in, so it was never put to him")
            continue
        p.update(repo=repo, file=where[1], said=said)
        last[where] = p
        if not said and p["picker"] not in settled:
            ended.append(p)
    untaken += [{"repo": r, "file": f, "why": why} for (r, f), why in nothis.items()]
    closed = ordinary + never + [_closed(p, session_id, ap, noted, deadline) for p in ended]
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
        return [], untaken, closed, None

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
        return [], untaken, closed, None

    try:
        events = _file_events(transcript_path, session_id,
                              {p["file"]: os.path.basename(p["file"]) for p in readable}, sw)
    except OSError as e:
        return [], untaken, closed, ("this session's transcript could not be read (" + type(e).__name__
                                     + "), so whether the wording was opened in front of him could not be told")
    approved = []
    for p in readable:
        if SAVE_FIRST not in _question_shown(p):
            # THE QUESTION TELLS HIM TO SAVE (module docstring): an edit of his left unsaved in the
            # window is not in the file, so it would not be in the wording that is hashed.
            untaken.append({"repo": p["repo"], "file": p["file"],
                            "why": "the picker's question did not tell him to save the file, so an edit he made in "
                                   "the window and left unsaved would not be in the wording that is hashed. Open the "
                                   "file for him again and, as the very next tool call, ask again with a question "
                                   "that ends with the sentence `" + SAVE_FIRST + "`"})
            continue
        note = _note_for(p, noted)
        why = _not_shown(p, events[p["file"]], ap, note,
                         lambda first, last: _calls_on(transcript_path, session_id, first, last))
        digest = None
        if why is None and note is not None:
            # Hashed when he answered, so what the file holds now does not matter.
            digest, why = note.get("hash"), _text(note.get("why"))
            if why is None and not (isinstance(digest, str) and SHA.fullmatch(digest)):
                why = "the note taken when he answered holds no hash of the file"
        elif why is None:
            digest, why = _file_hash(p["file"], deadline)
        if why is not None:
            untaken.append({"repo": p["repo"], "file": p["file"], "why": why})
        else:
            approved.append({"kind": "approved", "repo": p["repo"], "hash": digest, "file": p["file"],
                             "picker": p["picker"], "session": session_id, "answered": _text(p["stamp"])})
    return approved, untaken, closed, None


def _question_shown(p):
    """The one question of picker p as the dialog showed it to him: the result's copy when it holds
    one, else the call's. Empty when neither holds a question in words."""
    for holder in (p["result"], p["ask"]):
        questions = holder.get("questions") if isinstance(holder, dict) else None
        if isinstance(questions, list) and questions and isinstance(questions[0], dict):
            text = questions[0].get("question")
            if isinstance(text, str) and text:
                return text
    return ""


def _not_shown(p, events, ap, note=None, calls_on=None):
    """None when the file Dan approved is the one that was in front of him and has not changed since,
    else why not. With note, the note taken when he answered (note_answer), "since" ends when the
    file was hashed for that note: the change time noted then is the one judged. calls_on(first,
    last) gives the session's tool calls on those transcript lines (_calls_on)."""
    opens, touches = events
    before = [(sent, uid) for sent, done, uid in opens if sent < p["sent"] and done < p["answered"]]
    if not before:
        return ("the file was not opened in front of him before the picker: no Bash call in this session is "
                "nothing but a BBEdit open of it with the front window flag that finished without error")
    opened, opener = max(before)
    if any(opened < t < p["answered"] for t in touches):
        return ("after the file was opened for him and before he answered, this session wrote it, or ran a "
                "command or sent an agent a prompt naming it, so what he had in front of him may not be what is "
                "in it")
    # The open is the session's last tool call before the picker (claude-config#3742): any call
    # between the two may have put another window in front, and the picker names no file to him.
    if calls_on is not None:
        try:
            others = [name for uid, name in calls_on(opened, p["sent"]) if uid not in (opener, p["picker"])]
        except OSError as e:
            return ("this session's transcript could not be read (" + type(e).__name__ + "), so whether the open of the "
                    "file was the session's last tool call before the picker could not be told")
        if others:
            return ("after the file was opened for him this session made another tool call (" + others[0]
                    + (", and %d more" % (len(others) - 1) if len(others) > 1 else "") + ") before it put the picker, "
                    "so another window may have been in front of him when he answered: the open must be the "
                    "session's last tool call before the picker. To ask him again, open the file again and put the "
                    "picker in the very next tool call")
    answered = ap._stamp_ns(p["stamp"])
    if answered is None:
        return "the transcript does not say when he answered, so whether the file changed afterwards could not be told"
    if note is not None:
        changed = note.get("changed")
        if not isinstance(changed, int) or isinstance(changed, bool):
            return _text(note.get("why")) or "the note taken when he answered does not say when the file last changed"
        if changed >= answered:
            return ("the file had changed after he answered when the hash noted for his answer was taken, so that "
                    "hash is not of the wording he approved")
        return None
    try:
        changed = os.stat(p["file"]).st_ctime_ns
    except OSError as e:
        return "the file could not be read (" + type(e).__name__ + "), so the wording he approved cannot be hashed"
    if changed >= answered:
        return ("the file has changed since he answered, and no hash of it was noted when he answered, so the wording "
                "he approved cannot be told from it. Open the file for him again and ask him again")
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
    # Every blank line is dropped before the hash, so the hash cannot tell a padded file from its
    # lines written together (claude-config#3703). lib/changelog-entry.js counts the longest run
    # that has wording after it, by its own reading of a blank line, and an answer that does not
    # say is no clearance (L98).
    run, at = answer.get("blankRun"), answer.get("blankRunAt")
    if not isinstance(run, int) or isinstance(run, bool) or not isinstance(at, int) or isinstance(at, bool):
        return None, ("lib/changelog-entry.js did not say how many blank lines in a row the file holds, so whether "
                      "wording sat below the screen he was shown could not be told (claude-sync pull reinstalls it)")
    if run > BLANK_RUN:
        return None, ("the file holds " + str(run) + " blank lines in a row, from line " + str(at) + ", with more "
                      "wording below them, so the window it was opened in showed him the lines above and then white "
                      "space, and he may never have seen the rest. Take the blank lines out, leaving no more than "
                      + str(BLANK_RUN) + " blank lines in a row anywhere above the last line of wording, then open the "
                      "file for him and ask him again")
    return answer["hash"], None


def _harvest(payload, notes, key):
    """This session's pickers, the pickers the record notes that nothing has judged (those naming
    repository key, and those noted by their ids alone), and the record, read once for one call:
    (found, untaken, closed, unlooked, entries, unreadable), as approvals() and read_record() give
    them. Each approval of his found and not yet on the record is written to it here, and so is the
    line of each picker that came back any other way or is none of this record's, unless the call
    is a subagent's; a failed save is added to notes (module docstring)."""
    deadline = time.monotonic() + CHECK_SECONDS
    entries, unreadable = read_record()
    noted = _noted(entries)
    own = _text(payload.get("session_id"))
    # A picker the record already holds an ending for (withdrawn, settled) is not worked out again.
    ended = {(e.get("session"), e.get("picker")) for e in entries or [] if e.get("kind") in ("withdrawn", "settled")}
    on_record = ended | {(e.get("session"), e.get("picker")) for e in entries or [] if e.get("kind") == "approved"}

    def unjudged(session):
        """The session's noted pickers the record holds no outcome for (EVERY PICKER IS NOTED):
        {picker: its note}, of the notes that name this repository or name none (a note by its ids
        alone, which may be about any)."""
        return {p: n for p, n in noted.get(session, ("", {}))[1].items()
                if (session, p) not in on_record and n.get("repo") in (key, None)}

    found, untaken, closed, unlooked = approvals(payload.get("session_id"), payload.get("transcript_path"), deadline,
                                                 noted.get(own, ("", {}))[1], {p for s, p in ended if s == own},
                                                 set(unjudged(own)))
    # A picker the record notes, in any session, that the record holds no outcome for yet: read
    # back from that session's own transcript, in one pass for all of the session's, for the
    # NOTED_SESSIONS sessions whose newest such note is newest. This is what a caller naming no
    # session of its own (the merge helper) is approved by, and refused by when what he answered
    # was Not yet. A session is ranked by its newest note and not its first: every picker is noted,
    # so a session's first note is its first picker of any kind, long before the one about wording.
    looked = own if _text(payload.get("transcript_path")) else None
    place = {}
    for i, e in enumerate(entries or []):
        if e.get("kind") == "answered":
            place.setdefault((_text(e.get("session")), _text(e.get("picker"))), i)
    waiting = sorted((s for s in noted if s != looked and unjudged(s)),
                     key=lambda s: max(place.get((s, p), -1) for p in unjudged(s)))
    unlooked = [unlooked] if unlooked else []
    for session in waiting[-NOTED_SESSIONS:]:
        transcript, pickers = noted[session]
        left = unjudged(session)
        if _gone(transcript):
            # Its transcript is gone, so what a picker noted by its ids alone asked can never be
            # read: settled, so it is not looked for on every later call. A note that names this
            # repository is left to the reading below, which says the transcript could not be read.
            bare = sorted(p for p, n in left.items() if n.get("repo") is None)
            closed += [_settled_other(session, p, "its session's transcript is gone (" + transcript + "), so what it "
                                                  "asked can never be read: it approves nothing and is not read again")
                       for p in bare]
            if len(bare) == len(left):
                continue
        more, less, over, why = approvals(session, transcript, deadline, pickers, {p for s, p in ended if s == session},
                                          set(left))
        found += more
        untaken += less
        closed += over
        if why:
            unlooked.append("an answer of his the record notes, in the session whose transcript is " + transcript
                            + ", could not be read back: " + why)
    if (found or closed) and not payload.get("agent_id"):
        # One line per picker of his: the same wording approved in a second picker is a second
        # approval, which covers a second pull request.
        fresh = [f for f in found if entries is None or not any(
            e.get("kind") == "approved" and e.get("repo") == f["repo"] and e.get("hash") == f["hash"]
            and e.get("session") == f["session"] and e.get("picker") == f["picker"] for e in entries)]
        lines = [dict(f, at=_now()) for f in fresh + closed]
        failed = _append(lines) if lines else None
        if failed and fresh:
            notes.append(
                "Dan approved the wording in " + ", ".join(sorted({f["file"] for f in fresh})) + " in a picker"
                ", but that approval could not be saved: " + failed + ". His picker still counts for "
                "this call, but a later session will ask him again until that record can be written.")
        took = sorted({c["file"] for c in closed if c["kind"] == "withdrawn"})
        if failed and took:
            notes.append(
                "Dan answered a picker about the wording in " + ", ".join(took) + " with something other than `"
                + APPROVE + "`, which takes back his earlier approval of it, but that could not be saved: " + failed
                + ". It counts for this call, but a call that cannot read this session's transcript will not know "
                "of it until that record can be written.")
    return found, untaken, closed, ". ".join(w.rstrip(".") for w in unlooked) or None, entries, unreadable


def _said(why, key, untaken, unreadable, unlooked):
    """One refusal's reasons as a sentence each: the first, then what could not be read, then each
    Approve of his for this repository that does not count."""
    why = list(why)
    if unreadable:
        why.append(unreadable)
    if unlooked:
        why.append(unlooked)
    for u in untaken:
        if u["repo"] in (key, ""):
            why.append("his Approve for " + (u["file"] or "a file it did not name") + " does not count: " + u["why"])
    return ". ".join(w.rstrip(".") for w in why) + "."


def _pull_requests(numbers):
    """Pull requests named in a sentence: `pull request 7`, `pull requests 7 and 8`."""
    named = [str(n) for n in numbers]
    if len(named) == 1:
        return "pull request " + named[0]
    return "pull requests " + ", ".join(named[:-1]) + " and " + named[-1]


def _lock(fd):
    """Take the record's lock for a claim: None once it is held, else why not. The lock is the
    kernel's (flock), so a holder that dies releases it."""
    import fcntl
    deadline = _clock() + CLAIM_LOCK_SECONDS
    while True:
        try:
            fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            return None
        except BlockingIOError:
            if _clock() >= deadline:
                return ("the record of the wording Dan approved, " + record_path() + ", was held by another check for "
                        + str(CLAIM_LOCK_SECONDS) + " seconds, so this pull request's use of his approval could not "
                        "be written to it")
            _sleep(0.02)
        except OSError as e:
            return _unwritable(record_path(), e)


def _claim_pause():
    """Seam, for the tests: a wait, of at most 2 seconds, between a claim's decision and its write,
    inside the lock, so a case with two claims at once does not depend on luck. It can only make a
    claim hold the lock longer; it lets nothing through."""
    try:
        seconds = float(os.environ.get("ANNOUNCE_APPROVAL_CLAIM_PAUSE") or "")
    except ValueError:
        return
    if 0 < seconds <= 2:
        _sleep(seconds)


def _claim(repo, digest, pr, judged):
    """The merge gate's question, answered and recorded in one hold of the record's lock: (whether
    pr is covered, the count of approvals, the pull requests that used them, None), or (False, 0,
    [], why its use could not be recorded). judged(entries) is check's own reading of a record."""
    if not isinstance(pr, int) or isinstance(pr, bool):
        return False, 0, [], "the merge gate named no pull request number, so there is no pull request to record as using it"
    folder, path = record_dir(), record_path()
    try:
        os.makedirs(folder, mode=0o700, exist_ok=True)
        fd = os.open(path, os.O_RDWR | os.O_APPEND | os.O_CREAT, 0o600)
    except OSError as e:
        return False, 0, [], _unwritable(path, e)
    try:
        held = _lock(fd)
        if held is not None:
            return False, 0, [], held
        entries, unreadable = read_record()
        if entries is None:
            return False, 0, [], unreadable
        count, users, covered = judged(entries)
        if covered and pr not in users:
            _claim_pause()
            failed = _append([{"kind": "used", "repo": repo, "hash": digest, "pr": pr, "claim": True, "closes": None,
                               "unread": None, "at": _now()}])
            if failed:
                return False, 0, [], failed
        return covered, count, users, None
    finally:
        os.close(fd)


def check(repo, digest, payload, pr=None, claim=False):
    """Whether digest is wording Dan approved for repo that pull request pr may use, and, with
    claim, the record of pr using it (module docstring)."""
    out = {"approved": False, "state": "unapproved", "why": "", "how": HOW_TO_ASK, "notes": []}
    key = repo_key(repo)
    if key is None:
        out["why"] = "the repository could not be told as owner/name, so no approval of Dan's could be looked up for it"
        return out
    if not isinstance(digest, str) or not SHA.fullmatch(digest):
        out["why"] = "the announcement gave no hash, so there is no wording to look an approval up for"
        return out
    pr = pr if isinstance(pr, int) and not isinstance(pr, bool) else None
    record_only = payload is None
    payload = payload if isinstance(payload, dict) else {}
    if record_only:
        # The command line a session can run (claude-config#3703): the record, and nothing else. No
        # transcript is read, so nothing a caller hands over can be taken for his answer, and
        # nothing is written.
        found, untaken, closed, unlooked = [], [], [], RECORD_ONLY
        entries, unreadable = read_record()
    else:
        found, untaken, closed, unlooked, entries, unreadable = _harvest(payload, out["notes"], key)

    def judged(record):
        count = len(_approval_keys(record, found, key, digest, closed)[0])
        users = _users(record, key, digest)
        return count, users, _covers(count, users, pr)

    # A record that cannot be read names no pull request that used anything: his picker in this
    # session still counts for a question that claims nothing (Dan, 2026-11-16), and a claim, which
    # reads the record again under its lock, is refused there.
    count, users, covered = judged(entries)
    if count == 0 and _approval_keys(entries, found, key, digest, closed)[1] is not None:
        # He did approve it, and his later answer took that back: said as what happened, so the
        # session is not told he never approved wording it watched him approve.
        out["why"] = _said(["Dan approved this wording for " + key + " and then, asked about it again, answered "
                            "something other than `" + APPROVE + "` alone (`Not yet`, words of his own, or an Approve "
                            "with words typed beside it), which took that "
                            "approval back: his last answer on a wording decides, on this Mac's record as in the "
                            "session. Change what he wanted changed, then ask him again"],
                           key, untaken, unreadable, unlooked)
        return out
    if count == 0:
        why = ["Dan has not approved this wording for " + key + ": no approval on this Mac's record"
               + ("" if record_only else ", and none in this session,") + " is of the announcement as it reads here"]
        for f in found:
            if f["repo"] == key:
                why.append("the wording he approved in " + f["file"] + " is not this wording (they differ once "
                           "normalised), so make the Announcement block that file's text, or ask him again")
        # What IS on the record about this wording, said so the session is not told he never
        # approved wording it watched him approve (claude-config#3742).
        elsewhere = sorted({e.get("repo") for e in list(entries or []) + list(found)
                            if e.get("kind") == "approved" and e.get("hash") == digest
                            and isinstance(e.get("repo"), str) and e.get("repo") != key
                            and _approval_keys(entries, found, e.get("repo"), digest, closed)[0]})
        if elsewhere:
            why.append("he approved this same wording for " + " and ".join(elsewhere) + ", which this Mac's record "
                       "holds as another repository: an approval covers the repository its picker's metadata named. "
                       "If that is this repository under another name, ask him again with \"repo\": \"" + key + "\"")
        if pr is not None and pr in users:
            why.append("this Mac's record holds pull request " + str(pr) + " as let through on this wording before, "
                       "and holds no approval behind that use: his approval was read in a call that writes none (a "
                       "subagent's), or its line is gone from the record. So he is asked again")
        out["why"] = _said(why, key, untaken, unreadable, unlooked)
        return out
    if covered and claim:
        covered, count, users, failed = _claim(key, digest, pr, judged)
        if failed is not None:
            out["state"] = "unrecorded"
            out["why"] = ("Dan approved this wording for " + key + ", but nothing could record that "
                          + ("pull request " + str(pr) if pr is not None else "this merge") + " used that approval: "
                          + failed + ". One approval covers one pull request, so a merge whose use of it cannot be "
                          "recorded is refused.")
            out["how"] = ("Put that right (the record is kept in " + record_dir() + ", which must take a line), then "
                          "run the same merge again: he does not need to be asked again.")
            return out
    if covered:
        out["approved"], out["state"] = True, "approved"
        return out
    out["state"] = "used"
    took = users[:count]
    why = ("Dan approved this wording for " + key + (" once" if count == 1 else " %d times" % count) + ", and "
           + _pull_requests(took) + " used " + ("that approval" if count == 1 else "those approvals") + ": one approval "
           "covers one pull request, which may try its merge again, and a different pull request carrying the same "
           "wording asks him again")
    if pr is None:
        why += (". This command names no pull request by number, so it could not be told from "
                + ("that one" if len(took) == 1 else "those"))
    out["why"] = _said([why], key, untaken, unreadable, unlooked)
    return out


def mark_used(repo, digest, pr, closes=None, unread=None):
    """Record that the merge gate let pull request pr of repo through on digest: None, or why the
    line could not be written. closes is [{issue, milestone}] for the issues it closes, or None with
    unread saying why they could not be read. Beside its claim (check, with claim), one pull request
    and one wording get at most two lines: one saying its issues could not be read, when that came
    first, and one naming them. A merge tried again adds nothing it already said, and an unread line
    never follows a read one."""
    key = repo_key(repo)
    if key is None or not isinstance(digest, str) or not SHA.fullmatch(digest) or not isinstance(pr, int):
        return "the used line names no repository as owner/name, no hash or no pull request number"
    entries, why = read_record()
    if entries is None:
        return why
    mine = [e for e in entries
            if e.get("kind") == "used" and e.get("repo") == key and e.get("hash") == digest and e.get("pr") == pr
            and e.get("claim") is not True]
    if any(e.get("closes") is not None for e in mine) or (closes is None and mine):
        return None
    return _append([{"kind": "used", "repo": key, "hash": digest, "pr": pr, "closes": closes,
                     "unread": unread or None, "at": _now()}])


def _flag(args, name):
    return args[args.index(name) + 1] if name in args and args.index(name) + 1 < len(args) else None


def main(argv):
    command, args = (argv[1] if len(argv) > 1 else ""), argv[2:]
    if command == "check":
        # Without --claim this is the question a session can ask: the record only, with standard
        # input not read at all. With it, it is the merge gate's, which carries the payload Claude
        # Code handed the gate (claude-config#3703).
        payload = None
        if "--claim" in args:
            try:
                payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
            except ValueError:
                payload = {}
        pr = _flag(args, "--pr")
        json.dump(check(_flag(args, "--repo"), _flag(args, "--hash"), payload,
                        int(pr) if pr and pr.isdigit() else None, "--claim" in args), sys.stdout)
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
    if command == "answered":
        # announce-answer-note.sh's, with what Claude Code handed that hook on standard input.
        try:
            payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
        except ValueError:
            # Not a JSON object, so there is no picker to note, which note_answer says in its own words.
            payload = None
        noted, why = note_answer(payload, time.monotonic() + NOTE_SECONDS)
        json.dump({"noted": noted, "why": why or ""}, sys.stdout)
        return 0
    if command == "list":
        entries, why = read_record()
        json.dump({"record": record_path(), "entries": entries, "why": why or ""}, sys.stdout)
        return 0
    sys.stderr.write("Usage: announce-approval.py list | check --repo <owner/name> --hash <sha256> [--pr <number>], which reads "
                     "the record only | check --repo <owner/name> --hash <sha256> --pr <number> --claim, with the hook payload "
                     "on standard input | used --repo <owner/name> --hash <sha256> --pr <number> [--closes <json>] "
                     "[--unread <why>] | answered, with the PostToolUse payload on standard input\n")
    return 2


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
