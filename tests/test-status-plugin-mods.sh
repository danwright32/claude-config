#!/usr/bin/env bash
# `claude-sync status` names an installed plugin from elsewhere that carries a mod (claude-config#3681).
#
# Claude Code's built in guard is off on both Macs (#876), and the check that stands in for it
# (tools/check-mod-approvals.sh) reads only the mods under payload/mods. A plugin installed from a
# marketplace can carry a mod too (a hooks module), and nothing here reads that code, so status
# says which ones do. Every case is a stand in plugin folder in a scratch home: no real plugin, no
# real settings, and nothing is disabled or written (the last section proves the files are left as
# they were).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../claude-sync"
. "$HERE/../payload/hooks/lib/suite-deadline.sh" || {
  echo "FAIL: $(basename "$0"): lib/suite-deadline.sh is missing, so this suite cannot bound its own wall clock. Refusing to run unbounded."
  printf 'SUITE-RESULT passed=0 failed=1\n'
  exit 1
}
suite_deadline_arm || exit $?

pass=0; fail=0
check(){   # $1 = name  $2 = "ok" or the evidence of failure
  if [ "$2" = ok ]; then pass=$((pass + 1)); else fail=$((fail + 1)); echo "FAIL: $1: $2"; fi
}
WORK="$(mktemp -d "${TMPDIR:-/tmp}/status-plugin-mods.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
WORK="$(cd "$WORK" && pwd -P)"

# Everything else status reads from the machine, pointed inside WORK.
export SYNC_PS_FIXTURE="$WORK/ps-none"; : > "$SYNC_PS_FIXTURE"
export SYNC_SCRATCH_ROOT="$WORK/scratch-root"; mkdir -p "$SYNC_SCRATCH_ROOT"
export SYNC_MANAGED_SETTINGS="$WORK/managed-settings.json"
printf '{"prependPlugins": []}\n' > "$SYNC_MANAGED_SETTINGS"
export SYNC_CLAUDE_BIN="$WORK/no-such-claude"
export SYNC_GH="$WORK/no-such-gh"
export SYNC_NO_GIT=1 SYNC_NO_NOTIFY=1
export SYNC_TEMP_ROOTS="/no-such-temp-root-exists-here"
REPO="$WORK/repo"; mkdir -p "$REPO"

# A stand in plugin: $1 = home  $2 = name  $3 = hooks/hooks.json text (empty for none)
# $4 = plugin.json text (a plain manifest when left out)
plugin(){
  local d="$1/plugins/cache/market/$2/1.0.0"
  mkdir -p "$d/.claude-plugin" "$d/hooks"
  if [ -n "${4:-}" ]; then printf '%s\n' "$4" > "$d/.claude-plugin/plugin.json"
  else printf '{"name": "%s", "version": "1.0.0"}\n' "$2" > "$d/.claude-plugin/plugin.json"; fi
  [ -z "$3" ] || printf '%s\n' "$3" > "$d/hooks/hooks.json"
}
# The install record for a home: every plugin folder under its cache, as Claude Code writes it.
record(){
  local h="$1" d rows="" name
  for d in "$h"/plugins/cache/market/*/1.0.0; do
    [ -d "$d" ] || continue
    name="$(basename "$(dirname "$d")")"
    rows+="${rows:+,}\"$name@market\": [{\"scope\": \"user\", \"installPath\": \"$d\", \"version\": \"1.0.0\"}]"
  done
  printf '{"version": 2, "plugins": {%s}}\n' "$rows" > "$h/plugins/installed_plugins.json"
}
status(){ CLAUDE_HOME="$1" SYNC_REPO="$REPO" bash "$SCRIPT" status 2>&1 || true; }
section(){ printf '%s\n' "$1" | sed -n '/^--- plugins from elsewhere that carry a mod/,/^---/p' | sed '1d;/^---/d'; }
MODS='{ "modules": ["./register.ts"] }'
SETTINGS_HOOKS='{ "hooks": { "PreToolUse": [{ "matcher": "Bash", "hooks": [{ "type": "command", "command": "true" }] }] } }'

# ---- 1. an enabled plugin that carries a mod is named; one with settings hooks alone is not ----
H="$WORK/h1"; mkdir -p "$H/plugins"
plugin "$H" carries "$MODS"
plugin "$H" settingshooks "$SETTINGS_HOOKS"
plugin "$H" nohooks ""
plugin "$H" offmod '{ "modules": ["./a.ts", "./b.ts"] }'
plugin "$H" bymanifest "" '{"name": "bymanifest", "version": "1.0.0", "hooks": "./config/hooks.json"}'
mkdir -p "$H/plugins/cache/market/bymanifest/1.0.0/config"
printf '%s\n' '{ "modules": ["./mod.ts"] }' > "$H/plugins/cache/market/bymanifest/1.0.0/config/hooks.json"
plugin "$H" inline "" '{"name": "inline", "version": "1.0.0", "hooks": {"modules": ["./hooks/in.ts"]}}'
record "$H"
printf '%s\n' '{"hooks": {}, "enabledPlugins": {"carries@market": true, "settingshooks@market": true, "nohooks@market": true, "offmod@market": false, "bymanifest@market": true, "inline@market": true}}' > "$H/settings.json"
out="$(status "$H")"
sec="$(section "$out")"
on_line="$(printf '%s\n' "$sec" | grep -F 'enabled everywhere on this Mac:' || true)"
off_line="$(printf '%s\n' "$sec" | grep -F 'off at user scope' || true)"
printf '%s\n' "$out" | grep -qF -- '--- plugins (per Mac, never synced) ---' \
  && check "fixture: this is a real status run (the plugins report beside it is there)" ok \
  || check "fixture: this is a real status run (the plugins report beside it is there)" "$out"
case "$on_line" in *"carries (its hooks modules: ./register.ts)"*) check "an enabled plugin with a hooks module is named, with the module" ok ;;
  *) check "an enabled plugin with a hooks module is named, with the module" "${sec:-<no section>}" ;; esac
case "$on_line" in *"#3681"*"deny rule"*|*"deny rule"*"#3681"*) check "and the line says why it matters and names the issue" ok ;;
  *) check "and the line says why it matters and names the issue" "${on_line:-<no line>}" ;; esac
case "$on_line" in *"bymanifest (its hooks modules: ./mod.ts)"*) check "a hooks file the manifest names is read too" ok ;;
  *) check "a hooks file the manifest names is read too" "${sec:-<no section>}" ;; esac
case "$on_line" in *"inline (its hooks modules: ./hooks/in.ts)"*) check "and modules written in the manifest itself" ok ;;
  *) check "and modules written in the manifest itself" "${sec:-<no section>}" ;; esac
case "$sec" in *settingshooks*|*nohooks*) check "a plugin with settings hooks alone, or no hooks, is not named" "$sec" ;;
  *) check "a plugin with settings hooks alone, or no hooks, is not named" ok ;; esac
case "$off_line" in *"offmod (its hooks modules: ./a.ts, ./b.ts)"*) check "a plugin off at user scope that carries a mod is named on its own line" ok ;;
  *) check "a plugin off at user scope that carries a mod is named on its own line" "${sec:-<no section>}" ;; esac
case "$on_line" in *offmod*) check "and never as enabled everywhere" "$on_line" ;; *) check "and never as enabled everywhere" ok ;; esac

# ---- 2. no enablement recorded: every installed plugin loads, so each one counts as enabled ----
H="$WORK/h2"; mkdir -p "$H/plugins"
plugin "$H" carries "$MODS"
record "$H"
printf '%s\n' '{"hooks": {}}' > "$H/settings.json"
sec="$(section "$(status "$H")")"
case "$sec" in *"enabled everywhere on this Mac: carries"*) check "with no enablement recorded, a plugin with a mod is named as enabled" ok ;;
  *) check "with no enablement recorded, a plugin with a mod is named as enabled" "${sec:-<no section>}" ;; esac

# ---- 3. nothing carries a mod: nothing is said ----
H="$WORK/h3"; mkdir -p "$H/plugins"
plugin "$H" settingshooks "$SETTINGS_HOOKS"
record "$H"
printf '%s\n' '{"hooks": {}, "enabledPlugins": {"settingshooks@market": true}}' > "$H/settings.json"
out="$(status "$H")"
printf '%s\n' "$out" | grep -qF 'that carry a mod' && check "no plugin with a mod says nothing" "$(section "$out")" || check "no plugin with a mod says nothing" ok
printf '%s\n' "$out" | grep -qF -- 'enabled everywhere on this Mac: settingshooks' \
  && check "and that quiet run is a real status run that read the plugins" ok || check "and that quiet run is a real status run that read the plugins" "$out"

# ---- 4. what cannot be read is said, never passed over ----
H="$WORK/h4"; mkdir -p "$H/plugins"
plugin "$H" broken '{ "modules": ['
plugin "$H" gone "$MODS"
record "$H"
rm -rf "$H/plugins/cache/market/gone/1.0.0"
printf '%s\n' '{"hooks": {}, "enabledPlugins": {"broken@market": true, "gone@market": true}}' > "$H/settings.json"
sec="$(section "$(status "$H")")"
case "$sec" in *"could not be read"*broken*) check "a plugin whose hooks file is not valid JSON is named as unread" ok ;;
  *) check "a plugin whose hooks file is not valid JSON is named as unread" "${sec:-<no section>}" ;; esac
case "$sec" in *"could not be read"*gone*) check "and one whose folder is missing" ok ;;
  *) check "and one whose folder is missing" "${sec:-<no section>}" ;; esac
H="$WORK/h5"; mkdir -p "$H/plugins"
printf '%s\n' '{"version": 2, "plugins": ' > "$H/plugins/installed_plugins.json"
printf '%s\n' '{"hooks": {}}' > "$H/settings.json"
sec="$(section "$(status "$H")")"
case "$sec" in *"installed_plugins.json could not be read as JSON"*) check "an install record that is not valid JSON is said, not read as no plugins" ok ;;
  *) check "an install record that is not valid JSON is said, not read as no plugins" "${sec:-<no section>}" ;; esac

# ---- 5. our own mods are not named: the build check reads those ----
H="$WORK/h6"; mkdir -p "$H/plugins" "$H/mods/ours/.claude-plugin" "$H/mods/ours/hooks"
printf '%s\n' '{"name": "ours", "version": "0.1.0"}' > "$H/mods/ours/.claude-plugin/plugin.json"
printf '%s\n' "$MODS" > "$H/mods/ours/hooks/hooks.json"
printf '{"version": 2, "plugins": {"ours@inline": [{"scope": "user", "installPath": "%s"}]}}\n' "$H/mods/ours" > "$H/plugins/installed_plugins.json"
printf '%s\n' '{"hooks": {}}' > "$H/settings.json"
out="$(status "$H")"
printf '%s\n' "$out" | grep -qF 'that carry a mod' && check "a mod in this home's own mods folder is not named" "$(section "$out")" || check "a mod in this home's own mods folder is not named" ok

# ---- 6. it reads only ----
H="$WORK/h1"
before="$(cd "$H" && find settings.json plugins -type f -exec cksum {} + | sort)"
status "$H" >/dev/null
after="$(cd "$H" && find settings.json plugins -type f -exec cksum {} + | sort)"
[ "$before" = "$after" ] && check "status leaves the settings, the install record and every plugin file as they were" ok \
  || check "status leaves the settings, the install record and every plugin file as they were" "$(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after"))"

echo "passed: $pass, failed: $fail"
printf 'SUITE-RESULT passed=%s failed=%s\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
