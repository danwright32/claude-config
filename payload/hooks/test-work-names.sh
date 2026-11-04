#!/usr/bin/env bash
# The scanner that keeps the work GitHub organisations out of this public repository (claude-config#1568).
#
# The work's private repositories live under two GitHub organisations, and this repository is
# public. Their names were written into 40 tracked files, counted 2026-10-23 (lists the code reads, test
# fixtures, comments, lesson provenance), and each one tells a stranger exactly where to look.
# payload/hooks/lib/work-names.py is the one scanner that finds them, and this suite holds:
#   2. The scanner can see one: an organisation it is told about by hash is found as an owner, in a
#      URL, inside a longer hyphenated name and in any letter case, and a clean tree is clean.
#   3. The registry half: the owner of every repository in a fixture registry is found, a missing
#      registry is said rather than read as empty, and an unreadable one is refused.
#   4. Nothing the scanner prints repeats a name it found (CI logs of a public repository are
#      public too), only where it is.
#   6. Text that is not a file, a commit message or a pull request's title and description, is read
#      by the same rule from a labelled stream (claude-config#1995), and a stream cut short is refused.
#   7. With --work-repos, that text is also judged against the work repository list read live through
#      a fake gh (claude-config#2111): a listed repository or owner is found in plain prose, and a
#      list that cannot be read, or a read past its budget, is refused rather than passed. It also
#      holds the work MacBook's project list and an organisation's web and email domain
#      (claude-config#2184), with an unreadable project list refused.
# The two parts that need the repository, (1) nothing this repository publishes names one and (5) a
# send refuses to publish a file naming one, are tests/test-work-names-tree.sh, since this suite is
# also installed beside the hooks, where there is no repository.
#
# The scanner holds the two organisation names only as sha256 hashes, and this suite tests with an
# invented organisation handed in the same way (WORK_NAMES_EXTRA_HASHES). No work organisation or
# repository name belongs in this file.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SCAN="$HERE/lib/work-names.py"
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

for tool in node python3 shasum; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/work-names.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# An invented organisation, handed to the scanner by hash exactly as the real two are built in.
FAKE_ORG="Acme-HQ"
FAKE_HASH="$(printf '%s' "acme-hq" | shasum -a 256 | cut -d' ' -f1)"
EMPTY_HOME="$WORK/empty-home"; mkdir -p "$EMPTY_HOME"

# ---------------------------------------------------------------- 2. the scanner can see one
T="$WORK/tree"; mkdir -p "$T/sub"
printf 'a clean line about acme/widget#3\n' > "$T/clean.md"
printf 'line one\nsee %s/widget#3 for the story\n' "$FAKE_ORG" > "$T/owner.md"
printf 'url https://github.com/%s/widget/pull/9\n' "$(printf '%s' "$FAKE_ORG" | tr '[:lower:]' '[:upper:]')" > "$T/sub/url.txt"
printf '{"waitOwners": ["studio-%s-partner"]}\n' "$(printf '%s' "$FAKE_ORG" | tr '[:upper:]' '[:lower:]')" > "$T/embedded.json"
printf 'touch "$FAKE/%s_widget"\n' "$FAKE_ORG" > "$T/fixture.sh"
printf 'acmehq and acme hq and acme_hq are other names\n' > "$T/lookalike.md"
printf 'binary\000%s/widget\n' "$FAKE_ORG" > "$T/blob.bin"

scan_tree(){   # $1 = HOME  $2.. = files relative to $T -> output, rc in scan_rc
  local home="$1"; shift
  scan_out="$( cd "$T" && HOME="$home" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --root "$T" "$@" 2>&1 )"; scan_rc=$?
}
scan_tree "$EMPTY_HOME" clean.md lookalike.md
check "(control) a tree with no organisation name is clean (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 0 ]
scan_tree "$EMPTY_HOME" owner.md
check "an organisation as an owner is found (exit $scan_rc)" [ "$scan_rc" -eq 1 ]
check "and named by file and line: $scan_out" has "$scan_out" "owner.md:2"
scan_tree "$EMPTY_HOME" sub/url.txt
check "in a URL, in capitals: $scan_out" has "$scan_out" "sub/url.txt:1"
scan_tree "$EMPTY_HOME" embedded.json
check "inside a longer hyphenated owner: $scan_out" has "$scan_out" "embedded.json:1"
scan_tree "$EMPTY_HOME" fixture.sh
check "before an underscore in a fixture name: $scan_out" has "$scan_out" "fixture.sh:1"
scan_tree "$EMPTY_HOME" blob.bin
check "a binary file is not read as text (exit $scan_rc)" [ "$scan_rc" -eq 0 ]
scan_tree "$EMPTY_HOME" clean.md owner.md sub/url.txt embedded.json fixture.sh lookalike.md
check "every hit in one run is reported, and only those: $scan_out" [ "$(grep -c ': a work organisation' <<<"$scan_out")" -eq 4 ]
# 4. What it prints never repeats what it found, in any case.
check "the output never repeats the name it found: $scan_out" lacks "$(printf '%s' "$scan_out" | tr '[:upper:]' '[:lower:]')" "acme-hq"
# Paths come from a NUL separated list as well as from arguments, which is how this suite feeds it.
nul_out="$( cd "$T" && printf 'owner.md\0clean.md\0' | HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --root "$T" --files0-from - 2>&1 )"; nul_rc=$?
check "a NUL separated list is read too (exit $nul_rc): $nul_out" [ "$nul_rc" -eq 1 ]
# Without the extra hash, the invented organisation is nobody's: the hit above came from the hash.
plain_out="$( cd "$T" && HOME="$EMPTY_HOME" python3 "$SCAN" --root "$T" owner.md 2>&1 )"; plain_rc=$?
check "(control) the invented organisation is found only because the suite named it: $plain_out" [ "$plain_rc" -eq 0 ]
# A file the list names that is not there is a fault in the list, never a clean file (L98).
scan_tree "$EMPTY_HOME" clean.md missing.md
check "a listed file that cannot be read is refused (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 2 ]

# ---------------------------------------------------------------- 3. the registry half
check "with no registry the scan says only the built in names were checked: $plain_out" has "$plain_out" "no dev update registry"
check "and names where it looked" has "$plain_out" "$EMPTY_HOME/.claude/skills/pennie-dev-update/repos.local.json"
RH="$WORK/registry-home"; mkdir -p "$RH/.claude/skills/pennie-dev-update"
printf '{"repos":[{"name":"Widget","repo":"Globex-Work/widget","account":"globex-bot"}]}\n' > "$RH/.claude/skills/pennie-dev-update/repos.local.json"
printf 'the board lives in globex-work/widget\n' > "$T/registry.md"
scan_tree "$RH" clean.md registry.md
check "the owner of a repository in this Mac's registry is found (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 1 ]
check "and the hit says it came from the registry: $scan_out" has "$scan_out" "registry.md:1: a name from this Mac's dev update registry"
check "and never repeats it: $scan_out" lacks "$(printf '%s' "$scan_out" | tr '[:upper:]' '[:lower:]')" "globex-work"
check "and the summary says the registry was read" has "$scan_out" "1 owner from"
scan_tree "$EMPTY_HOME" registry.md
check "(control) without the registry the same file is clean (exit $scan_rc)" [ "$scan_rc" -eq 0 ]
# The coverage check the real registry is held to below can fail: an owner no built in hash covers.
unc_out="$(HOME="$RH" python3 "$SCAN" --uncovered-owners 2>&1)"; unc_rc=$?
check "(control) a registry owner the built in names do not cover is reported (exit $unc_rc): $unc_out" [ "$unc_rc" -eq 1 ]
check "and the report never repeats it" lacks "$unc_out" "globex"
printf '{ not json\n' > "$RH/.claude/skills/pennie-dev-update/repos.local.json"
scan_tree "$RH" clean.md
check "an unreadable registry is refused, never read as empty (exit $scan_rc): $scan_out" [ "$scan_rc" -eq 2 ]
check "and says why" has "$scan_out" "not valid JSON"

# ---------------------------------------------------------------- 6. text that is not a file
# A commit message or a pull request's title and description reaches main in a squash merge without
# ever being a file (claude-config#1995), so the same scanner reads labelled text too: a NUL
# separated stream of label, text, label, text, which `git log -z --format='commit %h%x00%B'`
# writes as it stands. A hit is the label and line, never the text.
# The stream is printf's arguments, piped to the scanner inside the substitution: its exit status is
# the scanner's (printf cannot fail here), and no process substitution is left for bash 3.2 never to
# wait for, whose exit can cut short a line this suite prints (L1035, #1989). A NUL cannot be held in
# a variable, so a here document is no use for this stream.
texts(){   # printf format and arguments making the stream -> output, rc in text_rc
  text_out="$( printf "$@" | HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" python3 "$SCAN" --texts0-from - 2>&1 )"; text_rc=$?
}
texts 'commit 1a2b3c4\0Fix the reader\n\nrefs widget#3\n\0commit 5d6e7f8\0Quote the refusal\n\nseen in %s/widget#4\n' "$FAKE_ORG"
check "a name in a commit message is found (exit $text_rc): $text_out" [ "$text_rc" -eq 1 ]
check "and named by its label and line: $text_out" has "$text_out" "commit 5d6e7f8:3: a work organisation name"
check "and only that one: $text_out" lacks "$text_out" "commit 1a2b3c4:"
check "the summary counts messages, not files: $text_out" has "$text_out" "checked 2 messages"
check "and carries the file check's own remedy: $text_out" has "$text_out" "write name#123, never owner/name#123"
check "the output never repeats the name it found: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "acme-hq"
texts 'title\0Add the %s reader\0description\0\0' "$(printf '%s' "$FAKE_ORG" | tr '[:upper:]' '[:lower:]')"
check "a title is found, and an empty description is a text, not a gap: $text_out" has "$text_out" "title:1: a work organisation name"
texts 'commit 1a2b3c4\0Fix the reader\n\nrefs widget#3\n'
check "(control) a clean message passes (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
texts 'commit 1a2b3c4\0Fix the reader\0commit 5d6e7f8'
check "a label with no text is a stream that cannot be read, never a clean one (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
check "and says so: $text_out" has "$text_out" "label with no text"

# ---------------------------------------------------------------- 7. work repositories, in messages
# A squash merge copies every commit message into main, so a message naming a work REPOSITORY is
# published as surely as one naming its organisation (claude-config#2111). With --work-repos the text
# scan also reads the work repository list, live through gh as the publish gate reads it (#2105), and
# refuses when it cannot. The file scan never takes it (#1568 left repository names out of files).
# gh is a fake answering only the list, from $FAKE_LIST; every name is invented.
GHBIN="$WORK/ghbin"; mkdir -p "$GHBIN"
cat > "$GHBIN/gh" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *contents/repos.json*)
    [ -n "${FAKE_GH_HANG:-}" ] && exec sleep 30
    [ -f "$FAKE_LIST" ] || { echo "HTTP 404: Not Found" >&2; exit 1; }
    cat "$FAKE_LIST"; exit 0 ;;
  "auth status"*) printf '{"hosts":{"github.com":[]}}\n'; exit 0 ;;
esac
echo "fake gh: unexpected call: $*" >&2
exit 1
SH
chmod +x "$GHBIN/gh"
LIST="$WORK/list.json"
printf '{"repos":[{"owner":"Globex-Corp","name":"halcyon"},{"owner":"Globex-Corp","name":"zephyr-app"},{"owner":"Globex-Corp","name":"globex.site"}]}\n' > "$LIST"
# The work MacBook's project list (claude-config#2184), one invented project on it.
PROJECTS="$WORK/projects-CLAUDE.md"
printf '## Projects\n\nOn Daniels-MacBook-Pro-2 (personal MacBook):\n- `~/Apps/home-garden`\n\nOn Dans-MacBook-Pro:\n- `~/Apps/Quillfeather`: a work app\n\n## Writing Style\n' > "$PROJECTS"
repo_texts(){   # printf format and arguments making the stream -> output, rc in text_rc
  text_out="$( printf "$@" | PATH="$GHBIN:$PATH" FAKE_LIST="$LIST" HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" \
    WORK_NAMES_PROJECT_LIST="$PROJECTS" HOOK_TESTS_RUNNING=1 WORK_NAMES_PROJECT_HASHES="" \
    python3 "$SCAN" --texts0-from - --work-repos 2>&1 )"; text_rc=$?
}
STREAM_REPO='commit 1a2b3c4\0Fix the reader\n\nrefs widget#3\n\0commit 5d6e7f8\0Quote the refusal\n\nfrom the Halcyon#12 checkout\n'
repo_texts "$STREAM_REPO"
check "a listed work repository in a commit message is found (exit $text_rc): $text_out" [ "$text_rc" -eq 1 ]
check "and named by its label and line: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
check "and only that one: $text_out" lacks "$text_out" "commit 1a2b3c4:"
check "the output never repeats the repository it found: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "halcyon"
check "the remedy says how to write it instead: $text_out" has "$text_out" "a work repository"
check "the summary says the list was read, by count only: $text_out" has "$text_out" "5 work repository and owner names"
texts "$STREAM_REPO"
check "(control) without --work-repos the same messages pass, so the hit came from the list (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
repo_texts 'commit 5d6e7f8\0Move it\n\nto globex-corp/thing\n'
check "a listed owner is found: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
repo_texts 'commit 5d6e7f8\0Move it\n\nthe zephyr-app-extra fork\n'
check "a listed hyphenated name inside a longer one is found: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
repo_texts 'commit 5d6e7f8\0Move it\n\nline two\nsee globex.site for it\n'
check "a listed name that is not one plain token is found by its line: $text_out" has "$text_out" "commit 5d6e7f8:4: a work repository or owner name"
check "and never repeated: $text_out" lacks "$text_out" "globex.site"
repo_texts 'commit 5d6e7f8\0Move it\n\na halcyonic day, and prehalcyon too\n'
check "(control) a listed name inside a longer word is no match (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
repo_texts 'commit 5d6e7f8\0Move it\n\nfrom %s/widget\n' "$FAKE_ORG"
check "an organisation is still found with the list read: $text_out" has "$text_out" "commit 5d6e7f8:3: a work organisation name"
# claude-config#2184: the work MacBook's project list, and an organisation's web and email domain.
repo_texts 'commit 5d6e7f8\0Move it\n\nfrom the QuillFeather checkout\n'
check "a project on the work MacBook's list is found: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
check "and never repeated: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "quillfeather"
repo_texts 'commit 5d6e7f8\0Move it\n\nfrom the home-garden checkout\n'
check "(control) a project on the personal MacBook's list passes (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
repo_texts 'commit 5d6e7f8\0Move it\n\nline two\nask ops@acmehq.com, or see acmehq.io\n'
check "an organisation without its hyphen as an email or web domain is found by its line: $text_out" has "$text_out" "commit 5d6e7f8:4: a work organisation's web or email domain"
check "and never repeated: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "acmehq"
repo_texts 'commit 5d6e7f8\0Move it\n\nthe acmehq notes, and acmehqs.com\n'
check "(control) the same letters as a bare word or another domain pass (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
mv "$PROJECTS" "$PROJECTS.away"
repo_texts 'commit 1a2b3c4\0clean\n'
check "an unreadable project list is refused, never read as clean (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
check "and says the project list could not be read: $text_out" has "$text_out" "project list"
mv "$PROJECTS.away" "$PROJECTS"
# claude-config#2112: the work MacBook's block lists no project in the public CLAUDE.md. It imports
# that Mac's own projects.local.txt inside a sentence instead, and the names are matched through a
# committed set of hashes (WORK_PROJECTS in work-names.py, built as BUILT_IN is), with the local
# file an extra source where it exists. WORK_NAMES_PROJECT_HASHES replaces the committed set, and is
# honoured only under HOOK_TESTS_RUNNING=1. Every name here is invented.
LOCALDIR="$WORK/local-list"; mkdir -p "$LOCALDIR"
PROJECTS_LOCAL="$LOCALDIR/CLAUDE.md"
printf '## Projects\n\nOn Daniels-MacBook-Pro-2 (personal MacBook):\n- `~/Apps/home-garden`\n\nOn Dans-MacBook-Pro:\n- Its projects are kept in that Mac'"'"'s own @projects.local.txt instead, which the sync never carries.\n\n## Writing Style\n' > "$PROJECTS_LOCAL"
INKWELL_HASH="$(printf '%s' "inkwellcove" | shasum -a 256 | cut -d' ' -f1)"
OTHER_HASH="$(printf '%s' "nothing-named-this" | shasum -a 256 | cut -d' ' -f1)"
local_texts(){   # <hashes or "unset"> <printf format and arguments> -> text_out, text_rc
  local h="$1"; shift
  if [ "$h" = unset ]; then
    text_out="$( printf "$@" | PATH="$GHBIN:$PATH" FAKE_LIST="$LIST" HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" \
      WORK_NAMES_PROJECT_LIST="$PROJECTS_LOCAL" HOOK_TESTS_RUNNING=0 WORK_NAMES_PROJECT_HASHES="" \
      python3 "$SCAN" --texts0-from - --work-repos 2>&1 )"; text_rc=$?
  else
    text_out="$( printf "$@" | PATH="$GHBIN:$PATH" FAKE_LIST="$LIST" HOME="$EMPTY_HOME" WORK_NAMES_EXTRA_HASHES="$FAKE_HASH" \
      WORK_NAMES_PROJECT_LIST="$PROJECTS_LOCAL" HOOK_TESTS_RUNNING=1 WORK_NAMES_PROJECT_HASHES="$h" \
      python3 "$SCAN" --texts0-from - --work-repos 2>&1 )"; text_rc=$?
  fi
}
INKWELL_TEXT='commit 5d6e7f8\0Move it\n\nfrom the InkwellCove checkout\n'
local_texts "$INKWELL_HASH" "$INKWELL_TEXT"
check "#2112 a hashed project is found with no entry in the block and no local file (exit $text_rc): $text_out" [ "$text_rc" -eq 1 ]
check "and named as a work repository by its line: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
check "and never repeated: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "inkwellcove"
local_texts "$INKWELL_HASH" 'commit 5d6e7f8\0Move it\n\nthe inkwellcove-tools fork\n'
check "#2112 a hashed project inside a hyphenated name is found, as a listed one is: $text_out" has "$text_out" "commit 5d6e7f8:3: a work repository or owner name"
local_texts "$OTHER_HASH" "$INKWELL_TEXT"
check "#2112 (control) with that hash absent the same text passes, so the hit came from the hash (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
local_texts "" 'commit 1a2b3c4\0clean\n'
check "#2112 no hash and no local file is refused, never read as clean (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
check "and says the project list lists no project: $text_out" has "$text_out" "lists no project"
printf -- '- `~/Apps/Lanternwick`: a work app\n' > "$LOCALDIR/projects.local.txt"
local_texts "" 'commit 5d6e7f8\0Move it\n\nfrom the Lanternwick checkout\n'
check "#2112 a project in the local file beside the CLAUDE.md is found with no hash (exit $text_rc): $text_out" [ "$text_rc" -eq 1 ]
check "and never repeated: $text_out" lacks "$(printf '%s' "$text_out" | tr '[:upper:]' '[:lower:]')" "lanternwick"
printf 'nothing listed\n' > "$LOCALDIR/projects.local.txt"
local_texts "" 'commit 1a2b3c4\0clean\n'
check "#2112 a local file listing nothing, with no hash, is refused (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
rm -f "$LOCALDIR/projects.local.txt"
local_texts unset 'commit 1a2b3c4\0clean\n'
check "#2112 outside a test run the seam is ignored and the committed hashes make the list readable (exit $text_rc): $text_out" [ "$text_rc" -eq 0 ]
check "and the five committed hashes are counted beside the list's four names: $text_out" has "$text_out" "9 work repository and owner names"
# Cannot tell is refused, never passed (L98, L345).
rm -f "$LIST"
repo_texts "$STREAM_REPO"
check "an unreadable list is refused, never read as clean (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
check "and says what could not be read: $text_out" has "$text_out" "work repository list"
printf '{"repos":[]}\n' > "$LIST"
repo_texts 'commit 1a2b3c4\0clean\n'
check "an empty list is refused (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
printf '{"repos":[{"owner":"Globex-Corp"}]}\n' > "$LIST"
repo_texts 'commit 1a2b3c4\0clean\n'
check "a list of the wrong shape is refused (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
printf '{"repos":[{"owner":"Globex-Corp","name":"halcyon"}]}\n' > "$LIST"
t0=$SECONDS
text_out="$( printf 'commit 1a2b3c4\0clean\n' | PATH="$GHBIN:$PATH" FAKE_LIST="$LIST" FAKE_GH_HANG=1 HOME="$EMPTY_HOME" WORK_NAMES_PROJECT_LIST="$PROJECTS" \
  WORK_NAMES_REPOS_BUDGET_SECONDS=3 python3 "$SCAN" --texts0-from - --work-repos 2>&1 )"; text_rc=$?
check "a list that does not answer inside the budget is refused (exit $text_rc): $text_out" [ "$text_rc" -eq 2 ]
check "and the scan stops at its budget, not at gh's own wait ($((SECONDS - t0)) seconds)" [ $((SECONDS - t0)) -lt 15 ]
file_out="$( cd "$T" && PATH="$GHBIN:$PATH" FAKE_LIST="$LIST" HOME="$EMPTY_HOME" python3 "$SCAN" --root "$T" --work-repos clean.md 2>&1 )"; file_rc=$?
check "the file scan never takes the list (exit $file_rc): $file_out" [ "$file_rc" -eq 2 ]
check "and says it is for text only: $file_out" has "$file_out" "only with --texts0-from"

# The two built in hashes cover every owner in the registry on a Mac that has one, so the check CI
# runs (with no registry) is the same check for the organisations that matter. Only measurable where
# a registry is, and said plainly where it is not, never failed for it (L411).
cover_out="$(python3 "$SCAN" --uncovered-owners 2>&1)"; cover_rc=$?
case "$cover_out" in
  *"no dev update registry"*) echo "note: this machine has no dev update registry, so whether the built in names cover its owners was not measured here." ;;
  *) check "every owner in this Mac's registry is one the built in names cover (exit $cover_rc): $cover_out" [ "$cover_rc" -eq 0 ] ;;
esac

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
