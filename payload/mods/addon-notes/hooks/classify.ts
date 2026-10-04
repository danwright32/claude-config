// Add-on notes (claude-config#620): what reads as an add-on, and what the model is told about one.
// Pure functions and fixed text, so the rules are tested on their own and the register module only
// wires them to events.

// A note starting with +: a + then words. Not a lone +, not ++, not +1, and not a pasted diff,
// whose later lines also start with + or - (or a hunk header).
export const isAddOnNote = (text: string): boolean => {
  const t = text.trimStart()
  if (!/^\+(?!\+)\s*[A-Za-z]/.test(t)) return false
  return !/\n\s*[-+@]/.test(t)
}

// After an interrupt, a short reply that adds scope rather than changing direction. Read
// conservatively: a reply this misses is simply a normal message, which Claude reads as it always
// has, while a redirect read as an add-on would carry on with work Dan just stopped (L93). So the
// reply must open with one of the words Dan uses to add scope, be short, and carry no word that
// turns it around.
const MAX_WORDS = 40
const LEADS = new RegExp(
  '^(?:(?:oh|ok|okay)[,\\s]+)?(?:' +
    [
      '\\+',
      'also\\b',
      'and\\b',
      'include\\b',
      'including\\b',
      'plus\\b',
      'keep going\\b',
      'carry on\\b',
      'continue\\b',
      'go on\\b',
      // "sorry" alone opens corrections as often as add-ons ("sorry, I meant the staging
      // database"), so it counts only when it is followed by carrying on or adding.
      'sorry[,\\s]+(?:keep going|carry on|continue|go on|go ahead|also|and|include)\\b',
    ].join('|') +
    ')',
  'i',
)
const TURNS_AROUND =
  /\b(?:instead|stop|never ?mind|nvm|scrap|cancel|forget (?:it|that|about)|rather than|not that|wrong|undo|revert|start over|hold off|wait)\b/i

export const isAmendment = (text: string): boolean => {
  const t = text.trim()
  if (!t || t === '+') return false
  if (t.split(/\s+/).length > MAX_WORDS) return false
  if (!LEADS.test(t)) return false
  return !TURNS_AROUND.test(t)
}

// The agreed resume line (docs/mods-design.md, "Add-on notes (#620)"): one line opening a reply.
const PREFIX = '+ add-on: '
export const resumeLine = (text: string): { line: string; rest: string } | undefined => {
  const nl = text.indexOf('\n')
  const line = (nl === -1 ? text : text.slice(0, nl)).trimEnd()
  if (!line.startsWith(PREFIX) || !line.slice(PREFIX.length).trim()) return undefined
  return { line, rest: nl === -1 ? '' : text.slice(nl + 1).trim() }
}

// The toast for a + note mid turn (wording from the issue, in the guards' plain style).
export const TOAST = 'Noted, applying after this step.'

// What the model reads beside a + note sent while it works. Claude Code already delivers a message
// typed mid turn without stopping the turn; this says how to treat it.
export const ADD_ON_CONTEXT =
  'Add-on notes: this message starts with +, which marks it as an add-on to the work in progress, ' +
  'not a redirect. Finish the step you are on, then fold this in at the next natural break in this ' +
  'same turn. Keep every part of the scope already agreed and carry on with the plan.'

// What the model reads beside a short reply sent after Dan interrupted a step. The example line is
// the one settled with Dan, so the example and the rule agree (L270, L562).
export const AMENDMENT_CONTEXT =
  'Add-on notes: the person interrupted your previous turn, and this short reply adds to that work. ' +
  'It is not a new task and not a change of direction. Resume the step you were on when you were ' +
  'interrupted, with this addition folded in, and do not redo work already finished. Keep every part ' +
  'of the scope already agreed. Open your reply with exactly one line, on its own, naming only the ' +
  `addition: "${PREFIX}<the addition, starting with an -ing verb> and carrying on." For example: ` +
  `"${PREFIX}Adding a direct link to the commission and carrying on." When the reply adds nothing ` +
  `(such as "keep going"), the line is "${PREFIX}Carrying on." Then carry on with the work.`
