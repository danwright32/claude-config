#!/usr/bin/env python3
"""Whether Dan has answered the picker a lessons review names when it stops a pull request at its
fourth round of findings (claude-config#3557).

From the fourth round of findings that stopped a push or merge of one pull request,
lib/pr-review.sh stops asking for the next fix and refuses until Dan has answered for that review.
This file is the rule for his answer, so it is written once: what ties an answer to a review, what
the question must have shown him, and where the answer is read. pr-review.sh keeps the round count
and writes every word of the refusal but the lines below.

WHAT TIES AN ANSWER TO A REVIEW. One sha256 (digest) over the repository, the branch, the whole head
commit, the base the review read from, the review's finish time, the round's number and how many
findings the review holds. The picker names it in its metadata,

    {"source": "review-round", "repository": "<owner/name>", "branch": "<branch>",
     "head": "<the whole head commit>", "round": <number>, "sha256": "<the digest>"}

and an answer counts only for a check whose own review gives that same digest. Another branch,
another head, the same head reviewed again, or another round is another digest.

WHAT HE MUST HAVE READ. The question he answered must hold, each on a line of its own:
  - the facts line (facts): the round, the branch, the repository, the head, how many findings the
    review holds and how many earlier rounds stopped a push or merge;
  - a line starting FINDINGS_LINE, the session's own account of the findings in plain words, at
    least FINDINGS_MIN characters. Nothing here can check those words against the findings, so the
    numbers are in the facts line, which is checked word for word.
Its three answers are NARROW, APPROACH and GO_ON and nothing else. Only GO_ON lifts the stop, and
only for that review: the push or merge of that head is then held as before the stop, by the
findings' read key. NARROW and APPROACH lift nothing: the work goes on to a new head, whose review
is asked about again when it is a round too.

WHERE HIS ANSWER IS READ. As the database apply's is (lib/db-apply-approval.py, answered_asks): from
the session's transcript, a picker of one question that carried no answers of its own, did not
close by itself, was answered exactly GO_ON, and that he could read as written (the shared picker
check). The transcript is the one the gate's hook payload names, so a subagent's call reads the
picker its session put to him. A transcript that cannot be read covers nothing.
WHAT IT CANNOT SEE: a picker written into the transcript by a script, which every answer read
this way shares, and the session's own words after FINDINGS_LINE.

    review-round.py judge --repository <owner/name> --branch <name> --head <commit> --base <commit>
                          --finished <epoch seconds> --round <number> --findings <number>
                          [--transcript <file> --session <id>]
        Prints ten lines, which pr-review.sh builds the refusal from so no word of the picker is
        written twice: `answered` or `unanswered`; the digest; the facts line; why an answer of his
        that was found was not taken (else an empty line); the picker's metadata as JSON; NARROW;
        APPROACH; GO_ON; FINDINGS_LINE without its closing space; FINDINGS_MIN.
Exit 0 when judged; 2 when it could not judge, said on stderr, which a caller must stop on.
"""
import hashlib
import json
import os
import sys

SOURCE = "review-round"
NARROW = "Narrow the change"
APPROACH = "Change the approach"
GO_ON = "Go on with these findings"
FINDINGS_LINE = "The findings: "
# The fewest characters the session's account of the findings may hold. Chosen, not measured, as
# the same floor the lesson merge form sets for its own account of a sweep (#3343): it only stops a
# line left empty.
FINDINGS_MIN = 20


def digest(a):
    body = {"repository": a["repository"].lower(), "branch": a["branch"], "head": a["head"].lower(),
            "base": a["base"].lower(), "finished": int(a["finished"]), "round": int(a["round"]),
            "findings": int(a["findings"])}
    text = json.dumps(body, sort_keys=True, ensure_ascii=True, separators=(",", ":"))
    return hashlib.sha256(text.encode("ascii")).hexdigest()


def facts(a):
    """The one line that says which review stopped and at which round, numbers only."""
    n, found, earlier = int(a["round"]), int(a["findings"]), int(a["round"]) - 1
    return ("Round %d of lessons review findings on %s in %s, at %s: the review holds %d finding%s, and %d earlier "
            "round%s of this pull request each stopped a push or merge."
            % (n, a["branch"], a["repository"], a["head"][:7], found, "" if found == 1 else "s",
               earlier, "" if earlier == 1 else "s"))


def missing(question, line):
    """What the question Dan read lacks of what it must hold, in words."""
    held = [l.strip() for l in question.split("\n")]
    out = []
    if line not in held:
        out.append('the line "%s"' % line)
    if not any(l.startswith(FINDINGS_LINE) and len(l) - len(FINDINGS_LINE) >= FINDINGS_MIN for l in held):
        out.append('a line starting "%s" that says in plain words what the findings are' % FINDINGS_LINE)
    return out


def _approval():
    import importlib.util
    # Loading a lib file with bytecode on would leave a __pycache__ in a folder the sync carries
    # (#2600).
    sys.dont_write_bytecode = True
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "db-apply-approval.py")
    spec = importlib.util.spec_from_file_location("db_apply_approval", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _picker(asked):
    """(sha256, question) of a picker's input when it is this form's, else None."""
    meta = asked.get("metadata")
    questions = asked.get("questions")
    if not isinstance(meta, dict) or not isinstance(questions, list) or len(questions) != 1:
        return None
    q = questions[0] if isinstance(questions[0], dict) else {}
    sha, question, options = meta.get("sha256"), q.get("question"), q.get("options")
    labels = sorted(o.get("label").strip() for o in options if isinstance(o, dict) and isinstance(o.get("label"), str)) \
        if isinstance(options, list) else []
    if not isinstance(sha, str) or not isinstance(question, str) or labels != sorted((NARROW, APPROACH, GO_ON)):
        return None
    return (sha, question)


def judge(a):
    """(whether his answer covers this review, why an answer found was not taken or '')."""
    sha, line = digest(a), facts(a)
    if not a.get("transcript") or not a.get("session"):
        return False, ""
    unread = []
    try:
        asks = _approval().answered_asks(a["transcript"], a["session"], SOURCE, GO_ON, unread)
    except Exception as e:  # a transcript or a library that cannot be read covers nothing
        return False, "this session's transcript could not be read for his answer (%s)" % type(e).__name__
    lacks = None
    for p in (_picker(x) for x in asks):
        if p is None or p[0] != sha:
            continue
        lacks = missing(p[1], line)
        if not lacks:
            return True, ""
    if lacks:
        return False, ("Dan answered \"%s\" for this review, but the question he read did not hold %s, and his answer "
                       "covers only what he was shown" % (GO_ON, "; ".join(lacks)))
    return False, "; ".join(sorted(set(w for _, w in unread)))


def main(argv):
    if len(argv) < 2 or argv[1] != "judge":
        sys.stderr.write("usage: review-round.py judge ... (see the top of the file)\n")
        return 2
    names = {"--repository": "repository", "--branch": "branch", "--head": "head", "--base": "base",
             "--finished": "finished", "--round": "round", "--findings": "findings",
             "--transcript": "transcript", "--session": "session"}
    a, rest, i = {}, argv[2:], 0
    while i < len(rest):
        if rest[i] in names and i + 1 < len(rest):
            a[names[rest[i]]] = rest[i + 1]
            i += 2
        else:
            sys.stderr.write("review-round.py: cannot read the argument %r\n" % rest[i])
            return 2
    for need in ("repository", "branch", "head", "finished", "round", "findings"):
        if not a.get(need):
            sys.stderr.write("review-round.py judge: needs --%s\n" % need)
            return 2
    a.setdefault("base", "")
    for number in ("finished", "round", "findings"):
        if not a[number].isdigit():
            sys.stderr.write("review-round.py judge: --%s is not a number\n" % number)
            return 2
    answered, why = judge(a)
    meta = {"source": SOURCE, "repository": a["repository"], "branch": a["branch"], "head": a["head"],
            "round": int(a["round"]), "sha256": digest(a)}
    lines = ["answered" if answered else "unanswered", digest(a), facts(a), " ".join(why.split()),
             json.dumps(meta, ensure_ascii=True), NARROW, APPROACH, GO_ON, FINDINGS_LINE.rstrip(), str(FINDINGS_MIN)]
    sys.stdout.write("\n".join(lines) + "\n")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Exception as e:  # never a silent pass: the caller stops on any exit but 0
        sys.stderr.write("review-round.py could not judge: %s: %s\n" % (type(e).__name__, e))
        sys.exit(2)
