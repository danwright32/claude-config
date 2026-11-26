#!/usr/bin/env bash
# Tests for lib/code-loaders.py, the Slack drafts gate's reading of code a command loads without
# naming it as a script (claude-config#2912, #2977, #2978): a PHP include, the modules NODE_OPTIONS
# names, a name perl's <> runs as a command, a file with a NUL in its first line run by zsh or dash.
# Also the perl safe list's %SIG and sort by name, and lib/program-writes.py's raw_path and
# raw_unchanged (#2912). And a cd built from $0 or BASH_SOURCE worked out (lib/data-names.py,
# #2913). And lib/sh-walk-shapes.py (#2912): a for loop over words written out sourcing a path built
# from its name, NAME=value for one command in a function, and a function that evaluates its
# argument. And text handed to eval or a shell's -c, read where the gate can read it (#3020), and a
# shell given -n (#3155). And, last, the gate's verdict on running each of the five code loaders
# suites as a session runs it (#3624).
#
# test-slack-drafts-code-loaders.sh held every case of these readers, 2,287 checks, until on
# 2026-11-25 its slowest run on GitHub's runners (485 s) was 81 percent of the line the suite cost
# guard draws at half of run-all-tests.sh's 1,200 second wall limit (L315). Its sections are now
# five suites, dealt by their measured cost and kept together where one section makes the fixtures
# another reads (claude-config#3624): test-slack-drafts-code-loaders.sh itself, -data-names,
# -package-runs, -python and -shell-input. Every check is as it was, and a comment saying "above"
# or "below" means in whichever of the five holds it. Every other judgement of the gate is in
# test-slack-drafts-only-gate.sh and the five suites split from it (#3575).
#
# The world they all run in (the gate under test, the throwaway folder and its judgement cache,
# POST) is lib/slack-drafts-gate-harness.sh, the one place each of them takes it from. The helper
# functions are the one thing each holds a copy of, below, because the gate reads functions only
# where they are called; test-slack-drafts-gate-helper-copies.sh holds the copies equal. A case is
# driven the same way in all of them: a hook payload piped into slack-drafts-only-gate.sh, exit 0
# allowed and 2 refused, the reason on stderr.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/lib/slack-drafts-gate-harness.sh" || {
  echo "FAIL: $(basename "$0"): lib/slack-drafts-gate-harness.sh is missing, so there is no gate to run and no world to run it in. Refusing to run."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}

# The helpers every case is driven through, copied as they are into each of the five suites: the
# gate knows a shell function only where the text calling it defines it (lib/unknown-program.py,
# #3304), so with these in a sourced file it would read `run_bash "<a command that posts>"` as an
# unknown program running that command, and refuse a plain run of this suite.
pass=0
fail=0
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

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
printf '%s\n' '<?php echo <<<EOT' "don't" 'EOT;' 'include "quiet.php";' > "$P8/herequiet.php"
run_p8 "php herequiet.php"
allowed "#2978 the control: a quiet include after a heredoc whose text holds a quote passes"
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
# A compiled program is no script file (claude-config#3299). The shared reader read the bytes of one
# run by its path as commands for the guards that ask it for script files. This gate reads files
# itself and never did: a program with no #! is searched for an endpoint and its bytes are not
# commands. These cases hold that, in both directions, with a Mach-O header written here.
N9="$T/n3299"
mkdir -p "$N9"
printf '%s\n' "$POST" > "$N9/post.sh"
printf '\317\372\355\376\014\000\000\001\000\000\000\000\n./post.sh\n' > "$N9/tool"
{ printf '\317\372\355\376\014\000\000\001\000\000\000\000\n'; printf '%s\n' "$POST"; } > "$N9/poster"
printf '#!/bin/bash\n./post.sh\n\000\000\n' > "$N9/nul-later.sh"
printf '\177ELF;./post.sh\n' > "$N9/magic-no-nul"
run_n9() { run_raw "$(payload Bash "$(bash_input "$1")" "$N9")"; }
run_n9 "./tool --front-window notes.txt"
allowed "#3299 a compiled program run by its path, whose bytes spell a script that posts, passes"
run_n9 "bash tool"
allowed "#3299 and handed to bash, which refuses to run it, passes"
run_n9 "./poster"
refused "#3299 a compiled program naming an endpoint is still refused"
run_n9 "./tool && ./post.sh"
refused "#3299 a script that posts, run beside a compiled program, is still refused"
run_n9 "zsh tool"
read_refused "#3299 a compiled program's lines run by zsh, which runs them, are still read"
run_n9 "bash nul-later.sh"
read_refused "#3299 a script with a NUL after its first line still runs, so it is still read"
run_n9 "zsh magic-no-nul"
read_refused "#3299 a file with the magic number and no NUL, which a shell runs as commands, is still read"
# $0 of such a file is the word that ran it, as any script's is (#2913), and of one that is sourced
# the script that ran (claude-config#3020). It was left unknown, so a cd built from it was not
# followed, and the file sourced after the cd was read from the folder the command ran in: a quiet
# b.sh there passed while the script sourced the one beside itself, which posts.
mkdir -p "$N7/hooks/lib" "$N7/q/hooks/lib"
printf '%s\n' "$POST" > "$N7/hooks/b.sh"
printf '%s\n' 'echo quiet' > "$N7/b.sh"
printf '%s\n' 'echo quiet' > "$N7/q/hooks/b.sh"
printf '%s\n' "$POST" > "$N7/q/b.sh"
printf 'echo a\0b\ncd "$(dirname "$0")"\n. ./b.sh\n' > "$N7/hooks/zero.sh"
cp "$N7/hooks/zero.sh" "$N7/q/hooks/zero.sh"
printf 'cd "$(dirname "$0")"; . ./b.sh\0junk\n' > "$N7/hooks/lib/srczero.sh"
cp "$N7/hooks/lib/srczero.sh" "$N7/q/hooks/lib/srczero.sh"
printf '%s\n' '. "$(dirname "${BASH_SOURCE[0]}")/lib/srczero.sh"' > "$N7/hooks/runs-srczero.sh"
cp "$N7/hooks/runs-srczero.sh" "$N7/q/hooks/runs-srczero.sh"
run_n7 "dash hooks/zero.sh"
refused "#3020 \$0 of a file with a NUL in its first line is the word that ran it, so the file it sources after a cd built from it is the one read"
says "#3020 and that file posts" "REFUSED: this command posts to Slack"
says "#3020 naming the sourced file as the script wrote it, as for a script with no NUL" "the script ./b.sh runs a command that posts"
run_n7 "cd $N7/q && dash hooks/zero.sh"
allowed "#3020 the same script beside a quiet file passes, whatever the folder it ran from holds"
run_n7 "bash hooks/runs-srczero.sh"
refused "#3020 \$0 in such a file that bash sources is the script that ran"
says "#3020 so the file it reaches is the one that posts" "REFUSED: this command posts to Slack"
run_n7 "cd $N7/q && bash hooks/runs-srczero.sh"
allowed "#3020 and the same beside a quiet file passes"

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
# deep as the gate reads any nesting, then refused as not checked; with no bound it ran past 120
# seconds (measured 2026-11-14, then killed).
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

echo "slack drafts only: a sourced path from BASH_SOURCE is worked out after a cd in the script (claude-config#2913)"

# Found by the #2914 builder: a suite named by a relative path, which moves with
# cd "$(dirname "$0")/.." before sourcing "$(dirname "${BASH_SOURCE[0]}")/lib/...", was refused as a
# path the gate could not work out. $0 of a script that is run is the word that ran it, as its
# BASH_SOURCE is; of a sourced file, the caller's. A cd to a directory built only from those is now
# worked out, and the sourced path read from where the cd moved to, as bash reads it.
B9="$T/b2913"
mkdir -p "$B9/hooks/lib" "$B9/q/hooks/lib"
printf '%s\n' 'echo quiet' > "$B9/q/hooks/lib/helper.sh"
printf '%s\n' 'curl -d hi https://hooks.slack.com/services/T0/B0/x' > "$B9/hooks/lib/helper.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cd "$(dirname "$0")/.."' '. "$(dirname "${BASH_SOURCE[0]}")/lib/helper.sh"' > "$B9/hooks/up.sh"
printf '%s\n' '#!/usr/bin/env bash' 'cd "$(dirname "$0")"' 'cd ..' '. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/helper.sh"' > "$B9/hooks/upcd.sh"
cp "$B9/hooks/up.sh" "$B9/q/hooks/up.sh"
cp "$B9/hooks/upcd.sh" "$B9/q/hooks/upcd.sh"
# $0 in a sourced file is the script that ran: lib/moves.sh moves to the runner's folder, so ./b.sh is
# hooks/b.sh (which posts), never hooks/lib/b.sh.
printf '%s\n' 'cd "$(dirname "$0")"' '. ./b.sh' > "$B9/hooks/lib/moves.sh"
printf '%s\n' 'echo quiet' > "$B9/hooks/lib/b.sh"
printf '%s\n' 'curl -d hi https://hooks.slack.com/services/T0/B0/x' > "$B9/hooks/b.sh"
printf '%s\n' '#!/usr/bin/env bash' '. "$(dirname "${BASH_SOURCE[0]}")/lib/moves.sh"' > "$B9/hooks/runs-moves.sh"
run_b9() { run_raw "$(payload Bash "$(bash_input "$1")" "$B9")"; }
for s in up upcd; do
  run_b9 "cd $B9/q && bash hooks/$s.sh"
  allowed "#2913 a relative suite sourcing a quiet helper after a cd built from \$0 passes: $s"
  run_b9 "cd $B9 && bash hooks/$s.sh"
  refused "#2913 the same sourcing a helper that posts is refused: $s"
  says "#2913 as a post found, not a path it could not work out: $s" "REFUSED: this command posts to Slack"
done
run_b9 "bash hooks/runs-moves.sh"
refused "#2913 \$0 in a sourced file is the script that ran, not the sourced file"
says "#2913 so the file it reaches is the one that posts" "REFUSED: this command posts to Slack"

echo
echo "slack drafts only: three sourced path shapes the variable walk now follows, and perl's built names (claude-config#2912)"

# Since #2911 a sourced path the walk of a script's variables cannot work out is refused, and three
# shapes it could not follow were refused that way however quiet the file: a for loop over literal
# words sourcing "$LIB/$f" (tools/load-window.sh's), a per command NAME="$NAME" cmd in a function read
# as the function binding NAME, and a call of a function of the script that evaluates its argument,
# where the walk stopped. Measured 2026-11-14 on this branch's base: every case below that should
# pass was refused as a path not worked out, and `ev "$2"` then `bash "$LIB/post.sh"`, a file RUN
# past the stop (behind the #2683 switch, off), passed though post.sh posts.
SP="$T/sp2912"
mkdir -p "$SP/lib" "$SP/evil"
printf '%s\n' 'echo a' > "$SP/lib/a.sh"
printf '%s\n' 'echo b' > "$SP/lib/b.sh"
printf '%s\n' "$POST" > "$SP/lib/post.sh"
printf '%s\n' "$POST" > "$SP/evil/b.sh"
printf '%s\n' 'echo a' > "$SP/evil/a.sh"
printf '%s\n' 'LIB="$LIB/../evil"' > "$SP/lib/moves.sh"
printf '%s\n' 'f=post.sh' > "$SP/lib/setf.sh"
SPL='LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"'
# The loop as tools/load-window.sh wrote it before #2911, then a source after it.
sp_loop() { # sp_loop <file> <words>
  printf '%s\n' '#!/usr/bin/env bash' "$SPL" "for f in $2; do" '  # shellcheck disable=SC1090' \
    '  . "$LIB/$f" 2>/dev/null || { echo "$LIB/$f is missing" >&2; exit 1; }' 'done' '. "$LIB/b.sh"' > "$SP/$1"
}
sp_loop loopq.sh "a.sh b.sh"
sp_loop loopp.sh "a.sh post.sh"
sp_loop loopq2.sh "'a.sh' \"b.sh\""
sp_loop loopglob.sh "*.sh"
sp_loop loopvar.sh "a.sh \$NOPE_2912"
sp_loop loopmoves.sh "moves.sh b.sh"
sp_loop loopnone.sh ""
printf '%s\n' "$SPL" 'for f in setf.sh a.sh; do . "$LIB/$f"; . "$LIB/$f"; done' > "$SP/loopsetf.sh"
printf '%s\n' "$SPL" 'for f in a.sh b.sh; do f=post.sh; . "$LIB/$f"; done' > "$SP/loopbody.sh"
printf '%s\n' "$SPL" 'for d in lib; do for f in a.sh b.sh; do . "$LIB/../$d/$f"; done; done' > "$SP/loopnestq.sh"
printf '%s\n' "$SPL" 'for d in lib evil; do for f in a.sh b.sh; do . "$LIB/../$d/$f"; done; done' > "$SP/loopnestp.sh"
run_sp() { run_raw "$(payload Bash "$(bash_input "$1")" "$SP")"; }
run_sp "bash loopq.sh"
allowed "#2912 a for loop over literal words sourcing \"\$LIB/\$f\", each file quiet, passes"
run_sp "bash loopq2.sh"
allowed "#2912 the same with the words quoted passes"
# A loop over no words runs its body never, so it sources nothing (lessons review at 1b81a0c: the
# gate read the first of no choices and crashed).
run_sp "bash loopnone.sh"
allowed "#2912 a for loop over no words, sourcing nothing, passes"
run_sp "bash loopp.sh"
refused "#2912 the same loop sourcing a file that posts is refused"
says "#2912 as a post found, each file read" "REFUSED: this command posts to Slack"
run_sp "bash loopglob.sh"
refused "#2912 a loop over a glob is still refused"
says "#2912 as a path it could not work out" "a path the gate cannot work out"
run_sp "bash loopvar.sh"
refused "#2912 a loop over a word built from a variable is still refused"
says "#2912 as a path it could not work out, too" "a path the gate cannot work out"
run_sp "bash loopmoves.sh"
refused "#2912 a loop whose first file moves \$LIB, so the second is evil/b.sh, which posts, is refused"
run_sp "bash loopsetf.sh"
refused "#2912 a loop whose first file sets the loop's own name to a file that posts is refused"
run_sp "bash loopbody.sh"
refused "#2912 a loop whose body sets its own name to a file that posts is refused"
run_sp "bash loopnestq.sh"
allowed "#2912 a loop inside a loop, each over literal words, sourcing quiet files passes"
run_sp "bash loopnestp.sh"
refused "#2912 the same reaching a file that posts is refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
printf '%s\n' "$SPL" 'for f in a.sh gone.sh; do . "$LIB/$f"; done' > "$SP/loopgone.sh"
run_sp "bash loopgone.sh"
refused "#2912 a loop naming a file that is not there is refused, the walk ending there"
says "#2912 as a path it could not work out" "a path the gate cannot work out"
printf '%s\n' "$SPL" 'setf() { read -r f < /dev/null; }' 'for f in a.sh b.sh; do setf; . "$LIB/$f"; done' > "$SP/loopcall.sh"
run_sp "bash loopcall.sh"
refused "#2912 a loop calling a function that may set the loop's own name is refused"

# NAME="$NAME" cmd sets NAME for that one command, in a function's body as anywhere else.
printf '%s\n' "$SPL" 'run() { LIB="$LIB" env | head -1; }' 'run' '. "$LIB/a.sh"' > "$SP/fnq.sh"
printf '%s\n' "$SPL" 'run() {' '  LIB="$LIB" bash -c true' '}' 'run' '. "$LIB/post.sh"' > "$SP/fnp.sh"
printf '%s\n' "$SPL" 'run() { LIB=/nowhere; }' 'run' '. "$LIB/a.sh"' > "$SP/fnreal.sh"
printf '%s\n' "$SPL" 'run() { LIB="$LIB/../evil" helper; }' 'helper() { :; }' 'run' '. "$LIB/b.sh"' > "$SP/fncalls.sh"
run_sp "bash fnq.sh"
allowed "#2912 a function setting NAME for one command of its own leaves NAME known past its call"
run_sp "bash fnp.sh"
refused "#2912 so a file that posts, sourced past the call, is read and refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
run_sp "bash fnreal.sh"
refused "#2912 a function that really sets NAME still leaves it unknown past its call"
run_sp "bash fncalls.sh"
refused "#2912 NAME=value in front of a call of a function of the script still counts as binding it"

# A call of a function of the script that evaluates its argument: one written out is followed as
# though written in its place, as lib/hang-wait.sh's calls are. One the gate cannot read still ends
# the walk, and past it a file run by a path built from a variable is refused as a sourced one is,
# whatever the #2683 switch says, since the walk's end is what made the path unknown. So is the same
# past a plain eval of what the gate cannot read. The call itself is judged as `eval "$2"` always was.
SPE='ev() { eval "$1"; }'
printf '%s\n' "$SPL" "$SPE" 'ev "echo hi"' '. "$LIB/a.sh"' > "$SP/evq.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "echo hi"' '. "$LIB/post.sh"' > "$SP/evp.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "$2"' '. "$LIB/a.sh"' > "$SP/evn.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "$2"' 'bash "$LIB/post.sh"' > "$SP/evrun.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "$(cat cmd.txt)"' 'bash "$LIB/a.sh"' > "$SP/evcat.sh"
printf '%s\n' "$SPL" 'eval "$2"' 'bash "$LIB/post.sh"' > "$SP/evplain.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "$2"' 'bash lib/a.sh' > "$SP/evlit.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "$2"' > "$SP/evonly.sh"
printf '%s\n' "$SPL" "$SPE" 'ev "LIB=/nowhere"' '. "$LIB/a.sh"' > "$SP/evbinds.sh"
printf '%s\n' "$SPL" 'f() { local c="$1"; eval "$c"; }' 'f "echo hi"' '. "$LIB/a.sh"' > "$SP/evlocal.sh"
printf '%s\n' "$SPL" "$SPE" 'if true; then ev "$2"; fi' '. "$LIB/a.sh"' > "$SP/evif.sh"
printf '%s\n' "$SPL" "$SPE" 'g() { ev "$1"; }' 'g "$2"' '. "$LIB/a.sh"' > "$SP/evvia.sh"
printf '%s\n' "$SPL" "$SPE" '. "$LIB/a.sh"' > "$SP/evnone.sh"
run_sp "bash evq.sh"
allowed "#2912 a call of an evaluating function with its argument written out is followed, and the walk goes on"
run_sp "bash evp.sh"
refused "#2912 so a file that posts, sourced past it, is read and refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
run_sp "bash evnone.sh"
allowed "#2912 the control: an evaluating function never called changes nothing"
for s in evn evif evvia evlocal; do
  run_sp "bash $s.sh"
  read_refused "#2912 a sourced path past an eval of text the gate cannot read is refused: $s"
  says "#2912 and it says the check could not be made: $s" "REFUSED: the gate could not check whether this command posts to Slack"
done
run_sp "bash evn.sh"
says "#2912 and the refusal names the call the walk ended at" 'ev "$2"'
# A file RUN past it (evrun, evcat, evplain) stays behind the #2683 switch, as the gate suite pins for
# `eval "$1"` and hang_wait "$cond": refusing it is Dan's decision (2026-11-10, "measure first").
for s in evrun evcat evplain; do
  SLACK_GATE_UNWORKED_PATHS=refuse run_sp "bash $s.sh"
  refused "#2912 switched on, a file run past an eval the gate cannot read is refused: $s"
done
printf '%s\n' "$SPL" "$SPE" 'ev "[ \"\${X:-0}\" -gt 3 ]"' '. "$LIB/a.sh"' > "$SP/evesc.sh"
printf '%s\n' "$SPE" 'ev "bash \"lib/post.sh\""' > "$SP/evescp.sh"
run_sp "bash evesc.sh"
allowed "#2912 an argument in double quotes with every \$ and quote escaped is written out, and followed"
run_sp "bash evescp.sh"
refused "#2912 so the command it evaluates is judged, and one running a file that posts is refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
run_sp "bash evlit.sh"
allowed "#2912 the control: a file run by a path written out, past the same call, is read and passes"
run_sp "bash evonly.sh"
allowed "#2912 the control: the call alone is judged as eval \"\$2\" is, and passes"
run_sp "bash evbinds.sh"
refused "#2912 an argument written out that binds NAME leaves NAME unknown past the call"
# What such a call evaluates, written out, is judged as a command line: measured 2026-11-14 on this
# branch's base, `ev "bash lib/post.sh"` passed, and so did hang_wait from a sourced file handed it.
printf '%s\n' "$SPE" 'ev "bash lib/post.sh"' > "$SP/evruns.sh"
printf '%s\n' "$SPE" "ev 'bash lib/a.sh'" > "$SP/evrunsq.sh"
printf '%s\n' 'hang_wait() { eval "$1"; }' > "$SP/lib/hw.sh"
printf '%s\n' '. lib/hw.sh' 'hang_wait "bash lib/post.sh"' > "$SP/hwruns.sh"
printf '%s\n' '. lib/hw.sh' 'go() { hang_wait "bash lib/post.sh"; }' 'go' > "$SP/hwbody.sh"
run_sp "bash evruns.sh"
refused "#2912 a function of the script evaluating a command written out that runs a file that posts is refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
run_sp "bash evrunsq.sh"
allowed "#2912 the control: the same running a quiet file passes"
run_sp "bash hwruns.sh"
refused "#2912 a sourced file's evaluating function handed a command that posts is refused"
says "#2912 as a post found" "REFUSED: this command posts to Slack"
run_sp "bash hwbody.sh"
refused "#2912 the same call inside a function of the script is refused"

# perl's <> opens a name a $(...) or backquote builds, or a variable the gate cannot work out, as
# readily as one written out (lessons review of #3010 at 73967ea: `perl -ne print "$(printf 'bash
# post.sh|')"` passed, measured). Where perl opens what it is handed (-n, -p, -i, or <> in its code)
# such a word is refused, as the gate cannot see the name it becomes.
run_pg "perl -ne print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 a perl pipe name built by a substitution is refused"
says "#2912 and it says the check could not be made" "REFUSED: the gate could not check whether this command posts to Slack"
run_pg "perl -ne print \`printf 'bash post.sh|'\`"
read_refused "#2912 the same built by backquotes is refused"
# A name from a variable the gate cannot work out is a file it cannot read, as `bash "$X/a.sh"` runs
# one: it stays behind the #2683 switch with that run, which the gate suite pins off (Dan, 2026-11-10:
# "measure first"). Refusing it newly refused four of the repository's suites run directly,
# tests/test-claude-sync.sh among them, which the gate suite pins as allowed.
run_pg "perl -ne print \"\$NOPE_2912\""
allowed "#2912 a name from a variable the gate cannot work out passes with the #2683 switch off"
run_pg "perl -pi -e 's/a/b/' \"\$NOPE_2912/a.txt\""
allowed "#2912 the same for perl -pi, a path under it, passes with the switch off"
SLACK_GATE_UNWORKED_PATHS=refuse run_pg "perl -ne print \"\$NOPE_2912\""
read_refused "#2912 a name from a variable the gate cannot work out is refused with the #2683 switch on"
SLACK_GATE_UNWORKED_PATHS=refuse run_pg "perl -pi -e 's/a/b/' \"\$NOPE_2912/a.txt\""
read_refused "#2912 the same for perl -pi is refused with the switch on"
run_pg "perl -ne print \"\$NOPE_2912\" \"\$(printf 'bash post.sh|')\""
read_refused "#2912 beside it, a substitution is still refused with the switch off"
run_pg "perl -ne print \"\$NOPE_2912/\$(printf 'bash post.sh|')\""
read_refused "#2912 and so is a word holding both"
run_pg "perl -ne print 'bash post.sh'{,'|'}"
read_refused "#2912 a perl pipe name made by a brace expansion is refused"
run_pg "perl -e 'while (<>) { print }' \"\$(printf a.txt)\""
read_refused "#2912 the same where the code reads <> itself is refused"
run_pg "perl -pi -e 's/a/b/' \"\$(printf a.txt)\""
read_refused "#2912 the same for perl -pi is refused"
# -a implies -n and -F implies -a (perl 5.20 on); -0 takes only digits, and the cluster goes on past
# them (lessons review at 1b81a0c).
run_pg "perl -ae print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 the same for perl -a, which implies -n, is refused"
run_pg "perl -F, -e print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 the same for perl -F, which implies -a, is refused"
run_pg "perl -0777ne print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 the same for -n behind -0777 in one cluster is refused"
run_pg "perl -00pe print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 the same for -p behind -00 is refused"
run_pg "perl -0x1Fne print \"\$(printf 'bash post.sh|')\""
read_refused "#2912 the same for -n behind a hex -0x1F is refused"
run_pg "perl -0777 -e 'print 1' \"\$(printf a.txt)\""
allowed "#2912 the control: -0 alone does not open what perl is handed"
run_pg "f='bash post.sh|'; perl -ne print \"\$f\""
read_refused "#2912 a variable the gate works out is read, and its pipe name judged"
run_pg "perl -e 'print 1' \"\$(printf a.txt)\""
allowed "#2912 the control: perl that never opens what it is handed passes a substitution"
run_pg "f=a.txt; perl -ne print \"\$f\""
allowed "#2912 the control: a variable worked out to a plain file passes"

echo "slack drafts only: text handed to eval or a shell's -c is read where the gate can read it, and refused where it cannot (claude-config#3020)"

# `X="$(cat cmd.txt)"; eval "$X"` ran a file's text with the file never read, where the same text fed
# to a shell's input (`bash <<< "$(cat cmd.txt)"`, #2887) was. Text eval, a shell's -c or a function
# that evaluates its argument is handed through a variable or a substitution is now read where the
# gate can read it: a value worked out, and the text of one file (cat or <, straight or through a
# variable set once from it), by the reader #2887 uses for a here string. Text it cannot read, a
# program's output or a variable set nowhere, is refused in the command itself, as input a shell
# reads is; inside a script on disk it is left as before, whatever the #2683 switch says, as the
# gate suite pins for the string an eval runs (2026-11-12).
E3="$T/e3020"
mkdir -p "$E3"
printf '%s\n' "$POST" > "$E3/cmd.txt"
printf '%s\n' "$POST" > "$E3/post.sh"
printf '%s\n' 'echo quiet' > "$E3/quiet.txt"
run_e3() { run_raw "$(payload Bash "$(bash_input "$1")" "$E3")"; }
for c in "eval \"\$(cat quiet.txt)\"" "X=\"\$(cat quiet.txt)\"; eval \"\$X\"" "X='echo hi'; eval \"\$X\"" "eval 'echo hi'" \
  "run() { eval \"\$1\"; }; run \"\$(cat quiet.txt)\"" "run() { eval \"\$1\"; }; run 'echo hi'" \
  "bash -c \"\$(cat quiet.txt)\"" "eval \"\$(cat missing-3020.txt)\""; do
  run_e3 "$c"
  allowed "#3020 the control, text that posts nothing passes: $c"
done
for c in "eval \"\$(cat cmd.txt)\"" "eval \$(cat cmd.txt)" "eval \"\$(< cmd.txt)\"" "eval \"\`cat cmd.txt\`\"" \
  "X=\"\$(cat cmd.txt)\"; eval \"\$X\"" "X=\$(<cmd.txt); eval \$X" "X=\"\$(cat cmd.txt)\"; eval \"\${X}\"" \
  "D=.; eval \"\$(cat \"\$D/cmd.txt\")\"" "X='bash post.sh'; eval \"\$X\"" \
  "run() { eval \"\$1\"; }; run \"\$(cat cmd.txt)\"" "run() { eval \"\$1\"; }; X=\"\$(cat cmd.txt)\"; run \"\$X\"" \
  "bash -c \"\$(cat cmd.txt)\"" "X=\"\$(cat cmd.txt)\"; sh -c \"\$X\"" \
  "printf '%s\\n' 'bash post.sh' > made-3020.txt; eval \"\$(cat made-3020.txt)\""; do
  run_e3 "$c"
  refused "#3020 text that posts, read from a file or a value worked out, is refused: $c"
  says "#3020 as the post it is: $c" "REFUSED: this command posts to Slack"
done
for c in "eval \"\$(date)\"" "eval \"\$UNSET_3020\"" "X=\"\$(date)\"; eval \"\$X\"" "eval \"\$(cat \"\$UNSET_3020/cmd.txt\")\"" \
  "eval \"\$(cat quiet.txt) --flag\"" "X=\"\$(cat quiet.txt)\"; X=\"\$(date)\"; eval \"\$X\"" \
  "run() { eval \"\$1\"; }; run \"\$(date)\"" "run() { eval \"\$1\"; }; run \"\$UNSET_3020\"" \
  "bash -c \"\$(date)\"" "sh -c \"\$UNSET_3020\""; do
  run_e3 "$c"
  read_refused "#3020 text the gate cannot read is refused in the command itself: $c"
  says "#3020 as a check it could not make: $c" "REFUSED: the gate could not check whether this command posts to Slack"
done
# Inside a script on disk: the text of a file is read there too, and text the gate cannot read is
# left as it was, so a script evaluating a variable its caller sets runs as before.
printf '%s\n' 'X="$(cat cmd.txt)"' "eval \"\$X\"" > "$E3/file-posts.sh"
printf '%s\n' 'X="$(cat quiet.txt)"' "eval \"\$X\"" > "$E3/file-quiet.sh"
printf '%s\n' "[ -n \"\${PAUSE_3020:-}\" ] && eval \"\${PAUSE_3020}\"" "eval \"\$(date +%s >/dev/null)\"" 'echo done' > "$E3/unread.sh"
run_e3 "bash file-posts.sh"
refused "#3020 a script on disk evaluating the text of a file that posts is refused"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
run_e3 "bash file-quiet.sh"
allowed "#3020 and one evaluating the text of a quiet file passes"
run_e3 "bash unread.sh"
allowed "#3020 a script on disk evaluating text the gate cannot read passes as before"
SLACK_GATE_UNWORKED_PATHS=refuse run_e3 "bash unread.sh"
allowed "#3020 and with the #2683 switch on too, which the gate suite pins for the string an eval runs"
# The same for the text of a file whose path cannot be worked out, and for text a script on disk
# evaluates through a string written out (a wait handed 'eval \"\$c\"'): it is the script's, not the
# command's, however many strings deep it is evaluated.
printf '%s\n' "eval \"\$(cat \"\$UNSET_3020/cmd.txt\")\"" 'echo done' > "$E3/unread-file.sh"
printf '%s\n' "ev() { eval \"\$1\"; }" "ev 'eval \"\$c\"'" "ev 'eval \"\$(date)\"'" "ev 'bash -c \"\$c\"'" 'echo done' > "$E3/unread-deep.sh"
for s in unread-file unread-deep; do
  run_e3 "bash $s.sh"
  allowed "#3020 a script on disk evaluating text the gate cannot read passes as before: $s"
  SLACK_GATE_UNWORKED_PATHS=refuse run_e3 "bash $s.sh"
  allowed "#3020 and with the #2683 switch on too: $s"
done
run_e3 "ev() { eval \"\$1\"; }; ev 'eval \"\$UNSET_3020\"'"
read_refused "#3020 the same string evaluated in the command itself is refused, as text the gate cannot read"
# Code written out in single quotes is not text handed through a variable, whatever its own commands
# start with: it is read where it is, with the positional parameters the shell is given, as before.
# Measured 2026-11-15 by judging every tracked script: test-gh-reader.sh and test-push-scope.sh, which
# run `bash -c '. "$1/lib/push-scope.sh"; ... "$@" ...' _ "$DIR"`, were newly refused without this.
printf '%s\n' 'echo quiet' > "$E3/quiet.sh"
printf '%s\n' "DIR=\"\$(cd \"\$(dirname \"\${BASH_SOURCE[0]}\")\" && pwd)\"" 'asks() {' \
  "  bash -c '. \"\$1/quiet.sh\"; shift; if \"\$@\" x; then echo yes; fi' _ \"\$DIR\" \"\$@\"" '}' 'asks true' > "$E3/lit.sh"
run_e3 "bash lit.sh"
allowed "#3020 the control: a script whose shell is handed code written out, one command of it a variable, passes as before"
run_e3 "bash -c 'echo hi; \"\$@\"' _ true"
allowed "#3020 the control: and the same in the command itself"
run_e3 "eval 'echo hi; \"\$@\"'"
allowed "#3020 the control: and handed to eval"
# A redirection on the eval is the shell's, never a word of the text it is handed.
run_e3 "eval \"\$(cat quiet.txt)\" 2>/dev/null"
allowed "#3020 the control: a quiet file's text evaluated with its errors sent away passes"
run_e3 "eval \"\$(cat cmd.txt)\" 2>/dev/null"
refused "#3020 and a file that posts, evaluated the same way, is read and refused"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
# A command on a later line reaches the wrapper as \n and the word in the payload's JSON, where the
# n of the escape read as a letter in front of the word: the call skipped the gate whole, whatever
# the eval, or a shell running a file with no extension, went on to run (measured 2026-11-15 on
# origin/main: `true`, a newline, `bash post` passed, and the same on one line with ; was refused).
printf '%s\n' "$POST" > "$E3/post"
printf '%s\n' 'echo quiet' > "$E3/quiet"
run_e3 "$(printf 'true\neval "$(cat quiet.txt)"')"
allowed "#3020 the control: a quiet file's text evaluated on a later line passes"
run_e3 "$(printf 'true\neval "$(cat cmd.txt)"')"
refused "#3020 an eval on a later line is judged"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
run_e3 "$(printf 'X=$(cat cmd.txt)\n\teval $X')"
refused "#3020 and after a tab, through a variable set on the line before"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
run_e3 "$(printf 'true\nbash quiet')"
allowed "#3020 the control: a shell running a quiet file with no extension on a later line passes"
run_e3 "$(printf 'true\nbash post')"
refused "#3020 a shell running a file with no extension that posts, on a later line, is judged"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
# The same for what the wrapper matches only where a command starts, a file run by a path with a
# slash in it and a runner the shared reader reads through (env, nohup, time and the rest): an
# escaped tab or return after the line break stood between the break and the word, so the start was
# not seen (lessons review at d06d7aa).
mkdir -p "$E3/bin"
printf '%s\n' '#!/bin/bash' "$POST" > "$E3/bin/post"
printf '%s\n' '#!/bin/bash' 'echo quiet' > "$E3/bin/quiet"
chmod +x "$E3/bin/post" "$E3/bin/quiet"
run_e3 "$(printf 'true\n\tenv bin/quiet')"
allowed "#3020 the control: a runner on a later line, after a tab, running a quiet file passes"
run_e3 "$(printf 'true\n\tbin/post')"
refused "#3020 a file run by its path on a later line, after a tab, is judged"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
run_e3 "$(printf 'true\n\tenv bin/post')"
refused "#3020 and behind a runner"
run_e3 "$(printf 'true\r\n\tnohup bin/post')"
refused "#3020 and after a return, a line break and a tab"

echo "slack drafts only: a shell given -n reads its script and runs none of it (claude-config#3155)"

# On 2026-11-17 the gate refused `bash -n payload/hooks/payload-write-gate.sh` because it could not
# follow that script's source of a path built from a variable. -n only parses. Measured 2026-11-18
# (bash 3.2.57, sh as bash in POSIX mode, zsh 5.9, dash, ksh), each handed a script that writes a
# marker file: nothing was written under -n, -n with -x, -v, -e or -u, -n before --, nor with startup
# files in HOME or BASH_ENV set; it was written with -n after the script (an argument to it), with
# +n or +o noexec after -n (which turn it off again) and with -n after the -c code ($0). So bash, sh
# or zsh given -n, among options of letters that take no value, before a script file, runs nothing
# of that file; everything else on the line, and every other spelling, is judged as before.
D55="$T/d3155"
mkdir -p "$D55"
run_55() { run_raw "$(payload Bash "$(bash_input "$1")" "$D55")"; }
printf '%s\n' "$POST" > "$D55/posts.sh"
printf '%s\n' '#!/bin/bash' '. "$HOOK_DIR_3155/lib/sync-clone.sh"' 'echo ok' > "$D55/sources.sh"
for runs in "bash -n posts.sh" "sh -n posts.sh" "zsh -n posts.sh" "/bin/bash -n posts.sh" "bash -n $D55/posts.sh" \
  "bash -n sources.sh" "bash -nx posts.sh" "bash -n -v posts.sh" "bash -e -n posts.sh" "bash -n -- posts.sh" \
  "sh -n -u posts.sh" "bash -n posts.sh && echo parsed" "bash -n posts.sh 2>&1 | head -5" "zsh -n sources.sh"; do
  run_55 "$runs"
  allowed "#3155 a shell given -n runs nothing of a script that posts: $runs"
done
for runs in "bash posts.sh" "bash sources.sh" "bash posts.sh -n" "bash -- -n posts.sh" "bash -n +n posts.sh" \
  "bash -n +o noexec posts.sh" "bash -n posts.sh; bash posts.sh" "bash -n posts.sh && sh posts.sh" \
  "bash -n posts.sh | bash" "bash -c '$POST' -n" "bash -n -c '$POST'" "bash -nc '$POST'" \
  "bash -n posts.sh \$(bash posts.sh)" "bash -n posts.sh <(bash posts.sh)" "bash -n posts.sh > >(bash posts.sh)" \
  "bash -n \$OPT posts.sh" "OPT=+n; bash -n \$OPT posts.sh" "bash -n \"\$(echo +n)\" posts.sh" "bash -n '+n' posts.sh"; do
  run_55 "$runs"
  read_refused "#3155 a script that posts is still refused where -n does not stop it, or with -c: $runs"
done

echo
echo "slack drafts only: each code loaders suite, run as a session runs it, is allowed (claude-config#3624)"

# Each of the five suites this one was cut into holds its own copy of the helpers, because the gate
# knows a shell function only where the text calling it defines it: with them in a sourced file it
# refused the start command of a drafts gate suite as a post (measured 2026-11-24, #3575). So the
# start command of every one of them is judged here, this one included, and a suite whose helpers
# move out is refused. They are found by their names, never by a list (L96), and finding fewer than
# two is a failure, so a pattern that matches nothing is not a pass (L98).
cl_found=0
for cl_suite in "$DIR"/test-slack-drafts-code-loaders*.sh; do
  [ -f "$cl_suite" ] || continue
  cl_found=$((cl_found + 1))
  run_bash "bash $cl_suite"
  allowed "running $(basename "$cl_suite") itself"
done
case "$cl_found" in
  0|1) check "the code loaders suites are found (at least two)" "found $cl_found in $DIR" ;;
  *) check "the code loaders suites are found (at least two)" ok ;;
esac


sdg_harness_result
