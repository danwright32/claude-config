#!/bin/bash
# check-mod-approvals.sh <mods dir>: no mod answers "allow" for a tool call or a permission prompt,
# changes what the permission rules allow, or makes a tool call of its own, unless the list beside
# this script names that one statement (#3681).
#
# Why: Claude Code's built in guard (sec-default) is off on both Macs. Dan chose that on 2026-10-06
# (#876) and kept it on 2026-11-25 (#3681: "Stay off, add a check"). Claude Code's permissions page
# says what is lost with it: a mod's approval can then beat some refusals a deny rule makes, skip an
# ask rule's prompt, and in auto mode skip the review of the call. This check is what stands in the
# guard's place for the mods under payload/mods: it fails the build when one of them could do that.
#
# The routes, read from the mod API's own types (Claude Code 2.1.332, in every mod's
# .claude-plugin/types) and its documentation, each named in a finding by the word in brackets:
#   [answers-allow]       the value 'allow' or 'approve' given to decision, permissionDecision or
#                         behavior, which is how a tool.check or tool.judge hook, a
#                         classic.PermissionRequest hook and a classic.PreToolUse hook approve; and
#                         allow: true, the PreToolUse result's own spelling.
#   [answers-ask]         the value 'ask' given to one of those keys: over a refusal beneath it, a
#                         question is a loosening, and a permission prompt is what a mod can approve.
#   [holds-allow]         the word allow as a whole string anywhere else in the mod's code or in a
#                         .json file beside it, since a decision can be computed from it or read
#                         from the file. The approving value has to come from somewhere.
#   [changes-permissions] updatedPermissions (a PermissionRequest answer that adds rules or sets
#                         the mode), the words setMode and bypassPermissions, a permissionMode given
#                         to an agent the mod starts, and $.config.set.
#   [rewrites-settings]   a hook on settings.read, which answers what the session's settings hold,
#                         its permission rules included.
#   [own-tool-call]       tool.call or mcp.call on any object: $.tool.call and $.mcp.call run a tool
#                         with no permission rule consulted, a deny rule included.
#   [takes-namespace]     $.tool, $.mcp or $.config taken whole (const t = $.tool), or a member of $
#                         reached by a computed name ($['tool']), so a call through it cannot be read.
#   [reads-unread-code]   an import from a tests folder, node_modules or outside the mods folder, or
#                         a hooks module listed from a folder this check does not read.
# The value is read whatever quotes it, with the key quoted or not, in every source file that is a
# mod's own code (mod_code in lib/ts_source.py: mod-kit, and each mod's own copy of mod-kit under
# hooks/mod-kit, are read like any other code). Comments and longer strings are never matched.
#
# Left out on purpose: each mod's tests folder, whose stand ins play other mods and the engine and
# answer allow by design. A session never loads it, and mod code that imports from it is a finding.
#
# What it cannot see is printed on the last line of every run (L98), so a pass is never read as
# more than it is.
#
# The list: tools/mod-approvals-allowed.tsv, one row per statement, tab separated: the mod's
# folder, the file within it, the route, the statement's own line with its spacing collapsed, the
# issue that decided it, and the reason. A row allows ONE statement (a second copy of it is found),
# follows the statement and not its line number, and fails the run once it matches nothing, so a
# row cannot outlive what it allowed. Adding a row is a decision for Dan, made on the issue.
# CHECK_MOD_APPROVALS_LIST names another list; tests/test-mod-approvals.sh sets it for every fixture.
#
# Exit codes, each distinct (L11): 0 nothing found beyond what the list names (the counts and each
# statement allowed by name are printed), 1 a statement was found or a row has gone, 2 the mods
# folder does not exist, 3 no python3, 4 something could not be read (a source file, a manifest, a
# hooks.json, the list or a row of it, a hook whose event is not a plain string), which is never a
# pass and never the exit 1 that names a statement, 5 the folder holds no mod.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-approvals: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-approvals: python3 is not installed, so no mod was read." >&2
  exit 3
fi
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
python3 -B - "${dir%/}" "$here/lib" "${CHECK_MOD_APPROVALS_LIST:-$here/mod-approvals-allowed.tsv}" <<'PY'
import json, os, re, sys, traceback

root, list_path = sys.argv[1], sys.argv[3]
# Which files are a mod's own code, and which of its characters are code, are read by the one
# reader every mod scan shares (#735).
sys.path.insert(0, sys.argv[2])

P = "check-mod-approvals: "
WHAT = {
    "answers-allow": "answers allow for a tool call or a permission prompt",
    "answers-ask": "answers ask, which turns a refusal beneath it into a question",
    "holds-allow": "holds the word allow as a value a decision could be computed or read from",
    "changes-permissions": "changes the permission rules or the permission mode",
    "rewrites-settings": "hooks settings.read, which answers what the session's permission rules are",
    "own-tool-call": "makes a tool call of its own, which no permission rule covers",
    "takes-namespace": "takes the engine's tool, mcp or config object whole, or a member of $ by a computed name, so a call through it cannot be read",
    "reads-unread-code": "runs code from a place this check does not read",
}
# The values that loosen, by the key they are given to; and the words that are a finding wherever
# they stand as a whole string.
LOOSE = {"allow": "answers-allow", "approve": "answers-allow", "ask": "answers-ask"}
KEYS = ("decision", "permissionDecision", "behavior")
WORDS = {"allow": "holds-allow", "updatedPermissions": "changes-permissions", "setMode": "changes-permissions",
         "bypassPermissions": "changes-permissions", "permissionMode": "changes-permissions"}
LITERAL = re.compile(r"(['\"`])([A-Za-z_$][\w$]*)\1\Z")
MEMBER = r"\s*(?:\?\.|\.)\s*"
IN_CODE = (
    (re.compile(r"\ballow\s*:\s*true\b"), "answers-allow"),
    (re.compile(r"\bupdatedPermissions\b"), "changes-permissions"),
    (re.compile(r"\bpermissionMode\s*:"), "changes-permissions"),
    (re.compile(r"\$" + MEMBER + r"config" + MEMBER + r"set\b"), "changes-permissions"),
    (re.compile(r"\b(?:tool|mcp)" + MEMBER + r"call\b"), "own-tool-call"),
    (re.compile(r"\$" + MEMBER + r"(?:tool|mcp|config)\b(?!" + MEMBER + r"[A-Za-z_$])"), "takes-namespace"),
    (re.compile(r"\$\s*(?:\?\.)?\s*\["), "takes-namespace"),
)
IMPORT = re.compile(r"(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)(['\"`])([^'\"`\n]+)\1")
IN_DATA = re.compile(r"\"(allow|updatedPermissions|setMode|bypassPermissions|permissionMode)\"")
ROW = ("mod", "file", "route", "statement", "issue", "reason")
unread = 0


def cannot(text):
    global unread
    print(P + text)
    unread = 1


def line_of(text, i):
    return text.count("\n", 0, i) + 1


def statement(text, line):
    return " ".join(text.split("\n")[line - 1].split())


def unread_place(path, mod_folder):
    """Why a file at path is one this check does not read, or None: outside the mods folder, or in
    a folder mod_code leaves out, or a test file."""
    full = os.path.normpath(path)
    if os.path.commonpath([full, os.path.normpath(root)]) != os.path.normpath(root):
        return "it is outside the mods folder"
    parts = os.path.relpath(full, root).split(os.sep)
    for part in parts[1:-1]:
        if part in ("tests", "node_modules"):
            return f"it is in a {part} folder"
    if ".test." in parts[-1]:
        return "it is a test file"
    return None


def read_source(text, jsx, path, mod_folder, add):
    """One pass over one source file: every finding in it, through add(index, route)."""
    kind = kinds(text, jsx)
    code = code_only(text, jsx)

    def skip_back(j):
        while j >= 0 and (kind[j] == COMMENT or (kind[j] == CODE and text[j].isspace())):
            j -= 1
        return j

    def key_before(a):
        """The key a value starting at a is given to, as `key: value`, quoted or not; or None."""
        j = skip_back(a - 1)
        if j < 0 or kind[j] != CODE or text[j] != ":":
            return None
        j = skip_back(j - 1)
        if j < 0:
            return None
        if kind[j] == STRING:
            s = j
            while s > 0 and kind[s - 1] == STRING:
                s -= 1
            m = LITERAL.match(text, s, j + 1)
            return m.group(2) if m else None
        m = re.search(r"[A-Za-z_$][\w$]*\Z", text[max(0, j - 80) : j + 1])
        return m.group(0) if m and kind[j] == CODE else None

    # Each whole string: a run of string characters that is one quoted word and nothing else.
    i, n = 0, len(text)
    while i < n:
        if kind[i] != STRING:
            i += 1
            continue
        a = i
        while i < n and kind[i] == STRING:
            i += 1
        m = LITERAL.match(text, a, i)
        if not m:
            continue
        word = m.group(2)
        if word in LOOSE and key_before(a) in KEYS:
            add(a, LOOSE[word])
        elif word in WORDS:
            add(a, WORDS[word])
    for pattern, route in IN_CODE:
        for m in pattern.finditer(code):
            add(m.start(), route)
    for m in IMPORT.finditer(text):
        if kind[m.start()] != CODE or not m.group(2).startswith("."):
            continue
        why = unread_place(os.path.join(os.path.dirname(path), m.group(2)), mod_folder)
        if why:
            add(m.start(), "reads-unread-code")
    for line, event in hook_events(text, jsx):
        if event is None:
            cannot(f"{os.path.relpath(path, root)}:{line} registers a hook whose event is not a plain string, so whether it is on settings.read is not known. Write the event as a string in the on( call.")
        elif event == "settings.read":
            add(sum(len(l) + 1 for l in text.split("\n")[: line - 1]), "rewrites-settings")


def read_modules(mod, folder, add_at):
    """The hooks modules a mod lists (hooks/hooks.json, or what its manifest's `hooks` names): one
    listed from a folder this check does not read is a finding, at the file that lists it."""
    lists = []  # (the file listing them, the folder its paths are relative to, the modules)
    manifest = os.path.join(folder, ".claude-plugin", "plugin.json")
    try:
        with open(manifest) as f:
            man = json.load(f)
    except (OSError, ValueError) as e:
        cannot(f"{mod}'s plugin.json cannot be read ({e}), so which hooks modules it lists is not known.")
        return
    named = man.get("hooks") if isinstance(man, dict) else None
    files = [os.path.join(folder, "hooks", "hooks.json")]
    if isinstance(named, dict):
        lists.append((manifest, folder, named.get("modules")))
    elif isinstance(named, str):
        files.append(os.path.join(folder, named))
    elif named is not None:
        cannot(f"{mod}'s plugin.json gives `hooks` in a shape this check does not read, so which hooks modules it lists is not known.")
    for path in files:
        if not os.path.exists(path):
            continue
        try:
            with open(path) as f:
                data = json.load(f)
        except (OSError, ValueError) as e:
            cannot(f"{os.path.relpath(path, root)} cannot be read ({e}), so which hooks modules {mod} lists is not known.")
            continue
        lists.append((path, os.path.dirname(path), data.get("modules") if isinstance(data, dict) else None))
    for path, base, modules in lists:
        if modules is None:
            continue
        if not isinstance(modules, list) or not all(isinstance(m, str) for m in modules):
            cannot(f"`modules` in {os.path.relpath(path, root)} is not a list of paths, so which hooks modules {mod} lists is not known.")
            continue
        try:
            with open(path) as f:
                text = f.read()
        except OSError:
            text = ""
        for module in modules:
            full = os.path.normpath(os.path.join(base, module))
            inside = os.path.commonpath([full, os.path.normpath(folder)]) == os.path.normpath(folder)
            parts = os.path.relpath(full, folder).split(os.sep) if inside else []
            if not inside or any(p in NOT_MOD_CODE for p in parts[:-1]) or ".test." in parts[-1] or unread_place(full, folder):
                at = text.find(json.dumps(module))
                add_at(path, text, max(at, 0), "reads-unread-code")


def read_list():
    """The rows of the list, or None where it cannot be read whole: never an empty list."""
    try:
        with open(list_path) as f:
            lines = f.read().split("\n")
    except OSError as e:
        cannot(f"the list of statements allowed by name, {list_path}, cannot be read ({e}), so nothing was checked against it.")
        return None
    rows = []
    for n, line in enumerate(lines, 1):
        if not line.strip() or line.startswith("#"):
            continue
        cells = line.split("\t")
        row = dict(zip(ROW, cells))
        bad = None
        if len(cells) != len(ROW):
            bad = f"it has {len(cells)} tab separated cells, not the {len(ROW)} a row has ({', '.join(ROW)})"
        elif not all(c.strip() for c in cells):
            bad = "its " + ", ".join(k for k in ROW if not row[k].strip()) + " is empty, and every row gives the mod, the file, the route, the statement, the issue that decided it and the reason"
        elif row["route"] not in WHAT:
            bad = f"its route, {row['route']}, is not one this check has ({', '.join(sorted(WHAT))})"
        elif not re.fullmatch(r"#\d+", row["issue"]):
            bad = f"its issue, {row['issue']}, is not an issue number written as #123"
        if bad:
            cannot(f"row {n} of {list_path} cannot be used: {bad}. Nothing was checked against the list.")
            return None
        row["n"], row["used"] = n, False
        rows.append(row)
    return rows


def main():
    rows = read_list()
    if rows is None:
        return 4
    try:
        entries = sorted(os.listdir(root))
    except OSError as e:
        cannot(f"{root} cannot be listed ({e}), so no mod in it was checked.")
        return 4
    mods = [e for e in entries if os.path.isfile(os.path.join(root, e, ".claude-plugin", "plugin.json"))]
    if not mods:
        print(f"{P}no mod (a folder holding .claude-plugin/plugin.json) was found in {root}, so nothing was checked.")
        return 5
    findings, seen, files = [], set(), 0
    for mod in mods:
        folder = os.path.join(root, mod)

        def add_at(path, text, i, route, mod=mod, folder=folder):
            rel, line = os.path.relpath(path, folder), line_of(text, i)
            if (mod, rel, line, route) not in seen:
                seen.add((mod, rel, line, route))
                findings.append((mod, rel, line, route, statement(text, line)))

        def unlisted(e, mod=mod, folder=folder):
            cannot(f"{mod}'s {os.path.relpath(e.filename, folder)} cannot be listed ({e.strerror}), so the code in it was not read.")

        for path in mod_code(folder, unlisted):
            try:
                with open(path, errors="replace") as f:
                    text = f.read()
            except OSError as e:
                cannot(f"{os.path.relpath(path, root)} cannot be read ({e}), so whether it approves or calls a tool is not known.")
                continue
            files += 1
            read_source(text, is_jsx(path), path, folder, lambda i, route, path=path, text=text: add_at(path, text, i, route))
        # The data files beside the code, which the code could read a decision from.
        for base, dirs, names in os.walk(folder, onerror=unlisted):
            dirs[:] = sorted(d for d in dirs if d not in NOT_MOD_CODE)
            for name in sorted(names):
                if not name.endswith(".json"):
                    continue
                path = os.path.join(base, name)
                try:
                    with open(path, errors="replace") as f:
                        text = f.read()
                except OSError as e:
                    cannot(f"{os.path.relpath(path, root)} cannot be read ({e}), so whether it holds a decision is not known.")
                    continue
                files += 1
                for m in IN_DATA.finditer(text):
                    add_at(path, text, m.start(), WORDS[m.group(1)])
        read_modules(mod, folder, add_at)

    found = allowed = 0
    for mod, rel, line, route, text in sorted(findings):
        row = next((r for r in rows if not r["used"] and (r["mod"], r["file"], r["route"], r["statement"]) == (mod, rel, route, text)), None)
        if row:
            row["used"] = True
            allowed += 1
            print(f"{P}ALLOWED BY NAME {mod} {rel}:{line} [{route}] ({row['issue']}, {row['reason']}): {text}")
        else:
            found += 1
            print(f"{P}FOUND {mod} {rel}:{line} [{route}] {mod} {WHAT[route]}: {text}")
    gone = [r for r in rows if not r["used"]]
    for r in gone:
        print(f"{P}LISTED BUT GONE {r['mod']} {r['file']} [{r['route']}] row {r['n']} of {list_path} names a statement that is no longer there, so it allows nothing and must be taken out: {r['statement']}")
    if found:
        print(f"{P}Claude Code's built in guard is off on both Macs (#876, #3681), so nothing but this check stops a mod's approval beating a deny rule. Take the statement out, or have Dan decide on an issue whether it is allowed by name in {list_path}.")
    print(f"{P}{len(mods)} mods checked in {root}, {files} files read; {found} found, {allowed} allowed by name, {len(gone)} listed but gone ({list_path}). "
          "Not read: a decision built while running from pieces of a word or read from outside the mod's folder (a file elsewhere, the network, a setting), "
          "a call made through a renamed copy of the engine's tool object, a hook that passes on the engine's verdict for a different call than the one asked about, "
          "what a mod does itself with $.process.run, $.fs or $.http (no tool call, and no permission rule covers it), a package a mod imports by name, "
          "each mod's tests folder, and any plugin that is not under this folder.")
    return 1 if found or gone else 4 if unread else 0


# Anything this check did not foresee, its shared reader failing to load included, is its own
# answer: exit 4 with words, never a traceback's exit 1, which here means a statement was found (L10).
try:
    from ts_source import CODE, COMMENT, NOT_MOD_CODE, STRING, code_only, hook_events, is_jsx, kinds, mod_code
    code = main()
except Exception as e:
    traceback.print_exc()
    print(f"{P}the check itself failed ({type(e).__name__}: {e}), so nothing was told about what any mod approves.")
    code = 4
sys.exit(code)
PY
