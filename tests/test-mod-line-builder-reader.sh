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
#   - #1296: in the real design round guard register.ts, the store key it keeps refused calls under
#     is no look change. #1756: nor is a sentence its blocked card says, handed to its own drawCard,
#     since a blocked card's words are copy in a tool result row, its look mod-kit's own; nor a
#     refusal's words in the real keystroke guard keys.ts.
#   - #1756: the real #1747 builder's Edit to the guard's register.ts, giving a loop its opening brace,
#     leaves a text whose brackets do not balance (bracketsOpen), and the change it was half of, once
#     its brace is closed, draws nothing. And a real colour, frame and border are look changes: goal
#     box's card border, scope modes' held band row frame, handoff's heading colour, beside the manual
#     steps divider (a row) above.
#   - #1833: the #1747 loop is found by its structure (a for loop whose braced block opens with its
#     spoolNote guard), never by the spelling of the line it pushes, which had to be kept as it was
#     for this suite to pass. Controls: a copy of the real file with the pushed object's fields
#     reversed is still found and judged the same, and the loop with its brace and guard taken out
#     is not found.
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

# #1833: the #1747 loop in the real register.ts is found by its structure, read with the repository's
# one TypeScript reader (tools/lib/ts_source.py), never by one line's spelling: a for loop whose
# braced block opens with `if (spoolNote(...)) continue`. From it come the three texts the #1756
# checks judge (whole, before its brace and guard, half with its brace not yet closed), the same
# three built from a copy whose pushed object has its fields in reverse order (a reordered but
# equivalent line, which must still be found), and whether the loop is found in the text before
# (the guarded thing removed, which must not be).
cat >"$TMP/loop.py" <<'PY'
import json
import re
import sys

lib, reg_path, out_path = sys.argv[1:4]
sys.path.insert(0, lib)
from ts_source import closing, code_only


def skip(code, i):
    while i < len(code) and code[i].isspace():
        i += 1
    return i


def loops(text):
    """Each for loop whose braced block opens with `if (spoolNote(...)) continue`, as the indices
    of its header's close, its block's { and }, and that first statement's start and end."""
    code = code_only(text)
    found = []
    for m in re.finditer(r"\bfor\s*\(", code):
        head = closing(code, m.end() - 1)
        if head is None:
            continue
        brace = skip(code, head)
        if code[brace : brace + 1] != "{":
            continue
        end = closing(code, brace)
        if end is None:
            continue
        first = skip(code, brace + 1)
        cond = re.compile(r"if\s*\(").match(code, first)
        if not cond:
            continue
        shut = closing(code, cond.end() - 1)
        if shut is None or not re.search(r"\bspoolNote\s*\(", code[cond.end() : shut]):
            continue
        cont = re.compile(r"\s*continue\b;?").match(code, shut)
        if not cont:
            continue
        found.append({"head": head, "open": brace, "close": end - 1, "first": first, "stmt": cont.end()})
    return found


def cut(text, a, b):
    """text without [a, b), and without the line holding it when nothing else stands on that line."""
    start = text.rfind("\n", 0, a) + 1
    stop = text.find("\n", b)
    stop = len(text) if stop < 0 else stop
    if not text[start:a].strip() and not text[b:stop].strip():
        return text[:start] + text[stop + 1 :]
    return text[:a] + text[b:]


def texts(text):
    """The #1747 change's three texts from text, or None unless exactly one such loop is there."""
    found = loops(text)
    if len(found) != 1:
        return None
    lp = found[0]
    half = cut(text, lp["close"], lp["close"] + 1)
    # From the end back, so each cut leaves the earlier indices where they were.
    before = cut(text, lp["close"], lp["close"] + 1)
    before = cut(before, lp["first"], lp["stmt"])
    before = before[: lp["head"]] + before[lp["open"] + 1 :]
    return {"whole": text, "before": before, "half": half}


def reordered(text):
    """text with the object the loop's first push( is handed written with its fields reversed, or
    None when that object cannot be found or has fewer than two fields."""
    found = loops(text)
    if len(found) != 1:
        return None
    lp = found[0]
    code = code_only(text)
    m = re.compile(r"\bpush\s*\(\s*\{").search(code, lp["stmt"], lp["close"])
    if not m:
        return None
    o = m.end() - 1
    e = closing(code, o)
    if e is None:
        return None
    fields, depth, start = [], 0, o + 1
    for j in range(o + 1, e - 1):
        c = code[j]
        if c in "([{":
            depth += 1
        elif c in ")]}":
            depth -= 1
        elif c == "," and depth == 0:
            fields.append(text[start:j].strip())
            start = j + 1
    fields.append(text[start : e - 1].strip())
    fields = [f for f in fields if f]
    if len(fields) < 2:
        return None
    return text[: o + 1] + " " + ", ".join(reversed(fields)) + " " + text[e - 1 :]


reg = open(reg_path, encoding="utf-8").read()
real = texts(reg)
moved = reordered(reg)
out = {
    "real": real,
    "reordered": None if moved is None else texts(moved),
    "reorderedText": moved,
    "builtReordered": moved is not None and moved != reg,
    "removedFound": None if real is None else bool(loops(real["before"])),
}
json.dump(out, open(out_path, "w", encoding="utf-8"))
PY
if ! command -v python3 >/dev/null 2>&1; then
  echo "FAIL: python3 is not installed, so the #1747 loop could not be read from register.ts"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
loop_out="$(python3 -I "$TMP/loop.py" "$ROOT/tools/lib" "$ROOT/payload/mods/design-round-guard/hooks/register.ts" "$TMP/loop.json" 2>&1)"; loop_rc=$?

cat >"$TMP/read.mjs" <<'JS'
import { readFileSync, readdirSync, existsSync } from 'node:fs'
import { pathToFileURL } from 'node:url'
const [rules, mods, loopJson] = process.argv.slice(2)
const loopRead = JSON.parse(readFileSync(loopJson, 'utf8'))
const { drawnParts, drawsChange, sourceSpans, bracketsOpen } = await import(pathToFileURL(rules).href)
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
const guard = readdirSync(`${mods}/design-round-guard/hooks`).filter(f => /\.(ts|tsx)$/.test(f) && !/\.d\.ts$/.test(f)).map(name => ({ name, text: readFileSync(`${mods}/design-round-guard/hooks/${name}`, 'utf8') }))
const reg = guard.find(f => f.name === 'register.ts')?.text ?? ''
const swap = (a, b) => (reg.split(a).length === 2 ? drawsChange(guard, 'register.ts', reg, reg.replace(a, b)) : 'missing')
// #1747's two halves, as they landed with #1761: the real loop as it is (whole), without the brace it
// was given and its continue (before), and with the closing brace not yet added (half, what the
// #1747 builder's first Edit left). Found by structure in loop.py (#1833), so a field added to or
// reordered in the line the loop pushes moves nothing here; null when the loop is not there.
const { whole, before, half } = loopRead.real ?? {}
const moved = loopRead.reordered
// A real file's text with one span swapped, judged beside its mod's other hook files.
const real = (mod, name, a, b) => {
  const dir = `${mods}/${mod}/hooks`
  const fs = readdirSync(dir).filter(f => /\.(ts|tsx)$/.test(f) && !/\.d\.ts$/.test(f)).map(n => ({ name: n, text: readFileSync(`${dir}/${n}`, 'utf8') }))
  const t = fs.find(f => f.name === name)?.text ?? ''
  return t.split(a).length === 2 ? drawsChange(fs, name, t, t.replace(a, b)) : 'missing'
}
console.log(JSON.stringify({
  sentence: swap(`"This would change the design round guard's own record."`, `"This changes the design round guard's own record."`),
  pending: swap("key: 'pending' }", "key: 'waiting' }"),
  keysReason: real('keystroke-guard', 'keys.ts', "safeWay: 'Open it first, then type.'", "safeWay: 'Start it first, then type.'"),
  halfOpen: half === undefined ? 'missing' : bracketsOpen(half),
  wholeDraws: whole === undefined ? 'missing' : drawsChange(guard, 'register.ts', before, whole),
  movedHalfOpen: moved ? bracketsOpen(moved.half) : 'missing',
  movedWholeDraws: moved ? drawsChange(guard, 'register.ts', moved.before, moved.whole) : 'missing',
  builtReordered: loopRead.builtReordered,
  removedFound: loopRead.removedFound,
  border: real('goal-box', 'box.ts', "border: 'success'", "border: 'warning'"),
  frame: real('scope-modes', 'away.ts', "slot: 'held', frame: { kind: 'box' }", "slot: 'held', frame: { kind: 'left-rule' }"),
  colour: real('handoff', 'handoff.ts', "color: 'warning', bold: true }, { text: input.title }", "color: 'error', bold: true }, { text: input.title }"),
}))
console.log(JSON.stringify({
  divider: once(each) ? drawsChange(files, 'card.ts', card, card.replace(each, `${each}    if (i > 1) lines.push({ divider: true })\n`)) : 'missing',
  waits: once(wait) ? drawsChange(files, 'card.ts', card, card.replace(wait, 'export const DROPPED_AFTER_MS = 3 * 60_000')) : 'missing',
}))
JS
out="$(node --experimental-strip-types --no-warnings "$TMP/read.mjs" "$RULES" "$ROOT/payload/mods" "$TMP/loop.json" 2>&1)"; rc=$?
if [ "$loop_rc" -ne 0 ]; then
  check "the #1747 loop was read from register.ts" "exit=$loop_rc out=$loop_out"
elif [ "$rc" -ne 0 ]; then
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
  case "$out" in *'"sentence":false'*) check "#1756: the real guard's blocked card sentence, handed to its drawCard, is no look change" ok ;; *) check "#1756: the real guard's blocked card sentence, handed to its drawCard, is no look change" "$out" ;; esac
  case "$out" in *'"keysReason":false'*) check "#1756: a refusal's words in the real keystroke guard keys.ts are no look change" ok ;; *) check "#1756: a refusal's words in the real keystroke guard keys.ts are no look change" "$out" ;; esac
  case "$out" in *'"halfOpen":true'*) check "#1756: the real #1747 Edit leaves the guard's register.ts with a bracket open" ok ;; *) check "#1756: the real #1747 Edit leaves the guard's register.ts with a bracket open" "$out" ;; esac
  case "$out" in *'"wholeDraws":false'*) check "#1756: the real #1747 change, its brace closed, is no look change" ok ;; *) check "#1756: the real #1747 change, its brace closed, is no look change" "$out" ;; esac
  case "$out" in *'"builtReordered":true'*) check "#1833 control: a copy of the real register.ts with the pushed object's fields reversed was built" ok ;; *) check "#1833 control: a copy of the real register.ts with the pushed object's fields reversed was built" "$out" ;; esac
  case "$out" in *'"movedHalfOpen":true'*) check "#1833 control: the #1747 loop is still found, its brace left open, once its pushed fields are reordered" ok ;; *) check "#1833 control: the #1747 loop is still found, its brace left open, once its pushed fields are reordered" "$out" ;; esac
  case "$out" in *'"movedWholeDraws":false'*) check "#1833 control: the #1747 change on the reordered copy is still found and is no look change" ok ;; *) check "#1833 control: the #1747 change on the reordered copy is still found and is no look change" "$out" ;; esac
  case "$out" in *'"removedFound":false'*) check "#1833 control: with its brace and spoolNote guard taken out, the #1747 loop is not found" ok ;; *) check "#1833 control: with its brace and spoolNote guard taken out, the #1747 loop is not found" "$out" ;; esac
  case "$out" in *'"border":true'*) check "#1756 control: goal box's real card border is a look change" ok ;; *) check "#1756 control: goal box's real card border is a look change" "$out" ;; esac
  case "$out" in *'"frame":true'*) check "#1756 control: scope modes' real held band row frame is a look change" ok ;; *) check "#1756 control: scope modes' real held band row frame is a look change" "$out" ;; esac
  case "$out" in *'"colour":true'*) check "#1756 control: handoff's real heading colour is a look change" ok ;; *) check "#1756 control: handoff's real heading colour is a look change" "$out" ;; esac
  case "$out" in *'"pending":false'*) check "#1296: the real guard's store key for refused calls is no look change" ok ;; *) check "#1296: the real guard's store key for refused calls is no look change" "$out" ;; esac
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
