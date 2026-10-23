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
            print("%s\t%s" % (ev, hit.group(1) if hit else "external:" + c.split()[0]))
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
run_hook(){ # run_hook <event> <name> -> runs it once in the current world, shims on PATH
  local cmd
  case "$2" in
    *.py) cmd=(python3 "$DIR/$2") ;;
    *) cmd=("$REAL_BASH" "$DIR/$2") ;;
  esac
  payload "$1" | ( cd "$F/proj" && env HOME="$F/home" TMPDIR="$F/tmp" CLAUDE_HOME="$F/home/.claude" \
    PATH="$SHIMBIN:$REAL_PATH" "${EXTRA_ENV[@]+"${EXTRA_ENV[@]}"}" "${cmd[@]}" ) >/dev/null 2>&1
  return 0
}

# ---- what each hook reads that grows, populated N deep ----
# Each entry sets EXTRA_ENV and fills the world with N of whatever piles up for that hook. "none"
# entries carry the reason they read nothing that accumulates.
EXTRA_ENV=()
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
      # This session's record is already there, so neither run measured starts a background run
      # whose processes would land in the count while it is being read.
      : > "$F/tmp/claude-stale-worktrees-$(printf '%s' cost-session | shasum | cut -c1-12).state" ;;
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
    *)
      REASON="UNKNOWN"; return 2 ;;
  esac
  return 0
}

launches(){ # launches <event> <name> <N> -> processes started by one settled run at depth N
  fresh "$3"
  populate "$2" "$3"
  run_hook "$1" "$2"          # settles anything a first prompt seeds
  : > "$SHIM_LOG"
  run_hook "$1" "$2"
  local n
  n="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
  echo "${n:-0}"
}

SMALL=2
LARGE=200
measured=0
while IFS="$(printf '\t')" read -r ev name; do
  [ -n "$name" ] || continue
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

# The control: the shims see a hook start anything at all, or every equal pair above is two zeros.
fresh control; populate rule-files-changed.sh 3
: > "$SHIM_LOG"; run_hook UserPromptSubmit rule-files-changed.sh
_ctl="$(grep -c . "$SHIM_LOG" 2>/dev/null)"
[ "${_ctl:-0}" -gt 0 ] && check "the control: the shims count what a hook starts" ok \
  || check "the control: the shims count what a hook starts" "they counted nothing, so every equal pair proves nothing"
[ "$measured" -gt 0 ] && check "at least one hook was measured rather than exempted" ok \
  || check "at least one hook was measured rather than exempted" "none was"

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
