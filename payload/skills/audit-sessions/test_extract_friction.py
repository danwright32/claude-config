"""Tests for extract_friction: a transcript it could not read fails the run (claude-config#677).

The transcripts folder is the module's BASE, and every test points it at a folder of its own, so
no test reads the real ~/.claude/projects (L2).
"""

import contextlib
import io
import json
import os
import sys
import tempfile
import time
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE))
import extract_friction  # noqa: E402

USER = {"type": "user", "timestamp": "2026-10-08T12:00:00", "message": {"content": "why did that fail"}}


def run(make):
    """Build a transcripts folder with make(project_dir), run main over it, return the outcome."""
    with tempfile.TemporaryDirectory() as base, tempfile.TemporaryDirectory() as out:
        project = Path(base) / "-Users-dan-Apps-demo"
        project.mkdir()
        make(project)
        real = extract_friction.BASE
        extract_friction.BASE = base
        stdout, stderr = io.StringIO(), io.StringIO()
        try:
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                code = extract_friction.main(["--out", out, "--min-sessions", "1"])
        finally:
            extract_friction.BASE = real
        written = sorted(os.listdir(out))
        return code, stdout.getvalue(), stderr.getvalue(), written


def test_a_malformed_line_is_skipped_and_the_rest_is_read():
    def make(project):
        (project / "a.jsonl").write_text("{not json\n" + json.dumps(USER) + "\n")
    code, out, err, written = run(make)
    assert code == 0, err
    assert written == ["friction_demo.txt"]
    assert "1 user msgs" in out


def test_lines_that_are_json_but_not_a_record_are_skipped_too():
    odd = ["null", "[1, 2]", "7", json.dumps({"type": "user", "message": "a bare string"})]
    def make(project):
        (project / "a.jsonl").write_text("\n".join(odd + [json.dumps(USER)]) + "\n")
    code, out, err, written = run(make)
    assert code == 0, err
    assert written == ["friction_demo.txt"]
    assert "1 user msgs" in out


def test_a_record_with_fields_of_odd_shapes_is_skipped_counted_and_said():
    odd = [
        json.dumps({"type": "user", "timestamp": 7, "message": {"content": "a number for a time"}}),
        json.dumps({"type": "user", "message": {"content": [{"type": "text", "text": 5}]}}),
    ]
    def make(project):
        (project / "a.jsonl").write_text("\n".join(odd + [json.dumps(USER)]) + "\n")
    code, out, err, written = run(make)
    assert code == 0, err
    assert "1 user msgs" in out
    assert "2 odd records skipped" in out


def test_a_transcript_that_cannot_be_read_fails_the_run_and_is_named():
    def make(project):
        (project / "a.jsonl").write_text(json.dumps(USER) + "\n")
        (project / "b.jsonl").mkdir()  # a path that opens as an error on every machine, root or not
        now = time.time()
        os.utime(project / "b.jsonl", (now, now))
    code, out, err, written = run(make)
    assert code == 1
    assert "b.jsonl" in err
    assert "could not be read" in err
    # What could be read is still written, so a partial run is not wasted.
    assert written == ["friction_demo.txt"]


def test_no_matching_transcripts_is_said_and_is_not_an_error():
    code, out, err, written = run(lambda project: None)
    assert code == 0
    assert "No project transcript dirs matched" in out
    assert written == []
