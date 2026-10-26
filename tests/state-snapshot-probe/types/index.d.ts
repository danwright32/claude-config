/** The probe's counters. */
export type ProbeCount = number

declare module 'claude-code' {
  interface PluginState {
    /** The probe of tests/test-state-snapshot.sh (#1720): two counters, one per step. */
    'state-snapshot-probe': {
      /** Written by the step that reads its own write back. */
      own: ProbeCount
      /** Written by the two racing writers. */
      race: ProbeCount
      /** Written by a timer's own dispatch while a hook run waits between its reads. */
      cross: ProbeCount
      /** Written by two racing writers inside a timer's dispatch rather than a hook's. */
      timerRace: ProbeCount
    }
  }
}
