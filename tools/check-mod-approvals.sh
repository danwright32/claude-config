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
#                         the name allow, the PreToolUse result's own spelling ({ allow: true }),
#                         wherever it is a key, a shorthand property, a variable or assigned to,
#                         unless the key is given false, undefined or null. What approves there
#                         is true, which can be computed anywhere, so the name itself is read.
#   [answers-ask]         the value 'ask' given to one of those keys: over a refusal beneath it, a
#                         question is a loosening, and a permission prompt is what a mod can approve.
#   [holds-allow]         the word allow as a whole string anywhere else in the mod's code, or quoted
#   [holds-approve]       in any other file of the mod (a .json file, a script, a data file), and
#   [holds-ask]           the same for approve and for ask, since a decision can be computed from
#                         the word (ok ? 'approve' : 'deny') or read from the file. The approving value has to come from somewhere. allow
#                         passes nowhere. approve and ask have harmless uses, so they pass in the
#                         positions below and nowhere else.
#   [changes-permissions] updatedPermissions (a PermissionRequest answer that adds rules or sets
#                         the mode), the words setMode and bypassPermissions, the name
#                         permissionMode wherever it is not read off something (a key, a shorthand
#                         property, a variable: what a mod gives an agent it starts), and
#                         $.config.set.
#   [rewrites-settings]   a hook on settings.read, which answers what the session's settings hold,
#                         its permission rules included.
#   [own-tool-call]       tool.call or mcp.call on any object: $.tool.call and $.mcp.call run a tool
#                         with no permission rule consulted, a deny rule included.
#   [takes-namespace]     $.tool, $.mcp or $.config taken whole (const t = $.tool), or a member of $
#                         reached by a computed name ($['tool']), so a call through it cannot be read.
#   [reads-unread-code]   an import from a tests folder, node_modules or outside the mods folder, or
#                         a hooks module listed from a folder this check does not read.
# Every decision word that does not refuse (allow, approve, ask) is held both ways, beside a
# decision key and apart from one, by one function (word_route) for code and data files alike. The
# suite reads the decision values out of the pinned mod API types and fails for any value that is
# not, so a build that adds one cannot pass unnoticed. approve is not in those types: it is the
# classic hooks' spelling, whose results the types do not describe, so it is held on that ground.
#
# Where the words approve and ask pass, each by the shape of the code around the word and never by
# a list of files:
#   as a property's value, when the key is not one of the three decision keys: `key: 'ask'` or
#     `key?: 'ask'` with the key a plain or quoted name that follows a {, a comma or a (. That
#     shape is a property of an object, a member of a type, a parameter's type, or a label whose
#     value is thrown away. A conditional's second arm (ok ? x : 'ask') is not that shape: its x
#     follows a question mark. The word then lives in that property and nowhere else, and reading
#     it back out (held.id) is the one thing left that this check cannot follow.
#   where an operator takes it and cannot hand it back: beside ===, !==, == or != (the answer is
#     true or false), beside a single | or & (a number in code, a union in a type), straight after
#     a single <, or straight before a > when a comma or a < stands before it (a comparison in
#     code, the first or last argument of a type such as Pick<Io, 'ask'>), and after the word case.
#   after the word as, in plain quotes: the type of a cast, whose value comes from what is cast.
# Everything else is a finding: either arm of a conditional, what follows || or ??, a variable's
# value, a default, a return, an arrow's body, an argument, a list's element, the value of a
# computed key, an element's attribute, and every type position not named above (a type alias of
# the word alone, a variable's or a function's declared type), which is stricter than it need be.
#
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
# The decision words that do not refuse, each with the route it is a finding by when it is given
# to one of KEYS. EVERY word here is also a finding apart from those keys, by the route holds-<word>,
# through the one function word_route below, for code and for data files alike: four rounds of
# review each found a word that one rule held and another did not, so no rule names a word of its
# own. tests/test-mod-approvals.sh section 4c reads the decision values out of the pinned mod API
# types and fails for any that is not held both ways.
LOOSE = {"allow": "answers-allow", "approve": "answers-allow", "ask": "answers-ask"}
KEYS = ("decision", "permissionDecision", "behavior")
# The decision words with a use that decides nothing (a picker's id, a verb, a type's member name).
# Apart from a decision key these pass where taken() below says the word cannot become a value. A
# word not named here, allow today, passes nowhere.
MAY_STAND = ("approve", "ask")
WHAT.update({"holds-" + w: f"holds the word {w} where a decision could be computed or read from it (it passes only as the value of a property that is no decision key, in a comparison, or in a type's union or first or last argument)" for w in MAY_STAND})
# The other words that are a finding wherever they stand as a whole string.
WORDS = {"updatedPermissions": "changes-permissions", "setMode": "changes-permissions",
         "bypassPermissions": "changes-permissions", "permissionMode": "changes-permissions"}
# The comparisons whose answer is true or false, and the characters operators are made of.
SAME = ("===", "!==", "==", "!=")
SIGNS = frozenset("=!<>|&?:+-*/%^~")
LITERAL = re.compile(r"(['\"`])([A-Za-z_$][\w$]*)\1\Z")
MEMBER = r"\s*(?:\?\.|\.)\s*"
# The names that approve or set the mode by being a KEY, whatever they are given: allow (what
# approves there is true, which no rule for a word can hold) and permissionMode. Each is a finding
# wherever it stands as a name in code, written out, as a shorthand property or assigned to, and
# passes only where it is read off something (x.allow, not assigned) or, for allow, is a key given
# false, undefined or null.
NAMES = {"allow": "answers-allow", "permissionMode": "changes-permissions"}
NAME = re.compile(r"(?<![\w$])(" + "|".join(NAMES) + r")(?![\w$])")
ASSIGNED = re.compile(r"\s*(?:\*\*|<<|>>>?|&&|\|\||\?\?|[-+*/%&|^])?=(?!=)")
REFUSES = re.compile(r"\s*\??\s*:\s*(?:false|undefined|null)\s*(?:[,;})]|\Z)")
IN_CODE = (
    (re.compile(r"\bupdatedPermissions\b"), "changes-permissions"),
    (re.compile(r"\$" + MEMBER + r"config" + MEMBER + r"set\b"), "changes-permissions"),
    (re.compile(r"\b(?:tool|mcp)" + MEMBER + r"call\b"), "own-tool-call"),
    (re.compile(r"\$" + MEMBER + r"(?:tool|mcp|config)\b(?!" + MEMBER + r"[A-Za-z_$])"), "takes-namespace"),
    (re.compile(r"\$\s*(?:\?\.)?\s*\["), "takes-namespace"),
)
IMPORT = re.compile(r"(?:\bfrom\s*|\bimport\s*\(?\s*|\brequire\s*\(\s*)(['\"`])([^'\"`\n]+)\1")
# A word in a file of the mod that is not its code: in a .json file as JSON writes a string, in
# any other file (a script, a .yaml, a text file) inside quotes of any kind.
IN_DATA = re.compile(r"\"(" + "|".join(list(LOOSE) + list(WORDS)) + r")\"")
IN_OTHER = re.compile(r"(['\"`])(" + "|".join(list(LOOSE) + list(WORDS)) + r")\1")
KEY_IN_DATA = re.compile(r"\"([^\"\\\n]*)\"\s*:\s*\Z")
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


def word_route(word, key, apart):
    """The route by which a decision word (one of LOOSE) is a finding, or None where it passes.
    key is the key the word is given to, or None. apart is whether it stands where it cannot
    become a value a decision is made from, which only a word in MAY_STAND is ever asked. The one
    rule for every decision word, in code and in a data file."""
    if key in KEYS:
        return LOOSE[word]
    if word in MAY_STAND and apart:
        return None
    return "holds-" + word


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

    def skip_on(j):
        while j < n and (kind[j] == COMMENT or (kind[j] == CODE and text[j].isspace())):
            j += 1
        return j

    def name_ending(j):
        """The whole plain name whose last character is at j, and where it starts; or None."""
        if j < 0 or kind[j] != CODE or not (text[j].isalnum() or text[j] in "_$"):
            return None
        s = j
        while s > 0 and kind[s - 1] == CODE and (text[s - 1].isalnum() or text[s - 1] in "_$"):
            s -= 1
        return text[s : j + 1], s

    def own_key(a):
        """The key the value starting at a is given to, where the code around it can only be a
        property, a type's member, a parameter's type or a label: `key: value` or `key?: value`,
        the key a plain or quoted name that follows a {, a comma or a (. None for everything else,
        above all a conditional's second arm (ok ? x : value), whose x follows a question mark."""
        j = skip_back(a - 1)
        if j < 0 or kind[j] != CODE or text[j] != ":":
            return None
        j = skip_back(j - 1)
        if j >= 0 and kind[j] == CODE and text[j] == "?":
            j = skip_back(j - 1)
        if j < 0:
            return None
        if kind[j] == STRING:
            s = j
            while s > 0 and kind[s - 1] == STRING:
                s -= 1
            m = LITERAL.match(text, s, j + 1)
            name = m.group(2) if m else None
        else:
            got = name_ending(j)
            name, s = got if got else (None, 0)
        if name is None:
            return None
        j = skip_back(s - 1)
        return name if j >= 0 and kind[j] == CODE and text[j] in "{,(" else None

    def taken(a, b):
        """Whether the string text[a:b] stands where it cannot become a value a decision is made
        from, other than by being read back out of the property it was given to. The positions,
        and why each is safe whether the code is read as JavaScript or as a type, are in this
        script's header. Anything not recognised here is not taken, so it is a finding."""
        key = own_key(a)
        if key is not None:
            return key not in KEYS
        j = skip_back(a - 1)
        before = ""
        if j >= 0 and kind[j] == CODE:
            s = j
            while s >= 0 and kind[s] == CODE and text[s] in SIGNS:
                s -= 1
            before = text[s + 1 : j + 1]
        k = e = skip_on(b)
        while e < n and kind[e] == CODE and text[e] in SIGNS:
            e += 1
        after = text[k:e]
        if before in SAME or after in SAME or before in ("|", "&", "<") or after in ("|", "&"):
            return True
        if after[:1] == ">" and (before == "<" or (j >= 0 and kind[j] == CODE and text[j] == ",")):
            return True
        got = name_ending(j)
        return bool(got) and (got[0] == "case" or (got[0] == "as" and text[a] != "`"))

    def strings(a, b):
        """Each quoted string within the run of string characters text[a:b], as (start, end). A
        run is one string except around a template's placeholder: the shared reader marks the
        placeholder's own ${ and } as the template's, so a string that touches them (`${'allow'}`)
        is in one run with the template around it, and read whole it is no word at all."""
        i = a
        while i < b:
            q, j = text[i], i + 1
            if q in "'\"":
                while j < b and text[j] != q:
                    j += 2 if text[j] == "\\" else 1
                yield i, min(j + 1, b)
                i = j + 1
            elif q in "`}":
                # A template's text, from its opening or from the } that ends a placeholder, to
                # its closing backtick or to the ${ that opens the next placeholder.
                while j < b and text[j] != "`" and not text.startswith("${", j):
                    j += 2 if text[j] == "\\" else 1
                if j < b and text[j] == "`":
                    if q == "`":
                        yield i, j + 1
                    i = j + 1
                else:
                    i = j + 2
            else:
                i += 1

    # Each whole string that is one quoted word and nothing else.
    i, n = 0, len(text)
    while i < n:
        if kind[i] != STRING:
            i += 1
            continue
        a = i
        while i < n and kind[i] == STRING:
            i += 1
        for s, e in strings(a, i):
            m = LITERAL.match(text, s, e)
            if not m:
                continue
            word = m.group(2)
            if word in LOOSE:
                route = word_route(word, key_before(s), word in MAY_STAND and taken(s, e))
                if route:
                    add(s, route)
            elif word in WORDS:
                add(s, WORDS[word])
    for m in NAME.finditer(code):
        before = code[: m.start()].rstrip()
        if before.endswith(".") and not before.endswith("...") and not ASSIGNED.match(code, m.end()):
            continue
        if m.group(1) == "allow" and not before.endswith(".") and REFUSES.match(code, m.end()):
            continue
        add(m.start(), NAMES[m.group(1)])
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
        # Every other file of the mod, which its code could read a decision from or run for
        # one: a .json file, a script, any data file. A source file is code, read above, or a
        # test file or a .d.ts, which is no session's code.
        for base, dirs, names in os.walk(folder, onerror=unlisted):
            dirs[:] = sorted(d for d in dirs if d not in NOT_MOD_CODE)
            for name in sorted(names):
                if name.endswith(SOURCE):
                    continue
                path = os.path.join(base, name)
                json_file = name.endswith(".json")
                try:
                    with open(path, errors="replace") as f:
                        text = f.read()
                except OSError as e:
                    cannot(f"{os.path.relpath(path, root)} cannot be read ({e}), so whether it holds a decision is not known.")
                    continue
                files += 1
                # A decision word in a data file is read by the rule code is read by: beside a
                # decision key it answers, and apart from one it passes only as the value of some
                # other key, so a list's element is found. Only a .json file has keys this check
                # can read, so in any other file the quoted word is found wherever it stands.
                for m in (IN_DATA if json_file else IN_OTHER).finditer(text):
                    word = m.group(m.lastindex)
                    if word in WORDS:
                        add_at(path, text, m.start(), WORDS[word])
                        continue
                    key = KEY_IN_DATA.search(text, max(0, m.start() - 400), m.start()) if json_file else None
                    route = word_route(word, key.group(1) if key else None, key is not None)
                    if route:
                        add_at(path, text, m.start(), route)
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
          "a decision word written without quotes in a file of the mod that is not its code, "
          "the word approve or ask read back out of a property it was given to (held.id, or by taking the object apart), "
          "a call made through a renamed copy of the engine's tool object, a hook that passes on the engine's verdict for a different call than the one asked about, "
          "what a mod does itself with $.process.run, $.fs or $.http (no tool call, and no permission rule covers it), a package a mod imports by name, "
          "each mod's tests folder, and any plugin that is not under this folder.")
    return 1 if found or gone else 4 if unread else 0


# Anything this check did not foresee, its shared reader failing to load included, is its own
# answer: exit 4 with words, never a traceback's exit 1, which here means a statement was found (L10).
try:
    from ts_source import CODE, COMMENT, NOT_MOD_CODE, SOURCE, STRING, code_only, hook_events, is_jsx, kinds, mod_code
    code = main()
except Exception as e:
    traceback.print_exc()
    print(f"{P}the check itself failed ({type(e).__name__}: {e}), so nothing was told about what any mod approves.")
    code = 4
sys.exit(code)
PY
