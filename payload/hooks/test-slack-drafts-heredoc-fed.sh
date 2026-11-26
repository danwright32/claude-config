#!/usr/bin/env bash
# Tests for where the Slack drafts gate's own reading of a heredoc's body ends (Judge.fed,
# claude-config#3497).
#
# fed() works out what a shell or an interpreter that reads its input is fed. For a heredoc it cut
# the lines after the command up to the first line that, with the blanks round it taken off, was
# the first plain word after the <<. The shells end a heredoc only at a line that IS its marker (a
# <<- lets leading tabs go and nothing else), read the whole word after the << as the marker, and
# in an unquoted body join a line ending in a backslash to the next. So fed() ended a body early
# at a marker with a space or a tab beside it, at the first letters of a longer marker (<<E"F",
# <<E-1), at a line that belongs to an earlier heredoc of the same line, and at a marker a
# backslash joins to the line before, and the lines the shell went on feeding the program were
# read as shell commands, where an import names no file. The shared reader refuses a joined marker
# (#3495), but gives up on a text whose earlier heredoc leaves a $( open before it reaches the
# later one, and the gate then judged it by fed() alone. Measured 2026-11-23 at 4ba7b6ba78 (the
# issue's comment) and 2026-11-26 on main at 6c4cee7247, through this wrapper: exit 0 for each.
#
# fed() now reads the body to where bash 3.2 and zsh end it, and where it cannot tell (a line
# joined by a backslash before the marker, a marker it cannot read) the gate refuses the command
# as one it could not check. The last section holds fed() against the shells of the machine the
# suite runs on, with texts that only print.
#
# Kept apart from test-slack-drafts-comment-start.sh, which covers the reader's side of a heredoc,
# so that suite does not grow; the helpers below are copied from it as they are, so a case here is
# driven the same way: a hook payload piped into slack-drafts-only-gate.sh, exit 0 allowed and 2
# refused, the reason on stderr. Nothing a case names is ever run but the texts of the last
# section, which only print, and no file here holds a token, a webhook address or a channel.
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
check() { if [[ "$2" == "ok" ]]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1 ($2)"; fi; }

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
run_bash() { run_raw "$(payload Bash "$(bash_input "$1")" "${2:-$T}")"; }

refused() { if [ "$RC" -eq 2 ]; then check "$1" ok; else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
allowed() { if [ "$RC" -eq 0 ] && [ -z "$(printf '%s%s' "$OUT" "$ERR" | tr -d '[:space:]')" ]; then check "$1" ok
            else check "$1" "exit $RC, stdout: ${OUT:0:200}, stderr: ${ERR:0:300}"; fi; }
says() { case "$ERR" in *"$2"*) check "$1" ok ;; *) check "$1" "stderr did not say '$2': ${ERR:0:400}" ;; esac; }

BS='\'
NL=$'\n'
TAB=$'\t'
shown() { local s="${1//$NL/ (line break) }"; printf '%s' "${s//$TAB/(tab)}"; }
POSTS="REFUSED: this command posts to Slack"
COULD_NOT="REFUSED: the gate could not check whether this command posts to Slack"

# The folder every case runs in: a module and a script that post, and one of each that does not.
FED="$T/fed"
mkdir -p "$FED"
printf '%s\n' 'import urllib.request' "urllib.request.urlopen('https://slack.com/api/chat.postMessage', b'text=hi')" > "$FED/poster.py"
printf '%s\n' 'x = 1' > "$FED/quiet.py"
printf '%s\n' 'curl -s -X POST -d text=hi https://slack.com/api/chat.postMessage' > "$FED/posts.sh"
printf '%s\n' 'echo hi' > "$FED/quiet.sh"

echo "slack drafts only: a heredoc feeds a program every line the shells feed it (claude-config#3497)"

# The controls, as they were before this change: a body every shell ends at its marker.
run_bash "python3 <<E${NL}import poster${NL}E" "$FED"
refused "the control: python3 fed a program that imports a module that posts is refused"
says "the control: as the post it is" "$POSTS"
run_bash "python3 <<E${NL}import quiet${NL}E" "$FED"
allowed "the control: python3 fed a program that imports a quiet module passes"
run_bash "python3 <<E${NL}pass${NL}E${NL}import poster" "$FED"
allowed "the control: after a heredoc every shell closes, the same line is a shell command that names no file, and passes"

# A line that is the marker with a blank beside it ends nothing: the shells feed the program that
# line and every line after it, to the marker on a line of its own or to the end of the text. Each
# shape feeds a module, then a script, that posts, and then one that does not. @P@ stands for the
# program and its first line, @M@ for what the body goes on to hold.
while IFS= read -r shape; do
  [ -n "$shape" ] || continue
  shape="${shape//@NL@/$NL}"; shape="${shape//@TAB@/$TAB}"
  for feeds in "python3:pass:import poster:import quiet" "bash:true:bash posts.sh:bash quiet.sh"; do
    prog="${feeds%%:*}"; rest="${feeds#*:}"; first="${rest%%:*}"; rest="${rest#*:}"
    loud="${rest%%:*}"; calm="${rest#*:}"
    text="${shape//@P@/$prog}"; text="${text//@1@/$first}"
    run_bash "${text//@M@/$loud}" "$FED"
    refused "$prog fed a line that posts, after a line the shells do not end the heredoc at, is refused: $(shown "$shape")"
    says "as the post it is: $prog, $(shown "$shape")" "$POSTS"
    printf '%s\n' "${text//@M@/$loud}" > "$FED/script.sh"
    run_bash "bash script.sh" "$FED"
    refused "and the same lines in a script that is run are refused: $prog, $(shown "$shape")"
    run_bash "${text//@M@/$calm}" "$FED"
    allowed "the same heredoc feeding a line that does not post passes: $prog, $(shown "$shape")"
  done
done <<'SHAPES'
@P@ <<E@NL@@1@@NL@ E@NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@E @NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@@TAB@E@NL@@M@@NL@E
@P@ <<'E'@NL@@1@@NL@ E@NL@@M@@NL@E
@P@ <<"E"@NL@@1@@NL@E @NL@@M@@NL@E
@P@ <<-E@NL@@1@@NL@ E@NL@@M@@NL@@TAB@E
@P@ <<-E@NL@@1@@NL@@TAB@ E@NL@@M@@NL@E
@P@ <<E@NL@@1@@NL@ E@NL@@M@
@P@ <<'E'@NL@@1@@NL@E @NL@@M@
@P@ <<E"F"@NL@@1@@NL@E@NL@@M@@NL@EF
@P@ <<E-1@NL@@1@@NL@E@NL@@M@@NL@E-1
@P@ <<E.x@NL@@1@@NL@E@NL@@M@@NL@E.x
: <<A | @P@ <<B@NL@B@NL@A@NL@@M@@NL@B
SHAPES

# A marker written with a backslash is a quoted one to the shells, and a word fed() never read as
# an opener at all: it gave the program's own line for what it is fed, so the body was read by
# nobody. Reading it now would let through what a pipe from such a heredoc was refused for (what
# cat prints from one was not known), so the gate says it does not read that marker, whatever the
# body holds, and how to write it.
for marked in "python3 <<${BS}E" "python3 - <<${BS}EOF" "bash <<${BS}E" "python3 <<E <<F"; do
  for body in "import poster" "import quiet"; do
    run_bash "$marked${NL}$body${NL}E" "$FED"
    refused "a program fed by a heredoc whose marker the gate does not read is refused: $marked, $body"
    says "as a check it could not make: $marked, $body" "$COULD_NOT"
    says "naming the line and how to write the marker: $marked, $body" "it feeds a program by a heredoc whose end the gate does not read, in the line \`$marked\`"
  done
done

# The measured shape: an earlier heredoc whose body leaves a substitution open makes the shared
# reader give up on the whole text before it reaches the heredoc that feeds python3, whose marker
# a backslash joins to the line before. Every shell keeps that heredoc open and feeds python3 the
# import (bash 3.2, bash --posix, sh and ksh, measured 2026-11-23, the issue's comment). The gate
# cannot follow such a text whatever it feeds, so a quiet module is refused too.
for open in '$(echo' '`echo' '${x'; do
  lead="cat <<A${NL}${open}${NL}A${NL}"
  run_bash "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import poster" "$FED"
  refused "python3 fed a module that posts through a heredoc a backslash keeps open, after a heredoc the reader gives up on, is refused: $open"
  says "and as a check it could not make: $open" "$COULD_NOT"
  says "naming the heredoc and the line it opens on: $open" "it opens a heredoc the gate cannot find the end of, in the line \`python3 <<E\`"
  printf '%s\n' "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import poster" > "$FED/script.sh"
  run_bash "bash script.sh" "$FED"
  refused "and the same lines in a script that is run are refused: $open"
  run_bash "${lead}python3 <<E${NL}# note$BS${NL}E${NL}import quiet" "$FED"
  refused "the same open heredoc feeding a quiet module is refused too, since the gate cannot read it: $open"
  says "and as a check it could not make, not as a post: $open" "$COULD_NOT"
  # The control: with no backslash every shell ends the heredoc at E, and the import is a shell
  # command that names no file.
  run_bash "${lead}python3 <<E${NL}# note${NL}E${NL}import poster" "$FED"
  allowed "the control: the same text with no backslash, where every shell ends the heredoc, passes: $open"
done

# What must still pass: a body whose lines a backslash joins, and whose marker follows a line that
# ends in none, is ended at that marker by every shell.
run_bash "python3 <<E${NL}x = 1 + $BS${NL}    2${NL}import quiet${NL}E${NL}echo done" "$FED"
allowed "a heredoc whose body joins two lines and then ends at its marker passes"
run_bash "python3 - <<'EOF'${NL}import quiet${NL}print('a $BS${NL}EOF b')${NL}EOF${NL}echo done" "$FED"
allowed "a quoted heredoc with a backslash at a line's end passes, the body read as written"
run_bash "python3 <<E${NL}x = 1 + $BS${NL}    2${NL}import poster${NL}E" "$FED"
refused "and the same joined body importing a module that posts is refused"
says "as the post it is" "$POSTS"

echo "slack drafts only: fed() ends a heredoc where the shells of this machine end it (claude-config#3497)"

# fed() against the shells themselves (L58): each text is run in every shell found here, with cat
# as the program and nothing after the heredoc but lines that print nothing, so what the shell
# prints is what it fed. fed() must give that body ("same"); or at least those lines, for a
# heredoc that follows another on its line, where it goes on giving the lines it always gave
# ("more"); or raise the refusal (UnsureComment), for a row it does not vouch for ("refuse": it
# must raise, and may never give a body the shell does not feed). One line per finding, then the
# count of comparisons made and the shells they ran in, so comparing nothing is a finding and not
# a pass (L98).
cat > "$T/shells.py" <<'PY'
import importlib.util, os, re, shutil, subprocess, sys, tempfile

spec = importlib.util.spec_from_file_location("gate", sys.argv[1])
gate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gate)

SHELLS = {"bash": ["bash", "--noprofile", "--norc", "-c"], "sh": ["sh", "-c"], "zsh": ["zsh", "-f", "-c"]}
HAVE = [name for name in SHELLS if shutil.which(SHELLS[name][0])]
BS, TAB = "\\", "\t"
# (the command fed() is asked about, the whole text's lines, what fed() must do)
ROWS = [
    ("cat <<E", ["cat <<E", "a", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", " E", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", "E ", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", TAB + "E", "b", "E"], "same"),
    ("cat <<-E", ["cat <<-E", "a", TAB + "E"], "same"),
    ("cat <<-E", ["cat <<-E", "a", " E", "b", TAB + TAB + "E"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a", " E", "b", "E"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a" + BS, "E"], "same"),
    ('cat <<"E"', ['cat <<"E"', "a", "E ", "b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a" + BS + BS, "E"], "same"),
    ("cat <<E", ["cat <<E", "a + " + BS, "  b", "E"], "same"),
    ("cat <<E", ["cat <<E", "a", " E", "b"], "same"),
    ("cat <<'E'", ["cat <<'E'", "a", "E ", "b"], "same"),
    ('cat <<E"F"', ['cat <<E"F"', "a", "E", "b", "EF"], "same"),
    ("cat <<E-1", ["cat <<E-1", "a", "E", "b", "E-1"], "same"),
    ("cat <<E.x", ["cat <<E.x", "a", "E", "b", "E.x"], "same"),
    ("cat <<E" + BS + "OF", ["cat <<E" + BS + "OF", "a", "E", "b", "EOF"], "same"),
    ("cat <<B", [": <<A | cat <<B", "B", "A", "x", "B"], "more"),
    ("cat <<B", [": <<A | cat <<B", "a", "A", "x", " B", "y", "B"], "more"),
    ("cat <<" + BS + "E", ["cat <<" + BS + "E", "a", "E"], "refuse"),
    ("cat <<E", ["cat <<E", "a" + BS, "E", "b", "E"], "refuse"),
    ("cat <<E", ["cat <<E", "a" + BS, "E", "b"], "refuse"),
    ("cat <<E", ["cat <<E", BS, "E", "b", "E"], "refuse"),
    ("cat <<E", ["cat <<E", "a", "E" + BS, "", "b", "E"], "refuse"),
]


def unquoted(command):
    return not re.search(r"['\"\\]", command.split("<<", 1)[1])


def as_fed(body, command):
    """body as the shell hands it on: in an unquoted heredoc a backslash and a line break vanish,
    and a backslash before a backslash is one."""
    if not unquoted(command):
        return body
    return re.sub(r"\\(\n|\\)", lambda m: "" if m.group(1) == "\n" else "\\", body)


made, d = 0, tempfile.mkdtemp()
for command, lines, want in ROWS:
    whole = "\n".join(lines) + "\n"
    where = whole.replace("\n", " (line break) ").replace(TAB, "(tab)")
    printed = {}
    for shell in HAVE:
        try:
            p = subprocess.run(SHELLS[shell] + [whole], cwd=d, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                               stderr=subprocess.DEVNULL, timeout=20)
        except subprocess.TimeoutExpired:
            print("FAIL %s did not end within 20 seconds: %s" % (shell, where))
            continue
        printed[shell] = p.stdout.decode("utf-8", "replace").rstrip("\n")
    try:
        got = gate.Judge.fed(command, whole)
    except gate.UnsureComment:
        got = None
    for shell, out in printed.items():
        made += 1
        gave = None if got is None else as_fed(got[0], command).rstrip("\n")
        if want == "refuse":
            if got is not None:
                print("FAIL fed() did not refuse a heredoc it cannot vouch for, and gave %r where %s fed %r: %s"
                      % (got[0], shell, out, where))
        elif got is None:
            print("FAIL fed() refused a heredoc %s ends plainly: %s" % (shell, where))
        elif not got[1]:
            print("FAIL fed() gave no body for a heredoc %s gave one: %s" % (shell, where))
        elif gave != out and not (want == "more" and ("\n" + gave).endswith("\n" + out)):
            print("FAIL fed() gave %r where %s fed %r: %s" % (got[0], shell, out, where))
shutil.rmtree(d, ignore_errors=True)
print("made %d" % made)
# Each shell with the version it gives of itself, so a run says what it measured.
ASK = {"bash": "echo $BASH_VERSION", "sh": "echo ${BASH_VERSION:-${KSH_VERSION:-unnamed}}", "zsh": "echo $ZSH_VERSION"}
said = []
for shell in HAVE:
    p = subprocess.run(SHELLS[shell] + [ASK[shell]], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                       stderr=subprocess.DEVNULL, timeout=20)
    said.append("%s=%s" % (shell, p.stdout.decode("utf-8", "replace").strip().replace(" ", "_") or "unnamed"))
print("shells %s" % " ".join(said))
PY
rows="$(python3 -B "$T/shells.py" "$DIR/slack_drafts_only_gate.py" 2>&1)"
made=0; ran=""
while IFS= read -r row; do
  case "$row" in
    "made "*) made="${row#made }" ;;
    "shells "*) ran="${row#shells }" ;;
    "") ;;
    *) check "fed() ends a heredoc where the shell ends it" "$row" ;;
  esac
done <<EOF
$rows
EOF
if [ "$made" -ge 20 ] 2>/dev/null; then check "fed() was held against the shells of this machine ($made comparisons, in: $ran)" ok
else check "fed() was held against the shells of this machine" "only '$made' comparisons were made, in: '$ran'"; fi
case " $ran " in *" bash="*) check "bash is among the shells fed() was held against" ok ;;
  *) check "bash is among the shells fed() was held against" "ran in: '$ran'" ;; esac
echo "  fed() held against the shells: $made comparisons, in: $ran"

echo

echo "passed: $pass, failed: $fail"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"

[ "$fail" -eq 0 ]
