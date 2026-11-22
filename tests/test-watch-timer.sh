#!/usr/bin/env bash
# A merge to main reaches a Mac whether or not a file changes on it, and status says when the clone
# is behind main's newest tested commit (claude-config#3396).
#
# On 2026-11-21 on the personal MacBook two merges with green checks (#3381 at 7:54 AM ET, #3382 at
# 8:11 AM ET) sat uninstalled: the change watcher wakes only when fswatch reports a local change, its
# last tick was 7:29 AM ET, and the receive timer runs once a day. A pull typed at about 8:22 AM ET
# installed both. Nothing said the clone was behind.
#
# This suite holds:
#   1. A watcher with no local change asks the shared repo on its timer, and a clone level with main
#      does nothing more: no tick, no send.
#   2. A new commit on main whose tests passed is installed by the next timer wake, through the
#      same locked and CI gated tick an edit runs.
#   3. A head still being tested is ticked once, never installed, and then only asked about; a
#      commit below it that passes later is taken in, and the head is once it passes.
#   4. A head that failed is never installed and is not ticked again.
#   5. A held lock, a hold and an unreachable shared repo each skip the wake, recorded and said.
#   6. Two watchers waking at once install the commit once and fail nothing (assume it runs twice).
#   7. status says when the clone is behind main's newest tested commit, by how many commits and
#      since when; says nothing when it is level with it or behind only untested commits; and says
#      when it could not read the verdicts.
#
# Everything is a fixture: CLAUDE_HOME and SYNC_REPO are throwaways, the shared repo is a bare repo
# on disk, gh is a stand in answering per commit, and every seam that could reach the Mac's own
# files is pointed into WORK. No test waits on a duration: the watcher's timer is one second (the
# shortest bash 3.2's read accepts), and each run ends on the CONDITION it is waiting for, read from
# the record the watcher writes, with a bound only as a guard against a run that never gets there
# (L290, L524).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2 = a command string that succeeds when the check holds  [$3 = output to show]
  if eval "$2"; then pass=$((pass + 1)); else
    fail=$((fail + 1)); echo "FAIL: $1"
    [ -n "${3:-}" ] && printf '%s\n' "$3" | sed -n '1,25p' | sed 's/^/    /'
  fi
  return 0
}
# Every pattern on ONE line of the output, so two halves of different sentences cannot pass it.
line_has(){   # $1 = output  $2.. = fixed strings
  local cur="$1" p
  [ -n "$cur" ] || return 1
  shift
  for p in "$@"; do cur="$(printf '%s\n' "$cur" | grep -F -- "$p")" || return 1; done
  [ -n "$cur" ]
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/watch-timer.XXXXXX")"
WORK="$(cd "$WORK" && pwd -P)"
HOLDER_PID=""
trap '[ -n "$HOLDER_PID" ] && kill "$HOLDER_PID" 2>/dev/null; rm -rf "$WORK"' EXIT

export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude" SYNC_RTK_BIN="$WORK/no-such-rtk"
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
export SYNC_LOG_FILE="$WORK/sync.log"
export SYNC_CLONE_REGISTRY="$WORK/clone-registry"; : > "$SYNC_CLONE_REGISTRY"
export SYNC_ZSHRC="$WORK/zshrc" SYNC_HOLD_FILE="$WORK/hold" SYNC_RETIRED_FILE="$WORK/retired"
export SYNC_WATCH_PID_FILE="$WORK/watch.pid"
# This suite starts one copy of claude-sync as the watcher many times in a few minutes, which is what
# a copy that keeps ending as soon as it starts looks like (#1594), and the fifth start would park.
export SYNC_WATCH_LOOP_MAX=100000
# A refused catch up is held off this long by the send; 0 here, and one case sets it (see case 4).
export SYNC_RECONCILE_RETRY=0
export SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_NO_NOTIFY=1
export SYNC_REPO_SLUG="acme/widgets"

# A gh that answers each commit with the state recorded for it (the last line for a commit wins), and
# in_progress for a commit nothing was recorded for, as the #2230 section of test-claude-sync.sh does.
# Its paths are written in, never read from the environment, so nothing has to be exported for it.
WBIN="$WORK/bin"; mkdir -p "$WBIN"
WSTATES="$WORK/ci-states"; : > "$WSTATES"
WCALLS="$WORK/ci-calls"; : > "$WCALLS"
cat > "$WBIN/gh" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$WCALLS"
sha=""
for a in "\$@"; do
  case "\$a" in repos/*/commits/*/check-runs) sha="\${a#*/commits/}"; sha="\${sha%%/*}" ;; esac
done
st="\$(awk -v s="\$sha" '\$1 == s { v = \$2 } END { print v }' "$WSTATES" 2>/dev/null)"
printf '%s\n' "\${st:-in_progress}"
STUB
chmod +x "$WBIN/gh"
export SYNC_GH="$WBIN/gh"
w_ci(){ printf '%s %s\n' "$1" "$2" >> "$WSTATES"; }   # $1 = commit  $2 = its check state

WB="$WORK/bare.git"; git init -q --bare -b main "$WB"
WA="$WORK/repoA"; git clone -q "$WB" "$WA" 2>/dev/null
WR="$WORK/repoB"; git clone -q "$WB" "$WR" 2>/dev/null
WHA="$WORK/homeA"; mkdir -p "$WHA/skills/base"; echo '{"hooks":{}}' > "$WHA/settings.json"
WHB="$WORK/homeB"; mkdir -p "$WHB/skills"; echo '{"hooks":{}}' > "$WHB/settings.json"
printf -- '---\nname: base\ndescription: base\n---\nbase\n' > "$WHA/skills/base/SKILL.md"
w_sync(){   # $1 = A or B -> a sync typed on that Mac, as the fixture's setup
  if [ "$1" = A ]; then
    CLAUDE_HOME="$WHA" SYNC_REPO="$WA" SYNC_HOSTNAME=mac-wt-A bash "$SCRIPT" sync >/dev/null 2>&1 || true
  else
    CLAUDE_HOME="$WHB" SYNC_REPO="$WR" SYNC_HOSTNAME=mac-wt-B bash "$SCRIPT" sync >/dev/null 2>&1 || true
  fi
}
w_sync A; w_sync B
# A merge on main, made with git alone, the way a pull request lands: prints the new head.
w_publish(){   # $1 = skill  $2 = body
  git -C "$WA" fetch -q origin 2>/dev/null
  git -C "$WA" reset -q --hard origin/main
  mkdir -p "$WA/payload/skills/$1"
  printf -- '---\nname: %s\ndescription: %s\n---\n%s\n' "$1" "$1" "$2" > "$WA/payload/skills/$1/SKILL.md"
  git -C "$WA" add "payload/skills/$1/SKILL.md"
  git -C "$WA" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m "merge the $1 skill"
  git -C "$WA" push -q origin HEAD:main 2>/dev/null
  git -C "$WB" rev-parse main
}
w_has(){ grep -q "$2" "$WHB/skills/$1/SKILL.md" 2>/dev/null; }   # $1 = skill  $2 = text Mac B runs
w_field(){ awk -F '\t' -v f="$1" 'NR == 1 { print $f }' "$WR/.watch-idle" 2>/dev/null; }   # 1 at 2 verdict 3 remote 4 handed

# The watcher, with a stand in fswatch that reports no change at all and ends once the record the
# watcher writes on a timer wake satisfies the condition given, or after 600 looks (a guard, not a
# wait: every case below ends on its condition in a few wakes).
w_watch(){   # $1 = the verdict to wait for  $2 = output file  [env assignments...]
  local want="$1" out="$2" fs="$WORK/fswatch.$RANDOM" since
  shift 2
  since="$(date +%s)"
  cat > "$fs" <<FS
#!/usr/bin/env bash
n=0
while [ "\$n" -lt ${WATCH_TIMER_GUARD:-600} ]; do
  if awk -F '\t' -v w="$want" -v s="$since" 'NR == 1 && \$2 == w && \$1 > s { f = 1 } END { exit !f }' "$WR/.watch-idle" 2>/dev/null; then exit 0; fi
  sleep 0.1; n=\$((n + 1))
done
FS
  chmod +x "$fs"
  env SYNC_FSWATCH="$fs" SYNC_WATCH_POLL=1 CLAUDE_HOME="$WHB" SYNC_REPO="$WR" SYNC_HOSTNAME=mac-wt-B "$@" \
    bash "$SCRIPT" watch > "$out" 2>&1 || true
}
w_wakes(){ grep -c 'woke on its timer' "$1" 2>/dev/null || true; }

# ---- 1. level with main: the timer asks, and nothing more happens ----
: > "$WORK/hits"
w_watch level "$WORK/w1.out" SYNC_WATCH_SEND="printf 'x\n' >> '$WORK/hits'"
w1="$(cat "$WORK/w1.out")"
check "(fixture) Mac B starts level with the shared repo, running its base skill" "w_has base base" "$w1"
check "a watcher with no local change asks the shared repo on its timer, and records that it is level" \
  "[ \"\$(w_field 2)\" = level ] && [ \"\$(w_field 3)\" = \"\$(git -C '$WB' rev-parse main)\" ]" "$w1"
check "and a level clone runs no tick at all" "[ ! -s '$WORK/hits' ] && [ \"\$(w_wakes '$WORK/w1.out')\" = 0 ]" "$w1"
check "and asks GitHub nothing, since there is nothing to judge" "[ ! -s '$WCALLS' ]" "$(cat "$WCALLS")"
check "its start line says how often it asks" "line_has \"\$w1\" 'asks the shared repo every 1 second'" "$w1"

# ---- 2. a merge whose tests passed arrives with no local change ----
c1="$(w_publish first 'C1, tests passed')"; w_ci "$c1" success
w_watch level "$WORK/w2.out"
w2="$(cat "$WORK/w2.out")"
check "a merge whose tests passed is installed by the timer, with nothing changed on this Mac" "w_has first 'C1, tests passed'" "$w2"
check "the log says the timer woke it, naming the commit main has" "line_has \"\$w2\" 'woke on its timer' '${c1:0:8}'" "$w2"
check "and the tick then said what it did, as an edit's tick does" "line_has \"\$w2\" 'claude-sync watch:' 'nothing to send'" "$w2"
check "and asked the CI verdict for it, through the gate" "grep -q \"commits/$c1/check-runs\" '$WCALLS'" "$(cat "$WCALLS")"

# ---- 3. a head still being tested: one tick, nothing installed, then only asked about ----
c2="$(w_publish second 'C2, passes later')"
c3="$(w_publish third 'C3, newest, still being tested')"
w_watch waiting "$WORK/w3.out"
w3="$(cat "$WORK/w3.out")"
check "while every new commit is still being tested nothing of them is installed" \
  "[ ! -e '$WHB/skills/second/SKILL.md' ] && [ ! -e '$WHB/skills/third/SKILL.md' ]" "$w3"
check "a new head is handed to one tick, and later wakes only ask about it" \
  "[ \"\$(w_wakes '$WORK/w3.out')\" = 1 ] && [ \"\$(w_field 4)\" = '$c3' ]" "$w3"
check "the record says it is waiting on the head's tests" "[ \"\$(w_field 2)\" = waiting ]" "$(head -1 "$WR/.watch-idle")"
w_ci "$c2" success
w_watch waiting "$WORK/w3b.out"
w3b="$(cat "$WORK/w3b.out")"
check "a commit below the head that passes later is taken in by the next wake" "w_has second 'C2, passes later'" "$w3b"
check "and the head, still being tested, is not" "[ ! -e '$WHB/skills/third/SKILL.md' ]" "$w3b"
check "and the wake says why it ticked" "line_has \"\$w3b\" 'woke on its timer' '${c2:0:8}' 'passed its tests'" "$w3b"
w_ci "$c3" success
w_watch level "$WORK/w3c.out"
w3c="$(cat "$WORK/w3c.out")"
check "the head is installed by the wake after it passes" "w_has third 'C3, newest'" "$w3c"

# ---- 4. a head that failed: never installed, and not ticked again ----
c4="$(w_publish fourth 'C4, failed')"; w_ci "$c4" failure
w_watch waiting "$WORK/w4.out"
w4="$(cat "$WORK/w4.out")"
check "a head that failed its tests is never installed" "[ ! -e '$WHB/skills/fourth/SKILL.md' ]" "$w4"
check "and is handed to one tick only" "[ \"\$(w_wakes '$WORK/w4.out')\" = 1 ]" "$w4"
c5="$(w_publish fifth 'C5, the fix')"; w_ci "$c5" success
# The send holds off a catch up for SYNC_RECONCILE_RETRY after one is refused, and the wake honours
# that rather than counting one more skipped send on every wake. The rest of this suite sets it to
# 0, because its one second timer is far inside the 300 second default (set in the code, not
# measured); the real timer is not.
w_watch waiting "$WORK/w4h.out" SYNC_RECONCILE_RETRY=3600
check "a wake inside the hold off after a refused catch up runs no tick, and says why" \
  "[ \"\$(w_wakes '$WORK/w4h.out')\" = 0 ] && [ ! -e '$WHB/skills/fifth/SKILL.md' ] && grep -q 'SYNC_RECONCILE_RETRY' '$WR/.watch-idle'" \
  "$(cat "$WORK/w4h.out" "$WR/.watch-idle")"
w_watch level "$WORK/w4b.out"
check "(control) the fix that lands after it is installed, the failed commit's change with it" \
  "w_has fifth 'C5, the fix' && w_has fourth 'C4, failed'" "$(cat "$WORK/w4b.out")"

# ---- 5. a held lock, a hold, an unreachable shared repo: the wake does nothing, and says why ----
c6="$(w_publish sixth 'C6, waits for the lock')"; w_ci "$c6" success
sleep 300 & HOLDER_PID=$!
mkdir -p "$WR/.sync-lock"; printf '%s\n' "$HOLDER_PID" > "$WR/.sync-lock/pid"; printf 'mac-wt-B\n' > "$WR/.sync-lock/host"
w_watch busy "$WORK/w5.out"
w5="$(cat "$WORK/w5.out")"
check "a wake while another run holds the sync lock runs no tick and installs nothing" \
  "[ ! -e '$WHB/skills/sixth/SKILL.md' ] && [ \"\$(w_wakes '$WORK/w5.out')\" = 0 ]" "$w5"
check "and its record names the run that holds the lock" "[ \"\$(w_field 2)\" = busy ] && grep -q \"$HOLDER_PID\" '$WR/.watch-idle'" "$(head -1 "$WR/.watch-idle")"
rm -rf "$WR/.sync-lock"; kill "$HOLDER_PID" 2>/dev/null; wait "$HOLDER_PID" 2>/dev/null; HOLDER_PID=""
CLAUDE_HOME="$WHB" SYNC_REPO="$WR" bash "$SCRIPT" hold 5 "committing by hand" >/dev/null 2>&1
w_watch held "$WORK/w5b.out"
check "a wake while a hold is in force runs no tick and installs nothing" \
  "[ ! -e '$WHB/skills/sixth/SKILL.md' ] && [ \"\$(w_wakes '$WORK/w5b.out')\" = 0 ] && [ \"\$(w_field 2)\" = held ]" "$(cat "$WORK/w5b.out")"
CLAUDE_HOME="$WHB" SYNC_REPO="$WR" bash "$SCRIPT" release --force >/dev/null 2>&1
git -C "$WR" remote set-url origin "$WORK/no-such-remote.git"
w_watch unreachable "$WORK/w5c.out"
w5c="$(cat "$WORK/w5c.out")"
check "a wake that cannot reach the shared repo installs nothing and stays up" \
  "[ ! -e '$WHB/skills/sixth/SKILL.md' ] && [ \"\$(w_field 2)\" = unreachable ]" "$w5c"
check "and does not log every failed look, which status and the record carry" "[ \"\$(w_wakes '$WORK/w5c.out')\" = 0 ] && ! grep -q 'FAILED' '$WORK/w5c.out'" "$w5c"
# A shared repo that never answers: the ask runs in the watcher's only loop, so it is bounded, or
# every later change would wait behind it. An ssh remote whose transport just sleeps stands in.
git -C "$WR" remote set-url origin "ssh://fixture.invalid/never-answers.git"
printf '#!/usr/bin/env bash\nsleep 5\n' > "$WBIN/silent-ssh"; chmod +x "$WBIN/silent-ssh"
w_watch unreachable "$WORK/w5d.out" GIT_SSH_COMMAND="$WBIN/silent-ssh" SYNC_WATCH_ASK_TIMEOUT=1
check "an ask the shared repo never answers is stopped at its bound and recorded, and the watcher goes on" \
  "grep -q 'did not answer within 1s' '$WR/.watch-idle'" "$(cat "$WORK/w5d.out" "$WR/.watch-idle")"
git -C "$WR" remote set-url origin "$WB"

# ---- 6. assume it runs twice: two watchers wake at once ----
w_watch level "$WORK/w6a.out" SYNC_WATCH_PID_FILE="$WORK/watch-a.pid" &
w6a_pid=$!
w_watch level "$WORK/w6b.out" SYNC_WATCH_PID_FILE="$WORK/watch-b.pid"
wait "$w6a_pid" 2>/dev/null
check "two watchers waking together install the commit" "w_has sixth 'C6, waits for the lock'" "$(cat "$WORK/w6a.out" "$WORK/w6b.out")"
check "and neither fails" "! grep -q 'FAILED' '$WORK/w6a.out' '$WORK/w6b.out'" "$(cat "$WORK/w6a.out" "$WORK/w6b.out")"
check "and the shared repo is untouched by either: main is still the merge" \
  "[ \"\$(git -C '$WB' rev-parse main)\" = '$c6' ]"

# ---- 7. status: behind main's newest tested commit, by how many and since when ----
w_status(){ env CLAUDE_HOME="$WHB" SYNC_REPO="$WR" SYNC_HOSTNAME=mac-wt-B "$@" bash "$SCRIPT" status 2>&1; }
s0="$(w_status)"
check "status says nothing about being behind when the clone is level with main" \
  "! printf '%s\n' \"\$s0\" | grep -q 'newest tested commit'" "$s0"
c7="$(w_publish seventh 'C7, passed')"; w_ci "$c7" success
c8="$(w_publish eighth 'C8, passed')"; w_ci "$c8" success
c9="$(w_publish ninth 'C9, still being tested')"
s1="$(w_status)"
check "status says the clone is behind main's newest tested commit, by how many commits" \
  "line_has \"\$s1\" '2 commits behind' 'newest tested commit' '${c8:0:8}'" "$s1"
check "and since when" "line_has \"\$s1\" 'newest tested commit' 'since'" "$s1"
s1u="$(w_status SYNC_GH="$WORK/no-such-gh")"
check "status says so when it could not read which commits passed, rather than nothing" \
  "line_has \"\$s1u\" 'behind' 'could not be read'" "$s1u"
w_watch waiting "$WORK/w7.out"
s2="$(w_status)"
check "(fixture) the next wake took in everything that passed" "w_has eighth 'C8, passed' && [ ! -e '$WHB/skills/ninth/SKILL.md' ]" "$(cat "$WORK/w7.out")"
check "status says nothing when the clone is behind only commits still being tested" \
  "! printf '%s\n' \"\$s2\" | grep -q 'newest tested commit'" "$s2"
# A commit that passed, under a head that FAILED: the gate takes nothing in below a red head, so
# status must not promise the watcher will take it in (the receiving stuck line says why).
c10="$(w_publish tenth 'C10, passed')"; w_ci "$c10" success
c11="$(w_publish eleventh 'C11, failed')"; w_ci "$c11" failure
s3="$(w_status)"
check "status does not offer a passed commit under a failed head as one the watcher will take in" \
  "! printf '%s\n' \"\$s3\" | grep -q 'newest tested commit'" "$s3"

# ---- where the writes landed (L322): the fixture, and nothing of this Mac's ----
check "the record the wakes write is inside the fixture clone, never this checkout" \
  "[ -f '$WR/.watch-idle' ] && [ ! -e '$HERE/../.watch-idle' ]"

echo ""
echo "PASS=$pass FAIL=$fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
