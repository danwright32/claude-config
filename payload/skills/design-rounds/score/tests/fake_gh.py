#!/usr/bin/env python3
"""A stand in for gh, so no test of the design score's GitHub side reaches the network.

It reads $FAKE_GH/routes.json, a list of {"args": [...], "out": text or JSON, "rc": 0, "err": "",
"token": ""}: the first route whose args the call STARTS with answers it, and one with "token" answers
only a call made with that GH_TOKEN (an account other than the active one). `auth status` lists
$FAKE_GH/accounts, and `auth token -u NAME` prints "tok-NAME". Every call is appended to
$FAKE_GH/calls.log as one JSON line, with any --body-file's text, so a test can read what was posted.
"""
import json
import os
import sys

root = os.environ["FAKE_GH"]
args = sys.argv[1:]
token = os.environ.get("GH_TOKEN", "")
entry = {"args": args, "token": token}
for i, a in enumerate(args):
    if a in ("--body-file", "-F") and i + 1 < len(args) and os.path.isfile(args[i + 1]):
        with open(args[i + 1]) as fh:
            entry["bodyFile"] = fh.read()
with open(os.path.join(root, "calls.log"), "a") as fh:
    fh.write(json.dumps(entry) + "\n")

if args[:2] == ["auth", "status"]:
    for name in open(os.path.join(root, "accounts")).read().split():
        print("  Logged in to github.com account %s (keyring)" % name)
    sys.exit(0)
if args[:2] == ["auth", "token"]:
    print("tok-" + args[-1])
    sys.exit(0)

with open(os.path.join(root, "routes.json")) as fh:
    routes = json.load(fh)
for r in routes:
    if args[:len(r["args"])] != r["args"]:
        continue
    if r.get("token", "") != token and "token" in r:
        continue
    if r.get("rc", 0):
        sys.stderr.write(r.get("err", "gh: failed") + "\n")
        sys.exit(r["rc"])
    out = r.get("out", "")
    sys.stdout.write(out if isinstance(out, str) else json.dumps(out))
    sys.exit(0)
sys.stderr.write("HTTP 404: Not Found (fake gh has no route for %s)\n" % " ".join(args))
sys.exit(1)
