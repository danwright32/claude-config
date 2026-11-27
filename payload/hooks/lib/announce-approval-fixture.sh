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
#       decide <repo> <feature> [answer] [shape] [session] [milestone]
#                                    the picker that asks whether a feature is announced to agents
#                                    (claude-config#3669), answered `Announce it` unless another answer
#                                    is given, and naming a milestone's number in its metadata when
#                                    one is given. The shapes: timeout, prefilled, two, error, unread,
#                                    typed:<words>, notest (its question does not state the test),
#                                    nofeature (its question does not name the feature), within (its
#                                    question holds the feature's name only as the start of a longer
#                                    name), unquoted (the name with no quotation marks round it),
#                                    twono (both of its options decline), otherlabel (its second
#                                    option is not the declining one) and nometa (its metadata names
#                                    no feature).
#       decide-put <repo> <feature> [shape] [session] [milestone]
#       decide-answer <id> <repo> <feature> [answer] [shape] [session] [milestone]
#       decide-late <id> <repo> <feature> [shape] [session] [milestone]
#       decide-payload <id> <repo> <feature> [answer] [shape] [session] [agent id] [milestone]
#                                    that picker put, answered, written after its hook ran, and
#                                    handed to a PostToolUse hook, as put, answer, late and payload
#                                    are for the approval picker (AAF_PAYLOAD_FORM included).
#   aaf_hook_decision <library> <repo> <feature> [milestone]
#                                    the library's answer, as JSON, to a hook asking what Dan last
#                                    answered about announcing a feature (the hook payload on
#                                    standard input), asked in process
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
#   aaf_record_mark <record folder>, aaf_record_untouched <record folder> <mark> <what is the suite's> ...
#                                    the check that ends each suite: whether the suite wrote this
#                                    Mac's real record while it ran (said in full above them, below)

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
def deciding(repo, feature, answer, shape, milestone):
    # The picker that asks whether a feature is announced to agents (claude-config#3669): at feature
    # discovery, or, with a milestone's number in its metadata, at the merge that finishes one.
    q = 'Will "%s" be announced to agents when it ships?' % feature
    if shape == "nofeature":
        q = "Will this feature be announced to agents when it ships?"
    if shape == "within":
        # The feature's name only as the first letters of a longer name: a question about another feature.
        q = 'Will "%sover notes export" be announced to agents when it ships?' % feature
    if shape == "unquoted":
        q = "Will %s be announced to agents when it ships?" % feature
    if shape != "notest":
        q += " The test: agents must or can act differently."
    if shape == "unread":
        q = q.replace(" be", chr(0x200b) + " be")
    ask = {"questions": [{"question": q, "header": "Announce", "multiSelect": False,
                          "options": [{"label": "Announce it", "description": "Its last pull request carries the post"},
                                      {"label": "Not announcing", "description": "It ships with no post for agents"}]}],
           "metadata": {"source": "announce-discovery", "repo": repo, "feature": feature}}
    if milestone:
        ask["metadata"]["milestone"] = int(milestone) if milestone.isdigit() else milestone
    if shape == "twono":
        ask["questions"][0]["options"][0] = {"label": "Skip the post", "description": "It ships with no post for agents"}
    if shape == "otherlabel":
        ask["questions"][0]["options"][1] = {"label": "Decide later", "description": "Ask again at the merge"}
    result = {"questions": ask["questions"], "answers": {q: answer}, "annotations": {}}
    if shape == "timeout":
        result["afkTimeoutMs"] = 60000
    if shape == "prefilled":
        ask["answers"] = {q: answer}
    if shape == "two":
        ask["questions"] = ask["questions"] * 2
    if shape == "nometa":
        del ask["metadata"]["feature"]
    if shape.startswith("typed:"):
        result["annotations"] = {q: {"notes": shape.split(":", 1)[1]}}
    return ask, result
def arg(n):
    return rest[n] if len(rest) > n and rest[n] else ""
if action == "decide":
    ask, result = deciding(rest[0], rest[1], arg(2) or "Announce it", arg(3), arg(5))
    call("AskUserQuestion", ask, error=arg(3) == "error", result=result, session=arg(4) or None)
elif action == "decide-put":
    ask, _ = deciding(rest[0], rest[1], "", arg(2), arg(4))
    uid = "toolu_ask%d" % time.time_ns()
    send(uid, "AskUserQuestion", ask, arg(3) or None)
    print(uid, end="")
elif action == "decide-answer":
    _, result = deciding(rest[1], rest[2], arg(3) or "Announce it", arg(4), arg(6))
    back(rest[0], arg(4) == "error", result, arg(5) or None)
elif action == "decide-late":
    ask, _ = deciding(rest[1], rest[2], "", arg(3), arg(5))
    send(rest[0], "AskUserQuestion", ask, arg(4) or None)
elif action == "decide-payload":
    ask, result = deciding(rest[1], rest[2], arg(3) or "Announce it", arg(4), arg(7))
    # The same two ways the hook's copy may differ from the transcript's as for `payload` below.
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
elif action == "write":
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

# aaf_hook_decision <library> <repo> <feature> [milestone]: what Dan last answered about announcing a
# feature, as a hook asks it (the payload on standard input), in process: the library's own command
# line reads the record only (claude-config#3669).
aaf_hook_decision() {
  python3 -B -c 'import importlib.util, json, sys
spec = importlib.util.spec_from_file_location("announce_approval", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
try:
    payload = json.loads(sys.stdin.buffer.read().decode("utf-8", "replace"))
except ValueError:
    payload = {}
number = sys.argv[4] if len(sys.argv) > 4 else ""
sys.stdout.reconfigure(errors="replace")
json.dump(lib.decision(sys.argv[2], sys.argv[3], int(number) if number.isdigit() else None, payload), sys.stdout)' "$@"
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

# aaf_record_mark and aaf_record_untouched: whether a suite wrote this Mac's real record
# (claude-config#3666, #3669).
#
# A suite keeps its record in a folder of its own through ONE environment variable
# (ANNOUNCE_APPROVALS_DIR), which isolates it only while every call honours the variable (L322). So
# each suite here marks the real record before its first case and asks, after its last, whether the
# suite wrote it. Until #3669 that was a listing of the record's folder compared before and after,
# which blames the suite for whatever else wrote in between (L375): the installed hook notes every
# picker any session on this Mac has answered (#3795), so the check failed whenever one was
# answered while a suite ran, nine times on 2026-11-26 with every other case green. What the check
# is for is narrower, and this says that and nothing more:
#
#   - every line the record held at the mark is still there, unchanged and in place. A line lost
#     or changed in place fails whoever did it: the record is only ever added to.
#   - no line GAINED since the mark is one the suite could have written. A line is the suite's
#     when it names anything of the suite's own, and each suite says what that is:
#       path:<folder>   the suite's temporary folder: a line holding that path anywhere, as the
#                       path of a transcript or a wording file under it is. A fixture session is
#                       called s1, a name too plain to look for, and every fixture transcript
#                       sits under the folder, so the folder stands for the session.
#       repo:<name>     a fixture repository, in any letter case: <owner>/<name>, or <owner>/ for
#                       every repository of that owner.
#     One more thing is the fixture's own and is looked for whatever the suite says: a picker id
#     shaped as aaf_talk and the cases shape theirs, `toolu_`, then lower case letters, then
#     digits or nothing. Claude Code's own ids go on from `toolu_` with `01`: 1,403 of the 1,403
#     in one session's transcript, read on 2026-11-26.
#     Every other gained line is taken as another session's. Its note of a picker answered while
#     the suite ran names its own session, picker and transcript, and none of the above.
#
# It reads the record's own file, keeps no copy of it (the mark is a count and one hash) and prints
# no line of it: a line held against the suite is said by its place among the gained lines, its
# kind and what it names.
#
# WHAT IT CANNOT SEE. A line of the suite's that names none of the above: the fixture writes none
# today, since a line of its with no repository carries a transcript's path or a fixture picker id,
# and a case that sends a picker id shaped as Claude Code's own, with a transcript kept outside the
# suite's folder, would write one. A file other than the record's own, made or changed in the
# record's folder. A line the suite wrote and took out again before it ended. And a record that
# could not be read, before or after, proves nothing: that is said as unread and is never `ok`.
#
#   aaf_record_mark <record folder>            prints the mark of the record as it stands
#   aaf_record_untouched <record folder> <mark> <path:... or repo:...> ...
#                                              prints `ok`, or in one line why not
aaf_record_mark() { _aaf_record mark "$@"; }
aaf_record_untouched() { _aaf_record untouched "$@"; }
_aaf_record() {
  python3 - "$@" <<'PY'
import hashlib, json, os, re, sys
verb, folder, rest = sys.argv[1], sys.argv[2] if len(sys.argv) > 2 else "", sys.argv[3:]
FIXTURE_PICKER = re.compile(r"toolu_[a-z]+[0-9]*")
def held():
    """(the record's lines that hold anything, as bytes, None), or (None, why it could not be
    read). No record yet is an empty one, as the library reads it."""
    try:
        with open(os.path.join(folder, "record.jsonl"), "rb") as f:
            raw = f.read()
    except FileNotFoundError:
        return [], None
    except OSError as e:
        return None, type(e).__name__
    return [l for l in raw.split(b"\n") if l.strip()], None
def digest(lines):
    return hashlib.sha256(b"\n".join(lines)).hexdigest()
def say(words):
    sys.stdout.reconfigure(errors="replace")
    sys.stdout.write(words)
    sys.exit(0)
if not folder:
    say("no record folder was named, so nothing was compared")
lines, why = held()
if verb == "mark":
    say("unread:" + why if lines is None else "%d:%s" % (len(lines), digest(lines)))
mark, own = (rest[0] if rest else ""), rest[1:]
if mark.startswith("unread:"):
    say("the record could not be read before the suite ran (" + mark[7:] + "), so whether the suite wrote it is not known")
at = re.fullmatch(r"([0-9]+):([0-9a-f]{64})", mark)
if not at:
    say("no mark of the record was taken before the suite ran, so nothing was compared")
# What the suite says is its own. A folder is looked for without a leading /private, the spelling
# both /var/... and /private/var/... hold, and one that is no folder at all is in every line.
needles = []
for o in own:
    kind, _, value = o.partition(":")
    if kind == "path":
        value = value.rstrip("/")
        value = value[len("/private"):] if value.startswith("/private/") else value
    if kind not in ("path", "repo") or len(value.strip("/")) < 2:
        needles = []
        break
    needles.append((kind, value.casefold() if kind == "repo" else value))
if not needles:
    say("the check was given " + (json.dumps(own) if own else "nothing") + ", which names nothing of the suite's own "
        "(path:<its temporary folder>, repo:<owner>/<name> or repo:<owner>/), so no line could be told as the suite's")
if lines is None:
    say("the record could not be read after the suite ran (" + why + "), so whether the suite wrote it is not known")
count = int(at.group(1))
if len(lines) < count or digest(lines[:count]) != at.group(2):
    say("a line the record held before the suite ran is gone or was changed in place: it held %d then, and "
        "the first %d it holds now are not those" % (count, count))
def texts(value):
    if isinstance(value, str):
        yield value
    elif isinstance(value, dict):
        for v in value.values():
            yield from texts(v)
    elif isinstance(value, list):
        for v in value:
            yield from texts(v)
def names(raw):
    """(the line's kind, what of the suite's own it names)."""
    text = raw.decode("utf-8", "replace")
    try:
        entry = json.loads(text)
    except ValueError:
        entry = None
    if isinstance(entry, (dict, list)):
        said = list(texts(entry))
        pickers = [t for t in said if FIXTURE_PICKER.fullmatch(t)]
    else:
        # No line the library writes: searched as the text it is.
        said = [text]
        pickers = re.findall(r"(?<![A-Za-z0-9_])" + FIXTURE_PICKER.pattern + r"(?![A-Za-z0-9_])", text)
    whole = isinstance(entry, (dict, list))
    found = []
    for kind, value in needles:
        if kind == "path" and any(value in t for t in said):
            found.append("a path under the suite's temporary folder")
        if kind == "repo":
            for t in said:
                low = t.casefold()
                if whole and (low == value or (value.endswith("/") and low.startswith(value))):
                    found.append("the fixture repository " + t)
                    break
                if not whole and value in low:
                    found.append("the fixture repository " + value)
                    break
    if pickers:
        found.append("a picker id shaped as the fixture's are")
    kind = entry.get("kind") if isinstance(entry, dict) else None
    return ("kind " + kind if isinstance(kind, str) and kind else "no kind"), found
gained = lines[count:]
ours = []
for n, raw in enumerate(gained, 1):
    kind, found = names(raw)
    if found:
        ours.append("gained line %d (%s) names %s" % (n, kind, " and ".join(found)))
if ours:
    say("the record gained %d line%s while the suite ran, and %d of them could be this suite's own: %s"
        % (len(gained), "" if len(gained) == 1 else "s", len(ours), "; ".join(ours[:5])
           + ("; and %d more" % (len(ours) - 5) if len(ours) > 5 else "")))
say("ok")
PY
}
