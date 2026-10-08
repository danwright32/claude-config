#!/bin/bash
#
# egress-setup.sh: the one time setup for bug bash read only runs against a deployment
# (claude-config#813). Run once per Mac, by Dan, since it needs his password:
#
#   sudo bash ~/.claude/skills/bug-bash/egress-setup.sh
#
# then, as himself, the self test that measures the rule on this Mac:
#
#   bash ~/.claude/skills/bug-bash/egress.sh selftest
#
# What it changes, and nothing else:
#   1. A group, _bugbash, that owns no file. The read only proxy runs in it, and the egress rule
#      lets only that group's connections through to the site under test.
#   2. egress-helper.sh installed as /usr/local/libexec/bug-bash-egress, owned by root and writable
#      by nobody else, so no process of Dan's can change what it does as root. It only ever loads,
#      reads or removes the one pf anchor com.apple/000.bug-bash-read-only.
#   3. /etc/sudoers.d/bug-bash, letting Dan's user run without a password exactly: that helper's
#      load, unload and status, as root; and any command as himself in the _bugbash group, which
#      carries no right but passage through the rule.
# The helper is a copy: when egress-helper.sh changes, egress.sh refuses until this is run again.
#
#   sudo bash ~/.claude/skills/bug-bash/egress-setup.sh --remove     undoes all three
#   bash ~/.claude/skills/bug-bash/egress-setup.sh --print-sudoers <user>   prints the grant only
set -u
PATH=/usr/bin:/bin:/usr/sbin:/sbin
export PATH

HELPER=/usr/local/libexec/bug-bash-egress
SUDOERS=/etc/sudoers.d/bug-bash
GROUP=_bugbash
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUN_CMD='sudo bash ~/.claude/skills/bug-bash/egress-setup.sh'
USER_RE='^[A-Za-z_][A-Za-z0-9_.-]*$'

die() { local code="$1"; shift; echo "egress-setup: $*" >&2; exit "$code"; }

sudoers_for() {
  printf '# Bug bash read only runs (claude-config#813), installed by egress-setup.sh.\n'
  printf '%s ALL = (root) NOPASSWD: %s load *, %s unload, %s unload *, %s status\n' "$1" "$HELPER" "$HELPER" "$HELPER" "$HELPER"
  printf '%s ALL = (:%s) NOPASSWD: ALL\n' "$1" "$GROUP"
}

if [ "${1:-}" = --print-sudoers ]; then
  [ "$#" -eq 2 ] && [[ $2 =~ $USER_RE ]] || die 2 "usage: egress-setup.sh --print-sudoers <user name>"
  sudoers_for "$2"
  exit 0
fi

[ "$(id -u)" = 0 ] || die 2 "it changes system settings, so run it with sudo: $RUN_CMD"
[ "$(uname -s)" = Darwin ] || die 2 "this sets up the macOS packet filter, and this is not macOS."
user="${SUDO_USER:-}"
{ [ -n "$user" ] && [ "$user" != root ] && [[ $user =~ $USER_RE ]]; } \
  || die 2 "run it with sudo from your own account, so it knows whose runs to allow: $RUN_CMD"

if [ "${1:-}" = --remove ]; then
  # The rule goes first, or nothing goes: with the helper deleted, a rule still loaded could only be
  # removed with pfctl by hand or a reboot.
  if [ -x "$HELPER" ] && ! why="$("$HELPER" unload 2>&1)"; then
    die 1 "the egress rule could not be taken away ($why), so nothing was removed. Run this again once it can be."
  fi
  rm -f "$SUDOERS" "$HELPER"
  if dscl . -read "/Groups/$GROUP" >/dev/null 2>&1; then dseditgroup -o delete "$GROUP" || die 1 "could not delete the $GROUP group."; fi
  echo "Removed: the sudoers entry, the helper and the $GROUP group."
  exit 0
fi
[ "$#" -eq 0 ] || die 2 "usage: $RUN_CMD [--remove]"

# 1. The group.
if ! dscl . -read "/Groups/$GROUP" PrimaryGroupID >/dev/null 2>&1; then
  dseditgroup -o create -r "Bug bash read only proxy" "$GROUP" || die 1 "could not create the $GROUP group."
fi
gid="$(dscl . -read "/Groups/$GROUP" PrimaryGroupID 2>/dev/null | awk '{print $2}')"
[ -n "$gid" ] || die 1 "the $GROUP group has no group id."
[ "$gid" != "$(id -g "$user")" ] || die 1 "the $GROUP group has $user's own group id, so the rule could not tell the proxy apart."

# 2. The helper, behind directories only root can write: a directory anyone else could write would
# let them swap the file root runs.
install -d -o root -g wheel -m 755 /usr/local/libexec || die 1 "could not make /usr/local/libexec."
for d in / /usr /usr/local /usr/local/libexec; do
  read -r owner mode <<< "$(stat -f '%Su %Lp' "$d")"
  [ "$owner" = root ] && [ $(( 8#$mode & 8#022 )) -eq 0 ] \
    || die 1 "$d is owned by $owner with mode $mode, so a program other than root could replace the helper. Not installing it."
done
install -o root -g wheel -m 755 "$HERE/egress-helper.sh" "$HELPER" || die 1 "could not install the helper."

# 3. The sudoers entry, checked on its own and then with everything else before it is relied on.
grep -Eq '^[#@]includedir /private/etc/sudoers\.d' /etc/sudoers \
  || die 1 "/etc/sudoers does not read /etc/sudoers.d, and this setup will not edit /etc/sudoers itself."
tmp="$(mktemp)"
sudoers_for "$user" > "$tmp"
visudo -cf "$tmp" >/dev/null || { rm -f "$tmp"; die 1 "the sudoers entry did not parse, so nothing was installed."; }
install -o root -g wheel -m 440 "$tmp" "$SUDOERS" || { rm -f "$tmp"; die 1 "could not install $SUDOERS."; }
rm -f "$tmp"
visudo -c >/dev/null || { rm -f "$SUDOERS"; die 1 "sudo's settings did not check out with the entry added, so it was taken out again."; }

echo "Set up for $user: the $GROUP group (id $gid), $HELPER and $SUDOERS."
echo "Now run, as yourself, not with sudo: bash ~/.claude/skills/bug-bash/egress.sh selftest"
