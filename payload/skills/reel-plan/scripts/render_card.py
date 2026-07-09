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
import html
import re
import sys
from pathlib import Path

MARKER = "<!--CARD-->"
DEFAULT_SHELL = Path(__file__).parent.parent / "templates" / "field-card.html"

HAND, PARK, STAR = "●", "◆", "★"


def _inline(text: str) -> str:
    """Escape, then re-introduce the small set of spans the card is allowed."""
    out = html.escape(text)
    out = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", out)
    out = out.replace(STAR, f'<span class="star">{STAR}</span>')
    out = out.replace(HAND, f'<span class="hand">{HAND}</span>')
    out = out.replace(PARK, f'<span class="park">{PARK}</span>')
    out = re.sub(r"·\s*(WIDE|MEDIUM|TIGHT|ALL SIZES|WIDE \+ TIGHT)\b",
                 r'<span class="size">\1</span>', out)
    return out


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
            out.append(
                f'<li><label><input type="checkbox">'
                f'<span class="txt">{_inline(stripped[6:])}</span></label></li>'
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

    out = shell.replace(MARKER, render_body(args.card.read_text()))
    dest = args.card.with_suffix(".html")
    dest.write_text(out)
    print(f"wrote {dest}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
