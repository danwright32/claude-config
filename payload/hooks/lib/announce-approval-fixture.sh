#!/usr/bin/env bash
#
# announce-approval-fixture.sh: the session transcript a suite builds to show what lib/announce-approval.py
# takes as Dan's approval of an announcement's wording (claude-config#3666).
#
# Sourced by test suites only. No hook uses it.
#
# Five suites need the same session: the library's own, the merge gate's, the label hook's, the
# answer note hook's and the merge helper's. Each writes it as Claude Code writes one (the call's
# input on the assistant entry holding its tool_use, its outcome on the user entry carrying its
# tool_result, and for a picker Dan's choice in toolUseResult.answers and any words he typed beside
# it in toolUseResult.annotations), so the shape is built here once and not once per suite (L613).
#
#   aaf_new <transcript>             a session's transcript holding nothing yet (session s1)
#   aaf_talk <transcript> <action> ...   one more thing the session did:
#       write <file>                 a Write of the file
#       edit <file>                  an Edit of it
#       bash <command> [error]       a Bash call, finished (or failed)
#       agent <prompt>               an agent sent that prompt
#       ask <repo> <file> [answer] [shape] [session]
#                                    the approval picker, answered `Approve the wording` unless
#                                    another answer is given. The shapes are the ways a picker is
#                                    NOT his answer (timeout, prefilled, two, error, othersource,
#                                    unread, nosave, whose question does not tell him to save the
#                                    file, typed:<words>, where he typed those words beside the
#                                    option he chose, typedform, where what came back beside his
#                                    answer is in a form nobody has seen, typedkey, where it is
#                                    under a key nobody has seen, and plain, an ordinary
#                                    picker with no metadata) and two ways it carries what must be ignored
#                                    (claimedhash:<hash>, a hash written into its metadata, and
#                                    preview, an annotation holding the chosen option's preview and
#                                    no words of his).
#       put <repo> <file> [shape] [session]
#                                    the same picker put and not yet answered: only the assistant
#                                    entry holding its tool_use. Prints the picker's id.
#       answer <id> <repo> <file> [answer] [shape] [session]
#                                    his answer to a picker `put` wrote: the user entry carrying its
#                                    tool_result.
#       late <id> <repo> <file> [shape] [session]
#                                    the assistant entry holding the tool_use of a picker with that
#                                    id, written AFTER the hook ran on its `payload` (below).
#       payload <id> <repo> <file> [answer] [shape] [session] [agent id]
#                                    prints, and writes nothing: what Claude Code hands a PostToolUse
#                                    hook once that picker is answered. The picker's tool_result is
#                                    never in the transcript when that hook runs: it is written
#                                    after the hooks have run. Its tool_use has been measured both
#                                    ways on 2026-11-26. In one session the transcript, read at the
#                                    moment a PostToolUse hook of its own call ran, ended at that
#                                    call's tool_use (claude-config#3742). In another (18.8 MB, about
#                                    9,400 lines) the hook found no line holding the picker's id,
#                                    for two pickers, and the transcript read afterwards held both,
#                                    each stamped when it was asked (claude-config#3789). So a case
#                                    about that hook is built in one of two orders: `put`, the hook
#                                    on `payload`, then `answer`; or the hook on `payload` with an
#                                    id of the case's own, then `late`, then `answer`.
#                                    AAF_PAYLOAD_FORM (answers, nometadata, or both words) makes the
#                                    payload's copy of the picker's input differ from the
#                                    transcript's: `nometadata` is the form measured in #3789, where
#                                    metadata a session sent was not in the hook's copy.
#   aaf_bulk <transcript> <lines> <bytes a line>
#                                    that many more lines of an ordinary long session, each about
#                                    that long: text, Bash calls and their results, and now and
#                                    then an ordinary picker. Every word in them is invented.
#   aaf_shown <folder> <transcript> <wording>
#                                    <folder>/announcement.md holding the wording, written by the
#                                    session and then opened in front of Dan; prints the file's path.
#   aaf_hook_check <library> <repo> <hash> [pull request number]
#                                    the library's answer, as JSON, to a hook asking without a claim
#                                    (the hook payload on standard input), asked in process
#   AAF_BBEDIT                       the helper a session opens a file in BBEdit with

AAF_BBEDIT=/Applications/BBEdit.app/Contents/Helpers/bbedit_tool

aaf_new() { printf '{"type": "user", "sessionId": "s1", "message": {"role": "user", "content": "hi"}}\n' > "$1"; }

aaf_talk() {
  python3 - "$@" <<'PY'
import datetime, json, os, sys, time
path, action, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
def line(entry):
    with open(path, "a", encoding="utf-8", errors="replace") as f:
        f.write(json.dumps(entry) + "\n")
def send(uid, name, tool_input, session=None):
    line({"type": "assistant", "sessionId": session or "s1", "cwd": "/", "timestamp": stamp(), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": name, "input": tool_input}]}})
def back(uid, error=False, result=None, session=None):
    entry = {"type": "user", "sessionId": session or "s1", "cwd": "/", "timestamp": stamp(), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": "done", "is_error": error}]}}
    if result is not None:
        entry["toolUseResult"] = result
    line(entry)
def call(name, tool_input, error=False, result=None, session=None):
    uid = "toolu_%s%d" % (name[:3].lower(), time.time_ns())
    send(uid, name, tool_input, session)
    back(uid, error, result, session)
def picker(repo, file, answer, shape):
    q = "Approve the announcement for acme/widget#7, to go to the announcements channel?"
    if shape != "nosave":
        # The sentence the library requires in the question he is shown (claude-config#3742).
        q += " Save the file before you answer."
    if shape == "unread":
        # A zero width space, made from its code point and never written here.
        q = q.replace(" for", chr(0x200b) + " for")
    ask = {"questions": [{"question": q, "header": "Announcement", "multiSelect": False,
                          "options": [{"label": "Approve the wording", "description": "Use it as it reads now"},
                                      {"label": "Not yet", "description": "Leave the label off"}]}],
           "metadata": {"source": "changelog-announce", "repo": repo, "file": file}}
    result = {"questions": ask["questions"], "answers": {q: answer}, "annotations": {}}
    if shape == "timeout":
        result["afkTimeoutMs"] = 60000
    if shape == "prefilled":
        ask["answers"] = {q: answer}
    if shape == "two":
        ask["questions"] = ask["questions"] * 2
    if shape == "othersource":
        ask["metadata"]["source"] = "db-apply"
    if shape == "plain":
        del ask["metadata"]
    if shape.startswith("claimedhash:"):
        ask["metadata"]["sha256"] = shape.split(":", 1)[1]
    # What he types beside the option he chose comes back in the result's annotations, keyed by the
    # question, as {"notes": "<his words>"}, with the chosen option's "preview" before it when the
    # option has one (read from pickers Dan answered with a note, in real session transcripts,
    # 2026-11-26, claude-config#3742).
    if shape.startswith("typed:"):
        result["annotations"] = {q: {"notes": shape.split(":", 1)[1]}}
    if shape == "preview":
        result["annotations"] = {q: {"preview": "Use it as it reads now"}}
    if shape == "typedform":
        # Not a form any transcript holds: his words as a list, which a reader of text would skip.
        result["annotations"] = {q: {"notes": ["approve, but fix line 2"]}}
    if shape == "typedkey":
        # Nor is this one: his words under a key that is neither notes nor the option's preview.
        result["annotations"] = {q: {"preview": "Use it as it reads now", "comment": "approve, but fix line 2"}}
    return ask, result
def arg(n):
    return rest[n] if len(rest) > n and rest[n] else ""
if action == "write":
    call("Write", {"file_path": rest[0], "content": "x"})
elif action == "edit":
    call("Edit", {"file_path": rest[0], "old_string": "a", "new_string": "b"})
elif action == "bash":
    call("Bash", {"command": rest[0], "description": "d"}, error=len(rest) > 1 and rest[1] == "error")
elif action == "agent":
    call("Agent", {"description": "d", "prompt": rest[0]})
elif action == "ask":
    ask, result = picker(rest[0], rest[1], arg(2) or "Approve the wording", arg(3))
    call("AskUserQuestion", ask, error=arg(3) == "error", result=result, session=arg(4) or None)
elif action == "put":
    ask, _ = picker(rest[0], rest[1], "", arg(2))
    uid = "toolu_ask%d" % time.time_ns()
    send(uid, "AskUserQuestion", ask, arg(3) or None)
    print(uid, end="")
elif action == "late":
    ask, _ = picker(rest[1], rest[2], "", arg(3))
    send(rest[0], "AskUserQuestion", ask, arg(4) or None)
elif action == "answer":
    _, result = picker(rest[1], rest[2], arg(3) or "Approve the wording", arg(4))
    back(rest[0], arg(4) == "error", result, arg(5) or None)
elif action == "payload":
    ask, result = picker(rest[1], rest[2], arg(3) or "Approve the wording", arg(4))
    # What the dialog did to the input before the hook saw it has not been measured, so a case can
    # ask for either way it may differ from what the transcript holds: AAF_PAYLOAD_FORM names
    # `answers` (his answers merged into the input, which is how the dialog hands them to the
    # tool), `nometadata` (keys the tool's own schema does not name dropped), or both.
    form = os.environ.get("AAF_PAYLOAD_FORM", "")
    if "answers" in form:
        ask = dict(ask, answers=result["answers"])
    if "nometadata" in form:
        ask = {k: v for k, v in ask.items() if k != "metadata"}
    d = {"session_id": arg(5) or "s1", "transcript_path": path, "cwd": "/", "permission_mode": "default",
         "hook_event_name": "PostToolUse", "tool_name": "AskUserQuestion", "tool_input": ask,
         "tool_response": result, "tool_use_id": rest[0]}
    if arg(6):
        d["agent_id"] = arg(6)
    print(json.dumps(d), end="")
else:
    sys.exit("aaf_talk: no action called " + action)
PY
}

# aaf_hook_check <library> <repo> <hash> [pull request number]: the library's answer to a hook that
# asks without claiming, as JSON, with the hook payload on standard input. It is asked in process,
# as announce-label-ask.sh asks it, because the library's own command line reads the record only
# unless it is the merge gate's claim (claude-config#3703).
aaf_hook_check() {
  python3 -B -c 'import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
try:
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except ValueError:
    payload = {}
pr = sys.argv[4] if len(sys.argv) > 4 else ""
sys.stdout.reconfigure(errors="replace")
json.dump(lib.check(sys.argv[2], sys.argv[3], payload, int(pr) if pr.isdigit() else None), sys.stdout)' "$@"
}

# aaf_bulk <transcript> <lines> <bytes a line>: an ordinary long session's lines, appended. The
# shapes are a real transcript's (an assistant entry of text or of one tool_use, a user entry of its
# tool_result) and every word is invented here: a real transcript holds private text.
aaf_bulk() {
  python3 - "$@" <<'PY'
import json, sys
path, lines, size = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
words = "the build ran and the suite passed on the second try with nothing left to do "
pad = (words * (size // len(words) + 1))[:max(size - 260, 20)]
with open(path, "a", encoding="utf-8", errors="replace") as f:
    n = 0
    while n < lines:
        stamp = "2026-01-01T00:%02d:%02d.000Z" % ((n // 60) % 60, n % 60)
        base = {"sessionId": "s1", "cwd": "/", "timestamp": stamp}
        if n % 500 == 499 and n + 1 < lines:
            uid = "toolu_bulkask%d" % n
            ask = {"questions": [{"question": "Which one? " + pad[:200], "header": "Pick", "multiSelect": False,
                                  "options": [{"label": "A", "description": "a"}, {"label": "B", "description": "b"}]}]}
            entries = [dict(base, type="assistant", message={"role": "assistant", "content": [
                           {"type": "tool_use", "id": uid, "name": "AskUserQuestion", "input": ask}]}),
                       dict(base, type="user", toolUseResult={"questions": ask["questions"], "answers": {"Which one?": "A"},
                                                              "annotations": {}},
                            message={"role": "user", "content": [
                                {"type": "tool_result", "tool_use_id": uid, "content": "done", "is_error": False}]})]
        elif n % 3 == 0:
            entries = [dict(base, type="assistant", message={"role": "assistant", "content": [{"type": "text", "text": pad}]})]
        elif n % 3 == 1:
            entries = [dict(base, type="assistant", message={"role": "assistant", "content": [
                {"type": "tool_use", "id": "toolu_bulk%d" % n, "name": "Bash", "input": {"command": "ls " + pad, "description": "d"}}]})]
        else:
            entries = [dict(base, type="user", toolUseResult={"stdout": pad, "stderr": ""}, message={"role": "user", "content": [
                {"type": "tool_result", "tool_use_id": "toolu_bulk%d" % (n - 1), "content": pad[:200], "is_error": False}]})]
        for e in entries:
            f.write(json.dumps(e) + "\n")
            n += 1
PY
}

aaf_shown() {  # <folder> <transcript> <wording>
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/announcement.md"
  aaf_new "$2"
  aaf_talk "$2" write "$1/announcement.md"
  aaf_talk "$2" bash "$AAF_BBEDIT --front-window $1/announcement.md"
  printf '%s' "$1/announcement.md"
}
