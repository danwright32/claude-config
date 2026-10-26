import type { EngineInterface, Register } from 'claude-code'

// The probe of tests/test-state-snapshot.sh (claude-config#1720), never installed: that suite loads
// it with --plugin-dir into a headless Claude Code session whose model is the scripted stand-in.
//
// On every Bash call whose command carries PROBE-TAG=<tag>, before the call runs, it appends one
// JSON line to STATE_SNAPSHOT_PROBE_OUT saying what $.state answered inside that one hook run:
//
//   own     a read, an unconditional write, and a read again: does the second read see the write
//           this same hook run just made?
//   race    two writers at once, each the versioned read, change and write retried up to five
//           times that the mods use (job-watcher's changeFact): how many tries each took, whether
//           each landed, and every version its reads saw
//   cross   a read, then a write made by ANOTHER dispatch (a timer's) while this hook run waits,
//           then a read again and a write at the first read's version: does this hook run see the
//           other dispatch's write?
//   timer   the race again, run inside a timer's dispatch (as job-watcher's minute look runs)
//           rather than a hook's
//   after   a read of every value, so the next hook run's view is on the record
//
// Each value lives under a key of its own, so one step's writes never move another's versions.
const OWN = { plugin: 'state-snapshot-probe', key: 'own' } as const
const RACE = { plugin: 'state-snapshot-probe', key: 'race' } as const
const CROSS = { plugin: 'state-snapshot-probe', key: 'cross' } as const
const TIMER_RACE = { plugin: 'state-snapshot-probe', key: 'timerRace' } as const

type Try = { read: number; seen: number; isSet: boolean; answered: number }

// The versioned write as the mods write it: read, add one, write at the version read, and on a miss
// read again and try again, five times at most.
const bump = async ($: EngineInterface, who: string, timer = false): Promise<{ who: string; landed: boolean; tries: Try[] }> => {
  const tries: Try[] = []
  for (let i = 0; i < 5; i++) {
    const held = timer ? await $.state.get(TIMER_RACE) : await $.state.get(RACE)
    const seen = typeof held.value === 'number' ? held.value : 0
    const r = timer ? await $.state.set(TIMER_RACE, seen + 1, { ifVersion: held.version }) : await $.state.set(RACE, seen + 1, { ifVersion: held.version })
    tries.push({ read: held.version, seen, isSet: r.isSet, answered: r.version })
    if (r.isSet) return { who, landed: true, tries }
  }
  return { who, landed: false, tries }
}

export const register: Register = on => {
  on('tool.call', { tool: 'Bash' }, async ($, e, next) => {
    const out = await $.env.get('STATE_SNAPSHOT_PROBE_OUT')
    const tag = /PROBE-TAG=(\S+)/.exec(String((e as unknown as Record<string, unknown>).command ?? ''))?.[1]
    if (!out || !tag) return next(e)
    let record: Record<string, unknown>
    try {
      if (tag === 'own') {
        const before = await $.state.get(OWN)
        const wrote = await $.state.set(OWN, (typeof before.value === 'number' ? before.value : 0) + 1)
        const again = await $.state.get(OWN)
        record = { tag, before, wrote, again }
      } else if (tag === 'race') {
        const writers = await Promise.all([bump($, 'first'), bump($, 'second')])
        const end = await $.state.get(RACE)
        record = { tag, writers, end }
      } else if (tag === 'cross') {
        const before = await $.state.get(CROSS)
        const base = typeof before.value === 'number' ? before.value : 0
        let other: unknown = 'not run'
        $.clock.after(0, () => {
          $.state.set(CROSS, base + 100).then(
            r => (other = r),
            err => (other = `failed: ${err instanceof Error ? err.message : String(err)}`),
          )
        })
        await $.clock.sleep(500)
        const again = await $.state.get(CROSS)
        const wrote = await $.state.set(CROSS, base + 1, { ifVersion: before.version })
        record = { tag, before, other, again, wrote }
      } else if (tag === 'timer') {
        let writers: unknown = 'not run'
        $.clock.after(0, () => {
          Promise.all([bump($, 'first', true), bump($, 'second', true)]).then(
            w => (writers = w),
            err => (writers = `failed: ${err instanceof Error ? err.message : String(err)}`),
          )
        })
        await $.clock.sleep(1000)
        record = { tag, writers, end: await $.state.get(TIMER_RACE) }
      } else {
        record = { tag, own: await $.state.get(OWN), race: await $.state.get(RACE), cross: await $.state.get(CROSS), timerRace: await $.state.get(TIMER_RACE) }
      }
    } catch (err) {
      record = { tag, error: err instanceof Error ? err.message : String(err) }
    }
    await $.process.run(['sh', '-c', 'printf "%s\\n" "$1" >> "$2"', '_', JSON.stringify(record), out])
    return next(e)
  })
}
