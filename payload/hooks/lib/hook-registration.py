#!/usr/bin/env python3
"""Where a settings file registers the hooks, judged against what each hook says about itself.

    hook-registration.py <settings file> <hooks dir>

Prints one fault per line and exits 1 when there are any, prints nothing and exits 0 when there are
none, and exits 2 when the settings could not be read, so a caller can tell "judged and clean" from
"not judged at all" (L98, L184).

ONE copy of the question, asked by two callers (claude-config#413): test-hook-coverage.sh, which
fails CI on a fault, and claude-sync's send, which holds the hooks block back on one so the fault
stays on the Mac that made it instead of turning main red for both (L667). Before this the send
asked nothing and CI was the first thing to notice, twice on 2026-09-17. Sharing the rule by copying
it would be two definitions drifting apart (L41, L370), so both run this file.

The faults:
  DUPLICATE    one command registered twice under the same event and matcher. The key includes the
               entry's `if`, because the same hook scoped to two different commands is deliberate.
  UNWIRED      a hook whose header declares `Claude Code <Event>(<tools>) hook` is not run for one
               of those tools under that event.
  EXTRA        such a hook is run for a tool its header does not declare, under that event or the
               other tool event. The header says EXACTLY which tools the hook is for, so the Edit
               gate folded into the Bash group next to its own (the 2026-09-17 shape) is a fault even
               though the Edit group is still there.
  BAD MATCHER  a matcher that is not a valid pattern, reported rather than scored either way (L11).
  UNMATCHABLE IF  an entry whose `if` holds a `|`. Claude Code 2.1.325 matches no command against
               such a condition, whether the `|` joins several rules or sits inside one, and logs
               "Skipping hook due to if condition ... not matching" every time (measured with a
               headless debug run, claude-config#3035). rtk-rewrite.sh shipped that way and so
               rewrote nothing, with every suite green. A hook meant for several commands is
               registered once per rule instead, which DUPLICATE allows because its key holds the if.

    hook-registration.py --runs-for <settings file> <hook basename> <command>

asks the question the last fault exists for: would a PreToolUse entry of that hook run for this Bash
command? Exit 0 yes, 1 no, 2 the settings could not be read. What Claude Code itself matches cannot
be asked offline, so the answer models only the shapes measured on 2.1.325: no `if` runs for every
command, an `if` holding a `|` for none, `Bash(<glob>)` where the glob's `*` matches anything, and the
`Bash(<prefix>:*)` form for the prefix alone or followed by a space.

A hook with no such header line is not judged at all: the header is the hook's own statement of where
it belongs, and without one there is nothing to compare the settings against. Only the hooks
directory itself is read, not lib/, because nothing in lib/ is registered.
"""
import fnmatch
import glob
import json
import os
import re
import sys

HEADER = re.compile(r"Claude Code (PreToolUse|PostToolUse)\(([^)]*)\) hook")
TOOL_EVENTS = ("PreToolUse", "PostToolUse")


def names(cmd):
    return {os.path.basename(t) for t in cmd.split()}


def valid(matcher, faults):
    try:
        re.compile(matcher)
        return True
    except re.error as e:
        line = f"BAD MATCHER {matcher!r} is not a valid pattern ({e}), so what it runs for was not judged"
        if line not in faults:
            faults.append(line)
        return False


def alternatives(matcher):
    """The matcher's top level `|` alternatives, leaving any inside brackets or parentheses alone."""
    out, cur, depth = [], "", 0
    for ch in matcher:
        if ch in "([":
            depth += 1
        elif ch in ")]" and depth:
            depth -= 1
        if ch == "|" and depth == 0:
            out.append(cur)
            cur = ""
        else:
            cur += ch
    out.append(cur)
    return out


def declared_covers(alt, declared):
    """Is one matcher alternative inside the declared tools? Either it IS one of them, written the
    same way (a header may declare a pattern such as mcp__playwright__.*), or it is a plain tool name
    one of them matches. Anything else, a pattern broader than what was declared included, is not."""
    if alt in declared:
        return True
    if re.escape(alt) != alt:
        return False
    for d in declared:
        try:
            if re.fullmatch(d, alt):
                return True
        except re.error:
            continue
    return False


def faults_for(settings, hooks_dir):
    faults = []
    events = json.load(open(settings, errors="replace")).get("hooks", {})
    seen = {}
    runs = {}  # (event, hook basename) -> matchers
    for event, groups in events.items():
        for g in groups:
            matcher = g.get("matcher", "")
            for h in g.get("hooks", []):
                cmd = h.get("command", "")
                key = (event, matcher, cmd, h.get("if", ""))
                seen[key] = seen.get(key, 0) + 1
                for n in names(cmd):
                    runs.setdefault((event, n), []).append(matcher)
    for (event, matcher, cmd, cond), n in sorted(seen.items()):
        if n > 1:
            faults.append(f"DUPLICATE {event} matcher={matcher!r} {cmd}{' if=' + cond if cond else ''} is registered {n} times")
        if "|" in cond:
            faults.append(
                f"UNMATCHABLE IF {event} {' '.join(sorted(names(cmd)))} if={cond!r}: Claude Code matches no "
                f"command against an if holding a |, so this never runs (claude-config#3035); register "
                f"it once per rule")

    def matches(matcher, tool):
        if matcher in ("", "*"):
            return True
        if not valid(matcher, faults):
            return True
        return re.fullmatch(matcher, tool) is not None

    paths = glob.glob(os.path.join(hooks_dir, "*.sh")) + glob.glob(os.path.join(hooks_dir, "*.py"))
    for path in sorted(paths):
        base = os.path.basename(path)
        if base.startswith("test-"):
            continue
        with open(path, errors="replace") as f:
            head = "".join(f.readline() for _ in range(8))
        # A hook may declare both tool events, one header line each (claude-config#647), and is held
        # to each declaration under its own event.
        decl = {}
        for m in HEADER.finditer(head):
            decl.setdefault(m.group(1), m.group(2))
        if not decl:
            continue
        first_event = next(iter(decl))
        for event, spec in decl.items():
            declared = spec.split("|")
            for tool in declared:
                if not any(matches(mt, tool) for mt in runs.get((event, base), [])):
                    faults.append(f"UNWIRED {base} declares {event}({spec}) and is not run for {tool}")
        for ev in TOOL_EVENTS:
            event = ev if ev in decl else first_event
            spec = decl[event]
            declared = spec.split("|")
            for mt in sorted(set(runs.get((ev, base), []))):
                if mt in ("", "*"):
                    faults.append(f"EXTRA {base} declares {event}({spec}) and is run under {ev} for every tool (matcher {mt!r})")
                    continue
                if not valid(mt, faults):
                    continue
                if ev != event:
                    faults.append(f"EXTRA {base} declares {event}({spec}) and is also run under {ev} for {mt}")
                    continue
                for alt in alternatives(mt):
                    if not declared_covers(alt, declared):
                        faults.append(f"EXTRA {base} declares {event}({spec}) and is also run for {alt}")
    return faults


def if_runs_for(cond, tool, command):
    """Would an entry with this `if` run for this tool call? Only the shapes measured on Claude Code
    2.1.325 (claude-config#3035), and anything else is answered no, so an unfamiliar shape fails the
    check rather than passing it."""
    if not cond:
        return True
    if "|" in cond:
        return False
    m = re.fullmatch(r"([A-Za-z0-9_]+)\((.*)\)", cond, re.S)
    if not m or m.group(1) != tool:
        return False
    pattern = m.group(2)
    if pattern.endswith(":*"):
        prefix = pattern[:-2]
        return command == prefix or command.startswith(prefix + " ")
    return fnmatch.fnmatchcase(command, pattern)


def runs_for(settings, hook, command):
    """0 when a PreToolUse entry registering `hook` would run for this Bash command, 1 when none would."""
    events = json.load(open(settings, errors="replace")).get("hooks", {})
    for g in events.get("PreToolUse", []):
        matcher = g.get("matcher", "")
        try:
            if matcher not in ("", "*") and re.fullmatch(matcher, "Bash") is None:
                continue
        except re.error:
            continue
        for h in g.get("hooks", []):
            if hook in names(h.get("command", "")) and if_runs_for(h.get("if", ""), "Bash", command):
                return 0
    return 1


def main(argv):
    if len(argv) == 5 and argv[1] == "--runs-for":
        try:
            return runs_for(argv[2], argv[3], argv[4])
        except (OSError, ValueError, AttributeError, TypeError) as e:
            print(f"could not read {argv[2]}: {e}", file=sys.stderr)
            return 2
    if len(argv) != 3:
        print("usage: hook-registration.py <settings file> <hooks dir>", file=sys.stderr)
        return 2
    try:
        faults = faults_for(argv[1], argv[2])
    except (OSError, ValueError, AttributeError, TypeError) as e:
        print(f"could not read {argv[1]}: {e}", file=sys.stderr)
        return 2
    for line in faults:
        print(line)
    return 1 if faults else 0


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv))
