// #1811: whether a page Claude publishes with the Artifact tool hands Dan steps to carry out (Slate's
// "Regal changes for Marcia", 13 journey edits, 2026-10-27), as against a report he only reads. Judged
// by what the page holds: a mod cannot add a marker to the built in Artifact publish, and a model
// judge would cost money on every turn that publishes. Measured on 2026-10-27 with signsOf itself over
// the 16 HTML pages this Mac's transcripts wrote, 5 of them published, and a Regal edits page built
// from that skill's fixture (docs/mods-design.md "Manual steps"): the page of live checks for Dan read
// 14 ticks, 8 Copy signs and 6 things to do, the Regal page 2 ticks and 10 Copy signs, and both are
// steps; every other page (overnight reports, an audit, an issue run, design mocks) read no sign at all.

/** The words the page refusal begins with, so a turn that already holds it is never refused twice. */
export const PAGE_MARK = 'You published a page that gives Dan steps'

/** What on a page says it is steps for a person to carry out. */
export type PageSigns = {
  /** Tick boxes: an HTML checkbox, or a Markdown task box. */
  ticks: number
  /** Copy buttons, or a page wired to write the clipboard. */
  copies: number
  /** List items, HTML or Markdown, numbered or bulleted, that begin with something a person does at a screen. */
  actions: number
}

// Something a person does at a screen, never work Claude does itself ("add", "update", "run" lead
// Claude's own plans as often as Dan's steps, so they are left out).
const ACTION = String.raw`(?:open|click|press|tap|paste|copy|type|go to|select|choose|tick|untick|sign in|log in|drag|toggle|turn (?:on|off)|enter|fill in|navigate to|visit|scroll)`
// A step's own number in its words ("Step 2:", "Step 3."), which leads the action rather than being it.
const STEP_NUMBER = String.raw`(?:step\s+\d+\s*[.:)]?\s*)?`
const LEADS_ACTION = new RegExp(String.raw`^\s*${STEP_NUMBER}${ACTION}\b`, 'i')
const MD_ACTION = new RegExp(String.raw`^\s*(?:\d+[.)]|[-*])\s+(?:\*\*|__)?${STEP_NUMBER}(?:\*\*|__)?\s*${ACTION}\b`, 'gim')

const count = (text: string, rx: RegExp) => (text.match(rx) ?? []).length

// Code and styling, where words are not the page's own (a script building rows, a selector).
const withoutCode = (page: string) => page.replace(/<(script|style)\b[\s\S]*?<\/\1\s*>/gi, ' ')
const plainText = (markup: string) =>
  markup
    .replace(/<[^>]*>/g, '')
    .replace(/&nbsp;/g, ' ')
    .replace(/&amp;/g, '&')

/** The signs on a page, HTML or Markdown, that it is steps for a person to carry out. */
export const signsOf = (page: string): PageSigns => {
  const shown = withoutCode(page)
  const items = [...shown.matchAll(/<li\b[^>]*>([\s\S]*?)(?=<\/li\s*>|<li\b|<\/[ou]l\s*>)/gi)].map(m => plainText(m[1] ?? ''))
  return {
    ticks: count(page, /<input\b[^>]*\btype\s*=\s*["']?checkbox\b/gi) + count(shown, /^\s*[-*]\s+\[[ xX]\]/gm),
    copies: count(shown, /<button\b[^>]*>\s*(?:<[^>]*>\s*)*copy\b/gi) + count(page, /navigator\.clipboard\.writeText/g),
    actions: items.filter(t => LEADS_ACTION.test(t)).length + count(shown, MD_ACTION),
  }
}

/**
 * Whether the signs make a page of steps: two list items that each begin with a thing to do at a screen, or any two kinds of
 * sign together. One sign alone is not: a design mock has a checkbox, a report a Copy beside a command.
 */
export const isStepsPage = (s: PageSigns): boolean => s.actions >= 2 || [s.ticks, s.copies, s.actions].filter(n => n > 0).length >= 2

/** The refusal for steps pages published with no card, named by their file names. */
export const pageRefusal = (pages: readonly string[], tool: string): string => {
  const names = pages.map(p => p.slice(p.lastIndexOf('/') + 1)).join(', ')
  return `${PAGE_MARK} (${names}), and no manual steps card was pinned this turn, so the steps on it are not on the card Dan works through and are lost once the page is closed. Check each step against the current state, then pin the ones he can do now with the ${tool} tool: each with its direct link or a location Dan can find, its actions one per item, and any value to paste. Then say in one line that they are on the card. If none of them are his to do now, say exactly "None of these steps are yours to do now." instead.`
}
