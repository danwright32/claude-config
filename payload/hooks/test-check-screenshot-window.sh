#!/usr/bin/env bash
# Tests for check-screenshot-window.sh and its judge screenshot_window_gate.py (claude-config#2908): a
# Bash command that runs screencapture without naming one window by its id (-l) is refused before it
# runs, in every spelling that runs it, and one capturing a single window, or only mentioning the
# tool, is not.
#
# On 2026-11-13 a session checking one app's state ran a full screen `screencapture -x` while another
# app was in front, and that app's private content landed in the transcript.
#
# The hook never runs screencapture, and nothing here does either: each case hands the hook a
# PreToolUse payload and reads its exit code and what it said. No screenshot is ever taken.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="$DIR/check-screenshot-window.sh"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }
check(){ if [[ "$3" == *"$2"* ]]; then ok; else bad "$1"; echo "  expected to contain: $2"; echo "  actual: ${3:0:1500}"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-check-screenshot-window: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

payload(){ # payload <command>
  python3 -c 'import json, sys; print(json.dumps({"tool_name": "Bash", "tool_input": {"command": sys.argv[1]}, "cwd": sys.argv[2]}))' "$1" "$WORKDIR"
}
judge(){ # judge <command> [hook]: sets out and rc
  out="$(payload "$1" | bash "${2:-$HOOK}" 2>&1)"; rc=$?
}
refused(){ # refused <name> <command>
  judge "$2"
  check_eq "#2908 refused: $1" "2" "$rc"
  check "#2908 and the refusal names the window form: $1" "screencapture -l <windowid>" "$out"
}
allowed(){ # allowed <name> <command>
  judge "$2"
  check_eq "#2908 allowed: $1" "0" "$rc"
  check_eq "#2908 and nothing is said: $1" "" "$out"
}

# 1. A capture of the whole screen is refused, in every spelling that runs screencapture.
refused "the bare form of the incident" "screencapture -x /tmp/shot.png"
refused "no options at all, only a file" "screencapture /tmp/shot.png"
refused "to the clipboard" "screencapture -c"
refused "one display" "screencapture -x -D 1 /tmp/shot.png"
refused "the main monitor" "screencapture -m /tmp/shot.png"
refused "by its full path" "/usr/sbin/screencapture -x /tmp/shot.png"
refused "in another case, which the file system still finds" "ScreenCapture -x /tmp/shot.png"
refused "after cd &&" "cd /tmp && screencapture -x shot.png"
refused "after a semicolon" "git status; screencapture -x /tmp/shot.png"
refused "after ||" "false || screencapture -x /tmp/shot.png"
refused "in a pipe" "screencapture -c | cat"
refused "in a subshell" "(cd /tmp && screencapture -x shot.png)"
refused "in a command substitution" 'echo "$(screencapture -x /tmp/shot.png)"'
refused "inside if" "if true; then screencapture -x /tmp/shot.png; fi"
refused "on the second line" "$(printf 'echo start\nscreencapture -x /tmp/shot.png')"
refused "in a substitution in an unquoted heredoc body" $'cat <<EOF\n$(screencapture -x /tmp/shot.png)\nEOF'
refused "behind env" "env screencapture -x /tmp/shot.png"
refused "behind env with a setting and the full path" "env A=1 /usr/sbin/screencapture -x /tmp/shot.png"
refused "behind an inline assignment" "A=1 screencapture -x /tmp/shot.png"
refused "behind command" "command screencapture -x /tmp/shot.png"
refused "behind exec" "exec screencapture -x /tmp/shot.png"
refused "behind sudo" "sudo screencapture -x /tmp/shot.png"
refused "behind nohup" "nohup screencapture -x /tmp/shot.png"
refused "behind timeout" "timeout 5 screencapture -x /tmp/shot.png"
refused "behind time" "time screencapture -x /tmp/shot.png"
refused "behind rtk proxy" "rtk proxy screencapture -x /tmp/shot.png"
refused "behind a redirection" "2>/dev/null screencapture -x /tmp/shot.png"
refused "quoted" "'screencapture' -x /tmp/shot.png"
refused "inside bash -c" "bash -c 'screencapture -x /tmp/shot.png'"
refused "inside zsh -c" 'zsh -c "screencapture -x /tmp/shot.png"'
refused "inside eval" "eval 'screencapture -x /tmp/shot.png'"
refused "behind xargs, which adds words nobody wrote" "echo /tmp/shot.png | xargs screencapture"
refused "behind xargs with only a quiet flag" "echo /tmp/shot.png | xargs screencapture -x"
printf '#!/bin/bash\nscreencapture -x /tmp/shot.png\n' > "$WORKDIR/shot.sh"
refused "in a script file run by bash" "bash $WORKDIR/shot.sh"
refused "in a script file run by its path" "$WORKDIR/shot.sh"
printf '#!/bin/bash\nscreencapture -l 123 /tmp/w.png\n' > "$WORKDIR/window.sh"
allowed "a script file capturing one window" "bash $WORKDIR/window.sh"
printf '#!/bin/bash\necho hi\n' > "$WORKDIR/plain.sh"
allowed "a script file capturing nothing" "bash $WORKDIR/plain.sh"
# A quote never closed leaves only the crude cut at every separator, which still holds the capture.
refused "after a quote never closed, read by the crude cut" "echo don't; screencapture -x /tmp/shot.png"

# 2. A window id that is not really there.
refused "-l with no id" "screencapture -l"
refused "-l last in a cluster with no id after it" "screencapture -xl"
refused "-l after the file, which screencapture reads as a file name" "screencapture /tmp/shot.png -l 123"
refused "-l after --, a file name" "screencapture -x -- -l 123"

# 3. Region, interactive, video and settings flags are refused even beside -l (the choice recorded in
# the hook's header): each captures more than the one window, or waits for a click from a person who
# may not be there, or both.
refused "a rectangle" "screencapture -R 0,0,400,300 /tmp/shot.png"
refused "a rectangle beside -l" "screencapture -l 123 -R 0,0,400,300 /tmp/shot.png"
refused "interactive" "screencapture -i /tmp/shot.png"
refused "interactive beside -l" "screencapture -l 123 -i /tmp/shot.png"
refused "interactive window selection" "screencapture -iw /tmp/shot.png"
refused "window selection only" "screencapture -w /tmp/shot.png"
refused "start in window selection" "screencapture -W /tmp/shot.png"
refused "mouse selection only" "screencapture -s /tmp/shot.png"
refused "an interactive style" "screencapture -J window /tmp/shot.png"
refused "the interactive toolbar" "screencapture -U /tmp/shot.png"
refused "the screenshot UI after" "screencapture -l 123 -u /tmp/shot.png"
refused "the screen instead of the window" "screencapture -l 123 -S /tmp/shot.png"
refused "a video of the screen" "screencapture -v /tmp/rec.mov"
refused "a timed video beside -l" "screencapture -l 123 -V 5 /tmp/rec.mov"
refused "the default settings, which ignore the file" "screencapture -l 123 -p"
refused "a display beside -l" "screencapture -l 123 -D 2 /tmp/shot.png"

# 4. One window by its id passes, in every spelling, and so does every mention.
allowed "one window by its id" "screencapture -l 12345 /tmp/w.png"
allowed "the id glued to -l" "screencapture -x -l12345 /tmp/w.png"
allowed "-l last in a cluster, its id the next word" "screencapture -xl 12345 /tmp/w.png"
allowed "-l inside a cluster with its id glued" "screencapture -xol12345 /tmp/w.png"
allowed "the id from a variable, by the full path" '/usr/sbin/screencapture -o -x -l "$WID" /tmp/w.png'
allowed "the id from a substitution" 'screencapture -l "$(cat /tmp/wid)" /tmp/w.png'
allowed "after cd, with a format and a delay" "cd /tmp && screencapture -l 5 -t jpg -T 1 w.jpg"
allowed "one window to the clipboard" "screencapture -c -l 5"
allowed "behind env" "env screencapture -l 5 /tmp/w.png"
allowed "inside bash -c" "bash -c 'screencapture -l 5 /tmp/w.png'"
allowed "behind xargs with the id written" "echo /tmp/w.png | xargs screencapture -l 5"
allowed "with a redirection between the options" "screencapture -x 2>/dev/null -l 5 /tmp/w.png"
allowed "with no arguments, which only prints its usage" "screencapture"
allowed "its help" "screencapture -h"
allowed "command -v finds it and runs nothing" "command -v screencapture"
allowed "a mention in echo" 'echo "screencapture -x /tmp/shot.png"'
allowed "a grep for it" "grep -n screencapture /tmp/notes.txt"
allowed "its manual" "man screencapture"
allowed "which" "which screencapture"
allowed "a commit message" "git commit -m 'refuse a bare screencapture -x'"
allowed "a quoted heredoc body, which is text" $'cat <<\'EOF\'\nscreencapture -x /tmp/shot.png\nEOF'
allowed "a command naming nothing of it" "ls -la"
allowed "a longer name" "screencapture-helper -x /tmp/shot.png"

# 5. Built is not wired (L3): registered to see every Bash call before it runs, blocking on failure.
. "$DIR/lib/settings-file.sh"
SETTINGS="$(hook_settings_file "$DIR/..")"
wired="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
print(sum(1 for m in d["hooks"].get("PreToolUse", []) if m.get("matcher") == "Bash"
          for h in m["hooks"] if h.get("command", "").endswith("/hooks/check-screenshot-window.sh")
          and h.get("onFailure") == "block"))' "${SETTINGS:-/dev/null}")"
check_eq "#2908 registered once as a PreToolUse hook on Bash, blocking on failure" "1" "$wired"

# 6. With the reader missing the command cannot be read word by word, so a command putting
# screencapture at the start of a command is refused as not judged, naming what is missing.
LONE="$WORKDIR/lone"; mkdir -p "$LONE"
cp "$HOOK" "$DIR/screenshot_window_gate.py" "$LONE/"
judge "screencapture -x /tmp/shot.png" "$LONE/check-screenshot-window.sh"
check_eq "#2908 with lib/shell-words.py missing, a capture is refused" "2" "$rc"
check "#2908 and says it could not be read" "could not be read" "$out"
check "#2908 and names the missing file" "shell-words.py" "$out"
check "#2908 and still names the window form" "screencapture -l <windowid>" "$out"
judge "cd /tmp && /usr/sbin/screencapture -c" "$LONE/check-screenshot-window.sh"
check_eq "#2908 with the reader missing, a capture after cd by its path is refused" "2" "$rc"
judge "grep -n screencapture /tmp/notes.txt" "$LONE/check-screenshot-window.sh"
check_eq "#2908 control: with the reader missing, a grep for it passes in silence" "0|" "$rc|$out"
judge "ls -la" "$LONE/check-screenshot-window.sh"
check_eq "#2908 control: with the reader missing, a command naming nothing of it passes" "0|" "$rc|$out"

# The judge missing is the same.
NOJUDGE="$WORKDIR/nojudge"; mkdir -p "$NOJUDGE"
cp "$HOOK" "$NOJUDGE/"
cp -R "$DIR/lib" "$NOJUDGE/lib"
judge "screencapture -x /tmp/shot.png" "$NOJUDGE/check-screenshot-window.sh"
check_eq "#2908 with the judge missing, a capture is refused" "2" "$rc"
check "#2908 and names the judge" "screenshot_window_gate.py" "$out"

# With no python3 at all the wrapper reads the text the same crude way.
NOPY="$WORKDIR/nopy"; mkdir -p "$NOPY"
p="$(command -v bash)" && ln -sf "$p" "$NOPY/bash"
nopy(){ out="$(payload "$1" | PATH="$NOPY" "$NOPY/bash" "$HOOK" 2>&1)"; rc=$?; }
nopy "screencapture -x /tmp/shot.png"
check_eq "#2908 with no python3, a capture is refused" "2" "$rc"
check "#2908 and says why it could not be read" "python3" "$out"
nopy "ls -la"
check_eq "#2908 control: with no python3, a command naming nothing of it passes in silence" "0|" "$rc|$out"

# A payload nothing can parse, naming screencapture at the start of the command, is refused.
out="$(printf '{"tool_name": "Bash", "tool_input": {"command": "screencapture -x /tmp/shot.png"' | bash "$HOOK" 2>&1)"; rc=$?
check_eq "#2908 a payload nothing can read, running screencapture, is refused" "2" "$rc"
check "#2908 and says it could not be read" "could not be read" "$out"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[[ "$fail" -eq 0 ]]
