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
install folder of a plugin of that name (~/.claude/plugins/installed_plugins.json), as a skill
folder, a SKILL.md whose own name it is, or a command file; or, for a directory's own, under that
directory of the working directory. Everything else with a prefix is asked about, which is the
side it fails to: a plugin skill this cannot find costs Dan one question, and a server skill it
took for local would load unread. A name starting mcp__ is asked about whatever follows.

A name is read the way the documentation says Claude Code compares names: compatibility forms
(a fullwidth colon) as their plain ones, spacing and invisible characters ignored. Punctuation
this cannot place is asked about too.

What it cannot read is asked about: a Skill call naming no skill, a payload that does not parse
and names the Skill tool or no tool whole, and a field of the input it does not know that names
an MCP server. A payload naming another tool is never this hook's.
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
    """Each installed plugin's name, lower case, with its install folders."""
    found = {}
    try:
        with open(os.path.join(home, ".claude", "plugins", "installed_plugins.json"), encoding="utf-8", errors="replace") as f:
            data = json.load(f)
    except Exception:
        return found
    plugins = data.get("plugins") if isinstance(data, dict) else None
    if not isinstance(plugins, dict):
        return found
    for key, entries in plugins.items():
        if not isinstance(key, str) or not isinstance(entries, list):
            continue
        name = key.split("@", 1)[0].lower()
        for e in entries:
            path = e.get("installPath") if isinstance(e, dict) else None
            if isinstance(path, str) and path:
                found.setdefault(name, []).append(path)
    return found


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


def plugin_holds(folder, skill):
    """Whether a plugin's install folder holds a skill or a command of this name."""
    want = skill.lower()
    base = folder.rstrip(os.sep).count(os.sep)
    for root, dirs, files in os.walk(folder):
        if root.count(os.sep) - base >= WALK_DEPTH:
            dirs[:] = []
        dirs[:] = [d for d in dirs if d not in SKIPPED_DIRS]
        if "SKILL.md" in files:
            if os.path.basename(root).lower() == want or own_name(os.path.join(root, "SKILL.md")) == want:
                return True
        parts = [p.lower() for p in os.path.relpath(root, folder).split(os.sep)]
        if "commands" in parts:
            under = parts[parts.index("commands") + 1:]
            for f in files:
                if f.lower().endswith(".md") and ":".join(under + [f[:-3].lower()]) == want:
                    return True
    return False


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
    for folder in installed_plugins(home).get(prefix.lower(), []):
        if plugin_holds(folder, skill):
            return None
    return (text_of(skill, server_words(prefix))
            + " " + shown(prefix) + ":" + shown(skill) + " is also the form a plugin's skill takes, and no installed plugin named "
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
    whole = re.findall(r"\"tool_name\"\s*:\s*\"([^\"\\]*)\"", raw)
    if whole and "Skill" not in whole:
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
