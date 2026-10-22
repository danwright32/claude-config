#!/usr/bin/env bash
# Tests for the one reading of which gh or git subcommand a command runs (claude-config#1188):
# lib/shell-words.py's tool reading, lib/push-scope.sh's ps_runs_gh and ps_runs_git over it, and
# lib/word-position-scan.py, which fails on a hook that reads the subcommand by word position again.
#
# gh takes a subcommand's flags written in front of it (`gh -R o/x pr create`, `gh pr -R o/x create`,
# measured on gh 2.89.0), and every gate but the merge gates read gh by its first three words, so a
# flag in front walked a pull request past the closing keyword and push scope checks. The push gates
# read rtk in front of git and nothing read env or sudo. Each gate's own suite holds it to these
# spellings; this one holds the reading and the scan.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SW="$DIR/lib/shell-words.py"
SCAN="$DIR/lib/word-position-scan.py"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $1"; }
check_eq(){ if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi; }

command -v python3 >/dev/null 2>&1 || { echo "test-gh-reader: python3 is not on PATH, so nothing was verified." >&2; exit 2; }

# The reading of one command, printable: tool|sub|act|word,word,...
reading(){ printf '%s' "$1" | python3 -B "$SW" tool | tr '\035\037' '|,'; }

# --- gh: the subcommand as gh finds it, past flags written in front -------------------------------
check_eq "gh pr create, plain" "gh|pr|create|--fill" "$(reading 'gh pr create --fill')"
check_eq "-R in front of the subcommand" "gh|pr|create|-R,o/x,--fill" "$(reading 'gh -R o/x pr create --fill')"
check_eq "-R between the subcommand and its action" "gh|pr|create|-R,o/x" "$(reading 'gh pr -R o/x create')"
check_eq "--repo=x in front" "gh|pr|edit|--repo=o/x,3" "$(reading 'gh --repo=o/x pr edit 3')"
check_eq "-Rx attached in front" "gh|issue|create|-Ro/x,-t,T" "$(reading 'gh -Ro/x issue create -t T')"
check_eq "a flag in front takes the next word, as gh does, so --fill took pr" "gh|create||--fill,pr" "$(reading 'gh --fill pr create')"
check_eq "--help takes nothing in front" "gh|pr|create|--help" "$(reading 'gh --help pr create')"
check_eq "gh api takes no action" "gh|api||-X,PUT,repos/o/r/pulls/1/merge" "$(reading 'gh -X PUT api repos/o/r/pulls/1/merge')"
check_eq "gh by its path" "gh|pr|merge|7" "$(reading '/opt/homebrew/bin/gh pr merge 7')"
check_eq "a body over several lines stays one word" "gh|pr|create|--body,a"$'\n'"b" "$(reading 'gh pr create --body "a
b"')"

# --- what stands in front of the program ----------------------------------------------------------
check_eq "rtk in front" "gh|pr|create|-R,o/x" "$(reading 'rtk gh -R o/x pr create')"
check_eq "env with a setting and an option in front" "gh|issue|create|" "$(reading 'env -u GH_HOST GH_TOKEN=x gh issue create')"
check_eq "sudo with an option in front" "gh|pr|edit|--repo,o/x,3" "$(reading 'sudo -u dan gh pr --repo o/x edit 3')"
check_eq "an assignment holding a substitution in front" "gh|pr|create|" "$(reading 'GH_TOKEN=$(gh auth token -u a) gh pr create')"
check_eq "a reserved word in front" "gh|pr|create|" "$(reading 'then gh pr create')"
check_eq "exec in front" "gh|issue|create|" "$(reading 'exec gh issue create')"

# --- git: the subcommand past the options git takes itself ----------------------------------------
G=git
check_eq "git push, plain" "$G|push||origin,main" "$(reading "$G push origin main")"
check_eq "git -C <dir> push" "$G|push||origin" "$(reading "$G -C /tmp/x push origin")"
check_eq "git -c k=v commit" "$G|commit||-m,x" "$(reading "$G -c user.name=a commit -m x")"
check_eq "env in front of git" "$G|commit||-m,x" "$(reading "env A=1 $G commit -m x")"
check_eq "sudo in front of git" "$G|push||" "$(reading "sudo $G push")"
check_eq "sudo env rtk in front of git" "$G|push||" "$(reading "sudo env A=1 rtk $G push")"
check_eq "an opener glued to git, as the crude cut leaves it" "$G|push||" "$(reading "($G push")"

# --- what is not a run of either -----------------------------------------------------------------
check_eq "a mention inside echo is no command of gh" "" "$(reading 'echo gh pr create')"
check_eq "command -v names gh without running a subcommand" "gh|||" "$(reading 'command -v gh')"
check_eq "another program" "" "$(reading 'ls -la')"
# --- rtk's own subcommand, where rtk runs no other program (claude-config#1468) -------------------
# rtk is read as a runner in front of gh and git (`rtk git push` is git push), so a command whose
# rtk runs a subcommand of its own, `rtk init`, used to read as a command named init. The reading
# says it is rtk's: tool rtk, its subcommand, then the words after it.
check_eq "#1468 rtk init, plain" "rtk|init||-g" "$(reading 'rtk init -g')"
check_eq "#1468 rtk's own option in front of its subcommand" "rtk|init||--show" "$(reading 'rtk -v init --show')"
check_eq "#1468 rtk by its path" "rtk|init||--global,--auto-patch" "$(reading '~/.local/bin/rtk init --global --auto-patch')"
check_eq "#1468 rtk by a path built from a variable, quoted" "rtk|init||" "$(reading '"$HOME/.local/bin/rtk" init')"
check_eq "#1468 command in front of rtk" "rtk|init||" "$(reading 'command rtk init')"
check_eq "#1468 env with a setting in front of rtk" "rtk|init||-g" "$(reading 'env A=1 rtk init -g')"
check_eq "#1468 a reserved word in front of rtk" "rtk|init||" "$(reading 'then rtk init')"
check_eq "#1468 rtk in front of git is still git's" "$G|push||" "$(reading "rtk $G push")"
check_eq "#1468 rtk in front of gh is still gh's" "gh|pr|view|3" "$(reading 'rtk gh pr view 3')"
check_eq "#1468 a mention of rtk init inside echo is no command of rtk" "" "$(reading 'echo "rtk init"')"
check_eq "#1468 nor inside grep's pattern" "" "$(reading 'grep "rtk init" notes.md')"
check_eq "#1468 a bare init is no rtk" "" "$(reading 'init -g')"

printf 'gh pr create' | python3 -B "$SW" tool >/dev/null; check_eq "the tool mode answers with exit 0" "0" "$?"
printf 'ls' | python3 -B "$SW" tool >/dev/null; check_eq "and exit 0 for a command that runs neither, so any other exit is a failed reader" "0" "$?"

# --- the git -C directory comes from the same reading --------------------------------------------
gitdir(){ printf '%s' "$1" | python3 -B "$SW" gitdir; }
check_eq "git -C names its directory" "/tmp/x" "$(gitdir "$G -C /tmp/x push")"
check_eq "and does behind env and sudo" "/tmp/x" "$(gitdir "env A=1 sudo $G -C /tmp/x push")"
check_eq "two -C compose as git composes them" "/tmp/x/y" "$(gitdir "$G -C /tmp/x -C y push")"
check_eq "a -c value is not a directory" "" "$(gitdir "$G -c core.x=y push")"

# --- ps_runs_gh and ps_runs_git, the bash entry -------------------------------------------------
asks(){ # asks <predicate words...> -- <command> : prints yes or no
  local cmd="${*: -1}"; local -a q=("${@:1:$#-2}")
  bash -c '. "$1/lib/push-scope.sh"; shift; c="$1"; shift; if "$@" "$c"; then echo yes; else echo no; fi' _ "$DIR" "$cmd" "${q[@]}"
}
runs(){ bash -c '. "$1/lib/push-scope.sh"; if ps_runs_gh "$2" "$3" "$4"; then printf "yes:%s" "${PS_RUN_ARGS[*]-}"; else echo no; fi' _ "$DIR" "$@"; }
check_eq "ps_runs_gh sees pr create behind -R in front" "yes:-R o/x --fill" "$(runs 'gh -R o/x pr create --fill' pr create)"
check_eq "ps_runs_gh sees pr edit behind env and a flag between" "yes:-R o/x 3" "$(runs 'env A=1 gh pr -R o/x edit 3' pr edit)"
check_eq "ps_runs_gh does not take pr view for pr create" "no" "$(runs 'gh -R o/x pr view 3' pr create)"
check_eq "ps_is_gh_pr_create sees a flag in front" "yes" "$(asks ps_is_gh_pr_create -- 'gh -R o/x pr create --fill')"
check_eq "ps_is_gh_pr_create sees one between pr and create" "yes" "$(asks ps_is_gh_pr_create -- 'gh pr --repo o/x create --fill')"
check_eq "ps_is_gh_pr_create sees one behind sudo" "yes" "$(asks ps_is_gh_pr_create -- 'sudo gh --repo=o/x pr create')"
check_eq "ps_is_gh_pr_create does not see one quoted in echo" "no" "$(asks ps_is_gh_pr_create -- 'echo "gh -R o/x pr create"')"
check_eq "ps_is_git_commit sees a commit behind env" "yes" "$(asks ps_is_git_commit -- "env A=1 $G commit -m x")"
check_eq "ps_is_git_commit sees a commit behind sudo" "yes" "$(asks ps_is_git_commit -- "sudo $G commit -m x")"
check_eq "ps_is_git_push sees a push behind env with an option" "yes" "$(asks ps_is_git_push -- "env -u X A=1 $G -C /tmp push")"
check_eq "ps_is_git_push sees a push behind sudo" "yes" "$(asks ps_is_git_push -- "sudo $G push origin main")"
check_eq "ps_is_git_push does not take a commit for a push" "no" "$(asks ps_is_git_push -- "env A=1 $G commit -m push")"

# A reader that crashes must not read as "runs no gh": the crude reading answers instead (L42).
BROKEN="$WORK/broken-sw.py"; printf 'import sys\nsys.exit(3)\n' > "$BROKEN"
crashed="$(bash -c '. "$1/lib/push-scope.sh"; PS_SHELL_WORDS="$2"; if ps_runs_gh "gh -R o/x pr create" pr create; then echo yes; else echo no; fi' _ "$DIR" "$BROKEN")"
check_eq "a crashed reader still lets a pr create be seen" "yes" "$crashed"
crashed="$(bash -c '. "$1/lib/push-scope.sh"; PS_SHELL_WORDS="$2"; if ps_runs_gh "gh pr view 3" pr create; then echo yes; else echo no; fi' _ "$DIR" "$BROKEN")"
check_eq "control: the crude reading does not take a pr view for a create" "no" "$crashed"
crashed="$(bash -c '. "$1/lib/push-scope.sh"; PS_SHELL_WORDS="$2"; if ps_runs_git "$3 push origin main" push; then echo "yes:${PS_RUN_ARGS[*]-}"; else echo no; fi' _ "$DIR" "$BROKEN" "$G")"
check_eq "and the crude reading keeps a push's own words, its remote and branch" "yes:origin main" "$crashed"
crashed="$(bash -c '. "$1/lib/push-scope.sh"; PS_SHELL_WORDS="$2"; if ps_runs_gh "gh pr -R o/x create --fill" pr create; then echo "yes:${PS_RUN_ARGS[*]-}"; else echo no; fi' _ "$DIR" "$BROKEN")"
check_eq "and a creation's words after its action" "yes:--fill" "$crashed"

# --- commands run by a wrapper (claude-config#1478) ---------------------------------------------
# Every gate read only commands in command position, so a command another program runs was invisible
# to all of them: `bash -c 'git push --force'`, `eval`, `xargs git push`, `nohup`, `rtk proxy`.
# A launcher that runs its own arguments is read through like env and sudo, by the tool reading.
check_eq "#1478 xargs runs its command" "$G|push||" "$(reading "xargs $G push")"
check_eq "#1478 xargs's own options and their values are passed over" "$G|add||{}" "$(reading "xargs -0 -n 1 -I {} -P 4 $G add {}")"
check_eq "#1478 xargs -I with its value attached" "$G|add||{}" "$(reading "xargs -I{} $G add {}")"
check_eq "#1478 nohup runs its command" "$G|push||origin" "$(reading "nohup $G push origin")"
check_eq "#1478 time with -p in front" "$G|push||" "$(reading "time -p $G push")"
check_eq "#1478 time by its path, with -o and its value" "$G|push||" "$(reading "/usr/bin/time -o out.txt $G push")"
check_eq "#1478 nice with -n and its value" "$G|push||" "$(reading "nice -n 5 $G push")"
check_eq "#1478 nice with an old style number" "$G|push||" "$(reading "nice -10 $G push")"
check_eq "#1478 timeout takes a duration before the command" "$G|push||--force" "$(reading "timeout 30 $G push --force")"
check_eq "#1478 timeout with -s and its value before the duration" "$G|push||" "$(reading "timeout -s KILL 30s $G push")"
check_eq "#1478 caffeinate runs its command" "$G|push||" "$(reading "caffeinate -i -t 600 $G push")"
check_eq "#1478 rtk proxy runs its command" "$G|push||--force" "$(reading "rtk proxy $G push --force")"
check_eq "#1478 rtk proxy with its own option" "gh|issue|create|" "$(reading 'rtk proxy -v gh issue create')"
check_eq "#1478 rtk proxy rtk init is rtk's init" "rtk|init||-g" "$(reading 'rtk proxy rtk init -g')"
check_eq "#1478 rtk proxy init runs a program named init, not rtk's" "" "$(reading 'rtk proxy init -g')"
# The mods' reader (mod-kit hooks/commands.ts, RUNNERS) reads stdbuf and doas too, so this one does.
check_eq "#1478 stdbuf with a value attached" "$G|push||" "$(reading "stdbuf -oL $G push")"
check_eq "#1478 doas with -u and its value" "$G|push||" "$(reading "doas -u root $G push")"
check_eq "#1478 launchers stack" "$G|push||" "$(reading "nohup nice -n 5 timeout 30 sudo env A=1 $G push")"

# A command given to a shell as a string, or to eval, is a command line of its own: read in the one
# reading as records after the wrapper's, recursively, in the directory the wrapper runs in. Each
# record printed as tool|sub|act ("-" for none), then !wrapper when it cannot be read, then @dir.
records(){ printf '%s' "$1" | python3 -B "$SW" read | python3 -c '
import sys
out = []
for rec in sys.stdin.read().split("\x1e"):
    if not rec:
        continue
    f = rec.split("\x1c")
    s = "|".join(f[7].split("\x1d")[:3]) if f[7] else "-"
    if len(f) > 8 and "\x1d" in f[8]:
        s += "!" + f[8].split("\x1d")[0]
    if f[0]:
        s += "@" + f[0]
    out.append(s)
print(" ; ".join(out))'; }
check_eq "#1478 bash -c" "- ; $G|push|" "$(records "bash -c '$G push --force'")"
check_eq "#1478 sh -c" "- ; $G|push|" "$(records "sh -c \"$G push\"")"
check_eq "#1478 zsh -c" "- ; $G|push|" "$(records "zsh -c '$G push'")"
check_eq "#1478 a flag joined to -c" "- ; $G|push|" "$(records "bash -lc '$G push'")"
check_eq "#1478 flags before -c, one taking a value" "- ; $G|push|" "$(records "bash -e -o pipefail -c '$G push'")"
check_eq "#1478 -- between -c and its string" "- ; $G|push|" "$(records "bash -c -- '$G push'")"
check_eq "#1478 a shell by its path" "- ; $G|push|" "$(records "/bin/bash -c '$G push'")"
check_eq "#1478 the shell's own arguments after its string are not commands" "- ; $G|push|" "$(records "sh -c '$G push \"\$1\"' sh origin")"
check_eq "#1478 several commands in the string" "- ; - ; $G|push|" "$(records "bash -c 'echo hi && $G push'")"
check_eq "#1478 a cd inside the string moves the commands after it" "- ; - ; $G|push|@/tmp/x" "$(records "bash -c 'cd /tmp/x && $G push'")"
check_eq "#1478 the string runs where the wrapper does" "- ; -@/tmp/a ; $G|push|@/tmp/a" "$(records "cd /tmp/a && bash -c '$G push'")"
check_eq "#1478 a cd in the string does not move what follows the wrapper" "- ; - ; $G|commit|" "$(records "bash -c 'cd /tmp/x' ; $G commit -m m")"
check_eq "#1478 a shell inside a shell" "- ; - ; $G|push|" "$(records "bash -c \"sh -c '$G push'\"")"
check_eq "#1478 behind a launcher" "- ; $G|push|" "$(records "nohup bash -c '$G push' &")"
check_eq "#1478 xargs running sh -c" "- ; $G|push|" "$(records "xargs -I{} sh -c '$G push {}'")"
check_eq "#1478 eval of plain words" "- ; $G|push|" "$(records "eval $G push --force")"
check_eq "#1478 eval of one quoted string holding two commands" "- ; $G|commit| ; $G|push|" "$(records "eval '$G commit -m x && $G push'")"
check_eq "#1478 env -S splits its string into the command" "- ; $G|push|" "$(records "env -S '$G push --force'")"
check_eq "#1478 a gh command in the string" "- ; gh|issue|create" "$(records "bash -c 'gh issue create --title T'")"
check_eq "#1478 rtk init in the string" "- ; rtk|init|" "$(records "sh -c 'rtk init -g'")"
check_eq "#1478 a variable among the string's arguments is read as it would be bare" "- ; $G|push|" "$(records "bash -c \"$G push origin \$BRANCH\"")"

# The programs that run a command line made of their own arguments: find's -exec and -ok, watch,
# script and GNU parallel, as the mods' reader reads find -exec (mod-kit hooks/commands.ts).
check_eq "#1478 find -exec ... ;" "- ; $G|add|" "$(records "find . -name '*.md' -exec $G add {} \\;")"
check_eq "#1478 find -exec ... + and a second -exec" "- ; $G|add| ; $G|commit|" "$(records "find . -exec $G add {} + -exec $G commit -m x \\;")"
check_eq "#1478 find -ok" "- ; $G|push|" "$(records "find . -maxdepth 0 -ok $G push \\;")"
check_eq "#1478 find -exec running sh -c" "- ; - ; $G|push|" "$(records "find . -maxdepth 0 -exec sh -c '$G push' \\;")"
check_eq "#1478 find -execdir runs in each file's own directory, which cannot be told" "-!find -execdir ; $G|push|" "$(records "find . -execdir $G push \\;")"
check_eq "#1478 find -exec that never ends" "-!find -exec" "$(records "find . -exec $G push")"
check_eq "#1478 watch, its words a command line" "- ; $G|status| ; $G|push|" "$(records "watch -n 5 '$G status && $G push'")"
check_eq "#1478 watch -x runs its words as they stand" "- ; $G|push|" "$(records "watch -x -n 5 $G push")"
check_eq "#1478 script -c, util-linux" "- ; $G|push|" "$(records "script -q -c '$G push' /dev/null")"
check_eq "#1478 script with a file then a command, macOS" "- ; $G|push|" "$(records "script -q /dev/null $G push --force")"
check_eq "#1478 parallel's command before :::" "- ; $G|push|" "$(records "parallel -j 2 $G push ::: origin upstream")"
check_eq "#1478 parallel with no command runs its arguments" "- ; $G|push| ; -" "$(records "parallel ::: '$G push' 'ls'")"
check_eq "#1478 parallel reading its commands from its input" "-!parallel" "$(records "parallel -j 4 < jobs.txt")"
check_eq "#1478 a shell running a script file cannot be read" "-!bash" "$(records 'bash ./deploy.sh --fast')"
check_eq "#1478 nor sh with an option and a script file" "-!sh" "$(records 'sh -e scripts/x.sh')"
check_eq "#1478 control: find with no -exec" "-" "$(records "find . -name '$G'")"
check_eq "#1478 control: watch mentioned by echo" "-" "$(records "echo watch $G push")"

# A wrapped string that cannot be read is said to be unreadable, naming the wrapper, so a gate can
# refuse rather than pass it.
check_eq "#1478 a variable holding the whole command" "-!bash -c ; -" "$(records 'bash -c "$CMD"')"
check_eq "#1478 a substitution holding the whole command" "- ; -!sh -c ; - ; -" "$(records 'sh -c "$(cat cmd.txt)"')"
check_eq "#1478 a variable holding a later command of the string" "-!bash -c ; - ; -" "$(records 'bash -c "set -e; $CMD"')"
check_eq "#1478 eval of a variable" "-!eval ; -" "$(records 'eval "$CMD"')"
check_eq "#1478 eval of a substitution" "- ; -!eval ; - ; -" "$(records 'eval "$(ssh-agent -s)"')"
check_eq "#1478 eval that changes directory for the commands after it" "-!eval ; - ; $G|push|" "$(records "eval 'cd /tmp' && $G push")"
check_eq "#1478 a string holding a quote that never closes" "-!bash -c ; $G|push|" "$(records "bash -c \"$G push 'x\"")"
check_eq "#1478 a shell fed a here string" "-!bash" "$(records "bash <<< '$G push'")"
check_eq "#1478 a shell fed by a pipe" "- ; -!sh" "$(records "echo '$G push' | sh")"
check_eq "#1478 a shell fed a heredoc" "-!bash" "$(records "$(printf 'bash <<EOF\n%s push\nEOF' "$G")")"
check_eq "#1478 wrapped more than five deep" "- ; - ; - ; - ; - ; -!eval" "$(records "eval eval eval eval eval eval $G push")"
check_eq "#1478 five deep is still read" "- ; - ; - ; - ; - ; $G|push|" "$(records "eval eval eval eval eval $G push")"

# What only mentions a wrapper stays text.
check_eq "#1478 control: a wrapper inside echo" "-" "$(records "echo \"bash -c '$G push'\"")"
check_eq "#1478 control: inside a grep pattern" "-" "$(records "grep \"bash -c '$G push'\" notes.md")"
check_eq "#1478 control: inside a commit message" "$G|commit|" "$(records "$G commit -m \"bash -c '$G push'\"")"
check_eq "#1478 control: inside a heredoc body" "-" "$(records "$(printf "cat <<'EOF'\nbash -c '%s push'\neval %s push\nEOF" "$G" "$G")")"
check_eq "#1478 control: eval mentioned by echo" "-" "$(records "echo eval $G push")"
check_eq "#1478 control: a shell asked its version" "-" "$(records 'bash --version')"
check_eq "#1478 control: python's -c is not a shell's" "-" "$(records "python3 -c 'import os; os.system(\"x\")'")"

check_eq "#1478 ps_is_git_push sees a push in bash -c" "yes" "$(asks ps_is_git_push -- "bash -c '$G push --force'")"
check_eq "#1478 and through xargs" "yes" "$(asks ps_is_git_push -- "printf 'a\n' | xargs $G push origin")"
check_eq "#1478 and through eval" "yes" "$(asks ps_is_git_push -- "eval '$G push'")"
check_eq "#1478 control: not one in echo" "no" "$(asks ps_is_git_push -- "echo \"bash -c '$G push'\"")"
check_eq "#1478 ps_is_gh_pr_create sees one in sh -c" "yes" "$(asks ps_is_gh_pr_create -- "sh -c 'gh pr create --fill'")"
check_eq "#1478 ps_is_git_commit sees one through rtk proxy" "yes" "$(asks ps_is_git_commit -- "rtk proxy $G commit -m x")"
unread(){ bash -c '. "$1/lib/push-scope.sh"; if ps_unreadable "$2"; then printf "%s|%s" "$PS_UNREAD_WRAPPER" "$PS_UNREAD_WHY"; else echo none; fi' _ "$DIR" "$1"; }
u="$(unread 'X=1; bash -c "$CMD"')"
check_eq "#1478 ps_unreadable names the wrapper" "bash -c" "${u%%|*}"
case "$u" in *"variable"*) ok ;; *) bad "#1478 and says why it cannot be read: $u" ;; esac
check_eq "#1478 ps_unreadable: nothing unreadable in a plain wrapper" "none" "$(unread "bash -c '$G push'")"

# --- the scan ----------------------------------------------------------------------------------
scan(){ out="$(python3 -B "$SCAN" "$1" 2>&1)"; rc=$?; }
scan "$DIR"
check_eq "no hook reads a gh or git subcommand by word position" "0" "$rc"
[ "$rc" -eq 0 ] || printf '%s\n' "$out"
case "$out" in *"findings=0"*) ok ;; *) bad "and the scan says how many hooks it read: $out" ;; esac

# Seen failing: each shape a hand written reading took before #1188, one fixture hook apiece.
F="$WORK/hooks"; mkdir -p "$F/lib"
cat > "$F/position.sh" <<'SH'
#!/usr/bin/env bash
# gh pr create in a comment is not a reading
[ "${w[0]##*/}" = "gh" ] || return 1
grep -Eq '(^|/)gh[[:space:]]+pr[[:space:]]+(create|edit)' <<< "$heads"
SH
cat > "$F/lib/position.py" <<'PY'
if at_head and tokens[i + 1 : i + 3] == ["issue", "create"]:
    pass
if toks[i + 1] in ("pr", "api"):
    pass
elif head == "git":
    pass
PY
cat > "$F/marked.sh" <<'SH'
[ "$t" = "git" ] || return 1   # gh-reader: smuggled past the scan
SH
scan "$F"
check_eq "a hook reading by word position fails the scan" "1" "$rc"
for want in "position.sh:3:" "position.sh:4:" "lib/position.py:1:" "lib/position.py:3:" "lib/position.py:5:" "marked.sh:1: carries gh-reader: outside"; do
  case "$out" in *"$want"*) ok ;; *) bad "the scan names $want: $out" ;; esac
done
case "$out" in *"position.sh:2:"*) bad "a comment naming the command is not a reading: $out" ;; *) ok ;; esac
case "$out" in *"findings=6"*) ok ;; *) bad "exactly the six readings are flagged: $out" ;; esac

mkdir -p "$WORK/empty"
scan "$WORK/empty"
check_eq "a folder with no hook is refused, not passed" "2" "$rc"

echo
echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
