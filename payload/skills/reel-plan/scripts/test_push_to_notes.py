"""Tests for push_to_notes: a failed push never reads as done (claude-config#677).

Every call to osascript goes through push_to_notes._osascript, and every test replaces it, so no
test ever drives Notes, the keyboard or the screen (L2). The replacement records the scripts it
was handed and answers with whatever the case needs.
"""

import contextlib
import io
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import push_to_notes  # noqa: E402

CARD = "# 11:30 Alone in the room\n\n## THE STORY\n- [ ] wide of the stage\n- [ ] the bow\n"


def push(*answers):
    """Run main against a card, with osascript answering each call in turn."""
    calls = []
    queue = list(answers)

    def fake(script):
        calls.append(script)
        rc, out, err = queue.pop(0)
        return subprocess.CompletedProcess(["osascript"], rc, out, err)

    real = push_to_notes._osascript
    push_to_notes._osascript = fake
    stdout, stderr = io.StringIO(), io.StringIO()
    try:
        with tempfile.TemporaryDirectory() as d:
            card = Path(d) / "ev-card.md"
            card.write_text(CARD)
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = push_to_notes.main([str(card), "--folder", "Reels"])
    finally:
        push_to_notes._osascript = real
    return code, stdout.getvalue(), stderr.getvalue(), calls


CREATED = (0, "", "")


def test_a_tick_box_step_that_fails_with_nothing_on_stdout_is_a_failure():
    code, out, err, calls = push(CREATED, (1, "", "execution error: Notes got an error (-1743)"))
    assert len(calls) == 2
    assert code == 1
    assert "wrote note" not in out
    assert "exit 1" in err and "-1743" in err


def test_a_tick_box_step_that_answers_something_unexpected_is_a_failure():
    code, out, err, _ = push(CREATED, (0, "", ""))
    assert code == 1
    assert "wrote note" not in out
    assert "tick boxes NOT applied" in err


def test_an_aborted_tick_box_step_still_says_nothing_was_sent():
    code, out, err, _ = push(CREATED, (0, "ABORTED: frontmost is Finder. Nothing sent.\n", ""))
    assert code == 1
    assert "ABORTED: frontmost is Finder" in err
    assert "wrote note" not in out


def test_a_note_that_could_not_be_created_stops_before_any_keystroke():
    code, out, err, calls = push((1, "", "Notes is not running"))
    assert code == 1
    assert len(calls) == 1
    assert "Notes is not running" in err


def test_the_whole_push_succeeds_only_when_the_step_says_applied():
    code, out, err, calls = push(CREATED, (0, "applied\n", ""))
    assert code == 0, err
    assert 'wrote note "11:30 Alone in the room" to "Reels"' in out
    assert "2 tick boxes" in out


def test_a_missing_card_is_an_error():
    real = push_to_notes._osascript
    push_to_notes._osascript = lambda s: (_ for _ in ()).throw(AssertionError("osascript reached"))
    try:
        with contextlib.redirect_stderr(io.StringIO()) as err:
            code = push_to_notes.main(["/nonexistent/card.md"])
    finally:
        push_to_notes._osascript = real
    assert code == 1
    assert "no such card" in err.getvalue()
