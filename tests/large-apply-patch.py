#!/usr/bin/env python3
"""Makes the scratch checkout and patch tests/test-large-git-apply-engine.sh applies (#2948).

    large-apply-patch.py REPO

REPO becomes a git checkout holding four files under docs/design, and REPO/design.patch a patch git
made of seven changes there, shaped as the one held five times on 2026-11-13 and 14: three new 720
line captured pages and an edit to each of the four. A captured page is what the design rounds
skill's capture-chrome.js writes: one stylesheet rule a line, every font and image inlined as base64
(one run of about 150,000 name characters for each font), the page's markup on the last line.
Prints the patch's line count, size and file count.
"""
import base64
import os
import random
import subprocess
import sys

repo = sys.argv[1]
design = os.path.join(repo, 'docs', 'design')
os.makedirs(design, exist_ok=True)
git = ['git', '-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', '-c', 'commit.gpgsign=false']
edited = {
    'build.ts': "import { readFileSync } from 'node:fs'\nexport const build = () => readFileSync('docs/design/sealed.html', 'utf8')\n",
    'settled.json': '{\n  "round": 4,\n  "settled": ["capture-before.html"]\n}\n',
    'checks.ts': "export const checks = ['contrast', 'spacing']\n",
    'sealed.html': '<!doctype html>\n<html>\n<body>\n<main class="sealed">round 3</main>\n</body>\n</html>\n',
}
for name, text in edited.items():
    with open(os.path.join(design, name), 'w') as f:
        f.write(text)
subprocess.run(git + ['init', '-q'], cwd=repo, check=True)
subprocess.run(git + ['add', '.'], cwd=repo, check=True)
subprocess.run(git + ['commit', '-q', '-m', 'base'], cwd=repo, check=True)


def captured(name):
    rnd = random.Random(name)
    inline = lambda n: base64.b64encode(bytes(rnd.getrandbits(8) for _ in range(n))).decode()
    rules = [f'@font-face {{ font-family: Inter; font-weight: {300 + i * 100}; src: url("data:font/woff2;base64,{inline(110000)}") format("woff2"); }}' for i in range(5)]
    k = 0
    while len(rules) < 715:
        rules.append(f'.c-{k} {{ display: flex; gap: {k % 16}px; padding: var(--space-{k % 8}); color: var(--ink-{k % 5}); }}')
        k += 1
    body = ''.join(f'<div class="flex items-center gap-3"><img src="data:image/png;base64,{inline(300)}" alt=""><span>Agent {i}</span></div>' for i in range(136))
    return ['<!doctype html>', f'<!-- the {name} page at 1280px; every stylesheet, font and image inlined -->',
            f'<html lang="en"><head><meta charset="utf-8"><title>Agents</title><style>{rules[0]}', *rules[1:],
            f'</style></head><body><main>{body}</main></body></html>']


for name in ['before', 'after', 'settled']:
    with open(os.path.join(design, f'capture-{name}.html'), 'w') as f:
        f.write('\n'.join(captured(name)) + '\n')
with open(os.path.join(design, 'sealed.html'), 'a') as f:
    f.write('<!-- round 4 sealed -->\n')
for name in ['build.ts', 'checks.ts']:
    with open(os.path.join(design, name), 'a') as f:
        f.write('export const round = 4\n')
with open(os.path.join(design, 'settled.json'), 'w') as f:
    f.write('{\n  "round": 4,\n  "settled": ["capture-before.html", "capture-after.html"]\n}\n')
subprocess.run(git + ['add', '-N', '.'], cwd=repo, check=True)
patch = subprocess.run(git + ['diff'], cwd=repo, check=True, capture_output=True, text=True).stdout
subprocess.run(git + ['reset', '-q', '--hard'], cwd=repo, check=True)
subprocess.run(git + ['clean', '-qfd'], cwd=repo, check=True)
with open(os.path.join(repo, 'design.patch'), 'w') as f:
    f.write(patch)
print(len(patch.splitlines()), len(patch), patch.count('\ndiff --git ') + patch.startswith('diff --git '))
