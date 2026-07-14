#!/usr/bin/env bash
#
# check-closing-keyword.sh
# Claude Code PreToolUse(Bash) hook.
#
# Goal: block a `gh pr create` / `gh pr edit` / `git commit` whose text contains a NEGATED
# closing keyword next to an issue reference ("this does not close #897"), because GitHub
# closes the issue anyway.
#
# Built 2026-07-13 after exactly that happened on Overture #912: a PR body that said, in as
# many words, "It does not close #897" closed #897 on merge and it had to be reopened by
# hand. GitHub's linked-issue parser matches the keyword plus the reference and does no
# negation handling at all. The "not" is invisible to it.
#
# The cruel part, and the reason a hook is worth it: the sentence is one a CAREFUL author
# wants to write. A PR that deliberately fixes only part of an issue should say so. The
# clearer you are about not finishing the issue, the likelier you are to trip this. It is
# silent, and only detectable after the merge.
#
# Safe phrasings the hook points you at: "part of #897", or "#897 stays open".
#
# Override: SKIP_CLOSING_CHECK=1 gh pr create ...   (a doc that has to quote the broken
# phrasing itself, e.g. this hook's own tests). Explain why to the user first, never skip
# silently, same rule as the test gate and the style gate.
#
# Fails OPEN: any parse error allows the command.

payload="$(cat)"

parse_payload() {
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "$payload" | jq -j '(.tool_input.command // "")' 2>/dev/null && return 0
  fi
  printf '%s' "$payload" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
except Exception:
    sys.exit(1)
ti = d.get("tool_input") or {}
sys.stdout.write(ti.get("command") or "")
' 2>/dev/null
}

cmd="$(parse_payload)" || exit 0
[ -n "$cmd" ] || exit 0

# Only the commands that can actually link an issue: a PR's body/title, or a commit message.
# A `gh pr comment` or an `gh issue comment` cannot close anything, and must not be blocked:
# discussing the mistake (as this hook's own issue does) has to stay possible.
printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])([^[:space:]]*/)?gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$)|(^|[[:space:];&|])([^[:space:]]*/)?(rtk[[:space:]]+)?git([[:space:]]+[^[:space:]]+)*[[:space:]]+commit([[:space:]]|$)' || exit 0

if printf '%s' "$cmd" | grep -Eq '(^|[[:space:];&|])SKIP_CLOSING_CHECK=1([[:space:]]|$)'; then
  exit 0
fi

findings="$(printf '%s' "$cmd" | python3 -c '
import sys, re

text = sys.stdin.read()

KEYWORDS = r"(?:close[sd]?|fix(?:e[sd])?|resolve[sd]?)"
# An issue reference in any form GitHub itself honours: #12, owner/repo#12, or the full URL.
REF = r"(?:#\d+|[\w.-]+/[\w.-]+#\d+|https?://\S*?/issues/\d+)"
NEGATIONS = {
    "not", "dont", "doesnt", "didnt", "wont", "cant", "cannot", "never", "no",
    "isnt", "arent", "wasnt", "neither", "nor", "without",
}

findings = []
for m in re.finditer(KEYWORDS + r"\s+" + REF, text, re.IGNORECASE):
    # Only a negation that GOVERNS this keyword counts, and two things decide that.
    #
    # First, the sentence: text is cut at the last sentence end before the keyword. "This does
    # not attempt the per-page contract. Closes #910." is ordinary, honest English and must
    # sail through. Without this the negation from the previous sentence would block it, and a
    # hook that fires on honest PRs is a hook that gets switched off.
    #
    # Second, the distance: within that sentence, only the last few words. Deliberately erring
    # towards blocking rather than passing, because the two failures are not symmetrical. A
    # false block is loud, visible, and overridable in one word. A false pass silently closes
    # an issue nobody meant to close, and is only found later, by accident, if at all.
    sentence = re.split(r"[.!?\n]", text[:m.start()])[-1]
    before = sentence
    # Apostrophes are stripped BEFORE tokenizing, both the ascii one and the typographic one.
    # Without this, the contraction tokenizes to "doesn" and sails straight past a list holding
    # "doesnt", and the contraction is the most natural way anybody would write this sentence.
    # Written as escape codes because this whole detector lives inside a single-quoted shell
    # string, where a literal apostrophe would end it.
    flat = re.sub("[\u2019\u0027]", "", before.lower())
    words = re.findall(r"[a-z]+", flat)[-4:]
    if any(w in NEGATIONS for w in words):
        findings.append(" ".join(before.split()[-6:]) + " " + m.group(0))

for f in findings:
    print(f)
' 2>/dev/null)"

[ -n "$findings" ] || exit 0

cat >&2 <<EOF
BLOCKED: a negated closing keyword next to an issue reference.

$findings

GitHub will CLOSE that issue on merge regardless of the "not". Its linked-issue parser
matches the keyword plus the reference and does no negation handling at all: the negation is
invisible to it. This exact sentence closed Overture #897 on a PR that said it did not.

Rewrite it so the keyword is never next to the number:
  "Part of #897, which stays open."
  "#897 stays open: this fixes only the ratchet."

Override (a doc that must quote the broken phrasing): SKIP_CLOSING_CHECK=1 <command>
EOF
exit 2
