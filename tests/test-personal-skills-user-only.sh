#!/usr/bin/env bash
# Dan's personal skills are typed by him, never listed to Claude (hook trim, 2026-10-15).
#
# Every skill Claude can invoke is listed with its description on every request of every session,
# in every project. coffee-profile, reel-plan, dan-wright-brand-voice, tracker and brag-slim are
# Dan's own errands, started by him by name, and in a work repository like Slate they were about
# 1.7K characters of the listing on every request. `disable-model-invocation: true` in a skill's
# frontmatter takes it out of that listing and keeps it on the / menu, so he can still type it
# anywhere. It is frontmatter rather than a skillOverrides entry because the choice belongs to the
# skill: it travels with the skill file to both Macs, where an override would be a second place to
# keep in step with it.
#
# brag-slim's description names a /brag skill that "hands off here", which is a model invocation and
# would be refused with this key. No /brag skill is installed (none in payload/skills, none on the
# work MacBook on 2026-10-15); if one is ever added, take brag-slim out of this list in the same change.
#
# The set is named here, not derived: which skills are personal is a decision, and the check is that
# the decision stays applied. Each must exist, so a rename cannot leave the check passing over
# nothing (L98), and the one key must sit inside the frontmatter, never in the body (L135).
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$DIR/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?
SKILLS="$DIR/../payload/skills"
pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}

frontmatter_value(){   # $1 = SKILL.md  $2 = key: the key's value inside the leading --- block, or nothing
  awk -v key="$2" '
    NR == 1 && $0 != "---" { exit }
    NR > 1 && $0 == "---" { exit }
    NR > 1 && index($0, key ":") == 1 { v = substr($0, length(key) + 2); sub(/^[ \t]+/, "", v); print v; exit }
  ' "$1"
}

for s in coffee-profile reel-plan dan-wright-brand-voice tracker brag-slim; do
  f="$SKILLS/$s/SKILL.md"
  if [ ! -f "$f" ]; then
    check "$s exists" "no SKILL.md at $f"
    continue
  fi
  v="$(frontmatter_value "$f" disable-model-invocation)"
  [ "$v" = "true" ] && check "$s is user invoked only" ok \
    || check "$s is user invoked only" "disable-model-invocation is [${v:-absent}] in its frontmatter"
  # Still a skill he can type: it keeps its name and description.
  [ "$(frontmatter_value "$f" name)" = "$s" ] && check "$s keeps its name" ok \
    || check "$s keeps its name" "name is [$(frontmatter_value "$f" name)]"
done

# Control: the reader must see a key that is there and miss one that is only in the body.
CTL="$(mktemp -d "${TMPDIR:-/tmp}/personal-skills.XXXXXX")" || exit 2
trap 'rm -rf "$CTL"' EXIT
printf -- '---\nname: x\ndisable-model-invocation: true\n---\nbody\n' > "$CTL/in.md"
printf -- '---\nname: x\n---\ndisable-model-invocation: true\n' > "$CTL/body.md"
[ "$(frontmatter_value "$CTL/in.md" disable-model-invocation)" = "true" ] && check "control: a frontmatter key is read" ok \
  || check "control: a frontmatter key is read" "it was missed"
[ -z "$(frontmatter_value "$CTL/body.md" disable-model-invocation)" ] && check "control: the same line in the body is not" ok \
  || check "control: the same line in the body is not" "it was read as frontmatter"

echo "passed: $pass   failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
