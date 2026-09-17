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

A hook with no such header line is not judged at all: the header is the hook's own statement of where
it belongs, and without one there is nothing to compare the settings against. Only the hooks
directory itself is read, not lib/, because nothing in lib/ is registered.
"""
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
    events = json.load(open(settings)).get("hooks", {})
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
        m = HEADER.search(head)
        if not m:
            continue
        event, spec = m.group(1), m.group(2)
        declared = spec.split("|")
        for tool in declared:
            if not any(matches(mt, tool) for mt in runs.get((event, base), [])):
                faults.append(f"UNWIRED {base} declares {event}({spec}) and is not run for {tool}")
        for ev in TOOL_EVENTS:
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


def main(argv):
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
    sys.exit(main(sys.argv))
