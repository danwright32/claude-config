#!/usr/bin/env bash
# Tests for scan.sh, the read only git repo discovery helper behind /tracker --scan
# (claude-config#1030, milestone "Tracker scan for git work").
#
# Every repository here is built in a throwaway directory with pinned author and committer dates,
# and every scan is given its reference "now" with --now, so both ends of the window are fixed and
# no assertion depends on the day the suite runs (L130). HOME is pointed at a throwaway directory
# too, so not even the default root can reach the real home directory (L2).
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../../hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCAN="$DIR/scan.sh"
TMP="$(mktemp -d)"
case "${TMP%/}" in
  ''|/|"${HOME%/}") echo "refusing to run: throwaway directory came back as '$TMP'." >&2; exit 2 ;;
esac
# The deadline helper stops children through its own watchdog and a USR1 handler, never an EXIT
# trap, and says the suite's EXIT trap is where scratch goes. Recorded here and asserted below, so
# the day the helper does take EXIT, this line stops silently replacing it.
EXIT_TRAP_BEFORE_OURS="$(trap -p EXIT)"
# The control (L1): the same capture sees the USR1 trap the helper DOES set, so an empty EXIT
# answer above means there was none, not that a command substitution cannot see traps.
USR1_TRAP_SEEN="$(trap -p USR1)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok()  { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL: $1"; }
check() { # check <description> <expected-substring> <actual>
  if [[ "$3" == *"$2"* ]]; then ok; else
    bad "$1"; echo "  expected to contain: $2"; echo "  actual: $3"
  fi
}
check_not() { # check_not <description> <forbidden-substring> <actual>
  if [[ "$3" != *"$2"* ]]; then ok; else bad "$1 (output should not contain '$2')"; fi
}
check_eq() { # check_eq <description> <expected> <actual>
  if [[ "$3" == "$2" ]]; then ok; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- a world with no access to the real one -----------------------------------
export HOME="$TMP/home"
mkdir -p "$HOME"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$TMP/gitconfig"
printf '[init]\n\tdefaultBranch = main\n[protocol "file"]\n\tallow = always\n' > "$GIT_CONFIG_GLOBAL"
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR

# The reference now every scan is given: 2026-06-15 12:00 UTC, a fixed instant.
NOW="$(python3 -c 'import calendar; print(calendar.timegm((2026, 6, 15, 12, 0, 0)))')"
DAY=86400
at(){ echo $((NOW + $1 * DAY)); }                # at <days from NOW> -> epoch seconds
iso_day(){ python3 -c 'import sys,datetime; print(datetime.datetime.fromtimestamp(int(sys.argv[1]), datetime.timezone.utc).strftime("%Y-%m-%d"))' "$1"; }

ROOT="$TMP/root"
mkdir -p "$ROOT"
REAL_ROOT="$(cd "$ROOT" && pwd -P)"   # mktemp hands back /var/..., which resolves to /private/var/...

commit(){ # commit <repo dir> <days from NOW> <author name> <author email> <subject>
  local when; when="$(at "$2")"
  GIT_AUTHOR_NAME="$3" GIT_AUTHOR_EMAIL="$4" GIT_COMMITTER_NAME="$3" GIT_COMMITTER_EMAIL="$4" \
    GIT_AUTHOR_DATE="$when +0000" GIT_COMMITTER_DATE="$when +0000" \
    git -C "$1" commit -q --allow-empty -m "$5"
}
newrepo(){ # newrepo <dir> [remote url]
  mkdir -p "$1" && git -C "$1" init -q
  if [ -n "${2:-}" ]; then git -C "$1" remote add origin "$2"; fi
}

ME_NAME="Dan Wright"
ME_EMAIL="dan@example.com"

# mine: every way a commit can or cannot be the user's.
newrepo "$ROOT/mine" "git@github.com:DanWright32/Mine-Repo.git"
commit "$ROOT/mine" -40 "$ME_NAME" "$ME_EMAIL" "before the window"
commit "$ROOT/mine" -20 "$ME_NAME" "$ME_EMAIL" "matched by name and email"
commit "$ROOT/mine" -10 "Daniel Someone Else" "$ME_EMAIL" "matched by email alone"
commit "$ROOT/mine" -5 "  dan   WRIGHT " "dan@laptop.local" "matched by name alone"
commit "$ROOT/mine" -3 "Stranger Person" "stranger@example.org" "a stranger's work"
commit "$ROOT/mine" -2 "dependabot[bot]" "49699333+dependabot[bot]@users.noreply.github.com" "bump a dependency"
commit "$ROOT/mine" -1 "$ME_NAME" "dan-wright[bot]@users.noreply.github.com" "a bot wearing the user's name"
commit "$ROOT/mine" 2 "$ME_NAME" "$ME_EMAIL" "after the reference now"

# strangers: commits in the window, none of them the user's.
newrepo "$ROOT/strangers" "https://github.com/someone/their-repo.git"
commit "$ROOT/strangers" -4 "Stranger Person" "stranger@example.org" "only strangers here"

# empty: a repository with no commits at all.
newrepo "$ROOT/empty"

# a worktree, whose .git is a FILE pointing back at mine.
git -C "$ROOT/mine" worktree add -q "$ROOT/wt/mine-feature" -b feature 2>/dev/null
commit "$ROOT/wt/mine-feature" -6 "$ME_NAME" "$ME_EMAIL" "work on the feature branch"
# and one whose path sorts BEFORE mine, so the main checkout is chosen as the entry by rule, not
# by happening to sort first.
git -C "$ROOT/mine" worktree add -q "$ROOT/a-early-wt" -b early 2>/dev/null

# a .git file pointing at nothing.
mkdir -p "$ROOT/broken"
printf 'gitdir: %s/nowhere/.git\n' "$TMP" > "$ROOT/broken/.git"

# a shallow clone.
git clone -q --depth 1 "file://$REAL_ROOT/strangers" "$ROOT/shallow" 2>/dev/null

# a remote carrying credentials in its address.
newrepo "$ROOT/secret" "https://dan:hunter2tokenvalue@github.com/o/secret-repo.git"
# rebased: the commit made last (newest committer date) was AUTHORED earlier than the one before it,
# so the newest author date is not the first commit in git's walk order.
newrepo "$ROOT/rebased" "https://github.com/o/rebased"
commit "$ROOT/rebased" -3 "$ME_NAME" "$ME_EMAIL" "authored three days ago"
GIT_AUTHOR_NAME="$ME_NAME" GIT_AUTHOR_EMAIL="$ME_EMAIL" GIT_COMMITTER_NAME="$ME_NAME" GIT_COMMITTER_EMAIL="$ME_EMAIL" \
  GIT_AUTHOR_DATE="$(at -10) +0000" GIT_COMMITTER_DATE="$(at -1) +0000" \
  git -C "$ROOT/rebased" commit -q --allow-empty -m "authored ten days ago, rebased yesterday"
# a password that itself holds an @, which a match stopping at the first @ would only half remove.
newrepo "$ROOT/atpass" "https://dan:pass@word99@github.com/o/atpass-repo.git"
commit "$ROOT/atpass" -1 "$ME_NAME" "$ME_EMAIL" "at in the password"
# and one holding a # and a ?, which a query or fragment cut made BEFORE the credentials are
# removed would truncate at, leaving the first half of the password in what is printed.
newrepo "$ROOT/hashpass" "https://dan:frag#qu?ery55@github.com/o/hashpass-repo.git"
commit "$ROOT/hashpass" -1 "$ME_NAME" "$ME_EMAIL" "hash and question mark in the password"
commit "$ROOT/secret" -1 "$ME_NAME" "$ME_EMAIL" "secret work"

# noise directories, whose repositories are never wanted, and one ignored on purpose.
for noise in node_modules/pkg mine-app/node_modules/dep Library/Thing .Trash/old .claude/worktrees/agent-x claude-backup-20261001/copy; do
  newrepo "$ROOT/$noise"
  commit "$ROOT/$noise" -1 "$ME_NAME" "$ME_EMAIL" "noise"
done
newrepo "$ROOT/ignored-repo" "https://github.com/o/ignored-repo"
commit "$ROOT/ignored-repo" -1 "$ME_NAME" "$ME_EMAIL" "ignored on purpose"

# heads: worktrees holding commits that no branch, remote branch or tag reaches.
newrepo "$ROOT/heads" "https://github.com/o/heads"
commit "$ROOT/heads" -12 "$ME_NAME" "$ME_EMAIL" "base on main"
git -C "$ROOT/heads" worktree add -q --detach "$ROOT/heads-wt/detached" 2>/dev/null
commit "$ROOT/heads-wt/detached" -1 "$ME_NAME" "$ME_EMAIL" "on a detached head"
git -C "$ROOT/heads" worktree add -q "$ROOT/heads-wt/left" -b left 2>/dev/null
commit "$ROOT/heads-wt/left" -9 "$ME_NAME" "$ME_EMAIL" "on a branch deleted after the worktree detached"
git -C "$ROOT/heads-wt/left" checkout -q --detach
git -C "$ROOT/heads" branch -q -D left
git -C "$ROOT/heads" worktree add -q "$ROOT/heads-wt/gone" -b gone 2>/dev/null
commit "$ROOT/heads-wt/gone" -8 "$ME_NAME" "$ME_EMAIL" "on a branch deleted under the worktree"
# git refuses to delete a branch a worktree has checked out, so the ref is removed directly: HEAD
# is then left naming a branch that does not exist, and only its reflog holds the last commit.
git -C "$ROOT/heads-wt/gone" update-ref -d refs/heads/gone

# a repository with a submodule, which has a git dir of its own and so is a repository of its own.
newrepo "$ROOT/withsub" "https://github.com/o/withsub"
commit "$ROOT/withsub" -1 "$ME_NAME" "$ME_EMAIL" "the superproject"
git -C "$ROOT/withsub" submodule add -q "file://$REAL_ROOT/strangers" sub 2>/dev/null

check_eq "the deadline helper had set no EXIT trap for this suite's own to replace" "" "$EXIT_TRAP_BEFORE_OURS"
check "and the same capture does see the helper's USR1 trap, so that empty answer is a reading" "_suite_deadline_expired" "$USR1_TRAP_SEEN"
# The fixture's own premises, checked before anything is concluded from them (L475).
[ -f "$ROOT/wt/mine-feature/.git" ] && ok || bad "premise: the worktree's .git is a file"
[ -f "$ROOT/withsub/sub/.git" ] && ok || bad "premise: the submodule's .git is a file"
# Premise: no ref reaches the three worktree commits, which is the case under test.
check_eq "premise: no branch, remote branch or tag reaches the worktrees' commits" "base on main" \
  "$(git -C "$ROOT/heads" log --branches --remotes --tags --format=%s)"
check_eq "premise: the deleted-under worktree's HEAD resolves to nothing" "" \
  "$(git -C "$ROOT/heads-wt/gone" rev-parse -q --verify 'HEAD^{commit}' 2>/dev/null)"
[ "$(git -C "$ROOT/shallow" rev-parse --is-shallow-repository)" = "true" ] && ok || bad "premise: the clone is shallow"

OUT="$TMP/out.json"
ERR="$TMP/err.txt"
scan(){ # scan <args...>; writes stdout to $OUT, stderr to $ERR, sets RC
  RC=0
  bash "$SCAN" "$@" > "$OUT" 2> "$ERR" || RC=$?
}
# q <python expression>: evaluated against the last scan's JSON as d, with R(name) the repo whose
# path is <scanned root>/<name>. Prints PARSE-ERROR when the output is not JSON at all.
q(){
  python3 - "$OUT" "$REAL_ROOT" "$1" <<'PY'
import json, sys
path, root, expr = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    d = json.load(open(path))
except Exception as e:
    print("PARSE-ERROR %s" % type(e).__name__); sys.exit(0)
def R(name):
    hits = [r for r in d.get("repos", []) if r.get("path") == root + "/" + name]
    return hits[0] if len(hits) == 1 else {"__found__": len(hits)}
try:
    v = eval(expr)
except Exception as e:
    print("EVAL-ERROR %s: %s" % (type(e).__name__, e)); sys.exit(0)
print(json.dumps(v) if not isinstance(v, str) else v)
PY
}

# --- the main scan --------------------------------------------------------------
scan --root "$ROOT" --now "$NOW" --days 30 --author "$ME_EMAIL" --author "dan wright" --ignore "$ROOT/ignored-repo"
check_eq "a scan over the fixture succeeds" 0 "$RC"
check_not "and its output is JSON" "PARSE-ERROR" "$(q 'd["repo_count"]')"

repos="$(q 'sorted(r["path"][len(sys.argv[2])+1:] for r in d["repos"])')"
check_eq "it finds exactly the wanted repositories, each once" \
  '["atpass", "empty", "hashpass", "heads", "mine", "rebased", "secret", "shallow", "strangers", "withsub", "withsub/sub"]' "$repos"
check_eq "and counts them" 11 "$(q 'd["repo_count"]')"
check_eq "and says it found some" "repos_found" "$(q 'd["outcome"]')"
check_eq "and names the root it searched, resolved" "[\"$REAL_ROOT\"]" "$(q 'd["roots_searched"]')"

# authors: matched by email, by name (case and spacing folded), never a stranger or a bot. The
# worktree's feature branch belongs to mine too (one repository, every branch), so its commit counts.
check_eq "mine: four window commits are the user's (email and name, email alone, name alone, the feature branch)" 4 "$(q 'R("mine")["window_commit_count"]')"
check_eq "and their subjects, newest first" \
  '["matched by name alone", "work on the feature branch", "matched by email alone", "matched by name and email"]' "$(q 'R("mine")["window_subjects"]')"
check_eq "every commit in the window is counted apart from whose it is" 7 "$(q 'R("mine")["window_commit_count_all"]')"
check_not "a stranger's commit is never the user's" "a stranger's work" "$(q 'R("mine")["window_subjects"]')"
check_not "a bot's commit is never the user's, even under the user's name" "bot wearing" "$(q 'R("mine")["window_subjects"]')"
check_eq "the bots' window commits are counted on their own" 2 "$(q 'R("mine")["bot_commits_in_window"]')"
authors="$(q 'sorted("%s <%s> %d" % (a["name"], a["email"], a["commits"]) for a in R("mine")["authors_in_window"])')"
check "authors_in_window lists the user under each identity" "Dan Wright <dan@example.com> 2" "$authors"
check "and the stranger" "Stranger Person <stranger@example.org> 1" "$authors"
check_not "and never a bot" "[bot]" "$authors"
check_eq "and says which of them matched the given authors" 3 "$(q 'sum(1 for a in R("mine")["authors_in_window"] if a["matched"])')"

# the window: both ends pinned by the injected now.
check_not "a commit before the window is outside it" "before the window" "$(q 'R("mine")["window_subjects"]')"
check_not "a commit after the reference now is outside it" "after the reference now" "$(q 'R("mine")["window_subjects"]')"
check_eq "the window is reported as ending at the reference now" "2026-06-15T12:00:00Z" "$(q 'd["until"]')"
check_eq "and starting the given days before it" "2026-05-16T12:00:00Z" "$(q 'd["since"]')"
check_eq "first_commit_date is the oldest commit's" "$(iso_day "$(at -40)")" "$(q 'R("mine")["first_commit_date"][:10]')"
check_eq "last_commit_date is the newest AUTHOR date, even when a rebased commit was committed after it" "$(iso_day "$(at -3)")" "$(q 'R("rebased")["last_commit_date"][:10]')"
check_eq "last_commit_date is the newest commit's" "$(iso_day "$(at 2)")" "$(q 'R("mine")["last_commit_date"][:10]')"

# zero matches is still a repository, and zero is not the same as unmeasured.
check_eq "a repository with no commits by the user is still emitted, with zero" 0 "$(q 'R("strangers")["window_commit_count"]')"
check_eq "and its commits in the window still counted" 1 "$(q 'R("strangers")["window_commit_count_all"]')"

# remotes.
check_eq "mine: the remote is normalized to host/owner/repo" "github.com/danwright32/mine-repo" "$(q 'R("mine")["normalized_url"]')"
check_eq "and repo_name comes from the remote, as written there" "Mine-Repo" "$(q 'R("mine")["repo_name"]')"
check_eq "and the raw remote is kept" "git@github.com:DanWright32/Mine-Repo.git" "$(q 'R("mine")["remote_url"]')"
check_eq "a repository with no remote has no normalized url" "null" "$(q 'R("empty")["normalized_url"]')"
check_eq "and no repo_name invented from its folder" "null" "$(q 'R("empty")["repo_name"]')"
check_eq "secret: credentials in a remote address are normalized away" "github.com/o/secret-repo" "$(q 'R("secret")["normalized_url"]')"
check_not "and never printed anywhere in the output" "hunter2tokenvalue" "$(cat "$OUT")"
check_eq "a password holding an @ is removed whole from the remote shown" "https://github.com/o/atpass-repo.git" "$(q 'R("atpass")["remote_url"]')"
check_eq "and from the normalized url" "github.com/o/atpass-repo" "$(q 'R("atpass")["normalized_url"]')"
check_not "and no piece of it is printed anywhere" "word99" "$(cat "$OUT")"
check_eq "a password holding a # and a ? is removed whole from the remote shown" "https://github.com/o/hashpass-repo.git" "$(q 'R("hashpass")["remote_url"]')"
check_eq "and from the normalized url" "github.com/o/hashpass-repo" "$(q 'R("hashpass")["normalized_url"]')"
check_not "and its first half is never printed" "frag" "$(cat "$OUT")"
check_not "nor its second" "ery55" "$(cat "$OUT")"

# .git as a file, worktrees and broken pointers.
# One entry per repository: a linked worktree shares mine's commits, so it is listed on mine's
# entry, never as an entry of its own that would count the same work twice.
check_eq "the worktree, whose .git is a file, is not an entry of its own" '{"__found__": 0}' "$(q 'R("wt/mine-feature")')"
check_eq "it is listed on its repository's entry, resolved, beside the other worktree" "[\"$REAL_ROOT/a-early-wt\", \"$REAL_ROOT/wt/mine-feature\"]" "$(q 'R("mine")["worktrees"]')"
check_eq "and the entry is the main checkout, though another worktree's path sorts first" '{"__found__": 0}' "$(q 'R("a-early-wt")')"
check_eq "which names the git dir they share" "$REAL_ROOT/mine/.git" "$(q 'R("mine")["git_common_dir"]')"
check_eq "and the feature branch's commit is counted once in the whole output" 1 \
  "$(q 'sum(1 for r in d["repos"] for s in (r["window_subjects"] or []) if s == "work on the feature branch")')"
# Every grouped worktree's HEAD is read, so work no ref reaches is still the repository's.
check_eq "heads: commits reached only by a worktree's HEAD are counted" 4 "$(q 'R("heads")["commit_count"]')"
check_eq "and are the user's window commits, newest first" \
  '["on a detached head", "on a branch deleted under the worktree", "on a branch deleted after the worktree detached", "base on main"]' \
  "$(q 'R("heads")["window_subjects"]')"
check_eq "and set last_commit_date" "$(iso_day "$(at -1)")" "$(q 'R("heads")["last_commit_date"][:10]')"
check "the branch deleted under a worktree is reported, since its work was read from the reflog" "heads-wt/gone" "$(q 'd["warnings"]')"
check_eq "a repository with no worktrees lists none" "[]" "$(q 'R("strangers")["worktrees"]')"
check_eq "a submodule, whose .git is also a file, is a repository of its own" 1 "$(q 'len([r for r in d["repos"] if r["path"] == sys.argv[2] + "/withsub/sub"])')"
check "with its own git dir" "/withsub/.git/modules/sub" "$(q 'R("withsub/sub")["git_common_dir"]')"
check_eq "and is not counted as a worktree of its superproject" "[]" "$(q 'R("withsub")["worktrees"]')"
check "a .git file pointing at nothing is reported as unresolved" "broken" "$(q 'd["unresolved"]')"
check_eq "and is not emitted as a repository" '{"__found__": 0}' "$(q 'R("broken")')"

# shallow and empty.
check_eq "the shallow clone is flagged" "true" "$(q 'R("shallow")["is_shallow"]')"
check_eq "a full clone is not" "false" "$(q 'R("mine")["is_shallow"]')"
check_eq "a file:// remote is not a hosted one, so it has no normalized url" "null" "$(q 'R("shallow")["normalized_url"]')"
check_eq "the empty repository is emitted and flagged empty" "true" "$(q 'R("empty")["is_empty"]')"
check_eq "with no dates" "[null, null]" "$(q '[R("empty")["first_commit_date"], R("empty")["last_commit_date"]]')"
check_eq "and zero commits, not null, since authors were given" 0 "$(q 'R("empty")["window_commit_count"]')"

# noise and the ignore list.
check_eq "no repository under a noise directory is emitted" "[]" \
  "$(q '[r["path"] for r in d["repos"] if any(n in r["path"] for n in ("node_modules", "/Library/", "/.Trash/", "/.claude/", "claude-backup-"))]')"
check_eq "the ignored repository is not emitted" '{"__found__": 0}' "$(q 'R("ignored-repo")')"
check_eq "and is listed as ignored, matched although the ignore path was given unresolved" "[\"$REAL_ROOT/ignored-repo\"]" "$(q 'd["ignored"]')"

# read only: nothing under the scanned root was written by the scan.
touch "$TMP/marker"
scan --root "$ROOT" --now "$NOW" --days 30 --author "$ME_EMAIL"
check_eq "a second scan succeeds" 0 "$RC"
check_eq "and writes nothing under the root it scans" "" "$(find "$ROOT" -newer "$TMP/marker" 2>&1)"

# --- the injected now moves the window, in both directions (L497) --------------
scan --root "$ROOT/mine" --now "$(at 30)" --days 30 --author "$ME_EMAIL"
check_eq "a later now takes in the commit after the first reference now, and only it" \
  '["after the reference now"]' "$(q 'R("mine")["window_subjects"]')"
scan --root "$ROOT/mine" --now "$(at -15)" --days 30 --author "$ME_EMAIL"
check_eq "an earlier now takes in the commit before the first window" \
  '["matched by name and email", "before the window"]' "$(q 'R("mine")["window_subjects"]')"

# --- no authors given: matching is unmeasured, never zero ------------------------
scan --root "$ROOT/mine" --now "$NOW" --days 30
check_eq "with no authors the user's count is null, not zero" "null" "$(q 'R("mine")["window_commit_count"]')"
check_eq "and so are the subjects" "null" "$(q 'R("mine")["window_subjects"]')"
check "while authors_in_window still lists who committed, for the first run's picker" "Stranger Person" "$(q 'R("mine")["authors_in_window"]')"
check_not "without the bots" "[bot]" "$(q 'R("mine")["authors_in_window"]')"

# --- a window read that FAILS is unmeasured, never a measured zero ---------------
# A git placed first on PATH fails only the windowed log or shortlog it is told to, and hands
# every other call to the real git, so only the step under test fails.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP/failgit"
cat > "$TMP/failgit/git" <<STUB
#!/usr/bin/env bash
sub=""; since=""
for a in "\$@"; do
  case "\$a" in
    log|shortlog) [ -n "\$sub" ] || sub="\$a" ;;
    --since=*) since=1 ;;
  esac
done
if [ -n "\$since" ] && [ "\$sub" = "\${FAIL_GIT_WINDOW:-}" ]; then echo "fatal: simulated \$sub failure" >&2; exit 128; fi
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP/failgit/git"
failscan(){ # failscan <log|shortlog> <args...>
  local which="$1"; shift
  RC=0
  FAIL_GIT_WINDOW="$which" PATH="$TMP/failgit:$PATH" bash "$SCAN" "$@" > "$OUT" 2> "$ERR" || RC=$?
}
failscan log --root "$ROOT/mine" --now "$NOW" --days 30 --author "$ME_EMAIL"
check_eq "a scan whose window log fails still finishes" 0 "$RC"
check_eq "and the window counts are null, not zero" "[null, null, null]" \
  "$(q '[R("mine")["window_commit_count"], R("mine")["window_commit_count_all"], R("mine")["window_subjects"]]')"
check "and the failure is named on the repository" "simulated log failure" "$(q 'R("mine")["errors"]')"
check "while the authors, read separately, are still there" "Stranger Person" "$(q 'R("mine")["authors_in_window"]')"
failscan shortlog --root "$ROOT/mine" --now "$NOW" --days 30 --author "$ME_EMAIL"
check_eq "a scan whose shortlog fails has null authors and bot count, not empty" "[null, null]" \
  "$(q '[R("mine")["authors_in_window"], R("mine")["bot_commits_in_window"]]')"
check "and the failure is named on the repository" "simulated shortlog failure" "$(q 'R("mine")["errors"]')"
check_eq "while the window counts, read separately, are still measured" 3 "$(q 'R("mine")["window_commit_count"]')"

# --- overlapping roots find a repository once -------------------------------------
scan --root "$ROOT/mine" --root "$ROOT" --now "$NOW" --days 30 --author "$ME_EMAIL"
check_eq "a repository under two roots is emitted once" 1 "$(q 'len([r for r in d["repos"] if r["path"] == sys.argv[2] + "/mine"])')"

# --- a worktree whose main checkout the scan did not reach ------------------------
scan --root "$ROOT/wt" --now "$NOW" --days 30 --author "$ME_EMAIL"
check_eq "a worktree found without its main checkout is the repository's one entry" '["wt/mine-feature"]' \
  "$(q 'sorted(r["path"][len(sys.argv[2])+1:] for r in d["repos"])')"
check_eq "naming the git dir it shares with the main checkout" "$REAL_ROOT/mine/.git" "$(q 'R("wt/mine-feature")["git_common_dir"]')"
check_eq "and reading the whole repository's work" 3 "$(q 'R("wt/mine-feature")["window_commit_count"]')"
scan --root "$ROOT" --now "$NOW" --days 30 --author "$ME_EMAIL" --ignore "$ROOT/wt/mine-feature"
check_eq "an ignored worktree is left off its repository's entry" "[\"$REAL_ROOT/a-early-wt\"]" "$(q 'R("mine")["worktrees"]')"
check "and listed as ignored" "wt/mine-feature" "$(q 'd["ignored"]')"
# Ignoring a repository's main checkout ignores the repository: a worktree of it found elsewhere
# must not come back as its one entry.
scan --root "$ROOT" --now "$NOW" --days 30 --author "$ME_EMAIL" --ignore "$ROOT/mine"
check_eq "an ignored repository's worktrees are not emitted in its place" "[]" \
  "$(q '[r["path"] for r in d["repos"] if r["git_common_dir"] == sys.argv[2] + "/mine/.git"]')"
check_eq "and are listed as ignored with it" \
  "[\"$REAL_ROOT/a-early-wt\", \"$REAL_ROOT/mine\", \"$REAL_ROOT/wt/mine-feature\"]" "$(q 'sorted(d["ignored"])')"
scan --root "$ROOT/wt" --now "$NOW" --days 30 --author "$ME_EMAIL" --ignore "$ROOT/mine"
check_eq "even when the scan never reached the main checkout" "[]" "$(q 'd["repos"]')"

# --- an inherited GIT_DIR cannot make every repository the same one ---------------
RC=0; GIT_DIR="$ROOT/strangers/.git" bash "$SCAN" --root "$ROOT/mine" --now "$NOW" --days 30 --author "$ME_EMAIL" > "$OUT" 2> "$ERR" || RC=$?
check_eq "with GIT_DIR set by a caller, mine is still read as itself (email given, so three)" 3 "$(q 'R("mine")["window_commit_count"]')"

# --- a root with no repositories is its own outcome -------------------------------
mkdir -p "$TMP/emptyroot/just-files"
echo hello > "$TMP/emptyroot/just-files/readme.txt"
scan --root "$TMP/emptyroot" --now "$NOW"
check_eq "a root with no repositories succeeds" 0 "$RC"
check_eq "and reports zero repositories" 0 "$(q 'd["repo_count"]')"
check_eq "as an outcome of its own" "no_repos" "$(q 'd["outcome"]')"
check "and names the root it searched" "emptyroot" "$(q 'd["roots_searched"]')"
check_eq "with an empty list, not a missing one" "[]" "$(q 'd["repos"]')"

# --- the default root is HOME, applied in the shell -------------------------------
newrepo "$HOME/proj" "https://github.com/o/home-proj"
commit "$HOME/proj" -1 "$ME_NAME" "$ME_EMAIL" "home work"
scan --now "$NOW" --author "$ME_EMAIL"
check_eq "with no --root the scan searches HOME" "[\"$(cd "$HOME" && pwd -P)\"]" "$(q 'd["roots_searched"]')"
check_eq "and finds the repository there" '["github.com/o/home-proj"]' "$(q '[r["normalized_url"] for r in d["repos"]]')"
check_eq "and defaults the window to 30 days" 30 "$(q 'd["window_days"]')"
check_eq "ending at the given now and starting 30 days before it" "2026-05-16T12:00:00Z 2026-06-15T12:00:00Z" "$(q 'd["since"] + " " + d["until"]')"

# --- refusals ---------------------------------------------------------------------
scan --root "$TMP/does-not-exist" --now "$NOW"
if [ "$RC" -ne 0 ]; then ok; else bad "a root that does not exist is refused (got $RC)"; fi
check "and named" "does-not-exist" "$(cat "$ERR")"
check_eq "and nothing is printed as a result" "" "$(cat "$OUT")"
scan --root "$ROOT/mine" --root "$TMP/does-not-exist" --now "$NOW"
if [ "$RC" -ne 0 ]; then ok; else bad "a missing root beside a good one is refused, not skipped (got $RC)"; fi
check_eq "and the good root's results are not printed as if the scan were whole" "" "$(cat "$OUT")"
# A leading zero is still decimal: 08 is eight days, never an octal error (or 0123 read as 83).
scan --root "$ROOT/mine" --days 08 --now "0$NOW" --author "$ME_EMAIL"
check_eq "a window given with a leading zero succeeds" 0 "$RC"
check_eq "and is read as decimal days" 8 "$(q 'd["window_days"]')"
check_eq "and the now beside it as decimal seconds" "2026-06-15T12:00:00Z" "$(q 'd["until"]')"
scan --root "$ROOT" --days 00
if [ "$RC" -ne 0 ]; then ok; else bad "a window of zero days written as 00 is refused"; fi
# An empty --root (an unset variable in the caller) must not widen the scan to all of HOME (L320).
scan --root "" --now "$NOW"
if [ "$RC" -ne 0 ]; then ok; else bad "an empty --root is refused, never searched as HOME (got $RC)"; fi
check "and says why" "--root" "$(cat "$ERR")"
check_eq "and nothing is printed as a result" "" "$(cat "$OUT")"
scan --root "$ROOT/mine" --ignore "" --now "$NOW"
if [ "$RC" -ne 0 ]; then ok; else bad "an empty --ignore is refused (got $RC)"; fi
scan --root "$ROOT/mine" --author "" --now "$NOW"
if [ "$RC" -ne 0 ]; then ok; else bad "an empty --author is refused (got $RC)"; fi
scan --root "$ROOT" --days thirty
if [ "$RC" -ne 0 ]; then ok; else bad "a window that is not a number of days is refused"; fi
check "and says why" "days" "$(cat "$ERR")"
scan --root "$ROOT" --now yesterday
if [ "$RC" -ne 0 ]; then ok; else bad "a now that is not epoch seconds is refused"; fi
check "and says why" "now" "$(cat "$ERR")"
scan --frobnicate
if [ "$RC" -ne 0 ]; then ok; else bad "an unknown argument is refused"; fi

# --help prints the whole leading comment, contract included, and nothing of the code after it.
scan --help
check_eq "--help succeeds" 0 "$RC"
check "and reaches the one entry per repository contract" "ONE ENTRY PER REPOSITORY" "$(cat "$OUT")"
check "and the paragraph after it" "macOS bash 3.2" "$(cat "$OUT")"
check_not "and stops at the end of the comment" "set -euo pipefail" "$(cat "$OUT")"

# --- url normalization, every form, through the one shared function ---------------
norm(){ bash "$SCAN" --normalize-url "$1" 2>/dev/null; }
while IFS='|' read -r input want; do
  [ -n "$input" ] || continue
  check_eq "normalize $input" "$want" "$(norm "$input")"
done <<'TABLE'
git@github.com:Owner/Repo.git|github.com/owner/repo
git@github.com:owner/repo|github.com/owner/repo
ssh://git@github.com/owner/repo.git|github.com/owner/repo
ssh://git@github.com:22/owner/repo.git|github.com/owner/repo
git+ssh://git@github.com/owner/repo|github.com/owner/repo
https://github.com/owner/repo|github.com/owner/repo
https://github.com/owner/repo.git|github.com/owner/repo
https://github.com/owner/repo/|github.com/owner/repo
https://github.com/owner/repo.git/|github.com/owner/repo
https://user@github.com/owner/repo.git|github.com/owner/repo
https://user:tok@GitHub.com/owner/repo|github.com/owner/repo
https://user:p@ss@github.com/owner/repo|github.com/owner/repo
https://user:pa#ss@github.com/owner/repo|github.com/owner/repo
https://user:pa?ss@github.com/owner/repo.git|github.com/owner/repo
https://github.com/owner/repo.git?ref=x#frag|github.com/owner/repo
ssh://u:p@ss@github.com/owner/repo|github.com/owner/repo
http://gitlab.com/group/sub/repo.git|gitlab.com/group/sub/repo
https://github.com/owner/my.github.repo|github.com/owner/my.github.repo
https://github.com/gitter/git.github.io.git|github.com/gitter/git.github.io
https://github.com/owner/repo.gitx|github.com/owner/repo.gitx
https://github.com/git/github.com|github.com/git/github.com
TABLE
for notours in "/srv/repos/thing.git" "file:///srv/repos/thing.git" "../sibling" "https://github.com/onlyowner" ""; do
  RC=0; got="$(bash "$SCAN" --normalize-url "$notours" 2>/dev/null)" || RC=$?
  if [ "$RC" -ne 0 ] && [ -z "$got" ]; then ok; else bad "normalize '$notours' is refused, not guessed (rc $RC, got '$got')"; fi
done

echo
echo "passed: $pass, failed: $fail"
echo "SUITE-RESULT passed=$pass failed=$fail"
[ "$fail" -eq 0 ]
