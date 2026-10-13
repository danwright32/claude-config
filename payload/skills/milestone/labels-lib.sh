# labels-lib.sh: reading a repository's labels and creating a missing one. Sourced, never run.
#
# ensure-priority-labels.sh makes the five priority levels exist, and create-milestone.sh makes the
# category labels a plan names exist (claude-config#1034). Both need the same three things: read the
# label list without ever mistaking a failed read for an empty repo, tell whether a name is already
# there as GitHub judges it, and treat a create that loses a race to another writer as the label
# existing. One copy of each, here, so the two callers cannot drift apart (L370).

# lb_read <owner/name> <error file>: prints every label name in the repository, lowercased, one per
# line. Returns 1 when the list could not be read or parsed, with the reason in the error file:
# a caller must then refuse rather than create blind, because an unreadable list and an empty one
# would otherwise look the same (L215). stdout and stderr are kept apart so a gh warning cannot
# land in the middle of the JSON.
lb_read() {
  local raw names
  if ! raw="$(gh label list --repo "$1" --limit 500 --json name 2>"$2")"; then
    return 1
  fi
  names="$(printf '%s' "$raw" | python3 -c '
import json, sys
try:
    data = json.load(sys.stdin)
except Exception:
    print("PARSE-ERROR")
    sys.exit(0)
if not isinstance(data, list):
    print("PARSE-ERROR")
    sys.exit(0)
# Lowercased: GitHub treats label names case insensitively for uniqueness, so creating
# priority-p2 next to an existing PRIORITY-P2 fails.
for item in data:
    name = (item or {}).get("name") if isinstance(item, dict) else None
    if name:
        print(name.lower())
')" || { echo "python3 could not read the response" >"$2"; return 1; }
  if [[ "$names" == "PARSE-ERROR" ]]; then
    echo "unexpected response" >"$2"
    return 1
  fi
  printf '%s' "$names"
}

# lb_has <the list lb_read printed> <name>: whether the name is in it, compared as GitHub does,
# without regard to case.
lb_has() {
  local want
  want="$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')"
  # `case` over the list rather than `printf ... | grep -qxF` (claude-config#162). `grep -q` leaves
  # on its first match, its producer is killed by SIGPIPE, and under `pipefail` the pipeline's
  # status becomes that death, so a label that IS present reads as missing and gets created again.
  # Whether it bites depends on how long the label list is and where in it the match falls, which
  # is a size threshold nobody watches (L183). The newlines on both sides make this a whole line
  # match, and the name is quoted inside the pattern so a glob character in it stays literal.
  case "
$1
" in *"
$want
"*) return 0 ;; esac
  return 1
}

# lb_create <owner/name> <name> <colour> <description> <error file>
#   0  created
#   3  already there: another run, or a person in the GitHub UI, created it between the list read
#      and this create. That is the idempotent outcome, not a failure.
#   1  could not be created, with gh's reason in the error file
# Only gh's own words for an existing label count as 3 ("already exists", or the API's
# already_exists code), never a bare 422: GitHub answers 422 for every validation failure, a bad
# name or a description over 100 characters included, and reading those as the label existing
# would carry on into an issue create gh then refuses.
lb_create() {
  if gh label create "$2" --repo "$1" --color "$3" --description "$4" >/dev/null 2>"$5"; then
    return 0
  fi
  if grep -iE 'already[ _]exists' "$5" >/dev/null; then
    return 3
  fi
  return 1
}
