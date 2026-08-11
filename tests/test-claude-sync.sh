#!/usr/bin/env bash
# Tests the core logic of claude-sync WITHOUT touching real git/GitHub or the
# real ~/.claude. Everything runs in throwaway temp dirs via env overrides:
#   CLAUDE_HOME  - stand-in for ~/.claude
#   SYNC_REPO    - stand-in for the sync repo
#   SYNC_NO_GIT  - skip all git operations
set -uo pipefail

SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/claude-sync"
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "  ok: $1"; }
bad()  { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
check(){ if eval "$2"; then ok "$1"; else bad "$1 (expr: $2)"; fi; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Redirect the shell rc for the WHOLE suite, not just the alias tests. install-autosync
# installs the claudesync alias, and the older autosync tests below call it without
# setting this, so a default of ~/.zshrc means the suite edits the real shell config of
# whoever runs it. It did exactly that, appending aliases pointing at temp dirs. A test
# must be structurally unable to touch live config, so the safe value is the default
# here and individual tests override it only to point at another throwaway file.
export SYNC_ZSHRC="$WORK/zshrc-guard"
CH="$WORK/dot-claude"          # fake ~/.claude
REPO="$WORK/repo"              # fake sync repo
mkdir -p "$CH/hooks" "$CH/skills/plan-council" "$CH/skills/wrangler" \
         "$CH/agents" "$CH/commands" "$REPO/payload"

# ---- seed a fake ~/.claude ----
echo 'echo hi' > "$CH/hooks/tdd-nudge.sh"
# Python bytecode cache next to a hook: local build cruft, tied to one Python
# version, invalidated by a timestamp that syncing scrambles. Must never travel.
mkdir -p "$CH/hooks/__pycache__"
echo 'BYTECODE' > "$CH/hooks/__pycache__/gh_issue_scan.cpython-314.pyc"
echo 'BYTECODE' > "$CH/hooks/stray.pyc"
echo 'SKILL custom' > "$CH/skills/plan-council/SKILL.md"
echo 'SKILL plugin-owned' > "$CH/skills/wrangler/SKILL.md"   # should be EXCLUDED from sync
echo 'AGENT' > "$CH/agents/plan-redteam.md"
echo 'CMD' > "$CH/commands/plannotator-last.md"
echo '# global rules v1' > "$CH/CLAUDE.md"
echo '# rtk notes' > "$CH/RTK.md"
echo '# lessons L1' > "$CH/LESSONS.md"
cat > "$CH/settings.json" <<JSON
{
  "model": "opus",
  "effortLevel": "high",
  "permissions": { "allow": ["LOCAL-ONLY"] },
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "command": "$CH/hooks/tdd-nudge.sh" } ] }
    ]
  }
}
JSON

export CLAUDE_HOME="$CH" SYNC_REPO="$REPO" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1

echo "== push =="
bash "$SCRIPT" push >/dev/null 2>&1
check "payload has the custom skill"        "[ -f '$REPO/payload/skills/plan-council/SKILL.md' ]"
check "payload EXCLUDES plugin skill"       "[ ! -e '$REPO/payload/skills/wrangler' ]"
check "payload has the hook script"         "[ -f '$REPO/payload/hooks/tdd-nudge.sh' ]"
check "payload EXCLUDES __pycache__ dir"    "[ ! -e '$REPO/payload/hooks/__pycache__' ]"
check "payload EXCLUDES a stray .pyc"       "[ ! -e '$REPO/payload/hooks/stray.pyc' ]"
check "payload has the agent"               "[ -f '$REPO/payload/agents/plan-redteam.md' ]"
check "payload has the command"             "[ -f '$REPO/payload/commands/plannotator-last.md' ]"
check "hooks fragment written"              "[ -f '$REPO/payload/settings.hooks.json' ]"
check "fragment path is tokenized"          "grep -q '__CLAUDE_HOME__/hooks/tdd-nudge.sh' '$REPO/payload/settings.hooks.json'"
check "fragment does NOT leak real home"    "! grep -q '$CH' '$REPO/payload/settings.hooks.json'"
check "payload has CLAUDE.md"               "[ -f '$REPO/payload/CLAUDE.md' ]"
check "payload has RTK.md"                  "[ -f '$REPO/payload/RTK.md' ]"
check "payload has LESSONS.md"              "[ -f '$REPO/payload/LESSONS.md' ]"

echo "== pull into a DIFFERENT home (simulates other Mac) =="
CH2="$WORK/dot-claude-2"
mkdir -p "$CH2/skills/wrangler"
echo 'PLUGIN-LOCAL' > "$CH2/skills/wrangler/SKILL.md"   # plugin skill present on Mac 2
cat > "$CH2/settings.json" <<JSON
{ "model": "opus", "effortLevel": "high",
  "permissions": { "allow": ["MAC2-ONLY-KEEP-ME"] },
  "hooks": {} }
JSON
export CLAUDE_HOME="$CH2"
bash "$SCRIPT" pull >/dev/null 2>&1
check "skill arrived on Mac 2"              "[ -f '$CH2/skills/plan-council/SKILL.md' ]"
check "hook script arrived on Mac 2"        "[ -f '$CH2/hooks/tdd-nudge.sh' ]"
check "agent arrived on Mac 2"              "[ -f '$CH2/agents/plan-redteam.md' ]"
check "Mac 2 plugin skill NOT deleted"      "[ -f '$CH2/skills/wrangler/SKILL.md' ]"
check "hooks merged into settings"          "jq -e '.hooks.UserPromptSubmit' '$CH2/settings.json' >/dev/null"
check "hook path rewritten to Mac2 home"    "jq -r '.hooks.UserPromptSubmit[0].hooks[0].command' '$CH2/settings.json' | grep -q '$CH2/hooks/tdd-nudge.sh'"
check "no token left in settings"           "! grep -q '__CLAUDE_HOME__' '$CH2/settings.json'"
check "Mac 2 model preserved"               "jq -e '.model==\"opus\"' '$CH2/settings.json' >/dev/null"
check "Mac 2 LOCAL permissions preserved"   "jq -e '.permissions.allow[0]==\"MAC2-ONLY-KEEP-ME\"' '$CH2/settings.json' >/dev/null"
check "CLAUDE.md arrived on Mac 2"          "[ -f '$CH2/CLAUDE.md' ]"
check "RTK.md arrived on Mac 2"             "[ -f '$CH2/RTK.md' ]"
check "CLAUDE.md content matches source"    "grep -q 'global rules v1' '$CH2/CLAUDE.md'"
check "LESSONS.md arrived on Mac 2"          "grep -q 'lessons L1' '$CH2/LESSONS.md'"

echo "== install-schedule plist content (background job must find Homebrew tools) =="
PLDIR="$WORK/launchagents"; mkdir -p "$PLDIR"
SYNC_LAUNCHAGENTS="$PLDIR" SYNC_NO_LAUNCHCTL=1 bash "$SCRIPT" install-schedule >/dev/null 2>&1
PL="$PLDIR/com.claudesync.pull.plist"
check "plist written"                 "[ -f '$PL' ]"
check "plist sets a PATH for the job" "grep -q '<key>PATH</key>' '$PL'"
check "PATH includes Homebrew bin"    "grep -q '/opt/homebrew/bin' '$PL'"
check "schedule is monthly (Day key)" "grep -q '<key>Day</key>' '$PL'"

echo "== sync (two-way) over a local fake remote =="
unset SYNC_NO_GIT   # this section exercises the real git round-trip
BARE="$WORK/bare.git"; git init -q --bare "$BARE"
# Mac A: has a custom skill, syncs it up
RA="$WORK/repoA"; git clone -q "$BARE" "$RA"
CA="$WORK/homeA"; mkdir -p "$CA/skills/alpha"
echo '{"model":"opus","hooks":{}}' > "$CA/settings.json"
echo 'ALPHA' > "$CA/skills/alpha/SKILL.md"
CLAUDE_HOME="$CA" SYNC_REPO="$RA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B: empty, syncs and should receive A's skill
RB="$WORK/repoB"; git clone -q "$BARE" "$RB"
CB="$WORK/homeB"; mkdir -p "$CB"
echo '{"model":"opus","permissions":{"allow":["B-LOCAL"]},"hooks":{}}' > "$CB/settings.json"
CLAUDE_HOME="$CB" SYNC_REPO="$RB" bash "$SCRIPT" sync >/dev/null 2>&1
check "sync pushed+committed from A"   "[ -n \"\$(git -C '$RA' log --oneline 2>/dev/null)\" ]"
check "B received A's skill via sync"  "[ -f '$CB/skills/alpha/SKILL.md' ]"
check "B kept its local permissions"   "jq -e '.permissions.allow[0]==\"B-LOCAL\"' '$CB/settings.json' >/dev/null"

echo "== install-autosync writes a receive-timer; adds an fswatch watcher when available =="
PLDIR2="$WORK/la2"; mkdir -p "$PLDIR2"
# no fswatch -> timer only, plus a hint
FAKEFS="$WORK/fake-fswatch"
outA="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
TPL="$PLDIR2/com.claudesync.timer.plist"; WPL="$PLDIR2/com.claudesync.watch.plist"
check "timer plist written"            "[ -f '$TPL' ]"
check "timer has StartInterval"        "grep -q 'StartInterval' '$TPL'"
check "timer sets Homebrew PATH"        "grep -q '/opt/homebrew/bin' '$TPL'"
check "timer runs sync"                 "grep -q '<string>sync</string>' '$TPL'"
check "no watcher without fswatch"      "[ ! -f '$WPL' ]"
check "hints to install fswatch"        "printf '%s' \"\$outA\" | grep -qi fswatch"
# with fswatch present -> also a watcher agent that runs 'watch' and stays alive
printf '#!/usr/bin/env bash\ntrue\n' > "$FAKEFS"; chmod +x "$FAKEFS"
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "watcher plist written"          "[ -f '$WPL' ]"
check "watcher runs the watch command"  "grep -q '<string>watch</string>' '$WPL'"
check "watcher stays alive"            "grep -q 'KeepAlive' '$WPL'"
check "watcher sets Homebrew PATH"      "grep -q '/opt/homebrew/bin' '$WPL'"

echo "== watch: errors without fswatch; runs a sync per event when present =="
out_nofs="$(SYNC_FSWATCH="$WORK/nope" CLAUDE_HOME="$CA" SYNC_REPO="$RA" bash "$SCRIPT" watch 2>&1)"; rcw=$?
check "watch fails without fswatch"     "[ $rcw -ne 0 ]"
check "watch error mentions fswatch"    "printf '%s' \"\$out_nofs\" | grep -qi fswatch"
# fake fswatch that emits one batch then exits; the watch loop should fire one sync
WBARE="$WORK/wbare.git"; git init -q --bare "$WBARE"
WR="$WORK/wrepo"; git clone -q "$WBARE" "$WR"
WC="$WORK/wchome"; mkdir -p "$WC/skills/zeta"; echo Z > "$WC/skills/zeta/SKILL.md"; echo '{"hooks":{}}' > "$WC/settings.json"
EMIT="$WORK/emit-fswatch"; printf '#!/usr/bin/env bash\necho 1\n' > "$EMIT"; chmod +x "$EMIT"
SYNC_FSWATCH="$EMIT" CLAUDE_HOME="$WC" SYNC_REPO="$WR" bash "$SCRIPT" watch >/dev/null 2>&1
check "watch pushed a commit on event"  "[ -n \"\$(git -C '$WR' log --oneline 2>/dev/null)\" ]"

echo "== apply is idempotent (no-op sync must not rewrite settings.json -> no watch loop) =="
CI="$WORK/idem"; mkdir -p "$CI/skills/keep"; echo K > "$CI/skills/keep/SKILL.md"
echo '# rules' > "$CI/CLAUDE.md"
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$CI/settings.json"
RI="$WORK/repoI"; mkdir -p "$RI"
# first pull-style apply establishes canonical form
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
before_mtime="$(stat -f %m "$CI/settings.json")"
before_cl="$(stat -f %m "$CI/CLAUDE.md")"
sleep 1
# second apply with identical payload must NOT touch settings.json or CLAUDE.md
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
after_mtime="$(stat -f %m "$CI/settings.json")"
after_cl="$(stat -f %m "$CI/CLAUDE.md")"
check "settings.json untouched on no-op sync" "[ '$before_mtime' = '$after_mtime' ]"
check "CLAUDE.md untouched on no-op sync"      "[ '$before_cl' = '$after_cl' ]"

echo "== a background failure fires a desktop notification (issue #1) =="
REC="$WORK/notify.rec"
NOTIFIER="$WORK/fake-notifier"
cat > "$NOTIFIER" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$REC"
EOS
chmod +x "$NOTIFIER"
# a sync that hits the merge-conflict path should notify when run non-interactively.
# Build divergent histories on a shared remote so the rebase fails.
CBARE="$WORK/cbare.git"; git init -q --bare "$CBARE"
CR1="$WORK/cr1"; git clone -q "$CBARE" "$CR1"; CC1="$WORK/cc1"; mkdir -p "$CC1"
echo '{"hooks":{}}' > "$CC1/settings.json"; mkdir -p "$CC1/hooks"; echo one > "$CC1/hooks/h.sh"
CLAUDE_HOME="$CC1" SYNC_REPO="$CR1" bash "$SCRIPT" sync >/dev/null 2>&1
CR2="$WORK/cr2"; git clone -q "$CBARE" "$CR2"; CC2="$WORK/cc2"; mkdir -p "$CC2/hooks"
echo '{"hooks":{}}' > "$CC2/settings.json"
# both sides change the same tracked file differently, without pulling
echo TWO_a > "$CC1/hooks/h.sh"; CLAUDE_HOME="$CC1" SYNC_REPO="$CR1" bash "$SCRIPT" sync >/dev/null 2>&1
echo TWO_b > "$CC2/hooks/h.sh"
SYNC_NOTIFIER="$NOTIFIER" SYNC_NO_NOTIFY=0 CLAUDE_HOME="$CC2" SYNC_REPO="$CR2" bash "$SCRIPT" sync >/dev/null 2>&1
check "conflict fired a notification"  "[ -s '$REC' ]"
check "notification mentions conflict"  "grep -qi 'merge\\|conflict\\|reconcile' '$REC'"

echo "== secret scan blocks sending a credential (issue #3) =="
SS="$WORK/sshome"; mkdir -p "$SS/hooks"
echo '{"hooks":{}}' > "$SS/settings.json"
echo 'export AWS_KEY=AKIAIOSFODNN7EXAMPLE' > "$SS/hooks/leak.sh"
SR="$WORK/ssrepo"; mkdir -p "$SR"
out="$(CLAUDE_HOME="$SS" SYNC_REPO="$SR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"; rc=$?
check "push aborts on detected secret"   "[ $rc -ne 0 ]"
check "message names offending file"     "printf '%s' \"\$out\" | grep -q 'leak.sh'"
# override lets it through if the user insists
SYNC_SKIP_SECRET_SCAN=1 CLAUDE_HOME="$SS" SYNC_REPO="$SR" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "override bypasses the scan"       "[ -f '$SR/payload/hooks/leak.sh' ]"
# clean content is unaffected
SS2="$WORK/sshome2"; mkdir -p "$SS2/hooks"; echo '{"hooks":{}}' > "$SS2/settings.json"; echo 'echo hello world' > "$SS2/hooks/ok.sh"
SR2="$WORK/ssrepo2"; mkdir -p "$SR2"
CLAUDE_HOME="$SS2" SYNC_REPO="$SR2" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "clean payload pushes fine"        "[ -f '$SR2/payload/hooks/ok.sh' ]"

echo "== allowlist accepts a known secret by fingerprint; new ones still blocked (issue #3) =="
SA="$WORK/sahome"; mkdir -p "$SA/hooks"; echo '{"hooks":{}}' > "$SA/settings.json"
echo 'KEY=AKIAIOSFODNN7EXAMPLE' > "$SA/hooks/known.sh"
SAR="$WORK/sarepo"; mkdir -p "$SAR"
fp="$(printf '%s' 'AKIAIOSFODNN7EXAMPLE' | shasum -a 256 | cut -d' ' -f1)"
printf '%s  # accepted test key\n' "$fp" > "$SAR/.secret-allowlist"
CLAUDE_HOME="$SA" SYNC_REPO="$SAR" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
check "allowlisted secret passes"        "[ -f '$SAR/payload/hooks/known.sh' ]"
echo '-----BEGIN RSA PRIVATE KEY-----' > "$SA/hooks/new.sh"
out3="$(CLAUDE_HOME="$SA" SYNC_REPO="$SAR" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"; rc3=$?
check "non-allowlisted secret blocks"     "[ $rc3 -ne 0 ]"
check "block names the new file"          "printf '%s' \"\$out3\" | grep -q 'new.sh'"

echo "== send (watcher path) propagates a delete and never re-applies to home (issue #2) =="
SDBARE="$WORK/sdbare.git"; git init -q --bare "$SDBARE"
SDR="$WORK/sdrepo"; git clone -q "$SDBARE" "$SDR"
SDC="$WORK/sdhome"; mkdir -p "$SDC/skills/plan-council"; echo '{"hooks":{}}' > "$SDC/settings.json"
echo deep > "$SDC/skills/plan-council/.nested"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SDC" SYNC_REPO="$SDR" bash "$SCRIPT" send >/dev/null 2>&1
check "send pushed the nested add"      "[ -n \"\$(git -C '$SDR' ls-files | grep nested)\" ]"
# delete it locally and send again
rm -f "$SDC/skills/plan-council/.nested"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SDC" SYNC_REPO="$SDR" bash "$SCRIPT" send >/dev/null 2>&1
check "send removed it from the repo"    "[ -z \"\$(git -C '$SDR' ls-files | grep nested)\" ]"
check "send did NOT resurrect it locally" "[ ! -e '$SDC/skills/plan-council/.nested' ]"

echo "== auto-commit is scoped to payload; uncommitted tool edits aren't swept (issue 1.1) =="
WB11="$WORK/w11bare.git"; git init -q --bare "$WB11"
WR11="$WORK/w11repo"; git clone -q "$WB11" "$WR11"
WC11="$WORK/w11home"; mkdir -p "$WC11/skills/s"; echo '{"hooks":{}}' > "$WC11/settings.json"; echo a > "$WC11/skills/s/f"
echo 'half-finished tool edit' > "$WR11/claude-sync.wip"   # simulates WIP in the repo
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$WC11" SYNC_REPO="$WR11" bash "$SCRIPT" sync >/dev/null 2>&1
check "payload change committed"        "[ -n \"\$(git -C '$WR11' ls-files | grep 'payload/skills/s/f')\" ]"
check "WIP tool file NOT committed"      "[ -z \"\$(git -C '$WR11' ls-files | grep 'claude-sync.wip')\" ]"
check "WIP still present on disk"        "[ -f '$WR11/claude-sync.wip' ]"

echo "== watch: a failed sync leaves a durable log line, not just a transient notification =="
# Regression for the 2026-07-06 incident: a secret-scan false positive blocked
# the real watcher for 4 days with nothing but an (easily-missed) notification
# -- ~/.claude-sync.log itself stayed silent the whole time.
WLBARE="$WORK/wlbare.git"; git init -q --bare "$WLBARE"
WLR="$WORK/wlrepo"; git clone -q "$WLBARE" "$WLR"
WLC="$WORK/wlhome"; mkdir -p "$WLC/hooks"
echo '-----BEGIN RSA PRIVATE KEY-----' > "$WLC/hooks/leak.sh"
echo '{"hooks":{}}' > "$WLC/settings.json"
WLEMIT="$WORK/wl-emit-fswatch"; printf '#!/usr/bin/env bash\necho 1\n' > "$WLEMIT"; chmod +x "$WLEMIT"
WLNOTIFIER="$WORK/wl-fake-notifier"; printf '#!/usr/bin/env bash\ntrue\n' > "$WLNOTIFIER"; chmod +x "$WLNOTIFIER"
wl_out="$(SYNC_FSWATCH="$WLEMIT" SYNC_NOTIFIER="$WLNOTIFIER" CLAUDE_HOME="$WLC" SYNC_REPO="$WLR" bash "$SCRIPT" watch 2>&1)"
check "watch output logs the failure"     "printf '%s' \"\$wl_out\" | grep -qi 'FAILED'"
check "logged failure names the file"     "printf '%s' \"\$wl_out\" | grep -q 'leak.sh'"

echo "== pull/sync auto-restarts the watch daemon when claude-sync itself changed =="
# The watch daemon (launchd KeepAlive) keeps the old script loaded until
# restarted -- a pulled edit to claude-sync itself must trigger a restart
# automatically, not rely on a manual launchctl step on each Mac (issue #5).
RSBARE="$WORK/rsbare.git"; git init -q --bare -b main "$RSBARE"
RSA="$WORK/rsrepoA"; git clone -q "$RSBARE" "$RSA"
cp "$SCRIPT" "$RSA/claude-sync"
mkdir -p "$RSA/payload/hooks"; echo '#!/bin/sh' > "$RSA/payload/hooks/dummy.sh"   # non-empty payload, or apply dies with "no payload in repo"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RSA" push -q -u origin main

RSB="$WORK/rsrepoB"; git clone -q "$RSBARE" "$RSB"
RSBHOME="$WORK/rsbhome"; mkdir -p "$RSBHOME"; echo '{"hooks":{}}' > "$RSBHOME/settings.json"
RSPLDIR="$WORK/rs-launchagents"; mkdir -p "$RSPLDIR"
touch "$RSPLDIR/com.claudesync.watch.plist"   # simulates the watcher being installed

# Mac A edits the script itself and pushes.
echo '# a harmless comment appended' >> "$RSA/claude-sync"
git -C "$RSA" add claude-sync && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "edit script" && git -C "$RSA" push -q

out_restart="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$RSBHOME" SYNC_REPO="$RSB" bash "$SCRIPT" pull 2>&1)"
check "pull restarts the watch daemon on a script change" "printf '%s' \"\$out_restart\" | grep -qi 'watch daemon'"

# First pull on a brand new Mac: the clone predates every commit (no local
# HEAD). repo_head used to capture the literal string "HEAD" here, which faked
# a diffable commit: the pull printed an empty "Received changes:" header and
# the script self-change detector diffed HEAD against itself and stayed quiet.
FPBARE="$WORK/fpbare.git"; git init -q --bare -b main "$FPBARE"
FPD="$WORK/fprepoD"; git clone -q "$FPBARE" "$FPD" 2>/dev/null   # clone while EMPTY
FPA="$WORK/fprepoA"; git clone -q "$FPBARE" "$FPA" 2>/dev/null
cp "$SCRIPT" "$FPA/claude-sync"
mkdir -p "$FPA/payload/hooks"; echo '#!/bin/sh' > "$FPA/payload/hooks/dummy.sh"
git -C "$FPA" checkout -q -b main 2>/dev/null || true
git -C "$FPA" add -A && git -C "$FPA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$FPA" push -q -u origin main
FPHOME="$WORK/fphome"; mkdir -p "$FPHOME"; echo '{"hooks":{}}' > "$FPHOME/settings.json"
out_first="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$FPHOME" SYNC_REPO="$FPD" bash "$SCRIPT" pull 2>&1)"
check "first pull announces itself as a first pull"      "printf '%s' \"\$out_first\" | grep -qi 'first pull'"
check "first pull does not print an empty changes header" "! printf '%s' \"\$out_first\" | grep -q 'Received changes from the shared repo'"
check "first pull restarts the watch daemon"              "printf '%s' \"\$out_first\" | grep -qi 'watch daemon'"

# Control: a payload-only change must NOT claim a restart happened.
mkdir -p "$RSA/payload/skills/ctrl"; echo x > "$RSA/payload/skills/ctrl/SKILL.md"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "payload only" && git -C "$RSA" push -q
out_nowatch="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 CLAUDE_HOME="$RSBHOME" SYNC_REPO="$RSB" bash "$SCRIPT" pull 2>&1)"
check "payload-only pull does not restart the daemon" "! printf '%s' \"\$out_nowatch\" | grep -qi 'watch daemon'"

# sync (two-way) must do the same self-change detection as pull, AND must still
# apply the payload afterwards. A self-update makes `sync` resume at an
# apply-only step; asserting only the restart notice would let a regression that
# skipped the copying entirely still pass. (#11)
RSC="$WORK/rsrepoC"; git clone -q "$RSBARE" "$RSC"
RSCHOME="$WORK/rschome"; mkdir -p "$RSCHOME"; echo '{"hooks":{}}' > "$RSCHOME/settings.json"
sed 's/^TOP_FILES_SEED=(CLAUDE.md/TOP_FILES_SEED=(RESUMED.md CLAUDE.md/' "$SCRIPT" > "$RSA/claude-sync"
echo '# only the NEW script version knows to sync this' > "$RSA/payload/RESUMED.md"
echo '#!/bin/sh ordinary' > "$RSA/payload/hooks/ordinary.sh"
git -C "$RSA" add -A && git -C "$RSA" -c user.name=t -c user.email=t@e commit -q -m "edit script again" && git -C "$RSA" push -q
out_sync_restart="$(SYNC_LAUNCHAGENTS="$RSPLDIR" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RSCHOME" SYNC_REPO="$RSC" bash "$SCRIPT" sync 2>&1)"
check "sync also restarts the watch daemon on a script change" "printf '%s' \"\$out_sync_restart\" | grep -qi 'watch daemon'"
check "the resumed sync still applies ordinary payload files" "[ -f '$RSCHOME/hooks/ordinary.sh' ]"
check "the resumed sync applies what only the NEW version syncs" "[ -f '$RSCHOME/RESUMED.md' ]"
check "the resumed sync still reports completion"             "printf '%s' \"\$out_sync_restart\" | grep -q 'Synced'"

# ---- status must actually REPORT a difference (#737) ----
# do_status ran `rsync -an`, which has no -v and no -i, so rsync printed nothing
# no matter what differed. The dry-run section could never report anything and
# status always read clean. A check that reports clean without checking is worse
# than no check, because it gets trusted.
STHOME="$WORK/st-home"; STREPO="$WORK/st-repo"
mkdir -p "$STHOME/hooks" "$STREPO/payload/hooks"
echo '{"hooks":{}}' > "$STHOME/settings.json"

# Identical on both sides -> status must stay quiet.
echo 'same' > "$STHOME/hooks/same.sh"
cp "$STHOME/hooks/same.sh" "$STREPO/payload/hooks/same.sh"
out_st_clean="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status is quiet when local matches payload" \
  "! printf '%s' \"\$out_st_clean\" | grep -q 'hooks: '"

# A hook that exists locally but NOT in the payload: status must name it.
echo 'brand new' > "$STHOME/hooks/added.sh"
out_st_add="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a hook missing from the payload" \
  "printf '%s' \"\$out_st_add\" | grep -q 'added.sh'"

# A file in the payload that is gone locally: --delete is in the command, so a
# working status must show the pending deletion. This is the exact case that
# proved the bug (rsync -an silent, rsync -ain printed '*deleting').
echo 'stale' > "$STREPO/payload/hooks/removed.sh"
out_st_del="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a payload file deleted locally" \
  "printf '%s' \"\$out_st_del\" | grep -q 'removed.sh'"

# An edit to an existing hook with the SAME byte count. -a quick-checks on size
# plus mtime, so without -c this edit is invisible even to an itemized rsync.
printf 'aaaa\n' > "$STHOME/hooks/edit.sh"
printf 'aaaa\n' > "$STREPO/payload/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh" "$STREPO/payload/hooks/edit.sh"
printf 'bbbb\n' > "$STHOME/hooks/edit.sh"
touch -t 202601010000 "$STHOME/hooks/edit.sh"
out_st_edit="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status names a same-size same-mtime edit" \
  "printf '%s' \"\$out_st_edit\" | grep -q 'edit.sh'"

# status must report what a push would ACTUALLY do, so it has to honor the same
# exclude set as stage_local_to_payload. Some skills are git clones carrying
# their own .git, and a status that reports those as pending changes is noise
# describing work that will never happen. (#737)
mkdir -p "$STHOME/skills/cloned/.git/hooks"
echo 'ref: refs/heads/main' > "$STHOME/skills/cloned/.git/HEAD"
echo 'SKILL' > "$STHOME/skills/cloned/SKILL.md"
echo 'junk' > "$STHOME/skills/cloned/.DS_Store"
out_st_ex="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status ignores nested .git the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.git/'"
check "status ignores .DS_Store the way a push does" \
  "! printf '%s' \"\$out_st_ex\" | grep -q '\.DS_Store'"
check "status still reports the real skill file next to them" \
  "printf '%s' \"\$out_st_ex\" | grep -q 'SKILL.md'"

# A plugin-managed skill is excluded from the sync, so status must not offer it.
mkdir -p "$STHOME/skills/wrangler"
echo 'PLUGIN' > "$STHOME/skills/wrangler/SKILL.md"
out_st_plugin="$(SYNC_NO_GIT=1 CLAUDE_HOME="$STHOME" SYNC_REPO="$STREPO" bash "$SCRIPT" status 2>&1)"
check "status ignores plugin-managed skills the way a push does" \
  "! printf '%s' \"\$out_st_plugin\" | grep -q 'wrangler'"

echo "== pull reports WHAT was received, so it's clear the sync worked =="
# A pull used to print only a generic success line; the /sync-config skill even
# claimed the script "prints which files were updated" when it never did. The
# summary must name each received file with what happened to it, and a pull
# that received nothing must say so instead of printing an empty summary.
SUBARE="$WORK/subare.git"; git init -q --bare "$SUBARE"
SUA="$WORK/surepoA"; git clone -q "$SUBARE" "$SUA"
SUAH="$WORK/suhomeA"; mkdir -p "$SUAH/hooks"
echo '{"hooks":{}}' > "$SUAH/settings.json"
echo one > "$SUAH/hooks/mod-me.sh"
echo bye > "$SUAH/hooks/del-me.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SUAH" SYNC_REPO="$SUA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B takes a baseline pull first
SUB="$WORK/surepoB"; git clone -q "$SUBARE" "$SUB"
SUBH="$WORK/suhomeB"; mkdir -p "$SUBH"; echo '{"hooks":{}}' > "$SUBH/settings.json"
CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull >/dev/null 2>&1
# Mac A then modifies, adds, and deletes a hook and syncs up
echo two > "$SUAH/hooks/mod-me.sh"
echo new > "$SUAH/hooks/add-me.sh"
rm -f "$SUAH/hooks/del-me.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SUAH" SYNC_REPO="$SUA" bash "$SCRIPT" sync >/dev/null 2>&1
# Mac B's next pull must say exactly what it received
out_sum="$(CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull 2>&1)"
check "pull names the modified file"      "printf '%s' \"\$out_sum\" | grep -q 'updated .*hooks/mod-me.sh'"
check "pull names the added file"         "printf '%s' \"\$out_sum\" | grep -q 'added .*hooks/add-me.sh'"
check "pull names the removed file"       "printf '%s' \"\$out_sum\" | grep -q 'removed .*hooks/del-me.sh'"
check "summary strips the payload/ prefix" "! printf '%s' \"\$out_sum\" | grep -q 'payload/hooks'"
# A pull with nothing new must say so, and must not print a change summary
out_noop="$(CLAUDE_HOME="$SUBH" SYNC_REPO="$SUB" bash "$SCRIPT" pull 2>&1)"
check "no-change pull says up to date"     "printf '%s' \"\$out_noop\" | grep -qi 'up to date'"
check "no-change pull has no change list"  "! printf '%s' \"\$out_noop\" | grep -q 'Received'"

echo "== a pull that updates claude-sync itself applies the NEW logic, same pull (#6) =="
# The running process loaded the OLD script at start, so a pull that updates
# claude-sync kept applying with the old code: anything the new version added to
# the synced set was skipped on the very pull that delivered it, and only landed
# on the NEXT pull. That is how CLAUDE.md arrived importing a LESSONS.md that was
# never copied. The pull must hand off to the freshly pulled copy before applying.
SUBARE2="$WORK/subare2.git"; git init -q --bare -b main "$SUBARE2"
# Mac A seeds the repo with the CURRENT (old) script, then upgrades it to a
# version that syncs one more top-level file, and adds that file to the payload.
UPA="$WORK/uprepoA"; git clone -q "$SUBARE2" "$UPA"
cp "$SCRIPT" "$UPA/claude-sync"
mkdir -p "$UPA/payload/hooks"; echo '#!/bin/sh' > "$UPA/payload/hooks/dummy.sh"
git -C "$UPA" checkout -q -b main 2>/dev/null || true
git -C "$UPA" add -A && git -C "$UPA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$UPA" push -q -u origin main
# Mac B clones at the OLD script and runs THAT copy, exactly as the real Mac does.
UPB="$WORK/uprepoB"; git clone -q "$SUBARE2" "$UPB"
UPBH="$WORK/uphomeB"; mkdir -p "$UPBH"; echo '{"hooks":{}}' > "$UPBH/settings.json"
CLAUDE_HOME="$UPBH" SYNC_REPO="$UPB" bash "$UPB/claude-sync" pull >/dev/null 2>&1
# Mac A: new script version teaches the sync about NOTES.md, and ships NOTES.md.
sed 's/^TOP_FILES_SEED=(CLAUDE.md/TOP_FILES_SEED=(NOTES.md CLAUDE.md/' "$SCRIPT" > "$UPA/claude-sync"
echo '# notes from the new version' > "$UPA/payload/NOTES.md"
git -C "$UPA" add -A && git -C "$UPA" -c user.name=t -c user.email=t@e commit -q -m "sync NOTES.md too" && git -C "$UPA" push -q
check "the new version really does sync NOTES.md" "grep -q 'TOP_FILES_SEED=(NOTES.md' '$UPA/claude-sync'"
out_up="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UPBH" SYNC_REPO="$UPB" bash "$UPB/claude-sync" pull 2>&1)"
check "file added by the new script version lands on the SAME pull" "[ -f '$UPBH/NOTES.md' ]"
check "that file has the right content"        "grep -q 'notes from the new version' '$UPBH/NOTES.md' 2>/dev/null"
check "the self-updating pull still reports the change" "printf '%s' \"\$out_up\" | grep -q 'NOTES.md'"
check "the self-updating pull still succeeds"  "printf '%s' \"\$out_up\" | grep -q 'Pulled shared config'"
# and it must not loop: exactly one hand-off, so one daemon-restart notice
restarts="$(printf '%s\n' "$out_up" | grep -ci 'watch daemon' || true)"
check "hand-off happens once, no re-exec loop"  "[ \"\$restarts\" -le 1 ]"

echo "== a broken pulled script must not be handed control, and must not restart the daemon (#10) =="
# A pull now hands off to the freshly pulled copy of claude-sync so the apply runs
# current logic. That makes a syntactically broken script pushed from one Mac able
# to break pulls on the other, which the old behavior would have survived. Worse,
# restarting the watch daemon into a broken script leaves it crash-looping. So:
# validate first, warn loudly, and degrade to the copy already running.
BKBARE="$WORK/bkbare.git"; git init -q --bare -b main "$BKBARE"
BKA="$WORK/bkrepoA"; git clone -q "$BKBARE" "$BKA" 2>/dev/null
cp "$SCRIPT" "$BKA/claude-sync"
mkdir -p "$BKA/payload/hooks"; echo '#!/bin/sh' > "$BKA/payload/hooks/base.sh"
git -C "$BKA" checkout -q -b main 2>/dev/null || true
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$BKA" push -q -u origin main
BKB="$WORK/bkrepoB"; git clone -q "$BKBARE" "$BKB" 2>/dev/null
BKBH="$WORK/bkhomeB"; mkdir -p "$BKBH"; echo '{"hooks":{}}' > "$BKBH/settings.json"
BKPL="$WORK/bk-launchagents"; mkdir -p "$BKPL"; touch "$BKPL/com.claudesync.watch.plist"
CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull >/dev/null 2>&1
# Mac A pushes a script with a syntax error, alongside a normal payload change.
# The error goes EARLY in the file, which is the case that actually hurts: bash
# executes a script incrementally, so a trailing error runs the whole pull first
# and only then complains, while an early one aborts before anything is applied.
awk 'NR==26{print "if [ ; then"} {print}' "$SCRIPT" > "$BKA/claude-sync"
echo '#!/bin/sh later' > "$BKA/payload/hooks/later.sh"
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m "break the script" && git -C "$BKA" push -q
check "the pushed script really is broken" "! bash -n '$BKA/claude-sync' 2>/dev/null"
if out_bk="$(SYNC_LAUNCHAGENTS="$BKPL" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull 2>&1)"; then rc_bk=0; else rc_bk=$?; fi
check "the pull still succeeds on a broken pulled script" "[ \"\$rc_bk\" -eq 0 ]"
check "it still applies the payload with the old logic"   "[ -f '$BKBH/hooks/later.sh' ]"
# grep for OUR wording, not 'syntax': bash prints its own syntax-error line, so a
# looser pattern would pass with no guard implemented at all.
check "it warns that the pulled script was rejected"      "printf '%s' \"\$out_bk\" | grep -q 'kept the copy already running'"
check "it does NOT restart the daemon into a broken script" "! printf '%s' \"\$out_bk\" | grep -qi 'restart'"
# The broken script is now the copy sitting in this clone, so the NEXT run
# executes it and cannot help itself. The guard protects the pull that delivers
# the break and keeps the daemon off it; recovering afterwards needs a plain git
# pull, which is why the warning has to name that command.
check "the warning names the plain git recovery command" "printf '%s' \"\$out_bk\" | grep -q 'git -C'"
if bash "$BKB/claude-sync" pull >/dev/null 2>&1; then rc_stuck=0; else rc_stuck=$?; fi
check "running the landed broken script fails (documented limit)" "[ \"\$rc_stuck\" -ne 0 ]"
# Control: after the other Mac fixes it, a plain git pull restores a working tool.
cp "$SCRIPT" "$BKA/claude-sync"
echo '#!/bin/sh fixed' > "$BKA/payload/hooks/fixed.sh"
git -C "$BKA" add -A && git -C "$BKA" -c user.name=t -c user.email=t@e commit -q -m "fix the script" && git -C "$BKA" push -q
git -C "$BKB" pull -q --ff-only
out_bk2="$(SYNC_LAUNCHAGENTS="$BKPL" SYNC_NO_LAUNCHCTL=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$BKBH" SYNC_REPO="$BKB" bash "$BKB/claude-sync" pull 2>&1)"
check "a recovered script runs and applies again"       "[ -f '$BKBH/hooks/fixed.sh' ]"
check "and no longer warns about the pulled copy"       "! printf '%s' \"\$out_bk2\" | grep -q 'kept the copy already running'"

echo "== pull fails loudly when CLAUDE.md references a rules file that isn't here (#7) =="
# CLAUDE.md pulls in extra rule files with an @import. When the imported file is
# missing, Claude Code loads nothing from it and says nothing, so an entire rules
# file goes silently absent. The pull must refuse to report success in that state.
IMH="$WORK/imp-home"; IMR="$WORK/imp-repo"
mkdir -p "$IMH" "$IMR/payload/hooks"
echo '{"hooks":{}}' > "$IMH/settings.json"
echo 'x' > "$IMR/payload/hooks/h.sh"
printf '@GONE.md\n\n# rules\n' > "$IMR/payload/CLAUDE.md"
if out_imp="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull 2>&1)"; then rc_imp=0; else rc_imp=$?; fi
check "pull exits nonzero on a dangling rules import" "[ \"\$rc_imp\" -ne 0 ]"
check "the error names the missing file"             "printf '%s' \"\$out_imp\" | grep -q 'GONE.md'"
check "it does not claim the pull succeeded"         "! printf '%s' \"\$out_imp\" | grep -q 'Pulled shared config'"
# Control: an import naming a file the sync actually carries must pull clean.
printf '@RTK.md\n\n# rules\n' > "$IMR/payload/CLAUDE.md"
printf '# rtk\n' > "$IMR/payload/RTK.md"
if out_imp2="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull 2>&1)"; then rc_imp2=0; else rc_imp2=$?; fi
check "pull succeeds when the import resolves"       "[ \"\$rc_imp2\" -eq 0 ]"
check "the imported file landed"                     "[ -f '$IMH/RTK.md' ]"
# An absolute or ~ path outside the synced set must not be treated as missing.
printf '@~/.some-external-thing-that-does-exist\n' > "$IMR/payload/CLAUDE.md"
touch "$HOME/.some-external-thing-that-does-exist" 2>/dev/null || true
if SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$IMH" SYNC_REPO="$IMR" bash "$SCRIPT" pull >/dev/null 2>&1; then rc_imp3=0; else rc_imp3=$?; fi
check "a resolvable ~ import does not fail the pull"  "[ \"\$rc_imp3\" -eq 0 ]"
rm -f "$HOME/.some-external-thing-that-does-exist"

echo "== the pull summary describes what was WRITTEN here, not what the repo changed (#8) =="
# The summary was built from the shared repo's commit range, so it could disagree
# with reality in both directions: it announced "added LESSONS.md" when that file
# was never written, then said "Already up to date" on the pull that finally wrote
# it. Both readings were the opposite of the truth, which is how a missing rules
# file went unnoticed. Report the actual local writes.
WRB="$WORK/wrbare.git"; git init -q --bare -b main "$WRB"
WRA="$WORK/wrrepoA"; git clone -q "$WRB" "$WRA"
WRAH="$WORK/wrhomeA"; mkdir -p "$WRAH/hooks"; echo '{"hooks":{}}' > "$WRAH/settings.json"
echo 'keep me' > "$WRAH/hooks/keep.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$WRAH" SYNC_REPO="$WRA" bash "$SCRIPT" sync >/dev/null 2>&1
WRBR="$WORK/wrrepoB"; git clone -q "$WRB" "$WRBR"
WRBH="$WORK/wrhomeB"; mkdir -p "$WRBH"; echo '{"hooks":{}}' > "$WRBH/settings.json"
CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull >/dev/null 2>&1
check "baseline pull delivered the hook"     "[ -f '$WRBH/hooks/keep.sh' ]"
# Now the exact failure mode: the repo has nothing new, but a file IS missing
# locally, so this pull really does write one. It must say so, not "up to date".
rm -f "$WRBH/hooks/keep.sh"
out_wr="$(CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull 2>&1)"
check "a pull that writes a file names it"        "printf '%s' \"\$out_wr\" | grep -q 'keep.sh'"
check "it does NOT claim to be up to date"        "! printf '%s' \"\$out_wr\" | grep -qi 'up to date'"
check "and the file is back"                      "[ -f '$WRBH/hooks/keep.sh' ]"
# A pull that genuinely writes nothing still has to say exactly that.
out_wr2="$(CLAUDE_HOME="$WRBH" SYNC_REPO="$WRBR" bash "$SCRIPT" pull 2>&1)"
check "a pull that writes nothing says up to date" "printf '%s' \"\$out_wr2\" | grep -qi 'up to date'"
check "and lists no files"                         "! printf '%s' \"\$out_wr2\" | grep -q 'keep.sh'"

echo "== a newly referenced rules file syncs with no script edit (#9) =="
# TOP_FILES was a hand-maintained list that had to mirror the @imports at the top
# of CLAUDE.md. Keeping the two in step was manual, and forgetting it is what made
# CLAUDE.md arrive referencing a LESSONS.md nobody had told the sync about. The
# list is now derived from the imports, following them through more than one hop.
DVH="$WORK/dv-home"; DVR="$WORK/dv-repo"
mkdir -p "$DVH/hooks" "$DVR/payload"
echo '{"hooks":{}}' > "$DVH/settings.json"
echo 'h' > "$DVH/hooks/h.sh"
printf '@EXTRA.md\n\n# root rules\n' > "$DVH/CLAUDE.md"
printf '@DEEP.md\n\n# extra rules\n' > "$DVH/EXTRA.md"     # a rules file that itself imports one
printf '# deep rules\n' > "$DVH/DEEP.md"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" push >/dev/null 2>&1
check "push carries a newly referenced rules file"  "[ -f '$DVR/payload/EXTRA.md' ]"
check "push follows a reference two hops deep"      "[ -f '$DVR/payload/DEEP.md' ]"
# and they must arrive on the other Mac
DVH2="$WORK/dv-home2"; mkdir -p "$DVH2"; echo '{"hooks":{}}' > "$DVH2/settings.json"
if out_dv="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH2" SYNC_REPO="$DVR" bash "$SCRIPT" pull 2>&1)"; then rc_dv=0; else rc_dv=$?; fi
check "pull delivers the referenced rules file"     "[ -f '$DVH2/EXTRA.md' ]"
check "pull delivers the two-hop rules file"        "[ -f '$DVH2/DEEP.md' ]"
check "the pull succeeds (no dangling reference)"   "[ \"\$rc_dv\" -eq 0 ]"
check "the still-listed defaults are unaffected"    "[ -f '$DVH2/CLAUDE.md' ]"
# status must describe the derived set too, not just the old hard-coded names
printf '# root rules CHANGED\n@EXTRA.md\n' > "$DVH/CLAUDE.md"
printf '# extra rules CHANGED\n' > "$DVH/EXTRA.md"
out_dvst="$(SYNC_NO_GIT=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" status 2>&1)"
check "status reports a referenced rules file differing" "printf '%s' \"\$out_dvst\" | grep -q 'EXTRA.md'"
# a nested reference that resolves nowhere must still fail loudly, not pass quietly
printf '@NOWHERE.md\n' > "$DVH/EXTRA.md"
if SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH" SYNC_REPO="$DVR" bash "$SCRIPT" push >/dev/null 2>&1; then rc_dv2=0; else rc_dv2=$?; fi
if out_dv3="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$DVH2" SYNC_REPO="$DVR" bash "$SCRIPT" pull 2>&1)"; then rc_dv3=0; else rc_dv3=$?; fi
check "a dangling NESTED reference fails the pull"  "[ \"\$rc_dv3\" -ne 0 ]"
check "and the error names the missing file"        "printf '%s' \"\$out_dv3\" | grep -q 'NOWHERE.md'"

echo "== a same-size edit still reaches the other Mac (rsync quick-check data loss) =="
# rsync's default quick check compares size plus mtime at one-second granularity.
# A same-size edit made in the same second as the last sync (a one character fix
# in a hook, a swapped word in CLAUDE.md) was therefore skipped: rsync updated the
# mode bit and left the OLD content, so the edit silently never left this Mac.
# Only -c (checksum) catches it. This is a data-loss path, not a cosmetic one.
QSRC="$WORK/qs-home"; QREPO="$WORK/qs-repo"
mkdir -p "$QSRC/hooks" "$QREPO/payload/hooks"
echo '{"hooks":{}}' > "$QSRC/settings.json"
printf 'aaaa\n' > "$QSRC/hooks/tiny.sh"
printf 'bbbb\n' > "$QREPO/payload/hooks/tiny.sh"          # same byte count, different content
chmod 755 "$QSRC/hooks/tiny.sh"; chmod 644 "$QREPO/payload/hooks/tiny.sh"
touch -t 202601010000 "$QSRC/hooks/tiny.sh" "$QREPO/payload/hooks/tiny.sh"   # identical mtime
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" push >/dev/null 2>&1
check "push propagates a same-size same-mtime edit" "grep -q 'aaaa' '$QREPO/payload/hooks/tiny.sh'"
# and the same hazard on the receiving side
printf 'cccc\n' > "$QREPO/payload/hooks/tiny.sh"
chmod 644 "$QREPO/payload/hooks/tiny.sh"
touch -t 202601010000 "$QSRC/hooks/tiny.sh" "$QREPO/payload/hooks/tiny.sh"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "pull applies a same-size same-mtime edit"     "grep -q 'cccc' '$QSRC/hooks/tiny.sh'"

echo "== the apply cleans up its own scratch file (no temp litter per run) =="
# The apply records what it wrote to a temp file so the summary can report real
# writes. That record has to be removed on the way out, including when the run
# ends early via die(), or every pull and sync leaves a file in the temp dir.
TMPD="$WORK/tmpdir"; mkdir -p "$TMPD"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "a clean pull leaves no temp file behind" "[ -z \"\$(ls -A '$TMPD' 2>/dev/null)\" ]"
# same on the failure path: a pull that dies must not litter either
printf '@NOPE.md\n' > "$QREPO/payload/CLAUDE.md"
SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 TMPDIR="$TMPD" CLAUDE_HOME="$QSRC" SYNC_REPO="$QREPO" bash "$SCRIPT" pull >/dev/null 2>&1
check "a failed pull leaves no temp file behind"  "[ -z \"\$(ls -A '$TMPD' 2>/dev/null)\" ]"
rm -f "$QREPO/payload/CLAUDE.md" "$QSRC/CLAUDE.md"

echo "== send must not publish over changes this Mac has never applied =="
# The 2026-07-27 incident, reproduced. Mirroring ~/.claude -> payload is
# unconditional and uses --delete, so whenever the repo holds content this Mac has
# not applied yet (the state right after ANY merge), a watcher firing publishes an
# older snapshot and silently reverts the other Mac's work. It cost a real lesson
# entry: the repo was 20 seconds ahead of ~/.claude and the watcher wiped it.
UABARE="$WORK/uabare.git"; git init -q --bare -b main "$UABARE"
UAA="$WORK/uarepoA"; git clone -q "$UABARE" "$UAA" 2>/dev/null
UAAH="$WORK/uahomeA"; mkdir -p "$UAAH/hooks"; echo '{"hooks":{}}' > "$UAAH/settings.json"
echo one > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
UAB="$WORK/uarepoB"; git clone -q "$UABARE" "$UAB" 2>/dev/null
UABH="$WORK/uahomeB"; mkdir -p "$UABH"; echo '{"hooks":{}}' > "$UABH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts in sync with A"            "grep -q one '$UABH/hooks/shared.sh'"
# A makes a change and sends it up.
echo two > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
# B merges it at the git level but never applies it: repo ahead of ~/.claude.
git -C "$UAB" pull -q --ff-only
check "B's repo now holds A's change"      "grep -q two '$UAB/payload/hooks/shared.sh'"
check "B's home does NOT have it yet"      "grep -q one '$UABH/hooks/shared.sh'"
commits_before="$(git -C "$UAB" rev-list --count HEAD)"
out_ua="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" send 2>&1)"
check "send does NOT revert A's change"    "grep -q two '$UAB/payload/hooks/shared.sh'"
check "send makes no commit in that state" "[ \"\$(git -C '$UAB' rev-list --count HEAD)\" = \"\$commits_before\" ]"
check "send says why it skipped"           "printf '%s' \"\$out_ua\" | grep -qi 'not applied'"
# Control: with both sides agreed, a genuine local edit still sends normally.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B received A's change on pull"      "grep -q two '$UABH/hooks/shared.sh'"
echo 'B-only' > "$UABH/hooks/b-only.sh"
out_ua2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" send 2>&1)"
check "a normal send still works"          "[ -f '$UAB/payload/hooks/b-only.sh' ]"
check "and does not warn"                  "! printf '%s' \"\$out_ua2\" | grep -qi 'not applied'"
# sync in that same state must RECEIVE first, then still send the local edit.
echo three > "$UAAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UAAH" SYNC_REPO="$UAA" bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$UAB" pull -q --ff-only
echo 'B-second' > "$UABH/hooks/b-two.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$UABH" SYNC_REPO="$UAB" bash "$SCRIPT" sync >/dev/null 2>&1
check "sync receives before sending"       "grep -q three '$UABH/hooks/shared.sh'"
check "sync keeps A's change in the repo"  "grep -q three '$UAB/payload/hooks/shared.sh'"
check "sync still sends B's own edit"      "[ -f '$UAB/payload/hooks/b-two.sh' ]"

echo "== when both Macs changed the same file, keep the local copy and say so =="
# Holding back the paths this Mac is stale on stops it reverting the other Mac,
# but on a REAL conflict (both sides edited the same file) it just moved the loss:
# the apply overwrote this Mac's edit with the other Mac's and said nothing. Trading
# one silent loss for the other is not a fix. Keep the local version beside it.
CFBARE="$WORK/cfbare.git"; git init -q --bare -b main "$CFBARE"
CFA="$WORK/cfrepoA"; git clone -q "$CFBARE" "$CFA" 2>/dev/null
CFAH="$WORK/cfhomeA"; mkdir -p "$CFAH/hooks"; echo '{"hooks":{}}' > "$CFAH/settings.json"
echo original > "$CFAH/hooks/x.sh"
echo untouched > "$CFAH/hooks/y.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFAH" SYNC_REPO="$CFA" bash "$SCRIPT" sync >/dev/null 2>&1
CFB="$WORK/cfrepoB"; git clone -q "$CFBARE" "$CFB" 2>/dev/null
CFBH="$WORK/cfhomeB"; mkdir -p "$CFBH"; echo '{"hooks":{}}' > "$CFBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" pull >/dev/null 2>&1
# A changes both files and sends them up; B merges at the git level only.
echo MAC-A-VERSION > "$CFAH/hooks/x.sh"
echo A-CHANGED-THIS-TOO > "$CFAH/hooks/y.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFAH" SYNC_REPO="$CFA" bash "$SCRIPT" sync >/dev/null 2>&1
git -C "$CFB" pull -q --ff-only
# B edits x.sh (a real conflict) but leaves y.sh alone (not a conflict).
echo MAC-B-MY-OWN-EDIT > "$CFBH/hooks/x.sh"
out_cf="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" sync 2>&1)"
check "the other Mac's version is applied"        "grep -q MAC-A-VERSION '$CFBH/hooks/x.sh'"
check "the local edit is kept beside it"          "grep -rq MAC-B-MY-OWN-EDIT '$CFBH/hooks/'"
check "the kept copy is named as a conflict"      "ls '$CFBH/hooks/' | grep -q 'x.sh.conflict'"
check "and the conflict is reported, not silent"  "printf '%s' \"\$out_cf\" | grep -qi 'both Macs changed'"
check "the report names the file"                 "printf '%s' \"\$out_cf\" | grep -q 'hooks/x.sh'"
# No conflict on a file this Mac never touched: no stray copy, no noise.
check "an untouched file gets the new version"    "grep -q A-CHANGED-THIS-TOO '$CFBH/hooks/y.sh'"
check "and leaves no conflict copy behind"        "! ls '$CFBH/hooks/' | grep -q 'y.sh.conflict'"
# Conflict copies are local evidence; they must never travel to the other Mac.
check "conflict copies are not sent up"           "! ls '$CFB/payload/hooks/' | grep -q conflict"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$CFBH" SYNC_REPO="$CFB" bash "$SCRIPT" sync >/dev/null 2>&1
check "and still are not sent on a later sync"    "! ls '$CFB/payload/hooks/' | grep -q conflict"

echo "== a send must not leave this Mac wedged against its own commit =="
# .last-applied is written only by the apply step, and send deliberately has no
# apply step. So a send moved HEAD forward and left .last-applied pointing at the
# commit before it, after which the "behind the other Mac" guard fired on this
# Mac's OWN commit and every later send was silently dropped. One Mac here, no
# other Mac involved: the second edit must still reach the repo.
SWBARE="$WORK/swbare.git"; git init -q --bare -b main "$SWBARE"
SWA="$WORK/swrepoA"; git clone -q "$SWBARE" "$SWA" 2>/dev/null
SWAH="$WORK/swhomeA"; mkdir -p "$SWAH/hooks"; echo '{"hooks":{}}' > "$SWAH/settings.json"
echo base > "$SWAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" sync >/dev/null 2>&1
echo 'first' > "$SWAH/hooks/sw-one.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send >/dev/null 2>&1
check "the first send lands"                   "[ -f '$SWA/payload/hooks/sw-one.sh' ]"
check "a sent commit counts as applied here"   "[ \"\$(cat '$SWA/.last-applied')\" = \"\$(git -C '$SWA' rev-parse HEAD)\" ]"
echo 'second' > "$SWAH/hooks/sw-two.sh"
out_sw="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send 2>&1)"
check "a second send still lands"              "[ -f '$SWA/payload/hooks/sw-two.sh' ]"
check "and is never called behind itself"      "! printf '%s' \"\$out_sw\" | grep -qi 'not applied'"
# The guard this replaces is load-bearing, so prove it still fires: genuinely
# behind the OTHER Mac must still skip, keep the other Mac's content, and say why.
SWB="$WORK/swrepoB"; git clone -q "$SWBARE" "$SWB" 2>/dev/null
SWBH="$WORK/swhomeB"; mkdir -p "$SWBH"; echo '{"hooks":{}}' > "$SWBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWBH" SYNC_REPO="$SWB" bash "$SCRIPT" pull >/dev/null 2>&1
echo 'A-MOVED-ON' > "$SWAH/hooks/shared.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWAH" SYNC_REPO="$SWA" bash "$SCRIPT" send >/dev/null 2>&1
git -C "$SWB" pull -q --ff-only
echo 'B-local' > "$SWBH/hooks/sw-b.sh"
out_swb="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$SWBH" SYNC_REPO="$SWB" bash "$SCRIPT" send 2>&1)"
check "still skips when truly behind"          "[ ! -f '$SWB/payload/hooks/sw-b.sh' ]"
check "still keeps the other Mac's change"     "grep -q A-MOVED-ON '$SWB/payload/hooks/shared.sh'"
check "still says why it skipped"              "printf '%s' \"\$out_swb\" | grep -qi 'not applied'"

echo "== a pull must not revert a local edit the repo never changed (2026-07-28) =="
# The incident: the watcher was down, a skill script was edited locally, and a
# pull driven by UNRELATED commits mirrored the repo's older copy straight over
# the edit. No conflict copy (preserve_local_conflicts only owns paths the repo
# changed), no warning, original mtime restored, so the loss was invisible. A
# file the repo has not touched since this Mac last applied, whose local copy
# differs, is simply AHEAD: the pull must leave it alone and say so, and the
# next send must publish it.
LEBARE="$WORK/lebare.git"; git init -q --bare -b main "$LEBARE"
LEA="$WORK/lerepoA"; git clone -q "$LEBARE" "$LEA" 2>/dev/null
LEAH="$WORK/lehomeA"; mkdir -p "$LEAH/hooks" "$LEAH/skills/reel"
echo '{"hooks":{}}' > "$LEAH/settings.json"
echo 'orig-script' > "$LEAH/skills/reel/push.py"
echo 'other-v1' > "$LEAH/hooks/other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
LEB="$WORK/lerepoB"; git clone -q "$LEBARE" "$LEB" 2>/dev/null
LEBH="$WORK/lehomeB"; mkdir -p "$LEBH"; echo '{"hooks":{}}' > "$LEBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts with the original script"   "grep -q orig-script '$LEBH/skills/reel/push.py'"
# B fixes the script locally; nothing sends it (the watcher is down).
echo 'MY-LOCAL-FIX' > "$LEBH/skills/reel/push.py"
# A changes an UNRELATED file and sends it up; B pulls.
echo 'other-v2' > "$LEAH/hooks/other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
out_le="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" pull 2>&1)"
check "the unrelated change still arrives"  "grep -q other-v2 '$LEBH/hooks/other.sh'"
check "the local edit is NOT reverted"      "grep -q MY-LOCAL-FIX '$LEBH/skills/reel/push.py'"
check "and the pull says it kept the edit"  "printf '%s' \"\$out_le\" | grep -qi 'kept'"
# The kept edit still reaches the repo on the next send, and the other Mac.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEBH" SYNC_REPO="$LEB" bash "$SCRIPT" send >/dev/null 2>&1
check "the next send publishes the edit"    "grep -q MY-LOCAL-FIX '$LEB/payload/skills/reel/push.py'"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LEAH" SYNC_REPO="$LEA" bash "$SCRIPT" sync >/dev/null 2>&1
check "the edit round-trips to the other Mac" "grep -q MY-LOCAL-FIX '$LEAH/skills/reel/push.py'"

echo "== a pull must not revert an unsent edit to a top-level rules file =="
# The keep-local-edits protection covered the mirrored subtrees only. Top-level
# rules files (CLAUDE.md, LESSONS.md, RTK.md and anything they import) take a
# separate plain-copy path that had no such guard, so a pull still mirrored the
# repo's older copy straight over an entry added here and never sent, leaving a
# .syncbak as the only evidence. Reproduced live on 2026-07-28: a pull run
# seconds after another session appended a lesson deleted it. These files carry
# the rules every session loads, which makes a silent revert here the most
# expensive one in the sync.
TFBARE="$WORK/tfbare.git"; git init -q --bare -b main "$TFBARE"
TFA="$WORK/tfrepoA"; git clone -q "$TFBARE" "$TFA" 2>/dev/null
TFAH="$WORK/tfhomeA"; mkdir -p "$TFAH/hooks"; echo '{"hooks":{}}' > "$TFAH/settings.json"
printf '# rules\n' > "$TFAH/CLAUDE.md"
printf -- '- L1. first lesson\n' > "$TFAH/LESSONS.md"
echo 'other-v1' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
TFB="$WORK/tfrepoB"; git clone -q "$TFBARE" "$TFB" 2>/dev/null
TFBH="$WORK/tfhomeB"; mkdir -p "$TFBH"; echo '{"hooks":{}}' > "$TFBH/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull >/dev/null 2>&1
check "B starts with the shared lessons file" "grep -q 'first lesson' '$TFBH/LESSONS.md'"
# B appends a lesson. Nothing sends it (the watcher is down, or it is seconds old).
printf -- '- L2. MY-NEW-LESSON\n' >> "$TFBH/LESSONS.md"
# A changes something unrelated and publishes, so B's next pull has real work.
echo 'other-v2' > "$TFAH/hooks/tf-other.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
out_tf="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "the unrelated change still arrives"      "grep -q other-v2 '$TFBH/hooks/tf-other.sh'"
check "the unsent lesson is NOT reverted"       "grep -q MY-NEW-LESSON '$TFBH/LESSONS.md'"
check "the earlier lesson is still there too"   "grep -q 'first lesson' '$TFBH/LESSONS.md'"
check "and the pull says it kept the edit"      "printf '%s' \"\$out_tf\" | grep -qi 'kept'"
check "and does not report overwriting it"      "! printf '%s' \"\$out_tf\" | grep -q 'updated .*LESSONS.md'"
# It must reach the repo on the next send, and the other Mac after that.
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" send >/dev/null 2>&1
check "the next send publishes the lesson"      "grep -q MY-NEW-LESSON '$TFB/payload/LESSONS.md'"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
check "the lesson round-trips to the other Mac" "grep -q MY-NEW-LESSON '$TFAH/LESSONS.md'"
# Control: when the repo HAS changed the file since this Mac last applied, the
# other Mac's work must still arrive. It must not be possible to ignore the other
# Mac by editing locally.
# Superseded by #14: this used to assert that the incoming copy WON and the local
# copy was set aside, which is the loss #14 exists to stop. Both Macs appending a
# different entry is a merge, not a conflict, so both entries must now end up in
# the one file that sessions actually load.
printf -- '- L3. FROM-MAC-A\n' >> "$TFAH/LESSONS.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFAH" SYNC_REPO="$TFA" bash "$SCRIPT" sync >/dev/null 2>&1
printf -- '- L4. FROM-MAC-B-SAME-TIME\n' >> "$TFBH/LESSONS.md"
out_tfc="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$TFBH" SYNC_REPO="$TFB" bash "$SCRIPT" pull 2>&1)"
check "the other Mac's entry arrives"           "grep -q FROM-MAC-A '$TFBH/LESSONS.md'"
check "this Mac's entry is still in the file"   "grep -q FROM-MAC-B-SAME-TIME '$TFBH/LESSONS.md'"
check "so no conflict copy was needed"          "! ls '$TFBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "and the merge is reported"               "printf '%s' \"\$out_tfc\" | grep -qi 'MERGED'"

echo "== a commit made outside send/sync must not wedge the watcher (#12) =="
# 2026-07-28: a session edited claude-sync itself and committed with plain git.
# .last-applied is written only by the apply step and by a clean send, so HEAD
# moved and the marker did not. The guard compared those two SHAs and read this
# Mac as behind ITS OWN commit, so every later edit was dropped with a "pull
# first, this Mac is behind" notification until a manual pull happened to reset
# the marker. A commit whose content is already here is not news arriving from
# the other Mac, whatever the SHAs say.
HCBARE="$WORK/hcbare.git"; git init -q --bare -b main "$HCBARE"
HCR="$WORK/hcrepo"; git clone -q "$HCBARE" "$HCR" 2>/dev/null
HCH="$WORK/hchome"; mkdir -p "$HCH/hooks"; echo '{"hooks":{}}' > "$HCH/settings.json"
echo base > "$HCH/hooks/hc-base.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" sync >/dev/null 2>&1
check "the hand-commit case starts in sync" \
  "[ \"\$(cat '$HCR/.last-applied')\" = \"\$(git -C '$HCR' rev-parse HEAD)\" ]"
# The tool itself is edited and committed by hand, exactly as a working session does.
echo '# an ordinary edit to the tool' >> "$HCR/README.md"
git -C "$HCR" add README.md
git -C "$HCR" -c user.name=t -c user.email=t@e commit -q -m "edit the tool by hand"
git -C "$HCR" push -q
HCREC="$WORK/hc-notify.rec"; HCN="$WORK/hc-notifier"
cat > "$HCN" <<EOS
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$HCREC"
EOS
chmod +x "$HCN"
echo 'edited after the hand commit' > "$HCH/hooks/hc-after.sh"
out_hc="$(SYNC_NOTIFIER="$HCN" SYNC_NO_NOTIFY=0 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "the edit still reaches the repo"           "[ -f '$HCR/payload/hooks/hc-after.sh' ]"
check "send is not called behind its own commit"  "! printf '%s' \"\$out_hc\" | grep -qi 'not applied'"
check "and no behind-notification is fired"       "! grep -qi 'behind' '$HCREC' 2>/dev/null"

# `claude-sync push` commits the payload straight from THIS Mac's home and pushes,
# with no apply step, so it moves HEAD with payload changes whose content is
# already here and leaves the marker behind. Same wedge, and the SHAs cannot tell
# it apart from the other Mac's work arriving. Comparing the bytes can.
echo 'pushed-from-here' > "$HCH/hooks/hc-pushed.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" push >/dev/null 2>&1
echo 'edited after the push' > "$HCH/hooks/hc-after-push.sh"
out_hcp="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "an edit after a plain push still sends"    "[ -f '$HCR/payload/hooks/hc-after-push.sh' ]"
check "and is not called behind either"           "! printf '%s' \"\$out_hcp\" | grep -qi 'not applied'"

# Deciding by content only works over paths the apply actually writes to disk.
# settings.hooks.json is merged INTO settings.json and never lands as a file of
# its own, so comparing it byte for byte finds nothing to compare against and
# reports "behind" forever. Any hooks-config change followed by a plain push put
# this Mac in exactly that state, which is the original wedge wearing a new hat.
HCJ="$WORK/hcj-home"; HCJR="$WORK/hcj-repo"
HCJBARE="$WORK/hcjbare.git"; git init -q --bare -b main "$HCJBARE"
git clone -q "$HCJBARE" "$HCJR" 2>/dev/null
mkdir -p "$HCJ/hooks"; printf '#!/bin/sh\necho a\n' > "$HCJ/hooks/hcj.sh"
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}]}}\n' "$HCJ" > "$HCJ/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" sync >/dev/null 2>&1
# change the hooks CONFIG, so the merged fragment itself changes, then plain push
printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}],"UserPromptSubmit":[{"hooks":[{"type":"command","command":"%s/hooks/hcj.sh"}]}]}}\n' "$HCJ" "$HCJ" > "$HCJ/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" push >/dev/null 2>&1
check "the hooks fragment really did change" \
  "git -C '$HCJR' diff --name-only \"\$(cat '$HCJR/.last-applied')\" HEAD -- payload | grep -q settings.hooks.json"
echo 'edit after a hooks change' > "$HCJ/hooks/hcj-after.sh"
out_hcj="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCJ" SYNC_REPO="$HCJR" bash "$SCRIPT" send 2>&1)"
check "a merged-only payload entry does not block sending" "[ -f '$HCJR/payload/hooks/hcj-after.sh' ]"
check "and it is not reported as unapplied"                "! printf '%s' \"\$out_hcj\" | grep -qi 'not applied'"

# A local commit not yet pushed leaves HEAD ahead of the server. Reading "differs
# from origin" as "behind" wedges sends in the one state where sending is exactly
# what would resolve it.
echo '# committed here, never pushed' >> "$HCR/README.md"
git -C "$HCR" add README.md
git -C "$HCR" -c user.name=t -c user.email=t@e commit -q -m "local only, unpushed"
echo 'edited while ahead' > "$HCH/hooks/hc-ahead.sh"
out_hca="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH" SYNC_REPO="$HCR" bash "$SCRIPT" send 2>&1)"
check "being ahead of the server is not being behind" "[ -f '$HCR/payload/hooks/hc-ahead.sh' ]"
check "and reports no unapplied changes"              "! printf '%s' \"\$out_hca\" | grep -qi 'not applied'"

# Control: the guard is load-bearing. The other Mac pushing something this Mac has
# not even fetched must still stop the send, or a watcher firing here mirrors an
# older snapshot over their work.
HCR2="$WORK/hcrepo2"; git clone -q "$HCBARE" "$HCR2" 2>/dev/null
HCH2="$WORK/hchome2"; mkdir -p "$HCH2"; echo '{"hooks":{}}' > "$HCH2/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH2" SYNC_REPO="$HCR2" bash "$SCRIPT" pull >/dev/null 2>&1
# Their work is published from its own healthy clone via sync, which carries no
# send guard. Publishing it from a Mac this test has deliberately wedged would
# make the control depend on the very bug it is the control for.
HCR3="$WORK/hcrepo3"; git clone -q "$HCBARE" "$HCR3" 2>/dev/null
HCH3="$WORK/hchome3"; mkdir -p "$HCH3"; echo '{"hooks":{}}' > "$HCH3/settings.json"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH3" SYNC_REPO="$HCR3" bash "$SCRIPT" pull >/dev/null 2>&1
echo 'THEIR-WORK' > "$HCH3/hooks/hc-theirs.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH3" SYNC_REPO="$HCR3" bash "$SCRIPT" sync >/dev/null 2>&1
check "their work really was published"            "[ -f '$HCR3/payload/hooks/hc-theirs.sh' ]"
hc2_commits="$(git -C "$HCR2" rev-list --count HEAD)"
echo 'mine while truly behind' > "$HCH2/hooks/hc-mine.sh"
out_hcb="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HCH2" SYNC_REPO="$HCR2" bash "$SCRIPT" send 2>&1)"
check "a real remote change still blocks the send" "[ ! -f '$HCR2/payload/hooks/hc-mine.sh' ]"
check "it makes no commit in that state"           "[ \"\$(git -C '$HCR2' rev-list --count HEAD)\" = \"\$hc2_commits\" ]"
check "and still says why it skipped"              "printf '%s' \"\$out_hcb\" | grep -qi 'not applied'"

echo "== a pull says which received files only take effect in a NEW session =="
# Claude Code reads the rule files (CLAUDE.md and its @imports) once, at session
# start, and builds its list of available skills/agents/commands then too. So a
# pull can land a rule change or a brand-new skill that every already-running
# session keeps ignoring, with nothing on screen saying so. Hook scripts are the
# opposite: they are re-read from disk every time they fire, so naming them here
# would train the eye to ignore the notice.
NSBARE="$WORK/nsbare.git"; git init -q --bare "$NSBARE"
NSA="$WORK/nsrepoA"; git clone -q "$NSBARE" "$NSA"
NSAH="$WORK/nshomeA"; mkdir -p "$NSAH/hooks" "$NSAH/skills/rs-existing"
echo '{"hooks":{}}' > "$NSAH/settings.json"
echo '# rules v1' > "$NSAH/CLAUDE.md"
echo 'one' > "$NSAH/hooks/rs-hook.sh"
echo 'SKILL v1' > "$NSAH/skills/rs-existing/SKILL.md"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
NSB="$WORK/nsrepoB"; git clone -q "$NSBARE" "$NSB"
NSBH="$WORK/nshomeB"; mkdir -p "$NSBH"; echo '{"hooks":{}}' > "$NSBH/settings.json"
CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull >/dev/null 2>&1
# Mac A now changes a rule file, adds a whole new skill, edits an existing
# skill, and edits a hook, all in one push.
echo '# rules v2' > "$NSAH/CLAUDE.md"
mkdir -p "$NSAH/skills/rs-added"; echo 'SKILL new' > "$NSAH/skills/rs-added/SKILL.md"
echo 'SKILL v2' > "$NSAH/skills/rs-existing/SKILL.md"
echo 'two' > "$NSAH/hooks/rs-hook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
notice_ns="$(printf '%s\n' "$out_ns" | grep -i 'new Claude Code session' || true)"
check "pull tells you a new session is needed"   "[ -n \"\$notice_ns\" ]"
check "the notice names the changed rule file"   "printf '%s' \"\$notice_ns\" | grep -q 'CLAUDE.md'"
check "the notice names the newly added skill"   "printf '%s' \"\$notice_ns\" | grep -q 'rs-added'"
check "it does NOT name the edited hook script"  "! printf '%s' \"\$notice_ns\" | grep -q 'rs-hook'"
# It is one sentence a person reads at a glance, so it has to render as one: the
# first draft joined the last filename straight onto the next word.
check "the notice reads as a sentence"           "! printf '%s' \"\$notice_ns\" | grep -q '[A-Za-z0-9]('"
check "nor an edit to an existing skill"         "! printf '%s' \"\$notice_ns\" | grep -q 'rs-existing'"
# The whole point is that it stays quiet otherwise: a pull carrying only hook
# edits must not tell you to restart, or the notice becomes noise to scroll past.
echo three > "$NSAH/hooks/rs-hook.sh"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns2="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "hook-only pull still reports the change"  "printf '%s' \"\$out_ns2\" | grep -q 'updated .*hooks/rs-hook.sh'"
check "hook-only pull says nothing about restarting" "! printf '%s' \"\$out_ns2\" | grep -qi 'new Claude Code session'"
# A removed skill is gone from the running session's list just as wrongly as an
# added one is missing from it, so it earns the notice too.
rm -rf "$NSAH/skills/rs-added"
SYNC_NO_NOTIFY=1 CLAUDE_HOME="$NSAH" SYNC_REPO="$NSA" bash "$SCRIPT" sync >/dev/null 2>&1
out_ns3="$(CLAUDE_HOME="$NSBH" SYNC_REPO="$NSB" bash "$SCRIPT" pull 2>&1)"
check "a removed skill also earns the notice"    "printf '%s' \"\$out_ns3\" | grep -i 'new Claude Code session' | grep -q 'rs-added'"

echo "== #13: an apply must not delete a hook registration this Mac has not sent yet =="
# Seen for real on 2026-07-29 (and once before, during the send-wedge): the hooks
# block was applied by REPLACING it wholesale, so a hook registered here since the
# last send vanished, silently, while its script file was correctly held back. The
# fix is a three-way merge against the fragment this Mac last applied: incoming
# wins, locally added entries survive, and a deliberate removal on the other Mac is
# still honored.
HK="$WORK/hkbare.git"; git init -q --bare -b main "$HK"
HKA="$WORK/hkrepoA"; git clone -q "$HK" "$HKA" 2>/dev/null
cp "$SCRIPT" "$HKA/claude-sync"
mkdir -p "$HKA/payload/hooks"; echo '#!/bin/sh' > "$HKA/payload/hooks/shared.sh"
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/shared.sh"}]}]}}
J
git -C "$HKA" checkout -q -b main 2>/dev/null || true
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$HKA" push -q -u origin main

HKBH="$WORK/hkhomeB"; mkdir -p "$HKBH/hooks"
echo '{"model":"opus","hooks":{}}' > "$HKBH/settings.json"
HKB="$WORK/hkrepoB"; git clone -q "$HK" "$HKB" 2>/dev/null
CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" SYNC_NO_NOTIFY=1 bash "$HKB/claude-sync" pull >/dev/null 2>&1
check "#13 baseline: the shared hook arrived on Mac B" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"

# Mac B registers a brand new hook of its own and has NOT sent it yet.
echo '#!/bin/sh' > "$HKBH/hooks/local-gate.sh"
jqtmp="$WORK/hk-tmp.json"
jq --arg c "$HKBH/hooks/local-gate.sh" \
   '.hooks.PreToolUse[0].hooks += [{"type":"command","command":$c}]' \
   "$HKBH/settings.json" > "$jqtmp" && mv "$jqtmp" "$HKBH/settings.json"
check "#13 setup: Mac B has its own hook registered locally" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"

# Mac A publishes an unrelated payload change: real news, fragment untouched.
echo '#!/bin/sh v2' > "$HKA/payload/hooks/shared.sh"
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "unrelated change" && git -C "$HKA" push -q
out_hk1="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 an unrelated pull keeps the unsent local hook" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 that pull still delivered the payload change" \
  "grep -q 'v2' '$HKBH/hooks/shared.sh'"
check "#13 the shared hook is still registered too" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"

# Now a true collision: Mac A registers a hook of its own in the fragment.
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/shared.sh"},{"type":"command","command":"__CLAUDE_HOME__/hooks/from-mac-a.sh"}]}]}}
J
echo '#!/bin/sh' > "$HKA/payload/hooks/from-mac-a.sh"
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds a hook" && git -C "$HKA" push -q
out_hk2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 both Macs' hooks coexist after the merge" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | (any(test(\"local-gate.sh\")) and any(test(\"from-mac-a.sh\")))' '$HKBH/settings.json' >/dev/null"
check "#13 the summary names the hook that arrived" \
  "printf '%s' \"\$out_hk2\" | grep -q 'from-mac-a.sh'"

# A deliberate removal on Mac A must still be honored, not resurrected from here.
cat > "$HKA/payload/settings.hooks.json" <<'J'
{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"__CLAUDE_HOME__/hooks/from-mac-a.sh"}]}]}}
J
git -C "$HKA" add -A && git -C "$HKA" -c user.name=t -c user.email=t@e commit -q -m "Mac A removes the shared hook" && git -C "$HKA" push -q
out_hk3="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKBH" SYNC_REPO="$HKB" bash "$HKB/claude-sync" pull 2>&1)"
check "#13 a removal on the other Mac is honored" \
  "! jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"shared.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 the local hook still survives that removal" \
  "jq -e '[.hooks.PreToolUse[]?.hooks[]?.command] | any(test(\"local-gate.sh\"))' '$HKBH/settings.json' >/dev/null"
check "#13 the summary names the hook that was removed" \
  "printf '%s' \"\$out_hk3\" | grep -q 'shared.sh'"
check "#13 machine-local settings are still untouched" \
  "jq -e '.model==\"opus\"' '$HKBH/settings.json' >/dev/null"
check "#13 no home-path token is left behind" \
  "! grep -q '__CLAUDE_HOME__' '$HKBH/settings.json'"

# Failure path: settings.json is not valid JSON, so the merge cannot run. It must
# say so loudly and leave the file byte for byte alone, never half write it.
HKC="$WORK/hkrepoC"; git clone -q "$HK" "$HKC" 2>/dev/null
HKCH="$WORK/hkhomeC"; mkdir -p "$HKCH/hooks"
printf '{ "hooks": { BROKEN' > "$HKCH/settings.json"
before_bad="$(shasum "$HKCH/settings.json" | awk '{print $1}')"
out_hkbad="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$HKCH" SYNC_REPO="$HKC" bash "$HKC/claude-sync" pull 2>&1)"
after_bad="$(shasum "$HKCH/settings.json" | awk '{print $1}')"
check "#13 an unmergeable settings.json is left untouched" "[ '$before_bad' = '$after_bad' ]"
check "#13 and it says so instead of failing silently" \
  "printf '%s' \"\$out_hkbad\" | grep -q 'could not merge the hooks block'"
check "#13 the rest of the pull still lands" "[ -f '$HKCH/hooks/from-mac-a.sh' ]"

echo "== #14: rule files merge entry by entry instead of one Mac's copy winning =="
# Seen for real on 2026-07-29: both Macs had appended lessons, so the conflict path
# applied the other Mac's whole LESSONS.md and set this Mac's aside with a suffix.
# Two lessons that existed nowhere else vanished from the file every session loads,
# and the warning named the file but not the lessons. These are append-only lists,
# so the two sides almost always touch different lines and a real three-way merge
# keeps both.
RM="$WORK/rmbare.git"; git init -q --bare -b main "$RM"
RMA="$WORK/rmrepoA"; git clone -q "$RM" "$RMA" 2>/dev/null
cp "$SCRIPT" "$RMA/claude-sync"
mkdir -p "$RMA/payload/hooks"; echo '#!/bin/sh' > "$RMA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$RMA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$RMA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body one\n- **L2. two.** body two\n' > "$RMA/payload/LESSONS.md"
git -C "$RMA" checkout -q -b main 2>/dev/null || true
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RMA" push -q -u origin main

RMBH="$WORK/rmhomeB"; mkdir -p "$RMBH"; echo '{"hooks":{}}' > "$RMBH/settings.json"
RMB="$WORK/rmrepoB"; git clone -q "$RM" "$RMB" 2>/dev/null
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" pull >/dev/null 2>&1
check "#14 baseline: lessons arrived on Mac B" "grep -q 'L1. one' '$RMBH/LESSONS.md'"

# Both Macs append a DIFFERENT lesson, neither knowing about the other.
printf -- '- **L3. three.** written only on Mac B\n' >> "$RMBH/LESSONS.md"
printf -- '- **L4. four.** written only on Mac A\n' >> "$RMA/payload/LESSONS.md"
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds L4" && git -C "$RMA" push -q
out_rm1="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" bash "$RMB/claude-sync" pull 2>&1)"
check "#14 the other Mac's lesson arrives"        "grep -q 'L4. four' '$RMBH/LESSONS.md'"
check "#14 this Mac's unsent lesson survives"     "grep -q 'L3. three' '$RMBH/LESSONS.md'"
check "#14 the original lessons are still there"  "grep -q 'L1. one' '$RMBH/LESSONS.md' && grep -q 'L2. two' '$RMBH/LESSONS.md'"
check "#14 no conflict copy is left behind"       "[ ! -e '$RMBH/LESSONS.md.conflict-'* ] 2>/dev/null || ! ls '$RMBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "#14 the merge is reported, not silent"     "printf '%s' \"\$out_rm1\" | grep -qi 'merged'"
check "#14 the report names the file merged"      "printf '%s' \"\$out_rm1\" | grep -q 'LESSONS.md'"
check "#14 no conflict markers reach the file"    "! grep -q '<<<<<<<' '$RMBH/LESSONS.md'"

# Seen for real on 2026-08-06: this same pull merged three lessons into LESSONS.md and
# then printed "Already up to date: nothing on this Mac needed changing", with no
# restart notice. The merge recorded its write only in MERGED_RULE_FILES, never in the
# applied list that BOTH the change summary and the restart notice read, so the one
# path that rewrites a rule file was the one path invisible to the report about it.
# Two things follow, and the second is the one that costs something: a rule file is
# loaded at session start (LESSONS.md via CLAUDE.md), so a session that stays open
# keeps the pre-merge copy while the summary says there is nothing to pick up.
check "#14 a merge is never reported as nothing-changed" \
  "! printf '%s' \"\$out_rm1\" | grep -qi 'nothing on this Mac needed changing'"
check "#14 the merged file is listed as a received change" \
  "printf '%s' \"\$out_rm1\" | grep -qE '^ +merged +LESSONS\\.md'"
check "#14 a merged rule file earns the restart notice" \
  "printf '%s' \"\$out_rm1\" | grep -i 'new Claude Code session' | grep -q 'LESSONS.md'"

# The merged file must then reach the other Mac, or the lesson is still stranded.
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" push >/dev/null 2>&1
check "#14 the merged result is published upward" "grep -q 'L3. three' '$RMB/payload/LESSONS.md'"
check "#14 and it still carries the other side"   "grep -q 'L4. four' '$RMB/payload/LESSONS.md'"

# A genuine clash is both Macs REWRITING the same existing entry, not both adding
# at the end. That cannot be settled by any rule, so the old behavior stands, but
# the entries that exist ONLY on this Mac have to be named, not just the filename.
git -C "$RMB" pull -q 2>/dev/null
CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" SYNC_NO_NOTIFY=1 bash "$RMB/claude-sync" pull >/dev/null 2>&1
git -C "$RMA" pull -q --no-rebase 2>/dev/null
# Mac A rewrites L1's wording.
sed -i '' 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac A/' "$RMA/payload/LESSONS.md"
git -C "$RMA" add -A && git -C "$RMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A rewrites L1" && git -C "$RMA" push -q
# Mac B rewrites the SAME line differently, and also adds an entry of its own.
sed -i '' 's/- \*\*L1\. one\.\*\* body one/- **L1. one.** rewritten by Mac B/' "$RMBH/LESSONS.md"
printf -- '- **L6. six.** only on Mac B\n' >> "$RMBH/LESSONS.md"
out_rm2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RMBH" SYNC_REPO="$RMB" bash "$RMB/claude-sync" pull 2>&1)"
check "#14 an unmergeable file still keeps a copy of yours" \
  "ls '$RMBH'/LESSONS.md.conflict-* >/dev/null 2>&1"
check "#14 and it names the entry only you had" \
  "printf '%s' \"\$out_rm2\" | grep -q 'L6'"
check "#14 an unmergeable file never gets conflict markers" \
  "! grep -q '<<<<<<<' '$RMBH/LESSONS.md'"

echo "== #15: duplicate lesson numbers must not be published or go unnoticed =="
# Numbers are assigned by hand, so two Macs working the same day both reach for the
# same one. On 2026-07-29 six lessons claimed three numbers, and a duplicate L43 had
# already sat in the file for a day. The file's own header promises the numbering is
# stable for reference, which a duplicate quietly breaks.
LN="$WORK/lnrepo"; mkdir -p "$LN/payload"
LNH="$WORK/lnhome"; mkdir -p "$LNH/hooks"
echo '{"hooks":{}}' > "$LNH/settings.json"
echo '#!/bin/sh' > "$LNH/hooks/keep-syncing.sh"
printf '# rules\n@LESSONS.md\n' > "$LNH/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body\n- **L2. two.** body\n' > "$LNH/LESSONS.md"
out_ln_ok="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push 2>&1)"; rc_ln_ok=$?
check "#15 a clean lessons file publishes normally" "[ \"\$rc_ln_ok\" -eq 0 ] && grep -q 'L1. one' '$LN/payload/LESSONS.md'"

# Now a duplicate number.
printf -- '- **L2. two again.** a different lesson with the same number\n' >> "$LNH/LESSONS.md"
out_ln_dup="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push 2>&1)"
check "#15 the duplicate is named, not silent"        "printf '%s' \"\$out_ln_dup\" | grep -q 'L2'"
check "#15 the file it is in is named"                "printf '%s' \"\$out_ln_dup\" | grep -q 'LESSONS.md'"
check "#15 the corrupt numbering is NOT published"    "! grep -q 'two again' '$LN/payload/LESSONS.md'"
check "#15 the previously published copy is intact"   "grep -q 'L1. one' '$LN/payload/LESSONS.md'"
# Blocking the whole sync over a numbering slip would stop hooks and skills moving
# between Macs, which is the wedge this tool has been bitten by twice. Only the
# affected file is held back.
check "#15 everything else still publishes"           "[ -f '$LN/payload/hooks/keep-syncing.sh' ]"

# The documented override still publishes it.
SYNC_SKIP_LESSON_CHECK=1 SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" push >/dev/null 2>&1
check "#15 the override publishes it anyway"          "grep -q 'two again' '$LN/payload/LESSONS.md'"

# The helper that stops a number being picked by eye. Next means one past the
# highest, never a gap: a skipped number was skipped deliberately.
printf '# Lessons\n\n- **L1. one.** body\n- **L2. two.** body\n- **L5. five.** body\n' > "$LNH/LESSONS.md"
out_next="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" next-lesson 2>&1)"
check "#15 next-lesson reports one past the highest"  "printf '%s' \"\$out_next\" | grep -q 'L6'"
check "#15 next-lesson does not offer a gap"          "! printf '%s' \"\$out_next\" | grep -q 'L3'"

# next-lesson must survive a rule file that contains no lessons at all: under
# pipefail a grep matching nothing killed the whole command and printed nothing.
printf '# just rules, no lessons here\n' > "$LNH/RTK.md"
out_next2="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" next-lesson 2>&1)"; rc_next2=$?
check "#15 next-lesson survives a file with no lessons" "[ \"\$rc_next2\" -eq 0 ] && printf '%s' \"\$out_next2\" | grep -q 'L6'"

# The standalone check, usable as a gate before writing a lesson.
out_chk_ok="$(SYNC_NO_GIT=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_ok=$?
check "#15 check-lessons passes on sound numbering" "[ \"\$rc_chk_ok\" -eq 0 ]"
check "#15 check-lessons reports the next free number" "printf '%s' \"\$out_chk_ok\" | grep -q 'L6'"
printf -- '- **L5. five again.** duplicate\n' >> "$LNH/LESSONS.md"
out_chk_bad="$(SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNH" SYNC_REPO="$LN" bash "$SCRIPT" check-lessons 2>&1)"; rc_chk_bad=$?
check "#15 check-lessons fails on a duplicate" "[ \"\$rc_chk_bad\" -ne 0 ]"
check "#15 and names the number involved"      "printf '%s' \"\$out_chk_bad\" | grep -q 'L5'"

# A duplicate created by the #14 merge (both Macs choosing the same number) has to
# surface at apply time too, since by then it is already in the file.
LNM="$WORK/lnmbare.git"; git init -q --bare -b main "$LNM"
LNMA="$WORK/lnmA"; git clone -q "$LNM" "$LNMA" 2>/dev/null
cp "$SCRIPT" "$LNMA/claude-sync"
mkdir -p "$LNMA/payload/hooks"; echo '#!/bin/sh' > "$LNMA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$LNMA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$LNMA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body\n' > "$LNMA/payload/LESSONS.md"
git -C "$LNMA" checkout -q -b main 2>/dev/null || true
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$LNMA" push -q -u origin main
LNMBH="$WORK/lnmhomeB"; mkdir -p "$LNMBH"; echo '{"hooks":{}}' > "$LNMBH/settings.json"
LNMB="$WORK/lnmB"; git clone -q "$LNM" "$LNMB" 2>/dev/null
CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" SYNC_NO_NOTIFY=1 bash "$LNMB/claude-sync" pull >/dev/null 2>&1
# Both Macs independently write an L2. Mac A also has an L4, so the next free
# number is L5: the renumber must go one past every number in use, never just
# one past the collision.
printf -- '- **L2. mine.** written on Mac B\n' >> "$LNMBH/LESSONS.md"
printf -- '- **L2. theirs.** written on Mac A\n- **L4. four.** also on Mac A\n' >> "$LNMA/payload/LESSONS.md"
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds its L2 and L4" && git -C "$LNMA" push -q
out_lnm="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" bash "$LNMB/claude-sync" pull 2>&1)"
echo "== #17: a collision the merge creates is settled by renumbering the unsent entry =="
# The settled rule (see the 2026-08-05 note above): the published copy keeps the
# number, because the other Mac may already reference it, and the entry that has
# never left this Mac takes the next free number. The script already knows both
# facts at merge time, so doing the renumber by hand (seen again 2026-08-11) was
# pure toil, and until it was done the guard held the file back from every send.
check "#17 both lessons survive the merge"               "grep -q 'mine' '$LNMBH/LESSONS.md' && grep -q 'theirs' '$LNMBH/LESSONS.md'"
check "#17 the published entry keeps its number"         "grep -q '^- \*\*L2\. theirs' '$LNMBH/LESSONS.md'"
check "#17 the unsent entry takes the next free number"  "grep -q '^- \*\*L5\. mine' '$LNMBH/LESSONS.md'"
check "#17 the old number is no longer duplicated"       "[ \"\$(grep -c '^- \*\*L2\.' '$LNMBH/LESSONS.md')\" = 1 ]"
check "#17 the numbering is sound afterwards"            "SYNC_NO_GIT=1 CLAUDE_HOME='$LNMBH' SYNC_REPO='$LNMB' bash '$LNMB/claude-sync' check-lessons >/dev/null 2>&1"
check "#17 the renumber is reported, naming old and new" "printf '%s' \"\$out_lnm\" | grep -qi 'renumber' && printf '%s' \"\$out_lnm\" | grep -q 'L2' && printf '%s' \"\$out_lnm\" | grep -q 'L5'"
check "#17 the file is not reported as held back"        "! printf '%s' \"\$out_lnm\" | grep -qi 'held back'"
# The renumbered file must publish on the very next send, which is the whole point.
CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" SYNC_NO_NOTIFY=1 bash "$LNMB/claude-sync" push >/dev/null 2>&1
check "#17 the renumbered entry publishes upward"        "grep -q '^- \*\*L5\. mine' '$LNMB/payload/LESSONS.md'"

# A collision that ARRIVES already published is NOT ours to settle: both entries
# are on the other Mac under those numbers, so renumbering either here would break
# references there. It applies as-is and the existing warning fires instead.
git -C "$LNMA" pull -q --no-rebase 2>/dev/null
printf -- '- **L6. six.** on Mac A\n- **L6. six again.** also on Mac A under the same number\n' >> "$LNMA/payload/LESSONS.md"
git -C "$LNMA" add -A && git -C "$LNMA" -c user.name=t -c user.email=t@e commit -q -m "Mac A publishes a collision" && git -C "$LNMA" push -q
out_lnm2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$LNMBH" SYNC_REPO="$LNMB" bash "$LNMB/claude-sync" pull 2>&1)"
check "#17 an arriving collision is applied untouched"   "[ \"\$(grep -c '^- \*\*L6\.' '$LNMBH/LESSONS.md')\" = 2 ]"
check "#17 and is warned about, not auto-renumbered"     "printf '%s' \"\$out_lnm2\" | grep -q 'used 2 times'"

# ---- repo hygiene: nothing already-committed slips past the rsync excludes ----
# The excludes above stop NEW bytecode being staged, but they cannot clean a file
# that was committed before they existed: three had been, and the apply-side
# exclude then hid them from every symptom. Assert the tracked set stays clean.
echo "== repo hygiene =="
if git -C "$(dirname "$SCRIPT")" rev-parse --git-dir >/dev/null 2>&1; then
  tracked_bytecode="$(git -C "$(dirname "$SCRIPT")" ls-files | grep -cE '\.pyc$|__pycache__' || true)"
  check "no bytecode tracked in the sync repo" "[ '$tracked_bytecode' = '0' ]"
else
  ok "no bytecode tracked in the sync repo (skipped: not a git checkout)"
fi

echo "== install-autosync installs the claudesync shell alias, idempotently =="
# Why: the /sync-config skill lives under skills/ so it reaches every Mac on the next
# push, but the `claudesync` terminal alias lives in ~/.zshrc which is deliberately NOT
# synced. So the alias had to be added by hand on each Mac while the skill arrived by
# itself. SYNC_ZSHRC redirects the target, so no test can reach the real ~/.zshrc.
ZDIR="$WORK/zsh"; mkdir -p "$ZDIR"
ALIAS_LINE="alias claudesync='"'"'$HOME/claude-config-sync/claude-sync pull'"'"'"

# 1. a zshrc with no alias gets one appended, and existing content is preserved
ZRC="$ZDIR/rc-plain"
printf 'export EDITOR=bbedit\n' > "$ZRC"
outZ="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "alias added when missing"        "grep -q 'alias claudesync=' '$ZRC'"
check "alias runs a pull"               "grep -q \"claude-sync' *pull\|claude-sync pull\" '$ZRC'"
check "alias line is commented"         "grep -q 'claude-config-sync: pull shared' '$ZRC'"
check "existing zshrc content kept"     "grep -q 'EDITOR=bbedit' '$ZRC'"
check "it says the alias was added"     "printf '%s' \"\$outZ\" | grep -qi 'alias'"

# 2. assume it runs twice: a second install must not append a duplicate
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "no duplicate alias on re-run"    "[ \"\$(grep -c 'alias claudesync=' '$ZRC')\" = 1 ]"
check "no duplicate comment on re-run"  "[ \"\$(grep -c 'claude-config-sync: pull shared' '$ZRC')\" = 1 ]"

# 3. an absent zshrc is created rather than skipped
ZRC2="$ZDIR/rc-absent"
SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC2" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync >/dev/null 2>&1
check "absent zshrc is created"         "[ -f '$ZRC2' ]"
check "created zshrc has the alias"     "grep -q 'alias claudesync=' '$ZRC2'"

# 4. someone else's claudesync alias is LEFT ALONE and reported, never rewritten.
# This is the user's shell config: silently repointing a command they typed themselves
# is worse than telling them it differs.
ZRC3="$ZDIR/rc-conflict"
printf "alias claudesync='echo something else'\n" > "$ZRC3"
outZ3="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC3" CLAUDE_HOME="$CA" bash "$SCRIPT" install-autosync 2>&1)"
check "a different alias is untouched"  "grep -q 'echo something else' '$ZRC3'"
check "no second alias appended"        "[ \"\$(grep -c 'alias claudesync=' '$ZRC3')\" = 1 ]"
check "the difference is reported"      "printf '%s' \"\$outZ3\" | grep -qi 'differ\|already\|points'"

# 5. `~` and the expanded home directory are the SAME path, so an alias written with a
# tilde (which is how it was added by hand on this Mac) must count as already installed
# rather than as somebody else's conflicting alias. A gate that cries wolf gets ignored.
ZRC4="$ZDIR/rc-tilde"
printf "alias claudesync='~/claude-config-sync/claude-sync pull'\n" > "$ZRC4"
outZ4="$(SYNC_LAUNCHAGENTS="$PLDIR2" SYNC_NO_LAUNCHCTL=1 SYNC_FSWATCH="$FAKEFS" \
  SYNC_ZSHRC="$ZRC4" SYNC_SELF_DIR="$HOME/claude-config-sync" CLAUDE_HOME="$CA" \
  bash "$SCRIPT" install-autosync 2>&1)"
check "a tilde alias counts as installed"  "printf '%s' \"\$outZ4\" | grep -qi 'already installed'"
check "no duplicate for the tilde form"    "[ \"\$(grep -c 'alias claudesync=' '$ZRC4')\" = 1 ]"
check "the tilde form is not called a conflict" "! printf '%s' \"\$outZ4\" | grep -qi 'points somewhere else'"

echo "== a lesson renumbered on the other Mac must not come back under its old number =="
# Seen for real on 2026-08-05, the third numbering collision. Both Macs had used L66
# and L67 for different lessons. The clash was settled in the shared repo the agreed
# way (published keeps the number, the unsent local one is renumbered), but the merge
# below is ADDITIVE: it kept this Mac's old-numbered copy alongside the arriving
# renumbered one, so the same lesson sat in the file twice, the duplicate numbers came
# straight back, and the duplicate guard then held the whole file back from every send
# with no wedge notification. The renumbering has to survive the merge that follows it.
RN="$WORK/rnbare.git"; git init -q --bare -b main "$RN"
RNA="$WORK/rnrepoA"; git clone -q "$RN" "$RNA" 2>/dev/null
cp "$SCRIPT" "$RNA/claude-sync"
mkdir -p "$RNA/payload/hooks"; echo '#!/bin/sh' > "$RNA/payload/hooks/x.sh"
echo '{"hooks":{}}' > "$RNA/payload/settings.hooks.json"
printf '# rules\n@LESSONS.md\n' > "$RNA/payload/CLAUDE.md"
printf '# Lessons\n\n- **L1. one.** body one\n' > "$RNA/payload/LESSONS.md"
git -C "$RNA" checkout -q -b main 2>/dev/null || true
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$RNA" push -q -u origin main

RNBH="$WORK/rnhomeB"; mkdir -p "$RNBH"; echo '{"hooks":{}}' > "$RNBH/settings.json"
RNB="$WORK/rnrepoB"; git clone -q "$RN" "$RNB" 2>/dev/null
CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" SYNC_NO_NOTIFY=1 bash "$RNB/claude-sync" pull >/dev/null 2>&1

# This Mac writes L2 and never gets to send it. The other Mac independently uses L2
# for something else and publishes it, then settles the clash by renumbering this
# Mac's entry to L3, exactly as the convention says.
printf -- '- **L2. mine.** written only on Mac B\n' >> "$RNBH/LESSONS.md"
printf -- '- **L2. theirs.** published first by Mac A\n- **L3. mine.** written only on Mac B\n' >> "$RNA/payload/LESSONS.md"
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m "Mac A publishes L2 and renumbers B's to L3" && git -C "$RNA" push -q
out_rn="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" bash "$RNB/claude-sync" pull 2>&1)"

check "renumber: the other Mac's L2 arrives"        "grep -q 'L2. theirs' '$RNBH/LESSONS.md'"
check "renumber: this Mac's lesson survives"        "grep -q 'mine.\\*\\* written only on Mac B' '$RNBH/LESSONS.md'"
check "renumber: it survives under its NEW number"  "grep -q 'L3. mine' '$RNBH/LESSONS.md'"
check "renumber: the old-numbered copy is gone"     "! grep -q 'L2. mine' '$RNBH/LESSONS.md'"
check "renumber: the lesson appears exactly once"   "[ \"\$(grep -c 'written only on Mac B' '$RNBH/LESSONS.md')\" = 1 ]"
check "renumber: no duplicate numbers are created"  "! printf '%s' \"\$out_rn\" | grep -qi 'used twice\\|used 2 times'"
check "renumber: numbering passes its own check" \
  "CLAUDE_HOME='$RNBH' SYNC_REPO='$RNB' bash '$RNB/claude-sync' check-lessons >/dev/null 2>&1"
# The report has to name what was dropped and both numbers involved, or a silently
# vanished entry reads as a clean merge. Asserting only the word "renumber" would
# pass on the pre-existing duplicate warning, which is a different message entirely.
check "renumber: the drop names the old and new number" \
  "printf '%s' \"\$out_rn\" | grep -qi 'renumbered' && printf '%s' \"\$out_rn\" | grep -q 'L2' && printf '%s' \"\$out_rn\" | grep -q 'L3'"
# And the file must still be sendable. A duplicate holds that ONE file back from every
# send, so prove it by sending something NEW: asserting the arriving L3 is still in the
# payload would pass either way, since the other Mac put it there.
printf -- '- **L4. later.** added on Mac B after the merge\n' >> "$RNBH/LESSONS.md"
CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" SYNC_NO_NOTIFY=1 bash "$RNB/claude-sync" push >/dev/null 2>&1
check "renumber: the file is not held back from sending" \
  "grep -q 'L4. later' '$RNB/payload/LESSONS.md'"

# The dangerous direction of the fix above is over-deleting: it removes an entry, so
# two entries that merely LOOK alike must never be collapsed. Only a pure renumber
# (identical text, different number) qualifies. Both Macs independently using one
# number for two DIFFERENT lessons is the ordinary collision, and both must survive:
# the published one under the contested number, the unsent one renumbered (#17).
printf -- '- **L9. same number.** but this text is only on Mac B\n' >> "$RNBH/LESSONS.md"
# Mac A has to take Mac B's published work first, or its own push is rejected and the
# scenario silently never happens (the assertions below would then pass vacuously).
git -C "$RNA" pull -q --no-rebase 2>/dev/null
printf -- '- **L9. same number.** and this different text is only on Mac A\n' >> "$RNA/payload/LESSONS.md"
git -C "$RNA" add -A && git -C "$RNA" -c user.name=t -c user.email=t@e commit -q -m "Mac A adds a clashing L9" && git -C "$RNA" push -q
out_rn2="$(SYNC_NO_NOTIFY=1 CLAUDE_HOME="$RNBH" SYNC_REPO="$RNB" bash "$RNB/claude-sync" pull 2>&1)"
check "renumber: a genuinely different entry is never dropped" \
  "grep -q 'only on Mac B' '$RNBH/LESSONS.md' && grep -q 'only on Mac A' '$RNBH/LESSONS.md'"
check "renumber: the published entry keeps the contested number" \
  "grep -q '^- \*\*L9\..*only on Mac A' '$RNBH/LESSONS.md'"
check "renumber: the unsent entry is renumbered, not left colliding" \
  "grep -q '^- \*\*L10\..*only on Mac B' '$RNBH/LESSONS.md'"
check "renumber: the settled collision is reported, not silent" \
  "printf '%s' \"\$out_rn2\" | grep -qi 'renumbered' && printf '%s' \"\$out_rn2\" | grep -q 'L10'"
check "renumber: no duplicate number remains afterwards" \
  "! printf '%s' \"\$out_rn2\" | grep -qi 'used twice\\|used 2 times'"

echo "== #16: a commit that does not touch payload must still be sent =="
# Found on 2026-08-06 while pushing a fix to this very script: push decided WHETHER to
# push from whether STAGING THE PAYLOAD had produced a commit. So a commit touching
# anything else in the repo (this script, this test file) was never sent, and push
# still printed "already up to date" over a branch that was ahead. Same shape as L78,
# one signal standing in for the whole state, except here what it silently withheld
# was the work itself. do_sync had it too, so the background daemon stranded them as
# well and the tool looked healthy the entire time.
UPB="$WORK/upbare.git"; git init -q --bare -b main "$UPB"
UPR="$WORK/uprepo"; git clone -q "$UPB" "$UPR" 2>/dev/null
cp "$SCRIPT" "$UPR/claude-sync"
echo '{"hooks":{}}' > "$UPR/payload/settings.hooks.json" 2>/dev/null || { mkdir -p "$UPR/payload"; echo '{"hooks":{}}' > "$UPR/payload/settings.hooks.json"; }
echo '# rules' > "$UPR/payload/CLAUDE.md"
git -C "$UPR" checkout -q -b main 2>/dev/null || true
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m seed && git -C "$UPR" push -q -u origin main
UPH="$WORK/uphome"; mkdir -p "$UPH"; echo '{"hooks":{}}' > "$UPH/settings.json"; echo '# rules' > "$UPH/CLAUDE.md"
# Settle first, so the run under test genuinely has nothing to stage. Without this the
# test could pass for the wrong reason: any incidental payload change makes push fire
# anyway, and the assertion would never exercise the bug.
CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push >/dev/null 2>&1
out_up0="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 precondition: a settled push has nothing to stage" \
  "printf '%s' \"\$out_up0\" | grep -qi 'already up to date'"

echo '# notes' > "$UPR/NOTES.md"
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m "edit outside payload"
out_up="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 push does not claim nothing changed while ahead" \
  "! printf '%s' \"\$out_up\" | grep -qi 'already up to date'"
# Captured, not piped straight into grep: under `set -o pipefail` grep -q exits on the
# first matching line, git takes SIGPIPE, and the pipeline reports failure over a log
# that DOES contain the commit. That false negative cost a debugging detour here.
bare_log_up="$(git -C "$UPB" log --oneline main 2>/dev/null || true)"
check "#16 the non-payload commit reaches the remote" \
  "printf '%s' \"\$bare_log_up\" | grep -q 'edit outside payload'"

# sync is what the background daemon runs, so the same hole there strands the commit
# with nobody watching at all.
echo '# more' >> "$UPR/NOTES.md"
git -C "$UPR" add -A && git -C "$UPR" -c user.name=t -c user.email=t@e commit -q -m "second edit outside payload"
CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" sync >/dev/null 2>&1
bare_log_up2="$(git -C "$UPB" log --oneline main 2>/dev/null || true)"
check "#16 sync also sends a non-payload commit" \
  "printf '%s' \"\$bare_log_up2\" | grep -q 'second edit outside payload'"

# And it must still stay quiet when there is genuinely nothing to do, or the line
# becomes noise and the real "already up to date" case stops meaning anything.
out_up2="$(CLAUDE_HOME="$UPH" SYNC_REPO="$UPR" SYNC_NO_NOTIFY=1 bash "$SCRIPT" push 2>&1)"
check "#16 a truly settled push still says so" \
  "printf '%s' \"\$out_up2\" | grep -qi 'already up to date'"

echo "== the suite never touches a real shell rc =="
check "SYNC_ZSHRC is redirected suite-wide"  "[ \"\$SYNC_ZSHRC\" = '$WORK/zshrc-guard' ]"
check "the guard file stayed inside the temp dir" "[ ! -e \"\$HOME/.zshrc.claude-sync-test\" ]"

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
