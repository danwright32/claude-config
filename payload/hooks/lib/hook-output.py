#!/usr/bin/env python3
"""What a hook PRINTS, judged against the output shapes Claude Code accepts (claude-config#478).

    hook-output.py <settings file> <hooks dir>   judge every hook in the tree
    hook-output.py --payload                     judge one JSON document read on stdin

Prints one fault per line and exits 1 when there are any, prints nothing and exits 0 when there are
none, and exits 2 when it could not judge at all, so a caller can tell "judged and clean" from "not
judged" (L98, L184).

Why it exists: post-compact.sh printed `{"hookSpecificOutput": {"additionalContext": ...}}` with no
`hookEventName`, so Claude Code rejected the whole payload with "Hook JSON output validation
failed" and the project rules it exists to restore never reached a compacted session. Every
assertion in its own suite passed throughout, because a hook's suite reads the words in its output
and nothing compared the output against what the platform takes (L3). The same object is copied
from hook to hook, so the guard is the tree wide question, not the one line (L30, L613).

THE TABLE BELOW IS A MEASUREMENT, not a memory. It is the discriminated union behind
`hookSpecificOutput` in the installed Claude Code, read out of the binary with
`strings -a ~/.local/share/claude/versions/<version>` and searching for `hookSpecificOutput:$e([`,
against 2.1.278 on 2026-09-19. Re-derive it the same way when a new event appears rather than
adding a name from memory: the whole value of this file is that it says what the platform accepts
rather than what somebody expected it to accept.

Two of the answers it gives are worth stating outright, because both look like working code:

  * An event absent from the table takes NO hookSpecificOutput at all. PostCompact is one. Its
    hooks run, and their stdout becomes a line shown to the person ("PostCompact [command]
    completed successfully: ..."), never context for the model. After a compaction Claude Code
    runs the SessionStart hooks with source "compact" and appends their results to the rebuilt
    transcript, so SessionStart is the event a compaction can inject context from.

  * A field the named event does not take is dropped or refused, so context handed to the wrong
    event reaches nothing while the hook goes on reporting success (L98).
"""
import glob
import json
import os
import re
import sys

# event -> the fields its hookSpecificOutput accepts. See the note above on where this came from.
EVENTS = {
    "PreToolUse": {"additionalContext", "permissionDecision", "permissionDecisionReason", "updatedInput"},
    "UserPromptSubmit": {"additionalContext", "sessionTitle", "suppressOriginalPrompt"},
    "UserPromptExpansion": {"additionalContext", "suppressOriginalPrompt"},
    "SessionStart": {"additionalContext", "initialUserMessage", "reloadSkills", "sessionTitle", "watchPaths"},
    "Setup": {"additionalContext"},
    "PreModelSwitch": {"permissionDecision", "permissionDecisionReason"},
    "PostModelSwitch": {"additionalContext"},
    "SubagentStart": {"additionalContext"},
    "PostToolUse": {"additionalContext", "classifierContext", "updatedMCPToolOutput", "updatedToolOutput"},
    "PostToolUseFailure": {"additionalContext"},
    "PostToolBatch": {"additionalContext"},
    "Stop": {"additionalContext"},
    "SubagentStop": {"additionalContext"},
    "PermissionDenied": {"retry"},
    "Notification": {"additionalContext"},
    "PermissionRequest": {"decision", "interrupt", "message", "updatedInput", "updatedPermissions"},
    "Elicitation": {"action", "content"},
    "ElicitationResult": {"action", "content"},
    "CwdChanged": {"watchPaths"},
    "FileChanged": {"watchPaths"},
    "WorktreeCreate": {"worktreePath"},
    "MessageDisplay": {"displayContent"},
}

# An EMISSION, not a read. `"hookSpecificOutput": {` is a hook building the object; the reads that
# fill this tree's test suites and measurement scripts are `.get("hookSpecificOutput")` and
# `["hookSpecificOutput"]`, neither of which puts a `{` after the key (L104: a shape filter has to
# be measured against what it must PRESERVE as well as what it must catch).
EMISSION = re.compile(r"""["']?hookSpecificOutput["']?\s*:\s*\{""")
NAMED = re.compile(r"""["']?hookEventName["']?\s*:\s*["']([A-Za-z]+)["']""")
FIELD = re.compile(r"""["']?([a-zA-Z]+)["']?\s*:\s*$""")


def walk(text, start):
    """Yield (index, character, depth) through `text` from `start`, counting braces and brackets
    outside quoted strings, and stopping once the object opened at `start` closes."""
    depth = 0
    quote = ""
    i = start
    while i < len(text):
        ch = text[i]
        if quote:
            if ch == "\\":
                i += 2
                continue
            if ch == quote:
                quote = ""
        elif ch in "\"'":
            quote = ch
        elif ch in "{[":
            depth += 1
        elif ch in "}]":
            depth -= 1
            if depth == 0:
                yield i, ch, depth
                return
        yield i, ch, depth
        i += 1


def object_after(text, start):
    """The balanced brace object beginning at `start`, or the rest of the text if it never closes."""
    end = start
    for i, _ch, _depth in walk(text, start):
        end = i
    return text[start:end + 1]


def top_level_fields(text, start):
    """The keys of the object opened at `start`, ignoring the keys of anything nested inside it: a
    nested object's own keys belong to a different shape and judging them here would accuse a
    correct hook (L104)."""
    fields = set()
    for i, ch, depth in walk(text, start):
        if ch == ":" and depth == 1:
            m = FIELD.search(text[max(start, i - 60):i + 1])
            if m:
                fields.add(m.group(1))
    return fields


def hook_files(hooks_dir):
    paths = []
    for pattern in ("*.sh", "*.py", "lib/*.sh", "lib/*.py"):
        paths.extend(glob.glob(os.path.join(hooks_dir, pattern)))
    # This file has to spell out the shape it looks for, in the table and in the sentences
    # explaining it, so a scan that read itself would report its own documentation as a broken hook
    # for ever (L245). It is a judge rather than a hook: nothing registers it and it prints no
    # payload of its own.
    mine = os.path.abspath(__file__)
    return sorted(
        p for p in paths
        if not os.path.basename(p).startswith("test-") and os.path.abspath(p) != mine
    )


def whole_name(name):
    return re.compile(r"(^|[^A-Za-z0-9_-])%s([^A-Za-z0-9_-]|$)" % re.escape(name))


def registered_events(settings, hooks_dir):
    """Which events run each hook, following one hook calling another until nothing new resolves.

    gh_issue_scan.py is never named in the settings: require-issue-fields.sh is, and it runs
    issue_field_gate.py, which imports the scanner. A resolver that stopped at the settings would
    call the scanner unregistered and accuse it of naming the wrong event (L96)."""
    runs = {}
    for event, groups in json.load(open(settings)).get("hooks", {}).items():
        for group in groups:
            for hook in group.get("hooks", []):
                for token in hook.get("command", "").split():
                    base = os.path.basename(token)
                    if base.endswith(".sh") or base.endswith(".py"):
                        runs.setdefault(base, set()).add(event)
    texts = {os.path.basename(p): open(p, errors="replace").read() for p in hook_files(hooks_dir)}
    changed = True
    while changed:
        changed = False
        for caller, text in texts.items():
            for callee in texts:
                if callee == caller or not whole_name(callee).search(text):
                    continue
                inherited = runs.get(caller, set()) - runs.get(callee, set())
                if inherited:
                    runs.setdefault(callee, set()).update(inherited)
                    changed = True
    return runs


def faults_for(settings, hooks_dir):
    faults = []
    runs = registered_events(settings, hooks_dir)
    judged = 0
    for path in hook_files(hooks_dir):
        base = os.path.basename(path)
        text = open(path, errors="replace").read()
        for m in EMISSION.finditer(text):
            judged += 1
            obj = object_after(text, m.end() - 1)
            named = NAMED.search(obj)
            if not named:
                faults.append(
                    f"NO EVENT NAME {base} prints hookSpecificOutput with no hookEventName, "
                    "so Claude Code refuses the whole payload and the hook says nothing to the session"
                )
                continue
            event = named.group(1)
            if event not in EVENTS:
                faults.append(
                    f"UNKNOWN EVENT {base} names {event}, which is not an event Claude Code takes "
                    "hookSpecificOutput from, so the payload is refused"
                )
                continue
            for field in sorted(top_level_fields(text, m.end() - 1) - {"hookEventName"}):
                if field not in EVENTS[event]:
                    faults.append(
                        f"WRONG CHANNEL {base} names {event} and carries {field}, which a {event} "
                        "output does not take, so what it carries reaches nothing"
                    )
            where = runs.get(base, set())
            if not where:
                faults.append(
                    f"UNREGISTERED {base} names {event} and nothing in the settings runs it, "
                    "so the event it claims was never compared against one"
                )
            elif event not in where:
                faults.append(
                    f"MISREGISTERED {base} names {event} and the settings run it under "
                    f"{', '.join(sorted(where))}"
                )
    if judged == 0:
        raise ValueError(f"no hook in {hooks_dir} prints hookSpecificOutput, so nothing was judged")
    return faults


def payload_faults(document):
    """Why Claude Code would refuse, or quietly drop, one hook's printed JSON."""
    try:
        data = json.loads(document)
    except ValueError as e:
        return [f"the hook printed something that is not JSON, so nothing of it is read ({e})"]
    if not isinstance(data, dict):
        return ["the hook printed JSON that is not an object, so nothing of it is read"]
    block = data.get("hookSpecificOutput")
    if block is None:
        return ["the hook printed no hookSpecificOutput, so it hands the session nothing"]
    if not isinstance(block, dict):
        return ["hookSpecificOutput is not an object, so Claude Code refuses the payload"]
    event = block.get("hookEventName")
    if not event:
        return ['hookSpecificOutput is missing required field "hookEventName", so Claude Code refuses the payload']
    if event not in EVENTS:
        return [f"hookEventName {event} is not an event Claude Code takes hookSpecificOutput from, so the payload is refused"]
    return [
        f"{field} is not a field a {event} output takes, so what it carries reaches nothing"
        for field in sorted(block)
        if field != "hookEventName" and field not in EVENTS[event]
    ]


def main(argv):
    if len(argv) == 2 and argv[1] == "--payload":
        document = sys.stdin.read()
        if not document.strip():
            print("read nothing on stdin, so no payload was judged", file=sys.stderr)
            return 2
        faults = payload_faults(document)
    elif len(argv) == 3:
        try:
            faults = faults_for(argv[1], argv[2])
        except (OSError, ValueError, AttributeError, TypeError) as e:
            print(f"could not judge {argv[1]}: {e}", file=sys.stderr)
            return 2
    else:
        print("usage: hook-output.py <settings file> <hooks dir> | hook-output.py --payload", file=sys.stderr)
        return 2
    for line in faults:
        print(line)
    return 1 if faults else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
