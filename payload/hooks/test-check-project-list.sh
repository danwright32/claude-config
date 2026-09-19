#!/usr/bin/env bash
# Tests for check-project-list.sh, which reads the Projects section of the synced CLAUDE.md and
# fails when a path listed for THIS Mac is not there (claude-config#122).
#
# The section named four projects by absolute path and not one of them existed on this machine.
# That file loads at the start of every session on both Macs, so it was read constantly and was
# wrong on at least one of them, and tracing it cost a search of the whole home directory before it
# became clear they were simply elsewhere. It is the shape L153 warns about, a path recording where
# something happened to be rather than what it is, made worse by one file being shared between two
# machines whose contents differ.
#
# A list kept by hand beside the thing it describes drifts (L41), and the only cheap way to stop
# that here is to check it. So the checks below care about three things: that a missing path is
# REPORTED rather than passed over, that a machine the list says nothing about is a distinct and
# stated outcome rather than a quiet pass (L98, L11), and that a section holding nothing at all is
# refused rather than read as a clean inventory.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-project-list.sh"

pass=0
fail=0
check() { # check <description> <result>   ("ok" passes, anything else is the failure text)
  if [[ "$2" == "ok" ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $1 ($2)"
  fi
}

TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/claude-sync-work.projlist.XXXXXXXX")" || TMPROOT=""
case "${TMPROOT%/}" in
  ''|/|"${HOME%/}") echo "test-check-project-list: refusing to run: throwaway directory came back as '$TMPROOT'." >&2; exit 2 ;;
esac
trap 'rm -rf "$TMPROOT"' EXIT

mkfile() { # mkfile <name> <body>  -> prints the path
  local f="$TMPROOT/$1"
  printf '%s\n' "$2" > "$f"
  printf '%s' "$f"
}
run() { # run <file> <host>
  PROJECT_LIST_FILE="$1" PROJECT_LIST_HOST="$2" bash "$CHECK" 2>&1
}

mkdir -p "$TMPROOT/here/AppOne" "$TMPROOT/here/AppTwo"
# Each fixture project carries its own instructions file, WITH CONTENT IN IT, because the check
# asks three questions of every entry and a test about the PATH must not fail for either of the
# others. An empty file was enough here until claude-config#496 made emptiness its own finding.
printf '# fixture instructions\n' > "$TMPROOT/here/AppOne/CLAUDE.md"
printf '# fixture instructions\n' > "$TMPROOT/here/AppTwo/CLAUDE.md"

GOOD="$(mkfile good.md "## Projects

On MacOne:
- \`$TMPROOT/here/AppOne\`: something
- \`$TMPROOT/here/AppTwo\`

On MacTwo:
- \`$TMPROOT/nowhere/AppThree\`

## Writing Style")"

# ---------------------------------------------------------------------------
# The ordinary case, and the control that matters: the OTHER Mac's entry is deliberately a path
# that does not exist here, so a check reading the whole section rather than this machine's block
# would fail, and passing proves it read the right block.
# ---------------------------------------------------------------------------
out_ok="$(run "$GOOD" MacOne)"; code_ok=$?
[ "$code_ok" -eq 0 ] \
  && check "a list whose paths are all present passes" ok \
  || check "a list whose paths are all present passes" "exit=$code_ok out=$out_ok"
grep -q '2' <<< "$out_ok" \
  && check "and says how many it checked" ok \
  || check "and says how many it checked" "out=$out_ok"
grep -q 'AppThree' <<< "$out_ok" \
  && check "the other Mac's entries are not checked here" "it complained about AppThree" \
  || check "the other Mac's entries are not checked here" ok

# ---------------------------------------------------------------------------
# A path that is not there. This is the whole point, and it is watched failing before anything
# below is trusted (L1).
# ---------------------------------------------------------------------------
BAD="$(mkfile bad.md "## Projects

On MacOne:
- \`$TMPROOT/here/AppOne\`
- \`$TMPROOT/here/Vanished\`

## Writing Style")"
out_bad="$(run "$BAD" MacOne)"; code_bad=$?
[ "$code_bad" -eq 1 ] \
  && check "a path that is not there fails the check" ok \
  || check "a path that is not there fails the check" "exit=$code_bad out=$out_bad"
grep -q 'Vanished' <<< "$out_bad" \
  && check "and names the one it could not find" ok \
  || check "and names the one it could not find" "out=$out_bad"
grep -q 'AppOne' <<< "$out_bad" \
  && check "and does not accuse the ones it did find" "it named AppOne too" \
  || check "and does not accuse the ones it did find" ok

# ---------------------------------------------------------------------------
# A machine the list says nothing about: the CI runner, or a third Mac. Passing is right, saying
# so is what stops it being read as a clean inventory of a machine nobody listed (L11, L98).
# ---------------------------------------------------------------------------
out_other="$(run "$GOOD" SomeRunner)"; code_other=$?
[ "$code_other" -eq 0 ] \
  && check "a machine the list does not mention is not a failure" ok \
  || check "a machine the list does not mention is not a failure" "exit=$code_other out=$out_other"
grep -qi 'no entries for' <<< "$out_other" \
  && check "but it says it checked nothing rather than reporting a clean list" ok \
  || check "but it says it checked nothing rather than reporting a clean list" "out=$out_other"

# ---------------------------------------------------------------------------
# Ways of reading nothing, each its own outcome. A section that has gone missing and one that is
# present but empty are different faults and must not share an answer (L11).
# ---------------------------------------------------------------------------
NOSEC="$(mkfile nosec.md "## Writing Style

- no dashes")"
out_nosec="$(run "$NOSEC" MacOne)"; code_nosec=$?
[ "$code_nosec" -eq 2 ] \
  && check "a file with no Projects section is refused" ok \
  || check "a file with no Projects section is refused" "exit=$code_nosec out=$out_nosec"

EMPTYSEC="$(mkfile emptysec.md "## Projects

## Writing Style")"
out_empty="$(run "$EMPTYSEC" MacOne)"; code_empty=$?
[ "$code_empty" -eq 2 ] \
  && check "a Projects section listing no machine at all is refused too" ok \
  || check "a Projects section listing no machine at all is refused too" "exit=$code_empty out=$out_empty"
[ "$out_nosec" != "$out_empty" ] \
  && check "and the two refusals do not say the same thing" ok \
  || check "and the two refusals do not say the same thing" "both said: $out_nosec"

out_missing="$(PROJECT_LIST_FILE="$TMPROOT/not-here.md" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_missing=$?
[ "$code_missing" -eq 2 ] \
  && check "a file that does not exist is refused" ok \
  || check "a file that does not exist is refused" "exit=$code_missing out=$out_missing"

# ---------------------------------------------------------------------------
# A tilde is how these paths are written, because a real home directory in a synced file is wrong
# on every other Mac and is refused by check-home-paths.sh. So it has to be expanded.
# ---------------------------------------------------------------------------
# HOME is SET here rather than read, so the assertion is about the expansion and not about what the
# real home directory happens to contain on the machine running this (L411, L504).
mkdir -p "$TMPROOT/fakehome"
printf '# fixture instructions\n' > "$TMPROOT/fakehome/CLAUDE.md"
TILDE="$(mkfile tilde.md "## Projects

On MacOne:
- \`~\`: the home directory, which this test supplies

## Writing Style")"
out_tilde="$(HOME="$TMPROOT/fakehome" PROJECT_LIST_FILE="$TILDE" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_tilde=$?
[ "$code_tilde" -eq 0 ] \
  && check "a path written with a tilde is expanded, not taken literally" ok \
  || check "a path written with a tilde is expanded, not taken literally" "exit=$code_tilde out=$out_tilde"

# And the failure it guards against, watched: with the tilde unexpanded there is no such directory,
# which is the missing path outcome rather than this one.
out_tilde_lit="$(HOME="$TMPROOT/nowhere-at-all" PROJECT_LIST_FILE="$TILDE" PROJECT_LIST_HOST=MacOne bash "$CHECK" 2>&1)"; code_tilde_lit=$?
[ "$code_tilde_lit" -eq 1 ] \
  && check "and a tilde pointing nowhere is reported as a missing path" ok \
  || check "and a tilde pointing nowhere is reported as a missing path" "exit=$code_tilde_lit out=$out_tilde_lit"

# ---------------------------------------------------------------------------
# A listed project carrying no instructions file of its own. The Projects section exists so that a
# session started in one of these repositories reads that repository's own context, and a project
# with neither CLAUDE.md nor AGENTS.md gets whatever sits ABOVE it instead: on 2026-09-19 that was
# a stray Vercel best practices file in the home directory, loaded as project instructions into a
# Swift app and a bash tool. The path being present says nothing about that, so it is its own
# question with its own exit code (L11).
#
# AGENTS.md counts, because the predicate has to be the one Claude Code itself uses when it decides
# what to load, not a stricter one of our own (L144). NurseDex carries an AGENTS.md and no
# CLAUDE.md, and it is correctly provided for.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/here/WithClaude" "$TMPROOT/here/WithAgents" "$TMPROOT/here/Bare"
printf '# fixture instructions\n' > "$TMPROOT/here/WithClaude/CLAUDE.md"
printf '# fixture instructions\n' > "$TMPROOT/here/WithAgents/AGENTS.md"

NOFILE="$(mkfile nofile.md "## Projects

On MacOne:
- \`$TMPROOT/here/WithClaude\`
- \`$TMPROOT/here/Bare\`

## Writing Style")"
out_nofile="$(run "$NOFILE" MacOne)"; code_nofile=$?
[ "$code_nofile" -eq 3 ] \
  && check "a listed project with no instructions file of its own is reported" ok \
  || check "a listed project with no instructions file of its own is reported" "exit=$code_nofile out=$out_nofile"
grep -q 'Bare' <<< "$out_nofile" \
  && check "and names the one that carries nothing" ok \
  || check "and names the one that carries nothing" "out=$out_nofile"
grep -q 'WithClaude' <<< "$out_nofile" \
  && check "and does not accuse the one that carries a CLAUDE.md" "it named WithClaude too" \
  || check "and does not accuse the one that carries a CLAUDE.md" ok

AGENTSOK="$(mkfile agentsok.md "## Projects

On MacOne:
- \`$TMPROOT/here/WithAgents\`

## Writing Style")"
out_agents="$(run "$AGENTSOK" MacOne)"; code_agents=$?
[ "$code_agents" -eq 0 ] \
  && check "an AGENTS.md is a project's own instructions too, which is what Claude Code loads" ok \
  || check "an AGENTS.md is a project's own instructions too, which is what Claude Code loads" "exit=$code_agents out=$out_agents"

# A path that is not there and a path with no instructions file, in one list. The missing path wins
# and says so: there is no useful answer to "what does that directory contain" when the directory
# is not there, and reporting the weaker fault would send somebody looking for the wrong thing.
BOTH="$(mkfile both.md "## Projects

On MacOne:
- \`$TMPROOT/here/Bare\`
- \`$TMPROOT/here/Vanished\`

## Writing Style")"
out_both="$(run "$BOTH" MacOne)"; code_both=$?
[ "$code_both" -eq 1 ] \
  && check "a missing path outranks a missing instructions file" ok \
  || check "a missing path outranks a missing instructions file" "exit=$code_both out=$out_both"
grep -q 'Vanished' <<< "$out_both" \
  && check "and the message is the one about the path" ok \
  || check "and the message is the one about the path" "out=$out_both"

[ "$code_nofile" != "$code_bad" ] \
  && check "the two faults do not share an exit code" ok \
  || check "the two faults do not share an exit code" "both exited $code_bad"

# ---------------------------------------------------------------------------
# A checkout with no instructions file in its working tree, whose repository's DEFAULT branch
# carries one. This is the common case on a Mac where sessions work in feature branches, and it is
# not the same fault as a project that has never had a file: the remedy is to merge, not to write
# one. Sending the reader to write a file that already exists is a notice naming an action that
# does not change the state they are stuck in (L111), and this one speaks in every session until it
# is cleared, which is exactly the kind that gets skimmed.
#
# Measured on 2026-09-19: PostRoll was reported bare while its CLAUDE.md sat on origin/main,
# because the checkout was standing on another session own branch.
#
# Both routes to the default branch are exercised, because the real case uses the first and a
# fixture with no remote uses the second: origin/HEAD when the repository has a remote, and a local
# main or master when it does not.
# ---------------------------------------------------------------------------
git_fixture() { # git_fixture <dir> <file-on-default-branch>  -> a repo whose checkout lacks it
  local d="$TMPROOT/here/$1" f="$2"
  mkdir -p "$d"
  git -C "$d" init -q -b main >/dev/null 2>&1 || return 1
  git -C "$d" config user.email tests@example.invalid
  git -C "$d" config user.name "project list tests"
  printf '# instructions\n' > "$d/$f"
  git -C "$d" add "$f" >/dev/null 2>&1
  git -C "$d" commit -qm "add $f" >/dev/null 2>&1 || return 1
  git -C "$d" checkout -q -b older-work >/dev/null 2>&1 || return 1
  git -C "$d" rm -q "$f" >/dev/null 2>&1 || return 1
  git -C "$d" commit -qm "a branch that predates $f" >/dev/null 2>&1 || return 1
  [ -f "$d/$f" ] && return 1
  return 0
}

git_fixture OnMainOnly CLAUDE.md \
  && check "the fixture for a branch predating its instructions file could be built" ok \
  || check "the fixture for a branch predating its instructions file could be built" "git refused"

PREDATES="$(mkfile predates.md "## Projects

On MacOne:
- \`$TMPROOT/here/OnMainOnly\`

## Writing Style")"
out_pre="$(run "$PREDATES" MacOne)"; code_pre=$?
[ "$code_pre" -eq 5 ] \
  && check "a checkout whose default branch has the file is its own outcome" ok \
  || check "a checkout whose default branch has the file is its own outcome" "exit=$code_pre out=$out_pre"
[ "$code_pre" != "$code_nofile" ] \
  && check "and does not share an exit code with a project that has no file anywhere" ok \
  || check "and does not share an exit code with a project that has no file anywhere" "both exited $code_pre"
grep -q 'main' <<< "$out_pre" \
  && check "and names the branch the file is on" ok \
  || check "and names the branch the file is on" "out=$out_pre"
grep -q 'older-work' <<< "$out_pre" \
  && check "and names the branch the checkout is standing on" ok \
  || check "and names the branch the checkout is standing on" "out=$out_pre"
grep -qi 'write one at the root' <<< "$out_pre" \
  && check "and does not send the reader to write a file that already exists" "it told them to write one" \
  || check "and does not send the reader to write a file that already exists" ok

# The same question asked through a remote, which is the route the real case takes: PostRoll has an
# origin and its default branch is named by refs/remotes/origin/HEAD. The ref is made locally
# rather than by cloning, so the fixture costs no network and no second copy of the tree (L299).
git_fixture ViaOrigin AGENTS.md \
  && check "the fixture for a default branch reached through origin could be built" ok \
  || check "the fixture for a default branch reached through origin could be built" "git refused"
git -C "$TMPROOT/here/ViaOrigin" update-ref refs/remotes/origin/main refs/heads/main 2>/dev/null
git -C "$TMPROOT/here/ViaOrigin" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main 2>/dev/null
git -C "$TMPROOT/here/ViaOrigin" branch -q -D main 2>/dev/null

VIAORIGIN="$(mkfile viaorigin.md "## Projects

On MacOne:
- \`$TMPROOT/here/ViaOrigin\`

## Writing Style")"
out_origin="$(run "$VIAORIGIN" MacOne)"; code_origin=$?
[ "$code_origin" -eq 5 ] \
  && check "the default branch is found through origin/HEAD when there is a remote" ok \
  || check "the default branch is found through origin/HEAD when there is a remote" "exit=$code_origin out=$out_origin"
grep -q 'AGENTS.md' <<< "$out_origin" \
  && check "and an AGENTS.md on the default branch counts the same as a CLAUDE.md" ok \
  || check "and an AGENTS.md on the default branch counts the same as a CLAUDE.md" "out=$out_origin"

# The control that keeps the new branch from swallowing the old one: a git repository whose default
# branch has no instructions file either is still the plain bare case, and must still say so. A
# check that answered "it is on another branch" for every git repository would be satisfied by
# nothing (L159).
mkdir -p "$TMPROOT/here/GitButBare"
git -C "$TMPROOT/here/GitButBare" init -q -b main >/dev/null 2>&1
git -C "$TMPROOT/here/GitButBare" config user.email tests@example.invalid
git -C "$TMPROOT/here/GitButBare" config user.name "project list tests"
printf 'nothing to do with instructions\n' > "$TMPROOT/here/GitButBare/README.md"
git -C "$TMPROOT/here/GitButBare" add README.md >/dev/null 2>&1
git -C "$TMPROOT/here/GitButBare" commit -qm "a repository with no instructions file at all" >/dev/null 2>&1

GITBARE="$(mkfile gitbare.md "## Projects

On MacOne:
- \`$TMPROOT/here/GitButBare\`

## Writing Style")"
out_gitbare="$(run "$GITBARE" MacOne)"; code_gitbare=$?
[ "$code_gitbare" -eq 3 ] \
  && check "a git repository whose default branch has no file either is still the bare case" ok \
  || check "a git repository whose default branch has no file either is still the bare case" "exit=$code_gitbare out=$out_gitbare"

# ---------------------------------------------------------------------------
# An instructions file that EXISTS but supplies nothing (claude-config#496). The check counted a
# project as provided for when the file was there and read nothing inside it, which is the same
# shape as the fault it was written for: a guard confirming a MARKER rather than the thing the
# marker stands for reads as protection and supplies none.
#
# Two ways a present file supplies nothing. It can be empty, and it can be nothing but an import of
# a file that is no longer beside it: Overture's CLAUDE.md is a single @AGENTS.md line, so renaming
# that sibling would leave the check reporting Overture as provided for while a session there
# started with none of it.
#
# The predicate is that EVERY instructions file the project has is faulty, not that one of them is.
# What is being asked is whether the project supplies instructions at all, and a full AGENTS.md
# beside an empty CLAUDE.md does. The cost of the other reading is a notice that speaks in every
# session about something harmless, which is how a notice gets skimmed. What this does NOT catch is
# a dangling import in one of two files where the other is sound (L93): no listed project has two
# today, and Overture, the only one with an import, has exactly one file carrying it.
# ---------------------------------------------------------------------------
mkdir -p "$TMPROOT/here/EmptyFile"
printf '   \n\n\t\n' > "$TMPROOT/here/EmptyFile/CLAUDE.md"

EMPTYFILE="$(mkfile emptyfile.md "## Projects

On MacOne:
- \`$TMPROOT/here/EmptyFile\`

## Writing Style")"
out_ef="$(run "$EMPTYFILE" MacOne)"; code_ef=$?
[ "$code_ef" -eq 4 ] \
  && check "an instructions file holding only whitespace is refused" ok \
  || check "an instructions file holding only whitespace is refused" "exit=$code_ef out=$out_ef"
[ "$code_ef" != "$code_nofile" ] && [ "$code_ef" != "$code_pre" ] \
  && check "and does not share an exit code with the absent file cases" ok \
  || check "and does not share an exit code with the absent file cases" "empty=$code_ef bare=$code_nofile predates=$code_pre"
grep -qi 'empty' <<< "$out_ef" \
  && check "and says the file is empty rather than that it is missing" ok \
  || check "and says the file is empty rather than that it is missing" "out=$out_ef"

# The real Overture shape, which must PASS: a CLAUDE.md that is one import line, resolving to the
# sibling beside it. A check that refused this would refuse a project that is correctly provided
# for, and an over match reads as the guard working (L104).
mkdir -p "$TMPROOT/here/ImportsOk"
printf '@AGENTS.md\n' > "$TMPROOT/here/ImportsOk/CLAUDE.md"
printf '# the real instructions\n' > "$TMPROOT/here/ImportsOk/AGENTS.md"

IMPORTSOK="$(mkfile importsok.md "## Projects

On MacOne:
- \`$TMPROOT/here/ImportsOk\`

## Writing Style")"
out_iok="$(run "$IMPORTSOK" MacOne)"; code_iok=$?
[ "$code_iok" -eq 0 ] \
  && check "a file that is one import resolving to a sibling passes" ok \
  || check "a file that is one import resolving to a sibling passes" "exit=$code_iok out=$out_iok"

# The same file with the sibling renamed away, which is the failure the issue was written from.
mkdir -p "$TMPROOT/here/ImportsNowhere"
printf '@AGENTS.md\n' > "$TMPROOT/here/ImportsNowhere/CLAUDE.md"

IMPORTSBAD="$(mkfile importsbad.md "## Projects

On MacOne:
- \`$TMPROOT/here/ImportsNowhere\`

## Writing Style")"
out_ibad="$(run "$IMPORTSBAD" MacOne)"; code_ibad=$?
[ "$code_ibad" -eq 4 ] \
  && check "an import pointing at nothing is refused" ok \
  || check "an import pointing at nothing is refused" "exit=$code_ibad out=$out_ibad"
grep -q 'AGENTS.md' <<< "$out_ibad" \
  && check "and names the import it could not resolve" ok \
  || check "and names the import it could not resolve" "out=$out_ibad"

# An import into a subdirectory, resolved relative to the FILE and not to the working directory,
# which is the playeditapp shape: its CLAUDE.md imports @PlayedIt/CLAUDE.md.
mkdir -p "$TMPROOT/here/NestedImport/Inner"
printf 'some prose\n\n@Inner/CLAUDE.md\n' > "$TMPROOT/here/NestedImport/CLAUDE.md"
printf '# inner\n' > "$TMPROOT/here/NestedImport/Inner/CLAUDE.md"

NESTED="$(mkfile nested.md "## Projects

On MacOne:
- \`$TMPROOT/here/NestedImport\`

## Writing Style")"
out_nested="$(cd "$TMPROOT" && run "$NESTED" MacOne)"; code_nested=$?
[ "$code_nested" -eq 0 ] \
  && check "an import into a subdirectory is resolved against the file, not the working directory" ok \
  || check "an import into a subdirectory is resolved against the file, not the working directory" "exit=$code_nested out=$out_nested"

# The control this rule was MEASURED against, and the reason it matches only a line that STARTS
# with the sigil. Across the eight instructions files the real list names on 2026-09-19, a rule
# matching the sigil anywhere would have accused Downbeat of importing @Query, @Suite and @Test
# (Swift attributes) and NurseDex of importing @vercel/otel (a package name), every one of them
# inside backticks or ordinary prose, and none of them an import. A guard is tested against what it
# must PRESERVE, not only what it must catch (L104).
mkdir -p "$TMPROOT/here/ProseWithSigils"
cat > "$TMPROOT/here/ProseWithSigils/CLAUDE.md" <<'PROSE'
# real instructions

- The renderer only runs in views that already have @Query for ProjectTemplates.
- Use Swift Testing: `import Testing`, `@Suite`, `@Test`, `#expect`. Not XCTest.
- Add OpenTelemetry via `@vercel/otel` on Node.
- Ask someone@example.invalid if this is unclear.
PROSE

PROSEF="$(mkfile prose.md "## Projects

On MacOne:
- \`$TMPROOT/here/ProseWithSigils\`

## Writing Style")"
out_prose="$(run "$PROSEF" MacOne)"; code_prose=$?
[ "$code_prose" -eq 0 ] \
  && check "a sigil inside prose or backticks is not read as an import" ok \
  || check "a sigil inside prose or backticks is not read as an import" "exit=$code_prose out=$out_prose"

# A fenced code block showing what an import LOOKS like is documentation, not an import, and the
# file it names need not exist. This is the shape the payload's own README and skills use.
mkdir -p "$TMPROOT/here/FencedExample"
cat > "$TMPROOT/here/FencedExample/CLAUDE.md" <<'FENCED'
# real instructions

To pull in a shared file, write:

```
@some/file/that/is/not/here.md
```

That is all.
FENCED

FENCEDF="$(mkfile fenced.md "## Projects

On MacOne:
- \`$TMPROOT/here/FencedExample\`

## Writing Style")"
out_fenced="$(run "$FENCEDF" MacOne)"; code_fenced=$?
[ "$code_fenced" -eq 0 ] \
  && check "an import shown inside a fenced code block is an example, not an import" ok \
  || check "an import shown inside a fenced code block is an example, not an import" "exit=$code_fenced out=$out_fenced"

# A full AGENTS.md beside an empty CLAUDE.md: the project DOES supply instructions, so it passes.
# This is the predicate stated out loud, because the other reading would speak in every session
# about a harmless stub.
mkdir -p "$TMPROOT/here/OneOfTwoIsReal"
: > "$TMPROOT/here/OneOfTwoIsReal/CLAUDE.md"
printf '# the real instructions\n' > "$TMPROOT/here/OneOfTwoIsReal/AGENTS.md"

ONEOFTWO="$(mkfile oneoftwo.md "## Projects

On MacOne:
- \`$TMPROOT/here/OneOfTwoIsReal\`

## Writing Style")"
out_oot="$(run "$ONEOFTWO" MacOne)"; code_oot=$?
[ "$code_oot" -eq 0 ] \
  && check "a project supplying instructions in one of its two files passes" ok \
  || check "a project supplying instructions in one of its two files passes" "exit=$code_oot out=$out_oot"

# And the ordering, pinned: a project with NO file anywhere outranks one whose file is empty. Both
# are true of the list, and the reader is sent to the more complete fault first.
ORDER="$(mkfile order.md "## Projects

On MacOne:
- \`$TMPROOT/here/EmptyFile\`
- \`$TMPROOT/here/Bare\`

## Writing Style")"
out_order="$(run "$ORDER" MacOne)"; code_order=$?
[ "$code_order" -eq 3 ] \
  && check "a project with no file anywhere outranks one whose file is empty" ok \
  || check "a project with no file anywhere outranks one whose file is empty" "exit=$code_order out=$out_order"

# ---------------------------------------------------------------------------
# The real file, last, by which point the checker has been watched failing several ways. On this
# Mac it names real projects; on the CI runner it names neither Mac and says so.
#
# The PATH half is asserted here, because the list controls it: an entry naming somewhere that is
# not on this machine is always wrong, and nothing outside this repository can make it right.
#
# The INSTRUCTIONS half deliberately is NOT asserted here, and that is not a softening. A checkout
# standing on a branch created before its CLAUDE.md landed genuinely has no file on disk, which is
# a true finding about that checkout and a false one about the project, and it is not fixable from
# here: the branch belongs to whoever is working in it. A red here would be indistinguishable from
# a real defect (L411) and would block every unrelated push in this repository for as long as it
# lasted (L538). The live state is reported where it can be acted on instead, by
# project-list-nudge.sh, once per session. What the checker DOES with a bare project is proven
# above, on fixtures this suite controls.
# ---------------------------------------------------------------------------
out_real="$(bash "$CHECK" 2>&1)"; code_real=$?
[ "$code_real" -ne 1 ] \
  && check "every project the real list names for this machine is on it" ok \
  || check "every project the real list names for this machine is on it" "exit=$code_real out=$out_real"
[ "$code_real" -ne 2 ] \
  && check "and the real list could be read at all" ok \
  || check "and the real list could be read at all" "exit=$code_real out=$out_real"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
