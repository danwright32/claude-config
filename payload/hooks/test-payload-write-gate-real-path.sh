#!/usr/bin/env bash
# Tests for the payload write gate judging a destination by where it REALLY is (claude-config#3537).
#
# The gate judged each destination by its text. Three kinds of text reach a payload file with no
# part of them under payload/: the volume folder with a disk number and a file number, which macOS
# resolves to the file itself, a symbolic link that lives elsewhere, and a hard link, which is a
# second name for the same file. And a link made by a short inline script was not counted as a
# write at all, so the second name could be made and then written through.
#
# Every file here is a stand in under a temporary folder. The watcher is a real process with a
# real command line, for the reason test-payload-write-gate.sh gives (L52).
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/payload-write-gate.sh"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }
not_run(){ # not_run <why>
  echo "test-payload-write-gate-real-path: $1" >&2
  printf 'SUITE-NOT-RUN %s\n' "$1"
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  exit 2
}
[ -f "$HOOK" ] || not_run "needs payload-write-gate.sh beside it"

FIX="$(cd "$(mktemp -d "${TMPDIR:-/tmp}/payload-write-gate-real.XXXXXXXX")" && pwd -P)"
trap 'rm -rf "$FIX"; [ -n "${WPID:-}" ] && kill "$WPID" 2>/dev/null; true' EXIT

# Two clones, as in the sibling suite: the development checkout and the one the daemon runs from.
mkdir -p "$FIX/dev/payload/hooks" "$FIX/src/payload/hooks" "$FIX/elsewhere" "$FIX/links" "$FIX/state"
: > "$FIX/dev/claude-sync"
: > "$FIX/src/claude-sync"
: > "$FIX/dev/payload/LESSONS.md"
: > "$FIX/dev/payload/hooks/x.sh"
: > "$FIX/src/payload/LESSONS.md"
: > "$FIX/elsewhere/a.txt"
: > "$FIX/elsewhere/twice.txt"
git init -q "$FIX/dev" 2>/dev/null
git init -q "$FIX/src" 2>/dev/null
[ -e "$FIX/dev/.git" ] && [ -e "$FIX/src/.git" ] || not_run "the fixture checkouts could not be made git checkouts"

# Second names for those files, all of them outside any payload/ folder.
ln -s "$FIX/dev/payload/hooks/x.sh" "$FIX/links/sym.sh"
ln -s "$FIX/dev/payload/hooks/notyet.sh" "$FIX/links/dangling.sh"
ln -s "$FIX/dev/payload/hooks" "$FIX/links/dirlink"
ln -s "$FIX/src/payload/LESSONS.md" "$FIX/links/sym-src.md"
ln -s "$FIX/elsewhere/a.txt" "$FIX/links/sym-plain.txt"
ln -s "$FIX/links/loop" "$FIX/links/loop"
ln "$FIX/dev/payload/LESSONS.md" "$FIX/links/hard.md"
ln "$FIX/elsewhere/twice.txt" "$FIX/links/twice-again.txt"

HOLD="$FIX/hold"
PIDF="$FIX/watch.pid"
( bash -c 'exec -a "'"$FIX"'/src/claude-sync watch" sleep 300' </dev/null >/dev/null 2>&1 &
  printf '%s\n' "$!" > "$PIDF" ) </dev/null >/dev/null 2>&1
WPID="$(cat "$PIDF" 2>/dev/null)"
for _ in $(seq 1 200); do
  case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in *claude-sync*watch*) break ;; esac
done
case "$(ps -o command= -p "$WPID" 2>/dev/null || true)" in
  *claude-sync*watch*) ;;
  *) not_run "the fixture watcher process could not be started with a readable command line" ;;
esac

RC=0; OUT=""
unset CLAUDE_CODE_SESSION_ID
SID=""
ME="11111111-aaaa-4bbb-8ccc-000000000001"
edit(){ # edit <file path> <cwd>
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Edit", "session_id": sys.argv[3], "cwd": sys.argv[2], "tool_input": {"file_path": sys.argv[1]}}))
' "$1" "$2" "$SID" | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" bash "$HOOK" 2>&1)"; RC=$?
}
runbash(){ # runbash <command> <cwd>
  OUT="$(python3 -c '
import json, sys
print(json.dumps({"tool_name": "Bash", "session_id": sys.argv[3], "cwd": sys.argv[2], "tool_input": {"command": sys.argv[1]}}))
' "$1" "$2" "$SID" | env SYNC_WATCH_PID_FILE="$PIDF" SYNC_HOLD_FILE="$HOLD" PAYLOAD_WRITE_STATE_DIR="$FIX/state" bash "$HOOK" 2>&1)"; RC=$?
}
refused(){ if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, said: ${OUT:0:160}"; fi; }
allowed(){
  if [ "$RC" -eq 0 ] && [ -z "$(printf '%s' "$OUT" | tr -d '[:space:]')" ]; then check "$1" ok
  else check "$1" "exit $RC, said: ${OUT:0:160}"; fi
}
says(){ case "$OUT" in *"$2"*) check "$1" ok ;; *) check "$1" "did not say '$2'" ;; esac; }
unsaid(){ case "$OUT" in *"$2"*) check "$1" "it said '$2'" ;; *) check "$1" ok ;; esac; }

# The fixture is only a fixture if the plain write is refused and a plain write elsewhere is not.
edit "$FIX/dev/payload/hooks/x.sh" "$FIX/dev"
refused "control: the stand in payload file is refused by its own name"
runbash "echo x > $FIX/elsewhere/a.txt" "$FIX/elsewhere"
allowed "control: a write outside any checkout is let through"

echo "real path: a destination written by disk number and file number"

# stat prints the two numbers macOS resolves under its volume folder. On a system with no such
# folder there is nothing to measure, and the cases say so rather than pass.
VOLF=""; VOLD=""; VOLOUT=""
if [ -d /.vol ] && [ "$(uname -s)" = Darwin ]; then
  VOLF="/.vol/$(stat -f '%d/%i' "$FIX/dev/payload/hooks/x.sh" 2>/dev/null)"
  VOLD="/.vol/$(stat -f '%d/%i' "$FIX/dev/payload/hooks" 2>/dev/null)"
  VOLOUT="/.vol/$(stat -f '%d/%i' "$FIX/elsewhere/a.txt" 2>/dev/null)"
  [ -f "$VOLF" ] && [ -d "$VOLD" ] && [ -f "$VOLOUT" ] || VOLF=""
fi
if [ -z "$VOLF" ]; then
  echo "SUITE-PART-UNMEASURED #3537 a destination by disk and file number: this system resolves no /.vol path, so there was none to write to"
else
  runbash "echo x > $VOLF" "$FIX/elsewhere"
  refused "#3537 a redirect to a payload file by its disk and file number is refused"
  says "#3537 and the refusal names the file it really is" "$FIX/dev/payload/hooks/x.sh"
  edit "$VOLF" "$FIX/elsewhere"
  refused "#3537 an Edit of a payload file by its disk and file number is refused"
  runbash "cp $FIX/elsewhere/a.txt $VOLD/new.sh" "$FIX/elsewhere"
  refused "#3537 a copy into a payload folder named by number is refused"
  runbash "python3 -c \"open('$VOLF', 'w').write('x')\"" "$FIX/elsewhere"
  refused "#3537 an inline script opening a payload file by number is refused"
  runbash "python3 -c \"import shutil; shutil.copy('$FIX/elsewhere/a.txt', '$VOLF')\"" "$FIX/elsewhere"
  refused "#3537 an inline script copying onto a payload file by number is refused"
  runbash "echo x > $VOLOUT" "$FIX/elsewhere"
  allowed "#3537 control: a file outside any checkout, by number, is still let through"
fi

echo "real path: a destination that is a link into payload"

runbash "echo x > $FIX/links/sym.sh" "$FIX/elsewhere"
refused "#3537 a redirect to a symbolic link whose file is under payload is refused"
says "#3537 and the refusal names the file it really is" "$FIX/dev/payload/hooks/x.sh"
edit "$FIX/links/sym.sh" "$FIX/elsewhere"
refused "#3537 an Edit of a symbolic link whose file is under payload is refused"
runbash "echo x > $FIX/links/dangling.sh" "$FIX/elsewhere"
refused "#3537 a redirect to a link naming a payload file not made yet is refused"
runbash "echo x > $FIX/links/dirlink/../LESSONS.md" "$FIX/elsewhere"
refused "#3537 a path that climbs out of a linked folder lands under payload and is refused"
runbash "python3 -c \"import shutil; shutil.copy('$FIX/elsewhere/a.txt', '$FIX/links/sym.sh')\"" "$FIX/elsewhere"
refused "#3537 an inline script copying onto such a link is refused"
runbash "echo x > $FIX/links/hard.md" "$FIX/elsewhere"
refused "#3537 a redirect to a second name of a payload file is refused"
says "#3537 saying the file has more than one name" "more than one name"
edit "$FIX/links/hard.md" "$FIX/elsewhere"
refused "#3537 and so is an Edit of that second name"

echo "real path: a different letter case of the folder name"

if [ -e "$FIX/dev/PAYLOAD/HOOKS/X.SH" ]; then
  runbash "python3 -c \"import shutil; shutil.copy('$FIX/elsewhere/a.txt', 'PAYLOAD/hooks/x.sh')\"" "$FIX/dev"
  refused "#3537 an inline script writing to PAYLOAD in capitals is refused"
  runbash "python3 -c \"import shutil; shutil.copy('$FIX/elsewhere/a.txt', '$FIX/DEV/Payload/Hooks/X.SH')\"" "$FIX/elsewhere"
  refused "#3537 and with every folder in another case"
  runbash "echo x > $FIX/dev/PAYLOAD/hooks/x.sh" "$FIX/elsewhere"
  refused "#3537 a redirect to PAYLOAD in capitals is refused"
else
  echo "SUITE-PART-UNMEASURED #3537 a different letter case: this volume tells letter case apart, so PAYLOAD names no payload folder here"
fi
runbash "cp $FIX/elsewhere/a.txt \"\$P/PAYLOAD/LESSONS.md\"" "$FIX/dev"
refused "#3537 a path only the shell can work out that names PAYLOAD in capitals is refused"

echo "real path: a real path that cannot be read is refused, never let through"

runbash "echo x > $FIX/links/loop" "$FIX/elsewhere"
refused "#3537 a destination whose links never end is refused"
says "#3537 saying its real path could not be read" "could not read where"
says "#3537 and naming the destination" "$FIX/links/loop"
edit "$FIX/links/loop" "$FIX/elsewhere"
refused "#3537 and so is an Edit of it"
# The reading itself failing: a python3 that runs everything but the real path step.
STUB="$FIX/stub"; mkdir -p "$STUB"
REALPY="$(command -v python3)"
cat > "$STUB/python3" <<STUBEOF
#!/bin/bash
for a in "\$@"; do case "\$a" in *F_GETPATH*) exit 3 ;; esac; done
exec "$REALPY" "\$@"
STUBEOF
chmod +x "$STUB/python3"
PATH="$STUB:$PATH" runbash "echo x > $FIX/elsewhere/a.txt" "$FIX/elsewhere"
refused "#3537 when the real path step cannot run, a write is refused, not let through"
says "#3537 saying what could not be read" "could not read where"

echo "real path: and nothing else"

runbash "echo x > $FIX/links/sym-plain.txt" "$FIX/elsewhere"
allowed "#3537 control: a link to a file outside any checkout is let through"
runbash "echo x > $FIX/links/sym-src.md" "$FIX/elsewhere"
allowed "#3537 control: a link into the clone the watcher runs from is let through"
runbash "cat $FIX/links/sym.sh 2>/dev/null" "$FIX/elsewhere"
allowed "#3537 control: reading through the link writes nothing"
runbash "echo x > $FIX/elsewhere/new/deeper/out.txt" "$FIX/elsewhere"
allowed "#3537 control: a file in a folder not made yet, outside any checkout, is let through"
# A word longer than any file name can be, as text read for a redirect often is, names no file.
LONG="$(printf 'w%.0s' $(seq 1 300))"
runbash "echo x > $FIX/elsewhere/$LONG" "$FIX/elsewhere"
allowed "#3537 control: a name too long to be any file is not taken for one that cannot be read"
runbash "echo x > $FIX/elsewhere/$LONG/deeper/out.txt" "$FIX/elsewhere"
allowed "#3537 control: nor is a path through such a name"
runbash "echo x > /dev/null" "$FIX/dev"
allowed "#3537 control: a write to the null device is let through"
runbash "python3 -c \"open('$FIX/elsewhere/a.txt', 'w').write('text/plain and ../x and /nowhere/at/all')\"" "$FIX/elsewhere"
allowed "#3537 control: a script whose quoted text only looks like paths is let through"
SID="$ME"
printf '%s %s host session=%s my work\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" "$ME" > "$HOLD"
runbash "echo x > $FIX/links/sym.sh" "$FIX/elsewhere"
allowed "#3537 control: this session's own hold lets the write through the link"
runbash "echo x > $FIX/links/loop" "$FIX/elsewhere"
allowed "#3537 control: and a destination that cannot be read, since nothing can revert it"
runbash "echo x > $FIX/links/hard.md" "$FIX/elsewhere"
allowed "#3537 control: and a second name of a payload file"
rm -f "$HOLD"; SID=""
runbash "echo x > $FIX/links/twice-again.txt" "$FIX/elsewhere"
refused "#3537 a file with two names, neither under payload, is refused: where its other name is cannot be read"
says "#3537 saying so" "more than one name"

echo "links made by an inline script are writes"

link_refused(){ # link_refused <description> <command>
  runbash "$2" "$FIX/dev"
  refused "#3537 $1"
}
link_refused "python os.link of a payload file" "python3 -c \"import os; os.link('payload/LESSONS.md', '$FIX/elsewhere/h1')\""
says "#3537 and the refusal names the payload file" "$FIX/dev/payload/LESSONS.md"
link_refused "python os.symlink of a payload folder" "python3 -c \"import os; os.symlink('payload/hooks', '$FIX/elsewhere/l1')\""
link_refused "pathlib symlink_to" "python3 -c \"from pathlib import Path; Path('$FIX/elsewhere/l2').symlink_to('payload/hooks/x.sh')\""
link_refused "pathlib hardlink_to" "python3 -c \"from pathlib import Path; Path('$FIX/elsewhere/h2').hardlink_to('payload/LESSONS.md')\""
link_refused "perl link with brackets" "perl -e 'link(\"payload/LESSONS.md\", \"$FIX/elsewhere/h3\")'"
link_refused "perl symlink without brackets" "perl -e 'symlink \"payload/hooks\", \"$FIX/elsewhere/l3\"'"
link_refused "ruby File.symlink" "ruby -e 'File.symlink(\"payload/hooks\", \"$FIX/elsewhere/l4\")'"
link_refused "ruby FileUtils.ln_s" "ruby -rfileutils -e 'FileUtils.ln_s \"payload/hooks\", \"$FIX/elsewhere/l5\"'"
link_refused "node symlinkSync" "node -e 'require(\"fs\").symlinkSync(\"payload/hooks\", \"$FIX/elsewhere/l6\")'"
link_refused "node linkSync" "node -e 'require(\"fs\").linkSync(\"payload/LESSONS.md\", \"$FIX/elsewhere/h6\")'"
link_refused "a script that runs ln itself" "python3 -c \"import subprocess; subprocess.run(['ln', '-s', 'payload/hooks', '$FIX/elsewhere/l7'])\""
link_refused "the link command" "link payload/LESSONS.md $FIX/elsewhere/h8"
link_refused "a heredoc script making the link" "python3 - <<'PY'
import os
os.symlink('payload/hooks', '$FIX/elsewhere/l9')
PY"
runbash "python3 -c \"import os; os.symlink('$FIX/links/dirlink', '$FIX/elsewhere/l10')\"" "$FIX/elsewhere"
refused "#3537 a link made to a path that is itself a link into payload"
# Only a link that is MADE. Reading one, or a word that merely holds those letters, writes nothing.
runbash "python3 -c \"import os; print(os.readlink('payload/hooks'))\"" "$FIX/dev"
allowed "#3537 control: reading where a link points is not a write"
runbash "grep -n hyperlink 'payload/LESSONS.md'" "$FIX/dev"
allowed "#3537 control: searching a payload file for a word holding link is not a write"
runbash "perl -ne 'print if /link /' 'payload/LESSONS.md'" "$FIX/dev"
allowed "#3537 control: nor is a perl search for the word"
runbash "grep -n 'see the link (below)' 'payload/LESSONS.md'" "$FIX/dev"
allowed "#3537 control: nor a search for prose that has the word before a bracket"
runbash "python3 -c \"import os; os.symlink('$FIX/elsewhere/a.txt', '$FIX/elsewhere/l11')\"" "$FIX/elsewhere"
allowed "#3537 control: a link between two files outside any checkout is let through"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
