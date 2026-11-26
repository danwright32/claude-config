#!/usr/bin/env python3
"""Which processes did an agent's commands leave running? (claude-config#3561)

Read by agent-leftovers-gate.sh at an agent's hand back and at its stop. It reports; it never
stops anything (a process is stopped by whoever started it, by the process id traced to it, L1011).

THE TIE, each step measured on the personal MacBook on 2026-11-25 (bash-shell-mark.sh has the
measurements):

  1. Every shell the Bash tool starts in a session leaves an empty file named for its process id
     in that session's marker folder (bash-shell-mark.sh's line). The shell leads its own process
     group, so that number is the group's id.
  2. A process is a leftover of THIS SESSION when its group's leader has gone, a marker for that
     group is in this session's folder, and no process in the group started before the marker was
     made. Another session's shell left its marker in another folder, so its children are never
     listed here, whatever second they started in.
  3. It is THIS AGENT'S when the marker was made while one of the agent's own Bash calls was
     running (the agent's transcript gives each call's start and end), and the group's oldest
     process started before that call ended. The second half is what stops a process id used
     again from being taken for the shell that had it before: a group whose oldest process started
     after the call ended is said as one that could not be told, never as the agent's.

WHAT IT COSTS. One narrow read of the process table (ps -axo pid=,ppid=,pgid=) and one stat per
group whose leader has gone; on 2026-11-25 that table held 1,017 rows and 8 such groups, and the
read took 21 to 30 ms (median 23 ms, 7 runs, load average 13.7) beside 23 to 37 ms for python to
start. Start times, commands and the transcript are read only once a group is tied to the session,
which on a healthy day is never. Each ps is killed at PS_SECONDS.

WHAT IT CANNOT TELL, and says so rather than say nothing was left:
  - the process table cannot be read (ps fails or times out, as it does inside a sandbox);
  - the session's shells are not recorded (it started before bash-shell-mark.sh was installed);
  - the agent's transcript cannot be read (a nested agent's is never written);
  - a process that left its shell's group (setsid, a job control shell, a runner that makes a
    group of its own, until that runner records its group the same way: bash-shell-mark.sh).

usage: agent-leftovers.py gate    hook payload on stdin; prints action, text and note, each
                                  separated by the byte 0x1f: refuse | notice | none
       agent-leftovers.py dir <session id>    prints that session's marker folder
"""
import json
import os
import re
import subprocess
import sys
import time

PS_SECONDS = 5
MAX_REFUSALS = 2
SLACK = 2.0          # seconds either side of a call: a start time is whole seconds
PLAIN = re.compile(r'\A[A-Za-z0-9_-]{1,64}\Z')  # \Z, never $: $ also matches before a final line break
ISSUE = 'claude-config#3561'


def marks_root():
    """The folder holding every session's marker folder. bash-shell-mark.sh derives the same path
    in bash, and test-agent-leftovers.sh holds the two to one answer. Under a test suite it is never
    this Mac's real record: a suite that names no folder of its own gets one named for its run."""
    root = os.environ.get('AGENT_LEFTOVERS_ROOT')
    if not root:
        name = 'claude-shell-marks-%d' % os.getuid()
        run = re.sub(r'[^A-Za-z0-9_-]', '', os.environ.get('CLAUDE_SUITE_RUN_ID') or '')
        root = os.path.join((os.environ.get('TMPDIR') or '/tmp').rstrip('/'), name + ('-suite-' + run if run else ''))
    return root.rstrip('/')


def state_root():
    """Where the gate keeps what it has already said and how often it refused an agent: this Mac's
    own state folder, which is never synced, and never the marker folders, which only a session's
    own shells write. One empty file per session it could not read and one small file per agent
    that left something, so there is nothing to sweep."""
    return os.path.join(os.path.expanduser('~'), '.claude', 'state', 'agent-leftovers')


def now():
    try:
        return float(os.environ['AGENT_LEFTOVERS_NOW'])
    except (KeyError, ValueError):
        return time.time()


class Unread(Exception):
    """The process table could not be read."""


def run_ps(args, none_is_empty=False):
    try:
        # A command line can hold any byte, so one that is not UTF-8 is replaced rather than
        # raising, which would turn a readable process table into "could not be read".
        r = subprocess.run(['ps'] + args, capture_output=True, text=True, errors='replace',
                           timeout=PS_SECONDS, env=dict(os.environ, LC_ALL='C'))
    except subprocess.TimeoutExpired:
        raise Unread('ps did not answer within %d seconds' % PS_SECONDS)
    except OSError as e:
        raise Unread('ps could not be started (%s)' % e)
    if none_is_empty and r.returncode == 1 and not r.stdout.strip() and not r.stderr.strip():
        return ''  # macOS ps exits 1 and prints nothing when none of the processes asked for is left
    if r.returncode != 0 and not r.stdout.strip():
        raise Unread('ps exited %d%s' % (r.returncode, ': ' + r.stderr.strip()[:200] if r.stderr.strip() else ''))
    return r.stdout


def parse_started(words):
    """`Wed Nov 25 10:18:10 2026` as ps prints lstart under LC_ALL=C, to seconds."""
    try:
        return time.mktime(time.strptime(' '.join(words), '%a %b %d %H:%M:%S %Y'))
    except ValueError:
        return None


def read_table():
    """[(pid, ppid, pgid)], and a function giving {pid: (started, command)} for chosen pids.

    AGENT_LEFTOVERS_PS names a file standing in for the table, in the shape
    `ps -axo pid=,ppid=,pgid=,lstart=,command=` prints: a suite never starts a real stray."""
    stand_in = os.environ.get('AGENT_LEFTOVERS_PS')
    full = {}
    if stand_in is not None:
        try:
            with open(stand_in, encoding='utf-8', errors='replace') as f:
                text = f.read()
        except OSError as e:
            raise Unread('the process table could not be read (%s)' % e.strerror)
        rows = []
        for line in text.splitlines():
            w = line.split()
            if len(w) >= 8 and all(x.isdigit() for x in w[:3]):
                rows.append((int(w[0]), int(w[1]), int(w[2])))
                full[int(w[0])] = (parse_started(w[3:8]), ' '.join(w[8:]))
        detail = lambda pids: {p: full[p] for p in pids if p in full}
    else:
        rows = []
        for line in run_ps(['-axo', 'pid=,ppid=,pgid=']).splitlines():
            w = line.split()
            if len(w) == 3 and all(x.isdigit() for x in w):
                rows.append((int(w[0]), int(w[1]), int(w[2])))

        def detail(pids):
            out = {}
            text = run_ps(['-o', 'pid=,lstart=,command=', '-p', ','.join(str(p) for p in pids)], none_is_empty=True)
            for line in text.splitlines():
                w = line.split()
                if len(w) >= 6 and w[0].isdigit():
                    out[int(w[0])] = (parse_started(w[1:6]), ' '.join(w[6:]))
            return out
    if not rows:
        raise Unread('the process table held no row that could be read')
    return rows, detail


def bash_calls(path):
    """The agent's own Bash calls: [{'began', 'ended' or None, 'command'}], or None if unreadable."""
    def stamp(s):
        m = re.match(r'^(\d{4})-(\d\d)-(\d\d)T(\d\d):(\d\d):(\d\d)(\.\d+)?Z$', s or '')
        if not m:
            return None
        import calendar
        return calendar.timegm(tuple(int(x) for x in m.groups()[:6]) + (0, 0, 0)) + float(m.group(7) or 0)
    calls = {}
    try:
        with open(path, encoding='utf-8', errors='replace') as f:
            for line in f:
                if '"tool_use' not in line and '"tool_result"' not in line:
                    continue
                try:
                    o = json.loads(line)
                except ValueError:
                    continue
                if not isinstance(o, dict) or not isinstance(o.get('message'), dict):
                    continue
                content = o['message'].get('content')
                at = stamp(o.get('timestamp'))
                if not isinstance(content, list) or at is None:
                    continue
                for b in content:
                    if not isinstance(b, dict):
                        continue
                    if b.get('type') == 'tool_use' and b.get('name') == 'Bash' and isinstance(b.get('id'), str):
                        inp = b.get('input') if isinstance(b.get('input'), dict) else {}
                        calls[b['id']] = {'began': at, 'ended': None, 'command': str(inp.get('command') or '')}
                    elif b.get('type') == 'tool_result' and b.get('tool_use_id') in calls:
                        calls[b['tool_use_id']]['ended'] = at
    except OSError:
        return None
    return list(calls.values())


def et(t):
    try:
        from datetime import datetime
        from zoneinfo import ZoneInfo
        d = datetime.fromtimestamp(t, ZoneInfo('America/New_York'))
        return '%d:%02d:%02d %s ET on %s' % ((d.hour % 12) or 12, d.minute, d.second, 'AM' if d.hour < 12 else 'PM', d.strftime('%Y-%m-%d'))
    except Exception:
        return time.strftime('%H:%M:%S UTC on %Y-%m-%d', time.gmtime(t))


def short(s, n):
    s = ' '.join(str(s).split())
    return s if len(s) <= n else s[:n - 3] + '...'


def survey(session, transcript):
    """What the stopping agent left. Returns a dict:

    state     'ok', or why nothing could be told: 'unread', 'unrecorded', 'no-transcript'
    why       the reason in words, for a state other than 'ok'
    mine      [{pid, pgid, started, command, call, others}]  the agent's own leftovers
    unsure    [{pid, pgid, started, command}]  tied to the session, whose agent could not be told
    """
    out = {'state': 'ok', 'why': '', 'mine': [], 'unsure': []}
    try:
        rows, detail = read_table()
    except Unread as e:
        return dict(out, state='unread', why=str(e))
    folder = os.path.join(marks_root(), session)
    if not os.path.isdir(folder):
        return dict(out, state='unrecorded', why='its marker folder %s is not there' % folder)
    alive = {pid for pid, _, _ in rows}
    groups = {}
    for pid, _, pgid in rows:
        if pgid > 1 and pgid not in alive:
            groups.setdefault(pgid, []).append(pid)
    tied = {}
    for pgid in groups:
        try:
            tied[pgid] = os.stat(os.path.join(folder, str(pgid))).st_mtime
        except OSError:
            continue
    if not tied:
        return out
    try:
        facts = detail([p for g in tied for p in groups[g]])
    except Unread as e:
        return dict(out, state='unread', why=str(e))
    calls = bash_calls(transcript) if transcript else None
    at = now()
    marks = None
    for pgid, made in sorted(tied.items()):
        members = [(p,) + facts[p] for p in groups[pgid] if p in facts and facts[p][0] is not None]
        if not members:
            continue  # they ended between the two reads
        oldest = min(m[1] for m in members)
        if oldest < made - SLACK:
            continue  # older than the shell that made the marker: not that shell's
        rows_out = [{'pid': p, 'pgid': pgid, 'started': s, 'command': c} for p, s, c in sorted(members)]
        if calls is None:
            out['unsure'] += rows_out
            out['state'], out['why'] = 'no-transcript', 'the transcript of the agent (%s) could not be read' % (transcript or 'none named')
            continue
        call = next((c for c in calls if c['began'] - SLACK <= made <= (c['ended'] if c['ended'] is not None else at) + SLACK), None)
        if call is None:
            continue  # another agent's command, or this conversation's own
        ended = call['ended'] if call['ended'] is not None else at
        if oldest > ended + SLACK:
            out['unsure'] += rows_out
            continue
        if marks is None:
            try:
                marks = [e.stat().st_mtime for e in os.scandir(folder) if e.name.isdigit()]
            except OSError:
                marks = []
        others = max(0, sum(1 for m in marks if call['began'] - SLACK <= m <= ended + SLACK) - 1)
        for r in rows_out:
            out['mine'].append(dict(r, call=call, others=others))
    return out


def line_of(p):
    return 'pid %d, started %s: %s' % (p['pid'], et(p['started']), short(p['command'], 160))


def key(p):
    """What a process is settled by: its id AND its start, since an id is given out again, and a
    later process given a settled one's number has been neither named nor said."""
    return '%d@%d' % (p['pid'], int(p['started']))


def load_state(path):
    try:
        # Strict: a state file holding a byte that is not UTF-8 is not this reader's, and the
        # UnicodeDecodeError it raises is a ValueError, so it reads as no state at all.
        with open(path, encoding='utf-8', errors='strict') as f:
            s = json.load(f)
        if isinstance(s, dict):
            return {'refusals': int(s.get('refusals') or 0), 'settled': [str(x) for x in s.get('settled') or []]}
    except (OSError, ValueError, TypeError):
        pass
    return {'refusals': 0, 'settled': []}


def save_state(path, state):
    """True when kept. A state that cannot be kept must never turn into a refusal for ever."""
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        tmp = '%s.%d' % (path, os.getpid())
        # Strict: json.dump escapes everything outside ASCII, so nothing here can fail to encode.
        with open(tmp, 'w', encoding='utf-8', errors='strict') as f:
            json.dump(state, f)
        os.replace(tmp, path)
        return True
    except OSError:
        return False


def once(path):
    """True the first time: an exclusive create, so two hand backs at once say it once."""
    try:
        os.makedirs(os.path.dirname(path), mode=0o700, exist_ok=True)
        os.close(os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600))
        return True
    except FileExistsError:
        return False
    except OSError:
        return True  # it cannot be remembered, so it is said: twice is better than never


def gate(payload):
    agent = payload.get('agent_id')
    session = payload.get('session_id')
    if not isinstance(agent, str) or not agent:
        return 'none', '', ''
    event = payload.get('hook_event_name')
    handback = event == 'PreToolUse' and payload.get('tool_name') == 'SubagentHandback'
    if not handback and event != 'SubagentStop':
        return 'none', '', ''
    if not isinstance(session, str) or not PLAIN.match(session) or not PLAIN.match(agent):
        return 'notice', ('LEFTOVER PROCESS CHECK DID NOT RUN: the hook payload names no session or agent this check can read '
                          '(session %r, agent %r), so what the agent left running could not be told (%s).' % (session, agent, ISSUE)), ''
    transcript = payload.get('agent_transcript_path') or ''
    if not transcript and isinstance(payload.get('transcript_path'), str) and payload['transcript_path'].endswith('.jsonl'):
        transcript = '%s/subagents/agent-%s.jsonl' % (payload['transcript_path'][:-6], agent)
    found = survey(session, transcript)
    root = state_root()
    said_dir = os.path.join(root, 'said')
    state_path = os.path.join(root, 'agents', '%s.%s.json' % (session, agent))
    notes = []    # said to Dan: what the check could not tell
    acts = []     # said to Dan and spooled for the orchestrating session: what somebody has to act on

    if found['state'] == 'unread':
        if once(os.path.join(said_dir, '%s.unread' % session)):
            notes.append('LEFTOVER PROCESS CHECK COULD NOT TELL what agent %s left running: %s. This is said once a session; '
                         'every later agent of this session whose check fails the same way goes unchecked too (%s).' % (agent, found['why'], ISSUE))
    elif found['state'] == 'unrecorded':
        if once(os.path.join(said_dir, '%s.unrecorded' % session)):
            notes.append('LEFTOVER PROCESS CHECK COULD NOT TELL what agent %s left running: this session\'s Bash commands are not recorded (%s), '
                         'which is so for a session that started before hooks/bash-shell-mark.sh was installed. This is said once a session; '
                         'a new session records them (%s).' % (agent, found['why'], ISSUE))

    state = load_state(state_path)
    settled = set(state['settled'])
    unsure = [p for p in found['unsure'] if key(p) not in settled]
    mine = [p for p in found['mine'] if key(p) not in settled]
    if unsure:
        whose = ('the transcript of agent %s could not be read, so whether its commands started them could not be told' % agent
                 if found['state'] == 'no-transcript' else
                 'each is in the process group of a shell agent %s\'s command ran in, but started after that command ended, '
                 'so whether it is that command\'s or a later process given the same number could not be told' % agent)
        acts.append('LEFTOVER PROCESS CHECK: %d process%s started by a Bash command of this session %s still running, and %s: %s. '
                     'Nothing was stopped (%s).' % (len(unsure), '' if len(unsure) == 1 else 'es', 'is' if len(unsure) == 1 else 'are',
                                                     whose, '; '.join(line_of(p) for p in unsure), ISSUE))

    action, text = 'none', ''
    if mine:
        tool_input = payload.get('tool_input') if isinstance(payload.get('tool_input'), dict) else {}
        report = str(tool_input.get('message') or '') if handback else ''
        named = {key(p) for p in mine if re.search(r'(?<![0-9])%d(?![0-9])' % p['pid'], report)}
        unnamed = [p for p in mine if key(p) not in named]
        settled |= named
        if handback and unnamed and state['refusals'] < MAX_REFUSALS:
            state['refusals'] += 1
            lines = []
            for p in unnamed:
                lines.append('  %s' % line_of(p))
                lines.append('    from your Bash command begun %s: %s' % (et(p['call']['began']), short(p['call']['command'], 120)))
                if p['others']:
                    lines.append('    (%d other command%s of this session began in that same span, so check it is yours first: '
                                 'a process another agent started is not yours to stop)' % (p['others'], '' if p['others'] == 1 else 's'))
            text = ('REFUSED (agent-leftovers-gate.sh): %d process%s your commands started %s still running.\n%s\n'
                    'Stop each one you do not need by its process id (kill %d, then ps -p %d to see it has gone), or keep it and '
                    'name its process id in your report with why it stays. Then hand back again. Nothing was stopped for you, and '
                    'a report that still names none of them is let through on attempt %d and said to Dan (%s).'
                    % (len(unnamed), '' if len(unnamed) == 1 else 'es', 'is' if len(unnamed) == 1 else 'are', '\n'.join(lines),
                       unnamed[0]['pid'], unnamed[0]['pid'], MAX_REFUSALS + 1, ISSUE))
            action = 'refuse'
        elif unnamed:
            acts.append('LEFTOVER PROCESS CHECK: agent %s left %d process%s its commands started still running: %s. '
                         'Nothing was stopped. Stop each with kill and its process id once you have checked it is not needed (%s).'
                         % (agent, len(unnamed), '' if len(unnamed) == 1 else 'es', '; '.join(line_of(p) for p in unnamed), ISSUE))
            settled |= {key(p) for p in unnamed}
    if action != 'refuse':
        # A refusal carries only the agent's own processes and the notice is not shown, so what
        # could not be told stays unsettled until a pass that does say it.
        settled |= {key(p) for p in unsure}

    if action == 'refuse' or settled != set(state['settled']):
        state['settled'] = sorted(settled)
        if not save_state(state_path, state) and action == 'refuse':
            # The count cannot be kept, so a refusal now would be a refusal at every attempt.
            action, text = 'none', ''
            acts.append('LEFTOVER PROCESS CHECK: agent %s left %d process%s its commands started still running (%s), and the check '
                         'could not keep count of its refusals under %s, so the hand back was let through. Nothing was stopped (%s).'
                         % (agent, len(mine), '' if len(mine) == 1 else 'es', '; '.join(line_of(p) for p in mine), root, ISSUE))
    if action == 'refuse':
        return action, text, ''
    if notes or acts:
        return 'notice', ' '.join(acts + notes), ' '.join(acts)
    return 'none', '', ''


def main(argv):
    # A payload can carry an escaped lone surrogate that survives the parse into the answer's
    # text, and writing it out strictly would raise and lose the whole answer.
    sys.stdout.reconfigure(errors='replace')
    if len(argv) == 3 and argv[1] == 'dir' and PLAIN.match(argv[2]):
        print(os.path.join(marks_root(), argv[2]))
        return 0
    if len(argv) == 2 and argv[1] == 'gate':
        try:
            payload = json.loads(sys.stdin.buffer.read().decode('utf-8', 'replace'))
        except ValueError:
            return 3
        if not isinstance(payload, dict):
            return 3
        action, text, note = gate(payload)
        sys.stdout.write('\x1f'.join([action, text, note]))
        return 0
    sys.stderr.write(__doc__)
    return 64


if __name__ == '__main__':
    sys.exit(main(sys.argv))
