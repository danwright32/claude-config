"""Tests for render_card: the HTML card is built FROM the markdown card.

The markdown card is the single source of truth. Generating the two documents
independently let them drift apart within a single editing session, which is the
bug this exists to prevent.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
RENDER = HERE / "render_card.py"


def render(markdown: str, shell: str = None) -> str:
    with tempfile.TemporaryDirectory() as d:
        md = Path(d) / "ev-card.md"
        md.write_text(markdown)
        cmd = [sys.executable, str(RENDER), str(md)]
        if shell is not None:
            sh = Path(d) / "shell.html"
            sh.write_text(shell)
            cmd += ["--shell", str(sh)]
        subprocess.run(cmd, check=True, capture_output=True, text=True)
        return (Path(d) / "ev-card.html").read_text()


SHELL = "<html><head><style>x</style></head><body>\n<!--CARD-->\n</body></html>"


def test_phase_heading_becomes_h1():
    out = render("# 11:30 · Alone in the room\n", SHELL)
    assert "<h1>11:30 · Alone in the room</h1>" in out


def test_section_heading_becomes_h2():
    out = render("## THE STORY\n", SHELL)
    assert "<h2>THE STORY</h2>" in out


def test_checkbox_line_becomes_labelled_input():
    out = render("- [ ] Choose the surface\n", SHELL)
    assert '<input type="checkbox">' in out
    assert "Choose the surface" in out
    assert "<label>" in out


def test_star_gets_its_own_class_so_it_can_be_styled():
    out = render("- [ ] ★ Park for the finale\n", SHELL)
    assert 'class="star"' in out


def test_in_hand_and_parked_markers_are_no_longer_special():
    """Dan, 2026-07-23: 'I'm not going to remember the symbols.'

    The ● and ◆ legend was dropped from the card. The star survives because it
    needs no decoding. Nothing should re-introduce a legend by styling these.
    """
    out = render("- [ ] ● Empty room\n- [ ] ◆ Bow\n", SHELL)
    assert 'class="hand"' not in out
    assert 'class="park"' not in out


def test_a_single_framing_size_is_boxed():
    out = render("- [ ] Empty stage · WIDE\n", SHELL)
    assert out.count('class="size"') == 1


def test_every_size_in_a_pair_is_boxed_not_just_the_first():
    """Dan, 2026-07-23: 'unclear why wide and tight are different fonts.'

    The old pattern listed WIDE before WIDE + TIGHT in an alternation, so it
    matched WIDE and stopped, leaving TIGHT as bare text. On the card that reads
    as two different kinds of thing when it is one instruction.
    """
    for line in ("- [ ] Empty stage · WIDE + TIGHT\n",
                 "- [ ] Empty stage · WIDE and TIGHT\n"):
        out = render(line, SHELL)
        assert out.count('class="size"') == 2, line


def test_a_size_word_inside_ordinary_prose_is_not_boxed():
    out = render("Take a wide berth around the TIGHTrope.\n", SHELL)
    assert 'class="size"' not in out


def test_rendering_never_overwrites_its_own_shell():
    """Rendering templates/field-card.md destroyed templates/field-card.html.

    The renderer writes <card>.html beside <card>.md, and the shell happens to
    be named field-card.html in the same folder as the template field-card.md.
    So rendering the template clobbered the shell with the rendered output, and
    the next render would have used a card as its own shell. 2026-07-23.
    """
    with tempfile.TemporaryDirectory() as d:
        md = Path(d) / "field-card.md"
        md.write_text("## THE STORY\n")
        shell = Path(d) / "field-card.html"   # same stem: the collision
        shell.write_text(SHELL)
        before = shell.read_text()

        r = subprocess.run(
            [sys.executable, str(RENDER), str(md), "--shell", str(shell)],
            capture_output=True, text=True,
        )
        assert r.returncode != 0, "should refuse, not clobber"
        assert shell.read_text() == before, "shell must be left untouched"


def test_a_wrapped_shot_stays_inside_one_checkbox_item():
    """Dan, 2026-07-23: 'this line break is going to screw me up because I
    won't read the second line in the heat of the moment.'

    An indented continuation line used to close the list and emit a <p>, so the
    tail of a shot rendered as a detached paragraph a full gap below its own
    checkbox. It must stay in the same item and simply wrap.
    """
    out = render("- [ ] Film the whole change\n      in one take · MEDIUM\n", SHELL)
    assert out.count("<li>") == 1
    assert "<p>" not in out
    assert "Film the whole change in one take" in out


SHELL_WITH_KEY = (
    '<html><head><style>x</style></head><body>\n<!--CARD-->\n'
    '<script>var KEY = "{event-slug}-card-v1";</script></body></html>'
)


def _key(out: str) -> str:
    m = re.search(r'var KEY = "([^"]*)"', out)
    assert m, "no storage key in output"
    return m.group(1)


def test_the_storage_key_placeholder_never_ships():
    """Every card shipped with the literal "{event-slug}" placeholder as its key.

    The ticked-checkbox state is saved per key, so every card shared one key.
    Ticking shots on one event's card made them appear already ticked on the
    next event's card, by position. A silent wrong answer, in a venue.
    """
    out = render("- [ ] A shot\n", SHELL_WITH_KEY)
    assert "{event-slug}" not in out
    assert "{" not in _key(out)


def test_two_cards_get_different_storage_keys():
    with tempfile.TemporaryDirectory() as d:
        keys = []
        for name in ("odyssey-card.md", "bludline-card.md"):
            md = Path(d) / name
            md.write_text("- [ ] A shot\n")
            sh = Path(d) / "shell.html"
            sh.write_text(SHELL_WITH_KEY)
            subprocess.run(
                [sys.executable, str(RENDER), str(md), "--shell", str(sh)],
                check=True, capture_output=True, text=True,
            )
            keys.append(_key(md.with_suffix(".html").read_text()))
        assert keys[0] != keys[1], f"both cards share the key {keys[0]}"


def test_notes_body_puts_every_card_line_in_its_own_div():
    """Apple Notes turns each block into one checklist item via Shift+Cmd+L.

    So every card line must be its own div, or several shots collapse into one
    tick box. Verified against Notes on 2026-07-23.
    """
    from render_card import notes_body
    out = notes_body("# ARRIVAL\n\n- [ ] First shot · WIDE\n- [ ] Second shot · TIGHT\n")
    assert out.count("<div>") == 3


def test_notes_body_drops_the_checkbox_syntax_but_keeps_the_words():
    from render_card import notes_body
    out = notes_body("- [ ] Barrow Street · WIDE\n")
    assert "- [ ]" not in out
    assert "Barrow Street" in out


def test_notes_body_keeps_headings_visually_distinct():
    from render_card import notes_body
    out = notes_body("# THE END\n")
    assert "<b>" in out and "THE END" in out


def test_notes_body_escapes_html_so_a_shot_name_cannot_inject():
    from render_card import notes_body
    out = notes_body("- [ ] A <script>alert(1)</script> shot\n")
    assert "<script>" not in out


def test_bold_is_converted():
    out = render("**Out by 2:00.**\n", SHELL)
    assert "<b>Out by 2:00.</b>" in out


def test_html_is_escaped_so_a_shot_named_with_angle_brackets_cannot_inject():
    out = render("- [ ] A <script>alert(1)</script> shot\n", SHELL)
    assert "<script>alert(1)</script>" not in out
    assert "&lt;script&gt;" in out


def test_comments_in_the_markdown_are_not_emitted():
    out = render("<!-- do not ship this note -->\n## THE STORY\n", SHELL)
    assert "do not ship this note" not in out


def test_output_is_inserted_into_the_shell_not_appended():
    out = render("## THE STORY\n", SHELL)
    assert out.startswith("<html>")
    assert out.rstrip().endswith("</html>")
    assert "<style>x</style>" in out


def test_rendering_twice_is_identical():
    md = "# 1:00 · The show\n- [ ] ★ ◆ Park\n"
    assert render(md, SHELL) == render(md, SHELL)


def test_missing_card_placeholder_is_an_error_not_a_silent_no_op():
    bad = "<html><body>no placeholder</body></html>"
    try:
        render("## X\n", bad)
    except subprocess.CalledProcessError as e:
        assert "CARD" in (e.stderr or "")
        return
    raise AssertionError("expected a non-zero exit when the shell has no <!--CARD--> marker")


def test_missing_input_file_is_an_error():
    with tempfile.TemporaryDirectory() as d:
        r = subprocess.run(
            [sys.executable, str(RENDER), str(Path(d) / "nope.md")],
            capture_output=True, text=True,
        )
    assert r.returncode != 0
    assert "nope.md" in r.stderr


if __name__ == "__main__":
    failures = 0
    for name, fn in sorted(globals().items()):
        if name.startswith("test_") and callable(fn):
            try:
                fn()
                print(f"PASS {name}")
            except Exception as e:
                failures += 1
                print(f"FAIL {name}: {e}")
    print(f"\n{failures} failing")
    sys.exit(1 if failures else 0)
