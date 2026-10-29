#!/usr/bin/env python3
"""Suites that hand roll a wall clock wait instead of taking the shared hang ceiling (claude-config#1679).

A wait on a condition needs a ceiling, or a broken fixture hangs the suite instead of failing it.
What it must never be is a JUDGEMENT OF SPEED: a ceiling of a few seconds is reached by a loaded Mac
with nothing broken (L290). #1577 and #1620 found the same shape in eleven suites, a `sleep 0.1`
loop of a few hundred ticks or a `$SECONDS` plus a few seconds, and moved them onto
hooks/lib/hang-wait.sh, whose one ceiling only a hang reaches. This finds the next one (L613).

WHAT IT LOOKS FOR, in a suite file (a test-*.sh), a loop that SLEEPS and is bounded by its own clock:
  - a `while` or `until` loop whose condition reads the clock (`SECONDS`, `date +%s`), or compares a
    counter the loop body itself counts up (`n=$((n + 1))`), against a bound that is not the hang
    ceiling (no `HANG` in it: `$HANG_S`, or `$FAKE_HANG_S` in a stand in that runs as its own
    process);
  - a `for` loop over `seq`, a brace range or a written list of numbers that sleeps, which is the
    same tick count spelled another way;
  - the same two shapes in a python stand in the suite writes (`while ... time.time() - t0 < 60:`,
    `for _ in range(300):`, each with a `time.sleep` in its body).
A sleep is `sleep`, perl's `select(undef, undef, undef, ...)` or python's `time.sleep`.
A counted loop is a wait only when it can stop early (a `break`): one that sleeps every pass to the
end paces something (a server answering a byte at a time) and is not reported.
A loop that waits on a condition with no bound of its own is not reported: the suite's own deadline
(lib/suite-deadline.sh) bounds it. A comparison against a count the body does NOT advance (a count
of calls the code under test makes) is a condition, not a clock, and is not reported either.
A `window_wait` (lib/hang-wait.sh) is the other kind of wait, a window the PASSING case runs out,
so its length is the caller's and short; called to wait for something the passing case DOES meet, it
is the short ceiling this scan exists to stop (claude-config#1721). So it is reported unless the
suite asserts the window ran out: its status captured in the same statement (`window_wait 2 "<cond>";
NAME=$?`, the dollar escaped where it is written for another shell) and NAME compared with 1 on some
code line of the file (`[ "$NAME" = 1 ]`, `-eq 1`, `(( NAME == 1 ))`). A constant condition (`true`,
`false`, `:`) waits on nothing and is the helper's own test, so it is not reported. A suite that
compares the capture with 1 and then ignores the comparison is not caught: the scan reads shape, not
intent.
Comment lines are skipped. A stand in a suite writes through a heredoc is shell, and is where half
these waits lived (the fake claude's hold), so its lines are judged like the suite's own.

A BARE FIXED SLEEP (claude-config#1743) is the same fault with no loop around it: the suite pauses a
fixed time and then acts as though what it waited for has happened (`kill "$p"; sleep 2; check
gone`). Fourteen such lines in seven suites escaped the rules above on 2026-10-25. A `sleep` is
reported when it is a statement of the suite's own (at the start of a line, or after `;`, `&&`,
`||`, `then`, `else` or `{`) with a written number of seconds, that runs in the foreground and
carries on, unless:
  - it is a poll tick: the loop around it, found by reading back to the `do` no `done` closes, is a
    `while` or `until`, or a `for` over ticks, which the rules above judge;
  - it is a holder, put in the background (`sleep 300 &`) or made the process itself (`exec sleep`),
    which waits for nothing and is killed;
  - it is in a heredoc's body: a stand in the suite writes, where it is how long the fake takes (a
    slow lookup, a hang until killed), never a wait of the suite's.
A duration held in a variable (`sleep "$SUITE_POLL_INTERVAL"`) is a poll interval or a test seam's
pause named where it is set, and is not read here. No file or line is excused by name. A wait for something the passing case meets takes hang_wait; a
window the passing case runs out takes window_wait with its status asserted, as above.

Reads the paths to judge, relative to --root, one per line on stdin, and judges only the suite files
among them. Prints `<path>:<line>: <text>` for each, and exits 1 when there is any.
"""
import argparse
import os
import re
import io
import sys

sys.dont_write_bytecode = True
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from shell_code_lines import code_lines, heredoc_body_lines  # noqa: E402

SUITE = re.compile(r'(^|/)test-[^/]*\.sh$')
LOOP = re.compile(r'(?:^|[;&|({\s]|\\n)(while|until)\s+(.*?)\s*;\s*do\b(.*)$')
FOR = re.compile(r'(?:^|[;&|({\s]|\\n)for\s+\w+\s+in\s+(.*?)\s*;\s*do\b(.*)$')
CLOCK = re.compile(r'\bSECONDS\b|date\s+\+%s')
CMP = re.compile(r'\$\{?(\w+)\}?"?\s+-(?:lt|le|gt|ge)\s+("[^"]*"|\$\(\([^)]*\)\)|\$\{[^}]*\}|\S+)')
ARITH = re.compile(r'\(\(\s*(\w+)\s*(?:<|<=|>|>=)\s*([^)]+)\)\)')
SLEEP = re.compile(r'(?:^|[;&|({\s/])sleep\s|select\(\s*undef')
TICKS = re.compile(r'\bseq\b|\{\d+\.\.\d+\}|^\s*\d+(\s+\d+){2,}\s*$')
PY_CLOCK = re.compile(r'^(\s*)while\b.*\btime\.(?:time|monotonic)\(\)\s*-\s*\w+\s*<\s*([^:]+):')
PY_TICKS = re.compile(r'^(\s*)for\s+\w+\s+in\s+range\(([^)]*)\)\s*:')
PY_SLEEP = re.compile(r'\btime\.sleep\(')
# The window's length is a number, a variable or a printf slot: prose naming the helper in a check's
# description (`window_wait is accepted ...`) is not a call.
WW_CALL = re.compile(r'(?:^|[;&|({\s!]|\\n)window_wait\s+["\']?(?:\d+|\$\S+|%\w)\S*\s+(.*)$')
WW_CONST = re.compile(r'''^["']?(?:true|false|:)["']?(?=[\s;)"']|$)''')
WW_CAPTURE = re.compile(r'^[^;]*;\s*(?:local\s+)?(\w+)=\\?\$\?')
# A foreground sleep statement that carries on (#1743): after a statement boundary, ended by one,
# never by a lone `&`, so a holder in the background is not one.
BARE = re.compile(r'(?:^|;|&&|\|\||\bthen\b|\belse\b|\{)\s*sleep\s+(["\']?)\d+(?:\.\d+)?\1\s*(?=;|&&|\|\||\}|$)')
# The loop words read back from a sleep to the loop around it, if any.
# A word written inside a quoted fixture or a printf stand in (`'while ...`, `\nwhile`) counts.
LOOP_TOK = re.compile(r'(?:^|(?<=[;&|({\s\'"])|(?<=\\n))(?P<kw>while|until|for)(?=\s)'
                      r'|(?:^|(?<=[;&|\s])|(?<=\\n))(?P<do>do)(?=[\s;\\]|$)'
                      r'|(?:^|(?<=[;&|\s])|(?<=\\n))(?P<done>done)(?=[\s;)<>|&\\\'"]|$)')
BARE_SAID = ('   <- a fixed sleep: wait on the condition itself with hang_wait, or, for a window the '
             'passing case runs out, window_wait with its status asserted (lib/hang-wait.sh)')


def in_tick_loop(code, k, pos, body):
    """Whether the sleep at code[k] (a (line number, line) pair), column pos, is a poll tick: the loop
    around it, read back at most 60 code lines to the `do` no `done` closes, is a while or until loop,
    or a for loop over ticks. A heredoc's body between is a stand in's own and is not read."""
    toks = []
    for j in range(max(0, k - 60), k + 1):
        n, line = code[j]
        if n in body:
            continue
        text = line[:pos] if j == k else line
        for m in LOOP_TOK.finditer(text):
            toks.append((j, m))
    depth = 0
    for t in range(len(toks) - 1, -1, -1):
        j, m = toks[t]
        if m.group('done'):
            depth += 1
        elif m.group('do'):
            if depth:
                depth -= 1
                continue
            for u in range(t - 1, -1, -1):
                kw = toks[u][1].group('kw')
                if kw in ('while', 'until'):
                    return True
                if kw == 'for':
                    f = FOR.search(code[toks[u][0]][1])
                    return bool(f and TICKS.search(f.group(1)))
            return False
    return False


def ww_ran_out_asserted(name, code):
    """Whether the file's code compares the captured window_wait status NAME with 1 (#1721)."""
    v = re.escape(name)
    pat = r'\\?\$\{?%s\}?(?:\\?")?\s*(?:==?|-eq)\s*(?:\\?")?1(?!\d)|\(\(\s*\$?%s\s*==\s*1(?!\d)' % (v, v)
    return re.search(pat, code) is not None


def py_body(lines, i, indent):
    out = []
    for ln in lines[i + 1:i + 41]:
        if ln.strip() and len(ln) - len(ln.lstrip()) <= indent:
            break
        out.append(ln)
    return '\n'.join(out)


def advances(var, body):
    v = re.escape(var)
    return re.search(r'\b%s=\$\(\(\s*\$?%s\s*\+\s*\d+\s*\)\)|\(\(\s*%s\s*(\+\+|\+=)|\(\(\s*\+\+%s' % (v, v, v, v), body) is not None


def body_of(lines, i, rest):
    """The loop body: the rest of the line up to `done` for a one line loop, otherwise every line up
    to the `done` indented no deeper than the loop, at most 60 lines on."""
    if re.search(r'\bdone\b', rest):
        return rest
    indent = len(lines[i]) - len(lines[i].lstrip())
    out = [rest]
    for j in range(i + 1, min(len(lines), i + 61)):
        ln = lines[j]
        if re.match(r'\s*done\b', ln) and len(ln) - len(ln.lstrip()) <= indent:
            break
        out.append(ln)
    return '\n'.join(out)


def judge(text):
    lines = text.split('\n')
    found = []
    code = '\n'.join(ln for _, ln in code_lines(text))
    body = heredoc_body_lines(text)
    listed = list(code_lines(text))
    # A bare fixed sleep of the suite's own (#1743).
    for k, (n, line) in enumerate(listed):
        if n in body:
            continue
        for b in BARE.finditer(line):
            if not in_tick_loop(listed, k, b.start(), body):
                found.append((n, line.strip() + BARE_SAID))
                break
    # Only the suite's own code: a comment, or a line inside a quoted string spanning lines (another
    # hook's input written as a fixture), is never judged (lib/shell_code_lines.py).
    for n, line in code_lines(text):
        i = n - 1
        # A window_wait whose running out the suite never asserts (#1721).
        w = WW_CALL.search(line)
        if w and not WW_CONST.match(w.group(1)):
            cap = WW_CAPTURE.match(w.group(1))
            if not (cap and ww_ran_out_asserted(cap.group(1), code)):
                found.append((i + 1, line.strip()))
                continue
        m = LOOP.search(line)
        if m:
            cond, rest = m.group(2), m.group(3)
            body = body_of(lines, i, rest)
            if not SLEEP.search(body):
                continue
            hit = False
            if CLOCK.search(cond) and 'HANG' not in cond:
                hit = True
            for var, bound in CMP.findall(cond) + ARITH.findall(cond):
                if 'HANG' in bound:
                    continue
                if advances(var, body) or advances(var, cond):
                    hit = True
            if hit:
                found.append((i + 1, line.strip()))
            continue
        m = FOR.search(line)
        if m:
            seq, rest = m.group(1), m.group(2)
            body = body_of(lines, i, rest)
            if TICKS.search(seq) and SLEEP.search(body) and re.search(r'\bbreak\b', body):
                found.append((i + 1, line.strip()))
            continue
        m = PY_CLOCK.match(line) or PY_TICKS.match(line)
        body = py_body(lines, i, len(m.group(1))) if m else ''
        if m and 'HANG' not in m.group(2) and PY_SLEEP.search(body) and (m.re is PY_CLOCK or re.search(r'\b(break|return)\b', body)):
            found.append((i + 1, line.strip()))
    return sorted(found)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--root', required=True)
    args = ap.parse_args()
    any_found = False
    for rel in io.TextIOWrapper(sys.stdin.buffer, encoding="utf-8", errors="replace").read().split('\n'):
        rel = rel.strip()
        if not rel or not SUITE.search(rel):
            continue
        path = os.path.join(args.root, rel)
        try:
            with open(path, encoding='utf-8', errors='replace') as fh:
                text = fh.read()
        except OSError:
            continue
        for n, t in judge(text):
            any_found = True
            print('%s:%d: %s' % (rel, n, t))
    return 1 if any_found else 0


if __name__ == '__main__':
    sys.exit(main())
