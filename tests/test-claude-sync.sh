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
CH="$WORK/dot-claude"          # fake ~/.claude
REPO="$WORK/repo"              # fake sync repo
mkdir -p "$CH/hooks" "$CH/skills/plan-council" "$CH/skills/wrangler" \
         "$CH/agents" "$CH/commands" "$REPO/payload"

# ---- seed a fake ~/.claude ----
echo 'echo hi' > "$CH/hooks/tdd-nudge.sh"
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

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
