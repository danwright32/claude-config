#!/bin/bash
# check-mod-dependencies.sh <mods dir>: every plugin a mod's plugin.json lists under "dependencies" is
# one its hooks actually use (#694: the job watcher listed mod-kit, which it never used). A listed
# dependency is what Claude Code lays the contract of into the mod's types and what a reader takes as
# a fact about how the mods fit together, so one nothing uses is a false statement in both places.
#
# Used means the mod's hooks (its hooks/ folder, test files left out) either reach a noun the
# dependency's contract declares on $ ($.modkit.bandRow, built.sessions.list), or name the
# dependency itself, as a ui.press matcher or a state reference does ('mod-kit'). A dependency that
# is no mod in the folder cannot be read, so it is reported rather than passed.
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
python3 - "${dir%/}" <<'PY'
import json, os, re, sys

root = sys.argv[1]
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

def nouns(folder, man):
    """The nouns a mod's contract declares on $, from its interface EngineInterface block."""
    types = man.get("types")
    if not isinstance(types, str):
        return []
    try:
        with open(os.path.join(folder, types)) as f:
            src = f.read()
    except OSError:
        return []
    block = re.search(r"interface\s+EngineInterface\s*\{([^}]*)\}", src)
    return re.findall(r"^\s*([A-Za-z_$][\w$]*)\??\s*:", block.group(1), re.M) if block else []

SOURCE = (".ts", ".tsx", ".js", ".jsx", ".mjs", ".cjs", ".mts", ".cts")
def hooks_source(folder):
    texts = []
    for base, _dirs, files in os.walk(os.path.join(folder, "hooks")):
        for name in sorted(files):
            if name.endswith(SOURCE) and ".test." not in name:
                with open(os.path.join(base, name), errors="replace") as f:
                    texts.append(f.read())
    return "\n".join(texts)

for name, (folder, man) in mods.items():
    deps = man.get("dependencies") or []
    if not deps:
        continue
    src = hooks_source(folder)
    for dep in deps:
        if dep not in mods:
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies, which is no mod in {root}, so whether {name} uses it cannot be read.")
            failed = 1
            continue
        declared = nouns(*mods[dep])
        reached = any(re.search(r"\." + re.escape(n) + r"\??\.", src) for n in declared)
        named = re.search(r"['\"`]" + re.escape(dep) + r"['\"`]", src)
        if not (reached or named):
            what = " or ".join(f"$.{n}" for n in declared) or "no noun of its"
            print(f"check-mod-dependencies: {name} lists {dep} under dependencies but never uses it: its hooks reach {what} nowhere and never name '{dep}'. Remove it from {name}/.claude-plugin/plugin.json.")
            failed = 1

print(f"check-mod-dependencies: {len(mods)} mods checked in {root}")
sys.exit(failed)
PY
