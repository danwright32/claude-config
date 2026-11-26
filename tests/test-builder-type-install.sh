#!/usr/bin/env bash
# The sync writes the builder agent type on each Mac and never carries it (claude-config#3389).
#
# Dan chose on 2026-11-25 ("3.35.1 Each Mac writes its own (Recommended)") that the builder agent
# type is written on each Mac from that Mac's own installed rules, at every apply and send, and is
# never published. The written file sits inside agents/, a tree the sync MIRRORS with --delete in
# both directions, so two things would undo it without an exclusion: a send would publish one Mac's
# copy (which holds whatever that Mac's rules import, a local project list included), and an apply
# would delete the copy from a Mac because the payload does not hold it. claude-sync's WRITTEN_HERE
# names the one file, and this suite proves, on two fixture Macs and a fixture shared repository:
#   1. the list holds exactly that one path;
#   2. the exclusion alone, with no renderer installed anywhere: a copy already written on each Mac
#      is never sent and never deleted, across two sends and two pulls (the second pull is the one
#      that exposes a protection derived from the payload), while an ordinary agent beside it does
#      travel, edit and deletion both;
#   3. a fresh Mac whose agents folder holds only the written type does not clear the shared agents
#      (the written file is not content a send would carry);
#   4. the write: with the renderer installed, a send and an apply each write the type from that
#      Mac's own rules, a run that changes nothing does not rewrite the file, and a render that
#      fails says so, fails nothing else and leaves the earlier copy as it was;
#   5. status does not list the written file as an edit waiting to be sent.
# Every home, clone and repository here is a fixture under a temp folder. Nothing reads or writes
# the real home.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPT="$ROOT/claude-sync"
. "$ROOT/payload/hooks/lib/suite-deadline.sh" || {
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
absent(){ [ ! -e "$1" ]; }
in_repo(){ git -C "$BARE" cat-file -e "main:$1" 2>/dev/null; }
not_in_repo(){ ! in_repo "$1"; }
inode(){ ls -i "$1" 2>/dev/null | awk '{print $1}'; }
same_inode(){ [ -n "$2" ] && [ "$(inode "$1")" = "$2" ]; }

for tool in git rsync python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "FAIL: $tool is not on PATH, so this suite cannot run."
    printf 'SUITE-RESULT passed=0 failed=1\n'
    exit 1
  fi
done

_tmp="${TMPDIR:-/tmp}"
WORK="$(mktemp -d "${_tmp%/}/builder-type-install.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# ---------------------------------------------------------------- 1. the one entry
WRITTEN_HERE=()
eval "$(grep -E '^WRITTEN_HERE=\(' "$SCRIPT")"
check "the script's WRITTEN_HERE could be read" [ "${#WRITTEN_HERE[@]}" -gt 0 ]
check "it holds exactly one path (${WRITTEN_HERE[*]:-none})" [ "${#WRITTEN_HERE[@]}" -eq 1 ]
check "and that path is agents/builder.md" [ "${WRITTEN_HERE[0]:-}" = "agents/builder.md" ]
check "no rendered copy is tracked in this repository" [ -z "$(git -C "$ROOT" ls-files --cached -- payload/agents/builder.md)" ]
check "nor sitting in this checkout's payload" absent "$ROOT/payload/agents/builder.md"

# ---------------------------------------------------------------- the fixture
BARE="$WORK/shared.git"; git init -q --bare -b main "$BARE"
RA="$WORK/cloneA"; RB="$WORK/cloneB"
git clone -q "$BARE" "$RA" 2>/dev/null; git clone -q "$BARE" "$RB" 2>/dev/null
CA="$WORK/macA/.claude"; CB="$WORK/macB/.claude"
mkdir -p "$CA/agents" "$CB/agents" "$WORK/sync-home-A" "$WORK/sync-home-B" "$WORK/sync-home-C"
printf '{"hooks":{}}\n' > "$CA/settings.json"; printf '{"hooks":{}}\n' > "$CB/settings.json"
rules(){   # $1 = a home  $2 = a sentence only this copy of the rules holds
  cat > "$1/CLAUDE.md" <<RULES
# Fixture rules

## Code Standards

- Use 2 space indentation where no config exists.
- $2
RULES
}
rules "$CA" "Fixture rule as first written."
rules "$CB" "Fixture rule as first written."
printf -- '---\nname: fixture-agent\ndescription: an ordinary agent the sync carries\n---\nfirst\n' > "$CA/agents/fixture-agent.md"
printf 'the type as Mac A wrote it\n' > "$CA/agents/builder.md"
printf 'the type as Mac B wrote it\n' > "$CB/agents/builder.md"
cp "$CA/agents/builder.md" "$WORK/a-before"; cp "$CB/agents/builder.md" "$WORK/b-before"
SENV=(SYNC_NO_NOTIFY=1 SYNC_NO_HOOK_TESTS=1 SYNC_NO_SEND_TESTS=1 SYNC_CLAUDE_BIN="$WORK/no-claude")
syncA(){ env "${SENV[@]}" HOME="$WORK/sync-home-A" CLAUDE_HOME="$CA" SYNC_REPO="$RA" SYNC_HOSTNAME=fixtureMacA bash "$SCRIPT" "$@" 2>&1; }
syncB(){ env "${SENV[@]}" HOME="$WORK/sync-home-B" CLAUDE_HOME="$CB" SYNC_REPO="$RB" SYNC_HOSTNAME=fixtureMacB bash "$SCRIPT" "$@" 2>&1; }

# ---------------------------------------------------------------- 2. the exclusion alone
# No renderer is installed on either Mac here, so nothing below is the write step putting a file
# back: what stays is what the mirror left alone.
out="$(syncA send)"
said_early="$out"
check "(control) an ordinary agent beside it reached the shared repository: $out" in_repo payload/agents/fixture-agent.md
check "a send does not publish the written type" not_in_repo payload/agents/builder.md
check "nor leave it in the sending clone's payload" absent "$RA/payload/agents/builder.md"
check "and the sending Mac keeps its own copy" cmp -s "$CA/agents/builder.md" "$WORK/a-before"
out="$(syncB pull)"
said_early="$said_early$out"
check "(control) the pull brought the ordinary agent to Mac B: $out" [ -f "$CB/agents/fixture-agent.md" ]
check "an apply leaves an already written type in place, byte for byte" cmp -s "$CB/agents/builder.md" "$WORK/b-before"
# The second round: the payload has now been applied here once without the file, which is the run
# where a protection derived from what the payload holds would be gone.
printf -- '---\nname: fixture-agent\ndescription: an ordinary agent the sync carries\n---\nsecond\n' > "$CA/agents/fixture-agent.md"
out="$(syncA send)"
out="$(syncB pull)"
check "(control) the second pull brought the agent's edit to Mac B: $out" grep -q '^second$' "$CB/agents/fixture-agent.md"
check "the second apply leaves the written type in place too" cmp -s "$CB/agents/builder.md" "$WORK/b-before"
out="$(syncB send)"
check "a send from the receiving Mac does not publish its copy either: $out" not_in_repo payload/agents/builder.md
# The mirror still deletes what it should: the ordinary agent, deleted on A, goes from B.
rm -f "$CA/agents/fixture-agent.md"
printf -- '---\nname: other-agent\ndescription: a second ordinary agent\n---\nbody\n' > "$CA/agents/other-agent.md"
out="$(syncA send)"
out="$(syncB pull)"
check "(control) a deleted ordinary agent is still deleted on the receiving Mac: $out" absent "$CB/agents/fixture-agent.md"
check "while the written type stays" cmp -s "$CB/agents/builder.md" "$WORK/b-before"
out="$(syncA status)"
check "status on the sending Mac does not list the written type as an edit to send: $out" lacks "$out" "agents/builder.md"
# A Mac with no renderer installed is left alone, without a word: there is nothing to write from.
check "with no renderer installed, the send and the pull said nothing about writing the type" lacks "$said_early" "agents/builder.md"

# ---------------------------------------------------------------- 3. a fresh Mac holding only the type
RC="$WORK/cloneC"; git clone -q "$BARE" "$RC" 2>/dev/null
CC="$WORK/macC/.claude"; mkdir -p "$CC/agents"
printf '{"hooks":{}}\n' > "$CC/settings.json"; rules "$CC" "Fixture rule as first written."
printf 'the type as a fresh Mac wrote it\n' > "$CC/agents/builder.md"
out="$(env "${SENV[@]}" HOME="$WORK/sync-home-C" CLAUDE_HOME="$CC" SYNC_REPO="$RC" SYNC_HOSTNAME=fixtureMacC bash "$SCRIPT" send 2>&1 || true)"
check "a fresh Mac whose agents folder holds only the written type does not clear the shared agents: $out" in_repo payload/agents/other-agent.md
check "nor publish its copy" not_in_repo payload/agents/builder.md

# ---------------------------------------------------------------- 4. the write
# The renderer arrives the way it does on a real Mac: installed in one home and carried by the sync.
mkdir -p "$CA/skills/orchestrate"
cp "$ROOT/payload/skills/orchestrate/render-builder-type.py" "$ROOT/payload/skills/orchestrate/builder-type-head.md" \
   "$ROOT/payload/skills/orchestrate/builder-type-rules.tsv" "$CA/skills/orchestrate/"
printf -- '---\nname: orchestrate\ndescription: a fixture copy holding the renderer\n---\nbody\n' > "$CA/skills/orchestrate/SKILL.md"
out="$(syncA pull)"
out="$(syncA send)"
check "(setup) the renderer reached the shared repository: $out" in_repo payload/skills/orchestrate/render-builder-type.py
check "a send writes the type on the sending Mac" grep -q '^name: builder$' "$CA/agents/builder.md"
check "from that Mac's own installed rules" grep -q 'Fixture rule as first written\.' "$CA/agents/builder.md"
check "replacing the copy that was there" lacks "$(cat "$CA/agents/builder.md")" "the type as Mac A wrote it"
check "and the send that wrote it did not publish it" not_in_repo payload/agents/builder.md
check "nor leave it in the sending clone's payload" absent "$RA/payload/agents/builder.md"
check "nor leave a temporary file in the agents folder" [ "$(ls -A "$CA/agents" | sort | tr '\n' ' ')" = "builder.md other-agent.md " ]
out="$(syncB pull)"
check "(setup) the pull installed the renderer on Mac B: $out" [ -f "$CB/skills/orchestrate/render-builder-type.py" ]
check "an apply writes the type on the receiving Mac" grep -q '^name: builder$' "$CB/agents/builder.md"
check "and the pull says it wrote it" has "$out" "agents/builder.md"
# Each Mac's copy is a function of ITS rules: B changes a rule and has not sent it yet when it
# writes, so its type holds the new sentence while A's still holds the old one.
rules "$CB" "Fixture rule as Mac B changed it."
ino_a="$(inode "$CA/agents/builder.md")"
out="$(syncB send)"
check "after Mac B changes a rule, its send writes its type with the changed rule: $out" grep -q 'Fixture rule as Mac B changed it\.' "$CB/agents/builder.md"
check "while Mac A's type still holds the rule Mac A has installed" grep -q 'Fixture rule as first written\.' "$CA/agents/builder.md"
check "and nothing published either copy" not_in_repo payload/agents/builder.md
# A run that changes nothing does not rewrite the file: the watcher sends on every change under
# agents/, so a rewrite on every send would never settle.
ino_b="$(inode "$CB/agents/builder.md")"
out="$(syncB send)"
check "a send that changes nothing leaves the written file untouched, same inode" same_inode "$CB/agents/builder.md" "$ino_b"
check "and Mac A's file was not rewritten by Mac B's sends" same_inode "$CA/agents/builder.md" "$ino_a"
out="$(syncA pull)"
check "once Mac A pulls the changed rule, its type holds it: $out" grep -q 'Fixture rule as Mac B changed it\.' "$CA/agents/builder.md"
out="$(syncA status)"
check "status does not list the written type as an edit to send: $out" lacks "$out" "agents/builder.md"
# A render that fails: said, nothing else fails, and the earlier copy stays whole.
cp "$CB/agents/builder.md" "$WORK/b-whole"
# The head is this Mac's own unsent deletion, which a pull holds back rather than restoring, so
# the renderer runs with a source missing.
mv "$CB/skills/orchestrate/builder-type-head.md" "$WORK/b-head-aside"
out="$(syncB pull; printf 'exit=%s\n' "$?")"
check "(setup) the head is still missing when the write runs" absent "$CB/skills/orchestrate/builder-type-head.md"
check "a render that fails is said, naming the file not written: $out" has "$out" "agents/builder.md was NOT written"
check "and the pull itself still succeeds" has "$out" "exit=0"
check "and the earlier copy is left exactly as it was" cmp -s "$CB/agents/builder.md" "$WORK/b-whole"

printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
