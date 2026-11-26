#!/usr/bin/env bash
# Holds the Read deny rules both Macs share to exactly the three stored login folders, and holds
# the sync to carrying them and nothing else under permissions (claude-config#3563).
#
# WHY. Measured 2026-11-24 on the work MacBook and 2026-11-25 on the personal MacBook: neither
# Mac's settings.json held a single deny rule, so a session misled by something it read could open
# an SSH private key or a stored Cloudflare or Salesforce CLI login with the ordinary file tool.
# Claude Code refuses a file tool call on a path a Read deny rule matches, and a shell command it
# recognises as reading that path. 91 headless runs on 2026-11-25 (Claude Code 2.1.332, stand in
# files in a scratch home) showed each of the three rules refusing Read in 3 of 3 runs against 3 of
# 3 successes without it, cat refused the same way by absolute, tilde and relative path, and
# ordinary files still readable (evidence on the pull request for #3563).
#
# THE RULES. Read(~/.ssh/**), Read(~/.sfdx/**) and Read(~/Library/Preferences/.wrangler/config/**).
# Each starts at ~/, which Claude Code reads as the home folder of whoever runs it, so the same
# text holds on both Macs and the repository names nobody's home. Each covers everything inside
# its folder at any depth and nothing outside it: a project's own .ssh or .wrangler folder, the
# rest of Library/Preferences and every ordinary file stay readable.
#
# THE MATCHER follows what Claude Code documents for a Read rule's path ("gitignore pattern
# syntax", with ~/path "from home directory", * inside one name and ** across folders, a leading
# dot matched like any other character). It is run against fixed patterns before it is believed
# about the real ones (L1). That the real rules take effect is shown only by a headless run, which
# spends tokens, so it is not part of this suite.
#
# THE SYNC. permissions otherwise stays each Mac's own, so the pull ADDS each shared rule to that
# Mac's permissions.deny and touches nothing else there: its allow and ask rules, its mode and its
# own deny rules survive, a second pull changes nothing, and a rule is never removed. The shared
# file may hold permissions.deny only, and only these three rules: an allow rule, a mode, or a
# rule wide enough to stop a Mac's sessions reading their own projects is refused whole.
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

# 0 when the rule $1, read for the home folder $2, covers the absolute path $3.
rule_match(){
  python3 -I - "$1" "$2" "$3" <<'PY'
import re, sys
rule, home, path = sys.argv[1], sys.argv[2], sys.argv[3]
m = re.fullmatch(r"Read\((.*)\)", rule)
if not m:
    sys.exit(2)
pat = m.group(1)
if pat.startswith("~/"):
    pat = home.rstrip("/") + "/" + pat[2:]
elif pat.startswith("//"):
    pat = pat[1:]
else:
    sys.exit(2)          # a relative rule depends on the working folder, which this suite has none of
parts = pat.split("/")[1:]
out = ""
for n, seg in enumerate(parts):
    last = n == len(parts) - 1
    if seg == "**":
        out += "/.+" if last else "(?:/[^/]+)*"
        continue
    s = ""
    for ch in seg:
        if ch == "*":
            s += "[^/]*"
        elif ch == "?":
            s += "[^/]"
        else:
            s += re.escape(ch)
    out += "/" + s
sys.exit(0 if re.fullmatch(out, path) else 1)
PY
}

# The matcher itself, against fixed patterns.
rule_match 'Read(~/a/**)' /h/u /h/u/a/b && ok || bad "matcher: ~/a/** should match a file in ~/a"
rule_match 'Read(~/a/**)' /h/u /h/u/a/b/c/d && ok || bad "matcher: ~/a/** should match at any depth"
rule_match 'Read(~/a/**)' /h/u /h/u/a/.hidden && ok || bad "matcher: ~/a/** should match a dot file"
rule_match 'Read(~/a/**)' /h/u /h/u/ab/c && bad "matcher: ~/a/** matched the sibling folder ab" || ok
rule_match 'Read(~/a/**)' /h/u /h/u/x/a/b && bad "matcher: ~/a/** matched an a folder deeper than home" || ok
rule_match 'Read(~/a/**)' /h/u /h/other/a/b && bad "matcher: ~/a/** matched another home" || ok
rule_match 'Read(~/a/*.pdf)' /h/u /h/u/a/x.pdf && ok || bad "matcher: * should match inside one name"
rule_match 'Read(~/a/*.pdf)' /h/u /h/u/a/b/x.pdf && bad "matcher: * crossed a folder" || ok
rule_match 'Read(~/**)' /h/u /h/u/anything/at/all && ok || bad "matcher: ~/** should match everything under home"

WANT_RULES='Read(~/.ssh/**)
Read(~/.sfdx/**)
Read(~/Library/Preferences/.wrangler/config/**)'
THREE='["Read(~/.ssh/**)","Read(~/.sfdx/**)","Read(~/Library/Preferences/.wrangler/config/**)"]'
SCRIPT="$ROOT/claude-sync"
SETTINGS="$ROOT/payload/settings.shared.json"
# The shared file a pull is handed in the checks below: this repository's own.
SHARED_JSON="$(cat "$SETTINGS")"

# HELD-BEGIN (claude-config#3563). The sync writes a shared setting only when its name is on
# claude-sync's SHARED_SETTINGS_ALLOWED, and adding permissions to that list is Dan's decision,
# not yet made. Until it is, the shared file cannot hold the rules (an unlisted key makes a pull
# refuse the whole file), so neither Mac is given them, and this suite says so on every run
# instead of failing on it. What it can still prove, it proves: that the hold is in force, and
# that the code waiting behind it is right, by running every pull, status and refusal check below
# against a copy of claude-sync that differs by that one name, handed this repository's shared
# file with the three rules added. The change that puts the name on the list deletes this block
# and the one further down, and the same checks then run against claude-sync and the shared file
# as they are.
HELD=""
if ! grep -q '^SHARED_SETTINGS_ALLOWED="[^"]* permissions"$' "$SCRIPT"; then
  HELD=1
  echo "SUITE-PART-UNMEASURED the three Read deny rules reaching either Mac, because claude-sync's SHARED_SETTINGS_ALLOWED does not name permissions (Dan's sign off for claude-config#3563 is pending), so payload/settings.shared.json cannot hold them and no pull installs them; the pull, status and refusal checks ran against a copy of claude-sync with that one name added"
  if [ "$(jq -r 'has("permissions")' "$SETTINGS" 2>/dev/null)" = false ]; then ok
  else bad "payload/settings.shared.json holds permissions while claude-sync's SHARED_SETTINGS_ALLOWED does not name it, so every pull refuses the whole shared file and no shared setting is written on either Mac"; fi
  SHARED_JSON="$(jq -c --argjson d "$THREE" '. + {permissions: {deny: $d}}' "$SETTINGS")"
fi
# HELD-END

if [ -z "$HELD" ]; then
  rules="$(jq -r '.permissions.deny // [] | if type == "array" then .[] else error("not an array") end' "$SETTINGS" 2>/dev/null)"
  if [ "$rules" = "$WANT_RULES" ]; then ok
  else bad "payload/settings.shared.json does not carry exactly the three Read deny rules under permissions.deny (it carries: ${rules:-none}), so neither Mac is given them and a session's file tools can open SSH keys and the stored Cloudflare and Salesforce logins"; fi
  if [ "$(jq -c '.permissions // {} | keys' "$SETTINGS" 2>/dev/null)" = '["deny"]' ]; then ok
  else bad "payload/settings.shared.json holds $(jq -c '.permissions // {} | keys' "$SETTINGS" 2>/dev/null) under permissions; it may hold deny and nothing else, since every other permission setting stays each Mac's own"; fi
fi

# The rules as written here are what the checks below judge, so a shared file that drops one fails
# above and the path checks still say what each rule covers.
while IFS= read -r r; do
  case "$r" in
    'Read(~/'*'/**)') ok ;;
    *) bad "rule '$r' is not Read(~/<folder>/**), so it names a home folder or a relative path and cannot hold on both Macs" ;;
  esac
  case "$r" in
    */Users/*|*/home/*) bad "rule '$r' names a home folder" ;;
    *) ok ;;
  esac
done <<< "$WANT_RULES"

match_any(){ # $1 home  $2 path -> 0 when any rule covers the path
  local r
  while IFS= read -r r; do
    rule_match "$r" "$1" "$2" && return 0
  done <<< "$WANT_RULES"
  return 1
}

for home in /Users/alice "/home/bob smith"; do
  must=(
    "$home/.ssh/id_ed25519"
    "$home/.ssh/id_rsa"
    "$home/.ssh/id_ed25519.pub"
    "$home/.ssh/config"
    "$home/.ssh/known_hosts"
    "$home/.ssh/keys/deploy/id_ed25519"
    "$home/.sfdx/alias.json"
    "$home/.sfdx/someone@example.com.json"
    "$home/.sfdx/orgs/sandbox.json"
    "$home/Library/Preferences/.wrangler/config/default.toml"
    "$home/Library/Preferences/.wrangler/config/staging/default.toml"
  )
  never=(
    "$home/.zshrc"
    "$home/.gitconfig"
    "$home/.claude/settings.json"
    "$home/.claude/CLAUDE.md"
    "$home/.sshrc"
    "$home/.ssh-old/id_rsa"
    "$home/.sfdx-notes.txt"
    "$home/Library/Preferences/com.apple.Terminal.plist"
    "$home/Library/Preferences/.wrangler/logs/wrangler.log"
    "$home/Non-icloudDocuments/Apps/Ovation/README.md"
    "$home/Non-icloudDocuments/Apps/Ovation/docs/notes/todo.txt"
    "$home/Non-icloudDocuments/Apps/Ovation/.ssh/config"
    "$home/Non-icloudDocuments/Apps/Ovation/.sfdx/sfdx-config.json"
    "$home/Non-icloudDocuments/Apps/Ovation/wrangler.toml"
    "$home/Non-icloudDocuments/Apps/Ovation/.wrangler/config/default.toml"
    "$home/Non-icloudDocuments/Apps/claude-config/payload/settings.shared.json"
    "/private/tmp/work/.ssh/id_rsa"
    "/Users/somebody-else/.ssh/id_rsa"
  )
  for f in "${must[@]}"; do
    if match_any "$home" "$f"; then ok; else bad "no rule covers $f for the home folder $home, so the file tools can open it"; fi
  done
  for f in "${never[@]}"; do
    if match_any "$home" "$f"; then bad "a rule covers $f for the home folder $home, which must stay readable"; else ok; fi
  done
done
# Each rule covers its own folder and neither of the others', so dropping one opens exactly that folder.
while IFS= read -r r; do
  hits=0
  for f in /Users/alice/.ssh/id_rsa /Users/alice/.sfdx/alias.json /Users/alice/Library/Preferences/.wrangler/config/default.toml; do
    rule_match "$r" /Users/alice "$f" && hits=$((hits + 1))
  done
  [ "$hits" -eq 1 ] && ok || bad "rule '$r' covers $hits of the three login folders; each rule covers exactly one"
done <<< "$WANT_RULES"

# ---- The sync carries them: a pull adds them, keeps the Mac's own rules, and refuses anything else ----
WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.denyrules.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}"|"${TMPDIR:-/tmp}"|"${TMPDIR:-/tmp}"/)
    echo "test-shared-deny-rules: refusing to run: the throwaway directory came back as '$WORK'." >&2
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

# A Mac with rules of its own in every list, one of them a shared rule it already holds.
OWN='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash x.sh"}]}]},"model":"opus","permissions":{"allow":["Bash(ls)","Read(~/notes/**)"],"ask":["Bash(git push *)"],"deny":["Read(./secrets/**)","Read(~/.sfdx/**)"],"defaultMode":"auto","additionalDirectories":["/tmp/extra"]}}'
BARE='{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"bash x.sh"}]}]},"model":"opus"}'
fixture(){ # $1 name  $2 shared settings JSON  $3 the Mac's settings.json -> sets R (repo) and H (home)
  R="$WORK/$1-repo"; H="$WORK/$1-home"
  git init -q "$R"; mkdir -p "$R/payload" "$H"
  printf '%s\n' "$2" > "$R/payload/settings.shared.json"
  printf '%s\n' "$3" > "$H/settings.json"
}
pull(){ CLAUDE_HOME="$H" SYNC_REPO="$R" SYNC_NO_GIT=1 bash "$SCRIPT" pull 2>&1 || true; }
status(){ CLAUDE_HOME="$H" SYNC_REPO="$R" SYNC_NO_GIT=1 bash "$SCRIPT" status 2>&1 || true; }
has_rule(){ jq -e --arg r "$1" '(.permissions.deny // []) | index($r) != null' "$H/settings.json" >/dev/null 2>&1; }
count_rule(){ jq -r --arg r "$1" '[(.permissions.deny // [])[] | select(. == $r)] | length' "$H/settings.json" 2>/dev/null; }
# 0 when one line of the text $1 holds both $2 and $3. One awk reading the whole text, never a pipe
# into grep -q, which under pipefail fails a check whose words are there (the first grep is cut off).
line_has(){ awk -v a="$2" -v b="$3" 'index($0, a) && index($0, b) { found = 1 } END { exit !found }' <<< "$1"; }
printf '%s\n' "$SHARED_JSON" > "$WORK/shared.json"

# HELD-BEGIN (claude-config#3563), the second of the two blocks: see the first.
if [ -n "$HELD" ]; then
  # The hold itself, on claude-sync as it is: a shared file carrying the rules is refused whole,
  # naming permissions, and nothing is written, the other shared settings included.
  fixture held "$SHARED_JSON" "$OWN"
  sum="$(cksum < "$H/settings.json")"
  out="$(pull)"
  [ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "claude-sync wrote settings.json from a shared file holding permissions, though SHARED_SETTINGS_ALLOWED does not name it"
  if line_has "$out" 'settings.shared.json' 'carries permissions'; then ok
  else bad "claude-sync's refusal of a shared file holding permissions does not name permissions as the key it does not share"; fi
  # The copy every check below runs: claude-sync with the one name added and nothing else, beside
  # a link to this repository's payload so it finds its own files where claude-sync does.
  mkdir -p "$WORK/withname"
  sed 's/^\(SHARED_SETTINGS_ALLOWED="[^"]*\)"$/\1 permissions"/' "$ROOT/claude-sync" > "$WORK/withname/claude-sync"
  ln -s "$ROOT/payload" "$WORK/withname/payload"
  sed 's/^\(SHARED_SETTINGS_ALLOWED="[^"]*\) permissions"$/\1"/' "$WORK/withname/claude-sync" > "$WORK/withname/back"
  if grep -q '^SHARED_SETTINGS_ALLOWED="[^"]* permissions"$' "$WORK/withname/claude-sync" && cmp -s "$WORK/withname/back" "$ROOT/claude-sync"; then ok
  else bad "fixture: the copy of claude-sync does not differ from it by exactly the name permissions on SHARED_SETTINGS_ALLOWED, so the checks below prove nothing about it"; fi
  SCRIPT="$WORK/withname/claude-sync"
fi
# HELD-END

# This repository's own shared file, pulled onto a Mac with rules of its own.
fixture real "$SHARED_JSON" "$OWN"
out="$(pull)"
while IFS= read -r r; do
  if has_rule "$r"; then ok
  else bad "a pull of payload/settings.shared.json did not add $r to permissions.deny in settings.json; the pull said: $(grep -i -e 'settings.shared.json' -e 'permissions' <<< "$out")"; fi
  [ "$(count_rule "$r")" = 1 ] && ok || bad "after a pull permissions.deny holds $r $(count_rule "$r") times; it must hold it once, a rule the Mac already had included"
done <<< "$WANT_RULES"
has_rule 'Read(./secrets/**)' && ok || bad "a pull dropped the Mac's own deny rule Read(./secrets/**)"
[ "$(jq -c '.permissions.deny[0:2]' "$H/settings.json" 2>/dev/null)" = '["Read(./secrets/**)","Read(~/.sfdx/**)"]' ] && ok \
  || bad "a pull reordered the deny rules the Mac already held"
if [ "$(jq -cS '.permissions | del(.deny)' "$H/settings.json" 2>/dev/null)" = "$(jq -cS '.permissions | del(.deny)' <<< "$OWN")" ]; then ok
else bad "a pull changed the Mac's own allow rules, ask rules, mode or extra folders under permissions"; fi
if [ "$(jq -cS --slurpfile s "$WORK/shared.json" 'reduce ($s[0] | keys[]) as $k (.; del(.[$k]))' "$H/settings.json" 2>/dev/null)" = "$(jq -cS --slurpfile s "$WORK/shared.json" 'reduce ($s[0] | keys[]) as $k (.; del(.[$k]))' <<< "$OWN")" ]; then ok
else bad "a pull changed a setting the shared file does not hold"; fi
if grep -q 'permissions\.deny' <<< "$out" && ! grep -q 'permissions\.deny\.0' <<< "$out"; then ok
else bad "the pull did not name permissions.deny once as written (it must not list it rule by rule)"; fi
# A second pull with nothing new leaves the file byte for byte and claims nothing.
sum="$(cksum < "$H/settings.json")"
out2="$(pull)"
[ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "a second pull rewrote settings.json though every shared deny rule was already there"
grep -q 'permissions\.deny' <<< "$out2" && bad "a second pull claims to have written permissions.deny again" || ok
# Status is quiet about the rules while they are all there, and names one a hand edit dropped.
st="$(status)"
grep -q -i 'deny rule' <<< "$st" && bad "status speaks of deny rules on a Mac that holds all three: $(grep -i 'deny rule' <<< "$st")" || ok
jq -c '.permissions.deny -= ["Read(~/.ssh/**)"]' "$H/settings.json" > "$H/settings.json.tmp" && mv "$H/settings.json.tmp" "$H/settings.json"
st="$(status)"
if line_has "$st" 'as a deny rule' 'Read(~/.ssh/**)'; then ok
else bad "status does not name Read(~/.ssh/**) on a Mac whose settings.json lost it"; fi
line_has "$st" 'as a deny rule' 'Read(~/.sfdx/**)' && bad "status names Read(~/.sfdx/**) as missing on a Mac that holds it" || ok
pull >/dev/null
has_rule 'Read(~/.ssh/**)' && ok || bad "the next pull did not put back a shared deny rule a hand edit dropped"

# A Mac with no permissions block at all gains the three, and nothing else under permissions.
fixture bare "$SHARED_JSON" "$BARE"
out="$(pull)"
[ "$(jq -c '.permissions' "$H/settings.json" 2>/dev/null)" = "{\"deny\":$THREE}" ] && ok \
  || bad "a Mac with no permissions block did not end with exactly the three deny rules; it holds $(jq -c '.permissions' "$H/settings.json" 2>/dev/null)"

# A Mac whose permissions.deny is not a list is left exactly as it was, and the pull says so.
fixture oddmac "$SHARED_JSON" '{"model":"opus","permissions":{"deny":"Read(./x)"}}'
sum="$(cksum < "$H/settings.json")"
out="$(pull)"
[ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "a settings.json whose permissions.deny is not a list was rewritten"
if line_has "$out" 'could not write' 'permissions.deny is not a list of rules'; then ok
else bad "a pull that could not add the deny rules to a settings.json whose permissions.deny is not a list did not say that is why"; fi
st="$(status)"
if line_has "$st" 'could not check' 'deny rules'; then ok
else bad "status does not say it could not check the deny rules on a Mac whose permissions.deny is not a list (silence there would read as every rule being in place)"; fi
# The same when permissions itself is not an object, so there is no list to add to.
fixture oddmac2 "$SHARED_JSON" '{"model":"opus","permissions":"none"}'
sum="$(cksum < "$H/settings.json")"
out="$(pull)"
[ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "a settings.json whose permissions is not an object was rewritten"
if line_has "$out" 'could not write' 'Its permissions is not an object'; then ok
else bad "a pull that could not add the deny rules to a settings.json whose permissions is not an object did not say that is why"; fi
line_has "$out" 'could not write' 'permissions.deny is not a list' && bad "the pull blamed permissions.deny for a settings.json whose permissions is not an object at all" || ok
st="$(status)"
if line_has "$st" 'could not check' 'deny rules'; then ok
else bad "status does not say it could not check the deny rules on a Mac whose permissions is not an object"; fi

# Anything else under permissions is refused whole, naming it, and writes nothing.
for c in "allow:{\"allow\":[\"Bash(rm *)\"]}" \
         "denyandallow:{\"deny\":$THREE,\"allow\":[\"Read(~/.ssh/**)\"]}" \
         "ask:{\"deny\":$THREE,\"ask\":[\"Bash(ls)\"]}" \
         "mode:{\"deny\":$THREE,\"defaultMode\":\"bypassPermissions\"}" \
         "folders:{\"deny\":$THREE,\"additionalDirectories\":[\"~/.ssh\"]}" \
         'nodeny:{}' \
         'string:{"deny":"Read(~/.ssh/**)"}' \
         'empty:{"deny":[]}' \
         'number:{"deny":[3]}' \
         'wholehome:{"deny":["Read(~/**)"]}' \
         'everything:{"deny":["Read(**)"]}' \
         'bash:{"deny":["Bash(*)"]}' \
         'homepath:{"deny":["Read(//Users/someone/.ssh/**)"]}' \
         'edit:{"deny":["Edit(~/.ssh/**)"]}' \
         'projects:{"deny":["Read(~/.ssh/**)","Read(~/Non-icloudDocuments/**)"]}' \
         'list:[]'; do
  name="${c%%:*}"; val="${c#*:}"
  fixture "bad-$name" "{\"ultracode\": true, \"permissions\": $val}" "$OWN"
  sum="$(cksum < "$H/settings.json")"
  out="$(pull)"
  [ "$(cksum < "$H/settings.json")" = "$sum" ] && ok || bad "a shared permissions of $val ($name) was written; it must be refused whole"
  grep -q -E 'settings\.shared\.json.*permissions(\.[A-Za-z]+)? (is|holds) ' <<< "$out" && ok \
    || bad "the refusal of $val ($name) does not say what is wrong with permissions"
done

# A send keeps them: the shared file is edited in the repository only, so a send that really
# publishes leaves the rules in the shared repository exactly as they were, and publishes none of
# the Mac's own permissions.
B="$WORK/send-bare.git"; D="$WORK/send-dev"; C="$WORK/send-clone"; SH="$WORK/send-home"
git init -q --bare -b main "$B"; git clone -q "$B" "$D" 2>/dev/null; mkdir -p "$D/payload" "$SH"
printf '# rules\n' > "$D/payload/CLAUDE.md"; cp "$WORK/shared.json" "$D/payload/settings.shared.json"
git -C "$D" add payload && git -C "$D" -c user.name=t -c user.email=t@e commit -q -m base 2>/dev/null && git -C "$D" push -q origin main 2>/dev/null
git clone -q "$B" "$C" 2>/dev/null; printf '%s\n' "$OWN" > "$SH/settings.json"
CLAUDE_HOME="$SH" SYNC_REPO="$C" bash "$SCRIPT" pull >/dev/null 2>&1
printf '# rules, edited on this Mac\n' > "$SH/CLAUDE.md"
CLAUDE_HOME="$SH" SYNC_REPO="$C" bash "$SCRIPT" send >/dev/null 2>&1
case "$(git -C "$B" show main:payload/CLAUDE.md 2>/dev/null)" in
  *'edited on this Mac'*) ok ;; *) bad "send fixture: the send did not publish, so it proves nothing about the shared file" ;;
esac
if [ "$(git -C "$B" show main:payload/settings.shared.json 2>/dev/null | jq -c '.permissions')" = "{\"deny\":$THREE}" ]; then ok
else bad "after a send the shared repository's settings.shared.json no longer carries permissions.deny as exactly the three rules (it must not gain the Mac's own Read(./secrets/**), nor lose a rule)"; fi

echo "test-shared-deny-rules: $pass passed, $fail failed"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
