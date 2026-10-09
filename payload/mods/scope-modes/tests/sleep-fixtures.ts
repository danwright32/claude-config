// The one committed fixture set both readers of the sleep record are held to (#840, L26): the
// mod's readSleep (hooks/sleep.ts, tests/sleep.test.ts) and the shell's sleep_state
// (payload/hooks/lib/sleep.sh, payload/hooks/test-sleep-state.sh). Each case is the record file's
// text exactly as it would sit on disk (null: no file), the time now in ms, this boot's start in
// seconds (null: it could not be read, when only the end decides), and the state both must answer.
//
// Everything after each `=` below, to the `]` that closes it at the start of a line, is plain JSON,
// which is what lets the shell suite read it too: keep it JSON (double quotes, no trailing commas,
// no comments inside), or that suite fails.
//
// This boot, as each reader takes it from `sysctl -n kern.boottime` (the mod's bootOf, the shell's
// sleep_boot_of): the seconds after the first `sec =`, never the `usec` after them. The shell's
// first reader took the last `sec =` on the line, which is the microseconds, so every shell route
// judged a sound record as another boot's; the real engine run of #838 found it, since both
// readers' suites had derived the boot the same wrong way they read it (L70).
export const BOOT_FIXTURES = [
  { "name": "the seconds, not the microseconds after them", "text": "{ sec = 1759800000, usec = 123456 } Tue Oct  7 01:20:00 2025\n", "boot": 1759800000 },
  { "name": "nothing printed", "text": "", "boot": null },
  { "name": "an error in place of the time", "text": "sysctl: unknown oid 'kern.boottime'", "boot": null }
]

// This boot's session, as each reader takes it from `sysctl -n kern.bootsessionuuid` (the mod's
// bootSessionOf, the shell's sleep_boot_session_of): the first line, a UUID, in upper case. It names
// the boot itself, so unlike kern.boottime no clock correction can move it; only a restart makes a
// new one.
export const SESSION_FIXTURES = [
  { "name": "the UUID sysctl prints", "text": "11111111-2222-3333-4444-555555555555\n", "session": "11111111-2222-3333-4444-555555555555" },
  { "name": "lower case, read as upper", "text": "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\n", "session": "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" },
  { "name": "only the first line", "text": "11111111-2222-3333-4444-555555555555\nsomething after it\n", "session": "11111111-2222-3333-4444-555555555555" },
  { "name": "nothing printed", "text": "", "session": null },
  { "name": "an error in place of the UUID", "text": "sysctl: unknown oid 'kern.bootsessionuuid'", "session": null },
  { "name": "not a UUID", "text": "1791403879\n", "session": null }
]

// Each case below may also carry `session`, this boot's session (absent or null: it could not be
// read). The boot is judged by the record's `bootSession` against it wherever both are known, and
// only otherwise by `bootTime` against this boot's start, within BOOT_TIME_TOLERANCE_S (300 s,
// hooks/sleep.ts) either way: a clock correction moves kern.boottime by seconds (2 s on
// 2026-10-08, with the Mac up since the day before), so an exact match ended the night on the
// shell side while the mod, holding its first reading, still said asleep.
export const SLEEP_FIXTURES = [
  { "name": "valid", "text": "{\"v\":1,\"generation\":\"g1\",\"since\":1791345600000,\"until\":1791388800000,\"night\":\"2026-10-07\",\"bootTime\":1759800000,\"report\":\"/Users/x/Downloads/Sleep report 2026-10-07.md\",\"startedBy\":{\"sessionId\":\"s1\",\"cwd\":\"/repo\"},\"workers\":[\"s1\"],\"placeBefore\":\"home\"}", "now": 1791360000000, "boot": 1759800000, "state": "asleep" },
  { "name": "one ms before until", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791388799999, "boot": 1759800000, "state": "asleep" },
  { "name": "at until exactly", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791388800000, "boot": 1759800000, "state": "expired" },
  { "name": "expired", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791400000000, "boot": 1759800000, "state": "expired" },
  { "name": "other boot", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759700000}", "now": 1791360000000, "boot": 1759800000, "state": "other-boot" },
  { "name": "other boot and expired", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759700000}", "now": 1791400000000, "boot": 1759800000, "state": "other-boot" },
  { "name": "boot not readable: the record still holds until its end", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791360000000, "boot": null, "state": "asleep" },
  { "name": "boot not readable and past its end", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791400000000, "boot": null, "state": "expired" },
  { "name": "boot not readable and the record broken", "text": "{\"v\":1,\"until\":1791388800000}", "now": 1791360000000, "boot": null, "state": "unreadable" },
  { "name": "malformed", "text": "{\"v\":1,\"until\":17913888", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "v 2, a later writer with a field this reader does not know", "text": "{\"v\":2,\"generation\":\"g2\",\"until\":1791388800000,\"bootTime\":1759800000,\"later\":{\"x\":1}}", "now": 1791360000000, "boot": 1759800000, "state": "asleep" },
  { "name": "v 0", "text": "{\"v\":0,\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "v missing", "text": "{\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "v true", "text": "{\"v\":true,\"until\":1791388800000,\"bootTime\":1759800000}", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "until a string", "text": "{\"v\":1,\"until\":\"1791388800000\",\"bootTime\":1759800000}", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "bootTime missing", "text": "{\"v\":1,\"until\":1791388800000}", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "a list, not a record", "text": "[1,2]", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "empty", "text": "", "now": 1791360000000, "boot": 1759800000, "state": "unreadable" },
  { "name": "the boot start moved 2 seconds by a clock correction, the same boot session", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800002,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "the boot start moved 2 seconds the other way, the same boot session", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759799998,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "the same boot session, the start far off: the session decides", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759700000,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "the same boot session in another case", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "another boot session, the same start", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "other-boot" },
  { "name": "another boot session and past its end", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\"}", "now": 1791400000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "other-boot" },
  { "name": "another boot session, this start unknown", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE\"}", "now": 1791360000000, "boot": null, "session": "11111111-2222-3333-4444-555555555555", "state": "other-boot" },
  { "name": "the same boot session, this start unknown", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": null, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "this boot session unknown: the start decides, 2 seconds off", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800002,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": null, "state": "asleep" },
  { "name": "this boot session unknown and the start far off", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759700000,\"bootSession\":\"11111111-2222-3333-4444-555555555555\"}", "now": 1791360000000, "boot": 1759800000, "session": null, "state": "other-boot" },
  { "name": "an older record with no boot session, its start 2 seconds off", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800002}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "an older record, its start off by the whole tolerance", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800300}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "asleep" },
  { "name": "an older record, its start a second past the tolerance", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800301}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "other-boot" },
  { "name": "an older record, its start a second past the tolerance the other way", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759799699}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "other-boot" },
  { "name": "an older record, its start a second inside the tolerance the other way", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759799701}", "now": 1791360000000, "boot": 1759800000, "session": null, "state": "asleep" },
  { "name": "a boot session that is not text", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":12}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "unreadable" },
  { "name": "a boot session that is null", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":null}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "unreadable" },
  { "name": "a boot session that is empty", "text": "{\"v\":1,\"generation\":\"g1\",\"until\":1791388800000,\"bootTime\":1759800000,\"bootSession\":\"\"}", "now": 1791360000000, "boot": 1759800000, "session": "11111111-2222-3333-4444-555555555555", "state": "unreadable" },
  { "name": "no record", "text": null, "now": 1791360000000, "boot": 1759800000, "state": "none" }
]
