#!/usr/bin/env python3
"""Which Skill calls load a skill shipped by an MCP server (claude-config#3615).

server-skill-ask.sh hands this a PreToolUse payload on stdin. It prints nothing when the skill is
kept on this Mac or the call is not a Skill call, and otherwise one line,

    ask <US> <kind of call> <US> <what it is>

with the unit separator between the parts, which the hook turns into the question.

THE NAMES, from Claude Code's documentation (the MCP and skills pages, read 2026-11-26). The Skill
tool's input names the skill in its "skill" field.

  a skill from a server           <server>:<skill>, as in docs:pdf
  from a claude.ai connector      claude_ai_<name>:<skill>
  from a plugin's server          plugin_<plugin>_<server>:<skill>
  the permission rule form        mcp__<server>__<skill>
  an installed plugin's skill     <plugin>:<skill>
  a directory's own skill         <path>:<skill>, as in apps/web:deploy
  one synced from claude.ai       anthropic-skills:<skill>, a prefix Claude Code reserves for them
  Dan's own, or a bundled one     <skill>, with no prefix

NO SERVER SKILL HAS EVER LOADED on either Mac (the feature is off for the account), so no payload
for one was ever seen. The forms above are the documentation's, not a measurement.

THE RULE. A server's skill and a plugin's carry the same form, so the form alone cannot tell them
apart. A name with a prefix passes only when the skill it names is found on this Mac: under the
install folder of a plugin of that name (~/.claude/plugins/installed_plugins.json), in one of the
places Claude Code reads a plugin's skills and commands from, which plugin_holds lists (a skill
folder under skills/ or under a directory the manifest lists, named by the folder or in the
SKILL.md's own text, or a command file under commands/); or, for a directory's own, under that
directory of the working directory. A file anywhere else inside the plugin does not make a name
the plugin's. Everything else with a prefix is asked about, which is the side it fails to: a
plugin skill this cannot find costs Dan one question, and a server skill it took for local would
load unread. A name starting mcp__ is asked about whatever follows.

A name is read the way the documentation says Claude Code compares names: compatibility forms
(a fullwidth colon) as their plain ones, spacing and invisible characters ignored. Punctuation
this cannot place is asked about too.

What it cannot read is asked about: a Skill call naming no skill, a payload that does not parse
and names the Skill tool or no tool whole, or is cut short inside a tool name that could still be
Skill, and a field of the input it does not know that names an MCP server. A payload naming
another tool is never this hook's.
"""
import json
import os
import re
import sys
import unicodedata

US = "\x1f"
KIND = "loading a skill from an MCP server"
NAME_SHOWN = 200
PLAIN_MARKS = "_.-/:"
WALK_DEPTH = 6
SKIPPED_DIRS = {"node_modules", ".git"}


def shown(text):
    """A name as the question shows it: printable, and cut short when long."""
    text = "".join(c if c.isprintable() else " " for c in str(text))
    if len(text) > NAME_SHOWN:
        text = text[:NAME_SHOWN] + " ... (cut short)"
    return text


def normal(name):
    """A skill's name as Claude Code compares it, by its documentation."""
    name = unicodedata.normalize("NFKC", name)
    name = "".join(c for c in name if unicodedata.category(c)[0] not in "ZC")
    return name.lstrip("/")


def installed_plugins(home):
    """Each installed plugin's name, lower case, with its install folders, and why the record of
    them could not be used, or None when it could. An unread record is never an empty one: the
    question says which it was (L11)."""
    found = {}
    path = os.path.join(home, ".claude", "plugins", "installed_plugins.json")
    if not os.path.exists(path):
        return found, "this Mac has no record of installed plugins (~/.claude/plugins/installed_plugins.json is not there)"
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        return found, "this Mac's record of installed plugins (~/.claude/plugins/installed_plugins.json) could not be read"
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        return found, "this Mac's record of installed plugins (~/.claude/plugins/installed_plugins.json) holds no list of plugins this hook could read"
    for key, entries in plugins.items():
        if not isinstance(key, str) or not isinstance(entries, list):
            continue
        name = key.split("@", 1)[0].lower()
        for e in entries:
            path = e.get("installPath") if isinstance(e, dict) else None
            if isinstance(path, str) and path:
                found.setdefault(name, []).append(path)
    return found, None


def own_name(skill_file):
    """The name a SKILL.md gives itself in its frontmatter, or None."""
    try:
        with open(skill_file, encoding="utf-8", errors="replace") as f:
            head = f.read(4096)
    except Exception:
        return None
    if not head.startswith("---"):
        return None
    for line in head.split("\n")[1:]:
        if line.strip() == "---":
            break
        m = re.match(r"\s*name\s*:\s*(.+?)\s*$", line)
        if m:
            return m.group(1).strip("\"'").lower()
    return None


def manifest_of(folder):
    """A plugin's manifest: {} when it has none, None when it has one this could not read."""
    path = os.path.join(folder, ".claude-plugin", "plugin.json")
    if not os.path.lexists(path):
        return {}
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        return None
    return data if isinstance(data, dict) else None


def listed(value):
    """The paths a manifest key lists: one path or a list of them."""
    if isinstance(value, str):
        return [value]
    if isinstance(value, list):
        return [v for v in value if isinstance(v, str)]
    return []


def placed(folder, rel, root_too=False):
    """A manifest's path as a path inside the plugin's folder, or None. The documentation: every
    such path "is relative to the plugin root and must start with ./", and skills also takes "."
    for the root itself."""
    if root_too and rel in (".", "./"):
        return folder
    if not rel.startswith("./"):
        return None
    path = os.path.normpath(os.path.join(folder, rel))
    top = os.path.normpath(folder)
    return path if path != top and path.startswith(top + os.sep) else None


def reached(folder, path):
    """Whether a directory in a plugin's folder is one a walk down from that folder comes to: no
    more than WALK_DEPTH folders down, under no skipped folder and through no link. This rule
    replaced such a walk, and nothing the walk did not find may pass now."""
    rel = os.path.relpath(path, folder)
    parts = [] if rel == "." else rel.split(os.sep)
    if ".." in parts or len(parts) > WALK_DEPTH:
        return False
    at = folder
    for p in parts:
        at = os.path.join(at, p)
        if p in SKIPPED_DIRS or os.path.islink(at):
            return False
    return os.path.isdir(at)


def skill_at(folder, want, by_folder=True):
    """Whether a folder holds a SKILL.md that names this skill, in its own text or by its folder."""
    f = os.path.join(folder, "SKILL.md")
    if not os.path.isfile(f):
        return False
    return own_name(f) == want or (by_folder and os.path.basename(os.path.normpath(folder)).lower() == want)


def holds_skill(folder, manifest, want):
    default = os.path.join(folder, "skills")
    if "skills" not in manifest and not os.path.isdir(default):
        # "A plugin with SKILL.md at its root, no skills/, and no skills key loads as a single
        # skill", named in its own text, or after the plugin's folder when it names itself nowhere.
        f = os.path.join(folder, "SKILL.md")
        return os.path.isfile(f) and skill_at(folder, want, by_folder=own_name(f) is None)
    scanned = [default]
    for rel in listed(manifest.get("skills")):
        path = placed(folder, rel, root_too=True)
        if path and path not in scanned:
            scanned.append(path)
    for d in scanned:
        if not reached(folder, d):
            continue
        # A listed directory is "a directory of <name>/SKILL.md folders or one folder holding
        # SKILL.md directly"; the default skills/ is the first kind only.
        if d != default and skill_at(d, want, by_folder=os.path.normpath(d) != os.path.normpath(folder)):
            return True
        try:
            names = sorted(os.listdir(d))
        except OSError:
            continue
        for n in names:
            sub = os.path.join(d, n)
            if reached(folder, sub) and skill_at(sub, want):
                return True
    return False


def command_under(folder, top, want):
    """Whether commands/ holds this command: "commands/<file>.md" is <file>, and "a subdirectory
    adds a segment", so commands/db/migrate.md is db:migrate."""
    if not reached(folder, top):
        return False
    for root, dirs, files in os.walk(top):
        dirs[:] = [d for d in dirs if reached(folder, os.path.join(root, d))]
        rel = os.path.relpath(root, top)
        under = [] if rel == "." else [p.lower() for p in rel.split(os.sep)]
        for f in files:
            if f.lower().endswith(".md") and ":".join(under + [f[:-3].lower()]) == want:
                return True
    return False


def holds_command(folder, manifest, want):
    default = os.path.join(folder, "commands")
    if "commands" not in manifest:
        return command_under(folder, default, want)
    # A manifest's commands key "replaces the default commands/ scan": only what it lists is a
    # command. Of that, this passes what sits in commands/ itself, which is all the walk this rule
    # replaced could find: the folder when it is listed, a file listed straight inside it, and a
    # name mapped to such a file of the same name. A command listed anywhere else, or written
    # inline in the manifest, is asked about, as it was before.
    def flat(path):
        return (os.path.dirname(path) == default and path.lower().endswith(".md")
                and os.path.basename(path)[:-3].lower() == want and os.path.isfile(path) and reached(folder, default))
    value = manifest["commands"]
    if isinstance(value, dict):
        for key, entry in value.items():
            source = entry.get("source") if isinstance(entry, dict) else None
            path = placed(folder, source) if isinstance(source, str) else None
            if isinstance(key, str) and key.lower() == want and path and flat(path):
                return True
        return False
    for rel in listed(value):
        path = placed(folder, rel)
        if path and (flat(path) or (path == default and command_under(folder, default, want))):
            return True
    return False


def plugin_holds(folder, skill):
    """Whether a plugin's install folder holds a skill or a command of this name, in one of the
    places Claude Code reads a plugin's skills and commands from. None when the plugin's manifest
    is there and could not be read, since it is what says where they are.

    The places, from Claude Code's plugin pages (the manifest reference, "Add components to a
    plugin" and the skills page, read 2026-11-26): skills/<name>/SKILL.md at the plugin's root; the
    directories the manifest's skills key lists, which add to skills/; a SKILL.md at the root when
    there is no skills/ and no skills key; and commands/ at the root with its subdirectories, or
    what the manifest's commands key lists in its place. A file anywhere else in the plugin (a
    SKILL.md among its examples, a page under a folder that happens to be named commands) is not
    the plugin's skill, so a name found only there is asked about. Not read: components a
    marketplace entry adds to a plugin, which are asked about."""
    want = skill.lower()
    folder = os.path.normpath(folder)
    manifest = manifest_of(folder)
    if manifest is None:
        return None
    return holds_skill(folder, manifest, want) or holds_command(folder, manifest, want)


def server_words(prefix):
    """How the question names the server a prefix stands for."""
    if prefix.startswith("claude_ai_"):
        return "the claude.ai connector " + shown(prefix[len("claude_ai_"):])
    if prefix.startswith("plugin_"):
        return "an MCP server shipped by a plugin (" + shown(prefix[len("plugin_"):]) + ")"
    return "the MCP server " + shown(prefix)


def text_of(skill, server):
    return ("the skill " + shown(skill) + " comes from " + server + ". Its text is written by that server, "
            "not kept on this Mac, and the server can change it at any time, so what loads now may not be "
            "what loaded last time.")


def judge(raw_name, cwd, home):
    """None when the skill is kept on this Mac, else what the question says about it."""
    name = normal(raw_name)
    if not name:
        return "the Skill call names no skill this hook could read, so whether it is a server's could not be told."
    if name.lower().startswith("mcp__"):
        rest = name[len("mcp__"):]
        server, _, skill = rest.partition("__")
        return text_of(skill or "(none named)", server_words(server))
    for c in name:
        if unicodedata.category(c)[0] in "PS" and c not in PLAIN_MARKS:
            return ("the skill name " + shown(raw_name) + " holds punctuation this hook cannot place, so whether "
                    "it is a server's could not be told.")
    if ":" not in name:
        return None
    prefix, skill = name.split(":", 1)
    if prefix.lower() == "anthropic-skills":
        return None
    if "/" in prefix:
        if cwd and os.path.isfile(os.path.join(cwd, prefix, ".claude", "skills", skill, "SKILL.md")):
            return None
        return (text_of(skill, server_words(prefix))
                + " No skill " + shown(skill) + " is on disk under " + shown(prefix) + " in the working directory.")
    plugins, unread = installed_plugins(home)
    no_manifest = False
    for folder in plugins.get(prefix.lower(), []):
        held = plugin_holds(folder, skill)
        if held:
            return None
        if held is None:
            no_manifest = True
    also = " " + shown(prefix) + ":" + shown(skill) + " is also the form a plugin's skill takes, and "
    if unread:
        return text_of(skill, server_words(prefix)) + also + unread + ", so whether a plugin holds it could not be told."
    if no_manifest:
        # Never "no plugin holds it": nothing was looked for (L11).
        return (text_of(skill, server_words(prefix)) + also + "the manifest of the installed plugin " + shown(prefix)
                + " (.claude-plugin/plugin.json in its folder) could not be read, so where its skills are, and "
                "whether it holds this one, could not be told.")
    return (text_of(skill, server_words(prefix)) + also + "no installed plugin named "
            + shown(prefix) + " holds a skill " + shown(skill) + " on this Mac.")


def verdict(raw, home):
    try:
        d = json.loads(raw)
    except Exception:
        d = None
    tool = d.get("tool_name") if isinstance(d, dict) else None
    if isinstance(tool, str):
        if tool != "Skill":
            return None
        ti = d.get("tool_input")
        if not isinstance(ti, dict):
            return "the payload's input could not be read as a Skill call's, so whether the skill is a server's could not be told."
        skill = ti.get("skill")
        if not isinstance(skill, str):
            return "the payload names no skill this hook could read, so whether it is a server's could not be told."
        cwd = d.get("cwd") if isinstance(d.get("cwd"), str) else ""
        found = judge(skill, cwd, home)
        if found:
            return found
        # A field this hook does not know may be where a server's skill is really named.
        for k, v in ti.items():
            if k in ("skill", "args"):
                continue
            if "mcp__" in (str(k) + json.dumps(v, ensure_ascii=True)).lower():
                return ("the Skill call for " + shown(skill) + " carries a field this hook does not know, " + shown(k)
                        + ", that names an MCP server, so the skill may be that server's.")
        return None
    # A payload that is not a tool call is judged by its text. Every tool it names whole is read,
    # never the first alone: one naming only other tools is not this hook's, and one naming the
    # Skill tool, or no tool whole, is a Skill call nobody could read.
    whole_key = r"\"tool_name\"\s*:\s*\"([^\"\\]*)\""
    whole = re.findall(whole_key, raw)
    if whole and "Skill" not in whole:
        # Another tool's name read whole does not vouch for the rest of the text: the call's own
        # name may be one the text is cut short inside, after them. One that could still be Skill
        # is a Skill call nobody could read.
        cut = re.search(r"\"tool_name\"\s*:\s*\"([^\"\\]*)$", re.sub(whole_key, " ", raw))
        if not cut or not "Skill".startswith(cut.group(1)):
            return None
    return "the payload could not be read as a Skill call, so whether the skill is a server's could not be told."


def main():
    sys.stdout.reconfigure(errors="replace")
    raw = sys.stdin.buffer.read().decode("utf-8", "replace")
    what = verdict(raw, os.environ.get("HOME", ""))
    if what:
        sys.stdout.write("ask" + US + KIND + US + what.replace(US, " ").replace("\x00", ""))


if __name__ == "__main__":
    main()
