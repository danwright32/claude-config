#!/bin/bash
# refresh-claude-code-types.sh [<laid types folder>]: pin a new Claude Code build's types for the mods
# type check (#953). tools/check-mods.sh checks every mod against the types in
# tools/typescript/claude-code-types and never against an installed copy's, whose MCP tool list is
# whatever was connected when that copy last reloaded, so the same tree gave a different verdict
# from one hour to the next. This copies a new build's types in, once, as a change to review.
#
# The source is a folder Claude Code laid for a loaded mod, by default
# ~/.claude/mods/mod-kit/.claude-plugin/types. Taken from it: claude-code/index.d.ts (the engine's
# API) and claude-code-tools/index.d.ts (this build's built-in tools), and its tsconfig.json with
# "types" cut back to the engine's three entries, since check-mods.sh adds each mod's own
# dependencies itself. Never taken: claude-code-mcp/index.d.ts, which is the session's connected MCP
# tools and is exactly what made the verdict move. The pinned one declares none, by hand, once.
#
# Every line that is wholly a comment is left out, but the engine's first, which names the build. Comments
# carry no types, and Claude Code's own carry what the push gates refuse in this repository: em
# dashes in tool descriptions, and phrases the deferral gate reads as work put off.
# A comment that shares its line with code is kept, and a character the Writing Style rule refuses
# anywhere in what is kept refuses the refresh by line, judged by the push gate's own scanner, never
# dropped, since that would change a type.
#
# Exit codes: 0 pinned, 1 refused (the reason is printed), 2 a source folder lacking a file.
# CHECK_MODS_TS_DIR moves where the pinned types are written (default tools/typescript), for tests.
set -u
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
src="${1:-$HOME/.claude/mods/mod-kit/.claude-plugin/types}"
dest="${CHECK_MODS_TS_DIR:-$here/typescript}/claude-code-types"
scanner="$here/../payload/hooks/lib/style-scan.py"

for f in claude-code/index.d.ts claude-code-tools/index.d.ts tsconfig.json; do
  if [ ! -f "$src/$f" ]; then
    echo "refresh-claude-code-types: $src has no $f, so it is not a folder Claude Code laid for a loaded mod. Name one: bash tools/refresh-claude-code-types.sh ~/.claude/mods/<mod>/.claude-plugin/types" >&2
    exit 2
  fi
done
[ -f "$scanner" ] || { echo "refresh-claude-code-types: the style scanner $scanner is missing, so the files cannot be judged for the push gate" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "refresh-claude-code-types: python3 is not on PATH, and it is what reads the files" >&2; exit 1; }

build="$(head -n 1 "$src/claude-code/index.d.ts" | sed -nE 's#^// Written by Claude Code ([0-9]+\.[0-9]+\.[0-9]+)\.?$#\1#p')"
if [ -z "$build" ]; then
  echo "refresh-claude-code-types: $src/claude-code/index.d.ts does not begin '// Written by Claude Code <version>.', so which build it describes cannot be recorded" >&2
  exit 1
fi

stage="$(mktemp -d "${TMPDIR:-/tmp}/refresh-cc-types.XXXXXX")" || { echo "refresh-claude-code-types: no scratch folder could be made" >&2; exit 1; }
trap 'rm -rf "$stage"' EXIT
python3 - "$scanner" "$src" "$stage" <<'PY' || exit 1
import importlib.util, json, os, re, sys
scanner, src, stage = sys.argv[1:4]
spec = importlib.util.spec_from_file_location("style_scan", scanner)
style = importlib.util.module_from_spec(spec)
spec.loader.exec_module(style)
refused = []
for part in ("claude-code", "claude-code-tools"):
    with open(os.path.join(src, part, "index.d.ts"), encoding="utf-8") as h:
        lines = h.read().split("\n")
    kept, dropped, block = [], 0, False
    for n, line in enumerate(lines, 1):
        s = line.strip()
        if n == 1 and part == "claude-code":
            # The engine's first line names the build, so it stays, and is judged like code.
            if style.breaks_rule(line):
                refused.append(f"{part}/index.d.ts line 1: a character the Writing Style rule refuses: {s[:120]}")
            kept.append(line)
        elif block:
            # Inside a block comment, to the line that closes it, which must close the line too.
            dropped += 1
            if "*/" in s:
                block = False
                if not s.endswith("*/"):
                    refused.append(f"{part}/index.d.ts line {n}: code after a comment closes: {s[:120]}")
        elif s.startswith("//"):
            dropped += 1
        elif s.startswith("/*"):
            dropped += 1
            if "*/" not in s[2:]:
                block = True
            elif not s.endswith("*/"):
                refused.append(f"{part}/index.d.ts line {n}: code after a comment closes: {s[:120]}")
        else:
            if style.breaks_rule(line):
                refused.append(f"{part}/index.d.ts line {n}: a character the Writing Style rule refuses, outside a comment: {s[:120]}")
            kept.append(line)
    os.makedirs(os.path.join(stage, part))
    with open(os.path.join(stage, part, "index.d.ts"), "w", encoding="utf-8") as h:
        h.write("\n".join(kept))
    print(f"{part}/index.d.ts: {len(kept)} lines kept, {dropped} comment lines left out")
if refused:
    print("refresh-claude-code-types: refused, since leaving these lines out would change a type:", file=sys.stderr)
    print("\n".join(refused[:10]), file=sys.stderr)
    sys.exit(1)
with open(os.path.join(src, "tsconfig.json"), encoding="utf-8") as h:
    cfg = json.load(h)
cfg.setdefault("compilerOptions", {})["types"] = ["claude-code", "claude-code-tools", "claude-code-mcp"]
with open(os.path.join(stage, "tsconfig.json"), "w", encoding="utf-8") as h:
    h.write(json.dumps(cfg, indent=2) + "\n")
PY

mkdir -p "$dest" || exit 1
for f in claude-code/index.d.ts claude-code-tools/index.d.ts tsconfig.json; do
  mkdir -p "$dest/$(dirname "$f")" && cp "$stage/$f" "$dest/$f" || { echo "refresh-claude-code-types: could not write $dest/$f" >&2; exit 1; }
done
echo "refresh-claude-code-types: pinned Claude Code $build's types in $dest. Run bash tests/test-mods.sh, then commit them with any change the newer types ask of a mod."
