#!/usr/bin/env bash
# Tests for lib/code-loaders.py, the Slack drafts gate's reading of code a command loads without
# naming it as a script (claude-config#2912, #2977, #2978): a PHP include, the modules NODE_OPTIONS
# names, a name perl's <> runs as a command, a file with a NUL in its first line run by zsh or dash.
# Also the perl safe list's %SIG and sort by name, and lib/program-writes.py's raw_path and
# raw_unchanged (#2912). And lib/data-names.py (#2913): an address only compared or listed told from
# one sent to, a test file read the same way by npx vitest and the node_modules path, and a cd built
# from $0 or BASH_SOURCE worked out. And lib/sh-walk-shapes.py (#2912): a for loop over words written
# out sourcing a path built from its name, NAME=value for one command in a function, and a function
# that evaluates its argument. And lib/js-mocks.py (#2359): a test file's import of a module the same
# file replaces with vi.mock or jest.mock and a factory is not followed. And lib/data-names.py again
# (#3050): the webhook's variable name where a JavaScript or TypeScript file only declares it, told
# from where it is read. And lib/program-runs.py's package_run beside a folder or a file of the
# package's name (#3069), kept here beside the other `npx vitest` cases, and beside a local package
# folder a launcher is handed by path (#3083). And a Python script that uses os only to read, handed
# a file naming an endpoint (#3085), kept here so the larger suite does not grow. And
# lib/py-aliases.py (#3102): a Python module given another name, or put where the gate does not
# follow it, is read as the imported name is. And three more routes to os (#3119): string.Formatter,
# a chain from a value the gate does not follow, and os under another name in a module the script
# imports or a class body. Every other
# judgement of the gate is in test-slack-drafts-only-gate.sh,
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

echo "slack drafts only: an address held only as data, compared or listed, is told from one sent to (claude-config#2913)"

# Dan's decision of 2026-11-14 on #2913: teach the gate to tell a Slack posting address that is only
# compared against or listed (a refusal list of hosts in a guard's own code) from one that is sent to,
# with no exemption list, and to keep refusing any it cannot classify. A name counts as data only where
# it sits in a string that is an element of a list literal, an operand of a comparison, the argument of
# a test such as includes or startswith, or a regex pattern, or in a comment; and only where nothing in
# the program that holds it (the script, every module it reaches, and any other code run in the same
# process) can send a request or run code, since a list or a comparison can still feed a send.
D9="$T/d2913"
mkdir -p "$D9/src" "$D9/scripts" "$D9/py" "$D9/node_modules/.bin" "$D9/node_modules/vitest/dist"
printf '%s\n' '// Scripts may not post to Slack: hooks.slack.com and chat.postMessage are refused.' \
  'export const REFUSED_HOSTS = ["hooks.slack.com", "example.invalid"];' \
  'export const REFUSED_METHODS = new Set(["chat.postMessage", "chat.scheduleMessage"]);' \
  'export function refuses(url: string): boolean {' \
  '  const host = new URL(url).host;' \
  '  if (host === "hooks.slack.com" || url.includes("chat.postMessage")) return true;' \
  '  if (/hooks\.slack\.com/.test(url)) return true;' \
  '  return REFUSED_HOSTS.some((h) => host === h);' \
  '}' > "$D9/src/refuse.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'import { readFileSync } from "node:fs";' \
  'const lines = readFileSync(process.argv[2], "utf8").split("\n");' 'console.log(lines.filter((l) => refuses(l)).length);' \
  > "$D9/scripts/count.ts"
printf '%s\n' 'import assert from "node:assert";' 'import { readFileSync } from "node:fs";' 'import { refuses } from "../src/refuse.ts";' \
  'const urls = JSON.parse(readFileSync("scripts/fixture.json", "utf8"));' 'for (const u of urls) assert.equal(refuses(u), true);' \
  > "$D9/scripts/refuse.test.ts"
printf '%s\n' '["https://example.invalid/a"]' > "$D9/scripts/fixture.json"
printf 'a\nb\n' > "$D9/data.txt"
# The same list, sent to: by the script that imports it, and by one that only compares and then sends.
printf '%s\n' 'import { REFUSED_HOSTS } from "../src/refuse.ts";' \
  'await fetch("https://" + REFUSED_HOSTS[0] + "/services/T0/B0/x", { method: "POST", body: "hi" });' > "$D9/scripts/send-listed.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'const u = process.env.HOOK ?? "";' \
  'if (refuses(u)) await fetch(u, { method: "POST", body: "hi" });' > "$D9/scripts/send-compared.ts"
printf '%s\n' 'import { refuses } from "../src/refuse.ts";' 'import { execFileSync } from "node:child_process";' \
  'if (refuses(process.argv[2])) execFileSync("curl", ["-d", "hi", process.argv[2]]);' > "$D9/scripts/run-compared.ts"
# A loader run in the same process, able to run code, beside a script that holds the name only as data.
printf '%s\n' 'import { register } from "node:module";' 'register("./hooks.mjs", import.meta.url);' > "$D9/scripts/loader.mjs"
printf '%s\n' 'export async function load(u, c, next) { return next(u, c); }' > "$D9/scripts/hooks.mjs"
# Shapes that are not data: a string handed to a call, held in an object, indexed, or built into a URL.
printf '%s\n' 'console.log("https://hooks.slack.com/services/T0/B0/x");' > "$D9/scripts/arg.ts"
printf '%s\n' 'export const target = { url: "https://hooks.slack.com/services/T0/B0/x" };' > "$D9/src/object.ts"
printf '%s\n' 'import { target } from "../src/object.ts";' 'console.log(target);' > "$D9/scripts/object.ts"
printf '%s\n' 'const t: Record<string, number> = {};' 'console.log(t["chat.postMessage"]);' > "$D9/scripts/index.ts"
printf '%s\n' 'const id = process.argv[2];' 'console.log(`https://hooks.slack.com/services/${id}`);' > "$D9/scripts/template.ts"
printf '%s\n' 'const pick = (a: string, b: string) => b;' 'console.log(pick("a", "hooks.slack.com"));' > "$D9/scripts/call-args.ts"
run_d9() { run_raw "$(payload Bash "$(bash_input "$1")" "$D9")"; }
run_d9 "node --experimental-strip-types scripts/count.ts data.txt"
allowed "#2913 a script whose import names the host only in a refusal list, a comparison, a regex and a comment passes"
run_d9 "node --experimental-strip-types scripts/refuse.test.ts"
allowed "#2913 a single node test whose chain names the host only as data, reading a fixture, passes"
run_d9 "node --experimental-strip-types scripts/send-listed.ts"
read_refused "#2913 a script sending to an address taken from the refusal list is still refused"
says "#2913 the refusal names the module and what the script can do" "refuse.ts), which posts to Slack (it names hooks.slack.com"
run_d9 "node --experimental-strip-types scripts/send-compared.ts"
read_refused "#2913 a script that only compares an address against the host and then sends to it is still refused"
run_d9 "node --experimental-strip-types scripts/run-compared.ts https://hooks.slack.com/services/T0/B0/x"
read_refused "#2913 a script that compares then hands the address to a program is still refused"
run_d9 "node --experimental-strip-types --import ./scripts/loader.mjs scripts/count.ts data.txt"
read_refused "#2913 a loader able to run code in the same process as data only names is refused"
says "#2913 the refusal names the loader" "loader.mjs"
for s in arg object index template call-args; do
  run_d9 "node --experimental-strip-types scripts/$s.ts"
  read_refused "#2913 a name not compared or listed is refused even where nothing can send: $s"
done
# Python, read the same way: a set, a tuple, a comparison, startswith and a match case are data; a
# program that can send, or a name handed to a call, is not.
printf '%s\n' '"""Refuses any address on Slack."""' 'HOSTS = {"hooks.slack.com", "example.invalid"}' 'METHODS = ("chat.postMessage",)' \
  'def refuses(url):' '    if url == "https://hooks.slack.com/" or url.startswith("https://hooks.slack.com/"):' '        return True' \
  '    match url:' '        case "chat.postMessage":' '            return True' '    return any(h in url for h in HOSTS)' > "$D9/py/guard.py"
printf '%s\n' 'import sys' 'from guard import refuses' 'print(sum(refuses(l) for l in open(sys.argv[1])))' > "$D9/py/count.py"
printf '%s\n' 'import sys, urllib.request' 'from guard import HOSTS' \
  'urllib.request.urlopen("https://" + sorted(HOSTS)[0] + "/services/T0/B0/x", data=b"hi")' > "$D9/py/send.py"
printf '%s\n' 'print("https://hooks.slack.com/services/T0/B0/x")' > "$D9/py/arg.py"
run_d9 "python3 py/count.py data.txt"
allowed "#2913 a Python script importing a guard that names the host only as data passes"
run_d9 "python3 py/send.py"
read_refused "#2913 a Python script sending to a host taken from the guard's set is still refused"
run_d9 "python3 py/arg.py"
read_refused "#2913 a Python script handing the name to a call is still refused"
# Real sends in the same shapes are refused as before: the name sent to directly beside a list.
printf '%s\n' 'const HOSTS = ["hooks.slack.com"];' 'await fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/both.ts"
run_d9 "node --experimental-strip-types scripts/both.ts"
read_refused "#2913 a script listing the host and also sending to it is refused"
says "#2913 the refusal names what it sends to" "posts to Slack (it names hooks.slack.com)"
# What a program prints or writes can carry a listed address to a sender in the same command, and a
# computed name reaches fetch unnamed, so each of these, sending for real, is refused (found probing
# the first build of this change, 2026-11-14).
printf '%s\n' 'console.log(["https://hooks.slack.com/services/T0/B0/x"][0]);' > "$D9/scripts/prints.ts"
printf '%s\n' 'import { writeFileSync } from "node:fs";' 'writeFileSync("u.txt", ["https://hooks.slack.com/services/T0/B0/x"][0]);' > "$D9/scripts/writes.ts"
printf '%s\n' 'const H = ["hooks.slack.com"];' 'globalThis["fe" + "tch"]("https://" + H[0] + "/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/computed.ts"
printf '%s\n' 'const H = ["hooks.slack.com"];' 'const load = process["getBuiltin" + "Module"];' > "$D9/scripts/process-index.ts"
printf '%s\n' 'print(["https://hooks.slack.com/services/T0/B0/x"][0])' > "$D9/py/prints.py"
printf '%s\n' 'import { promises as p } from "node:fs";' 'const H = ["hooks.slack.com"];' \
  'await p["write" + "File"]("u.cfg", "url = https://" + H[0] + "/services/T0/B0/x");' > "$D9/scripts/computed-write.ts"
printf '%s\n' 'const H = ["hooks.slack.com", "example.invalid"];' 'for (let i = 0; i < H.length; i++) console.log(H[i].length);' > "$D9/scripts/var-index.ts"
for runs in "node scripts/computed-write.ts && curl -d hi -K u.cfg" "node scripts/var-index.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a computed name other than a number or a string can reach a write, so it is refused: $runs"
done
run_d9 "node scripts/var-index.ts"
says "#2913 the refusal names the computed name" "by a computed name"
for runs in "node scripts/prints.ts | xargs curl -d hi" "curl -d hi \$(node scripts/prints.ts)" \
  "node scripts/prints.ts > u.txt; curl -d hi \$(cat u.txt)" "U=\`node scripts/prints.ts\`; curl -d hi \"\$U\"" \
  "node scripts/prints.ts | tail -1 | xargs curl -d hi" "python3 py/prints.py | xargs curl -d hi" \
  "node scripts/writes.ts" "node scripts/computed.ts" "node scripts/process-index.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a listed address that can still reach a sender is refused: $runs"
done
# A module NODE_OPTIONS preloads shares the process with whatever node then runs, which can read what
# it leaves on the global object (lessons review at 73967ea), so a name it holds only as data is
# refused as before.
printf '%s\n' 'globalThis.H = ["hooks.slack.com"];' > "$D9/scripts/preload.mjs"
printf '%s\n' 'await fetch("https://" + globalThis.H[0] + "/services/T0/B0/x", { method: "POST" });' > "$D9/scripts/uses-preload.mjs"
run_d9 "NODE_OPTIONS='--import ./scripts/preload.mjs' node scripts/uses-preload.mjs"
read_refused "#2913 a module NODE_OPTIONS preloads, holding the host only as data, beside a script that sends, is refused"
says "#2913 the refusal names the preloaded module" "preload.mjs"
printf '%s\n' '#!/usr/bin/env bash' 'out=$(node scripts/prints.ts)' 'curl -d hi "$out"' > "$D9/scripts/captures.sh"
run_d9 "bash scripts/captures.sh"
read_refused "#2913 a script capturing what a program holding a listed address prints is refused"
printf '%s\n' '#!/usr/bin/env bash' 'node --experimental-strip-types scripts/count.ts data.txt' > "$D9/scripts/runs-count.sh"
run_d9 "bash scripts/runs-count.sh | xargs curl -d hi"
read_refused "#2913 a script's output piped on carries what the program inside it prints"
for runs in "node --experimental-strip-types scripts/count.ts data.txt 2>&1 | tail -20" \
  "node --experimental-strip-types scripts/count.ts data.txt > /dev/null && echo done" "bash scripts/runs-count.sh"; do
  run_d9 "$runs"
  allowed "#2913 output that only reaches the terminal, a filter or nowhere passes: $runs"
done

echo "slack drafts only: npx vitest and the node_modules path read a test file the same way (claude-config#2913)"

# Before this, `npx vitest run x.test.ts` judged the test file by its own text only (#2865), while
# `./node_modules/.bin/vitest run x.test.ts` followed its imports, so a test importing a module that
# posts passed one spelling and was refused by the other. A package a launcher runs counts as able to
# run what it is handed, so a file it is handed that says it is JavaScript, TypeScript or Python is now
# read as a script, its imports followed, by every launcher; one another program only may have
# rewritten is read as it is on disk, as before.
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$D9/node_modules/vitest/vitest.mjs"
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$D9/node_modules/vitest/dist/cli.js"
ln -s ../vitest/vitest.mjs "$D9/node_modules/.bin/vitest"
printf '%s\n' 'export const post = (t: string) => fetch("https://hooks.slack.com/services/T0/B0/x", { method: "POST", body: t });' > "$D9/src/poster.ts"
printf '%s\n' 'import { it } from "vitest";' 'import { post } from "./poster";' 'it("posts", () => post("hi"));' > "$D9/src/poster.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'it("adds", () => {});' > "$D9/src/quiet.test.ts"
for runs in "npx vitest run src/poster.test.ts" "./node_modules/.bin/vitest run src/poster.test.ts" "bunx vitest run src/poster.test.ts" \
  "pnpm dlx vitest run src/poster.test.ts" "npm exec -- vitest run src/poster.test.ts" "yarn dlx vitest run src/poster.test.ts"; do
  run_d9 "$runs"
  read_refused "#2913 a test importing a module that posts is refused by every spelling: $runs"
  says "#2913 and the refusal follows the import: $runs" "poster"
done
for runs in "npx vitest run src/quiet.test.ts" "./node_modules/.bin/vitest run src/quiet.test.ts" "pnpm dlx vitest run src/quiet.test.ts"; do
  run_d9 "$runs"
  allowed "#2913 the control: a quiet test passes by every spelling: $runs"
done
run_d9 "npx prettier --write src/quiet.test.ts >/dev/null && npx vitest run src/quiet.test.ts"
allowed "#2913 a test a formatter only may rewrite is still read as it is on disk when a package is handed it"
# A shell script handed to a package is still judged by its own text, as before: only a file that says
# it is JavaScript, TypeScript or Python is followed.
printf '%s\n' 'sh scripts/poster.sh' > "$D9/scripts/lint-me.sh"
printf '%s\n' 'curl -d hi https://hooks.slack.com/services/T0/B0/x' > "$D9/scripts/poster.sh"
run_d9 "npx shellcheck scripts/lint-me.sh"
allowed "#2913 a shell script handed to a package is not read as commands"

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

echo "slack drafts only: a test file's import of a module the same file mocks out is not followed (claude-config#2359)"

# A test runner never loads a module a test file replaces with vi.mock or jest.mock and a factory:
# the import gets the factory's object. In the probe of 2026-11-06, 7 test files in two personal
# repositories that imported a posting helper only to mock it were refused when run directly. Dan
# decided on 2026-11-15 to let that import through, and only that: a real unmocked import, a mock
# without a factory (automock loads the module), a factory handed the original, the original fetched
# by importActual or requireActual, a mock taken back, a mock of another path, a mock the gate cannot
# read, a mock inside a block (babel-jest lifts a jest.mock only to the top of its own block, so the
# file's imports run first), a file that is not a test file, and a test file node runs itself (where
# vi.mock and jest.mock replace nothing) each stay refused.
MK="$T/g2359"
mkdir -p "$MK/__tests__" "$MK/node_modules/.bin" "$MK/node_modules/vitest/dist" "$MK/node_modules/jest/bin"
printf '%s\n' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$MK/posts.ts"
printf '%s\n' "export function send() { fetch('https://slack.com/api/chat.postMessage'); }" > "$MK/posts2.ts"
printf '%s\n' 'export const other = 1;' > "$MK/other.ts"
# The runners as D9's: a node script that starts each file it is handed.
printf '%s\n' '#!/usr/bin/env node' "import './dist/cli.js'" > "$MK/node_modules/vitest/vitest.mjs"
printf '%s\n' "import { fork } from 'node:child_process'" 'for (const f of process.argv.slice(3)) fork(f)' > "$MK/node_modules/vitest/dist/cli.js"
ln -s ../vitest/vitest.mjs "$MK/node_modules/.bin/vitest"
printf '%s\n' '#!/usr/bin/env node' "const { fork } = require('node:child_process')" 'for (const f of process.argv.slice(2)) fork(f)' > "$MK/node_modules/jest/bin/jest.js"
ln -s ../jest/bin/jest.js "$MK/node_modules/.bin/jest"
run_mk() { run_raw "$(payload Bash "$(bash_input "$1")" "$MK")"; }
MK_RUN="./node_modules/.bin/vitest run"
mk_case() { # mk_case <file name> <lines...>: judge $MK_RUN handed a file in $MK holding them
  local name="$1"
  shift
  printf '%s\n' "$@" 'console.log(1);' > "$MK/$name"
  run_mk "$MK_RUN $name"
}
mk_case a.test.ts 'import { send } from "./posts.ts";'
read_refused "#2359 the control: a test file's unmocked import of a module that posts is refused"
mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a vi.mock with a factory, written after the import it replaces"
MK_RUN="./node_modules/.bin/jest"
mk_case a.spec.ts 'jest.mock("./posts", function () { return { send: jest.fn() }; });' 'import { send } from "./posts.ts";'
allowed "#2359 a jest.mock with a function factory, written before, naming the same file another way, run by jest"
mk_case a.test.js 'jest.mock("./posts.ts", () => ({ send: jest.fn() }));' 'const { send } = require("./posts.ts");'
allowed "#2359 a require of a module jest.mock replaces, run by jest"
mk_case a.test.js 'const { send } = require("./posts.ts");' 'describe("x", () => {' '  jest.mock("./posts.ts", () => ({ send: jest.fn() }));' '});'
read_refused "#2359 a jest.mock inside a block, which babel-jest lifts only to the top of that block, is refused"
MK_RUN="npx vitest run"
mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", async () => ({ send: vi.fn() }));'
allowed "#2359 an async factory, handed to the runner by npx"
MK_RUN="./node_modules/.bin/vitest run"
mk_case a.test.ts 'import { send } from "./posts.ts";' 'describe("x", () => {' '  vi.mock("./posts.ts", () => ({ send: vi.fn() }));' '});'
read_refused "#2359 a vi.mock inside a block is refused too"
mk_case a.test.ts 'import { vi, beforeAll } from "vitest"' 'import { send } from "./posts.ts"' 'beforeAll(() => {})' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }))'
allowed "#2359 a mock as its own statement in a file written without semicolons"
mk_case a.test.ts 'import { send } from "./posts.ts";' 'vi.mock<typeof import("./posts.ts")>("./posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a mock with a type argument"
mk_case __tests__/a.ts 'import { send } from "../posts.ts";' 'vi.mock("../posts.ts", () => ({ send: vi.fn() }));'
allowed "#2359 a file in a __tests__ folder"
mk_case a.ts 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
read_refused "#2359 a file that is not a test file is unchanged: its mocked import is still followed"
for runs in "node a.test.ts" "npx tsx a.test.ts" "bash -c 'node a.test.ts'"; do
  mk_case a.test.ts 'import { vi } from "vitest";' 'import { send } from "./posts.ts";' 'vi.mock("./posts.ts", () => ({ send: vi.fn() }));'
  run_mk "$runs"
  read_refused "#2359 a test file run by node itself, where the mock replaces nothing, is refused: $runs"
done
printf '%s\n' "const { fork } = require('node:child_process')" 'for (const f of process.argv.slice(2)) fork(f)' > "$MK/my-vitest-runner.js"
run_mk "node my-vitest-runner.js a.test.ts"
read_refused "#2359 a script handed the file that only has the runner's name inside its own is not the runner"
# A script of the repository's own that takes the runner's name is not the runner as installed.
mkdir -p "$MK/vitest"
cp "$MK/my-vitest-runner.js" "$MK/jest.js"
cp "$MK/my-vitest-runner.js" "$MK/vitest/run.js"
for runs in "node jest.js a.test.ts" "node vitest/run.js a.test.ts"; do
  run_mk "$runs"
  read_refused "#2359 a script outside node_modules named after the runner is not the runner: $runs"
done
for line in 'vi.mock("./posts.ts");' \
  'jest.mock("./posts.ts");' \
  'vi.mock("./posts.ts", { spy: true });' \
  'vi.mock("./posts.ts", async (importOriginal) => ({ ...(await importOriginal()) }));' \
  'vi.mock("./posts.ts", factory);' \
  'vi.doMock("./posts.ts", () => ({}));' \
  'jest.doMock("./posts.ts", () => ({}));' \
  'vi.mock("./other.ts", () => ({}));' \
  'vi.mock(`./${name}.ts`, () => ({}));' \
  'vi.mock(path, () => ({}));' \
  'vi.mock(import("./posts.ts"), () => ({}));' \
  '// vi.mock("./posts.ts", () => ({}));' \
  'const s = '"'"'vi.mock("./posts.ts", () => ({}))'"'"';' \
  'vi.mock("./posts.ts", () => ({}));  vi.mock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const real = jest.requireActual("./posts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual(p);' \
  'vi.mock("./posts.ts", () => ({}));  vi.unmock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  jest.unmock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  jest.dontMock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  vi.doUnmock("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const m = await vi.importMock("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const m = jest.createMockFromModule("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi.importActual<typeof import("./posts.ts")>("./posts.ts");' \
  'jest.mock("./posts.ts", () => ({}));  const real = jest.requireActual<typeof import("./posts")>("./posts");' \
  'vi.mock("./posts.ts", () => ({}));  const load = vi.importActual;' \
  'const setup = () => vi.mock("./posts.ts", () => ({}));' \
  'if (process.env.MOCK) vi.mock("./posts.ts", () => ({}));' \
  'process.env.MOCK && vi.mock("./posts.ts", () => ({}));' \
  'void vi.mock("./posts.ts", () => ({}));' \
  'vi.mock("./posts.ts", () => ({}));  const real = await vi["importActual"]("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const { importActual } = vi;' \
  'vi.mock("./posts.ts", () => ({}));  const k = "import" + "Actual";  const real = await vi[k]("./posts.ts");' \
  'vi.mock("./posts.ts", () => ({}));  const v = vi;' \
  'vi.mock("./posts.ts", () => ({}));  const fns = Object.values(vi);' \
  'vi.mock("./posts.ts", () => ({}));  const g = globalThis["vi"];' \
  'import { vi as v } from "vitest";  vi.mock("./posts.ts", () => ({}));' \
  'vi.mock("./posts.ts", () => ({}));  const m = vi.mock;'; do
  mk_case a.test.ts 'import { send } from "./posts.ts";' "$line"
  read_refused "#2359 a test file importing a module that posts stays refused beside: $line"
done
mk_case a.test.ts 'import { send } from "./posts.ts";' 'import { send as s2 } from "./posts2.ts";' 'vi.mock("./posts.ts", () => ({}));'
read_refused "#2359 a second module that posts, not mocked, is still followed"
says "#2359 the refusal names the unmocked module" "posts2.ts"
# Through the test runner's launcher, as the refusals of 2026-11-06 were met.
printf '%s\n' 'import { it, vi } from "vitest";' 'import { post } from "./poster";' 'vi.mock("./poster", () => ({ post: vi.fn() }));' \
  'it("posts", () => post("hi"));' > "$D9/src/mocks-poster.test.ts"
for runs in "npx vitest run src/mocks-poster.test.ts" "./node_modules/.bin/vitest run src/mocks-poster.test.ts"; do
  run_d9 "$runs"
  allowed "#2359 a test file mocking the poster it imports passes: $runs"
done
run_d9 "npx vitest run src/poster.test.ts"
read_refused "#2359 the same test without the mock is still refused (the control)"

echo
echo "slack drafts only: a module loaded through the test runner's own loaders is followed as an import (claude-config#3020)"

# vi.importActual, jest.requireActual and the runners' other loaders (importMock, requireMock,
# createMockFromModule, genMockFromModule) each load the module they name: the original, or the
# original read to build a mock of its shape. A test file reaching a module that posts only through
# one of them, with no import, require or import() of it, passed: the gate followed none of those
# calls. Each is now followed as an import is, and one whose path is not written out is read as a
# require of a computed name is.
MK_RUN="./node_modules/.bin/vitest run"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./other.ts");'
allowed "#3020 the control: a module that posts nothing, loaded by vi.importActual, passes"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./posts.ts");'
read_refused "#3020 a module that posts, loaded only by vi.importActual, is followed and refused"
says "#3020 and the refusal names the module" "posts.ts"
mk_case b.test.ts 'const real = await vi.importActual<typeof Posts>("./posts.ts");'
read_refused "#3020 and with a type argument naming no import"
mk_case b.test.ts 'const real = await vi.importActual(`./posts.ts`);'
read_refused "#3020 and with the path in a template"
# A type argument written as an object type, or over several lines, holds { } = ; and line breaks,
# which the pattern left out, so the call matched nothing and the module was not followed (lessons
# review at d06d7aa).
mk_case b.test.ts 'const real = await vi.importActual<{ send: () => void }>("./posts.ts");'
read_refused "#3020 and with an object type as the type argument"
mk_case b.test.ts 'const real = await vi.importActual<{' '  send: (text: string) => Promise<void>;' '}>("./posts.ts");'
read_refused "#3020 and with one written over several lines"
mk_case b.test.ts 'const real = await vi.importActual<{ send: () => void }>("./other.ts");'
allowed "#3020 the control: the same type argument on a module that posts nothing passes"
mk_case b.test.ts 'const m = await vi.importMock("./posts.ts");'
read_refused "#3020 and by vi.importMock, which loads the module to mock its shape"
MK_RUN="./node_modules/.bin/jest"
for call in 'jest.requireActual("./posts")' 'jest.requireMock("./posts.ts")' 'jest.createMockFromModule("./posts.ts")' \
  'jest.genMockFromModule("./posts.ts")' 'jest . requireActual ( "./posts.ts" )'; do
  mk_case b.test.js "const m = $call;"
  read_refused "#3020 and by jest's loader: $call"
done
mk_case b.test.js 'const m = jest.requireActual("./other.ts");'
allowed "#3020 the control: jest.requireActual of a module that posts nothing passes"
mk_case b.test.js '// const m = jest.requireActual("./posts.ts");'
allowed "#3020 a loader call in a comment loads nothing"
mk_case b.test.js "const s = 'jest.requireActual(\"./posts.ts\")';"
allowed "#3020 nor one inside an ordinary string"
mk_case b.test.ts 'import { vi } from "vitest";' 'const real = await vi.importActual("./posts.ts");'
run_mk "node b.test.ts"
read_refused "#3020 the call is followed whatever runs the file"

echo
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

echo "slack drafts only: a launcher's package run is read as one beside a folder or a file of the same name (claude-config#3069)"

# Found by the #3050 builder on 2026-11-16: package_run (lib/program-runs.py) answered "not a package"
# for a spec naming anything on disk, so beside a folder named vitest `npx vitest run posts.test.ts`
# was read as a path. A path holding no / is read as nothing at all (a bare name is no file the shell
# or a launcher runs from the directory), so the test file the package was handed was never opened,
# and an endpoint in its arguments was not seen either. No launcher reads such a word as a file: npm
# takes a word for a path only where it starts with . / or ~, or holds a / outside a scope. So a
# package spec is always read as the package, and as the file of that name as well where there is
# one, the call refused where either reading refuses. A word that can only be a path (./x) was read as
# the file alone, and since #3083 (the section below) only where it names a script. Measured through this wrapper on main at 2963c2b: every command in the first list
# below passed but `npx @acme/tool --method chat.postMessage`, which was refused as a path run with an
# endpoint in its arguments, and every command in the list with no folder was refused.
PB="$T/p3069/beside"; PN="$T/p3069/alone"
mkdir -p "$PB/vitest" "$PB/tool" "$PB/@acme/tool" "$PN"
for side in "$PB" "$PN"; do
  printf '%s\n' 'import { it } from "vitest";' 'it("adds", () => {});' > "$side/quiet.test.ts"
  printf '%s\n' 'import { it } from "vitest";' 'it("posts", () => fetch("https://slack.com/api/chat.postMessage"));' > "$side/posts.test.ts"
  printf '%s\n' 'import { it } from "vitest";' 'import { post } from "./poster";' 'it("posts", () => post("hi"));' > "$side/imports-poster.test.ts"
  printf '%s\n' 'export const post = (t: string) => fetch("https://slack.com/api/chat.postMessage", { body: t });' > "$side/poster.ts"
  printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$side/msg.json"
  printf '%s\n' '{"text": "hi"}' > "$side/quiet.json"
done
: > "$PB/filetool"  # a file of the package's name, as the folders vitest, tool and @acme/tool are
printf '%s\n' '#!/bin/sh' 'echo quiet' > "$PB/@acme/quietdisk"
printf '%s\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > "$PB/@acme/ondisk"
printf '%s\n' '#!/bin/sh' 'echo quiet' > "$PB/runner"
printf '%s\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > "$PB/poster"
run_pb() { run_raw "$(payload Bash "$(bash_input "$1")" "$PB")"; }
run_pn() { run_raw "$(payload Bash "$(bash_input "$1")" "$PN")"; }
# Beside a folder, or a file, of the package's name: the package is handed a test file naming an
# endpoint, one importing a module that posts, a data file naming one, or an endpoint itself.
for runs in "npx vitest run posts.test.ts" "npx vitest run imports-poster.test.ts" "npx -y vitest run posts.test.ts" \
  "npm exec -- vitest run posts.test.ts" "npm x vitest run posts.test.ts" "pnpm dlx vitest run posts.test.ts" \
  "yarn dlx vitest run posts.test.ts" "bunx vitest run posts.test.ts" "pnpx vitest run posts.test.ts" \
  "npx tool msg.json" "npx tool --url https://hooks.slack.com/services/T0/B0/x" "npx @acme/tool msg.json" \
  "npx @acme/tool --method chat.postMessage" "npx filetool msg.json" "npx @acme/quietdisk msg.json" \
  "printf '%s\\n' 'quiet' > made && npx made msg.json"; do
  run_pb "$runs"
  read_refused "#3069 a package run beside a folder or a file of its name is still read as the package: $runs"
done
run_pb "npx vitest run posts.test.ts"
says "#3069 beside a folder of its name the refusal names the package" "the package vitest, run by npx,"
says "#3069 beside a folder of its name the refusal names the test file it was handed" "posts.test.ts"
BESIDE_SAYS="${ERR//"$PB"/}"
run_pb "npx vitest run imports-poster.test.ts"
says "#3069 beside a folder of its name a test file's imports are followed to the module that posts" "poster"
# The folder decides nothing: with none there the same commands are refused, in the same words.
for runs in "npx vitest run posts.test.ts" "npx vitest run imports-poster.test.ts" "npm exec -- vitest run posts.test.ts" \
  "npx tool msg.json" "npx tool --url https://hooks.slack.com/services/T0/B0/x" "npx @acme/tool msg.json"; do
  run_pn "$runs"
  read_refused "#3069 the same package run with no folder of its name is refused (the control): $runs"
done
run_pn "npx vitest run posts.test.ts"
if [ "${ERR//"$PN"/}" = "$BESIDE_SAYS" ]; then check "#3069 the refusal reads the same with a folder of the package's name and with none" ok
else check "#3069 the refusal reads the same with a folder of the package's name and with none" "beside: ${BESIDE_SAYS:0:200}, alone: ${ERR:0:200}"; fi
# And it refuses nothing more than the package reading does: handed nothing naming an endpoint, the
# run passes on both sides.
for runs in "npx vitest run quiet.test.ts" "npx vitest --version" "npm exec -- vitest run quiet.test.ts" \
  "pnpm dlx vitest run quiet.test.ts" "npx tool quiet.json" "npx @acme/tool quiet.json"; do
  run_pb "$runs"
  allowed "#3069 a package run beside a folder of its name, handed nothing naming an endpoint, passes: $runs"
  run_pn "$runs"
  allowed "#3069 the same package run with no folder of its name passes (the control): $runs"
done
run_pb "npx filetool quiet.json"
allowed "#3069 a package run beside a file of its name, handed nothing naming an endpoint, passes"
# The file of that name is still read as well, as before #3069: a script on disk that posts, or one
# this command wrote, is refused as that script even where the package is handed nothing.
for runs in "npx @acme/ondisk quiet.json" \
  "printf '%s\\n' '#!/bin/sh' 'curl https://hooks.slack.com/services/T0/B0/x' > @acme/made && npx @acme/made quiet.json"; do
  run_pb "$runs"
  read_refused "#3069 a package shaped word naming a script that posts is still read as that script too: $runs"
done
run_pb "npx @acme/ondisk quiet.json"
says "#3069 and the refusal is the script's, in the words it had before" "the script @acme/ondisk runs a command that posts"
# A path naming a script is read as the file alone, where the path reading is the right one:
# the gate reads the script, so a quiet one handed a data file naming an endpoint passes, which a
# package (code the gate cannot read) handed the same file does not, and one that posts is refused as
# the script it is.
run_pb "npx ./runner msg.json"
allowed "#3069 a path run through a launcher is read as the script there, not as a package: a quiet script handed a data file"
run_pb "npx runner msg.json"
read_refused "#3069 the same word with no ./ is a package, whatever file has its name"
run_pb "npx ./poster"
read_refused "#3069 a path naming a script that posts, run through a launcher, is refused as that script"
case "$ERR" in *"the package"*) check "#3069 a path's refusal does not call the script a package" "stderr: ${ERR:0:300}" ;;
  *) check "#3069 a path's refusal does not call the script a package" ok ;; esac

echo
echo "slack drafts only: a launcher handed a local package folder runs that package (claude-config#3083)"

# Left by #3069, measured on main at 2963c2b: `npx ./vitest run posts.test.ts` beside a local package
# folder ./vitest was read as that path alone. A folder is no script, so nothing was read and the test
# file the package was handed was never opened. npm runs the package the folder holds (a word starting
# with . / or ~ that names no archive is a folder to it), so the run is read as a package run too:
# every file it is handed is judged against a program the gate cannot read. The same for every word a
# launcher is handed that is no package name and no script on disk: the folder it runs in (.), a
# folder an earlier command makes, a path naming nothing yet, an archive, and a GitHub shorthand
# (owner/repo). A script on disk is still read as the script it is, as #3069 left it.
printf '%s\n' '{"name": "vitest", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/vitest/package.json"
printf '%s\n' '#!/usr/bin/env node' 'console.log("quiet")' > "$PB/vitest/cli.js"
printf '%s\n' '{"name": "tool", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/tool/package.json"
printf '%s\n' '{"name": "here", "version": "1.0.0", "bin": "./cli.js"}' > "$PB/package.json"
ln -s vitest "$PB/linked"
: > "$PB/pkg.tgz"
for runs in "npx ./vitest run posts.test.ts" "npx ./vitest run imports-poster.test.ts" "npx -y ./vitest run posts.test.ts" \
  "npx ./vitest/ run posts.test.ts" "npx $PB/vitest run posts.test.ts" "npm exec -- ./vitest run posts.test.ts" \
  "npm x ./vitest run posts.test.ts" "pnpm dlx ./vitest run posts.test.ts" "yarn dlx ./vitest run posts.test.ts" \
  "bunx ./vitest run posts.test.ts" "pnpx ./vitest run posts.test.ts" "npx ./tool msg.json" \
  "npx ./tool --url https://hooks.slack.com/services/T0/B0/x" "npx . run posts.test.ts" "npx ./linked run posts.test.ts" \
  "npx ./pkg.tgz run posts.test.ts" "npx ./nothing-there run posts.test.ts" "npx acme/tool-repo run posts.test.ts" \
  "mkdir -p fresh && npx ./fresh run posts.test.ts"; do
  run_pb "$runs"
  read_refused "#3083 a launcher's run of a local package folder is read as a package run: $runs"
done
run_pb "npx ./vitest run posts.test.ts"
says "#3083 the refusal names the folder as the package the launcher runs" "the package ./vitest, run by npx,"
says "#3083 the refusal names the test file the package was handed" "posts.test.ts"
run_pb "npx ./vitest run imports-poster.test.ts"
says "#3083 a test file's imports are followed to the module that posts" "poster"
# It refuses nothing more than a package run does: handed nothing naming an endpoint, the run passes.
for runs in "npx ./vitest run quiet.test.ts" "npx ./vitest --version" "npm exec -- ./vitest run quiet.test.ts" \
  "pnpm dlx ./vitest run quiet.test.ts" "npx ./tool quiet.json" "npx . run quiet.test.ts" \
  "npx ./nothing-there run quiet.test.ts" "mkdir -p fresh && npx ./fresh run quiet.test.ts"; do
  run_pb "$runs"
  allowed "#3083 a launcher's run of a local package folder, handed nothing naming an endpoint, passes: $runs"
done
# The controls. A script on disk is read as the script it is, so a quiet one handed a data file naming
# an endpoint still passes (#3069's own case, run again here beside the folders), as does one an
# earlier command of the call writes; and a word the gate cannot work out is left as it was (#2683).
run_pb "npx ./runner msg.json"
allowed "#3083 a script on disk run through a launcher is still read as that script alone"
run_pb "printf '%s\\n' '#!/bin/sh' 'echo quiet' > made.sh && npx ./made.sh msg.json"
allowed "#3083 a script an earlier command writes, run through a launcher, is still read as that script alone"
run_pb 'npx "$SOMEWHERE/tool" msg.json'
allowed "#3083 a word the gate cannot work out is left as it was"

echo
echo "slack drafts only: a file that only declares the webhook's name is not one that posts (claude-config#3050)"

# On 2026-11-15, in a work repository whose worker has a Slack module, three runs of test files by
# name were refused: one file's fixtures held the word slack_webhook, one imported a module that
# names it, and one imported a route reaching the module that sends. The first two name the variable
# without reading it. slack_webhook is the name projects keep a webhook in, never an address, so a
# file posts through it only by reading what is kept under it. Two uses read nothing and are now
# left out: the name as an object literal's key set to null, undefined or a string that is no
# address anyone receives at, and the name as a member of an interface or a type alias, which is
# erased. Every other use (a member read, a destructuring, a string, a key set to anything else)
# refuses as before, and so does the third run, which reaches a module that reads the name and
# sends. These files are written from the issue's words: the work repository is not on this Mac.
printf '%s\n' 'export async function notify(env: { SLACK_WEBHOOK_URL?: string }, text: string) {' \
  '  if (env.SLACK_WEBHOOK_URL) await fetch(env.SLACK_WEBHOOK_URL, { method: "POST", body: text });' '}' > "$MK/hook.ts"
printf '%s\n' 'import { notify } from "./hook.ts";' 'export const run = (env: object, text: string) => notify(env, text);' > "$MK/engine.ts"
printf '%s\n' 'import { run } from "./engine.ts";' 'export const handle = (env: object) => run(env, "hi");' > "$MK/route.ts"
printf '%s\n' 'export interface Env {' '  DB: unknown;' '  SLACK_WEBHOOK_URL?: string;' '}' \
  'export type Team = { id: string; slack_webhook: string | null };' 'export const DEFAULTS = { retries: 3 };' > "$MK/env.ts"
printf '%s\n' 'export const rank = (rows: { id: string }[]) => rows.map((r) => r.id);' > "$MK/rank.ts"
MK_RUN="./node_modules/.bin/vitest run"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' 'it("ranks", () => expect(rank([{ id: "t1" }])).toEqual(["t1"]));'
allowed "#3050 the control: a test file naming nothing passes"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' \
  'const team = { id: "t1", slack_webhook: null };' 'it("ranks", () => expect(rank([team])).toEqual(["t1"]));'
allowed "#3050 a test file whose fixture row holds the name as a key set to null passes"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { rank } from "./rank.ts";' \
  'const env = { DB: null, SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' 'it("ranks", () => expect(rank([])).toEqual([]));'
allowed "#3050 and as a key of a worker's env set to an address reserved for tests"
for value in 'undefined' '""' "'fake-hook'" '"http://localhost:8787/hook"' '"https://example.com/hook"' '"https://hooks.slack.invalid/x"'; do
  mk_case c.test.ts "const team = { id: 't1', slack_webhook: $value, name: 'a' };"
  allowed "#3050 a key set to a value that is no address anyone receives at passes: $value"
done
mk_case c.test.ts 'const rows = [' '  {' '    id: "t1",' '    "slack_webhook": null,' '  },' '  { id: "t2", slack_webhook_url: undefined },' '];'
allowed "#3050 a quoted key, and keys over several lines, pass"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { DEFAULTS } from "./env.ts";' 'it("retries", () => expect(DEFAULTS.retries).toBe(3));'
allowed "#3050 a test file importing a module that names it only in an interface and a type alias passes"
printf '%s\n' 'import { DEFAULTS } from "./env.ts";' 'console.log(DEFAULTS);' > "$MK/d.test.ts"
run_mk "./node_modules/.bin/vitest run c.test.ts d.test.ts"
allowed "#3050 and with several test files named in one run"
# Handed to the runner by a launcher, as the three runs of the issue were, in $D9. Since #3069 the
# gate reads `npx vitest` as the package run even beside a folder named vitest.
cp "$MK/env.ts" "$MK/hook.ts" "$D9/src/"
printf '%s\n' 'import { expect, it } from "vitest";' 'import { DEFAULTS } from "./env";' \
  'const team = { id: "t1", slack_webhook: null };' 'it("retries", () => expect(DEFAULTS.retries).toBe(3));' > "$D9/src/declares.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'const env = { DB: null, SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' \
  'it("adds", () => {});' > "$D9/src/env-fixture.test.ts"
printf '%s\n' 'import { it } from "vitest";' 'import { notify } from "./hook";' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.example.test/T0/B0/x" };' 'it("notifies", () => notify(env, "hi"));' > "$D9/src/notifies.test.ts"
for runs in "npx vitest run src/declares.test.ts" "pnpm dlx vitest run src/declares.test.ts" "bunx vitest run src/env-fixture.test.ts" \
  "./node_modules/.bin/vitest run src/declares.test.ts" "npx vitest run src/declares.test.ts src/env-fixture.test.ts src/quiet.test.ts"; do
  run_d9 "$runs"
  allowed "#3050 test files that only declare the name pass, handed to the runner by a launcher: $runs"
done
for runs in "npx vitest run src/notifies.test.ts" "pnpm dlx vitest run src/notifies.test.ts" "./node_modules/.bin/vitest run src/notifies.test.ts" \
  "npx vitest run src/declares.test.ts src/notifies.test.ts" "npx vitest run src/notifies.test.ts src/declares.test.ts"; do
  run_d9 "$runs"
  read_refused "#3050 a test file importing the module that reads the name and sends is still refused: $runs"
  says "#3050 and the refusal names that module: $runs" "hook"
done
MK_RUN="./node_modules/.bin/jest"
mk_case c.spec.ts 'import { DEFAULTS } from "./env.ts";' 'const team = { id: "t1", slack_webhook: null };'
allowed "#3050 and run by jest"
run_mk "node c.spec.ts"
allowed "#3050 the reading is of the file's text, so it is the same whatever runs the file"
# The third run of the issue reaches a module that reads the name and sends, so it is refused still,
# through every loader the gate follows, with a declared name beside the loader hiding nothing.
MK_RUN="./node_modules/.bin/vitest run"
mk_case c.test.ts 'import { expect, it } from "vitest";' 'import { handle } from "./route.ts";' 'it("handles", () => expect(handle({})).toBeDefined());'
read_refused "#3050 a test file whose route reaches the module that reads the name and sends is still refused"
says "#3050 and the refusal names that module" "hook.ts"
says "#3050 and the name it reads" "it names SLACK_WEBHOOK"
for target in ./hook.ts ./posts.ts; do
  for line in "import { x } from \"$target\";" "import \"$target\";" "export * from \"$target\";" "const m = await import(\"$target\");" \
    "const m = require(\"$target\");" "const m = await vi.importActual(\"$target\");" "const m = await vi.importMock(\"$target\");" \
    "const m = await vi.importActual<{ send: () => void }>(\"$target\");" "const m = jest.requireActual(\"$target\");" \
    "const m = jest.requireMock(\"$target\");" "const m = jest.createMockFromModule(\"$target\");" "const m = jest.genMockFromModule(\"$target\");"; do
    mk_case c.test.ts 'const env = { SLACK_WEBHOOK_URL: "https://hooks.example.test/x", slack_webhook: null };' "$line"
    read_refused "#3050 a module that can post is still refused beside a declared name, reached by: $line"
  done
done
run_mk "./node_modules/.bin/vitest run d.test.ts c.test.ts"
read_refused "#3050 and named after a file that only declares the name"
# Every use that reads the name, or sets it to something the gate cannot see is no address, refuses
# as before, in the test file itself and in a module it imports.
for line in 'const hook = env.SLACK_WEBHOOK_URL;' \
  'const { SLACK_WEBHOOK_URL } = process.env;' \
  'const { slack_webhook: hook } = row;' \
  'const env = { SLACK_WEBHOOK_URL: process.env.HOOK };' \
  'const env = { SLACK_WEBHOOK_URL: hook };' \
  'const env = { SLACK_WEBHOOK_URL };' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.slack.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test@hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "hooks.slack-gov.com/services/T0/B0/x" };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/" + id };' \
  'const env = { SLACK_WEBHOOK_URL: `https://${host}/x` };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/\x2e" };' \
  'const env = { SLACK_WEBHOOK_URL: null as unknown as string };' \
  'const env = { SLACK_WEBHOOK_URL: null ?? hook };' \
  'const env = { SLACK_WEBHOOK_URL: null, ...process.env };' \
  'const env = { SLACK_WEBHOOK_URL: "https://example.test/x", DB: { rows: [] }, ...real };' \
  'const pick = { select: { slack_webhook: true } };' \
  'const pick = { slack_webhook: 1 };' \
  'const key = "SLACK_WEBHOOK_URL";' \
  'const hook = on ? slack_webhook : null;' \
  'const hook = [on ? a : b, slack_webhook][1];' \
  'function send(a, slack_webhook) { return fetch(slack_webhook); }' \
  'process.env.SLACK_WEBHOOK_URL = "https://example.test/x";' \
  'function f(env: { SLACK_WEBHOOK_URL: string }) { return env; }' \
  'class Env { SLACK_WEBHOOK_URL = process.env.HOOK; }' \
  'const type = { SLACK_WEBHOOK_URL: string };' \
  'const env = { SLACK_WEBHOOK_URL: null };  const hook = env.SLACK_WEBHOOK_URL;' \
  'interface Env { SLACK_WEBHOOK_URL?: string }  const hook = env.SLACK_WEBHOOK_URL;' \
  'interface Env { SLACK_WEBHOOK_URL: typeof hook }' \
  'interface Env { SLACK_WEBHOOK_URL: string }  const env = { SLACK_WEBHOOK_URL: string };'; do
  mk_case c.test.ts "$line"
  read_refused "#3050 a use that is no bare declaration stays refused: $line"
  says "#3050 as a file naming what posts: $line" "c.test.ts posts to Slack (it names "
  printf '%s\n' "$line" 'export const DEFAULTS = { retries: 3 };' > "$MK/uses.ts"
  mk_case c.test.ts 'import { DEFAULTS } from "./uses.ts";'
  read_refused "#3050 and in a module the test file imports: $line"
  says "#3050 named as that module: $line" "uses.ts), which posts to Slack (it names "
done
mk_case c.test.ts 'const base = { DB: null };' 'const env = { ...base, SLACK_WEBHOOK_URL: "https://example.test/x", nested: { ...base } };'
allowed "#3050 a spread before the key, or inside a value after it, leaves the key as written"
# A fixture file can hold the name once per row, so the reading is judged at that size too: 5,000
# rows, each read by stepping back to its own row's brace and never by a copy of the file.
{
  printf '%s\n' 'export const rows = ['
  for ((i = 0; i < 5000; i++)); do printf '  { id: "t%d", slack_webhook: null, name: "team %d" },\n' "$i" "$i"; done
  printf '%s\n' '];'
} > "$MK/rows.ts"
mk_case c.test.ts 'import { rows } from "./rows.ts";'
allowed "#3050 a fixture module holding the name in each of 5,000 rows is read in time and passes"
# And written on one line, as a generated fixture is, where anything read per name back to the start
# of its line is read 5,000 times over the whole file.
{
  printf '%s' 'export const rows = ['
  for ((i = 0; i < 5000; i++)); do printf '{ id: "t%d", slack_webhook: null, name: "team %d" },' "$i" "$i"; done
  printf '%s\n' '];'
} > "$MK/rows-line.ts"
mk_case c.test.ts 'import { rows } from "./rows-line.ts";'
allowed "#3050 and the same 5,000 rows on one line"
printf '%s\n' 'export const last = { id: "t5000", slack_webhook: process.env.HOOK };' >> "$MK/rows.ts"
mk_case c.test.ts 'import { rows } from "./rows.ts";'
read_refused "#3050 and one row among them set to something else is still found"
# A key built in brackets is no declared name. The name in a string inside brackets reads as a list's
# element, held only as data (#2913), which a runner able to send refuses as it always did.
mk_case c.test.ts 'const env = { ["SLACK_WEBHOOK_URL"]: process.env.HOOK };'
read_refused "#3050 a key computed from a string stays refused"
# A header and its { on two lines is not read as a type's: in JavaScript `type` and `interface` are
# names there, and the braces a block holding a label.
mk_case c.test.ts 'type' 'Env = { SLACK_WEBHOOK_URL: string };'
read_refused "#3050 a type alias whose header is split over lines is not read as one"
mk_case c.test.ts 'interface Env' '{ SLACK_WEBHOOK_URL: string }'
read_refused "#3050 nor an interface whose brace is on the next line"
# The other names are addresses, and a file holding one is judged as before whatever it is set to.
mk_case c.test.ts 'const methods = { "chat.postMessage": null, chat_postMessage: null };'
read_refused "#3050 a posting method as a key is not a declared name"
mk_case c.test.ts 'interface Hosts { "hooks.slack.com": string }'
read_refused "#3050 nor a webhook's host as a member of an interface"
# A shell script and a Python script are read as before: this reading is of JavaScript and TypeScript.
printf '%s\n' 'ENV = {"SLACK_WEBHOOK_URL": None}' > "$MK/names.py"
run_mk "python3 names.py"
read_refused "#3050 a Python script naming it is unchanged"
printf '%s\n' '#!/bin/bash' 'curl -d hi "$SLACK_WEBHOOK_URL"' > "$MK/send.sh"
run_mk "bash send.sh"
refused "#3050 a shell script sending to what the variable holds is refused"
run_mk "node -e 'const env = { SLACK_WEBHOOK_URL: null }; fetch(process.env.SLACK_WEBHOOK_URL)'"
refused "#3050 and code given inline"

echo
echo "slack drafts only: a script that uses os only to read is one the gate has read end to end (claude-config#3085)"

# The global rules file names chat.postMessage in its own Slack rule, so every script handed
# payload/CLAUDE.md, or a copy of it, was refused as one that posts the moment it imported os: on
# 2026-11-16 a measuring script, the #2575 trim script and a builder's plain read of the file. Across
# this project's session records "imports os" was the commonest reason a script handed a data file
# was refused (54 of the 213 such refusals found, measured 2026-11-16). Dan chose the rule that day:
# trust only a program the gate can read end to end. So os is read as every other module is, use by
# use: the names that read a file, a path or the environment (OS_READS) pass, and any other use of
# os (a program started, a file written, os handed on or renamed) is refused as before, as is
# anything the gate cannot follow. The file handed below is the real rules file beside this hooks
# folder, copied, with the Slack rule line that named chat.postMessage put back on its end: #3084
# (the #2575 trim) took that line out, so the real file alone no longer names an endpoint, and every
# case below would pass for that reason instead of the one it measures. The control just after
# checks the copy still names one.
D85="$T/d3085"
mkdir -p "$D85/rules"
RULES="$D85/rules/CLAUDE.md"
cp "$(cd "$DIR/.." && pwd)/CLAUDE.md" "$RULES"
printf '%s\n' '- Never post another way (`curl` to `chat.postMessage`, a webhook, a script) to get around it.' >> "$RULES"
printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$D85/msg.json"
run_85() { run_raw "$(payload Bash "$(bash_input "$1")" "$D85")"; }
printf '%s\n' 'import json, sys, urllib.request' 'urllib.request.urlopen(open(sys.argv[1]).read()[:40])' > "$D85/sends.py"
run_85 "python3 sends.py $RULES"
read_refused "#3085 the control: a script that can send, handed the real rules file, is refused"
says "#3085 because the rules file names an endpoint, which is what makes the cases below a measurement" "CLAUDE.md, which names chat.postMessage"
cat > "$D85/reads-os.py" <<'PY'
import os, sys
text = open(sys.argv[1]).read()
here = os.path.dirname(os.path.abspath(sys.argv[1]))
print(len(text), os.getcwd(), os.environ.get("HOME"), os.getenv("USER"), os.sep, os.name)
for name in sorted(os.listdir(here)):
    print(name, os.stat(os.path.join(here, name)).st_size)
for root, dirs, files in os.walk(here):
    print(root, len(files))
PY
cat > "$D85/reads-os-as.py" <<'PY'
import os as o, sys
print(o.path.getsize(sys.argv[1]), o.getpid(), o.access(sys.argv[1], o.R_OK), [e.name for e in o.scandir(".")])
PY
cat > "$D85/reads-from-os.py" <<'PY'
import sys
from os import environ, getcwd, listdir, path
print(path.basename(sys.argv[1]), getcwd(), environ.get("HOME"), len(listdir(".")), len(open(sys.argv[1]).read()))
PY
cat > "$D85/reads-ospath.py" <<'PY'
import os.path, sys
print(os.path.getsize(sys.argv[1]), os.getcwd())
PY
cat > "$D85/lib_sizes.py" <<'PY'
import os
def size(p):
    return os.stat(p).st_size
PY
cat > "$D85/reads-via.py" <<'PY'
import sys
import lib_sizes
print(lib_sizes.size(sys.argv[1]))
PY
for reads in reads-os.py reads-os-as.py reads-from-os.py reads-ospath.py reads-via.py; do
  run_85 "python3 $reads $RULES"
  allowed "#3085 a script that uses os only to read, handed the real rules file: $reads"
  run_85 "python3 $reads msg.json"
  allowed "#3085 the same script handed a data file naming the endpoint: $reads"
done
run_85 "python3 -c 'import os, sys; print(os.path.getsize(sys.argv[1]), os.getcwd())' $RULES"
allowed "#3085 code given inline that uses os only to read, handed the real rules file"
run_85 "python3 - $RULES <<'PY'
import os, sys
print(len(open(sys.argv[1]).read()), os.getcwd())
PY"
allowed "#3085 code fed on standard input that uses os only to read, handed the real rules file"
# Everything else os can do is still refused, each handed the same file: a program started every
# way os offers, os handed on, renamed or reached through another name, a file written or removed
# (writing counts for a script file, as it does without os), and a module beside the script that
# does any of it. Each says what it found, so the script is fixed rather than moved.
w85() { local name="$1"; shift; printf '%s\n' "$@" > "$D85/$name"; }
w85 os-system.py 'import os, sys' 'os.system("curl -d @" + sys.argv[1] + " https://example.com")'
w85 os-popen.py 'import os, sys' 'os.popen("bash " + sys.argv[1])'
w85 os-exec.py 'import os, sys' 'os.execvp("bash", ["bash", sys.argv[1]])'
w85 os-spawn.py 'import os, sys' 'os.posix_spawn("/bin/bash", ["bash", sys.argv[1]], os.environ)'
w85 os-fork.py 'import os, sys' 'if os.fork() == 0:' '    print(open(sys.argv[1]).read())'
w85 os-startfile.py 'import os, sys' 'os.startfile(sys.argv[1])'
w85 os-alias.py 'import os, sys' 'tool = os' 'tool.system("bash " + sys.argv[1])'
w85 os-passed.py 'import os, sys' 'def go(m):' '    m.system("bash " + sys.argv[1])' 'go(os)'
w85 os-getattr.py 'import os, sys' 'getattr(os, "sys" + "tem")("bash " + sys.argv[1])'
w85 os-as.py 'import os as o, sys' 'o.system("bash " + sys.argv[1])'
w85 os-from.py 'import sys' 'from os import system' 'system("bash " + sys.argv[1])'
w85 os-from-star.py 'import sys' 'from os import *' 'system("bash " + sys.argv[1])'
w85 os-pathos.py 'import os, sys' 'os.path.os.system("bash " + sys.argv[1])'
w85 os-dunder.py 'import os, sys' 'os.walk.__globals__["system"]("bash " + sys.argv[1])'
w85 os-remove.py 'import os, sys' 'os.remove(sys.argv[1])'
w85 os-rename.py 'import os, sys' 'os.rename(sys.argv[1], "/tmp/run-later.sh")'
w85 os-open.py 'import os, sys' 'fd = os.open("/tmp/run-later.sh", os.O_WRONLY | os.O_CREAT)' 'os.write(fd, open(sys.argv[1], "rb").read())'
w85 os-symlink.py 'import os, sys' 'os.symlink(sys.argv[1], "/tmp/run-later.sh")'
w85 os-chmod.py 'import os, sys' 'os.chmod(sys.argv[1], 0o755)'
w85 os-putenv.py 'import os, sys' 'os.putenv("BASH_ENV", sys.argv[1])'
w85 os-ospath-only.py 'import os.path, sys' 'os.system("bash " + sys.argv[1])'
w85 os-subprocess.py 'import os, subprocess, sys' 'subprocess.run(["bash", sys.argv[1]], cwd=os.getcwd())'
w85 os-unparsed.py 'import os, sys' 'print(os.getcwd(' 'os.system("bash " + sys.argv[1])'
w85 os-unplaced.py 'import os, sys' 'import no_such_module_3085' 'print(os.getcwd())'
w85 lib_runner.py 'import os' 'def go(p):' '    os.system("bash " + p)'
w85 os-via.py 'import sys' 'import lib_runner' 'lib_runner.go(sys.argv[1])'
for acts in os-system.py os-popen.py os-exec.py os-spawn.py os-fork.py os-startfile.py os-alias.py os-passed.py \
  os-getattr.py os-as.py os-from.py os-from-star.py os-pathos.py os-dunder.py os-remove.py os-rename.py \
  os-open.py os-symlink.py os-chmod.py os-putenv.py os-ospath-only.py os-subprocess.py os-unparsed.py \
  os-unplaced.py os-via.py; do
  run_85 "python3 $acts $RULES"
  read_refused "#3085 a script that uses os for more than reading, handed the real rules file, is still refused: $acts"
done
run_85 "python3 os-system.py $RULES"
says "#3085 the refusal names the use of os that is more than reading" "uses os for more than reading files, paths and the environment (os.system)"
run_85 "python3 os-alias.py $RULES"
says "#3085 and os handed on under another name" "uses os for more than reading files, paths and the environment (os, handed on or renamed)"
run_85 "python3 os-remove.py $RULES"
says "#3085 and a removal, which is a write" "(os.remove)"
run_85 "python3 os-via.py $RULES"
says "#3085 and a module beside the script that starts a program" "lib_runner.py"
run_85 "python3 -c 'import os, sys; os.system(\"bash \" + sys.argv[1])' $RULES"
read_refused "#3085 code given inline that starts a program through os, handed the real rules file, is still refused"
# Code a shell script writes inline keeps the wider list it had (OS_FILES, claude-config#2446), where
# writing a file is not counted: os.remove passes there and os.system does not, as before.
cat > "$D85/inline-remove.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
print(len(open(sys.argv[1]).read()))
os.remove("/tmp/scratch-3085.txt")
PY
SH
cat > "$D85/inline-system.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import os, sys
os.system("bash " + sys.argv[1])
PY
SH
run_85 "bash inline-remove.sh $RULES"
allowed "#3085 code a shell script writes inline may still remove a file through os, as before"
run_85 "bash inline-system.sh $RULES"
read_refused "#3085 and still may not start a program through it"
says "#3085 in the words that refusal had before" "uses os for more than its file, path and environment calls"
# What the gate cannot follow is still refused, which is the other half of Dan's rule: a shell
# script whose loop reads the file it is handed, and asks a library it sources about each line
# (the push gates builder's measuring script, 2026-11-16, refused over a file of command texts
# naming an endpoint). The loop's reads, and what a sourced library's functions do with what they
# are handed, are two things the gate does not read, so this is not one it has read end to end.
printf '%s\n' 'is_push() { grep -Eq "git push" <<< "$1"; }' > "$D85/questions.sh"
printf '%s\n' 'curl -s https://slack.com/api/chat.postMessage -d text=hi' 'git push origin main' > "$D85/commands.txt"
cat > "$D85/routes.sh" <<SH
#!/usr/bin/env bash
set -u
IN="\$1"
. $D85/questions.sh || exit 2
count=0
while IFS= read -r cmd; do
  is_push "\$cmd" && count=\$((count + 1))
done < "\$IN"
echo "pushes: \$count"
SH
run_85 "bash routes.sh commands.txt"
read_refused "#3085 a shell script whose loop reads the file it is handed is still refused: the gate does not follow the loop"
says "#3085 and the refusal says that is why" "a loop or block whose reads the gate does not follow"

echo
echo "slack drafts only: a module given another name is still followed (claude-config#3102)"

# The gate reads a module's attributes only from a name an import binds, so `q = pathlib` and then
# q.os.system(...) was read as unable to act, and the data file the script was handed went unchecked
# for a Slack posting address. Measured 2026-11-16 by the cases below against the gate as it stood:
# every one marked "renamed", "handed on" or "imported out of" passed. A name is now followed through
# each binding the gate can read (an assignment, an annotated one, a walrus, a tuple assignment, a
# for loop or comprehension over a list written out, a parameter's default), and a module put
# anywhere it cannot follow (an argument, a list, an attribute, a class body, a return) counts as
# the script being able to act. Whether what is handed on is a module is asked of the standard
# library module itself (lib/py-aliases.py), so os.path.getsize handed to sorted() is a function
# and passes, and os.path handed to a helper is a module and does not.
D02="$T/d3102"
mkdir -p "$D02"
printf '%s\n' '{"text": "hi", "url": "https://slack.com/api/chat.postMessage"}' > "$D02/msg.json"
run_02() { run_raw "$(payload Bash "$(bash_input "$1")" "$D02")"; }
w02() { local name="$1"; shift; printf '%s\n' "$@" > "$D02/$name"; }
ACT02='.os.system("bash " + sys.argv[1])'
w02 direct.py 'import glob, sys' "glob$ACT02"
run_02 "python3 direct.py msg.json"
read_refused "#3102 the control: a module reached through an imported name, handed a data file naming an endpoint, is refused"
says "#3102 in the words the renamed forms below must now get too" "reaches the os module through glob"
# Renamed by a binding the gate follows: the new name is read as the imported one is.
w02 assign.py 'import pathlib, sys' 'q = pathlib' "q$ACT02"
w02 assign-glob.py 'import glob, sys' 'q = glob' "q$ACT02"
w02 ospath.py 'import os, sys' 'p = os.path' "p$ACT02"
w02 twice.py 'import glob, sys' 'a = glob' 'b = a' "b$ACT02"
w02 annotated.py 'import glob, sys' 'q: object = glob' "q$ACT02"
w02 chained.py 'import glob, sys' 'a = b = glob' "b$ACT02"
w02 walrus.py 'import glob, sys' "(q := glob)$ACT02"
w02 walrus-if.py 'import glob, sys' 'if (q := glob):' "    q$ACT02"
w02 tuple.py 'import glob, sys' 'q, r = glob, 1' "q$ACT02"
w02 for.py 'import glob, sys' 'for m in (glob,):' "    m$ACT02"
w02 comprehension.py 'import glob, sys' "[m$ACT02 for m in [glob]]"
w02 default.py 'import glob, sys' 'def go(p, m=glob):' '    m.os.system("bash " + p)' 'go(sys.argv[1])'
w02 kw-default.py 'import glob, sys' 'def go(p, *, m=glob):' '    m.os.system("bash " + p)' 'go(sys.argv[1])'
w02 lambda-default.py 'import glob, sys' '(lambda p, m=glob: m.os.system("bash " + p))(sys.argv[1])'
w02 submodule.py 'import glob, sys' 'f = glob.fnmatch' "f$ACT02"
w02 lib_q.py 'import glob as helper'
w02 local.py 'import lib_q, sys' 'h = lib_q.helper' "h$ACT02"
# A walrus inside a function, a method or a lambda binds a name of that function, which is followed.
w02 function-walrus.py 'import glob, sys' 'def go(p):' '    (q := glob)' '    q.os.system("bash " + p)' 'go(sys.argv[1])'
w02 method-walrus.py 'import glob, sys' 'class H:' '    def go(self, p):' '        (q := glob)' '        q.os.system("bash " + p)' 'H().go(sys.argv[1])'
w02 lambda-walrus.py 'import glob, sys' '(lambda p: [(q := glob), q.os.system("bash " + p)])(sys.argv[1])'
for renamed in assign.py assign-glob.py ospath.py twice.py annotated.py chained.py walrus.py walrus-if.py tuple.py \
  for.py comprehension.py default.py kw-default.py lambda-default.py submodule.py local.py \
  function-walrus.py method-walrus.py lambda-walrus.py; do
  run_02 "python3 $renamed msg.json"
  read_refused "#3102 a module renamed and then used to start a program is refused: $renamed"
done
run_02 "python3 assign.py msg.json"
says "#3102 the refusal names the module reached and the name it was reached through" "reaches the os module through q"
run_02 "python3 ospath.py msg.json"
says "#3102 and for os.path given another name" "reaches the os module through p"
run_02 "python3 -c 'import glob, sys; q = glob; q.os.system(\"bash \" + sys.argv[1])' msg.json"
read_refused "#3102 code given inline that renames a module is refused"
cat > "$D02/inline-renamed.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import glob, sys
q = glob
q.os.system("bash " + sys.argv[1])
PY
SH
run_02 "bash inline-renamed.sh msg.json"
read_refused "#3102 and code a shell script writes inline"
# Put where the gate does not follow it: an argument, a list, a dictionary, an attribute, a class
# body, a return, a lambda, one arm of a choice, a comparison another object answers, an assignment
# whose two sides it cannot pair, and the two standard library calls that read attributes by name
# (string.Formatter.get_field, functools.update_wrapper).
w02 argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(glob, sys.argv[1])'
w02 ospath-argument.py 'import os, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(os.path, sys.argv[1])'
w02 submodule-argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(glob.fnmatch, sys.argv[1])'
w02 local-argument.py 'import lib_q, sys' 'def go(m, p):' '    m.helper.os.system("bash " + p)' 'go(lib_q, sys.argv[1])'
w02 list.py 'import glob, sys' "[glob][0]$ACT02"
w02 dictionary.py 'import glob, sys' "{'m': glob}['m']$ACT02"
w02 choice.py 'import glob, sys' "(glob if sys.argv else None)$ACT02"
w02 either.py 'import glob, sys' 'q = glob or None' "q$ACT02"
w02 starred.py 'import glob, sys' 'q, *r = glob, 1' "q$ACT02"
w02 attribute.py 'import glob, sys' 'class H: pass' 'h = H()' 'h.m = glob' "h.m$ACT02"
w02 ospath-attribute.py 'import os, sys' 'class H: pass' 'h = H()' 'h.m = os.path' "h.m$ACT02"
w02 class-body.py 'import glob, sys' 'class H:' '    m = glob' "H.m$ACT02"
w02 return.py 'import glob, sys' 'def get():' '    return glob' "get()$ACT02"
w02 lambda.py 'import glob, sys' "(lambda: glob)()$ACT02"
w02 comparison.py 'import glob, sys' 'class E:' '    def __eq__(self, o):' '        o.os.system("bash " + sys.argv[1])' 'E() == glob'
w02 renamed-argument.py 'import glob, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'q = glob' 'go(q, sys.argv[1])'
w02 get-field.py 'import glob, string, sys' 'string.Formatter().get_field("0.os.system", (glob,), {})[0]("bash " + sys.argv[1])'
w02 update-wrapper.py 'import functools, glob, sys' 'class H: pass' 'h = H()' 'functools.update_wrapper(h, glob, assigned=())' "h$ACT02"
# A walrus whose name the gate does not follow is a place like any other the module has gone to
# (the lessons review of PR #3130 at 4c7dc1b): one in a class body, whose bindings are not followed,
# and one over a value the gate does not read as a name or a chain (a choice of two, another
# walrus). Each was read as going wherever the whole expression went, a statement left alone, so the
# module was neither followed as renamed nor counted as handed on. And the other bindings of a
# class body (a loop, a comprehension, a method's default, a lambda's), and a walrus inside a
# comprehension or a default, which were refused already and are kept so.
w02 class-walrus.py 'import glob, sys' 'class H:' '    (q := glob)' "    q$ACT02"
w02 class-walrus-if.py 'import glob, sys' 'class H:' '    if (q := glob):' "        q$ACT02"
w02 class-walrus-attribute.py 'import glob, sys' 'class H:' '    (q := glob)' "H.q$ACT02"
w02 class-walrus-ospath.py 'import os, sys' 'class H:' '    (p := os.path)' "    p$ACT02"
w02 walrus-either.py 'import glob, sys' '(q := glob or None)' "q$ACT02"
w02 walrus-nested.py 'import glob, sys' '(q := (r := glob))' "q$ACT02"
w02 class-for.py 'import glob, sys' 'class H:' '    for m in (glob,):' "        m$ACT02"
w02 class-comprehension.py 'import glob, sys' 'class H:' "    [m$ACT02 for m in [glob]]"
w02 class-default.py 'import glob, sys' 'class H:' '    def go(self, p, m=glob):' '        m.os.system("bash " + p)' 'H().go(sys.argv[1])'
w02 class-lambda-default.py 'import glob, sys' 'class H:' '    go = lambda p, m=glob: m.os.system("bash " + p)' 'H.go(sys.argv[1])'
w02 comprehension-walrus.py 'import glob, sys' '[(q := glob) for _ in (1,)]' "q$ACT02"
w02 default-walrus.py 'import glob, sys' 'def go(p, m=(q := glob)):' '    q.os.system("bash " + p)' 'go(sys.argv[1])'
w02 lambda-default-walrus.py 'import glob, sys' '(lambda p, m=(q := glob): q.os.system("bash " + p))(sys.argv[1])'
for handed in argument.py ospath-argument.py submodule-argument.py local-argument.py list.py dictionary.py choice.py \
  either.py starred.py attribute.py ospath-attribute.py class-body.py return.py lambda.py comparison.py \
  renamed-argument.py get-field.py update-wrapper.py class-walrus.py class-walrus-if.py class-walrus-attribute.py \
  class-walrus-ospath.py walrus-either.py walrus-nested.py class-for.py class-comprehension.py class-default.py \
  class-lambda-default.py comprehension-walrus.py default-walrus.py lambda-default-walrus.py; do
  run_02 "python3 $handed msg.json"
  read_refused "#3102 a module handed on where the gate does not follow it is refused: $handed"
done
run_02 "python3 argument.py msg.json"
says "#3102 the refusal names the module handed on" "puts the module glob where the gate does not follow it"
run_02 "python3 ospath-argument.py msg.json"
says "#3102 and os.path, which is a module" "puts the module os.path where the gate does not follow it"
run_02 "python3 class-walrus.py msg.json"
says "#3102 and a walrus in a class body, in the same words" "puts the module glob where the gate does not follow it"
run_02 "python3 walrus-either.py msg.json"
says "#3102 and a walrus over a choice of two" "puts the module glob where the gate does not follow it"
# A module imported out of another module's namespace is the same reach written as an import.
w02 from-module.py 'import sys' 'from glob import os' 'os.system("bash " + sys.argv[1])'
w02 from-module-as.py 'import sys' 'from glob import os as tool' 'tool.system("bash " + sys.argv[1])'
for imported in from-module.py from-module-as.py; do
  run_02 "python3 $imported msg.json"
  read_refused "#3102 a module imported out of another module's namespace is refused: $imported"
done
run_02 "python3 from-module.py msg.json"
says "#3102 the refusal names the module and where it was imported from" "imports os from glob, which reaches the os module through glob"
# The controls: read only scripts that rename a module, hand its functions and classes on, and test
# whether it was imported still pass, handed the same data file and the real rules file. Each of
# these shapes is ordinary: a function as a sort key, a class as an argument's type, a class in an
# isinstance or an except, a module kept under a shorter name.
cat > "$D02/reads-renamed.py" <<'PY'
import argparse, datetime, json, os, pathlib, re, sys
from datetime import time, timezone
from os import path
from pathlib import Path
try:
    import zoneinfo
except ImportError:
    zoneinfo = None
j = json
pth = os.path
loads = json.loads
join = os.path.join
P = pathlib.Path
env = os.environ
flags, kinds = re.I, (pathlib.Path, datetime.time)
def sizes(names, key=os.path.getsize, codec=json):
    return codec.dumps(sorted(names, key=key))
def stamp(p: pathlib.Path, when: datetime.datetime = None) -> datetime.time:
    return (when or datetime.datetime.now(timezone.utc)).time()
parser = argparse.ArgumentParser()
parser.add_argument("file", type=pathlib.Path)
args = parser.parse_args()
text = args.file.read_text()
try:
    rows = j.loads(text)
except json.JSONDecodeError:
    rows = list(map(loads, [ln for ln in text.splitlines() if ln.startswith("{")]))
for fn in (len, str.strip):
    print(fn(text[:40]))
if zoneinfo is not None and zoneinfo and not isinstance(rows, (Path, time)):
    print(pth.getsize(args.file), path.basename(str(args.file)), join("a", "b"), P("x").name, env.get("HOME"))
print(sizes([str(args.file)]), stamp(args.file), isinstance(args.file, kinds), re.search("chat", text, flags) is not None)
print([m.__name__ for m in ()], sorted([str(args.file)], key=pth.getsize))
PY
run_02 "python3 reads-renamed.py msg.json"
allowed "#3102 the control: a read only script that renames modules and hands their functions on passes"
run_02 "python3 reads-renamed.py $RULES"
allowed "#3102 and handed the real rules file"
run_02 "python3 -c 'import json, sys; j = json; print(len(j.loads(open(sys.argv[1]).read())))' msg.json"
allowed "#3102 the control: code given inline that renames a module only to read passes"
# The control for the walrus cases: a walrus in a class body and one over a choice of two pass where
# what they bind is no module, and a module a followed walrus renames is still read on from.
cat > "$D02/reads-walrus.py" <<'PY'
import json, re, sys
class Reader:
    if (limit := len(sys.argv)) > 1:
        cap = limit
    (pattern := re.compile("chat"))
    (flags := re.I or 0)
text = open(sys.argv[1]).read()
if (j := json) and (m := Reader.pattern.search(text)) and (lines := text.splitlines() or None):
    print(m.group(0), len(lines), (n := len(text) or 1), (a := (b := len(lines))), j.dumps(lines[:1]))
PY
run_02 "python3 reads-walrus.py msg.json"
allowed "#3102 the control: a read only script with a walrus in a class body and one over a choice of two passes"
run_02 "python3 reads-walrus.py $RULES"
allowed "#3102 and handed the real rules file"
# The from import check runs for every module inline code may import, the ones it may import for its
# files (errno, io, stat, tempfile) included (the lessons review of PR #3130). It sat behind the line
# that passes those four, so code a shell script writes inline could write `from tempfile import os`
# and then os.system(...): measured through the gate at 055ac70, both forms below passed, exit 0 and
# nothing said. Neither can run on a Python measured (3.9.6, 3.11.16, 3.14.4): none of the four holds
# a module under a public name but io.abc, which is inert, so the import stops with ImportError before
# the next line. The gate still read a script that names os.system as one unable to act, so the check
# now comes first. os keeps its own line: `from os import stat` is os's call, not the stat module.
cat > "$D02/inline-from-files.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from tempfile import os
os.system("bash " + sys.argv[1])
PY
SH
cat > "$D02/inline-from-files-as.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from io import os as tool
tool.system("bash " + sys.argv[1])
PY
SH
for imported in inline-from-files.sh inline-from-files-as.sh; do
  run_02 "bash $imported msg.json"
  read_refused "#3102 inline code importing a module out of one it may import for its files is refused: $imported"
done
run_02 "bash inline-from-files.sh msg.json"
says "#3102 in the words the same import gets from any other module" "imports os from tempfile, which reaches the os module through tempfile"
cat > "$D02/inline-files.sh" <<'SH'
#!/bin/bash
python3 - "$1" <<'PY'
import sys
from errno import ENOENT
from io import StringIO, abc
from os import path, stat
from stat import S_ISDIR
from tempfile import gettempdir
print(StringIO(open(sys.argv[1]).read()).getvalue()[:20], S_ISDIR(stat(gettempdir()).st_mode), path.basename(sys.argv[1]), ENOENT)
PY
SH
run_02 "bash inline-files.sh msg.json"
allowed "#3102 the control: inline code importing those modules' own names, and os's stat and path, still passes"

# The reading asks the standard library module itself, so a judgement it took part in rests on where
# Python finds that module and on what its file holds. Both are asked through the stand ins the
# judgement cache records (lib/judgement-cache.py), and a kept judgement is not used once either has
# changed. Measured through the gate at 055ac70, where the module was imported by name: "its
# judgement is kept" failed for both scripts below (the cache traced "not stored: importlib.import_module,
# which the recorder does not know"), so no call whose script renamed a module was ever answered
# from the cache; and the file of the same name in front of the standard library's was run inside
# the gate. The cache's own checks of this are in test-judgement-cache.sh.
D02C="$T/d3102-kept"
mkdir -p "$D02C/w" "$D02C/pp" "$D02C/other"
cp "$D02/msg.json" "$D02C/w/msg.json"
printf '%s\n' 'import numbers, sys' 'n = numbers' 'print(isinstance(len(open(sys.argv[1]).read()), n.Integral))' > "$D02C/w/counts.py"
printf '%s\n' 'import cmath, sys' 'q = cmath' 'print(q.pi, len(open(sys.argv[1]).read()))' > "$D02C/w/compiled.py"
# run_02c <command>: judged with a cache of its own, traced, with $D02C/pp on the gate's own path.
run_02c() {
  : > "$D02C/trace"
  PYTHONPATH="$D02C/pp" SLACK_GATE_CACHE_DIR="$D02C/cache" SLACK_GATE_CACHE_TRACE="$D02C/trace" \
    run_raw "$(payload Bash "$(bash_input "$1")" "$D02C/w")"
}
# traced_02 <what> <start> [<also>]: a trace line starts with <start> (so "stored" is never "not
# stored") and, where given, holds <also>.
traced_02() { if awk -v p="$2" -v q="${3:-}" 'index($0, p) == 1 && (q == "" || index($0, q)) { f = 1 } END { exit !f }' "$D02C/trace"
              then check "$1" ok; else check "$1" "the cache traced: $(tr '\n' '|' < "$D02C/trace")"; fi; }
run_02c "python3 counts.py msg.json"
allowed "#3102 a script that renames a module written in Python, only to read, passes"
traced_02 "#3102 its judgement is kept" "stored"
run_02c "python3 counts.py msg.json"
allowed "#3102 judged again with nothing changed, it passes"
traced_02 "#3102 and is answered from the cache" "hit"
run_02c "python3 compiled.py msg.json"
allowed "#3102 a script that renames a compiled module, only to read, passes"
traced_02 "#3102 its judgement is kept too" "stored"
run_02c "python3 compiled.py msg.json"
traced_02 "#3102 and is answered from the cache" "hit"
# A file of the module's name in a folder the command's own path holds too: the gate's placing of
# the import looked there, so the kept judgement is not used (by whichever of its recorded answers
# is asked first, here that file test).
printf '%s\n' 'Integral = int' > "$D02C/pp/numbers.py"
run_02c "python3 counts.py msg.json"
traced_02 "#3102 once a file of the module's name is on the path, the kept judgement is not used" "miss: " "answers differently now"
rm -f "$D02C/pp/numbers.py"
run_02c "python3 counts.py msg.json"
allowed "#3102 with that file gone, the script passes as before"
# The same where the command sets a path of its own, so the only thing that looks in the gate's
# folder is the reading's own question, where does Python find numbers. Kept while the answer is the
# standard library's; not used once it is that file; and the file, which is not the standard
# library's, is not run to answer. It says so itself if it is.
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
allowed "#3102 the same script run with a path of its own passes"
traced_02 "#3102 its judgement is kept" "stored"
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
traced_02 "#3102 and is answered from the cache" "hit"
printf '%s\n' 'import sys' "open('$D02C/ran', 'w').write('ran')" 'Integral = int' > "$D02C/pp/numbers.py"
run_02c "PYTHONPATH=$D02C/other python3 counts.py msg.json"
traced_02 "#3102 once Python would find the module in another file, the kept judgement is not used" "miss: find_spec" "answers differently now"
allowed "#3102 judged afresh, the script still passes"
if [ -e "$D02C/ran" ]; then check "#3102 and the gate does not run that file" "the gate ran $D02C/pp/numbers.py"
else check "#3102 and the gate does not run that file" ok; fi
rm -f "$D02C/pp/numbers.py"

echo
echo "slack drafts only: three more routes to os in a Python script are followed (claude-config#3119)"

# Three routes past the #3102 reading, each of which passed the gate as it stood (measured
# 2026-11-17 by the cases below, exit 0 and nothing said, handed a data file naming an endpoint):
# a string naming attributes, read by string.Formatter; an attribute chain that starts at a call's
# result, a parameter or any other value the gate does not follow; and a module one of the script's
# own modules binds under another name. Each now counts as able to act: Formatter wherever it is
# named, os read off a value the gate does not follow (any other attribute of one is read as a
# field, as the controls at the end show), and os bound under another name where that name is read.
D19="$T/d3119"
mkdir -p "$D19"
cp "$D02/msg.json" "$D19/msg.json"
run_19() { run_raw "$(payload Bash "$(bash_input "$1")" "$D19")"; }
w19() { local name="$1"; shift; printf '%s\n' "$@" > "$D19/$name"; }
SYS19='.system("bash " + sys.argv[1])'
# string.Formatter reads the attributes a field names, so a string reaches what no attribute shows:
# a function's globals, a class's attributes, and a subclass's format_field is handed what it found.
w19 fmt-function.py 'import glob, string, sys' "string.Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-class.py 'import pathlib, string, sys' "string.Formatter().get_field(\"0.parser.os\", (pathlib.PurePath,), {})[0]$SYS19"
w19 fmt-from.py 'import glob, sys' 'from string import Formatter' "Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-renamed.py 'import glob, string, sys' 's = string' "s.Formatter().get_field(\"0.__globals__[os]\", (glob.glob,), {})[0]$SYS19"
w19 fmt-subclass.py 'import glob, string, sys' 'class F(string.Formatter):' '    def format_field(self, value, spec):' \
  "        value$SYS19" '        return ""' 'F().format("{0.__globals__[os]}", glob.glob)'
# A chain from a value the gate does not follow: a call's result, a parameter handed a class, a
# name bound to an instance, a subscript, a name functools.update_wrapper copied a class's
# attribute onto, and a class body's own import.
w19 call-chain.py 'import pathlib, sys' "pathlib.PurePath(\"x\").parser.os$SYS19"
w19 param-chain.py 'import pathlib, sys' 'def go(c, p):' '    c.parser.os.system("bash " + p)' 'go(pathlib.PurePath, sys.argv[1])'
w19 lambda-chain.py 'import pathlib, sys' '(lambda c, p: c.parser.os.system("bash " + p))(pathlib.PurePath, sys.argv[1])'
w19 instance-chain.py 'import pathlib, sys' 'p = pathlib.PurePath("x")' "p.parser.os$SYS19"
w19 subscript-chain.py 'import pathlib, sys' "[pathlib.PurePath][0].parser.os$SYS19"
w19 wrapper-chain.py 'import functools, pathlib, sys' 'class H: pass' 'h = H()' \
  'functools.update_wrapper(h, pathlib.PurePath, assigned=("parser",), updated=())' "h.parser.os$SYS19"
w19 class-import.py 'import sys' 'class C:' '    import os' "C.os$SYS19"
# A module the script's own module binds under another name: handed on (the issue's own form, and
# one whose helper uses it straight away), read through the module, imported out of it, and os
# imported by its own name out of such a module. And os imported under another name in a class
# body, or by a function into the module's globals, where a chain through the class or the module
# reaches it under that name.
w19 lib_g.py 'import glob as helper'
w19 lib_os.py 'import os as helper' 'def size(p):' '    return helper.path.getsize(p)'
w19 lib_plain.py 'import os' 'def size(p):' '    return os.path.getsize(p)'
w19 lib_global.py 'def setup():' '    global helper' '    import os as helper'
w19 own-glob-handed.py 'import lib_g, sys' 'def go(m, p):' '    m.os.system("bash " + p)' 'go(lib_g.helper, sys.argv[1])'
w19 own-handed.py 'import lib_os, sys' 'def go(m, p):' '    m.system("bash " + p)' 'go(lib_os.helper, sys.argv[1])'
w19 own-direct.py 'import lib_os, sys' "lib_os.helper$SYS19"
w19 own-from.py 'import sys' 'from lib_os import helper' "helper$SYS19"
w19 own-from-os.py 'import sys' 'from lib_plain import os' "os$SYS19"
w19 own-from-os-as.py 'import sys' 'from lib_plain import os as tool' "tool$SYS19"
w19 own-global.py 'import lib_global, sys' 'lib_global.setup()' "lib_global.helper$SYS19"
w19 class-alias.py 'import sys' 'class C:' '    import os as helper' "C.helper$SYS19"
for route in fmt-function.py fmt-class.py fmt-from.py fmt-renamed.py fmt-subclass.py \
  call-chain.py param-chain.py lambda-chain.py instance-chain.py subscript-chain.py wrapper-chain.py class-import.py \
  own-glob-handed.py own-handed.py own-direct.py own-from.py own-from-os.py own-from-os-as.py own-global.py class-alias.py; do
  run_19 "python3 $route msg.json"
  read_refused "#3119 a route to os the gate did not follow is refused: $route"
done
run_19 "python3 fmt-function.py msg.json"
says "#3119 the refusal names string.Formatter" "reaches past what the gate reads (Formatter)"
run_19 "python3 call-chain.py msg.json"
says "#3119 the refusal names the module and the value it was reached through" "reaches the os module through pathlib.PurePath('x').parser, which the gate does not follow"
run_19 "python3 own-handed.py msg.json"
says "#3119 the refusal names the module that binds os under another name" "imports lib_os.py, which binds os as helper"
run_19 "python3 own-from-os.py msg.json"
says "#3119 os imported out of the script's own module is held to os's reads" "uses os for more than reading files, paths and the environment (os.system)"
run_19 "python3 class-alias.py msg.json"
says "#3119 and os imported under another name in a class body" "binds os as helper"
# The controls: read only scripts that call a method named like a module, read a chain from a call's
# result and a parameter, format a string, import os under another name at their own top level or
# in a function, and import the script's own module that imports os by name, still pass.
w19 lib_fn.py 'def size(p):' '    import os as o' '    return o.path.getsize(p)'
cat > "$D19/reads-routes.py" <<'PY'
import argparse, os as o, pathlib, string, sys
import lib_fn, lib_plain
from lib_plain import size
parser = argparse.ArgumentParser()
parser.add_argument("file", type=pathlib.Path)
args = parser.parse_args()
def width(p):
    return p.stat().st_size
print(args.file.stat().st_size, pathlib.Path(args.file).parent.name, width(args.file))
print("{0.name}".format(args.file), string.Template("$x").substitute(x=1), o.path.basename(str(args.file)))
print(lib_fn.size(args.file), size(args.file), sorted([str(args.file)], key=lib_plain.size))
PY
run_19 "python3 reads-routes.py msg.json"
allowed "#3119 the control: a read only script with chains from calls and parameters and its own modules passes"
run_19 "python3 reads-routes.py $RULES"
allowed "#3119 and handed the real rules file"
# A field of a script's own named like a standard library module is a field, not the module: the
# chain rule is about reaching os, so a value it does not follow may have any other attribute read
# off it, and on through it (Dan's choice on PR #3161, 2026-11-17). Each of these was refused by the
# rule's first version, which refused every standard library module's name off the list.
w19 field-email.py 'import argparse, sys' 'parser = argparse.ArgumentParser()' 'parser.add_argument("file")' \
  'parser.add_argument("--email", default="a@example.com")' 'args = parser.parse_args()' \
  'print(args.email, args.email.lower(), len(open(args.file).read()))'
w19 field-code.py 'import sys' 'try:' '    sys.exit(len(open(sys.argv[1]).read()) % 3)' 'except SystemExit as e:' \
  '    print(e.code, str(e.code).zfill(2))'
w19 field-queue.py 'import sys' 'class Store:' '    def __init__(self):' '        self.queue = []' \
  '    def add(self, line):' '        self.queue.append(line)' '        return len(self.queue)' \
  's = Store()' 'print(s.add(open(sys.argv[1]).read()[:20]), s.queue)'
for field in field-email.py field-code.py field-queue.py; do
  run_19 "python3 $field msg.json"
  allowed "#3119 a field named like a standard library module is read as a field: $field"
done

echo "slack drafts only: builtins under another name, sys.breakpointhook and sys.path under another name are read (claude-config#3151)"

# Three more routes, each of which ran on Python 3.14.4 and passed the gate as it stood (measured
# 2026-11-17 by the cases below, exit 0 and nothing said, handed a data file naming an endpoint).
# One: enum binds builtins as bltns (Python 3.12 and later), a name no standard library module has,
# so enum.bltns.exec(...) named no module off the list and exec was an attribute, not the builtin.
# Two: sys.breakpointhook imports and calls whatever PYTHONBREAKPOINT names, set by the script
# itself or on the command, and only the builtin breakpoint was read. Three: sys.path was read only
# as the name sys followed by path, so sys under another name, sys read off another module
# (glob.sys) and sys read off a value the gate does not follow (pathlib.PurePath("x").parser.sys)
# all changed where Python finds modules unseen.
D51="$T/d3151"
mkdir -p "$D51/lib"
cp "$D02/msg.json" "$D51/msg.json"
run_51() { run_raw "$(payload Bash "$(bash_input "$1")" "$D51")"; }
w51() { local name="$1"; shift; printf '%s\n' "$@" > "$D51/$name"; }
EXEC51='.exec("import os; os.system(\"bash \" + sys.argv[1])")'
w51 bltns.py 'import enum, sys' "enum.bltns$EXEC51"
w51 bltns-renamed.py 'import enum, sys' 'e = enum' "e.bltns$EXEC51"
w51 bltns-from.py 'import sys' 'from enum import bltns' "bltns$EXEC51"
w51 bltns-open.py 'import enum, sys' 'enum.bltns.open(sys.argv[1], "a").close()'
w51 hook-env.py 'import os, sys' 'os.environ["PYTHONBREAKPOINT"] = "os.system"' 'sys.breakpointhook("bash " + sys.argv[1])'
w51 hook.py 'import sys' 'sys.breakpointhook("bash " + sys.argv[1])'
w51 hook-from.py 'import sys' 'from sys import breakpointhook' 'breakpointhook("bash " + sys.argv[1])'
w51 hook-renamed.py 'import sys' 's = sys' 's.breakpointhook("bash " + sys.argv[1])'
# The other name on sys that runs code it is given by name rather than as a function the script
# already holds: sys.remote_exec (Python 3.14) runs a file in a Python process, the script's own
# included (measured 2026-11-17: handed its own pid and a file, the file ran).
w51 remote.py 'import os, sys' 'sys.remote_exec(os.getpid(), sys.argv[1])'
PATH51='.path.insert(0, "lib")'
w51 path-call-chain.py 'import pathlib' "pathlib.PurePath(\"x\").parser.sys$PATH51" 'import json'
w51 path-module-chain.py 'import glob' "glob.sys$PATH51" 'import json'
w51 path-as.py 'import sys as s' "s$PATH51" 'import json'
w51 path-renamed.py 'import sys' 'q = sys' "q$PATH51" 'import json'
w51 path-renamed-chain.py 'import glob' 'q = glob.sys' "q$PATH51" 'import json'
w51 path-from.py 'from glob import sys as s' "s$PATH51" 'import json'
w51 path-default.py 'import sys' 'def go(m=sys):' "    m$PATH51" 'go()' 'import json'
w51 path-unfollowed-name.py 'import pathlib' 'p = pathlib.PurePath("x").parser.sys' "p$PATH51" 'import json'
# sys read off one of the script's own modules, whose attributes the gate does not read: the value
# is one reached from a module and not known to be one, which is not the same as one reached from
# no module, and a name bound to it was not taken as a name for sys (PR #3151 review; measured
# 2026-11-17, path-own-module-name.py passed with exit 0 while path-own-module-chain.py, the same
# read with no name in between, was refused).
w51 lib_sys.py 'import sys'
w51 path-own-module-chain.py 'import lib_sys' "lib_sys.sys$PATH51" 'import json'
w51 path-own-module-name.py 'import lib_sys' 'q = lib_sys.sys' "q$PATH51" 'import json'
for route in bltns.py bltns-renamed.py bltns-from.py bltns-open.py hook-env.py hook-from.py hook-renamed.py remote.py \
  path-call-chain.py path-module-chain.py path-as.py path-renamed.py path-renamed-chain.py path-from.py \
  path-default.py path-unfollowed-name.py path-own-module-chain.py path-own-module-name.py; do
  run_51 "python3 $route msg.json"
  read_refused "#3151 a route the gate did not read is refused: $route"
done
run_51 "PYTHONBREAKPOINT=os.system python3 hook.py msg.json"
read_refused "#3151 and sys.breakpointhook with PYTHONBREAKPOINT set on the command"
run_51 "python3 bltns.py msg.json"
says "#3151 the refusal names enum's name for builtins" "reaches past what the gate reads (bltns)"
run_51 "python3 hook-env.py msg.json"
says "#3151 the refusal names sys.breakpointhook" "reaches past what the gate reads (breakpointhook)"
run_51 "python3 path-call-chain.py msg.json"
says "#3151 sys.path read off a value the gate does not follow is named as sys.path" "changes where Python finds modules (sys.path)"
run_51 "python3 path-as.py msg.json"
says "#3151 and sys.path under another name" "changes where Python finds modules (sys.path)"
# The class behind bltns (L96): a module the gate holds to be inert may bind any module under a
# name that is not the module's own, which a reading by name cannot see. Every such name this
# Python has is found here, from the gate's own list (its names cut out of the gate's text and
# handed over as words, never the file), and a script reading through it must be refused, so the
# next one fails here on the Python that brings it.
read -r -a INERT51 <<< "$(sed -n '/^PY_INERT = frozenset({/,/})/p' "$DIR/slack_drafts_only_gate.py" | grep -o '"[A-Za-z_.]*"' | tr -d '"' | tr '\n' ' ')"
python3 -B - ${INERT51[@]+"${INERT51[@]}"} > "$D51/aliases.txt" 2>"$D51/aliases.err" <<'PY'
import importlib, sys
MODULE = type(sys)
seen, todo = set(), []
for name in sorted(sys.argv[1:]):
    try:
        todo.append((name, importlib.import_module(name)))
    except ImportError:
        pass  # a module this Python does not have binds nothing
print(f"modules {len(todo)}")
while todo:
    label, mod = todo.pop()
    if id(mod) in seen:
        continue
    seen.add(id(mod))
    for attr, value in sorted(vars(mod).items()):
        if attr.startswith("_") or not isinstance(value, MODULE):
            continue
        if value.__name__.split(".")[-1] != attr:
            print(f"alias {label} {attr} {value.__name__}")
        if value.__name__.startswith(mod.__name__ + "."):
            todo.append((f"{label}.{attr}", value))
PY
walked="$(sed -n 's/^modules //p' "$D51/aliases.txt")"
if [ "${walked:-0}" -ge 40 ] 2>/dev/null; then check "#3151 the walk read the gate's list of inert modules ($walked of them)" ok
else check "#3151 the walk read the gate's list of inert modules" "it read ${walked:-none}: $(head -c 300 "$D51/aliases.err")"; fi
if python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else 1)'; then
  if grep -qx 'alias enum bltns builtins' "$D51/aliases.txt"; then check "#3151 and finds builtins under enum's name for it" ok
  else check "#3151 and finds builtins under enum's name for it" "it found: $(tr '\n' '|' < "$D51/aliases.txt")"; fi
else
  echo "SUITE-PART-UNMEASURED enum binds builtins as bltns only on Python 3.12 and later, and this is $(python3 -V 2>&1)"
fi
ALIASES51="$(grep '^alias ' "$D51/aliases.txt")"
while read -r _ module attr real; do
  [ -n "$module" ] || continue  # a here document of nothing found is one empty line
  w51 "alias-$module-$attr.py" "import $module, sys" "$module.$attr.x(sys.argv[1])"
  run_51 "python3 alias-$module-$attr.py msg.json"
  read_refused "#3151 a script reading through $module.$attr, which is the $real module, is refused"
done <<EOF
$ALIASES51
EOF
# The controls: enum and sys used as they ordinarily are, sys under another name for anything but
# its path, a path that is a field or os.path, and a field named sys, read and handed on, which is
# a field like any other the gate does not follow (PR #3161).
cat > "$D51/reads-3151.py" <<'PY'
import argparse, enum, os, sys
import sys as s
class Kind(enum.Enum):
    A = enum.auto()
class Times:
    def __init__(self, path):
        self.path, self.sys, self.user = path, 0.5, 1.5
    def total(self):
        return round(self.sys, 1) + self.user
q = sys
parser = argparse.ArgumentParser()
parser.add_argument("path")
args = parser.parse_args()
t = Times(args.path)
print(Kind.A.name, s.argv[0], q.platform, sys.version_info[0], t.sys, round(t.sys), t.total())
print(len(open(t.path).read()), os.path.basename(args.path), t.path.upper(), args.path.lower())
sys.stdout.write("done\n")
PY
run_51 "python3 reads-3151.py msg.json"
allowed "#3151 the control: a read only script using enum, sys under another name, a path field and a field named sys passes"
run_51 "python3 reads-3151.py $RULES"
allowed "#3151 and handed the real rules file"
# And the same narrowing for a value read off one of the script's own modules: a field called sys
# there, bound to a name and read, is a field, and only a write to its path is refused.
w51 lib_times.py 'class Times:' '    sys, user, path = 0.5, 1.5, "x"' 'now = Times()'
w51 own-module-field.py 'import lib_times' 'q = lib_times.now.sys' 'p = lib_times.now.path' 'print(q, round(q), p.upper())'
run_51 "python3 own-module-field.py msg.json"
allowed "#3151 and a field named sys read off one of the script's own modules into a name passes"

echo "slack drafts only: a submodule of an inert package, and sys put where the gate does not follow it (claude-config#3172)"

# Two more routes, each of which passed the gate as #3151 left it (measured 2026-11-17 by the cases
# below, exit 0 and nothing said, handed a data file naming an endpoint). One: PY_INERT admitted any
# submodule of a package on it, so `import json.tool` passed, and json.tool.main reads its output
# path from sys.argv and writes it (on Python 3.14.4 it wrote out.py). Two: a sys read off a value the
# gate does not follow was read on only through a name it was bound to, so the same sys handed to a
# function, put in a list, returned, or chosen by a conditional changed where Python finds modules
# unseen.
D72="$T/d3172"
mkdir -p "$D72/lib"
cp "$D02/msg.json" "$D72/msg.json"
run_72() { run_raw "$(payload Bash "$(bash_input "$1")" "$D72")"; }
w72() { local name="$1"; shift; printf '%s\n' "$@" > "$D72/$name"; }
ARGV72='sys.argv[1:] = [sys.argv[1], "out.py"]'
w72 jt-import.py 'import json.tool, sys' "$ARGV72" 'json.tool.main()'
w72 jt-as.py 'import json.tool as t, sys' "$ARGV72" 't.main()'
w72 jt-from.py 'import sys' 'from json import tool' "$ARGV72" 'tool.main()'
w72 jt-from-sub.py 'import sys' 'from json.tool import main' "$ARGV72" 'main()'
w72 jt-main.py 'import sys' "$ARGV72" 'import json.__main__' 'json.tool.main()'
for route in jt-import.py jt-as.py jt-from.py jt-from-sub.py jt-main.py; do
  run_72 "python3 $route msg.json"
  read_refused "#3172 a submodule of an inert package that is not itself on the list is refused: $route"
done
run_72 "python3 jt-import.py msg.json"
says "#3172 the refusal names the submodule" "json.tool"
PATH72='.path.insert(0, "lib")'
w72 lib_sys.py 'import sys'
w72 go-call-chain.py 'import pathlib' 'def go(m):' "    m$PATH72" 'go(pathlib.PurePath("x").parser.sys)' 'import json'
w72 go-own-module.py 'import lib_sys' 'def go(m):' "    m$PATH72" 'go(lib_sys.sys)' 'import json'
w72 go-keyword.py 'import lib_sys' 'def go(m=None):' "    m$PATH72" 'go(m=lib_sys.sys)' 'import json'
w72 go-name.py 'import lib_sys' 'q = lib_sys.sys' 'def go(m):' "    m$PATH72" 'go(q)' 'import json'
w72 ifexp-name.py 'import lib_sys, os' 'q = lib_sys.sys if os.sep else None' "q$PATH72" 'import json'
w72 ifexp-chain.py 'import os, pathlib' 'q = pathlib.PurePath("x").parser.sys if os.sep else None' "q$PATH72" 'import json'
w72 ifexp-direct.py 'import lib_sys, os' "(lib_sys.sys if os.sep else None)$PATH72" 'import json'
w72 boolop-name.py 'import lib_sys' 'q = lib_sys.sys or None' "q$PATH72" 'import json'
w72 list.py 'import lib_sys' 'qs = [lib_sys.sys]' "qs[0]$PATH72" 'import json'
w72 returned.py 'import lib_sys' 'def f():' '    return lib_sys.sys' "f()$PATH72" 'import json'
w72 cast.py 'import lib_sys, typing' "typing.cast(object, lib_sys.sys)$PATH72" 'import json'
w72 walrus.py 'import lib_sys' 'def go(m):' "    m$PATH72" 'go((q := lib_sys.sys))' 'import json'
w72 attr-store.py 'import lib_sys' 'class H:' '    pass' 'h = H()' 'h.m = lib_sys.sys' "h.m$PATH72" 'import json'
w72 shadowed-print.py 'import lib_sys' 'def print(m):' "    m$PATH72" 'print(lib_sys.sys)' 'import json'
# An operand hands sys to the other operand's method where the script writes one: a module has no
# __add__, so sys + A() calls A.__radd__ with it, and `in` calls __contains__. Each case but the one
# about the script's own module reads sys off pathlib, so that importing one of the script's own
# modules (which refuses an operand by itself) is not what refuses it.
SYS72='pathlib.PurePath("x").parser.sys'
w72 operand-radd.py 'import pathlib' 'class A:' '    def __radd__(self, m):' "        m$PATH72" '        return 0' \
  "print($SYS72 + A())" 'import json'
w72 operand-contains.py 'import pathlib' 'class A:' '    def __contains__(self, m):' "        m$PATH72" '        return True' \
  "print($SYS72 in A())" 'import json'
# The lessons review at d63d189: a chained assignment that also stores sys on an attribute, and an
# operand whose class's hook is written where the script's own class bodies do not show it (a module
# of the script's own, type() given the methods, a method set on the class afterwards).
w72 chain-attr.py 'import lib_sys' 'class H:' '    pass' 'h = H()' 'q = h.m = lib_sys.sys' "h.m$PATH72" 'import json'
w72 lib_hook.py 'class A:' '    def __radd__(self, m):' "        m$PATH72" '        return 0'
w72 operand-own-module.py 'import lib_sys, lib_hook' 'print(lib_sys.sys + lib_hook.A())' 'import json'
w72 operand-type.py 'import pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = type("A", (), {"__radd__": radd})' "print($SYS72 + A())" 'import json'
w72 operand-set-later.py 'import pathlib' 'class A:' '    pass' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A.__radd__ = radd' "print($SYS72 + A())" 'import json'
# (operand-set-later.py and operand-setattr.py were refused before #3172 too, by the rule on an
# attribute starting with _ and by setattr being on PY_RUNS; they stay so a change to either is seen.)
w72 operand-setattr.py 'import pathlib' 'class A:' '    pass' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'setattr(A, "__r" + "add__", radd)' "print($SYS72 + A())" 'import json'
# The lessons review at 510611e: a hook written inside an if or a try in the class body.
w72 operand-in-if.py 'import os, pathlib' 'class A:' '    if os.sep:' '        def __radd__(self, m):' "            m$PATH72" \
  '            return 0' "print($SYS72 + A())" 'import json'
w72 operand-in-try.py 'import pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' 'class A:' '    try:' \
  '        __radd__ = radd' '    except Exception:' '        pass' "print($SYS72 + A())" 'import json'
# The lessons review at 54ccd1c: abc.ABCMeta makes a class from a dictionary whose key is built, or
# from dict() with keywords. Three reviews each found a way to give a class a method the last list
# missed, so an operand now passes only beside literals; one beside any other value is refused,
# a field added to a field included (handed the other's __radd__ all the same).
w72 operand-abcmeta-key.py 'import abc, pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = abc.ABCMeta("A", (), {"__r" + "add__": radd})' "print($SYS72 + A())" 'import json'
w72 operand-abcmeta-kw.py 'import abc, pathlib' 'def radd(self, m):' "    m$PATH72" '    return 0' \
  'A = abc.ABCMeta("A", (), dict(__radd__=radd))' "print($SYS72 + A())" 'import json'
w72 operand-field.py 'import pathlib' 'class T:' '    user = 1.5' 't = T()' "print($SYS72 + t.user)" 'import json'
for route in go-call-chain.py go-own-module.py go-keyword.py go-name.py ifexp-name.py ifexp-chain.py ifexp-direct.py \
  boolop-name.py list.py returned.py cast.py walrus.py attr-store.py shadowed-print.py operand-radd.py operand-contains.py \
  chain-attr.py operand-own-module.py operand-type.py operand-set-later.py operand-setattr.py operand-in-if.py \
  operand-in-try.py operand-abcmeta-key.py operand-abcmeta-kw.py operand-field.py; do
  run_72 "python3 $route msg.json"
  read_refused "#3172 sys put where the gate does not follow it is refused: $route"
done
run_72 "python3 go-call-chain.py msg.json"
says "#3172 the refusal says sys went where the gate does not follow it" "where the gate does not follow it"
# The class behind json.tool (L96): every submodule each package on the gate's list has on this
# Python, found from the list itself (its names cut out of the gate's text), is either on the list
# by its own dotted name or refused, so a submodule a later Python adds is refused until read.
read -r -a INERT72 <<< "$(sed -n '/^PY_INERT = frozenset({/,/})/p' "$DIR/slack_drafts_only_gate.py" | grep -o '"[A-Za-z_.]*"' | tr -d '"' | tr '\n' ' ')"
python3 -B - ${INERT72[@]+"${INERT72[@]}"} > "$D72/subs.txt" 2>"$D72/subs.err" <<'PY'
import importlib, pkgutil, sys
listed = set(sys.argv[1:])
for name in sorted(listed):
    try:
        mod = importlib.import_module(name)
    except ImportError:
        continue
    for sub in pkgutil.iter_modules(getattr(mod, "__path__", None) or []):
        print(("listed " if f"{name}.{sub.name}" in listed else "unlisted ") + f"{name}.{sub.name}")
PY
if grep -qx 'unlisted json.tool' "$D72/subs.txt"; then check "#3172 the walk found json.tool among the inert packages' submodules" ok
else check "#3172 the walk found json.tool among the inert packages' submodules" "it found: $(tr '\n' '|' < "$D72/subs.txt") $(head -c 300 "$D72/subs.err")"; fi
while read -r kind sub; do
  [ -n "$sub" ] || continue
  w72 "sub-$sub.py" "import $sub, sys" 'print(len(open(sys.argv[1]).read()))'
  run_72 "python3 sub-$sub.py msg.json"
  if [ "$kind" = listed ]; then allowed "#3172 a submodule on the list by its own name passes: $sub"
  else read_refused "#3172 a submodule not on the list by its own name is refused: $sub"; fi
done < "$D72/subs.txt"
# The controls: json read and written to the screen, its decoder and html's parser imported as real
# code in this repository imports them (lib/local-allow-rules.py, skills/design-rounds/design_file.py),
# html.parser also as `import html.parser`, sys used as scripts use it, and a field named sys read, printed,
# rounded, formatted, compared and added, which is a field (PR #3161), also when a conditional picks
# it into a name.
cat > "$D72/reads-3172.py" <<'PY'
import collections, html.parser, json, sys
import sys as s
from html.parser import HTMLParser
from json.decoder import JSONDecodeError, scanstring
class Times:
    def __init__(self):
        self.sys, self.user = 0.5, 1.5
    def total(self):
        return round(self.sys, 1) + self.user
t = Times()
q = t.sys if t.user else 0
assert 0 < t.sys <= 1.5 and t.sys != -1 and t.sys + 1 > 1
try:
    data = json.load(open(sys.argv[1]))
except JSONDecodeError as e:
    print(e, file=sys.stderr)
    sys.exit(1)
print(json.dumps(data, indent=2), isinstance(data, collections.abc.Iterable), scanstring('"a"', 1)[0], HTMLParser, html.parser.HTMLParser)
print(t.sys, round(t.sys), str(t.sys), f"{t.sys:.1f}", t.sys == 0.5, -t.sys, t.sys * 2, t.total(), round(q))
json.dump(data, sys.stdout)
s.stdout.write(s.argv[0] + "\n")
if __name__ == "__main__":
    print(t.sys * 3)
PY
run_72 "python3 reads-3172.py msg.json"
allowed "#3172 the control: json, its decoder, html.parser, collections' abc, sys and a field named sys used as scripts use them pass"
run_72 "python3 reads-3172.py $RULES"
allowed "#3172 and handed the real rules file"
run_72 "python3 -m json.tool msg.json"
allowed "#3172 and python3 -m json.tool printing a file, which the gate reads as a program, still passes"
# A name on PY_REACH used as a plain name is refused with what that name does: only the typing
# names evaluate a string as code; enum's builtins, sys's hooks and the rest reach past what the
# gate reads (the message said "can evaluate a string as code" for all of them until #3172).
w72 name-bltns.py 'import sys' 'def f(bltns):' '    return bltns' 'print(f(1), sys.argv[1])'
w72 name-forwardref.py 'import sys' 'def f(ForwardRef):' '    return ForwardRef' 'print(f(1), sys.argv[1])'
run_72 "python3 name-bltns.py msg.json"
says "#3172 a name that is builtins is not said to evaluate a string" "reaches past what the gate reads (bltns)"
run_72 "python3 name-forwardref.py msg.json"
says "#3172 a typing name still says it evaluates a string as code" "can evaluate a string as code (ForwardRef)"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
