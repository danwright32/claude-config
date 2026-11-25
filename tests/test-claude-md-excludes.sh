#!/usr/bin/env bash
# Holds the claudeMdExcludes patterns the sync installs on both Macs to exactly this repository's own
# copies of the global rules file (claude-config#3635).
#
# WHY. payload/CLAUDE.md is the global rules file, with 14 imports. Claude Code loads a CLAUDE.md in
# a subfolder of the working folder the first time a session reads, writes or edits a file beside
# it, so every agent working here took a second copy of the rules, about 100,000 characters, at its
# first touch of payload/. Measured 2026-11-25 over 433 agents: 318 loaded it, a median 36,610
# tokens more than an ordinary read, kept for the rest of each run. claudeMdExcludes skips a file
# by glob on its absolute path; 22 headless runs on 2026-11-25 showed it stops the load in a main
# session, a general purpose agent and an omitClaudeMd agent, drops the 14 imports with it, and
# leaves the installed ~/.claude/CLAUDE.md loading (evidence on pull request for #3635).
#
# THE RULE. Every pattern matches this repository's payload/CLAUDE.md in the development checkout,
# in any worktree under its .claude/worktrees, and in the sync clone, whatever the home folder is
# called; and none matches the installed ~/.claude/CLAUDE.md, the repository's own root CLAUDE.md,
# a worktree's root CLAUDE.md, or any other project's CLAUDE.md. No pattern names a home folder.
#
# THE MATCHER follows the glob rules Claude Code documents for the setting ("matched against
# absolute file paths using glob syntax"): ** spans whole folders, * stays inside one name, and
# neither matches a name starting with a dot unless the pattern spells the dot. It is run against
# fixed patterns before it is believed about the real ones (L1). That the real patterns take effect
# is shown only by a headless run, which spends tokens, so it is not part of this suite.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }

# 0 when the glob $1 matches the absolute path $2.
glob_match(){
  python3 -I - "$1" "$2" <<'PY'
import re, sys
pat, path = sys.argv[1], sys.argv[2]
out = ""
parts = pat.split("/")
for n, seg in enumerate(parts):
    last = n == len(parts) - 1
    if seg == "**":
        # zero or more whole names, none starting with a dot; a leading ** also takes the root slash
        if n == 0:
            out += "(?:/[^/.][^/]*)*/"
        elif last:
            out += "(?:[^/.][^/]*(?:/[^/.][^/]*)*)?"
        else:
            out += "(?:[^/.][^/]*/)*"
        continue
    s = ""
    for k, ch in enumerate(seg):
        if ch == "*":
            s += "(?![.])[^/]*" if k == 0 else "[^/]*"
        elif ch == "?":
            s += "[^/]"
        else:
            s += re.escape(ch)
    out += s + ("" if last else "/")
sys.exit(0 if re.fullmatch(out, path) else 1)
PY
}

# The matcher itself, against fixed patterns.
glob_match '**/a/b.md' '/x/y/a/b.md' && ok || bad "matcher: **/a/b.md should match /x/y/a/b.md"
glob_match '**/a/b.md' '/x/a/c/b.md' && bad "matcher: **/a/b.md matched /x/a/c/b.md" || ok
glob_match '**/a/*/b.md' '/x/a/w1/b.md' && ok || bad "matcher: * should match one name"
glob_match '**/a/*/b.md' '/x/a/w1/w2/b.md' && bad "matcher: * crossed a folder" || ok
glob_match '**/b.md' '/x/.hidden/b.md' && bad "matcher: ** crossed a dot folder" || ok
glob_match '**/.c/b.md' '/x/.c/b.md' && ok || bad "matcher: a spelled dot should match"

SETTINGS="$ROOT/payload/settings.shared.json"
pats="$(jq -r '.claudeMdExcludes // [] | if type == "array" then .[] else error("not an array") end' "$SETTINGS" 2>/dev/null)"
if [ -z "$pats" ]; then
  bad "payload/settings.shared.json carries no claudeMdExcludes, so every session here loads payload/CLAUDE.md and its 14 imports a second time at its first touch of payload/"
else
  ok
fi

match_any(){ # 0 when any pattern matches $1
  local p
  while IFS= read -r p; do
    [ -n "$p" ] || continue
    glob_match "$p" "$1" && return 0
  done <<< "$pats"
  return 1
}

while IFS= read -r p; do
  [ -n "$p" ] || continue
  case "$p" in
    '**/'*) ok ;;
    *) bad "pattern '$p' does not start with **/, so it names a home folder or a relative path and cannot hold on both Macs" ;;
  esac
done <<< "$pats"

for home in /Users/alice "/home/bob smith"; do
  must=(
    "$home/Non-icloudDocuments/Apps/claude-config/payload/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config/.claude/worktrees/fix-3635/payload/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config/.claude/worktrees/agent-a1b2c3/payload/CLAUDE.md"
    "$home/claude-config-sync/payload/CLAUDE.md"
    "$home/code/claude-config/payload/CLAUDE.md"
  )
  never=(
    "$home/.claude/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config/.claude/worktrees/fix-3635/CLAUDE.md"
    "$home/claude-config-sync/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/Ovation/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/Ovation/payload/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config-old/payload/CLAUDE.md"
    "$home/Non-icloudDocuments/Apps/claude-config/payload/skills/x/CLAUDE.md"
  )
  for f in "${must[@]}"; do
    if [ -n "$pats" ] && match_any "$f"; then ok; else bad "no claudeMdExcludes pattern matches $f, so it loads as a second copy of the rules"; fi
  done
  for f in "${never[@]}"; do
    if [ -n "$pats" ] && match_any "$f"; then bad "a claudeMdExcludes pattern matches $f, which must keep loading"; else ok; fi
  done
done

# ---- The sync carries it: a pull installs it, refuses a bad one, and a send keeps it ----
# claudeMdExcludes is a user setting, so it travels in payload/settings.shared.json and claude-sync
# admits it by name (Dan's sign off, 2026-11-25). The sync checks its shape: a list of patterns,
# each starting with **/ and ending in /payload/CLAUDE.md, so the shared file cannot be used to
# stop any other rules file loading.
SCRIPT="$ROOT/claude-sync"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.mdexcl.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-claude-md-excludes: refusing to run: the throwaway directory came back as '$WORK'." >&2
    printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$((fail + 1))"
    exit 1 ;;
esac
trap 'rm -rf "$WORK"' EXIT
# Every file seam claude-sync honours, pointed inside WORK, as tests/test-claude-sync.sh does, so
# nothing here can reach this Mac's own config, log, notifier, GitHub or Claude Code.
export SYNC_CLONE_REGISTRY="$WORK/no-such-directory/clone-registry" SYNC_ZSHRC="$WORK/zshrc-guard"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root" SYNC_NO_SEND_TESTS=1 SYNC_NO_HOOK_TESTS=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here" SYNC_WATCH_PID_FILE="$WORK/watch-pid-guard"
export SYNC_HOLD_FILE="$WORK/hold-guard" SYNC_RETIRED_FILE="$WORK/retired-guard" SYNC_LOG_FILE="$WORK/sync-log-guard"
export SYNC_GH="$WORK/no-such-gh-here" SYNC_CLAUDE_BIN="$WORK/no-such-claude-here"
export SYNC_LAUNCHAGENTS="$WORK/launchagents-guard" SYNC_MANAGED_SETTINGS="$WORK/managed-settings-guard.json"
export SYNC_PS_FIXTURE="$WORK/ps-guard" SYNC_NO_NOTIFY=1
mkdir -p "$SYNC_SCRATCH_ROOT"; printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"; : > "$SYNC_PS_FIXTURE"

ORIG='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash x.sh"}]}]},"model":"opus","permissions":{"allow":["Bash(ls)"]}}'
fixture(){ # $1 name  $2 shared settings JSON -> sets R (repo) and H (home)
  R="$WORK/$1-repo"; H="$WORK/$1-home"
  git init -q "$R"; mkdir -p "$R/payload" "$H"
  printf '%s\n' "$2" > "$R/payload/settings.shared.json"
  printf '%s\n' "$ORIG" > "$H/settings.json"
}
pull(){ CLAUDE_HOME="$H" SYNC_REPO="$R" SYNC_NO_GIT=1 bash "$SCRIPT" pull 2>&1 || true; }

# This repository's own shared file, pulled into a Mac whose settings.json has a list of its own.
fixture real "$(cat "$SETTINGS")"
jq -c '. + {"claudeMdExcludes": ["**/elsewhere/payload/CLAUDE.md"]}' <<< "$ORIG" > "$H/settings.json"
out="$(pull)"
want="$(jq -c '.claudeMdExcludes' "$SETTINGS" 2>/dev/null)"
if [ -n "$pats" ] && [ "$(jq -c '.claudeMdExcludes' "$H/settings.json" 2>/dev/null)" = "$want" ]; then ok
else bad "a pull of payload/settings.shared.json did not write its claudeMdExcludes into settings.json; the pull said: $(printf '%s' "$out" | grep -m1 -i 'settings.shared.json\|claudeMdExcludes')"; fi
grep -q 'elsewhere' "$H/settings.json" && bad "a pull kept the Mac's own claudeMdExcludes instead of the shared list" || ok
if grep -q 'claudeMdExcludes' <<< "$out" && ! grep -q 'claudeMdExcludes\.0' <<< "$out"; then ok
else bad "the pull did not name claudeMdExcludes once as written (it must not list it element by element)"; fi
keep='reduce ($s[0] | keys[]) as $k (.; del(.[$k]))'
if [ "$(jq -cS --slurpfile s "$SETTINGS" "$keep" "$H/settings.json")" = "$(jq -cS --slurpfile s "$SETTINGS" "$keep" <<< "$ORIG")" ]; then ok
else bad "a pull changed a setting the shared file does not hold"; fi

# A bad value is refused whole, naming the setting, and writes nothing.
for c in 'string:"**/claude-config/payload/CLAUDE.md"' 'home:["/Users/someone/claude-config/payload/CLAUDE.md"]' \
         'other:["**/CLAUDE.md"]' 'number:[3]' 'empty:[]'; do
  name="${c%%:*}"; val="${c#*:}"
  fixture "bad-$name" "{\"claudeMdExcludes\": $val}"
  sum="$(cksum < "$H/settings.json")"
  out="$(pull)"
  [ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "a claudeMdExcludes of $val ($name) was written; it must be refused"
  grep 'settings.shared.json' <<< "$out" | grep -q -e 'claudeMdExcludes is ' -e 'claudeMdExcludes holds ' && ok \
    || bad "the refusal of $val ($name) does not say what is wrong with claudeMdExcludes"
done

# A send keeps it: the shared file is edited in the repository only, so a send that really publishes
# leaves the exclusion in the shared repository exactly as it was.
B="$WORK/send-bare.git"; D="$WORK/send-dev"; C="$WORK/send-clone"; SH="$WORK/send-home"
git init -q --bare -b main "$B"; git clone -q "$B" "$D" 2>/dev/null; mkdir -p "$D/payload" "$SH"
printf '# rules\n' > "$D/payload/CLAUDE.md"; cp "$SETTINGS" "$D/payload/settings.shared.json"
git -C "$D" add payload && git -C "$D" -c user.name=t -c user.email=t@e commit -q -m base 2>/dev/null && git -C "$D" push -q origin main 2>/dev/null
git clone -q "$B" "$C" 2>/dev/null; printf '%s\n' "$ORIG" > "$SH/settings.json"
CLAUDE_HOME="$SH" SYNC_REPO="$C" bash "$SCRIPT" pull >/dev/null 2>&1
printf '# rules, edited on this Mac\n' > "$SH/CLAUDE.md"
CLAUDE_HOME="$SH" SYNC_REPO="$C" bash "$SCRIPT" send >/dev/null 2>&1
case "$(git -C "$B" show main:payload/CLAUDE.md 2>/dev/null)" in
  *'edited on this Mac'*) ok ;; *) bad "send fixture: the send did not publish, so it proves nothing about the shared file" ;;
esac
if [ -n "$pats" ] && [ "$(git -C "$B" show main:payload/settings.shared.json 2>/dev/null | jq -c '.claudeMdExcludes')" = "$want" ]; then ok
else bad "after a send the shared repository's settings.shared.json no longer carries claudeMdExcludes as the repository held it"; fi

echo "test-claude-md-excludes: $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
