import { describe, expect, test } from 'claude-code/testing'
import { assess, harnessFinished, holdRefusal, inFlight, listedStatuses, isErrorLine, isPollLoop, leftoverLine, notifiedTasks, parseVerdict, runFor, shortCommand, shortLine, startedJob, startedTask } from '../hooks/jobs.ts'

const MIN = 60_000

describe('a background job, from what starting it said', () => {
  const STARTED_TEXT = 'Command running in background with ID: btv0drbh3. Output is being written to: /private/tmp/x/tasks/btv0drbh3.output. You will be notified when it completes.'
  const MOVED_TEXT =
    'Command did not complete within its 120s timeout and was moved to the background (ID: b8wxdk1kr). Output is being written to: /private/tmp/x/tasks/b8wxdk1kr.output. You will be notified when it completes. To check interim output, use Read on that file path.'
  test('its id and output file are read from the tool result', () => {
    expect(startedJob(STARTED_TEXT, { inBackground: true })).toEqual({ id: 'btv0drbh3', outputPath: '/private/tmp/x/tasks/btv0drbh3.output' })
  })
  test('a result that did not start one is not a job', () => {
    expect(startedJob('ok', { inBackground: true })).toBeUndefined()
    expect(startedJob('ok', { inBackground: false })).toBeUndefined()
  })
  // #706: a foreground command Claude Code moves to the background at its timeout is a job too. The
  // text is this build's own, seen in a session on 2026-10-04.
  test('a command moved to the background at its timeout is read the same way', () => {
    expect(startedJob(MOVED_TEXT, { inBackground: false })).toEqual({ id: 'b8wxdk1kr', outputPath: '/private/tmp/x/tasks/b8wxdk1kr.output' })
  })
  // The lessons review of #721: a foreground command whose own output quotes either text (a cat of
  // a test file, a grep of this mod) started nothing. Only Claude Code's own result, opening with its
  // own words, is a job moved there; a background start is known by the call that asked for one.
  test('a foreground command whose output quotes a start started nothing', () => {
    expect(startedJob(`line 1\n${STARTED_TEXT}\n`, { inBackground: false })).toBeUndefined()
    expect(startedJob(`line 1\n${MOVED_TEXT}\n`, { inBackground: false })).toBeUndefined()
  })
  // #1302: Claude Code moves a foreground call to the background in three more ways than its
  // timeout, each in words of its own, read from the function that writes them in the 2.1.302
  // build (2026-10-17). A merge helper run in the foreground while builders' messages arrive is the
  // second, and the watcher read none of them, so keep_job said no job was running.
  const USER_TEXT = 'Command was manually backgrounded by user with ID: bu4kq01a. Output is being written to: /private/tmp/x/tasks/bu4kq01a.output.'
  const MESSAGE_TEXT =
    'Command was moved to the background (ID: bm9z2c7d) so that a message that arrived while it was running can reach you; it was not interrupted. Output is being written to: /private/tmp/x/tasks/bm9z2c7d.output. You will be notified when it completes.'
  test('a command the user sent to the background is a job', () => {
    expect(startedJob(USER_TEXT, { inBackground: false })).toEqual({ id: 'bu4kq01a', outputPath: '/private/tmp/x/tasks/bu4kq01a.output' })
  })
  test('a command moved to the background so a message could reach Claude is a job', () => {
    expect(startedJob(MESSAGE_TEXT, { inBackground: false })).toEqual({ id: 'bm9z2c7d', outputPath: '/private/tmp/x/tasks/bm9z2c7d.output' })
  })
  // A turn stopped while a foreground command runs leaves it going, said in the background start's words.
  test('a foreground command left running when its turn stopped is a job', () => {
    expect(startedJob(STARTED_TEXT, { inBackground: false })).toEqual({ id: 'btv0drbh3', outputPath: '/private/tmp/x/tasks/btv0drbh3.output' })
  })
  test("each of those quoted by a foreground command's own output still started nothing", () => {
    expect(startedJob(`line 1\n${USER_TEXT}\n`, { inBackground: false })).toBeUndefined()
    expect(startedJob(`line 1\n${MESSAGE_TEXT}\n`, { inBackground: false })).toBeUndefined()
  })
  // Claude Code's result also names the task it started (backgroundTaskId), which is its own word
  // that the call started one whatever the text says. With it, the notice naming that task is read
  // wherever it stands; one naming any other task is still a quote.
  test('a result naming the task it started is read by that task, wherever its notice stands', () => {
    expect(startedJob(`warning: something\n${MESSAGE_TEXT}`, { inBackground: false, taskId: 'bm9z2c7d' })).toEqual({
      id: 'bm9z2c7d',
      outputPath: '/private/tmp/x/tasks/bm9z2c7d.output',
    })
    expect(startedJob(`warning: something\n${MESSAGE_TEXT}`, { inBackground: false, taskId: 'other1' })).toBeUndefined()
  })
  // Lessons review of #1302: a background call's start read by the looser pattern it always was
  // read by stays a job when its result also names the task, and only as that task.
  test('a background start the looser pattern reads is still a job when its result names the task', () => {
    const loose = 'Running in background with ID: bl0se1. Output is being written to: /private/tmp/x/tasks/bl0se1.output.'
    expect(startedJob(loose, { inBackground: true })).toEqual({ id: 'bl0se1', outputPath: '/private/tmp/x/tasks/bl0se1.output' })
    expect(startedJob(loose, { inBackground: true, taskId: 'bl0se1' })).toEqual({ id: 'bl0se1', outputPath: '/private/tmp/x/tasks/bl0se1.output' })
    expect(startedJob(loose, { inBackground: true, taskId: 'other1' })).toBeUndefined()
  })
  // The cwd note Claude Code adds after a background start whose command changes directory, as the
  // merge helper's does (gh pr comment, then cd into a worktree), leaves the start readable.
  test('a background start followed by the note about its cd is still a job', () => {
    const hinted = `${STARTED_TEXT}\nSession cwd remains /repo; directory changes made by the backgrounded command do not apply to subsequent commands.`
    expect(startedJob(hinted, { inBackground: true })).toEqual({ id: 'btv0drbh3', outputPath: '/private/tmp/x/tasks/btv0drbh3.output' })
  })
})

// #706: Claude Code's notice that a background job ended names it by id (seen in a session,
// 2026-10-04), so the watcher can stop naming it at once rather than at its next look.
describe('a task notification', () => {
  test('names the jobs it reports on', () => {
    const text = '<task-notification>\n<task-id>boljn4dt6</task-id>\n<tool-use-id>toolu_01</tool-use-id>\n<output-file>/private/tmp/x/tasks/boljn4dt6.output</output-file>\n<status>completed</status>\n<summary>Background command "x" completed (exit code 0)</summary>\n</task-notification>'
    expect(notifiedTasks(text)).toEqual(['boljn4dt6'])
  })
  test('anything else names none', () => {
    expect(notifiedTasks('the task-id was boljn4dt6')).toEqual([])
  })
})

describe('a poll loop', () => {
  test('until or while, with a sleep, is a poll loop', () => {
    expect(isPollLoop('until curl -sf http://x/health; do sleep 3; done')).toBe(true)
    expect(isPollLoop('while ! gh pr checks 9 | grep -q pass; do sleep 30; done')).toBe(true)
  })
  test('anything else is not', () => {
    expect(isPollLoop('npm run dev')).toBe(false)
    expect(isPollLoop('for f in *.ts; do echo $f; done')).toBe(false)
  })
})

describe('is it stuck', () => {
  const lines = (n: number, s: string) => Array.from({ length: n }, () => s).join('\n') + '\n'
  test('fresh output is running', () => {
    expect(assess({ tail: 'built 1\nbuilt 2\n', size: 20, lastGrowth: 10 * MIN }, 11 * MIN)).toEqual({ state: 'running' })
  })
  test('the same error line over and over is stuck repeating (2026-09-22: 183KB of one curl error)', () => {
    expect(assess({ tail: lines(30, 'zsh: no matches found: http://x?y'), size: 9000, lastGrowth: 11 * MIN }, 11 * MIN)).toEqual({
      state: 'repeating',
      line: 'zsh: no matches found: http://x?y',
      lines: ['zsh: no matches found: http://x?y'],
    })
  })
  // #706: a poll loop printing its error and then a retry line on every pass never repeats one line,
  // and is as stuck as one that does.
  const cycle = (n: number, ...pass: string[]) => Array.from({ length: n }, () => pass.join('\n')).join('\n') + '\n'
  const REFUSED = 'curl: (7) Failed to connect to localhost port 3000: Connection refused'
  test('an error and a retry line taking turns is stuck repeating, named by its error line', () => {
    expect(assess({ tail: cycle(15, REFUSED, 'retrying in 3s'), size: 9000, lastGrowth: 11 * MIN }, 11 * MIN)).toEqual({
      state: 'repeating',
      line: REFUSED,
      lines: [REFUSED, 'retrying in 3s'],
    })
  })
  test('a pass of up to four lines over and over is stuck repeating, named by its last line when none is an error', () => {
    expect(assess({ tail: cycle(8, 'checking', 'still pending', 'waiting 30s'), size: 900, lastGrowth: 0 }, 1 * MIN)).toEqual({
      state: 'repeating',
      line: 'waiting 30s',
      lines: ['checking', 'still pending', 'waiting 30s'],
    })
  })
  test('lines that change on each pass are running, not repeating', () => {
    const counting = Array.from({ length: 30 }, (_, i) => `attempt ${i}\nretrying in 3s`).join('\n') + '\n'
    expect(assess({ tail: counting, size: 900, lastGrowth: 0 }, 1 * MIN).state).toBe('running')
  })
  test('a few repeats are not yet stuck', () => {
    expect(assess({ tail: lines(3, 'waiting'), size: 30, lastGrowth: 10 * MIN }, 10 * MIN).state).toBe('running')
  })
  test('no new output for ten minutes is stuck silent, measured from the last growth', () => {
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0 }, 10 * MIN + 1)).toEqual({ state: 'silent', forMs: 10 * MIN + 1 })
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0 }, 10 * MIN - 1).state).toBe('running')
  })
  test('a job kept as quiet by design is never silent', () => {
    expect(assess({ tail: 'listening on 3000\n', size: 18, lastGrowth: 0, quietByDesign: true }, 60 * MIN).state).toBe('running')
  })
  test('blank lines do not count as a repeating error', () => {
    expect(assess({ tail: lines(40, ''), size: 40, lastGrowth: 5 * MIN }, 5 * MIN).state).toBe('running')
  })
})

// Decided with Dan (2026-10-04, after the review of #634): a waiting loop is stopped by itself only
// when the line it repeats reads as an error.
describe('an error line', () => {
  test('lines that report a failure read as errors', () => {
    for (const line of [
      'zsh: no matches found: http://x?y',
      'curl: (7) Failed to connect to localhost port 3000 after 0 ms: Couldn\'t connect to server',
      'Error: connect ECONNREFUSED 127.0.0.1:5432',
      'fatal: not a git repository',
      'Permission denied',
      'ls: x: No such file or directory',
    ]) expect(isErrorLine(line)).toBe(true)
  })
  test('a patient waiting line does not', () => {
    for (const line of ['waiting for deploy', 'checks still pending', 'Waiting for server to start...', '.', 'retrying in 3s']) expect(isErrorLine(line)).toBe(false)
  })
  // Lessons review of #634: a count of zero or a negation reports no failure.
  test('a count of zero or a negation of failure does not', () => {
    for (const line of ['0 failed, 3 pending', 'no errors yet', 'built without errors', 'errors: 0', 'Tests: 0 failures, 12 passed', 'no failures so far']) expect(isErrorLine(line)).toBe(false)
  })
  test('a real failure beside a zero count still does', () => {
    for (const line of ['0 passed, 2 failed', 'Error: connect ECONNREFUSED 127.0.0.1:5432 (no errors before this)']) expect(isErrorLine(line)).toBe(true)
  })
})

// Leftover jobs from closed sessions (Dan, 2026-10-04): a model's verdict on each, and the one dim
// line Dan sees afterwards.
describe('a verdict on a leftover job', () => {
  test('JSON with stop and a name is a verdict, wherever it sits in the reply', () => {
    expect(parseVerdict('{"stop": true, "name": "curl loop repeating connection refused"}')).toEqual({ stop: true, name: 'curl loop repeating connection refused' })
    expect(parseVerdict('Here you go:\n{"stop": false, "name": "dev server", "reason": "still serving"}\n')).toEqual({ stop: false, name: 'dev server' })
  })
  test('anything else is no verdict, never a guess', () => {
    for (const text of ['', 'stop it', '{"stop": "yes", "name": "x"}', '{"stop": true}', '{"stop": true, "name": "  "}', '{not json}']) expect(parseVerdict(text)).toBeUndefined()
  })
  test('the first verdict is found when the reply holds a second object or a stray brace', () => {
    expect(parseVerdict('{"stop": true, "name": "curl loop"} and also {"note": 1}')).toEqual({ stop: true, name: 'curl loop' })
    expect(parseVerdict('{"stop": false, "name": "dev server"}\n} trailing')).toEqual({ stop: false, name: 'dev server' })
    expect(parseVerdict('Thinking {about it}. {"stop": true, "name": "loop {x}"}')).toEqual({ stop: true, name: 'loop {x}' })
  })
  test('a long name is cut to fit one line', () => {
    expect((parseVerdict(`{"stop": true, "name": "${'x'.repeat(200)}"}`)?.name ?? '').length).toBeLessThanOrEqual(60)
  })
})

describe('how long a job has run', () => {
  test('minutes under an hour, hours and minutes after', () => {
    expect(runFor(30_000)).toBe('0m')
    expect(runFor(14 * MIN)).toBe('14m')
    expect(runFor(134 * MIN)).toBe('2h 14m')
  })
})

describe('the line Dan sees after leftovers are judged', () => {
  test('stopped and left, the settled example word for word', () => {
    expect(
      leftoverLine(
        [
          { kind: 'stopped', name: 'curl loop repeating connection refused', session: 'a' },
          { kind: 'left', name: 'dev server', session: 'a' },
        ],
        [],
      ),
    ).toBe('Stopped 1 leftover job from a closed session (curl loop repeating connection refused); left 1 running (dev server).')
  })
  // Shortened to the bare fact by Dan (2026-10-04, picker), the job named in brackets.
  test('a job that could not be judged, or stopped, says so in its own words', () => {
    expect(
      leftoverLine(
        [
          { kind: 'unjudged', name: 'npm run dev', session: 'a' },
          { kind: 'stopFailed', name: 'curl loop', why: 'kill: Operation not permitted', session: 'b' },
        ],
        [],
      ),
    ).toBe('1 leftover job not judged, left running (npm run dev); 1 leftover job could not be stopped (curl loop).')
  })
  test('the shortened lines alone, word for word', () => {
    expect(leftoverLine([{ kind: 'unjudged', name: 'dev server', session: 'a' }], [])).toBe('1 leftover job not judged, left running (dev server).')
    expect(leftoverLine([{ kind: 'stopFailed', name: 'curl loop', why: 'kill: Operation not permitted', session: 'a' }], [])).toBe('1 leftover job could not be stopped (curl loop).')
  })
  test('several of a kind are counted and named together', () => {
    expect(
      leftoverLine(
        [
          { kind: 'left', name: 'dev server', session: 'a' },
          { kind: 'left', name: 'test watcher', session: 'a' },
        ],
        [],
      ),
    ).toBe('Left 2 leftover jobs from a closed session running (dev server, test watcher).')
  })
  // #753: what could not be read is named, so the line claims only what was measured (L11).
  test('session records that could not be read are named, so their jobs are not taken as none', () => {
    expect(leftoverLine([], ['abc.json'])).toBe('Session record abc.json could not be read, so its leftover jobs were not checked.')
    expect(leftoverLine([{ kind: 'stopped', name: 'curl loop', session: 'a' }], ['abc.json', 'def.json'])).toBe(
      'Stopped 1 leftover job from a closed session (curl loop); 2 session records could not be read (abc.json, def.json), so their leftover jobs were not checked.',
    )
  })
  test('a sessions folder that could not be read is named as the registry names it', () => {
    expect(leftoverLine([], ['the sessions folder'])).toBe('The sessions folder could not be read, so leftover jobs were not checked.')
  })
  test('nothing judged and nothing unreadable is no line at all', () => {
    expect(leftoverLine([], [])).toBeUndefined()
  })
})

describe('a job named in a notice', () => {
  test('a short command is kept whole, on one line', () => {
    expect(shortCommand('  npm run\n dev  ')).toBe('npm run dev')
  })
  test('a long command is cut to forty characters, ending in dots', () => {
    const cut = shortCommand(`until curl -sf http://x/${'a'.repeat(200)}; do sleep 3; done`)
    expect(cut.length).toBe(40)
    expect(cut.endsWith('...')).toBe(true)
    expect(cut.startsWith('until curl -sf')).toBe(true)
  })
  test('a long repeated line is cut to one hundred and twenty characters', () => {
    expect(shortLine(`error: ${'b'.repeat(500)}`).length).toBe(120)
  })
})

// #1326: the shapes are the 2.1.302 build's, from real transcripts (2026-10-19).
describe('background work a call started that is no Bash job', () => {
  const MONITOR_TEXT = 'Monitor started (task b16r21r6f, expires in 30m unless the source ends first). You will be notified on each event.'
  test("a Monitor's task is read from its result, or from its opening words", () => {
    expect(startedTask('Monitor', { taskId: 'b16r21r6f', persistent: false, timeoutMs: 1800000 }, MONITOR_TEXT)).toBe('b16r21r6f')
    expect(startedTask('Monitor', MONITOR_TEXT, MONITOR_TEXT)).toBe('b16r21r6f')
  })
  test('a Monitor that started nothing, and words quoted by any other tool, are no task', () => {
    expect(startedTask('Monitor', {}, 'Error: no such command')).toBeUndefined()
    expect(startedTask('Bash', MONITOR_TEXT, MONITOR_TEXT)).toBeUndefined()
    expect(startedTask('Monitor', {}, `line 1\n${MONITOR_TEXT}`)).toBeUndefined()
  })
  test('an agent run in the background is its agent id; one run in the foreground is nothing', () => {
    expect(startedTask('Agent', { isAsync: true, status: 'async_launched', agentId: 'a86adeb544d22338e' }, '')).toBe('a86adeb544d22338e')
    expect(startedTask('Agent', { status: 'completed', agentId: 'a86adeb544d22338e' }, '')).toBeUndefined()
  })
})

describe('the background work sent with a stop', () => {
  test('each entry is its task id, named by its command or else its description', () => {
    expect(inFlight([
      { id: 'b5injl7eg', type: 'shell', status: 'running', description: 'Sleep 200 seconds', command: 'sleep 200' },
      { id: 'a41a8a9e4e2d20c71', type: 'subagent', status: 'running', description: 'probe2', agent_type: 'general-purpose' },
    ])).toEqual([{ id: 'b5injl7eg', what: 'sleep 200' }, { id: 'a41a8a9e4e2d20c71', what: 'probe2' }])
  })
  test('a missing list, or one that is not a list, is unreadable, never empty (L10)', () => {
    expect(inFlight(undefined)).toBeUndefined()
    expect(inFlight({ b1: 'running' })).toBeUndefined()
    expect(inFlight([])).toEqual([])
  })
  test('an entry naming no task is passed over', () => {
    expect(inFlight([null, 'b1', { type: 'shell' }, { id: '' }, { id: 'b2' }])).toEqual([{ id: 'b2', what: 'b2' }])
  })
  // #1517: what Claude Code says of each task it lists, by id, for the watcher to read beside its
  // own measure. A task it lists with no status is listed, never read as finished or as missing.
  test('each listed task is read with its status, and an unreadable list is no reading (#1517)', () => {
    expect(listedStatuses([{ id: 'b1', status: 'running' }, { id: 'b2', status: 'completed' }, { id: 'b3' }, null, { status: 'failed' }])).toEqual(
      new Map([['b1', 'running'], ['b2', 'completed'], ['b3', '']]),
    )
    expect(listedStatuses(undefined)).toBeUndefined()
    expect(listedStatuses({ b1: 'running' })).toBeUndefined()
  })
  test('a task Claude Code has finished is one it lists as ended or no longer lists; any other status is not (#1517)', () => {
    for (const s of ['completed', 'failed', 'killed', 'stopped', 'unlisted']) expect(harnessFinished(s)).toBe(true)
    for (const s of ['running', 'pending', '', 'paused']) expect(harnessFinished(s)).toBe(false)
  })
  test('the refusal names each piece of work and the ways out', () => {
    const said = holdRefusal([{ id: 'b1', what: 'gh pr checks 9 --watch' }, { id: 'mon1', what: 'gh run watch 99' }])
    expect(said).toContain('You still hold background work you started: b1 (gh pr checks 9 --watch), mon1 (gh run watch 99).')
    expect(said).toContain('wait for it in the foreground')
    expect(said).toContain('stop it with TaskStop')
    expect(said).toContain('hand back your report')
  })
})
