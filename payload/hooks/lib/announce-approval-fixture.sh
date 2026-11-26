#!/usr/bin/env bash
#
# announce-approval-fixture.sh: the session transcript a suite builds to show what lib/announce-approval.py
# takes as Dan's approval of an announcement's wording (claude-config#3666).
#
# Sourced by test suites only. No hook uses it.
#
# Three suites need the same session: the library's own, the merge gate's and the label hook's. Each
# writes it as Claude Code writes one (the call's input on the assistant entry holding its tool_use,
# its outcome on the user entry carrying its tool_result, and for a picker Dan's choice in
# toolUseResult.answers), so the shape is built here once and not once per suite (L613).
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
#                                    unread, and plain, an ordinary picker with no metadata) and
#                                    one way it carries what must be ignored (claimedhash:<hash>, a
#                                    hash written into its metadata).
#       put <repo> <file> [shape] [session]
#                                    the same picker put and not yet answered: only the assistant
#                                    entry holding its tool_use. Prints the picker's id.
#       answer <id> <repo> <file> [answer] [shape] [session]
#                                    his answer to a picker `put` wrote: the user entry carrying its
#                                    tool_result.
#       payload <id> <repo> <file> [answer] [shape] [session] [agent id]
#                                    prints, and writes nothing: what Claude Code hands a PostToolUse
#                                    hook once that picker is answered. A hook that runs then finds
#                                    the picker's tool_use in the transcript and NOT its tool_result,
#                                    which is written after the hooks have run (measured 2026-11-26,
#                                    claude-config#3742: the transcript of a session read at the
#                                    moment a PostToolUse hook of its own call ran ended at that
#                                    call's tool_use). So a case about that hook is `put`, the hook on
#                                    `payload`, then `answer`. AAF_PAYLOAD_FORM (answers,
#                                    nometadata, or both words) makes the payload's copy of the
#                                    picker's input differ from the transcript's in the ways the
#                                    dialog may change it, since no real payload has been printed.
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

aaf_shown() {  # <folder> <transcript> <wording>
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/announcement.md"
  aaf_new "$2"
  aaf_talk "$2" write "$1/announcement.md"
  aaf_talk "$2" bash "$AAF_BBEDIT --front-window $1/announcement.md"
  printf '%s' "$1/announcement.md"
}
