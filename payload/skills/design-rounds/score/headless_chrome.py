#!/usr/bin/env python3
"""headless_chrome.py: the one place every hidden Chrome the design rounds start is found
(claude-config#2191), by make-settled.py (through chrome_frame.find_chrome), by capture-web.mjs and
capture-terminal.mjs (the score's "chrome" channel), by headless-dom.sh, and by every suite.

    python3 headless_chrome.py              print the Chrome to run; exit 2 saying why there is none
    python3 headless_chrome.py vet <path>   exit 0 when <path> may be run hidden; exit 2 saying why not

WHY NOT DAN'S CHROME. Every hidden Chrome once ran /Applications/Google Chrome.app, the copy Dan
uses, and each one checked in with macOS as com.google.Chrome (unified log, 2026-11-03 22:25 ET:
CHECKIN com.google.Chrome, foreground=1, launchedByLS=0). So while a suite started them back to back,
a click on Chrome in the Dock reached a windowless test copy and Dan's own Chrome did not open. A
program inside a bundle whose id is com.google.Chrome is therefore refused here, wherever it lives
and whatever it is called, and nothing falls back to it.

WHAT IS RUN INSTEAD. The Chrome Headless Shell of the one shared Playwright each machine keeps for
the design match score (install-playwright.sh, shared-playwright.json, beside this file): a bare
program with no app bundle, which checks in with no bundle id at all (lsappinfo, 2026-11-08:
bundleID=[ NULL ], type UIElement), so nothing Dan clicks can reach it, and which makes no copy of
itself in the code sign clone folder (#988), having no bundle to copy. It is found at the revision
the installed Playwright names in its browsers.json, the same way on both Macs and on a Linux runner,
which runs install-playwright.sh first. DESIGN_ROUNDS_CHROME names another build instead (Chrome for
Testing, say); it is vetted like any other, and one naming nothing runnable is refused rather than
passed over, so a typo in it is never a different Chrome.

When neither gives a Chrome, this refuses by name with the command that installs one. Exit codes:
0 found (or vetted), 2 none (or refused).
"""
import glob
import json
import os
import plistlib
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PIN = os.path.join(HERE, "shared-playwright.json")
INSTALLER = os.path.join(HERE, "install-playwright.sh")
# The bundle id Dan's own Google Chrome checks in with.
DANS_CHROME = "com.google.Chrome"
SHELL_NAME = "chromium-headless-shell"


class NoHiddenChrome(Exception):
    """There is no separate build to run hidden, or the one named may not be run."""


def install_hint():
    return "Install the separate build with: bash %s" % INSTALLER


def bundle_id(path):
    """The CFBundleIdentifier of the app bundle the program at path sits in, by its real path, or None
    when it sits in none. Read from the bundle's own Info.plist, never from its name, so a renamed copy
    of Dan's Chrome is told as surely as the original."""
    p = os.path.realpath(path)
    while p and p != os.path.dirname(p):
        plist = os.path.join(p, "Contents", "Info.plist")
        if p.endswith(".app") and os.path.isfile(plist):
            try:
                with open(plist, "rb") as fh:
                    return plistlib.load(fh).get("CFBundleIdentifier")
            except Exception as err:  # an unreadable plist is not proof it is someone else's Chrome
                raise NoHiddenChrome("%s sits in the app bundle %s, whose Info.plist could not be read (%s), "
                                     "so it cannot be told from the Chrome Dan uses" % (path, p, err))
        p = os.path.dirname(p)
    return None


def vet(path):
    """path, when it is a program this may run hidden; NoHiddenChrome saying why, when it is not."""
    if not path or not os.path.isfile(path) or not os.access(path, os.X_OK):
        raise NoHiddenChrome("%s is not a program this can run" % path)
    if bundle_id(path) == DANS_CHROME:
        raise NoHiddenChrome("%s is Google Chrome, the Chrome Dan uses (bundle id %s). A hidden copy of it checks "
                             "in with macOS under that id, so a click on Chrome in the Dock can reach the test copy "
                             "instead of his own (claude-config#2191). %s"
                             % (path, DANS_CHROME, install_hint()))
    return path


def shared_root(home):
    with open(PIN, encoding="utf-8") as fh:
        rel = json.load(fh)["root"]
    return os.path.join(home, rel)


def shared_shell(home):
    """The shared Playwright's headless shell under home, at the revision that Playwright names;
    NoHiddenChrome saying what is missing otherwise."""
    root = shared_root(home)
    manifest = os.path.join(root, "node_modules", "playwright-core", "browsers.json")
    try:
        with open(manifest, encoding="utf-8") as fh:
            browsers = json.load(fh).get("browsers") or []
    except (OSError, ValueError) as err:
        raise NoHiddenChrome("there is no shared Playwright at %s (%s)" % (root, err))
    revision = next((str(b.get("revision")) for b in browsers if b.get("name") == SHELL_NAME), None)
    if not revision:
        raise NoHiddenChrome("the shared Playwright at %s names no %s in %s" % (root, SHELL_NAME, manifest))
    folder = os.path.join(root, "browsers", "%s-%s" % (SHELL_NAME.replace("-", "_"), revision))
    found = sorted(glob.glob(os.path.join(folder, "chrome-headless-shell-*", "chrome-headless-shell")))
    if len(found) != 1:
        raise NoHiddenChrome("the shared Playwright at %s has %s headless shell program at %s, where its "
                             "Playwright names revision %s" % (root, "no" if not found else "more than one",
                                                               os.path.join(folder, "chrome-headless-shell-*"), revision))
    try:
        return vet(found[0])
    except NoHiddenChrome as err:
        raise NoHiddenChrome("the shared Playwright's headless shell cannot be run: %s" % err)


def find(env=None):
    """The Chrome every hidden run uses: DESIGN_ROUNDS_CHROME when it is set, else the shared
    Playwright's headless shell. NoHiddenChrome, naming the install command, when there is none."""
    env = os.environ if env is None else env
    named = env.get("DESIGN_ROUNDS_CHROME")
    if named:
        try:
            return vet(named)
        except NoHiddenChrome as err:
            raise NoHiddenChrome("DESIGN_ROUNDS_CHROME names a Chrome this will not run hidden: %s. Point it at a "
                                 "separate build, or unset it to use the shared Playwright's headless shell" % err)
    home = env.get("HOME") or os.path.expanduser("~")
    try:
        return shared_shell(home)
    except NoHiddenChrome as err:
        raise NoHiddenChrome("there is no separate headless Chrome to run hidden: %s. Google Chrome itself is never "
                             "run in its place, since a hidden copy of it can take Dan's click on Chrome in the Dock "
                             "(claude-config#2191). %s" % (err, install_hint()))


def main(argv):
    try:
        if len(argv) == 1:
            print(find())
        elif len(argv) == 3 and argv[1] == "vet":
            vet(argv[2])
        else:
            print("usage: headless_chrome.py [vet <path>]", file=sys.stderr)
            return 2
    except NoHiddenChrome as err:
        print("headless_chrome.py: %s" % err, file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
