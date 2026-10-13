#!/bin/bash
# The design round guard's reader of what a mod's hook file draws (claude-config#1138), run over every
# REAL mod hook file in TSX or JSX in this payload. The guard lets a logic edit to such a file through
# unasked only when its reader (rules.ts sourceSpans) can follow the whole file, and holds the edit
# otherwise, so a reader that cannot follow the real files would quietly hold every edit to them and
# the rule would ship inert (L543, L147). The mods' own tests cannot touch the disk, so this reads the
# files under node, with rules.ts itself.
#   - Every mod hook file in TSX or JSX is read, none refused, and elements are found in them: they
#     draw Claude Code's panels, which is why they count as screen files at all. (Manual steps holds
#     none: it draws only through mod-kit's frames, which the drawing words catch instead.)
#   - There is at least one such file, so a payload with none cannot pass as nothing to check (L98).
#   - A line naming how a mod draws (a colour) outside any element is not logic only, read from the
#     real manual steps file, and a change to a comment line in each real file is logic only.
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

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-hook-render-reader.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
RULES="$ROOT/payload/mods/design-round-guard/hooks/rules.ts"

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
const [rules, mods] = process.argv.slice(2)
const { sourceSpans, modHookLogicOnly, isModHook } = await import(pathToFileURL(rules).href)
for (const mod of readdirSync(mods)) {
  const hooks = `${mods}/${mod}/hooks`
  if (!existsSync(hooks)) continue
  for (const f of readdirSync(hooks)) {
    if (!/\.(tsx|jsx)$/.test(f)) continue
    const rel = `payload/mods/${mod}/hooks/${f}`
    const text = readFileSync(`${hooks}/${f}`, 'utf8')
    const spans = sourceSpans(text)
    // A comment line of the file's own, changed, is logic only; -1 when it has none.
    const c = spans?.comments.find(([a, b]) => text.slice(a, b).startsWith('//') && !spans.jsx.some(([x, y]) => x < b && a < y))
    const comment = c ? modHookLogicOnly(text, text.slice(0, c[1]) + ' (read again)' + text.slice(c[1])) : -1
    console.log(JSON.stringify({ rel, isModHook: isModHook(rel), read: spans !== null, elements: spans ? spans.jsx.length : 0, comment }))
  }
}
const steps = readFileSync(`${mods}/manual-steps/hooks/register.tsx`, 'utf8')
const at = "frame: { kind: 'left-rule', color: AMBER }"
console.log(JSON.stringify({ colour: steps.includes(at) ? modHookLogicOnly(steps, steps.replace(at, "frame: { kind: 'left-rule', color: RED }")) : 'missing' }))
JS
out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$RULES" "$ROOT/payload/mods" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the reader ran under node" "exit=$rc out=$out"
else
  files="$(printf '%s\n' "$out" | grep -c '"rel"')"
  [ "$files" -ge 1 ] && check "at least one real mod hook file in TSX or JSX is read" ok || check "at least one real mod hook file in TSX or JSX is read" "none found: $out"
  while IFS= read -r line; do
    case "$line" in *'"rel"'*) ;; *) continue ;; esac
    name="$(printf '%s' "$line" | sed -E 's/.*"rel":"([^"]*)".*/\1/')"
    case "$line" in *'"isModHook":true'*'"read":true'*) check "$name is read as a mod hook file" ok ;; *) check "$name is read as a mod hook file" "$line" ;; esac
    case "$line" in *'"comment":true'*|*'"comment":-1'*) check "$name: a changed comment line is logic only" ok ;; *) check "$name: a changed comment line is logic only" "$line" ;; esac
  done <<<"$out"
  # Most draw through JSX; manual steps draws only through mod-kit's frames, so holds none. A reader
  # finding no element in any of them would be reading nothing.
  drawing="$(printf '%s\n' "$out" | grep '"rel"' | grep -c -v '"elements":0')"
  [ "$drawing" -ge 1 ] && check "elements are found in the real files that draw through JSX" ok || check "elements are found in the real files that draw through JSX" "none in: $out"
  case "$out" in *'{"colour":false}'*) check "the real band colour in manual steps is held" ok ;; *) check "the real band colour in manual steps is held" "$out" ;; esac
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
