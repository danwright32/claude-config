#!/bin/bash
# Tests for tools/check-mod-tiers.sh (claude-config#3298): no mod is seated in a tier where the user
# tier mods' hooks cannot hear its calls. Each way Claude Code's types say a mod is seated there is
# built as a fixture and seen to fail (L1), by the state reached and never one spelling of it (L247);
# then the real payload is checked against this machine's own settings, and must find the real
# guards, so a hook reader that reads nothing cannot pass as nothing to miss (L98).
#
# Every fixture names its own managed and user settings files, so no case but the last reads this
# machine's, and none writes anywhere but its own scratch folder.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
CHECK="$ROOT/tools/check-mod-tiers.sh"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-mod-tiers.XXXXXX")"
# Section 13 takes read permission off some fixtures, so it is put back before the folder is removed.
trap 'chmod -R u+rwx "$TMP" 2>/dev/null; rm -rf "$TMP"' EXIT

mkmod(){   # $1 = mods dir  $2 = name  $3 = the hooks module's source
  mkdir -p "$1/$2/.claude-plugin" "$1/$2/hooks"
  printf '{ "name": "%s", "version": "0.1.0", "description": "t" }\n' "$2" > "$1/$2/.claude-plugin/plugin.json"
  printf '%s\n' "$3" > "$1/$2/hooks/register.ts"
}
# Four mods: two whose hooks hear a tool call, one that hooks nothing of the kind, and one that makes
# a call of its own.
MODS="$TMP/mods"
mkmod "$MODS" guard "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
mkmod "$MODS" checker "export const register = on => {
  on('tool.check', async (\$, e, next) => next(e))
  on(\"tool.call\", { tool: 'Bash' }, async (\$, e, next) => next(e))
}"
mkmod "$MODS" quiet "export const register = on => { on('session.start', async (\$, e, next) => next(e)) }"
mkmod "$MODS" caller "export const register = on => { on('command.run', async (\$, e, next) => { await \$.tool.call({ tool: 'TaskStop' }); return next(e) }) }"

# A case's settings: $1 = its folder, $2 = the managed settings file's text (empty for no file),
# $3 = the user settings file's text (empty for no file).
settings(){
  mkdir -p "$1"
  rm -rf "$1/managed-settings.json" "$1/managed-settings.d" "$1/settings.json"
  [ -z "$2" ] || printf '%s\n' "$2" > "$1/managed-settings.json"
  [ -z "$3" ] || printf '%s\n' "$3" > "$1/settings.json"
}
run(){   # $1 = the case's settings folder  $2 = mods dir (the four above when left out)
  out="$(CHECK_MOD_TIERS_MANAGED="$1/managed-settings.json" CHECK_MOD_TIERS_USER="$1/settings.json" bash "$CHECK" "${2:-$MODS}" 2>&1)"; code=$?
}
has(){ printf '%s\n' "$out" | grep -qF -- "$1"; }
seated_line(){ printf '%s\n' "$out" | grep -F "check-mod-tiers: $1 is seated"; }

# 1. Nothing seated: the state both Macs are in, a managed file with an empty list.
S="$TMP/clean"; settings "$S" '{"prependPlugins": []}' '{"env": {}}'
run "$S"
[ "$code" -eq 0 ] && check "no mod seated passes" ok || check "no mod seated passes" "exit $code: $out"
has "4 mods checked in $MODS, 2 with a hook that hears another mod's tool call (checker, guard)" \
  && check "the mods and the mods that hear are counted and named" ok || check "the mods and the mods that hear are counted and named" "$out"
has "$S/managed-settings.json (prependPlugins: 0 listed" && has "$S/settings.json (prependPlugins: not set" \
  && check "and each settings file read is named with what it held" ok || check "and each settings file read is named with what it held" "$out"
has "Not read:" && check "and what no file can show is said" ok || check "and what no file can show is said" "$out"

# 2. The issue's own case: managed settings seat one mod in prepend.
S="$TMP/prepend"; settings "$S" '{"prependPlugins": ["caller@inline"]}' ''
run "$S"
[ "$code" -eq 1 ] && check "a mod the managed settings list in prependPlugins fails the run" ok \
  || check "a mod the managed settings list in prependPlugins fails the run" "exit $code: $out"
line="$(seated_line caller)"
case "$line" in *"the organization's prepend tier"*"$S/managed-settings.json"*'"caller@inline"'*) check "naming the mod, the tier, the file and the entry" ok ;;
  *) check "naming the mod, the tier, the file and the entry" "$out" ;; esac
case "$line" in *"checker (tool.call, tool.check), guard (tool.call)"*) check "and each mod that would not hear it, with the events it hooks" ok ;;
  *) check "and each mod that would not hear it, with the events it hooks" "$out" ;; esac
case "$line" in *quiet*) check "a mod with no tool hook is not named as missing anything" "$line" ;; *) check "a mod with no tool hook is not named as missing anything" ok ;; esac

# 3. The other list, and an entry that is the bare name.
S="$TMP/append"; settings "$S" '{"prependPlugins": [], "appendPlugins": ["caller"]}' ''
run "$S"
[ "$code" -eq 1 ] && seated_line caller | grep -qF "the organization's append tier" \
  && check "a mod listed in appendPlugins by its bare name fails, naming append" ok \
  || check "a mod listed in appendPlugins by its bare name fails, naming append" "exit $code: $out"

# 4. A drop in file beside the managed settings seats one too.
S="$TMP/dropin"; settings "$S" '{"prependPlugins": []}' ''
mkdir -p "$S/managed-settings.d"
printf '{"appendPlugins": ["quiet@inline"]}\n' > "$S/managed-settings.d/10-more.json"
run "$S"
[ "$code" -eq 1 ] && seated_line quiet | grep -qF "$S/managed-settings.d/10-more.json" \
  && check "a mod a managed-settings.d file lists fails, naming that file" ok \
  || check "a mod a managed-settings.d file lists fails, naming that file" "exit $code: $out"

# 5. Enabled from a remote marketplace the managed settings declare: the organization's tier with no
#    list naming it (prepend, after the listed ones).
S="$TMP/enabled"; settings "$S" '{"prependPlugins": [], "enabledPlugins": {"caller@acme": true}, "extraKnownMarketplaces": {"acme": {"source": {"source": "github", "repo": "acme/mods"}}}}' ''
run "$S"
[ "$code" -eq 1 ] && seated_line caller | grep -F "the organization's prepend tier" | grep -qF 'enabledPlugins' \
  && check "a mod the managed settings enable from a declared remote marketplace fails" ok \
  || check "a mod the managed settings enable from a declared remote marketplace fails" "exit $code: $out"
S="$TMP/enabled-undeclared"; settings "$S" '{"prependPlugins": [], "enabledPlugins": {"caller@acme": true}}' ''
run "$S"
[ "$code" -eq 0 ] && check "enabled from a marketplace the managed settings do not declare, it stays in user" ok \
  || check "enabled from a marketplace the managed settings do not declare, it stays in user" "exit $code: $out"
S="$TMP/enabled-local"; settings "$S" '{"prependPlugins": [], "enabledPlugins": {"caller@acme": true}, "extraKnownMarketplaces": {"acme": {"source": {"source": "directory", "path": "/x"}}}}' ''
run "$S"
[ "$code" -eq 0 ] && check "enabled from a marketplace with no remote source, it stays in user" ok \
  || check "enabled from a marketplace with no remote source, it stays in user" "exit $code: $out"
S="$TMP/enabled-off"; settings "$S" '{"prependPlugins": [], "enabledPlugins": {"caller@acme": false}, "extraKnownMarketplaces": {"acme": {"source": {"source": "git", "url": "https://example.com/m.git"}}}}' ''
run "$S"
[ "$code" -eq 0 ] && check "set false in enabledPlugins, it is not seated" ok || check "set false in enabledPlugins, it is not seated" "exit $code: $out"

# 6. A person's own list in user settings, which seats a mod wherever nothing sets the list aside.
S="$TMP/user-list"; settings "$S" '' '{"prependPlugins": ["caller@inline"]}'
run "$S"
[ "$code" -eq 1 ] && check "a mod the user settings list in prependPlugins fails the run" ok \
  || check "a mod the user settings list in prependPlugins fails the run" "exit $code: $out"
line="$(seated_line caller)"
case "$line" in *"$S/settings.json"*"user settings"*"checker (tool.call, tool.check), guard (tool.call)"*) check "naming the user settings file and the mods that would not hear it" ok ;;
  *) check "naming the user settings file and the mods that would not hear it" "$out" ;; esac
has "no managed settings file at $S/managed-settings.json" \
  && check "and a managed settings file that is not there is said, never read as empty" ok \
  || check "and a managed settings file that is not there is said, never read as empty" "$out"
# The enabledPlugins route is the organization's alone: in user settings it seats nothing.
S="$TMP/user-enabled"; settings "$S" '{"prependPlugins": []}' '{"enabledPlugins": {"caller@acme": true}, "extraKnownMarketplaces": {"acme": {"source": {"source": "github", "repo": "acme/mods"}}}}'
run "$S"
[ "$code" -eq 0 ] && check "a plugin a person enables from a marketplace of their own is not seated" ok \
  || check "a plugin a person enables from a marketplace of their own is not seated" "exit $code: $out"

# 7. An entry is matched by the whole name before its @, never a part of one.
S="$TMP/others"; settings "$S" '{"prependPlugins": ["cc-plugin-sec-default@builtin", "caller-two@inline", "the-caller", "call"]}' ''
run "$S"
[ "$code" -eq 0 ] && check "entries naming other plugins seat no mod" ok || check "entries naming other plugins seat no mod" "exit $code: $out"
has "prependPlugins: 4 listed, none a mod here" && check "and the entries read are counted" ok || check "and the entries read are counted" "$out"

# 8. A mod that hears is seated: the others miss its calls, and it is not listed as missing its own.
S="$TMP/guard-seated"; settings "$S" '{"prependPlugins": ["guard@inline"]}' ''
run "$S"
line="$(seated_line guard)"
[ "$code" -eq 1 ] && case "$line" in *"would not hear a call it makes: checker (tool.call, tool.check)."*) true ;; *) false ;; esac \
  && check "a seated mod that hears is named with the others that would not hear it, never itself" ok \
  || check "a seated mod that hears is named with the others that would not hear it, never itself" "exit $code: $out"
# With every mod that hears seated by the organization too, no user tier hook is left to miss a call.
S="$TMP/all-seated"; settings "$S" '{"prependPlugins": ["guard@inline", "checker@inline"], "appendPlugins": ["caller@inline"]}' ''
run "$S"
[ "$code" -eq 0 ] && has "no user tier mod has a hook that would miss" \
  && check "with every mod that hears seated by the organization, a seated mod is said and not failed" ok \
  || check "with every mod that hears seated by the organization, a seated mod is said and not failed" "exit $code: $out"
# Seated only by a person's own list, a mod that hears still counts as one that would miss a call.
S="$TMP/user-all"; settings "$S" '' '{"prependPlugins": ["guard@inline", "checker@inline", "caller@inline"]}'
run "$S"
[ "$code" -eq 1 ] && seated_line caller | grep -qF "checker (tool.call, tool.check), guard (tool.call)" \
  && check "mods that hear, seated only by the user settings, still count as missing the call" ok \
  || check "mods that hear, seated only by the user settings, still count as missing the call" "exit $code: $out"

# 9. What cannot be read is its own answer (exit 4), never a pass and never a seat.
S="$TMP/bad-json"; settings "$S" '{"prependPlugins": [' ''
run "$S"
[ "$code" -eq 4 ] && has "$S/managed-settings.json cannot be read as JSON" \
  && check "managed settings that are not JSON are refused with their own exit code" ok \
  || check "managed settings that are not JSON are refused with their own exit code" "exit $code: $out"
S="$TMP/bad-list"; settings "$S" '{"prependPlugins": "caller"}' ''
run "$S"
[ "$code" -eq 4 ] && has "prependPlugins in $S/managed-settings.json is not a list" \
  && check "a prependPlugins that is not a list is refused, never read as empty" ok \
  || check "a prependPlugins that is not a list is refused, never read as empty" "exit $code: $out"
S="$TMP/bad-entry"; settings "$S" '{"prependPlugins": [{"name": "caller"}]}' ''
run "$S"
[ "$code" -eq 4 ] && has "an entry of prependPlugins in $S/managed-settings.json is not a name" \
  && check "an entry that is not a name is refused, never skipped" ok \
  || check "an entry that is not a name is refused, never skipped" "exit $code: $out"
S="$TMP/bad-and-seated"; settings "$S" '{"prependPlugins": ["caller"]}' '{"prependPlugins": 3}'
run "$S"
[ "$code" -eq 1 ] && has "is not a list" && check "a seat found beside something unreadable still fails as a seat" ok \
  || check "a seat found beside something unreadable still fails as a seat" "exit $code: $out"
S="$TMP/no-files"; settings "$S" '' ''
run "$S"
[ "$code" -eq 0 ] && has "no managed settings file at $S/managed-settings.json" && has "no user settings file at $S/settings.json" \
  && check "with neither file there nothing is seated, and both are said to be absent" ok \
  || check "with neither file there nothing is seated, and both are said to be absent" "exit $code: $out"

# 10. Nothing to check is never a pass.
S="$TMP/clean"
run "$S" "$TMP/not-there"
[ "$code" -eq 2 ] && check "a missing mods folder is its own exit code" ok || check "a missing mods folder is its own exit code" "exit $code: $out"
mkdir -p "$TMP/empty-mods/not-a-mod"
run "$S" "$TMP/empty-mods"
[ "$code" -eq 5 ] && has "nothing was checked" && check "a folder holding no mod is its own exit code, never 0 mods passing" ok \
  || check "a folder holding no mod is its own exit code, never 0 mods passing" "exit $code: $out"

# 11. What hears is read from code: a comment, a string, a test file and a stand in under tests/ are
#     not hooks, and tool.list, which the engine asks a person's hooks about for every caller, is not
#     an event a seated mod's call goes past.
M11="$TMP/mods11"
mkmod "$M11" commented "// on('tool.call', ...) is how a guard would hear it
const how = \"on('tool.check', handler)\"
export const register = on => { on('turn.complete', async (\$, e, next) => next(e)) }"
mkmod "$M11" tested "export const register = on => { on('session.end', async (\$, e, next) => next(e)) }"
printf "import { test } from 'claude-code/testing'\nconst register = on => { on('tool.call', async (\$, e, next) => next(e)) }\n" > "$M11/tested/hooks/register.test.ts"
mkdir -p "$M11/tested/tests"
printf "export const standIn = on => { on('tool.call', async (\$, e, next) => next(e)) }\n" > "$M11/tested/tests/stand-in.ts"
mkmod "$M11" lister "export const register = on => { on('tool.list', async (\$, e, next) => next(e)) }"
mkmod "$M11" caller "export const register = () => {}"
S="$TMP/seat11"; settings "$S" '{"prependPlugins": ["caller"]}' ''
run "$S" "$M11"
[ "$code" -eq 0 ] && has "4 mods checked in $M11, 0 with a hook that hears another mod's tool call" \
  && check "a comment, a string, a test, a stand in and a tool.list hook are not hooks that would miss a call" ok \
  || check "a comment, a string, a test, a stand in and a tool.list hook are not hooks that would miss a call" "exit $code: $out"
# A hook kept outside hooks/ in a file the module imports is the mod's code too.
mkmod "$M11" elsewhere "import { wire } from '../lib/wire.ts'
export const register = on => wire(on)"
mkdir -p "$M11/elsewhere/lib"
printf "export const wire = on => { on('tool.run', async (\$, e, next) => next(e)) }\n" > "$M11/elsewhere/lib/wire.ts"
run "$S" "$M11"
[ "$code" -eq 1 ] && seated_line caller | grep -qF "elsewhere (tool.run)" \
  && check "a tool hook registered outside hooks/ is read, on any tool event" ok \
  || check "a tool hook registered outside hooks/ is read, on any tool event" "exit $code: $out"
# A mod whose manifest cannot be read has no name to look for, so it is refused, not passed over.
mkdir -p "$M11/broken/.claude-plugin"
printf '{ "name": ' > "$M11/broken/.claude-plugin/plugin.json"
S="$TMP/clean"
run "$S" "$M11"
[ "$code" -eq 4 ] && has "broken's plugin.json cannot be read" \
  && check "a mod whose manifest cannot be read is refused with the unreadable exit code" ok \
  || check "a mod whose manifest cannot be read is refused with the unreadable exit code" "exit $code: $out"

# 11b. A hook is a hook however its on( is spelled (the lessons review of #3298, L247): a member
#      call is read as one, by the matcher the screen scan's reader of tool.call hooks uses, and a
#      registration whose event is not a plain string cannot be read, so it is refused (exit 4),
#      never passed over as no hook.
M11B="$TMP/mods11b"
mkmod "$M11B" member "export const register = reg => { reg.on('tool.call', async (\$, e, next) => next(e)) }"
mkmod "$M11B" caller "export const register = () => {}"
S="$TMP/seat11"
run "$S" "$M11B"
[ "$code" -eq 1 ] && seated_line caller | grep -qF "member (tool.call)" \
  && check "a tool hook registered through a member call (reg.on) is read as a hook" ok \
  || check "a tool hook registered through a member call (reg.on) is read as a hook" "exit $code: $out"
M11C="$TMP/mods11c"
mkmod "$M11C" named "const EVENT = 'tool.call'
export const register = on => { on(EVENT, async (\$, e, next) => next(e)) }"
mkmod "$M11C" caller "export const register = () => {}"
run "$TMP/clean" "$M11C"
[ "$code" -eq 4 ] && has "named registers a hook at hooks/register.ts:2 whose event is not a plain string" \
  && check "a hook whose event is a name, not a string, is refused with the file and line" ok \
  || check "a hook whose event is a name, not a string, is refused with the file and line" "exit $code: $out"
run "$S" "$M11C"
[ "$code" -eq 4 ] && has "whose event is not a plain string" && ! has "so this does not fail" \
  && check "and a seated mod beside it is never said to be missed by nothing" ok \
  || check "and a seated mod beside it is never said to be missed by nothing" "exit $code: $out"
M11D="$TMP/mods11d"
mkmod "$M11D" built "export const register = (on, kind) => { on(\`tool.\${kind}\`, async (\$, e, next) => next(e)) }"
run "$TMP/clean" "$M11D"
[ "$code" -eq 4 ] && has "built registers a hook at hooks/register.ts:1 whose event is not a plain string" \
  && check "a hook whose event is built at run time is refused too" ok \
  || check "a hook whose event is built at run time is refused too" "exit $code: $out"

# 12. The real payload. First that the real guards are found at all: with one real mod seated by a
#     fixture's managed settings, the mods the issue names must be among those that would not hear it.
if [ -d "$ROOT/payload/mods" ]; then
  S="$TMP/real-seated"; settings "$S" '{"prependPlugins": ["job-watcher@inline"]}' ''
  run "$S" "$ROOT/payload/mods"
  line="$(seated_line job-watcher)"
  missing=""
  for g in secret-guard ask-before-saving is-it-live; do
    case "$line" in *"$g (tool."*) ;; *) missing="$missing $g" ;; esac
  done
  [ "$code" -eq 1 ] && [ -z "$missing" ] && check "a real mod seated by a fixture fails, naming the secret guard, ask before saving and is it live" ok \
    || check "a real mod seated by a fixture fails, naming the secret guard, ask before saving and is it live" "exit $code missing:$missing out=$out"
  # Then this machine's own settings, read from where Claude Code reads them: no mod is seated.
  out="$(bash "$CHECK" "$ROOT/payload/mods" 2>&1)"; code=$?
  if [ "$code" -eq 0 ] && printf '%s\n' "$out" | grep -qE "^check-mod-tiers: [1-9][0-9]* mods checked in .*, [1-9][0-9]* with a hook that hears another mod's tool call"; then
    check "no mod in payload/mods is seated out of the guards' hearing on this machine" ok
  else
    check "no mod in payload/mods is seated out of the guards' hearing on this machine" "exit $code: $out"
  fi
fi

# 13. No error path ends as no mod seated (L10, L11): each thing the check could not read is exit 4
#     with words naming it. Shapes first, which hold for any user.
S="$TMP/not-object"; settings "$S" '[]' ''
run "$S"
[ "$code" -eq 4 ] && has "$S/managed-settings.json cannot be read as JSON settings" \
  && check "managed settings holding no object are refused" ok || check "managed settings holding no object are refused" "exit $code: $out"
S="$TMP/enabled-shape"; settings "$S" '{"prependPlugins": [], "enabledPlugins": ["caller@acme"]}' ''
run "$S"
[ "$code" -eq 4 ] && has "enabledPlugins in $S/managed-settings.json is not an object" \
  && check "an enabledPlugins that is not an object is refused" ok || check "an enabledPlugins that is not an object is refused" "exit $code: $out"
S="$TMP/market-shape"; settings "$S" '{"prependPlugins": [], "enabledPlugins": {"caller@acme": true}, "extraKnownMarketplaces": {"acme": 7}}' ''
run "$S"
[ "$code" -eq 4 ] && has "the source of the marketplace acme" \
  && check "a mod enabled from a marketplace whose source cannot be read is refused" ok \
  || check "a mod enabled from a marketplace whose source cannot be read is refused" "exit $code: $out"
# The check's own helper failing is exit 4 with words, never the exit 1 that means a mod is seated:
# a copy of the script with no lib folder beside it cannot load the shared reader.
mkdir -p "$TMP/alone"
cp "$CHECK" "$TMP/alone/check-mod-tiers.sh"
out="$(CHECK_MOD_TIERS_MANAGED="$TMP/clean/managed-settings.json" CHECK_MOD_TIERS_USER="$TMP/clean/settings.json" bash "$TMP/alone/check-mod-tiers.sh" "$MODS" 2>&1)"; code=$?
[ "$code" -eq 4 ] && has "check-mod-tiers: the check itself failed" && has "so nothing was told" \
  && check "the check's own helper failing is exit 4 with words, never a seat and never a pass" ok \
  || check "the check's own helper failing is exit 4 with words, never a seat and never a pass" "exit $code: $out"
# Then what only permissions can produce. Root reads everything, so there it is said and not measured (L411).
if [ "$(id -u)" -eq 0 ]; then
  echo "SUITE-PART-UNMEASURED the tier check's cases of a file or folder this user may not read, because this suite is running as root, which may read them all"
else
  S="$TMP/locked-file"; settings "$S" '{"prependPlugins": ["caller"]}' ''
  chmod 000 "$S/managed-settings.json"
  run "$S"
  [ "$code" -eq 4 ] && has "$S/managed-settings.json cannot be read as JSON" \
    && check "a managed settings file this user may not read is refused" ok \
    || check "a managed settings file this user may not read is refused" "exit $code: $out"
  S="$TMP/locked-folder"; settings "$S/in" '{"prependPlugins": ["caller"]}' ''
  chmod 000 "$S/in"
  run "$S/in"
  chmod 700 "$S/in"
  [ "$code" -eq 4 ] && has "whether there is a managed settings file at $S/in/managed-settings.json cannot be told" && ! has "no managed settings file at" \
    && check "a settings file in a folder this user may not enter is refused, never read as absent" ok \
    || check "a settings file in a folder this user may not enter is refused, never read as absent" "exit $code: $out"
  S="$TMP/locked-dropin"; settings "$S" '{"prependPlugins": []}' ''
  mkdir -p "$S/managed-settings.d"
  printf '{"prependPlugins": ["caller"]}\n' > "$S/managed-settings.d/10-more.json"
  chmod 000 "$S/managed-settings.d"
  run "$S"
  chmod 700 "$S/managed-settings.d"
  [ "$code" -eq 4 ] && has "$S/managed-settings.d cannot be listed" \
    && check "a managed-settings.d folder this user may not list is refused, never read as empty" ok \
    || check "a managed-settings.d folder this user may not list is refused, never read as empty" "exit $code: $out"
  M13="$TMP/mods13"
  mkmod "$M13" guard "export const register = on => { on('tool.call', async (\$, e, next) => next(e)) }"
  mkmod "$M13" caller "export const register = () => {}"
  chmod 000 "$M13/guard/hooks/register.ts"
  run "$TMP/clean" "$M13"
  [ "$code" -eq 4 ] && has "guard's hooks/register.ts cannot be read" \
    && check "a mod's source this user may not read is refused, never read as no hook" ok \
    || check "a mod's source this user may not read is refused, never read as no hook" "exit $code: $out"
  # A folder inside a mod that cannot be listed may hold a hook, so it is refused too, never walked past.
  M13B="$TMP/mods13b"
  mkmod "$M13B" deep "import { wire } from '../lib/wire.ts'
export const register = on => wire(on)"
  mkdir -p "$M13B/deep/lib"
  printf "export const wire = on => { on('tool.call', async (\$, e, next) => next(e)) }\n" > "$M13B/deep/lib/wire.ts"
  mkmod "$M13B" caller "export const register = () => {}"
  chmod 000 "$M13B/deep/lib"
  run "$TMP/seat11" "$M13B"
  chmod 700 "$M13B/deep/lib"
  [ "$code" -eq 4 ] && has "deep's lib cannot be listed" && ! has "so this does not fail" \
    && check "a folder inside a mod this user may not list is refused, never walked past as no hook" ok \
    || check "a folder inside a mod this user may not list is refused, never walked past as no hook" "exit $code: $out"
  mkdir -p "$TMP/locked-mods"
  chmod 000 "$TMP/locked-mods"
  run "$TMP/clean" "$TMP/locked-mods"
  chmod 700 "$TMP/locked-mods"
  [ "$code" -eq 4 ] && has "$TMP/locked-mods cannot be listed" \
    && check "a mods folder this user may not list is refused with words, never a crash or a pass" ok \
    || check "a mods folder this user may not list is refused with words, never a crash or a pass" "exit $code: $out"
fi

[ -x "$CHECK" ] && check "tools/check-mod-tiers.sh is executable" ok || check "tools/check-mod-tiers.sh is executable" "not executable"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
