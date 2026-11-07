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
esac
for a in "$@"; do
  case "$a" in -) cat > "$FAKE_STDIN_SAVE" ;; esac
done
printf 'POST|%s\n' "$*" >> "$FAKE_CALLS"
exit 0
SH
chmod +x "$BIN/gh"

printf '%s\n' '{"tokenByOwner":{"Acme-Corp":"X"},"repos":[{"owner":"Acme-Corp","name":"acme-widgets","label":"widgets"},{"owner":"Acme-Corp","name":"zephyr","label":"Zephyr"}]}' > "$LIST"
printf 'danwright-test/public-notes PUBLIC\ndanwright-test/private-notes PRIVATE\n' > "$VIS"
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
    FAKE_STDIN_SAVE="$STDIN_SAVE" FAKE_ALIASES="$ALIASES" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" \
    WORK_NAMES_PROJECT_LIST="$PROJECTS" WORK_NAMES_PROJECT_HASHES="" "$@"
}

# ================================================================ 1. the reader
read_gh(){   # $@ = a command's words; prints sub and act as gh_command reads them
  python3 -c '
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
guard_args release list
check "#2398 (control) gh release list still runs the real gh at once: rc=$rc $out" [ "$rc" -eq 0 ]
check "#2398 (control) and asks GitHub nothing first" [ "$(grep -c -v '^POST|' "$CALLS")" = "1" ]

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
