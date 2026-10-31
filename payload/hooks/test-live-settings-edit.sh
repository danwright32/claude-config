#!/usr/bin/env bash
# Tests for how run-all-tests.sh judges a change to settings.json made while it runs
# (claude-config#1969).
#
# settings.json is on the runner's list of live stores, so a suite bound to the real path is caught
# writing it. But it has a writer that is neither the sync nor a suite: the person at the keyboard.
# Claude Code saves it on /model, on a plugin toggle and on a permission granted for good, and Dan
# edits it by hand. On 2026-10-30 a one line hand edit at 6:41 PM ET was enough to fail a full run as
# live-store-pollution (#1964 traced it). Nothing on macOS records which process wrote a file
# without root, so the runner cannot ask WHO wrote it; what it can read is WHAT changed. The rule
# under test: a change is a person's own settings edit when the file is still a JSON object, at
# least one setting was carried over untouched, and every setting that changed is one no code in
# this config ever writes. Every case below that must still fail is the half that keeps the guard's
# teeth, and each one was seen to fail against a runner with its leg of the rule broken (L1).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$DIR/run-all-tests.sh"

if [ ! -f "$DIR/lib/suite-deadline.sh" ]; then
  echo "FAIL: test-live-settings-edit: no helper at $DIR/lib/suite-deadline.sh, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/lib/suite-deadline.sh"
suite_deadline_arm || exit $?
. "$DIR/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

T="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.live-settings.XXXXXXXX")" || T=""
case "${T%/}" in
  ''|/|"${HOME%/}") echo "test-live-settings-edit: refusing to run: throwaway directory came back as '$T'." >&2; exit 2 ;;
esac
trap 'rm -rf "$T"' EXIT

# No fixture run inherits the deadline, or the live store hand over, of the run this suite is part
# of: each judges its own throwaway home as a run started on its own would.
unset HOOK_TESTS_DEADLINE HOOK_TESTS_DEADLINE_RESERVE HOOK_TESTS_JOB_STARTED HOOK_TESTS_NOW GITHUB_ACTIONS GITHUB_WORKFLOW_REF GITHUB_JOB
unset HOOK_TESTS_LIVE_BRACKETED HOOK_TESTS_LIVE_BRACKETED_RUN
mkdir -p "$T/cfg" "$T/suites" "$T/spool"
SETTINGS="$T/cfg/settings.json"
# The register names a clone that does not exist, so no apply of the sync can explain anything here.
printf '%s\n' "$T/no-such-clone" > "$T/registry"

ls_run(){ # every live store seam pointed at the throwaway home, so nothing real is bracketed
  CLAUDE_HOME="$T/cfg" \
  SYNC_CLONE_REGISTRY="$T/registry" \
  SYNC_ZSHRC="$T/zshrc" \
  SYNC_WATCH_PID_FILE="$T/watch.pid" \
  SYNC_HOLD_FILE="$T/hold" \
  CLAUDE_ISSUE_SPOOL_DIR="$T/spool" \
  HOOK_TESTS_ROOT="$T" HOOK_TESTS_TIMINGS= HOOK_TESTS_BUDGET=4 \
  bash "$RUNNER" "$T/suites" 2>&1
}

# The runner reads settings.json with jq, and without it counts every change (it fails closed). So
# where jq is missing the excusing half cannot be measured, and is said to be rather than failed.
if ! command -v jq >/dev/null 2>&1; then
  echo "SUITE-PART-UNMEASURED every case, because jq is not installed here and the runner reads settings.json with it"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi

# A settings.json shaped like a real Mac's: settings a person picks (model, permissions) beside the
# ones the sync installs (the hooks block, the mods in env, a shared setting).
seed(){
  cat > "$SETTINGS" <<'JSON'
{
  "model": "opus",
  "permissions": {
    "allow": ["Bash(ls:*)"]
  },
  "hooks": {
    "Stop": [{"hooks": [{"type": "command", "command": "bash /fixture/hooks/stop.sh"}]}]
  },
  "env": {
    "CLAUDE_CODE_PLUGIN_DIRS": "/fixture/mods/a"
  },
  "outputStyle": "Explanatory"
}
JSON
}

# A suite that rewrites settings.json with the content given, standing in for one bound to the real
# path. Written with a quoted heredoc, so the JSON reaches the file byte for byte.
mk_writer(){ # mk_writer <content, or the word DELETE>
  rm -f "$T/suites"/test-*.sh
  {
    printf '#!/usr/bin/env bash\n'
    if [ "$1" = DELETE ]; then
      printf 'rm -f "%s"\n' "$SETTINGS"
    else
      printf 'cat > "%s" <<'"'"'SETTINGSJSON'"'"'\n%s\nSETTINGSJSON\n' "$SETTINGS" "$1"
    fi
    printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
  } > "$T/suites/test-writer.sh"
  chmod +x "$T/suites/test-writer.sh"
}
caught(){ # caught <description> <exit code> <output>: the run must fail and name settings.json
  case "$3" in
    *"SUITES CHANGED A LIVE STORE"*"$SETTINGS"*)
      [ "$2" -ne 0 ] && check "$1" ok || check "$1" "exit=$2 out=$3" ;;
    *) check "$1" "exit=$2 out=$3" ;;
  esac
}

# ---- 1. The incident's shape: a person saves settings.json while a run is going ----
# The writer is a child of THIS file, not of the run, and is timed by the suite's signal rather than
# a clock, so it lands inside the run's window however loaded the Mac is. It changes the model (a
# /model pick) and adds enabledPlugins (a plugin toggle), and rewrites the whole file in another
# layout, as Claude Code does, so no line based reading of the change could excuse it.
seed
rm -f "$T/go" "$T/done" "$T/suites"/test-*.sh
{
  printf '#!/usr/bin/env bash\n'
  printf '. "%s"\n' "$DIR/lib/hang-wait.sh"
  printf ': > "%s"\n' "$T/go"
  printf 'if hang_wait %q; then printf "SUITE-RESULT passed=1 failed=0\\n"; else printf "the outside writer never wrote\\nSUITE-RESULT passed=0 failed=1\\n"; exit 1; fi\n' "[ -f \"$T/done\" ]"
} > "$T/suites/test-waiter.sh"
chmod +x "$T/suites/test-waiter.sh"
(
  hang_wait '[ -f "$T/go" ]' || exit 0
  cat > "$SETTINGS" <<'JSON'
{
  "model": "sonnet",
  "permissions": {
    "allow": [
      "Bash(ls:*)"
    ]
  },
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "bash /fixture/hooks/stop.sh"
          }
        ]
      }
    ]
  },
  "env": {
    "CLAUDE_CODE_PLUGIN_DIRS": "/fixture/mods/a"
  },
  "outputStyle": "Explanatory",
  "enabledPlugins": {
    "example@marketplace": true
  }
}
JSON
  : > "$T/done"
) &
writer=$!
out1="$(ls_run)"; code1=$?
kill "$writer" 2>/dev/null; wait "$writer" 2>/dev/null
# The positive control first: the edit really landed while the run was going (L246).
[ -f "$T/done" ] && grep -q '"sonnet"' "$SETTINGS" \
  && printf '%s\n' "$out1" | grep -E '^ +ok +test-waiter\.sh' > /dev/null \
  && check "#1969 (control) the outside writer saved settings.json inside the run" ok \
  || check "#1969 (control) the outside writer saved settings.json inside the run" "out=$out1"
[ "$code1" -eq 0 ] \
  && check "#1969 a person saving settings.json during a run does not fail it" ok \
  || check "#1969 a person saving settings.json during a run does not fail it" "exit=$code1 out=$out1"
case "$out1" in
  *"live-store-pollution"*|*"SUITES CHANGED A LIVE STORE"*)
    check "#1969 and it does not call the edit pollution" "out=$out1" ;;
  *) check "#1969 and it does not call the edit pollution" ok ;;
esac
case "$out1" in
  *"$SETTINGS: "*"a person's own settings edit"*)
    check "#1969 and it says the change was a person's settings edit" ok ;;
  *) check "#1969 and it says the change was a person's settings edit" "out=$out1" ;;
esac
case "$out1" in
  *"enabledPlugins"*"model"*|*"model"*"enabledPlugins"*)
    check "#1969 and it names the settings that changed" ok ;;
  *) check "#1969 and it names the settings that changed" "out=$out1" ;;
esac

# ---- 2. Every setting this config writes is still counted, whoever changed it ----
# The runner's list of them is the one under test, read from the runner itself, so a key added to
# the list is proved counted here on the day it is added. Each case changes that ONE setting and
# keeps every other, which is exactly the shape of claude-sync's own apply run against the real path.
config_keys="$(grep -m1 '^LIVE_SETTINGS_CONFIG_KEYS=' "$RUNNER" | sed -E 's/^[^=]*="([^"]*)".*/\1/')"
[ -n "$config_keys" ] \
  && check "#1969 the runner states the settings this config writes" ok \
  || check "#1969 the runner states the settings this config writes" "no LIVE_SETTINGS_CONFIG_KEYS line in $RUNNER"
for key in $config_keys; do
  seed
  # The one setting changed (or added, where the seed has none), every other kept, by an edit of
  # the parsed file, as claude-sync's own jq writes make it.
  changed="$(jq --arg k "$key" '.[$k] = {"changed": "by a suite"}' "$SETTINGS")"
  mk_writer "$changed"
  out2="$(ls_run)"; code2=$?
  caught "#1969 a suite changing only $key, a setting this config writes, still fails the run" "$code2" "$out2"
done

# ---- 3. A suite's other shapes stay caught ----
# A person's setting changed TOGETHER with one this config writes.
seed
mk_writer '{
  "model": "sonnet",
  "permissions": {"allow": ["Bash(ls:*)"]},
  "hooks": {},
  "env": {"CLAUDE_CODE_PLUGIN_DIRS": "/fixture/mods/a"},
  "outputStyle": "Explanatory"
}'
out3="$(ls_run)"; code3=$?
caught "#1969 a person's setting changed together with the hooks block still fails the run" "$code3" "$out3"

# A whole fixture file written over a settings.json that held only a person's settings: nothing the
# person had is carried over, which is a file being replaced rather than a setting being picked.
printf '{\n  "model": "opus"\n}\n' > "$SETTINGS"
mk_writer '{
  "model": "sonnet",
  "theme": "dark"
}'
out4="$(ls_run)"; code4=$?
caught "#1969 a whole file written over settings.json, carrying nothing over, still fails the run" "$code4" "$out4"

# Truncated, or written as something that is not JSON.
seed
mk_writer ''
out5="$(ls_run)"; code5=$?
caught "#1969 a suite emptying settings.json still fails the run" "$code5" "$out5"
seed
mk_writer 'not json at all'
out6="$(ls_run)"; code6=$?
caught "#1969 a suite writing settings.json as something that is not JSON still fails the run" "$code6" "$out6"

# Deleted outright.
seed
mk_writer DELETE
out7="$(ls_run)"; code7=$?
caught "#1969 a suite deleting settings.json still fails the run" "$code7" "$out7"

# Rewritten with every value the same, in another layout. No setting changed, so nothing a person
# picked explains it, and it stays counted rather than excused.
seed
mk_writer '{"model": "opus", "permissions": {"allow": ["Bash(ls:*)"]}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash /fixture/hooks/stop.sh"}]}]}, "env": {"CLAUDE_CODE_PLUGIN_DIRS": "/fixture/mods/a"}, "outputStyle": "Explanatory"}'
out8="$(ls_run)"; code8=$?
caught "#1969 a rewrite that changed no setting at all is still counted" "$code8" "$out8"

# The control beside all of it: another store in the same home, rewritten by a suite, is caught by
# the same fixture, so a red above is about settings.json and not about a run that brackets nothing.
seed
printf 'the live rules\n' > "$T/cfg/CLAUDE.md"
rm -f "$T/suites"/test-*.sh
{
  printf '#!/usr/bin/env bash\n'
  printf 'printf "a whole file a suite wrote\\n" > "%s"\n' "$T/cfg/CLAUDE.md"
  printf 'printf "SUITE-RESULT passed=1 failed=0\\n"\n'
} > "$T/suites/test-rules.sh"
chmod +x "$T/suites/test-rules.sh"
out9="$(ls_run)"; code9=$?
case "$out9" in
  *"SUITES CHANGED A LIVE STORE"*"$T/cfg/CLAUDE.md"*)
    [ "$code9" -ne 0 ] && check "#1969 (control) a rule file a suite rewrote is still caught beside it" ok \
      || check "#1969 (control) a rule file a suite rewrote is still caught beside it" "exit=$code9 out=$out9" ;;
  *) check "#1969 (control) a rule file a suite rewrote is still caught beside it" "exit=$code9 out=$out9" ;;
esac
rm -f "$T/suites"/test-*.sh

# ---- 4. The runner's list covers every setting claude-sync writes ----
# The list is typed into the runner, which is installed without claude-sync beside it, so it cannot
# read the sync's own constants at run time. A setting the sync starts writing and the list does not
# name would become one a suite could change unnoticed, so the two are compared here wherever the
# checkout is present (L96).
# Asked of lib/checkout-root.sh, never by counting folders up: installed, two levels up is the home
# folder. Inside a checkout the settings lookup answers with the payload's hooks block, which is the
# statement of what the sync installs.
CHECKOUT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null)" || CHECKOUT=""
. "$DIR/lib/settings-file.sh"
HOOKS_JSON="$(hook_settings_file "$DIR/.." 2>/dev/null)" || HOOKS_JSON=""
SYNC_SCRIPT="${CHECKOUT:+$CHECKOUT/claude-sync}"
if [ -n "$CHECKOUT" ] && [ -f "$SYNC_SCRIPT" ] && [ -n "$HOOKS_JSON" ]; then
  shared="$(grep -m1 '^SHARED_SETTINGS_ALLOWED=' "$SYNC_SCRIPT" | sed -E 's/^[^=]*="([^"]*)".*/\1/')"
  [ -n "$shared" ] \
    && check "#1969 claude-sync's shared settings list was read" ok \
    || check "#1969 claude-sync's shared settings list was read" "no SHARED_SETTINGS_ALLOWED line in $SYNC_SCRIPT"
  # The hooks block's own top level keys, then the two the sync writes by name: the status line
  # (#772) and the mods it names for Claude Code in env (CLAUDE_CODE_PLUGIN_DIRS).
  written="$shared $(jq -r 'keys[]' "$HOOKS_JSON" | tr '\n' ' ')"
  grep -q "\.statusLine = " "$SYNC_SCRIPT" && written="$written statusLine"
  grep -q "\.env\.CLAUDE_CODE_PLUGIN_DIRS = " "$SYNC_SCRIPT" && written="$written env"
  missing=""
  for key in $written; do
    case " $config_keys " in *" $key "*) ;; *) missing="$missing $key" ;; esac
  done
  [ -z "$missing" ] \
    && check "#1969 every setting claude-sync writes is one the runner counts" ok \
    || check "#1969 every setting claude-sync writes is one the runner counts" "missing from LIVE_SETTINGS_CONFIG_KEYS:$missing"
  case " $written " in *" statusLine "*) check "#1969 the scan found the status line write" ok ;;
    *) check "#1969 the scan found the status line write" "no .statusLine assignment found in $SYNC_SCRIPT" ;; esac
  case " $written " in *" env "*) check "#1969 the scan found the mods write" ok ;;
    *) check "#1969 the scan found the mods write" "no .env.CLAUDE_CODE_PLUGIN_DIRS assignment found in $SYNC_SCRIPT" ;; esac
else
  echo "SUITE-PART-UNMEASURED the comparison with the settings claude-sync writes, because this copy is not in a claude-config checkout, so claude-sync is not beside it"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
