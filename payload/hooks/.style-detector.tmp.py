import sys, re

emoji_re = re.compile(
    "[\U0001F300-\U0001FAFF\U00002600-\U000027BF\U0001F1E6-\U0001F1FF"
    "⤴⤵⬅-⬇⬛⬜⭐⭕️]"
)
dash_re = re.compile("[—–]")

current_file = "(unknown file)"
out = []
for line in sys.stdin:
    line = line.rstrip("\n")
    if line.startswith("+++ "):
        f = line[4:]
        if f.startswith("b/"):
            f = f[2:]
        current_file = f
        continue
    if line.startswith("--- NEW FILE: ") and line.endswith(" ---"):
        current_file = line[len("--- NEW FILE: "):-4]
        continue
    if not line.startswith("+") or line.startswith("+++"):
        continue
    content = line[1:]
    if dash_re.search(content) or emoji_re.search(content):
        out.append(f"{current_file}: {content.strip()[:160]}")

for o in out[:25]:
    print(o)
if len(out) > 25:
    print(f"... and {len(out) - 25} more")
