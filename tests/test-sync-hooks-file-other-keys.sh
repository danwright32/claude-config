#!/usr/bin/env bash
# A key other than hooks in payload/settings.hooks.json is named by the pull and kept by the send
# (claude-config#3741).
#
# The sync reads only the hooks block from that file. Until #3741 a pull met any other top level key
# in silence, so it reached no Mac and nobody was told, and the next send rewrote the file as the
# hooks block alone, deleting the key from the repository. Measured once on 2026-11-26, with a
# permissions block in a throwaway folder. Now the pull applies the hooks block, names every other
# key it left out (in its output, in the sync log, and once in a notification), and the send writes
# the hooks block INTO the file it read, so nothing else in it is dropped.
#
# What this suite does not make the sync do is carry such a key: a setting both Macs share goes in
# settings.shared.json, and only once it is on that file's list, which is Dan's to sign off.
#
# Real claude-sync runs, each against a throwaway home and a throwaway repository: a bare repository
# stands in for GitHub, with one clone per Mac. Kept out of tests/test-claude-sync.sh, whose length
# and run time are open issues (#2463, #2091).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

SCRIPT="$ROOT/claude-sync"
pass=0; fail=0
check(){ # check <name> <command>
  if bash -c "$2" >/dev/null 2>&1; then pass=$((pass + 1)); echo "ok: $1"; else fail=$((fail + 1)); echo "FAIL: $1"; fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-sync-hooks-file-other-keys.XXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "FAIL: $(basename "$0"): the throwaway directory came back as '$WORK'."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT
export CLAUDE_SUITE_RUN_ID="${CLAUDE_SUITE_RUN_ID:-test-sync-hooks-file-other-keys}"
# Every file seam claude-sync honours, pointed inside WORK, as tests/test-claude-sync.sh does, so
# nothing here can reach this Mac's own config, log, notifier, GitHub or Claude Code.
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry" SYNC_ZSHRC="$WORK/zshrc-guard"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root" SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here" SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard"
export SYNC_HOLD_FILE="$WORK/hold-guard" SYNC_RETIRED_FILE="$WORK/retired-guard" SYNC_LOG_FILE="$WORK/sync-log"
export SYNC_GH="$WORK/no-such-gh-here" SYNC_CLAUDE_BIN="$WORK/no-such-claude-here"
export SYNC_LAUNCHAGENTS="$WORK/launchagents-guard" SYNC_MANAGED_SETTINGS="$WORK/managed-settings-guard.json"
export SYNC_PS_FIXTURE="$WORK/ps-guard" SYNC_NO_NOTIFY=1
mkdir -p "$SYNC_SCRATCH_ROOT"; printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"; : > "$SYNC_PS_FIXTURE"
# A commit identity of the fixture's own: the Linux runner has none and refuses to commit.
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# 0 when one line of the text $1 holds every one of the words after it.
line_has(){
  local text="$1"; shift
  awk -v want="$(printf '%s\034' "$@")" 'BEGIN { n = split(want, w, "\034") - 1 }
    { ok = 1; for (i = 1; i <= n; i++) if (index($0, w[i]) == 0) { ok = 0; break } ; if (ok) found = 1 }
    END { exit !found }' <<< "$text"
}
export -f line_has

BARE="$WORK/shared.git"; git init -q --bare "$BARE"
RA="$WORK/repoA"; git clone -q "$BARE" "$RA" 2>/dev/null
HA="$WORK/homeA"; mkdir -p "$HA/hooks"
RB="$WORK/repoB"
HB="$WORK/homeB"; mkdir -p "$HB/hooks"
script(){ printf '#!/usr/bin/env bash\n# %s\nexit 0\n' "$2" > "$1/hooks/$2"; chmod +x "$1/hooks/$2"; }
# settings <home> <name...> -> a settings.json whose hooks block registers each named script, by
# its real path as Claude Code holds it
settings(){
  local home="$1"; shift
  jq -n --arg h "$home" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [$ARGS.positional[] | {type: "command", command: ($h + "/hooks/" + .)}]}]}}' --args "$@" > "$home/settings.json"
}
run(){ # run <command> <home> <repo> <output file>
  CLAUDE_HOME="$2" SYNC_REPO="$3" bash "$SCRIPT" "$1" > "$4" 2>&1
}
branch(){ git -C "$1" symbolic-ref --short HEAD 2>/dev/null || echo main; }
# The file the shared repository holds, as the clone $1 last fetched it
shared_file(){ git -C "$1" show "origin/$(branch "$1"):payload/settings.hooks.json" 2>/dev/null; }
fetch(){ git -C "$1" pull -q --ff-only origin "$(branch "$1")" 2>/dev/null; }
export -f branch shared_file

# A publishes a hooks block registering one gate.
script "$HA" keep.sh; settings "$HA" keep.sh
run sync "$HA" "$RA" "$WORK/a1"
check "fixture: A published its hooks block" "shared_file '$RA' | grep -q 'hooks/keep.sh'"

# Somebody puts a permissions block into the shared file, beside the hooks block, as the builder of
# #3618 did in a throwaway folder: committed and pushed, the way any edit to the repository arrives.
fetch "$RA"
PERMS='{"ask":["Bash(git push *)"]}'
jq --argjson p "$PERMS" '. + {permissions: $p}' "$RA/payload/settings.hooks.json" > "$WORK/with-perms.json"
cp "$WORK/with-perms.json" "$RA/payload/settings.hooks.json"
git -C "$RA" commit -qm "a permissions block beside the hooks block" -- payload/settings.hooks.json
git -C "$RA" push -q origin HEAD 2>/dev/null
check "fixture: the shared file holds the permissions block" "shared_file '$RA' | jq -e '.permissions.ask[0] == \"Bash(git push *)\"'"

# B receives it.
git clone -q "$BARE" "$RB" 2>/dev/null
echo '{}' > "$HB/settings.json"
run pull "$HB" "$RB" "$WORK/b1"
out_b1="$(cat "$WORK/b1")"
check "the pull still applies the hooks block from that file" "jq -e '[.. | .command? // empty | select(endswith(\"/hooks/keep.sh\"))] | length == 1' '$HB/settings.json'"
check "the key beside it never reaches settings.json" "! jq -e 'has(\"permissions\")' '$HB/settings.json'"
check "the pull names the key it did not apply, and the file it is in" \
  "line_has \"\$(cat '$WORK/b1')\" 'settings.hooks.json' 'permissions' 'NOT applied'"
check "and says so in the sync log too" "line_has \"\$(cat '$SYNC_LOG_FILE' 2>/dev/null)\" 'settings.hooks.json' 'permissions' 'NOT applied'"
if ! line_has "$out_b1" 'settings.hooks.json' 'permissions' 'NOT applied'; then
  echo "    the pull said:"; sed -n '1,30p' "$WORK/b1" | cut -c1-300 | sed 's/^/      /'
fi

# B registers a gate of its own and sends. The send must write its hooks block into the file it
# read, keeping the permissions block, rather than rewriting the file as the hooks block alone.
script "$HB" mine.sh
jq --arg c "$HB/hooks/mine.sh" '.hooks.PreToolUse[0].hooks += [{type: "command", command: $c}]' "$HB/settings.json" > "$WORK/b-settings.json"
cp "$WORK/b-settings.json" "$HB/settings.json"
run sync "$HB" "$RB" "$WORK/b2"
fetch "$RB"
check "the send publishes this Mac's new gate" "shared_file '$RB' | grep -q 'hooks/mine.sh'"
check "and keeps the permissions block in the shared file, unchanged" \
  "[ \"\$(shared_file '$RB' | jq -c '.permissions')\" = '$PERMS' ]"
if ! shared_file "$RB" | jq -e '.permissions' >/dev/null 2>&1; then
  echo "    the shared file after the send:"; shared_file "$RB" | sed -n '1,20p' | sed 's/^/      /'
  echo "    the send said:"; sed -n '1,20p' "$WORK/b2" | cut -c1-300 | sed 's/^/      /'
fi

# Control: a shared file holding nothing but the hooks block draws no such report, so the words the
# checks above look for come from the report and not from the pull's ordinary output (L1).
CR="$WORK/control-repo"; CH="$WORK/control-home"; mkdir -p "$CR/payload/hooks" "$CH/hooks"
cp "$HA/hooks/keep.sh" "$CR/payload/hooks/keep.sh"
jq -n --arg c "__CLAUDE_HOME__/hooks/keep.sh" '{hooks: {PreToolUse: [{matcher: "Bash", hooks: [{type: "command", command: $c}]}]}}' > "$CR/payload/settings.hooks.json"
echo '{}' > "$CH/settings.json"
CLAUDE_HOME="$CH" SYNC_REPO="$CR" SYNC_NO_GIT=1 bash "$SCRIPT" pull > "$WORK/c1" 2>&1
check "control: a file holding only the hooks block applies it" "grep -q 'hooks/keep.sh' '$CH/settings.json'"
check "control: and draws no report of a key left out" "! grep -q 'NOT applied' '$WORK/c1' && ! grep -q 'beside the hooks block' '$WORK/c1'"

# Said ONCE in a notification per set of keys, not on every pull (L36), and again for a new key.
NL="$WORK/notified"; : > "$NL"
printf '#!/bin/bash\nwhile [ $# -gt 0 ]; do [ "$1" = -message ] && { printf "%%s\\n" "$2" >> "%s"; shift; }; shift; done\n' "$NL" > "$WORK/notifier"
chmod +x "$WORK/notifier"
jq --argjson p "$PERMS" '. + {permissions: $p}' "$CR/payload/settings.hooks.json" > "$WORK/c-perms.json"
cp "$WORK/c-perms.json" "$CR/payload/settings.hooks.json"
npull(){ CLAUDE_HOME="$CH" SYNC_REPO="$CR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=0 SYNC_NOTIFIER="$WORK/notifier" bash "$SCRIPT" pull > "$1" 2>&1 < /dev/null; }
npull "$WORK/n1"
check "the first pull to meet the key posts a notification naming it" "line_has \"\$(cat '$NL')\" 'permissions' 'settings.hooks.json'"
npull "$WORK/n2"
check "a second pull meeting the same key still says so in its output" "line_has \"\$(cat '$WORK/n2')\" 'settings.hooks.json' 'permissions' 'NOT applied'"
check "but posts no second notification" "[ \"\$(grep -c 'permissions' '$NL')\" = 1 ]"
jq '. + {model: "opus"}' "$CR/payload/settings.hooks.json" > "$WORK/c-model.json"
cp "$WORK/c-model.json" "$CR/payload/settings.hooks.json"
npull "$WORK/n3"
check "a new key beside it is news again, and is named" "line_has \"\$(cat '$NL')\" 'model' 'settings.hooks.json'"

# Failure path: a shared file that cannot be parsed is held exactly as it was by the send, and the
# pull does not claim to have found a key in it (it says the file could not be read instead).
fetch "$RA"
printf 'this is not json\n' > "$WORK/broken.json"
cp "$WORK/broken.json" "$RA/payload/settings.hooks.json"
git -C "$RA" commit -qm "a broken hooks file" -- payload/settings.hooks.json
git -C "$RA" push -q origin HEAD 2>/dev/null
run sync "$HB" "$RB" "$WORK/b3"
fetch "$RB"
check "failure path: a send leaves a shared file that cannot be parsed byte for byte" "shared_file '$RB' | cmp -s - '$WORK/broken.json'"
check "failure path: and the run says the file could not be read" "grep -q 'settings.hooks.json could not be read as JSON' '$WORK/b3'"
check "failure path: and claims no key beside the hooks block" "! grep -q 'beside the hooks block' '$WORK/b3'"

# Failure path: a top level that is not an object holds no hooks block to keep anything beside, and
# is held back the same way rather than replaced.
fetch "$RA"
printf '["hooks"]\n' > "$WORK/array.json"
cp "$WORK/array.json" "$RA/payload/settings.hooks.json"
git -C "$RA" commit -qm "a hooks file that is a list" -- payload/settings.hooks.json
git -C "$RA" push -q origin HEAD 2>/dev/null
run sync "$HB" "$RB" "$WORK/b4"
fetch "$RB"
check "failure path: a send leaves a shared file whose top level is a list as it was" "shared_file '$RB' | cmp -s - '$WORK/array.json'"

echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
