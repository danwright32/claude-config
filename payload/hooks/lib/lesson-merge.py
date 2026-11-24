#!/usr/bin/env python3
"""What a pull request does to the lesson entries of payload/LESSONS.md, and whether Dan's answer
in the lesson picker's merge form covers it (claude-config#3343, route 3).

Dan, 2026-11-20, by picker ("Guard the merge (Recommended)"): a pull request that adds or changes
an entry in payload/LESSONS.md, other than by the sync's send, cannot merge until he has answered
the lesson picker for it, and a sweep over many entries gets one question naming the count and the
change. lessons-merge-gate.sh is the gate; this file is its rule, so the rule is written once.

THE ENTRIES. A lessons file is walked as its own reader walks it (claude-sync lesson_entries_render,
the ask before saving mod's lessonLayout): an entry starts at a line matching ENTRY_START and owns
every line down to the next such line or the next "## " heading, the blank lines at its end
dropped; its section is the heading above it. Between the file at the pull request's merge base
and the file at its head, four things are found, and each needs his answer:
  added     a number the head holds and the base does not
  changed   a number in both whose lines differ (spaces and tabs at a line's end are ignored, and
            nothing else: the reader takes an entry's first line and its SHORT line by where a line
            starts, so a rule wrapped another way is another entry to it)
  removed   a number the base holds and the head does not
  moved     the same lines under another section heading (a renamed heading moves every entry
            under it), which changes the index file every session loads it from
Text above the first heading, text under a heading that is no entry's, blank lines between entries
and the order of entries or sections are no entry's change, and are never asked about.

WHAT TIES AN ANSWER TO A CHANGE. One sha256 (digest) over the repository, the pull request's
number and every added, changed, removed and moved entry, lines and sections included. The picker
names it in its metadata, {"source": "lesson-merge", "repo": "<owner/name>", "pr": <number>,
"sha256": "<the digest>"}, and an answer counts only for a merge whose change, read again from
GitHub, gives that same digest. One entry reworded after he answered is another digest.

WHAT HE MUST HAVE READ. The question he answered must hold, each on a line of its own:
  - the facts line (facts): the pull request, and how many entries it adds, changes, removes and
    moves, with their numbers;
  - when every added or changed entry's rule and SHORT line fit in the dialog beside it (ROWS_MAX
    rows of ROW_COLUMNS, inside the 20 rows of 76 the shared picker check allows): each one's rule
    after its number, white space folded, and its SHORT line word for word, since the SHORT line is
    what every session loads;
  - otherwise, the sweep: a line starting CHANGE_LINE, the session's own account of the change. The
    count and the numbers are in the facts line.
Its two answers are MERGE and REFUSE and nothing else. A question missing any of it covers nothing,
and the refusal says which lines it lacked.

WHERE HIS ANSWER IS READ. As the database apply's is (lib/db-apply-approval.py, answered_asks):
from the session's transcript, a picker of one question that carried no answers of its own, did
not close by itself, was answered exactly MERGE, and that he could read as written (the shared
picker check). merge-when-ready.sh asks the gate with no transcript, so each such answer is also
kept on a record on this Mac, <record>/answers.jsonl, one JSON line holding the repository, the
number, the digest and the question he read; the gate writes it whenever it runs with a main
session's transcript (a subagent's call reads his picker and writes nothing). The record has no
expiry: an answer is about content, and the same content is the same question.
WHAT THE RECORD CANNOT SEE: a line written into it by an Edit, a Write or a script that builds its
path at run time. The gate refuses a shell command that names the folder.

    lesson-merge.py judge --repo <owner/name> --pr <number> --base <file> --head <file>
                          --record-dir <folder> [--transcript <file> --session <id>] [--agent]
                          [--asleep]
        A file that is not there reads as a lessons file with no entries. Prints one JSON object:
        {"verdict": "untouched"} when no entry is added, changed, removed or moved,
        {"verdict": "covered"} when an answer of his covers the change, else
        {"verdict": "refuse", "reason": <what the session is told>}.
    lesson-merge.py harvest --record-dir <folder> --transcript <file> --session <id>
        Keeps on the record every answer the transcript holds. Exit 3, saying why on stderr, when
        one could not be written.
Exit 0 when judged; 2 when it could not judge, said on stderr, which a caller must refuse on.
"""
import hashlib
import json
import os
import re
import sys

SOURCE = "lesson-merge"
MERGE = "Merge these lessons"
REFUSE = "Do not merge"
PATH = "payload/LESSONS.md"
ENTRY_START = re.compile(r"^- \*\*(L[0-9]+)\.")
SECTION_START = re.compile(r"^## ")
RULE = re.compile(r"^- \*\*L[0-9]+\.\s*(.*?)\*\*")
# The numbers of one kind are written out up to this many; past it the facts line gives the count
# and the first and last. Chosen, not measured: twelve numbers are about seventy characters.
IDS_SHOWN = 12
# The rules and SHORT lines are stated word for word while the required lines take at most this
# many rows of this many columns. The shared picker check allows a question 20 rows of 76; these
# leave five rows for the session's own words and four columns for a word that wraps early.
ROWS_MAX = 15
ROW_COLUMNS = 72
CHANGE_LINE = "The change: "
CHANGE_MIN = 20
RECORD_NAME = "answers.jsonl"
SHA = re.compile(r"^[0-9a-f]{64}$")


def entries(text):
    """{key: (section, lines)} for a lessons file, in file order. The key is the entry's number,
    and for a number the file holds more than once, the number with which copy it is."""
    found, section, current = [], "", None
    for raw in text.split("\n"):
        line = raw.rstrip(" \t\r")
        start = ENTRY_START.match(line)
        if start or SECTION_START.match(line):
            if current is not None:
                found.append(current)
            current = None
            if start:
                current = [start.group(1), section, [line]]
            else:
                section = line[3:].strip()
        elif current is not None:
            current[2].append(line)
    if current is not None:
        found.append(current)
    out, seen = {}, {}
    for number, sect, lines in found:
        while lines and not lines[-1]:
            lines.pop()
        seen[number] = seen.get(number, 0) + 1
        key = number if seen[number] == 1 else "%s (copy %d)" % (number, seen[number])
        out[key] = (sect, "\n".join(lines))
    return out


def _order(key):
    m = re.match(r"L([0-9]+)", key)
    return (int(m.group(1)) if m else 0, key)


def change(base, head):
    """What the head's file does to the base's entries: the four lists of keys, each in number
    order, with both walks."""
    b, h = entries(base), entries(head)
    return {
        "added": sorted((k for k in h if k not in b), key=_order),
        "changed": sorted((k for k in h if k in b and h[k][1] != b[k][1]), key=_order),
        "removed": sorted((k for k in b if k not in h), key=_order),
        "moved": sorted((k for k in h if k in b and h[k][1] == b[k][1] and h[k][0] != b[k][0]), key=_order),
        "base": b,
        "head": h,
    }


def touches(c):
    return bool(c["added"] or c["changed"] or c["removed"] or c["moved"])


def digest(repo, pr, c):
    b, h = c["base"], c["head"]
    body = {
        "repo": repo.lower(), "pr": int(pr), "path": PATH,
        "added": [[k, h[k][0], h[k][1]] for k in c["added"]],
        "changed": [[k, h[k][0], h[k][1]] for k in c["changed"]],
        "removed": list(c["removed"]),
        "moved": [[k, b[k][0], h[k][0]] for k in c["moved"]],
    }
    text = json.dumps(body, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("ascii")).hexdigest()


def _numbers(keys):
    if len(keys) <= IDS_SHOWN:
        return ", ".join(keys)
    return "between %s and %s" % (keys[0], keys[-1])


def facts(repo, pr, c):
    """The one line that says what the pull request does to the entries, counts and numbers."""
    parts = []
    for kind, word in (("added", "added"), ("changed", "changed"), ("removed", "removed"),
                       ("moved", "moved to another section")):
        keys = c[kind]
        if keys:
            parts.append("%d %s %s (%s)" % (len(keys), "entry" if len(keys) == 1 else "entries", word, _numbers(keys)))
    return "Pull request #%d in %s changes %s: %s." % (int(pr), repo, PATH, ", ".join(parts))


def shown_lines(c):
    """For each added or changed entry, its rule after its number and its SHORT lines."""
    out = []
    for key in sorted(c["added"] + c["changed"], key=_order):
        text = c["head"][key][1]
        flat = " ".join(text.split())
        m = RULE.match(flat)
        rule = m.group(1).strip() if m else " ".join(text.split("\n")[0].split()).lstrip("- ").replace("**", "")
        out.append("%s: %s" % (key, rule))
        out.extend(l.strip() for l in text.split("\n") if l.strip().startswith("SHORT:"))
    return out


def required(repo, pr, c):
    """(the lines the question must hold, whether it is the sweep form)."""
    first = [facts(repo, pr, c)]
    detail = shown_lines(c)
    rows = sum(max(1, -(-len(l) // ROW_COLUMNS)) for l in first + detail)
    if detail and rows > ROWS_MAX:
        return first, True
    return first + detail, False


def missing(question, lines, sweep):
    """What of the required lines the question Dan read does not hold, in words."""
    held = [l.strip() for l in question.split("\n")]
    out = ['the line "%s"' % l for l in lines if l not in held]
    if sweep and not any(l.startswith(CHANGE_LINE) and len(l) - len(CHANGE_LINE) >= CHANGE_MIN for l in held):
        out.append('a line starting "%s" that says what the pull request does to those entries' % CHANGE_LINE)
    return out


def _approval():
    import importlib.util
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "db-apply-approval.py")
    spec = importlib.util.spec_from_file_location("db_apply_approval", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _picker(asked):
    """(repo, pr, sha256, question) of a picker's input when it is the merge form's, else None."""
    meta = asked.get("metadata")
    questions = asked.get("questions")
    if not isinstance(meta, dict) or not isinstance(questions, list) or len(questions) != 1:
        return None
    q = questions[0] if isinstance(questions[0], dict) else {}
    repo, pr, sha, question = meta.get("repo"), meta.get("pr"), meta.get("sha256"), q.get("question")
    options = q.get("options")
    labels = sorted(o.get("label").strip() for o in options if isinstance(o, dict) and isinstance(o.get("label"), str)) \
        if isinstance(options, list) else []
    if isinstance(pr, str) and pr.isdigit():
        pr = int(pr)
    if (not isinstance(repo, str) or not isinstance(pr, int) or isinstance(pr, bool) or not isinstance(sha, str)
            or not SHA.match(sha) or not isinstance(question, str) or labels != sorted((MERGE, REFUSE))):
        return None
    return (repo.lower(), pr, sha, question)


def from_transcript(transcript, session):
    """(answers, why not): the merge form's pickers Dan answered MERGE in this session, each as
    _picker gives it, and what could not be read, in words, or ''."""
    if not transcript or not session:
        return [], ""
    unread = []
    try:
        asks = _approval().answered_asks(transcript, session, SOURCE, MERGE, unread)
    except Exception as e:  # a transcript or a library that cannot be read covers nothing
        return [], "this session's transcript could not be read for his answer (%s)" % type(e).__name__
    answers = [p for p in (_picker(a) for a in asks) if p is not None]
    why = "; ".join(sorted(set(w for _, w in unread)))
    return answers, why


def on_record(folder):
    out = []
    try:
        with open(os.path.join(folder, RECORD_NAME), "r", encoding="utf-8", errors="replace") as f:
            for line in f:
                try:
                    e = json.loads(line)
                except ValueError:
                    continue
                if isinstance(e, dict) and isinstance(e.get("repo"), str) and isinstance(e.get("pr"), int) \
                        and isinstance(e.get("sha256"), str) and isinstance(e.get("question"), str):
                    out.append((e["repo"].lower(), e["pr"], e["sha256"], e["question"]))
    except FileNotFoundError:
        pass
    return out


def keep(folder, answers):
    """Appends to the record each answer it does not hold. Raises OSError when it cannot."""
    have = set(on_record(folder))
    new = [a for a in answers if a not in have]
    if not new:
        return 0
    os.makedirs(folder, mode=0o700, exist_ok=True)
    import time
    text = "".join(json.dumps({"repo": r, "pr": p, "sha256": s, "question": q, "at": int(time.time())},
                              ensure_ascii=True) + "\n" for r, p, s, q in dict.fromkeys(new))
    fd = os.open(os.path.join(folder, RECORD_NAME), os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)
    try:
        os.write(fd, text.encode("ascii"))
    finally:
        os.close(fd)
    return len(new)


def _unshown(lines):
    """Why Dan would not read the required lines as written in a picker, or None. Raises when the
    shared check cannot be run."""
    ask = {"questions": [{"question": "\n".join(lines), "header": "Lessons", "multiSelect": False,
                          "options": [{"label": MERGE, "description": "The pull request may merge."},
                                      {"label": REFUSE, "description": "The pull request stays open."}]}]}
    return _approval().picker_faults([ask])[0]


def _read(path):
    try:
        with open(path, "rb") as f:
            return f.read().decode("utf-8", "replace")
    except FileNotFoundError:
        return ""


def judge(a):
    c = change(_read(a["base"]), _read(a["head"]))
    if not touches(c):
        return {"verdict": "untouched"}
    repo, pr = a["repo"], int(a["pr"])
    sha = digest(repo, pr, c)
    lines, sweep = required(repo, pr, c)
    said, unread = from_transcript(a.get("transcript"), a.get("session"))
    unkept = ""
    if said and not a.get("agent"):
        try:
            keep(a["record"], said)
        except OSError as e:
            unkept = " (His answer could not be kept on this Mac's record, %s: %s, so the merge helper, which reads the record alone, will not find it.)" % (
                os.path.join(a["record"], RECORD_NAME), e.strerror or type(e).__name__)
    answers = [x for x in said + on_record(a["record"]) if x[0] == repo.lower() and x[1] == pr and x[2] == sha]
    lacks = None
    for answer in answers:
        lacks = missing(answer[3], lines, sweep)
        if not lacks:
            return {"verdict": "covered"}
    head = ("Refusing to merge PR #%d: it changes lesson entries in %s, which every session on both Macs loads once "
            "this merges, and Dan has not answered the lesson picker for them (claude-config#3343). " % (pr, PATH)) + facts(repo, pr, c)
    if lacks:
        head = ("Refusing to merge PR #%d: Dan answered %s for these lesson entries, but the question he read did not hold %s, "
                "and his answer covers only what he was shown (claude-config#3343). " % (pr, MERGE, "; ".join(lacks))) + facts(repo, pr, c)
    if a.get("asleep"):
        return {"verdict": "refuse", "reason": head + " Dan is asleep (sleep mode), so he is not asked tonight: this merge waits "
                "for him. Ask nothing, leave the pull request open, and do not merge it another way." + unkept}
    if not sweep:
        try:
            fault = _unshown(lines)
        except Exception as e:
            return {"verdict": "refuse", "reason": head + " The picker for it cannot be put yet: whether Dan could read its lines as "
                    "written could not be checked (%s), and his answer counts only for text he can read. Nothing was merged." % e}
        if fault is not None:
            return {"verdict": "refuse", "reason": head + " The lesson picker cannot be put for it: a rule or SHORT line of these "
                    "entries would not reach Dan as written (%s), and he approves only text he can read. Reword that entry on the "
                    "branch so it can be shown, or leave the merge to Dan." % fault}
    how = ("\n\nAsk him %s, with AskUserQuestion: one question, the two options \"%s\" and \"%s\", no answers filled in, and "
           "metadata {\"source\": \"%s\", \"repo\": \"%s\", \"pr\": %d, \"sha256\": \"%s\"}. The question must hold each of "
           "these lines, word for word, on a line of its own:\n\n%s\n\n"
           % ("again" if lacks else "once", MERGE, REFUSE, SOURCE, repo, pr, sha, "\n".join(lines)))
    if sweep:
        how += ("It must also hold a line starting \"%s\" that says in plain words what the pull request does to those entries "
                "(at least %d characters). " % (CHANGE_LINE, CHANGE_MIN))
    how += ("Then send this merge again, or start the merge helper again: his answer is read from this session and kept for the "
            "helper. It covers exactly these entries as they are now, so a push that changes one of them is asked about again. "
            "A subagent cannot ask: hand this back to the main session.")
    if unread:
        how += " (An answer was not taken: %s.)" % unread
    return {"verdict": "refuse", "reason": head + how + unkept}


def main(argv):
    if len(argv) < 2 or argv[1] not in ("judge", "harvest"):
        sys.stderr.write("usage: lesson-merge.py judge|harvest ... (see the top of the file)\n")
        return 2
    a, rest = {"agent": False, "asleep": False}, argv[2:]
    names = {"--repo": "repo", "--pr": "pr", "--base": "base", "--head": "head", "--record-dir": "record",
             "--transcript": "transcript", "--session": "session"}
    i = 0
    while i < len(rest):
        if rest[i] in ("--agent", "--asleep"):
            a[rest[i][2:]] = True
            i += 1
        elif rest[i] in names and i + 1 < len(rest):
            a[names[rest[i]]] = rest[i + 1]
            i += 2
        else:
            sys.stderr.write("lesson-merge.py: cannot read the argument %r\n" % rest[i])
            return 2
    if argv[1] == "harvest":
        if not a.get("record") or not a.get("transcript") or not a.get("session"):
            sys.stderr.write("lesson-merge.py harvest: needs --record-dir, --transcript and --session\n")
            return 2
        said, _ = from_transcript(a["transcript"], a["session"])
        try:
            keep(a["record"], said)
        except OSError as e:
            sys.stderr.write("%s: %s\n" % (os.path.join(a["record"], RECORD_NAME), e.strerror or type(e).__name__))
            return 3
        return 0
    for need in ("repo", "pr", "base", "head", "record"):
        if not a.get(need):
            sys.stderr.write("lesson-merge.py judge: needs --%s\n" % {"record": "record-dir"}.get(need, need))
            return 2
    if not str(a["pr"]).isdigit():
        sys.stderr.write("lesson-merge.py judge: --pr is not a number\n")
        return 2
    sys.stdout.write(json.dumps(judge(a)) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # never a silent pass: the gate refuses on any exit but 0
        sys.stderr.write("lesson-merge.py could not judge: %s: %s\n" % (type(e).__name__, e))
        sys.exit(2)
