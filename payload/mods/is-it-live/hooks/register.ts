import type { EngineInterface, Register } from 'claude-code'
import type { IsItLiveCard } from '../types/index.d.ts'
import { type CardInput, MOD, buttonId, cardOf, cardText, liveList, messageRow, reasonToRefuse, stateOf, titleOf } from './card.ts'

// Is it live (claude-config#617). After a merge, and after checking the project's deploy, Claude
// calls this mod's card tool with what it found; the mod confirms the merge with GitHub itself (L161:
// a fact the system can read is checked, never taken from the model), keeps the card per repository
// so /live can list it in any later session, toasts it, and pins a message for whoever asked in the
// band until Dan presses Mark sent. Spec agreed with Dan 2026-10-03, looks settled 2026-10-04.
//
// The card's result row is mod-kit's boxed card ($.modkit.card, #663), the blocked card's shape:
// only mod-kit draws a result row (tools/check-mod-shared-parts.sh, L613). The same lines go to the
// model as the tool's text result, which is also what the row shows after a reload.

const TOOL = `mcp__${MOD}__card`
const KEEP = 50
const storeKey = (repo: string) => `cards:${repo}`

const run = async ($: EngineInterface, argv: string[]) => {
  try {
    const r = await $.process.run(argv, { timeoutMs: 20_000 })
    return r.exitCode === 0 ? { out: r.stdout } : { error: (r.stderr || r.stdout || `exit ${r.exitCode}`).trim() }
  } catch (err) {
    return { error: String((err as Error)?.message ?? err) }
  }
}

const cardsOf = async ($: EngineInterface, repo: string): Promise<IsItLiveCard[]> => {
  const v = await $.store.get(storeKey(repo))
  return Array.isArray(v) ? (v as IsItLiveCard[]) : []
}

// owner/name from the origin remote, ssh or https.
const repoOf = (remote: string | null | undefined): string | undefined => {
  const m = /github\.com[:/]([\w.-]+\/[\w.-]+?)(?:\.git)?\/?$/.exec(remote ?? '')
  return m?.[1]
}

const pin = async ($: EngineInterface, c: IsItLiveCard): Promise<string | undefined> => {
  if (!c.requester || !c.message || c.sentAt !== undefined) return undefined
  try {
    await $.modkit.bandRow(messageRow({ repo: c.repo, pr: c.pr, requester: c.requester, message: c.message }) as never)
    return undefined
  } catch (err) {
    return String((err as Error)?.message ?? err)
  }
}

const DESCRIPTION = [
  'Shows Dan the card for a merged pull request, once you have checked whether it is live.',
  'Call it after every merge: first while the deploy runs (deploy "deploying"), and again once you have checked it.',
  'deploy is "live" only when you confirmed the change itself is live (say how in checked); "failed" or "unreachable" when you could not confirm it (say why in checked); "none" when the project has no recorded deploy step.',
  'changed: what changed, in 2 to 3 plain sentences. see: the direct link and the exact clicks to see it.',
  'requester and message ONLY when someone other than Dan asked: an issue another person reported (via "issue" with its number), a pasted Slack thread ("slack"), or a person Dan named ("named"). The message is in Dan\'s voice, with no dashes.',
  'The card is shown in the chat as it stands: add no sentence that repeats it.',
].join(' ')

const SCHEMA = {
  type: 'object',
  properties: {
    repo: { type: 'string', description: 'owner/name' },
    pr: { type: 'integer' },
    deploy: { type: 'string', enum: ['live', 'deploying', 'failed', 'unreachable', 'none'] },
    checked: { type: 'string' },
    changed: { type: 'string' },
    see: { type: 'object', properties: { link: { type: 'string' }, clicks: { type: 'array', items: { type: 'string' } } }, required: ['link', 'clicks'] },
    requester: { type: 'object', properties: { name: { type: 'string' }, via: { type: 'string', enum: ['issue', 'slack', 'named'] }, issue: { type: 'integer' } }, required: ['name', 'via'] },
    message: { type: 'string' },
  },
  required: ['repo', 'pr', 'deploy', 'changed', 'see'],
}

export const register: Register = on => {
  on('session.start', async ($, e, next) => {
    await $.tool.register({ name: 'card', description: DESCRIPTION, inputSchema: SCHEMA })
    await $.command.register({ name: 'live', description: "This project's recent change cards, and the messages not yet sent." })
    return next(e)
  })

  on('tool.call', { tool: TOOL }, async ($, e) => {
    const { tool: _t, tool_use_id: toolUseId, agentId: _a, consent: _c, ...raw } = e as unknown as Record<string, unknown>
    const input = raw as unknown as CardInput
    const why = reasonToRefuse(input)
    if (why) return { deny: `No card: ${why}` }

    // The merge, from GitHub: a card for an unmerged change would be the false "done" it exists to stop.
    const pr = await run($, ['gh', 'pr', 'view', String(input.pr), '--repo', input.repo, '--json', 'state,title,url'])
    if (pr.error !== undefined) return { deny: `No card: could not confirm #${input.pr} is merged (${pr.error}).` }
    let facts: { state?: string; title?: string; url?: string }
    try {
      facts = JSON.parse(pr.out as string)
    } catch {
      return { deny: `No card: GitHub's answer about #${input.pr} could not be read.` }
    }
    if (facts.state !== 'MERGED') return { deny: `No card: #${input.pr} is ${String(facts.state ?? 'unknown').toLowerCase()}, not merged.` }

    // An issue Dan or Claude filed is filed from Dan's own account, and gets no message (the spec).
    const notes: string[] = []
    let requester = input.requester
    let message = input.message
    if (requester?.via === 'issue') {
      const issue = await run($, ['gh', 'issue', 'view', String(requester.issue), '--repo', input.repo, '--json', 'author'])
      const me = await run($, ['gh', 'api', 'user', '--jq', '.login'])
      let author: string | undefined
      try {
        author = issue.out !== undefined ? (JSON.parse(issue.out) as { author?: { login?: string } }).author?.login : undefined
      } catch {
        author = undefined
      }
      if (!author || me.error !== undefined) return { deny: `No card: could not read who filed issue #${requester.issue} (${issue.error ?? me.error ?? 'no author in the answer'}).` }
      if (author === (me.out as string).trim()) {
        notes.push(`The message was dropped: issue #${requester.issue} was filed from your own account, so Dan or you asked for it.`)
        requester = undefined
        message = undefined
      }
    }

    const state = stateOf(input.deploy)
    const title = facts.title ?? `#${input.pr}`
    const now = await $.clock.now()
    const had = await cardsOf($, input.repo)
    const before = had.find(c => c.pr === input.pr)
    const kept: IsItLiveCard = { repo: input.repo, pr: input.pr, title, url: facts.url ?? '', state, at: now }
    if (requester && message) {
      kept.requester = requester
      kept.message = message
      // A message already marked sent stays sent only while it is the same message.
      if (before?.sentAt !== undefined && before.message === message) kept.sentAt = before.sentAt
    }
    await $.store.set(storeKey(input.repo), [kept, ...had.filter(c => c.pr !== input.pr)].slice(0, KEEP))
    // Taken out of the band when the new card carries no message for it.
    if (!kept.message) await $.modkit.clearBandRow({ mod: MOD, id: buttonId(input.repo, input.pr) }).catch(() => undefined)
    const unpinned = await pin($, kept)
    if (unpinned) notes.push(`The message for ${kept.requester?.name} could not be pinned in the band (${unpinned}); /live lists it.`)

    const shown = { ...input, state, title, url: kept.url }
    try {
      await $.modkit.card({ toolUseId: String(toolUseId ?? ''), ...cardOf(shown) })
    } catch (err) {
      notes.push(`The card could not be drawn boxed (${String((err as Error)?.message ?? err)}), so it shows as text.`)
    }
    $.ui.toast(titleOf(state, title))
    return {
      result: cardText(shown),
      context: [...notes, 'The card is shown in the chat as it stands: add no sentence that repeats it.'],
    }
  })

  // Copy and Mark sent, on any message this mod pinned. One hook for all of them: the buttons are
  // named after their card, so they cannot be listed when the module loads.
  on('ui.press', { plugin: 'mod-kit' }, async ($, e, next) => {
    const m = new RegExp(`^${MOD}:(copy|sent)-(.+)$`).exec(String(e.element ?? ''))
    if (!m) return next(e)
    const [, verb, id] = m
    const repo = repoOf((await $.session.repo())?.remote)
    const cards = repo ? await cardsOf($, repo) : []
    const c = cards.find(x => buttonId(x.repo, x.pr) === id)
    if (!c || !c.message) {
      $.ui.toast('That message is no longer kept.')
      return { element: e.element }
    }
    if (verb === 'copy') {
      const r = await $.ui.copy({ text: c.message, surface: e.surface })
      if (!r.isCopied) $.ui.toast(`Not copied: ${r.reason}`)
    } else {
      const at = await $.clock.now()
      await $.store.set(storeKey(c.repo), cards.map(x => (x === c ? { ...x, sentAt: at } : x)))
      await $.modkit.clearBandRow({ mod: MOD, id: buttonId(c.repo, c.pr) })
    }
    return { element: e.element }
  })

  on('command.run', { command: 'live' }, async $ => {
    const repo = repoOf((await $.session.repo())?.remote)
    if (!repo) return { text: 'This folder has no GitHub repository, so it has no cards.' }
    const cards = await cardsOf($, repo)
    // Every message not yet sent is pinned again, so Copy and Mark sent are at hand in any session.
    for (const c of cards) await pin($, c)
    return { text: liveList(cards) }
  })
}
