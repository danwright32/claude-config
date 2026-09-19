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


# The library, not a copy: six near copies of this had already drifted (claude-config#102).
# `raw` because this hook searches the whole command rather than splitting it.
HOOK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/push-scope.sh
. "$HOOK_DIR/lib/push-scope.sh" 2>/dev/null || exit 0

# THE DETECTOR'S OWN READER, asked before anything is measured (claude-config#486, L490).
#
# The negation detector below is python3 and nothing here asked whether python3 was installed.
# Without it the findings came back empty, the emptiness test passed, and this gate exited 0 on
# exactly the phrasing it exists to stop, with nothing said. A detector that cannot run finds
# nothing, and finding nothing is exactly what a clean run looks like (L42, L98).
#
# Asked above the payload read, because python3 is also one of the two tools ps_parse_payload
# reads with: with neither jq nor python3 the parse below exits 0 first and this question would
# never be reached (L135, L667).
#
# Narrowed, on the raw payload, to the three commands that can link an issue at all, since the
# refusal must not reach a command this hook was never about (L36, L54). A substring rather than
# the leading token test used below, because with no reader there are no tokens: it can only ever
# be too broad here, never too narrow. The override is read the same way (L109).
if ps_reader_missing python3; then
  case "$payload" in
    *SKIP_CLOSING_CHECK=1*) exit 0 ;;
    *"pr create"*|*"pr edit"*|*"git commit"*)
      echo "BLOCKED: $(ps_detector_absent_why "python3 is not on PATH" \
        "check-closing-keyword.sh reads this text with it, looking for a negated closing keyword beside an issue reference, so with python3 absent nothing here reads the text at all." \
        "python3")" >&2
      echo "A sentence like \"does not close #897\" closes the issue on merge regardless of the negation, which is why this is a gate rather than a note." >&2
      echo "OVERRIDE, this one command: SKIP_CLOSING_CHECK=1 <your original command>" >&2
      exit 2 ;;
  esac
  exit 0
fi

parsed="$(ps_parse_payload "$payload" raw)" || exit 0
cmd="${parsed%%$'\x1f'*}"
[ -n "$cmd" ] || exit 0

# Only the commands that can actually link an issue: a PR body/title, or a commit message.
#
# Matched on the LEADING TOKENS of each shell segment, never anywhere in the string. That is
# the whole difference between a command and a command PAYLOAD, and getting it wrong was not
# theoretical: the first draft of this hook blocked its own issue-closing comment, because
# that comment QUOTED a PR-creation command as the example of what it catches. An issue
# comment cannot close anything, and neither can a comment that merely talks about a PR.
is_target=0
while IFS= read -r seg; do
  # Drop leading env assignments (GH_TOKEN=... gh pr create ...) before reading the program.
  head_tokens="$(printf '%s' "$seg" | sed -E 's/^[[:space:]]*//; s/^([A-Za-z_][A-Za-z0-9_]*=[^[:space:]]+[[:space:]]+)*//' | awk '{print $1, $2, $3}')"
  if printf '%s' "$head_tokens" | grep -Eq '(^|/)gh[[:space:]]+pr[[:space:]]+(create|edit)([[:space:]]|$)'; then
    is_target=1
    break
  fi
  if printf '%s' "$head_tokens" | grep -Eq '(^|/)(rtk[[:space:]]+)?git[[:space:]]+commit([[:space:]]|$)'; then
    is_target=1
    break
  fi
done < <(printf '%s\n' "$cmd" | sed -E 's/(&&|\|\||;)/\n/g')
[ "$is_target" -eq 1 ] || exit 0

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
