#!/bin/bash
# The Slack alert guard's reading of the REAL Slack drafts gate (claude-config#2662), run against the
# guard's real rules.ts and the gate's real files, where they live, never a copy. The mod's own tests
# cannot read a file outside the mod's folder, so they hold a few of the gate's lines; this suite
# holds the whole files to the same answer, so a change to either side that makes the guard read the
# gate as a file that posts to Slack again turns red here (L48, L58).
#
# Dan, 2026-11-10: "Recognise refusal code". The gate names chat.postMessage and hooks.slack.com in
# a pattern so it can refuse them, and the guard read it as a sender: it held what the gate prints
# on stderr (#2576) and edits to lib/issue-spool.sh, which the gate's docstrings name, as "Slack
# message text Dan has not approved". No file is exempted by name: the guard tells a name written
# only to be matched from one that is used.
#   - The gate's wrapper and its python half each carry a Slack marker (so these checks are about
#     the rule, never a gate that stopped naming endpoints), and neither is a sender, with or
#     without the #2576 advice added.
#   - lib/issue-spool.sh is no sender. Since #2837 the guard stops only on a file that posts by
#     itself, so whether some sender reads the spool no longer decides anything and is not checked.
#   - The control: skills/nudge/nudge.py, which really posts, is still a sender, and so is the
#     gate's wrapper with a posting line added to it.
#   - The guard's own source carries no marker of its own, so the guard never reads itself as a
#     file that posts (a function named for a Slack send made it one while this was being built).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the Slack alert guard's reading of the drafts gate could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-slack-alert-guard-real-gate.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
EXPECTED=12

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync, readdirSync } from 'node:fs'
const [root] = process.argv.slice(2)
const MOD = 'payload/mods/slack-alert-guard/hooks'
const { codeOf, isProseFile, isSender, slackMarked, testFile } = await import(`${root}/${MOD}/rules.ts`)
const read = rel => readFileSync(`${root}/${rel}`, 'utf8')
let n = 0
const say = (name, ok, evidence) => {
  n++
  console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
}
const WRAPPER = 'payload/hooks/slack-drafts-only-gate.sh'
const PYTHON = 'payload/hooks/slack_drafts_only_gate.py'
const SPOOL = 'payload/hooks/lib/issue-spool.sh'
const NUDGE = 'payload/skills/nudge/nudge.py'

for (const rel of [WRAPPER, PYTHON]) {
  const text = read(rel)
  say(`${rel} carries a Slack marker in its code, so it was a sender before`, slackMarked(codeOf(rel, text)), 'no marker in its code: the gate no longer names an endpoint, and the checks below prove nothing')
  say(`${rel} is no sender when it is the file edited`, !isSender(rel, text, true), 'the guard reads it as a file that posts to Slack')
  say(`${rel} is no sender when another file is searched for what sends it`, !isSender(rel, text), 'the guard reads it as a file that posts to Slack')
}

// The edit held on 2026-11-09 (#2576): the advice the gate prints on stderr.
const wrapper = read(WRAPPER)
const advice = `merge_instead() {\n  case "$payload" in *merge-when-ready.sh*) ;; *) return 0 ;; esac\n  printf '%s\\n' 'This call runs merge-when-ready.sh, so do not retry it in a loop.' >&2\n}\n`
const at = wrapper.indexOf('case "$verdict" in')
say('the wrapper still has the place the #2576 advice goes', at >= 0, 'no `case "$verdict" in` line')
const advised = `${wrapper.slice(0, at)}${advice}${wrapper.slice(at)}`
say('the wrapper with the #2576 advice added is no sender', at >= 0 && !isSender(WRAPPER, advised, true), 'the guard reads it as a file that posts to Slack')
// The control: the same wrapper with a line that posts.
say('the wrapper with a posting line added is a sender', isSender(WRAPPER, `${wrapper}\ncurl -s --data "$detail" "$SLACK_WEBHOOK_URL"\n`, true), 'a script that refuses and also posts was not read as a sender')

// Every file under payload that could send, read as the guard's search reads one.
const walk = dir => readdirSync(`${root}/${dir}`, { withFileTypes: true }).flatMap(e => (e.isDirectory() ? walk(`${dir}/${e.name}`) : e.isFile() ? [`${dir}/${e.name}`] : []))
const senders = walk('payload').filter(rel => {
  if (testFile(rel) || isProseFile(rel)) return false
  const text = read(rel)
  return /slack|postmessage/i.test(text) && isSender(rel, text)
})
say(`${SPOOL} is no sender itself`, !isSender(SPOOL, read(SPOOL), true), 'the guard reads it as a file that posts to Slack')
say(`${NUDGE}, which posts, is still a sender`, senders.includes(NUDGE), `the senders found: ${senders.join(', ') || 'none'}`)

// The guard's own source: no marker anywhere in it, comments included.
const own = readdirSync(`${root}/${MOD}`).filter(f => f.endsWith('.ts')).map(f => `${MOD}/${f}`)
const marked = own.filter(rel => slackMarked(read(rel)))
say("the guard's own source carries no Slack marker", own.length >= 3 && marked.length === 0, own.length < 3 ? `only ${own.length} source files found` : `${marked.join(', ')} would be read as a file that posts to Slack`)
console.log(`SENDERS\t${senders.join(' ')}`)
console.log(`DONE\t${n}`)
JS

out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$ROOT" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the guard's real rules.ts ran under node" "exit=$rc out=$out"
else
  seen=0
  while IFS=$'\t' read -r verdict name evidence; do
    case "$verdict" in
      PASS) seen=$((seen + 1)); check "$name" ok ;;
      FAIL) seen=$((seen + 1)); check "$name" "$evidence" ;;
    esac
  done <<<"$out"
  done_line="$(printf '%s\n' "$out" | grep -c "^DONE	$EXPECTED\$")"
  # Judged by the count run against the count expected, so a check that never ran is a failure (L288).
  [ "$seen" -eq "$EXPECTED" ] && [ "$done_line" -eq 1 ] && check "all $EXPECTED checks ran" ok || check "all $EXPECTED checks ran" "$seen ran: $out"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
