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
