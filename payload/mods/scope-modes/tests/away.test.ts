import { describe, expect, test } from 'claude-code/testing'
import { awayAllows, heldCard, heldTool, isTestBuild, needsTheMac, targetPath, targetPaths, typedTargets } from '../hooks/away.ts'
import { pipeline } from './mod-kit/hooks/commands.ts'

// Each command with what it runs, read by mod-kit's own reader (a byte for byte copy under
// tests/mod-kit, held to mod-kit's by tools/check-mod-shared-parts.sh), as the mod's tool call
// hook reads it through $.modkit.pipeline (#712, #730: never words split by hand).
const needs = (raw: string) => needsTheMac({ raw, commands: pipeline(raw) })
const HOME = '/Users/x'
const DD = `${HOME}/Library/Developer/Xcode/DerivedData`

// What a test build is (#1269, Dan 2026-10-16 ET: "an executable under Xcode's DerivedData or a
// project checkout, plus Simulator"). A checkout is the nearest folder holding .git, as mod-kit's
// workingTree reads it (stood in here by the same nearest first walk over the .git entries given);
// the home folder itself and the folders above it are never one, so a dotfiles repository in the
// home folder cannot make every app beneath it a test build.
const treeOver = (present: string[]) => async (path: string): Promise<string | null> => {
  for (let dir = path; dir; dir = dir.slice(0, dir.lastIndexOf('/'))) if (present.includes(`${dir}/.git`)) return dir
  return present.includes('/.git') ? '/' : null
}
describe('isTestBuild: what typing and clicking may target while away', () => {
  const fsWith = (...present: string[]) => ({ home: HOME, treeOf: treeOver(present) })
  test('an executable under Xcode\'s DerivedData', async () => {
    expect(await isTestBuild(`${DD}/Overture-abc/Build/Products/Debug/Overture.app/Contents/MacOS/Overture`, fsWith())).toBe(true)
  })
  test('Simulator, where Xcode keeps it', async () => {
    expect(await isTestBuild('/Applications/Xcode.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator', fsWith())).toBe(true)
    expect(await isTestBuild('/Applications/Xcode-beta.app/Contents/Developer/Applications/Simulator.app/Contents/MacOS/Simulator', fsWith())).toBe(true)
    expect(await isTestBuild('/Users/x/Downloads/Simulator.app/Contents/MacOS/Simulator', fsWith())).toBe(false)
  })
  test('an executable inside a project checkout, a worktree included', async () => {
    const app = `${HOME}/Apps/Overture/build/Debug/Overture.app/Contents/MacOS/Overture`
    expect(await isTestBuild(app, fsWith(`${HOME}/Apps/Overture/.git`))).toBe(true)
    expect(await isTestBuild('/tmp/wt/out/Tool', fsWith('/tmp/wt/.git'))).toBe(true)
  })
  test('an installed app is not', async () => {
    expect(await isTestBuild('/Applications/Mail.app/Contents/MacOS/Mail', fsWith())).toBe(false)
    expect(await isTestBuild('/Applications/Overture.app/Contents/MacOS/Overture', fsWith())).toBe(false)
    expect(await isTestBuild('/System/Applications/Messages.app/Contents/MacOS/Messages', fsWith())).toBe(false)
  })
  test('the home folder or anything above it holding .git makes nothing a test build', async () => {
    expect(await isTestBuild(`${HOME}/Applications/Mail.app/Contents/MacOS/Mail`, fsWith(`${HOME}/.git`, '/.git', '/Users/.git'))).toBe(false)
  })
  test('a path that is not absolute, or climbs with .., is not', async () => {
    expect(await isTestBuild('build/Debug/Overture', fsWith('build/.git'))).toBe(false)
    expect(await isTestBuild(`${DD}/../../../../../Applications/Mail.app/Contents/MacOS/Mail`, fsWith())).toBe(false)
  })
  test('a checkout that cannot be read (mod-kit not loaded, the disk not answering) is not a test build, so the action stays held (L42)', async () => {
    const throws = { home: HOME, treeOf: async () => { throw new Error('denied') } }
    expect(await isTestBuild(`${HOME}/Apps/Overture/build/Overture`, throws)).toBe(false)
  })
  test('with no home known, DerivedData under any home still counts, and no home folder is a checkout', async () => {
    expect(await isTestBuild('/Users/y/Library/Developer/Xcode/DerivedData/a/Tool', { home: undefined, treeOf: async () => null })).toBe(true)
    expect(await isTestBuild('/Users/y/Applications/Mail.app/Contents/MacOS/Mail', { home: undefined, treeOf: treeOver(['/Users/y/.git']) })).toBe(false)
  })
  test('a checkout inside a home folder that is itself a repository still counts, as the nearest one', async () => {
    expect(await isTestBuild(`${HOME}/Apps/Overture/build/Overture`, fsWith(`${HOME}/.git`, `${HOME}/Apps/Overture/.git`))).toBe(true)
  })
})

describe('awayAllows: what another guard may do while away without its action being held (#1269)', () => {
  const fs = { home: HOME, treeOf: async () => null }
  test('bringing an app forward', async () => {
    expect(await awayAllows({ kind: 'focus' }, fs)).toBe(true)
  })
  test('typing into a test build, never into anything else or into no named app', async () => {
    expect(await awayAllows({ kind: 'input', target: `${DD}/a/Overture` }, fs)).toBe(true)
    expect(await awayAllows({ kind: 'input', target: '/Applications/Overture.app/Contents/MacOS/Overture' }, fs)).toBe(false)
    expect(await awayAllows({ kind: 'input' }, fs)).toBe(false)
  })
})

describe('targetPath: the executable TARGET_APP names, as written', () => {
  test('bare, double quoted or single quoted', () => {
    expect(targetPath('TARGET_APP=/a/b/Tool cliclick c:1,1')).toBe('/a/b/Tool')
    expect(targetPath('TARGET_APP="/a b/Tool" cliclick c:1,1')).toBe('/a b/Tool')
    expect(targetPath("TARGET_APP='/a b/Tool' cliclick c:1,1")).toBe('/a b/Tool')
    expect(targetPath('cliclick c:1,1')).toBeUndefined()
  })
  // Lessons review of #1269: a marker in an echo, or one command's marker standing for another's,
  // must not make a call a test build's. Each typing or clicking command carries its own marker,
  // written right before it, and there is no other marker.
  test('typedTargets: the target of each typing or clicking command, only when each names its own', () => {
    const KS = `osascript -e 'tell application "System Events" to keystroke "n"'`
    const t = (raw: string) => typedTargets(raw, pipeline(raw))
    expect(t(`TARGET_APP=/a/Tool ${KS}`)).toEqual(['/a/Tool'])
    expect(t(`open -a Simulator && TARGET_APP="/b c/Tool" ${KS}`)).toEqual(['/b c/Tool'])
    expect(t('TARGET_APP=/a/Tool cliclick c:1,1')).toEqual(['/a/Tool'])
    expect(t(`echo TARGET_APP=/a/Tool && ${KS}`)).toBeUndefined()
    expect(t(`TARGET_APP=/a/Tool ${KS}; ${KS}`)).toBeUndefined()
    expect(t(KS)).toBeUndefined()
  })
  test('every one a call carries, wherever it stands, for the rule that all of them must be test builds', () => {
    expect(targetPaths('echo TARGET_APP=/a/Tool && TARGET_APP="/b c/Mail" osascript -e x')).toEqual(['/a/Tool', '/b c/Mail'])
    expect(targetPaths('npm test')).toEqual([])
  })
})

describe('needsTheMac: what is held while Dan is away', () => {
  // #1269, Dan (2026-10-16 ET): "I don't care if you bring apps to the front or do automations for
  // testing". Opening an app or a file, BBEdit's helper and bringing an app forward run while away.
  test('opening an app, a file or a link runs while away', () => {
    expect(needs('open -a "Google Chrome" /tmp/report.html')).toBeUndefined()
    expect(needs('open /Users/x/shot.png')).toBeUndefined()
    expect(needs('open -a Preview a.pdf b.pdf')).toBeUndefined()
    expect(needs('open "https://x.com/a?token=abc#f"')).toBeUndefined()
    expect(needs('open -a Simulator')).toBeUndefined()
  })
  test("BBEdit's helper runs while away", () => {
    expect(needs('/Applications/BBEdit.app/Contents/Helpers/bbedit_tool --front-window /tmp/d.md')).toBeUndefined()
  })
  test('an app brought to the front runs while away', () => {
    expect(needs(`osascript -e 'tell application "Google Chrome" to activate'`)).toBeUndefined()
    expect(needs(`osascript -e 'tell application "System Events" to set frontmost of process "Overture" to true'`)).toBeUndefined()
  })
  test("typing or clicking into an app that is not a test build is held, named by the app TARGET_APP names", () => {
    const raw = `TARGET_APP=/Applications/Overture.app/Contents/MacOS/Overture osascript -e 'tell application "System Events" to keystroke "n" using command down'`
    expect(needs(raw)).toBe('Type into Overture')
    expect(needs('TARGET_APP=/Applications/Overture.app/Contents/MacOS/Overture cliclick c:10,10')).toBe('Click in Overture')
    expect(needs(`osascript -e 'tell application "System Events" to keystroke "n"'`)).toBe('Type into an app')
  })
  test('typing or clicking into a test build runs while away (the keystroke guard still proves it is in front)', () => {
    const raw = `TARGET_APP=${DD}/Overture-abc/Build/Products/Debug/Overture.app/Contents/MacOS/Overture osascript -e 'tell application "System Events" to keystroke "n"'`
    expect(needsTheMac({ raw, commands: pipeline(raw), testBuild: true })).toBeUndefined()
    expect(needsTheMac({ raw: `TARGET_APP=${DD}/x/Overture cliclick c:1,1`, commands: pipeline('cliclick c:1,1'), testBuild: true })).toBeUndefined()
  })
  test('a dialog is held even from a script that types into a test build', () => {
    const raw = `TARGET_APP=${DD}/x/Overture osascript -e 'display dialog "x"'`
    expect(needsTheMac({ raw, commands: pipeline(raw), testBuild: true })).toBe('Show a dialog on the Mac')
  })
  test('a script it cannot read is held even beside a test build', () => {
    expect(needsTheMac({ raw: `TARGET_APP=${DD}/x/Overture osascript front.scpt`, commands: pipeline('osascript front.scpt'), testBuild: true })).toBe('Run an AppleScript on the Mac')
  })
  test('an AppleScript that only reads takes no focus and is not held', () => {
    expect(needs(`osascript -e 'tell application "System Events" to get name of first process whose frontmost is true'`)).toBeUndefined()
  })
  test('everything else runs as usual', () => {
    expect(needs('npm test')).toBeUndefined()
    expect(needs('cat open.txt')).toBeUndefined()
  })
  // The milestone audit (#702): what still opened something or took focus while away.
  test('an AppleScript dialog, which takes focus; a notification banner does not', () => {
    expect(needs(`osascript -e 'display dialog "hi"'`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'display alert "x"'`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'choose file'`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -e 'display notification "done"'`)).toBeUndefined()
  })
  // #730: JavaScript for Automation spells a dialog as a method, which the AppleScript words missed.
  test('a dialog shown by JavaScript for Automation is held too', () => {
    expect(needs(`osascript -l JavaScript -e 'app.displayDialog("Done?")'`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -l JavaScript -e 'Application.currentApplication().chooseFile()'`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript -l JavaScript -e 'Application("Mail").name()'`)).toBeUndefined()
  })
  test("an AppleScript fed by a heredoc's body is judged by it, as the reader gives it (#712)", () => {
    expect(needs(`osascript <<'EOF'\ndisplay dialog "x"\nEOF`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript <<'EOF'\ndisplay notification "done"\nEOF`)).toBeUndefined()
    expect(needs(`bash -c 'osascript' <<< 'tell application "System Events" to keystroke "n"'`)).toBe('Type into an app')
  })
  test('an AppleScript fed by a here-string or echo is judged by its text; one fed by a heredoc, which cannot be read, is held', () => {
    expect(needs(`osascript <<< 'tell application "System Events" to keystroke "n"'`)).toBe('Type into an app')
    expect(needs(`echo 'display dialog "x"' | osascript`)).toBe('Show a dialog on the Mac')
    expect(needs(`osascript <<< 'tell application "Finder" to activate'`)).toBeUndefined()
    expect(needs(`osascript <<'EOF'`)).toBe('Run an AppleScript on the Mac')
  })
  // #724: a script file was never judged, so one that shows a dialog or activates an app ran.
  test('an AppleScript in a file, or one that runs a script it cannot read, is held', () => {
    expect(needs('osascript notify.scpt')).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript -s o ~/bin/front.applescript Overture')).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript -l JavaScript front.js')).toBe('Run an AppleScript on the Mac')
    expect(needs('osascript < front.applescript')).toBe('Run an AppleScript on the Mac')
    expect(needs(`osascript -e 'run script file "x.scpt"'`)).toBe('Run an AppleScript on the Mac')
    // #730: cat of a script file pipes that file in, as `osascript notify.scpt` names it.
    expect(needs('cat notify.scpt | osascript')).toBe('Run an AppleScript on the Mac')
    // A script file run by anything but osascript is no AppleScript.
    expect(needs('python3 tools/report.py')).toBeUndefined()
    expect(needs('osascript -l JavaScript')).toBeUndefined()
  })
})

describe('heldTool: the tools that open something on the Mac by another route than Bash (#702)', () => {
  // #1269: browser automation is testing, so opening a page or a tab runs while away.
  test('a browser opened or pointed somewhere, by Playwright or in Chrome, runs while away', () => {
    expect(heldTool('mcp__playwright__browser_navigate', { url: 'https://x.dev/a?token=abc' })).toBeUndefined()
    expect(heldTool('mcp__plugin_playwright_playwright__browser_navigate', { url: 'https://x.dev' })).toBeUndefined()
    expect(heldTool('mcp__playwright__browser_tabs', { action: 'new' })).toBeUndefined()
    expect(heldTool('mcp__claude-in-chrome__navigate', { url: 'https://x.dev', tabId: 1 })).toBeUndefined()
    expect(heldTool('mcp__claude-in-chrome__tabs_create_mcp', {})).toBeUndefined()
  })
  // Kept held (Dan, 2026-10-16): it exists only to show him a page, so it waits for when he is back.
  test("the Artifact tool's open action, which opens the page in the browser, is held", () => {
    expect(heldTool('Artifact', { action: 'open', url: 'https://claude.ai/artifact/abc' })).toBe('Open https://claude.ai/artifact/abc')
  })
  test('a link keeps its address but never its query or fragment, which can carry a token (L741)', () => {
    expect(heldTool('Artifact', { action: 'open', url: 'https://claude.ai/artifact/abc?token=x#f' })).toBe('Open https://claude.ai/artifact/abc')
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
