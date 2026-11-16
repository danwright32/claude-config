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
# The folder of shell snapshots the gate reads (WN_SHELL_SNAPSHOTS, claude-config#3020): none until the
# checks of the shell profile write one, so no check reads this Mac's own.
SNAPS="$WORK/shell-snapshots"

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
  # RUN_DIR, when set, is the directory the session runs the command from (the checkout otherwise).
  local payload dir="${RUN_DIR:-$CO}"
  payload="$(jq -nc --arg c "$1" --arg d "$dir" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  : > "$CALLS"
  out="$(cd "$dir" && printf '%s' "$payload" | PATH="$BIN:$PATH" HOME="$HOMEDIR" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" \
    FAKE_VIS="$VIS" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH,$WORD_HASH" WORK_NAMES_PROJECT_LIST="$PROJECTS" \
    HOOK_TESTS_RUNNING=1 WORK_NAMES_PROJECT_HASHES="$PROJ_HASHES" WN_SHELL_SNAPSHOTS="$SNAPS" bash "$GATE" 2>&1)"; rc=$?
  decision="$(printf '%s' "$out" | jq -r '.hookSpecificOutput.permissionDecision // empty' 2>/dev/null)"
}
refused(){ [ "$rc" -eq 2 ] || [ "$decision" = deny ]; }
passed(){ [ "$rc" -eq 0 ] && [ -z "$decision" ]; }
# Refused as a program whose output cannot be read, never by the name where it runs: from a work
# checkout a git lookup is refused either way, so only the reason shows which reading was taken.
refused_unread(){ refused && has "$out" "cannot read before the command runs"; }

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

# ---------------------------------------------------------------- a variable in posted text (claude-config#2961)
# A variable was judged by its spelling, so a title built from $CLAUDE_PROJECT_DIR, or any variable
# holding a work checkout's path, passed while the shell posted the path. A variable the shell expands
# in what is posted is judged by its value where that is known (the environment every Bash call
# starts from, or an assignment earlier in the command), and refused as unreadable where it is not.
export WN_TEST_DIR="$WORKCO" WN_TEST_CLEAN="nothing to see" WN_TEST_NOTES="$NOTES"
unset WN_TEST_NOT_SET
run "gh issue create --repo danwright-test/public-notes --title \"from \$WN_TEST_DIR\" --body x"
check "#2961 a title expanding a variable whose value names a work repository is refused: $out" refused
check "#2961 and says the name: $out" has "$out" "acme-widgets"
run "gh issue create --repo danwright-test/public-notes --title x --body \"see \${WN_TEST_DIR}/notes\""
check "#2961 and so is a body writing it in braces: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"from \$WN_TEST_NOT_SET\" --body x"
check "#2961 a variable set nowhere this check can read is refused: $out" refused
check "#2961 saying its value cannot be told: $out" has "$out" "cannot be told"
run "gh issue create --repo danwright-test/public-notes --title \"from \${WN_TEST_CLEAN:-x}\" --body x"
check "#2961 an expansion past a plain name is refused as unreadable: $out" refused
run "T=\$(date); gh issue create --repo danwright-test/public-notes --title \"\$T\" --body x"
check "#2961 a variable this command sets from a substitution is refused: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen in \$WN_TEST_DIR
EOF
)\""
check "#2961 a variable in an unquoted heredoc body is expanded, so judged: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"from \$WN_TEST_CLEAN\" --body x"
check "#2961 (control) a variable whose value names nothing passes: $out" passed
run "T='clean words'; gh issue create --repo danwright-test/public-notes --title \"\$T\" --body x"
check "#2961 (control) and so does one this command sets to clean text: $out" passed
run "gh issue create --repo danwright-test/public-notes --title 'from \$WN_TEST_DIR' --body x"
check "#2961 (control) a single quoted dollar is text, not a variable: $out" passed
run "gh issue create --repo danwright-test/public-notes --title \"cost \\\$WN_TEST_NOT_SET\" --body x"
check "#2961 (control) and so is an escaped one: $out" passed
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<'EOF'
Use \$WN_TEST_NOT_SET and \$WN_TEST_DIR here.
EOF
)\""
check "#2961 (control) a quoted heredoc body is text, however many dollars it holds: $out" passed
run "cd \"\$WN_TEST_DIR\" && gh issue create --repo danwright-test/public-notes --title x --body-file $NOTES/body.md"
check "#2961 (control) a cd's directory is where the command runs, not posted: $out" passed
# Unless something reads the directory back, when the cd's own variable is posted after all (the
# lessons review of 1029c9f).
run "cd \"\$WN_TEST_DIR\" && gh issue create --repo danwright-test/public-notes --title \"\$(basename \$(pwd))\" --body x"
check "#2961 a cd into a variable's folder, read back by pwd, is judged by the variable's value: $out" refused
run "cd \"\$WN_TEST_DIR\" && gh issue create --repo danwright-test/public-notes --title \"\$_\" --body x"
check "#2961 and so is one read back by \$_: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body-file \"\$WN_TEST_NOTES/body.md\""
check "#2961 (control) nor is the path of a body file: $out" passed
run "gh issue create --repo danwright-test/private-notes --title \"from \$WN_TEST_NOT_SET \$WN_TEST_DIR\" --body x"
check "#2961 (control) a private repository is not asked about its variables: $out" passed
# $_ is the last word of the command before, which can be a body file's path, never posted itself
# and so never judged (the lessons review of 6bb51da).
run "gh issue create --repo danwright-test/public-notes --title x --body-file \"$NOTES/body.md\" && gh issue comment 5 --repo danwright-test/public-notes --body \"\$_\""
check "#2961 \$_ after a body file's path is refused as unreadable: $out" refused
run "gh issue comment 5 --repo danwright-test/public-notes --body \"\${_}\""
check "#2961 and so is \${_}: $out" refused
# A new public repository's name, description and homepage are judged the same way.
run "gh repo create danwright-test/fresh --public --description \"from \$WN_TEST_DIR\""
check "#2961 a public repository described from a variable naming a work repository is refused: $out" refused
run "gh repo create danwright-test/fresh --public --homepage \"\$WN_TEST_NOT_SET\""
check "#2961 and one with a homepage from a variable set nowhere: $out" refused
run "gh repo create danwright-test/fresh --public --description \"\$WN_TEST_CLEAN\""
check "#2961 (control) a public repository described from a clean variable passes: $out" passed
run "gh repo create danwright-test/fresh --private --description \"from \$WN_TEST_DIR\""
check "#2961 (control) a private one is not asked about its variables: $out" passed
# A sync posts no text of its own; a variable naming either repository leaves it unreadable, refused.
run "gh repo sync \"\$WN_TEST_NOT_SET\" --source danwright-test/private-notes"
check "#2961 a sync to a repository named by a variable is refused: $out" refused
export WN_TEST_SRC="danwright-test/private-notes"
run "gh repo sync danwright-test/public-notes --source \"\$WN_TEST_SRC\""
check "#2961 and so is one from a source named by a variable: $out" refused
unset WN_TEST_SRC
# A gh api write is judged where it runs too, with what the command set before it (the lessons
# review of af806e6: it was judged from the environment alone, so a clean assignment was refused).
run "T='clean words'; gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"\$T\""
check "#2961 (control) a gh api write posting a variable this command set to clean text passes: $out" passed
run "gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"see \$WN_TEST_DIR\""
check "#2961 a gh api write posting a variable whose value names a work repository is refused: $out" refused
run "T=\$(date); gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"\$T\""
check "#2961 and one set from a substitution is refused: $out" refused
run "T='clean words'; gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"\$T\"; T=\$(date); gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"\$T\""
check "#2961 two api writes in the same words are each judged where they run (the lessons review of ce9f5b1): $out" refused
unset WN_TEST_DIR WN_TEST_CLEAN WN_TEST_NOTES

# ---------------------------------------------------------------- the directory read back with no cd (claude-config#2981)
# ~+, ~- and a pwd substitution were judged by their spelling when no cd came before them, so a title
# of ~+ or "$(pwd)", run from a work checkout, passed while the shell posted the checkout's path. Each
# is judged by the directory it reads (where the command runs, or the one before it for ~-), and
# refused where that cannot be known.
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title ~+ --body x"
check "#2981 a title of ~+ run from a work checkout is refused: $out" refused
check "#2981 and says the name its directory holds: $out" has "$out" "acme-widgets"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(pwd)\" --body x"
check "#2981 and so is a title of \$(pwd): $out" refused
check "#2981 saying what it expands: $out" has "$out" '$(pwd)'
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\`pwd\`\" --body x"
check "#2981 and a backquoted pwd: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$( pwd -L )\" --body x"
check "#2981 and pwd -L, spaced: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"seen in \$(basename \$(pwd))\""
check "#2981 and a pwd substitution inside another: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"a=\$(echo ~+)\""
check "#2981 and ~+ inside a substitution, where it is unquoted: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen in \$(pwd)
EOF
)\""
check "#2981 and a pwd substitution in an unquoted heredoc body: $out" refused
RUN_DIR="$WORKCO" run "cd /tmp && gh issue create --repo danwright-test/public-notes --title ~- --body x"
check "#2981 ~- after a cd out of a work checkout is judged by the directory it left: $out" refused
check "#2981 and says the name: $out" has "$out" "acme-widgets"
RUN_DIR="$WORKCO" run "gh repo create danwright-test/fresh --public --description \"from \$(pwd)\""
check "#2981 a public repository described from \$(pwd) is refused: $out" refused
RUN_DIR="$WORKCO" run "gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"see \$(pwd)\""
check "#2981 and a gh api write posting it: $out" refused
# Where the directory cannot be known, refused.
run "gh issue create --repo danwright-test/public-notes --title ~- --body x"
check "#2981 ~- with no cd before it, whose directory this check cannot know, is refused: $out" refused
check "#2981 saying it cannot be told: $out" has "$out" "cannot be told"
run "gh issue create --repo danwright-test/public-notes --title \"\$(pwd | tr a-z A-Z)\" --body x"
check "#2981 a substitution that runs pwd and changes its output is refused: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$(cd .. && pwd)\" --body x"
check "#2981 and so is one that runs pwd somewhere else: $out" refused
# pwd run after a word that runs it in turn prints the directory too (the lessons review of 913e483).
run "gh issue create --repo danwright-test/public-notes --title \"\$(command pwd)\" --body x"
check "#2981 and pwd run through command: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$(builtin pwd) \`env pwd\`\" --body x"
check "#2981 and through builtin or env: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen in \$(echo ~+)
EOF
)\""
check "#2981 and ~+ in a substitution in an unquoted heredoc body: $out" refused
# And pwd written with a backslash or quotes, which the shell runs all the same (the lessons review
# of 5d2a327).
run "gh issue create --repo danwright-test/public-notes --title \"\$(\\pwd)\" --body x"
check "#2981 and pwd behind a backslash: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$('pwd') \$(p\\wd)\" --body x"
check "#2981 and pwd quoted: $out" refused
run "gh issue create --repo danwright-test/public-notes --title ~1 --body x"
check "#2981 and a directory stack entry: $out" refused
# Controls: a clean directory, and text the shell does not expand.
run "gh issue create --repo danwright-test/public-notes --title \"\$(pwd) \`pwd\`\" --body x"
check "#2981 (control) pwd from a directory that names nothing passes: $out" passed
run "gh issue create --repo danwright-test/public-notes --title ~+ --body x"
check "#2981 (control) and so does ~+: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title '~+ \$(pwd) ~-' --body x"
check "#2981 (control) single quoted, from a work checkout, they are text: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"~+ and ~-\" --body x"
check "#2981 (control) and a tilde inside double quotes is not expanded: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x~+ --body x"
check "#2981 (control) nor is one inside a word: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"run pwd to see it\""
check "#2981 (control) the word pwd in text is not a substitution: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<'EOF'
seen in \$(pwd) and \`pwd\`
EOF
)\""
check "#2981 (control) a quoted heredoc body is text: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/private-notes --title \"~+ \$(pwd)\" --body x"
check "#2981 (control) a private repository is not asked about its directory: $out" passed

# ---------------------------------------------------------------- programs a substitution runs (claude-config#2997)
# A substitution running git, or any program this check cannot show prints no directory or remote,
# was judged by its spelling, so "$(git rev-parse --show-toplevel)" or "$(git remote get-url origin)"
# run from a work checkout posted the checkout's path or repository and passed. Each program is judged
# by what it can print: pwd and the git lookups of the checkout by where they run (the directory's
# path, and in a git checkout its git directories, remotes and branch), cat by the files it reads, and
# any program whose output this check cannot read is refused from a work checkout or from where the
# command cannot be placed (the lessons review of e4c7d07, narrowed by #3016), while one a cd or git -C
# takes where this check cannot follow it is refused wherever the command runs. Commands in a sh -c or
# bash -c string and in an unquoted heredoc body are read the same way.
REMOTECO="$WORK/apps/plain-notes"; mkdir -p "$REMOTECO"
git -C "$REMOTECO" init -q
git -C "$REMOTECO" remote add origin https://github.com/Acme-Corp/acme-widgets.git
CLEANGIT="$WORK/apps/garden-notes"; mkdir -p "$CLEANGIT"
git -C "$CLEANGIT" init -q
git -C "$CLEANGIT" remote add origin https://github.com/danwright-test/public-notes.git
BRANCHCO="$WORK/apps/fern-notes"; mkdir -p "$BRANCHCO"
git -C "$BRANCHCO" init -q
git -C "$BRANCHCO" symbolic-ref HEAD refs/heads/fix-acme-widgets
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-prefix)\" --body x"
check "#2997 a substitution running git from a work checkout is refused: $out" refused
check "#2997 and says the name where it runs holds: $out" has "$out" "acme-widgets"
check "#2997 naming the program it runs: $out" has "$out" "git rev-parse --show-prefix"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"at \`git remote -v\`\""
check "#2997 and a backquoted one: $out" refused
RUN_DIR="$REMOTECO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 from a checkout whose path is clean and whose remote is a work repository, the remote lookup: $out" refused
check "#2997 says the name the remote holds, its owner first: $out" has "$out" "acme-corp"
RUN_DIR="$REMOTECO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(git config --get remote.origin.url)\""
check "#2997 and the remote read from git config: $out" refused
RUN_DIR="$REMOTECO" run "gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"see \$(git rev-parse --show-toplevel)\""
check "#2997 and a gh api write posting the top level lookup: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#2997 (control) cat prints only its file, so a clean file passes even from a work checkout: $out" passed
# A program whose output this check cannot read is refused when the command runs from a work checkout
# (the lessons review of e4c7d07, narrowed to work checkouts by Dan on 2026-11-15, #3016): file text
# by another program, commit messages, and a git lookup with other options. A work checkout is one
# whose path or git checkout names a work repository, the same reading a git lookup there is judged
# by. From a directory naming nothing the command posts as it did before #2997, and one the check
# cannot place anywhere stays refused.
printf 'Nothing to see.\n' > "$CO/clean-2997.md"
printf 'Seen first in the zephyr checkout.\n' > "$CO/named-2997.md"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(head -1 clean.md)\""
check "#2997 head of a file is refused from a work checkout: $out" refused
check "#2997 saying its output cannot be told: $out" has "$out" "cannot be told"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(command cat clean.md)\""
check "#2997 and so is cat run through command: $out" refused
RUN_DIR="$REMOTECO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git log -1 --format=%s)\" --body x"
check "#2997 and git log, whose commit messages are not read, from a checkout whose remote is a work repository: $out" refused
check "#2997 as a program whose output this check cannot read: $out" has "$out" "cannot read before the command runs"
RUN_DIR="$BRANCHCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git log -1 --format=%s)\" --body x"
check "#3016 and from one whose branch names a work repository: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(head -1 clean-2997.md)\""
check "#3016 head of a file from a directory naming nothing posts as before #2997: $out" passed
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(command cat clean-2997.md)\""
check "#3016 and so does cat run through command there: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git log -1 --format=%s)\" --body x"
check "#3016 and git log from a checkout whose path, remote and branch name nothing: $out" passed
run "cd \"\$(mktemp -d)\" && gh issue create --repo danwright-test/public-notes --title x --body \"\$(head -1 clean-2997.md)\""
check "#3016 a program run where the check cannot follow the command stays refused: $out" refused
LONG="clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md clean.md"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(cat $LONG) \$(cat $LONG -)\" --body x"
check "#2997 two programs alike for their first 120 characters are each judged: $out" refused
RUN_DIR="$BRANCHCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git branch --show-current)\" --body x"
check "#2997 the branch lookup from a checkout whose branch names a work repository is refused: $out" refused
check "#2997 and says the name: $out" has "$out" "acme-widgets"
# A program is trusted for what it prints only by the name the shell finds it under (the lessons
# review of a45f8c1, the four rounds taken together): the bare word, which nothing in the command
# makes run something else. A path ending in git, a function or alias of the name, a changed PATH or
# hash, git's environment, a sourced file, or a quoted name is a program whose output this check
# cannot read, refused from a work checkout (#3016), and named as that rather than by where it runs.
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(./git rev-parse --show-toplevel)\" --body x"
check "#2997 a program at ./git is not git: $out" refused_unread
check "#2997 refused as a program whose output this check cannot read: $out" has "$out" "cannot read before the command runs"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(/tmp/x/git remote get-url origin)\" --body x"
check "#2997 nor one at any other path ending in git: $out" refused_unread
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$('git' remote -v)\" --body x"
check "#2997 nor a quoted git, which an alias would not reach: $out" refused_unread
RUN_DIR="$WORKCO" run "git() { cat named.md; }; gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#2997 nor git once the command defines a function of that name: $out" refused_unread
RUN_DIR="$WORKCO" run "function git {
  cat named.md
}
gh issue create --repo danwright-test/public-notes --title \"\$(git remote -v)\" --body x"
check "#2997 nor one defined with the function keyword over several lines: $out" refused_unread
RUN_DIR="$WORKCO" run "functions[git]='cat named.md'; gh issue create --repo danwright-test/public-notes --title \"\$(git remote -v)\" --body x"
check "#2997 nor one set in zsh's function table: $out" refused_unread
RUN_DIR="$WORKCO" run "alias git='cat named.md'
gh issue create --repo danwright-test/public-notes --title \"\$(git remote -v)\" --body x"
check "#2997 nor git behind an alias the command defines: $out" refused_unread
RUN_DIR="$WORKCO" run "export PATH=/tmp/x:\$PATH; gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 nor git after the command changes PATH: $out" refused_unread
RUN_DIR="$WORKCO" run "hash -p /tmp/x/git git; gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 nor after it points the shell's hash at another program: $out" refused_unread
RUN_DIR="$WORKCO" run "export GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=url.x.insteadOf GIT_CONFIG_VALUE_0=y; gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 nor after it sets git's configuration in the environment: $out" refused_unread
RUN_DIR="$WORKCO" run ". ./helpers.sh; gh issue create --repo danwright-test/public-notes --title \"\$(git remote -v)\" --body x"
check "#2997 nor after it sources a file, which can define anything: $out" refused_unread
RUN_DIR="$WORKCO" run "eval 'git() { cat named.md; }'; gh issue create --repo danwright-test/public-notes --title \"\$(git remote -v)\" --body x"
check "#2997 nor after a function defined in an eval string: $out" refused_unread
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(sh -c 'git() { cat named.md; }; git remote -v')\" --body x"
check "#2997 nor inside a sh -c string the substitution runs: $out" refused_unread
RUN_DIR="$WORKCO" run "cat() { head -1 \"\$@\"; }; gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#2997 and cat is held to the same rule: $out" refused_unread
# From a work checkout whose path is clean, so the directory itself names nothing.
RUN_DIR="$REMOTECO" run "pwd() { cat named.md; }; gh issue create --repo danwright-test/public-notes --title \"\$(pwd)\" --body x"
check "#2997 and so is pwd: $out" refused_unread
RUN_DIR="$CLEANGIT" run "f() { :; }; GH_TOKEN=x gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#2997 (control) a function of another name and an assignment that changes no lookup leave git as git: $out" passed
RUN_DIR="$WORKCO" run "f() { :; }; GH_TOKEN=x gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#3016 (control) and leave cat as cat in a work checkout, so a clean file passes there: $out" passed
RUN_DIR="$WORKCO" run "f() { :; }; GH_TOKEN=x gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#3016 (control) and git as git there, judged by the name where it runs: $out" has "$out" "acme-widgets"
check "#3016 (control) not as a program whose output cannot be read: $out" lacks "$out" "cannot read before the command runs"
# The checkout and a cat's files are read before the command runs, so from a work checkout the
# reading holds only while nothing else the command runs can change them first (the lessons review of
# 02a97db, narrowed to work checkouts by Dan on 2026-11-15, #3016): a git command other than a lookup,
# a gh command that is not a posting one, a script, or any program not shown to change nothing.
RUN_DIR="$REMOTECO" run "git remote set-url origin https://example.com/garden.git && gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 a remote lookup after the command sets the remote is refused in a work checkout: $out" refused
check "#2997 saying what else it runs can change it: $out" has "$out" "can change"
RUN_DIR="$REMOTECO" run "git checkout -b topic-7 && gh issue create --repo danwright-test/public-notes --title \"\$(git branch --show-current)\" --body x"
check "#2997 and a branch lookup after it makes a branch: $out" has "$out" "can change"
RUN_DIR="$REMOTECO" run "gh pr checkout 5 && gh pr comment 5 --repo danwright-test/public-notes --body \"\$(git branch --show-current)\""
check "#2997 and after a gh command that changes the branch: $out" has "$out" "can change"
RUN_DIR="$REMOTECO" run "./release.sh && gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#2997 and after a script, which can run git: $out" refused
RUN_DIR="$WORKCO" run "printf hello > clean.md; gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#2997 and cat of a file the command writes first: $out" refused
check "#2997 refused as something it runs can change: $out" has "$out" "can change"
RUN_DIR="$WORKCO" run "echo start; cd . && gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\" || true"
check "#2997 (control) echo, a cd and true change nothing a cat reads: $out" passed
# From a checkout whose path, remote and branch name nothing, the same commands post as they did
# before #2997 (#3016): the lookup and the cat are judged as they read now.
RUN_DIR="$CLEANGIT" run "git remote set-url origin https://example.com/garden.git && gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#3016 a remote lookup after setting the remote passes from a checkout naming nothing: $out" passed
RUN_DIR="$CLEANGIT" run "git checkout -b topic-7 && gh issue create --repo danwright-test/public-notes --title \"\$(git branch --show-current)\" --body x"
check "#3016 and a branch lookup after making a branch: $out" passed
RUN_DIR="$CLEANGIT" run "gh pr checkout 5 && gh pr comment 5 --repo danwright-test/public-notes --body \"\$(git branch --show-current)\""
check "#3016 and after checking out a pull request: $out" passed
RUN_DIR="$CLEANGIT" run "./release.sh && gh issue create --repo danwright-test/public-notes --title \"\$(git remote get-url origin)\" --body x"
check "#3016 and after a script: $out" passed
run "printf hello > clean-2997.md; gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean-2997.md)\""
check "#3016 and cat of a file the command writes first: $out" passed
run "printf hello > clean-2997.md; gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat named-2997.md)\""
check "#3016 while cat of a file naming a work repository is still judged by its text there: $out" refused
run "cd \"\$(mktemp -d)\" && ./release.sh && gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean-2997.md)\""
check "#3016 and a command the check cannot place stays refused: $out" refused
RUN_DIR="$CLEANGIT" run "git push -u origin HEAD && gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
a body written here
EOF
)\""
check "#2997 (control) and a push does not stop a heredoc body, which reads nothing: $out" passed
# cat's output is the file's text, which is read and judged wherever it runs (the lessons review of
# 028d7e6): here from a directory whose path names nothing.
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat named-2997.md)\""
check "#2997 cat of a file naming a work repository is refused from a clean directory: $out" refused
check "#2997 and says the name the file holds: $out" has "$out" "zephyr"
# An input redirection alone is read as a program whose output cannot be read, so it is refused from
# a work checkout (#3016) and posts as before #2997 from a directory naming nothing.
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(< clean.md)\""
check "#2997 a file printed by an input redirection alone is refused from a work checkout: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(<clean.md)\""
check "#2997 and by one written without a space: $out" refused
check "#2997 as a program whose output this check cannot read: $out" has "$out" "cannot read before the command runs"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat missing-2997.md)\""
check "#2997 and a file that cannot be read is refused as cannot be told: $out" has "$out" "cannot be told"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat -n)\""
check "#2997 and so is cat given only options, which reads standard input: $out" has "$out" "cannot be told"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean-2997.md)\""
check "#2997 (control) cat of a clean file from a clean directory passes: $out" passed
# Only a regular file of a bounded size is read: a device or a pipe can be read for ever (the lessons
# review of 17059ea), and a file past the bound is refused rather than read in part.
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat /dev/null)\""
check "#2997 cat of something that is not a regular file is refused as cannot be told: $out" has "$out" "cannot be told"
head -c 3000000 /dev/zero | tr '\0' 'a' > "$CO/big-2997.md"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat big-2997.md)\""
check "#2997 and so is a file past the size it reads: $out" has "$out" "cannot be told"
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(echo ../*)\""
check "#2997 and echo of a glob, which the shell fills with file names: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(echo ../*)\""
check "#3016 which posts as before #2997 from a directory naming nothing: $out" passed
# sh -c and bash -c strings, and unquoted heredoc bodies, are read too (the review of #2981).
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(sh -c 'git rev-parse --show-prefix')\" --body x"
check "#2997 git run by sh -c from a work checkout is refused: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(bash -c 'basename \"\$(pwd)\"')\" --body x"
check "#2997 and pwd run by bash -c: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$(sh -c 'cd ..; pwd')\" --body x"
check "#2997 a sh -c string that changes directory is refused wherever it runs: $out" refused
check "#2997 saying it cannot be told: $out" has "$out" "cannot be told"
run "gh issue create --repo danwright-test/public-notes --title \"\$(cd .. && git remote -v)\" --body x"
check "#2997 and git run after a cd in the substitution: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$(cd .. && head -1 x.md)\" --body x"
check "#3016 and a program whose output cannot be read after a cd there, even from a directory naming nothing: $out" refused
run "gh issue create --repo danwright-test/public-notes --title \"\$(git -C .. remote -v)\" --body x"
check "#2997 and git -C: $out" refused
# git's own options in front of the subcommand are read by the shared reader (lib/shell-words.py
# git_read), as every other hook reads them (#3007): a lookup behind one that leaves its output alone
# is still a lookup of the checkout, one that moves it is refused as moved, and -c, which can rewrite
# what the lookup prints, makes it a program like any other.
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git --no-pager rev-parse --show-prefix)\" --body x"
check "#3007 a lookup behind --no-pager from a work checkout is refused: $out" refused
check "#3007 and says the name where it runs holds, read as a lookup of the checkout: $out" has "$out" "acme-widgets"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git --no-pager rev-parse --show-toplevel)\" --body x"
check "#3007 (control) and the same lookup from a checkout naming nothing passes: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git -C .. rev-parse --show-toplevel)\" --body x"
check "#3007 a lookup behind git -C is refused even from a clean checkout: $out" refused
check "#3007 as run where a directory option takes it: $out" has "$out" "directory option"
RUN_DIR="$REMOTECO" run "gh issue create --repo danwright-test/public-notes --title \"\$(git -c url.x.insteadOf=y remote get-url origin)\" --body x"
check "#3007 a lookup behind git -c is refused from a work checkout: $out" refused
check "#3007 as printing what this check cannot read: $out" has "$out" "cannot read before the command runs"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git -c url.x.insteadOf=y remote get-url origin)\" --body x"
check "#3016 and posts as before #2997 from a checkout naming nothing: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen at \$(git remote get-url origin)
EOF
)\""
check "#2997 git in a substitution in an unquoted heredoc body: $out" refused
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen in \$(p\\wd)
EOF
)\""
check "#2997 and pwd written with a backslash there: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
seen in \$(sh -c 'cd ..; pwd')
EOF
)\""
check "#2997 and a sh -c string changing directory there, wherever it runs: $out" refused
# Controls: programs shown to print no directory, a checkout naming nothing, and a cd's directory.
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title \"\$(date +%F) \$(echo hi) \$(printf '%s' ok)\" --body x"
check "#2997 (control) date, echo and printf from a work checkout pass: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<EOF
a body written here
EOF
)\""
check "#2997 (control) and cat of an unquoted heredoc: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body \"\$(git remote get-url origin)\""
check "#2997 (control) git from a checkout whose path and remote name nothing passes: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git branch --show-current) \$(git config --get remote.origin.url) \$(git rev-parse --abbrev-ref HEAD)\" --body x"
check "#2997 (control) and so do the branch and remote lookups there: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(sh -c 'git rev-parse --show-toplevel')\" --body x"
check "#2997 (control) and so does git run by sh -c there: $out" passed
RUN_DIR="$WORKCO" run "cd \"\$(git rev-parse --show-toplevel)\" && gh issue create --repo danwright-test/public-notes --title x --body y"
check "#2997 (control) a substitution naming only where a cd goes is not posted: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/private-notes --title \"\$(git remote -v)\" --body x"
check "#2997 (control) a private repository is not asked about its programs: $out" passed

# ---------------------------------------------------------------- a folder listing (claude-config#3020)
# From a directory naming nothing, a program whose output this check cannot read posts as before
# #2997 (#3016). But a listing prints the names of the folders beside it: "$(ls ~/apps)" run from a
# personal checkout posted every sibling checkout's name, work ones included. So such a program is
# still judged by the folder names it can print: the entries of the directory it runs in, of each
# folder one of its words names, and the names an unquoted glob in it matches.
mkdir -p "$HOMEDIR/apps/acme-widgets" "$HOMEDIR/apps/garden" "$HOMEDIR/garden/ferns" "$HOMEDIR/garden/moss"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls ..)\""
check "#3020 a listing of the folder holding the checkouts, from a personal checkout, is refused: $out" refused
check "#3020 naming the work checkout the listing holds: $out" has "$out" "acme-widgets"
check "#3020 and saying a folder it lists names it: $out" has "$out" "a folder it can list"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls ~/apps)\""
check "#3020 and one of a folder under the home directory, written with a tilde: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls -1 \"\$HOME/apps\")\""
check "#3020 and written through \$HOME: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(find ~/apps -maxdepth 1 -type d)\""
check "#3020 and by any other program handed the folder: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls ~/apps | head -3)\""
check "#3020 and through a pipe: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(echo ~/apps/*)\""
check "#3020 and the names a glob matches there: $out" refused
check "#3020 saying the name it matched: $out" has "$out" "acme-widgets"
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls -d ~/apps/acme*)\""
check "#3020 and a glob matching the work checkout alone: $out" refused
RUN_DIR="$WORK/apps" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls)\""
check "#3020 and a bare listing run from the folder holding the checkouts: $out" refused
run "gh api repos/danwright-test/public-notes/issues/5/comments -f body=\"see \$(ls ~/apps)\""
check "#3020 and a gh api write posting one: $out" refused
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls ~/garden)\""
check "#3020 (control) a listing of a folder whose entries name nothing passes: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls)\""
check "#3020 (control) and a bare listing from a checkout whose entries name nothing: $out" passed
run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(echo ~/garden/*)\""
check "#3020 (control) and a glob matching names that name nothing: $out" passed
run "gh issue create --repo danwright-test/private-notes --title x --body \"\$(ls ~/apps)\""
check "#3020 (control) and a private repository is not asked what a listing holds: $out" passed
RUN_DIR="$WORKCO" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(ls ~/garden)\""
check "#3020 (control) from a work checkout a listing stays refused as output this check cannot read: $out" refused_unread

# ---------------------------------------------------------------- a token for another account (claude-config#3020)
# GH_TOKEN=$(gh auth token -u <account>) gh ..., the way the global rules say to run gh as another
# account without switching the active one, was refused from a work checkout: the substitution was
# read as a program whose output is posted. A token variable set from gh auth token alone sets the
# account the command runs as. It is not posted text, and neither is the account it names.
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 a gh command run as another account from a work checkout passes: $out" passed
RUN_DIR="$WORKCO" run "GH_TOKEN=\"\$(gh auth token --user bob)\" gh issue comment 5 --repo danwright-test/public-notes --body y"
check "#3020 and with the substitution in double quotes and the long option: $out" passed
RUN_DIR="$WORKCO" run "GITHUB_TOKEN=\$(gh auth token --hostname github.com -u bob) gh pr comment 5 --repo danwright-test/public-notes --body y"
check "#3020 and with gh's other token variable and a host: $out" passed
RUN_DIR="$WORKCO" run "export GH_TOKEN=\$(gh auth token -u bob); gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and exported for the commands after it: $out" passed
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u acme-corp) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and the account it names is not posted, so an account named as a work owner passes too: $out" passed
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<'EOF'
nothing to see
EOF
)\""
check "#3020 and beside a heredoc body: $out" passed
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body \"copied from the acme-widgets issue\""
check "#3020 the text it posts is still judged: $out" refused
check "#3020 by the name it holds: $out" has "$out" "acme-widgets"
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title \"\$(gh auth token -u bob)\" --body y"
check "#3020 the same substitution in the posted text is still a program whose output is posted: $out" refused_unread
RUN_DIR="$WORKCO" run "TITLE=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and so is one setting any other variable: $out" refused_unread
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh api user --jq .login) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and a token variable set from any other gh command: $out" refused_unread
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob; cat named.md) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and from more than the one command: $out" refused_unread
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(./gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and from a program at ./gh, which is not gh: $out" refused_unread
RUN_DIR="$WORKCO" run "gh() { cat named.md; }; GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and once the command defines a function named gh: $out" refused_unread
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob)x gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and where the substitution is only part of the value: $out" refused_unread
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title \"\$GH_TOKEN\" --body y"
check "#3020 and the token variable expanded into the posted text is refused: $out" refused

# ---------------------------------------------------------------- the shell profile (claude-config#3020)
# A function or alias from the shell profile reaches every Bash call: Claude Code sources a shell
# snapshot of them in front of each command. The hook is not told which snapshot is its session's
# (measured 2026-11-15: neither the payload nor its environment names one), so every snapshot in the
# folder is read, and a trusted name any of them redefines is refused wherever the command runs.
mkdir -p "$SNAPS"
cat > "$SNAPS/snapshot-zsh-1794000000000-quiet1.sh" <<'SNAP'
# Snapshot file
unalias -a 2>/dev/null || true
# Functions
newshoot () {
	local name="$1"
	git status
}
# Aliases
alias -- claudesync='~/sync/claude-sync pull'
alias -- which-command=whence
unalias find 2>/dev/null || true
function find {
  command find "$@"
}
export PATH=/usr/local/bin:/usr/bin:/bin
SNAP
printf 'nothing to see\n' > "$CLEANGIT/clean.md"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body \"\$(cat clean.md)\""
check "#3020 (control) a snapshot defining other names leaves git and cat as they are: $out" passed
cat > "$SNAPS/snapshot-zsh-1794000000001-gitfn2.sh" <<'SNAP'
# Functions
git () {
	command cat "$HOME/notes/named.md"
}
SNAP
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#3020 git in a substitution is refused once a shell snapshot defines a function of that name: $out" refused
check "#3020 saying the shell profile redefines it: $out" has "$out" "shell profile"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#3020 (control) while cat, which that snapshot leaves alone, still passes: $out" passed
rm -f "$SNAPS/snapshot-zsh-1794000000001-gitfn2.sh"
printf '%s\n' "alias -- cat='head -1'" 'function pwd {' '  echo elsewhere' '}' > "$SNAPS/snapshot-zsh-1794000000002-alias3.sh"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat clean.md)\""
check "#3020 and cat once a snapshot aliases it: $out" refused
check "#3020 with the same reason: $out" has "$out" "shell profile"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(pwd)\" --body x"
check "#3020 and pwd behind the function keyword: $out" refused
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#3020 (control) while git, with its snapshot gone, passes again: $out" passed
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(cat <<'EOF'
nothing to see
EOF
)\""
check "#3020 a heredoc body through the aliased cat is refused too, since the alias decides what prints: $out" refused
rm -f "$SNAPS/snapshot-zsh-1794000000002-alias3.sh"
printf '%s\n' "alias -- gh='gh --repo danwright-test/private-notes'" > "$SNAPS/snapshot-zsh-1794000000003-ghfn4.sh"
RUN_DIR="$WORKCO" run "GH_TOKEN=\$(gh auth token -u bob) gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 and a token read through a gh the profile redefines is not taken as a token: $out" refused
rm -f "$SNAPS/snapshot-zsh-1794000000003-ghfn4.sh"
mkdir "$SNAPS/snapshot-zsh-1794000000004-unread.sh"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#3020 a snapshot that cannot be read leaves no name trusted: $out" refused
check "#3020 and says it could not be read: $out" has "$out" "could not be read"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body \"\$(date +%F)\""
check "#3020 which refuses a program printing its own words as well: $out" refused
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title x --body y"
check "#3020 (control) while a command with no substitution is not asked about the profile: $out" passed
rmdir "$SNAPS/snapshot-zsh-1794000000004-unread.sh"
RUN_DIR="$CLEANGIT" run "gh issue create --repo danwright-test/public-notes --title \"\$(git rev-parse --show-toplevel)\" --body x"
check "#3020 (control) and with it gone git passes again: $out" passed
rm -rf "$SNAPS"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
