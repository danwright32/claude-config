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
# this config ever writes. The sync adds deny rules under permissions (#3563), and those rules are
# the only thing under permissions it writes, so a change under permissions stays counted only when
# it touches one of them (#3692): a permission granted for good, or a rule added by hand, is a
# person's edit again, and a shared rule added, removed, reworded or moved is not. The rules are
# read from claude-sync, where they are defined, and a runner that cannot read them counts every
# change under permissions. Every case below that must still fail is the half that keeps the guard's
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
# Nor the checkout a pull names for the runner it starts: the runner reads the shared deny rules
# from it (#3692), so a fixture run names its own or none.
unset RUN_ALL_TESTS_CHECKOUT
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
  RUN_ALL_TESTS_CHECKOUT="${LS_CHECKOUT:-}" \
  bash "${LS_RUNNER:-$RUNNER}" "$T/suites" 2>&1
}

# The runner reads settings.json with jq, and without it counts every change (it fails closed). So
# where jq is missing the excusing half cannot be measured, and is said to be rather than failed.
if ! command -v jq >/dev/null 2>&1; then
  echo "SUITE-PART-UNMEASURED every case, because jq is not installed here and the runner reads settings.json with it"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 0
fi

# The checkout this copy sits in, where there is one, and claude-sync in it: the one place the
# settings the sync writes, and the deny rules it shares, are defined. Asked of
# lib/checkout-root.sh, never by counting folders up: installed, two levels up is the home folder.
CHECKOUT="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null)" || CHECKOUT=""
SYNC_SCRIPT="${CHECKOUT:+$CHECKOUT/claude-sync}"
# The deny rules the sync shares, one per line, read from that definition and typed nowhere here
# (#3692). Empty where there is no checkout, and the cases that need them say so.
SHARED_RULES=""
if [ -n "$SYNC_SCRIPT" ] && [ -f "$SYNC_SCRIPT" ]; then
  SHARED_RULES="$(grep -m1 '^SHARED_DENY_RULES=' "$SYNC_SCRIPT" | sed -E 's/^[^=]*="([^"]*)".*/\1/' | tr ' ' '\n' | sed '/^$/d')"
fi

# A settings.json shaped like a real Mac's: settings a person picks (model, their own permission
# rules) beside the ones the sync installs (the hooks block, the mods in env, a shared setting).
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
  if [ "$key" = permissions ] && [ -n "$SHARED_RULES" ]; then
    # Under permissions the sync writes its deny rules and nothing else, so that is the change
    # that stays counted there (#3692): each shared rule added after the Mac's own, as a pull adds
    # them. Where the rules cannot be read, the runner counts every change under permissions, which
    # section 5 holds.
    changed="$(jq --arg rules "$SHARED_RULES" '.permissions.deny = ((.permissions.deny // []) + ($rules | split("\n")))' "$SETTINGS")"
  else
    changed="$(jq --arg k "$key" '.[$k] = {"changed": "by a suite"}' "$SETTINGS")"
  fi
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
# The checkout was asked for above. Inside one the settings lookup answers with the payload's hooks
# block, which is the statement of what the sync installs.
. "$DIR/lib/settings-file.sh"
HOOKS_JSON="$(hook_settings_file "$DIR/.." 2>/dev/null)" || HOOKS_JSON=""
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

# ---- 5. Under permissions, only the deny rules the sync shares are the sync's (#3692) ----
# permissions is on the runner's list because the sync adds its shared deny rules there (#3563),
# and as #3563 shipped that counted every change under it, a permission granted for good included. The
# sync writes nothing else under permissions, so the rule under test: a change under permissions
# is a person's edit when the runner can READ that no shared rule was added, removed, reworded or
# moved, and stays counted in every case where it cannot.
excused(){ # excused <description> <exit code> <output>: the run passes and calls it a person's edit
  case "$3" in
    *"SUITES CHANGED A LIVE STORE"*|*"live-store-pollution"*) check "$1" "exit=$2 out=$3" ;;
    *"$SETTINGS: "*"permissions"*"a person's own settings edit"*)
      [ "$2" -eq 0 ] && check "$1" ok || check "$1" "exit=$2 out=$3" ;;
    *) check "$1" "exit=$2 out=$3" ;;
  esac
}
edit_run(){ # edit_run <jq filter>: a writer making that one edit of the parsed file, then the run
  mk_writer "$(jq --arg rules "$SHARED_RULES" --arg r1 "$R1" --arg r2 "$R2" "$1" "$SETTINGS")"
  out="$(ls_run)"; code=$?
}
if [ -n "$SHARED_RULES" ]; then
  R1="$(printf '%s\n' "$SHARED_RULES" | sed -n 1p)"
  R2="$(printf '%s\n' "$SHARED_RULES" | sed -n '$p')"
  seed_rules(){ # the seed as a Mac holds it after a pull: its own deny rule, then every shared one
    seed
    jq --arg rules "$SHARED_RULES" '.permissions.deny = (["Read(./secrets/**)"] + ($rules | split("\n")))' "$SETTINGS" > "$T/seeded.json" \
      && cat "$T/seeded.json" > "$SETTINGS"
  }
  seed_rules
  [ "$(jq -r '.permissions.deny | length' "$SETTINGS" 2>/dev/null)" -gt 1 ] 2>/dev/null \
    && jq -e --arg r "$R1" '.permissions.deny | index($r) != null' "$SETTINGS" >/dev/null 2>&1 \
    && check "#3692 (control) the fixture holds the shared deny rules claude-sync defines" ok \
    || check "#3692 (control) the fixture holds the shared deny rules claude-sync defines" "rules read: [$SHARED_RULES], settings: $(cat "$SETTINGS")"

  # THE SIDE THAT IS EXCUSED AGAIN. A permission granted for good, as Claude Code saves it: one
  # allow rule added, every shared rule where it was.
  seed_rules
  edit_run '.permissions.allow += ["Bash(git status:*)"]'
  excused "#3692 an allow rule added during a run, with every shared deny rule left alone, does not fail it" "$code" "$out"
  jq -e '.permissions.allow | index("Bash(git status:*)") != null' "$SETTINGS" >/dev/null 2>&1 \
    && check "#3692 (control) and the allow rule really landed in settings.json" ok \
    || check "#3692 (control) and the allow rule really landed in settings.json" "settings: $(cat "$SETTINGS")"
  case "$out" in
    *"none of the deny rules the sync shares"*) check "#3692 and the verdict says the shared deny rules were not touched" ok ;;
    *) check "#3692 and the verdict says the shared deny rules were not touched" "out=$out" ;;
  esac
  # A person's own deny rule put in front of the shared ones, an ask rule and a mode, by hand.
  seed_rules
  edit_run '.permissions.deny = (["Read(./private/**)"] + .permissions.deny) | .permissions.ask = ["Bash(git push:*)"] | .permissions.defaultMode = "acceptEdits"'
  excused "#3692 a person's own deny rule, ask rule and mode, with every shared rule still in deny, do not fail the run" "$code" "$out"
  # The first permission ever granted on a Mac whose settings.json had none.
  seed
  jq 'del(.permissions)' "$SETTINGS" > "$T/seeded.json" && cat "$T/seeded.json" > "$SETTINGS"
  edit_run '.permissions = {"allow": ["Bash(ls:*)"]}'
  excused "#3692 the first permission on a settings.json that had none does not fail the run" "$code" "$out"

  # THE SIDE THAT STAYS COUNTED: a shared rule touched, in each way it can be. Each rule in turn
  # removed, read line by line because the rules hold globs a word split would expand.
  while IFS= read -r rule; do
    [ -n "$rule" ] || continue
    seed_rules
    mk_writer "$(jq --arg r "$rule" '.permissions.deny -= [$r]' "$SETTINGS")"
    out="$(ls_run)"; code=$?
    caught "#3692 the shared deny rule $rule removed still fails the run" "$code" "$out"
  done <<SHAREDRULES
$SHARED_RULES
SHAREDRULES
  seed_rules
  edit_run '.permissions.deny |= map(if . == $r1 then ascii_downcase else . end)'
  caught "#3692 a shared deny rule reworded still fails the run" "$code" "$out"
  seed_rules
  edit_run '.permissions.deny -= [$r1] | .permissions.allow += [$r1]'
  caught "#3692 a shared deny rule moved out of deny into allow still fails the run" "$code" "$out"
  seed_rules
  edit_run '.permissions.deny -= [$r2] | .permissions.allow += ["Bash(git status:*)"]'
  caught "#3692 a shared deny rule removed while another permission is added still fails the run" "$code" "$out"
  seed_rules
  edit_run 'del(.permissions.deny)'
  caught "#3692 the whole deny list removed, shared rules with it, still fails the run" "$code" "$out"
  seed_rules
  edit_run '.permissions.allow += [$r1]'
  caught "#3692 a shared rule's text added to allow beside its deny entry still fails the run" "$code" "$out"
  # Added, beside a person's own change: a Mac holding none gains one, the shape of the sync's write.
  seed
  edit_run '.permissions.deny = [$r2] | .permissions.allow += ["Bash(git status:*)"]'
  caught "#3692 a shared deny rule added beside a hand added allow rule still fails the run" "$code" "$out"

  # A SHAPE THE CHECK CANNOT READ IS NEVER EXCUSED. None of these holds a shared rule before or
  # after, so nothing but the shape can count them: permissions that is not an object, a deny list
  # that is not a list, or holds something other than rule text, in either copy.
  seed
  edit_run '.permissions = "allow everything"'
  caught "#3692 permissions rewritten as a string still fails the run" "$code" "$out"
  seed
  edit_run '.permissions = null'
  caught "#3692 permissions rewritten as null still fails the run" "$code" "$out"
  seed
  edit_run '.permissions.deny = "none" | .permissions.allow += ["Bash(git status:*)"]'
  caught "#3692 a deny list rewritten as a string still fails the run" "$code" "$out"
  seed
  edit_run '.permissions.deny = [{"rule": "Read(./x/**)"}] | .permissions.allow += ["Bash(git status:*)"]'
  caught "#3692 a deny list holding something that is not rule text still fails the run" "$code" "$out"
  seed
  jq '.permissions.deny = {"0": "Read(./x/**)"}' "$SETTINGS" > "$T/seeded.json" && cat "$T/seeded.json" > "$SETTINGS"
  edit_run '.permissions.allow += ["Bash(git status:*)"]'
  caught "#3692 an allow rule added where the deny list was already unreadable still fails the run" "$code" "$out"
  # The same allow rule that is excused above, in a file cut short so it is not JSON.
  seed_rules
  mk_writer "$(jq '.permissions.allow += ["Bash(git status:*)"]' "$SETTINGS" | sed '$d')"
  out="$(ls_run)"; code=$?
  caught "#3692 an allow rule added in a file that is no longer valid JSON still fails the run" "$code" "$out"

  # ANOTHER SETTING THE SYNC WRITES, changed beside a hand added permission.
  seed_rules
  edit_run '.permissions.allow += ["Bash(git status:*)"] | .outputStyle = "default"'
  caught "#3692 a hand added allow rule beside a changed shared setting still fails the run" "$code" "$out"
  seed_rules
  edit_run '.permissions.allow += ["Bash(git status:*)"] | .hooks = {}'
  caught "#3692 a hand added allow rule beside a changed hooks block still fails the run" "$code" "$out"

  # WHERE THE RULES CANNOT BE READ, EVERY CHANGE UNDER permissions IS COUNTED. An installed runner
  # has no claude-sync beside it, so it reads the rules only from the checkout whoever started it
  # named, as a pull does. The copy below sits in no checkout, as the installed one does.
  mkdir -p "$T/installed/hooks" "$T/nolist" "$T/emptylist" "$T/twolists"
  cp "$RUNNER" "$T/installed/hooks/run-all-tests.sh" && ln -s "$DIR/lib" "$T/installed/hooks/lib"
  seed_rules
  mk_writer "$(jq '.permissions.allow += ["Bash(git status:*)"]' "$SETTINGS")"
  out="$(LS_RUNNER="$T/installed/hooks/run-all-tests.sh" LS_CHECKOUT="$CHECKOUT" ls_run)"; code=$?
  excused "#3692 (control) a runner in no checkout, given one by name, reads the rules there and excuses the allow rule" "$code" "$out"
  seed_rules
  out="$(LS_RUNNER="$T/installed/hooks/run-all-tests.sh" ls_run)"; code=$?
  caught "#3692 a runner with no claude-sync to read the shared rules from counts the same allow rule" "$code" "$out"
  printf '#!/usr/bin/env bash\n# a claude-sync that defines no shared deny rules\n' > "$T/nolist/claude-sync"
  seed_rules
  out="$(LS_RUNNER="$T/installed/hooks/run-all-tests.sh" LS_CHECKOUT="$T/nolist" ls_run)"; code=$?
  caught "#3692 a claude-sync with no SHARED_DENY_RULES line leaves the allow rule counted" "$code" "$out"
  printf '#!/usr/bin/env bash\nSHARED_DENY_RULES=""\n' > "$T/emptylist/claude-sync"
  seed_rules
  out="$(LS_RUNNER="$T/installed/hooks/run-all-tests.sh" LS_CHECKOUT="$T/emptylist" ls_run)"; code=$?
  caught "#3692 an empty SHARED_DENY_RULES is not read as nothing to protect: the allow rule stays counted" "$code" "$out"
  { printf '#!/usr/bin/env bash\n'; grep -m1 '^SHARED_DENY_RULES=' "$SYNC_SCRIPT"; printf 'SHARED_DENY_RULES="Read(./elsewhere/**)"\n'; } > "$T/twolists/claude-sync"
  seed_rules
  out="$(LS_RUNNER="$T/installed/hooks/run-all-tests.sh" LS_CHECKOUT="$T/twolists" ls_run)"; code=$?
  caught "#3692 a claude-sync defining SHARED_DENY_RULES twice leaves the allow rule counted" "$code" "$out"
  rm -f "$T/suites"/test-*.sh
else
  echo "SUITE-PART-UNMEASURED the shared deny rule cases (#3692), because this copy is not in a claude-config checkout, so there is no claude-sync to read SHARED_DENY_RULES from"
  # What can be measured anywhere: with no rules to read, this runner counts a hand added allow rule.
  seed
  mk_writer "$(jq '.permissions.allow += ["Bash(git status:*)"]' "$SETTINGS")"
  out="$(ls_run)"; code=$?
  caught "#3692 a runner with no claude-sync to read the shared rules from counts a hand added allow rule" "$code" "$out"
  rm -f "$T/suites"/test-*.sh
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
