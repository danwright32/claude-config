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
echo '{"model":"opus","hooks":{"Stop":[{"hooks":[{"type":"command","command":"echo hi"}]}]}}' > "$CI/settings.json"
RI="$WORK/repoI"; mkdir -p "$RI"
# first pull-style apply establishes canonical form
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" push >/dev/null 2>&1
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
before_mtime="$(stat -f %m "$CI/settings.json")"
sleep 1
# second apply with identical payload must NOT touch settings.json
CLAUDE_HOME="$CI" SYNC_REPO="$RI" SYNC_NO_GIT=1 bash "$SCRIPT" pull >/dev/null 2>&1
after_mtime="$(stat -f %m "$CI/settings.json")"
check "settings.json untouched on no-op sync" "[ '$before_mtime' = '$after_mtime' ]"

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

echo ""
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
