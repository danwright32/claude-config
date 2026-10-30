#!/usr/bin/env python3
"""Test support, never run outside a suite: a fake claude's plain text answer, in the events the
lessons review asks the real one for (claude-config#1619).

The runner (lib/ai-review-run.py) runs `claude -p --output-format stream-json --verbose
--include-partial-messages` and reads the review from the stream's result event, starting the
reviews behind it at the stream's first answering event. The suites' fakes answer in plain text,
each in many ways, so rather than each writing the stream itself, a fake asked for stream-json runs
itself again with its output piped through this:

    for a in "$@"; do
      if [ "$a" = stream-json ] && [ -z "${FAKE_STREAM_INNER:-}" ]; then
        FAKE_STREAM_INNER=1 "$0" "$@" | python3 "$FAKE_STREAM"; exit "${PIPESTATUS[0]}"
      fi
    done

It writes the init event and the start of the answer AT ONCE, as the real stream does seconds into
a review however long the review then takes, then reads the fake's text to its end and writes the
whole answer and the result event carrying it. A fake that printed nothing gets a result whose text
is empty. FAKE_STREAM_RESULT, a JSON object, is merged into the result event (a suite's cost and
token counts).
"""
import json
import os
import io
import sys


def out(ev):
    sys.stdout.write(json.dumps(ev) + "\n")
    sys.stdout.flush()


def main():
    out({"type": "system", "subtype": "init", "session_id": "fake"})
    out({"type": "stream_event", "event": {"type": "message_start", "message": {}}})
    text = io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().strip()
    out({"type": "assistant", "message": {"content": [{"type": "text", "text": text}]}})
    res = {"type": "result", "subtype": "success", "is_error": False, "result": text}
    extra = os.environ.get("FAKE_STREAM_RESULT")
    if extra:
        res.update(json.loads(extra))
    out(res)
    return 0


if __name__ == "__main__":
    sys.exit(main())
