"""Tests for render_card: the HTML card is built FROM the markdown card.

The markdown card is the single source of truth. Generating the two documents
independently let them drift apart within a single editing session, which is the
bug this exists to prevent.
"""

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
