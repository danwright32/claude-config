#!/usr/bin/env python3
"""Render the phone-readable HTML card from the markdown card.

The markdown card is the single source of truth. The HTML is a build product.
Never hand-write the HTML: the two drift, and the one he reads at the venue is
the one that goes stale.

    python3 render_card.py path/to/260708-home-r-bust-card.md

Writes 260708-home-r-bust-card.html beside it, using templates/field-card.html
as the styled shell. The shell must contain a <!--CARD--> placeholder.
"""

import argparse
import hashlib
import html
import re
import sys
from pathlib import Path

MARKER = "<!--CARD-->"
DEFAULT_SHELL = Path(__file__).parent.parent / "templates" / "field-card.html"

# ★ is the only marker left. The ● in-hand / ◆ parked legend was dropped on
# 2026-07-23: "I'm not going to remember the symbols." A star needs no decoding;
# a legend does, and the card is read in a dark room with a camera in one hand.
STAR = "★"


def _inline(text: str) -> str:
    """Escape, then re-introduce the small set of spans the card is allowed."""
    out = html.escape(text)
    out = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", out)
    out = out.replace(STAR, f'<span class="star">{STAR}</span>')
    out = _box_sizes(out)
    return out


SIZE_WORD = r"ALL SIZES|WIDE|MEDIUM|TIGHT"
# A run of sizes after a separator: "· WIDE", "· WIDE + TIGHT", "· WIDE and TIGHT".
SIZE_RUN = re.compile(
    rf"·\s*(?P<run>(?:{SIZE_WORD})(?:\s*(?:\+|and|&amp;|,)\s*(?:{SIZE_WORD}))*)\b"
)


def _box_sizes(text: str) -> str:
    """Box every framing size in a run, not just the first.

    The previous pattern was a flat alternation, so "WIDE + TIGHT" matched the
    WIDE branch and left TIGHT as bare prose. On the card that reads as two
    different kinds of thing when it is one instruction (Dan, 2026-07-23).
    """
    def box_run(m: re.Match) -> str:
        return re.sub(rf"\b({SIZE_WORD})\b",
                      r'<span class="size">\1</span>', m.group("run"))

    return SIZE_RUN.sub(box_run, text)


def render_body(markdown: str) -> str:
    lines, out, in_list = markdown.splitlines(), [], False

    def close_list():
        nonlocal in_list
        if in_list:
            out.append("</ul>")
            in_list = False

    i = 0
    while i < len(lines):
        line = lines[i]
        i += 1

        if "<!--" in line:  # comments never ship
            while "-->" not in line and i < len(lines):
                line = lines[i]
                i += 1
            continue

        stripped = line.strip()
        if not stripped or stripped == "---":
            close_list()
            continue

        if stripped.startswith("- [ ] "):
            if not in_list:
                out.append("<ul>")
                in_list = True
            # Gather indented continuation lines into this same item. Emitting
            # them separately detached the tail of a shot into its own paragraph
            # a full gap below the checkbox, which is unreadable at a glance.
            text = stripped[6:]
            while i < len(lines):
                nxt = lines[i]
                if not nxt.startswith((" ", "\t")) or not nxt.strip():
                    break
                if nxt.strip().startswith("- [ ] "):
                    break
                text += " " + nxt.strip()
                i += 1
            out.append(
                f'<li><label><input type="checkbox">'
                f'<span class="txt">{_inline(text)}</span></label></li>'
            )
            continue

        close_list()

        if stripped.startswith("## "):
            out.append(f"<h2>{_inline(stripped[3:])}</h2>")
        elif stripped.startswith("# "):
            out.append(f"<h1>{_inline(stripped[2:])}</h1>")
        else:
            out.append(f"<p>{_inline(stripped)}</p>")

    close_list()
    return "\n".join(out)


class NotesBlock(NamedTuple):
    """One paragraph of the note.

    `paragraph` is 1-based and starts at 2, because Notes injects the note's
    own name as paragraph 1 of the body. `tickable` marks the lines that should
    become tick boxes: shots and actions, never headings or camera settings.
    """
    html: str
    tickable: bool
    paragraph: int


def notes_blocks(markdown: str) -> list:
    blocks, lines, i = [], markdown.splitlines(), 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        line = raw.strip()
        if not line or line == "---" or line.startswith("<!--"):
            continue
        while i < len(lines) and lines[i].startswith((" ", "\t")) and lines[i].strip() \
                and not lines[i].strip().startswith("- [ ] "):
            line += " " + lines[i].strip()
            i += 1
        n = len(blocks) + 2
        if line.startswith("# "):
            blocks.append(NotesBlock(
                f'<div><b><span style="font-size: 20px">'
                f'{html.escape(line[2:])}</span></b></div>', False, n))
        elif line.startswith("## "):
            blocks.append(NotesBlock(
                f"<div><b>{html.escape(line[3:])}</b></div>", False, n))
        elif line.startswith("- [ ] "):
            blocks.append(NotesBlock(
                f"<div>{_notes_inline(line[6:])}</div>", True, n))
        else:
            blocks.append(NotesBlock(f"<div>{_notes_inline(line)}</div>", False, n))
    return blocks


def notes_body(markdown: str) -> str:
    """Render the card as HTML for an Apple Notes note.

    Notes cannot be given checkboxes through AppleScript: the checkbox state is
    a proprietary format that lives outside the HTML. The working route, proven
    against Notes on 2026-07-23, is to create the note with plain content and
    then apply Shift+Cmd+L, which converts **every block** into a checklist
    item. So the only structural requirement here is one div per card line.

    Bold and font size survive that conversion, so headings stay legible.
    Do not emit the note's own title: Notes takes it from the name property,
    and repeating it in the body shows it twice.
    """
    out, lines, i = [], markdown.splitlines(), 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        line = raw.strip()
        if not line or line == "---" or line.startswith("<!--"):
            continue
        # Fold indented continuation lines into the line above, or a wrapped
        # shot becomes two separate tick boxes.
        while i < len(lines) and lines[i].startswith((" ", "\t")) and lines[i].strip() \
                and not lines[i].strip().startswith("- [ ] "):
            line += " " + lines[i].strip()
            i += 1
        if line.startswith("# "):
            out.append(f'<div><b><span style="font-size: 20px">'
                       f'{html.escape(line[2:])}</span></b></div>')
        elif line.startswith("## "):
            out.append(f"<div><b>{html.escape(line[3:])}</b></div>")
        elif line.startswith("- [ ] "):
            out.append(f"<div>{_notes_inline(line[6:])}</div>")
        else:
            out.append(f"<div>{_notes_inline(line)}</div>")
    return "".join(out)


def _notes_inline(text: str) -> str:
    return re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(text))


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("card", type=Path)
    ap.add_argument("--shell", type=Path, default=DEFAULT_SHELL)
    args = ap.parse_args()

    if not args.card.is_file():
        print(f"error: no such card: {args.card}", file=sys.stderr)
        return 1
    if not args.shell.is_file():
        print(f"error: no such shell: {args.shell}", file=sys.stderr)
        return 1

    shell = args.shell.read_text()
    if MARKER not in shell:
        print(f"error: shell {args.shell} has no {MARKER} placeholder, "
              f"so there is nowhere to put the card", file=sys.stderr)
        return 1

    dest = args.card.with_suffix(".html")
    if dest.resolve() == args.shell.resolve():
        print(f"error: {dest} is the shell. Rendering would overwrite it with a "
              f"card, and the next render would use that card as its shell. "
              f"Rename the input, or pass a --shell somewhere else.", file=sys.stderr)
        return 1

    body = args.card.read_text()
    out = shell.replace(MARKER, render_body(body))

    # Ticked checkboxes persist under this key. It must be unique per card:
    # every card used to ship the literal "{event-slug}" placeholder, so they
    # all shared one key and ticks from one event surfaced on the next event's
    # card by position. Include a content hash so an edited card starts clean
    # rather than landing old ticks on renumbered shots.
    digest = hashlib.sha1(body.encode()).hexdigest()[:8]
    out = out.replace("{event-slug}-card-v1", f"{args.card.stem}-{digest}")

    dest.write_text(out)
    print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
