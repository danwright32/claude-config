import { expect, tier } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import type { Register } from 'claude-code'
import { GH_TOKEN, KNOWN, kit, start, steps, world } from './world.ts'

// #707: a mod that answers a tool call itself never calls next, so a hook beneath it never sees the
// call: manual steps, is it live, handoff and the job watcher all sort above this mod. Such a mod
// asks $.secretGuard.screen before it acts, and these are the cases for that request.
//
// WHY THIS FILE SEATS THE MOD IN THE BUILTIN TIER (#3291). The cases need an answering mod above
// this one whose call on $ this mod's hooks hear, as a real answering mod's is heard: on the Macs
// every mod, this one included, loads in the user tier. Claude Code's test kit cannot seat that:
// it puts the mod under test above an inline plugin of its own tier (measured on 2.1.328), so a
// stand-in in the user tier never gets a call before this mod's own tool.call hook refuses it.
// The stand-in therefore sat in the prepend tier, until 2.1.328 made a mod seated there the
// organization's, whose calls on $ a person's hooks do not hear (Tier, in Claude Code's types):
// this mod's hook on secretGuard.screen never ran and the noun's own refusal answered, 2 of 77
// failing on 2.1.328 and none on 2.1.327, on the same files.
// So the stand-in stays a person's mod, in the user tier, and this mod is moved beneath it for
// this file alone: the builtin tier nests inside the user tier, a person's call runs through every
// hook there, and a built-in's own calls on $ are raised everywhere (measured: these cases pass on
// 2.1.327 and on 2.1.328). Every other case runs in register.test.ts with this mod in the user
// tier, which is also where the organization's seat is pinned.
tier('builtin')

// The answering mod, standing in for the real ones (a mod's tests cannot load another mod's
// files). It says it acted by a toast.
const answerer: { name: string; register: Register } = {
  name: 'manual-steps',
  register: on => {
    // Its tool is matched in the hook, since a stand-in's tool is in no list of tools Claude Code's types name.
    on('tool.call', async ($, e, next) => {
      if (String(e.tool) !== 'mcp__manual-steps__steps') return next(e)
      const refused = await $.secretGuard.screen(e as never)
      if (refused) return refused
      await $.ui.toast('ACTED on the steps')
      return { result: 'Pinned.' } as never
    })
  },
}

test('a call another mod answers itself is refused before it acts when it carries a secret, with the card and toast (#707)', { plugins: [kit, answerer] }, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call(steps(`sk_live_${KNOWN}`, 'm1'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe('Blocked: this message contains a secret. Refer to it by its name, not its value.')
  expect(w.toasts).toEqual(['Blocked a message containing a secret.'])
  expect(w.cards).toEqual([{ toolUseId: 'm1', guard: 'Secret guard', reason: 'This message contains a secret.', safeWay: 'Refer to it by its name, not its value.' }])
  // The same mod's clean call goes ahead: the refusal above was the screen, not the stand-in.
  const ok = await $.tool.call(steps('pk_test_public', 'm2'))
  expect((ok as { result?: unknown }).result).toBe('Pinned.')
  expect(w.toasts).toEqual(['Blocked a message containing a secret.', 'ACTED on the steps'])
  // Neither call reached this mod's own tool.call hook, which hands a call it passes down to the
  // world: the stand-in answered above it, so the screen alone judged them.
  expect(w.reached).toEqual([])
})

test('a token shaped value is refused through the screen too, before the guard has read any source (#707)', { plugins: [kit, answerer] }, async ($, on) => {
  const w = world(on)
  const r = await $.tool.call(steps(GH_TOKEN, 'm3'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toContain('contains a secret')
  expect(w.toasts).not.toContain('ACTED on the steps')
  // The answering mod's hook ran rather than failing through to this mod's own tool.call hook: its
  // clean call is answered by it.
  expect((await $.tool.call(steps('pk_test_public', 'm4')) as { result?: unknown }).result).toBe('Pinned.')
})

// The screen's check failing part way (here mod-kit cannot draw the card) refuses the call, since a
// screen that fails open would let the secret through to the answering mod (L42).
const brokenKit: { name: string; register: Register } = {
  name: 'mod-kit',
  register: on => {
    on('engine.create', async ($, e, next) => {
      const built = await next(e)
      return {
        ...built,
        modkit: {
          // Said before it fails, so the test below can tell the check failing part way from the
          // check never being asked: both end in the same refusal (#3291).
          blocked: async () => {
            await built.ui.log('THE CARD WAS ASKED FOR')
            throw new Error('the card could not be kept')
          },
          commands: async () => [],
          // The kit's other members, which these tests never reach: each refuses by name if one ever is.
          card: async () => { throw new Error("mod-kit's card is not stood in by these tests") },
          writes: async () => { throw new Error("mod-kit's writes is not stood in by these tests") },
          git: async () => { throw new Error("mod-kit's git is not stood in by these tests") },
          pipeline: async () => { throw new Error("mod-kit's pipeline is not stood in by these tests") },
          workingTree: async () => { throw new Error("mod-kit's workingTree is not stood in by these tests") },
          repo: async () => { throw new Error("mod-kit's repo is not stood in by these tests") },
          gh: async () => { throw new Error("mod-kit's gh is not stood in by these tests") },
          mergeHelper: async () => { throw new Error("mod-kit's mergeHelper is not stood in by these tests") },
          goal: async () => { throw new Error("mod-kit's goal is not stood in by these tests") },
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
          isDans: async () => { throw new Error("mod-kit's isDans is not stood in by these tests") },
          typedAnswer: async () => { throw new Error("mod-kit's typedAnswer is not stood in by these tests") },
          hold: async () => { throw new Error("mod-kit's hold is not stood in by these tests") },
          release: async () => { throw new Error("mod-kit's release is not stood in by these tests") },
          pythonText: async () => { throw new Error("mod-kit's pythonText is not stood in by these tests") },
          login: async () => { throw new Error("mod-kit's login is not stood in by these tests") },
          account: async () => { throw new Error("mod-kit's account is not stood in by these tests") },
        },
      }
    })
  },
}
test('a screen whose check fails refuses the call rather than let it through (#707, L42)', { plugins: [brokenKit, answerer] }, async ($, on) => {
  const w = world(on)
  await start($)
  const r = await $.tool.call(steps(KNOWN, 'm5'))
  expect(String((r as { text?: string }).text ?? (r as { deny?: string }).deny)).toBe(
    'Blocked: the secret guard could not check this for secrets, so it did not run. Try it again; if it fails the same way, tell Dan.',
  )
  expect(w.toasts).not.toContain('ACTED on the steps')
  // The check ran as far as the card and failed there. Without this the refusal alone would pass
  // just as well where the screen's hook was never reached, as it did on 2.1.328 until #3291.
  expect(w.logs).toContain('THE CARD WAS ASKED FOR')
})
