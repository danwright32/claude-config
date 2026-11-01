// Where a result goes when Dan cannot be shown it on the Mac (#1935): a private claude.ai page,
// published with the Artifact tool, and its link given. Away mode delivers every result that way, a
// call held while he is away says so, and since #1935 the keystroke guard says so too when he has
// answered Not now to bringing an app to the front: on 2026-10-29 that refusal named no next step,
// and a design was described in prose instead of published. One wording, kept here once and copied
// byte for byte into each mod that says it (hooks/mod-kit/deliver.ts, which
// tools/check-mod-shared-parts.sh holds to this one), since a mod cannot import another mod's files.

/** What the result is delivered as, a phrase Dan and Claude both read. */
export const PRIVATE_PAGE = 'a private claude.ai page'

/** The tool that publishes one, named only where Claude reads it. */
export const PAGE_TOOL = 'the Artifact tool'

/** The next step a refusal gives Claude, for `what` it could not show Dan on the Mac. */
export const publishInstead = (what: string): string => `Publish ${what} as ${PRIVATE_PAGE} instead (${PAGE_TOOL}), and give its link.`
