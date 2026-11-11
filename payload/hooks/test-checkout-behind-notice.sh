#!/usr/bin/env bash
# A whole tree scan: a send touching these paths runs this suite (claude-config#809).
# send-gate: scans settings.hooks.json
# Tests for checkout-behind-notice.sh, which tells a session (and each subagent it starts) when the
# checkout it is reading is behind the remote's default branch, once per answer, and never touches
# the checkout (claude-config#2712).
#
# On 2026-11-10, on the work MacBook, a project's primary checkout sat on a detached HEAD 279 commits
# behind its main branch. The session read it as current, told Dan twice that a shipped feature did
# not exist, and filed an issue for work that had gone live nine days earlier. A written rule to read
# the live repository already existed in that project's memory (L27).
#
# Every origin here is a local bare repository, so the real fetch runs and no case reaches the
# network. The clock is set (CHECKOUT_BEHIND_NOW) and every commit is dated against it, so no case
# waits; a fetch that fails or runs out of time is a stand in command, so no case waits for a bound.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/checkout-behind-notice.sh"
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
has() { case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "expected '$3' in: ${2:0:600}" ;; esac; }
hasnt() { case "$2" in *"$3"*) check "$1" "did not expect '$3' in: ${2:0:600}" ;; *) check "$1" ok ;; esac; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: test-checkout-behind-notice: checkout-behind-notice.sh is missing beside this suite"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" 1
  exit 1
fi

WORK="$(mktemp -d "${TMPDIR:-/tmp}/cb-notice.XXXXXXXX")" || exit 1
WORK="$(cd "$WORK" && pwd -P)"
case "$WORK" in ''|/) echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;; esac
trap 'rm -rf "$WORK"' EXIT

# The fixture's git sees none of the Mac's own configuration, hooks or signing.
export HOME="$WORK/home" GIT_CONFIG_GLOBAL="$WORK/gitconfig" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME"
printf '[user]\n\tname = Fixture\n\temail = fixture@example.invalid\n[init]\n\tdefaultBranch = main\n[commit]\n\tgpgsign = false\n' > "$GIT_CONFIG_GLOBAL"

NOW=1800000000
export CHECKOUT_BEHIND_NOW="$NOW"
HOUR=3600

g() { git "$@" >/dev/null 2>&1; }
# commit_at <checkout> <name> <seconds before NOW>
commit_at() {
  printf '%s\n' "$2" > "$1/$2.txt"
  g -C "$1" add "$2.txt"
  GIT_AUTHOR_DATE="@$((NOW - $3)) +0000" GIT_COMMITTER_DATE="@$((NOW - $3)) +0000" g -C "$1" commit -q -m "$2"
}

# fixture <name> [branch]: a bare origin, a seed clone that pushes to it, and the checkout under test
# cloned at the first commit. Sets O (origin), S (seed), R (the checkout), and its own state folder.
n_fix=0
fixture() {
  local name="$1" branch="${2:-main}"
  n_fix=$((n_fix + 1))
  O="$WORK/$name.git"; S="$WORK/$name-seed"; R="$WORK/$name"
  git init -q --bare --initial-branch="$branch" "$O"
  git clone -q "$O" "$S" 2>/dev/null
  g -C "$S" checkout -q -b "$branch"
  commit_at "$S" base $((40 * 24 * HOUR))
  g -C "$S" push -q origin "$branch"
  git clone -q "$O" "$R" 2>/dev/null
  export CHECKOUT_BEHIND_STATE_DIR="$WORK/state-$n_fix"
  mkdir -p "$CHECKOUT_BEHIND_STATE_DIR"
}
# advance <count> <seconds before NOW> [branch]: origin moves on, behind the checkout's back.
n_commit=0
advance() {
  local i
  for ((i = 1; i <= $1; i++)); do n_commit=$((n_commit + 1)); commit_at "$S" "c$n_commit" "$2"; done
  g -C "$S" push -q origin "${3:-main}"
}

# run_hook <event> <cwd> [session] [source] -> RC, OUT (stdout), MSG (systemMessage), CTX
# (additionalContext), EV (its hookEventName)
run_hook() {
  local payload parts rest
  payload="$(python3 -c '
import json, sys
event, cwd, session, source = sys.argv[1:5]
d = {"hook_event_name": event, "session_id": session, "cwd": cwd}
if event == "SessionStart":
    d["source"] = source
else:
    d["agent_id"] = "a123"; d["agent_type"] = "general-purpose"
print(json.dumps(d))' "$1" "$2" "${3:-s1}" "${4:-startup}")"
  OUT="$(printf '%s' "$payload" | bash "$HOOK" 2>/dev/null)"; RC=$?
  parts="$(printf '%s' "$OUT" | python3 -c '
import json, sys
raw = sys.stdin.read()
if not raw.strip():
    print("\x1f\x1f"); sys.exit()
try:
    d = json.loads(raw)
except Exception as e:
    print("NOT JSON: %r\x1f\x1f" % raw[:300]); sys.exit()
h = d.get("hookSpecificOutput") or {}
print("%s\x1f%s\x1f%s" % (d.get("systemMessage", ""), h.get("additionalContext", ""), h.get("hookEventName", "")))')"
  MSG="${parts%%$'\x1f'*}"; rest="${parts#*$'\x1f'}"
  CTX="${rest%%$'\x1f'*}"; EV="${rest#*$'\x1f'}"; EV="${EV%$'\n'}"
}
valid_output() { # valid_output <label>: the printed object is one Claude Code accepts for its event
  local v
  v="$(printf '%s' "$OUT" | python3 "$DIR/lib/hook-output.py" --payload 2>&1)"
  if [ -z "$v" ]; then check "$1" ok; else check "$1" "hook-output.py: $v"; fi
}
fetches() { wc -l < "$WORK/fetch-calls" | tr -d ' '; }

# --- 1. a checkout level with origin says nothing -------------------------------------------------
fixture current
run_hook SessionStart "$R"
check "current: exit 0" "$([ "$RC" = 0 ] && echo ok || echo "rc $RC")"
check "current: says nothing" "$([ -z "$OUT" ] && echo ok || echo "printed: $OUT")"

# --- 2. a little behind and recent says nothing, after a real fetch -------------------------------
fixture recent
advance 3 $((1 * HOUR))
run_hook SessionStart "$R"
check "recent: says nothing under the thresholds" "$([ -z "$OUT" ] && echo ok || echo "printed: $OUT")"
check "recent: the fetch really ran (the checkout's origin/main is origin's tip)" \
  "$([ "$(git -C "$R" rev-parse origin/main)" = "$(git -C "$O" rev-parse main)" ] && echo ok || echo 'origin/main was not refreshed')"

# --- 3. behind by work older than the hours threshold: the notice ---------------------------------
fixture old
advance 3 $((10 * HOUR))
head_before="$(git -C "$R" rev-parse HEAD)"; ref_before="$(git -C "$R" symbolic-ref HEAD)"
printf 'local edit\n' >> "$R/base.txt"
status_before="$(git -C "$R" status --porcelain)"
run_hook SessionStart "$R"
has "old: names the count" "$MSG" "3 commits behind origin/main"
has "old: names the checkout" "$MSG" "$R"
has "old: says how old the missing work is" "$MSG" "10 hours"
has "old: tells the session to read files from the remote branch" "$CTX" "git -C '$R' show origin/main:"
has "old: tells the session to search the remote branch" "$CTX" "git -C '$R' grep"
has "old: says the checkout must not be switched" "$CTX" "must not be switched"
has "old: the person is told what the session was told to do" "$MSG" "not to switch this checkout"
hasnt "old: the person's line carries no commands" "$MSG" "grep -n"
check "old: the session gets it as SessionStart context" "$([ "$EV" = SessionStart ] && echo ok || echo "event '$EV'")"
hasnt "old: offers no pull" "$OUT" "pull --"
hasnt "old: offers no checkout" "$OUT" "checkout --"
valid_output "old: output is valid for SessionStart"
check "old: HEAD did not move" "$([ "$(git -C "$R" rev-parse HEAD)" = "$head_before" ] && echo ok || echo moved)"
check "old: branch did not change" "$([ "$(git -C "$R" symbolic-ref HEAD)" = "$ref_before" ] && echo ok || echo changed)"
check "old: working tree untouched" "$([ "$(git -C "$R" status --porcelain)" = "$status_before" ] && echo ok || echo changed)"

# --- 4. once per answer, again when context is rebuilt, again when the answer changes -------------
run_hook SessionStart "$R" s1 resume
check "repeat: the same answer in the same session is not said again" "$([ -z "$OUT" ] && echo ok || echo "printed: $OUT")"
run_hook SessionStart "$R" s1 compact
check "compact: the session is handed it again" "$([ -n "$CTX" ] && echo ok || echo "no context: $OUT")"
check "compact: the person is not told twice" "$([ -z "$MSG" ] && echo ok || echo "systemMessage: $MSG")"
valid_output "compact: context only output is valid"
advance 1 $((1 * HOUR))
CHECKOUT_BEHIND_NOW=$((NOW + 11 * 60)) run_hook SessionStart "$R" s1 resume
has "moved: a new answer is said" "$MSG" "4 commits behind origin/main"
run_hook SessionStart "$R" s2 startup
check "new session: told afresh" "$([ -n "$MSG" ] && echo ok || echo "nothing: $OUT")"

# --- 5. subagents get it as their own context ----------------------------------------------------
run_hook SubagentStart "$R" s2
check "subagent: gets the notice as context" "$([ -n "$CTX" ] && echo ok || echo "no context: $OUT")"
check "subagent: as SubagentStart context" "$([ "$EV" = SubagentStart ] && echo ok || echo "event '$EV'")"
check "subagent: the person already told in this session is not told again" "$([ -z "$MSG" ] && echo ok || echo "systemMessage: $MSG")"
valid_output "subagent: output is valid for SubagentStart"
run_hook SubagentStart "$R" s3
check "subagent in a session not yet told: the person is told too" "$([ -n "$MSG" ] && [ -n "$CTX" ] && echo ok || echo "$OUT")"
fixture subcurrent
run_hook SubagentStart "$R" s9
check "subagent in a current checkout: nothing" "$([ -z "$OUT" ] && echo ok || echo "printed: $OUT")"

# --- 6. many commits, however recent ----------------------------------------------------------------
fixture many
advance 55 $((1 * HOUR))
run_hook SessionStart "$R"
has "many: past the commit threshold the notice is said however recent" "$MSG" "55 commits behind origin/main"

# --- 7. a detached HEAD is reported at any distance behind ----------------------------------------
fixture detached
g -C "$R" checkout -q --detach HEAD
advance 1 $((1 * HOUR))
run_hook SessionStart "$R"
has "detached: one commit behind is reported" "$MSG" "1 commit behind origin/main"
has "detached: says it is on no branch" "$MSG" "detached HEAD"
fixture detachedtip
g -C "$R" checkout -q --detach origin/main
run_hook SessionStart "$R"
check "detached at origin's tip: nothing" "$([ -z "$OUT" ] && echo ok || echo "printed: $OUT")"

# --- 8. a fetch that fails says it could not check, never zero ----------------------------------
fixture failed
advance 3 $((10 * HOUR))
cat > "$WORK/fetch-fails" <<'EOF'
#!/usr/bin/env bash
echo "fatal: unable to access 'https://example.invalid/': Could not resolve host" >&2
exit 128
EOF
chmod +x "$WORK/fetch-fails"
CHECKOUT_BEHIND_FETCH="$WORK/fetch-fails" run_hook SessionStart "$R"
has "failed: says it could not check" "$MSG" "could not be checked"
has "failed: names git's reason" "$MSG" "Could not resolve host"
hasnt "failed: never claims zero behind" "$MSG" "0 commits"
has "failed: still points at the remote branch" "$CTX" "show origin/main:"
valid_output "failed: output is valid"
# The local copy of origin already shows it behind: said, with the caveat.
g -C "$R" fetch -q origin
advance 2 $((1 * HOUR))
CHECKOUT_BEHIND_FETCH="$WORK/fetch-fails" run_hook SessionStart "$R" s5
has "failed but already behind: says so from the last fetch" "$MSG" "already shows it 3 commits behind"
has "failed but already behind: still says it could not check" "$MSG" "could not be checked"

# --- 9. a fetch that runs out of time ----------------------------------------------------------------
fixture slow
printf '#!/usr/bin/env bash\nexit 124\n' > "$WORK/fetch-times-out"
chmod +x "$WORK/fetch-times-out"
CHECKOUT_BEHIND_FETCH="$WORK/fetch-times-out" run_hook SessionStart "$R"
has "timed out: says it could not check" "$MSG" "could not be checked"
has "timed out: names the bound" "$MSG" "longer than 5 seconds"

# --- 10. the fetch is cached per repository, and runs again once the cache is old ------------------
fixture cached
advance 3 $((10 * HOUR))
cat > "$WORK/fetch-counts" <<EOF
#!/usr/bin/env bash
echo x >> "$WORK/fetch-calls"
git -C "\$1" fetch -q origin "\$2"
EOF
chmod +x "$WORK/fetch-counts"
: > "$WORK/fetch-calls"
CHECKOUT_BEHIND_FETCH="$WORK/fetch-counts" run_hook SessionStart "$R" c1
CHECKOUT_BEHIND_FETCH="$WORK/fetch-counts" run_hook SessionStart "$R" c2
has "cached: a second session within the window still gets the notice" "$MSG" "3 commits behind"
check "cached: one fetch for two sessions within the window" "$([ "$(fetches)" = 1 ] && echo ok || echo "$(fetches) fetches")"
CHECKOUT_BEHIND_FETCH="$WORK/fetch-counts" CHECKOUT_BEHIND_NOW=$((NOW + 11 * 60)) run_hook SessionStart "$R" c3
check "cached: fetched again once the window has passed" "$([ "$(fetches)" = 2 ] && echo ok || echo "$(fetches) fetches")"
: > "$WORK/fetch-calls"
CHECKOUT_BEHIND_FETCH="$WORK/fetch-fails" CHECKOUT_BEHIND_NOW=$((NOW + 40 * 60)) run_hook SessionStart "$R" c4
CHECKOUT_BEHIND_FETCH="$WORK/fetch-counts" CHECKOUT_BEHIND_NOW=$((NOW + 41 * 60)) run_hook SessionStart "$R" c5
check "cached: a failed fetch is not cached as a success" "$([ "$(fetches)" = 1 ] && echo ok || echo "$(fetches) fetches")"

# --- 11. another default branch, read from origin/HEAD ---------------------------------------------
fixture trunky trunk
advance 2 $((20 * HOUR)) trunk
run_hook SessionStart "$R"
has "trunk: the default branch comes from origin/HEAD" "$MSG" "2 commits behind origin/trunk"

# --- 12. a worktree is judged on its own HEAD ---------------------------------------------------------
fixture wt
g -C "$R" worktree add -q -b feature "$WORK/wt-feature" HEAD
advance 3 $((30 * HOUR))
run_hook SubagentStart "$WORK/wt-feature" s7
has "worktree: the agent's worktree is what is judged" "$CTX" "$WORK/wt-feature is on feature"

# --- 13. nothing to judge -----------------------------------------------------------------------------
mkdir -p "$WORK/plain"
export CHECKOUT_BEHIND_STATE_DIR="$WORK/state-plain"
run_hook SessionStart "$WORK/plain"
check "not a repository: nothing" "$([ -z "$OUT" ] && [ "$RC" = 0 ] && echo ok || echo "rc $RC: $OUT")"
git init -q "$WORK/noorigin"
commit_at "$WORK/noorigin" one 100
run_hook SessionStart "$WORK/noorigin"
check "no origin remote: nothing" "$([ -z "$OUT" ] && [ "$RC" = 0 ] && echo ok || echo "rc $RC: $OUT")"
run_hook PreToolUse "$WORK/plain"
check "another event: nothing" "$([ -z "$OUT" ] && [ "$RC" = 0 ] && echo ok || echo "rc $RC: $OUT")"

# --- 14. the bounded runner missing: the fetch was not run, and it says so ------------------------
fixture nolib
advance 3 $((10 * HOUR))
mkdir -p "$WORK/bare-hooks/lib"
cp "$HOOK" "$WORK/bare-hooks/"
python3 "$DIR/lib/install-hook-libs.py" "$DIR/lib" "$WORK/bare-hooks/lib" hook-notice.sh >/dev/null 2>&1
check "no bounded-run.sh: the fixture really lacks it" "$([ ! -e "$WORK/bare-hooks/lib/bounded-run.sh" ] && [ -f "$WORK/bare-hooks/lib/hook-notice.sh" ] && echo ok || echo 'the scratch lib is not as intended')"
OUT="$(printf '{"hook_event_name":"SessionStart","session_id":"n1","cwd":"%s","source":"startup"}' "$R" | bash "$WORK/bare-hooks/checkout-behind-notice.sh" 2>/dev/null)"
has "no bounded-run.sh: says it could not check" "$OUT" "could not be checked"
has "no bounded-run.sh: names the missing file" "$OUT" "bounded-run.sh"

# --- 15. registered on both events ---------------------------------------------------------------
reg="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
for ev in ("SessionStart", "SubagentStart"):
    found = any("checkout-behind-notice.sh" in h.get("command", "")
                for grp in d.get("hooks", {}).get(ev, []) for h in grp.get("hooks", []))
    print("%s=%s" % (ev, found))' "$SETTINGS" 2>&1)"
has "registered on SessionStart" "$reg" "SessionStart=True"
has "registered on SubagentStart" "$reg" "SubagentStart=True"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
