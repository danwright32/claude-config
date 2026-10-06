#!/usr/bin/env python3
"""Compress a subagent transcript into something small enough to hand a model.

Usage: subagent-digest.py <transcript_path> [max_chars]

Prints the agent's own words plus the files it touched. Tool RESULTS are left
out on purpose: they are most of the bytes and none of the judgment, and what
this is looking for is what the agent NOTICED, which only ever appears in what
it said.

Exit codes, because the caller has to tell these apart and stdout cannot:
  0  a digest was printed
  1  the transcript was read fine and the agent said nothing
  2  the transcript could not be read at all

A caller that consults only stdout files an unreadable transcript as an agent
with nothing to report, which is the reassuring half of the pair and therefore
the one that gets believed.
"""
import json
import sys

MAX_DEFAULT = 40000

# The task is capped so one enormous brief cannot crowd out what the agent SAID, which is the part
# the harvest is reading for. 6000 rather than the old 1500, measured 2026-10-06 over 508 real
# subagent transcripts on this Mac: the median brief was 1,564 characters, so 1500 trimmed more
# than half of them, the 75th percentile was 3,325 and the 90th 5,801. The cost is bounded: at
# most 4,500 more characters, roughly 1,100 tokens, against a harvest call measured at 29,663
# input tokens (claude-config#538), and the body below is still capped on its own.
TASK_MAX = 6000

# What a trimmed task ends with. The harvest prompt names this exact opening so the model knows the
# cut was made here and is not the brief being broken; without it a complete brief read as one cut
# off mid sentence and was filed as a finding (claude-config#860). Imported by nothing, so the
# harvest prompt carries its own copy, and test-subagent-issue-harvest.sh reads the marker out of a
# real digest and checks the prompt names it, so the two cannot drift apart silently.
TASK_TRIM_MARKER = "[task trimmed by the digest"


def trim_task(text):
    text = text.strip()
    if len(text) <= TASK_MAX:
        return text
    return "%s\n%s at %d of %d characters; the brief itself was complete]" % (
        text[:TASK_MAX], TASK_TRIM_MARKER, TASK_MAX, len(text))


def main():
    if len(sys.argv) < 2:
        return 2
    try:
        max_chars = int(sys.argv[2]) if len(sys.argv) > 2 else MAX_DEFAULT
    except ValueError:
        max_chars = MAX_DEFAULT

    try:
        with open(sys.argv[1], "r", encoding="utf-8") as fh:
            lines = [ln for ln in fh if ln.strip()]
    except Exception:
        return 2   # unreadable: not the same as silent

    said = []
    touched = []
    task = None
    for ln in lines:
        try:
            obj = json.loads(ln)
        except Exception:
            continue

        if obj.get("type") == "user" and task is None:
            content = (obj.get("message") or {}).get("content")
            if isinstance(content, str) and content.strip():
                task = trim_task(content)
            elif isinstance(content, list):
                for it in content:
                    if isinstance(it, dict) and it.get("type") == "text" and (it.get("text") or "").strip():
                        task = trim_task(it["text"] or "")
                        break

        if obj.get("type") != "assistant":
            continue
        for it in ((obj.get("message") or {}).get("content") or []):
            if not isinstance(it, dict):
                continue
            if it.get("type") == "text" and (it.get("text") or "").strip():
                said.append((it["text"] or "").strip())
            elif it.get("type") == "tool_use":
                inp = it.get("input") or {}
                path = inp.get("file_path") or inp.get("path")
                if path and path not in touched:
                    touched.append(path)

    body = "\n\n".join(said).strip()
    if not body:
        return 1   # read fine, the agent simply said nothing

    # Keep the END of what the agent said: the observations it is still carrying
    # when it wraps up are the ones worth filing, and an agent's closing summary
    # is where it says what it left alone.
    if len(body) > max_chars:
        body = "[earlier output trimmed]\n\n" + body[-max_chars:]

    out = []
    if task:
        out.append("TASK THE AGENT WAS GIVEN:\n%s" % task)
    if touched:
        out.append("FILES IT TOUCHED:\n%s" % "\n".join(touched[:60]))
    out.append("WHAT THE AGENT SAID:\n%s" % body)
    print("\n\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
