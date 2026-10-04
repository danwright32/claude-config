import { describe, expect, test } from 'claude-code/testing'
import { appNameOf, classify, judge } from '../hooks/keys.ts'

const OVERTURE = '/Applications/Overture.app/Contents/MacOS/Overture'
const KEY = 'key' + 'stroke'

describe('classify', () => {
  const input: [string, string][] = [
    ['an osascript keystroke', `TARGET_APP=${OVERTURE} osascript -e 'tell application "System Events" to ${KEY} "n" using command down'`],
    ['an osascript key code', `osascript -e 'tell application "System Events" to key code 36'`],
    ['an osascript click', `osascript -e 'tell application "System Events" to click button 1 of window 1 of process "X"'`],
    ['an osascript keystroke whose script spans lines', `osascript -e 'tell application "System Events"\n  ${KEY} "n" using command down\nend tell'`],
    ['an osascript keystroke after another command', `cd /tmp && osascript -e 'tell application "System Events" to ${KEY} "n"'`],
    ['an osascript keystroke inside bash -c', `bash -c "osascript -e 'tell application \\"System Events\\" to ${KEY} \\"n\\"'"`],
    ['cliclick', 'cliclick c:100,200'],
    ['peekaboo type', 'peekaboo type "hello"'],
    ['peekaboo hotkey', 'peekaboo hotkey --keys cmd,n'],
    ['peekaboo click', 'peekaboo click --on B1'],
  ]
  for (const [name, cmd] of input) test(`${name} is synthetic input`, () => expect(classify(cmd).kind).toBe('input'))

  const focus: [string, string][] = [
    ['open -a', 'open -a "Google Chrome" report.html'],
    ['an activate', `osascript -e 'tell application "Overture" to activate'`],
    ['set frontmost', `osascript -e 'tell application "System Events" to set frontmost of process "Overture" to true'`],
  ]
  for (const [name, cmd] of focus) test(`${name} steals focus`, () => expect(classify(cmd).kind).toBe('focus'))

  const neither: [string, string][] = [
    ['an ordinary command', 'git status'],
    ['a Python venv activate', 'source .venv/bin/activate && pytest'],
    ['a conda activate', 'conda activate base'],
    ['a search that mentions set frontmost', 'grep -n "set frontmost" notes.txt'],
    ['a bare open of a file', 'open -R ~/x.txt'],
    // The command that blocked this mod's own author on 2026-10-03: a file being WRITTEN whose
    // text mentions an osascript keystroke. Nothing is typed anywhere (L673).
    ['a heredoc that only writes the words', `cat > builder.js <<'EOF'\n  var s = "osascript -e 'tell application \\"System Events\\" to ${KEY} \\"n\\"'"\nEOF`],
    ['an echo of the words', `echo "osascript ${KEY}" > notes.txt`],
  ]
  for (const [name, cmd] of neither) test(`${name} is neither`, () => expect(classify(cmd).kind).toBe('none'))

  test('the declared target is read from the marker', () => {
    expect(classify(`TARGET_APP=${OVERTURE} cliclick c:1,1`).target).toBe(OVERTURE)
    expect(classify(`TARGET_APP="${OVERTURE}" cliclick c:1,1`).target).toBe(OVERTURE)
  })
  test('the app a focus stealer names is read', () => {
    expect(classify('open -a "Google Chrome" r.html').app).toBe('Google Chrome')
    expect(classify(`osascript -e 'tell application "Overture" to activate'`).app).toBe('Overture')
  })
  test('the app name comes from the bundle in the path', () => expect(appNameOf(OVERTURE)).toBe('Overture'))
})

// Wording settled with Dan, 2026-10-03 (docs/mods-design.md): a reason, then the safe way.
describe('judge', () => {
  const base = { target: OVERTURE, targetPids: [10], otherPids: [] as number[], frontmost: 10 as number | undefined, frontName: 'Overture' }
  test('an undeclared target is refused', () => {
    expect(judge({ ...base, target: undefined })).toEqual({
      reason: "This doesn't say which app it types into.",
      safeWay: "Add TARGET_APP=<the app's executable path> to the command.",
    })
  })
  test('a target that is not running is refused', () => {
    expect(judge({ ...base, targetPids: [] })).toEqual({ reason: "Overture isn't running.", safeWay: 'Open it first, then type.' })
  })
  test('a second running copy of the app is refused', () => {
    expect(judge({ ...base, otherPids: [11] })).toEqual({
      reason: 'Another copy of Overture is running (pid 11).',
      safeWay: "Quit the one you're not using first.",
    })
  })
  test('a wrong frontmost app is refused, naming the app that is in front', () => {
    expect(judge({ ...base, frontmost: 99, frontName: 'Adobe Lightroom Classic' })).toEqual({
      reason: "Overture isn't the front app (Adobe Lightroom Classic is).",
      safeWay: 'Bring it forward first, then type.',
    })
  })
  test('an unreadable frontmost app is refused, never passed (L42)', () => {
    expect(judge({ ...base, frontmost: undefined })).toEqual({
      reason: "Couldn't tell which app is in front, so the input could land anywhere.",
      safeWay: 'Try again in a moment.',
    })
  })
  test('two pids for the target path is refused too', () => {
    expect(judge({ ...base, targetPids: [10, 12] })).toEqual({
      reason: 'Overture is running twice from the same place, so the input could land in either.',
      safeWay: 'Quit one first.',
    })
  })
  test('the right app frontmost, alone, passes', () => {
    expect(judge(base)).toBeUndefined()
  })
})
