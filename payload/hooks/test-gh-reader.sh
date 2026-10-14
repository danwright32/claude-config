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
