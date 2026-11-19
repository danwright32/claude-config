#!/usr/bin/env bash
# Tests for lib/keep_rules.py, the two keep rules Dan set on 2026-11-18 for what Claude Code leaves
# on disk (claude-config#3235): an ended session's bulky leftovers go and its written notes stay,
# and agent and test run transcripts are kept 7 days.
#
# Every case runs against a planted home in a throwaway folder, with the time handed in through
# --now and every age set with os.utime, so nothing here waits and nothing reaches the real
# ~/.claude. A folder OUTSIDE the planted home stands in for anything a link could lead to.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JOB="$DIR/lib/keep_rules.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/keep-rules.XXXXXX")" || { echo "FAIL: could not make a scratch folder"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
pass=0; fail=0
ok(){ if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; fi; }
has(){ [[ "$2" == *"$1"* ]]; }

# The real time, handed in, so a folder whose own time a removal moves reads as written to just now,
# as it would on a real run; every age below is set relative to it.
NOW="$(date +%s)"
DAY=86400
H="$WORK/home"; OUTSIDE="$WORK/outside"
NOTES="$H/state/session-notes"; PROJ="$H/projects"; REG="$H/state/sessions"
LIVE="11111111-1111-4111-8111-111111111111"
ENDED="22222222-2222-4222-8222-222222222222"
RECENT="33333333-3333-4333-8333-333333333333"
SUB="44444444-4444-4444-8444-444444444444"
RUN="55555555-5555-4555-8555-555555555555"

# Sets the modification time of a path, and of everything under it, to N days before NOW, never
# following a link.
age(){ python3 -c 'import os,sys
t=float(sys.argv[2])
for r,ds,fs in os.walk(sys.argv[1]):
  for n in ds+fs: os.utime(os.path.join(r,n),(t,t),follow_symlinks=False)
os.utime(sys.argv[1],(t,t),follow_symlinks=False)' "$1" "$(( NOW - $2 * DAY ))"; }
big(){ mkdir -p "$(dirname "$1")"; head -c 1200000 /dev/urandom > "$1"; }
note(){ mkdir -p "$(dirname "$1")"; printf 'written by hand\n' > "$1"; }
record(){   # $1 = session id  $2 = closedAt (ms, or null)  $3 = lastSeen (ms)
  mkdir -p "$REG"
  printf '{"v":1,"sessionId":"%s","lastSeen":%s,"closedAt":%s}\n' "$1" "$3" "$2" > "$REG/$1.json"
}

plant(){
  rm -rf "$H" "$OUTSIDE"
  mkdir -p "$OUTSIDE"; big "$OUTSIDE/precious.bin"; note "$OUTSIDE/precious.md"
  # A live session: open in the registry, every file old, a bulky folder in it.
  note "$NOTES/-p/$LIVE/handoff.md"; big "$NOTES/-p/$LIVE/t1/fixtures/a.bin"
  record "$LIVE" null "$(( NOW * 1000 ))"
  # An ended session: closed in the registry and quiet for four days.
  E="$NOTES/-p/$ENDED"
  note "$E/handoff.md"
  note "$E/t1/evidence.md"; note "$E/t1/tests.txt"; note "$E/t1/pr-body.md"; note "$E/t1/run.log"
  big "$E/t1/base.tar"
  big "$E/t1/fixtures/deep/a.sh"; note "$E/t1/fixtures/README.md"; note "$E/t1/fixtures/repo1/.git/HEAD"
  note "$E/t2/.git/HEAD"; big "$E/t2/src/big.sh"
  ln -s "$OUTSIDE" "$E/t1/fixtures/escape"
  note "$E/t1/small/notes.md"
  big "$E/t1/wt/payload.bin"; printf 'gitdir: /elsewhere\n' > "$E/t1/wt/.git"
  big "$E/t1/photos/a.jpg"
  big "$E/t1/sources/paper.pdf"; note "$E/t1/sources/notes.sh"
  ln -s "$OUTSIDE" "$E/t1/escape-task"
  ln -s "$OUTSIDE" "$E/escape-session"
  note "$E/t1/.keep-rules-removing.half/left.txt"
  record "$ENDED" "$(( (NOW - 5 * DAY) * 1000 ))" "$(( (NOW - 5 * DAY) * 1000 ))"
  # Absent from the registry, but written to a day ago.
  note "$NOTES/-p/$RECENT/handoff.md"; big "$NOTES/-p/$RECENT/t1/fixtures/a.bin"
  # Not a session folder at all.
  big "$NOTES/claude-config/2465/fixtures/a.bin"
  age "$NOTES" 4; age "$NOTES/-p/$RECENT" 1
  # Transcripts.
  note "$PROJ/-Users-x-proj/$SUB.jsonl"
  note "$PROJ/-Users-x-proj/$SUB/subagents/agent-old.jsonl"; note "$PROJ/-Users-x-proj/$SUB/subagents/agent-old.meta.json"
  note "$PROJ/-Users-x-proj/$SUB/subagents/workflows/r1/agent-wf.jsonl"
  note "$PROJ/-Users-x-proj/$SUB/tool-results/r.txt"
  note "$PROJ/-Users-x-proj/memory/MEMORY.md"
  note "$PROJ/-Users-x-proj--claude-worktrees-w1/$RUN.jsonl"; note "$PROJ/-Users-x-proj--claude-worktrees-w1/$RUN/tool-results/r.txt"
  note "$PROJ/-Users-x-proj--claude-worktrees-w1/memory/MEMORY.md"
  note "$PROJ/-private-tmp-abc/$RUN.jsonl"
  note "$PROJ/-private-tmp-new/$RUN.jsonl"
  age "$PROJ" 8
  note "$PROJ/-Users-x-proj/$SUB/subagents/agent-new.jsonl"; age "$PROJ/-Users-x-proj/$SUB/subagents/agent-new.jsonl" 6
  age "$PROJ/-private-tmp-new" 2
  age "$OUTSIDE" 30
}
# Every path under a folder with its time and size, read the same way on macOS and Linux.
tree(){ python3 -c 'import os,sys
for r,ds,fs in sorted(os.walk(sys.argv[1])):
  for n in sorted(ds+fs):
    p=os.path.join(r,n); s=os.lstat(p); print(p,s.st_mtime,s.st_size)' "$1"; }

# ---- would-remove lists, and writes nothing but its report ----
plant
before="$(tree "$WORK")"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" would-remove --now "$NOW" 2>&1)"; rc=$?
ok "would-remove: exits 0" "[ $rc -eq 0 ]"
ok "would-remove: changes nothing on disk" '[ "$before" = "$(tree "$WORK")" ]'
ok "would-remove: makes no state folder" "[ ! -e '$H/state/keep-rules' ]"
ok "would-remove: lists the bulky folder with its size" 'has "notes: folder in a task folder	" "$out" && has "$E/t1/fixtures" "$out"'
ok "would-remove: lists the tar file" 'has "$E/t1/base.tar" "$out"'
ok "would-remove: says why the live session is kept" 'has "live session: the session registry shows it open" "$out"'
ok "would-remove: names the largest ten" 'has "THE LARGEST TEN" "$out"'
CLAUDE_HOME="$H" python3 -B "$JOB" would-remove --now "$NOW" --report "$WORK/report.txt" >/dev/null 2>&1
ok "would-remove --report: writes the report there" 'has "WOULD REMOVE:" "$(cat "$WORK/report.txt")"'
rm -f "$WORK/report.txt"

# ---- readable-folders: what /disk-clean shows, the folders kept as mostly images or documents ----
# Dan, 2026-11-18: "2.4 Keep, and show in disk cleanup". Only ended sessions; nothing is written.
big "$NOTES/-p/$LIVE/t1/shots/a.png"; big "$NOTES/-p/$RECENT/t1/shots/a.png"
age "$NOTES/-p/$LIVE" 4; age "$NOTES/-p/$RECENT" 1
before="$(tree "$WORK")"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" readable-folders --now "$NOW" 2>&1)"; rc=$?
ok "readable-folders: exits 0" "[ $rc -eq 0 ]"
ok "readable-folders: changes nothing on disk" '[ "$before" = "$(tree "$WORK")" ]'
ok "readable-folders: lists an ended session's folder of images, with its size" 'printf "%s\n" "$out" | grep -qE "^folder	[1-9][0-9]*	$E/t1/photos\$"'
ok "readable-folders: and its folder mostly of documents" 'printf "%s\n" "$out" | grep -qE "^folder	[1-9][0-9]*	$E/t1/sources\$"'
ok "readable-folders: not a live session's folder of images" '! has "$NOTES/-p/$LIVE/" "$out"'
ok "readable-folders: not one written within 3 days" '! has "$NOTES/-p/$RECENT/" "$out"'
ok "readable-folders: not a bulky folder the rule removes" '! has "$E/t1/fixtures" "$out"'
ok "readable-folders: not a folder under 1 MB" '! has "$E/t1/small" "$out"'
ok "readable-folders: every line is a folder line" '[ -z "$(printf "%s\n" "$out" | grep -v "^folder	")" ]'
mv "$REG" "$WORK/reg-aside"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" readable-folders --now "$NOW" 2>&1)"; rc=$?
mv "$WORK/reg-aside" "$REG"
ok "readable-folders, no registry: exits 3, so a reader cannot take it for no folders" "[ $rc -eq 3 ]"
ok "readable-folders, no registry: says why in an unmeasured line" 'has "unmeasured	" "$out" && has "session registry" "$out"'
ok "readable-folders, no registry: lists no folder as ended" '! has "folder	" "$out"'

# ---- remove: the first run ----
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
ok "remove: exits 0 when nothing failed" "[ $rc -eq 0 ]"
ok "remove: prints an ok summary" 'has "KEEP-RULES-SUMMARY	ok	" "$out"'
ok "live session: its bulky folder is untouched" "[ -f '$NOTES/-p/$LIVE/t1/fixtures/a.bin' ]"
ok "recent session: kept while written within 3 days" "[ -f '$NOTES/-p/$RECENT/t1/fixtures/a.bin' ]"
ok "not a session folder: untouched" "[ -f '$NOTES/claude-config/2465/fixtures/a.bin' ]"
ok "ended: the bulky folder is gone" "[ ! -e '$E/t1/fixtures' ]"
ok "ended: the tar file is gone" "[ ! -e '$E/t1/base.tar' ]"
ok "ended: the half removed folder is finished" "[ ! -e '$E/t1/.keep-rules-removing.half' ]"
for f in handoff.md t1/evidence.md t1/tests.txt t1/pr-body.md t1/run.log t1/small/notes.md; do
  ok "ended: written note $f stays" "[ -f '$E/$f' ]"
done
ok "ended: a git checkout stays" "[ -f '$E/t1/wt/payload.bin' ]"
ok "ended: a task folder that is a checkout stays whole" "[ -f '$E/t2/src/big.sh' ]"
ok "ended: a folder of images stays" "[ -f '$E/t1/photos/a.jpg' ]"
ok "ended: a folder mostly of documents stays" "[ -f '$E/t1/sources/paper.pdf' ] && [ -f '$E/t1/sources/notes.sh' ]"
ok "ended: links stay, unfollowed" "[ -L '$E/t1/escape-task' ] && [ -L '$E/escape-session' ]"
ok "links: nothing outside was touched" "[ -f '$OUTSIDE/precious.bin' ] && [ -f '$OUTSIDE/precious.md' ]"
ok "transcripts: an old subagent transcript is gone" "[ ! -e '$PROJ/-Users-x-proj/$SUB/subagents/agent-old.jsonl' ] && [ ! -e '$PROJ/-Users-x-proj/$SUB/subagents/agent-old.meta.json' ]"
ok "transcripts: a workflow's old subagent transcript is gone" "[ ! -e '$PROJ/-Users-x-proj/$SUB/subagents/workflows/r1/agent-wf.jsonl' ]"
ok "transcripts: a subagent transcript under 7 days stays" "[ -f '$PROJ/-Users-x-proj/$SUB/subagents/agent-new.jsonl' ]"
ok "transcripts: Dan's own old session stays" "[ -f '$PROJ/-Users-x-proj/$SUB.jsonl' ] && [ -f '$PROJ/-Users-x-proj/$SUB/tool-results/r.txt' ]"
ok "transcripts: memory stays everywhere" "[ -f '$PROJ/-Users-x-proj/memory/MEMORY.md' ] && [ -f '$PROJ/-Users-x-proj--claude-worktrees-w1/memory/MEMORY.md' ]"
ok "transcripts: an old worktree run is gone, folder and all" "[ ! -e '$PROJ/-Users-x-proj--claude-worktrees-w1/$RUN.jsonl' ] && [ ! -e '$PROJ/-Users-x-proj--claude-worktrees-w1/$RUN' ]"
ok "transcripts: an old /private/tmp run is gone, and its emptied folder" "[ ! -e '$PROJ/-private-tmp-abc' ]"
ok "transcripts: a recent /private/tmp run stays" "[ -f '$PROJ/-private-tmp-new/$RUN.jsonl' ]"
LOG="$H/state/keep-rules/removed.log"
ok "log: one line per removed item, with its size" "grep -q '	removed	notes: tar file	[0-9][0-9]*	$E/t1/base.tar\$' '$LOG'"
ok "log: the folder line carries its size" "grep -q '	removed	notes: folder in a task folder	[1-9][0-9]*	$E/t1/fixtures\$' '$LOG'"
ok "log: a run line closes the run" "grep -q '	run	ok	' '$LOG'"

# ---- a second run finds nothing ----
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
ok "second run: exits 0" "[ $rc -eq 0 ]"
ok "second run: removes nothing" 'has "KEEP-RULES-SUMMARY	ok	0	0	-" "$out"'

# ---- a run already in progress: the second waits for nobody and removes nothing ----
plant
mkdir -p "$H/state/keep-rules"
out="$(CLAUDE_HOME="$H" python3 -B -c 'import fcntl,os,subprocess,sys
fh=open(os.path.join(sys.argv[1],"state/keep-rules/.lock"),"w"); fcntl.flock(fh,fcntl.LOCK_EX)
print(subprocess.run([sys.executable,"-B",sys.argv[2],"remove","--now",sys.argv[3]],capture_output=True,text=True).stdout)' "$H" "$JOB" "$NOW" 2>&1)"
ok "lock held: says another run is removing" 'has "KEEP-RULES-SUMMARY	busy	0	0	-" "$out"'
ok "lock held: removed nothing" "[ -e '$E/t1/fixtures' ]"

# ---- the registry cannot be read: fail, loudly, and remove no notes ----
plant
rm -rf "$REG"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
ok "no registry: exits 1" "[ $rc -eq 1 ]"
ok "no registry: the summary says failed and why" 'has "KEEP-RULES-SUMMARY	failed	" "$out" && has "session registry" "$out"'
ok "no registry: no notes were removed" "[ -e '$E/t1/fixtures' ] && [ -e '$E/t1/base.tar' ]"
ok "no registry: the transcripts rule still ran" "[ ! -e '$PROJ/-private-tmp-abc' ]"
ok "no registry: the log says it failed" "grep -q '	run	failed	' '$H/state/keep-rules/removed.log'"

# ---- an item that cannot be removed fails the run ----
plant
chmod a-w "$E/t1"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
chmod u+w "$E/t1"
ok "unremovable: exits 1" "[ $rc -eq 1 ]"
ok "unremovable: names the item" 'has "could not be removed" "$out"'
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
ok "after a failed run: its own removals do not make the session look written to, so the next run finishes" "[ $rc -eq 0 ] && [ ! -e '$E/t1/fixtures' ]"

# ---- a folder that cannot be read: its session cannot be judged quiet, so it is kept ----
plant
mkdir -p "$E/t3/locked"; note "$E/t3/locked/new.md"; chmod 000 "$E/t3/locked"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"
chmod 755 "$E/t3/locked"
ok "unreadable folder: the session's bulky folder is kept" "[ -e '$E/t1/fixtures' ]"

# ---- an empty folder the run did not empty is left alone ----
plant
mkdir -p "$PROJ/-Users-x-proj/$SUB/tool-results/empty-now"
CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" >/dev/null 2>&1
ok "prune: an empty folder in Dan's own session that this run did not empty stays" "[ -d '$PROJ/-Users-x-proj/$SUB/tool-results/empty-now' ]"
ok "prune: the subagents folder this run emptied of old transcripts keeps the newer one" "[ -f '$PROJ/-Users-x-proj/$SUB/subagents/agent-new.jsonl' ]"
ok "prune: the workflow folder it emptied is gone" "[ ! -e '$PROJ/-Users-x-proj/$SUB/subagents/workflows' ]"

# ---- a log that cannot be written: nothing is removed without its line ----
plant
mkdir -p "$H/state/keep-rules/removed.log"
out="$(CLAUDE_HOME="$H" python3 -B "$JOB" remove --now "$NOW" 2>&1)"; rc=$?
ok "no log: exits 1" "[ $rc -eq 1 ]"
ok "no log: says the log could not be opened" 'has "could not be opened" "$out"'
ok "no log: removed nothing" "[ -e '$E/t1/fixtures' ] && [ -e '$PROJ/-private-tmp-abc' ]"

# ---- a mode that is not one does nothing ----
plant
before="$(tree "$WORK")"
CLAUDE_HOME="$H" python3 -B "$JOB" >/dev/null 2>&1; rc=$?
ok "no mode: exits 2 and changes nothing" '[ $rc -eq 2 ] && [ "$before" = "$(tree "$WORK")" ]'

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
