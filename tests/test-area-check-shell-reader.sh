#!/bin/bash
# The area check's reading of a shell command (claude-config#2142), run against mod-kit's REAL reader
# of what a command writes (payload/mods/mod-kit/hooks/writes.ts commandWrites, where it lives, never
# a copy) and the area check's real rules.ts (shellTargets). The mod's own tests cannot import the
# reader: the mod test runner refuses any import from outside the mod's folder. So they answer with
# the reader's measured answers, and this suite holds those answers to the real reader, so a change to
# it that the area check misreads turns red here (L48, L58).
#   - A file a command names is judged as that file: sed -i, truncate, git checkout --, an inline
#     python3 script's own target, a heredoc redirect. A write reaching a whole folder (a find -exec
#     over it) keeps `tree`, which the area check reads to judge every file there it could hold.
#   - A write whose file cannot be named is unread, with why: a name built from a variable, a pattern
#     (with the folder it is matched in), git reaching a whole folder, an inline node script handed a
#     file it writes by position.
#   - A command writing nothing, a removal, and a name that can only be no source file are not judged.
#   - The known blind spot, measured so it is never claimed away (L460): a program that builds its own
#     file names, or a script run with no arguments, is not marked unread, so it passes unjudged.
#   - Every answer register.test.ts gives in place of the reader (its WRITES) is what the real reader
#     answers for that command in /w/app.
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
  echo "FAIL: node is not installed, so the area check's shell reading could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-area-check-shell-reader.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
EXPECTED=33

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync } from 'node:fs'
const [writesPath, rulesPath, testPath] = process.argv.slice(2)
const { commandWrites } = await import(writesPath)
const { shellTargets } = await import(rulesPath)
const CWD = '/w/app'
const targets = c => shellTargets(commandWrites(c, CWD, '/Users/dan'), '/Users/dan')
const canon = v => JSON.stringify(v, (k, x) => (x && typeof x === 'object' && !Array.isArray(x) ? Object.fromEntries(Object.entries(x).sort(([a], [b]) => (a < b ? -1 : 1))) : x))
const say = (name, ok, evidence) => console.log(ok ? `PASS\t${name}` : `FAIL\t${name}\t${evidence}`)
let n = 0
const is = (name, c, want) => {
  n++
  const got = targets(c)
  say(name, canon(got) === canon(want), `${c} gave ${canon(got)}`)
}
const unread = (name, c, word, why, folder) => {
  n++
  const got = targets(c)
  const t = got[0] ?? {}
  const ok = got.length === 1 && t.word === word && typeof t.unread === 'string' && t.unread.includes(why) && !('path' in t) && t.folder === folder
  say(name, ok, `${c} gave ${canon(got)}`)
}

is('sed -i names the file it edits', "sed -i '' 's/a/b/' src/lib/slack.ts", [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
is('truncate names the file it empties', 'truncate -s 0 src/big.ts', [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }])
is('git checkout -- names the file it puts back, judged as that file', 'git checkout -- src/big.ts', [{ word: 'src/big.ts', path: '/w/app/src/big.ts', tree: true }])
is("an inline python3 script's own target is judged", `python3 -c "open('/w/app/src/lib/slack.ts', 'w').write('x')"`, [{ word: '/w/app/src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
is('a heredoc redirect names its file', "cat > src/big.ts <<'EOF'\nx\nEOF", [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }])
is('a find -exec edit over a folder is a write reaching every file under it, so each held one there is judged', "find src -name '*.ts' -exec sed -i '' 's/a/b/' {} +", [{ word: 'src', path: '/w/app/src', tree: true }])
unread('a name built from a variable is unread', 'echo hi > "$OUT/big.ts"', '$OUT/big.ts', 'built as the command runs', undefined)
unread('a pattern is unread, with the folder it is matched in', "perl -pi -e 's/a/b/' src/*.ts", 'src/*.ts', 'a pattern', '/w/app/src')
unread('git reaching a whole folder is unread', 'git restore .', '.', 'reaches a whole folder', undefined)
unread('an inline node script handed a file by position is unread', `node -e "require('fs').writeFileSync(process.argv[1], 'x')" src/big.ts`, "node -e require('fs').writeFileSync(process.argv[1], 'x') src/big.ts", 'writes files its words do not name', '/w/app')
is('a name that can only be no source file is not judged', 'echo x > "$OUT/log.txt"', [])
is('a command writing nothing is not judged', 'npm test', [])
is('a removal adds no lines, so it is not judged', 'rm src/big.ts', [])
is('known blind spot: a script run with no arguments that builds its own file names passes unjudged (node)', 'node gen.js', [])
is('known blind spot: a script run with no arguments that builds its own file names passes unjudged (python3)', 'python3 gen.py', [])
// #2254: a findings note to the installed spool helper writes no file of the repository; nothing else is let off.
const F = 'reads $PWD and every *.ts file, so why?'
const NOTE = `bash ~/.claude/hooks/lib/issue-spool.sh note . "${F}" "builder 2254"`
is('a findings note to the installed spool helper is not judged, whatever its text holds', NOTE, [])
is('a findings note chained with an in place edit still judges the edit', `${NOTE} && sed -i '' 's/a/b/' src/lib/slack.ts`, [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
is('an edit run by substitution inside the note text is still judged', `bash ~/.claude/hooks/lib/issue-spool.sh note . "$(sed -i '' s/a/b/ src/lib/slack.ts)" "x"`, [{ word: 'src/lib/slack.ts', path: '/w/app/src/lib/slack.ts' }])
is('a copy of the spool helper in a checkout is judged as any script', `bash payload/hooks/lib/issue-spool.sh note . "${F}" "builder 2254"`, [
  { word: 'note', path: '/w/app/note' },
  { word: '.', path: '/w/app' },
  { word: F, unread: `a bash script file is handed ${F}, built as the command runs` },
  { word: 'builder 2254', path: '/w/app/builder 2254' },
])
is("the spool helper's other subcommands are judged as before", 'bash ~/.claude/hooks/lib/issue-spool.sh append . "$RECORD"', [
  { word: 'append', path: '/w/app/append' },
  { word: '.', path: '/w/app' },
  { word: '$RECORD', unread: 'a bash script file is handed $RECORD, built as the command runs' },
])

// #2255: text whose every pattern character is quoted reaches a script file as its characters, so it
// is judged as the one file they name; a pattern the shell or a tool expands, a value filled in as the
// command runs, and every other write in the command are judged as before.
is('a quoted pattern handed to a script file is judged as the one file its characters name', "python3 probe.py 'src/*.ts'", [{ word: 'src/*.ts', path: '/w/app/src/*.ts' }])
is('quoted prose holding a wildcard and a question mark is judged as the one file it names', "python3 probe.py 'every *.ts file, why?'", [{ word: 'every *.ts file, why?', path: '/w/app/every *.ts file, why?' }])
is('a pattern quoted in double quotes, or only around its wildcard, is judged the same way', `python3 probe.py "src/*.ts" src/'*'.ts`, [{ word: 'src/*.ts', path: '/w/app/src/*.ts' }])
unread('an unquoted pattern handed to a script file is still unread', 'python3 probe.py src/*.ts', 'src/*.ts', 'a pattern', '/w/app/src')
unread('a dollar sign in double quotes, filled in as the command runs, is still unread', 'python3 probe.py "$OUT/*.ts"', '$OUT/*.ts', 'built as the command runs', undefined)
is('a variable the command sets to a held file is judged as that file', 'X=src/big.ts; python3 probe.py "$X"', [{ word: '$X', path: '/w/app/src/big.ts' }])
is('a quoted pattern beside a redirect into a file still judges that file', "python3 probe.py 'src/*.ts' > src/big.ts", [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }, { word: 'src/*.ts', path: '/w/app/src/*.ts' }])
is('a quoted pattern beside a heredoc written into a file still judges that file', "python3 probe.py 'src/*.ts' && cat > src/big.ts <<'EOF'\nx\nEOF", [{ word: 'src/big.ts', path: '/w/app/src/big.ts' }, { word: 'src/*.ts', path: '/w/app/src/*.ts' }])
unread('a quoted pattern handed to a tool, which expands its own operands, is still unread', "npx foo 'src/*.ts'", 'src/*.ts', 'a pattern', '/w/app/src')
unread('a quoted group is still unread', "python3 probe.py '{a,b}.ts'", '{a,b}.ts', 'a pattern', '/w/app')
is('a word the reader cannot close is still unread beside a quoted pattern', `python3 probe.py 'src/*.ts' "$(`, [{ word: 'src/*.ts', path: '/w/app/src/*.ts' }, { word: '$(', unread: 'a python3 script file is handed $(, built as the command runs' }])

// register.test.ts answers for the reader with WRITES: each must be what the real reader answers.
const text = readFileSync(testPath, 'utf8')
const start = text.indexOf('const WRITES: Record<string, unknown> = {')
const end = start < 0 ? -1 : text.indexOf('\n}\n', start)
n++
if (start < 0 || end < 0) {
  say("register.test.ts's WRITES is found", false, 'no `const WRITES: Record<string, unknown> = {` block closed by a line holding only }')
  n++
  say("every answer in register.test.ts's WRITES is the real reader's", false, 'WRITES was not found')
} else {
  const fixture = new Function(`return ${text.slice(text.indexOf('{', start), end + 2)}`)()
  const keys = Object.keys(fixture)
  say("register.test.ts's WRITES is found", keys.length >= 5, `only ${keys.length} commands in it`)
  n++
  const wrong = keys.filter(c => canon(fixture[c]) !== canon(commandWrites(c, '/w/app', '/Users/dan')))
  say("every answer in register.test.ts's WRITES is the real reader's", wrong.length === 0, wrong.map(c => `${c}: the reader answers ${canon(commandWrites(c, '/w/app', '/Users/dan'))}`).join('; '))
}
console.log(`DONE\t${n}`)
JS

out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$ROOT/payload/mods/mod-kit/hooks/writes.ts" "$ROOT/payload/mods/area-check/hooks/rules.ts" "$ROOT/payload/mods/area-check/tests/register.test.ts" 2>&1)"; rc=$?
if [ "$rc" -ne 0 ]; then
  check "the real reader and rules.ts ran under node" "exit=$rc out=$out"
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
