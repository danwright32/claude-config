"""design_file.py: the one reader of the JSON blocks a settled design file carries (claude-config#1364).

A settled design is one self contained HTML file, and what tools need from it sits in blocks of the
form <script type="application/json" id="NAME">...</script>: the decision map (check-decision-map.py,
#1290), and the frames and Dan's exceptions the design match score reads (score/design_score.py).
Each tool reading its own block with its own parser would be two readers of one file that could
disagree about where a block ends, so both use this one. The decision map's optional list of the
design's numbered requirements is read here too (read_requirements, #1401), by make-settled.py, which
writes it, and check-decision-map.py, which holds every decision's number to it. It also holds the kinds of design drawn with
no product page around it, and the shared screens a design may be drawn in, which the frames block may
name, for the same reason: one list, read by the tools that write that block and the score that reads it.
"""
import json
from html.parser import HTMLParser

# The kinds of screen a design round may draw with NO product page around it, each with the one plain
# line said wherever the round is shown (claude-config#1393). Dan, 2026-10-20, on #1393: "allow named
# kinds", an email, a document (a PDF, an invoice export) or a new product whose page does not exist
# yet; every other round is drawn inside the product's captured page. These three and no more: the
# switcher, make-settled.py and the score all read this one list, so a fourth kind is a decision of
# Dan's recorded here, never a spelling one tool accepts and another refuses.
NO_PAGE_KINDS = {
    "email": "An email, with no product page around it",
    "document": "A document, with no product page around it",
    "new-product": "A new product, whose page does not exist yet",
}


def no_page_kinds():
    """The allowed kinds as one readable list, for every refusal to name."""
    return ", ".join(NO_PAGE_KINDS)


# The shared screens a SETTLED design may be drawn in (claude-config#1413), each with its plain line. The
# terminal is itself a Claude Code mod's chrome, so a mod's rounds are drawn in it (the switcher's
# "screen": "terminal", #1384) and so is its settled design. The switcher offers whatever screens/ holds;
# the score is copied into apps without screens/, so the kinds a frames block may name are listed here,
# and a screen added to screens/ reaches a settled design only once it is added here too.
SCREEN_KINDS = {
    "terminal": "The Claude Code terminal, which is itself the chrome of a mod",
}

# Every kind a settled design's frames block may name, and what make-settled.py accepts in "screen".
FRAME_KINDS = dict(NO_PAGE_KINDS, **SCREEN_KINDS)


def frame_kinds():
    """Every kind a frames block may name, as one readable list, for every refusal to name."""
    return ", ".join(FRAME_KINDS)


def read_requirements(value):
    """The design's numbered requirements (claude-config#1401), as make-settled.py's spec and the decision
    map both carry them: a list of {"number": "6.4", "text": "the sentence"}, the number written as text
    exactly as the PRD numbers it. Returns the numbers in order; raises ValueError saying what is wrong.
    One reader, so the tool writing the map and the check reading it never disagree about its shape.
    An empty list is refused rather than read as none: leaving the field out is how a design says it
    gives no sentences, and an empty one cannot be told from a list that was never filled in."""
    if not isinstance(value, list):
        raise ValueError('"requirements" must be a list of {"number", "text"}')
    if not value:
        raise ValueError('"requirements" lists none; leave the field out when the design gives no sentences')
    numbers = []
    for n, r in enumerate(value, 1):
        if not isinstance(r, dict):
            raise ValueError("requirement %d is not an object with a number and its sentence" % n)
        number = r.get("number")
        if not isinstance(number, str) or not number.strip():
            raise ValueError("requirement %d has no number written as text in quotes (it was read as %s), "
                             "exactly as the PRD numbers it" % (n, json.dumps(number)))
        if not isinstance(r.get("text"), str) or not r["text"].strip():
            raise ValueError("requirement %s has no sentence (\"text\")" % number)
        if number.strip() in numbers:
            raise ValueError("two requirements share the number %s" % number.strip())
        numbers.append(number.strip())
    return numbers


class BlockFinder(HTMLParser):
    """Collects the text of every <script id="..."> whose id is one of `ids`, in file order."""

    def __init__(self, ids):
        super().__init__(convert_charrefs=False)
        self.ids = set(ids)
        self.blocks = {i: [] for i in ids}
        self._inside = None

    def handle_starttag(self, tag, attrs):
        if tag == "script":
            block_id = dict(attrs).get("id")
            if block_id in self.ids:
                self._inside = block_id
                self.blocks[block_id].append("")

    def handle_endtag(self, tag):
        if tag == "script":
            self._inside = None

    def handle_data(self, data):
        if self._inside is not None:
            self.blocks[self._inside][-1] += data


def find_blocks(source, ids):
    """{id: [the text of each block with that id]} for every id asked for, empty when there is none."""
    finder = BlockFinder(ids)
    finder.feed(source)
    finder.close()
    return finder.blocks
