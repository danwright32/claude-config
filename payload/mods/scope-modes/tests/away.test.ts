import { describe, expect, test } from 'claude-code/testing'
import { heldCard, needsTheMac } from '../hooks/away.ts'

const needs = (raw: string, ...words: string[][]) => needsTheMac({ raw, commands: words })

describe('needsTheMac: what is held while Dan is away', () => {
  test('opening anything on the Mac, named by what it opens', () => {
    expect(needs('open -a "Google Chrome" /tmp/report.html', ['open', '-a', 'Google Chrome', '/tmp/report.html'])).toBe('Open report.html in Google Chrome')
    expect(needs('open /Users/x/shot.png', ['open', '/Users/x/shot.png'])).toBe('Open shot.png')
    expect(needs('open -a Preview a.pdf b.pdf', ['open', '-a', 'Preview', 'a.pdf', 'b.pdf'])).toBe('Open a.pdf, b.pdf in Preview')
  })
  test('a link keeps its address but never its query or fragment, which can carry a token (L741)', () => {
    expect(needs('open "https://x.com/a?token=abc#f"', ['open', 'https://x.com/a?token=abc#f'])).toBe('Open https://x.com/a')
  })
  test('drafts in BBEdit', () => {
    expect(needs('/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window /tmp/d.md', ['/Applications/BBEdit.app/Contents/Helpers/bbedit_tool', '--front-window', '/tmp/d.md'])).toBe('Open d.md in BBEdit')
  })
  test("the keystroke guard's actions, named by the app TARGET_APP names", () => {
    const raw = `TARGET_APP=/Applications/Overture.app/Contents/MacOS/Overture osascript -e 'tell application "System Events" to keystroke "n" using command down'`
    expect(needs(raw, ['osascript', '-e', 'tell application "System Events" to keystroke "n" using command down'])).toBe('Type into Overture')
    expect(needs('TARGET_APP=/Applications/Overture.app/Contents/MacOS/Overture cliclick c:10,10', ['cliclick', 'c:10,10'])).toBe('Click in Overture')
    expect(needs(`osascript -e 'tell application "Google Chrome" to activate'`, ['osascript', '-e', 'tell application "Google Chrome" to activate'])).toBe('Bring an app to the front')
  })
  test('an AppleScript that only reads takes no focus and is not held', () => {
    expect(needs(`osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'`, ['osascript', '-e', 'tell application "System Events" to get name of first process whose frontmost is true'])).toBeUndefined()
  })
  test('everything else runs as usual', () => {
    expect(needs('npm test', ['npm', 'test'])).toBeUndefined()
    expect(needs('cat open.txt', ['cat', 'open.txt'])).toBeUndefined()
  })
})

describe('heldCard: coming home', () => {
  test('a boxed card, amber heading, one row per held thing with its own button, a divider between rows', () => {
    const row = heldCard([
      { id: 'h1', label: 'Open report.html in Google Chrome', prompt: 'open it' },
      { id: 'h2', label: 'Type into Overture', prompt: 'type it' },
    ])
    expect(row).toEqual({
      mod: 'scope-modes',
      id: 'held',
      slot: 'held',
      frame: { kind: 'box' },
      lines: [
        [{ text: 'Held while you were away', color: 'warning' }],
        [{ text: 'Open report.html in Google Chrome ' }, { button: 'held-h1', label: 'Open' }],
        { divider: true },
        [{ text: 'Type into Overture ' }, { button: 'held-h2', label: 'Do it' }],
      ],
    })
  })
  test('nothing held is no card at all', () => {
    expect(heldCard([])).toBeUndefined()
  })
})
