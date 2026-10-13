// The plan a claude.ai login is on (#1156), named from the login record's organizationType. One email
// can hold a Team login and a personal one, and with only the email and org the two read almost alike.
//
// The table is the one Claude Code 2.1.296 itself keeps (claude_max, claude_pro, claude_enterprise,
// claude_team), measured from its build on 2026-10-13, never guessed. The status line names plans in
// jq (payload/mods/status-bar/statusline.sh) and keeps its own copy of this table as one JSON object
// on its `plans='...'` line. tests/test-status-bar-statusline.sh reads each entry below (so keep them
// one per line, written `  claude_x: 'Name',`), runs it through the status line, and compares the
// two tables' keys, failing when they differ, so the two cannot drift.
export const PLANS: Readonly<Record<string, string>> = {
  claude_team: 'Team',
  claude_max: 'Max',
  claude_pro: 'Pro',
  claude_enterprise: 'Enterprise',
}

/**
 * The plan an organizationType names: its name when the table knows it, else the value as it came
 * (Dan, 2026-10-13: shown, never hidden), control bytes removed so it cannot colour or break a line.
 * No value, an empty one or one that is not text is no plan (undefined), not an unknown one.
 */
export const planOf = (organizationType: unknown): string | undefined => {
  if (typeof organizationType !== 'string') return undefined
  if (Object.prototype.hasOwnProperty.call(PLANS, organizationType)) return PLANS[organizationType]
  const plain = organizationType.replace(/[\u0000-\u001f\u007f]/g, '').trim()
  return plain || undefined
}

/** How a plan reads beside an email and org: "Team plan", so an org named Team is not taken for it. */
export const planText = (plan: string): string => `${plan} plan`
