import { describe, expect, test } from 'claude-code/testing'
import { lastSource, powerChange, powerOf, sleepRefusal } from '../hooks/power.ts'

// pmset -g batt as it answers on a MacBook: the first line names the source in single quotes. AC is
// the answer read on the personal MacBook on 2026-10-23 ET; the battery answer was not measured (the
// Mac stayed plugged in) and keeps that shape with the other source named.
const AC = "Now drawing from 'AC Power'\n -InternalBattery-0 (id=22937699)\t80%; AC attached; not charging present: true\n"
const BATTERY = "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=22937699)\t79%; discharging; (no estimate) present: true\n"
const ran = (stdout: string, exitCode = 0, stderr = '') => ({ exitCode, stdout, stderr })

describe('powerOf: what pmset says this Mac draws from, never guessed (#844, #1545)', () => {
  test('mains and battery are read from the source pmset names', () => {
    expect(powerOf(ran(AC))).toEqual({ state: 'ac' })
    expect(powerOf(ran(BATTERY))).toEqual({ state: 'battery' })
  })
  test('a pmset that fails is unknown, with its own words', () => {
    expect(powerOf(ran('', 1, 'pmset: IOPS unavailable\n'))).toEqual({ state: 'unknown', why: 'whether this Mac is on battery could not be read (pmset: IOPS unavailable)' })
    expect(powerOf(ran('', 127))).toEqual({ state: 'unknown', why: 'whether this Mac is on battery could not be read (pmset exited 127)' })
  })
  test('an answer naming neither source is unknown, quoting its first line, never read as mains', () => {
    expect(powerOf(ran("Now drawing from 'UPS Power'\nmore\n"))).toEqual({ state: 'unknown', why: "pmset did not say what this Mac is drawing power from (Now drawing from 'UPS Power')" })
  })
})

describe('sleepRefusal: why /sleep does not start, and the notification saying so (#1545)', () => {
  test('mains refuses nothing', () => {
    expect(sleepRefusal({ state: 'ac' })).toBeNull()
  })
  test('battery keeps the reply /sleep always gave, and the notification says to plug in and run /sleep again', () => {
    expect(sleepRefusal({ state: 'battery' })).toEqual({
      text: 'Sleep mode did not start: this Mac is on battery power, and a night of work would drain it. Plug it in and run /sleep again.',
      notice: 'Sleep mode did not start: this Mac is on battery power. Plug it in and run /sleep again.',
    })
  })
  test('an unreadable reading is said as unreadable in both, never as battery', () => {
    const r = sleepRefusal({ state: 'unknown', why: 'whether this Mac is on battery could not be read (pmset exited 1)' })
    expect(r).toEqual({
      text: 'Sleep mode did not start: whether this Mac is on battery could not be read (pmset exited 1).',
      notice: 'Sleep mode did not start: whether this Mac is on battery could not be read (pmset exited 1). Check it is plugged in, then run /sleep again.',
    })
    expect(r?.notice).not.toMatch(/on battery power/)
  })
})

describe('lastSource: the power source last recorded tonight (#1545)', () => {
  test('no change recorded is mains, since /sleep starts only on mains', () => {
    expect(lastSource([])).toEqual({ last: 'ac', n: 0 })
  })
  test('the highest numbered change wins, by number, not by name order', () => {
    expect(lastSource([{ name: '9', text: 'battery' }, { name: '10', text: 'ac\n' }])).toEqual({ last: 'ac', n: 10 })
  })
  test('a name that is not a number is no change', () => {
    expect(lastSource([{ name: '.1.x.tmp', text: 'battery' }])).toEqual({ last: 'ac', n: 0 })
  })
  test('a change reading neither source is unknown, said, never guessed', () => {
    expect(lastSource([{ name: '1', text: 'mains?' }])).toEqual({ unknown: 'the power change recorded as 1 reads "mains?", which is neither source' })
  })
})

describe('powerChange: what the overnight watch notifies (#1545)', () => {
  test('onto battery and back onto mains are each a change with their own words', () => {
    expect(powerChange('ac', { state: 'battery' })).toEqual({ to: 'battery', notice: 'This Mac went onto battery power while sleep mode is on, so the night of work will drain it. Plug it back in.' })
    expect(powerChange('battery', { state: 'ac' })).toEqual({ to: 'ac', notice: 'This Mac is plugged in again, so sleep mode carries on with the night on mains power.' })
  })
  test('the source already recorded is no change, and neither is a reading it cannot make', () => {
    expect(powerChange('battery', { state: 'battery' })).toBeNull()
    expect(powerChange('ac', { state: 'ac' })).toBeNull()
    expect(powerChange('ac', { state: 'unknown', why: 'pmset exited 1' })).toBeNull()
    expect(powerChange('battery', { state: 'unknown', why: 'pmset exited 1' })).toBeNull()
  })
})
