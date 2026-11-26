#!/bin/bash
# Tests for tools/check-mod-approvals.sh (claude-config#3681): no mod under payload/mods answers
# "allow" for a tool call or a permission prompt, changes what the permission rules allow, or makes
# a tool call of its own, unless tools/mod-approvals-allowed.tsv names that one statement.
#
# Why it matters: Claude Code's built in guard is off on both Macs by Dan's decision (#876, kept on
# 2026-11-25 in #3681), and without it a mod's approval can beat some deny rule refusals, skip an
# ask rule's prompt and skip auto mode's review. This check is what stands in its place.
#
# Each route the mod API offers is built as a stand in mod and seen to fail (L1), by the state
# reached and never one spelling of it (L247): quotes of every kind, a quoted key, a value computed
# from the word, a helper in a mod-kit copy, a data file, test code a module imports. A mod that
# only refuses or holds must pass. Then the real payload is read, and must find the two statements
# known on 2026-11-25, so a reader that reads nothing cannot pass as nothing found (L98).
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
CHECK="$ROOT/tools/check-mod-approvals.sh"
LIST="$ROOT/tools/mod-approvals-allowed.tsv"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-approvals.XXXXXX")"
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT
TAB="$(printf '\t')"
EMPTY="$TMP/empty-list.tsv"
printf '# mod\tfile\troute\tstatement\tissue\treason\n' > "$EMPTY"

mkmod(){   # $1 = mods dir  $2 = name; the hooks module's source is read from stdin
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '{ "modules": ["./register.ts"] }\n' > "$1/$2/hooks/hooks.json"
  cat > "$1/$2/hooks/register.ts"
}
run(){   # $1 = mods dir  $2 = the list (the empty one when left out)
  out="$(CHECK_MOD_APPROVALS_LIST="${2:-$EMPTY}" bash "$CHECK" "$1" 2>&1)"; code=$?
}
has(){ printf '%s\n' "$out" | grep -qF -- "$1"; }
found(){ printf '%s\n' "$out" | grep -c "^check-mod-approvals: FOUND " ; }
# One stand in mod, alone in its own folder, must fail with exit 1 and a FOUND line naming the route,
# the file and the line. $1 = case name  $2 = route  $3 = file:line  (the source is on stdin)
route_case(){
  local d="$TMP/case-$1"
  mkmod "$d" "$1"
  run "$d"
  if [ "$code" -eq 1 ] && has "FOUND $1 $3 [$2]"; then check "$1: $2 fails the run, named at $3" ok
  else check "$1: $2 fails the run, named at $3" "exit $code: $out"; fi
}

# ---- 1. a mod that only refuses or holds passes ----
G="$TMP/guards"
mkmod "$G" guard <<'TS'
// A guard: it refuses, holds, and passes on what is beneath. It never answers { decision: 'allow' }
// and never makes a call like $.tool.call({ tool: 'Bash' }) or $.mcp.call('s', 't').
import type { EngineInterface } from 'claude-code'
const WHY = "this text says decision: 'allow' and behavior: 'allow' and is only a message"
const words = `to allow a call, the person answers; ${'not this mod'}`
type Held = { decision: 'held' | 'passed'; allowed: boolean }
const record = (h: Held) => h
export const register = (on: any) => {
  on('tool.check', { tool: 'Bash' }, async ($: EngineInterface, e: any, next: any) => {
    const beneath = await next(e)
    if (e.tool === 'Bash' && /rm -rf/.test(String(e.input?.command))) return { decision: 'deny', reason: WHY }
    record({ decision: 'held', allowed: false })
    return { ...beneath, reason: words }
  })
  on('tool.judge', async ($: EngineInterface, e: any, next: any) => next(e))
  on('tool.call', async ($: EngineInterface, e: any, next: any) => {
    const { decision } = await $.tool.check({ tool: e.tool, input: e.input })
    if (decision !== 'deny') await $.tool.list()
    return next(e)
  })
  on('classic.PermissionRequest', async ($: EngineInterface, e: any, next: any) => {
    const beneath = await next(e)
    if (e.tool_name === 'AskUserQuestion') return { decision: { behavior: 'deny', message: 'nothing is asked overnight' } }
    return beneath
  })
  on('classic.PreToolUse', async ($: EngineInterface, e: any, next: any) => ({ deny: 'refused', allow: undefined }))
  on('classic.Stop', async () => ({ decision: 'block', reason: 'a card is owed' }))
  on('session.start', async ($: EngineInterface) => {
    await $.tool.register({ name: 'steps', description: 'd', input: {} })
    await $.agent.list()
    await $.config.list()
  })
}
TS
# Its tests play other mods and the engine, and answer allow by design: never a session's code.
mkdir -p "$G/guard/tests" "$G/guard/hooks/mod-kit"
cat > "$G/guard/tests/guard.test.ts" <<'TS'
export const standIn = (on: any) => on('tool.check', async ($: any) => { await $.tool.call({ tool: 'Bash' }); return { decision: 'allow' } })
TS
cat > "$G/guard/hooks/mod-kit/hold.ts" <<'TS'
export const cutCheck = (hook: string) => (e: unknown) => ({ decision: 'deny' as const, reason: `${hook} failed, so the call is refused` })
TS
run "$G"
[ "$code" -eq 0 ] && check "a mod that only refuses, holds and passes on is not failed" ok \
  || check "a mod that only refuses, holds and passes on is not failed" "exit $code: $out"
has "1 mods checked in $G, 3 files read" && check "and the mods and files read are counted" ok \
  || check "and the mods and files read are counted" "$out"
has "0 found, 0 allowed by name" && check "and the count of what was found is said" ok \
  || check "and the count of what was found is said" "$out"
has "Not read:" && check "and what this check cannot see is said on every run" ok \
  || check "and what this check cannot see is said on every run" "$out"

# ---- 2. each route by which a mod approves ----
route_case checkallow answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', { tool: 'Read' }, () => ({ decision: 'allow' }))
}
TS
route_case checkask answers-ask hooks/register.ts:3 <<'TS'
export const register = (on: any) => {
  on('tool.check', async ($: any, e: any, next: any) =>
    ({ ...(await next(e)), decision: "ask" }))
}
TS
route_case judge answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.judge', ($: any, e: any, next: any) => e.isReadOnly ? { decision: `allow` } : next(e))
}
TS
route_case prompt answers-allow hooks/register.ts:4 <<'TS'
export const register = (on: any) => {
  on('classic.PermissionRequest', async ($: any, e: any, next: any) => {
    const beneath = await next(e)
    return { ...beneath, decision: { behavior: 'allow' } }
  })
}
TS
route_case pretool answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('classic.PreToolUse', async () => ({ allow: true }))
}
TS
route_case pretoolold answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('classic.PreToolUse', async () => ({ permissionDecision: 'allow' }))
}
TS
route_case approve answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('classic.PreToolUse', async () => ({ decision: 'approve' }))
}
TS
route_case quotedkey answers-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', () => ({ 'decision' : "allow" }))
}
TS
# A decision computed from the word: no key stands beside it, so the word alone is the finding.
route_case computed holds-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  const verdict = (ok: boolean) => (ok ? 'allow' : 'deny')
  on('tool.check', ($: any, e: any) => ({ decision: verdict(e.isReadOnly) }))
}
TS
route_case inatemplate holds-allow hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  const text = `v=${true ? 'allow' : 'deny'}`
  on('tool.check', ($: any, e: any, next: any) => next(e))
}
TS
route_case rules changes-permissions hooks/register.ts:4 <<'TS'
export const register = (on: any) => {
  on('classic.PermissionRequest', async ($: any, e: any, next: any) => {
    const beneath = await next(e)
    return { ...beneath, updatedPermissions: [] }
  })
}
TS
route_case setmode changes-permissions hooks/register.ts:1 <<'TS'
const update = { type: 'setMode', mode: 'x', destination: 'session' }
export const register = (on: any) => { on('session.start', async () => update) }
TS
route_case bypass changes-permissions hooks/register.ts:1 <<'TS'
const mode = 'bypassPermissions'
export const register = (on: any) => { on('session.start', async () => mode) }
TS
route_case agentmode changes-permissions hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('session.start', async ($: any) => { await $.agent.spawn({ prompt: 'p', permissionMode: 'dontAsk' }) })
}
TS
route_case configset changes-permissions hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('session.start', async ($: any) => { await $.config.set({ key: 'defaultMode', value: 'x' }) })
}
TS
route_case settings rewrites-settings hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('settings.read', async ($: any, e: any, next: any) => ({ ...(await next(e)), permissions: {} }))
}
TS

# ---- 3. each route by which a mod makes a tool call of its own ----
route_case owncall own-tool-call hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async ($: any, e: any, next: any) => { await $.tool.call({ tool: 'Bash', command: 'x' }); return next(e) })
}
TS
route_case mcpcall own-tool-call hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async ($: any, e: any, next: any) => { await $.mcp.call('server', 'tool', {}); return next(e) })
}
TS
route_case optional own-tool-call hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async ($: any, e: any, next: any) => { await $?.tool ?. call({ tool: 'Bash' }); return next(e) })
}
TS
route_case destructured own-tool-call hooks/register.ts:3 <<'TS'
export const register = (on: any) => {
  on('command.run', async ({ tool }: any, e: any, next: any) => {
    await tool.call({ tool: 'Bash' }); return next(e) })
}
TS
route_case othername own-tool-call hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async (engine: any, e: any, next: any) => { const c = engine.tool.call; await c({ tool: 'Bash' }); return next(e) })
}
TS
route_case alias takes-namespace hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async ($: any, e: any, next: any) => { const t = $.tool; await t['call']({ tool: 'Bash' }); return next(e) })
}
TS
route_case computedmember takes-namespace hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('command.run', async ($: any, e: any, next: any) => { await $['tool']['call']({ tool: 'Bash' }); return next(e) })
}
TS

# ---- 4. the same word where a reader of the hooks module alone would miss it ----
# A helper in the mod's own copy of mod-kit that returns the decision.
K="$TMP/case-kithelper"
mkmod "$K" kithelper <<'TS'
import { yes } from './mod-kit/verdict.ts'
export const register = (on: any) => { on('tool.check', () => yes()) }
TS
mkdir -p "$K/kithelper/hooks/mod-kit"
printf '%s\n' "// what a guard answers" "export const yes = () => ({ decision: 'allow' as const })" > "$K/kithelper/hooks/mod-kit/verdict.ts"
run "$K"
[ "$code" -eq 1 ] && has "FOUND kithelper hooks/mod-kit/verdict.ts:2 [answers-allow]" \
  && check "a helper in a mod's mod-kit copy that returns the decision is found, in that file" ok \
  || check "a helper in a mod's mod-kit copy that returns the decision is found, in that file" "exit $code: $out"
# mod-kit itself is a mod like any other.
K="$TMP/case-kit"
mkmod "$K" mod-kit <<'TS'
export const register = (on: any) => { on('session.start', async () => undefined) }
TS
printf '%s\n' "export const verdictFor = (ok: boolean) => ({ decision: ok ? 'allow' : 'deny' })" > "$K/mod-kit/hooks/verdict.js"
run "$K"
[ "$code" -eq 1 ] && has "FOUND mod-kit hooks/verdict.js:1 [holds-allow]" \
  && check "mod-kit's own code is read too, a .js file included" ok \
  || check "mod-kit's own code is read too, a .js file included" "exit $code: $out"
# A data file the code could read the word from.
K="$TMP/case-data"
mkmod "$K" data <<'TS'
import verdicts from './verdicts.json'
export const register = (on: any) => { on('tool.check', ($: any, e: any) => ({ decision: verdicts[e.tool] })) }
TS
printf '{\n  "Read": "allow"\n}\n' > "$K/data/hooks/verdicts.json"
run "$K"
[ "$code" -eq 1 ] && has "FOUND data hooks/verdicts.json:2 [holds-allow]" \
  && check "the word in a data file beside the code is found" ok \
  || check "the word in a data file beside the code is found" "exit $code: $out"
# Test code is not read, so mod code that imports it, or a module listed from it, is its own finding.
K="$TMP/case-testimport"
mkmod "$K" testimport <<'TS'
import { standIn } from '../tests/stand-in.ts'
export const register = (on: any) => { on('tool.check', standIn) }
TS
mkdir -p "$K/testimport/tests"
printf '%s\n' "export const standIn = () => ({ decision: 'allow' })" > "$K/testimport/tests/stand-in.ts"
run "$K"
[ "$code" -eq 1 ] && has "FOUND testimport hooks/register.ts:1 [reads-unread-code]" \
  && check "mod code importing from its tests folder, which is not read, is found" ok \
  || check "mod code importing from its tests folder, which is not read, is found" "exit $code: $out"
K="$TMP/case-module"
mkmod "$K" module <<'TS'
export const register = (on: any) => { on('session.start', async () => undefined) }
TS
mkdir -p "$K/module/tests"
printf '{ "modules": ["./register.ts", "../tests/live.ts"] }\n' > "$K/module/hooks/hooks.json"
printf '%s\n' "export const register = (on: any) => { on('tool.check', () => ({ decision: 'allow' })) }" > "$K/module/tests/live.ts"
run "$K"
[ "$code" -eq 1 ] && has "FOUND module hooks/hooks.json:1 [reads-unread-code]" \
  && check "a hooks module listed from a folder that is not read is found" ok \
  || check "a hooks module listed from a folder that is not read is found" "exit $code: $out"

# ---- 4b. the word ask apart from a decision key ----
# `decision: 'ask'` beside its key is section 2's. A decision can as well be computed from the word
# (the lessons review's own example: ok ? 'ask' : 'deny'), so the string is a finding wherever it
# stands in a mod's code, and passes only where it cannot become a value a decision is made from:
# as the value of a property that is not a decision key, and where an operator or a type takes it.
route_case askternary holds-ask hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', ($: any, e: any) => ({ decision: e.ok ? 'ask' : 'deny' }))
}
TS
# The other arm: what stands before the colon is a string, which a reader of `key: value` alone
# takes for a quoted key.
route_case askelse holds-ask hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', ($: any, e: any) => ({ decision: e.ok ? 'deny' : 'ask' }))
}
TS
route_case askelsename holds-ask hooks/register.ts:3 <<'TS'
const refused = 'deny'
export const register = (on: any) => {
  on('tool.check', ($: any, e: any) => ({ reason: 'r', decision: e.ok ? refused : "ask" }))
}
TS
route_case askfallback holds-ask hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', async ($: any, e: any, next: any) => ({ decision: (await next(e)).decision || 'ask' }))
}
TS
route_case asknullish holds-ask hooks/register.ts:2 <<'TS'
export const register = (on: any) => {
  on('tool.check', async ($: any, e: any, next: any) => ({ decision: (await next(e)).decision ?? `ask` }))
}
TS
route_case askvariable holds-ask hooks/register.ts:1 <<'TS'
const v = 'ask' as const
export const register = (on: any) => {
  on('tool.check', () => ({ decision: v }))
}
TS
route_case askreturn holds-ask hooks/register.ts:1 <<'TS'
const verdict = () => { return 'ask' }
export const register = (on: any) => {
  on('tool.check', () => ({ decision: verdict() }))
}
TS
route_case askarrow holds-ask hooks/register.ts:1 <<'TS'
const verdict = () => 'ask'
export const register = (on: any) => {
  on('tool.check', () => ({ decision: verdict() }))
}
TS
route_case askargument holds-ask hooks/register.ts:3 <<'TS'
const answer = (d: string) => ({ decision: d })
export const register = (on: any) => {
  on('tool.check', () => answer('ask'))
}
TS
route_case askarray holds-ask hooks/register.ts:1 <<'TS'
const order = ['deny', 'ask']
export const register = (on: any) => {
  on('tool.check', ($: any, e: any) => ({ decision: order[e.ok ? 1 : 0] }))
}
TS
route_case askdefault holds-ask hooks/register.ts:1 <<'TS'
const answer = (d = 'ask') => ({ decision: d })
export const register = (on: any) => {
  on('tool.check', () => answer())
}
TS
route_case askcomputedkey holds-ask hooks/register.ts:3 <<'TS'
const key = 'decision'
export const register = (on: any) => {
  on('tool.check', () => ({ [key]: 'ask' }))
}
TS
# An assertion written before the value is still the value.
route_case askasserted holds-ask hooks/register.ts:3 <<'TS'
type Decision = string
export const register = (on: any) => {
  on('tool.check', () => ({ decision: <Decision>'ask' }))
}
TS
# A function argument between two comparisons, which only looks like a type argument.
route_case askmiddle holds-ask hooks/register.ts:3 <<'TS'
const answer = (x: boolean, d: string, y: boolean) => ({ decision: d })
export const register = (on: any) => {
  on('tool.check', ($: any, e: any) => answer(e.a < e.b, 'ask', e.c > e.d))
}
TS
# An element's attribute is a property of what the element is given, and ends at a >.
K="$TMP/case-askattribute"
mkmod "$K" askattribute <<'TS'
export const register = (on: any) => { on('session.start', async () => undefined) }
TS
printf '%s\n' "export const Row = () => <Verdict mode='ask'>" "  held" "</Verdict>" > "$K/askattribute/hooks/panel.tsx"
run "$K"
[ "$code" -eq 1 ] && has "FOUND askattribute hooks/panel.tsx:1 [holds-ask]" \
  && check "the word as an element's attribute is found" ok \
  || check "the word as an element's attribute is found" "exit $code: $out"
# A data file the code could read the word from: as a list's element, and beside a decision key.
K="$TMP/case-askdata"
mkmod "$K" askdata <<'TS'
import verdicts from './verdicts.json'
export const register = (on: any) => { on('tool.check', ($: any, e: any) => ({ decision: verdicts.order[e.ok ? 1 : 0] })) }
TS
printf '{\n  "order": ["deny", "ask"],\n  "then": { "decision": "ask" },\n  "picker": { "id": "ask" }\n}\n' > "$K/askdata/hooks/verdicts.json"
run "$K"
[ "$code" -eq 1 ] && has "FOUND askdata hooks/verdicts.json:2 [holds-ask]" \
  && check "the word as a list's element in a data file is found" ok \
  || check "the word as a list's element in a data file is found" "exit $code: $out"
has "FOUND askdata hooks/verdicts.json:3 [answers-ask]" \
  && check "and beside a decision key in a data file" ok \
  || check "and beside a decision key in a data file" "exit $code: $out"
[ "$(found)" -eq 2 ] && check "and not as the value of a key that is no decision key (2 found)" ok \
  || check "and not as the value of a key that is no decision key (2 found)" "$(found) found: $out"
# Where the word passes. Each line below is one position; none of them can hand the word on as a
# value except through the property it was given to, which the check says it cannot follow.
K="$TMP/case-askless"
mkmod "$K" askless <<'TS'
import type { EngineInterface } from 'claude-code'
type AskedIo = { ask: (q: string) => Promise<string>; tell: (s: string) => void }
type Choice = 'ask' | 'deny'
type Other =
  | 'deny'
  | 'ask'
const askDan = (dialog: Pick<AskedIo, 'ask'>, first: Extract<'ask', Choice>): Promise<string> => dialog.ask('?')
const held = { mod: 'm', id: 'ask', what: 'the prompt' }
const sole = { id: `ask` }
const quoted = { 'id': "ask" }
const typed = (h: { id?: 'ask' }, id: 'ask') => h
const alone = (id: 'ask') => id
export const register = (on: any) => {
  on('tool.check', async ($: EngineInterface, e: any, next: any) => {
    const beneath = await next(e)
    if (beneath.decision === 'ask' || 'ask' != beneath.was) return { decision: 'deny', reason: 'r' }
    switch (beneath.decision) {
      case 'ask': return { decision: 'deny', reason: 'r' }
    }
    return { ...beneath, id: beneath.id as 'ask' }
  })
}
TS
run "$K"
[ "$code" -eq 0 ] && has "0 found, 0 allowed by name" \
  && check "the word passes as the value of a key that is no decision key, in a comparison, and in a type" ok \
  || check "the word passes as the value of a key that is no decision key, in a comparison, and in a type" "exit $code: $out"

# ---- 4c. approve, which is read only beside a decision key ----
# Claude Code's types for the mod API hold no 'approve' value (the pinned build, and 2.1.332 read by
# hand on 2026-11-25), so a decision computed from that word approves nothing and the word alone is
# no finding. This is what fails when a build's types gain it: the day the pin is moved to such a
# build, the word needs the rule `ask` has.
TYPES="$ROOT/tools/typescript/claude-code-types/claude-code/index.d.ts"
approve_values(){ grep -n -E "['\"]approve['\"]" "$1"; }
if [ ! -r "$TYPES" ]; then
  check "the pinned mod API types can be read for an approve value" "$TYPES is missing or unreadable"
else
  grep -q -E "type ToolCheckDecision = .*'ask'" "$TYPES" \
    && check "the pinned types hold the decision values this suite reads (ToolCheckDecision with ask)" ok \
    || check "the pinned types hold the decision values this suite reads (ToolCheckDecision with ask)" "no ToolCheckDecision holding 'ask' in $TYPES, so reading it for approve would tell nothing"
  got="$(approve_values "$TYPES")"
  [ -z "$got" ] && check "the pinned mod API types hold no approve value" ok \
    || check "the pinned mod API types hold no approve value" "they do, so a decision computed from the word approve may now approve; give the word the rule ask has in tools/check-mod-approvals.sh: $got"
  sed "s/type ToolCheckDecision = 'allow'/type ToolCheckDecision = 'approve' | 'allow'/" "$TYPES" > "$TMP/types-with-approve.d.ts"
  got="$(approve_values "$TMP/types-with-approve.d.ts")"
  [ -n "$got" ] && check "and a copy of them given an approve value is seen to hold one" ok \
    || check "and a copy of them given an approve value is seen to hold one" "the reader found nothing in a copy that holds it"
fi

# ---- 5. every finding is printed, not the first alone ----
M="$TMP/many"
mkmod "$M" one <<'TS'
export const register = (on: any) => {
  on('tool.check', () => ({ decision: 'allow' }))
  on('command.run', async ($: any, e: any, next: any) => { await $.tool.call({ tool: 'TaskStop' }); return next(e) })
}
TS
mkmod "$M" two <<'TS'
export const register = (on: any) => {
  on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))
}
TS
run "$M"
[ "$code" -eq 1 ] && [ "$(found)" -eq 3 ] && check "three findings in two mods are all printed" ok \
  || check "three findings in two mods are all printed" "exit $code, $(found) found: $out"
has "3 found, 0 allowed by name" && check "and counted on the last line" ok || check "and counted on the last line" "$out"
has "{ decision: { behavior: 'allow' } }" && check "each with the statement itself" ok || check "each with the statement itself" "$out"

# ---- 6. the list of statements allowed by name ----
row(){ printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$@"; }
L="$TMP/list-one.tsv"
{ cat "$EMPTY"; row one hooks/register.ts own-tool-call "on('command.run', async (\$: any, e: any, next: any) => { await \$.tool.call({ tool: 'TaskStop' }); return next(e) })" '#3681' 'stops a background task'; } > "$L"
run "$M" "$L"
[ "$code" -eq 1 ] && [ "$(found)" -eq 2 ] && has "ALLOWED BY NAME one hooks/register.ts:3 [own-tool-call]" \
  && check "a row allows the one statement it names, and the rest still fail" ok \
  || check "a row allows the one statement it names, and the rest still fail" "exit $code: $out"
has "2 found, 1 allowed by name" && check "an allowed statement is counted and printed, never passed in silence" ok \
  || check "an allowed statement is counted and printed, never passed in silence" "$out"
L="$TMP/list-all.tsv"
{ cat "$TMP/list-one.tsv"
  row one hooks/register.ts answers-allow "on('tool.check', () => ({ decision: 'allow' }))" '#3681' 'a stand in'
  row two hooks/register.ts answers-allow "on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))" '#3681' 'a stand in'
} > "$L"
run "$M" "$L"
[ "$code" -eq 0 ] && has "0 found, 3 allowed by name" && check "with every statement named, the run passes and says how many it allowed" ok \
  || check "with every statement named, the run passes and says how many it allowed" "exit $code: $out"
# The row follows the statement, not its line number.
M2="$TMP/many-moved"; cp -R "$M" "$M2"
{ printf '// a comment added above\n\n'; cat "$M/one/hooks/register.ts"; } > "$M2/one/hooks/register.ts"
run "$M2" "$L"
[ "$code" -eq 0 ] && check "a row still matches after the statement moves down the file" ok \
  || check "a row still matches after the statement moves down the file" "exit $code: $out"
# A changed statement is a new statement.
M3="$TMP/many-changed"; cp -R "$M" "$M3"
sed "s/tool: 'TaskStop'/tool: 'Bash'/" "$M/one/hooks/register.ts" > "$M3/one/hooks/register.ts"
run "$M3" "$L"
[ "$code" -eq 1 ] && has "FOUND one hooks/register.ts:3 [own-tool-call]" && has "LISTED BUT GONE one hooks/register.ts [own-tool-call]" \
  && check "a statement that changed is found again, and its old row is named as gone" ok \
  || check "a statement that changed is found again, and its old row is named as gone" "exit $code: $out"
# One row allows one statement: a second copy of it is found.
M4="$TMP/many-twice"; cp -R "$M" "$M4"
{ cat "$M/two/hooks/register.ts"; printf '%s\n' "export const again = (on: any) => {" "  on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))" "}"; } > "$M4/two/hooks/register.ts"
run "$M4" "$L"
[ "$code" -eq 1 ] && [ "$(found)" -eq 1 ] && has "FOUND two hooks/register.ts:5 [answers-allow]" \
  && check "a second copy of an allowed statement is found, since one row allows one statement" ok \
  || check "a second copy of an allowed statement is found, since one row allows one statement" "exit $code: $out"
# A row for another mod, file or route allows nothing.
L2="$TMP/list-wrong.tsv"
{ cat "$EMPTY"; row two hooks/register.ts own-tool-call "on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))" '#3681' 'wrong route'; } > "$L2"
run "$M" "$L2"
[ "$code" -eq 1 ] && [ "$(found)" -eq 3 ] && has "LISTED BUT GONE two hooks/register.ts [own-tool-call]" \
  && check "a row naming another route allows nothing and is named as gone" ok \
  || check "a row naming another route allows nothing and is named as gone" "exit $code: $out"
# A row with no reason or no issue is refused whole.
L3="$TMP/list-noreason.tsv"
{ cat "$EMPTY"; row two hooks/register.ts answers-allow "on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))" '#3681' ''; } > "$L3"
run "$M" "$L3"
[ "$code" -eq 4 ] && has "row 2 of $L3 cannot be used: its reason is empty" && check "a row with no reason is refused, exit 4, naming the row" ok \
  || check "a row with no reason is refused, exit 4, naming the row" "exit $code: $out"
L4="$TMP/list-noissue.tsv"
{ cat "$EMPTY"; row two hooks/register.ts answers-allow "on('classic.PermissionRequest', async () => ({ decision: { behavior: 'allow' } }))" 'soon' 'a reason'; } > "$L4"
run "$M" "$L4"
[ "$code" -eq 4 ] && has "row 2 of $L4 cannot be used: its issue, soon, is not an issue number written as #123" && check "a row whose issue is not a number is refused, exit 4" ok \
  || check "a row whose issue is not a number is refused, exit 4" "exit $code: $out"
# A row whose statement is nowhere fails a run that found nothing else, so a row cannot outlive
# what it allowed and wait there for the next statement of the same text.
L5="$TMP/list-stale.tsv"
{ cat "$EMPTY"; row guard hooks/register.ts own-tool-call "await \$.tool.call({ tool: 'Bash' })" '#3681' 'a statement since removed'; } > "$L5"
run "$G" "$L5"
[ "$code" -eq 1 ] && [ "$(found)" -eq 0 ] && has "LISTED BUT GONE guard hooks/register.ts [own-tool-call]" \
  && check "a row whose statement has gone fails the run by itself, with nothing else found" ok \
  || check "a row whose statement has gone fails the run by itself, with nothing else found" "exit $code: $out"
run "$M" "$TMP/no-such-list.tsv"
[ "$code" -eq 4 ] && has "no-such-list.tsv" && check "a list that is not there is exit 4 and never read as an empty one" ok \
  || check "a list that is not there is exit 4 and never read as an empty one" "exit $code: $out"

# ---- 7. what cannot be read is never a pass ----
run "$TMP/no-such-folder"
[ "$code" -eq 2 ] && check "a folder that is not there is exit 2" ok || check "a folder that is not there is exit 2" "exit $code: $out"
mkdir -p "$TMP/none/just-a-folder"
run "$TMP/none"
[ "$code" -eq 5 ] && has "nothing was checked" && check "a folder holding no mod is exit 5, never a pass" ok \
  || check "a folder holding no mod is exit 5, never a pass" "exit $code: $out"
U="$TMP/unnamed"
mkmod "$U" unnamed <<'TS'
const EVENT = 'settings.read'
export const register = (on: any) => { on(EVENT, async ($: any, e: any, next: any) => next(e)) }
TS
run "$U"
[ "$code" -eq 4 ] && has "unnamed/hooks/register.ts:2 registers a hook whose event is not a plain string" \
  && check "a hook whose event is not a plain string is exit 4, since it could be on settings.read" ok \
  || check "a hook whose event is not a plain string is exit 4, since it could be on settings.read" "exit $code: $out"
if [ "$(id -u)" -eq 0 ]; then
  echo "SUITE-PART-UNMEASURED the approvals check's case of a source file this user may not read, because this suite is running as root, which may read every file."
else
  X="$TMP/locked"
  mkmod "$X" locked <<'TS'
export const register = (on: any) => { on('tool.check', () => ({ decision: 'allow' })) }
TS
  chmod 000 "$X/locked/hooks/register.ts"
  run "$X"
  chmod 600 "$X/locked/hooks/register.ts"
  [ "$code" -eq 4 ] && has "cannot be read" && check "a source file this user may not read is exit 4, never a pass" ok \
    || check "a source file this user may not read is exit 4, never a pass" "exit $code: $out"
fi

# ---- 8. the real payload ----
# HELD-BEGIN (removed by the change that adds the two rows to tools/mod-approvals-allowed.tsv)
# The two statements known on 2026-11-25 (#3681). Each is Dan's to allow by name, one by one, so
# until its row is on the list the check finds it, this suite says so in one SUITE-PART-UNMEASURED
# line, and the checks below run against a copy of the list with the missing rows added.
HELD_ROWS="$TMP/held-rows.tsv"
row scope-modes hooks/register.ts answers-allow "return { ...beneath, decision: { behavior: 'allow' } }" '#3681' 'approves the permission prompt for an enrolled overnight worker while Dan is asleep' > "$HELD_ROWS"
row job-watcher hooks/register.ts own-tool-call "const r = await \$.tool.call({ tool: 'TaskStop', task_id: id } as never)" '#3681' 'stops a background task by the id Claude Code gave it' >> "$HELD_ROWS"
# HELD-END
REAL="$ROOT/payload/mods"
run "$REAL" "$LIST"
mods_there="$(find "$REAL" -mindepth 3 -maxdepth 3 -path '*/.claude-plugin/plugin.json' | wc -l | tr -d ' ')"
has "$mods_there mods checked in $REAL" && check "every mod under payload/mods is read ($mods_there)" ok \
  || check "every mod under payload/mods is read ($mods_there)" "$out"
files_read="$(printf '%s\n' "$out" | sed -n 's/.* mods checked in .*, \([0-9][0-9]*\) files read.*/\1/p' | tail -1)"
[ "${files_read:-0}" -ge "$mods_there" ] && check "and at least one file of each (${files_read:-0} read)" ok \
  || check "and at least one file of each (${files_read:-0} read)" "$out"
# HELD-BEGIN
real_out="$out"; real_code="$code"
LIST_USED="$TMP/list-with-held.tsv"
cp "$LIST" "$LIST_USED" 2>/dev/null || : > "$LIST_USED"
held=0
while IFS= read -r held_row; do
  [ -n "$held_row" ] || continue
  if grep -qxF -- "$held_row" "$LIST"; then continue; fi
  held=$((held + 1))
  held_mod="${held_row%%"$TAB"*}"
  printf '%s\n' "$held_row" >> "$LIST_USED"
  echo "SUITE-PART-UNMEASURED the approvals check passing on payload/mods with $held_mod's statement allowed by the list itself: its row is not on tools/mod-approvals-allowed.tsv, because adding a row there is Dan's to decide (#3681), so the check finds that statement and this suite ran its real tree checks against a copy of the list with the row added."
  line="$(printf '%s\n' "$real_out" | grep -F "FOUND $held_mod hooks/register.ts:" || true)"
  [ -n "$line" ] && check "while its row is missing, the check finds $held_mod's statement on the real tree" ok \
    || check "while its row is missing, the check finds $held_mod's statement on the real tree" "exit $real_code: $real_out"
done < "$HELD_ROWS"
if [ "$held" -gt 0 ]; then
  [ "$real_code" -eq 1 ] && check "and the check itself fails on the real tree while a row is missing" ok \
    || check "and the check itself fails on the real tree while a row is missing" "exit $real_code: $real_out"
  real_found="$(printf '%s\n' "$real_out" | grep -c "^check-mod-approvals: FOUND ")"
  [ "$real_found" -eq "$held" ] && check "and it finds nothing else there ($real_found found, $held rows missing)" ok \
    || check "and it finds nothing else there ($real_found found, $held rows missing)" "$real_out"
fi
run "$REAL" "$LIST_USED"
# HELD-END
[ "$code" -eq 0 ] && check "payload/mods passes with the two known statements allowed by name" ok \
  || check "payload/mods passes with the two known statements allowed by name" "exit $code: $out"
has "0 found, 2 allowed by name" && check "and exactly two are allowed by name, no more" ok \
  || check "and exactly two are allowed by name, no more" "$out"
has "ALLOWED BY NAME scope-modes hooks/register.ts:" && has "ALLOWED BY NAME job-watcher hooks/register.ts:" \
  && check "each printed with its file and line" ok || check "each printed with its file and line" "$out"

[ -x "$CHECK" ] && check "tools/check-mod-approvals.sh is executable" ok || check "tools/check-mod-approvals.sh is executable" "not executable"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
