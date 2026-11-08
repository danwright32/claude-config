#!/usr/bin/env bash
# gh's other names for its write commands, and the public text gh posts outside pull requests and
# issues, in the work names gates and the issue field gate (claude-config#2398).
#
# gh answers to `gh pr new` and `gh issue new` exactly as to `gh pr create` and `gh issue create`
# (the ALIASES section of each command's own help, gh 2.89.0), and the one reading of gh,
# lib/shell-words.py's gh_command, read them as (pr, new) and (issue, new), which no gate treated as a
# create: text posted through them was never checked for work names, and an issue filed through
# `gh issue new` skipped the milestone, priority and category check. Release notes, public gists and
# a public repository's description were not judged at all. This suite holds:
#   1. The reader: every alias gh's help lists for a write (new, remove, co) and every other name of
#      a command group (cs, at, rs, agent, agents, agent-tasks, ext, extensions) reads as its long
#      form, wherever gh's flags stand, so every gate built on it sees the long form.
#   2. The issue field gate refuses `gh issue new` missing its fields, read, unreadable or in a
#      payload nothing could parse, and judges `gh pr new`'s body file.
#   3. The command hook refuses each form whose public text names a work repository: gh pr new, gh
#      issue new, release notes (--notes, --notes-file, the title), a public gist's files and
#      description, and the description of a repository made or edited public; it refuses the forms
#      whose text it cannot read (--generate-notes, --notes-from-tag, a gist file written from what
#      the command does not show). A private repository, a secret gist and clean text pass.
#   4. bin/gh, the guard on PATH, judges the same forms a script runs, standard input included, and
#      still runs gh release list at once.
#
# Every name here is invented. This repository is public, and no work organisation or repository name
# belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-work-names-publish.sh"
FIELDS="$HERE/require-issue-fields.sh"
GUARD_BIN="$HERE/bin"
READER="$HERE/lib/shell-words.py"
. "$HERE/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2.. = a command that succeeds when the check holds
  local name="$1"; shift
  if "$@"; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $name"; fi
}
has(){ [[ "$1" == *"$2"* ]]; }
lacks(){ [[ "$1" != *"$2"* ]]; }

for tool in python3 shasum jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/gh-write-aliases.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR"
CALLS="$WORK/gh-calls"
LIST="$WORK/list.json"
VIS="$WORK/visibility"
STDIN_SAVE="$WORK/stdin-seen"
CO="$WORK/checkout"; mkdir -p "$CO"
ALIASES="$WORK/aliases"; : > "$ALIASES"

# A fake gh, never the real one, so nothing here reaches GitHub: one signed in account, a visibility
# table, the work repository list, no aliases, and any other call recorded as a POST.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "auth status")
    printf '{"hosts":{"github.com":[{"login":"alice","active":true,"state":"success"}]}}\n'
    exit 0 ;;
  "auth token")
    printf 'tok-alice\n'; exit 0 ;;
  "alias list")
    cat "$FAKE_ALIASES"; exit 0 ;;
  "repo view")
    slug=""
    [ "$3" != "--json" ] && slug="$3"
    [ -n "$slug" ] || slug="${GH_REPO:-$(cat "$PWD/.fake-default" 2>/dev/null)}"
    want="$(tr '[:upper:]' '[:lower:]' <<<"$slug")"
    while read -r s v; do
      [ "$(tr '[:upper:]' '[:lower:]' <<<"$s")" = "$want" ] || continue
      printf '{"nameWithOwner":"%s","visibility":"%s"}\n' "$s" "$v"; exit 0
    done < "$FAKE_VIS"
    echo "GraphQL: Could not resolve to a Repository with the name '$slug'." >&2; exit 1 ;;
  "api -H")
    case "$*" in *contents/repos.json*)
      cat "$FAKE_LIST"; exit 0 ;;
    esac ;;
  "api gists/"*)
    # A gist's own record, from the gist table: its id and whether it is public (#2412).
    id="${2#gists/}"
    while read -r g p; do
      [ "$g" = "$id" ] || continue
      printf '{"id":"%s","public":%s}\n' "$g" "$p"; exit 0
    done < "$FAKE_GISTS"
    echo "HTTP 404: Not Found (https://api.github.com/gists/$id)" >&2; exit 1 ;;
esac
for a in "$@"; do
  case "$a" in -) cat > "$FAKE_STDIN_SAVE" ;; esac
done
printf 'POST|%s\n' "$*" >> "$FAKE_CALLS"
exit 0
SH
chmod +x "$BIN/gh"

printf '%s\n' '{"tokenByOwner":{"Acme-Corp":"X"},"repos":[{"owner":"Acme-Corp","name":"acme-widgets","label":"widgets"},{"owner":"Acme-Corp","name":"zephyr","label":"Zephyr"}]}' > "$LIST"
printf 'danwright-test/public-notes PUBLIC\ndanwright-test/private-notes PRIVATE\nAcme-Corp/quiet-tools PRIVATE\n' > "$VIS"
GISTS="$WORK/gists"
printf 'aaaa1111 true\nbbbb2222 false\n' > "$GISTS"
printf 'danwright-test/public-notes' > "$CO/.fake-default"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
PROJECTS="$WORK/CLAUDE.md"
printf '%s' '## Projects

On Dans-MacBook-Pro:
- `~/Apps/Quillfeather`: Next.js

## Writing Style
' > "$PROJECTS"
printf 'Release notes\n\nThe acme-widgets build showed it.\n' > "$CO/named.md"
printf 'Release notes\n\nA work repository showed it.\n' > "$CO/clean.md"

fixture_env(){
  env HOOK_TESTS_RUNNING=1 HOME="$HOMEDIR" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" FAKE_VIS="$VIS" \
    FAKE_STDIN_SAVE="$STDIN_SAVE" FAKE_ALIASES="$ALIASES" FAKE_GISTS="$GISTS" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" \
    WORK_NAMES_PROJECT_LIST="$PROJECTS" WORK_NAMES_PROJECT_HASHES="" "$@"
}

# ================================================================ 1. the reader
read_gh(){   # $@ = a command's words; prints sub and act as gh_command reads them
  python3 -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shell_words", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
found = sw.gh_command(sys.argv[2:])
print("%s %s" % (found[0], found[1]) if found else "none")
' "$READER" "$@"
}
reads(){   # $1 = what it should read as, $2.. = the words
  local want="$1" got; shift
  got="$(read_gh "$@")"
  check "#2398 the reader reads '$*' as '$want', got '$got'" [ "$got" = "$want" ]
}
reads "pr create" gh pr new --title T
reads "issue create" gh issue new --title T
reads "release create" gh release new v1
reads "gist create" gh gist new f.md
reads "repo create" gh repo new o/x --public
reads "secret delete" gh secret remove NAME
reads "variable delete" gh variable remove NAME
reads "pr checkout" gh pr co 5
reads "issue create" gh -R o/x issue new --title T
reads "issue create" gh issue -R o/x new --title T
reads "codespace list" gh cs list
reads "codespace delete" gh cs delete
reads "attestation verify" gh at verify
reads "ruleset view" gh rs view
reads "agent-task create" gh agent create
reads "agent-task create" gh agents create
reads "agent-task create" gh agent-tasks create
reads "extension exec" gh ext exec x
reads "extension exec" gh extensions exec x
reads "pr create" gh pr create
reads "issue view" gh issue view 5
# A name gh does not give is never mapped: `new` is create only where gh's help lists it.
reads "label new" gh label new
# list's alias is left as written, so no gate reading list as a harmless read passes more.
reads "pr ls" gh pr ls
# The checks that skip a command before reading it (claude-config#2411) look only for the group's own
# word, issue or pr, never for an action's: the action is read by gh_path, which knows every alias. So
# every other name gh gives those groups must hold that word, or the cheap test would skip it unread.
# This fails the day the table gains a name for either group that does not.
groups_hold_word(){
  python3 -B -c '
import importlib.util, sys
spec = importlib.util.spec_from_file_location("shell_words", sys.argv[1])
sw = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sw)
bad = [k for k, v in sw.GH_GROUP_ALIASES.items() if v in ("issue", "pr") and v not in k]
print(" ".join(bad))
sys.exit(1 if bad else 0)
' "$READER"
}
check "#2411 every other name of the issue and pr groups holds the word the cheap tests look for" groups_hold_word
# Loading the reader leaves no bytecode beside it (claude-config#2422, the #2080 class). Python caches
# a file it loads by path in lib/__pycache__ unless told not to, and test-shell-code-lines.sh asserts
# lib/ holds no shell-words bytecode, so one run of this suite failed that one in every later full run.
# Measured with both loaders above pointed at a copy, never the real lib/, so a sibling run cannot race it.
PYC="$WORK/pyc"; mkdir -p "$PYC"
python3 "$HERE/lib/install-hook-libs.py" "$HERE/lib" "$PYC" shell-words.py \
  || check "#2422 the reader installs into $PYC" false
pyc_read="$(READER="$PYC/shell-words.py" read_gh gh pr new)"
check "#2422 control: the copied reader ran, got '$pyc_read'" [ "$pyc_read" = "pr create" ]
READER="$PYC/shell-words.py" groups_hold_word >/dev/null
_pyc="$(ls "$PYC/__pycache__" 2>/dev/null | grep -c '^shell-words' || true)"
check "#2422 loading the reader leaves no shell-words bytecode beside it (got $_pyc)" [ "$_pyc" = 0 ]

# ================================================================ 2. the issue field gate
fields(){   # $1 = the command; stdout in out
  out="$(jq -nc --arg c "$1" --arg d "$CO" '{tool_name:"Bash",tool_input:{command:$c},cwd:$d}' \
    | env -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_BRIDGE_SESSION_ID bash "$FIELDS" 2>/dev/null)"
}
denied(){ has "$out" '"deny"'; }
allowed(){ lacks "$out" '"deny"'; }
OPEN='--body "## Open questions

None"'
fields "gh issue new --title T --label priority-p2 --label bug $OPEN"
check "#2398 gh issue new with no milestone is refused by the issue field gate: $out" denied
check "#2398 and named as the create it is: $out" has "$out" "milestone"
fields "gh -R o/x issue new --title T --milestone Ungrouped --label bug $OPEN"
check "#2398 gh issue new with flags in front and no priority is refused: $out" denied
fields "gh issue new --title T --milestone Ungrouped --label priority-p2 --label bug $OPEN"
check "#2398 (control) gh issue new with all its fields passes: $out" allowed
fields 'gh issue new --title "never closed --milestone Ungrouped'
check "#2398 an unreadable command naming gh issue new is refused: $out" denied
: > "$WORK/empty.md"
fields "gh pr create --title T --body-file $WORK/empty.md"
check "#2398 (control) gh pr create with an empty body file is refused: $out" denied
fields "gh pr new --title T --body-file $WORK/empty.md"
check "#2398 gh pr new with an empty body file is refused the same way: $out" denied
out="$(printf '%s' '{"tool_name":"Bash","tool_input":{"command":"gh issue new --title T' | bash "$FIELDS" 2>&1)"; rc=$?
check "#2398 a payload nothing can parse naming gh issue new is refused: rc=$rc $out" [ "$rc" -eq 2 ]

# ================================================================ 3. the command hook
hook(){   # $1 = the command; output in out, decision in decision
  local payload
  payload="$(jq -nc --arg c "$1" --arg d "$CO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  : > "$CALLS"
  out="$(cd "$CO" && printf '%s' "$payload" | fixture_env PATH="$BIN:$PATH" bash "$GATE" 2>&1)"; rc=$?
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
}
refused(){ [ "$rc" -eq 2 ] || [ "$decision" = deny ]; }
passed(){ [ "$rc" -eq 0 ] && [ -z "$decision" ]; }
PUB="--repo danwright-test/public-notes"
PRIV="--repo danwright-test/private-notes"

hook "gh pr new $PUB --title \"Fix it\" --body \"copied from the acme-widgets issue\""
check "#2398 gh pr new naming a work repository in a public repository is refused: $out" refused
hook "gh pr new $PUB --title \"Fix it\" --body \"a work repository showed it\""
check "#2398 (control) a clean gh pr new passes: $out" passed
hook "gh issue new $PUB --title \"Seen in Zephyr\" --body x"
check "#2398 gh issue new naming one is refused: $out" refused
hook "gh -R danwright-test/public-notes issue new --title zephyr --body x"
check "#2398 gh issue new with its flags in front is refused: $out" refused

hook "gh release create v1 $PUB --notes \"built from acme-widgets\""
check "#2398 release notes naming one in a public repository are refused: $out" refused
check "#2398 and the refusal names release notes' command: $out" has "$out" "gh release create"
hook "gh release new v1 $PUB --notes \"built from acme-widgets\""
check "#2398 gh release new is judged as gh release create: $out" refused
hook "gh release create v1 $PUB -n \"the zephyr board\""
check "#2398 the short -n is judged: $out" refused
hook "gh release create v1 $PUB --title \"Zephyr build\" --notes clean"
check "#2398 a release title naming one is refused: $out" refused
hook "gh release create v1 $PUB --notes-file named.md"
check "#2398 a release notes file naming one is refused: $out" refused
check "#2398 and says it was in the notes file: $out" has "$out" "named.md"
hook "gh release create v1 $PUB -F named.md"
check "#2398 the short -F notes file is read: $out" refused
hook "gh release create v1 $PUB --notes-file clean.md"
check "#2398 (control) a clean notes file passes: $out" passed
hook "gh release create v1 $PUB --notes \"a clean build\""
check "#2398 (control) clean notes pass: $out" passed
hook "gh release create v1 $PRIV --notes \"built from acme-widgets\""
check "#2398 (control) release notes in a private repository pass: $out" passed
hook "gh release create v1 $PUB --generate-notes"
check "#2398 notes GitHub generates, which this check cannot read, are refused in a public repository: $out" refused
hook "gh release create v1 $PUB --notes-from-tag"
check "#2398 notes taken from the tag, which this check does not read, are refused: $out" refused
hook "gh release create v1 $PRIV --generate-notes"
check "#2398 (control) generated notes in a private repository pass: $out" passed
hook "gh release edit v1 $PUB --notes \"the zephyr board\""
check "#2398 gh release edit's notes are judged too: $out" refused
hook "python3 gen.py > made.md && gh release create v1 $PUB --notes-file made.md"
check "#2398 a notes file this command writes from what it does not show is refused: $out" refused

# Release notes gh reads from standard input (`--notes-file -`, claude-config#2430) are judged where the
# command shows them (a heredoc, a here-string, echo or printf piped in) or names the file fed in (`<`),
# and refused anywhere else, since the hook cannot read them: the guard reads them only when gh runs.
hook "cat named.md | gh release create v1 $PUB --notes-file -"
check "#2430 notes piped in from what the command does not show are refused: $out" refused
check "#2430 and the refusal says standard input: $out" has "$out" "standard input"
hook "cat clean.md | gh release create v1 $PUB --notes-file -"
check "#2430 clean notes piped from a file are refused the same way, since the hook cannot read them: $out" refused
hook "gh release create v1 $PUB -F - < named.md"
check "#2430 notes fed from a file naming one are read and refused: $out" refused
check "#2430 and the refusal names the file: $out" has "$out" "named.md"
hook "gh release create v1 $PUB -F - < not-there.md"
check "#2430 notes fed from a file that is not there are refused: $out" refused
check "#2430 and say the file fed in could not be read, never that the command wrote it: $out" \
  has "$out" "not-there.md fed to it on standard input, which could not be read"
hook "gh release create v1 $PUB --notes-file=- < named.md"
check "#2430 the --notes-file=- form is read too: $out" refused
hook "gh release create v1 $PUB -F-"
check "#2430 the -F- form with nothing shown on standard input is refused: $out" refused
hook "gh release edit v1 $PUB --notes-file -"
check "#2430 gh release edit's notes from standard input are refused too: $out" refused
hook "bash -c 'cat clean.md | gh release create v1 $PUB --notes-file -'"
check "#2430 notes on standard input inside a shell's string are refused: $out" refused
hook "gh release create v1 $PUB --notes-file - <<'EOF'
a clean build
EOF
bash -c 'cat clean.md | gh release create v2 $PUB --notes-file -'"
check "#2430 and still refused beside a release whose clean notes the command shows: $out" refused
hook "gh release create v1 $PUB --help --notes-file - ; bash -c 'cat clean.md | gh release create v2 $PUB --notes-file -'"
check "#2430 and beside a release that posts nothing (--help), which never stands in for it: $out" refused
hook "gh release create v1 $PUB -F - < clean.md"
check "#2430 (control) a clean file fed in passes: $out" passed
hook "printf 'a clean build\n' | gh release create v1 $PUB --notes-file -"
check "#2430 (control) clean notes the command shows, piped in, pass: $out" passed
hook "printf 'built from acme-widgets\n' | gh release create v1 $PUB --notes-file -"
check "#2430 (control) and naming one, they are judged and refused: $out" refused
hook "gh release create v1 $PUB --notes-file - <<< 'a clean build'"
check "#2430 (control) a clean here-string passes: $out" passed
hook "gh release create v1 $PUB --notes-file - <<'EOF'
a clean build
EOF"
check "#2430 (control) a clean heredoc passes: $out" passed
hook "gh release create v1 $PUB --notes-file - <<'EOF'
built from acme-widgets
EOF"
check "#2430 (control) a heredoc naming one is refused: $out" refused
hook "cat named.md | gh release create v1 $PRIV --notes-file -"
check "#2430 (control) notes on standard input in a private repository pass: $out" passed
# The shell gives a command only its LAST redirection to standard input, so a stage with more than one
# is refused as unread, never judged from the clean one shown beside the file gh really reads (the
# lessons review of #2442). Each heredoc, here-string, `<`, `<&` and `<>` counts as one.
hook "gh release create v1 $PUB -F - <<'EOF' < named.md
a clean build
EOF"
check "#2442 a clean heredoc beside a file fed in is refused, since gh reads the file: $out" refused
check "#2442 and the refusal says standard input: $out" has "$out" "standard input"
hook "gh release create v1 $PUB -F - <<< 'a clean build' < named.md"
check "#2442 a clean here-string beside a file fed in is refused: $out" refused
hook "gh release create v1 $PUB -F - < clean.md <<< 'a clean build'"
check "#2442 a file and a here-string together are refused whichever comes last: $out" refused
hook "printf 'a clean build\n' | gh release create v1 $PUB -F - <&3"
check "#2442 clean text piped in is refused when standard input is taken from another descriptor: $out" refused
hook "printf 'a clean build\n' | gh release create v1 $PUB -F - <> named.md"
check "#2442 and when standard input is a file opened for reading and writing: $out" refused
hook "cat <<'EOF' < named.md | gh release create v1 $PUB -F -
a clean build
EOF"
check "#2442 a stage piping in a file beside a clean heredoc is refused: $out" refused
hook "cat <<< 'a clean build' < named.md | gh release create v1 $PUB -F -"
check "#2442 and beside a clean here-string: $out" refused

hook "gh gist create --public named.md"
check "#2398 a public gist whose file names one is refused: $out" refused
hook "gh gist new -p named.md"
check "#2398 gh gist new -p is judged as gh gist create --public: $out" refused
hook "gh gist create --public --desc \"zephyr notes\" clean.md"
check "#2398 a public gist whose description names one is refused: $out" refused
hook "gh gist create --public clean.md"
check "#2398 (control) a clean public gist passes: $out" passed
hook "gh gist create named.md"
check "#2398 (control) a secret gist passes: $out" passed
hook "python3 gen.py > made.md && gh gist create --public made.md"
check "#2398 a public gist file this command writes from what it does not show is refused: $out" refused
hook "gh gist create --public"
check "#2398 a public gist naming no file, so read from standard input, is refused: $out" refused
hook "cat clean.md | gh gist create --public clean.md -"
check "#2398 standard input beside a named file is refused by the hook, which cannot read it: $out" refused
hook "cat clean.md | gh gist create --public -"
check "#2398 and standard input alone: $out" refused
hook "gh gist create --public -w named.md"
check "#2398 --web still makes the gist before it opens it, so it is judged: $out" refused
hook "gh gist create -wp named.md"
check "#2398 --public among other one letter flags is read as public: $out" refused

hook "gh repo create danwright-test/new-tools --public --description \"zephyr tools\""
check "#2398 a public repository's description naming one is refused with no --push: $out" refused
hook "gh repo new danwright-test/new-tools --public -d \"zephyr tools\""
check "#2398 gh repo new -d is judged as gh repo create: $out" refused
hook "gh repo create danwright-test/new-tools --private --description \"zephyr tools\""
check "#2398 (control) a private repository's description passes: $out" passed
hook "gh repo create danwright-test/new-tools --public --description \"handy tools\""
check "#2398 (control) a clean public description passes: $out" passed
hook "gh repo edit danwright-test/public-notes --description \"zephyr tools\""
check "#2398 editing a public repository's description to name one is refused: $out" refused
hook "gh repo edit --description \"zephyr tools\""
check "#2398 and with the repository read from the checkout: $out" refused
hook "gh repo edit danwright-test/public-notes -h https://example.org --description \"zephyr tools\""
check "#2398 -h is --homepage to gh repo edit, not help, so the edit is judged: $out" refused
hook "gh repo create danwright-test/new-tools --public -h https://example.org -d \"zephyr tools\""
check "#2398 and to gh repo create: $out" refused
hook "gh repo edit danwright-test/public-notes --help"
check "#2398 (control) gh repo edit --help sets nothing and passes: $out" passed
hook "gh repo edit danwright-test/private-notes --description \"zephyr tools\""
check "#2398 (control) a private repository's description passes: $out" passed
hook "gh repo edit danwright-test/public-notes --description \"handy tools\""
check "#2398 (control) a clean description passes: $out" passed

# gh gist edit on a public gist posts its description, a file it adds and a file's new text
# (claude-config#2412). Whether the gist is public is read from GitHub (gh api gists/<id>).
hook "gh gist edit aaaa1111 --desc \"zephyr notes\""
check "#2412 a public gist's new description naming one is refused: $out" refused
check "#2412 and the refusal names gh gist edit and the public gist: $out" has "$out" "gh gist edit posts as a public gist"
hook "gh gist edit https://gist.github.com/someone/aaaa1111 --add named.md"
check "#2412 a file added to a public gist, named by its address, is read and refused: $out" refused
hook "gh gist edit aaaa1111 --filename notes.md named.md"
check "#2412 a public gist file's new text read from a file naming one is refused: $out" refused
hook "gh gist edit aaaa1111 -a named.md"
check "#2412 the short -a is read: $out" refused
hook "gh gist edit aaaa1111 --filename notes.md"
check "#2412 a public gist file edited in an editor program, which this check cannot read, is refused: $out" refused
check "#2412 and says it is an editor's text: $out" has "$out" "editor"
hook "cat clean.md | gh gist edit aaaa1111 --filename notes.md -"
check "#2412 a public gist file's new text from standard input is refused by the hook, which cannot read it: $out" refused
hook "gh gist edit cccc3333 --add clean.md"
check "#2412 a gist whose visibility cannot be read is refused: $out" refused
check "#2412 and says the visibility could not be told: $out" has "$out" "could not tell whether the gist cccc3333 is public"
hook "gh gist edit aaaa1111 --add clean.md"
check "#2412 (control) a clean file added to a public gist passes: $out" passed
hook "gh gist edit aaaa1111 --remove old.md"
check "#2412 (control) removing a file from a public gist posts no text and passes: $out" passed
hook "gh gist edit bbbb2222 --desc \"zephyr notes\" --add named.md"
check "#2412 (control) a secret gist's edit passes: $out" passed
hook "gh gist edit bbbb2222 --filename notes.md"
check "#2412 (control) and a secret gist edited in an editor: $out" passed

# gh repo edit --visibility public publishes every file, commit and issue a private repository holds,
# none of which this check can read (claude-config#2412).
hook "gh repo edit danwright-test/private-notes --visibility public --accept-visibility-change-consequences"
check "#2412 making a private repository public is refused: $out" refused
check "#2412 and says why: $out" has "$out" "makes danwright-test/private-notes public"
hook "gh repo edit danwright-test/private-notes --visibility=PUBLIC --accept-visibility-change-consequences"
check "#2412 the --visibility=value form is read too: $out" refused
hook "GH_REPO=danwright-test/private-notes gh repo edit --visibility public --accept-visibility-change-consequences"
check "#2412 and with the repository named by GH_REPO: $out" refused
hook "gh repo edit danwright-test/private-notes --visibility private --accept-visibility-change-consequences"
check "#2412 (control) keeping a repository private passes: $out" passed
hook "gh repo edit danwright-test/private-notes --visibility internal --accept-visibility-change-consequences"
check "#2412 (control) making it internal, which is not public, passes: $out" passed
hook "gh repo edit danwright-test/public-notes --visibility public --accept-visibility-change-consequences"
check "#2412 (control) a repository already public publishes nothing new and passes: $out" passed
hook "gh repo edit Acme-Corp/quiet-tools --visibility public --accept-visibility-change-consequences"
check "#2412 (control) a work owner's own repository made public passes, as its text does today: $out" passed

# A body or notes file given inside clustered short flags is read (claude-config#2412): gh reads
# `-dF body.md` as --draft then --body-file body.md, and `-dFbody.md` the same.
hook "gh pr create $PUB --title T --head x -dF named.md"
check "#2412 a body file after a clustered -d is read and refused: $out" refused
check "#2412 and says it was in the body file: $out" has "$out" "named.md"
hook "gh pr create $PUB --title T --head x -dFnamed.md"
check "#2412 and with its value attached: $out" refused
hook "gh release create v1 $PUB -dF named.md"
check "#2412 a notes file after a clustered -d is read and refused: $out" refused
hook "gh pr create $PUB --title T --head x -dF clean.md"
check "#2412 (control) a clean body file after a clustered flag passes: $out" passed

# The repository a command posts to, given inside clustered short flags, is read (claude-config#2423):
# gh reads `-dR o/x` as --draft then --repo o/x. GH_REPO names a private repository, so a reading that
# misses the clustered -R judges the private one and passes text posted to the public one.
INPRIV="GH_REPO=danwright-test/private-notes"
hook "$INPRIV gh pr create --title T --head x --body \"copied from the acme-widgets issue\" -dR danwright-test/public-notes"
check "#2423 a repository after a clustered -d is read, and text naming one there is refused: $out" refused
check "#2423 and the refusal names the public repository: $out" has "$out" "danwright-test/public-notes"
hook "$INPRIV gh pr create --title T --head x --body \"copied from the acme-widgets issue\" -dRdanwright-test/public-notes"
check "#2423 and with its value attached: $out" refused
hook "$INPRIV gh pr create --title T --head x --body \"copied from the acme-widgets issue\" -dR=danwright-test/public-notes"
check "#2423 and attached with =, as gh reads it: $out" refused
hook "$INPRIV gh release create v1 -dR danwright-test/public-notes --notes \"built from acme-widgets\""
check "#2423 a release's repository after a clustered -d is read too: $out" refused
hook "$INPRIV gh pr review 5 -cR danwright-test/public-notes --body \"seen in zephyr\""
check "#2423 and a review's, after its clustered -c: $out" refused
# A letter that takes a value of its own ends the cluster, as gh reads it, so `-tRelease` is the title
# Release and never a repository: read as one, the repository elease could not be found and a clean
# command would be refused.
hook "gh pr create $PRIV --head x -tRelease --body \"copied from the acme-widgets issue\""
check "#2423 (control) -tRelease is a title, not a repository, and the private repository's command passes: $out" passed
hook "gh release create v1 -dtR $PRIV --notes \"built from acme-widgets\""
check "#2423 (control) -dtR is a draft titled R, so the private repository named after it is still the one: $out" passed
hook "$INPRIV gh pr create --title T --head x --body \"copied from the acme-widgets issue\" -dR danwright-test/private-notes"
check "#2423 (control) a clustered -R naming a private repository passes: $out" passed

# Each refusal says only what its check measured (L11): a gist file that is not there was never
# written by the command, and standard input is not a file this command writes.
hook "gh gist create --public not-there.md"
check "#2398 a public gist file that is not there is refused: $out" refused
check "#2398 and says it could not be read: $out" has "$out" "could not be read"
check "#2398 and never says the command wrote it: $out" lacks "$out" "writes from something it does not show"
hook "cat clean.md | gh gist create --public -"
check "#2398 a public gist from standard input says standard input: $out" has "$out" "standard input"
check "#2398 and never says the command wrote a file: $out" lacks "$out" "writes from something it does not show"

# ================================================================ 4. the guard on PATH
guard_args(){   # $@ = gh's arguments, run from a script with the guard first on PATH
  : > "$CALLS"; rm -f "$STDIN_SAVE"
  printf '%s\n' 'import subprocess, sys' 'r = subprocess.run(["gh"] + sys.argv[1:], input=sys.stdin.buffer.read())' \
    'sys.exit(r.returncode)' > "$CO/scrub.py"
  out="$(cd "$CO" && fixture_env PATH="$GUARD_BIN:$BIN:$PATH" python3 scrub.py "$@" 2>&1 < "${FEED:-/dev/null}")"; rc=$?
}
not_posted(){ ! grep -q '^POST|' "$CALLS"; }
posted(){ grep -q '^POST|' "$CALLS"; }

guard_args pr new --repo danwright-test/public-notes --title "Fix it" --body "seen in acme-widgets"
check "#2398 the guard refuses gh pr new naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts it" not_posted
guard_args issue new --repo danwright-test/public-notes --title "Zephyr" --body x
check "#2398 the guard refuses gh issue new naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts it" not_posted
guard_args release create v1 --repo danwright-test/public-notes --notes "the zephyr board"
check "#2398 the guard refuses release notes naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts them" not_posted
printf 'Notes from acme-hq\n' > "$WORK/feed-named"
FEED="$WORK/feed-named" guard_args release create v1 --repo danwright-test/public-notes --notes-file -
check "#2398 the guard reads release notes sent on standard input and refuses them: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts them" not_posted
# The guard reads standard input only for a lone `-`, so `--notes-file=-` is notes it never read
# (claude-config#2430): refused, never posted unread.
FEED="$WORK/feed-named" guard_args release create v1 --repo danwright-test/public-notes --notes-file=-
check "#2430 the guard refuses release notes on standard input it did not read (--notes-file=-): rc=$rc $out" [ "$rc" -ne 0 ]
check "#2430 and never posts them" not_posted
FEED="$WORK/feed-named" guard_args gist create --public -
check "#2398 the guard refuses a public gist sent on standard input naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts it" not_posted
guard_args repo edit danwright-test/public-notes --description "zephyr tools"
check "#2398 the guard refuses a public repository's description naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never posts it" not_posted
printf 'Clean notes\n' > "$WORK/feed-clean"
FEED="$WORK/feed-clean" guard_args release create v1 --repo danwright-test/public-notes --notes-file -
check "#2398 (control) clean release notes on standard input post: rc=$rc $out" [ "$rc" -eq 0 ]
check "#2398 (control) with the same bytes the script sent" [ "$(cat "$STDIN_SAVE" 2>/dev/null)" = "Clean notes" ]
guard_args -R danwright-test/public-notes notely
check "#2398 an extension behind a flag gh passes over is refused as an extension: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never runs" not_posted
guard_args --repo danwright-test/public-notes extension exec notely
check "#2398 gh extension exec behind a flag is refused: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never runs" not_posted
guard_args --repo danwright-test/public-notes copilot
check "#2398 gh copilot behind a flag is refused: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2398 and never runs" not_posted
FEED="$WORK/feed-clean" guard_args gist create --public -
check "#2398 (control) the guard reads a clean public gist on standard input and posts it: rc=$rc $out" [ "$rc" -eq 0 ]
guard_args gist edit aaaa1111 --desc "zephyr notes"
check "#2412 the guard refuses a public gist's description naming one: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2412 and never posts it" not_posted
FEED="$WORK/feed-named" guard_args gist edit aaaa1111 --filename notes.md -
check "#2412 the guard reads a public gist file's new text on standard input and refuses it: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2412 and never posts it" not_posted
FEED="$WORK/feed-clean" guard_args gist edit aaaa1111 --filename notes.md -
check "#2412 (control) clean text on standard input for a public gist file posts: rc=$rc $out" [ "$rc" -eq 0 ]
guard_args repo edit danwright-test/private-notes --visibility public --accept-visibility-change-consequences
check "#2412 the guard refuses making a private repository public: rc=$rc $out" [ "$rc" -ne 0 ]
check "#2412 and never runs it" not_posted
guard_args release list
check "#2398 (control) gh release list still runs the real gh at once: rc=$rc $out" [ "$rc" -eq 0 ]
check "#2398 (control) and asks GitHub nothing first" [ "$(grep -c -v '^POST|' "$CALLS")" = "1" ]

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
