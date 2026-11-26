#!/bin/bash
# Tests for tools/check-mod-guard-catch.sh (claude-config#3655): every hook a mod registers at
# tool.call or tool.check ends in a catch built by mod-kit's hooks/hold.ts, so a hook Claude Code
# cuts at 10 s, or one that throws, never lets the call it was judging run unsaid. Measured
# 2026-11-25 on Claude Code 2.1.332 (#3627): cut with no catch, the call ran in 6 of 6 runs.
#
# Each way a tool hook can be without that catch is built as a fixture and seen to fail (L1), by
# the state reached and never one spelling of it (L247). Then the real payload is checked, and must
# be seen to hold tool hooks at all, so a reader that reads nothing cannot pass as nothing to miss
# (L98); a real mod with its catch taken off must fail; and, where Claude Code is installed, the
# count of each mod's tool hooks is held to the one `claude plugin validate` gives, since the engine
# lists hooks by what it loads and this tool by what it can read (L96).
#
# No case writes anywhere but its own scratch folder.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
CHECK="$ROOT/tools/check-mod-guard-catch.sh"
HOLD="$ROOT/payload/mods/mod-kit/hooks/hold.ts"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-guard-catch.XXXXXX")"
# One case takes read permission off a fixture, so it is put back before the folder is removed.
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

mkmod(){   # $1 = mods dir  $2 = name; the hooks module's source on standard input
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks/mod-kit"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  cat > "$1/$2/hooks/register.ts"
  cp "$HOLD" "$1/$2/hooks/mod-kit/hold.ts"
}
mkkit(){   # $1 = mods dir: a mod-kit holding the real hold.ts, which each mod's copy is held to
  mkdir -p "$1/mod-kit/.claude-plugin" "$1/mod-kit/hooks"
  printf '{ "name": "mod-kit", "version": "0.1.0", "description": "t" }\n' > "$1/mod-kit/.claude-plugin/plugin.json"
  cp "$HOLD" "$1/mod-kit/hooks/hold.ts"
}
run(){ out="$(bash "$CHECK" "$1" 2>&1)"; code=$?; }
has(){ printf '%s\n' "$out" | grep -qF -- "$1"; }
named(){ printf '%s\n' "$out" | grep -F "check-mod-guard-catch: $1's hook at "; }
fails_with(){   # $1 = mod  $2 = words its line must carry  $3 = the case's name
  named "$1" | grep -qF -- "$2" && check "$3" ok || check "$3" "wanted '$2' on $1's line, got: $(named "$1") | whole run: $out"
}

[ -f "$HOLD" ] && check "mod-kit's hooks/hold.ts is where the fixtures copy it from" ok || check "mod-kit's hooks/hold.ts is where the fixtures copy it from" "no $HOLD"

# 1. Every spelling that IS the shared catch passes, and the hooks are counted.
OK="$TMP/ok"; mkkit "$OK"
mkmod "$OK" clean <<'TS'
import { cutCall, cutCheck, cutOwn, watchesOnly, withinGrace } from './mod-kit/hold.ts'
// on('tool.call', async ($, e, next) => next(e))   a registration in a comment is no hook
const note = "on('tool.check', h) is no hook inside a string"
const judge = async ($, e, next) => (e.input.bad ? { deny: 'no' } : next(e))
const look = async ($, e, next) => {
  const r = await next(e)
  return { ...r, context: [...(r.context ?? []), 'seen'] }
}
export const register = (on, reg) => {
  on('tool.call', judge).catch(($, e, next) => cutCall('the mod', e, next))
  on("tool.check", async ($, e, next) => ({ decision: 'deny', reason: 'x' })).catch(($, e, next) => cutCheck('the mod', next, {
    work: () => withinGrace(next.budget, () => ({ decision: 'deny', reason: 'again' }), () => ({ decision: 'deny', reason: 'late' })),
  }))
  on(`tool.call`, { tool: 'mine' }, async ($, e) => ({ result: 'done' })).catch(async ($, e, next) => cutOwn('the mod', next))
  on('tool.call', look).catch(watchesOnly)
  reg.on('tool.call', async ($, e, next) => next(e))
    // a comment between the registration and its catch
    .catch(watchesOnly)
  on('session.start', async ($, e, next) => next(e))
}
TS
mkmod "$OK" quiet <<'TS'
export const register = on => { on('session.start', async ($, e, next) => next(e)) }
TS
# A mod's tests stand in for other mods and register hooks of their own: they are not its code.
mkdir -p "$OK/clean/tests"
printf "on('tool.call', async (\$, e, next) => next(e))\n" > "$OK/clean/tests/stand-in.test.ts"
printf "on('tool.call', async (\$, e, next) => next(e))\n" > "$OK/clean/hooks/register.test.ts"
run "$OK"
[ "$code" -eq 0 ] && check "tool hooks ending in the four shared catches pass" ok || check "tool hooks ending in the four shared catches pass" "exit $code: $out"
has "3 mods checked in $OK, 5 tool.call and tool.check hooks read, 0 not ending in a shared catch. Hooks per mod: clean=5" \
  && check "and the mods, the hooks read and the hooks per mod are counted" ok || check "and the mods, the hooks read and the hooks per mod are counted" "$out"

# 2. Each way a tool hook is without the shared catch fails, named with its mod, file and line.
BAD="$TMP/bad"; mkkit "$BAD"
mkmod "$BAD" no-catch <<'TS'
export const register = on => {
  on('session.start', async ($, e, next) => next(e))
  on('tool.call', async ($, e, next) => (e.input.bad ? { deny: 'no' } : next(e)))
}
TS
mkmod "$BAD" no-catch-check <<'TS'
export const register = on => { on("tool.check", async ($, e, next) => ({ decision: 'ask', reason: 'sure?' })) }
TS
mkmod "$BAD" own-catch <<'TS'
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => ({ deny: 'could not check' })) }
TS
mkmod "$BAD" own-never <<'TS'
import { neverThrows } from './mod-kit/hold.ts'
export const register = on => { on('tool.check', async ($, e, next) => next(e)).catch(($, e, next) => neverThrows(() => ({ decision: 'deny', reason: 'x' }), () => ({ decision: 'deny', reason: 'x' }), { decision: 'deny', reason: 'x' })) }
TS
mkmod "$BAD" wrong-event <<'TS'
import { cutCall, cutCheck, cutOwn } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => cutCheck('the mod', next)) }
TS
mkmod "$BAD" wrong-event-check <<'TS'
import { cutCall, cutCheck, cutOwn } from './mod-kit/hold.ts'
export const register = on => { on('tool.check', async ($, e, next) => next(e)).catch(($, e, next) => cutOwn('the mod', next)) }
TS
mkmod "$BAD" watcher-refuses <<'TS'
import { watchesOnly } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', async ($, e, next) => (e.input.bad ? { deny: 'no' } : next(e))).catch(watchesOnly) }
TS
mkmod "$BAD" watcher-refuses-named <<'TS'
import { watchesOnly } from './mod-kit/hold.ts'
const judge = async ($, e, next) => {
  if (e.input.bad) return { decision: 'deny', reason: 'no' }
  return next(e)
}
export const register = on => { on('tool.check', judge).catch(watchesOnly) }
TS
mkmod "$BAD" watcher-answers <<'TS'
import { watchesOnly } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', { tool: 'mine' }, async ($, e) => ({ result: 'done' })).catch(watchesOnly) }
TS
mkmod "$BAD" watcher-lost <<'TS'
import { watchesOnly } from './mod-kit/hold.ts'
import { judge } from './elsewhere.ts'
export const register = on => { on('tool.call', judge).catch(watchesOnly) }
TS
mkmod "$BAD" own-name <<'TS'
const cutCall = () => undefined
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => cutCall('the mod', e, next)) }
TS
mkmod "$BAD" renamed <<'TS'
import { withinGrace as cutCheck } from './mod-kit/hold.ts'
export const register = on => { on('tool.check', async ($, e, next) => next(e)).catch(($, e, next) => cutCheck('the mod', next)) }
TS
mkmod "$BAD" commented-import <<'TS'
// import { watchesOnly } from './mod-kit/hold.ts'
const watchesOnly = () => ({ result: 'ran anyway' })
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(watchesOnly) }
TS
mkmod "$BAD" from-elsewhere <<'TS'
import { cutOwn } from './mine.ts'
export const register = on => { on('tool.call', { tool: 'mine' }, async ($, e) => ({ result: 'done' })).catch(($, e, next) => cutOwn('the mod', next)) }
TS
mkmod "$BAD" no-copy <<'TS'
import { cutCall } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => cutCall('the mod', e, next)) }
TS
rm "$BAD/no-copy/hooks/mod-kit/hold.ts"
mkmod "$BAD" stale-copy <<'TS'
import { cutCall } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => cutCall('the mod', e, next)) }
TS
printf 'export const cutCall = () => undefined\n' > "$BAD/stale-copy/hooks/mod-kit/hold.ts"
mkmod "$BAD" judges <<'TS'
import { cutCall } from './mod-kit/hold.ts'
export const register = on => {
  on('tool.judge', async ($, e, next) => next(e)).catch(($, e, next) => cutCall('the mod', e, next))
  on('tool.run', async ($, e, next) => next(e))
}
TS
mkmod "$BAD" named-event <<'TS'
const EVENT = 'tool.call'
export const register = on => { on(EVENT, async ($, e, next) => next(e)) }
TS
mkmod "$BAD" member <<'TS'
export const register = reg => { reg.on('tool.call', async ($, e, next) => next(e)) }
TS
mkmod "$BAD" unclosed <<'TS'
export const register = on => { on('tool.call', async ($, e, next) => { return next(e)
TS
mkmod "$BAD" second-file <<'TS'
import { more } from './more.tsx'
export const register = on => { more(on) }
TS
cat > "$BAD/second-file/hooks/more.tsx" <<'TS'
export const more = on => {

  on('tool.check', async ($, e, next) => next(e))
}
TS
run "$BAD"
[ "$code" -eq 1 ] && check "a tool hook without the shared catch fails the run" ok || check "a tool hook without the shared catch fails the run" "exit $code: $out"
fails_with no-catch "/hooks/register.ts:3: the tool.call hook has no catch" "a tool.call hook with no catch is named with its file and line"
fails_with no-catch-check "the tool.check hook has no catch" "a tool.check hook with no catch fails"
fails_with own-catch "keeps a catch of its own" "a hand written catch fails, whatever it answers"
fails_with own-never "keeps a catch of its own" "a hand written catch through neverThrows fails here too"
fails_with wrong-event "answers through cutCheck, which answers in another event's shape: use cutCall or cutOwn" "a tool.call hook caught by the check's catch fails"
fails_with wrong-event-check "answers through cutOwn, which answers in another event's shape: use cutCheck" "a tool.check hook caught by a tool.call catch fails"
fails_with watcher-refuses "is declared watchesOnly and its own lines answer a refusal" "a hook declared a watcher that denies in its own lines fails"
fails_with watcher-refuses-named "is declared watchesOnly and its own lines answer a refusal" "and one whose named function decides fails, read where it is defined"
fails_with watcher-answers "is declared watchesOnly and its own lines answer the call themselves" "a hook declared a watcher that answers the call with a result fails"
fails_with watcher-lost "is declared watchesOnly and its function could not be found to read" "a hook declared a watcher whose function is not in its file fails, never passed unread"
fails_with own-name "names cutCall, which this file does not import, under that name, from ./mod-kit/hold.ts" "a function of the mod's own with the kit's name fails"
fails_with renamed "names cutCheck, which this file does not import, under that name" "another import renamed to the kit's name fails"
fails_with commented-import "names watchesOnly, which this file does not import, under that name" "an import that is commented out is no import"
fails_with from-elsewhere "names cutOwn, which this file does not import, under that name" "the kit's name imported from another file fails"
fails_with no-copy "and no such file is beside it" "a mod with no copy of hold.ts fails"
fails_with stale-copy "is not mod-kit's hooks/hold.ts byte for byte" "a mod whose hold.ts is not mod-kit's fails"
named judges | grep -F "register.ts:3:" | grep -qF "a tool.judge hook decides whether a call runs" && check "a tool.judge hook fails, since no shared catch is written for it" ok || check "a tool.judge hook fails, since no shared catch is written for it" "$(named judges)"
named judges | grep -F "register.ts:4:" | grep -qF "a tool.run hook decides whether a call runs" && check "and a tool.run hook" ok || check "and a tool.run hook" "$(named judges)"
fails_with named-event "its event is not a plain string, so whether it is a tool hook cannot be read" "a registration whose event is not a plain string fails, never passed unread"
fails_with member "the tool.call hook has no catch" "a hook registered through a member call is read as a hook"
fails_with unclosed "could not be read to its end" "a registration that never closes fails, never passed unread"
fails_with second-file "/hooks/more.tsx:3: the tool.check hook has no catch" "a hook in another file of the mod is found, named with that file and line"
has "22 mods checked in $BAD, 22 tool.call and tool.check hooks read, 22 not ending in a shared catch" \
  && check "and the count says how many hooks do not end in a shared catch" ok || check "and the count says how many hooks do not end in a shared catch" "$(printf '%s\n' "$out" | tail -n 1)"
named mod-kit | grep -q . && check "the mod-kit fixture, which registers no tool hook, is not named" "$(named mod-kit)" || check "the mod-kit fixture, which registers no tool hook, is not named" ok

# 3. With no mod-kit in the folder a copy cannot be held to it, and the run says so rather than
#    reading as a full check.
LONE="$TMP/lone"
mkmod "$LONE" alone <<'TS'
import { cutCall } from './mod-kit/hold.ts'
export const register = on => { on('tool.call', async ($, e, next) => next(e)).catch(($, e, next) => cutCall('the mod', e, next)) }
TS
run "$LONE"
[ "$code" -eq 0 ] && has "no mod-kit in $LONE, so each mod's copy of hold.ts was only seen to exist" \
  && check "a folder with no mod-kit says its copies were not held to it" ok || check "a folder with no mod-kit says its copies were not held to it" "exit $code: $out"

# 4. A mod that cannot be read fails, with words, and is never counted as having no tool hooks.
if [ "$(id -u)" -ne 0 ]; then
  DARK="$TMP/dark"; mkkit "$DARK"
  mkmod "$DARK" unreadable <<'TS'
export const register = on => { on('tool.call', async ($, e, next) => next(e)) }
TS
  chmod 000 "$DARK/unreadable/hooks/register.ts"
  run "$DARK"
  chmod 600 "$DARK/unreadable/hooks/register.ts"
  [ "$code" -eq 1 ] && has "check-mod-guard-catch: unreadable's hooks could not be read, so whether each tool hook ends in a shared catch is not known" \
    && check "a mod whose source cannot be read fails the run, said in words" ok || check "a mod whose source cannot be read fails the run, said in words" "exit $code: $out"
else
  echo "SUITE-PART-UNMEASURED the guard catch check's case of a source file this user may not read: this suite is running as root, which may read them all"
fi

# 5. A folder that is not there, and one holding no mod, are each refused with their own exit code.
run "$TMP/absent"
[ "$code" -eq 2 ] && has "is not a folder, so nothing was checked" && check "a mods folder that does not exist exits 2" ok || check "a mods folder that does not exist exits 2" "exit $code: $out"
mkdir -p "$TMP/empty/not-a-mod"
run "$TMP/empty"
[ "$code" -eq 2 ] && has "no mod (a folder with .claude-plugin/plugin.json)" && check "a folder holding no mod exits 2, never a pass over nothing" ok || check "a folder holding no mod exits 2, never a pass over nothing" "exit $code: $out"

# 6. The real mods: every tool hook ends in a shared catch, and there ARE tool hooks to read.
if [ -d "$ROOT/payload/mods" ]; then
  run "$ROOT/payload/mods"
  [ "$code" -eq 0 ] && check "every tool.call and tool.check hook in payload/mods ends in a shared catch" ok \
    || check "every tool.call and tool.check hook in payload/mods ends in a shared catch" "exit $code: $out"
  real="$out"
  hooks="$(printf '%s\n' "$real" | sed -n 's/.* mods checked in .*, \([0-9][0-9]*\) tool\.call and tool\.check hooks read, .*/\1/p')"
  [ "${hooks:-0}" -ge 17 ] && check "and the reader found the mods' tool hooks (at least the 17 the guards had on 2026-11-25)" ok \
    || check "and the reader found the mods' tool hooks (at least the 17 the guards had on 2026-11-25)" "read '${hooks:-nothing}': $real"
  for guard in area-check ask-before-saving collision-guard design-round-guard keystroke-guard picker-manners scope-modes secret-guard style-check; do
    case "$real" in *" $guard="[1-9]*) check "and $guard's tool hooks are among them" ok ;; *) check "and $guard's tool hooks are among them" "$real" ;; esac
  done

  # 7. A real mod with its catch taken off fails: the check is seen to fail on the code it guards.
  PLANT="$TMP/plant"; mkdir -p "$PLANT"
  cp -R "$ROOT/payload/mods/mod-kit" "$PLANT/mod-kit"
  cp -R "$ROOT/payload/mods/style-check" "$PLANT/style-check"
  before="$(grep -c "\.catch((\$, e, next) => cutCall('the style check', e, next))" "$PLANT/style-check/hooks/register.ts")"
  sed "s/\.catch((\$, e, next) => cutCall('the style check', e, next))//" "$ROOT/payload/mods/style-check/hooks/register.ts" > "$PLANT/style-check/hooks/register.ts"
  [ "$before" -eq 1 ] && ! grep -qF "cutCall('the style check'" "$PLANT/style-check/hooks/register.ts" \
    && check "the style check's one registration catch was found and taken off the copy" ok \
    || check "the style check's one registration catch was found and taken off the copy" "found $before to take off"
  run "$PLANT"
  [ "$code" -eq 1 ] && named style-check | grep -qF "the tool.call hook has no catch, so a call it was judging runs when the hook is cut or throws" \
    && check "the real style check with its catch taken off fails the run" ok \
    || check "the real style check with its catch taken off fails the run" "exit $code: $out"

  # 8. Where Claude Code is installed, its own list of each mod's tool hooks is held against this
  #    tool's count, and every one of them has a catch by the engine's reading too.
  bin="${CLAUDE_BIN:-}"
  if [ -z "$bin" ]; then
    bin="$(command -v claude 2>/dev/null || true)"
    [ -n "$bin" ] || { [ -x "$HOME/.local/bin/claude" ] && bin="$HOME/.local/bin/claude"; }
  fi
  if [ -n "$bin" ] && [ -x "$bin" ]; then
    measured=0; unread=""
    for d in "$ROOT/payload/mods"/*/; do
      [ -f "$d.claude-plugin/plugin.json" ] || continue
      name="$(basename "$d")"
      engine="$("$bin" plugin validate --json "${d%/}" 2>/dev/null | python3 -I -c '
import json, sys
try:
    j = json.load(sys.stdin)
    hooks = [g for c in j["contents"] if isinstance(c, dict) for g in c.get("gatingHooks", [])]
    tool = [g for g in hooks if g["pattern"] in ("tool.call", "tool.check")]
    print(len(tool), sum(1 for g in tool if not g["hasCatch"]))
except Exception:
    print("unread")
' 2>/dev/null)"
      if [ "$engine" = unread ] || [ -z "$engine" ]; then unread="$unread $name"; continue; fi
      measured=$((measured + 1))
      ours="$(printf '%s\n' "$real" | tail -n 1 | tr ' ' '\n' | sed -n "s/^$name=\([0-9][0-9]*\)$/\1/p")"
      [ "${engine% *}" = "${ours:-0}" ] && check "$name: Claude Code lists as many tool hooks as this tool read" ok \
        || check "$name: Claude Code lists as many tool hooks as this tool read" "Claude Code lists ${engine% *}, this tool read ${ours:-0}"
      [ "${engine#* }" = 0 ] && check "$name: and none of them is without a catch by Claude Code's own reading" ok \
        || check "$name: and none of them is without a catch by Claude Code's own reading" "${engine#* } without a catch"
    done
    [ -z "$unread" ] || echo "SUITE-PART-UNMEASURED Claude Code's own list of tool hooks for$unread: claude plugin validate --json gave nothing this suite could read for them ($("$bin" --version 2>/dev/null | head -n 1))"
    [ "$measured" -gt 0 ] || echo "SUITE-PART-UNMEASURED the guard catch check against Claude Code's own list of tool hooks: claude plugin validate --json was readable for no mod"
  else
    echo "SUITE-PART-UNMEASURED the guard catch check against Claude Code's own list of tool hooks: no claude command here (looked for ${CLAUDE_BIN:-claude on PATH, then ~/.local/bin/claude})"
  fi
fi

[ -x "$CHECK" ] && check "tools/check-mod-guard-catch.sh is executable" ok || check "tools/check-mod-guard-catch.sh is executable" "not executable"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
