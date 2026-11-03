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

run(){   # $1 = the command; output in out, exit code in rc, the decision in decision
  local payload
  payload="$(jq -nc --arg c "$1" --arg d "$CO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
  : > "$CALLS"
  out="$(cd "$CO" && printf '%s' "$payload" | PATH="$BIN:$PATH" HOME="$HOMEDIR" FAKE_CALLS="$CALLS" FAKE_LIST="$LIST" \
    FAKE_VIS="$VIS" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" bash "$GATE" 2>&1)"; rc=$?
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
check "a command that is not gh passes silently" [ "$rc" -eq 0 ] && [ -z "$out" ]
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
run 'gh api repos/danwright-test/private-notes/issues/5/comments -f body="zephyr"'
check "(control) a gh api write to a private repository passes: $out" passed
run 'gh api repos/danwright-test/public-notes/issues/5/comments'
check "(control) a gh api read passes: $out" passed
run 'gh api repos/danwright-test/public-notes/issues/5/comments -f body="nothing to see"'
check "(control) a clean gh api write passes: $out" passed

# ---------------------------------------------------------------- 7. a gate that fails refuses
BROKEN="$WORK/broken"; mkdir -p "$BROKEN"
printf '#!/usr/bin/env bash\nexit 3\n' > "$BROKEN/python3"; chmod +x "$BROKEN/python3"
payload="$(jq -nc --arg c 'gh pr create --repo danwright-test/public-notes --title Tidy --body ok' --arg d "$CO" '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')"
out="$(printf '%s' "$payload" | PATH="$BROKEN:$BIN:$PATH" bash "$GATE" 2>&1)"; rc=$?
check "a gate that crashes refuses the command rather than passing it: rc=$rc $out" [ "$rc" -eq 2 ]
check "and says it could not check: $out" has "$out" "could not be checked"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
