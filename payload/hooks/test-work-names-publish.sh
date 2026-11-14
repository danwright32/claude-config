#!/usr/bin/env bash
# The gate that refuses a pull request or issue text naming a work organisation or repository in a
# public repository (claude-config#2105): check-work-names-publish.sh and work_names_publish_gate.py.
#
# On 2026-11-02 a pull request description in this public repository named a work repository three
# times, copied from the issue it closed, and both were scrubbed by hand. This suite holds:
#   1. A gh pr create, pr edit, issue create, issue edit, issue comment, pr comment or pr review in a
#      public repository whose text names a listed work repository or owner is refused, naming what it
#      matched, in any letter case, from --title, --body or a --body-file.
#   2. Whole names only: a listed name inside a longer word is not a match.
#   3. A private repository, a command that is not one of those, and a work repository naming its own
#      owner all pass, and a private repository never needs the list at all.
#   4. Cannot tell is refused, never passed (L98, L345): the list unreadable or empty, the visibility
#      unreadable under every signed in account, a body file the command writes from something it
#      does not show, and a command that cannot be read but names a gated gh command.
#   5. The names come from three places, each seen to fire: the work repository list, this Mac's dev
#      update registry, and the built in organisation hashes (handed in by the WORK_NAMES_EXTRA_HASHES
#      seam, as the scanner's own suite does).
#   6. Two more (claude-config#2184): every project on the work MacBook's project list in the global
#      CLAUDE.md (handed in by the WORK_NAMES_PROJECT_LIST seam), and an organisation's name without
#      its hyphen written as a web or email domain, while the ordinary word sharing those letters
#      passes. A project list that cannot be read, or holds no work MacBook projects, is refused.
#
# Every name here is invented. This repository is public, and no work organisation or repository name
# belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/check-work-names-publish.sh"
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

for tool in node python3 shasum jq; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/work-names-publish.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"; mkdir -p "$BIN"
HOMEDIR="$WORK/home"; mkdir -p "$HOMEDIR"
CALLS="$WORK/gh-calls"
LIST="$WORK/list.json"
VIS="$WORK/visibility"   # lines: <owner/name> <PUBLIC|PRIVATE> [<the only token that can see it>]
CO="$WORK/checkout"; mkdir -p "$CO"

# A fake gh: two signed in accounts, a visibility table, and the work repository list.
cat > "$BIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$FAKE_CALLS"
case "$1 $2" in
  "auth status")
    printf '{"hosts":{"github.com":[{"login":"alice","active":true,"state":"success"},{"login":"bob","active":false,"state":"success"}]}}\n'
    exit 0 ;;
  "auth token")
    for a in "$@"; do last="$a"; done
    printf 'tok-%s\n' "$last"; exit 0 ;;
  "repo view")
    slug=""
    [ "$3" != "--json" ] && slug="$3"
    [ -n "$slug" ] || slug="${GH_REPO:-$(cat "$PWD/.fake-default" 2>/dev/null)}"
    [ -n "$slug" ] || { echo "no git remotes found" >&2; exit 1; }
    want="$(tr '[:upper:]' '[:lower:]' <<<"$slug")"
    while read -r s v only; do
      [ "$(tr '[:upper:]' '[:lower:]' <<<"$s")" = "$want" ] || continue
      if [ -n "$only" ] && [ "${GH_TOKEN:-}" != "$only" ]; then
        echo "GraphQL: Could not resolve to a Repository with the name '$slug'." >&2; exit 1
      fi
      printf '{"nameWithOwner":"%s","visibility":"%s"}\n' "$s" "$v"; exit 0
    done < "$FAKE_VIS"
    echo "GraphQL: Could not resolve to a Repository with the name '$slug'." >&2; exit 1 ;;
  "api -H")
    case "$*" in *contents/repos.json*)
      [ -f "$FAKE_LIST" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
      cat "$FAKE_LIST"; exit 0 ;;
    esac ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
SH
chmod +x "$BIN/gh"

write_list(){ printf '%s\n' "$1" > "$LIST"; }
GOOD_LIST='{"tokenByOwner":{"Acme-Corp":"X"},"repos":[{"owner":"Acme-Corp","name":"acme-widgets","label":"widgets"},{"owner":"Acme-Corp","name":"zephyr","label":"Zephyr"}]}'
write_list "$GOOD_LIST"
printf 'danwright-test/public-notes PUBLIC\ndanwright-test/private-notes PRIVATE\nAcme-Corp/site PUBLIC\ndanwright-test/bob-only PRIVATE tok-bob\n' > "$VIS"
printf 'danwright-test/public-notes' > "$CO/.fake-default"

FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
# A second invented organisation whose name without its hyphen is an ordinary word, for the domain
# rule (claude-config#2184): the word alone is prose, the domain or email address is the organisation.
WORD_HASH="$(printf '%s' "sun-flower" | shasum -a 256 | cut -d' ' -f1)"

# The work MacBook's project list, as the Projects section of the global CLAUDE.md carries it
# (claude-config#2184). The personal MacBook's block comes first, so a reader that took the wrong
# block would be seen. The last work entry is an organisation's name without its hyphen, a project
# all the same, so it is refused as a plain word as well as a domain (claude-config#2190).
PROJECTS="$WORK/CLAUDE.md"
write_projects(){ printf '%s' "$1" > "$PROJECTS"; }
GOOD_PROJECTS='# Global

## Projects

On Daniels-MacBook-Pro-2 (personal MacBook):
- `~/Apps/home-garden`: a personal project
- `~/Apps/Quillwork`: the personal Quillwork

On Dans-MacBook-Pro:
- `~/Apps/Quillfeather`: Next.js, moved here from elsewhere
- `~/thornbury-app`: Vite
- `~/acmehq`: the website

This list records where each project should be.

## Writing Style
'
write_projects "$GOOD_PROJECTS"

# The hashed work MacBook projects (claude-config#2112) replaced through the test seam, none unless a
# check sets them, so these fixtures judge only the names their own block lists.
PROJ_HASHES=""
run(){   # $1 = the command; output in out, exit code in rc, the decision in decision
  local payload
  payload="$(jq -nc --arg c "$1" --arg d "$CO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  : > "$CALLS"
  out="$(cd "$CO" && printf '%s' "$payload" | PATH="$BIN:$PATH" HOME="$HOMEDIR" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" \
    FAKE_VIS="$VIS" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH,$WORD_HASH" WORK_NAMES_PROJECT_LIST="$PROJECTS" \
    HOOK_TESTS_RUNNING=1 WORK_NAMES_PROJECT_HASHES="$PROJ_HASHES" bash "$GATE" 2>&1)"; rc=$?
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
}
refused(){ [ "$rc" -eq 2 ] || [ "$decision" = deny ]; }
passed(){ [ "$rc" -eq 0 ] && [ -z "$decision" ]; }

# ---------------------------------------------------------------- 1. refused in a public repository
run 'gh pr create --repo danwright32-test/x --title "Fix it" --body "copied from the acme-widgets issue"'
check "(control) an unknown repository is not public by any answer, so refused as cannot tell: $out" refused
run 'gh pr create --repo danwright-test/public-notes --title "Fix it" --body "copied from the acme-widgets issue"'
check "a public pull request whose body names a listed work repository is refused: $out" refused
check "and names the name it matched: $out" has "$out" "acme-widgets"
check "and says how to fix it: $out" has "$out" "Scrub"
run 'gh pr create --repo danwright-test/public-notes --title "Fix it" --body "copied from the ACME-Widgets issue"'
check "in any letter case: $out" refused
run 'gh issue create --title "Seen in Zephyr" --body "nothing here" --milestone Ungrouped'
check "a title naming one, with the repository read from the checkout: $out" refused
check "and the visibility was asked about the checkout's repository" has "$(cat "$CALLS")" "repo view --json"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the acme-corp board"'
check "a comment naming a listed owner: $out" refused
run 'gh pr comment 5 --repo danwright-test/public-notes -b "see acme-widgets#12"'
check "a pull request comment, written name#N: $out" refused
run 'gh pr edit 5 --repo danwright-test/public-notes --body "zephyr"'
check "a pull request edit: $out" refused
run 'gh issue edit 5 --repo danwright-test/public-notes --title "zephyr again"'
check "an issue edit: $out" refused
run 'gh pr review 5 --repo danwright-test/public-notes --comment --body "like zephyr does"'
check "a review: $out" refused
printf 'Closes #1\n\nThe acme-widgets checkout showed it.\n' > "$CO/body.md"
run 'gh pr create --repo danwright-test/public-notes --title "Fix it" --body-file body.md'
check "a body file naming one: $out" refused
check "and says it was in the body file: $out" has "$out" "body.md"
printf 'Closes #1\n\nA work repository showed it.\n' > "$CO/clean.md"
run 'gh pr create --repo danwright-test/public-notes --title "Fix it" --body-file clean.md'
check "(control) a clean body file passes: $out" passed

# ---------------------------------------------------------------- 2. whole names only
run 'gh pr create --repo danwright-test/public-notes --title "Zephyrine weather" --body "acme-widgetsmith and zephyrs"'
check "a listed name inside a longer word is not a match: $out" passed

# ---------------------------------------------------------------- 3. what passes
run 'gh pr create --repo danwright-test/private-notes --title "zephyr" --body "acme-widgets"'
check "a private repository passes: $out" passed
rm -f "$LIST"
run 'gh pr create --repo danwright-test/private-notes --title "zephyr" --body "acme-widgets"'
check "and never needs the list, so an unreadable one does not refuse it: $out" passed
check "(the list was not even asked for)" lacks "$(cat "$CALLS")" "contents/repos.json"
write_list "$GOOD_LIST"
run 'gh pr create --repo danwright-test/bob-only --title "zephyr" --body "acme-widgets"'
check "a private repository only the second signed in account can see is read through that account and passes: $out" passed
run 'gh pr view 5 --repo danwright-test/public-notes --json body'
check "a gh command that posts nothing passes: $out" passed
check "and asks GitHub nothing" [ ! -s "$CALLS" ]
run 'ls -la /tmp && echo zephyr'
check "a command that is not gh passes: $out" [ "$rc" -eq 0 ]
check "and silently: $out" [ -z "$out" ]
run 'gh issue create --repo Acme-Corp/site --title "zephyr" --body "acme-widgets" --milestone M'
check "a public repository of a work owner may name its own work: $out" passed
run 'gh pr create --repo danwright-test/public-notes --title "Tidy the reader" --body "nothing to see"'
check "(control) a clean public pull request passes: $out" passed

# ---------------------------------------------------------------- 4. cannot tell is refused
rm -f "$LIST"
run 'gh pr create --repo danwright-test/public-notes --title "Tidy" --body "nothing to see"'
check "the list unreadable refuses a public write rather than passing it unchecked: $out" refused
check "and says the list could not be read: $out" has "$out" "could not be read"
write_list '{"repos":[]}'
run 'gh pr create --repo danwright-test/public-notes --title "Tidy" --body "nothing to see"'
check "an empty list is refused, never read as clean: $out" refused
write_list '{"nope":true}'
run 'gh pr create --repo danwright-test/public-notes --title "Tidy" --body "nothing to see"'
check "a list of the wrong shape is refused: $out" refused
write_list "$GOOD_LIST"
run 'gh pr create --repo danwright-test/nowhere --title "Tidy" --body "nothing to see"'
check "visibility unreadable under every account is refused: $out" refused
check "and says the visibility could not be told: $out" has "$out" "public"
run 'python3 make_body.py > gen.md; gh pr create --repo danwright-test/public-notes --title "Tidy" --body-file gen.md'
check "a body file the command writes from something it does not show is refused in a public repository: $out" refused
run 'gh pr create --repo danwright-test/public-notes --title "Tidy --body unclosed'
check "a command that cannot be read but names a gated gh command is refused: $out" refused
run 'echo "unclosed && gh pr view 5'
check "(control) an unreadable command naming no gated gh command passes: $out" passed

# ---------------------------------------------------------------- 5. each source fires
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the acme-hq board"'
check "a built in organisation, handed in by hash: $out" refused
check "and names it: $out" has "$out" "acme-hq"
mkdir -p "$HOMEDIR/.claude/skills/pennie-dev-update"
printf '{"repos":[{"name":"Widget","repo":"Globex-Work/gadget-hub","account":"globex-bot"}]}\n' > "$HOMEDIR/.claude/skills/pennie-dev-update/repos.local.json"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "fixed in gadget-hub"'
check "a repository from this Mac's dev update registry: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the globex-work board"'
check "an owner from this Mac's dev update registry: $out" refused
printf '{not json' > "$HOMEDIR/.claude/skills/pennie-dev-update/repos.local.json"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "an unreadable registry is refused, never read as empty: $out" refused
printf 'setTimeout(function () {}, 30000);\n' > "$WORK/hung-registry.js"
started=$SECONDS
WORK_NAMES_REGISTRY_READER="$WORK/hung-registry.js" WN_PUBLISH_BUDGET_SECONDS=3 \
  run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
took=$((SECONDS - started))
check "a registry reader that hangs is refused with the gate's own reason: $out" [ "$decision" = deny ]
check "within the gate's budget, not the reader's 60 seconds or the hook's 45 (took ${took}s)" [ "$took" -lt 15 ]
rm -f "$HOMEDIR/.claude/skills/pennie-dev-update/repos.local.json"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "(control) no registry at all is allowed, and the list and the hashes still judge: $out" passed

# ---------------------------------------------------------------- 6. a body fed by a heredoc, and gh api
run "gh pr create --repo danwright-test/public-notes --title Tidy --body-file - <<'EOF'
Seen first in the zephyr checkout.
EOF"
check "a body fed to standard input by a heredoc is read from the command: $out" refused
run 'gh api repos/danwright-test/public-notes/issues/5/comments -f body="see acme-widgets"'
check "a gh api comment naming a listed repository in a public repository: $out" refused
run 'gh api -X PATCH repos/danwright-test/public-notes/pulls/5 -f body="zephyr"'
check "a gh api pull request edit: $out" refused
run 'gh api repos/{owner}/{repo}/issues -f title="Seen in Zephyr"'
check "a gh api write to the checkout's own repository, through the placeholders: $out" refused
run 'gh api repos/danwright-test/public-notes/issues/5/comments --input body.md'
check "a gh api write sending a file naming one: $out" refused
check "and says which file: $out" has "$out" "body.md"
run 'gh api repos/danwright-test/public-notes/issues/5/comments --input nowhere.json'
check "a gh api write sending a file that cannot be read is refused: $out" refused
check "with the gate's own reason, not a crash the wrapper caught: $out" [ "$decision" = deny ]
check "and names the file it could not read: $out" has "$out" "nowhere.json"
run 'gh api repos/danwright-test/public-notes/issues/5/comments -F body=@nowhere.md'
check "a gh api field read from a file that cannot be read is refused with the gate's own reason: $out" [ "$decision" = deny ]
check "and names that file: $out" has "$out" "nowhere.md"
run 'gh api repos/danwright-test/private-notes/issues/5/comments -f body="zephyr"'
check "(control) a gh api write to a private repository passes: $out" passed
run 'gh api repos/danwright-test/public-notes/issues/5/comments'
check "(control) a gh api read passes: $out" passed
run 'gh api repos/danwright-test/public-notes/issues/5/comments -f body="nothing to see"'
check "(control) a clean gh api write passes: $out" passed

# ---------------------------------------------------------------- 7. the work MacBook's projects, and domains
# claude-config#2184: work repositories on the work MacBook's project list that neither the list nor
# the registry holds, and an organisation's web and email domain, were let through.
run 'gh pr create --repo danwright-test/public-notes --title "Fix it" --body "copied from the Quillfeather checkout"'
check "a project on the work MacBook's list is refused, in any letter case: $out" refused
check "and names the name it matched: $out" has "$out" "quillfeather"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the thornbury-app board"'
check "every project on that list, a hyphenated one too: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the home-garden and quillwork notes"'
check "(control) projects on the personal MacBook's list pass: $out" passed
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the quillfeathers and thornbury-apple"'
check "(control) a listed project inside a longer word is no match: $out" passed
run 'gh issue comment 5 --repo danwright-test/public-notes --body "mail dan@sunflower.com about it"'
check "an organisation's email domain, the name without its hyphen after an @, is refused: $out" refused
check "and names what it matched: $out" has "$out" "sunflower"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "see https://www.SunFlower.io/pricing"'
check "its web domain, the name without its hyphen before a dot and a top level domain, is refused: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the form posts to mail.sunflower.co.uk"'
check "under a subdomain and a two part top level domain too: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "a sunflower grows; sunflowers.com is a florist; plant sunflower seeds"'
check "(control) the ordinary word sharing those letters passes, alone or in another domain: $out" passed
run 'gh issue comment 5 --repo danwright-test/public-notes --body "write to team@acmehq.com"'
check "a project list name that is an organisation without its hyphen is refused as an email domain: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the acmehq folder"'
check "#2190 and as a bare word it is a project all the same, so it is refused: $out" refused
run 'gh issue comment 5 --repo danwright-test/public-notes --body "the acmehqs and preacmehq notes"'
check "#2190 (control) that project inside a longer word is no match: $out" passed
# Cannot tell is refused (L98, L345): the project list is a source like the others.
rm -f "$PROJECTS"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "the project list unreadable refuses a public write: $out" refused
check "and says the project list could not be read: $out" has "$out" "project list"
run 'gh issue comment 5 --repo danwright-test/private-notes --body "quillfeather"'
check "(control) a private repository never needs the project list: $out" passed
write_projects '# Global

## Writing Style
- `~/Apps/Quillfeather`
'
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "a CLAUDE.md with no Projects section is refused: $out" refused
check "and says the section is missing: $out" has "$out" "Projects"
write_projects '## Projects

On Daniels-MacBook-Pro-2 (personal MacBook):
- `~/Apps/home-garden`
'
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "a Projects section with no work MacBook block is refused: $out" refused
check "and says that block is missing: $out" has "$out" "Dans-MacBook-Pro"
write_projects '## Projects

On Dans-MacBook-Pro:

The list is empty today.
'
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "a work MacBook block that lists no project is refused, never read as clean: $out" refused
# claude-config#2112: the same empty block with a hashed project (an invented name) is readable, and
# the gate refuses that name through its hash alone, as it refuses a listed one.
PROJ_HASHES="$(printf '%s' "fernhollow" | shasum -a 256 | cut -d' ' -f1)"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "#2112 an empty block with a hashed project lets a clean comment through: $out" passed
run 'gh issue comment 5 --repo danwright-test/public-notes --body "moved from the FernHollow checkout"'
check "#2112 and refuses a comment naming the hashed project: $out" refused
PROJ_HASHES="$(printf '%s' "nothing-named-this" | shasum -a 256 | cut -d' ' -f1)"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "moved from the FernHollow checkout"'
check "#2112 (control) with that hash absent the same comment passes, so the refusal came from it: $out" passed
PROJ_HASHES=""
write_projects "$GOOD_PROJECTS"
run 'gh issue comment 5 --repo danwright-test/public-notes --body "nothing to see"'
check "(control) the project list restored, a clean comment passes: $out" passed

# ---------------------------------------------------------------- 8. a gate that fails refuses
BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN/python3"; chmod +x "$BROKEN/python3"
payload="$(jq -nc --arg c 'gh pr create --repo danwright-test/public-notes --title Tidy --body ok' --arg d "$CO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | PATH="$BROKEN:$BIN:$PATH" bash "$GATE" 2>&1)"; rc=$?
check "a gate that crashes refuses the command rather than passing it: rc=$rc $out" [ "$rc" -eq 2 ]
check "and says it could not check: $out" has "$out" "could not be checked"

# ---------------------------------------------------------------- a redirection in front of gh (claude-config#2235)
# The shell takes a redirection out of a command before it finds the name, so `2>/dev/null gh pr
# create` opens the pull request. The scan cut `2>` into `2` and `>` and wrote the words back quoted,
# so the gate read a command named 2 and let a work name through. Each case is also run through a
# copy of the hooks whose reader reads the redirection the old way, which must let it through.
for v in rejoin glue; do
  check "#2235 the $v copy of the hooks is made" python3 -B "$HERE/lib/loose-reader.py" "$HERE" "$WORK/loose-$v" "$v"
done
redirected(){ # redirected <description> <command> <loose copy>...
  local name="$1" cmd="$2" v
  shift 2
  run "$cmd"
  check "#2235 $name: $out" refused
  for v in "$@"; do
    GATE="$WORK/loose-$v/check-work-names-publish.sh" run "$cmd"
    check "#2235 the $v copy should let it through, or the case decides nothing: $name: $out" passed
  done
}
redirected "a public pull request behind an error redirection" '2>/dev/null gh pr create --repo danwright-test/public-notes --title "Fix it" --body "copied from the acme-widgets issue"' rejoin glue
redirected "a comment behind an output redirection" '> /dev/null gh issue comment 5 --repo danwright-test/public-notes --body "the acme-corp board"' rejoin
redirected "a pull request edit behind input" '</dev/null gh pr edit 5 --repo danwright-test/public-notes --body "zephyr"' rejoin
redirected "gh api behind an error redirection" '2>/dev/null gh api repos/danwright-test/public-notes/issues/5/comments -f body="see acme-widgets"' glue
run '2>/dev/null gh pr create --repo danwright-test/public-notes --title "Fix it" --body "nothing to see"'
check "#2235 control: clean text behind a redirection passes: $out" passed

# ---------------------------------------------------------------- the path of a body file, and a cd (claude-config#2909)
# A session in a work project keeps its files in a notes folder named after the project, so the path
# of every body file it writes carries the name, and so does a cd into its checkout. Neither is posted:
# what is judged is the title, the body and the text of the body file. Here the invented work
# repository acme-widgets stands in for that project.
NOTES="$WORK/session-notes/acme-widgets/s1"; mkdir -p "$NOTES"
WORKCO="$WORK/apps/acme-widgets"; mkdir -p "$WORKCO"
printf 'A report that names no work repository.\n' > "$NOTES/body.md"
printf 'Seen first in the zephyr checkout.\n' > "$NOTES/named.md"
printf 'A report that names no work repository.\n' > "$WORKCO/clean.md"
run "gh issue create --repo danwright-test/public-notes --title \"x\" --body-file $NOTES/body.md"
check "#2909 a clean body file whose path names a work repository passes: $out" passed
run "gh issue create --repo danwright-test/public-notes --title \"x\" --body-file=$NOTES/body.md"
check "#2909 and written --body-file=path: $out" passed
run "gh pr comment 5 --repo danwright-test/public-notes -F \"$NOTES/body.md\""
check "#2909 and as a quoted -F on a pull request comment: $out" passed
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"x\" --body-file clean.md"
check "#2909 a cd into a checkout named after a work repository is not posted: $out" passed
run "cd \"$WORKCO\"
gh issue create --repo danwright-test/public-notes --title \"x\" --body-file $NOTES/body.md"
check "#2909 a quoted cd on its own line, and a body file in the notes folder: $out" passed
# What is posted is still judged.
run "gh issue create --repo danwright-test/public-notes --title \"x\" --body-file $NOTES/named.md"
check "#2909 a body file in that folder whose text names one is refused: $out" refused
check "#2909 and names the name in its text: $out" has "$out" "zephyr"
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"the acme-widgets bug\" --body-file $NOTES/body.md"
check "#2909 a title naming one is refused, cd and path aside: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"x\" --label acme-widgets --body-file $NOTES/body.md"
check "#2909 a name in another argument that is posted (a label) is refused: $out" refused
run "cd $WORKCO && echo 'the acme-widgets board' > made.md && gh issue create --repo danwright-test/public-notes --title x --body-file made.md"
check "#2909 a body file this command writes from text naming one is refused: $out" refused
run "cd \"\$(echo $WORKCO)\" && gh issue create --repo danwright-test/public-notes --title x --body-file clean.md"
check "#2909 (control) a cd whose directory comes from a substitution is still judged as written: $out" refused
# A cd is left out only while nothing in the command can read back the directory it entered.
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"\$(basename \$(pwd))\" --body-file clean.md"
check "#2909 a title read from the directory a cd entered is still judged with the cd: $out" refused
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"from \$PWD\" --body-file clean.md"
check "#2909 and so is one naming \$PWD: $out" refused
run "cd $WORKCO && echo \"\$PWD\" > made.md && gh issue create --repo danwright-test/public-notes --title x --body-file made.md"
check "#2909 and a body file written from \$PWD: $out" refused
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title ~+ --body-file clean.md"
check "#2909 and a title of ~+, which the shell expands to the directory: $out" refused
run "cd $WORKCO && cd /tmp && gh issue create --repo danwright-test/public-notes --title \"\$OLDPWD\" --body-file $NOTES/body.md"
check "#2909 and \$OLDPWD after a second cd: $out" refused
run "cd $WORKCO && cd /tmp && gh issue create --repo danwright-test/public-notes --title ~- --body-file $NOTES/body.md"
check "#2909 and ~- after a second cd: $out" refused
# Any expansion keeps the cd judged, not a list of the ones known to read it back: $_ is the cd's own
# last argument and ${DIRSTACK[0]} the directory itself (the lessons review of 312c22b).
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"\$_\" --body-file clean.md"
check "#2909 and \$_, the cd's own argument: $out" refused
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"\${DIRSTACK[0]}\" --body-file clean.md"
check "#2909 and \${DIRSTACK[0]}: $out" refused
run "cd $WORKCO && gh issue create --repo danwright-test/public-notes --title \"\`basename .\`\" --body-file clean.md"
check "#2909 and a backquoted command: $out" refused
run "cd $WORKCO && pwd | gh issue create --repo danwright-test/public-notes --title x --body-file -"
check "#2909 (control) a body piped from pwd is refused, as any unshown standard input is: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body-file $NOTES/nowhere.md"
check "#2909 a body file that cannot be read is refused: $out" refused
check "#2909 saying it could not be read: $out" has "$out" "could not be read"
check "#2909 not that the text names a work repository: $out" lacks "$out" 'names `'
run "gh issue create --repo danwright-test/private-notes --title x --body-file $NOTES/nowhere.md"
check "#2909 (control) a private repository is not asked about its body file: $out" passed

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
