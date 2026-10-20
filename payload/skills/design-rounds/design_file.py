"""design_file.py: the one reader of the JSON blocks a settled design file carries (claude-config#1364).

A settled design is one self contained HTML file, and what tools need from it sits in blocks of the
form <script type="application/json" id="NAME">...</script>: the decision map (check-decision-map.py,
#1290), and the frames and Dan's exceptions the design match score reads (score/design_score.py).
Each tool reading its own block with its own parser would be two readers of one file that could
disagree about where a block ends, so both use this one. It also holds the kinds of design drawn with
no product page around it, which the frames block may name, for the same reason: one list, read by
the tools that write that block and the score that reads it.
"""
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
