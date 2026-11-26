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
#                                    unread) and one way it carries what must be ignored
#                                    (claimedhash:<hash>, a hash written into its metadata).
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
import datetime, json, sys, time
path, action, rest = sys.argv[1], sys.argv[2], sys.argv[3:]
def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%f")[:-3] + "Z"
def call(name, tool_input, error=False, result=None, session=None):
    uid = "toolu_%s%d" % (name[:3].lower(), time.time_ns())
    who = session or "s1"
    sent = {"type": "assistant", "sessionId": who, "cwd": "/", "timestamp": stamp(), "message": {"role": "assistant", "content": [
        {"type": "tool_use", "id": uid, "name": name, "input": tool_input}]}}
    back = {"type": "user", "sessionId": who, "cwd": "/", "timestamp": stamp(), "message": {"role": "user", "content": [
        {"type": "tool_result", "tool_use_id": uid, "content": "done", "is_error": error}]}}
    if result is not None:
        back["toolUseResult"] = result
    with open(path, "a", encoding="utf-8", errors="replace") as f:
        f.write(json.dumps(sent) + "\n")
        f.write(json.dumps(back) + "\n")
if action == "write":
    call("Write", {"file_path": rest[0], "content": "x"})
elif action == "edit":
    call("Edit", {"file_path": rest[0], "old_string": "a", "new_string": "b"})
elif action == "bash":
    call("Bash", {"command": rest[0], "description": "d"}, error=len(rest) > 1 and rest[1] == "error")
elif action == "agent":
    call("Agent", {"description": "d", "prompt": rest[0]})
elif action == "ask":
    repo, file = rest[0], rest[1]
    answer = rest[2] if len(rest) > 2 and rest[2] else "Approve the wording"
    shape = rest[3] if len(rest) > 3 else ""
    session = rest[4] if len(rest) > 4 else None
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
    if shape.startswith("claimedhash:"):
        ask["metadata"]["sha256"] = shape.split(":", 1)[1]
    call("AskUserQuestion", ask, error=shape == "error", result=result, session=session)
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
