import { describe, expect, test } from 'claude-code/testing'
import { heldCard, heldTool, needsTheMac } from '../hooks/away.ts'
import { programsOf } from '../hooks/program.ts'
import { listed } from './listed.ts'

// Each command with its program, read as the mod's tool call hook reads it; a '|' between two
// commands is a pipe (listed.ts).
const needs = (raw: string, ...items: (string[] | '|')[]) => {
  const list = listed(...items)
  const programs = programsOf(list)
  return needsTheMac({ raw, commands: list.map(({ words }, i) => ({ words, ...(programs[i] ? { program: programs[i] } : {}) })) })
}

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
  // The milestone audit (#702): what still opened something or took focus while away.
  test('an AppleScript dialog, which takes focus; a notification banner does not', () => {
    expect(needs(`osascript -e 'display dialog "hi"'`, ['osascript', '-e', 'display dialog "hi"'])).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'display alert "x"'`, ['osascript', '-e', 'display alert "x"'])).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'choose file'`, ['osascript', '-e', 'choose file'])).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'display notification "done"'`, ['osascript', '-e', 'display notification "done"'])).toBeUndefined()
  })
  test('an AppleScript fed by a here-string or echo is judged by its text; one fed by a heredoc, which cannot be read, is held', () => {
    expect(needs(`osascript <<< 'tell application "Finder" to activate'`, ['osascript', '<<<tell application "Finder" to activate'])).toBe('Bring an app to the front')
    expect(needs(`echo 'tell application "Finder" to activate' | osascript`, ['echo', 'tell application "Finder" to activate'], '|', ['osascript'])).toBe('Bring an app to the front')
    expect(needs(`osascript <<'EOF'`, ['osascript', '<<EOF'])).toBe('Run an AppleScript on the Mac')
  })
  // #724: a script file was never judged, so one that shows a dialog or activates an app ran.
  test('an AppleScript in a file, or one that runs a script it cannot read, is held', () => {
    expect(needs('osascript notify.scpt', ['osascript', 'notify.scpt'])).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript -s o ~/bin/front.applescript Overture', ['osascript', '-s', 'o', '~/bin/front.applescript', 'Overture'])).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript -l JavaScript front.js', ['osascript', '-l', 'JavaScript', 'front.js'])).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript < front.applescript', ['osascript', '<', 'front.applescript'])).toBe('Run an AppleScript on the Mac')
    expect(needs(`osascript -e 'run script file "x.scpt"'`, ['osascript', '-e', 'run script file "x.scpt"'])).toBe('Run an AppleScript on the Mac')
    // A script file run by anything but osascript is no AppleScript.
    expect(needs('python3 tools/report.py', ['python3', 'tools/report.py'])).toBeUndefined()
    expect(needs('osascript -l JavaScript', ['osascript', '-l', 'JavaScript'])).toBeUndefined()
  })
})

describe('heldTool: the tools that open something on the Mac by another route than Bash (#702)', () => {
  test('a browser opened or pointed somewhere, by Playwright or in Chrome', () => {
    expect(heldTool('mcp__playwright__browser_navigate', { url: 'https://x.dev/a?token=abc' })).toBe('Open https://x.dev/a in the Playwright browser')
    expect(heldTool('mcp__plugin_playwright_playwright__browser_navigate', { url: 'https://x.dev' })).toBe('Open https://x.dev in the Playwright browser')
    expect(heldTool('mcp__playwright__browser_tabs', { action: 'new' })).toBe('Open a tab in the Playwright browser')
    expect(heldTool('mcp__claude-in-chrome__navigate', { url: 'https://x.dev', tabId: 1 })).toBe('Open https://x.dev in Chrome')
    expect(heldTool('mcp__claude-in-chrome__tabs_create_mcp', {})).toBe('Open a tab in Chrome')
  })
  test("the Artifact tool's open action, which opens the page in the browser", () => {
    expect(heldTool('Artifact', { action: 'open', url: 'https://claude.ai/artifact/abc' })).toBe('Open https://claude.ai/artifact/abc')
  })
  test('reading a page already open, publishing a page, or any other tool goes ahead', () => {
    expect(heldTool('mcp__playwright__browser_snapshot', {})).toBeUndefined()
    expect(heldTool('mcp__playwright__browser_tabs', { action: 'list' })).toBeUndefined()
    expect(heldTool('mcp__claude-in-chrome__get_page_text', { tabId: 1 })).toBeUndefined()
    expect(heldTool('Artifact', { file_path: '/tmp/p.html' })).toBeUndefined()
    expect(heldTool('Artifact', { action: 'read', url: 'https://claude.ai/artifact/abc' })).toBeUndefined()
    expect(heldTool('Read', { file_path: '/tmp/a' })).toBeUndefined()
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
