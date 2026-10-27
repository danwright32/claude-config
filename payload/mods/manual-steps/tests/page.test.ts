import { describe, expect } from 'claude-code/testing'
import { test } from './mod-kit/tests/hang-ceiling.ts'
import { isStepsPage, signsOf } from '../hooks/page.ts'

// #1811: a page Claude publishes is judged by what it holds, since a mod cannot add a marker to the
// built in Artifact publish and a model judge would cost money on every turn. The pages here are
// shaped after the real ones measured on 2026-10-27 (docs/mods-design.md "Manual steps"): the page of
// checks for Dan held ticks, Copy buttons and numbered steps that open and click, while every report
// held numbered facts and none of the three.

const html = (body: string) => `<!doctype html><html><head><title>t</title><style>li{color:red}</style></head><body>${body}</body></html>`

describe('signsOf', () => {
  test('counts ticks, Copy buttons and list items that tell a person what to do at a screen', () => {
    const page = html(`
      <ol>
        <li>Open the <b>Regal</b> journey.</li>
        <li><strong>Click</strong> the No exit of node 3.</li>
        <li>The journey has 14 nodes.</li>
      </ol>
      <label><input type="checkbox" class="check"> Done</label>
      <code>Marcia call?</code><button class="cp" data-copy="Marcia call?">Copy</button>
      <script>navigator.clipboard.writeText(x); var s = '<li>Click here</li>'</script>`)
    expect(signsOf(page)).toEqual({ ticks: 1, copies: 2, actions: 2 })
  })

  test('a step numbered in its own words ("Step 2: Paste ...") still counts as one to do', () => {
    expect(signsOf(html('<ol><li><b>Step 2:</b> Paste the token.</li><li>Step 3. Press Save.</li></ol>')).actions).toBe(2)
  })

  test('a Markdown page counts its numbered steps and its task boxes', () => {
    const md = '# Changes\n\n1. Open Regal and find the journey.\n2. **Click** the node.\n3. The node is the third one.\n\n- [ ] journey 1\n- [x] journey 2\n'
    expect(signsOf(md)).toEqual({ ticks: 2, copies: 0, actions: 2 })
    // A bulleted list of things to do counts as an HTML <ul> does.
    expect(signsOf('- Open Regal.\n- Click **Save**.\n').actions).toBe(2)
  })
})

describe('isStepsPage', () => {
  test('a page of steps for Dan, as measured: the 2026-10 page of live checks and the Regal journey edits page', () => {
    // The live checks page, as signsOf reads it: 14 ticks, 8 Copy signs, 6 things to do at a screen.
    expect(isStepsPage({ ticks: 14, copies: 8, actions: 6 })).toBe(true)
    // The Regal edits page built from its skill's own fixture: ticks and Copy buttons, its steps
    // written as sentences, so only one leads with an action.
    expect(isStepsPage({ ticks: 2, copies: 10, actions: 1 })).toBe(true)
  })

  test('two list items that each begin with a thing to do at a screen make a page of steps on their own', () => {
    expect(isStepsPage(signsOf(html('<ol><li>Open Settings.</li><li>Turn on <b>Remote control</b>.</li></ol>')))).toBe(true)
  })

  test('a report Dan only reads is not a page of steps: numbered facts, no ticks, no Copy', () => {
    const report = html(`
      <h1>Overnight report</h1>
      <ol><li>Merged #812, the band fix.</li><li>#813 is waiting on CI.</li><li>Run time was 4 hours.</li></ol>`)
    expect(isStepsPage(signsOf(report))).toBe(false)
  })

  test('one sign alone is not enough: a design mock with a checkbox, or a page with one Copy, is not steps', () => {
    expect(isStepsPage(signsOf(html('<form><label><input type="checkbox"> Remember me</label></form>')))).toBe(false)
    expect(isStepsPage(signsOf(html('<p>The command:</p><code>ls</code><button>Copy</button>')))).toBe(false)
    expect(isStepsPage(signsOf(html('<ol><li>Open the PR when CI is green.</li><li>The tests pass.</li></ol>')))).toBe(false)
  })
})
