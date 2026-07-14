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
    # Only the few words immediately BEFORE the keyword count. A negation five sentences
    # earlier ("this does not attempt the contract ... Closes #910") is ordinary English and
    # must not be blocked, or the hook would fire on half the honest PRs ever written.
    before = text[max(0, m.start() - 60):m.start()]
    # Apostrophes are stripped BEFORE tokenizing, both the ascii one and the typographic one.
    # Without this, the contraction tokenizes to "doesn" and sails straight past a list holding
    # "doesnt", and the contraction is the most natural way anybody would write this sentence.
    # Written as escape codes because this whole detector lives inside a single-quoted shell
    # string, where a literal apostrophe would end it.
    flat = re.sub("[\u2019\u0027]", "", before.lower())
    words = re.findall(r"[a-z]+", flat)[-0:]
    if any(w in NEGATIONS for w in words):
        findings.append(" ".join(before.split()[-6:]) + " " + m.group(0))

for f in findings:
    print(f)
