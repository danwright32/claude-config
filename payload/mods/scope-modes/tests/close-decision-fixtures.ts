// The picker Dan answered at about 1:38 PM ET on 2026-11-26 (#3779), word for word from that
// session's record: its question, its three answers with what each said, and the one he picked. It
// named claude-config's pull request 3749 in words and its issue with a #, and an hour later winding
// down sent that pull request back to be reopened. Kept once, for the reader's own tests and the
// engine's.

export const SIGN_OFF =
  '3.79 Sign off for #3692 (pull request 3749), now that both Macs are counted. Today, if a permission changes in your real settings while the full test run is going, the run fails and has to be run again. The pull request would excuse that again, unless the change touches one of the three shared deny rules, which also means a suite that wrongly edited only an allow rule would no longer be caught. In about 30 days neither Mac has a single case of a run failing or being excused for this. What should happen to it?'

/** The answer he picked. */
export const CLOSE_IT = '3.79.1 Close it unmerged (Recommended)'

export const SIGN_OFF_OPTIONS: { label: string; description: string }[] = [
  {
    label: CLOSE_IT,
    description:
      'The stricter check stays. The cost is one rerun on the rare day you grant a permission during a full run, which has not happened on either Mac in the period searched. I close pull request 3749 and issue #3692 with the counts, and the branch stays on GitHub in case it is wanted later.',
  },
  {
    label: '3.79.2 Merge it',
    description: 'A permission change during a full run is treated as your own edit again unless it touches the three shared deny rules. No rerun on that rare day, and a suite that wrongly edits only an allow rule or a mode is no longer caught by this check.',
  },
  { label: '3.79.3 Keep it open', description: 'Nothing merges or closes. It stays held, and I count again in a month to see whether a case has turned up.' },
]

/** The words the session closed it with, which name no pull request and are the session's own. */
export const SESSION_NOTE = 'Closed without merging, by Dan\'s decision on 2026-11-26 ("3.79.1 Close it unmerged (Recommended)").'

/** The call as the session made it: one question, one answer to pick. `more` is laid over the call, `id` its tool use. */
export const signOff = (question: string = SIGN_OFF, options: { label: string; description?: string }[] = SIGN_OFF_OPTIONS, more: Record<string, unknown> = {}, id = 'q1') => ({
  tool: 'AskUserQuestion',
  tool_use_id: id,
  questions: [{ question, header: '3.79 #3692', multiSelect: false, options }],
  ...more,
})
