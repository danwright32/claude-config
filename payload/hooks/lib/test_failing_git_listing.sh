# A stand in for git that fails the listing lib/push-changes.sh takes of what a push carries, and
# passes every other call to the real git (claude-config#2349). Sourced by test suites; no hook uses
# it. Named test_ because it is test code, and not test-, which run-all-tests would run as a suite.
#
# pc_resolve once answered a listing git failed exactly as it answered a push carrying no files, so
# a gate judged nothing and let the push through. The suites driving each gate put this stand in on
# the PATH to see each one refuse, or say it could not read, instead.
#
#   failing_git_listing <dir> [committed|staged]
#       writes <dir>/git. committed (the default) fails `git diff --name-only --diff-filter=ACMR
#       <from> HEAD`, the listing of the committed range (pc_files_since); staged fails `git diff
#       --cached --name-only --diff-filter=ACMR`, the listing of the index a pending commit takes.
#       The failed call prints git's own kind of error and exits 128. Returns 1 when no real git is
#       on the PATH to pass the other calls to.

failing_git_listing(){
  local dir="$1" which="${2:-committed}" real pattern
  real="$(command -v git 2>/dev/null)" || return 1
  case "$which" in
    committed) pattern='*" diff --name-only --diff-filter=ACMR "*" HEAD "' ;;
    staged)    pattern='*" diff --cached --name-only --diff-filter=ACMR "' ;;
    *) echo "failing_git_listing: unknown listing '$which' (committed or staged)" >&2; return 1 ;;
  esac
  mkdir -p "$dir" || return 1
  cat > "$dir/git" <<STUB
#!/usr/bin/env bash
case " \$* " in
  $pattern) echo "fatal: the listing failed (a stand in from lib/test_failing_git_listing.sh)" >&2; exit 128 ;;
esac
exec "$real" "\$@"
STUB
  chmod +x "$dir/git"
}
