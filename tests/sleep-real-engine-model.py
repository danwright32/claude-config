#!/usr/bin/env python3
"""A scripted stand-in for the model behind tests/test-sleep-real-engine.sh (claude-config#838).

Claude Code, the mods and the shell tools in that suite are the real ones; only the model's answers
come from here, so the night runs the same way every time, costs nothing, and never depends on how
much of this week's usage the account has left (the real account read 100 percent weekly on
2026-10-07, which stops every overnight worker at its first Stop, as the driver should).

    sleep-real-engine-model.py PORT_FILE LOG_FILE

Listens on 127.0.0.1 on a free port, writes the port to PORT_FILE, and logs every request it is
sent to LOG_FILE as one JSON line. It answers the Messages API as Claude Code calls it (streamed or
not) and nothing else of substance: count_tokens gets a count, anything else an empty object.

The answer is derived from the conversation it is sent, never from state kept here, so a retried
request gets the same answer. A request with no Bash tool (a side call: a title, a summary) gets a
one word text answer. Otherwise the first user message names the script:

  BAN-STEP     runs the force push to a scratch branch, then the push to main, then answers.
  PERMISSION-STEP  runs a command a settings PermissionRequest hook denies, then one it does not.
  WORKER-STEP  answers "ready" until the overnight rules arrive in a Stop block, then works the
               night from the commands those rules name: claim with `next`, commit and push in
               the claim's worktree, propose an issue, release the claim done, claim again (none
               left), write the stopped note, and end.
  anything else (the morning turn after /wake) gets a short text answer.
"""
import json
import re
import shlex
import sys
import threading
import uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOCK = threading.Lock()


def texts_of(content):
    if isinstance(content, str):
        return [content]
    out = []
    for c in content or []:
        if not isinstance(c, dict):
            continue
        if c.get('type') == 'text':
            out.append(c.get('text', ''))
        elif c.get('type') == 'tool_result':
            body = c.get('content')
            out.extend(texts_of(body) if not isinstance(body, str) else [body])
    return out


def all_text(messages, role=None):
    return '\n'.join(t for m in messages if role is None or m.get('role') == role for t in texts_of(m.get('content')))


def tool_uses(messages):
    """Every Bash command this conversation has already run, in order, with its result text."""
    uses, results = [], {}
    for m in messages:
        for c in m.get('content') or [] if isinstance(m.get('content'), list) else []:
            if not isinstance(c, dict):
                continue
            if c.get('type') == 'tool_use':
                uses.append((c.get('id'), (c.get('input') or {}).get('command', '')))
            elif c.get('type') == 'tool_result':
                body = c.get('content')
                results[c.get('tool_use_id')] = body if isinstance(body, str) else '\n'.join(texts_of(body))
    return [(cmd, results.get(i, '')) for i, cmd in uses]


def text(t):
    return {'kind': 'text', 'text': t}


def bash(cmd):
    return {'kind': 'tool', 'command': cmd}


def note_cmd(line):
    """sleep_note run the way the rules name it, sourced from sleep.sh in bash whatever the shell."""
    return "bash -c '. ~/.claude/hooks/lib/sleep.sh && sleep_note \"$1\"' _ " + shlex.quote(line)


def first_user(messages):
    for m in messages:
        if m.get('role') == 'user':
            return '\n'.join(texts_of(m.get('content')))
    return ''


def ban_step(messages, ran):
    steps = ['git push --force origin HEAD:refs/heads/scratch-forced', 'git push origin HEAD:main']
    if len(ran) < len(steps):
        return bash(steps[len(ran)])
    return text('Both pushes were refused.')


def permission_step(messages, ran):
    steps = ['touch denied-by-settings.txt', 'touch allowed-overnight.txt']
    if len(ran) < len(steps):
        return bash(steps[len(ran)])
    return text('Done.')


def worker_step(messages, ran):
    convo = all_text(messages)
    m = re.search(r'`(bash ~/\.claude/hooks/lib/sleep-queue\.sh next [^`]+)`', convo)
    if not m:
        return text('ready')
    claim_cmd = m.group(1)
    rel = re.search(r'`(bash ~/\.claude/hooks/lib/sleep-queue\.sh release \S+) <issue> (\S+) done\|parked\|failed "<why>"`', convo)
    stopped = re.search(r"`sleep_note '(\{\"kind\":\"stopped\"[^`']+)'`", convo)
    cmds = [c for c, _ in ran]
    if claim_cmd not in cmds:
        return bash(claim_cmd)
    claimed = next((r for c, r in ran if c == claim_cmd), '')
    wt = re.search(r'worktree=(\S.*?)\t', claimed + '\t')
    issue = re.search(r'^claimed\t(\d+)', claimed, re.M)
    if not (wt and issue):
        return text('The claim did not print a worktree, so there is nothing to work on.')
    wtp = wt.group(1).strip()
    work = f'cd {shlex.quote(wtp)} && printf "hi\\n" > hello.txt && git add hello.txt && git commit -q -m "Add hello.txt (#{issue.group(1)})" && git push -q origin HEAD'
    propose = note_cmd(json.dumps({'kind': 'issue', 'repo': 'danwright32/sleepdemo', 'title': 'Add goodbye.txt', 'priority': 'p3',
                                   'labels': ['test'], 'milestone': 'Ungrouped', 'text': 'A follow up the night noticed.'}))
    release = f'{rel.group(1)} {issue.group(1)} {rel.group(2)} done "hello.txt is on its branch"' if rel else ''
    plan = [work, propose] + ([release] if release else [])
    for step in plan:
        if step not in cmds:
            return bash(step)
    # Claim again once the first is released: the queue has nothing left.
    if cmds.count(claim_cmd) < 2:
        return bash(claim_cmd)
    if stopped:
        note = note_cmd(stopped.group(1))
        if note not in cmds:
            return bash(note)
    return text('Nothing left to claim tonight; stopping.')


def answer(body):
    messages = body.get('messages') or []
    tools = [t.get('name') for t in body.get('tools') or [] if isinstance(t, dict)]
    if 'Bash' not in tools:
        return text('ok')
    first = first_user(messages)
    ran = tool_uses(messages)
    if 'BAN-STEP' in first:
        return ban_step(messages, ran)
    if 'PERMISSION-STEP' in first:
        return permission_step(messages, ran)
    if 'WORKER-STEP' in first:
        return worker_step(messages, ran)
    return text('Good morning: nothing to add here.')


def sse(handler, event, data):
    handler.wfile.write(f'event: {event}\ndata: {json.dumps(data)}\n\n'.encode())


class Handler(BaseHTTPRequestHandler):
    protocol_version = 'HTTP/1.1'

    def log_message(self, *args):
        pass

    def _json(self, code, obj):
        raw = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header('content-type', 'application/json')
        self.send_header('content-length', str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        with LOCK, open(self.server.log_path, 'a') as log:
            log.write(json.dumps({'method': 'GET', 'path': self.path}) + '\n')
        self._json(200, {'data': []})

    def do_POST(self):
        n = int(self.headers.get('content-length') or 0)
        raw = self.rfile.read(n) if n else b''
        try:
            body = json.loads(raw or b'{}')
        except ValueError:
            body = {}
        path = self.path.split('?')[0]
        if not path.endswith('/v1/messages'):
            with LOCK, open(self.server.log_path, 'a') as log:
                log.write(json.dumps({'method': 'POST', 'path': self.path}) + '\n')
            if path.endswith('/count_tokens'):
                return self._json(200, {'input_tokens': 100})
            return self._json(200, {})
        a = answer(body)
        with LOCK, open(self.server.log_path, 'a') as log:
            log.write(json.dumps({'method': 'POST', 'path': self.path, 'first': first_user(body.get('messages') or [])[:80],
                                  'tools': len(body.get('tools') or []), 'answer': a}) + '\n')
        mid = 'msg_' + uuid.uuid4().hex[:20]
        if a['kind'] == 'text':
            block = {'type': 'text', 'text': a['text']}
            stop = 'end_turn'
        else:
            block = {'type': 'tool_use', 'id': 'toolu_' + uuid.uuid4().hex[:20], 'name': 'Bash',
                     'input': {'command': a['command'], 'description': 'Overnight step'}}
            stop = 'tool_use'
        usage = {'input_tokens': 10, 'output_tokens': 5, 'cache_creation_input_tokens': 0, 'cache_read_input_tokens': 0}
        model = body.get('model') or 'claude-haiku-4-5'
        if not body.get('stream'):
            return self._json(200, {'id': mid, 'type': 'message', 'role': 'assistant', 'model': model, 'content': [block],
                                    'stop_reason': stop, 'stop_sequence': None, 'usage': usage})
        self.send_response(200)
        self.send_header('content-type', 'text/event-stream')
        self.send_header('cache-control', 'no-cache')
        self.send_header('connection', 'close')
        self.end_headers()
        sse(self, 'message_start', {'type': 'message_start', 'message': {'id': mid, 'type': 'message', 'role': 'assistant', 'model': model,
                                                                          'content': [], 'stop_reason': None, 'stop_sequence': None, 'usage': usage}})
        if block['type'] == 'text':
            sse(self, 'content_block_start', {'type': 'content_block_start', 'index': 0, 'content_block': {'type': 'text', 'text': ''}})
            sse(self, 'content_block_delta', {'type': 'content_block_delta', 'index': 0, 'delta': {'type': 'text_delta', 'text': block['text']}})
        else:
            sse(self, 'content_block_start', {'type': 'content_block_start', 'index': 0,
                                              'content_block': {'type': 'tool_use', 'id': block['id'], 'name': 'Bash', 'input': {}}})
            sse(self, 'content_block_delta', {'type': 'content_block_delta', 'index': 0,
                                              'delta': {'type': 'input_json_delta', 'partial_json': json.dumps(block['input'])}})
        sse(self, 'content_block_stop', {'type': 'content_block_stop', 'index': 0})
        sse(self, 'message_delta', {'type': 'message_delta', 'delta': {'stop_reason': stop, 'stop_sequence': None}, 'usage': {'output_tokens': 5}})
        sse(self, 'message_stop', {'type': 'message_stop'})
        self.wfile.flush()
        self.close_connection = True


def main(argv):
    port_file, log_path = argv
    srv = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
    srv.log_path = log_path
    with open(port_file + '.tmp', 'w') as f:
        f.write(str(srv.server_address[1]))
    import os
    os.replace(port_file + '.tmp', port_file)
    srv.serve_forever()


if __name__ == '__main__':
    main(sys.argv[1:])
