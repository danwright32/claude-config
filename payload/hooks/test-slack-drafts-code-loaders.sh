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
# file replaces with vi.mock or jest.mock and a factory is not followed. Every other judgement of the gate is in test-slack-drafts-only-gate.sh,
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
says "#3020 naming the file beside the script" "hooks/b.sh"
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
# reads is; inside a script on disk it stays behind the #2683 switch, as a file run by a path the
# gate cannot work out does.
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
# Inside a script on disk: the text of a file is read there too, and text the gate cannot read
# stays behind the #2683 switch, so a script evaluating a variable its caller sets runs as before.
printf '%s\n' 'X="$(cat cmd.txt)"' "eval \"\$X\"" > "$E3/file-posts.sh"
printf '%s\n' 'X="$(cat quiet.txt)"' "eval \"\$X\"" > "$E3/file-quiet.sh"
printf '%s\n' "[ -n \"\${PAUSE_3020:-}\" ] && eval \"\${PAUSE_3020}\"" "eval \"\$(date +%s >/dev/null)\"" 'echo done' > "$E3/unread.sh"
run_e3 "bash file-posts.sh"
refused "#3020 a script on disk evaluating the text of a file that posts is refused"
says "#3020 as the post it is" "REFUSED: this command posts to Slack"
run_e3 "bash file-quiet.sh"
allowed "#3020 and one evaluating the text of a quiet file passes"
run_e3 "bash unread.sh"
allowed "#3020 a script on disk evaluating text the gate cannot read passes as before, with the #2683 switch off"
SLACK_GATE_UNWORKED_PATHS=refuse run_e3 "bash unread.sh"
read_refused "#3020 and is refused with the switch on"
says "#3020 as a check it could not make" "REFUSED: the gate could not check whether this command posts to Slack"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
