#!/bin/bash
# check-mod-tiers.sh <mods dir>: no mod is seated in a tier where the user tier mods' hooks cannot
# hear its calls (#3298).
#
# Why: Claude Code runs every hook in one of five tiers, and since 2.1.328 the types it writes into
# every mod's folder (.claude-plugin/types/claude-code/index.d.ts, the comment on `Tier`) say: "A
# person's hooks don't hear a call an organization's mod makes, or what is raised beneath it while it
# runs. The organization's mods are those it seats in `prepend` or `append` and those it requires in
# `user`." Read there, never run. Every mod here loads in the user tier (CLAUDE_CODE_PLUGIN_DIRS),
# and the guards among them (the secret guard, ask before saving, the Slack drafts gate's mod side)
# refuse a call from a tool.call or tool.check hook. So a mod seated higher could call a tool with
# none of them hearing it, and nothing would say so.
#
# What seats a mod, as the same comment and the plugin authoring reference give it, each read from
# the file Claude Code reads:
#   - the managed settings file, and each .json in managed-settings.d beside it, naming the mod in
#     `prependPlugins` or `appendPlugins`;
#   - the same files setting it true in `enabledPlugins` from a marketplace they declare in
#     `extraKnownMarketplaces` with a remote source (github, git, url or inline settings): "in
#     neither, it is `prepend`, after the listed ones";
#   - the user settings file naming it in `prependPlugins` or `appendPlugins`, which seats a person's
#     own mod wherever no managed settings, Team or Enterprise plan or managed MCP server file sets
#     that list aside. The types do not say a person's hooks hear a mod seated that way, so it is
#     counted as unheard: of the two ways to be wrong, a false failure costs one line read.
# An entry is matched by the whole name before its @ (caller@inline, caller), never part of one.
#
# What misses the call: every other mod with a hook on a tool event (tool.call, tool.check, tool.run
# and the rest), read from its own code with comments, strings and tests left out, unless the
# managed settings seat that mod too, since the organization's hooks hear every call. tool.list is
# left out: "the engine asks a person's `tool.list` hooks about an organization's tool call too".
# There is no list of mods allowed in a higher tier: one is a decision for Dan, made on the issue.
#
# Not read, because no file this check can open holds it: managed settings delivered another way (a
# device management profile, the organization's server), and a plugin the app that started the
# session marks as required by the organization. The last line of every run says so.
#
# CHECK_MOD_TIERS_MANAGED names another managed settings file (the drop in folder is read beside
# it) and CHECK_MOD_TIERS_USER another user settings file; tests/test-mod-tiers.sh sets both for
# every fixture.
#
# Exit codes, each distinct (L11): 0 no mod is seated out of a hook's hearing (the mods, the mods
# that hear and each file read are printed, L98), 1 a mod is, each named with the mods that would not
# hear it, 2 the mods folder does not exist, 3 no python3 to read the files with, 4 a settings file,
# a list in one, a manifest or a mod's source could not be read, so a seat could not be told (never a
# pass over something unread, L490), 5 the folder holds no mod.
dir="${1:-}"
if [ -z "$dir" ] || [ ! -d "$dir" ]; then
  echo "check-mod-tiers: '${dir:-<none given>}' is not a folder, so nothing was checked." >&2
  exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "check-mod-tiers: python3 is not installed, so no settings file was read." >&2
  exit 3
fi
# Where Claude Code reads managed settings from, by platform.
case "$(uname -s)" in
  Darwin) managed_default="/Library/Application Support/ClaudeCode/managed-settings.json" ;;
  *) managed_default="/etc/claude-code/managed-settings.json" ;;
esac
managed="${CHECK_MOD_TIERS_MANAGED:-$managed_default}"
user="${CHECK_MOD_TIERS_USER:-${CLAUDE_CONFIG_DIR:-$HOME/.claude}/settings.json}"
python3 -B - "${dir%/}" "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib" "$managed" "$user" <<'PY'
import glob, json, os, sys

root, managed_path, user_path = sys.argv[1], sys.argv[3], sys.argv[4]
# Which files are a mod's own code, and which of its characters are code, are read by the one
# reader every mod scan shares (#735).
sys.path.insert(0, sys.argv[2])
from ts_source import hook_events, is_jsx, mod_code

P = "check-mod-tiers: "
unread = 0


def cannot(text):
    global unread
    print(P + text)
    unread = 1


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
        cannot(f"{entry}'s plugin.json cannot be read ({e}), so the name a settings file would seat it by is not known.")
        continue
    name = man.get("name") if isinstance(man, dict) else None
    mods[name if isinstance(name, str) and name else entry] = folder
if not mods and not unread:
    print(f"{P}no mod (a folder holding .claude-plugin/plugin.json) was found in {root}, so nothing was checked.")
    sys.exit(5)

# The mods whose hooks hear a tool call another mod makes, each with the tool events it hooks.
hearing = {}
for name, folder in mods.items():
    events = set()
    for path in mod_code(folder):
        try:
            with open(path, errors="replace") as f:
                text = f.read()
        except OSError as e:
            cannot(f"{name}'s {os.path.relpath(path, folder)} cannot be read ({e}), so whether it hooks a tool event is not known.")
            continue
        events.update(e for e in hook_events(text, is_jsx(path)) if e.startswith("tool.") and e != "tool.list")
    if events:
        hearing[name] = sorted(events)

LISTS = (("prependPlugins", "prepend"), ("appendPlugins", "append"))
REMOTE = ("github", "git", "url", "settings")
seats = []  # (mod, tier, whose it is: "organization" or "person", how it is seated)
read = []


def load(path):
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError) as e:
        cannot(f"{path} cannot be read as JSON ({e}), so what it seats cannot be told.")
        return None
    if not isinstance(data, dict):
        cannot(f"{path} cannot be read as JSON settings (it holds no object), so what it seats cannot be told.")
        return None
    return data


def plugin_name(entry):
    return entry.rsplit("@", 1)[0] if "@" in entry else entry


def read_lists(path, data, whose):
    notes = []
    for key, tier in LISTS:
        if key not in data:
            notes.append(f"{key}: not set")
            continue
        if not isinstance(data[key], list):
            cannot(f"{key} in {path} is not a list, so what it seats cannot be told.")
            notes.append(f"{key}: not a list")
            continue
        found = 0
        for entry in data[key]:
            if not isinstance(entry, str):
                cannot(f"an entry of {key} in {path} is not a name ({json.dumps(entry)}), so what it seats cannot be told.")
            elif plugin_name(entry) in mods:
                found += 1
                seats.append((plugin_name(entry), tier, whose, f'{path} lists "{entry}" in {key}'))
        count = len(data[key])
        notes.append(f"{key}: {count} listed" + ("" if not count else f", {found} a mod here" if found else ", none a mod here"))
    return notes


managed_files = ([managed_path] if os.path.exists(managed_path) else []) + sorted(
    glob.glob(os.path.join(glob.escape(os.path.dirname(managed_path)), "managed-settings.d", "*.json"))
)
if not os.path.exists(managed_path):
    read.append(f"no managed settings file at {managed_path}")
enabled, markets = [], {}
for path in managed_files:
    data = load(path)
    if data is None:
        read.append(f"{path} (could not be read)")
        continue
    notes = read_lists(path, data, "organization")
    if "enabledPlugins" in data:
        if isinstance(data["enabledPlugins"], dict):
            on = [k for k, v in data["enabledPlugins"].items() if v is True]
            enabled += [(k, path) for k in on]
            notes.append(f"enabledPlugins: {len(on)} set true")
        else:
            cannot(f"enabledPlugins in {path} is not an object, so what it seats cannot be told.")
    declared = data.get("extraKnownMarketplaces")
    if isinstance(declared, dict):
        for market, entry in declared.items():
            source = entry.get("source") if isinstance(entry, dict) else None
            markets[market] = source.get("source") if isinstance(source, dict) else source
    elif declared is not None:
        cannot(f"extraKnownMarketplaces in {path} is not an object, so what it seats cannot be told.")
    read.append(f"{path} ({', '.join(notes)})")
listed = {mod for mod, _, _, _ in seats}
for key, path in enabled:
    mod, _, market = key.rpartition("@")
    if mod not in mods or mod in listed or market not in markets:
        continue
    kind = markets[market]
    if not isinstance(kind, str):
        cannot(f"the source of the marketplace {market}, which {path} enables {mod} from, cannot be read, so whether {mod} is seated cannot be told.")
    elif kind in REMOTE:
        seats.append((mod, "prepend", "organization", f'{path} sets "{key}" true in enabledPlugins, and the managed settings declare the marketplace {market} with a {kind} source'))

if os.path.exists(user_path):
    data = load(user_path)
    read.append(f"{user_path} (could not be read)" if data is None else f"{user_path} ({', '.join(read_lists(user_path, data, 'person'))})")
else:
    read.append(f"no user settings file at {user_path}")

# The organization's hooks hear every call, so a mod the managed settings seat misses none.
with_organization = {mod for mod, _, whose, _ in seats if whose == "organization"}
failed = 0
for mod, tier, whose, how in seats:
    missing = ", ".join(f"{g} ({', '.join(evs)})" for g, evs in sorted(hearing.items()) if g != mod and g not in with_organization)
    where = f"the organization's {tier} tier: {how}" if whose == "organization" else f"the {tier} tier: {how}, a person's own list in user settings"
    if not missing:
        print(f"{P}{mod} is seated in {where}, and no user tier mod has a hook that would miss a call it makes, so this does not fail.")
        continue
    failed += 1
    if whose == "organization":
        print(f"{P}{mod} is seated in {where}. A person's hooks do not hear a call an organization's mod makes, or what is raised beneath it (Claude Code's types, under Tier, since 2.1.328; read there, never run), so these user tier mods' hooks would not hear a call it makes: {missing}. Take it out of that file, or settle on #3298 whether those mods move to the organization's tier with it.")
    else:
        print(f"{P}{mod} is seated in {where}. Claude Code seats it there wherever no managed settings, Team or Enterprise plan or managed MCP server file sets that list aside (its plugin authoring reference), and its types do not say a person's hooks hear a mod seated there, so it is counted as unheard and these user tier mods' hooks would not hear a call it makes: {missing}. Take it out of that list (#3298).")

names = f" ({', '.join(sorted(hearing))})" if hearing else ""
print(f"{P}{len(mods)} mods checked in {root}, {len(hearing)} with a hook that hears another mod's tool call{names}; {failed} seated where one would not hear it. Read: {'; '.join(read)}. Not read: managed settings delivered any other way (a device management profile, the organization's server) and a plugin the starting app marks as required by the organization, which are in no file this check can open.")
sys.exit(1 if failed else 4 if unread else 0)
PY
