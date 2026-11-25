#!/usr/bin/env bash
# Tests for check-home-paths.sh, the guard against a machine specific home
# directory reaching the synced config (claude-config#86).
#
# The guard reports ZERO on the real tree today, because the eight paths that
# prompted it are fixed. A count that is already zero is exactly the kind of
# number that stops being read as a measurement and starts being read as proof
# the thing cannot happen (L182), so every check below runs against a tree built
# to hold the answer it expects: one with a planted machine path, one with each
# allowed form, one excused by the marker, and one holding nothing at all. Only
# then is the real tree asked, and by then the scanner has been seen to fail.
set -uo pipefail

# Its own wall clock, and whatever it starts stopped with it however it ends (claude-config#465).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECK="$DIR/check-home-paths.sh"

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

TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

# Assembled at runtime, never written whole. Spelled out, this file would itself
# carry a machine path, and the guard cannot tell the line demonstrating the
# defect from the line committing it: the scan over the real tree at the bottom
# would then fail on its own test. Same trick the style hook needs for the
# characters it bans.
BADHOME="/Users""/someone-elses-mac"

tree() { # tree <name>  -> builds an empty synced-shaped tree and prints its root
  local root="$TMPROOT/$1"
  mkdir -p "$root/hooks" "$root/skills/demo" "$root/agents" "$root/commands"
  printf 'name: demo\n' > "$root/skills/demo/SKILL.md"
  printf '# rules\n' > "$root/CLAUDE.md"
  printf '%s' "$root"
}

# ---------------------------------------------------------------------------
# It fires on a planted path, and names where. A guard nobody has watched fail
# is not a guard (L1), and one that reports a hit without saying which file
# cannot be acted on (L11).
# ---------------------------------------------------------------------------
BAD="$(tree bad)"
printf 'bash %s/.claude/skills/x/healthcheck.sh\n' "$BADHOME" > "$BAD/skills/demo/SKILL.md"
out_bad="$(bash "$CHECK" "$BAD" 2>&1)"
code_bad=$?
[ "$code_bad" -eq 1 ] \
  && check "a planted machine path fails the check" ok \
  || check "a planted machine path fails the check" "exit=$code_bad out=$out_bad"
grep -q "skills/demo/SKILL.md" <<< "$out_bad" \
  && check "the failure names the file it found it in" ok \
  || check "the failure names the file it found it in" "out=$out_bad"

# ---------------------------------------------------------------------------
# It leaves the portable forms alone. A guard tested only against what it must
# CATCH says nothing about what it must PRESERVE, and an over match here reads
# exactly like the guard working (L104).
# ---------------------------------------------------------------------------
GOOD="$(tree good)"
cat > "$GOOD/skills/demo/SKILL.md" <<'ALLOWED'
bash ~/.claude/skills/x/healthcheck.sh
bash $HOME/.claude/skills/x/healthcheck.sh
os.path.expanduser("~/.claude/skills/x/state.json")
ALLOWED
# The sync's placeholder, assembled rather than written out. Spelled in full, the
# apply rewrites this very line into a real home directory, and then this fixture,
# which exists to prove a portable form PASSES, is a machine path that correctly
# fails (claude-config#99). Measured on the installed copy, not reasoned about.
printf '%s/hooks/tdd-nudge.sh\n' "__CLAUDE""_HOME__" >> "$GOOD/skills/demo/SKILL.md"
# An elided example, written with dots where the account name would be. One of
# these lives in a vendored skill in the real tree below, so this is measured
# from what is actually there rather than invented (L48).
printf 'absolute: node "%s/.../hook.mjs"\n' "/Users" >> "$GOOD/skills/demo/SKILL.md"
out_good="$(bash "$CHECK" "$GOOD" 2>&1)"
code_good=$?
[ "$code_good" -eq 0 ] \
  && check "every portable form passes, and an elided example is not a machine path" ok \
  || check "every portable form passes, and an elided example is not a machine path" "exit=$code_good out=$out_good"
printf '%s' "$out_good" | grep -Eq '[0-9]+ file' \
  && check "a clean run says how many files it read" ok \
  || check "a clean run says how many files it read" "out=$out_good"

# ---------------------------------------------------------------------------
# The deliberate exception, and its blast radius: the marker excuses its own
# line and nothing else in the file.
# ---------------------------------------------------------------------------
MARK="$(tree marked)"
printf 'an example path %s/.claude/x claude-sync-allow-home-path\n' "$BADHOME" > "$MARK/skills/demo/SKILL.md"
out_mark="$(bash "$CHECK" "$MARK" 2>&1)"
code_mark=$?
[ "$code_mark" -eq 0 ] \
  && check "a line carrying the marker is excused" ok \
  || check "a line carrying the marker is excused" "exit=$code_mark out=$out_mark"

printf 'and this one is not %s/.claude/y\n' "$BADHOME" >> "$MARK/skills/demo/SKILL.md"
out_mark2="$(bash "$CHECK" "$MARK" 2>&1)"
code_mark2=$?
[ "$code_mark2" -eq 1 ] \
  && check "the marker does not excuse the rest of its file" ok \
  || check "the marker does not excuse the rest of its file" "exit=$code_mark2 out=$out_mark2"

# ---------------------------------------------------------------------------
# The one allowance, and its three edges. claude-sync rewrites this Mac's config
# directory to its token in every mirrored file on the way out and expands it per
# Mac on the way in, so inside a LIVE config tree an absolute path under that same
# directory is portable. Outside those conditions it is the same defect as before,
# and each edge is asserted rather than assumed (L142: the half you do not exercise
# is where the harm lives).
# ---------------------------------------------------------------------------
LIVE="$(tree live)"
printf 'bash %s/hooks/helper.sh\n' "$LIVE" > "$LIVE/skills/demo/SKILL.md"
out_live="$(CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LIVE" bash "$CHECK" "$LIVE" 2>&1)"
code_live=$?
[ "$code_live" -eq 0 ] \
  && check "this Mac's own config path passes inside its live tree" ok \
  || check "this Mac's own config path passes inside its live tree" "exit=$code_live out=$out_live"

# CLAUDE_HOME_PATH_ROOTS points the rule at this run's own temp directory, so "a home
# directory" means a directory inside it. Without that the whole block would be inert on the
# Linux runner, where nothing is under /Users, and four checks would pass by matching nothing.
#
# The SAME line, in a tree that is NOT this machine's config directory: the repo's copy of it,
# say, where nothing has been through a send and so nothing will be rewritten. This is the case
# the root comparison exists for, and it is only a real test when the path in the file genuinely
# belongs to the live config directory, which is why the fixture copies the live file rather than
# writing a different path: with CLAUDE_HOME merely pointing somewhere else, the line is refused
# for having an unrelated home path in it and the root comparison is never consulted.
COPY="$(tree copy)"
cp "$LIVE/skills/demo/SKILL.md" "$COPY/skills/demo/SKILL.md"
out_notlive="$(CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LIVE" bash "$CHECK" "$COPY" 2>&1)"
code_notlive=$?
[ "$code_notlive" -eq 1 ] \
  && check "the same path is refused when the tree is not this Mac's config" ok \
  || check "the same path is refused when the tree is not this Mac's config" "exit=$code_notlive out=$out_notlive"

# A rule file is merged entry by entry and deliberately never rewritten, so a home
# path there is still wrong on the other Mac.
printf 'name: demo\n' > "$LIVE/skills/demo/SKILL.md"
printf 'read %s/LESSONS.md first\n' "$LIVE" > "$LIVE/CLAUDE.md"
out_rule="$(CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LIVE" bash "$CHECK" "$LIVE" 2>&1)"
code_rule=$?
[ "$code_rule" -eq 1 ] \
  && check "a home path in a top level rule file is still refused" ok \
  || check "a home path in a top level rule file is still refused" "exit=$code_rule out=$out_rule"

# And another machine's home is still the original defect, in the same live tree
# that accepts this one's, on a line sitting right beside a portable one.
printf '# rules\n' > "$LIVE/CLAUDE.md"
printf 'bash %s/hooks/helper.sh\nbash %s/other-mac/.claude/hooks/other.sh\n' "$LIVE" "$TMPROOT" > "$LIVE/skills/demo/SKILL.md"
out_mixed="$(CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LIVE" bash "$CHECK" "$LIVE" 2>&1)"
code_mixed=$?
[ "$code_mixed" -eq 1 ] \
  && check "another Mac's home is still refused beside a portable one" ok \
  || check "another Mac's home is still refused beside a portable one" "exit=$code_mixed out=$out_mixed"
grep -q "other.sh" <<< "$out_mixed" \
  && check "and the refusal names the offending line, not the portable one" ok \
  || check "and the refusal names the offending line, not the portable one" "out=$out_mixed"

# ---------------------------------------------------------------------------
# Naming the sync's placeholder in full is its own defect, because the apply
# rewrites that text into a home directory. Only a scriptPath, which is meant to
# be expanded, and a line carrying the marker are allowed to.
# ---------------------------------------------------------------------------
TOKTREE="$(tree token)"
printf 'the %s placeholder, explained\n' "__CLAUDE""_HOME__" > "$TOKTREE/skills/demo/SKILL.md"
out_tok="$(bash "$CHECK" "$TOKTREE" 2>&1)"
code_tok=$?
[ "$code_tok" -eq 1 ] \
  && check "a file that writes the placeholder out in full is refused" ok \
  || check "a file that writes the placeholder out in full is refused" "exit=$code_tok out=$out_tok"

printf '      scriptPath: "%s/skills/x/panel.workflow.js"\n' "__CLAUDE""_HOME__" > "$TOKTREE/skills/demo/SKILL.md"
out_tok2="$(bash "$CHECK" "$TOKTREE" 2>&1)"
code_tok2=$?
[ "$code_tok2" -eq 0 ] \
  && check "it standing in front of a path is left alone" ok \
  || check "it standing in front of a path is left alone" "exit=$code_tok2 out=$out_tok2"

# The worst of the three, because it changed behaviour rather than wording: a shell substitution
# over the placeholder. The slash after it belongs to the substitution, not to a path.
printf 'WFPATH="${WFPATH/%s/$HOME}"\n' "__CLAUDE""_HOME__" > "$TOKTREE/skills/demo/SKILL.md"
out_tok4="$(bash "$CHECK" "$TOKTREE" 2>&1)"
code_tok4=$?
[ "$code_tok4" -eq 1 ] \
  && check "a substitution over the placeholder is refused" ok \
  || check "a substitution over the placeholder is refused" "exit=$code_tok4 out=$out_tok4"

printf 'the %s placeholder claude-sync-allow-home-path\n' "__CLAUDE""_HOME__" > "$TOKTREE/skills/demo/SKILL.md"
out_tok3="$(bash "$CHECK" "$TOKTREE" 2>&1)"
code_tok3=$?
[ "$code_tok3" -eq 0 ] \
  && check "and a marked line is excused here too" ok \
  || check "and a marked line is excused here too" "exit=$code_tok3 out=$out_tok3"

# ---------------------------------------------------------------------------
# The hand substituted placeholder, which is refused now rather than allowed
# (claude-config#106). It was only ever needed for two Workflow scriptPath values
# that could not be written as a tilde; since #87 the sync rewrites this Mac's
# home directory in every mirrored file, so both are concrete again and nothing
# writes it. Left merely unmentioned it would still pass, because it is not a
# machine path and never matched that rule, so what is asserted here is the
# REFUSAL: an unsubstituted placeholder in a live file resolves to nothing, which
# is the same silent half working the guard exists to catch (L67).
#
# Assembled, never written whole, for the same reason as BADHOME above: this file
# is itself inside the scanned tree, and the real tree scan at the bottom would
# fail on the line demonstrating the defect.
# ---------------------------------------------------------------------------
ANGLE="<""HOME>"
ANGTREE="$(tree angle)"
printf 'node "%s/.claude/skills/plan-council/panel.workflow.js"\n' "$ANGLE" > "$ANGTREE/skills/demo/SKILL.md"
out_ang="$(bash "$CHECK" "$ANGTREE" 2>&1)"
code_ang=$?
[ "$code_ang" -eq 1 ] \
  && check "the hand substituted placeholder is refused" ok \
  || check "the hand substituted placeholder is refused" "exit=$code_ang out=$out_ang"
grep -q "skills/demo/SKILL.md" <<< "$out_ang" \
  && check "and the refusal names the file it found it in" ok \
  || check "and the refusal names the file it found it in" "out=$out_ang"

# Its own exit is 1, not 2: it is a finding, and it must be reported as the same
# kind of finding as a machine path rather than as a scan that read nothing.
grep -qi "substitut" <<< "$out_ang" \
  && check "the refusal says what to do about it" ok \
  || check "the refusal says what to do about it" "out=$out_ang"

# A rule file is not rewritten by the sync either, so it is refused there too.
printf 'name: demo\n' > "$ANGTREE/skills/demo/SKILL.md"
printf 'see %s/LESSONS.md\n' "$ANGLE" > "$ANGTREE/CLAUDE.md"
out_ang2="$(bash "$CHECK" "$ANGTREE" 2>&1)"
code_ang2=$?
[ "$code_ang2" -eq 1 ] \
  && check "it is refused in a top level rule file too" ok \
  || check "it is refused in a top level rule file too" "exit=$code_ang2 out=$out_ang2"

# The same escape hatch as everything else here, and it excuses its own line only.
printf '# rules\n' > "$ANGTREE/CLAUDE.md"
printf 'an example, %s/x claude-sync-allow-home-path\n' "$ANGLE" > "$ANGTREE/skills/demo/SKILL.md"
out_ang3="$(bash "$CHECK" "$ANGTREE" 2>&1)"
code_ang3=$?
[ "$code_ang3" -eq 0 ] \
  && check "a marked line is excused here too" ok \
  || check "a marked line is excused here too" "exit=$code_ang3 out=$out_ang3"

printf 'and this one is not %s/y\n' "$ANGLE" >> "$ANGTREE/skills/demo/SKILL.md"
out_ang4="$(bash "$CHECK" "$ANGTREE" 2>&1)"
code_ang4=$?
[ "$code_ang4" -eq 1 ] \
  && check "the marker does not excuse the rest of its file here either" ok \
  || check "the marker does not excuse the rest of its file here either" "exit=$code_ang4 out=$out_ang4"

# ---------------------------------------------------------------------------
# All three causes are reported by ONE run (claude-config#108). The three rules
# grew one at a time and each walked the tree itself, exiting on the first one
# that fired, so a tree holding all three reported one cause per run and had to
# be fixed three runs deep. They are three distinct causes with three distinct
# messages (L11) and they stay that way; what changes is that one run names all
# of the ones it found instead of the first.
# ---------------------------------------------------------------------------
ALL="$(tree allthree)"
printf 'bash %s/.claude/x.sh\n' "$BADHOME"       > "$ALL/skills/demo/SKILL.md"
printf 'the %s placeholder, explained\n' "__CLAUDE""_HOME__" > "$ALL/agents/a.md"
printf 'node "%s/.claude/panel.js"\n' "$ANGLE"   > "$ALL/commands/c.md"
out_all="$(bash "$CHECK" "$ALL" 2>&1)"
code_all=$?
[ "$code_all" -eq 1 ] \
  && check "a tree holding all three defects fails" ok \
  || check "a tree holding all three defects fails" "exit=$code_all out=$out_all"

grep -q "skills/demo/SKILL.md" <<< "$out_all" \
  && check "one run reports the machine path" ok \
  || check "one run reports the machine path" "out=$out_all"
grep -q "agents/a.md" <<< "$out_all" \
  && check "the same run also reports the placeholder" ok \
  || check "the same run also reports the placeholder" "out=$out_all"
grep -q "commands/c.md" <<< "$out_all" \
  && check "and the same run also reports the hand substituted one" ok \
  || check "and the same run also reports the hand substituted one" "out=$out_all"

# The three messages stay distinct: one run naming three causes must not collapse
# them into a single sentence that says none of them precisely.
[ "$(printf '%s' "$out_all" | grep -c '^check-home-paths:')" -eq 3 ] \
  && check "each cause keeps its own message" ok \
  || check "each cause keeps its own message" "out=$out_all"

# ---------------------------------------------------------------------------
# A scan that read nothing must not report a clean tree. Both ways of reading
# nothing are separate outcomes with separate exits, because a guard pointed at
# the wrong directory would otherwise pass for ever (L98, L151).
# ---------------------------------------------------------------------------
EMPTY="$TMPROOT/empty"; mkdir -p "$EMPTY"
out_empty="$(bash "$CHECK" "$EMPTY" 2>&1)"
code_empty=$?
[ "$code_empty" -eq 2 ] \
  && check "a tree with nothing synced in it is refused, not passed" ok \
  || check "a tree with nothing synced in it is refused, not passed" "exit=$code_empty out=$out_empty"

BARE="$(tree bare)"
rm -f "$BARE/skills/demo/SKILL.md" "$BARE/CLAUDE.md"
out_bare="$(bash "$CHECK" "$BARE" 2>&1)"
code_bare=$?
[ "$code_bare" -eq 2 ] \
  && check "synced directories holding no files are refused too" ok \
  || check "synced directories holding no files are refused too" "exit=$code_bare out=$out_bare"

out_missing="$(bash "$CHECK" "$TMPROOT/not-here" 2>&1)"
code_missing=$?
[ "$code_missing" -eq 2 ] \
  && check "a root that does not exist is refused" ok \
  || check "a root that does not exist is refused" "exit=$code_missing out=$out_missing"

# ---------------------------------------------------------------------------
# Skills the sync never carries are not the sync's to judge (claude-config#415).
# On 2026-09-17 a login to a second account made the Claude app download its
# built in skills into skills/synced/<bucket>/, one of which carries example
# paths under /home, and every hook suite run on that Mac failed on a file no
# send will ever publish. The entries left out come from ONE list, the one
# claude-sync itself reads (lib/unmanaged-skills.sh), with the sync's own
# matching: a plugin skill name is excluded wherever it appears, while the
# platform's folders are excluded only at the top of skills/, so a folder that
# merely happens to be called `synced` inside a real skill is still config and
# is still scanned.
#
# The plugin name is taken from that list rather than written here, so the
# fixture means "a name the sync leaves out" for as long as the list has one
# (L401), and the check that the list is not empty keeps that from being vacuous.
# ---------------------------------------------------------------------------
UNMANAGED_LIB="$DIR/lib/unmanaged-skills.sh"
PLUGIN_NAME="$(bash -c '. "$1" && printf "%s" "${PLUGIN_SKILLS[0]:-}"' _ "$UNMANAGED_LIB" 2>/dev/null)"
PLATFORM_NAME="$(bash -c '. "$1" && printf "%s" "${PLATFORM_SKILL_DIRS[0]:-}"' _ "$UNMANAGED_LIB" 2>/dev/null)"
[ -n "$PLUGIN_NAME" ] && [ -n "$PLATFORM_NAME" ] \
  && check "#415 the shared list names a plugin skill and a platform folder" ok \
  || check "#415 the shared list names a plugin skill and a platform folder" "plugin='$PLUGIN_NAME' platform='$PLATFORM_NAME' lib=$UNMANAGED_LIB"

UNM="$(tree unmanaged)"
mkdir -p "$UNM/skills/$PLATFORM_NAME/bucket-1/web-asset-generator" "$UNM/skills/$PLUGIN_NAME" \
         "$UNM/skills/demo/$PLUGIN_NAME"
printf 'python gen.py %s/output all\n' "$BADHOME" > "$UNM/skills/$PLATFORM_NAME/bucket-1/web-asset-generator/SKILL.md"
printf '{"skills":[]}\n' > "$UNM/skills/$PLATFORM_NAME/bucket-1/manifest.json"
printf 'bash %s/.claude/skills/x.sh\n' "$BADHOME" > "$UNM/skills/$PLUGIN_NAME/SKILL.md"
printf 'bash %s/.claude/skills/y.sh\n' "$BADHOME" > "$UNM/skills/demo/$PLUGIN_NAME/notes.md"
out_unm="$(bash "$CHECK" "$UNM" 2>&1)"
code_unm=$?
[ "$code_unm" -eq 0 ] \
  && check "#415 home paths inside skills the sync never carries are not reported" ok \
  || check "#415 home paths inside skills the sync never carries are not reported" "exit=$code_unm out=$out_unm"

# The same tree, plus the two places that ARE config: a folder called synced
# inside a real skill, and the real skill itself. Both must still be reported,
# and the unmanaged files must still not be, in the same run.
mkdir -p "$UNM/skills/demo/$PLATFORM_NAME"
printf 'bash %s/.claude/skills/nested.sh\n' "$BADHOME" > "$UNM/skills/demo/$PLATFORM_NAME/notes.md"
printf 'bash %s/.claude/skills/own.sh\n' "$BADHOME" > "$UNM/skills/demo/SKILL.md"
out_unm2="$(bash "$CHECK" "$UNM" 2>&1)"
code_unm2=$?
[ "$code_unm2" -eq 1 ] \
  && check "#415 a tree holding real skills with home paths still fails" ok \
  || check "#415 a tree holding real skills with home paths still fails" "exit=$code_unm2 out=$out_unm2"
grep -q "skills/demo/$PLATFORM_NAME/notes.md:" <<< "$out_unm2" \
  && check "#415 a nested folder named $PLATFORM_NAME inside a real skill is still scanned" ok \
  || check "#415 a nested folder named $PLATFORM_NAME inside a real skill is still scanned" "out=$out_unm2"
grep -q "skills/demo/SKILL.md:" <<< "$out_unm2" \
  && check "#415 the real skill itself is still reported" ok \
  || check "#415 the real skill itself is still reported" "out=$out_unm2"
grep -q "skills/$PLATFORM_NAME/bucket-1\|skills/$PLUGIN_NAME/SKILL.md\|skills/demo/$PLUGIN_NAME/" <<< "$out_unm2" \
  && check "#415 and the unmanaged files are still left out of that same run" "out=$out_unm2" \
  || check "#415 and the unmanaged files are still left out of that same run" ok

# The list that could not be read. The check runs from a hooks folder with no
# lib beside it, which is the only way that state occurs on a Mac. Chosen
# direction: it skips NOTHING, so a guard missing its list can only report too
# much rather than too little (L42), and it SAYS so, whatever the verdict, since
# a scan quietly widened reads the same as the normal one (L98).
NOLIB="$TMPROOT/nolib-hooks"; mkdir -p "$NOLIB"
cp "$CHECK" "$NOLIB/check-home-paths.sh"
UNM3="$(tree unmanaged-nolib)"
mkdir -p "$UNM3/skills/$PLATFORM_NAME/bucket-1/x"
printf 'python gen.py %s/output all\n' "$BADHOME" > "$UNM3/skills/$PLATFORM_NAME/bucket-1/x/SKILL.md"
out_nolib="$(bash "$NOLIB/check-home-paths.sh" "$UNM3" 2>&1)"
code_nolib=$?
[ "$code_nolib" -eq 1 ] \
  && check "#415 with no readable list, nothing is skipped and the platform file is reported" ok \
  || check "#415 with no readable list, nothing is skipped and the platform file is reported" "exit=$code_nolib out=$out_nolib"
grep -q "unmanaged-skills.sh" <<< "$out_nolib" \
  && check "#415 and the run names the list it could not read" ok \
  || check "#415 and the run names the list it could not read" "out=$out_nolib"

rm -rf "$UNM3/skills/$PLATFORM_NAME"
out_nolib2="$(bash "$NOLIB/check-home-paths.sh" "$UNM3" 2>&1)"
code_nolib2=$?
[ "$code_nolib2" -eq 0 ] \
  && check "#415 a clean tree still passes without the list" ok \
  || check "#415 a clean tree still passes without the list" "exit=$code_nolib2 out=$out_nolib2"
grep -q "unmanaged-skills.sh" <<< "$out_nolib2" \
  && check "#415 but the pass still says the list could not be read" ok \
  || check "#415 but the pass still says the list could not be read" "out=$out_nolib2"

# A list that is THERE but defines nothing (truncated, or a different file under
# that name) is the same unreadable state, not an empty list meaning skip nothing
# quietly.
mkdir -p "$NOLIB/lib"; printf '# nothing here\n' > "$NOLIB/lib/unmanaged-skills.sh"
out_badlib="$(bash "$NOLIB/check-home-paths.sh" "$UNM3" 2>&1)"
grep -q "unmanaged-skills.sh" <<< "$out_badlib" \
  && check "#415 a list file that defines nothing is reported as unreadable too" ok \
  || check "#415 a list file that defines nothing is reported as unreadable too" "out=$out_badlib"

# ---------------------------------------------------------------------------
# Every tree the sync mirrors is read, and the list of them is the sync's own
# (claude-config#2754). The guard used to keep its own list, hooks agents commands
# skills, while claude-sync also mirrors audits/ and mods/, so a home path written
# in a mod reached the other Mac and this public repository with nothing reading
# it. The list now comes from lib/synced-trees.sh, which test-synced-trees.sh holds
# to claude-sync's MIRROR_DIRS. Asked per tree from that same list, so a tree added
# there and missed here fails below, and asked of a tree the sync does NOT mirror,
# so the guard reading more than the sync carries fails too: the two lists must be
# the same set, not merely overlap.
# ---------------------------------------------------------------------------
TREES_LIB="$DIR/lib/synced-trees.sh"
TREES="$(bash -c '. "$1" && printf "%s\n" "${SYNCED_TREES[@]}"' _ "$TREES_LIB" 2>/dev/null)"
[ -n "$TREES" ] \
  && check "#2754 the sync's list of mirrored trees can be read" ok \
  || check "#2754 the sync's list of mirrored trees can be read" "lib=$TREES_LIB"
grep -qx mods <<< "$TREES" && grep -qx audits <<< "$TREES" \
  && check "#2754 that list names mods and audits" ok \
  || check "#2754 that list names mods and audits" "trees=$TREES"

MODTREE="$(tree mod)"
mkdir -p "$MODTREE/mods/demo/hooks"
printf 'const p = "%s/.claude/mods/demo/state.json"\n' "$BADHOME" > "$MODTREE/mods/demo/hooks/register.ts"
out_mod="$(bash "$CHECK" "$MODTREE" 2>&1)"
code_mod=$?
[ "$code_mod" -eq 1 ] \
  && check "#2754 a home path in a mod is refused" ok \
  || check "#2754 a home path in a mod is refused" "exit=$code_mod out=$out_mod"
grep -q "mods/demo/hooks/register.ts:" <<< "$out_mod" \
  && check "#2754 and the refusal names the mod file" ok \
  || check "#2754 and the refusal names the mod file" "out=$out_mod"

AUDTREE="$(tree audit)"
mkdir -p "$AUDTREE/audits/2026-01-01-demo"
printf 'evidence copied from %s/.claude/state/x.json\n' "$BADHOME" > "$AUDTREE/audits/2026-01-01-demo/notes.md"
out_aud="$(bash "$CHECK" "$AUDTREE" 2>&1)"
code_aud=$?
[ "$code_aud" -eq 1 ] \
  && check "#2754 a home path in an audit is refused" ok \
  || check "#2754 a home path in an audit is refused" "exit=$code_aud out=$out_aud"
grep -q "audits/2026-01-01-demo/notes.md:" <<< "$out_aud" \
  && check "#2754 and the refusal names the audit file" ok \
  || check "#2754 and the refusal names the audit file" "out=$out_aud"

# One planted path per tree the sync mirrors, each in a tree holding nothing else, so a tree the
# guard does not read is a pass here and a failure of this check.
unread_trees=""
while IFS= read -r t; do
  [ -n "$t" ] || continue
  one="$TMPROOT/each-$t"; mkdir -p "$one/$t/demo"
  printf 'bash %s/.claude/x.sh\n' "$BADHOME" > "$one/$t/demo/file.md"
  out_one="$(bash "$CHECK" "$one" 2>&1)"; code_one=$?
  { [ "$code_one" -eq 1 ] && grep -q "$t/demo/file.md:" <<< "$out_one"; } || unread_trees="$unread_trees $t(exit=$code_one)"
done <<< "$TREES"
[ -n "$TREES" ] && [ -z "$unread_trees" ] \
  && check "#2754 every tree the sync mirrors is read by the guard" ok \
  || check "#2754 every tree the sync mirrors is read by the guard" "not read:${unread_trees:- (no list)}"

# And the other direction: a tree the sync never mirrors is not the guard's to judge. state/ holds
# each Mac's session notes and never leaves it, so a home path there must not fail the scan.
NOTSYNC="$(tree notsynced)"
mkdir -p "$NOTSYNC/state/notes"
printf 'cd %s/work\n' "$BADHOME" > "$NOTSYNC/state/notes/handoff.md"
out_ns="$(bash "$CHECK" "$NOTSYNC" 2>&1)"
code_ns=$?
[ "$code_ns" -eq 0 ] \
  && check "#2754 a tree the sync does not mirror is not read" ok \
  || check "#2754 a tree the sync does not mirror is not read" "exit=$code_ns out=$out_ns"

# The guard keeps no list of its own beside the sync's: a second copy is how mods and audits went
# unread for as long as they did (L41, L96).
grep -nE '^[[:space:]]*SYNCED_DIRS=\(' "$CHECK" >/dev/null \
  && check "#2754 the guard keeps no tree list of its own" "$(grep -nE '^[[:space:]]*SYNCED_DIRS=\(' "$CHECK")" \
  || check "#2754 the guard keeps no tree list of its own" ok

# With no list to read, the guard leaves NOTHING out and says so, the same direction it takes for
# the skills list above: a mod and a folder it has never heard of are both reported (L42, L98).
NOTREES="$TMPROOT/notrees-hooks"; mkdir -p "$NOTREES"
cp "$CHECK" "$NOTREES/check-home-paths.sh"
WIDE="$(tree wide)"
mkdir -p "$WIDE/mods/demo" "$WIDE/brand-new-tree"
printf 'x %s/.claude/a\n' "$BADHOME" > "$WIDE/mods/demo/a.ts"
printf 'y %s/.claude/b\n' "$BADHOME" > "$WIDE/brand-new-tree/b.md"
out_wide="$(bash "$NOTREES/check-home-paths.sh" "$WIDE" 2>&1)"
code_wide=$?
[ "$code_wide" -eq 1 ] && grep -q "mods/demo/a.ts:" <<< "$out_wide" && grep -q "brand-new-tree/b.md:" <<< "$out_wide" \
  && check "#2754 with no tree list, every folder is read" ok \
  || check "#2754 with no tree list, every folder is read" "exit=$code_wide out=$out_wide"
grep -q "synced-trees.sh" <<< "$out_wide" \
  && check "#2754 and the run names the list it could not read" ok \
  || check "#2754 and the run names the list it could not read" "out=$out_wide"

# ---------------------------------------------------------------------------
# A list of files, for the sync to ask about what a send is about to publish
# (claude-config#3465). On 2026-11-22 a send pushed 126 scratch files to main,
# 100 of them naming one Mac's home, and this check ran only afterwards, on
# GitHub. The send now asks first, and it asks about the
# files it is sending rather than walking the tree on every change, so the check
# takes a list: --files0-from <file>, NUL separated paths relative to the root.
#
# The list narrows WHICH files are read and nothing else. A listed file is read
# exactly when the whole tree walk would read it, by the same three rules, so
# the send and main's own run cannot disagree about a file (L370). That is held
# below by asking both forms about one tree holding every kind of place.
# ---------------------------------------------------------------------------
list_of() { # list_of <list file> <path>...  -> writes the paths NUL separated
  local f="$1" p
  shift
  : > "$f"
  for p in "$@"; do printf '%s\0' "$p" >> "$f"; done
}
LST="$(tree listed)"
mkdir -p "$LST/hooks/run/cache-base" "$LST/state"
printf 'cwd %s/projects/x\n' "$BADHOME" > "$LST/hooks/run/cache-base/entry.json"
printf 'echo clean\n' > "$LST/hooks/clean.sh"
printf 'elsewhere %s/notes\n' "$BADHOME" > "$LST/hooks/untouched.sh"
printf 'note %s/x\n' "$BADHOME" > "$LST/state/local.md"
printf '{"hooks":{}}\n' > "$LST/settings.json"
LISTF="$TMPROOT/listed.files"

list_of "$LISTF" hooks/run/cache-base/entry.json hooks/clean.sh
out_l1="$(bash "$CHECK" --files0-from "$LISTF" "$LST" 2>&1)"
code_l1=$?
[ "$code_l1" -eq 1 ] && grep -q "hooks/run/cache-base/entry.json:1:" <<< "$out_l1" \
  && check "#3465 a listed file naming a home folder fails the check, with its line" ok \
  || check "#3465 a listed file naming a home folder fails the check, with its line" "exit=$code_l1 out=$out_l1"
grep -q "untouched.sh" <<< "$out_l1" \
  && check "#3465 and a file that was not listed is not read" "out=$out_l1" \
  || check "#3465 and a file that was not listed is not read" ok

# The control for the two above: the same tree walked whole does report the file the list left out,
# so the list is what kept it from being read, not the file being clean.
out_l1w="$(bash "$CHECK" "$LST" 2>&1)"
code_l1w=$?
[ "$code_l1w" -eq 1 ] && grep -q "hooks/untouched.sh:1:" <<< "$out_l1w" \
  && check "#3465 control: the whole tree walk reports the file the list left out" ok \
  || check "#3465 control: the whole tree walk reports the file the list left out" "exit=$code_l1w out=$out_l1w"

list_of "$LISTF" hooks/clean.sh
out_l2="$(bash "$CHECK" --files0-from "$LISTF" "$LST" 2>&1)"
code_l2=$?
[ "$code_l2" -eq 0 ] \
  && check "#3465 a list of clean files passes in a tree that holds a failing file elsewhere" ok \
  || check "#3465 a list of clean files passes in a tree that holds a failing file elsewhere" "exit=$code_l2 out=$out_l2"
grep -q "1 of 1 listed file" <<< "$out_l2" \
  && check "#3465 and the pass says how many of the listed files it read" ok \
  || check "#3465 and the pass says how many of the listed files it read" "out=$out_l2"

# Listed files the whole tree walk never reads (a folder the sync does not mirror, settings.json)
# are not read here either. That is a pass, since the list was the caller's and none of it was this
# check's to judge, and it is said as that rather than as files found clean (L11).
list_of "$LISTF" state/local.md settings.json
out_l3="$(bash "$CHECK" --files0-from "$LISTF" "$LST" 2>&1)"
code_l3=$?
[ "$code_l3" -eq 0 ] \
  && check "#3465 listed files outside the synced set are not judged" ok \
  || check "#3465 listed files outside the synced set are not judged" "exit=$code_l3 out=$out_l3"
grep -q "none of the 2 listed file" <<< "$out_l3" \
  && check "#3465 and the run says it read none of them, not that they were clean" ok \
  || check "#3465 and the run says it read none of them, not that they were clean" "out=$out_l3"
grep -q "state/local.md" <<< "$out_l1w" \
  && check "#3465 control: the whole tree walk does not read that folder either" "out=$out_l1w" \
  || check "#3465 control: the whole tree walk does not read that folder either" ok

# A list that cannot answer the question is a failure, never a pass (L98): nothing listed, a list
# that is not there, and a listed file that is not there are each a scan of something other than
# what was asked about.
: > "$LISTF"
out_l4="$(bash "$CHECK" --files0-from "$LISTF" "$LST" 2>&1)"
code_l4=$?
[ "$code_l4" -eq 2 ] && grep -q "names no files" <<< "$out_l4" \
  && check "#3465 an empty list is refused, not reported clean" ok \
  || check "#3465 an empty list is refused, not reported clean" "exit=$code_l4 out=$out_l4"
out_l5="$(bash "$CHECK" --files0-from "$TMPROOT/no-such-list" "$LST" 2>&1)"
code_l5=$?
[ "$code_l5" -eq 2 ] && grep -q "no-such-list" <<< "$out_l5" \
  && check "#3465 a list file that is not there is refused" ok \
  || check "#3465 a list file that is not there is refused" "exit=$code_l5 out=$out_l5"
list_of "$LISTF" hooks/clean.sh hooks/gone.sh
out_l6="$(bash "$CHECK" --files0-from "$LISTF" "$LST" 2>&1)"
code_l6=$?
[ "$code_l6" -eq 2 ] && grep -q "hooks/gone.sh" <<< "$out_l6" \
  && check "#3465 a listed file that is not there is refused, by name" ok \
  || check "#3465 a listed file that is not there is refused, by name" "exit=$code_l6 out=$out_l6"
out_l7="$(bash "$CHECK" --files0-from 2>&1)"
code_l7=$?
[ "$code_l7" -eq 2 ] && grep -q "needs the file" <<< "$out_l7" \
  && check "#3465 the option with no list file is refused" ok \
  || check "#3465 the option with no list file is refused" "exit=$code_l7 out=$out_l7"

# The two forms agree. One tree holding a failing line in every kind of place: read (a hook, a mod,
# a real skill, a folder named like a platform folder inside a real skill, a rule file), left out (a
# plugin skill, a platform folder, a folder the sync does not mirror, bytecode, a conflict copy,
# node_modules), excused by the marker, and the two placeholder rules. Listing every file in it must
# report exactly the lines the walk reports.
EQ="$(tree agree)"
mkdir -p "$EQ/hooks/__pycache__" "$EQ/hooks/node_modules/pkg" "$EQ/mods/demo" "$EQ/state" \
         "$EQ/skills/$PLATFORM_NAME/bucket-1" "$EQ/skills/$PLUGIN_NAME" "$EQ/skills/demo/$PLUGIN_NAME" \
         "$EQ/skills/demo/$PLATFORM_NAME"
printf 'a %s/a\n' "$BADHOME" > "$EQ/hooks/a.sh"
printf 'b %s/b\n' "$BADHOME" > "$EQ/mods/demo/b.ts"
printf 'c %s/c\n' "$BADHOME" > "$EQ/skills/demo/SKILL.md"
printf 'd %s/d\n' "$BADHOME" > "$EQ/skills/demo/$PLATFORM_NAME/d.md"
printf 'e %s/e\n' "$BADHOME" > "$EQ/CLAUDE.md"
printf 'f %s/f\n' "$BADHOME" > "$EQ/skills/$PLUGIN_NAME/SKILL.md"
printf 'g %s/g\n' "$BADHOME" > "$EQ/skills/demo/$PLUGIN_NAME/g.md"
printf 'h %s/h\n' "$BADHOME" > "$EQ/skills/$PLATFORM_NAME/bucket-1/h.md"
printf 'i %s/i\n' "$BADHOME" > "$EQ/state/i.md"
printf 'j %s/j\n' "$BADHOME" > "$EQ/hooks/__pycache__/j.txt"
printf 'k %s/k\n' "$BADHOME" > "$EQ/hooks/k.pyc"
printf 'l %s/l\n' "$BADHOME" > "$EQ/hooks/l.sh.conflict-othermac"
printf 'm %s/m\n' "$BADHOME" > "$EQ/hooks/node_modules/pkg/m.js"
printf 'n %s/n claude-sync-allow-home-path\n' "$BADHOME" > "$EQ/hooks/n.sh"
printf 'o names the %s token in prose\n' "__CLAUDE""_HOME__" > "$EQ/hooks/o.sh"
printf 'p %s/p\n' "<""HOME>" > "$EQ/hooks/p.sh"
printf 'q clean\n' > "$EQ/agents/q.md"
EQLIST="$TMPROOT/agree.files"
( cd "$EQ" && find . -type f | sed 's|^\./||' | sort | tr '\n' '\0' ) > "$EQLIST"
eq_listed="$(tr '\0' '\n' < "$EQLIST" | grep -c . || true)"
out_eqw="$(bash "$CHECK" "$EQ" 2>&1)"
code_eqw=$?
out_eql="$(bash "$CHECK" --files0-from "$EQLIST" "$EQ" 2>&1)"
code_eql=$?
eq_w="$(grep '^  ' <<< "$out_eqw" | sort)"
eq_l="$(grep '^  ' <<< "$out_eql" | sort)"
[ "$code_eqw" -eq 1 ] && [ "$(grep -c . <<< "$eq_w")" -eq 7 ] \
  && check "#3465 control: the walk reports the seven lines in the places it reads" ok \
  || check "#3465 control: the walk reports the seven lines in the places it reads" "exit=$code_eqw out=$out_eqw"
[ "$code_eql" -eq "$code_eqw" ] && [ -n "$eq_l" ] && [ "$eq_l" = "$eq_w" ] \
  && check "#3465 listing every file ($eq_listed of them) reports exactly the lines the walk reports" ok \
  || check "#3465 listing every file ($eq_listed of them) reports exactly the lines the walk reports" "walk exit=$code_eqw list exit=$code_eql walk=[$eq_w] list=[$eq_l]"

# ---------------------------------------------------------------------------
# A matching line far longer than anybody reads (claude-config#3479). On 2026-11-22 a send
# published 126 scratch files whose matching lines ran to 1.6 MB each, and the check carried every
# one of them whole through the shell and printed it whole: 11.5 MB of report, and 6 to 10 seconds
# where the bare search took under one. A long line is now reported as the part around what was
# found, and it is judged by exactly the rules a short one is.
#
# So every rule is asked here about a line of 100,000 bytes or more (1.5 MB where the size itself
# is the point), with what it looks for far past any cut. A
# line cut BEFORE it is judged passes everything that sat below the cut, which is the fault this
# change could introduce, and a short fixture can never show it (L101). The reports go to files and
# the failure texts give sizes, never the output: a megabyte in a failure line buries the sentence
# saying what went wrong (L445).
# ---------------------------------------------------------------------------
filler() { # filler <bytes>  -> that many bytes of plain words on one line, with no newline
  LC_ALL=C awk -v n="$1" 'BEGIN { w = "lorem ipsum dolor sit amet consectetur adipiscing "; l = length(w)
    for (i = l; i <= n; i += l) printf "%s", w
    printf "%s", substr(w, 1, n % l) }'
}
longest_line() { LC_ALL=C awk '{ if (length($0) > m) m = length($0) } END { print m + 0 }' "$1"; }
size_of() { wc -c < "$1" | tr -d ' '; }
HALF=750000   # the size that happened: the first fixture and the allowance are asked at 1.5 MB
FAR=100000    # far past any cut, and a fifth of a megabyte a run cheaper, for the rest
LTOK="__CLAUDE""_HOME__"
LANG_TOK="<""HOME>"

LONG="$(tree long)"
{ printf 'a short first line\n'; filler "$HALF"; printf 'bash %s/.claude/x.sh ' "$BADHOME"; filler "$HALF"; printf '\n'; } > "$LONG/hooks/long.txt"
LOUT="$TMPROOT/long.out"
bash "$CHECK" "$LONG" > "$LOUT" 2>&1
code_long=$?
long_line_bytes="$(LC_ALL=C awk 'NR == 2 { print length($0) }' "$LONG/hooks/long.txt")"
long_widest="$(longest_line "$LOUT")"
[ "$code_long" -eq 1 ] \
  && check "#3479 a file whose home path sits 750,000 bytes into a line still fails" ok \
  || check "#3479 a file whose home path sits 750,000 bytes into a line still fails" "exit=$code_long, report of $(size_of "$LOUT") bytes"
grep -q "hooks/long.txt:2:" "$LOUT" \
  && check "#3479 and the report names the file and the line" ok \
  || check "#3479 and the report names the file and the line" "exit=$code_long, report of $(size_of "$LOUT") bytes"
[ "$long_widest" -le 1000 ] \
  && check "#3479 a line of $long_line_bytes bytes is reported as a part of it, never whole" ok \
  || check "#3479 a line of $long_line_bytes bytes is reported as a part of it, never whole" "the longest line of the report is $long_widest bytes, and the whole report $(size_of "$LOUT")"
grep -q "$BADHOME/.claude/x.sh" "$LOUT" \
  && check "#3479 the part reported is the part holding what was found" ok \
  || check "#3479 the part reported is the part holding what was found" "the home path is not in a report of $(size_of "$LOUT") bytes whose longest line is $long_widest"
grep -Eq "hooks/long.txt:2:.*\[line cut: bytes [0-9]+ to [0-9]+ of $long_line_bytes shown\]$" "$LOUT" \
  && check "#3479 and it says the line was cut, which bytes are shown and how long the line is" ok \
  || check "#3479 and it says the line was cut, which bytes are shown and how long the line is" "no such note in a report of $(size_of "$LOUT") bytes whose longest line is $long_widest"

# The claim under all of it, measured where it can be seen without a stopwatch: a shell that holds
# a line prints it in its own trace, so the trace of a run over a 1.5 MB line is megabytes if the
# line went through the shell and a few thousand bytes if it did not. A timing would say the same
# thing only on a quiet machine, and this one is never quiet when the suites run.
bash -x "$CHECK" "$LONG" > /dev/null 2> "$TMPROOT/long.trace"
trace_bytes="$(size_of "$TMPROOT/long.trace")"
[ "$trace_bytes" -gt 0 ] && [ "$trace_bytes" -lt 200000 ] \
  && check "#3479 the long line never passes through the shell (its trace stays small)" ok \
  || check "#3479 the long line never passes through the shell (its trace stays small)" "the shell's own trace of the run is $trace_bytes bytes, for a line of $long_line_bytes"

# The listed form is the one a send uses, and it must report what the walk reports here too.
printf 'hooks/long.txt\0' > "$TMPROOT/long.files"
bash "$CHECK" --files0-from "$TMPROOT/long.files" "$LONG" > "$LOUT.listed" 2>&1
code_long_listed=$?
grep '^  ' "$LOUT" > "$LOUT.lines"
grep '^  ' "$LOUT.listed" > "$LOUT.listed.lines"
[ "$code_long_listed" -eq 1 ] && [ -s "$LOUT.lines" ] && cmp -s "$LOUT.lines" "$LOUT.listed.lines" \
  && check "#3479 the listed form reports the long line exactly as the walk does" ok \
  || check "#3479 the listed form reports the long line exactly as the walk does" "walk exit=$code_long list exit=$code_long_listed, reports of $(size_of "$LOUT") and $(size_of "$LOUT.listed") bytes"

# A line no longer than the cut is printed as it always was, byte for byte, and one byte more is
# enough to cut it. 300 is the length the check cuts to.
EDGE="$(tree edge)"
edge_lead="bash $BADHOME/.claude/x.sh "
{ printf '%s' "$edge_lead"; filler "$((300 - ${#edge_lead}))"; printf '\n'
  printf '%s' "$edge_lead"; filler "$((301 - ${#edge_lead}))"; printf '\n'; } > "$EDGE/hooks/edge.txt"
bash "$CHECK" "$EDGE" > "$TMPROOT/edge.out" 2>&1
code_edge=$?
edge_whole="  $EDGE/hooks/edge.txt:1:$(sed -n 1p "$EDGE/hooks/edge.txt")"
[ "$code_edge" -eq 1 ] && grep -Fxq -- "$edge_whole" "$TMPROOT/edge.out" \
  && check "#3479 a line of exactly 300 bytes is reported whole, byte for byte" ok \
  || check "#3479 a line of exactly 300 bytes is reported whole, byte for byte" "exit=$code_edge out=$(cat "$TMPROOT/edge.out")"
grep -Eq "hooks/edge.txt:2:.*\[line cut: bytes 1 to 300 of 301 shown\]$" "$TMPROOT/edge.out" \
  && check "#3479 and a line of 301 bytes is cut to 300" ok \
  || check "#3479 and a line of 301 bytes is cut to 300" "exit=$code_edge out=$(cat "$TMPROOT/edge.out")"

# What is refused does not move. The marker still excuses its line from 200,000 bytes away: the
# home path is at the start, where any cut keeps it, and the marker at the far end, where a cut
# loses it.
LMARK="$(tree longmark)"
{ printf 'bash %s/.claude/x.sh ' "$BADHOME"; filler "$FAR"; filler "$FAR"; printf ' claude-sync-allow-home-path\n'; } > "$LMARK/hooks/long.txt"
bash "$CHECK" "$LMARK" > "$TMPROOT/longmark.out" 2>&1
code_lmark=$?
[ "$code_lmark" -eq 0 ] \
  && check "#3479 the marker at the far end of a long line still excuses it" ok \
  || check "#3479 the marker at the far end of a long line still excuses it" "exit=$code_lmark, report of $(size_of "$TMPROOT/longmark.out") bytes"

# The placeholder in front of a path, 100,000 bytes after a substitution that closed: allowed.
LTOKTREE="$(tree longtoken)"
{ printf 'A="${VAR}" '; filler "$FAR"; printf ' %s/skills/x/panel.js\n' "$LTOK"; } > "$LTOKTREE/hooks/long.txt"
bash "$CHECK" "$LTOKTREE" > "$TMPROOT/longtok.out" 2>&1
code_ltok=$?
[ "$code_ltok" -eq 0 ] \
  && check "#3479 the placeholder fronting a path, far into a long line, is left alone" ok \
  || check "#3479 the placeholder fronting a path, far into a long line, is left alone" "exit=$code_ltok, report of $(size_of "$TMPROOT/longtok.out") bytes"
# The same placeholder 100,000 bytes after a substitution that never closed: it is inside it.
{ printf 'A="${VAR '; filler "$FAR"; printf ' %s/skills/x/panel.js\n' "$LTOK"; } > "$LTOKTREE/hooks/long.txt"
bash "$CHECK" "$LTOKTREE" > "$TMPROOT/longtok.out" 2>&1
code_ltok2=$?
[ "$code_ltok2" -eq 1 ] && grep -q "not standing in front of a path" "$TMPROOT/longtok.out" && [ "$(longest_line "$TMPROOT/longtok.out")" -le 1000 ] \
  && check "#3479 a substitution opened 100,000 bytes before the placeholder is still refused, and cut" ok \
  || check "#3479 a substitution opened 100,000 bytes before the placeholder is still refused, and cut" "exit=$code_ltok2, report of $(size_of "$TMPROOT/longtok.out") bytes, longest line $(longest_line "$TMPROOT/longtok.out")"
# And the placeholder as the last thing on a long line, with nothing after it at all.
{ filler "$FAR"; filler "$FAR"; printf ' the %s\n' "$LTOK"; } > "$LTOKTREE/hooks/long.txt"
bash "$CHECK" "$LTOKTREE" > "$TMPROOT/longtok.out" 2>&1
code_ltok3=$?
[ "$code_ltok3" -eq 1 ] && grep -q "not standing in front of a path" "$TMPROOT/longtok.out" && grep -Eq "the ${LTOK} \[line cut: " "$TMPROOT/longtok.out" \
  && check "#3479 the placeholder ending a long line is refused, and the part shown holds it" ok \
  || check "#3479 the placeholder ending a long line is refused, and the part shown holds it" "exit=$code_ltok3, report of $(size_of "$TMPROOT/longtok.out") bytes, longest line $(longest_line "$TMPROOT/longtok.out")"

# The hand substituted placeholder, in the middle of a long line.
LANGLE="$(tree longangle)"
{ filler "$FAR"; printf ' cat %s/notes.md ' "$LANG_TOK"; filler "$FAR"; printf '\n'; } > "$LANGLE/hooks/long.txt"
bash "$CHECK" "$LANGLE" > "$TMPROOT/longangle.out" 2>&1
code_langle=$?
[ "$code_langle" -eq 1 ] && grep -q "hand substituted home placeholder" "$TMPROOT/longangle.out" && grep -Fq "cat ${LANG_TOK}/notes.md" "$TMPROOT/longangle.out" \
   && [ "$(longest_line "$TMPROOT/longangle.out")" -le 1000 ] \
  && check "#3479 the hand substituted placeholder far into a long line is refused, cut around it" ok \
  || check "#3479 the hand substituted placeholder far into a long line is refused, cut around it" "exit=$code_langle, report of $(size_of "$TMPROOT/longangle.out") bytes, longest line $(longest_line "$TMPROOT/longangle.out")"

# The live config allowance. This Mac's own config path, twice on one long line, passes in its own
# live tree; another Mac's home 750,000 bytes further along the same line does not, and the part
# shown is the other Mac's path, not the first portable one.
LLIVE="$(tree longlive)"
{ printf 'bash %s/hooks/a.sh ' "$LLIVE"; filler "$HALF"; printf ' bash %s/hooks/b.sh ' "$LLIVE"; filler "$HALF"; printf '\n'; } > "$LLIVE/hooks/long.txt"
CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LLIVE" bash "$CHECK" "$LLIVE" > "$TMPROOT/longlive.out" 2>&1
code_llive=$?
[ "$code_llive" -eq 0 ] \
  && check "#3479 this Mac's own config path, twice on a long line, passes in its live tree" ok \
  || check "#3479 this Mac's own config path, twice on a long line, passes in its live tree" "exit=$code_llive, report of $(size_of "$TMPROOT/longlive.out") bytes"
{ printf 'bash %s/hooks/a.sh ' "$LLIVE"; filler "$HALF"; printf ' bash %s/hooks/b.sh ' "$LLIVE"; filler "$HALF"
  printf ' bash %s/other-mac/.claude/hooks/other.sh ' "$TMPROOT"; filler 4000; printf '\n'; } > "$LLIVE/hooks/long.txt"
CLAUDE_HOME_PATH_ROOTS="$TMPROOT" CLAUDE_HOME="$LLIVE" bash "$CHECK" "$LLIVE" > "$TMPROOT/longlive.out" 2>&1
code_llive2=$?
[ "$code_llive2" -eq 1 ] && grep -q "other-mac/.claude/hooks/other.sh" "$TMPROOT/longlive.out" && [ "$(longest_line "$TMPROOT/longlive.out")" -le 1000 ] \
  && check "#3479 another Mac's home at the far end of that line is refused, and is the part shown" ok \
  || check "#3479 another Mac's home at the far end of that line is refused, and is the part shown" "exit=$code_llive2, report of $(size_of "$TMPROOT/longlive.out") bytes, longest line $(longest_line "$TMPROOT/longlive.out")"

# The step that judges each line is a separate program, and a judge that broke must never read as
# a clean tree: nothing it did not judge can be called clean (L98). Two ways it can break, each
# with a stand in put first on the path: one that fails, and one that ends well having said
# nothing. The stand in is only itself when asked to judge, so nothing else the check runs breaks.
REAL_AWK="$(command -v awk)"
mkdir -p "$TMPROOT/awk-fails" "$TMPROOT/awk-silent"
printf '#!/bin/sh\n[ -n "${HP_TOKEN:-}" ] && exit 3\nexec "%s" "$@"\n' "$REAL_AWK" > "$TMPROOT/awk-fails/awk"
printf '#!/bin/sh\n[ -n "${HP_TOKEN:-}" ] && { cat > /dev/null; exit 0; }\nexec "%s" "$@"\n' "$REAL_AWK" > "$TMPROOT/awk-silent/awk"
chmod +x "$TMPROOT/awk-fails/awk" "$TMPROOT/awk-silent/awk"
out_jf="$(PATH="$TMPROOT/awk-fails:$PATH" bash "$CHECK" "$BAD" 2>&1)"
code_jf=$?
[ "$code_jf" -eq 2 ] && grep -q "could not be judged" <<< "$out_jf" \
  && check "#3479 a judging step that fails is exit 2 and says so, never a clean tree" ok \
  || check "#3479 a judging step that fails is exit 2 and says so, never a clean tree" "exit=$code_jf out=$out_jf"
out_js="$(PATH="$TMPROOT/awk-silent:$PATH" bash "$CHECK" "$BAD" 2>&1)"
code_js=$?
[ "$code_js" -eq 2 ] && grep -q "could not be judged" <<< "$out_js" \
  && check "#3479 a judging step that ends well having judged nothing is exit 2 too" ok \
  || check "#3479 a judging step that ends well having judged nothing is exit 2 too" "exit=$code_js out=$out_js"
out_jc="$(PATH="$TMPROOT/awk-silent:$PATH" bash "$CHECK" "$GOOD" 2>&1)"
code_jc=$?
[ "$code_jc" -eq 2 ] \
  && check "#3479 and that holds on a tree with nothing to refuse, where silence would read as clean" ok \
  || check "#3479 and that holds on a tree with nothing to refuse, where silence would read as clean" "exit=$code_jc out=$out_jc"

# ---------------------------------------------------------------------------
# A line holding a byte that is not valid text (claude-config#3538). Measured on 2026-11-24 with
# the grep macOS ships, under en_US.UTF-8: the search lost 17 of 23 matching lines that held such a
# byte, with exit 0, nothing on stderr and no "Binary file matches", so a home path on one of those
# lines passed. Under LC_ALL=C the same search found all 23.
#
# The locale is SET for every run below, never inherited, because the fault shows in one locale and
# not the other: a suite started under C would pass over the unfixed check and prove nothing
# (L411). Each case is asked in a UTF-8 locale and in C, and when this machine has no UTF-8 locale
# the suite says so rather than counting the C runs twice.
#
# Every odd byte is a printf octal escape, so this file itself stays plain text.
# ---------------------------------------------------------------------------
utf8_locale=""
for _cand in en_US.UTF-8 C.UTF-8 en_US.utf8 C.utf8; do
  if [ "$(LC_ALL="$_cand" locale charmap 2>/dev/null)" = "UTF-8" ]; then utf8_locale="$_cand"; break; fi
done
ODD_LOCALES="C"
if [ -n "$utf8_locale" ]; then
  ODD_LOCALES="$utf8_locale C"
else
  echo "  (UNMEASURED: this machine has no UTF-8 locale, so the #3538 cases ran under C only, where the fault never showed)"
fi
H1="name one machine's home directory"
H2="write the sync's placeholder somewhere"
H3="carry the hand substituted home placeholder"
valid_text() { iconv -f UTF-8 -t UTF-8 < "$1" > /dev/null 2>&1; }
# The start of a report for a failure message, its odd bytes made visible. head reads the file
# itself and cat reads all head gives it, so nothing here leaves a pipe early (claude-config#162).
peek() { head -c "$2" "$1" | LC_ALL=C cat -v; } # peek <file> <bytes>
ODD_N=0
odd_case() { # odd_case <what the line is> <line number> <the rule's heading> <text the report must show> <printf format> [args]
  local what="$1" lineno="$2" heading="$3" needle="$4" fmt="$5"; shift 5
  local root loc out code n
  ODD_N=$((ODD_N + 1))
  root="$(tree "odd$ODD_N")"
  # shellcheck disable=SC2059
  printf "$fmt" "$@" > "$root/hooks/odd.txt"
  for loc in $ODD_LOCALES; do
    out="$TMPROOT/odd$ODD_N.$loc.out"
    LC_ALL="$loc" bash "$CHECK" "$root" > "$out" 2>&1
    code=$?
    n="$(LC_ALL=C grep -a -F -- "hooks/odd.txt:$lineno:" "$out" | LC_ALL=C grep -a -c -F -- "$needle" || true)"
    [ "$code" -eq 1 ] && [ "${n:-0}" -eq 1 ] && LC_ALL=C grep -a -q -F -- "$heading" "$out" \
      && check "#3538 $what is reported with its file and line (locale $loc)" ok \
      || check "#3538 $what is reported with its file and line (locale $loc)" "exit=$code, ${n:-0} reported line(s) name hooks/odd.txt:$lineno: and show it: $(peek "$out" 500)"
  done
}
# Rule 1, a home path, with the byte in each place it was measured to hide the line.
odd_case "a home path after a byte that is not valid text" 1 "$H1" "$BADHOME/one" 'x \377 %s/one\n' "$BADHOME"
odd_case "a home path touching such a byte" 1 "$H1" "$BADHOME/two" '\377%s/two\n' "$BADHOME"
odd_case "a home path after a character cut short" 1 "$H1" "$BADHOME/three" 'x \303 %s/three\n' "$BADHOME"
odd_case "a home path after a Latin-1 letter" 1 "$H1" "$BADHOME/four" 'caf\351 %s/four\n' "$BADHOME"
odd_case "a home path before such a byte" 1 "$H1" "$BADHOME/five" '%s/five \377 tail\n' "$BADHOME"
# Rule 2, the sync's placeholder where it fronts no path.
odd_case "the placeholder with such a byte right after it" 1 "$H2" "the $LTOK" 'the %s\377 token\n' "$LTOK"
odd_case "the placeholder after such a byte" 1 "$H2" "the $LTOK token" '\377 the %s token\n' "$LTOK"
odd_case "the placeholder ending a line on a character cut short" 1 "$H2" "x $LTOK" 'x %s\303\n' "$LTOK"
# Rule 3, the hand substituted placeholder.
odd_case "the hand substituted placeholder after such a byte" 1 "$H3" "$LANG_TOK/skills/x" '\377 %s/skills/x\n' "$LANG_TOK"
odd_case "the hand substituted placeholder with such a byte right after it" 1 "$H3" "$LANG_TOK" 'see %s\377/skills/x\n' "$LANG_TOK"
# The byte on ANOTHER line than the finding. A search that calls the whole file binary over one
# such byte (GNU grep does, in a UTF-8 locale) would skip the file with -I and report nothing.
odd_case "a home path on the line after one holding such a byte" 2 "$H1" "$BADHOME/six" 'first \377 line\n%s/six\n' "$BADHOME"
odd_case "a home path on the line before one holding such a byte" 1 "$H1" "$BADHOME/seven" '%s/seven\nlater \377 line\n' "$BADHOME"
# The marker excuses its own line and no other, in a file holding such bytes too.
odd_case "an unmarked line below a marked one, each holding such a byte," 2 "$H1" "$BADHOME/eight" \
  'plain %s/excused claude-sync-allow-home-path \n\377 %s/eight\n' "$BADHOME" "$BADHOME"
for loc in $ODD_LOCALES; do
  ! LC_ALL=C grep -a -q -F -- "hooks/odd.txt:1:" "$TMPROOT/odd$ODD_N.$loc.out" \
    && check "#3538 and the marked line above it stays excused (locale $loc)" ok \
    || check "#3538 and the marked line above it stays excused (locale $loc)" "$(peek "$TMPROOT/odd$ODD_N.$loc.out" 500)"
done

# Nothing after such a line is lost. A filter that reads the search's output and meets a byte it
# calls binary can stop printing there (L329), so the findings that sort after it are the ones at
# risk: three files, the odd one in the middle, and all three reported.
ODDSEQ="$(tree oddseq)"
printf 'plain %s/first\n' "$BADHOME" > "$ODDSEQ/hooks/a.txt"
printf 'x \377 %s/second\n' "$BADHOME" > "$ODDSEQ/hooks/b.txt"
printf 'plain %s/third\n' "$BADHOME" > "$ODDSEQ/hooks/c.txt"
printf 'plain %s/fourth\n' "$BADHOME" > "$ODDSEQ/skills/demo/SKILL.md"
for loc in $ODD_LOCALES; do
  LC_ALL="$loc" bash "$CHECK" "$ODDSEQ" > "$TMPROOT/oddseq.out" 2>&1
  code_seq=$?
  seq_n="$(LC_ALL=C grep -a -c -E -- "hooks/(a|b|c)\.txt:1:|skills/demo/SKILL\.md:1:" "$TMPROOT/oddseq.out" || true)"
  [ "$code_seq" -eq 1 ] && [ "${seq_n:-0}" -eq 4 ] \
    && check "#3538 every finding beside a line holding such a byte is still reported (locale $loc)" ok \
    || check "#3538 every finding beside a line holding such a byte is still reported (locale $loc)" "exit=$code_seq, ${seq_n:-0} of 4 findings reported: $(peek "$TMPROOT/oddseq.out" 600)"
  # The listed form is a search of its own, the one a send runs, and must not lose the line either.
  printf 'hooks/a.txt\0hooks/b.txt\0hooks/c.txt\0skills/demo/SKILL.md\0' > "$TMPROOT/oddseq.files"
  LC_ALL="$loc" bash "$CHECK" --files0-from "$TMPROOT/oddseq.files" "$ODDSEQ" > "$TMPROOT/oddseq.listed.out" 2>&1
  code_seql=$?
  LC_ALL=C grep -a '^  ' "$TMPROOT/oddseq.out" | LC_ALL=C sort > "$TMPROOT/oddseq.lines"
  LC_ALL=C grep -a '^  ' "$TMPROOT/oddseq.listed.out" | LC_ALL=C sort > "$TMPROOT/oddseq.listed.lines"
  [ "$code_seql" -eq 1 ] && [ -s "$TMPROOT/oddseq.lines" ] && cmp -s "$TMPROOT/oddseq.lines" "$TMPROOT/oddseq.listed.lines" \
    && [ "$(LC_ALL=C grep -a -c -F -- "hooks/b.txt:1:" "$TMPROOT/oddseq.listed.out" || true)" -eq 1 ] \
    && check "#3538 the listed form reports those lines exactly as the walk does (locale $loc)" ok \
    || check "#3538 the listed form reports those lines exactly as the walk does (locale $loc)" "walk exit=$code_seq list exit=$code_seql: $(peek "$TMPROOT/oddseq.listed.out" 600)"
done

# The report stays text a person and a program can both read. Each byte that is not valid text is
# shown as a backslash and its octal value, with a note of how many there are, so the path beside
# it is still on the line and the report is valid text whatever the file held. Valid text is
# reported byte for byte, as it always was, whatever characters it holds.
SHOW="$(tree oddshow)"
printf 'x \377 %s/one \303 two\n' "$BADHOME" > "$SHOW/hooks/a.txt"
printf 'caf\303\251 \342\202\254 \360\237\230\200 %s/valid\n' "$BADHOME" > "$SHOW/hooks/b.txt"
for loc in $ODD_LOCALES; do
  SOUT="$TMPROOT/oddshow.$loc.out"
  LC_ALL="$loc" bash "$CHECK" "$SHOW" > "$SOUT" 2>&1
  code_show=$?
  # The fixture really is not valid text, or a report passing the same test would prove nothing.
  ! valid_text "$SHOW/hooks/a.txt" && [ "$code_show" -eq 1 ] && valid_text "$SOUT" \
    && check "#3538 the report of a line holding such bytes is itself valid text (locale $loc)" ok \
    || check "#3538 the report of a line holding such bytes is itself valid text (locale $loc)" "exit=$code_show: $(peek "$SOUT" 600)"
  LC_ALL=C grep -a -q -F -- "hooks/a.txt:1:x \\377 $BADHOME/one \\303 two [2 bytes that are not valid text, each shown as a backslash and its octal value]" "$SOUT" \
    && check "#3538 each such byte is shown as its octal value beside the path, and counted (locale $loc)" ok \
    || check "#3538 each such byte is shown as its octal value beside the path, and counted (locale $loc)" "exit=$code_show: $(peek "$SOUT" 600)"
  LC_ALL=C grep -a -q -F -x -- "  $SHOW/hooks/b.txt:1:$(cat "$SHOW/hooks/b.txt")" "$SOUT" \
    && check "#3538 a line of valid text, accents and all, is reported byte for byte (locale $loc)" ok \
    || check "#3538 a line of valid text, accents and all, is reported byte for byte (locale $loc)" "exit=$code_show: $(peek "$SOUT" 600)"
done

# A long line is cut to a count of bytes, and a cut that lands inside a character would leave half
# of one at the edge of the report: not valid text, from a file that is. So the cut moves to the
# nearest whole character, and the note gives the bytes really shown. Two fixtures, each proved to
# split a character when cut at the plain byte count, or the test would pass without the care.
euros() { LC_ALL=C awk -v n="$1" 'BEGIN { for (i = 0; i < n; i++) printf "\342\202\254" }'; }
CUTV="$(tree oddcut)"
# The end of the cut: a home path at the start (43 bytes), then three byte characters, so byte 300
# is the second byte of one.
{ printf 'bash %s/.claude/x.sh ' "$BADHOME"; euros 200; printf '\n'; } > "$CUTV/hooks/tail.txt"
# The start of the cut: 60 bytes before the home path is the second byte of a three byte character.
{ printf 'x'; euros 300; printf '\303\251bash %s/.claude/x.sh ' "$BADHOME"; filler 400; printf '\n'; } > "$CUTV/hooks/head.txt"
cut_tail_len="$(LC_ALL=C awk '{ print length($0) }' "$CUTV/hooks/tail.txt")"
cut_head_len="$(LC_ALL=C awk '{ print length($0) }' "$CUTV/hooks/head.txt")"
head -c 300 "$CUTV/hooks/tail.txt" > "$TMPROOT/oddcut.tail.plain"
dd if="$CUTV/hooks/head.txt" of="$TMPROOT/oddcut.head.plain" bs=1 skip=848 count=300 2> /dev/null
for loc in $ODD_LOCALES; do
  COUT="$TMPROOT/oddcut.$loc.out"
  LC_ALL="$loc" bash "$CHECK" "$CUTV" > "$COUT" 2>&1
  code_cutv=$?
  ! valid_text "$TMPROOT/oddcut.tail.plain" && ! valid_text "$TMPROOT/oddcut.head.plain" \
    && [ "$code_cutv" -eq 1 ] && valid_text "$COUT" && ! LC_ALL=C grep -a -q "not valid text" "$COUT" \
    && check "#3538 a cut never leaves half a character, or calls valid text invalid (locale $loc)" ok \
    || check "#3538 a cut never leaves half a character, or calls valid text invalid (locale $loc)" "exit=$code_cutv: $(peek "$COUT" 900)"
  LC_ALL=C grep -a -q -E -- "hooks/tail\.txt:1:bash $BADHOME/\.claude/x\.sh .* \[line cut: bytes 1 to 298 of $cut_tail_len shown\]$" "$COUT" \
    && LC_ALL=C grep -a -q -E -- "hooks/head\.txt:1:.*$BADHOME/\.claude/x\.sh .* \[line cut: bytes 851 to 1148 of $cut_head_len shown\]$" "$COUT" \
    && check "#3538 and the note names the bytes really shown (locale $loc)" ok \
    || check "#3538 and the note names the bytes really shown (locale $loc)" "exit=$code_cutv: $(peek "$COUT" 900)"
done

# ---------------------------------------------------------------------------
# The real tree this file lives in, which is the whole point. It runs LAST, so
# by the time it reports clean the scanner has been watched failing four ways.
# ---------------------------------------------------------------------------
out_real="$(bash "$CHECK" 2>&1)"
code_real=$?
[ "$code_real" -eq 0 ] \
  && check "the synced config here names no machine's home directory" ok \
  || check "the synced config here names no machine's home directory" "exit=$code_real out=$out_real"

# ---------------------------------------------------------------------------
# The checkout this copy is the payload of, scanned the way a push needs it (claude-config#1734).
# On 2026-10-25 a fixture naming this machine's home reached CI in PR #1732 because only CI ran
# this suite: the gate before a push (scanners-before-push.sh) runs the suites that list the
# repository's own files, and this one only walked folders. So here it lists them, and is run there.
#
# Two things make this the form that flags ANY machine's home. CLAUDE_HOME points at nowhere, so
# the live config allowance (a path under this Mac's own config directory) can never excuse a line,
# however the folders are linked (L177). And the files the check read are counted against what the
# repository holds in the synced folders, so a scan that read fewer than that cannot report clean
# over the rest (L98). Installed in ~/.claude there is no checkout, and the line above is the scan.
# ---------------------------------------------------------------------------
CO="$(bash "$DIR/lib/checkout-root.sh" "$DIR/.." 2>/dev/null || true)"
if [ -n "$CO" ]; then
  out_co="$(CLAUDE_HOME="$TMPROOT/no-live-config" bash "$CHECK" "$CO/payload" 2>&1)"
  code_co=$?
  [ "$code_co" -eq 0 ] \
    && check "#1734 the checkout's synced files name no machine's home, this one's included" ok \
    || check "#1734 the checkout's synced files name no machine's home, this one's included" "exit=$code_co out=$out_co"
  # The folders are the sync's own list (#2754), so a tree added to it is counted here too.
  co_specs=()
  while IFS= read -r t; do [ -n "$t" ] && co_specs+=("payload/$t"); done <<< "$TREES"
  if [ "${#co_specs[@]}" -gt 0 ] && co_files="$(bash "$DIR/lib/repo-files.sh" "$CO" "${co_specs[@]}" ':(glob)payload/*.md')"; then
    co_n="$(printf '%s\n' "$co_files" | grep -c . || true)"
    read_n="$(sed -n 's/^check-home-paths: \([0-9][0-9]*\) file(s) under .*/\1/p' <<< "$out_co")"
    [ "$co_n" -gt 0 ] && [ -n "$read_n" ] && [ "$read_n" -ge "$co_n" ] \
      && check "#1734 and it read every file the repository holds in the synced folders" ok \
      || check "#1734 and it read every file the repository holds in the synced folders" "the repository lists ${co_n} there and the check read ${read_n:-no count}: $out_co"
  else
    check "#1734 and it read every file the repository holds in the synced folders" "lib/repo-files.sh could not list $CO, so what the check should have read is unknown"
  fi
  # The same checkout asked the way a send asks (claude-config#3465): every file under payload
  # listed. It must give the walk's verdict and read at least as many of the repository's files, or
  # a send would be held over a tree main's own run passes, or let through one it fails (L147).
  COLIST="$TMPROOT/checkout.files"
  ( cd "$CO/payload" && find . -type f | sed 's|^\./||' | tr '\n' '\0' ) > "$COLIST"
  out_col="$(CLAUDE_HOME="$TMPROOT/no-live-config" bash "$CHECK" --files0-from "$COLIST" "$CO/payload" 2>&1)"
  code_col=$?
  [ "$code_col" -eq "$code_co" ] \
    && check "#3465 the checkout's files, listed, get the verdict the walk gives" ok \
    || check "#3465 the checkout's files, listed, get the verdict the walk gives" "walk exit=$code_co list exit=$code_col out=$out_col"
  read_l="$(sed -n 's/^check-home-paths: \([0-9][0-9]*\) of [0-9][0-9]* listed file(s) .*/\1/p' <<< "$out_col")"
  [ -n "${co_n:-}" ] && [ "${co_n:-0}" -gt 0 ] && [ -n "$read_l" ] && [ "$read_l" -ge "$co_n" ] \
    && check "#3465 and the listed form read every file the repository holds in the synced folders" ok \
    || check "#3465 and the listed form read every file the repository holds in the synced folders" "the repository lists ${co_n:-no count} there and the listed form read ${read_l:-no count}: $out_col"
else
  echo "  (no claude-config checkout above $DIR, so only the scan above ran; the checkout form runs where the repository is)"
fi

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
