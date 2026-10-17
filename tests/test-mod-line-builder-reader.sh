#!/bin/bash
# The design round guard's reader of what a mod's plain TypeScript hook file draws (claude-config#1275),
# run over every REAL mod hook file in this payload. The guard judges an edit to a mod's .ts hook file
# by what in it reaches what the mod draws (rules.ts drawsChange): a line builder, anything handed to
# a drawing call or used in JSX, and what those use. A reader that cannot follow the real files would
# hold every edit to them, and one that finds nothing drawn would pass every look change, so either
# would ship looking like a rule (L543, L147). The mods' own tests cannot touch the disk, so this
# reads the files under node, with rules.ts itself.
#   - Every mod's hook files are read, none refused.
#   - Real files are found to draw, so the reader is not reading nothing (L98), and most draw nothing.
#   - In the real manual steps card.ts, a divider added to cardLines (#1263's change) is a look
#     change, and the time a sent step waits (DROPPED_AFTER_MS) is not.
#   - A changed comment line in each real .ts hook file is no look change.
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
  echo "FAIL: node is not installed, so the design round guard's reader could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-line-builder-reader.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RULES="$ROOT/payload/mods/design-round-guard/hooks/rules.ts"

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
const [rules, mods] = process.argv.slice(2)
const { drawnParts, drawsChange, sourceSpans } = await import(pathToFileURL(rules).href)
for (const mod of readdirSync(mods)) {
  const hooks = `${mods}/${mod}/hooks`
  if (!existsSync(hooks)) continue
  const files = readdirSync(hooks)
    .filter(f => /\.(ts|tsx|mts|cts|jsx)$/.test(f) && !/\.d\.[mc]?ts$/.test(f))
    .map(name => ({ name, text: readFileSync(`${hooks}/${name}`, 'utf8') }))
  for (const f of files) {
    if (!/\.(ts|mts|cts)$/.test(f.name)) continue
    const rel = `payload/mods/${mod}/hooks/${f.name}`
    const parts = drawnParts(files, f.name)
    // A comment line of the file's own, changed: no look change; -1 when it has none.
    const spans = sourceSpans(f.text, false)
    const c = spans?.comments.find(([a, b]) => f.text.slice(a, b).startsWith('//'))
    const comment = c ? drawsChange(files, f.name, f.text, f.text.slice(0, c[1]) + ' (read again)' + f.text.slice(c[1])) : -1
    console.log(JSON.stringify({ rel, read: parts !== null, draws: parts ? parts.length > 0 : false, comment }))
  }
}
const hooks = `${mods}/manual-steps/hooks`
const files = readdirSync(hooks).filter(f => /\.(ts|tsx)$/.test(f) && !/\.d\.ts$/.test(f)).map(name => ({ name, text: readFileSync(`${hooks}/${name}`, 'utf8') }))
const card = files.find(f => f.name === 'card.ts')?.text ?? ''
const each = '  card.steps.forEach((s, i) => {\n'
const wait = 'export const DROPPED_AFTER_MS = 2 * 60_000'
const once = (s) => card.split(s).length === 2
console.log(JSON.stringify({
  divider: once(each) ? drawsChange(files, 'card.ts', card, card.replace(each, `${each}    if (i > 1) lines.push({ divider: true })\n`)) : 'missing',
  waits: once(wait) ? drawsChange(files, 'card.ts', card, card.replace(wait, 'export const DROPPED_AFTER_MS = 3 * 60_000')) : 'missing',
}))
JS
out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$RULES" "$ROOT/payload/mods" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the reader ran under node" "exit=$rc out=$out"
else
  files="$(printf '%s\n' "$out" | grep -c '"rel"')"
  [ "$files" -ge 10 ] && check "the real mod hook files in plain TypeScript are read" ok || check "the real mod hook files in plain TypeScript are read" "only $files found: $out"
  while IFS= read -r line; do
    case "$line" in *'"rel"'*) ;; *) continue ;; esac
    name="$(printf '%s' "$line" | sed -E 's/.*"rel":"([^"]*)".*/\1/')"
    case "$line" in *'"read":true'*) check "$name is read" ok ;; *) check "$name is read" "$line" ;; esac
    case "$line" in *'"comment":false'*|*'"comment":-1'*) check "$name: a changed comment line is no look change" ok ;; *) check "$name: a changed comment line is no look change" "$line" ;; esac
  done <<<"$out"
  measured="$(printf '%s\n' "$out" | grep -c '"comment":false')"
  [ "$measured" -ge 1 ] && check "a changed comment line was measured in at least one real file" ok || check "a changed comment line was measured in at least one real file" "none measured: $out"
  drawing="$(printf '%s\n' "$out" | grep -c '"draws":true')"
  quiet="$(printf '%s\n' "$out" | grep -c '"draws":false')"
  [ "$drawing" -ge 3 ] && check "real .ts hook files are found to draw" ok || check "real .ts hook files are found to draw" "only $drawing: $out"
  [ "$quiet" -gt "$drawing" ] && check "most real .ts hook files draw nothing" ok || check "most real .ts hook files draw nothing" "$quiet quiet against $drawing drawing: $out"
  case "$out" in *'"divider":true'*) check "a divider added to the real cardLines is a look change" ok ;; *) check "a divider added to the real cardLines is a look change" "$out" ;; esac
  case "$out" in *'"waits":false'*) check "the real DROPPED_AFTER_MS is no look change" ok ;; *) check "the real DROPPED_AFTER_MS is no look change" "$out" ;; esac
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
