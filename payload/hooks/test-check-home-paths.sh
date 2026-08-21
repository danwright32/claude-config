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
printf '%s' "$out_bad" | grep -q "skills/demo/SKILL.md" \
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
<HOME>/.claude/skills/plan-council/panel.workflow.js
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
printf '%s' "$out_mixed" | grep -q "other.sh" \
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
# The real tree this file lives in, which is the whole point. It runs LAST, so
# by the time it reports clean the scanner has been watched failing four ways.
# ---------------------------------------------------------------------------
out_real="$(bash "$CHECK" 2>&1)"
code_real=$?
[ "$code_real" -eq 0 ] \
  && check "the synced config here names no machine's home directory" ok \
  || check "the synced config here names no machine's home directory" "exit=$code_real out=$out_real"

echo "passed: $pass, failed: $fail"
[ "$fail" -eq 0 ]
