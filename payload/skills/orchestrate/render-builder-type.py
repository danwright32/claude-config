"""Render the builder agent type from the rules it carries (claude-config#3389).

  python3 -I render-builder-type.py                  print the agent definition
  python3 -I render-builder-type.py --out FILE       write it, only when it differs from FILE
  python3 -I render-builder-type.py --check FILE     exit 1, naming a line, when FILE is stale
  python3 -I render-builder-type.py --decisions      print, as a table, what each section came to
  --strict                                           a table that has fallen behind the rules is
                                                     an error, where otherwise it is only said
  --rules DIR    the folder holding CLAUDE.md and the files it imports (default: the config root
                 this script sits in, two folders up: payload/ in a checkout, ~/.claude installed)
  --head FILE    the frontmatter and opening words (default: builder-type-head.md beside this)
  --table FILE   the choices (default: builder-type-rules.tsv beside this)

WHY IT IS RENDERED. A builder of this type starts without the rule files (omitClaudeMd), so its
prompt has to hold the lessons core and the builder's share of the global rules. That is a copy of
text whose home is CLAUDE.md and the lessons files, and a copy kept by hand is believed long after
it has drifted (L244). So the only things written by hand are the head and the table of choices;
every rule in the output is read from its home on each run.

THE OUTPUT HOLDS NO DATE, COUNT OR HASH. Two renders of the same sources are byte identical, and a
change to one rule changes only that rule's lines, so nothing in a rendered copy can collide with
another edit over content nobody wrote (L554).

WHAT IS CARRIED. CLAUDE.md is walked top to bottom. Each import line at its top (a line that is
only @NAME) is replaced by the file it names, which is how the lessons core arrives. Then every
`## ` section is carried or left out by the table:

  carry<TAB>section<TAB>reason                 the whole section
  leave<TAB>section<TAB>reason                 none of it
  drop<TAB>section<TAB>opening words<TAB>reason  one item of a carried section is left out
  keep<TAB>section<TAB>opening words<TAB>reason  one item of a left out section is carried

An item is a bullet with the lines indented under it, or a paragraph. It is named by the words it
opens with, after any list marker and bold marker.

EVERY DOUBT IS SETTLED BY CARRYING. A section the table does not name is carried. A drop row that
matches no item drops nothing. A keep row that matches no item carries its whole section. Each is
said on stderr, and is an error under --strict, which is what the suite holds the payload to: so a
new rule reaches builders the day it is written, and a pull request is where somebody decides
otherwise.

Exit 0 rendered, 1 the checked copy is stale or missing, 2 nothing could be rendered. On 2 nothing
is printed and FILE is left as it was: a prompt missing its lessons must never replace a whole one.
"""
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOP = "(top of the file)"
NAME = "render-builder-type"
MARK = (
    "# Global rules and lessons for a builder (generated, do not edit)\n"
    "\n"
    "Everything from here down is written by skills/orchestrate/render-builder-type.py from the\n"
    "global CLAUDE.md and the files it imports. Sections and items a builder does not need are left\n"
    "out, and skills/orchestrate/builder-type-rules.tsv records each choice with its reason. To change\n"
    "a rule, change it in CLAUDE.md or the lessons file, never here.\n"
)


class CannotRender(Exception):
    pass


def read(path, what):
    try:
        with open(path, encoding="utf-8") as fh:
            return fh.read()
    except OSError as e:
        raise CannotRender("%s %s could not be read (%s)" % (what, path, e.strerror or type(e).__name__))


def opening(item):
    """The words an item opens with, without its list marker or bold marker."""
    first = item[0]
    if first.startswith("- "):
        first = first[2:]
    if first.startswith("**"):
        first = first[2:]
    return first


def split_items(lines):
    """A section's lines as items: a bullet with what is indented under it, or a paragraph."""
    items, cur, after_blank = [], [], True
    for ln in lines:
        if not ln.strip():
            if cur:
                items.append(cur)
                cur = []
            after_blank = True
            continue
        starts = ln.startswith("- ") or (after_blank and not ln[0].isspace())
        if starts and cur:
            items.append(cur)
            cur = []
        cur.append(ln)
        after_blank = False
    if cur:
        items.append(cur)
    return items


IMPORT = re.compile(r"@(\S+)")
COMMENT = re.compile(r"<!--.*-->")


def parse_rules(text, path):
    """CLAUDE.md as (top entries, [(heading, lines)]).

    A top entry is ("import", name) for a line that is only @NAME, or ("text", line). The sync
    wraps the lessons imports in two marker comments (ensure_lesson_index_imports); a line that is
    only a comment is the file's bookkeeping and is passed over, so the imports between the
    markers are found like any other.
    """
    top, sections, cur = [], [], None
    for ln in text.split("\n"):
        bare = ln.strip()
        if ln.startswith("## "):
            cur = (ln[3:].strip(), [])
            sections.append(cur)
        elif cur is None:
            m = IMPORT.fullmatch(bare)
            if m:
                top.append(("import", m.group(1)))
            elif not COMMENT.fullmatch(bare):
                top.append(("text", ln))
        elif IMPORT.fullmatch(bare):
            # Claude Code would load this file for a session. Here it would reach the builder as a
            # bare line naming a file it never sees, with nothing to say so.
            raise CannotRender("%s imports %s inside the section '%s', and only an import above the first section is written out" % (path, bare, cur[0]))
        else:
            cur[1].append(ln)
    return top, sections


def parse_table(text, path):
    rows = {}
    for n, ln in enumerate(text.split("\n"), 1):
        if not ln.strip() or ln.startswith("#"):
            continue
        f = ln.split("\t")
        kind = f[0]
        if kind in ("carry", "leave") and len(f) == 3 and f[1] and f[2]:
            sec = rows.setdefault(f[1], {"kind": None, "reason": "", "drop": [], "keep": []})
            if sec["kind"] is not None:
                raise CannotRender("%s line %d gives the section '%s' a second carry or leave row" % (path, n, f[1]))
            sec["kind"], sec["reason"] = kind, f[2]
        elif kind in ("drop", "keep") and len(f) == 4 and f[1] and f[2] and f[3]:
            sec = rows.setdefault(f[1], {"kind": None, "reason": "", "drop": [], "keep": []})
            sec[kind].append((f[2], f[3]))
        else:
            raise CannotRender(
                "%s line %d is not a row this reads: carry or leave take a section and a reason, "
                "drop or keep take a section, the item's opening words and a reason, tab separated" % (path, n)
            )
    for name, sec in rows.items():
        if sec["kind"] is None:
            raise CannotRender("%s has a drop or keep row for the section '%s' and no carry or leave row for it" % (path, name))
        if sec["kind"] == "carry" and sec["keep"]:
            raise CannotRender("%s keeps an item of '%s', which is carried whole already" % (path, name))
        if sec["kind"] == "leave" and sec["drop"]:
            raise CannotRender("%s drops an item of '%s', which is left out already" % (path, name))
    return rows


def decide(sections, rows):
    """For each section: what is carried, what the choice is called, and what was left out."""
    out, notes = [], []
    seen = set()
    for heading, lines in sections:
        seen.add(heading)
        items = split_items(lines)
        row = rows.get(heading)
        if row is None:
            notes.append("the section '%s' has no row in the table, so it is carried whole" % heading)
            out.append({"heading": heading, "items": items, "status": "carried", "reason": "no row names it, and a section nobody decided about is carried", "left": [], "kept": []})
            continue
        wanted = row["drop"] if row["kind"] == "carry" else row["keep"]
        matched, unmatched = {}, []
        for words, reason in wanted:
            hits = [k for k, it in enumerate(items) if opening(it).startswith(words)]
            if len(hits) == 1:
                matched[hits[0]] = (words, reason)
            else:
                unmatched.append((words, len(hits)))
        verb = "drop" if row["kind"] == "carry" else "keep"
        for words, count in unmatched:
            notes.append(
                "the %s row for '%s' that opens '%s' matches %d items, where it must match one, so %s"
                % (verb, heading, words, count, "nothing is dropped for it" if verb == "drop" else "the whole section is carried")
            )
        if row["kind"] == "carry":
            carried = [it for k, it in enumerate(items) if k not in matched]
            left = [matched[k] for k in sorted(matched)]
            status = "carried in part" if left else "carried"
            out.append({"heading": heading, "items": carried, "status": status, "reason": row["reason"], "left": left, "kept": []})
        elif unmatched:
            out.append({"heading": heading, "items": items, "status": "carried", "reason": "a keep row no longer matches an item, so all of it is carried until the row is put right", "left": [], "kept": []})
        elif matched:
            carried = [it for k, it in enumerate(items) if k in matched]
            out.append({"heading": heading, "items": carried, "status": "carried in part", "reason": row["reason"], "left": [], "kept": [matched[k] for k in sorted(matched)]})
        else:
            out.append({"heading": heading, "items": [], "status": "left out", "reason": row["reason"], "left": [], "kept": []})
    for name in rows:
        if name not in seen:
            notes.append("the table has a row for the section '%s', which CLAUDE.md does not have" % name)
    return out, notes


def build(rules_dir, head_path, table_path):
    head = read(head_path, "the head")
    if not re.match(r"---\n(?:.*\n)+?---\n", head):
        raise CannotRender("the head %s does not open with frontmatter between two --- lines" % head_path)
    rules_path = os.path.join(rules_dir, "CLAUDE.md")
    top, sections = parse_rules(read(rules_path, "the rules file"), rules_path)
    rows = parse_table(read(table_path, "the table"), table_path)
    decided, notes = decide(sections, rows)
    parts = [head.rstrip("\n"), MARK.rstrip("\n")]
    whole = {heading: len("\n".join(lines).strip("\n")) for heading, lines in sections}
    imports, text, before = 0, [], len(parts)
    for kind, value in top + [("end", "")]:
        if kind == "text":
            text.append(value)
            continue
        words = "\n".join(text).strip("\n")
        if words:
            parts.append(words)
        text = []
        if kind == "import":
            if "/" in value or value.startswith("."):
                raise CannotRender("%s imports %s, and only a file beside it is written out" % (rules_path, value))
            parts.append(read(os.path.join(rules_dir, value), "the imported file").strip("\n"))
            imports += 1
    top_size = sum(len(p) for p in parts[before:])
    for sec in decided:
        sec["of"], sec["chars"] = whole[sec["heading"]], 0
        if not sec["items"]:
            continue
        parts.append("## " + sec["heading"])
        block, bullets = [], []
        for it in sec["items"]:
            if it[0].startswith("- "):
                bullets.append("\n".join(it))
            else:
                if bullets:
                    block.append("\n".join(bullets))
                    bullets = []
                block.append("\n".join(it))
        if bullets:
            block.append("\n".join(bullets))
        parts.append("\n\n".join(block))
        sec["chars"] = len(parts[-1])
    return "\n\n".join(parts) + "\n", decided, notes, (imports, top_size)


def cell(s):
    return s.replace("|", "\\|").replace("\n", " ")


def decisions(decided, top):
    """The choices as a table for a person. The sizes are here and never in the rendered prompt."""
    imports, top_size = top
    lines = ["| Section of CLAUDE.md | For a builder | Characters carried, of the section's | Why, and what is left out or kept |", "| --- | --- | --- | --- |"]
    lines.append(
        "| The top of the file | carried | {:,} | {} |".format(
            top_size,
            "Each of the %d files it imports is written out in full, the lessons core among them, with the words on how to read a lesson in full." % imports
            if imports else "The words above the first section.",
        )
    )
    for sec in decided:
        why = sec["reason"]
        for words, reason in sec["left"]:
            why += " Left out: \"%s\" (%s)" % (words, reason.rstrip("."))
            why += "."
        for words, reason in sec["kept"]:
            why += " Kept: \"%s\" (%s)" % (words, reason.rstrip("."))
            why += "."
        lines.append("| {} | {} | {:,} of {:,} | {} |".format(cell(sec["heading"]), sec["status"], sec["chars"], sec["of"], cell(why)))
    return "\n".join(lines) + "\n"


def first_difference(want, have):
    w, h = want.split("\n"), have.split("\n")
    for n in range(max(len(w), len(h))):
        a = w[n] if n < len(w) else None
        b = h[n] if n < len(h) else None
        if a != b:
            return n + 1, a, b
    return None


def main(argv):
    opts = {"rules": os.path.normpath(os.path.join(HERE, "..", "..")),
            "head": os.path.join(HERE, "builder-type-head.md"),
            "table": os.path.join(HERE, "builder-type-rules.tsv")}
    mode, target, strict = "print", None, False
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("--rules", "--head", "--table", "--out", "--check") and i + 1 < len(argv):
            if a in ("--out", "--check"):
                mode, target = a[2:], argv[i + 1]
            else:
                opts[a[2:]] = argv[i + 1]
            i += 2
        elif a == "--strict":
            strict = True
            i += 1
        elif a == "--decisions":
            mode = "decisions"
            i += 1
        else:
            sys.stderr.write("%s: '%s' is not an option this takes, or lacks its value. See the top of %s.\n" % (NAME, a, os.path.basename(__file__)))
            return 2
    try:
        text, decided, notes, top = build(opts["rules"], opts["head"], opts["table"])
    except CannotRender as e:
        sys.stderr.write("%s: nothing was rendered: %s.\n" % (NAME, e))
        return 2
    for note in notes:
        sys.stderr.write("%s: %s.\n" % (NAME, note))
    if strict and notes:
        sys.stderr.write("%s: nothing was rendered: the table %s has fallen behind %s in the %d ways above. Give each a row, or put the row right.\n"
                         % (NAME, opts["table"], os.path.join(opts["rules"], "CLAUDE.md"), len(notes)))
        return 2
    if mode == "decisions":
        sys.stdout.write(decisions(decided, top))
        return 0
    if mode == "print":
        sys.stdout.write(text)
        return 0
    if mode == "check":
        try:
            with open(target, encoding="utf-8") as fh:
                have = fh.read()
        except OSError as e:
            print("%s: STALE: %s could not be read (%s), so there is no copy to compare." % (NAME, target, e.strerror or type(e).__name__))
            return 1
        diff = first_difference(text, have)
        if diff is None:
            return 0
        n, want, got = diff
        print("%s: STALE: %s is not what its sources render now. First difference, line %d:" % (NAME, target, n))
        print("  the sources give: %s" % ("(no such line)" if want is None else want[:300]))
        print("  the copy holds:   %s" % ("(no such line)" if got is None else got[:300]))
        return 1
    # --out: written beside the target and moved into place, so a reader never sees half a prompt.
    try:
        try:
            with open(target, encoding="utf-8") as fh:
                if fh.read() == text:
                    return 0
        except OSError:
            pass
        tmp = "%s.tmp.%d" % (target, os.getpid())
        try:
            with open(tmp, "w", encoding="utf-8") as fh:
                fh.write(text)
            os.replace(tmp, target)
        finally:
            if os.path.exists(tmp):
                os.remove(tmp)
    except OSError as e:
        sys.stderr.write("%s: nothing was written: %s could not be written (%s).\n" % (NAME, target, e.strerror or type(e).__name__))
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
