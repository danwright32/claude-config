#!/usr/bin/env python3
"""The detached half of the advisory AI review (claude-config#433).

ai-review-on-push.sh starts this in the background the moment a `git push` has succeeded and
returns at once, so the push waits for nothing. This process then asks `claude` to review the
diff and writes the answer where ai-review-nudge.sh will find it on a later prompt.

    ai-review-run.py --state-dir D --key K --sha S --repo-label L --branch B --repo-dir R
                     --model M --prompt-file P --lessons-dir D --diff-file F --deadline SECONDS
                     --started EPOCH

It runs EXACTLY `env -u CLAUDECODE CLAUDE_CODE_PROMPT_CACHE_TTL=5m CLAUDE_CODE_DISABLE_CLAUDE_MDS=1 claude -p
<message> --append-system-prompt <lessons> --exclude-dynamic-system-prompt-sections --output-format
stream-json --verbose --include-partial-messages --model <model> --settings {"disableAllHooks":true}
--strict-mcp-config --disable-slash-commands --disallowedTools ReportFindings` with the diff on
stdin (each part is explained where the command is built), reading the review from the stream's
result event (THE STREAM, below). Before it starts claude it takes a turn, so reviews started
together send their requests one after another and share the cached lessons (STARTS IN TURN, below,
claude-config#1619); the order and wait are in the metadata as start_order and start_wait, and the
cost and token counts claude reports as cost_usd and the API's own token field names.
The `env -u` is load bearing: a nested claude refuses to start while CLAUDECODE is set, and every
hook inherits that variable from the session that fired it. Removing it here rather than in the
shell keeps the whole command in one place the test can read back from the fake claude's recorded
environment.

The lessons index is the appended system prompt. The message is two context lines (the framework
read from package.json, or that there was none, and which files handle failure), then the text of
ai-review-prompt.txt, verbatim, with the diff after it on stdin. The file is the prompt the test
compares against, so the hook never holds wording of its own (L41). The lessons, identical across
reviews and most of the prompt, come first as the system prompt, so a review started within five
minutes of another reads them back from the prompt cache (claude-config#1599).

THE LESSONS, on purpose, and nothing else of the global config (claude-config#539). The review used
to inherit the whole global CLAUDE.md by accident, because a headless claude loads it unless told
not to. It is now told not to, and every LESSONS-INDEX-*.md in --lessons-dir (the config root
beside the hooks) is read HERE, at run time, into the prompt, so it is always the current index and
never a copy that drifts (L41). A review that found no index files still runs, and its answer says
so on its first line, because running on without them silently would read as a review that applied
the lessons and found nothing to cite.

WHAT IT WRITES, and the one rule about the order. The hook has already written
<key>-<sha>.txt.pending carrying the start time. On any exit at all this process writes
<key>-<sha>.txt (the finished file, atomically, via a temporary name and rename), THEN removes the
pending file, THEN removes the diff. The finished file lands first so there is never a moment with
neither: a nudge that saw nothing would read it as no review having been started (L98). A review
that ran out of time, a claude that exited non-zero, one that printed nothing, and a crash inside
this script all still produce a finished file, each saying which it was in its own words (L11,
L514). The deadline is enforced here with subprocess's own timeout because macOS has no `timeout`
command, and the whole process group is killed on expiry so a stuck child cannot outlive it.

The finished file's first lines are `name=value` metadata (repo, branch, sha, started, finished,
status, model), then a blank line, then the review. The nudge reads only that shape.

PLACED BY QUOTE (claude-config#1357). The reviewer writes a `Quote:` line under each finding, the
line of code it means, and the runner moves the finding to the line of the file at the reviewed
head that matches it, then drops the Quote line, so the stored review is one line per finding in
the `<path>:<line>: ` shape every reader parses. A finding it cannot place keeps its number, marked
as unchecked (place_findings below).

TWO KINDS, one reviewer (claude-config#560). `--kind push` (the default) is the advisory review of
one push. `--kind pr` is the lessons review of a WHOLE branch that lib/pr-review.sh starts when a
pull request is opened, and that the merge gate waits for. A pr review also records `kind`, `base`
and `findings` (the count of finding lines, 0 for "No issues found.") in its metadata, and its
`--scope-file` is sent in front of the shared prompt, so the one prompt file serves both (L41).

THE CITATION LEDGER. Every finished review with findings appends one line to citations.tsv in the
state directory: finish time, kind, repository, sha, findings, and the lesson numbers its findings
cite. The review files themselves are swept after 14 days; the ledger is not, because the monthly
re-rank of the lessons core (#563, #566) needs which lessons reviews actually cite, over months.
"""
import argparse
import fcntl
import glob
import hashlib
import json
import os
import re
import signal
import subprocess
import sys
import threading
import time


def framework_line(repo_dir):
    """One sentence about what kind of code base this is, read from the files that say so."""
    pj = os.path.join(repo_dir, "package.json")
    if os.path.isfile(pj):
        try:
            with open(pj, encoding="utf-8", errors="replace") as f:
                d = json.load(f)
            deps = {}
            for section in ("dependencies", "devDependencies", "peerDependencies"):
                v = d.get(section)
                if isinstance(v, dict):
                    deps.update(v)
        except (OSError, ValueError, AttributeError):
            deps = {}
        known = (
            ("next", "a Next.js/React application"),
            ("react", "a React application"),
            ("vue", "a Vue application"),
            ("svelte", "a Svelte application"),
            ("express", "an Express (Node.js) service"),
            ("fastify", "a Fastify (Node.js) service"),
        )
        for key, name in known:
            if key in deps:
                return f"Context: this repository is {name} (read from its package.json)."
        return "Context: this repository is a JavaScript or TypeScript project (it has a package.json naming no framework this review knows)."
    for marker in ("pyproject.toml", "requirements.txt", "setup.py"):
        if os.path.isfile(os.path.join(repo_dir, marker)):
            return f"Context: this repository is a Python project (it has a {marker})."
    return "Context: this repository has no package.json, so treat it as a general code base and apply framework rules only where the code makes the framework obvious."


FAILURE_LIB = os.path.join(os.path.dirname(os.path.abspath(__file__)), "failure-handling.sh")


def failure_line(diff_path):
    """Which files' added code handles failure, from lib/failure-handling.sh (claude-config#1477).

    The same predicate the lessons advisory and the push gate read (L261, L370), handed over as a
    fact. Bidspoke PR #2630's review called a test file retry or failure handling over a mocked
    field named retries_assumed and an option labelled 'Fail the run'. When the list cannot be read
    the line says so, rather than reading as "no file handles failure" (L11)."""
    try:
        with open(diff_path, "rb") as diff:
            r = subprocess.run(["bash", FAILURE_LIB, "files"], stdin=diff,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=60)
        if r.returncode != 0:
            raise OSError(r.stderr.decode("utf-8", errors="replace").strip() or f"exit {r.returncode}")
        files = [f for f in r.stdout.decode("utf-8", errors="replace").splitlines() if f.strip()]
    except (OSError, subprocess.SubprocessError) as e:
        return ("Context: which files handle failure could not be read from lib/failure-handling.sh "
                f"({type(e).__name__}: {e}), so judge failure handling from the code itself, never from "
                "words in strings, labels, test names or comments.")
    head = "Context: failure handling, read from the code with strings and comments removed: "
    if not files:
        return (head + "none. No file in this diff adds code that catches, raises, branches on an error "
                "or a status, or retries. A word such as fail, error or retry in a string, a label, a "
                "test name, fixture data or a comment does not make a file failure handling.")
    return (head + ", ".join(files) + ". Only these files add code that catches, raises, branches on an "
            "error or a status, or retries. A word such as fail, error or retry in a string, a label, a "
            "test name, fixture data or a comment does not make any other file failure handling.")


def lessons_block(lessons_dir):
    """(text for the prompt, note for the answer). The note is empty when the lessons were read."""
    files = sorted(glob.glob(os.path.join(lessons_dir, "LESSONS-INDEX-*.md")))
    if not files:
        return "", (f"Note: this review ran without the lessons index: no LESSONS-INDEX-*.md in "
                    f"{os.path.abspath(lessons_dir)}, so no recorded lesson could be cited.")
    parts = []
    for path in files:
        with open(path, encoding="utf-8", errors="replace") as f:
            parts.append(f.read().strip())
    return "===== LESSONS\n\n" + "\n\n".join(parts), ""


# A finding that says a WHOLE FILE was not changed (claude-config#533, narrowed in #1354). The path
# must sit in the clause itself, as its subject ("<path> is not changed", "<path> is not part of the
# diff") or as the object of a change the diff or push is said not to hold ("no change to <path>",
# "this push does not touch <path>"). An absence word anywhere in the finding plus a path anywhere
# in it is not enough: every finding starts with its own path, and "`pickerVendors` was not updated"
# or "Lines 203 to 209 have not changed" is about a symbol or part inside a changed file, which Dan
# decided on 2026-10-19 is left unmarked. A possessive after the path ("<path>'s `retryLimit`") is
# a part too, and so is "<path> was not updated to mention the new flag". The path must also be one the complete list names, so a true absence is left alone.
_ABSENT_VERB = r"(?:changed|modified|updated|touched|edited|included)"
_CHANGE_SET = r"(?:diff|push|change|changeset|branch|pr|pull request|commit)"
# "<path> was not updated" ends there, or goes on only to say where ("in this push"). Going on to
# say what or why ("to mention the new flag", "for #3641") makes it a claim about a part.
_CLAUSE_END = (r"(?=\s*(?:[.,;:)\]!?]|$)|\s+(?:in|by|from|on|with)\s+(?:the|this|that)\s+" + _CHANGE_SET +
               r"\b|\s+(?:at\s+all|yet|either)\b)")
ABSENCE_AFTER_PATH = re.compile(
    r"^`?(?: file)?\s+(?:"
    r"(?:is|was|are|were|has|have)\s+(?:not|never)\s+(?:been\s+)?" + _ABSENT_VERB + _CLAUSE_END + r"|"
    r"(?:is|was|stays|remains)\s+unchanged" + _CLAUSE_END + r"|"
    r"(?:is|was)\s+(?:absent|missing)\s+from\s+(?:the|this)\s+" + _CHANGE_SET + r"|"
    r"(?:is|was)\s+not\s+(?:in|part\s+of)\s+(?:the|this)\s+" + _CHANGE_SET + r"(?![\w-]|\s+(?:segment|command|step|string|text)\b))",
    re.IGNORECASE)
ABSENCE_BEFORE_PATH = re.compile(
    r"(?:no\s+(?:changes?|edits?|modifications?)\s+(?:at\s+all\s+)?to|"
    r"\b" + _CHANGE_SET + r"s?\s+(?:does\s+not|doesn't|did\s+not|didn't|never)\s+"
    r"(?:change|modify|touch|include|update|edit)s?)"
    r"\s+(?:the\s+(?:file\s+)?)?`?$",
    re.IGNORECASE)
POSSESSIVE = re.compile(r"^`?['’]s\b")
# A finding's own location, `<path>:<line>: `, or `<path>:~<line>: ` when the reviewer marks its
# number as approximate (seen 2026-10-19, refused as unparsed though the finding was real). The one
# pattern every reading of a finding here uses; place_findings writes the number back plain, so what
# is stored, and every reader after this runner, sees only `<path>:<line>: ` (claude-config#1357).
FINDING = re.compile(r"^(\S+):(~?)([0-9]+): ")
LOCATION = FINDING


def claims_file_absent(body, path):
    """True when `path` appears in `body` as the file a whole file absence clause is about."""
    start = body.find(path)
    while start != -1:
        before, after = body[:start], body[start + len(path):]
        bounded = (not before or not (before[-1].isalnum() or before[-1] in "/._-")) and \
                  (not after or not (after[0].isalnum() or after[0] in "/_-" or
                                     (after[0] == "." and after[1:2].isalnum())))
        if bounded and not POSSESSIVE.match(after) and \
                (ABSENCE_AFTER_PATH.match(after) or ABSENCE_BEFORE_PATH.search(before)):
            return True
        start = body.find(path, start + 1)
    return False


def changed_files(diff_path):
    """The paths the push changed, from the list the hook put at the top of the input, or None
    when there is no list or it was truncated, since a partial list cannot prove a file changed
    and must not be read as the whole truth."""
    paths, in_block = [], False
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            for line in f:
                if line.startswith("===== FILES THIS PUSH CHANGED"):
                    in_block = True
                    continue
                if not in_block:
                    return None
                if line.startswith("===== END OF FILE LIST"):
                    return paths
                if line.startswith("TRUNCATED:"):
                    return None
                parts = line.rstrip("\n").split("\t")
                if len(parts) >= 2 and parts[1]:
                    paths.append(parts[1])
    except OSError:
        return None
    return None


def mark_false_absences(text, paths):
    """(text, count): each finding claiming a listed file was not changed gets a visible mark.
    Marked rather than deleted, because deleting would destroy the evidence the reviewer ignored
    the list, which is the thing to know about it (L340). Only the finding's text after its own
    `<path>:<line>: ` location is read, since that location names where the reviewer was reading,
    never a file it claims the push left out."""
    if not paths:
        return text, 0
    out, marked = [], 0
    for line in text.splitlines():
        hit = None
        body = LOCATION.sub("", line, count=1)
        for p in sorted(paths, key=len, reverse=True):
            if claims_file_absent(body, p):
                hit = p
                break
        if hit:
            line += (f" [review harness: {hit} IS in this push, per the complete list of changed files, "
                     "so this finding's premise is false]")
            marked += 1
        out.append(line)
    return "\n".join(out), marked


LESSON = re.compile(r"\(L([0-9]{1,4})\)")


def count_findings(text):
    """The number of lines in the review's own finding shape, `<path>:<line>: ...`."""
    return sum(1 for line in text.splitlines() if FINDING.match(line))


# PLACEMENT BY QUOTED LINE (claude-config#1357). In a hand judged sample of 60 lessons review
# findings on 2026-10-19, 44 cited the wrong line, usually a blank line, a lone brace or a neighbour
# within about 20 lines of the real one, and everything keyed on file and line (the earlier review
# history and the answered findings match in pr-review.sh) was misled by it. So the prompt asks for
# the line itself on a `Quote: <the line>` line under each finding, and this places the finding at
# the line of the file AT THE REVIEWED HEAD that matches it: compared with surrounding white space
# trimmed and runs of it collapsed, and one leading diff marker dropped only when the quote as given
# matches nothing (claude-config#1368), nothing more, and the occurrence nearest the cited number when
# the line is there more than once. The Quote line is then dropped, so a stored review stays one
# line per finding for every reader. A finding that cannot be placed keeps the number it cited and
# says why on its own line, so a guess never reads as a checked line (L11); it is never dropped.
QUOTE_LINE = re.compile(r"^\s*quote:\s?(.*)$", re.IGNORECASE)


def _normal(s):
    return " ".join(s.split())


def _quoted(raw):
    q = raw.strip()
    if len(q) >= 2 and q[0] == "`" and q[-1] == "`":
        q = q[1:-1]
    return _normal(q)


def _head_lines(repo_dir, sha, path, cache):
    """The file's lines at the head, None when it is not a file there, or raises OSError when the
    head itself cannot be read."""
    if "" not in cache:
        r = subprocess.run(["git", "-C", repo_dir, "cat-file", "-e", f"{sha}^{{commit}}"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=30, check=False)
        cache[""] = r.returncode == 0
    if not cache[""]:
        raise OSError("head unreadable")
    if path not in cache:
        r = subprocess.run(["git", "-C", repo_dir, "cat-file", "blob", f"{sha}:{path}"],
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False)
        if r.returncode != 0:
            cache[path] = None
        else:
            # Split on newlines only, as git and the reviewer count them; str.splitlines would also
            # split on form feeds and Unicode separators and shift every line after one.
            body = r.stdout.decode("utf-8", errors="replace")
            if body.endswith("\n"):
                body = body[:-1]
            cache[path] = [line.rstrip("\r") for line in body.split("\n")]
    return cache[path]


def _place(path, cited, quote, repo_dir, sha, cache):
    """(line, None) for a placed finding, or (None, why) for one that cannot be placed."""
    if quote is None:
        return None, "it quoted no line"
    if not quote:
        return None, "its Quote line was empty"
    try:
        lines = _head_lines(repo_dir, sha, path, cache)
    except (OSError, subprocess.SubprocessError):
        return None, "the reviewed head could not be read to check it"
    if lines is None:
        return None, f"{path} is not a file at the reviewed head"
    hits = _hits(lines, quote)
    tried = ""
    # A quote copied from the diff can keep the diff's leading + or - (claude-config#1368). The
    # quote as given is tried first and wins whenever it matches, because a real line can begin with
    # either (a Markdown or YAML list item, a unary minus, a diff kept in the repository); only a
    # quote matching nothing loses that one marker and is tried again. A quote that is nothing but
    # the marker is not retried, since the empty rest would match every blank line. A leading space
    # needs no such step: the quote is trimmed before it is compared.
    if not hits and quote[0] in "+-" and quote[1:].strip():
        hits = _hits(lines, _normal(quote[1:]))
        tried = f", as given or without its leading {quote[0]}"
    if not hits:
        shown = quote if len(quote) <= 60 else quote[:60] + "..."
        return None, f'its quote matches no line of {path} at the reviewed head{tried}: "{shown}"'
    return min(hits, key=lambda n: (abs(n - cited), n)), None


def _hits(lines, quote):
    return [n for n, line in enumerate(lines, 1) if _normal(line) == quote]


def place_findings(text, repo_dir, sha):
    """(text, counts): each finding moved to the line its Quote names, its Quote line dropped, and
    every approximate `~N` written as a plain number. counts holds how many were placed and not."""
    lines = text.splitlines()
    out, counts, cache = [], {"placed": 0, "unplaced": 0}, {}
    i = 0
    while i < len(lines):
        line = lines[i]
        m = FINDING.match(line)
        if not m:
            out.append(line)
            i += 1
            continue
        # The finding's quote is the next line that is not blank, when it is a Quote line.
        k = i + 1
        while k < len(lines) and not lines[k].strip():
            k += 1
        quote = None
        if k < len(lines):
            q = QUOTE_LINE.match(lines[k])
            if q:
                quote = _quoted(q.group(1))
                i = k
        path, cited, rest = m.group(1), int(m.group(3)), line[m.end():]
        placed, why = _place(path, cited, quote, repo_dir, sha, cache)
        if why is None:
            counts["placed"] += 1
            out.append(f"{path}:{placed}: {rest}")
        else:
            counts["unplaced"] += 1
            out.append(f"{path}:{cited}: {rest} [review harness: not placed, {why}, so line {cited} "
                       "is the reviewer's own number, unchecked]")
        i += 1
    return "\n".join(out), counts


def append_ledger(state_dir, meta, text):
    """One line per review with findings, never swept (see the module docstring)."""
    lessons = sorted({int(m) for m in LESSON.findall(text)})
    line = "\t".join(str(x) for x in (
        meta.get("finished", ""), meta.get("kind", "push"), meta.get("repo", ""), meta.get("sha", ""),
        meta.get("findings", ""), ",".join(f"L{n}" for n in lessons)))
    with open(os.path.join(state_dir, "citations.tsv"), "a", encoding="utf-8") as f:
        f.write(line + "\n")


def write_finished(state_dir, name, meta, body):
    final = os.path.join(state_dir, name + ".txt")
    tmp = final + ".tmp"
    lines = [f"{k}={v}" for k, v in meta.items()]
    text = "\n".join(lines) + "\n\n" + (body.rstrip("\n") + "\n" if body else "")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp, final)
    for leftover in (final + ".pending",):
        try:
            os.remove(leftover)
        except OSError:
            pass


def redact(text, stderr=False):
    """Reviewer text made safe to store and print (claude-config#581), through the ONE redactor,
    ar_redact in ai-review-common.sh. Its stderr once carried a live secret key quoted inside a
    permission rule warning, which the merge gate then echoed into the session. A redactor that
    cannot run withholds the text rather than passing it through raw (L42)."""
    common = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai-review-common.sh")
    args = ["bash", "-c", '. "$1" && ar_redact $2', "_", common, "--stderr" if stderr else ""]
    try:
        r = subprocess.run(args, input=text.encode("utf-8", errors="replace"),
                           stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=30, check=False)
    except (OSError, subprocess.TimeoutExpired):
        return "(withheld: the redactor could not run, so this text was not stored)"
    if r.returncode != 0:
        return "(withheld: the redactor failed, so this text was not stored)"
    return r.stdout.decode("utf-8", errors="replace").strip()


# STARTS IN TURN (claude-config#1619). The lessons are cached for five minutes from the moment a
# reviewer's first request is answered, so a review that sends its request after that reads them
# back, and reviews sent at the same moment each write them: measured 2026-10-23, the first three
# reviews launched together each read back only the 19k tool and system prefix, not the 57k with the
# lessons. Reviews are launched together whenever a branch is read in groups (pr-review.sh, #601)
# and in the review score's parallel runs, and can be by two sessions at once. So before claude
# starts, every review with the same model and lessons (one cache, so one key) takes a TURN:
#
#   warm       the lessons were warm within WARM_FRESH_SECONDS: start at once.
#   first      nobody ahead: start at once, holding the turn until the reviewer BEGINS answering
#              (the first event of claude's stream, by when the cache has been written), which
#              marks the lessons warm and lets the turn go.
#   followed   waited for the review ahead, which began answering: start now, reading them back.
#   took-over  the review ahead ended without answering (it failed, or died): the turn passed to
#              this one at once, so a failed first review never holds the rest for their bound.
#   gave-up    the review ahead held the turn past this review's bound and never began answering:
#              start anyway. Recorded so a wait that bought nothing is never silent (L11).
#   unavailable the turn could not be kept (no folder, no lock): start at once rather than block.
#
# The turn is an flock, which the kernel lets go when its holder dies (L409), so nothing is left
# standing to wait on; the warm mark is a file whose time says when. Each review's order and wait
# are in its metadata (start_order, start_wait), and the wait is taken out of its own deadline, so
# a review never runs past the deadline its caller set.
WARM_FRESH_SECONDS = 240    # under the cache's five minutes, leaving room for claude's own start
START_WAIT_SECONDS = 60     # a reviewer begins answering within seconds; this is only the ceiling
START_POLL_SECONDS = 0.25


def warm_dir(env=None):
    """Where turns are kept: AI_REVIEW_WARM_DIR, else a folder of the review state, so every review
    on this Mac shares it and a suite's own state keeps its turns apart from the live ones."""
    env = os.environ if env is None else env
    if env.get("AI_REVIEW_WARM_DIR"):
        return env["AI_REVIEW_WARM_DIR"]
    state = env.get("AI_REVIEW_STATE_DIR") or os.path.join(os.path.expanduser("~"), ".claude", "state", "ai-review")
    return os.path.join(state, "warm")


def start_key(model, fixed):
    """One turn per cache: the model and the appended system prompt (the lessons)."""
    return hashlib.sha256((model + "\0" + fixed).encode("utf-8")).hexdigest()[:16]


def start_wait_bound(deadline, env=None):
    """How long a review waits for the one ahead: AI_REVIEW_START_WAIT_SECONDS, else
    START_WAIT_SECONDS, never more than a quarter of its own deadline."""
    env = os.environ if env is None else env
    try:
        bound = int(env.get("AI_REVIEW_START_WAIT_SECONDS", "") or START_WAIT_SECONDS)
    except ValueError:
        bound = START_WAIT_SECONDS
    return max(0, min(bound, deadline // 4))


class StartTurn:
    """A review's turn. answering() is called from the stream reader when the reviewer begins
    answering, release() when the review ends, in either order and any number of times."""

    def __init__(self, order, waited, warm_path, fd):
        self.order, self.waited = order, waited
        self._warm, self._fd = warm_path, fd
        self._mu = threading.Lock()
        self._answered = False

    def answering(self):
        with self._mu:
            if self._answered:
                return
            self._answered = True
            if self._warm:
                try:
                    with open(self._warm, "a", encoding="utf-8"):
                        pass
                    os.utime(self._warm, None)
                except OSError:
                    pass  # the next review then writes the cache itself, as before #1619
            self._let_go()

    def release(self):
        with self._mu:
            self._let_go()

    def _let_go(self):
        if self._fd is not None:
            try:
                os.close(self._fd)  # closing the only descriptor lets the flock go
            except OSError:
                pass
            self._fd = None


def _fresh(path, now, fresh):
    try:
        return now() - os.stat(path).st_mtime < fresh
    except OSError:
        return False


def take_turn(folder, key, bound, clock=time.monotonic, sleep=time.sleep, now=time.time,
              poll=START_POLL_SECONDS, fresh=WARM_FRESH_SECONDS):
    """The review's StartTurn (see STARTS IN TURN). clock, sleep and now are injected by the tests,
    so no test of a wait waits for real (L524)."""
    warm = os.path.join(folder, key + ".warm")
    try:
        os.makedirs(folder, exist_ok=True)
        fd = os.open(os.path.join(folder, key + ".lock"), os.O_RDWR | os.O_CREAT, 0o600)
    except OSError:
        return StartTurn("unavailable", 0, None, None)
    t0, waited_any = clock(), False
    try:
        while True:
            if _fresh(warm, now, fresh):
                os.close(fd)
                return StartTurn("followed" if waited_any else "warm", clock() - t0, warm, None)
            try:
                fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                if _fresh(warm, now, fresh):  # the one ahead began answering between look and lock
                    os.close(fd)
                    return StartTurn("followed" if waited_any else "warm", clock() - t0, warm, None)
                return StartTurn("took-over" if waited_any else "first", clock() - t0, warm, fd)
            waited = clock() - t0
            if waited >= bound:
                os.close(fd)
                return StartTurn("gave-up", waited, warm, None)
            sleep(min(poll, bound - waited))
            waited_any = True
    except OSError:
        try:
            os.close(fd)
        except OSError:
            pass
        return StartTurn("unavailable", clock() - t0, None, None)


# THE STREAM (claude-config#1619). claude is asked for --output-format stream-json with
# --include-partial-messages, so the first event of the reviewer's answer arrives when the answer
# BEGINS, which is what lets the reviews behind it start. Without the partial events the first
# event after init is the whole first message, which for a review is often the whole review.
# Checked in Claude Code 2.1.309's own text: a `stream_event` carries the API's event (the first of
# a turn is message_start), and the run ends with a `result` event whose `result` is the text the
# plain output prints. The text kept and parsed is that result, nothing else of the stream.
STARTED_BY = ("stream_event", "assistant", "result")
OTHER_KEPT_CHARS = 20000


def model_answered(ev):
    """False for the events Claude Code writes when no request reached the model: an assistant
    message from model `<synthetic>` (an API error it reports as a message, the same marker
    tools/cache-usage.py skips) and a result marked is_error. Neither means the cache was written,
    so neither may let the reviews behind it start as if it had (lessons review of #1619)."""
    if ev.get("type") == "assistant":
        msg = ev.get("message") if isinstance(ev.get("message"), dict) else {}
        return msg.get("model") != "<synthetic>"
    if ev.get("type") == "result":
        return not ev.get("is_error")
    return True


def new_stream():
    return {"result": None, "events": 0, "other": []}


def read_event(raw, got, on_start):
    """Read one line of claude's output into `got`. Calls on_start at every event that means the
    reviewer is answering (StartTurn.answering keeps only the first)."""
    line = raw.decode("utf-8", errors="replace").strip()
    if not line:
        return
    try:
        ev = json.loads(line)
    except ValueError:
        ev = None
    if not isinstance(ev, dict):
        if sum(len(x) for x in got["other"]) < OTHER_KEPT_CHARS:
            got["other"].append(line)
        return
    got["events"] += 1
    kind = ev.get("type")
    if kind in STARTED_BY and model_answered(ev):
        on_start()
    if kind == "result":
        got["result"] = ev


def run_stream(cmd, stdin, timeout, on_start):
    """(returncode, stream, stderr bytes, timed out). Read while it runs, so the start is seen when
    it happens; its own process group, so the deadline can kill everything claude started and not
    only the one pid subprocess knows about."""
    proc = subprocess.Popen(cmd, stdin=stdin, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            start_new_session=True)
    got, err = new_stream(), []

    def read_out():
        for raw in iter(proc.stdout.readline, b""):
            read_event(raw, got, on_start)

    def read_err():
        err.append(proc.stderr.read())

    readers = [threading.Thread(target=read_out, daemon=True), threading.Thread(target=read_err, daemon=True)]
    for t in readers:
        t.start()
    timed_out = False
    try:
        proc.wait(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        try:
            os.killpg(proc.pid, signal.SIGKILL)
        except OSError:
            pass
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
    for t in readers:
        t.join(5)
    return proc.returncode, got, b"".join(e for e in err if e), timed_out


USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def usage_meta(res):
    """What the review cost, as claude's result reports it, under the API's own names, for the
    review score and for measuring what the turns save. A figure that is not a number is left out."""
    out = {}
    cost = res.get("total_cost_usd")
    if isinstance(cost, (int, float)) and not isinstance(cost, bool):
        out["cost_usd"] = cost
    usage = res.get("usage") if isinstance(res.get("usage"), dict) else {}
    for k in USAGE_FIELDS:
        v = usage.get(k)
        if isinstance(v, int) and not isinstance(v, bool):
            out[k] = v
    return out


def main(argv):
    ap = argparse.ArgumentParser()
    for opt in ("--state-dir", "--key", "--sha", "--repo-label", "--branch", "--repo-dir",
                "--model", "--prompt-file", "--lessons-dir", "--diff-file"):
        ap.add_argument(opt, required=True)
    ap.add_argument("--deadline", type=int, required=True)
    ap.add_argument("--kind", default="push", choices=("push", "pr"))
    ap.add_argument("--base", default="")
    # A later round of a pull request review that reads only what changed since this head (#1358).
    ap.add_argument("--since", default="")
    ap.add_argument("--scope-file", default="")
    ap.add_argument("--name", default="")
    ap.add_argument("--started", type=int, required=True)
    a = ap.parse_args(argv)

    name = a.name or f"{a.key}-{a.sha}"
    meta = {
        "repo": a.repo_label,
        "branch": a.branch,
        "sha": a.sha,
        "started": a.started,
        "finished": "",
        "status": "",
        "model": a.model,
        "deadline": a.deadline,
    }
    if a.kind == "pr":
        meta["kind"] = "pr"
        meta["base"] = a.base
        if a.since:
            meta["since"] = a.since
        meta["findings"] = ""

    status, body = "error", ""
    lessons_note = ""
    try:
        with open(a.prompt_file, encoding="utf-8") as f:
            prompt_text = f.read()
        lessons, lessons_note = lessons_block(a.lessons_dir)
        scope = ""
        if a.scope_file:
            with open(a.scope_file, encoding="utf-8") as f:
                scope = f.read().strip() + "\n\n"
        # THE ORDER, for the prompt cache (claude-config#1599). The lessons, identical in every
        # review and most of its prompt, are the appended system prompt; the message is the two per
        # diff context lines, then the scope and the instructions, with the diff after them on stdin.
        # Reordering inside the message is not enough: the message is ONE content block and a cache
        # is read back only up to a block boundary, so with the lessons first in it a second review
        # read back only the 18,902 token tool and system prefix (measured 2026-10-23, Claude Code
        # 2.1.309). In the system prompt, with the per machine sections moved into the message
        # (--exclude-dynamic-system-prompt-sections, below), a second review of another diff read
        # back 56,997. The scope and instructions stay beside the diff on purpose: moved into the
        # system prompt too, the share of findings citing a lesson fell from 21 of 69 to 11 of 64
        # over the same cases, and with only the lessons moved it was 18 of 65. Any per diff text
        # added to `fixed` makes every review write it all again.
        fixed = lessons
        prompt = (framework_line(a.repo_dir) + "\n" + failure_line(a.diff_file) + "\n\n"
                  + scope + prompt_text)

        # Hooks OFF (claude-config#560). Measured 2026-09-24, the first real whole branch reviews: the
        # headless claude ran Dan's global hooks, the reviewer's own tool use tripped the end of turn
        # issue review, and what came back was that review of the SESSION, not a review of the diff.
        # --bare would skip hooks too but refuses subscription sign in, so the setting is passed.
        # The findings tool OFF (claude-config#804). Claude Code offers every headless run a built
        # in ReportFindings tool whose own description says to report a code review through it and
        # not also print the findings as text, so the reviewer often did exactly that: measured
        # 2026-10-08, 6 of about 10 rounds on one pull request answered "I reported N findings
        # through ReportFindings" with no finding line, the gate correctly refused that as unparsed,
        # and the findings existed only in a tool call nobody reads. Disallowed, the tool is gone
        # from the run's tool list (checked against the run's own init event), so the text this
        # runner parses is the review's only channel. Last on the line because the flag takes a list.
        # MCP servers OFF (claude-config#956). Without it the reviewer started every server Dan has
        # connected (claude.ai connectors, plugin servers, his own), none of which a review of a diff
        # calls: 12 in the run's init event on 2026-10-08, and 0 with --strict-mcp-config and no
        # --mcp-config, which is what the flag means ("only use MCP servers from --mcp-config").
        # The servers cost startup on every review (median 2.39 s to the init event with them, 1.68 s
        # without, five runs each) and one stored answer ended with the reviewer's aside that they
        # needed authorizing, text that is neither a finding nor "No issues found.". So never name
        # an --mcp-config here: one would bring its servers straight back.
        # Skills OFF (hook trim, 2026-10-15). The reviewer invokes no skill, and without the flag the
        # whole skills list, every skill's name and description, rides on each request of the run.
        # Prompt caching on the FIVE MINUTE lifetime (claude-config#1599). On a Claude subscription a
        # headless run otherwise writes to the ONE HOUR cache at twice the input price; five minutes
        # costs 1.25 times it, and a read 0.1. #1573 switched caching off (DISABLE_PROMPT_CACHING=1)
        # while the per diff lines opened the prompt, because then 775 reviews (2026-10-16 to 23)
        # never read back more than the 20k tool and system prefix. With the identical text now in
        # the system prompt (THE ORDER, above), a review started within five minutes of another's
        # first request reads them back; reviews started together, the groups of a branch too large
        # for one review, each wrote them, measured, until they took turns (STARTS IN TURN, #1619).
        # The variable is
        # read by Claude Code 2.1.309 itself (checked in the binary and by probe runs that wrote
        # to ephemeral_5m only). --exclude-dynamic-system-prompt-sections moves the working folder,
        # git status and the rest of the per machine sections out of the system prompt, which
        # would otherwise differ for every repository and worktree ahead of the lessons.
        # The stream (THE STREAM, above): --verbose is required with stream-json under -p, and
        # --include-partial-messages makes the first event arrive when the answer begins.
        cmd = ["env", "-u", "CLAUDECODE", "CLAUDE_CODE_PROMPT_CACHE_TTL=5m",
               "CLAUDE_CODE_DISABLE_CLAUDE_MDS=1", "claude", "-p", prompt,
               *(["--append-system-prompt", fixed] if fixed else []),
               "--exclude-dynamic-system-prompt-sections",
               "--output-format", "stream-json", "--verbose", "--include-partial-messages",
               "--model", a.model, "--settings", '{"disableAllHooks":true}', "--strict-mcp-config",
               "--disable-slash-commands",
               "--disallowedTools", "ReportFindings"]
        # The turn (STARTS IN TURN, above), taken last, right before claude starts, so nothing
        # between the wait and the request delays the reviews behind this one.
        turn = take_turn(warm_dir(), start_key(a.model, fixed), start_wait_bound(a.deadline))
        meta["start_order"] = turn.order
        meta["start_wait"] = int(round(turn.waited))
        try:
            with open(a.diff_file, "rb") as diff:
                rc, got, err, timed_out = run_stream(cmd, diff, max(1, a.deadline - int(turn.waited)),
                                                     turn.answering)
        finally:
            turn.release()
        if timed_out:
            status = "timeout"
            body = (f"The review did not finish inside {a.deadline} seconds and was stopped. "
                    "Nothing was read back. Re-run it by pushing again, or raise "
                    "AI_REVIEW_DEADLINE_SECONDS if this repository's pushes are routinely large.")
        else:
            res = got["result"]
            if res is not None:
                meta.update(usage_meta(res))
            raw = res.get("result") if res is not None else None
            text = raw.strip() if isinstance(raw, str) else ""
            errtext = err.decode("utf-8", errors="replace").strip()
            printed = "\n".join(got["other"]).strip()
            if rc != 0:
                status = "error"
                # Never the raw stderr: settings warnings dropped and credentials redacted first.
                safe = redact(errtext, stderr=True) if errtext else ""
                tail = ("\n".join(safe.splitlines()[-5:]) if safe else
                        "(claude printed nothing on stderr)" if not errtext else
                        "(nothing left to show once settings warnings were dropped)")
                body = f"claude exited {rc} and no review was read back. Its last lines:\n{tail}"
            elif res is None and printed:
                # Not the stream it was asked for: kept as the evidence, never read as a review.
                status = "unparsed"
                body = ("claude exited 0 and sent no result event, though it was asked for "
                        "--output-format stream-json, so no review was read back. What it printed:\n"
                        + redact(printed))
            elif res is None:
                status = "empty"
                body = ("claude exited 0 and its output ended without a result, so there is no review to show."
                        if got["events"] else
                        "claude exited 0 and printed nothing, so there is no review to show.")
            elif res.get("is_error"):
                status = "error"
                kind = res.get("subtype") or "no kind given"
                said = redact(text) if text else ""
                body = (f"claude reported an error result ({kind}) and no review was read back."
                        + (f" What it said:\n{said}" if said else ""))
            elif not text:
                status = "empty"
                body = "claude exited 0 and its answer was empty, so there is no review to show."
            elif text != "No issues found." and count_findings(text) == 0:
                # Neither shape the prompt allows. Counting it as zero findings would read an answer
                # that is not a review (the hook hijack above, a refusal, a question back) as a clean
                # one (L98, L340), so it is its own outcome, kept verbatim as the evidence.
                status = "unparsed"
                body = ("The reviewer answered, but not in the review's format: no finding lines and not "
                        "\"No issues found.\", so this is not a review. What it said:\n" + redact(text))
            else:
                status = "ok"
                # Placed first, so every later reading of a finding sees the line it is about.
                text, _ = place_findings(text, a.repo_dir, a.sha)
                text, marked = mark_false_absences(text, changed_files(a.diff_file))
                if marked:
                    text = (f"Note: {marked} finding below claims a file this push changed was not changed; "
                            "the complete list of changed files says otherwise, and each is marked.\n\n"
                            if marked == 1 else
                            f"Note: {marked} findings below claim a file this push changed was not changed; "
                            "the complete list of changed files says otherwise, and each is marked.\n\n") + text
                body = text
                if a.kind == "pr":
                    meta["findings"] = count_findings(text)
    except Exception as e:  # noqa: BLE001  a crash here must still leave a finished file (L514)
        status = "error"
        body = f"The review runner failed before it could read an answer: {type(e).__name__}: {e}"

    if lessons_note:
        body = lessons_note + "\n\n" + body
    meta["finished"] = int(time.time())
    meta["status"] = status
    if status == "ok":
        try:
            append_ledger(a.state_dir, meta, body)
        except OSError:
            pass  # the ledger is a record for later; losing one line must not lose the review
    try:
        write_finished(a.state_dir, name, meta, body)
        if a.kind == "pr":
            # The durable outcome ledger, written by the one bash function every finishing path
            # shares (lib/ai-review-common.sh ar_pr_ledger, claude-config#562).
            common = os.path.join(os.path.dirname(os.path.abspath(__file__)), "ai-review-common.sh")
            subprocess.run(["bash", "-c", '. "$1" && ar_pr_ledger "$2" "$3"', "_", common,
                            os.path.join(a.state_dir, name + ".txt"), a.repo_dir],
                           env=dict(os.environ, AI_REVIEW_STATE_DIR=a.state_dir),
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=30, check=False)
    finally:
        try:
            os.remove(a.diff_file)
        except OSError:
            pass
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
