import { read } from 'claude-code'
import type { EngineInterface, Register, ResolveInput } from 'claude-code'
import type { ModKit, ModKitBandButton, ModKitBandLine, ModKitBandPart, ModKitBandRow, ModKitBandText, ModKitCall, ModKitCard, ModKitClickSite, ModKitPane, ModKitPress, ModKitRun } from '../types/index.d.ts'
import { clicksReach, compose, drop, fallbackOf, isDivider, isSlot, mostRows, paneRefusal, put, refusal, wraps } from './band.ts'
import { blockedCard, cardRefusal } from './card.ts'
import { commands, git, pipeline } from './commands.ts'
import { dependsOn, judgeProviders, newestFile, reloadedUnder } from './dependents.ts'
import { sendTwice } from './send.ts'
import { githubRepo, repoName } from './repo.ts'
import { readBranch } from './branch.ts'
import { workingTree } from './tree.ts'
import { commandWrites } from './writes.ts'

// What every mod draws the same way (claude-config milestone 18, docs/mods-design.md), in one
// place so no guard keeps its own copy (L613). Among it: the boxed card a tool result row is drawn
// as, the shape settled with Dan for a blocked action in design rounds 1 and 3 on 2026-10-03, and
// opened to any mod's own tool result in #663. Its border is grey, because colour is kept for what
// Dan has to act on; a run in the title may carry a colour, such as a leading state word.
//
// A card is recorded by its tool_use_id when the mod's tool.call hook runs, and its result row is
// drawn as the card. Kept in memory: after a reload an earlier row is drawn as Claude Code's own
// row again, which still carries the whole text the model read.
const cards = new Map<string, ModKitCard>()
const MAX = 500
const keep = (card: ModKitCard) => {
  cards.set(card.toolUseId, card)
  // Bounded, so a long session cannot grow it without end; the oldest rows are long gone.
  if (cards.size > MAX) cards.delete(cards.keys().next().value as string)
}

/** The secret guard's noun as its contract has it (#707); it may not be loaded at all. */
type SecretGuardScreen = { screen: (call: ModKitCall) => Promise<{ deny: string } | null> }

// A screen that could not ask refuses the call, with the card, rather than let input it could not
// check reach the mod answering the call (L42).
const screenFailed = (call: ModKitCall, why: string): { deny: string } => {
  // A call with no id is refused all the same, drawn as Claude Code's error row, as `blocked` does.
  if (call.tool_use_id) keep(blockedCard({ toolUseId: call.tool_use_id, guard: 'Secret guard', reason: "Couldn't check this for secrets, so it was stopped.", safeWay: 'Try it again, or ask Dan.' }))
  return { deny: `Blocked: the secret guard could not be asked about this (${why}), so it did not run. Try it again; if it fails the same way, tell Dan.` }
}

// The band's rows, in $.state so a reload of this module keeps them (a module variable would not).
const band = { plugin: 'mod-kit', key: 'band' } as const
// What each mod's side pane shows (#690), there for the same reason.
const panes = { plugin: 'mod-kit', key: 'panes' } as const
// When this mod last started in this session (#960), there for the same reason: a reload reads it.
const started = { plugin: 'mod-kit', key: 'started' } as const
// The mods a pass could not ask to load again, asked again at the next one whatever their times.
const askAgain = { plugin: 'mod-kit', key: 'askAgain' } as const
// The time each manifest mod-kit touched was left with, so its own touch is not read as a change.
const stamped = { plugin: 'mod-kit', key: 'stamped' } as const
// Where each provider other than mod-kit was last looked at, at a turn's start (#966).
const swept = { plugin: 'mod-kit', key: 'swept' } as const

// #960, measured 2026-10-08 with throwaway mods in a session of its own. When one delivery changes
// mod-kit and a mod that starts using something mod-kit only now provides (the steps card hooking
// modkit.press, #946), an open session reloads the dependent first, in a busy session at its turn's
// end whatever order the files were written in. Built against the mod-kit still loaded, which lacks
// the new member, it is unloaded: its tools go ("MCP server removed from the configuration") although
// Claude Code's notice says the previous version stays loaded, and nothing retries it once mod-kit
// has reloaded. A save to its folder does, so at its own reload mod-kit touches the manifest of every
// mod that depends on it and changed since mod-kit last started in this session. A touch changes the
// time alone: the sync compares content, so it carries nothing, and nothing a delivery is writing
// can be overwritten with an older copy. A mod that had loaded is loaded once more, which is harmless.
// The session's own start loads every mod as it is on disk, so it only records the time.
//
// #966, measured the same day (2.1.295): the same happens to a mod that depends on another provider
// (session-registry, status-bar, is-it-live, addon-notes), and nothing of mod-kit runs when that
// provider reloads: session.start is raised for the reloaded mod alone. So mod-kit also looks at each
// turn's start, by when a provider changed since the last look has reloaded (a busy session reloads
// at its turn's end, an idle one at once), and asks again for its dependents that changed since
// then. One place for every provider, present and future, none of which has to opt in. The cost: a
// look at the mods folder each turn, made once the turn has begun so it holds nothing back, and such
// a mod's tools come back at the end of the turn that looked rather than at once.
//
// From the #967 review: the next pass compares against the time this pass BEGAN, so a delivery that
// lands while it is still asking is seen then; mod-kit's own touches are told apart by the time each
// left its manifest with, so they are not taken for changes; a mod that could not be asked is kept by
// name and asked again at the next pass of either kind, so one that keeps failing holds no other
// back; a folder that could not be listed moves nothing, so every mod is looked at again; and a
// change in a folder beneath a module's hooks folder counts.
const lost = 'If its tools or commands are missing in this session, a new session brings them back.'
const reason = (err: unknown) => String((err as Error)?.message ?? err)
const modsFolder = ($: EngineInterface) => $.plugin.root.replace(/\/+[^/]+\/*$/, '')

// The newest file in a module's folder and the folders beneath it, to a depth no module here comes
// near, links not followed, so a loop cannot hold a pass.
const newestBeneath = async ($: EngineInterface, dir: string, depth = 0): Promise<number> => {
  const entries = await $.fs.list(dir)
  let newest = newestFile(entries)
  for (const f of entries) if (f.kind === 'dir' && !f.isLink && depth < 4) newest = Math.max(newest, await newestBeneath($, `${dir}/${f.name}`, depth + 1))
  return newest
}

type ModLook = { name: string; manifestPath: string; deps: string[]; newest: () => Promise<number> }
type Pass = { mods: ModLook[]; unread: { name: string; text: string }[]; retry: Set<string>; stamps: Record<string, number> }

// Every mod in the mods folder but mod-kit, in the folder's order: what it depends on and, when
// asked, its newest file, mod-kit's own touch of its manifest not counted. No manifest, no mod:
// nothing loads the folder. No hooks folder, no module: nothing of it is loaded, so it has no tools
// to lose. A manifest that is there but cannot be read may be a mod that is unloaded now, so it is a
// failure, said and asked about again. Its line says only that: no reload or ask was measured (#977
// review).
const beginPass = async ($: EngineInterface, home: string, entries: readonly { name: string; kind: string }[]): Promise<Pass> => {
  const pass: Pass = { mods: [], unread: [], retry: new Set((await $.state.get(askAgain)).value ?? []), stamps: { ...((await $.state.get(stamped)).value ?? {}) } }
  for (const entry of entries) {
    if (entry.kind !== 'dir' || entry.name === 'mod-kit') continue
    const dir = `${home}/${entry.name}`
    const manifestPath = `${dir}/.claude-plugin/plugin.json`
    let part = 'manifest'
    try {
      if (!(await $.fs.exists(manifestPath))) continue
      const deps = dependsOn(await $.fs.read(manifestPath))
      part = 'hooks folder'
      if (!(await $.fs.exists(`${dir}/hooks`))) continue
      const own = (f: { name: string; mtimeMs: number }) => f.name === 'plugin.json' && f.mtimeMs === pass.stamps[entry.name]
      const read = async () => Math.max(newestFile((await $.fs.list(`${dir}/.claude-plugin`)).filter(f => !own(f))), await newestBeneath($, `${dir}/hooks`))
      let newest: Promise<number> | undefined
      pass.mods.push({ name: entry.name, manifestPath, deps, newest: () => (newest ??= read()) })
    } catch (err) {
      pass.unread.push({ name: entry.name, text: `${entry.name}'s ${part} could not be read (${reason(err)}), so mod-kit could not tell whether it needs to load again. ${lost}` })
    }
  }
  return pass
}

// Asks again for each mod that depends on a provider in `reloaded` (each with the time it was last
// looked at) and changed since then, and for each the last pass could not ask, then records the
// outcome. With `sayAgain` false a failure is said only the first time, so a look made every turn
// does not repeat a line the person already has.
const askDependents = async ($: EngineInterface, pass: Pass, reloaded: ReadonlyMap<string, number>, opts: { sayAgain: boolean; who: (under: string[]) => string }) => {
  const touched: string[] = []
  const failed: string[] = []
  const fail = (name: string, text: string) => {
    failed.push(name)
    if (opts.sayAgain || !pass.retry.has(name)) $.ui.log(text)
  }
  for (const u of pass.unread) fail(u.name, u.text)
  for (const mod of pass.mods) {
    let under: string[] = []
    try {
      if (mod.deps.some(p => reloaded.has(p))) under = reloadedUnder(mod.deps, await mod.newest(), reloaded)
      if (!under.length && !pass.retry.has(mod.name)) continue
      const r = await $.process.run(['touch', '-c', mod.manifestPath])
      if (r.exitCode !== 0) throw new Error(r.stderr.trim() || `touch exited ${r.exitCode}`)
      touched.push(mod.name)
      try {
        pass.stamps[mod.name] = (await $.fs.stat(mod.manifestPath)).mtimeMs
      } catch {
        delete pass.stamps[mod.name] // unknown: its touch is taken for a change once more, which is harmless
      }
    } catch (err) {
      fail(mod.name, `${mod.name} could not be asked to load again after ${opts.who(under)} reloaded (${reason(err)}). ${lost}`)
    }
  }
  if (touched.length) $.ui.log(`These mods load again, as a mod they depend on reloaded: ${touched.join(', ')}`, { to: 'debug' })
  await $.state.set(askAgain, failed)
  await $.state.set(stamped, pass.stamps)
}

// mod-kit's own reload (#960): its dependents that changed since it last started.
const afterOwnStart = async ($: EngineInterface) => {
  const before = (await $.state.get(started)).value
  const passStart = await $.clock.now()
  // The look at turns begins with the session, or with the first start of a mod-kit that makes it.
  if ((await $.state.get(swept)).value === undefined) await $.state.set(swept, { from: passStart, at: {} })
  if (before === undefined) {
    await $.state.set(started, passStart)
    return
  }
  const home = modsFolder($)
  let entries: Awaited<ReturnType<EngineInterface['fs']['list']>>
  try {
    entries = await $.fs.list(home)
  } catch (err) {
    $.ui.log(`mod-kit reloaded, but the mods folder ${home} could not be read (${reason(err)}), so a mod that changed with it was not asked to load again. ${lost}`)
    return
  }
  const pass = await beginPass($, home, entries)
  await askDependents($, pass, new Map([['mod-kit', before]]), { sayAgain: true, who: () => 'mod-kit' })
  await $.state.set(started, passStart)
}

// What a look at a turn's start has said and not yet seen put right, so each is said once.
const saidAtTurns = new Set<string>()
const sayOnce = ($: EngineInterface, kind: string, text: string) => {
  if (saidAtTurns.has(kind)) return
  saidAtTurns.add(kind)
  $.ui.log(text)
}

// A turn's start (#966): every provider but mod-kit that changed since the last look has reloaded.
// mod-kit asks for its own dependents when it reloads, at once, so it is not judged here.
const atTurnStart = async ($: EngineInterface, turnStart: number) => {
  const look = (await $.state.get(swept)).value
  if (look === undefined) {
    await $.state.set(swept, { from: turnStart, at: {} })
    return
  }
  const home = modsFolder($)
  let entries: Awaited<ReturnType<EngineInterface['fs']['list']>>
  try {
    entries = await $.fs.list(home)
  } catch (err) {
    sayOnce($, 'folder', `The mods folder ${home} could not be read at a turn's start (${reason(err)}), so mod-kit could not check whether a mod needs to load again. ${lost}`)
    return
  }
  saidAtTurns.delete('folder')
  const pass = await beginPass($, home, entries)
  const byName = new Map(pass.mods.map(m => [m.name, m]))
  const newest: Record<string, number> = {}
  for (const provider of new Set(pass.mods.flatMap(m => m.deps))) {
    const mod = byName.get(provider)
    if (provider === 'mod-kit' || !mod) continue
    try {
      newest[provider] = await mod.newest()
      saidAtTurns.delete(`provider:${provider}`)
    } catch (err) {
      // Not judged, so looked at from the same time at the next turn. Said once, and never kept to
      // be asked again itself: touching it would reload a mod that was never unloaded (#977 review).
      sayOnce($, `provider:${provider}`, `mod-kit could not tell at a turn's start whether ${provider} changed (${reason(err)}), so a mod that depends on it was not asked to load again. ${lost}`)
    }
  }
  const { reloaded, at } = judgeProviders(newest, look, turnStart)
  await askDependents($, pass, reloaded, { sayAgain: false, who: under => (under.length ? under.join(' and ') : 'a mod it depends on') })
  await $.state.set(swept, { from: look.from, at })
  saidAtTurns.delete('check')
}

// One pass at a time, so two never read and write the same records over each other.
let passes: Promise<void> = Promise.resolve()
const onePass = (fn: () => Promise<void>) => (passes = passes.then(fn, fn))

export const register: Register = (on, options) => {
  registerBand(on, options)
  // Every mod's message to another session, tried once more when refused (hooks/send.ts). Only a
  // mod's: Claude's own SendMessage, and anything else, is left as it is.
  on('session.send', async ($, e, next) => {
    const origin = (e as unknown as { origin?: { kind?: string } }).origin
    if (origin?.kind !== 'plugin') return next(e)
    return sendTwice(() => next(e))
  })
  on('engine.create', async ($, e, next) => {
    const built = await next(e)
    // Read, change and write the band with ifVersion, again on a miss, so two mods publishing at
    // once both land (assume it runs twice). The engine requires $ to be spelled in place, so this
    // cannot be the library's update(), which takes $ as an argument.
    const change = async (fn: (rows: ModKitBandRow[]) => ModKitBandRow[]) => {
      for (let attempt = 0; attempt < 10; attempt++) {
        const held = await built.state.get(band)
        // A row stored under a slot the band no longer has (a question row from before #796) is
        // dropped on the next write, so it does not stay in the state for good (L377).
        const r = await built.state.set(band, fn((held.value ?? []).filter(row => isSlot(row.slot))), { ifVersion: held.version })
        if (r.isSet) return
      }
      throw new Error('the band changed under every one of 10 attempts to update it')
    }
    // The same for the panes. fn may throw a refusal, judged against the panes as they are now.
    const changePanes = async (fn: (held: ModKitPane[]) => ModKitPane[]) => {
      for (let attempt = 0; attempt < 10; attempt++) {
        const held = await built.state.get(panes)
        const r = await built.state.set(panes, fn(held.value ?? []), { ifVersion: held.version })
        if (r.isSet) return
      }
      throw new Error('the panes changed under every one of 10 attempts to update them')
    }
    const modkit: ModKit = {
      blocked: async input => {
        // A guard's refusal stands without its card, so a call with no id is drawn as Claude Code's error row.
        if (!input.toolUseId) return
        keep(blockedCard(input))
      },
      card: async input => {
        const why = cardRefusal(input)
        if (why) throw new Error(why)
        keep(input)
      },
      commands: async ({ command }) => commands(command),
      writes: async ({ command, cwd, home }) => commandWrites(command, cwd, home),
      git: async ({ words }) => git(words),
      pipeline: async ({ command }) => pipeline(command),
      workingTree: async ({ path }) => (await workingTree(path, dir => built.fs.exists(`${dir === '/' ? '' : dir}/.git`))) ?? null,
      repo: async ({ root, remote }) => ({ github: githubRepo(remote), name: repoName({ root, remote }) }),
      branch: async ({ path }) => {
        const root = await workingTree(path, dir => built.fs.exists(`${dir === '/' ? '' : dir}/.git`))
        if (root === undefined) return null
        return readBranch(root, argv => built.process.run(argv, { timeoutMs: 3_000 }))
      },
      bandRow: async row => {
        const why = refusal(row)
        if (why) throw new Error(why)
        await change(rows => put(rows, row))
      },
      clearBandRow: async ({ mod, id }) => {
        await change(rows => drop(rows, mod, id))
      },
      pane: async pane => {
        await changePanes(held => {
          const why = paneRefusal(pane, held)
          if (why) throw new Error(why)
          return put(held, pane)
        })
      },
      clearPane: async ({ mod, id }) => {
        await changePanes(held => drop(held, mod, id))
      },
      // Answered by this mod's own hook on the noun's event below, which has the whole $ and so can
      // ask the secret guard wherever its folder sorts; this answers only when that hook failed.
      screen: async call => screenFailed(call, 'the check itself failed'),
      // The bottom of every press (#939): reached only when no publisher's modkit.press hook took it.
      press: async () => ({ isAnswered: false }),
      clickable: async site => siteClickable(site, () => built.env.get('TERM_PROGRAM')),
    }
    return { ...built, modkit }
  })

  // #707: a mod answering a tool call itself asks here before it acts. The guards that refuse a call
  // for its input are asked by name: today the secret guard alone.
  on('modkit.screen', async ($, e) => {
    try {
      return { value: await ($ as unknown as { secretGuard: SecretGuardScreen }).secretGuard.screen(e) }
    } catch (err) {
      const why = String((err as Error)?.message ?? err)
      // The engine needs the noun called in place, so the secret guard not being loaded arrives as a
      // TypeError naming the noun; whatever the noun itself throws arrives wrapped as the engine's
      // own error, and is a failure, never taken for absence.
      if (err instanceof TypeError && /secretGuard/.test(why)) return { value: null }
      return { value: screenFailed(e, why) }
    }
  })

  on('ui.render', { component: 'ToolResult' }, ($, e, next) => {
    const card = cards.get(e.props.tool_use_id)
    if (!card) return next(e)
    const { Box, Text } = $.ui.resolve(e)
    // Each run its own Text nested in the line's, so a line wraps as one piece of text.
    const runs = (rs: ModKitRun[]) =>
      rs.map((r, i) => (
        <Text key={String(i)} color={r.color} bold={r.bold} dimColor={r.dim}>
          {r.text}
        </Text>
      ))
    return (
      <Box flexDirection="column" borderStyle="round" borderColor="gray" paddingX={1}>
        <Text bold>{runs(card.title)}</Text>
        {card.lines.map((l, n) => (
          <Text key={String(n)}>{runs(l)}</Text>
        ))}
      </Box>
    )
  })
}


// One mod's card as the band and a side pane both draw it (#690): its lines, inside its frame.
// `columns` is how wide the site is, so a divider reaches its edge. The one drawing of a card, so
// the band and the pane cannot drift apart as cards gain shapes.
// `isClickable` is whether a click on a Button here reaches the mod (band.ts clicksReach, #939).
const drawCard = <E extends ResolveInput>($: EngineInterface, e: E, columns: number, row: ModKitPane, isClickable: boolean) => {
  const { Box, Button, Link, Text } = $.ui.resolve(e)
  // A link inside the run's own Text, so it keeps the run's style and is cut or wrapped as the
  // run says, while the address it opens and copies stays whole (#708). Where the terminal
  // draws no hyperlinks (Apple Terminal) a Link with text is drawn as the text then the
  // address, so a run whose text is its own address is a Link with neither, which shows it once.
  const run = (p: ModKitBandText, key: string) => (
    <Text key={key} color={p.color} bold={p.bold} dimColor={p.dim} strikethrough={p.strikethrough} wrap={p.wrap ? 'wrap' : 'truncate-end'}>
      {p.href === undefined ? p.text : p.text === p.href ? <Link href={p.href} /> : <Link href={p.href}>{p.text}</Link>}
    </Text>
  )
  const part = (p: ModKitBandPart, i: number) => {
    // Where a click may not land, a button that says what to draw instead is that text, never a
    // control that looks pressable and does nothing (#939).
    const instead = 'button' in p && !isClickable ? fallbackOf(row.mod, p) : undefined
    if ('button' in p && instead)
      return (
        <Box key={`instead:${row.mod}:${p.button}`} flexDirection="row" flexShrink={0} paddingLeft={p.indent}>
          {instead.map((r, k) => run(r, `${p.button}:${k}`))}
        </Box>
      )
    const drawn =
      'button' in p ? (
        // The press reaches the publisher through its modkit.press hook, as a typed /press does (#939).
        <Button key={`${row.mod}:${p.button}`} label={p.label} hotkey={p.hotkey} plain={p.plain} onPress={press => void pressed($, press.element, String(press.surface), 'click').then(why => why && $.ui.toast(why))} />
      ) : (
        run(p, String(i))
      )
    // #872: a whole run, a label, never shrinks, so a long run beside it is cut or wrapped instead
    // of taking the label with it ("Whe..." on Ink at 30 columns).
    if (!('button' in p) && p.whole)
      return (
        <Box key={`whole:${i}`} flexShrink={0} paddingLeft={p.indent}>
          {drawn}
        </Box>
      )
    return p.indent ? (
      <Box key={`indent:${i}`} paddingLeft={p.indent}>
        {drawn}
      </Box>
    ) : (
      drawn
    )
  }
  // A divider is as wide as the site and cut at the edge of whatever frame it sits in.
  const line = (l: ModKitBandLine, n: number) =>
    isDivider(l) ? (
      <Text key={String(n)} color="gray" wrap="truncate-end">
        {'─'.repeat(Math.max(1, columns))}
      </Text>
    ) : (
      <Box key={String(n)} flexDirection="row">
        {l.map(part)}
      </Box>
    )
  const key = `${row.mod}/${row.id}`
  const lines = row.lines.map(line)
  const color = row.frame?.color ?? 'gray'
  if (row.frame?.kind === 'box')
    return (
      <Box key={key} flexDirection="column" borderStyle="round" borderColor={color} paddingX={1}>
        {lines}
      </Box>
    )
  if (row.frame?.kind === 'left-rule' && row.lines.some(wraps))
    // A run that wraps makes a line more than one terminal row, so the rule is one column laid over
    // the row's whole height, its marks enough for every row the lines could take and clipped to it
    // (#734). The lines stand clear of it as they do beside one mark per line.
    return (
      <Box key={key} flexDirection="column">
        <Box key={`${key}:rule`} position="absolute" top={0} bottom={0} left={0} width={1} overflow="hidden" flexDirection="column">
          <Text color={color}>{Array.from({ length: mostRows(row.lines, row.mod) }, () => '│').join('\n')}</Text>
        </Box>
        <Box key={`${key}:lines`} flexDirection="column" paddingLeft={2} flexGrow={1}>
          {lines}
        </Box>
      </Box>
    )
  if (row.frame?.kind === 'left-rule')
    // One rule mark per line, since every line here is one terminal line.
    return (
      <Box key={key} flexDirection="row">
        <Box key={`${key}:rule`} flexDirection="column">
          {row.lines.map((_, n) => (
            <Text key={String(n)} color={color}>
              {'│'}
            </Text>
          ))}
        </Box>
        <Box flexDirection="column" paddingLeft={1} flexGrow={1}>
          {lines}
        </Box>
      </Box>
    )
  return (
    <Box key={key} flexDirection="column">
      {lines}
    </Box>
  )
}

// The band above the prompt: every mod's rows, in the settled order (hooks/band.ts). The one hook on
// it in any mod (tools/check-mod-shared-parts.sh). A survey holds the band, and the rows yield to it.
// A side pane a mod published through $.modkit.pane is drawn here too, as the same card; one it did
// not publish is left to whoever draws it.
// Whether a click on a Button drawn at `site` reaches the mod (#939), for mod-kit's own drawing and
// for any mod drawing its own Button ($.modkit.clickable). The terminal's name is read from the
// session's environment; one that cannot be read is taken as unknown, which draws the text.
const siteClickable = async (site: ModKitClickSite, terminalName: () => Promise<string | undefined>) => {
  const terminal = site.surface === 'terminal' ? await terminalName().catch(() => undefined) : undefined
  return clicksReach({ surface: site.surface, isFullscreen: site.viewport?.isFullscreen, terminal })
}
const clickable = ($: EngineInterface, e: ModKitClickSite) => siteClickable(e, () => $.env.get('TERM_PROGRAM'))

// A press on one of mod-kit's buttons, clicked or typed: raised as modkit.press for the publisher to
// answer. Nothing answering, or the press failing, is said rather than left as a dead control.
const pressed = async ($: EngineInterface, element: string, surface: string, how: ModKitPress['how']): Promise<string | undefined> => {
  try {
    const r = await $.modkit.press({ element, surface, how })
    if (r?.isAnswered) return undefined
    return `Nothing answered the button ${element}; its mod may not be loaded.`
  } catch (err) {
    return `The button ${element} failed: ${String((err as Error)?.message ?? err)}`
  }
}

// The buttons showing now, in the band and in every pane, by their `<mod>:<button>` key (#939).
const showing = async ($: EngineInterface): Promise<Map<string, ModKitBandButton>> => {
  const out = new Map<string, ModKitBandButton>()
  for (const r of [...((await read($, band)) ?? []), ...((await read($, panes)) ?? [])])
    for (const l of r.lines) if (Array.isArray(l)) for (const p of l) if ('button' in p) out.set(`${r.mod}:${p.button}`, p)
  return out
}

const registerBand: Register = on => {
  // #939: where a click cannot land, a button is drawn as "type: /press <mod> <button>", and this is
  // that command. Only a button showing now is pressed, so an old line typed again presses nothing.
  on('session.start', async ($, e, next) => {
    if (e.isInteractive) await $.command.register({ name: 'press', description: 'Press a button in the band or a pane: /press <mod> <button>, as the band shows it', argumentHint: '<mod> <button>' })
    // #960: at a reload, the mods that changed with mod-kit are asked to load again.
    await onePass(async () => {
      try {
        await afterOwnStart($)
      } catch (err) {
        $.ui.log(`mod-kit could not check which mods to load again after it started (${reason(err)}). ${lost}`)
      }
    })
    return next(e)
  })
  // #966: at each turn's start, the mods whose provider reloaded since the last look. Looked at once
  // the turn has begun, so it never holds the turn back, judged by the time the turn began.
  on('turn.start', async ($, e, next) => {
    const r = await next(e)
    const failed = (err: unknown) => sayOnce($, 'check', `mod-kit could not check at a turn's start which mods to load again (${reason(err)}). ${lost}`)
    try {
      const turnStart = await $.clock.now()
      $.clock.after(0, () => void onePass(() => atTurnStart($, turnStart).catch(failed)))
    } catch (err) {
      failed(err)
    }
    return r
  })
  on('command.run', { command: 'press' }, async ($, e) => {
    const [mod = '', ...rest] = e.args.trim().split(/\s+/)
    const element = `${mod}:${rest.join(' ')}`
    const button = (await showing($)).get(element)
    if (!mod || !rest.length || !button) return { text: `No button "${e.args.trim()}" is showing in the band or a pane, so nothing was pressed.` }
    // Pressed once this command has returned: a press that sends a prompt (Done, Use) cannot send it
    // from inside command.run, which holds the turn. Nothing answering, or a failure, is a toast.
    try {
      $.clock.after(0, () => {
        void pressed($, element, 'terminal', 'typed').then(why => why && $.ui.toast(why))
      })
    } catch (err) {
      return { text: `${button.label} could not be pressed: ${String((err as Error)?.message ?? err)}` }
    }
    return { text: `Pressing ${button.label}.` }
  })
  on('ui.render', { component: 'AbovePrompt' }, async ($, e, next) => {
    const rows = compose((await read($, band)) ?? [])
    if (e.props.hasSurvey || rows.length === 0) return next(e)
    const isClickable = await clickable($, e)
    const { Box } = $.ui.resolve(e)
    return <Box flexDirection="column">{rows.map(row => drawCard($, e, e.props.bodyColumns, row, isClickable))}</Box>
  })
  on('ui.render', { component: 'Pane' }, async ($, e, next) => {
    const pane = ((await read($, panes)) ?? []).find(p => p.id === e.requestId)
    if (!pane) return next(e)
    return drawCard($, e, e.props.bodyColumns, pane, await clickable($, e))
  })
}
