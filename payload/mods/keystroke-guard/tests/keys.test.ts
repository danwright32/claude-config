import { describe, expect, test } from 'claude-code/testing'
import { appNameOf, classify, judge } from '../hooks/keys.ts'

const OVERTURE = '/Applications/Overture.app/Contents/MacOS/Overture'

describe('classify', () => {
  const input: [string, string][] = [
    ['an osascript keystroke', `TARGET_APP=${OVERTURE} osascript -e 'tell application "System Events" to keystroke "n" using command down'`],
    ['an osascript key code', `osascript -e 'tell application "System Events" to key code 36'`],
    ['an osascript click', `osascript -e 'tell application "System Events" to click button 1 of window 1 of process "X"'`],
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

  test('an ordinary command is neither', () => expect(classify('git status').kind).toBe('none'))
  test('a bare open of a file is neither', () => expect(classify('open -R ~/x.txt').kind).toBe('none'))
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

describe('judge', () => {
  test('an undeclared target is refused', () => {
    expect(judge({ target: undefined, targetPids: [], otherPids: [], frontmost: 1 })).toMatch(/TARGET_APP/)
  })
  test('a target that is not running is refused', () => {
    expect(judge({ target: OVERTURE, targetPids: [], otherPids: [], frontmost: 1 })).toMatch(/not running/)
  })
  test('a second running copy of the app is refused', () => {
    expect(judge({ target: OVERTURE, targetPids: [10], otherPids: [11], frontmost: 10 })).toMatch(/another copy/)
  })
  test('a wrong frontmost app is refused', () => {
    expect(judge({ target: OVERTURE, targetPids: [10], otherPids: [], frontmost: 99 })).toMatch(/frontmost/)
  })
  test('an unreadable frontmost app is refused, never passed (L42)', () => {
    expect(judge({ target: OVERTURE, targetPids: [10], otherPids: [], frontmost: undefined })).toMatch(/could not/)
  })
  test('two pids for the target path is refused too', () => {
    expect(judge({ target: OVERTURE, targetPids: [10, 12], otherPids: [], frontmost: 10 })).toMatch(/copies|more than one/)
  })
  test('the right app frontmost, alone, passes', () => {
    expect(judge({ target: OVERTURE, targetPids: [10], otherPids: [], frontmost: 10 })).toBeUndefined()
  })
})
