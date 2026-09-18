#!/usr/bin/env python3
"""Find a deferral written down with no issue number beside it (claude-config#430).

    deferrals.py [--diff]                       a unified diff on stdin; ADDED lines are judged
    deferrals.py --file <path> [--lines A-B,..] a whole file's text on stdin, judged as <path>
    deferrals.py --edit-payload                 a PostToolUse Edit/Write/MultiEdit payload on stdin
    deferrals.py --phrases <file>               read the phrase list from here instead

Prints one finding per line as

    <file>:<line>: <matched phrase>: <the line>

and exits 0 whether or not it found anything (the caller decides what a finding means). Exits 3
when the phrase list cannot be read, because a detector with no phrases would report a clean scan
of nothing (L98). In --edit-payload mode an unreadable payload prints nothing and exits 0: that
hook runs on every edit in every project and has nothing to say about a tool call it cannot read.

WHAT COUNTS. A line is judged when it is a COMMENT in a code file (`//`, `#`, `/* ... */`, a `*`
continuation inside a block comment, `--` in SQL, `<!-- -->`), or ANY line of a markdown or text
file. Which markers count as a comment depends on the file's extension, so `#` is a comment in a
shell script and not in TypeScript, and `--` is a comment in SQL and not anywhere else. String
literals are blanked from a code line before its comment marker is looked for, so a `//` inside a
URL in a string is not a comment and "later" inside a string literal is never a finding.

A judged line is a FINDING when it carries a phrase from lib/deferral-phrases.txt (case
insensitive, on word boundaries) and no ISSUE REFERENCE, `#NNNN` or a GitHub issue URL, sits on the
line itself or on the two lines either side of it in the NEW text. In a diff, removed lines are not
part of the new text and cannot clear a finding; context lines can, which is why the push hook asks
git for at least two lines of context.

ONE detector, two hooks. check-deferrals.sh feeds it the pushed diff; deferral-edit-check.sh feeds
it the Edit/Write payload, and this file locates the new text inside the file just written so the
two lines either side come from the REAL neighbours rather than from the fragment alone. The test
suite drives this file directly, so the rule is tested where it lives rather than re-implemented in
the test (L52).

WHAT IT NEVER JUDGES, and the rule lives here so both hooks agree (L41): the phrase list itself,
the two hooks and this detector (their own comments have to name the phrases), and the config
repo's test suites (`payload/hooks/test-*.sh`, `hooks/test-*.sh`, `tests/test-*.sh`), whose
fixtures are made of the phrases.

Left out on purpose, and named here so nobody assumes it is covered: a Python docstring is not a
comment to this detector, so a deferral written inside one is not seen.
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_PHRASES = os.path.join(HERE, "deferral-phrases.txt")

# Two lines either side, in the new text, is where an issue number clears a deferral.
WINDOW = 2

# `#NNNN` not preceded by a word character or `&` (so `&#123;`, an HTML entity, is not a reference,
# and neither is `a#1`), or a GitHub issue, pull or discussion URL.
ISSUE_REF = re.compile(
    r"(?<![A-Za-z0-9_&])#[0-9]+(?![0-9A-Za-z_])"
    r"|github\.com/[^/\s]+/[^/\s]+/(?:issues|pull|discussions)/[0-9]+"
)

SELF_BASENAMES = {"deferral-phrases.txt", "deferrals.py", "check-deferrals.sh",
                  "deferral-edit-check.sh", "test-check-deferrals.sh"}
SUITE_DIRS = {"payload/hooks", "hooks", "tests"}


def is_exempt(path):
    """The guard's own files and the config repo's test suites are never judged."""
    if not path:
        return False
    norm = path.replace("\\", "/").rstrip("/")
    base = os.path.basename(norm)
    if base in SELF_BASENAMES:
        return True
    if base.startswith("test-") and base.endswith(".sh"):
        parent = os.path.dirname(norm)
        for d in SUITE_DIRS:
            if parent == d or parent.endswith("/" + d):
                return True
    return False


TEXT_EXT = {".md", ".mdx", ".markdown", ".txt", ".rst", ".adoc"}
TEXT_BASENAMES = {"README", "CHANGELOG", "LICENSE", "NOTES"}

# Which comment markers a file's lines can carry, by extension. Anything not listed gets the
# C-family pair (`//` and `/* */`) plus `#`, which is the union that misses least; the phrase still
# has to be inside the comment for anything to be said.
HASH_EXT = {".sh", ".bash", ".zsh", ".py", ".rb", ".pl", ".yml", ".yaml", ".toml", ".ini", ".cfg",
            ".conf", ".env", ".tf", ".r", ".properties", ".mk"}
HASH_BASENAMES = {"Makefile", "Dockerfile", ".env", ".env.local", ".env.example", ".gitignore",
                  ".gitattributes", ".dockerignore", ".npmrc", ".nvmrc"}
SLASH_EXT = {".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts", ".go", ".rs", ".java",
             ".kt", ".swift", ".c", ".h", ".cc", ".cpp", ".hpp", ".cs", ".scala", ".dart", ".php",
             ".jsonc", ".json5", ".scss", ".less", ".sass"}
BLOCK_ONLY_EXT = {".css"}
DASH_EXT = {".sql", ".lua", ".hs", ".plsql", ".psql"}
HTML_EXT = {".html", ".htm", ".xml", ".svg", ".vue", ".svelte", ".astro"}


def kind_of(path):
    """text | code, plus the set of comment markers that apply."""
    base = os.path.basename(path or "")
    ext = os.path.splitext(base)[1].lower()
    if ext in TEXT_EXT or (not ext and base in TEXT_BASENAMES):
        return "text", set()
    markers = set()
    if ext in HASH_EXT or base in HASH_BASENAMES:
        markers.add("#")
    if ext in SLASH_EXT:
        markers.update({"//", "/*"})
    if ext in BLOCK_ONLY_EXT:
        markers.add("/*")
    if ext in DASH_EXT:
        markers.update({"--", "/*"})
    if ext in HTML_EXT:
        markers.update({"<!--", "/*", "//"})
    if not markers:
        markers = {"//", "/*", "#"}
    return "code", markers


STRING_RE = re.compile(r'"(?:\\.|[^"\\])*"|\'(?:\\.|[^\'\\])*\'|`(?:\\.|[^`\\])*`')


def strip_strings(line):
    """String literals blanked to spaces, same length, so a `//` inside one is not a marker."""
    return STRING_RE.sub(lambda m: " " * len(m.group(0)), line)


def load_phrases(path):
    phrases = []
    with open(path, encoding="utf-8") as fh:
        for raw in fh:
            line = raw.strip()
            if not line or line.startswith("#"):
                continue
            phrase = line.split("#", 1)[0].strip()
            if phrase:
                phrases.append(phrase)
    if not phrases:
        raise ValueError("no phrases")
    # Longest first, so "follow-up" is named as itself and not as a shorter phrase inside it.
    phrases.sort(key=len, reverse=True)
    pat = "|".join(re.escape(p).replace(r"\ ", r"\s+") for p in phrases)
    return phrases, re.compile(r"(?<![A-Za-z0-9_])(?:" + pat + r")(?![A-Za-z0-9_])", re.IGNORECASE)


class CommentReader:
    """Yields the comment text of each line of ONE file, or None when the line has none.

    Carries block comment state (`/* ... */`, `<!-- ... -->`) across lines, so a comment body
    with no leading `*` is still read. In a diff the state is reset at each hunk, and a hunk
    that opens inside a block comment is covered by the `*` continuation rule instead.
    """

    def __init__(self, path):
        self.kind, self.markers = kind_of(path)
        self.in_block = None   # None, "*/" or "-->"

    def reset(self):
        self.in_block = None

    def comment_text(self, line):
        if self.kind == "text":
            return line
        stripped = line.strip()
        if self.in_block:
            end = self.in_block
            idx = line.find(end)
            if idx < 0:
                return line
            self.in_block = None
            head = line[:idx]
            tail = self.comment_text(line[idx + len(end):])
            return head + (" " + tail if tail else "")
        # A `*` continuation line is a comment body whatever the marker set, because a hunk can
        # begin inside a block comment with no opener in sight.
        if "/*" in self.markers and stripped.startswith("*") and not stripped.startswith("*/"):
            return stripped[1:]
        code = strip_strings(line)
        found = []   # (index, marker)
        for m in self.markers:
            i = code.find(m)
            if i >= 0:
                found.append((i, m))
        if not found:
            return None
        i, m = min(found)
        if m == "/*":
            j = code.find("*/", i + 2)
            if j < 0:
                self.in_block = "*/"
                return line[i + 2:]
            inner = line[i + 2:j]
            rest = self.comment_text(line[j + 2:])
            return inner + (" " + rest if rest else "")
        if m == "<!--":
            j = code.find("-->", i + 4)
            if j < 0:
                self.in_block = "-->"
                return line[i + 4:]
            inner = line[i + 4:j]
            rest = self.comment_text(line[j + 3:])
            return inner + (" " + rest if rest else "")
        # `//`, `#`, `--`: the rest of the line.
        return line[i + len(m):]


def judge(path, new_lines, judged_numbers, phrase_re, reset_at=None):
    """Findings over ONE file's new text.

    new_lines:      [(line_number, text)] for every line of the new text we can see, in order
    judged_numbers: the line numbers to judge (added lines in a diff, the edited range in a file)
    reset_at:       line numbers where block comment state resets (hunk starts)
    """
    if is_exempt(path):
        return []
    reader = CommentReader(path)
    numbers = [n for n, _ in new_lines]
    texts = [t for _, t in new_lines]
    has_ref = [bool(ISSUE_REF.search(t)) for t in texts]
    out = []
    for idx, (n, text) in enumerate(new_lines):
        if reset_at and n in reset_at:
            reader.reset()
        comment = reader.comment_text(text)
        if n not in judged_numbers or comment is None:
            continue
        m = phrase_re.search(comment)
        if not m:
            continue
        lo, hi = max(0, idx - WINDOW), min(len(texts), idx + WINDOW + 1)
        # A neighbour clears only when it is really within two LINES, not two visible entries
        # (a hunk boundary can put a far away line next in the list).
        if any(has_ref[k] and abs(numbers[k] - n) <= WINDOW for k in range(lo, hi)):
            continue
        out.append((path, n, m.group(0), text.rstrip("\n")))
    return out


HUNK = re.compile(r"^@@ -\d+(?:,\d+)? \+(\d+)(?:,\d+)? @@")


def scan_diff(text, phrase_re):
    """Findings over the ADDED lines of a unified diff, one file at a time."""
    findings = []
    path = None
    new_lines = []
    judged = set()
    resets = set()
    line_no = 0

    def flush():
        if path is not None and new_lines:
            findings.extend(judge(path, new_lines, judged, phrase_re, resets))

    for raw in text.splitlines():
        if raw.startswith("+++ "):
            flush()
            p = raw[4:].strip()
            if p.startswith("b/"):
                p = p[2:]
            path = None if p == "/dev/null" else p
            new_lines, judged, resets = [], set(), set()
            continue
        if raw.startswith("--- "):
            continue
        m = HUNK.match(raw)
        if m:
            line_no = int(m.group(1))
            resets.add(line_no)
            continue
        if path is None:
            continue
        if raw.startswith("+"):
            new_lines.append((line_no, raw[1:]))
            judged.add(line_no)
            line_no += 1
        elif raw.startswith(" ") or raw == "":
            new_lines.append((line_no, raw[1:] if raw else ""))
            line_no += 1
        elif raw.startswith("\\"):
            continue   # "\ No newline at end of file"
        # A removed line is not in the new text: it neither moves the counter nor clears anything.
    flush()
    return findings


def parse_ranges(spec):
    """"3-7,12" -> {3,4,5,6,7,12}; None -> None (judge every line)."""
    if not spec:
        return None
    out = set()
    for part in spec.split(","):
        part = part.strip()
        if not part:
            continue
        if "-" in part:
            a, b = part.split("-", 1)
            out.update(range(int(a), int(b) + 1))
        else:
            out.add(int(part))
    return out


def split_lines(text):
    lines = text.split("\n")
    if lines and lines[-1] == "":
        lines.pop()
    return lines


def scan_file(path, text, phrase_re, only=None):
    new_lines = [(i + 1, t) for i, t in enumerate(split_lines(text))]
    judged = only if only is not None else {n for n, _ in new_lines}
    return judge(path, new_lines, judged, phrase_re)


def lines_holding(text, needle, replace_all):
    """The 1-based line numbers of the file text that the needle occupies, or None if absent."""
    if not needle:
        return None
    out = set()
    start = 0
    while True:
        i = text.find(needle, start)
        if i < 0:
            break
        first = text.count("\n", 0, i) + 1
        last = first + needle.count("\n")
        out.update(range(first, last + 1))
        if not replace_all:
            break
        start = i + len(needle)
    return out or None


def scan_edit_payload(payload_text, phrase_re):
    """Findings for a PostToolUse Edit / Write / MultiEdit payload.

    Returns (findings, fragment_mode). fragment_mode is True when the new text could not be found
    in the file (so the line numbers count from the start of the text just written and its
    neighbours in the file were not available to clear it).
    """
    try:
        d = json.loads(payload_text)
    except Exception:
        return [], False
    if not isinstance(d, dict):
        return [], False
    ti = d.get("tool_input") or {}
    if not isinstance(ti, dict):
        return [], False
    path = ti.get("file_path") or ""
    if not path or is_exempt(path):
        return [], False
    tool = d.get("tool_name") or ""

    if tool == "Write" or ("content" in ti and "new_string" not in ti and "edits" not in ti):
        content = ti.get("content")
        if not isinstance(content, str):
            return [], False
        return scan_file(path, content, phrase_re), False

    edits = []
    if isinstance(ti.get("edits"), list):
        for e in ti["edits"]:
            if isinstance(e, dict) and isinstance(e.get("new_string"), str):
                edits.append((e["new_string"], bool(e.get("replace_all"))))
    elif isinstance(ti.get("new_string"), str):
        edits.append((ti["new_string"], bool(ti.get("replace_all"))))
    if not edits:
        return [], False

    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            file_text = fh.read()
    except OSError:
        file_text = None

    if file_text is not None:
        judged = set()
        located = True
        for new_string, replace_all in edits:
            if new_string == "":
                continue
            held = lines_holding(file_text, new_string, replace_all)
            if held is None:
                located = False
                break
            judged |= held
        if located:
            if not judged:
                return [], False
            return scan_file(path, file_text, phrase_re, judged), False

    # The file could not be read, or the new text is not where the tool said it put it (the edit
    # failed, or another writer got there first). Judge the fragment on its own and say so.
    findings = []
    for new_string, _ in edits:
        findings.extend(scan_file(path, new_string, phrase_re))
    return findings, True


def main(argv):
    mode = "diff"
    path = None
    lines_spec = None
    phrases_path = DEFAULT_PHRASES
    i = 1
    while i < len(argv):
        a = argv[i]
        if a == "--diff":
            mode = "diff"
        elif a == "--file":
            mode = "file"
            i += 1
            path = argv[i]
        elif a == "--edit-payload":
            mode = "edit"
        elif a == "--lines":
            i += 1
            lines_spec = argv[i]
        elif a == "--phrases":
            i += 1
            phrases_path = argv[i]
        else:
            sys.stderr.write(f"deferrals.py: unknown argument {a!r}\n")
            return 2
        i += 1
    try:
        _, phrase_re = load_phrases(phrases_path)
    except (OSError, ValueError) as e:
        sys.stderr.write(f"deferrals.py: could not read the phrase list at {phrases_path}: {e}\n")
        return 3
    text = sys.stdin.read()
    fragment = False
    if mode == "diff":
        findings = scan_diff(text, phrase_re)
    elif mode == "file":
        findings = scan_file(path, text, phrase_re, parse_ranges(lines_spec))
    else:
        findings, fragment = scan_edit_payload(text, phrase_re)
    for f, n, phrase, line in findings:
        where = f"{f}:{n}" if not fragment else f"{f}:new text line {n}"
        sys.stdout.write(f"{where}: {phrase}: {line.strip()[:200]}\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
