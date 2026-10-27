#!/usr/bin/env bash
# Every hook that runs on every prompt, or at the end of every turn, does work that does not grow
# with what has piled up on disk (claude-config#603).
#
# ai-review-nudge.sh timed out on every prompt because its cost grew with the review files in its
# state directory: one process per file, and a pattern match of each name against the session's
# whole shown list, 15 to 26 s at load 200 to 330 (measured 2026-10-03) against a 5 s timeout, so its output was thrown
# away every time (fixed in #602). Nothing had checked any other per prompt hook for that shape.
#
# The hooks are read from the hooks block beside them (settings.hooks.json in the checkout, settings.json
# once installed, through lib/settings-file.sh), never listed here by hand (L41, L96): a UserPromptSubmit
# or Stop hook added there and not given an entry below fails this suite until somebody has said how
# its accumulated state is populated, or why it has none.
#
# Each hook is run against a SMALL and a LARGE copy of the state it reads, and the processes it
# starts are COUNTED, never timed (L224): every external command it could start is shimmed to log
# its name. The two counts must be equal. A command run by absolute path bypasses the shims, which
# is why each entry also names what it reads.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

# Every wait on a condition gives up at the one ceiling only a hang reaches (lib/hang-wait.sh,
# claude-config#1679), handed to the stand ins this suite writes as FAKE_HANG_S, since they run as
# processes of their own.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/hang-wait.sh" || {
  echo "FAIL: $(basename "$0"): lib/hang-wait.sh is missing, so this suite's waits have no ceiling."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
export FAKE_HANG_S="$HANG_S"

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The shipped hooks block in the checkout, the installed one under ~/.claude (claude-config#1237).
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ -z "$SETTINGS" ] || ! command -v python3 >/dev/null 2>&1; then
  printf 'SUITE-NOT-RUN %s\n' "needs settings.hooks.json or settings.json beside the hooks and python3 to read it"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
fi

WORK="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/per-prompt-cost.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$WORK"' EXIT

# Every UserPromptSubmit and Stop command, as "<event><TAB><name>", where name is the script under
# hooks/ or, for a command that runs nothing of ours, the command's first word.
HOOKS="$(python3 -c '
import json, re, sys
d = json.load(open(sys.argv[1]))["hooks"]
for ev in ("UserPromptSubmit", "Stop"):
    for m in d.get(ev, []):
        for h in m.get("hooks", []):
            c = h.get("command", "")
            hit = re.search(r"/hooks/([^\s\"]+)", c)
            # The arguments it is registered with ride along, so it is run as Claude Code runs it:
            # pr-merge-quiz.sh is a Stop hook only with --release-held (#1768).
            print("%s\t%s\t%s" % (ev, hit.group(1) if hit else "external:" + c.split()[0], c[hit.end():].strip() if hit else ""))
' "$SETTINGS")"
[ -n "$HOOKS" ] && check "settings name per prompt hooks to measure" ok \
  || check "settings name per prompt hooks to measure" "none were read, so nothing below measures anything"

# ---- the shims: one log line per external command started ----
SHIMBIN="$WORK/shimbin"; mkdir -p "$SHIMBIN"
export SHIM_LOG="$WORK/shim.log"
REAL_PATH="$PATH"
REAL_BASH="$(command -v bash)"
for c in basename dirname cat date mkdir touch find git cksum cut jq python3 awk rm mv cp sed grep \
         wc head tail tr sort uniq stat ls shasum ps df comm hostname perl bash sh env xargs tee \
         sleep id uname readlink mktemp paste od; do
  real="$(command -v "$c" 2>/dev/null)" || continue
  printf '#!/bin/sh\nprintf "%%s\\n" %s >> "$SHIM_LOG"\nexec %s "$@"\n' "$c" "$real" > "$SHIMBIN/$c"
  chmod +x "$SHIMBIN/$c"
done

# ---- a fresh, isolated world per run: its own HOME and TMPDIR, so nothing real is read (L2) ----
F=""
fresh(){
  F="$WORK/run.$1.$RANDOM"
  mkdir -p "$F/home/.claude" "$F/tmp" "$F/proj"
  : > "$F/t.jsonl"
}
payload(){ # payload <event>
  python3 -c '
import json, sys
print(json.dumps({"session_id": "cost-session", "transcript_path": sys.argv[2], "cwd": sys.argv[3],
                  "prompt": "please look at this", "hook_event_name": sys.argv[1], "stop_hook_active": False}))
' "$1" "$F/t.jsonl" "$F/proj"
}
# Each run logs to a shim log of its OWN, which SHIM_LOG names once it returns (claude-config#1577).
# A process an earlier run left running (a settling run's detached background job) keeps the log of
# the run that started it, inherited through its environment, so it can never land in the count of
# the run being measured. One shared log, emptied between runs, counted whatever the earlier run's
# job had reached by then: on 2026-10-23 at 17:14 ET, at load average 160 to 220 on 12 cores, the
# same stale-worktree-nudge.sh run counted 13, 15, 16 or 17 as its settling run's background check
# got further or not, and the hook's own share was 10 every time (L203, L470).
run_hook(){ # run_hook <event> <name> -> runs it once in the current world, shims on PATH
  local cmd
  SHIM_LOG="$(mktemp "$WORK/shim.XXXXXXXX")"
  case "$2" in
    /*) cmd=("$REAL_BASH" "$2") ;;   # a stand-in of the suite's own, by its full path
    *.py) cmd=(python3 "$DIR/$2") ;;
    *) cmd=("$REAL_BASH" "$DIR/$2") ;;
  esac
  payload "$1" | ( cd "$F/proj" && env HOME="$F/home" TMPDIR="$F/tmp" CLAUDE_HOME="$F/home/.claude" \
    PATH="$SHIMBIN:$REAL_PATH" "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" "${cmd[@]}" "${RUN_ARGS[@]+"${RUN_ARGS[@]}"}" ) >/dev/null 2>&1
  return 0
}

# ---- what each hook reads that grows, populated N deep ----
# Each entry sets EXTRA_ENV and fills the world with N of whatever piles up for that hook. "none"
# entries carry the reason they read nothing that accumulates. RUN_ARGS are the arguments the hook
# being measured is registered with, set by the loop below and empty for every other run.
EXTRA_ENV=()
RUN_ARGS=()
populate(){ # populate <name> <N> -> 0, or 1 with REASON set when the hook reads nothing that piles up
  local name="$1" n="$2" i
  EXTRA_ENV=()
  REASON=""
  case "$name" in
    turn-end-sound.sh)
      REASON="reads the one sleep record and plays one sound file; the record is a single small file that does not pile up"; return 1 ;;
    no-ai-tells-detect.py)
      REASON="reads the prompt and one skill file, neither of which piles up"; return 1 ;;
    ai-review-nudge.sh)
      # Measured where its fixture already lives, a real repository with real review files.
      REASON="measured by test-ai-review-on-push.sh sections 6b and 6c against 300 review files of another repository and 300 of each kind of its own"; return 1 ;;
    project-list-nudge.sh)
      REASON="reads the project list Dan writes by hand in CLAUDE.md, a curated list rather than anything that piles up"; return 1 ;;
    stale-worktree-nudge.sh)
      # Once per session by construction: the record is written before the run starts, and the run
      # itself is never waited for (#1247). So the later prompts, which are every prompt but one, are
      # what is measured, in a repository with N worktrees and with N answers from OTHER
      # repositories' runs waiting in the state directory, which every prompt globs.
      git init -q "$F/proj" >/dev/null 2>&1
      i=0; while [ "$i" -lt "$n" ]; do
        mkdir -p "$F/proj/.claude/worktrees/w$i"
        printf 'removed w%d\n' "$i" > "$F/tmp/claude-stale-worktrees-repo-other$i.result.1700000000.$i"
        i=$((i + 1))
      done
      # This session's record is already there, with a run started this minute, so neither run
      # starts a background run (#1577). An EMPTY record, as this was, is one the hook treats as due
      # (it cannot say how old it is), so the settling run started the real cleanup check in the
      # background every time this suite ran, and its processes landed in the measured count.
      printf 'started %s\n' "$(date +%s)" > "$F/tmp/claude-stale-worktrees-$(printf '%s' cost-session | shasum | cut -c1-12).state" ;;
    rule-files-changed.sh)
      # The rule files this session loaded: CLAUDE.md and every bare import, which grows with
      # every section the lessons index is split into, and the mods it loaded, which grow with
      # every mod written.
      : > "$F/home/.claude/CLAUDE.md"
      i=0; while [ "$i" -lt "$n" ]; do
        printf '@RULES-%d.md\n' "$i" >> "$F/home/.claude/CLAUDE.md"
        printf 'rule %d\n' "$i" > "$F/home/.claude/RULES-$i.md"
        # And the mods it named at its start (claude-config#1535), one folder per mod.
        mkdir -p "$F/home/.claude/mods/mod-$i/.claude-plugin"
        printf '{ "name": "mod-%d" }\n' "$i" > "$F/home/.claude/mods/mod-$i/.claude-plugin/plugin.json"
        i=$((i + 1))
      done ;;
    payload-revert-warning.sh)
      # Every other session's record sits beside this one's.
      i=0; while [ "$i" -lt "$n" ]; do : > "$F/tmp/claude-payload-revert-other$i.state"; i=$((i + 1)); done ;;
    free-space-nudge.sh)
      # One reading per prompt across every session, kept for the window.
      EXTRA_ENV=(FREE_SPACE_BYTES=500000000000 FREE_SPACE_NOW=2000000000 FREE_SPACE_STATE_DIR="$F/fs")
      mkdir -p "$F/fs"
      awk -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%d %d\n", 2000000000 - 3600 + i, 500000000000 }' > "$F/fs/_" ;;
    sync-stuck-notice.sh)
      EXTRA_ENV=(SYNC_LAUNCHAGENTS="$F/agents")
      mkdir -p "$F/agents"
      i=0; while [ "$i" -lt "$n" ]; do
        printf '<plist><string>%s/clone/claude-sync</string></plist>\n' "$F" > "$F/agents/com.claudesync.job$i.plist"
        i=$((i + 1))
      done ;;
    suite-pile-notice.sh)
      EXTRA_ENV=(SYNC_PS_FIXTURE="$F/ps.txt")
      awk -v n="$n" 'BEGIN { for (i = 0; i < n; i++) printf "%d 1 00:01 /bin/sleep %d\n", 1000 + i, i }' > "$F/ps.txt" ;;
    lessons-core-notice.sh)
      printf 'fallback the list is empty\n' > "$F/home/.claude/.lessons-core-state"
      mkdir -p "$F/home/.claude/state/lessons-core-notice"
      i=0; while [ "$i" -lt "$n" ]; do printf 'x\n' > "$F/home/.claude/state/lessons-core-notice/other$i"; i=$((i + 1)); done ;;
    session-reflection.sh|feature-issue-review.sh)
      # The session's transcript, which only grows: N earlier turns, then a last turn that worked,
      # so the hook takes its full path. The bytes turn-worked.py reads of it, which no process
      # count can see, are measured in test-turn-worked.sh against a 2000 turn history.
      python3 -c '
import json, sys
with open(sys.argv[1], "w") as f:
    for i in range(int(sys.argv[2])):
        f.write(json.dumps({"type": "user", "message": {"content": "turn %d" % i}}) + "\n")
        f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Edit", "input": {"file_path": "/x"}}]}}) + "\n")
    f.write(json.dumps({"type": "user", "message": {"content": "last"}}) + "\n")
    f.write(json.dumps({"type": "assistant", "message": {"content": [{"type": "tool_use", "name": "Edit", "input": {"file_path": "/y"}}]}}) + "\n")
' "$F/t.jsonl" "$n" ;;
    pr-merge-quiz.sh)
      # With --release-held, at every turn end (#1768). What piles up is every OTHER session's held
      # merges, one file each in the one shared folder, plus any a stopped release left part taken;
      # this session holds none, which is every turn end but the few after a backgrounded merge. It
      # must read its own file alone, never list the folder.
      mkdir -p "$F/home/.claude-quiz-verdicts/held"
      i=0; while [ "$i" -lt "$n" ]; do
        printf '{"heldAt":%s,"merges":[{"dir":"/x","repo":"","slug":"a/b","pr":"%d"}],"payload":{}}\n' "$(date +%s)" "$i" \
          > "$F/home/.claude-quiz-verdicts/held/other-session-$i"
        : > "$F/home/.claude-quiz-verdicts/held/other-session-$i.releasing.$i"
        i=$((i + 1))
      done ;;
    *)
      REASON="UNKNOWN"; return 2 ;;
  esac
  return 0
}

launches(){ # launches <event> <name> <N> -> processes started by one settled run at depth N
  fresh "$3"
  populate "$2" "$3"
  run_hook "$1" "$2"          # settles anything a first prompt seeds
  run_hook "$1" "$2"          # counted in a log of its own, never the settling run's
  local n
  n="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
  echo "${n:-0}"
}

SMALL=2
LARGE=200
measured=0
while IFS="$(printf '\t')" read -r ev name args; do
  [ -n "$name" ] || continue
  # shellcheck disable=SC2206 # the registered arguments, split as the hook's command line splits them
  RUN_ARGS=($args)
  fresh probe; populate "$name" 1; rc=$?
  if [ "$rc" -eq 2 ]; then
    check "$ev hook $name has an entry saying what piles up for it" "it has none: add one to populate() in $(basename "$0")"
    continue
  fi
  if [ "$rc" -eq 1 ]; then
    case "$REASON" in
      *[A-Za-z]*) check "$ev hook $name is exempt with a reason ($REASON)" ok ;;
      *) check "$ev hook $name is exempt with a reason" "no reason given" ;;
    esac
    continue
  fi
  a="$(launches "$ev" "$name" "$SMALL")"
  b="$(launches "$ev" "$name" "$LARGE")"
  measured=$((measured + 1))
  echo "  $ev $name: $a processes with $SMALL, $b with $LARGE"
  if [ "$a" = "$b" ]; then
    check "$ev hook $name starts as many processes with $LARGE of what it reads as with $SMALL ($a)" ok
  else
    check "$ev hook $name starts as many processes with $LARGE of what it reads as with $SMALL" "$a with $SMALL, $b with $LARGE"
  fi
done <<EOF
$HOOKS
EOF
RUN_ARGS=()

# The control: the shims see a hook start anything at all, or every equal pair above is two zeros.
fresh control; populate rule-files-changed.sh 3
: > "$SHIM_LOG"; run_hook UserPromptSubmit rule-files-changed.sh
_ctl="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
[ "${_ctl:-0}" -gt 0 ] && check "the control: the shims count what a hook starts" ok \
  || check "the control: the shims count what a hook starts" "they counted nothing, so every equal pair proves nothing"
[ "$measured" -gt 0 ] && check "at least one hook was measured rather than exempted" ok \
  || check "at least one hook was measured rather than exempted" "none was"

# The control for #1577: what a SETTLING run leaves running never lands in the measured run's count,
# however late it runs. A stand-in hook whose first run leaves a detached job holding until the suite
# releases it, after the measured run has returned; released, the job starts two shimmed commands.
# Judged by the state, never by timing (L290): the job is waited on until it says it has finished,
# with the hang ceiling (lib/hang-wait.sh, #1679), and its two commands must be in the settling run's
# log, so the control knows the straggler really ran (L470) before it reads the measured count.
STRAGGLER="$WORK/straggler-hook.sh"
cat > "$STRAGGLER" <<'EOS'
#!/bin/bash
cat >/dev/null
if [ ! -f "$CLAUDE_HOME/seeded" ]; then
  : > "$CLAUDE_HOME/seeded"
  nohup /bin/bash -c '
    t0=$SECONDS; while [ ! -f "$CLAUDE_HOME/release" ] && [ $((SECONDS - t0)) -lt "${FAKE_HANG_S:-300}" ]; do /bin/sleep 0.05; done
    cat /dev/null; cat /dev/null; : > "$CLAUDE_HOME/straggled"' </dev/null >/dev/null 2>&1 &
  exit 0
fi
cat /dev/null
EOS
fresh straggler
run_hook UserPromptSubmit "$STRAGGLER"; _settle_log="$SHIM_LOG"
run_hook UserPromptSubmit "$STRAGGLER"; _measured_log="$SHIM_LOG"
: > "$F/home/.claude/release"
hang_wait '[ -f "$F/home/.claude/straggled" ]' 0.05
_late="$(grep -c '^cat$' "$_settle_log" 2>/dev/null)"
_counted="$(grep -c . "$_measured_log" 2>/dev/null)"
if [ ! -f "$F/home/.claude/straggled" ] || [ "${_late:-0}" -lt 3 ]; then
  check "the control: a job the settling run left running is never counted with the measured run" "the straggler never ran its two commands (finished: $([ -f "$F/home/.claude/straggled" ] && echo yes || echo no), cat lines in the settling run's log: ${_late:-0} of 3), so this control measured nothing"
elif [ "${_counted:-0}" -eq 2 ]; then
  check "the control: a job the settling run left running is never counted with the measured run (2: its own cat and cat)" ok
else
  check "the control: a job the settling run left running is never counted with the measured run" "the measured run counted ${_counted:-0}, its own 2 (cat, cat) plus what the settling run's job ran after it returned"
fi

# rule-files-changed.sh also runs at SessionStart, where it takes the baseline the prompts compare
# against (claude-config#1544). That is once per session rather than per prompt, but it is the same
# snapshot, so it must not grow with the rule files and mods either; and a start that finds its
# record already there (a resume, a compaction) must keep it without taking a snapshot at all.
# The snapshot is the hook's second shasum (the first derives the session's key), so the shasum
# count says whether one was taken, whatever else the run starts.
# Called directly, never inside $(...), so the world it makes is still F for the kept start below.
start_launches(){ # start_launches <N> -> sets S_COUNT, processes started by the first SessionStart at depth N
  fresh "start$1"; populate rule-files-changed.sh "$1"
  : > "$SHIM_LOG"; run_hook SessionStart rule-files-changed.sh
  S_COUNT="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
}
start_launches "$SMALL"; s_small="$S_COUNT"
start_launches "$LARGE"; s_large="$S_COUNT"
s_seed_sums="$(grep -c '^shasum$' "$SHIM_LOG" 2>/dev/null)"
s_world="$F"
echo "  SessionStart rule-files-changed.sh: ${s_small:-0} processes with $SMALL, ${s_large:-0} with $LARGE"
[ "${s_small:-0}" -gt 0 ] && [ "$s_small" = "$s_large" ] \
  && check "SessionStart hook rule-files-changed.sh starts as many processes with $LARGE of what it reads as with $SMALL ($s_small)" ok \
  || check "SessionStart hook rule-files-changed.sh starts as many processes with $LARGE of what it reads as with $SMALL" "${s_small:-0} with $SMALL, ${s_large:-0} with $LARGE"
: > "$SHIM_LOG"; run_hook SessionStart rule-files-changed.sh
s_kept_sums="$(grep -c '^shasum$' "$SHIM_LOG" 2>/dev/null)"
case "$s_world" in *"/run.start$LARGE."*) s_same=ok ;; *) s_same="the kept start ran in $s_world" ;; esac
check "the kept start runs in the world the $LARGE deep start recorded in" "$s_same"
[ "${s_seed_sums:-0}" -eq 2 ] && [ "${s_kept_sums:-0}" -eq 1 ] \
  && check "a SessionStart that keeps its record takes no snapshot (1 shasum, the key, against 2 to take one)" ok \
  || check "a SessionStart that keeps its record takes no snapshot" "shasum ran ${s_kept_sums:-0} times keeping and ${s_seed_sums:-0} taking one, expected 1 and 2"
# local-allow-sweep.sh also runs at SessionStart (claude-config#1582). What it reads that piles up is
# the project's own .claude/settings.local.json, which gains a rule at every "don't ask again". With no
# such file it must start nothing at all; with one, the same processes whether it holds 2 rules or 200,
# clean or flagged: one python3 reading the file once, and the one redactor run once over every rule.
allow_launches(){ # allow_launches <N> <clean|flagged|none> -> sets A_COUNT
  fresh "allow$2$1"
  if [ "$2" != none ]; then
    mkdir -p "$F/proj/.claude"
    python3 -c '
import json, sys
n, kind = int(sys.argv[2]), sys.argv[3]
rules = ["Bash(tool%d:*)" % i if kind == "clean" else "Bash(grep -n \"x%d\" a/b.ts)" % i for i in range(n)]
json.dump({"permissions": {"allow": rules}}, open(sys.argv[1], "w"), indent=2)
' "$F/proj/.claude/settings.local.json" "$1" "$2"
  fi
  EXTRA_ENV=(CLAUDE_PROJECT_DIR="$F/proj")
  : > "$SHIM_LOG"; run_hook SessionStart local-allow-sweep.sh
  EXTRA_ENV=()
  A_COUNT="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
}
allow_launches 1 none; a_none="${A_COUNT:-0}"
echo "  SessionStart local-allow-sweep.sh: $a_none processes with no local settings file"
[ "$a_none" -eq 0 ] && check "SessionStart hook local-allow-sweep.sh starts nothing when the project has no local settings file" ok \
  || check "SessionStart hook local-allow-sweep.sh starts nothing when the project has no local settings file" "it started $a_none"
for _kind in clean flagged; do
  allow_launches "$SMALL" "$_kind"; a_small="${A_COUNT:-0}"
  allow_launches "$LARGE" "$_kind"; a_large="${A_COUNT:-0}"
  echo "  SessionStart local-allow-sweep.sh, $_kind rules: $a_small processes with $SMALL, $a_large with $LARGE"
  [ "$a_small" -gt 0 ] && [ "$a_small" = "$a_large" ] \
    && check "SessionStart hook local-allow-sweep.sh starts as many processes with $LARGE $_kind rules as with $SMALL ($a_small)" ok \
    || check "SessionStart hook local-allow-sweep.sh starts as many processes with $LARGE $_kind rules as with $SMALL" "$a_small with $SMALL, $a_large with $LARGE"
done

# The exemption pointing elsewhere is only as good as the test it points at.
for _case in "300 more review files start no more processes" \
             "300 unshown whole branch reviews of this repository start no more processes" \
             "300 unshown push reviews of this repository start no more processes"; do
  grep -qF "$_case" "$DIR/test-ai-review-on-push.sh" 2>/dev/null \
    && check "the ai-review-nudge exemption points at a test that exists: $_case" ok \
    || check "the ai-review-nudge exemption points at a test that exists: $_case" "test-ai-review-on-push.sh no longer carries it"
done

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
