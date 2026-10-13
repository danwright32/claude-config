/**
 * Whether a prompt is Dan's own words, read from `prompt.submit`'s origin: only what he types, at
 * the terminal (`composer`) or from his phone through Remote Control (`bridge`). Nothing else is,
 * however it is framed: a handoff's opening prompt he pressed Use on, which the handoff mod submits
 * `asUser`, another plugin's prompt sent as his, a task notification, a peer session, a schedule.
 * Decided by Dan on 2026-10-13 for every mod (#1135); before it, five mods asked this in two ways,
 * two of them counting a handoff's opening prompt. The one reader every mod asks
 * (`$.modkit.isDans`), so the question has one answer (L261). Any origin the engine gives is
 * accepted, by its kind alone, so a kind the engine adds later is never Dan's.
 */
export const isDans = (origin: { readonly kind?: string } | undefined): boolean => origin?.kind === 'composer' || origin?.kind === 'bridge'
