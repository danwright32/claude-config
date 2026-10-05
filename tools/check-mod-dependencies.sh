#!/bin/bash
# check-mod-dependencies.sh <mods dir>: every plugin a mod's plugin.json lists under "dependencies" is
# one its code actually uses (#694: the job watcher listed mod-kit, which it never used). A listed
# dependency is what Claude Code lays the contract of into the mod's types and what a reader takes as
# a fact about how the mods fit together, so one nothing uses is a false statement in both places.
#
# Used means the mod's code either reaches a noun the dependency's contract declares on $
# ($.modkit.bandRow, built.sessions.list), or names the dependency itself, as a ui.press matcher or a
# state reference does ('mod-kit'). The mod's code is every source file in its folder, wherever its
# hooks module imports it from, less its tests, its own contract and what Claude Code generates, and
# with comments taken out, since a comment naming a noun calls nothing (lessons review of #696).
# A dependency that is no mod in the folder, a contract that cannot be read or parsed whole, and a
# mod with no source at all are each reported as such, never passed and never taken as unused.
#
# Exit codes, each distinct (L11): 0 every dependency is used (the count of mods is printed, L98),
# 1 an unused or unreadable dependency, each named with its mod, 2 the mods folder does not exist,
# 3 no python3 to read the manifests with (L490: never a pass over nothing read).
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-dependencies: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-dependencies: python3 is not installed, so no mod's dependencies were read." >&2
  exit 3
fi
python3 - "${dir%/}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" <<'PY'
import json, os, re, sys

root = sys.argv[1]
# Comments are taken out by the one reader of source every mod scan shares, which reads a regex
# literal and JSX text as what they are (#735): this file's own stripper took a regex holding // or
# /* for a comment, and JSX text's // or apostrophe for a comment or a quote.
sys.path.insert(0, sys.argv[2])
from ts_source import is_jsx, strip_comments
failed = 0
mods = {}
for entry in sorted(os.listdir(root)):
    folder = os.path.join(root, entry)
    manifest = os.path.join(folder, ".claude-plugin", "plugin.json")
    if not os.path.isfile(manifest):
        continue
    try:
        with open(manifest) as f:
            man = json.load(f)
    except (OSError, ValueError) as e:
        print(f"check-mod-dependencies: {entry}'s plugin.json cannot be read ({e}), so its dependencies were not checked.")
        failed = 1
        continue
    mods[man.get("name") or entry] = (folder, man)

QUOTES = "'\"`"

def nouns(folder, man):
    """The nouns a mod's contract declares on $, from its interface EngineInterface block: none when
    it names no contract, None when the contract it names cannot be read or parsed whole."""
    types = man.get("types")
    if not isinstance(types, str):
        return []
    try:
        with open(os.path.join(folder, types)) as f:
            src = strip_comments(f.read())
    except OSError:
        return None
    head = re.search(r"interface\s+EngineInterface\s*\{", src)
    if not head:
        return []
    # The block runs to its own closing brace, past any member's inline object type; only what stands
    # at its top level is a member, so whatever is nested is blanked before the members are read.
    depth, top = 1, []
    for c in src[head.end():]:
        if c == "{":
            depth += 1
        elif c == "}":
            depth -= 1
            if depth == 0:
                break
        top.append(c if depth == 1 or c == "\n" else " ")
    else:
        return None
    return re.findall(r"^\s*([A-Za-z_$][\w$]*)\??\s*:", "".join(top), re.M)

SOURCE = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
# Not the mod's code: its tests (which stand in for other mods), its own contract, and what Claude
# Code generates into its folder.
SKIP_DIRS = {"tests", "types", ".claude-plugin", "node_modules"}

def mod_source(folder):
    texts = []
    for base, dirs, files in os.walk(folder):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            if name.endswith(SOURCE) and ".test." not in name and not name.endswith(".d.ts"):
                with open(os.path.join(base, name), errors="replace") as f:
                    texts.append(strip_comments(f.read(), is_jsx(name)))
    return texts

for name, (folder, man) in mods.items():
    deps = man.get("dependencies") or []
    if not deps:
        continue
    texts = mod_source(folder)
    if not texts:
        for dep in deps:
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies, but no source file of {name} was found, so whether it uses it cannot be read.")
        failed = 1
        continue
    src = "\n".join(texts)
    for dep in deps:
        if dep not in mods:
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies, which is no mod in {root}, so whether {name} uses it cannot be read.")
            failed = 1
            continue
        declared = nouns(*mods[dep])
        if declared is None:
            # Never scored as declaring nothing: that would accuse a mod reaching its nouns (L11).
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies, whose contract {mods[dep][1].get('types')} cannot be read or parsed whole, so whether {name} uses it cannot be read.")
            failed = 1
            continue
        reached = any(re.search(r"\." + re.escape(n) + r"\??\.", src) for n in declared)
        named = re.search("[" + QUOTES + "]" + re.escape(dep) + "[" + QUOTES + "]", src)
        if not (reached or named):
            what = " or ".join(f"$.{n}" for n in declared) or "no noun of its"
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies but never uses it: its code reaches {what} nowhere and never names '{dep}'. Remove it from {name}/.claude-plugin/plugin.json.")
            failed = 1

print(f"check-mod-dependencies: {len(mods)} mods checked in {root}")
sys.exit(failed)
PY
