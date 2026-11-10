import { expect } from 'claude-code/testing'
import { test } from './hang-ceiling.ts'
import { quotedEnd, yamlFlowList, yamlScalar } from '../hooks/quoted.ts'

// The one reader of quoted strings that are not shell, and of YAML flow lists (#2467): the design
// round guard reads a TypeScript or JSX string with it, and the Slack alert guard a GitLab script's
// flow list, each from a byte for byte copy at hooks/mod-kit/quoted.ts.

test('a code string closes at its own quote, a backslash escaping the next character', () => {
  expect(quotedEnd(`'a\\'b' + x`, 0, 'code')).toBe(5)
  expect(quotedEnd(`"it's" + x`, 0, 'code')).toBe(5)
  expect(quotedEnd(`x = "a\\\\" + y`, 4, 'code')).toBe(8)
  // An escaped line break continues the string.
  expect(quotedEnd(`'a\\\nb'`, 0, 'code')).toBe(5)
})

test('a code string that meets a line break or the end of the text does not close', () => {
  expect(quotedEnd(`'open\nstill'`, 0, 'code')).toBe(-1)
  expect(quotedEnd(`"never closed`, 0, 'code')).toBe(-1)
  expect(quotedEnd(`'ends on a backslash\\`, 0, 'code')).toBe(-1)
})

test("a YAML single quoted scalar takes '' as one quote, and a backslash as itself", () => {
  expect(quotedEnd(`'it''s' x`, 0, 'yaml')).toBe(6)
  expect(quotedEnd(`'a\\' b`, 0, 'yaml')).toBe(3)
  expect(quotedEnd(`'a''`, 0, 'yaml')).toBe(-1)
  // A YAML scalar runs on over a line break.
  expect(quotedEnd(`'one\ntwo'`, 0, 'yaml')).toBe(8)
})

test('a YAML double quoted scalar takes a backslash escape, over line breaks too', () => {
  expect(quotedEnd(`"say \\"hi\\"" x`, 0, 'yaml')).toBe(11)
  expect(quotedEnd(`"one\ntwo"`, 0, 'yaml')).toBe(8)
  expect(quotedEnd(`"open`, 0, 'yaml')).toBe(-1)
})

test('a position that holds no quote opens nothing', () => {
  expect(quotedEnd('abc', 0, 'code')).toBe(-1)
  expect(quotedEnd('abc', 0, 'yaml')).toBe(-1)
})

test("a YAML scalar as the shell receives it: quoting undone, '' and backslash escapes read", () => {
  expect(yamlScalar(`'it''s'`)).toBe("it's")
  expect(yamlScalar(`"say \\"hi\\"\\n\\tnow"`)).toBe('say "hi"\n\tnow')
  expect(yamlScalar('plain value')).toBe('plain value')
  expect(yamlScalar(`'`)).toBe(`'`)
  expect(yamlScalar(`'unclosed`)).toBe(`'unclosed`)
})

test("a YAML flow list is read as YAML reads one: a quoted item's commas and brackets are its own, a quote opens only at an item's start, and a comment ends its line", () => {
  const text = [
    `[ 'echo "Backup, of [orders] is late"', # the backup check`,
    `    echo don't, "say \\"hi\\" now", echo a#b,`,
    `    {text: [1, 2]}, 'it''s' ]`,
    'after: x',
  ].join('\n')
  expect(yamlFlowList(text)).toEqual(['echo "Backup, of [orders] is late"', "echo don't", 'say "hi" now', 'echo a#b', '{text: [1, 2]}', "it's"])
})

test('a YAML flow list that never closes keeps every item it read, and an empty one reads none', () => {
  expect(yamlFlowList('["a", b')).toEqual(['a', 'b'])
  expect(yamlFlowList('[]')).toEqual([])
  expect(yamlFlowList('[ , ]')).toEqual([])
  expect(yamlFlowList(`['unclosed, b]`)).toEqual([`'unclosed, b]`])
})

test("a flow list's items come back with their quoting undone, one shell command each", () => {
  const text = `['export MSG="Backup of orders is late"', 'curl -X POST --data ''{"text":"Nightly sync finished"}'' "$SLACK_WEBHOOK_URL"']`
  expect(yamlFlowList(text)).toEqual(['export MSG="Backup of orders is late"', `curl -X POST --data '{"text":"Nightly sync finished"}' "$SLACK_WEBHOOK_URL"`])
})
