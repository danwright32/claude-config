#!/usr/bin/env bash
# Tests for sync-stuck-notice.sh, the per prompt notice that the automatic config sync has been
# stuck for a long time, and that it has cleared (claude-config#391).
#
# On 2026-09-17 one Mac skipped 57 sends in a row over 11 hours and refused 52 receives, and nothing
# said so until somebody happened to run `claude-sync status`. The detection already existed; only
# the delivery was missing.
#
# What has to be proven is as much the QUIET as the speaking: a notice on every prompt is the noise
# that teaches a person to skip it (L36), and a notice that never comes back when the stretch ends
# leaves it standing for ever (L160). So every loud case below is followed by the prompt after it,
# in the same fixture, and the silent cases run where the loud ones can fire (L159).
#
# The predicate is NOT copied here, and not stubbed. The hook runs the real `claude-sync stuck`
# against a fixture clone, which is the same function `claude-sync status` prints from, so this
# suite fails if the two ever stop agreeing about what stuck means (L41, L52).
set -uo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/sync-stuck-notice.sh"
REPO="$(cd "$DIR/../.." && pwd)"
# The installed copy of these hooks has no claude-sync beside it, and this suite drives the real
# one, so there it reports NOT RUN in the shape the runner reads rather than failing for a reason
# that has nothing to do with the hook (the same rule test-lesson-entry-check.sh follows).
if [ ! -f "$REPO/claude-sync" ] || [ ! -d "$REPO/payload" ]; then
  echo "test-sync-stuck-notice: $REPO is not a checkout of this repo (no claude-sync and payload/ in it), so the tool this suite drives is not there." >&2
  printf 'SUITE-NOT-RUN %s\n' "needs the repository above it, and $REPO is not one"
  echo "passed: 0, failed: 0"
  printf 'SUITE-RESULT passed=0 failed=0\n'
  exit 2
fi

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi
}
says() { # says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" ok ;; *) check "$1" "did not say '$3' (said: ${2:0:300})" ;; esac
}
never_says() { # never_says <description> <text> <substring>
  case "$2" in *"$3"*) check "$1" "it said '$3' (said: ${2:0:300})" ;; *) check "$1" ok ;; esac
}
silent() { # silent <description> <text>
  if [ -z "$(printf '%s' "$2" | tr -d '[:space:]')" ]; then check "$1" ok; else check "$1" "it said: ${2:0:300}"; fi
}

[ -f "$HOOK" ] || { echo "FAIL: no hook at $HOOK"; echo "passed: 0, failed: 1"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.stucknotice.XXXXXXXX")" || WORK=""
case "${WORK%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$WORK'" >&2; exit 2 ;;
esac
trap 'rm -rf "$WORK"' EXIT

# EVERYTHING the hook or the tool could read from the real machine is pointed into the fixture: the
# home directory, the config root, the launch agents naming which clone runs automatically, and the
# per session record. Without the launch agents seam the hook would ask the real scheduled clone
# (L2, L284).
FHOME="$WORK/home"; mkdir -p "$FHOME/.claude" "$WORK/agents" "$WORK/state"
# A fixture clone is a directory holding the real tool and the real payload, so the tool resolves
# its own libraries exactly as a real clone does and reads its state from this directory.
CLONE="$WORK/clone"; mkdir -p "$CLONE"
ln -s "$REPO/claude-sync" "$CLONE/claude-sync"
ln -s "$REPO/payload" "$CLONE/payload"

agent_for() { # agent_for <clone dir>  -> a launch agent plist naming that clone's tool, as the installer writes it
  printf '<?xml version="1.0" encoding="UTF-8"?>\n<plist version="1.0"><dict>\n<key>Label</key><string>com.claudesync.watch</string>\n<key>ProgramArguments</key><array>\n<string>/bin/bash</string>\n<string>%s/claude-sync</string>\n<string>watch</string>\n</array>\n</dict></plist>\n' "$1" \
    > "$WORK/agents/com.claudesync.watch.plist"
}
agent_for "$CLONE"

NOW="$(date +%s)"
prompt() { # prompt <session id> [now]  -> runs the hook as a UserPromptSubmit would
  printf '{"session_id":"%s","transcript_path":"/x/%s.jsonl","cwd":".","prompt":"carry on"}' "$1" "$1" \
    | HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" SYNC_LAUNCHAGENTS="$WORK/agents" \
      CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" CLAUDE_SYNC_STUCK_NOW="${2:-$NOW}" \
      SYNC_NO_NOTIFY=1 bash "$HOOK" 2>/dev/null
}
clear_state() { rm -f "$CLONE/.behind-skips" "$CLONE/.ci-red-since"; }

echo "sync stuck notice: a healthy sync says nothing"

clear_state
out="$(prompt healthy)"
silent "no stuck record means nothing is said" "$out"

echo "sync stuck notice: sending stuck past the threshold is said once, then clears once"

# Fields as the tool writes them: count, first skip, last skip, last reconcile attempt.
printf '57 %s %s %s\n' "$(( NOW - 39600 ))" "$(( NOW - 60 ))" "$(( NOW - 60 ))" > "$CLONE/.behind-skips"
out="$(prompt s1)"
says "a send stuck for eleven hours is reported" "$out" "sending is stuck"
says "with the words status uses, count included" "$out" "skipped 57 send(s) in a row"
says "and names the clone it is about" "$out" "$CLONE"
says "and says what it means for the person" "$out" "not reaching the other Mac"
out="$(prompt s1)"
silent "the next prompt in the same session is quiet" "$out"
out="$(prompt s1)"
silent "and so is the one after" "$out"
# Per session: a session that has never been told has not been told.
out="$(prompt s2)"
says "a different session is told once too" "$out" "sending is stuck"
# The count growing is the same stretch, not a new one, so it is not said again.
printf '60 %s %s %s\n' "$(( NOW - 39600 ))" "$(( NOW - 30 ))" "$(( NOW - 30 ))" > "$CLONE/.behind-skips"
out="$(prompt s1)"
silent "more skips in the same stretch are not a new notice" "$out"

clear_state
out="$(prompt s1)"
says "when it clears, the session that was told hears that it has" "$out" "moving again"
never_says "and the recovery does not repeat the stuck wording" "$out" "sending is stuck"
out="$(prompt s1)"
silent "and the prompt after the recovery is quiet" "$out"
out="$(prompt healthy)"
silent "a session never told it was stuck is not told it recovered" "$out"

echo "sync stuck notice: a stretch younger than the threshold stays quiet until it is not"

printf '2 %s %s %s\n' "$(( NOW - 300 ))" "$(( NOW - 30 ))" "$(( NOW - 30 ))" > "$CLONE/.behind-skips"
out="$(prompt young)"
silent "five minutes of waiting on CI says nothing" "$out"
out="$(prompt young "$(( NOW + 1800 ))")"
silent "nor at thirty five minutes" "$out"
# The clock is injected, so the boundary is exercised without waiting for it (L290).
out="$(prompt young "$(( NOW - 300 + 3600 ))")"
says "at the threshold it is said" "$out" "sending is stuck"
out="$(prompt young "$(( NOW + 7200 ))")"
silent "and not again afterwards" "$out"
# A stuck stretch that recovered while nobody prompted and started again is a NEW stretch.
printf '1 %s %s %s\n' "$(( NOW + 3600 ))" "$(( NOW + 3600 ))" "$(( NOW + 3600 ))" > "$CLONE/.behind-skips"
out="$(prompt young "$(( NOW + 3700 ))")"
says "a stretch that ended between prompts is reported as ended" "$out" "moving again"
out="$(prompt young "$(( NOW + 3600 + 3600 ))")"
says "and the new one is reported once it too is past the threshold" "$out" "sending is stuck"
clear_state

echo "sync stuck notice: receiving stuck is its own notice"

# Fields as the tool writes them: since, count, and the moment it was escalated (may be empty).
printf '%s 52 %s\n' "$(( NOW - 39600 ))" "$(( NOW - 36000 ))" > "$CLONE/.ci-red-since"
out="$(prompt r1)"
says "a shared repo red for eleven hours is reported" "$out" "receiving is stuck"
says "with the words status uses" "$out" "failed its tests 52 time(s) in a row"
says "and says what it means for the person" "$out" "not arriving here"
never_says "and it is not described as sending" "$out" "sending is stuck"
out="$(prompt r1)"
silent "the next prompt is quiet" "$out"
clear_state
out="$(prompt r1)"
says "and its end is said" "$out" "moving again"
says "naming which direction moved" "$out" "receiving"

echo "sync stuck notice: a record nobody can read is not a healthy sync"

printf 'garbage\n' > "$CLONE/.behind-skips"
out="$(prompt u1)"
says "an unreadable record of skipped sends is reported" "$out" "could not be read"
says "naming the file" "$out" "$CLONE/.behind-skips"
never_says "and it is not reported as stuck, which was never measured" "$out" "sending is stuck"
out="$(prompt u1)"
silent "and only once" "$out"
clear_state

# A count that reads but a start that does not: stuck is measured, how long is not, so it cannot be
# held back behind a threshold it cannot be compared with.
printf '9 notatime\n' > "$CLONE/.behind-skips"
out="$(prompt u2)"
says "a stuck record whose start cannot be read is reported rather than held back for ever" "$out" "sending is stuck"
says "and says the start could not be read" "$out" "could not be read"
out="$(prompt u2)"
silent "once" "$out"
clear_state

echo "sync stuck notice: a clone that cannot be asked says so, once"

OLD="$WORK/oldclone"; mkdir -p "$OLD"
cat > "$OLD/claude-sync" <<'OLDEOF'
#!/usr/bin/env bash
echo "claude-sync: unknown command '$1' (try: push, pull, sync, status, help)" >&2
exit 1
OLDEOF
chmod +x "$OLD/claude-sync"
agent_for "$OLD"
out="$(prompt old1)"
says "a clone too old to have the command says it could not check" "$out" "cannot be checked"
says "and names that clone" "$out" "$OLD"
never_says "and does not claim the sync is fine or stuck" "$out" "is stuck"
out="$(prompt old1)"
silent "once" "$out"

# A session that was told it was stuck, whose clone then cannot be asked, has learned NOTHING about
# whether it recovered, so it is not told that it did (L11).
agent_for "$CLONE"
printf '57 %s %s %s\n' "$(( NOW - 39600 ))" "$(( NOW - 60 ))" "$(( NOW - 60 ))" > "$CLONE/.behind-skips"
out="$(prompt told)"
says "set up: told it is stuck" "$out" "sending is stuck"
clear_state
# The SAME clone becomes unaskable, which is the case that matters: a different clone would simply
# be a different subject.
rm -f "$CLONE/claude-sync"; cp "$OLD/claude-sync" "$CLONE/claude-sync"
out="$(prompt told)"
never_says "a clone that cannot be asked is not read as recovered" "$out" "moving again"
says "and it says it could not check instead" "$out" "cannot be checked"
rm -f "$CLONE/claude-sync"; ln -s "$REPO/claude-sync" "$CLONE/claude-sync"
out="$(prompt told)"
says "and once it can be asked again, the recovery is said" "$out" "moving again"

echo "sync stuck notice: what it needs to run"

# No automatic sync installed on this Mac: nothing runs unattended, so nothing can be stuck without
# somebody watching the run that got stuck.
rm -f "$WORK/agents/"*.plist
printf '57 %s %s %s\n' "$(( NOW - 39600 ))" "$(( NOW - 60 ))" "$(( NOW - 60 ))" > "$CLONE/.behind-skips"
out="$(prompt noagents)"
silent "with no automatic sync installed there is nothing to report" "$out"
agent_for "$CLONE"

# No session to key on means a first prompt cannot be told from a later one, so it says on stderr
# that it did not run rather than repeating itself on every prompt.
out="$(printf '{"cwd":"."}' | HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" SYNC_LAUNCHAGENTS="$WORK/agents" \
       CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" SYNC_NO_NOTIFY=1 bash "$HOOK" 2>"$WORK/err")"
silent "a payload with no session says nothing to the session" "$out"
says "and says on stderr why it did not run" "$(cat "$WORK/err")" "session"

# A threshold nobody can read falls back to the default and says so, rather than being silently
# ignored or read as zero, which would speak on every young stretch.
printf '2 %s %s %s\n' "$(( NOW - 300 ))" "$(( NOW - 30 ))" "$(( NOW - 30 ))" > "$CLONE/.behind-skips"
out="$(printf '{"session_id":"badthreshold"}' | HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" SYNC_LAUNCHAGENTS="$WORK/agents" \
       CLAUDE_SYNC_STUCK_STATE_DIR="$WORK/state" CLAUDE_SYNC_STUCK_NOW="$NOW" SYNC_STUCK_NOTICE_AFTER=soon SYNC_NO_NOTIFY=1 bash "$HOOK" 2>"$WORK/err")"
silent "an unreadable threshold is not read as zero" "$out"
says "and says it used the default" "$(cat "$WORK/err")" "SYNC_STUCK_NOTICE_AFTER"
clear_state

echo "sync stuck notice: status and the notice share one predicate"

# The tool's own stuck command, run directly: the same sentence the notice carried, which is the one
# status prints. A regression that gave status its own copy again would show here as a mismatch.
printf '57 %s %s %s\n' "$(( NOW - 39600 ))" "$(( NOW - 60 ))" "$(( NOW - 60 ))" > "$CLONE/.behind-skips"
raw="$(HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" SYNC_NO_NOTIFY=1 "$CLONE/claude-sync" stuck 2>&1)"
says "claude-sync stuck reports the stretch" "$raw" "sending is stuck"
st="$(cd "$CLONE" && HOME="$FHOME" CLAUDE_HOME="$FHOME/.claude" SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1 SYNC_LAUNCHAGENTS="$WORK/agents" \
      SYNC_CLONE_REGISTRY="$WORK/noreg" "$CLONE/claude-sync" status 2>&1)"
sentence="$(printf '%s\n' "$raw" | awk -F'\t' '$1=="sending"{print $4}')"
says "and status prints exactly the sentence it carries" "$st" "$sentence"
clear_state

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
