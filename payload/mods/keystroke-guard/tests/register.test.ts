import { expect, mock, test, type Engine } from 'claude-code/testing'
import type { On, Register } from 'claude-code'

const OVERTURE = '/Applications/Overture.app/Contents/MacOS/Overture'
const DEBUG = '/Users/x/Build/Debug/Overture.app/Contents/MacOS/Overture'
const LIGHTROOM = '/Applications/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic'
const KEYWORD = 'key' + 'stroke'

type World = { front: number; running: Record<number, string>; answer: string | 'dismiss'; away?: boolean }
type Card = { toolUseId: string; guard: string; reason: string; safeWay?: string }

const ok = (stdout: string) => ({ value: { exitCode: 0, stdout, stderr: '', isStdoutTruncated: false, isStderrTruncated: false } })
const none = { value: { exitCode: 1, stdout: '', stderr: '', isStdoutTruncated: false, isStderrTruncated: false } }

// A stand-in for mod-kit: an inline plugin cannot reach this file's variables, so it reports each
// card as a transcript line the world collects. Its command reader is a small stand-in for the real
// one (a mod cannot import another mod's files): enough for the commands below, quotes and leading
// assignments. The real reader is tested in mod-kit.
const kit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    const read = (cmd: string): string[][] =>
      cmd
        .split(/&&|;|\n/)
        .map(part => {
          const words: string[] = []
          // A word may mix bare and quoted parts (X="a b" is one word), as the shell's are.
          for (const m of part.matchAll(/(?:[^\s"']+|"[^"]*"|'[^']*')+/g)) words.push(m[0].replace(/"([^"]*)"|'([^']*)'/g, '$1$2'))
          while (words.length && /^[A-Za-z_][A-Za-z0-9_]*=/.test(words[0] ?? '')) words.shift()
          return words
        })
        .filter(w => w.length > 0)
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async (b: unknown) => built.ui.log('CARD ' + JSON.stringify(b)),
          commands: async ({ command }: { command: string }) => read(command),
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
        },
      }
    })
  },
}
// A stand-in for Claude Code's built-in security default (#875), loaded in every test so none can
// pass on a hook that never runs. Seated outermost for a Team or Enterprise organization, it sends
// every classic hook event past the tier a person's own plugins load in. This is its own code for
// that event, copied from the 2.1.292 binary: `e("classic.*",(n,o,t)=>t.to(o,"append"))`. A
// headless debug run on 2026-10-06 logged it for this mod on every Bash call:
// "...keystroke-guard: classic.PreToolUse bypassed by cc-plugin-sec-default (tier user); beneath runs".
const secDefault: { name: string; tier: 'prepend'; register: Register } = {
  name: 'sec-default-stand-in',
  tier: 'prepend',
  register: on => {
    on('classic.*', ($, e, next) => next.to(e, 'append'))
  },
}
const withKit = { plugins: [secDefault, kit] }

// The Mac beneath the mod: which processes run at which path, which is frontmost, and what Dan
// answers. Each tool call that gets past the mod is recorded, and so is each question asked.
const world = (engine: Engine, on: On, w: World) => {
  const reached: string[] = []
  const asked: { question: string; header: string; options: string[] }[] = []
  const toasts: string[] = []
  const cards: Card[] = []
  on('process.run', ($, e) => {
    const [cmd, ...args] = e.argv
    if (cmd === 'pgrep' && args[0] === '-f') {
      const pids = Object.entries(w.running).filter(([, p]) => p.includes(args[1] ?? '')).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'pgrep' && args[0] === '-x') {
      // As macOS does: the process name it matches is cut to 16 characters (lessons review).
      const pids = Object.entries(w.running).filter(([, p]) => (p.split('/').pop() ?? '').slice(0, 16) === (args[1] ?? '')).map(([pid]) => pid)
      return pids.length ? ok(pids.join('\n') + '\n') : none
    }
    if (cmd === 'ps' && args.includes('-axo')) {
      return ok(Object.entries(w.running).map(([pid, p]) => `${pid} ${p}`).join('\n') + '\n')
    }
    if (cmd === 'ps') return ok((w.running[Number(args[args.length - 1])] ?? '') + '\n')
    if (cmd === 'osascript') return ok(`${w.front}\n`)
    // Where Dan is, for the scope modes stand-in below.
    if (cmd === '__away') return w.away ? ok('') : none
    return none
  })
  on('tool.call', { tool: 'AskUserQuestion' }, ($, e) => {
    const qs = (e as unknown as { questions: { question: string; header: string; options: { label: string }[] }[] }).questions
    const q = qs[0]
    asked.push({ question: q?.question ?? '', header: q?.header ?? '', options: (q?.options ?? []).map(o => o.label) })
    if (w.answer === 'dismiss') return { deny: 'dismissed' } as never
    // The tool's own result: answers keyed by each question's text, as the dialog records them.
    return { result: { questions: qs, answers: { [q?.question ?? '']: w.answer } }, text: `"${q?.question}"="${w.answer}"` } as never
  })
  // Core, standing in: the engine decides whether the call may run (the tool.check chain over every
  // plugin, with the call's id and its arguments as the permission decision reads them), then runs
  // it. The harness raises classic.PreToolUse above this hook as a session does, but not tool.check,
  // so it is raised here. Beneath every plugin's tool.check hook the rules allow the call.
  on('tool.check', () => ({ decision: 'allow' }))
  on('tool.call', async ($, e) => {
    const { tool, tool_use_id, agentId: _a, consent: _c, ...input } = e as unknown as Record<string, unknown>
    const verdict = await engine.tool.check({ tool: String(tool), input, ...(tool_use_id === undefined ? {} : { tool_use_id: String(tool_use_id) }) } as never)
    // A refusal there reaches the call as core reports it, an errored result whose text is the reason.
    if (verdict.decision === 'deny') return { isError: true, result: verdict.reason, text: verdict.reason ?? 'denied' } as never
    reached.push(e.tool)
    return { result: 'ran', text: 'ran' } as never
  })
  on('ui.toast', ($, e) => {
    toasts.push(e.text)
    return { value: undefined }
  })
  const holds: { label: string; prompt: string }[] = []
  on('ui.log', ($, e) => {
    if (e.text.startsWith('CARD ')) cards.push(JSON.parse(e.text.slice(5)))
    if (e.text.startsWith('HOLD ')) holds.push(JSON.parse(e.text.slice(5)))
    return { value: undefined }
  })
  return { reached, asked, toasts, cards, holds }
}

const KEY = `TARGET_APP=${OVERTURE} osascript -e 'tell application "System Events" to ${KEYWORD} "n" using command down'`
const bash = (command: string, id = 't1') => ({ tool: 'Bash', command, tool_use_id: id }) as never
const refusal = (r: unknown) => {
  const x = r as { deny?: string; text?: string }
  return x.deny ?? x.text ?? ''
}

test('an undeclared target is refused before anyone is asked', withKit, async ($, on) => {
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(`osascript -e 'tell application "System Events" to ${KEYWORD} "n"'`))
  expect(w.reached).not.toContain('Bash')
  expect(w.asked.length).toBe(0)
  expect(refusal(r)).toBe("Blocked: This doesn't say which app it types into. Add TARGET_APP=<the app's executable path> to the command.")
})

test('the right app, frontmost and alone, gets the agreed question once and then runs', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  expect(w.asked).toEqual([{ question: "I'm about to type into Overture. Ready?", header: 'Taking over', options: ['Go ahead', 'Not now'] }])
  expect(w.reached).toContain('Bash')
})

test('a wrong frontmost app is refused, with the card and a toast', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 77, running: { 10: OVERTURE, 77: LIGHTROOM }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(KEY, 'w1'))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe("Blocked: Overture isn't the front app (Adobe Lightroom Classic is). Bring it forward first, then type.")
  expect(w.cards).toEqual([
    { toolUseId: 'w1', guard: 'Keystroke guard', reason: "Overture isn't the front app (Adobe Lightroom Classic is).", safeWay: 'Bring it forward first, then type.' },
  ])
  expect(w.toasts).toContain('Blocked typing into Overture.')
})

test('two copies of an app with a long name are refused too (lessons review)', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const OTHER_LR = '/Users/x/Beta/Adobe Lightroom Classic.app/Contents/MacOS/Adobe Lightroom Classic'
  const w = world($, on, { front: 10, running: { 10: LIGHTROOM, 11: OTHER_LR }, answer: 'Go ahead' })
  await $.tool.call(bash(`TARGET_APP="${LIGHTROOM}" cliclick c:1,1`))
  expect(w.reached).not.toContain('Bash')
})

test('two running copies of the app are refused', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
})

test('a declined heads up refuses the action', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Not now' })
  const r = await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: You said not now to typing into Overture.')
})

test('a dismissed heads up refuses the action', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'dismiss' })
  const r = await $.tool.call(bash(KEY))
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toBe('Blocked: The question about Overture was dismissed.')
})

test('a yes holds while input keeps coming, and lapses after 10 quiet minutes', withKit, async ($, on) => {
  const clock = mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  await clock.advance(9 * 60_000)
  await $.tool.call(bash(KEY))
  await clock.advance(9 * 60_000)
  await $.tool.call(bash(KEY))
  expect(w.asked.length).toBe(1)
  await clock.advance(10 * 60_000 + 1)
  await $.tool.call(bash(KEY))
  expect(w.asked.length).toBe(2)
})

test('a focus stealer gets the agreed question but no process check', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  // Two copies running and the wrong app frontmost: a full check would refuse this.
  const w = world($, on, { front: 77, running: { 10: OVERTURE, 11: DEBUG }, answer: 'Go ahead' })
  await $.tool.call(bash('open -a "Google Chrome" report.html'))
  expect(w.asked).toEqual([{ question: "I'm about to bring Google Chrome to the front. Ready?", header: 'Taking over', options: ['Go ahead', 'Not now'] }])
  expect(w.reached).toContain('Bash')
})

test('a declined focus stealer says so in its own words', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: {}, answer: 'Not now' })
  const r = await $.tool.call(bash('open -a "Google Chrome" report.html'))
  expect(refusal(r)).toBe('Blocked: You said not now to bringing Google Chrome to the front.')
  expect(w.toasts).toContain('Blocked bringing Google Chrome to the front.')
})

test('an ordinary command is not asked about', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: {}, answer: 'Go ahead' })
  await $.tool.call(bash('git status'))
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('Bash')
})

test('a yes for an app it cannot name covers nothing else (lessons review)', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: {}, answer: 'Go ahead' })
  // An activate with no app named: the guard cannot say which app comes forward.
  await $.tool.call(bash(`osascript -e 'activate'`, 'u1'))
  await $.tool.call(bash(`osascript -e 'activate'`, 'u2'))
  expect(w.asked.length).toBe(2)
})

test('Chrome extension tools are left alone', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: {}, answer: 'Go ahead' })
  await $.tool.call({ tool: 'mcp__claude-in-chrome__computer', action: 'left_click' } as never)
  expect(w.asked.length).toBe(0)
  expect(w.reached).toContain('mcp__claude-in-chrome__computer')
})

// #707: a guard that refuses decides before the heads up is asked, whichever order the mods load
// in. The guard here stands in for no build, winding down, the secret guard and the style check (a
// mod's tests cannot load another mod's files): it refuses at tool.call any command naming
// NO-BUILD. It is loaded above this guard (prepend) and beneath it (append).
const Refuser = (tier: 'prepend' | 'append'): { name: string; tier: 'prepend' | 'append'; register: Register } => ({
  name: 'refuser',
  tier,
  register: on => {
    on('tool.call', async ($, e, next) => {
      if (String((e as unknown as { command?: string }).command ?? '').includes('NO-BUILD')) return { deny: 'Blocked: no build is on.' }
      return next(e)
    })
  },
})

for (const [where, tier] of [['above', 'prepend'], ['beneath', 'append']] as const) {
  test(`an action a guard ${where} it refuses is never asked about, while one it lets through still is (#707)`, { plugins: [secDefault, kit, Refuser(tier)] }, async ($, on) => {
    mock.clock(on, { now: 0 })
    const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
    await $.tool.call(bash(KEY, 'a1'))
    expect(w.asked.length).toBe(1)
    // An app not yet asked about, which this guard would ask about.
    const r = await $.tool.call(bash('open -a "Google Chrome" report.html && echo NO-BUILD', 'a2'))
    expect(refusal(r)).toBe('Blocked: no build is on.')
    // An app that is not running, which this guard would refuse itself: the refusal beneath still
    // decides first.
    const r2 = await $.tool.call(bash(`TARGET_APP="${LIGHTROOM}" osascript -e 'tell application "System Events" to ${KEYWORD} "x"' && echo NO-BUILD`, 'a3'))
    expect(refusal(r2)).toBe('Blocked: no build is on.')
    expect(w.asked.length).toBe(1)
    expect(w.cards).toEqual([])
    expect(w.toasts).toEqual([])
  })
}

// A settings hook decides at classic.PreToolUse beneath every mod, as the test's own hook does here.
test('an action a settings hook refuses is never asked about (#707)', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  on('classic.PreToolUse', ($, e) => (String((e as unknown as { command?: string }).command).includes('NO-BUILD') ? { deny: 'Blocked by a settings hook.' } : {}))
  const r = await $.tool.call(bash(`${KEY} && echo NO-BUILD`))
  expect(refusal(r)).toBe('Blocked by a settings hook.')
  expect(w.asked.length).toBe(0)
  await $.tool.call(bash(KEY, 't2'))
  expect(w.asked.length).toBe(1)
})

// The scope modes mod (#621), standing in: while Dan is away it holds what it is handed for the held
// card and answers with the refusal worded as its own held actions are; at home nothing is held.
// Where Dan is comes from the world (an inline plugin cannot reach this file's variables): a
// process.run of __away answers 0 while he is away.
const scopeModes: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      const isAway = async () => (await built.process.run(['__away'])).exitCode === 0
      const hold = async (h: { label: string; prompt: string }) => {
        built.ui.log('HOLD ' + JSON.stringify(h))
        if (!(await isAway())) return { isHeld: false }
        return {
          isHeld: true,
          card: { guard: 'Away', reason: `Held for when you are back: ${h.label}.`, safeWay: 'Claude publishes a private page for your phone instead.' },
          deny: `Held: Dan is away from the Mac, so "${h.label}" waits for him to come back.`,
        }
      }
      return { ...built, scopeModes: { isAway, hold } }
    })
  },
}

test('while Dan is away an action is held for when he is back, never asked about in the band (#707)', { plugins: [secDefault, kit, scopeModes] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  // The wrong app in front: held all the same, since Dan cannot bring it forward from his phone.
  const w = world($, on, { front: 77, running: { 10: OVERTURE, 77: LIGHTROOM }, answer: 'Go ahead', away: true })
  const r = await $.tool.call(bash(KEY, 'h1'))
  expect(w.asked).toEqual([])
  expect(w.reached).not.toContain('Bash')
  expect(w.holds).toEqual([{ label: 'Type into Overture', prompt: `Do it now. What was held: ${KEY}` }])
  expect(refusal(r)).toBe('Held: Dan is away from the Mac, so "Type into Overture" waits for him to come back.')
  expect(w.cards).toEqual([{ toolUseId: 'h1', guard: 'Away', reason: 'Held for when you are back: Type into Overture.', safeWay: 'Claude publishes a private page for your phone instead.' }])
  const r2 = await $.tool.call(bash('open -a "Google Chrome" report.html', 'h2'))
  expect(w.holds[1]?.label).toBe('Bring Google Chrome to the front')
  expect(refusal(r2)).toContain('waits for him to come back')
  expect(w.asked).toEqual([])
})

test('at home nothing is held and the heads up is asked as before (#707)', { plugins: [secDefault, kit, scopeModes] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY))
  expect(w.holds.length).toBe(1)
  expect(w.asked.length).toBe(1)
  expect(w.reached).toContain('Bash')
})

// Whether Dan is away cannot be read: asking in the band could wait on nobody, so it is refused.
const brokenScopeModes: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, scopeModes: { isAway: async () => false, hold: async () => { throw new Error('the state could not be read') } } }
    })
  },
}
// A TypeError from inside a loaded scope modes is a failure too, never taken for the mod being absent
// (lessons review of #707). Measured: the engine hands the caller a noun's own throw wrapped as its
// error, never as a TypeError, so this held before the absent check named the noun as well; it is
// kept so neither half can be loosened alone.
const typeErrorScopeModes: { name: string; register: Register } = {
  name: 'scope-modes',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return { ...built, scopeModes: { isAway: async () => false, hold: async () => { throw new TypeError("undefined is not an object (evaluating 'held.length')") } } }
    })
  },
}
test('a TypeError from inside a loaded scope modes refuses the action too (#707 review)', { plugins: [secDefault, kit, typeErrorScopeModes] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(KEY, 'b2'))
  expect(w.asked).toEqual([])
  expect(refusal(r)).toContain("Couldn't tell whether you are away")
})

test('an away check that fails refuses the action rather than ask a question nobody may see (#707)', { plugins: [secDefault, kit, brokenScopeModes] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(KEY, 'b1'))
  expect(w.asked).toEqual([])
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain("Couldn't tell whether you are away")
  expect(w.cards[0]?.guard).toBe('Keystroke guard')
})

// The toast says what failed, the away check, never "Blocked typing into Overture", which reads as
// though the action itself was judged and refused (L11, #732).
test('an away check that fails toasts that the check failed, in each of the two actions', { plugins: [secDefault, kit, brokenScopeModes] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  await $.tool.call(bash(KEY, 'b3'))
  await $.tool.call(bash('open -a "Google Chrome" report.html', 'b4'))
  expect(w.toasts).toEqual([
    "Couldn't tell whether you are away, so typing into Overture was stopped.",
    "Couldn't tell whether you are away, so bringing Google Chrome to the front was stopped.",
  ])
})

// The control for the stand-in (L159): a classic PreToolUse hook of a person's own plugin runs
// without it and is sent past with it, so the tests above, which pass beside it, cannot be leaning
// on a classic hook (#875).
const probe: { name: string; register: Register } = {
  name: 'probe',
  register: on => {
    on('classic.PreToolUse', async ($, e, next) => {
      await $.ui.log('probe ran', { to: 'debug' })
      return next(e)
    })
  },
}
const probeRan = async ($: Engine, on: On) => {
  const logs: string[] = []
  on('ui.log', ($, e) => {
    logs.push(e.text)
    return { value: undefined }
  })
  on('classic.PreToolUse', () => ({}))
  on('tool.call', () => ({ result: 'ran', text: 'ran' }) as never)
  await $.tool.call(bash('echo hi', 'p1'))
  return logs.includes('probe ran')
}
test("a person's own classic PreToolUse hook runs where no security default is seated (#875)", { plugins: [probe] }, async ($, on) => {
  expect(await probeRan($, on)).toBe(true)
})
test("the security default's stand-in sends that hook past, as the real one does (#875)", { plugins: [secDefault, probe] }, async ($, on) => {
  expect(await probeRan($, on)).toBe(false)
})

// A $.tool.check query runs nothing and carries no call id: Dan is never asked about a command that
// is only being looked at, and the real call is judged when it is made (#875).
test('a query about a keystroke asks nobody, and the real call is still judged', withKit, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Not now' })
  const q = await $.tool.check({ tool: 'Bash', input: { command: KEY } } as never)
  expect(q.decision).toBe('allow')
  expect(w.asked).toEqual([])
  const r = await $.tool.call(bash(KEY, 'q1'))
  expect(w.asked.length).toBe(1)
  expect(w.reached).not.toContain('Bash')
  expect(refusal(r)).toContain('You said not now to typing into Overture.')
})

// A hook that fails at tool.check is skipped and the verdict beneath stands, which would let the
// keystroke through unchecked; this guard refuses instead (L42, #875).
const brokenKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          blocked: async () => undefined,
          commands: async () => {
            throw new Error('the command reader is down')
          },
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          ghRepo: async () => { throw new Error("mod-kit's ghRepo is not stood in by these tests") },
          linkRepo: async () => { throw new Error("mod-kit's linkRepo is not stood in by these tests") },
          branch: async () => { throw new Error("mod-kit's branch is not stood in by these tests") },
          bandRow: async () => { throw new Error("mod-kit's bandRow is not stood in by these tests") },
          clearBandRow: async () => { throw new Error("mod-kit's clearBandRow is not stood in by these tests") },
          pane: async () => { throw new Error("mod-kit's pane is not stood in by these tests") },
          clearPane: async () => { throw new Error("mod-kit's clearPane is not stood in by these tests") },
          screen: async () => { throw new Error("mod-kit's screen is not stood in by these tests") },
          // #939: a press raised by the kit's Button below, and whether a click lands; every Button here is clickable.
          press: async () => ({ isAnswered: false }),
          clickable: async () => true,
        },
      }
    })
  },
}
test('a check that fails refuses the keystroke rather than let it through unchecked', { plugins: [secDefault, brokenKit] }, async ($, on) => {
  mock.clock(on, { now: 0 })
  const w = world($, on, { front: 10, running: { 10: OVERTURE }, answer: 'Go ahead' })
  const r = await $.tool.call(bash(KEY, 'f1'))
  expect(w.reached).not.toContain('Bash')
  expect(w.asked).toEqual([])
  expect(refusal(r)).toContain('Blocked: the keystroke guard could not check this command (the command reader is down)')
})
