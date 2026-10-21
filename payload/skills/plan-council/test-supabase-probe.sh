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

# A project whose own folder is NAMED supabase is not evidence by its name alone.
mkdir -p "$TMP/named/supabase"; printf 'x\n' > "$TMP/named/supabase/README.md"
uses "$TMP/named/supabase"
check "a project folder that is itself named supabase is not counted for its name" \
  "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC, said: $OUT")"

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

# ---- 1b. source code that READS a SUPABASE env variable, or names a supabase.co host (#1352) ----
# PET runs on Supabase but calls its REST API over plain https with the keys in CI secrets, so it
# has no supabase folder, no @supabase dependency and no env file, and the detector said no. These
# fixtures are shaped like it: a git checkout whose only evidence is the code that reads the keys.
gitrepo(){ git -C "$1" init -q 2>/dev/null && git -C "$1" add -A 2>/dev/null; }

P="$TMP/pet"; mkdir -p "$P/src"
printf 'const url = process.env.SUPABASE_URL;\nconst key = process.env.SUPABASE_SECRET_KEY;\nexport async function fetchRows(t){ return fetch(url + "/rest/v1/" + t, { headers: { apikey: key } }) }\n' > "$P/src/fetchSupabase.js"
printf '{"dependencies":{"node-fetch":"3.3.2"}}\n' > "$P/package.json"
gitrepo "$P"
uses "$P"
check "a checkout whose code reads process.env.SUPABASE_URL uses Supabase (the PET shape)" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
check "and it names the file and that it reads an env variable" \
  "$(grep -q 'src/fetchSupabase.js' <<< "$OUT" && grep -q 'reads a SUPABASE env variable' <<< "$OUT" && echo ok || echo "said: $OUT")"

P="$TMP/workflow"; mkdir -p "$P/.github/workflows" "$P/scripts"
printf 'on: push\njobs:\n  sync:\n    runs-on: ubuntu-latest\n    env:\n      SUPABASE_URL: ${{ secrets.SUPABASE_URL }}\n    steps:\n      - run: node scripts/sync.js\n' > "$P/.github/workflows/sync.yml"
printf 'console.log("sync")\n' > "$P/scripts/sync.js"
gitrepo "$P"
uses "$P"
check "a workflow file passing secrets.SUPABASE_URL means it uses Supabase" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && grep -q 'sync.yml' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/host"; mkdir -p "$P/app"
printf 'BASE = "https://abcdefghijkl.supabase.co/rest/v1"\nKEY = "eyJnot-a-real-key"\n' > "$P/app/client.py"
gitrepo "$P"
uses "$P"
check "code naming a project's supabase.co host means it uses Supabase" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && grep -q 'app/client.py names a supabase.co host' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
check "and the matching line is never printed, only the file" \
  "$(grep -q -e 'abcdefghijkl' -e 'eyJ' <<< "$OUT" && echo "printed: $OUT" || echo ok)"

# Negative controls: the word alone, in prose or a comment, or a link to supabase.com, is not use.
P="$TMP/readme-only"; mkdir -p "$P/src"
printf '# App\n\nWe looked at Supabase (https://supabase.com/docs, app.supabase.com) and chose not to use it.\n' > "$P/README.md"
printf 'export const x = 1\n' > "$P/src/index.js"
gitrepo "$P"
uses "$P"
check "a README that only mentions Supabase is still no (exit 1)" \
  "$([ "$RC" -eq 1 ] && grep -q '^no' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

P="$TMP/comment-only"; mkdir -p "$P/src"
printf '// TODO: maybe move this table to supabase later\nexport const SUPABASE_NOTE = "not used"\n' > "$P/src/index.ts"
gitrepo "$P"
uses "$P"
check "a comment or a constant that only names supabase is still no (exit 1)" \
  "$([ "$RC" -eq 1 ] && grep -q '^no' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# Measured from Overture, a Swift app with no Supabase: its only match was a code snippet inside a
# Markdown plan written for another project. Prose documents are not the project's code.
P="$TMP/plan-doc"; mkdir -p "$P/docs/plans" "$P/Sources"
printf '# Plan\n\n```ts\nconst db = createClient(\n  env.NEXT_PUBLIC_SUPABASE_URL,\n  env.SUPABASE_SERVICE_ROLE_KEY,\n)\n```\n' > "$P/docs/plans/2026-06-22-plan.md"
printf 'notes: see https://abcdefghijkl.supabase.co\n' > "$P/docs/notes.txt"
printf 'let x = 1\n' > "$P/Sources/App.swift"
gitrepo "$P"
uses "$P"
check "an env read or host inside a Markdown or text document is still no (the Overture shape)" \
  "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC, said: $OUT")"

# A folder given with a trailing slash still names its evidence relative to the folder.
uses "$TMP/env-only/"
check "a folder given with a trailing slash names the file relative to it, not as a full path" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes: \.env\.local sets' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# Vendored and build output, and lockfiles, are somebody else's code even when committed.
P="$TMP/vendored-read"; mkdir -p "$P/dist" "$P/vendor/lib" "$P/node_modules/x" "$P/src"
printf 'var u=process.env.SUPABASE_URL\n' > "$P/dist/bundle.js"
printf 'u = os.environ["SUPABASE_URL"]\n' > "$P/vendor/lib/x.py"
printf 'var u=process.env.SUPABASE_URL\n' > "$P/node_modules/x/index.js"
printf 'resolved "https://abc.supabase.co/x.tgz"\n' > "$P/yarn.lock"
printf 'export const x = 1\n' > "$P/src/index.js"
gitrepo "$P"
uses "$P"
check "reads in committed dist, vendor or node_modules folders, or a lockfile, do not count" \
  "$([ "$RC" -eq 1 ] && echo ok || echo "exit $RC, said: $OUT")"

# Every common language form of reading an env variable. These folders are NOT git checkouts, so
# they also exercise the bounded walk used when there is no git index to search.
n=0
while IFS='|' read -r file line; do
  [ -n "$file" ] || continue
  n=$((n + 1)); P="$TMP/form-$n"; mkdir -p "$(dirname "$P/$file")"
  printf '%s\n' "$line" > "$P/$file"
  uses "$P"
  check "form $n ($file: $line) reads as yes outside a git checkout" \
    "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && grep -q 'not a git checkout' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
done <<'FORMS'
src/a.js|const u = process.env["NEXT_PUBLIC_SUPABASE_URL"]
src/b.ts|const u = import.meta.env.VITE_SUPABASE_URL
app/c.py|u = os.environ["SUPABASE_URL"]
app/d.py|u = os.environ.get('SUPABASE_URL')
app/e.py|u = os.getenv("SUPABASE_KEY")
fn/f.ts|const u = Deno.env.get("SUPABASE_URL")
lib/g.rb|u = ENV["SUPABASE_URL"]
lib/h.rb|u = ENV.fetch("SUPABASE_URL")
cmd/i.go|u := os.Getenv("SUPABASE_URL")
src/j.rs|let u = std::env::var("SUPABASE_URL");
bin/k.sh|curl "$SUPABASE_URL/rest/v1/rows"
bin/l.sh|curl "${SUPABASE_URL}/rest/v1/rows"
FORMS

# A fresh checkout with nothing added yet has no index to search, so the walk covers it.
P="$TMP/untracked"; mkdir -p "$P/src"; printf 'const u = process.env.SUPABASE_URL\n' > "$P/src/x.js"
git -C "$P" init -q 2>/dev/null
uses "$P"
check "a git checkout with nothing tracked yet is walked instead, not read as no" \
  "$([ "$RC" -eq 0 ] && grep -q '^yes' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# The walk outside git is bounded by a file count; past it, finding nothing is could not tell.
P="$TMP/too-many"; mkdir -p "$P/src"
printf 'a\n' > "$P/src/1.js"; printf 'b\n' > "$P/src/2.js"; printf 'c\n' > "$P/src/3.js"; printf 'd\n' > "$P/src/4.js"
OUT="$(PLAN_COUNCIL_SCAN_FILE_CAP=3 bash "$USES" "$P" 2>&1)"; RC=$?
check "a walk that hit its file cap and found nothing is could not tell (exit 2), never no" \
  "$([ "$RC" -eq 2 ] && grep -q 'could not tell' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# A walk that could not read part of the folder found nothing only in what it read, so it is could
# not tell, never no (L11): first a folder it cannot enter, then a file it cannot open. Both depend
# on chmod 000 actually locking this user out, which root or a filesystem ignoring modes defeats, so
# each first confirms the lock took and otherwise says UNMEASURED rather than passing or failing
# (L411).
unmeasured=0
locked_check() { # locked_check <description> <path that should now be unreadable>
  local readable=""
  if [ -d "$2" ]; then ls "$2" >/dev/null 2>&1 && readable=1; else cat "$2" >/dev/null 2>&1 && readable=1; fi
  if [ -n "$readable" ]; then
    unmeasured=$((unmeasured + 1))
    echo "SUITE-PART-UNMEASURED $1 (chmod 000 did not lock this user out of $2, so the walk could read it)"
    return
  fi
  check "$1" "$([ "$RC" -eq 2 ] && grep -q 'could not tell' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"
}
P="$TMP/locked-dir"; mkdir -p "$P/src" "$P/secret"; printf 'x\n' > "$P/src/a.js"; printf 'y\n' > "$P/secret/b.js"
chmod 000 "$P/secret"
uses "$P"
locked_check "a walk that could not enter a folder and found nothing is could not tell (exit 2)" "$P/secret"
chmod 755 "$P/secret"
P="$TMP/locked-file"; mkdir -p "$P/src"; printf 'x\n' > "$P/src/a.js"; printf 'y\n' > "$P/src/b.js"
chmod 000 "$P/src/b.js"
uses "$P"
locked_check "a walk that could not open a file and found nothing is could not tell (exit 2)" "$P/src/b.js"
chmod 644 "$P/src/b.js"
# And the no it does give claims only what it read: files of 1MB or more are skipped, and it says so.
uses "$TMP/form-1/../swift"
check "a walk's no says it read only files under 1MB" \
  "$([ "$RC" -eq 1 ] && grep -q 'under 1MB' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

# A git search that fails is could not tell, never no (L11): a shim git refuses grep only.
REALGIT="$(command -v git)"; mkdir -p "$TMP/shim"
printf '#!/usr/bin/env bash\nfor a in "$@"; do [ "$a" = grep ] && { echo "fatal: simulated" >&2; exit 128; }; done\nexec "%s" "$@"\n' "$REALGIT" > "$TMP/shim/git"
chmod +x "$TMP/shim/git"
OUT="$(PATH="$TMP/shim:$PATH" bash "$USES" "$TMP/readme-only" 2>&1)"; RC=$?
check "a git search that errors is could not tell (exit 2), never no" \
  "$([ "$RC" -eq 2 ] && grep -q 'could not tell' <<< "$OUT" && echo ok || echo "exit $RC, said: $OUT")"

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
if [ "$unmeasured" -gt 0 ]; then echo "unmeasured: $unmeasured (named above, neither passed nor failed)"; fi
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
