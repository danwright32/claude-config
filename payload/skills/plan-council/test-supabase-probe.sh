#!/usr/bin/env bash
# Tests that plan-council probes the Supabase schema only for a project that uses Supabase
# (claude-config#685).
#
# The preflight always asked whether the Supabase MCP tools could reach the schema, so on
# Overture, Ovation and every other project with no Supabase at all the answer was false, and the
# skill then opened the plan with a grounding warning about a database the project never had. A
# warning that fires on every run of most projects teaches everyone to skip it, including on the
# run where Supabase really was unreachable (L36). So whether a project uses Supabase is decided by
# a script reading the project's files, and the schema state has a third value, not applicable,
# kept apart from both reachable and unreachable (L11).
#
# Everything runs against throwaway project folders and evaluates the workflow's own functions in
# node; no agent, MCP server or database is involved (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WF="$DIR/panel.workflow.js"
COUNCIL="$DIR/SKILL.md"
USES="$DIR/uses-supabase.sh"
SYNTAX="$DIR/../../hooks/lib/workflow-syntax.js"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/plan-council-supabase.XXXXXXXX")" || TMP=""
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "test-supabase-probe: refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMP"' EXIT

# ---- 1. uses-supabase.sh decides from the project's own files ----
OUT=""; RC=0
uses(){ OUT="$(bash "$USES" "$@" 2>&1)"; RC=$?; }

check "the detector is there" "$([ -f "$USES" ] && echo ok || echo "no $USES")"

P="$TMP/with-folder"; mkdir -p "$P/supabase/migrations"; printf 'project_id = "x"\n' > "$P/supabase/config.toml"
uses "$P"
check "a supabase folder means it uses Supabase (exit 0, prints yes)" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
check "and it names the evidence" \
  "$(grep -q 'supabase' <<< "$OUT" && echo ok || echo "said: $OUT")"

# A project reached through a symlink is walked, not read as the link alone.
ln -s "$P" "$TMP/linked-project"
uses "$TMP/linked-project"
check "a project folder given as a symlink is followed, not read as no" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/with-client"; mkdir -p "$P"; printf '{"dependencies":{"@supabase/supabase-js":"2.45.0"}}\n' > "$P/package.json"
uses "$P"
check "a dependency on an @supabase package means it uses Supabase" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/monorepo"; mkdir -p "$P/apps/web"; printf '{"dependencies":{"@supabase/ssr":"0.5.0"}}\n' > "$P/apps/web/package.json"
uses "$P"
check "so does one in a nested app's package.json" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# Deliberate: an app's own client folder is evidence too, and a false yes only restores the probe
# every project had before this change, which is the harmless direction (L93).
P="$TMP/client-folder"; mkdir -p "$P/src/lib/supabase"; printf 'export {}\n' > "$P/src/lib/supabase/client.ts"
uses "$P"
check "an app's own src/lib/supabase folder counts as using Supabase" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/env-only"; mkdir -p "$P"; printf 'NEXT_PUBLIC_SUPABASE_URL=https://abc.supabase.co\n' > "$P/.env.local"
uses "$P"
check "a SUPABASE variable in an env file means it uses Supabase" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
check "and the env file's value is never printed" \
  "$(grep -q 'abc.supabase.co' <<< "$OUT" && echo "printed: $OUT" || echo ok)"

P="$TMP/nested-env"; mkdir -p "$P/apps/api"; printf 'SUPABASE_SERVICE_ROLE_KEY=not-a-real-key\n' > "$P/apps/api/.env"
uses "$P"
check "a SUPABASE variable in a nested app's env file counts too" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/swift"; mkdir -p "$P/Sources/App"; printf '// swift-tools-version:5.9\n' > "$P/Package.swift"
printf 'let note = "we chose not to use supabase"\n' > "$P/Sources/App/Note.swift"
uses "$P"
check "a project with no Supabase is not one (exit 1, prints no)" \
  "$([ "$RC" -eq 1 ] && grep -q '^no' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/vendored"; mkdir -p "$P/node_modules/@supabase/supabase-js"
printf '{"dependencies":{"react":"18.3.1"}}\n' > "$P/package.json"
printf '{"name":"@supabase/supabase-js"}\n' > "$P/node_modules/@supabase/supabase-js/package.json"
uses "$P"
check "a copy inside node_modules, pulled in by something else, does not count" \
  "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC, said: $OUT")"

uses "$TMP/no-such-project"
check "a folder that is not there is could not tell (exit 2), never no" \
  "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC, said: $OUT")"
uses
check "no folder given is could not tell (exit 2), never no" \
  "$([ "$RC" -eq 2 ] && echo ok || echo "exit $RC, said: $OUT")"

# ---- 2. the workflow probes only when it should, and reports not applicable otherwise ----
check "the workflow still parses as the Workflow engine runs it" \
  "$(node "$SYNTAX" "$WF" >/dev/null 2>&1 && echo ok || echo "$(node "$SYNTAX" "$WF" 2>&1)")"

fns="$(grep -E '^const (probesSchema|schemaState|preflightPrompt|preflightSchema) = ' "$WF")"
n_fns="$(grep -c . <<< "$fns")"
check "the workflow defines the four preflight functions on one line each" \
  "$([ "$n_fns" -eq 4 ] && echo ok || echo "found $n_fns")"
cat > "$TMP/probe.js" <<JS
$fns
const r = []
const no = { usesSupabase: false }, yes = { usesSupabase: true }, unknown = {}
r.push(probesSchema(no), probesSchema(yes), probesSchema(unknown))
r.push(schemaState(no, { repoReadable: true, notes: '' }))
r.push(schemaState(no, null))
r.push(schemaState(yes, { repoReadable: true, schemaReachable: true, notes: '' }))
r.push(schemaState(yes, { repoReadable: true, schemaReachable: false, notes: '' }))
r.push(schemaState(yes, { repoReadable: true, notes: '' }))
r.push(schemaState(yes, null))
r.push(schemaState(unknown, { repoReadable: true, schemaReachable: false, notes: '' }))
r.push(/supabase/i.test(preflightPrompt(no, 'f', '/p')), /Supabase MCP/.test(preflightPrompt(yes, 'f', '/p')), /Supabase MCP/.test(preflightPrompt(unknown, 'f', '/p')))
r.push(preflightSchema(no).required.includes('schemaReachable'), 'schemaReachable' in preflightSchema(no).properties, preflightSchema(yes).required.includes('schemaReachable'))
console.log(r.join(','))
JS
got="$(node "$TMP/probe.js" 2>&1)"
want="false,true,true,not-applicable,not-applicable,reachable,unreachable,unverified,unverified,unreachable,false,true,true,false,false,true"
check "probe only when Supabase is used or unknown; state is not-applicable, reachable, unreachable or unverified" \
  "$([ "$got" = "$want" ] && echo ok || echo "want $want, got $got")"

check "the grounding gap is decided by the schema state, not the raw boolean" \
  "$(grep -q 'schemaState(a, preflight)' "$WF" && ! grep -q '!preflight.schemaReachable' "$WF" && echo ok || echo "the gap test still reads schemaReachable directly")"
# The returned preflight carries the state for the skill to read, and a probe that NEVER RAN stays
# null: spreading null into an object would make it look like a probe that ran and read nothing
# (L98, L11), and on usesSupabase:false would even look not applicable and quiet.
pr="$(grep -E '^const preflightResult = ' "$WF")"
cat > "$TMP/result.js" <<JS
$fns
$pr
const ran = preflightResult({ repoReadable: true, notes: '' }, { usesSupabase: false })
console.log([preflightResult(null, { usesSupabase: false }), preflightResult(null, {}), ran.repoReadable, ran.schemaState].join(','))
JS
res="$(node "$TMP/result.js" 2>&1)"
check "a probe that ran is returned with its schemaState, and one that never ran stays null" \
  "$([ "$res" = ",,true,not-applicable" ] && echo ok || echo "got: $res")"
check "and the workflow returns that, not a spread of whatever came back" \
  "$(grep -qE '^return \{[^}]*preflight: preflightResult\(preflight, a\)' "$WF" && echo ok || echo "not in the return")"

# ---- 3. the skill runs the detector, passes its answer, and warns only on a real gap ----
check "the skill runs uses-supabase.sh on the project" \
  "$(grep -qF 'uses-supabase.sh' "$COUNCIL" && echo ok || echo "not in $COUNCIL")"
check "and passes usesSupabase in the workflow args" \
  "$(grep -qF 'usesSupabase:' "$COUNCIL" && echo ok || echo "not in $COUNCIL")"
# Positive on the exact grounding sentence, rather than the old wording's absence, so the check is
# satisfied only by the rule it is about (L178).
grounding_line="$(grep -m 1 -F 'Check grounding next' "$COUNCIL")"
check "and warns on schemaState being unreachable or unverified" \
  "$(grep -qF 'its `schemaState` is `unreachable` or `unverified`' <<< "$grounding_line" && echo ok || echo "the line is: $grounding_line")"
check "and says not-applicable is no warning" \
  "$(grep -qF '`schemaState` of `not-applicable` means the project does not use Supabase' <<< "$grounding_line" && echo ok || echo "the line is: $grounding_line")"

echo ""
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
