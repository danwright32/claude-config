#!/usr/bin/env bash
# Tests for tools/record-copy.py, which a count of session records runs first (claude-config#3413):
# it says how far back each kind of record really reaches, refuses a window longer than that, and
# copies the records in the window to a folder that outlives the session, so a count and any recount
# read the same set.
#
# Every case runs against a planted home in a throwaway folder, with the time handed in through
# --now and every age set with os.utime, so nothing here waits and nothing reads or writes the real
# ~/.claude. Every fixture line is invented.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOL="$DIR/record-copy.py"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/record-copy.XXXXXX")" || { echo "FAIL: could not make a scratch folder"; printf 'SUITE-RESULT passed=0 failed=1\n'; exit 1; }
trap 'chmod -R u+rwx "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"
pass=0; fail=0
ok(){ if eval "$2"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1"; echo "  output: ${out:0:2000}"; fi; }
has(){ [[ "$2" == *"$1"* ]]; }

# A fixed instant, so the dates below are the same on every run: 2026-11-21 12:00 in New York.
export TZ=America/New_York
NOW=1795280400
DAY=86400
H="$WORK/home"; P="$H/projects"; COPIES="$H/state/record-copies"
OWN1="11111111-1111-4111-8111-111111111111"
OWN2="22222222-2222-4222-8222-222222222222"
OWN3="33333333-3333-4333-8333-333333333333"
RUN1="55555555-5555-4555-8555-555555555555"
RUN2="66666666-6666-4666-8666-666666666666"
RUN3="77777777-7777-4777-8777-777777777777"

age(){ python3 -c 'import os,sys
t=float(sys.argv[2])
for r,ds,fs in os.walk(sys.argv[1]):
  for n in ds+fs: os.utime(os.path.join(r,n),(t,t),follow_symlinks=False)
os.utime(sys.argv[1],(t,t),follow_symlinks=False)' "$1" "$(( NOW - $2 * DAY ))"; }
rec(){ mkdir -p "$(dirname "$1")"; printf '{"invented":"%s"}\n' "$(basename "$1")" > "$1"; age "$1" "$2"; }
# Every path under a folder with its time, size and mode, read the same way on macOS and Linux.
tree(){ python3 -c 'import os,sys
for r,ds,fs in sorted(os.walk(sys.argv[1])):
  for n in sorted(ds+fs):
    p=os.path.join(r,n); s=os.lstat(p); print(p,s.st_mtime,s.st_size,oct(s.st_mode))' "$1"; }
mode(){ python3 -c 'import os,stat,sys; print(oct(stat.S_IMODE(os.lstat(sys.argv[1]).st_mode)))' "$1"; }
run(){ CLAUDE_HOME="$H" python3 -B "$TOOL" "$@" --now "$NOW" 2>&1; }

# Dan's own sessions last written 1, 5 and 20 days ago; agent records 2 and 8 days ago (one with its
# meta file); a worktree run 3 and 8 days ago and a /private/tmp run 1 day ago; a memory file and a
# tool result in Dan's own session, which are not records of any kind.
plant(){
  rm -rf "$H"
  rec "$P/-Users-x-proj/$OWN1.jsonl" 1
  rec "$P/-Users-x-proj/$OWN2.jsonl" 5
  rec "$P/-Users-x-proj/$OWN3.jsonl" 20
  rec "$P/-Users-x-proj/$OWN1/subagents/agent-a1.jsonl" 2
  rec "$P/-Users-x-proj/$OWN1/subagents/agent-a1.meta.json" 2
  rec "$P/-Users-x-proj/$OWN2/subagents/agent-a2.jsonl" 8
  rec "$P/-Users-x-proj/$OWN1/tool-results/r.txt" 1
  rec "$P/-Users-x-proj/memory/MEMORY.md" 1
  rec "$P/-Users-x-proj--claude-worktrees-w1/$RUN1.jsonl" 3
  rec "$P/-Users-x-proj--claude-worktrees-w1/$RUN2.jsonl" 8
  rec "$P/-private-tmp-abc/$RUN3.jsonl" 1
}

# ---- report: per kind, the oldest record and how many fall in the window; writes nothing ----
plant
before="$(tree "$WORK")"
out="$(run report --days 7)"; rc=$?
ok "report, 7 days: exits 0, since every kind reaches back 7 days" "[ $rc -eq 0 ]"
ok "report: changes nothing on disk and makes no copy folder" '[ "$before" = "$(tree "$WORK")" ] && [ ! -e "$COPIES" ]'
ok "report: Dan's own sessions, 2 in the window, the oldest 20 days back" 'has "Dan'"'"'s own sessions: 2 files in the window; the oldest was last written 2026-11-01" "$out" && has "(20.0 days back)" "$out"'
ok "report: agent records, 2 files in the window (a transcript and its meta file), the oldest 8 days back" 'has "agent records: 2 files in the window; the oldest was last written 2026-11-13" "$out"'
ok "report: worktree and temporary folder runs, 2 in the window, the oldest 8 days back" 'has "worktree and temporary folder runs: 2 files in the window; the oldest was last written 2026-11-13" "$out"'
ok "report: never counts a memory file or Dan's own tool result" '! has "MEMORY" "$out" && ! has "r.txt" "$out"'

# ---- the refusal: a 14 day window against records reaching 8 days ----
out="$(run report --days 14)"; rc=$?
ok "refusal, report: exits 3" "[ $rc -eq 3 ]"
ok "refusal: names the kind and how far it really reaches" 'has "agent records reach back only 8.0 days" "$out" && has "worktree and temporary folder runs reach back only 8.0 days" "$out"'
ok "refusal: says what to do instead" 'has "--accept-shorter" "$out" && has "8 days or fewer" "$out"'
ok "refusal: does not refuse over a kind that reaches the window" '! has "own sessions reach back only" "$out"'
out="$(run copy --days 14 --label refused)"; rc=$?
ok "refusal, copy: exits 3 and copies nothing" "[ $rc -eq 3 ] && [ ! -e '$COPIES' ] && has 'Nothing was copied' \"\$out\""
out="$(run report --days 14 --kinds own)"; rc=$?
ok "refusal: a count needing only Dan's own sessions, which reach 20 days, is not refused" "[ $rc -eq 0 ]"
ok "report --kinds own: reports only that kind" '! has "agent records" "$out"'

# ---- go on anyway: the copy states the shorter window it really has ----
plant
before="$(tree "$P")"
out="$(run copy --days 14 --label c3230 --accept-shorter)"; rc=$?
DEST="$(printf '%s\n' "$out" | sed -n 's|^Copied [0-9]* record files ([^)]*) to \(.*\), readable only by you\.$|\1|p')"
ok "go on: exits 0" "[ $rc -eq 0 ]"
ok "go on: names the copy folder, under state/record-copies and named for the count" '[ -n "$DEST" ] && [[ "$DEST" == "$COPIES/c3230-20261121-120000" ]]'
ok "go on: states the real window of each shorter kind" 'has "agent records: 3 files, last written 2026-11-13 to 2026-11-19; the window it really has is 8.0 days (14 asked)" "$out"'
ok "go on: and the full window of a kind that reaches it" 'has "Dan'"'"'s own sessions: 2 files, last written 2026-11-16 to 2026-11-20; the window it really has is 14 days" "$out"'
ok "copy: says how many files it holds" 'has "Copied 8 record files" "$out"'
ok "copy: lists the dates it holds, with a count for each" 'has "2026-11-13  2
  2026-11-16  1
  2026-11-18  1
  2026-11-19  2
  2026-11-20  2" "$out"'
want="./-Users-x-proj--claude-worktrees-w1/$RUN1.jsonl ./-Users-x-proj--claude-worktrees-w1/$RUN2.jsonl ./-Users-x-proj/$OWN1.jsonl ./-Users-x-proj/$OWN1/subagents/agent-a1.jsonl ./-Users-x-proj/$OWN1/subagents/agent-a1.meta.json ./-Users-x-proj/$OWN2.jsonl ./-Users-x-proj/$OWN2/subagents/agent-a2.jsonl ./-private-tmp-abc/$RUN3.jsonl "
ok "copy: holds exactly those eight records, at the paths they had under projects" '[ "$(cd "$DEST/projects" && find . -type f | LC_ALL=C sort | tr "\n" " ")" = "$want" ]'
ok "copy: left out a record last written before the window" "[ ! -e '$DEST/projects/-Users-x-proj/$OWN3.jsonl' ]"
ok "copy: keeps each record's time, so a recount by date reads the same days" '[ "$(python3 -c "import os,sys; print(int(os.stat(sys.argv[1]).st_mtime))" "$DEST/projects/-Users-x-proj/$OWN2.jsonl")" = "$(( NOW - 5 * DAY ))" ]'
ok "copy: the folders are readable only by this user" '[ "$(mode "$COPIES")" = 0o700 ] && [ "$(mode "$DEST")" = 0o700 ] && [ "$(mode "$DEST/projects/-Users-x-proj")" = 0o700 ]'
ok "copy: every file is readable only by this user" '[ -z "$(find "$DEST" -type f ! -perm 600)" ]'
ok "copy: writes what it holds beside the records" 'has "the window it really has is 8.0 days" "$(cat "$DEST/COPY.txt")"'
ok "copy: says how to delete it, and that nothing else will" 'has "Nothing removes this copy" "$out" && has "rm -rf '"'"'$DEST'"'"'" "$out"'
ok "copy: leaves no unfinished folder" '[ -z "$(ls -A "$COPIES" | grep -v -x "c3230-20261121-120000")" ]'
ok "copy: the records it copied from are untouched" '[ "$before" = "$(tree "$P")" ]'
# A recount reads the copy, which nothing removes, and finds the same set after the originals go.
rm -f "$P/-Users-x-proj--claude-worktrees-w1/$RUN2.jsonl"
out2="$(CLAUDE_HOME="$DEST" python3 -B "$TOOL" report --days 14 --accept-shorter --now "$NOW" 2>&1)"; rc=$?
ok "recount from the copy: the same counts after an original has gone" "[ $rc -eq 0 ] && has 'worktree and temporary folder runs: 3 files in the window' \"\$out2\" && has 'agent records: 3 files in the window' \"\$out2\""

# ---- a second copy in the same second, of the same count, never writes into the first ----
out="$(run copy --days 14 --label c3230 --accept-shorter)"; rc=$?
ok "same name twice: fails rather than writing into the first copy" "[ $rc -eq 1 ] && has 'already exists' \"\$out\" && ! has 'Copied ' \"\$out\""

# ---- the copy folder cannot be written: fails loudly and counts nothing ----
plant
mkdir -p "$H/state"; printf 'in the way\n' > "$COPIES"
out="$(run copy --days 7 --label blocked)"; rc=$?
ok "copy folder cannot be made: exits 1" "[ $rc -eq 1 ]"
ok "copy folder cannot be made: says so and names the folder" 'has "could not make" "$out" && has "$COPIES" "$out"'
ok "copy folder cannot be made: counts nothing and claims no copy" '! has "Copied " "$out" && ! has "files in the window" "$out" && ! has "rm -rf" "$out"'
rm -f "$COPIES"; mkdir -p "$COPIES"; chmod 500 "$COPIES"
out="$(run copy --days 7 --label readonly)"; rc=$?
chmod 700 "$COPIES"
ok "copy folder read only: exits 1 and claims no copy" "[ $rc -eq 1 ] && has 'could not make' \"\$out\" && ! has 'Copied ' \"\$out\""

# ---- a record that cannot be read: the copy is not whole, and says so ----
plant
chmod 000 "$P/-Users-x-proj/$OWN2.jsonl"
out="$(run copy --days 7 --label unreadable)"; rc=$?
chmod 600 "$P/-Users-x-proj/$OWN2.jsonl"
ok "unreadable record: exits 1" "[ $rc -eq 1 ]"
ok "unreadable record: names the record and says the copy is not whole" 'has "$OWN2.jsonl" "$out" && has "is not whole" "$out"'
ok "unreadable record: claims no finished copy, and the unfinished one is marked" '! has "Copied " "$out" && [ ! -e "$COPIES/unreadable-20261121-120000" ] && [ -d "$COPIES/unreadable-20261121-120000.incomplete" ]'

# ---- a folder of records that cannot be read: never counted as empty ----
plant
chmod 000 "$P/-Users-x-proj--claude-worktrees-w1"
out="$(run report --days 7)"; rc=$?
ok "unreadable project folder, report: exits 1 and names the folder" "[ $rc -eq 1 ] && has 'could not be read' \"\$out\" && has '-Users-x-proj--claude-worktrees-w1' \"\$out\""
ok "unreadable project folder, report: claims no counts" '! has "files in the window" "$out"'
out="$(run copy --days 7 --label unreadfolder)"; rc=$?
chmod 755 "$P/-Users-x-proj--claude-worktrees-w1"
ok "unreadable project folder, copy: exits 1 and copies nothing" "[ $rc -eq 1 ] && [ ! -e '$COPIES' ] && ! has 'Copied ' \"\$out\""
plant
chmod 000 "$P/-Users-x-proj/$OWN1/subagents"
out="$(run report --days 7)"; rc=$?
chmod 755 "$P/-Users-x-proj/$OWN1/subagents"
ok "unreadable folder inside a session: exits 1 and names it" "[ $rc -eq 1 ] && has '$OWN1/subagents' \"\$out\""

# ---- too little free space for the copy: refused before anything is written ----
plant
out="$(run copy --days 7 --label roomy --keep-free-gb 1000000000)"; rc=$?
ok "free space: refused, exit 3, nothing written" "[ $rc -eq 3 ] && has 'free' \"\$out\" && [ ! -e '$COPIES' ]"

# ---- no records folder, and options that are not options ----
rm -rf "$H"; mkdir -p "$H"
out="$(run report --days 7)"; rc=$?
ok "no records folder: exits 1 and says it is not there" "[ $rc -eq 1 ] && has 'no records folder' \"\$out\" && ! has 'link' \"\$out\""
ln -s "$WORK" "$H/projects"
out="$(run report --days 7)"; rc=$?
ok "a records folder that is a link: exits 1 and says it is not followed" "[ $rc -eq 1 ] && has 'a link is never followed' \"\$out\""
rm -f "$H/projects"
# A kind with no records at all: the refusal never advises a window that would still be refused.
plant
rm -rf "$P/-private-tmp-abc" "$P/-Users-x-proj--claude-worktrees-w1"
out="$(run report --days 3)"; rc=$?
ok "no records of a kind: refused, names the kind, and never advises 0 days" "[ $rc -eq 3 ] && has 'there are no worktree and temporary folder runs at all' \"\$out\" && ! has 'ask for 0 days' \"\$out\" && has 'leave out run with --kinds' \"\$out\""
out="$(run report --days 10)"; rc=$?
ok "a short kind and an empty one: the advice is both together, which would pass" "[ $rc -eq 3 ] && has 'ask for 8 days or fewer and leave out run with --kinds' \"\$out\""
# Records reaching back half a day: the advice is a window --days accepts, never 0 days.
plant
rm -rf "$P/-Users-x-proj--claude-worktrees-w1"
out="$(CLAUDE_HOME="$H" python3 -B "$TOOL" report --days 3 --kinds run --now "$(( NOW - DAY / 2 ))" 2>&1)"; rc=$?
ok "a kind reaching under a day: advises a window above 0" "[ $rc -eq 3 ] && has 'ask for 0.5 days or fewer' \"\$out\""
plant
out="$(run report)"; rc=$?
ok "no --days: exits 2" "[ $rc -eq 2 ]"
out="$(run report --days inf)"; rc=$?
ok "--days inf: exits 2 with no traceback" "[ $rc -eq 2 ] && ! has 'Traceback' \"\$out\""
out="$(run report --days 1e300)"; rc=$?
ok "--days 1e300: exits 2 with no traceback" "[ $rc -eq 2 ] && ! has 'Traceback' \"\$out\""
out="$(CLAUDE_HOME="$H" python3 -B "$TOOL" report --days 7 --now 1e300 2>&1)"; rc=$?
ok "--now 1e300: exits 2 with no traceback" "[ $rc -eq 2 ] && ! has 'Traceback' \"\$out\""
out="$(run report --days nan)"; rc=$?
ok "--days nan: exits 2 with no traceback" "[ $rc -eq 2 ] && ! has 'Traceback' \"\$out\""
out="$(run report --days 7 --kinds own,everything)"; rc=$?
ok "an unknown kind: exits 2 and names the kinds there are" "[ $rc -eq 2 ] && has 'own, agent, run' \"\$out\""
out="$(run copy --days 7)"; rc=$?
ok "copy without a label: exits 2" "[ $rc -eq 2 ] && [ ! -e '$COPIES' ]"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
