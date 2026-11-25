#!/usr/bin/env bash
# Tests for how the Slack drafts gate reads what a command feeds another: a command inside a process
# substitution, or handed one as the file it runs (claude-config#3213), and a shell handed its input
# by the group, loop, subshell, substitution or string it is in, or by a redirection glued to its
# name or its file (#3229).
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

echo "slack drafts only: a command inside a process substitution is judged as a command of its own (claude-config#3213)"

# Measured 2026-11-18 on the branch for #3155: `cat <(bash posts.sh)`, `echo <(bash posts.sh)` and
# `cat posts.sh > >(bash)` each passed, while `bash posts.sh` alone is refused. The shared reader
# gave the gate no command for what is written inside <( ), >( ) or zsh's =( ), so nothing judged it.
# Where each runs, measured the same day (bash 3.2.57, zsh 5.9): anywhere outside quotes in a
# command's words, mid word and after an escaped backslash too, in an array's words, and in bash in
# the word of an unquoted ${NAME:-word}; =( ) only at the start of a word. Inside double or single
# quotes it is text. A shell inside one reads what feeds the command around it (`echo CODE | cat
# <(bash)` ran CODE in bash), so a program that runs its input there reads text the gate cannot see.
D13="$T/d3213"
mkdir -p "$D13"
run_13() { run_raw "$(payload Bash "$(bash_input "$1")" "$D13")"; }
printf '%s\n' "$POST" > "$D13/posts.sh"
printf '%s\n' 'echo ok' > "$D13/ok.sh"
printf '%s\n' 'echo ok' > "$D13/o"
printf '%s\n' 'cat <(bash posts.sh)' > "$D13/runner.sh"
printf '%s\n' 'cat posts.sh > >(bash)' > "$D13/feeder.sh"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=b"text=hi")' > "$D13/posts.py"
printf '%s\n' 'url = "https://slack.com/api/chat.postMessage"' 'data = "text=hi"' > "$D13/curlrc"
printf '%s\n' 'bash <(cat posts.sh)' > "$D13/handed.sh"
printf '%s\n' 'source <(sort a.txt)' 'echo sourced' > "$D13/sourced.sh"
printf '%s\n' 'import sys' 'print(open(sys.argv[1]).read())' > "$D13/ok.py"
printf '%s\n' 'while read -r l; do echo "$l"; done < <(sort a.txt)' 'diff <(sort a.txt) <(sort b.txt) || true' > "$D13/reads.sh"
printf '%s\n' 'b' 'a' > "$D13/a.txt"
printf '%s\n' 'c' 'a' > "$D13/b.txt"
run_13 "bash posts.sh"
read_refused "#3213 the yardstick: the script that posts is refused run on its own"
for runs in "cat <(bash posts.sh)" "echo <(bash posts.sh)" "diff <(bash posts.sh) <(echo x)" "diff <(echo x) <(bash posts.sh)" \
  "echo hi | tee >(bash posts.sh)" "cat < <(bash posts.sh)" "while read -r l; do echo \"\$l\"; done < <(bash posts.sh)" \
  "cat <(cat <(bash posts.sh))" "cat <($POST)" "cat <(echo x; bash posts.sh)" "cat <(echo x && bash posts.sh)" \
  "a=( <(bash posts.sh) ); echo \"\${a[0]}\"" "echo \${x:-<(bash posts.sh)}" "cat =(bash posts.sh)" "a=( =(bash posts.sh) )" \
  "echo x<(bash posts.sh)" "echo \\\\<(bash posts.sh)" "bash -c 'cat <(bash posts.sh)'" "bash runner.sh" \
  "echo \"\$(cat <(bash posts.sh))\"" "(cat <(bash posts.sh))" "sort a.txt > >(bash posts.sh)" "cat <(sort a.txt) <(bash posts.sh) b.txt" \
  "cat <(cat posts.sh | bash)" "cat <(bash < posts.sh)" "case \$x in <(bash posts.sh)) echo y ;; esac"; do
  run_13 "$runs"
  read_refused "#3213 a script that posts is refused run inside a process substitution: $runs"
done
# A shell or an interpreter with no script reads its input, and inside a process substitution that is
# whatever feeds it or the command around it, which the gate does not work out: refused as unread.
for runs in "cat posts.sh > >(bash)" "cat posts.sh > >(sh)" "cat posts.sh | tee >(bash)" "tee >(bash) < posts.sh" \
  "cat posts.sh | cat <(bash)" "cat posts.sh > >(true; bash)" "cat posts.sh > >(bash -c 'bash')" "cat posts.sh > >(python3)" \
  "bash feeder.sh" "cat curlrc > >(curl -K -)"; do
  run_13 "$runs"
  read_refused "#3213 a program that runs its input is refused inside a process substitution: $runs"
  says "#3213 and the refusal says its input cannot be read: $runs" "what that holds cannot be read"
done
# The wrapper in front of the rule starts python only for a payload that could post. A shell that
# closes a ( ) has no space after it, so with a file of no extension nothing in the payload named a
# script or a shell the wrapper knew, and the call never reached the rule.
printf '%s\n' "$POST" > "$D13/posts"
for runs in "cat posts > >(bash)" "cat posts > >(sh)" "cat posts | tee >(zsh)" "cat posts > >(true; bash )"; do
  run_13 "$runs"
  read_refused "#3213 a shell closing a process substitution reaches the rule with no script named: $runs"
  says "#3213 and the refusal says its input cannot be read: $runs" "what that holds cannot be read"
done
# A process substitution handed to a program as the file it runs or reads its request from: the
# program runs what the commands inside print. One command the gate reads the output of, as it does
# for a pipe (cat of a file, echo or printf of written text), is judged by that output.
for runs in "bash <(cat posts.sh)" "source <(cat posts.sh)" ". <(cat posts.sh)" "bash < <(cat posts.sh)" "python3 <(cat posts.py)" \
  "curl -K <(cat curlrc)" "zsh =(cat posts.sh)" "bash <(echo 'bash posts.sh')" "bash -x <(cat posts.sh)" "env bash <(cat posts.sh)" \
  "bash handed.sh" "cat <(bash <(cat posts.sh))" "bash -o <(cat posts.sh) o" "bash -o o -o <(cat posts.sh) o"; do
  run_13 "$runs"
  read_refused "#3213 a program handed a process substitution that prints a script that posts is refused: $runs"
  says "#3213 and the refusal names what it prints: $runs" "prints"
done
# The last two: one given as an option's value, before a script whose name an earlier word holds
# (`-o` holds `o`) or repeats. The script's place was found by searching the words for its text, which
# stopped at that earlier word and left the substitution out of what is read (lessons review of
# 9e299673b7). The file `o` posts nothing, so nothing else refuses the line.
run_13 "bash o"
allowed "#3213 the yardstick for those two: the script named o posts nothing and passes run on its own"
# Anything else it prints cannot be read before it runs, and is refused as unread.
for runs in "sh <(sort posts.sh)" "bash <(cat posts.sh | grep -v x)" "bash <(echo x; cat posts.sh)" "source <(sed 1q posts.sh)" \
  "bash -c 'bash <(cat posts.sh)'" "bash <(cat <(cat posts.sh))" "bash -o <(sort posts.sh) o"; do
  run_13 "$runs"
  read_refused "#3213 a program handed a process substitution whose output cannot be read is refused: $runs"
  says "#3213 and the refusal says it cannot be read: $runs" "cannot be read before the command runs"
done
# The controls: what is run inside is judged by what it is, so a command that passes on its own still
# passes inside one, and quoted text that only looks like one is text.
run_13 "bash ok.sh"
allowed "#3213 the control's yardstick: a script that posts nothing passes run on its own"
for runs in "cat <(echo hi)" "diff <(sort a.txt) <(sort b.txt)" "cat <(bash ok.sh)" "echo hi | tee >(cat) > /dev/null" \
  "sort a.txt > >(head -1)" "while read -r l; do echo \"\$l\"; done < <(sort a.txt)" "cat <(bash -n posts.sh)" \
  "echo \"<(bash posts.sh)\"" "echo '<(bash posts.sh)'" "echo \"\${x:-<(bash posts.sh)}\"" "a=(one two); echo \"\${a[1]}\"" \
  "cat =(sort a.txt)" "comm -12 <(sort a.txt) <(sort b.txt) | wc -l" "echo \$(( 3 < (2) ))" \
  "cat <(cat ok.sh | bash)" "cat <(bash < ok.sh)" "bash reads.sh" \
  "bash <(cat ok.sh)" "source <(cat ok.sh)" "bash < <(cat ok.sh)" "bash <(echo 'echo hi')" "python3 ok.py <(sort a.txt)" \
  "bash ok.sh <(sort a.txt)" "python3 -c 'print(1)' <(sort a.txt)" "bash sourced.sh" "sort <(cat posts.sh)" \
  "bash ok.sh <(sort a.txt) ok.sh" "bash -o <(cat ok.sh) o"; do
  run_13 "$runs"
  allowed "#3213 a process substitution that runs nothing that posts still passes: $runs"
done

echo "slack drafts only: a shell handed its input by what is around it is read as one fed directly (claude-config#3229)"

# Measured 2026-11-18 on main at 31cb0890, through this harness: `cat posts.sh | bash` is refused, and
# 107 commands of the refused lists below exited 0 (the lists also keep, as checks, the forms that
# were refused before: a pipe straight into `bash -s`, `env bash` and the like). A shell or an interpreter given no script reads
# what the shell around it is reading (bash 3.2.57 and zsh 5.9 ran the fed text in every form below,
# but for `echo $(bash)` behind a pipe, which only bash runs, and `x=$(bash) < file`, which only zsh
# does). The gate asked only whether a pipe stood right before the program's own name, or a
# redirection among its own words, so one fed through a group, a loop, a subshell, a command
# substitution or a string a shell is handed was taken to read nothing. And a redirection glued to a
# name or to its file was no redirection to the words reading: `bash <gen` passed where `bash < gen`
# is refused, and `bash<gen` was a program nobody knew, which with a file of no extension never
# reached the rule at all, as `cat posts | { true; bash; }` did not (no space follows the name).
D29="$T/d3229"
mkdir -p "$D29"
run_29() { run_raw "$(payload Bash "$(bash_input "$1")" "$D29")"; }
printf '%s\n' "$POST" > "$D29/posts.sh"
printf '%s\n' "$POST" > "$D29/posts"
printf '%s\n' 'echo ok' > "$D29/ok.sh"
printf '%s\n' 'echo ok' > "$D29/ok"
printf '%s\n' 'import urllib.request' 'urllib.request.urlopen("https://slack.com/api/chat.postMessage", data=b"text=hi")' > "$D29/posts.py"
printf '%s\n' 'print("ok")' > "$D29/ok.py"
printf '%s\n' 'cat posts.sh | (true; bash)' > "$D29/group.sh"
printf '%s\n' 'bash -c "cat posts.sh | bash"' > "$D29/string.sh"
printf '%s\n' 'bash<posts' > "$D29/glued.sh"
printf '%s\n' 'cat ok.sh | (true; bash)' > "$D29/okgroup.sh"
printf '%s\n' 'sort ok.sh | bash' > "$D29/unread-direct.sh"
printf '%s\n' 'sort ok.sh | (true; bash)' > "$D29/unread-group.sh"
# A function whose body runs its input, in a script on disk, fed where it is called or defined.
printf '%s\n' 'f() { bash; }' 'cat posts.sh | f' > "$D29/fn-pipe.sh"
printf '%s\n' 'f() { bash; }' 'f < posts.sh' > "$D29/fn-file.sh"
printf '%s\n' 'f() { bash; } < posts.sh' 'f' > "$D29/fn-def.sh"
printf '%s\n' 'f() { bash; }' 'cat posts.sh | { true; f; }' > "$D29/fn-group.sh"
printf '%s\n' 'f() { bash; }' '(f) < posts.sh' > "$D29/fn-sub.sh"
printf '%s\n' 'f() { bash; }' 'g() { f; }' 'cat posts.sh | g' > "$D29/fn-nest.sh"
printf '%s\n' 'function f {' '  bash' '}' 'if true; then f < posts.sh; fi' > "$D29/fn-if.sh"
printf '%s\n' 'f() { bash; }' 'cat ok.sh | f' 'f < ok.sh' 'f' > "$D29/fn-ok.sh"
printf '%s\n' 'f() { bash; }' 'sort ok.sh | f' > "$D29/fn-unread.sh"
printf '%s\n' 'f() { cat; }' 'cat posts.sh | f' 'g() { bash ok.sh; }' 'g < posts.sh' > "$D29/fn-reads-none.sh"
# Two functions that call each other, fed a script that posts and one that does not.
printf '%s\n' 'f() { bash; g; }' 'g() { f; }' 'cat posts.sh | g' > "$D29/fn-loop.sh"
printf '%s\n' 'f() { bash; g; }' 'g() { f; }' 'cat ok.sh | g' 'g < ok.sh' > "$D29/fn-loop-ok.sh"
NL='
'
run_29 "cat posts.sh | bash"
read_refused "#3229 the yardstick: a shell a pipe feeds a script that posts is refused"
says "#3229 and the yardstick's refusal names the file it runs" "runs what it reads on its input"
# A feed the gate cannot read is refused typed, as it is for a pipe straight into the shell, and left
# alone in a script on disk, as that is (unread-direct.sh and unread-group.sh, among the twins below).
run_29 "sort ok.sh | bash"
read_refused "#3229 the yardstick for an unread feed: a shell fed what sort prints is refused typed"
for runs in "sort ok.sh | (true; bash)" "sort ok.sh | { true; bash; }" "sort ok.sh | bash -c bash" "bash -c 'sort ok.sh | bash'" \
  "sort ok.sh | echo \$(bash)" "sort ok.sh | while true; do bash; break; done" "cat ok.sh | tee copy.txt | (true; bash)" \
  "f() { bash; }; cat ok.sh | f" "f() { bash; }; f"; do
  run_29 "$runs"
  read_refused "#3229 a shell handed a feed the gate cannot read by what is around it is refused typed: $runs"
  says "#3229 and the refusal says its input cannot be read: $runs" "what that holds cannot be read"
done
# The last two: a function's body is fed by whatever calls it, and not every way of calling one is
# worked out, so typed, a program that runs its input there is unread even where nothing feeds the
# call: the cost of the function case. Measured 2026-11-18 over 45 days of this Mac's Bash calls
# (147,020 calls, 123,744 distinct commands): 376 define a function, and it changes the verdict of none.
#
# A script that posts, handed to a shell or an interpreter by what is around it. In turn: a pipe into
# the subshell, group, if, loop or case it is in; a file, a here string or a heredoc given to that; a
# pipe into, or a file given to, a shell running a string, eval and find -exec with them, and a pipe
# inside the string; a command substitution in a command that is fed; a redirection glued to the
# name or to the file, with a file of no extension so nothing but the shell's name sends the call to
# the rule; `exec < file` before the shell and a redirection before its name; a function called with
# a feed; and the forms that were refused before, which still are; then scripts on disk holding one.
for runs in "cat posts.sh | (true; bash)" "cat posts.sh | (bash)" "cat posts.sh | { true; bash; }" "cat posts.sh | { bash; }" \
  "cat posts.sh | (true; (true; bash))" "cat posts.sh | { true && bash; }" "cat posts.sh | if true; then bash; fi" \
  "cat posts.sh | while true; do bash; break; done" "cat posts.sh | for i in 1; do bash; done" \
  "cat posts.sh | case x in x) bash ;; esac" "cat posts.sh | (true; sh)" "cat posts.sh | (true; env bash)" \
  "cat posts.sh | (exec bash)" "cat posts.sh | (true; bash -s)" "cat posts.sh | time (bash)" "cat posts.sh | { (bash); }" \
  "cat posts.py | (true; python3)" "cat posts.py | (true; python3 -)" "cat posts.sh | time bash" \
  "cat posts.sh | (true; bash > /dev/null)" "cat posts.sh | (bash &)" \
  "cat posts.sh | (true${NL}bash${NL})" "cat posts.sh | {${NL}true${NL}bash${NL}}" \
  "(bash) < posts.sh" "{ bash; } < posts.sh" "{ true; bash; } < posts.sh" "if true; then bash; fi < posts.sh" \
  "while true; do bash; break; done < posts.sh" "for i in 1; do bash; done < posts.sh" \
  "(true; bash) <<< \"\$(cat posts.sh)\"" "(true; bash) <<'EOF'${NL}${POST}${NL}EOF" "{ true; bash; } <<'EOF'${NL}${POST}${NL}EOF" \
  "cat <<'EOF' | (true; bash)${NL}${POST}${NL}EOF" "(if true; then bash; fi < posts.sh)" "( { true; bash; } < posts.sh )" \
  "cat posts.sh | bash -c \"bash\"" "cat posts.sh | bash -c 'true; bash'" "cat posts.sh | bash -c \"bash -c bash\"" \
  "cat posts.sh | sh -c 'sh'" "cat posts.sh | eval bash" "cat posts.sh | eval \"true; bash\"" "bash -c \"bash\" < posts.sh" \
  "bash -c \"cat posts.sh | bash\"" "bash -c \"cat posts.sh | (true; bash)\"" "bash -c \"bash < posts.sh\"" \
  "bash -c \"bash<posts\"" "bash -c 'cat posts.sh > >(bash)'" "eval \"cat posts.sh | bash\"" \
  "cat posts.py | bash -c \"python3\"" "sh -c \"cat posts.py | python3\"" "bash>out.txt -c 'bash posts.sh'" \
  "cat posts.sh | find . -maxdepth 0 -exec bash \\;" "bash -c bash <<'EOF'${NL}${POST}${NL}EOF" \
  "bash -c 'bash' <<< \"\$(cat posts.sh)\"" "cat posts.sh | (true; bash -c bash)" "bash -c \"(true; bash) < posts.sh\"" \
  "cat posts.sh | echo \$(bash)" "cat posts.sh | echo \`bash\`" "cat posts.sh | x=\$(bash) env" "cat posts.sh | (echo \$(bash))" \
  "echo \$(cat posts.sh | bash)" "echo \$(bash < posts.sh)" "x=\$(bash) < posts.sh" \
  "echo \$(cat posts.sh | (true; bash))" "cat posts.sh | echo \"\$(bash)\"" \
  "bash<posts" "bash<posts.sh" "sh<posts" "zsh<posts" "bash 0<posts" "(bash<posts)" "true;bash<posts" "bash<posts>out.txt" \
  "bash <posts" "bash <posts.sh" "bash <posts>out.txt" "python3<posts.py" "python3 <posts.py" "env bash<posts" "< posts bash" "<posts bash" \
  "bash>out.txt<posts" "bash<<<\"\$(cat posts)\"" "cat posts | { true; bash; }" "cat posts | {${NL}true${NL}bash${NL}}" \
  "cat posts | (true${NL}bash${NL})" "exec < posts; bash" "cat posts | (true; bash>out.txt)" "cat posts | (true; bash;)" \
  "cat posts | (true; bash&)" "true < posts; cat posts | (true;bash)" "\"bash\" posts" "\"bash\" < posts" "'bash' < posts" \
  "'bash'<posts" \
  "exec < posts.sh; bash" "exec < posts.sh${NL}bash" "exec 3< posts.sh; bash <&3" "bash 3< posts.sh <&3" \
  "f() { bash; }; cat posts.sh | f" "f() { bash; }; f < posts.sh" "f() { bash; } < posts.sh; f" \
  "cat posts.sh | bash -s" "cat posts.sh | bash -" "bash /dev/stdin < posts.sh" \
  "cat posts.sh | env bash" "cat posts.sh | exec bash" "cat posts.sh | command bash" "cat posts.sh | nohup bash" \
  "cat posts.sh | cat | bash" "cat posts.sh | tee /dev/null | bash" "{ cat posts.sh; } | bash" "(cat posts.sh) | bash" \
  "cat posts.sh | { cat; } | bash" "cat posts.sh | (cat | bash)" "cat posts.sh |& bash" \
  "cat posts.sh | bash -c 'read -r l; eval \"\$l\"'" "cat posts.sh | (read -r l; eval \"\$l\")" \
  "cat posts.sh | while read -r l; do eval \"\$l\"; done" \
  "bash group.sh" "bash string.sh" "bash glued.sh"; do
  run_29 "$runs"
  read_refused "#3229 a shell handed a script that posts by what is around it is refused: $runs"
done
# A function's body in a script on disk. A feed the gate cannot read is left alone there, as it is
# for a pipe straight into a shell, and the function case was nothing but such a feed, so a script on
# disk that hands its function a script that posts passed whole. What is written where the function
# is called, or on its definition, is read like any other feed, through a group, a subshell, an if
# or another function that calls it.
for runs in "bash fn-pipe.sh" "bash fn-file.sh" "bash fn-def.sh" "bash fn-group.sh" "bash fn-sub.sh" "bash fn-nest.sh" \
  "bash fn-if.sh" "bash fn-loop.sh"; do
  run_29 "$runs"
  read_refused "#3229 a function fed a script that posts, in a script on disk, is refused: $runs"
  says "#3229 and the refusal names the file the function's program runs: $runs" "posts.sh"
done
for runs in "bash fn-ok.sh" "bash fn-unread.sh" "bash fn-reads-none.sh" "bash fn-loop-ok.sh"; do
  run_29 "$runs"
  allowed "#3229 a function fed nothing that posts, or running none of its input, passes on disk as before: $runs"
done
# Not covered here, and not by this gate at all: a function whose body is a subshell, `f() ( bash )`.
# The shared reader gives the whole definition as one command, so the commands of its body are read
# by nobody (measured 2026-11-18 with harmless files: `f() ( sort ok.sh | bash ); f` exits 0 where
# `f() { sort ok.sh | bash; }; f` and `( sort ok.sh | bash )` are refused). Recorded for an issue of
# its own against lib/shell-words.py, which every guard reads through.
#
# Where the reading of what is around a program cannot be finished, the answer is an unread feed,
# never that nothing feeds it: a group or an if left open, subshells past the depth that is read,
# functions that call each other. Each is fed a file that posts nothing here, so the refusal is the
# reading giving up, not the file.
for runs in "cat ok.sh | { true; bash" "cat ok.sh | if true; then bash" \
  "cat ok.sh | (true; (true; (true; (true; (true; (true; (true; (true; (true; (true; bash))))))))))" \
  "f() { bash; g; }; g() { f; }; cat ok.sh | g"; do
  run_29 "$runs"
  read_refused "#3229 a reading of what feeds a program that cannot be finished is refused typed: $runs"
  says "#3229 and the refusal says its input cannot be read: $runs" "what that holds cannot be read"
done
# The same for a reading that fails part way: the gate's own code, with the one step that looks for
# the pipe into a group made to fail as the shared reader fails on text it cannot read. The control
# is the same copy judging the same shape without the word that makes it fail.
mkdir -p "$D29/failing"
cp "$HOOK" "$D29/failing/slack-drafts-only-gate.sh"
ln -s "$DIR/lib" "$D29/failing/lib"
cat > "$D29/failing/slack_drafts_only_gate.py" <<'PY'
import importlib.util, os
spec = importlib.util.spec_from_file_location("gate", os.environ["REAL_GATE_3229"])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)
real = gate.Judge.sh_pipe_into
def failing(self, s, *a, **k):
    if "UNREADABLE-3229" in s:
        raise self.sw.Unreadable("made to fail by the suite")
    return real(self, s, *a, **k)
gate.Judge.sh_pipe_into = failing
gate.main()
PY
run_failing() { # run_failing <command>: judged by the copy whose look for a pipe fails on UNREADABLE-3229
  local errf; errf="$(mktemp "${TMPDIR:-/tmp}/slack-gate-err.XXXXXXXX")"
  OUT="$(payload Bash "$(bash_input "$1")" "$D29" | REAL_GATE_3229="$DIR/slack_drafts_only_gate.py" bash "$D29/failing/slack-drafts-only-gate.sh" 2>"$errf")"; RC=$?
  ERR="$(cat "$errf")"; rm -f "$errf"
}
run_failing "cat ok.sh | { echo plain; bash; }"
allowed "#3229 the copy made to fail judges a fed group as the gate does where nothing fails"
run_failing "cat ok.sh | { echo UNREADABLE-3229; bash; }"
read_refused "#3229 a reading of what feeds a program that fails part way is refused, not taken as nothing feeding it"
says "#3229 and that refusal says its input cannot be read" "what that holds cannot be read"
# What it costs, each beside the shape it is the harmless twin of. A shell handed a file that posts
# nothing through any of these still passes, the file being read as it is for `cat ok.sh | bash`.
run_29 "cat ok.sh | bash"
allowed "#3229 the twins' yardstick: a shell a pipe feeds a script that posts nothing passes"
for runs in "cat ok.sh | (true; bash)" "cat ok.sh | { true; bash; }" "cat ok.sh | if true; then bash; fi" \
  "cat ok.sh | while true; do bash; break; done" "cat ok.py | (true; python3)" "(bash) < ok.sh" "{ true; bash; } < ok.sh" \
  "(true; bash) <<< 'echo ok'" "(true; bash) <<'EOF'${NL}echo ok${NL}EOF" "cat ok.sh | bash -c \"bash\"" "bash -c \"bash\" < ok.sh" \
  "bash -c \"cat ok.sh | bash\"" "bash -c bash <<'EOF'${NL}echo ok${NL}EOF" "cat ok.sh | eval bash" "cat ok.sh | echo \$(bash)" \
  "bash<ok" "bash<ok.sh" "bash <ok" "bash 0<ok" "'bash'<ok" "bash<ok>out.txt" "python3 <ok.py" "< ok.sh bash" "exec < ok.sh; bash" \
  "bash okgroup.sh" "bash unread-direct.sh" "bash unread-group.sh"; do
  run_29 "$runs"
  allowed "#3229 a shell handed a script that posts nothing by what is around it still passes: $runs"
done
# And nothing around a program is taken to feed it that does not: a shell with no input at all, one
# given its own file or script, a program that runs none of its input, a pipe that ended before the
# group, a descriptor other than the input, a < inside a quoted word.
for runs in "(true; bash)" "{ true; bash; }" "bash -c bash" "echo \$(bash)" "(true; bash --version)" \
  "cat posts.sh | (true; cat)" "cat posts.sh | bash -c \"cat\"" "cat posts.sh | echo \$(cat)" "cat posts.sh | (cd . && wc -l)" \
  "echo hi | bash -c 'cat > out.txt'" "cat posts.sh | while read -r l; do echo \"\$l\"; done" "(true; bash ok.sh)" \
  "cat posts.sh | (true; bash ok.sh)" "cat posts.sh | bash -c 'bash ok.sh'" "bash -c \"cat posts.sh | wc -l\"" \
  "cat posts.sh | (true; bash -c 'echo hi')" "cat posts.sh | (true; python3 -c 'print(1)')" "cat posts.sh | (true; python3 ok.py)" \
  "cat posts.sh | (true; bash < ok.sh)" "cat posts.sh | bash -c 'bash < ok.sh'" "cat posts.sh | (true; cat ok.sh | bash)" \
  "cat posts.sh > /dev/null; (true; bash)" "cat posts.sh | wc -l; (true; bash)" "cat posts.sh | wc -l; bash -c bash" \
  "exec 3< posts.sh; bash" "true < posts.sh; bash" "cat posts.sh | grep -c bash" "echo bash<posts" "wc -l<posts" "cat <posts.sh" \
  "python3 -c 'print(1<2)'" "echo \"a<b\" posts" "sort <ok.sh >out.txt" "du -sh" "bash ok"; do
  run_29 "$runs"
  allowed "#3229 a program nothing feeds, or that runs none of its input, passes as before: $runs"
done

echo


sdg_harness_result
