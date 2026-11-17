#!/bin/bash
# tests/area-check-named-texts.mjs reads the scripts the area check lets through by name and says
# which files they source and which program files they run (#3082, #3134). Its count is part of the
# proof behind that let through, so it must never miss a run the shell would make, and it reads
# quoting, so a message only quoting a run is not counted as one. This suite holds both, on fixture
# scripts, each read as its own list (an export of a fixture named.mjs):
#   - Quoted text is no run: a message quoting "(bash tools/x.sh ...)", in double or single quotes,
#     after echo or printf, or in a comment, counts nothing (#3134: #3115's message did, and had to
#     be reworded).
#   - Every spelling the shell runs is counted, or the list is refused as unreadable: after ; && and
#     |, in $(...) and backticks, by eval, sourced with . source or builtin source, inside a function
#     or a subshell, in a heredoc fed to a shell, by a shell's -c, by a variable naming the program or
#     holding the file, run directly by its path, and a shell reading what feeds it. Each runs a file
#     the list lacks, so the reading must name it in a PROBLEM.
#   - A line that reads as a run on its own but as text in the whole script (a line of a quoted
#     message running over several lines) is refused, never skipped.
#   - Each of those is seen to fail (L1): copies of the reader made too lenient, one without the
#     refusal of what cannot be read, one without the line by line second reading, one that also
#     drops what a command substitution runs, each miss the cases that depend on them.
set -u
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$DIR/.." && pwd)"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
finish(){
  echo "passed: $pass, failed: $fail"
  printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
  [ "$fail" -eq 0 ]
  exit $?
}
if ! command -v node >/dev/null 2>&1; then
  echo "FAIL: node is not installed, so the reader could not be run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi
. "$DIR/area-check-named-reader.sh" || {
  echo "FAIL: $(basename "$0"): tests/area-check-named-reader.sh is missing, so nothing was run"
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
named_tmp test-area-check-named-texts
READER="$ROOT/tests/area-check-named-texts.mjs"
COMMANDS="$ROOT/payload/mods/mod-kit/hooks/commands.ts"
FX="$TMP/fx"
mkdir -p "$FX/tools"
: > "$FX/named.mjs"
# A listed library a fixture may source or run, which is then no problem.
printf 'true\n' > "$FX/tools/lib.sh"

# fixture <body> [listed lib]: a fixture script and its list, as the next export. Sets ID.
n=0
fixture(){
  n=$((n + 1)); ID="F$n"
  printf '%s\n' "$1" > "$FX/tools/$ID.sh"
  if [ "${2:-}" = lib ]; then
    printf 'export const %s = { script: "tools/%s.sh", texts: ["tools/%s.sh", "tools/lib.sh"] }\n' "$ID" "$ID" "$ID" >> "$FX/named.mjs"
  else
    printf 'export const %s = { script: "tools/%s.sh", texts: ["tools/%s.sh"] }\n' "$ID" "$ID" "$ID" >> "$FX/named.mjs"
  fi
}
# read_fixture <reader> <id>: what that reader prints for the fixture, in `out`.
read_fixture(){
  out="$(node --experimental-strip-types --no-warnings "$1" "$FX/named.mjs" "$FX" "$2" "$COMMANDS" 2>&1)" || out="EXIT $? $out"
}
fact(){ printf '%s\n' "$out" | sed -n "s/^$1	//p"; }

# ---- Quoted text is no run ----
FREE=()
free(){   # $1 = name  $2 = body: nothing counted, nothing refused
  fixture "$2"; FREE+=("$ID")
  read_fixture "$READER" "$ID"
  [ "$(fact RUNS)" = 0 ] && [ "$(fact LINES)" = 0 ] && [ -z "$(fact PROBLEM)" ] && check "$1 counts nothing" ok \
    || check "$1 counts nothing" "$(printf '%s\n' "$out" | grep -v -e '^SCRIPT' -e '^TEXT' | paste -sd';' -)"
}
free 'a run quoted in a message after a bracket' 'echo "check-mods: no mods (bash tools/check-mods.sh <mods folder>)" >&2'
free 'one in single quotes' "echo 'it ran (python3 tools/x.py)' >&2"
free 'a source quoted for printf' "printf '%s\\n' \"(. tools/lib.sh)\""
free 'a run in a comment after a command' 'true   # (bash tools/x.sh)'
free 'a run in a whole line comment' '# then (bash tools/x.sh) runs'
free 'a quoted run assigned to a variable and printed' "msg='(node tools/x.mjs)'; echo \"\$msg\""
free 'a message in a substitution' 'x="$(echo "(bash tools/x.sh)")"; echo "$x"'
free 'a program given on the command line' "perl -e 'print 1'"

# ---- Every spelling the shell runs is counted or refused ----
HELD=()
held(){   # $1 = name  $2 = body  $3 = what the PROBLEM must say
  fixture "$2"; HELD+=("$ID|$3|$1")
  read_fixture "$READER" "$ID"
  fact PROBLEM | grep -qF -- "$3" && check "$1 is held" ok || check "$1 is held" "no PROBLEM saying $3: $(printf '%s\n' "$out" | paste -sd';' -)"
}
UN='unlisted.sh'
held 'a plain run' 'bash tools/unlisted.sh' "$UN"
held 'a run after ;' 'true; bash tools/unlisted.sh' "$UN"
held 'a run after &&' 'true && bash tools/unlisted.sh' "$UN"
held 'a run fed by |' 'echo x | bash tools/unlisted.sh' "$UN"
held 'a run in $(...)' 'y="$(bash tools/unlisted.sh)"' "$UN"
held 'a run in backticks' 'y=`bash tools/unlisted.sh`' "$UN"
held 'a run in $(...) over several lines' "$(printf 'y="$(\n  bash tools/unlisted.sh\n)"')" "$UN"
held 'a run by eval' 'eval "bash tools/unlisted.sh"' "$UN"
held 'eval of text the shell builds' 'eval "$CMD"' 'cannot read'
held 'a source by .' '. tools/unlisted.sh' "$UN"
held 'a source by source' 'source "$(dirname "$0")/unlisted.sh"' "$UN"
held 'a source by builtin source' 'builtin source tools/unlisted.sh' "$UN"
held 'a run inside a function' "$(printf 'f() {\n  bash tools/unlisted.sh\n}\nf')" "$UN"
held 'a run inside a subshell' '( cd tools && bash unlisted.sh )' "$UN"
held 'a run in a heredoc fed to a shell' "$(printf "bash <<'EOF'\nbash tools/unlisted.sh\nEOF")" "$UN"
held 'a run in a heredoc piped to a shell' "$(printf 'cat <<EOF | bash\nbash tools/unlisted.sh\nEOF')" "$UN"
held "a run in a shell's -c" "bash -c 'bash tools/unlisted.sh'" "$UN"
held 'a variable naming the shell' "$(printf 'CMD=bash\n$CMD tools/unlisted.sh')" 'CMD'
held 'a variable holding the whole run' "$(printf 'RUN="bash tools/unlisted.sh"\n$RUN')" "$UN"
held 'a variable holding the file' "$(printf 'P="$DIR/unlisted.py"\npython3 -I "$P" go')" 'unlisted.py'
held 'a file run directly by its path' './tools/unlisted.sh go' "$UN"
held 'a shell reading what feeds it' 'cat tools/x | bash' 'cannot'
held 'a run by ssh' 'ssh host bash tools/unlisted.sh' 'cannot read'
held 'a line reading as a run in a quoted message over several lines' "$(printf 'msg="first\n(bash tools/unlisted.sh)\nlast"\necho "$msg"')" 'on its own'

# A run of a listed text is counted, where it is, past a message quoting it.
fixture "$(printf 'echo "(bash tools/lib.sh)"\nbash tools/lib.sh\n# bash tools/lib.sh')" lib
read_fixture "$READER" "$ID"
[ "$(fact RUNS)" = 1 ] && [ -z "$(fact PROBLEM)" ] && [ "$(fact RAN)" = "tools/$ID.sh:2 bash tools/lib.sh" ] \
  && check "a run of a listed text is counted once, at the line that runs it" ok \
  || check "a run of a listed text is counted once, at the line that runs it" "$(printf '%s\n' "$out" | paste -sd';' -)"
# A program named by the environment is no text of the checkout, and is said, not counted.
fixture "$(printf 'bin="${SOME_BIN:-}"\n"$bin" --version')"
read_fixture "$READER" "$ID"
[ "$(fact RUNS)" = 0 ] && [ -z "$(fact PROBLEM)" ] && [ "$(fact BYVALUE)" = "tools/$ID.sh:2 \$bin" ] \
  && check "a program named only by the environment is printed as BYVALUE" ok \
  || check "a program named only by the environment is printed as BYVALUE" "$(printf '%s\n' "$out" | paste -sd';' -)"

# ---- Each of those is seen to fail ----
# lenient <name> <sed expression>: a copy of the reader with one part taken out, in LENIENT.
lenient(){
  LENIENT="$TMP/$1.mjs"
  sed "$2" "$READER" > "$LENIENT"
  cmp -s "$READER" "$LENIENT" && { check "the $1 copy differs from the reader" "the sed matched nothing"; return 1; }
  check "the $1 copy differs from the reader" ok
}
# missed_by <copy name> <name of held case>...: each case named is no longer held by the copy.
missed_by(){
  local copy="$1" entry id what name found
  shift
  for name in "$@"; do
    found=no
    for entry in "${HELD[@]}"; do
      id="${entry%%|*}"; what="${entry#*|}"; what="${what%%|*}"
      [ "${entry##*|}" = "$name" ] || continue
      found=yes
      read_fixture "$LENIENT" "$id"
      fact PROBLEM | grep -qF -- "$what" && check "without $copy, $name is missed" "it was still held: $(fact PROBLEM | paste -sd';' -)" \
        || check "without $copy, $name is missed" ok
    done
    [ "$found" = yes ] || check "the control names a case: $name" "no held case is named so"
  done
}
lenient no-refusal 's#if (c.unread) {  // control: no-refusal#if (false) {#' \
  && missed_by 'the refusal of what cannot be read' 'a run by eval' 'eval of text the shell builds' 'a variable naming the shell' 'a variable holding the whole run' 'a run by ssh'
lenient no-second-reading 's#const second = true  // control: no-second-reading#const second = false#' \
  && missed_by 'the line by line second reading' 'a line reading as a run in a quoted message over several lines'
lenient no-substitutions 's#const second = true  // control: no-second-reading#const second = false#; s#commands = pipeline(body)  // control: no-substitutions#commands = pipeline(body).filter(c => !c.substitution)#' \
  && missed_by 'what a substitution runs' 'a run in $(...)' 'a run in backticks' 'a run in $(...) over several lines'
# And with nothing taken out but the second reading, every other held case is still held by the
# quoting reading alone.
lenient only-quoting 's#const second = true  // control: no-second-reading#const second = false#' && {
  for entry in "${HELD[@]}"; do
    id="${entry%%|*}"; what="${entry#*|}"; what="${what%%|*}"; name="${entry##*|}"
    [ "$name" = 'a line reading as a run in a quoted message over several lines' ] && continue
    read_fixture "$LENIENT" "$id"
    fact PROBLEM | grep -qF -- "$what" && check "the quoting reading alone holds $name" ok || check "the quoting reading alone holds $name" "$(printf '%s\n' "$out" | paste -sd';' -)"
  done
}
finish
