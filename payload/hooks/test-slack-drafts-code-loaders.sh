#!/usr/bin/env bash
# Tests for lib/code-loaders.py, the Slack drafts gate's reading of code a command loads without
# naming it as a script (claude-config#2912, #2977, #2978): a PHP include, the modules NODE_OPTIONS
# names, a name perl's <> runs as a command, a file with a NUL in its first line run by zsh or dash.
# Also the perl safe list's %SIG and sort by name, and lib/program-writes.py's raw_path and
# raw_unchanged (#2912). Every other judgement of the gate is in test-slack-drafts-only-gate.sh,
# whose helpers below are copied as they are, so a case here is driven the same way: a hook payload
# piped into slack-drafts-only-gate.sh, exit 0 allowed and 2 refused, the reason on stderr.
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
# The gate's switched off refusal of a file run by a path it cannot work out (#2683) is switched on
# only where run_ur asks for it, never by whatever the caller's environment holds. A file sourced by
# one is refused either way (#2538).
unset SLACK_GATE_UNWORKED_PATHS
NUDGE="$(cd "$DIR/.." && pwd)/skills/nudge/nudge.py"

pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

if [ ! -f "$HOOK" ]; then
  echo "FAIL: there is no slack-drafts-only-gate.sh beside this suite at $DIR, so no Slack send is refused."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
fi

T="$(mktemp -d "${TMPDIR:-/tmp}/slack-gate.XXXXXXXX")" || exit 1
case "${T%/}" in ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$T'" >&2; exit 2 ;; esac
trap 'rm -rf "$T"' EXIT
# The gate keeps the judgements it allowed in a cache (claude-config#2918). Every case in this suite
# runs with one of its own, so the cache is in front of every judgement below, and none of them reads
# or writes the cache in this Mac's ~/.claude/state. The cost checks each start from an empty one, so
# they measure a cold judgement.
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
run_tool() { run_raw "$(payload "$1" "$2")"; }
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }
read_refused() {
  refused "$1"
  case "$ERR" in
    *"could not judge"*|*Traceback*) check "$1 (judged, not a crash)" "the gate crashed: ${ERR:0:300}" ;;
    *) check "$1 (judged, not a crash)" ok ;;
  esac
}
POST="curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage"

echo "slack drafts only: a PHP include is followed as an import is (claude-config#2978)"

# Measured 2026-11-14: with post.php naming an endpoint, `php -r 'include "post.php";'` and the same
# with -i in front passed, so PHP code reached a posting file the gate never read. Each include,
# include_once, require and require_once of a literal path in code given by -r, -B, -R or -E, or in a
# PHP script, is now followed as a JavaScript or Python import is, and one whose path is not a
# literal is refused. PHP looks for a bare name on its include path ("." first), then in the
# including script's own folder; ./ and ../ are from the folder it runs in.
P8="$T/p2978"
mkdir -p "$P8/sub" "$P8/q"
printf '%s\n' '<?php file_get_contents("https://slack.com/api/chat.postMessage");' > "$P8/post.php"
printf '%s\n' '<?php echo "hi";' > "$P8/quiet.php"
printf '%s\n' '<?php include "post.php";' > "$P8/run.php"
printf '%s\n' '<?php include "quiet.php"; ?>' '<p>include the header here, then require login</p>' > "$P8/runq.php"
printf '%s\n' '<?php include_once "mid.php";' > "$P8/chain.php"
printf '%s\n' '<?php require "post.php";' > "$P8/mid.php"
printf '%s\n' '<?php include "near.php";' > "$P8/sub/own.php"
printf '%s\n' '<?php include "./near.php";' > "$P8/sub/dot.php"
cp "$P8/post.php" "$P8/sub/near.php"
printf '%s\n' '#!/usr/bin/env php' '<?php include "post.php";' > "$P8/runx"
run_p8() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$P8}")"; }
run_p8 "php -r 'include \"quiet.php\";'"
allowed "#2978 the control: code including a file that names no endpoint passes"
run_p8 "php -r 'include \"post.php\";'"
read_refused "#2978 php -r code including a file that posts is refused"
says "#2978 and the refusal names the file it includes" "post.php"
run_p8 "php -i -r 'include \"post.php\";'"
read_refused "#2978 the same with -i in front, which takes no value, is refused"
for kw in include include_once require require_once; do
  run_p8 "php -r '$kw(\"post.php\");'"
  read_refused "#2978 $kw of a file that posts, its path in brackets, is refused"
done
run_p8 "php -r \"require 'post.php';\""
read_refused "#2978 a path in single quotes is followed too"
run_p8 "php -B 'echo 1;' -R 'include \"post.php\";'"
read_refused "#2978 code given by a second option (-R after -B) is followed too"
run_p8 "php -E 'include \"post.php\";'"
read_refused "#2978 code given by -E is followed"
run_p8 "php -r 'include \$f;'"
read_refused "#2978 an include whose path is not a literal is refused"
says "#2978 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
run_p8 "php -r 'include \"dir/\" . \$f;'"
read_refused "#2978 an include of a path built from a variable is refused"
run_p8 "php -r 'include \"missing.php\";'"
read_refused "#2978 an include of a file that is not there is refused"
run_p8 "php -r 'echo \"include post.php\"; /* require post.php */ // include post.php'"
allowed "#2978 the words include and require inside a string or a comment are not an include"
run_p8 "php run.php"
read_refused "#2978 a PHP script including a file that posts is refused"
run_p8 "php runq.php"
allowed "#2978 a PHP script including a quiet file passes, the words in its page text are not code"
run_p8 "php chain.php"
read_refused "#2978 an include reached through another include is followed"
says "#2978 and the refusal names the file reached" "post.php"
run_p8 "php sub/own.php"
read_refused "#2978 a bare name is looked for in the including script's own folder too"
# ./ is from the folder php runs in alone: with a quiet near.php there, sub/dot.php reaches it and
# never the posting sub/near.php beside it, while a bare name is still looked for in both places.
printf '%s\n' '<?php echo "near";' > "$P8/near.php"
run_p8 "php sub/dot.php"
allowed "#2978 an include starting ./ is from the folder php runs in, not the including script's"
run_p8 "php sub/own.php"
read_refused "#2978 a bare name is still looked for in the including script's folder with a quiet one in ."
# A heredoc's text is not code: an apostrophe in it must not open a string that hides what follows.
printf '%s\n' '<?php echo <<<EOT' "don't" 'EOT;' 'include "post.php";' > "$P8/here.php"
run_p8 "php here.php"
read_refused "#2978 an include after a heredoc whose text holds a quote is followed"
# The heredoc ends at its closing label, and the code then goes on as before: a ?> after it ends the
# code, so the page text past it is not read as an include. A nowdoc's text is never code.
printf '%s\n' '<?php echo <<<EOT' 'hi' 'EOT;' '?>' '<p>include the header here, then require login</p>' > "$P8/herepage.php"
run_p8 "php herepage.php"
allowed "#2978 page text after a heredoc and a ?> is not read as code"
printf '%s\n' "<?php echo <<<'EOT'" 'include $f;' 'EOT;' 'include "quiet.php";' > "$P8/nowdoc.php"
run_p8 "php nowdoc.php"
allowed "#2978 the text of a nowdoc is not code"
printf '%s\n' '<?php echo <<<EOT' 'include $f;' 'EOT;' > "$P8/heretext.php"
run_p8 "php heretext.php"
refused "#2978 a heredoc's own text, which can run code in {\${...}}, is still read word by word"
run_p8 "./runx"
read_refused "#2978 a script run by its #! naming php is followed"
run_p8 "php -i"
allowed "#2978 the control: php -i alone passes"

echo "slack drafts only: a file with a NUL in its first line is read as the shell running it reads it (claude-config#2977)"

# bash, sh and ksh refuse to run a file with a NUL in its first line ("cannot execute binary file"),
# so #2892 only searches such a file for an endpoint. zsh and dash run it (measured 2026-11-14, zsh
# 5.9 and /bin/dash): dash drops each NUL and zsh keeps it inside the word, ending a program's name
# there. So under dash the file is read as commands with each NUL dropped, and under zsh, or a shell
# that cannot be told, what it runs is refused where it cannot be worked out. A file bash sources is
# run up to its first NUL, which is read as commands too.
N7="$T/n2977"
mkdir -p "$N7"
printf '%s\n' "$POST" > "$N7/post.sh"
printf 'echo a\0b\n./post.sh\n' > "$N7/crafted.sh"
printf 'echo a\0b\nls\n' > "$N7/quiet.sh"
printf './post.sh\0junk\n' > "$N7/srcpost.sh"
printf 'ls\0junk\n' > "$N7/srcquiet.sh"
printf '%s\n' '. ./srcpost.sh' > "$N7/outer.sh"
printf '%s\n' '. ./srcquiet.sh' > "$N7/outerq.sh"
run_n7() { run_raw "$(payload Bash "$(bash_input "$1")" "$N7")"; }
run_n7 "bash crafted.sh"
allowed "#2977 the control: bash refuses the file, so it passes"
run_n7 "ksh crafted.sh"
allowed "#2977 ksh refuses it too, so it passes"
run_n7 "zsh crafted.sh"
read_refused "#2977 zsh runs the file, and the script it runs posts"
says "#2977 and the refusal names the script that posts" "post.sh"
run_n7 "dash crafted.sh"
read_refused "#2977 dash runs the file with the NUL dropped, and the script it runs posts"
says "#2977 and that refusal names the script that posts" "post.sh"
run_n7 "dash quiet.sh"
allowed "#2977 dash running such a file that runs nothing posting passes"
run_n7 "zsh quiet.sh"
read_refused "#2977 zsh keeps the NUL inside a word, so what it runs cannot be worked out"
says "#2977 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
run_n7 "bash outer.sh"
read_refused "#2977 a file bash sources runs up to its first NUL, and that part runs a script that posts"
run_n7 "bash outerq.sh"
allowed "#2977 a file bash sources whose part before the NUL posts nothing passes"
run_n7 "source srcquiet.sh"
read_refused "#2977 a file sourced by the session's own shell, which may be zsh, is refused"

echo "slack drafts only: NODE_OPTIONS, a perl glob, perl's \$SIG and sort by name, and a write in the background (claude-config#2912)"

# node loads every --require, --import and loader NODE_OPTIONS names before anything else, so a
# command that sets it to a module that posts ran that module unread (`NODE_OPTIONS='--require
# ./post.mjs' node -e 1` passed). Each module it names is now read as code, whatever program the
# command runs, since any of them can start node.
NO="$T/no2912"
mkdir -p "$NO"
printf '%s\n' "fetch('https://slack.com/api/chat.postMessage');" > "$NO/post.mjs"
printf '%s\n' "console.log('hi');" > "$NO/quiet.mjs"
run_no() { run_raw "$(payload Bash "$(bash_input "$1")" "$NO")"; }
run_no "NODE_OPTIONS='--require ./quiet.mjs' node -e 1"
allowed "#2912 the control: NODE_OPTIONS loading a quiet module passes"
run_no "NODE_OPTIONS=--max-old-space-size=4096 node -e 1"
allowed "#2912 NODE_OPTIONS loading nothing passes"
run_no "NODE_OPTIONS=\"\$NODE_OPTIONS --max-old-space-size=4096\" node -e 1"
allowed "#2912 NODE_OPTIONS adding to the session's own passes"
run_no "NODE_OPTIONS='--require ./post.mjs' node -e 1"
read_refused "#2912 NODE_OPTIONS requiring a module that posts is refused"
says "#2912 and the refusal names the module" "post.mjs"
run_no "NODE_OPTIONS=--import=./post.mjs node -e 1"
read_refused "#2912 NODE_OPTIONS importing it with = is refused"
run_no "export NODE_OPTIONS='-r ./post.mjs'; node -e 1"
read_refused "#2912 NODE_OPTIONS exported earlier in the line is refused"
run_no "env NODE_OPTIONS='--loader ./post.mjs' npm test"
read_refused "#2912 NODE_OPTIONS set through env for another program that starts node is refused"
run_no "env NODE_OPTIONS=--max-old-space-size=1 NODE_OPTIONS='--require ./post.mjs' node -e 1"
read_refused "#2912 the last NODE_OPTIONS of a prefix, the one node gets, is read"
run_no "NODE_OPTIONS=--max-old-space-size=1 node -e 1; NODE_OPTIONS='--require ./post.mjs' node -e 1"
read_refused "#2912 a NODE_OPTIONS set by a later command on the line is read, not only the first"
# Named with no folder and no extension, so nothing else in the command sends it past the wrapper's
# first look; node finds a bare name as a package, and the gate reads a file of that name as well.
cp "$NO/post.mjs" "$NO/postmod"
run_no "NODE_OPTIONS=--require=postmod make test"
read_refused "#2912 NODE_OPTIONS set for a program the gate does not otherwise read is refused"
run_no "NODE_OPTIONS=\"\$(cat opts.txt)\" node -e 1"
read_refused "#2912 NODE_OPTIONS set to a value the gate cannot work out is refused"
says "#2912 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"

# perl's <> opens each name it is handed with the two argument open, which runs a name starting or
# ending in | as a command. Such a name was never judged, written out or reached through a glob the
# shell expands (`perl -ne print *` in a folder holding "bash post.sh|"), so the command it runs is
# now judged as a command line.
PG="$T/pg2912"
mkdir -p "$PG/q"
printf '%s\n' "$POST" > "$PG/post.sh"
printf 'hi\n' > "$PG/a.txt"
printf 'hi\n' > "$PG/q/a.txt"
printf 'x\n' > "$PG/bash post.sh|"
printf 'x\n' > "$PG/q/ls|"
printf '%s\n' 'text naming https://slack.com/api/chat.postMessage' > "$PG/marked.txt"
run_pg() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$PG}")"; }
run_pg "perl -ne print *" "$PG/q"
allowed "#2912 the control: a glob naming a command that posts nothing passes"
run_pg "perl -ne print *"
read_refused "#2912 a glob perl's <> opens as a command that posts is refused"
says "#2912 and the refusal names the command" "post.sh"
run_pg "perl -ne print '| bash post.sh'"
read_refused "#2912 a name written out that perl opens as a command that posts is refused"
run_pg "perl -ne print 'bash post.sh |'"
read_refused "#2912 the same with the pipe at the end"
run_pg "perl -ne print a.txt"
allowed "#2912 the control: a plain file passes"
# The folder perl runs in is not part of the pattern: a [ or * in its path is literal to the glob.
PB="$T/pg[2912]"
mkdir -p "$PB"
printf '%s\n' "$POST" > "$PB/post.sh"
printf 'x\n' > "$PB/bash post.sh|"
run_pg "perl -ne print *" "$PB"
read_refused "#2912 a glob is still expanded where the folder perl runs in holds a ["
# A name that holds the very command naming it ("perl -ne print *|", which * matches) is read only as
# deep as the gate reads any nesting, then refused as not checked; it had no bound and ran past 120s.
PL="$T/pl2912"
mkdir -p "$PL"
printf 'x\n' > "$PL/perl -ne print *|"
run_pg "perl -ne print *" "$PL"
refused "#2912 a perl pipe name that runs itself is refused, not followed for ever"
says "#2912 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
# The safe list: a sub named by a string, through %SIG or sort, is off it.
run_pg "perl -ne '\$SIG{__WARN__} = \"main::x\"; print' marked.txt"
read_refused "#2912 perl code setting a handler in %SIG, handed a file naming an endpoint, is refused"
says "#2912 and the refusal names SIG" "SIG"
run_pg "perl -ne 'print sort \$n @F' marked.txt"
read_refused "#2912 perl code sorting with a sub named by a variable is refused"
run_pg "perl -ne 'print sort(\$n @F)' marked.txt"
read_refused "#2912 the same with the list in parentheses is refused"
run_pg "perl -ne 'print sort @F' marked.txt"
allowed "#2912 the control: a plain sort passes"

# raw_path wrote ${X}y as \$Xy, so two different variables gave one key; and raw_unchanged looked only
# between the write and the import, so a program started in the background before the write, which
# can rewrite the module after it, was not seen (#2854).
cat > "$T/raw-path-check.py" <<'PY'
import importlib.util, sys
sys.dont_write_bytecode = True  # the gate is carried by the sync: leave no cache beside it (#2919)
spec = importlib.util.spec_from_file_location("program_writes", sys.argv[1] + "/lib/program-writes.py")
pw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pw)
a, b, c = pw.raw_path('"${X}y/m.py"'), pw.raw_path('"$Xy/m.py"'), pw.raw_path('"$X/m.py"')
print("ok" if a != b and a and b and c == pw.raw_path('"${X}/m.py"') else "raw_path gave %r, %r and %r" % (a, b, c))
PY
check "#2912 raw_path keeps \${X}y and \$Xy apart" "$(python3 "$T/raw-path-check.py" "$DIR" 2>&1)"
BG="$T/bg2912"
mkdir -p "$BG"
bg2912() { # bg2912 <name> <line before the write>: a script writing a module, then importing it
  printf '%s\n' '#!/usr/bin/env bash' 'TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/bg2912.XXXXXXXX")"' 'mkdir -p "$TMPROOT/fault/lib"' \
    "$2" "printf 'X = 1\\n' > \"\$TMPROOT/fault/lib/fault_probe.py\"" \
    "python3 -c 'import sys; sys.dont_write_bytecode = True; sys.path.insert(0, sys.argv[1]); import fault_probe' \"\$TMPROOT/fault/lib\"" \
    > "$BG/$1.sh"
}
bg2912 fore 'ls "$TMPROOT"'
bg2912 back 'gen_tool "$TMPROOT/fault/lib" &'
bg2912 group '{ ls "$TMPROOT"; gen_tool "$TMPROOT/fault/lib"; } &'
bg2912 sub '( ls "$TMPROOT"; gen_tool "$TMPROOT/fault/lib" ) &'
run_bg() { run_raw "$(payload Bash "$(bash_input "$1")" "$BG")"; }
run_bg "bash fore.sh"
allowed "#2912 the control: a module written after a command that has finished is read as written"
for s in back group sub; do
  run_bg "bash $s.sh"
  read_refused "#2912 a program started in the background before the write may rewrite the module: $s"
done

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
