#!/usr/bin/env bash
# Tests for the two readings of claude-config#3395: a sourced path built from the script's own $0
# or $1 (lib/script-params.py), and a script made by a sed filter or a git show of one file earlier
# in the same command (lib/exact-output.py). Kept apart from test-slack-drafts-only-gate.sh as
# test-slack-drafts-python-file-runs.sh is, so that suite does not grow past its wall clock; the
# helpers below are copied from that one as they are, so a case here is driven the same way: a hook
# payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr.
# Nothing a case names is ever run by a shell: the files that name a Slack address are only ever
# read by the gate. The one program run on a fixture is this Mac's own sed, on text that names no
# address, to hold the emulation to what sed prints.
#
# Measured on this change's base (0c1d688af8) on 2026-11-22, before it was made: each command
# below that the header of its section calls "newly read" was refused with "a path the gate cannot
# work out" or "is written earlier in this command by sed" (or "by git"), whether the file it
# reaches posts or not. What is held:
#   * each newly read shape is refused where the file it reaches posts, with a refusal that names
#     the post rather than a path or a file the gate could not read, and passes where it does not;
#   * each value is taken only where it is certain: $0 for bash and dash, a sourced file's $0 as
#     its caller's, $1 only from a command line the gate reads whole and only before anything in
#     the script could change it, and what sed prints only for the part of sed emulated exactly on
#     input known exactly; everything else is refused as it was;
#   * a script's $0 and $1 are taken up only where a sourced path of it cannot be worked out
#     without them, so a script the gate passed before is read exactly as it was;
#   * the emulation prints what this Mac's sed prints for every program it accepts;
#   * an error inside either reading refuses the call (seen to fail against a copy of the gate
#     that swallowed the error, on 2026-11-22);
#   * a script read once and found clean is read again when it is handed other words.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/slack-drafts-only-gate.sh"
unset SLACK_GATE_UNWORKED_PATHS

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)" | sed '2,$s/^/  /'; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# Every case runs with a judgement cache of its own, never this Mac's (claude-config#2918).
export SLACK_GATE_CACHE_DIR="$T/gate-cache"
unset SLACK_GATE_CACHE_TRACE

# payload <tool name> <tool_input JSON> [cwd]: one PreToolUse payload in the measured shape.
payload() {
  python3 -c '
import json, sys
tool, inp, cwd = sys.argv[1], json.loads(sys.argv[2]), sys.argv[3]
print(json.dumps({"session_id": "f6017250-8f33-47ac-bbb2-b82a7c319d0d",
                  "transcript_path": "/tmp/transcript.jsonl", "cwd": cwd,
                  "permission_mode": "auto", "hook_event_name": "PreToolUse", "tool_name": tool,
                  "tool_input": inp, "tool_use_id": "toolu_01X4Qw7JnfYswF7UVX94Z4Sy"}))
' "$1" "$2" "${3:-$T}"
}
bash_input() { python3 -c 'import json, sys; print(json.dumps({"command": sys.argv[1], "description": "d"}))' "$1"; }

RC=0; OUT=""; ERR=""
run_raw() { # run_raw <stdin text>
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(printf '%s' "$1" | bash "$HOOK" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_at() { run_raw "$(payload Bash "$(bash_input "$1")" "$2")"; } # run_at <command> <cwd>

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"
FOUND="REFUSED: this command posts to Slack"
UNREAD="the gate could not check whether this command posts to Slack"

G="$T/g3395"
mkdir -p "$G/lib" "$G/sub"
printf '%s\n' "$POST" > "$G/lib/posts.sh"
printf '%s\n' 'echo ok' > "$G/lib/calm.sh"
run() { run_at "$1" "${2:-$G}"; } # run <command> [the folder it runs in]
# posts <what>: the command just judged reached a file that posts, and the refusal says so.
posts() {
  refused "#3395 $1 is refused"
  says "#3395 $1: the refusal is a post found, not a file left unread" "$FOUND"
  says "#3395 $1: and names the send call" "chat.postMessage"
}
# unread <what> [words the refusal holds]: refused as before, as a check that could not be made.
unread() {
  refused "#3395 $1 is still refused"
  says "#3395 $1: as a check that could not be made" "$UNREAD"
  [ -z "${2:-}" ] || says "#3395 $1: for the reason it had" "$2"
}
passes() { allowed "#3395 $1 passes"; }

echo "slack drafts only: a script's own \$0, through a variable, names the folder of a sourced file (claude-config#3395)"
# Newly read: the folder idiom on $0, set in a variable, then a file sourced from that folder.
printf '%s\n' 'D="$(cd "$(dirname "$0")" && pwd)"' '. "$D/lib/posts.sh"' > "$G/zero-cd-posts.sh"
printf '%s\n' 'D="$(cd "$(dirname "$0")" && pwd)"' '. "$D/lib/calm.sh"' > "$G/zero-cd-calm.sh"
printf '%s\n' 'D="$(dirname "$0")"' 'LIB="$D/lib/posts.sh"' '. "$LIB"' > "$G/zero-dir-posts.sh"
printf '%s\n' 'D="$(dirname "$0")"' 'LIB="$D/lib/calm.sh"' '. "$LIB"' > "$G/zero-dir-calm.sh"
printf '%s\n' '#!/bin/sh' 'D="${0%/*}"' '. "$D/lib/posts.sh"' > "$G/zero-cut-posts.sh"
printf '%s\n' '#!/bin/sh' 'D="${0%/*}"' '. "$D/lib/calm.sh"' > "$G/zero-cut-calm.sh"
run "bash zero-cd-posts.sh";      posts "the cd and pwd idiom on \$0, of a file that posts,"
run "bash zero-cd-calm.sh";       passes "the cd and pwd idiom on \$0, of a file that does not post,"
run "bash zero-dir-posts.sh";     posts "dirname of \$0 through two variables, of a file that posts,"
run "bash zero-dir-calm.sh";      passes "dirname of \$0 through two variables, of a file that does not post,"
run "bash $G/zero-cd-posts.sh" "$T"; posts "the idiom in a script run by its whole path from another folder"
run "bash $G/zero-cd-calm.sh" "$T";  passes "its twin that does not post"
run "./zero-cut-posts.sh";        posts "\${0%/*} in a script run by its path under #!/bin/sh"
run "./zero-cut-calm.sh";         passes "its twin that does not post"

# A sourced file's $0 is its caller's in bash, so the idiom there names the CALLER's folder. The
# folder of the file itself holds a file of the same name that does the opposite.
mkdir -p "$G/in-caller/lib" "$G/in-lib/lib"
printf '%s\n' 'H="$(cd "$(dirname "$0")" && pwd)"' '. "$H/same.sh"' > "$G/in-caller/lib/idiom.sh"
cp "$G/in-caller/lib/idiom.sh" "$G/in-lib/lib/idiom.sh"
printf '%s\n' '. lib/idiom.sh' > "$G/in-caller/caller.sh"
cp "$G/in-caller/caller.sh" "$G/in-lib/caller.sh"
printf '%s\n' "$POST" > "$G/in-caller/same.sh";  printf '%s\n' 'echo ok' > "$G/in-caller/lib/same.sh"
printf '%s\n' 'echo ok' > "$G/in-lib/same.sh";   printf '%s\n' "$POST" > "$G/in-lib/lib/same.sh"
run "bash caller.sh" "$G/in-caller"
posts "the idiom on \$0 in a SOURCED file, where the caller's folder holds the file that posts and the file's own a harmless one,"
run "bash caller.sh" "$G/in-lib"
passes "the same where the caller's folder holds the harmless one (bash never reads the other)"
# zsh gives a sourced file its own name as $0, so there the same text reads the OTHER folder: the
# walk is told nothing, and the path stays one the gate cannot work out.
run "zsh caller.sh" "$G/in-lib"
unread "the idiom on \$0 in a file zsh sources, whose own folder holds the file that posts," "a path the gate cannot work out"
run "zsh zero-cd-calm.sh"
unread "the idiom on \$0 in a script zsh runs" "a path the gate cannot work out"
run ". ./zero-cd-calm.sh"
unread "the idiom on \$0 in a file sourced from the command line, whose \$0 is the session's shell," "a path the gate cannot work out"
# The same idiom on BASH_SOURCE names the file's own folder, as it did before this change.
printf '%s\n' 'H="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"' '. "$H/same.sh"' > "$G/in-lib/lib/own.sh"
printf '%s\n' '. lib/own.sh' > "$G/in-lib/caller-own.sh"
run "bash caller-own.sh" "$G/in-lib"
posts "the idiom on BASH_SOURCE in a sourced file, whose own folder holds the file that posts,"

printf '%s\n' 'D="$(dirname "$0")"' 'if [ -n "${ELSEWHERE:-}" ]; then D="$ELSEWHERE"; fi' '. "$D/lib/calm.sh"' > "$G/zero-branch.sh"
run "bash zero-branch.sh"
unread "a variable set from \$0 and set again in a branch" "\$D is not certain there"
printf '%s\n' 'D="$(dirname "$0")"' '. "$D/lib/absent.sh"' > "$G/zero-absent.sh"
printf '%s\n' '. ./lib/absent.sh' > "$G/plain-absent.sh"
run "bash plain-absent.sh"; plain_rc=$RC
run "bash zero-absent.sh"
if [ "$RC" -eq "$plain_rc" ]; then check "#3395 a file that is not there, reached through \$0, is judged as one named plainly is (exit $plain_rc)" ok
else check "#3395 a file that is not there, reached through \$0, is judged as one named plainly is" "exit $RC against $plain_rc: ${ERR:0:300}"; fi

echo "slack drafts only: a script's \$1 is the word the command line hands it (claude-config#3395)"
printf '%s\n' 'set -euo pipefail' '. "$1"' > "$G/one.sh"
printf '%s\n' '# a probe for one library' 'if [ -f "$1/lib/posts.sh" ]; then . "$1/lib/posts.sh"; fi' > "$G/one-under-posts.sh"
printf '%s\n' '# a probe for one library' 'if [ -f "$1/lib/calm.sh" ]; then . "$1/lib/calm.sh"; fi' > "$G/one-under-calm.sh"
printf '%s\n' '#!/usr/bin/env bash' '. "$2"' > "$G/two.sh"
run "bash one.sh lib/posts.sh";             posts "a file sourced as \$1, where the word names a file that posts,"
run "bash one.sh lib/calm.sh";              passes "a file sourced as \$1, where the word names one that does not,"
run "bash one-under-posts.sh .";            posts "a file sourced under \$1, a folder, that posts"
run "bash one-under-calm.sh .";             passes "its twin that does not post"
run "env KEEP=1 bash -eu one.sh lib/posts.sh"; posts "the same behind env, a variable and the shell's -eu"
run "KEEP=1 bash one.sh lib/calm.sh > out.txt 2>&1"; passes "the same with a variable in front and its output sent to a file"
run "./two.sh lib/calm.sh lib/posts.sh";    posts "a script run by its path that sources \$2, a file that posts,"
# A script that sources a word it is handed is taken to run every file it is handed, as before.
run "./two.sh lib/posts.sh lib/calm.sh"
refused "#3395 the same where \$2 does not post and \$1, never sourced, does is still refused, by the rule for a handed file"
# A script found clean with one word is read again with another.
run "bash one.sh lib/calm.sh; bash one.sh lib/posts.sh"
posts "the same script run twice, the second time handed a file that posts,"
mkdir -p "$G/common" "$G/first" "$G/second"
cp "$G/in-caller/lib/idiom.sh" "$G/common/idiom.sh"
printf '%s\n' ". $G/common/idiom.sh" > "$G/first/caller.sh"
cp "$G/first/caller.sh" "$G/second/caller.sh"
printf '%s\n' 'echo ok' > "$G/first/same.sh"; printf '%s\n' "$POST" > "$G/second/same.sh"
run "bash first/caller.sh; bash second/caller.sh"
posts "one sourced file reached from two callers, the second of which has the file that posts beside it,"
run "bash first/caller.sh; bash first/caller.sh"
passes "the same file reached twice from the caller with the harmless one"

# Not certain, so left as it was.
run 'bash one.sh "$NOT_SET_3395/calm.sh"';  unread "a word the gate cannot work out" "a path the gate cannot work out"
run "echo lib/calm.sh | xargs bash one.sh"; unread "a script xargs hands its words" "\$1 is not certain there"
run "find lib -name calm.sh -exec bash one.sh {} \\;"; unread "a script find -exec hands its words"
run "bash -o pipefail one.sh lib/calm.sh";  unread "a shell option that takes a word" "\$1 is not certain there"
printf '%s\n' 'shift' '. "$1"' > "$G/shifted.sh"
run "bash shifted.sh lib/calm.sh lib/posts.sh"; unread "\$1 after a shift" "\$1 is not certain there"
printf '%s\n' 'set -- lib/posts.sh' '. "$1"' > "$G/reset.sh"
run "bash reset.sh lib/calm.sh";            unread "\$1 after a set that gives new words" "\$1 is not certain there"
printf '%s\n' 'go() { . "$1"; }' 'go lib/posts.sh' > "$G/in-function.sh"
run "bash in-function.sh lib/calm.sh";      unread "\$1 inside a function, which is the function's own" "a path the gate cannot work out"
printf '%s\n' 'for turn in 1 2; do' '  . "$1"' '  shift' 'done' > "$G/in-loop.sh"
run "bash in-loop.sh lib/calm.sh lib/posts.sh"; unread "\$1 inside a loop that shifts" "\$1 is not certain there"
printf '%s\n' 'shift' > "$G/lib/shifter.sh"
printf '%s\n' '. lib/shifter.sh' '. "$1"' > "$G/after-source.sh"
run "bash after-source.sh lib/calm.sh lib/posts.sh"; unread "\$1 after a sourced file, which can shift," "\$1 is not certain there"
printf '%s\n' 'eval "$PREPARE"' '. "$1"' > "$G/after-eval.sh"
run "bash after-eval.sh lib/calm.sh";       unread "\$1 after an eval" "a path the gate cannot work out"
printf '%s\n' '. "$1"' > "$G/lib/takes-one.sh"
printf '%s\n' '. lib/takes-one.sh' > "$G/passes-on.sh"
run "bash passes-on.sh lib/calm.sh";        unread "\$1 in a sourced file, which shares its caller's," "\$1 is not certain there"
printf '%s\n' 'L="$1"' '. "$L"' > "$G/through-variable.sh"
run "bash through-variable.sh lib/calm.sh"; passes "\$1 through a variable, of a file that does not post,"
run "bash through-variable.sh lib/posts.sh"; posts "\$1 through a variable, of a file that posts,"
printf '%s\n' 'shift' 'L="$1"' '. "$L"' > "$G/shift-then-variable.sh"
run "bash shift-then-variable.sh lib/calm.sh lib/posts.sh"; unread "\$1 through a variable set after a shift" "\$L is not certain there"
printf '%s\n' "eval 'shift; . \"\$1\"'" > "$G/eval-shift.sh"
run "bash eval-shift.sh lib/calm.sh lib/posts.sh"; refused "#3395 an eval that shifts and then sources \$1 is still refused"
printf '%s\n' 'case "$MODE" in' '  a) shift; L="$1" ;;' '  *) L="$1" ;;' 'esac' '. "$L"' > "$G/case-shift.sh"
run "bash case-shift.sh lib/calm.sh lib/posts.sh"; refused "#3395 a case whose branch shifts before it reads \$1 is still refused"

echo "slack drafts only: a script's \$0 and \$1 are taken up only where a sourced path needs them (claude-config#3395)"
# Seen to fail on 2026-11-22 against the first form of this change, which gave every command of a
# script its $1 and every variable its $0: each of the three scripts below passes on the base
# (0c1d688af8), since the word it hands on is one the gate does not work out, and was refused there
# as a script handed a file that names the send call. A script with no sourced path the gate
# cannot work out is read exactly as it was.
printf '%s\n' '{"url": "https://slack.com/api/chat.postMessage", "text": "hi"}' > "$G/msg.json"
WRITES="node -e 'require(\"fs\").writeFileSync(process.argv[1] + \".bak\", \"1\")'"
printf '%s\n' '#!/bin/bash' 'F="$1"' "$WRITES \"\$F\"" > "$G/var-writes.sh"
printf '%s\n' '#!/bin/bash' 'D="$(dirname "$0")"' "$WRITES \"\$D/msg.json\"" > "$G/zero-var-writes.sh"
printf '%s\n' '#!/bin/bash' 'F="$1"' '. lib/calm.sh' "$WRITES \"\$F\"" > "$G/var-writes-sources.sh"
run "bash var-writes.sh msg.json";          passes "a script that hands on its \$1 through a variable, as on the base,"
run "bash zero-var-writes.sh";              passes "a script that hands on a path under its \$0 through a variable, as on the base,"
run "bash var-writes-sources.sh msg.json";  passes "the same beside a sourced path the gate already worked out"
# Where a sourced path does need them, the base refused the script unread, so reading the rest of it
# with them refuses nothing the base passed: the word handed on is then the file it names.
printf '%s\n' '#!/bin/bash' 'D="$(dirname "$0")"' '. "$D/lib/calm.sh"' "$WRITES \"\$D/msg.json\"" > "$G/zero-sources-writes.sh"
run "bash zero-sources-writes.sh"
refused "#3395 a script whose sourced path needs its \$0, and which hands a file that names the send call to code that can write, is refused"
says "#3395 that refusal names the file handed, read with the script's \$0" "msg.json, which names chat.postMessage"
# A script run inside another command of the same line is read with its own words, never the
# outer command's (both were refused on the first form too, measured 2026-11-22).
run 'bash one.sh lib/calm.sh "$(bash one.sh lib/posts.sh)"'
refused "#3395 a script run inside a substitution of a command that runs it with a harmless word is refused"
run 'bash one.sh lib/calm.sh <(bash one.sh lib/posts.sh)'
refused "#3395 the same inside a process substitution is refused"
run "bash one.sh lib/calm.sh; bash -c 'bash one.sh lib/posts.sh'"
refused "#3395 the same inside a string another shell is handed is refused"
# A script found clean with the words one command hands it is read again where its words are not
# certain, and refused unread there.
run "bash one.sh lib/calm.sh; echo lib/posts.sh | xargs bash one.sh"
unread "a script found clean with one word, then handed words by xargs," "\$1 is not certain there"
run "bash one.sh lib/calm.sh; bash one.sh lib/calm.sh"; passes "the same script run twice with the harmless word"

echo "slack drafts only: a script made by a sed filter earlier in the command is read as sed leaves it (claude-config#3395)"
printf '%s\n' 'echo start' '# bash lib/posts.sh' 'echo end' > "$G/commented-posts.sh"
printf '%s\n' 'echo start' '# bash lib/calm.sh' 'echo end' > "$G/commented-calm.sh"
printf '%s\n' "cat > /dev/null <<'EOF'" 'bash lib/posts.sh' 'EOF' > "$G/heredoc-posts.sh"
printf '%s\n' "cat > /dev/null <<'EOF'" 'bash lib/calm.sh' 'EOF' > "$G/heredoc-calm.sh"
run "bash commented-posts.sh"; passes "(control) a script whose only mention of the file that posts is a comment"
run "bash heredoc-posts.sh";   passes "(control) a script whose only mention of it is text in a heredoc"
run "sed 's/ok/fine/' lib/calm.sh > made.sh; bash made.sh"
passes "a copy with one word changed, of a file that does not post,"
run "sed 's/hi/ho/' lib/posts.sh > made.sh; bash made.sh"
posts "a copy with one word changed, of a file that posts,"
run "sed 's|^echo ok\$|bash lib/posts.sh|' lib/calm.sh > made.sh; bash made.sh"
posts "a sed that INSERTS a line running a script that posts"
run "sed 's|^echo ok\$|bash lib/calm.sh|' lib/calm.sh > made.sh; bash made.sh"
passes "its twin that inserts a line running one that does not"
run "sed 's/^# //' commented-posts.sh > made.sh; bash made.sh"
posts "a sed that UNCOMMENTS a line running a script that posts"
run "sed 's/^# //' commented-calm.sh > made.sh; bash made.sh"
passes "its twin that uncomments one that does not"
run "sed '1d;\$d' heredoc-posts.sh > made.sh; bash made.sh"
posts "a sed that deletes the lines around a heredoc's text, leaving it as a command,"
run "sed '1d;\$d' heredoc-calm.sh > made.sh; bash made.sh"
passes "its twin"
run "sed -n '2p' heredoc-posts.sh > made.sh; bash made.sh"
posts "a sed -n that prints only the line that runs the script that posts"
run "sed -n -e '1p' -e '3p' commented-posts.sh > made.sh; bash made.sh"
passes "a sed -n that prints only the lines beside the comment"
run "sed -n '/^cat/,/^EOF\$/p' heredoc-posts.sh | sed '1d;\$d' > made.sh; bash made.sh"
posts "a part cut out by one sed and trimmed by a second through a pipe"
run "sed -n '/^cat/,/^EOF\$/p' heredoc-calm.sh | sed '1d;\$d' > made.sh; bash made.sh"
passes "its twin"
run "sed -E -e 's/(start|end)\$/done/' -e '/^# /d' commented-posts.sh > made.sh; bash made.sh"
passes "an extended expression and a delete that removes the comment"
run "cat commented-posts.sh | sed 's/^# //' > made.sh; bash made.sh"
posts "a sed fed the file by cat through a pipe"
run "sed 's/^# //' < commented-posts.sh > made.sh; bash made.sh"
posts "a sed fed the file on its input"
run "printf '%s\\n' 'echo start' '# bash lib/posts.sh' | sed 's/^# //' > made.sh; bash made.sh"
posts "a sed fed text the command writes out"

# What happens to the file after, by the gate's readings of a written file as they were.
run "sed 's/ok/fine/' lib/calm.sh > made.sh; sed 's/hi/ho/' lib/posts.sh > made.sh; bash made.sh"
posts "the same file written twice, the second time from a file that posts,"
run "sed 's/ok/fine/' lib/calm.sh > made.sh; date > made.sh; bash made.sh"
unread "a file sed wrote and a later command replaced with text the gate cannot read" "written earlier in this command by date"
run "cat > made.sh <<'EOF'
echo start
EOF
date >> made.sh; bash made.sh"
unread "a heredoc then added to by a command the gate cannot read" "written earlier in this command by date"
run "printf 'echo start\\n' > made.sh; sed 's/hi/ho/' lib/posts.sh >> made.sh; bash made.sh"
posts "a file written out and then added to by a sed of a file that posts"
ln -s real.sh "$G/link.sh"
run "sed 's/hi/ho/' lib/posts.sh > link.sh; bash real.sh"
posts "a sed that writes through a symbolic link, the file it points at then run,"
run "sed 's/hi/ho/' lib/posts.sh > sub/../made.sh; bash made.sh"
posts "a sed that writes by a path through .., the file then run by its plain name,"

# Outside what is emulated exactly, or input not known exactly: refused as before.
by_sed="written earlier in this command by sed"
run "sed 's/ok/fine\\nmore/' lib/calm.sh > made.sh; bash made.sh";   unread "a backslash and a letter, which the two seds read differently," "$by_sed"
run "sed 's/\\(o\\)k/\\1/' lib/calm.sh > made.sh; bash made.sh";     unread "a back reference" "$by_sed"
run "sed 'y/o/a/' lib/calm.sh > made.sh; bash made.sh";              unread "a command other than p, d and s" "$by_sed"
run "sed '1!G;h;\$!d' lib/calm.sh > made.sh; bash made.sh";          unread "a program that keeps lines aside" "$by_sed"
run "sed 's/x*/-/' lib/calm.sh > made.sh; bash made.sh";             unread "a match of no characters" "$by_sed"
run "sed 's/[[:space:]]ok/ fine/' lib/calm.sh > made.sh; bash made.sh"; unread "a class name" "$by_sed"
run "sed -f prog.sed lib/calm.sh > made.sh; bash made.sh";           unread "a program in a file" "$by_sed"
run "sed \"\$PROGRAM_3395\" lib/calm.sh > made.sh; bash made.sh";    unread "a program the gate cannot work out" "by sed"
run "sed '1,2p;1d;1,2p' lib/calm.sh > made.sh; bash made.sh";        unread "a range ending at a line number after a d" "$by_sed"
run "LC_ALL=C sed 's/ok/fine/' lib/calm.sh > made.sh; bash made.sh"; unread "a sed with a variable set in front of it" "$by_sed"
# sed takes the backslash off an escaped delimiter BEFORE it reads the expression (measured on this
# Mac's sed, 2026-11-22: `printf '# go\nx\n' | sed -E 's|^# \|x||'` prints "go" and an empty line).
# So under -E an escaped bar, with the bar as the delimiter, is alternation, and this sed uncomments
# the line that runs the script that posts. The emulation read a literal bar there, left the
# comment in place, and the made script passed.
run "sed -E 's|^# \\|x||' commented-posts.sh > made.sh; bash made.sh"
unread "under -E an escaped bar as the delimiter, which sed reads as alternation and so uncomments the line," "$by_sed"
run "sed 's|^# \\|x||' commented-posts.sh > made.sh; bash made.sh"
unread "the same without -E" "$by_sed"
run "sed() { cat lib/posts.sh; }; sed 's/ok/fine/' lib/calm.sh > made.sh; bash made.sh"
refused "#3395 a function named sed, which is not the program, is still refused"
# Whether a text holds a function or an alias of that name is worked out once for each text and
# name (searching the text again for every sed and git command cost about 0.4 s of the 6 s it took
# to judge bash tests/test-claude-sync.sh, measured 2026-11-22). So: the answer for one script is
# never another's, a caller's function still counts in a file it sources, and an alias still
# counts. The three refusals below, and the one above, were each seen to fail on 2026-11-22
# against the first form of that change: its method shared a name with one lib/data-names.py
# already had, so the question was answered no for every text and each command was allowed.
printf '%s\n' "sed 's/ok/fine/' lib/calm.sh > made-a.sh" 'bash made-a.sh' > "$G/plain-filter.sh"
printf '%s\n' 'sed() { cat lib/posts.sh; }' "sed 's/ok/fine/' lib/calm.sh > made-b.sh" 'bash made-b.sh' > "$G/own-sed.sh"
printf '%s\n' "sed 's/ok/fine/' lib/calm.sh > made-c.sh" 'bash made-c.sh' > "$G/uses-sed.sh"
run "bash plain-filter.sh";                 passes "a script whose sed filter makes a harmless script and runs it"
run "bash plain-filter.sh; bash own-sed.sh"
refused "#3395 that script, then one that makes sed a function of its own before the same filter, is refused"
run ". ./uses-sed.sh";                      passes "a sourced file whose sed filter makes a harmless script and runs it"
run "sed() { cat lib/posts.sh; }; . ./uses-sed.sh"
refused "#3395 the same file sourced after its caller made sed a function is refused"
run "shopt -s expand_aliases; alias sed='cat lib/posts.sh'; sed 's/ok/fine/' lib/calm.sh > made.sh; bash made.sh"
refused "#3395 an alias named sed, which is not the program, is still refused"
printf 'echo ok' > "$G/no-newline.sh"
run "sed 's/ok/fine/' no-newline.sh > made.sh; bash made.sh";        unread "input whose last line has no newline" "$by_sed"
printf 'echo caf\303\251\n' > "$G/accent.sh"
run "sed 's/caf/tea/' accent.sh > made.sh; bash made.sh";            unread "input outside ASCII" "$by_sed"
run "date > in.sh; sed 's/ok/fine/' in.sh > made.sh; bash made.sh";  unread "input an earlier command wrote with text the gate cannot read" "written earlier in this command"
run "awk 'NR < 3' lib/calm.sh > made.sh; bash made.sh";              unread "awk, which is not read," "written earlier in this command by awk"
run "{ sed 's/ok/fine/' lib/calm.sh; } > made.sh; bash made.sh";     unread "a group's output, which is not read," "written earlier in this command"

echo "slack drafts only: the emulation prints what this Mac's sed prints (claude-config#3395)"
printf '%s\n' 'echo start' '# bash lib/x.sh' '. "$(cd "$(dirname "$0")" && pwd)/lib/y.sh" || {' '  DIR=/a/b.c  # x*y' \
  'foo bar baz' 'aaa bbb aaa' '' 'check_eq "a|b" "0" "$rc"' 'cat > "$T/u.py" <<PY' 'x = [1, 2]' 'PY' 'has_code = bool(X.search(p))' \
  'range(60000)' 'tail' > "$G/input.txt"
cat > "$T/emulate.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True  # the library is loaded by its path: leave no __pycache__ beside it
spec = importlib.util.spec_from_file_location("exact_output", sys.argv[1])
lib = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lib)
if sys.argv[2] == "--escaped-delims":
    # regex() itself, asked about every delimiter: sed takes the backslash off an escaped delimiter
    # first, so one that means something in an expression is never the literal character.
    wrong = []
    for ere in (False, True):
        for d in ".*[]^$(){}+?|":
            try:
                lib.regex("a\\" + d + "b", ere, d)
                wrong.append("read%s:%s" % (" -E" if ere else "", d))
            except lib.Outside:
                pass
        for d in "/#,:@%!~=":
            try:
                lib.regex("a\\" + d + "b", ere, d)
            except lib.Outside:
                wrong.append("not read%s:%s" % (" -E" if ere else "", d))
    sys.stdout.write(" ".join(wrong) or "none")
    sys.exit(0)
plan = lib.sed_plan(sys.argv[3:])
out = None if plan is None else lib.sed_apply(plan[0], plan[1], open(sys.argv[2]).read())
sys.stdout.write("NOT-READ\n" if out is None else out)
PY
same=0; differ=0; outside=0
same_as_sed() { # same_as_sed <sed's words...>: where the emulation reads the program, it prints what sed does
  local got want
  got="$(python3 -B "$T/emulate.py" "$DIR/lib/exact-output.py" "$G/input.txt" "$@" 2>&1)"
  if [ "$got" = "NOT-READ" ]; then outside=$((outside + 1)); return; fi
  want="$(sed "$@" "$G/input.txt" 2>&1)"
  if [ "$got" = "$want" ]; then same=$((same + 1)); else differ=$((differ + 1)); echo "  differs from sed: $*"; fi
}
if [ -f "$DIR/lib/exact-output.py" ] && [ "$(printf 'a\n' | sed 's/a/b/' 2>/dev/null)" = "b" ]; then
  for p in 's/a/b/' 's/a/b/g' 's/a*b/X/' 's/a*b/X/g' 's/aa*/<&>/g' 's/^# //' 's/ *$//' 's/b.z/&&/' 's/[abc][abc]*/Q/g' \
           's/[^ ]* //' 's/[^ ]* //g' 's/\(a\)\(b\)*a/Z/' 's/a\{2,3\}/T/g' 's|^DIR=.*|DIR=/tmp/x|' 's#range(60000)#range(int(n))#' \
           's/"\$rc"/"\$?"/' 's/\. "\$(cd/true # /' 's/x\*y/star/' 's/b\.c/dot/' 's/a|b/pipe/' 's,/a/b,\,&\\,' 's/aaa/x\&y/' \
           's/^$/EMPTY/' 's/^\(foo\) /[&]/' 's/start/&/p' '1d' '$d' '1d;$d' '2,4d' '/^cat/,/^PY$/d' '/foo/!d' '$!d' '3,$d' \
           '/^#/d;s/a/A/g' 's/a/A/;s/A/aa/g;2d' '/aaa/s/b*$/!/' '2,/^foo/s/a/@/g' '/x =/,$d' '5p' 's/ba[rz]/R/gp'; do
    same_as_sed "$p"
  done
  for p in '2,4p' '/^cat/,/^PY$/p' '1p;$p' '/a/p' '$p' '1,/^foo/p' 's/a/b/p' '/^cat/,/^PY$/!p' '3!p' '2,2p' '4,2p' '/foo/,3p'; do
    same_as_sed -n "$p"
  done
  for p in 's/(foo|bar) +/X/g' 's/a+/P/g' 's/(ab*)+a/M/' 's/ba(r|z)$/E/' 's/[0-9]+/N/g' 's/a{2}/D/g' 's/\(X\.search\)/call/' \
           's/(hang_wait|window_wait) .*$/true/' 's/^(echo|tail)$/[&]/' 's/b?a/O/g' 's/ (bar|baz)/-/'; do
    same_as_sed -E "$p"
  done
  same_as_sed -n -e '1,3p' -e '8,9p'
  same_as_sed -e 's/a/b/' -e '2d'
  same_as_sed -n -E '/^(foo|aaa)/p'
  for p in 's/a/\n/' 's/\(a\)/\1/' 's/a\+/x/' 's/\<a/x/' 's/x*/-/g' 'y/a/b/' '2q' 'N;P;D' 's/a/b/2' 's/a/b/I' '0,/a/d' '2~2d' \
           '/a/I p' 's/[[:alpha:]]/x/' 's/[\n]/x/' 's/a^b/x/' 's/a$b/x/' 's.a.b.' '2,+1d' 's/a/b/w out' 'a\' '1{p}' '='; do
    before=$outside
    same_as_sed "$p"
    [ "$outside" -gt "$before" ] || { differ=$((differ + 1)); echo "  read, though the two seds differ on it or it is not emulated: $p"; }
  done
  # An escaped delimiter that means something in an expression: sed reads the bare character.
  for p in 's|^# \|x||' 's|a\|b|X|g' 's|(foo\|aaa) |Y|'; do
    for e in -E -e; do
      before=$outside
      same_as_sed "$e" "$p"
      [ "$outside" -gt "$before" ] || { differ=$((differ + 1)); echo "  read, though its escaped delimiter is special to sed: $e $p"; }
    done
  done
  got="$(python3 -B "$T/emulate.py" "$DIR/lib/exact-output.py" --escaped-delims 2>&1)"
  if [ "$got" = "none" ]; then check "#3395 an escaped delimiter that means something in an expression is never read, with -E or without, and the plain ones still are" ok
  else check "#3395 an escaped delimiter that means something in an expression is never read" "$got"; fi
  if [ "$differ" -eq 0 ] && [ "$same" -ge 60 ]; then check "#3395 the emulation prints what sed prints for each of $same programs, and reads none of $outside it must not" ok
  else check "#3395 the emulation prints what sed prints" "$same the same, $differ wrong, $outside not read"; fi
else
  # UNMEASURED, not a pass: there is no library yet, or no sed that answers as sed does (L411).
  check "#3395 the emulation prints what sed prints" "UNMEASURED: no lib/exact-output.py beside the suite, or no working sed on this Mac"
fi

echo "slack drafts only: a file as a commit holds it, written by git show and then run (claude-config#3395)"
R="$T/repo3395"
mkdir -p "$R"
if git -C "$R" init -q 2>/dev/null && cp "$G/lib/posts.sh" "$G/lib/calm.sh" "$R/" && git -C "$R" add posts.sh calm.sh \
   && git -C "$R" -c user.name=suite -c user.email=suite@example.invalid commit -q -m first; then
  SHA="$(git -C "$R" rev-parse HEAD)"
  printf '%s\n' "$POST" > "$R/calm.sh"   # on disk it posts now; the commit's copy does not
  by_git="written earlier in this command by git"
  run "git show $SHA:calm.sh > old.sh; bash old.sh" "$R"
  passes "git show of a commit's file that does not post, whatever the file on disk holds now,"
  run "git show $SHA:posts.sh > old.sh; bash old.sh" "$R"
  posts "git show of a commit's file that posts"
  run "git -C $R show ${SHA:0:9}:calm.sh > old.sh; bash old.sh"
  passes "the same by -C and a short object name"
  run "git --no-pager -C $R cat-file -p $SHA:posts.sh > old.sh; bash old.sh"
  posts "git cat-file -p of a commit's file that posts"
  run "git -C $R cat-file blob $SHA:calm.sh > old.sh; bash old.sh"
  passes "git cat-file blob of one that does not"
  run "git show HEAD:calm.sh > old.sh; bash old.sh" "$R"
  unread "git show of HEAD, which an earlier command can move," "$by_git"
  git -C "$R" branch "${SHA:0:8}" 2>/dev/null
  run "git show ${SHA:0:8}:calm.sh > old.sh; bash old.sh" "$R"
  unread "git show of a branch whose name is hex" "$by_git"
  run "git show --textconv $SHA:calm.sh > old.sh; bash old.sh" "$R"
  unread "git show with an option" "$by_git"
  run "git show $SHA:calm.sh $SHA:posts.sh > old.sh; bash old.sh" "$R"
  unread "git show of two files" "$by_git"
  run "GIT_DIR=$T/elsewhere git show $SHA:calm.sh > old.sh; bash old.sh" "$R"
  unread "git show with GIT_DIR set in front of it" "$by_git"
  run "export GIT_DIR=$T/elsewhere; git show $SHA:calm.sh > old.sh; bash old.sh" "$R"
  refused "#3395 git show after GIT_DIR is exported is still refused"
  run "git show $SHA:absent.sh > old.sh; bash old.sh" "$R"
  unread "git show of a file the commit does not hold" "$by_git"
else
  check "#3395 git show of a commit's file" "UNMEASURED: git could not make a repository under $T"
fi

echo "slack drafts only: an error inside either reading refuses the call (claude-config#3395)"
# A copy of the gate whose two readings raise when the command holds a marker word. A reading that
# caught its own errors would let such a call through as one it had nothing to say about.
mkdir -p "$T/failing"
cp "$HOOK" "$T/failing/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$T/failing/lib"
cat > "$T/failing/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gate", os.environ["REAL_GATE_3395"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
real_output, real_params = gate.Judge.exact_output, gate.Judge.script_params
def failing_output(self, name, vals, *a, **k):
    if any(v and "FAILS-3395" in v for v in vals):
        raise RuntimeError("made to fail by the suite")
    return real_output(self, name, vals, *a, **k)
def failing_params(self, word, *a, **k):
    if "FAILS-3395" in word:
        raise RuntimeError("made to fail by the suite")
    return real_params(self, word, *a, **k)
gate.Judge.exact_output, gate.Judge.script_params = failing_output, failing_params
gate.main()
PY
run_failing() { # run_failing <command>: judged by the copy whose readings fail on FAILS-3395
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$1")" "$G" | REAL_GATE_3395="$DIR/slack_drafts_only_gate.py" bash "$T/failing/slack-drafts-only-gate.sh" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
cp "$G/one.sh" "$G/FAILS-3395.sh"
run_failing "sed 's/ok/fine/' lib/calm.sh > made.txt"
allowed "#3395 the copy made to fail judges a sed filter as the gate does where nothing fails"
run_failing "sed 's/hi/ho/' lib/posts.sh > made.sh; bash made.sh"
refused "#3395 and refuses a file that posts as the gate does"
run_failing "sed 's/ok/FAILS-3395/' lib/calm.sh > made.txt"
refused "#3395 a reading of what sed prints that fails part way is refused, not taken as nothing to read"
says "#3395 and that refusal says the call could not be judged" "could not judge"
run_failing "bash one.sh lib/calm.sh"
allowed "#3395 the copy reads a script's words as the gate does where nothing fails"
run_failing "bash FAILS-3395.sh lib/calm.sh"
refused "#3395 a reading of a script's words that fails is refused"
says "#3395 and that refusal says the call could not be judged" "could not judge"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
