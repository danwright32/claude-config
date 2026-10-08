#!/usr/bin/env python3
"""Drives one headless Claude Code session for tests/test-sleep-real-engine.sh (claude-config#838).

The session is `claude -p` with stream-json in and out, its input held open so that a turn a plugin
starts by itself (sleep mode's morning turn, started with `$.prompt.submit` once /wake is done) can
still run, which a plain `claude -p "<prompt>"` would have exited before (#839, item 2).

    sleep-real-engine-session.py OUT DEADLINE_S RESULTS MESSAGE... -- CLAUDE_ARGV...

Each MESSAGE is sent as a user message once the turn before it has ended (a `result` line), and
after the last one the input stays open until RESULTS results in all have been seen, then closes.
Every line the session prints goes to OUT as it arrives. A session still running at DEADLINE_S is
stopped, its whole process group with it, and the summary says so (L110). The summary is one JSON
line on stdout: the results seen, the texts of their `result` lines, the summed cost, the exit
status and whether the deadline stopped it.
"""
import json
import os
import selectors
import signal
import subprocess
import sys
import time


def main(argv):
    if '--' not in argv:
        print('usage: OUT DEADLINE_S RESULTS MESSAGE... -- CLAUDE_ARGV...', file=sys.stderr)
        return 2
    cut = argv.index('--')
    head, cmd = argv[:cut], argv[cut + 1:]
    out_path, deadline_s, want = head[0], float(head[1]), int(head[2])
    messages = head[3:]
    proc = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True)
    sel = selectors.DefaultSelector()
    sel.register(proc.stdout, selectors.EVENT_READ)
    end = time.monotonic() + deadline_s
    results, texts, cost = 0, [], 0.0
    sent = 0
    buf = b''
    timed_out = False
    input_error = ''

    # A session that has stopped reading (it exited at start, or crashed) is said in the summary,
    # and its output is still read to the end, never a traceback with no summary.
    def send(text):
        nonlocal input_error
        if input_error:
            return
        line = json.dumps({'type': 'user', 'message': {'role': 'user', 'content': text}}) + '\n'
        try:
            proc.stdin.write(line.encode())
            proc.stdin.flush()
        except (BrokenPipeError, ValueError) as err:
            input_error = f'the session stopped reading its input before message {sent + 1} was sent ({err})'

    def close_input():
        if not proc.stdin.closed:
            try:
                proc.stdin.close()
            except BrokenPipeError:
                pass

    # One line the session printed: a result is counted, and the next message sent once it lands.
    def take(line):
        nonlocal results, cost, sent
        try:
            msg = json.loads(line)
        except ValueError:
            return
        if not isinstance(msg, dict) or msg.get('type') != 'result':
            return
        results += 1
        texts.append(msg.get('result'))
        cost += float(msg.get('total_cost_usd') or 0)
        if sent < len(messages):
            send(messages[sent])
            sent += 1
        elif results >= want:
            close_input()

    with open(out_path, 'ab') as out:
        if messages:
            send(messages[0])
            sent = 1
        else:
            close_input()
        eof = False
        while not eof:
            left = end - time.monotonic()
            if left <= 0:
                timed_out = True
                break
            for _key, _ in sel.select(timeout=min(left, 1.0)):
                chunk = os.read(proc.stdout.fileno(), 65536)
                if not chunk:
                    eof = True
                    break
                out.write(chunk)
                out.flush()
                buf += chunk
                while b'\n' in buf:
                    line, buf = buf.split(b'\n', 1)
                    take(line)
        # The last line counts even when the session ended it without a newline.
        if eof and buf.strip():
            take(buf)
            buf = b''
    if timed_out:
        close_input()
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
    else:
        try:
            proc.wait(timeout=max(1.0, end - time.monotonic()))
        except subprocess.TimeoutExpired:
            timed_out = True
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            proc.wait()
    summary = {'results': results, 'texts': texts, 'cost_usd': round(cost, 4), 'exit': proc.returncode, 'timed_out': timed_out}
    if input_error:
        summary['input_error'] = input_error
    print(json.dumps(summary))
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
