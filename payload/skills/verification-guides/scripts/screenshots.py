#!/usr/bin/env python3
"""Before and after screenshots on a UI pull request (claude-config#2516).

L606 asks for every UI pull request to carry pictures at the production count, at a wide and a
laptop window, in both themes. Left to each session that is a hope (L27), so the verification
runner takes them and this file puts them in the pull request body, where the merge check reads
them back.

A pull request is UI when it touches an area of `.claude/verification/areas.json` that declares
`screens` (verification.py validates them). Each screen is shot on the BASE build and the HEAD
build, at WIDTHS and in THEMES: eight pictures a screen. A screen is a route on a served web app
or, for a native app, an offscreen test and the frame it draws (claude-config#2696); both give the
same pictures under the same names, so nothing after shoot tells them apart.

Where the pictures live:
  images  each picture is a blob on the orphan branch `pr-screenshots`, written through GitHub's git
          data API (no push, so the pull request's diff and the push gates never see it), under
          pr-<number>/<head sha>/, and linked by the commit that added it, so a later write to the
          branch cannot change what a body shows. Nothing is ever pruned (Dan, 2026-11-10).
  link    no picture is uploaded; the block links a private Artifact page instead.
Images only in a public repository whose screens all use a seed declared synthetic (made up data),
and in a private repository only once PRIVATE_REPO_IMAGES says inline images were measured to
render there. Everything else is a link.

Formats, read only here (the merge check imports this file, L370):
  verification-screenshots/1   the ```verification-screenshots manifest inside the `## Screenshots`
                               block of the PR body, between BEGIN and END
  rendered-screenshots.jsonl   beside the HEAD receipt, the fingerprint of every block render wrote,
                               so a block edited by hand is refused, as rendered.jsonl does for run
                               records (#1572)

CLI (every refusal prints `verification: <kind>: <message>` on stderr):
  screenshots.py shots <areas.json> --areas <a,b>          the pictures a pull request needs
  screenshots.py shoot <receipt id> --side base|head --areas-file <base areas.json>
  screenshots.py publish --areas-file <f> --repo <owner/name> --pr <n> --base-receipt <id>
                         --head-receipt <id> [--link <private Artifact URL>]      manifest on stdout
  screenshots.py render --manifest <f> --body <f>          the new PR body on stdout
"""

import argparse
import base64
import hashlib
import json
import os
import re
import subprocess
import sys

sys.dont_write_bytecode = True  # a module beside this one is carried by the sync: leave no cache (#2919)
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import verification as v  # noqa: E402

SCHEMA = "verification-screenshots/1"
DIGEST_SCHEMA = "verification-screenshots-rendered/1"
WIDTHS = (1440, 1280)
THEMES = ("light", "dark")
SIDES = ("base", "head")
BRANCH = "pr-screenshots"
HEADING = "## Screenshots"
BEGIN = "<!-- verification-screenshots:begin -->"
END = "<!-- verification-screenshots:end -->"
FENCE = "```verification-screenshots"
UPLOAD_TRIES = 3
FOLDER_RE = re.compile(r"^pr-[1-9][0-9]{0,9}/[0-9a-f]{40}$")
ARTIFACT_RE = re.compile(r"^https://claude\.ai/(code/)?artifact/[A-Za-z0-9-]{8,}$")

# Whether a picture committed to a branch shows inline in a PRIVATE repository's PR body, measured in
# claude-config#2699: on 2026-11-10 creating the private test repository was refused by Claude Code's
# auto mode safety check, so private repositories get the private link, right either way. Flip it
# only with the measurement in the same pull request.
PRIVATE_REPO_IMAGES = False


# ---------------------------------------------------------------------------------------------
# which pictures


def ui_areas(areas, touched):
    """The touched areas that declare screens, in areas.json order: the ones that make a PR UI."""
    return [a for a in areas["areas"] if a["name"] in touched and a.get("screens")]


def shot_name(area, screen, side, width, theme):
    return "%s__%s__%s__%d__%s.png" % (area, screen, side, width, theme)


def label(shot):
    return "%s %s %s %d %s" % (shot["area"], shot["screen"], shot["side"], shot["width"], shot["theme"])


def required_shots(areas, touched):
    out = []
    for a in ui_areas(areas, touched):
        for sc in a["screens"]:
            for side in SIDES:
                for w in WIDTHS:
                    for t in THEMES:
                        out.append({"area": a["name"], "screen": sc["name"], "side": side, "width": w, "theme": t,
                                    "name": shot_name(a["name"], sc["name"], side, w, t)})
    return out


def _screen(areas, area, screen):
    for a in areas["areas"]:
        if a["name"] == area:
            for sc in a["screens"]:
                if sc["name"] == screen:
                    return sc
    return None


def _named(shots):
    return "; ".join(label(s) for s in shots)


# ---------------------------------------------------------------------------------------------
# shoot


def shoot(receipt_id, side, areas, run=subprocess.run, home=None):
    """Shoot every screen of the run's areas through the project's drive helper. Returns the failures.

    The helper is called as `screenshot <path> <width> <theme> <file> <rows selector or -> <min rows>`
    through run_session.py drive, so the call is logged and sandboxed like every other drive call,
    and saves <file> into VERIFICATION_RECEIPT_DIR. shoot_web.mjs is a helper that does exactly this.
    A native screen (claude-config#2696) is called as
    `screenshot-native <test> <frame> <width> <theme> <file> <min rows>`, which shoot_native.py takes.
    """
    if side not in SIDES:
        v.fail("usage", "--side is base or head, not %r" % side)
    rec = v.load_receipt(receipt_id, home)
    script = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run_session.py")
    failed = []
    for shot in [s for s in required_shots(areas, rec.get("areas", [])) if s["side"] == side]:
        sc = _screen(areas, shot["area"], shot["screen"])
        if "test" in sc:
            args = ["screenshot-native", sc["test"], sc["frame"], str(shot["width"]), shot["theme"], shot["name"],
                    str(sc.get("min_rows") or 0)]
        else:
            args = ["screenshot", sc["path"], str(shot["width"]), shot["theme"], shot["name"],
                    sc.get("rows") or "-", str(sc.get("min_rows") or 0)]
        r = run([sys.executable, script, "drive", receipt_id, "--area", shot["area"], "--"] + args)
        if r.returncode != 0 or not os.path.isfile(os.path.join(v.receipt_dir(receipt_id, home), shot["name"])):
            failed.append(shot)
    return failed


# ---------------------------------------------------------------------------------------------
# publish


def _gh(args, data=None):
    r = subprocess.run(["gh"] + list(args), input=data, capture_output=True, text=True, errors="replace")
    return r.returncode, r.stdout, r.stderr


def _api(gh, path, method="GET", body=None):
    args = ["api", path]
    if method != "GET":
        args = ["api", "--method", method, path, "--input", "-"]
    return gh(args, json.dumps(body) if body is not None else None)


def _json(out):
    try:
        return json.loads(out)
    except ValueError:
        return None


def _upload(gh, slug, files, message):
    """Commit `files` [(path, bytes)] onto BRANCH, keeping every file already there. Returns the commit.

    Built on the branch's current tree, never replacing it, so nothing is pruned. Moved without
    force, so two publishes at once cannot lose either one's pictures: the one that loses the race
    builds again on the new tip. Blobs are made once and reused across tries.
    """
    def failed(what, err):
        v.fail("screenshots-upload-failed", "%s on %s failed: %s. Nothing on the branch moved"
               % (what, slug, (err or "no reason given").strip()[:300]))

    blobs = []
    for path, data in files:
        rc, out, err = _api(gh, "repos/%s/git/blobs" % slug, "POST",
                            {"content": base64.b64encode(data).decode("ascii", errors="strict"), "encoding": "base64"})
        sha = (_json(out) or {}).get("sha") if rc == 0 else None
        if not sha:
            failed("uploading %s" % path, err)
        blobs.append({"path": path, "mode": "100644", "type": "blob", "sha": sha})
    for _ in range(UPLOAD_TRIES):
        rc, out, err = _api(gh, "repos/%s/git/ref/heads/%s" % (slug, BRANCH))
        if rc == 0:
            tip = ((_json(out) or {}).get("object") or {}).get("sha")
            if not tip:
                failed("reading the %s branch" % BRANCH, "GitHub's answer named no commit")
            rc, out, err = _api(gh, "repos/%s/git/commits/%s" % (slug, tip))
            base_tree = ((_json(out) or {}).get("tree") or {}).get("sha") if rc == 0 else None
            if not base_tree:
                failed("reading the tree of %s" % tip[:7], err)
        elif "HTTP 404" in (err or ""):
            tip, base_tree = None, None
        else:
            failed("reading the %s branch" % BRANCH, err)
        tree_body = {"tree": blobs}
        if base_tree:
            tree_body["base_tree"] = base_tree
        rc, out, err = _api(gh, "repos/%s/git/trees" % slug, "POST", tree_body)
        tree = (_json(out) or {}).get("sha") if rc == 0 else None
        if not tree:
            failed("writing the tree", err)
        rc, out, err = _api(gh, "repos/%s/git/commits" % slug, "POST",
                            {"message": message, "tree": tree, "parents": [tip] if tip else []})
        commit = (_json(out) or {}).get("sha") if rc == 0 else None
        if not commit:
            failed("writing the commit", err)
        if tip:
            rc, out, err = _api(gh, "repos/%s/git/refs/heads/%s" % (slug, BRANCH), "PATCH", {"sha": commit, "force": False})
        else:
            rc, out, err = _api(gh, "repos/%s/git/refs" % slug, "POST", {"ref": "refs/heads/" + BRANCH, "sha": commit})
        if rc == 0:
            return commit
        if "HTTP 422" not in (err or ""):
            failed("moving the %s branch" % BRANCH, err)
    v.fail("screenshots-upload-failed", "the %s branch on %s moved under every one of %d tries to add to it, so"
           " nothing was added. Publish again" % (BRANCH, slug, UPLOAD_TRIES))


def publish(areas, slug, pr, base_rid, head_rid, gh=_gh, home=None, link=None):
    """Put a run's pictures where the PR body can show them, and return the manifest render reads.

    `areas` is the BASE areas.json, the one that judges the merge. Every refusal happens before
    anything is uploaded, the public repository rule above all (Dan, 2026-11-10: pictures in a
    public repository only of made up seed data).
    """
    if base_rid == head_rid:
        v.fail("screenshots-same-receipt", "the base and head receipts are both %s: the before pictures come from"
               " a run of the base commit and the after pictures from a run of the head" % head_rid)
    if not isinstance(pr, int) or pr < 1:
        v.fail("usage", "--pr must be the pull request number")
    if link is not None and not ARTIFACT_RE.match(link):
        v.fail("screenshots-bad-link", "%r is not a claude.ai Artifact link: the private link is the page the"
               " pictures were published to with the Artifact tool, which only its owner can open" % link)
    base, head = v.load_receipt(base_rid, home), v.load_receipt(head_rid, home)
    required = required_shots(areas, head.get("areas", []))
    if not required:
        v.fail("screenshots-no-screens", "run %s covers %s, and none of them declares screens in areas.json, so"
               " there is nothing to picture" % (head_rid, ", ".join(head.get("areas", [])) or "no area"))
    dirs = {"base": v.receipt_dir(base_rid, home), "head": v.receipt_dir(head_rid, home)}
    missing = [s for s in required if not os.path.isfile(os.path.join(dirs[s["side"]], s["name"]))]
    if missing:
        v.fail("screenshots-missing-shot", "these pictures are not in their receipts, so nothing was published: %s."
               " Shoot them with screenshots.py shoot" % _named(missing))

    rc, out, err = _api(gh, "repos/%s" % slug)
    info = _json(out) if rc == 0 else None
    if not isinstance(info, dict) or not isinstance(info.get("private"), bool):
        v.fail("screenshots-github-unreadable", "whether %s is public could not be read from GitHub (%s), so no"
               " picture was published" % (slug, (err or "no answer").strip()[:200]))
    private = info["private"]
    synthetic = all(areas["seeds"][_screen(areas, s["area"], s["screen"])["seed"]]["synthetic"] for s in required)
    images_ok = PRIVATE_REPO_IMAGES if private else synthetic
    if link is None and not images_ok:
        why = ("%s is private, and whether a picture on a branch shows in a private repository's PR body has not"
               " been measured" % slug) if private else (
            "%s is public, and a screen is shot with a seed not declared synthetic in areas.json" % slug)
        v.fail("screenshots-need-private-link", "%s, so no picture may go there. Publish the pictures to a private"
               " Artifact page and pass its link with --link" % why)

    shots, data = [], {}
    for s in required:
        with open(os.path.join(dirs[s["side"]], s["name"]), "rb") as f:
            data[s["name"]] = f.read()
        shots.append(dict(s, sha256=hashlib.sha256(data[s["name"]]).hexdigest(), url=None))
    folder = "pr-%d/%s" % (pr, head["head_sha"])
    commit = None
    if link is None:
        commit = _upload(gh, slug, [("%s/%s" % (folder, s["name"]), data[s["name"]]) for s in shots],
                         "Screenshots for #%d at %s" % (pr, head["head_sha"][:7]))
        for s in shots:
            s["url"] = image_url(slug, commit, folder, s["name"])
    pairs = {}
    for s in shots:
        pairs.setdefault((s["area"], s["screen"], s["width"], s["theme"]), {})[s["side"]] = s["sha256"]
    same = all(p.get("base") == p.get("head") for p in pairs.values())
    screens = []
    for a in ui_areas(areas, head.get("areas", [])):
        for sc in a["screens"]:
            where = {"test": sc["test"], "frame": sc["frame"]} if "test" in sc else {"path": sc["path"]}
            screens.append(dict(where, area=a["name"], screen=sc["name"], seed=sc["seed"],
                                synthetic=areas["seeds"][sc["seed"]]["synthetic"]))
    return {"schema": SCHEMA, "repo": slug, "pr": pr, "head_sha": head["head_sha"], "base_sha": base["head_sha"],
            "head_receipt": head_rid, "base_receipt": base_rid, "mode": "link" if link else "images",
            "link": link, "commit": commit, "folder": folder, "screens": screens, "shots": shots,
            "no_visible_change": same}


def image_url(slug, commit, folder, name):
    return "https://github.com/%s/blob/%s/%s/%s?raw=true" % (slug, commit, folder, name)


# ---------------------------------------------------------------------------------------------
# the block


def render_block(m):
    """The `## Screenshots` block for a manifest. The same manifest always gives the same text."""
    lines = [HEADING, "", BEGIN,
             "Before is the base at %s and after is the head at %s, each at %s wide in %s." % (
                 m["base_sha"][:7], m["head_sha"][:7], " and ".join(str(w) for w in WIDTHS), " and ".join(THEMES))]
    if m["no_visible_change"]:
        lines += ["", "No visible change measured: every before and after pair is byte for byte identical."]
    if m["mode"] == "link":
        lines += ["", "The pictures are on a private page, since they may not be shown in this repository: %s" % m["link"]]
    by = {(s["area"], s["screen"], s["side"], s["width"], s["theme"]): s for s in m["shots"]}
    for sc in m["screens"]:
        where = ("test `%s`, frame `%s`" % (sc["test"], sc["frame"]) if "test" in sc else "`%s`" % sc["path"])
        lines += ["", "### %s: %s (%s, seed %s)" % (sc["area"], sc["screen"], where, sc["seed"])]
        if m["mode"] != "images":
            continue
        lines += ["", "| | Before | After |", "|---|---|---|"]
        for w in WIDTHS:
            for t in THEMES:
                cells = []
                for side, word in (("base", "before"), ("head", "after")):
                    s = by.get((sc["area"], sc["screen"], side, w, t))
                    cells.append("![%s %s %s %d %s](%s)" % (sc["area"], sc["screen"], word, w, t, s["url"]) if s else "missing")
                lines.append("| %d %s | %s | %s |" % (w, t, cells[0], cells[1]))
    lines += ["", FENCE, json.dumps(m, indent=1, sort_keys=True), "```", END]
    return "\n".join(lines)


def _region(body):
    """(start, end) of the block in body, the heading before BEGIN included, or None."""
    b = body.find(BEGIN)
    if b < 0:
        return None
    e = body.find(END, b)
    if e < 0:
        return None
    start = b
    h = body.rfind(HEADING, 0, b)
    if h >= 0 and body[h + len(HEADING):b].strip() == "":
        start = h
    return start, e + len(END)


def apply_block(body, block):
    """The body with its block replaced in place, or the block added at the end: one block, always."""
    r = _region(body)
    if r is None:
        return body.rstrip("\n") + "\n\n" + block + "\n"
    return body[:r[0]] + block + body[r[1]:]


def block_digest(text):
    """The fingerprint of a block's text, with the line ends and trailing spaces GitHub may change."""
    norm = "\n".join(line.rstrip() for line in text.replace("\r\n", "\n").split("\n"))
    return "sha256:" + hashlib.sha256(norm.encode("utf-8", "replace")).hexdigest()


def parse_block(body):
    """{"found", "text", "manifest", "errors"} for the block in a PR body."""
    body = body or ""
    out = {"found": False, "text": None, "manifest": None, "errors": []}
    if body.count(BEGIN) == 0:
        return out
    out["found"] = True
    if body.count(BEGIN) > 1 or body.count(END) != 1:
        out["errors"].append("the body holds %d block starts and %d block ends, and must hold one of each"
                             % (body.count(BEGIN), body.count(END)))
        return out
    r = _region(body)
    if r is None:
        out["errors"].append("the block's end comes before its start")
        return out
    out["text"] = body[r[0]:r[1]]
    inner = out["text"].replace("\r\n", "\n")
    f = inner.find(FENCE + "\n")
    close = inner.find("\n```", f + len(FENCE) + 1) if f >= 0 else -1
    if f < 0 or close < 0:
        out["errors"].append("the block holds no %s manifest" % FENCE)
        return out
    try:
        m = json.loads(inner[f + len(FENCE) + 1:close])
    except ValueError as e:
        out["errors"].append("its manifest is not JSON: %s" % e)
        return out
    if not isinstance(m, dict) or m.get("schema") != SCHEMA:
        out["errors"].append("its manifest is not a %s manifest" % SCHEMA)
        return out
    keys = ("head_sha", "head_receipt", "mode", "shots", "screens", "folder")
    if any(k not in m for k in keys) or not isinstance(m["shots"], list) or m["mode"] not in ("images", "link"):
        out["errors"].append("its manifest lacks one of %s" % ", ".join(keys))
        return out
    out["manifest"] = m
    return out


def _digest_path(receipt_id, home):
    return os.path.join(v.receipt_dir(receipt_id, home), "rendered-screenshots.jsonl")


def remember_block(receipt_id, text, home=None):
    path = _digest_path(receipt_id, home)
    line = json.dumps({"schema": DIGEST_SCHEMA, "digest": block_digest(text), "at": v.utc_now()}) + "\n"
    try:
        with open(path, "a", errors="replace") as f:
            f.write(line)
    except OSError as e:
        v.fail("render-not-remembered", "the fingerprint of the screenshots block could not be written to %s (%s),"
               " so the merge check would refuse it: render it again once that is fixed" % (path, e))


def load_block_digests(receipt_id, home=None):
    """Every block fingerprint render wrote beside this receipt. No file is an answer: none."""
    path = _digest_path(receipt_id, home)
    try:
        with open(path, errors="strict") as f:
            lines = f.read().splitlines()
    except FileNotFoundError:
        return set()
    out = set()
    for n, line in enumerate(lines, 1):
        if not line.strip():
            continue
        obj = _json(line)
        if not isinstance(obj, dict) or obj.get("schema") != DIGEST_SCHEMA or not isinstance(obj.get("digest"), str):
            v.fail("rendered-bad-line", "%s line %d is not a %s line" % (path, n, DIGEST_SCHEMA))
        out.add(obj["digest"])
    return out


def render_into_body(m, body, home=None):
    """The PR body with the manifest's block in it, its fingerprint kept beside the head receipt."""
    v.load_receipt(m["head_receipt"], home)
    block = render_block(m)
    remember_block(m["head_receipt"], block, home)
    return apply_block(body, block)


# ---------------------------------------------------------------------------------------------
# the merge check's question


def judge(areas, touched, body, head, private, listings, changed_since, home=None):
    """Does this pull request's body carry the pictures its UI areas need?

    areas: the BASE areas.json. private: True, False, None when GitHub could not say, or "unasked",
    which asks for it (need.repo) only when an images block makes it matter. listings:
    {commit: [file names in the block's folder] or None when GitHub could not list it}. changed_since:
    the pull request's own files changed since the block's head, or None when not yet read. A listing
    GitHub failed is None or the reason it gave.
    Returns {"required", "problems" [{kind, area, message}], "need" {"compares", "listings", "repo"},
    "unmeasured", "note", "mode"}.
    """
    out = {"required": [], "problems": [], "need": {"compares": [], "listings": [], "repo": False}, "unmeasured": False,
           "note": "", "mode": areas["screenshots"]["mode"]}

    def add(kind, area, message):
        out["problems"].append({"kind": kind, "area": area, "message": message})

    if not any(a.get("screens") for a in areas["areas"]):
        out["unmeasured"] = True
        out["note"] = ("Screenshots: unmeasured. No area in %s declares screens, so no pull request here is"
                       " recognised as changing UI." % v.AREAS_PATH)
        return out
    ui = ui_areas(areas, touched)
    if not ui:
        out["note"] = "Screenshots: none needed, since this pull request touches no area that declares screens."
        return out
    names = ", ".join(a["name"] for a in ui)
    required = out["required"] = required_shots(areas, touched)
    found = parse_block(body)
    if not found["found"]:
        add("screenshots-missing", names, "the body has no %s block, and these pictures are missing: %s. Take them"
            " with the verification-guides skill's RUN procedure (screenshots.py shoot, publish and render)"
            % (HEADING, _named(required)))
        return out
    if found["errors"]:
        add("screenshots-malformed", names, "the %s block is malformed: %s. Render it again with screenshots.py"
            " render" % (HEADING, "; ".join(found["errors"])))
        return out
    m = found["manifest"]
    try:
        digests = load_block_digests(m["head_receipt"], home)
    except v.VerificationError as e:
        add("screenshots-receipt-unreadable", names, "the fingerprints beside receipt %s could not be read (%s: %s)"
            % (m["head_receipt"], *e.problems[0]))
        return out
    if block_digest(found["text"]) not in digests:
        add("screenshots-edited", names, "the %s block is not one screenshots.py render wrote from receipt %s on this"
            " machine: it was changed by hand, or rendered elsewhere. Render it again and put it in the body"
            " unchanged" % (HEADING, m["head_receipt"]))
        return out
    if m["head_sha"] != head and changed_since is None:
        # Asked for, and the rest judged meanwhile, so one round of reads answers every question.
        out["need"]["compares"].append(m["head_sha"])
    elif m["head_sha"] != head:
        b = v.bucket(areas, changed_since)
        moved = [f["path"] for f in b["files"] if f["bucket"] in ["area:" + a["name"] for a in ui]]
        if moved:
            add("screenshots-stale", names, "the pictures were taken at %s, and %s changed since in an area they show."
                " Take them again at %s" % (m["head_sha"][:7], ", ".join(moved[:8]), head[:7]))
            return out

    have = {(s.get("area"), s.get("screen"), s.get("side"), s.get("width"), s.get("theme")): s
            for s in m["shots"] if isinstance(s, dict)}
    missing = [r for r in required if (r["area"], r["screen"], r["side"], r["width"], r["theme"]) not in have]
    if missing:
        add("screenshots-missing-shot", names, "the %s block lacks %s" % (HEADING, _named(missing)))

    if m["mode"] == "link":
        if not isinstance(m.get("link"), str) or not ARTIFACT_RE.match(m["link"]):
            add("screenshots-bad-link", names, "the block says its pictures are on a private page and links none")
        return out
    if private == "unasked":
        out["need"]["repo"] = True
    elif private is None:
        add("screenshots-github-unreadable", names, "whether this repository is public could not be read from GitHub,"
            " so whether its pictures may be shown here cannot be told")
    elif not private:
        real = [sc for sc in {(r["area"], r["screen"]) for r in required}
                if not areas["seeds"][_screen(areas, *sc)["seed"]]["synthetic"]]
        if real:
            add("screenshots-public-not-synthetic", names, "this repository is public and the block shows pictures of"
                " %s, whose seed is not declared synthetic. Delete them from the %s branch history and use a private"
                " link" % (", ".join("%s %s" % sc for sc in sorted(real)), BRANCH))
    commit = m.get("commit")
    if not isinstance(commit, str) or not v.SHA_RE.match(commit):
        add("screenshots-link-unresolved", names, "the block's manifest names no commit its pictures were added in")
        return out
    # The folder comes from the PR body, which its author controls, so it is read only in the one
    # shape publish writes before it reaches any GitHub path.
    if not isinstance(m["folder"], str) or not FOLDER_RE.match(m["folder"]) or \
            m["folder"] != "pr-%s/%s" % (m.get("pr"), m["head_sha"]):
        add("screenshots-link-unresolved", names, "the block's folder %r is not pr-<number>/<head sha>, the only"
            " place publish puts pictures" % (m["folder"],))
        return out
    if commit not in listings:
        out["need"]["listings"].append({"commit": commit, "folder": m["folder"]})
        return out
    listed = listings[commit]
    if listed is None or isinstance(listed, str):
        add("screenshots-github-unreadable", names, "GitHub could not list %s at %s (%s), so whether its pictures"
            " exist cannot be told" % (m["folder"], commit[:7], (listed or "no reason given").strip()[:300]))
        return out
    slug = m.get("repo")
    bad = [s for s in have.values() if s.get("name") not in listed
           or s.get("url") != image_url(slug, commit, m["folder"], s.get("name"))]
    if bad:
        add("screenshots-link-unresolved", names, "these pictures do not resolve to a file the %s branch holds at %s:"
            " %s" % (BRANCH, commit[:7], "; ".join(label(s) for s in bad if "area" in s)))
    return out


# ---------------------------------------------------------------------------------------------
# CLI


def _print_problems(e):
    for kind, msg in e.problems:
        print("verification: %s: %s" % (kind, msg), file=sys.stderr)


def main(argv):
    ap = argparse.ArgumentParser(prog="screenshots.py")
    sub = ap.add_subparsers(dest="cmd", required=True)
    s = sub.add_parser("shots")
    s.add_argument("areas_file")
    s.add_argument("--areas", required=True)
    s = sub.add_parser("shoot")
    s.add_argument("receipt_id")
    s.add_argument("--side", required=True)
    s.add_argument("--areas-file", required=True)
    s = sub.add_parser("publish")
    for k in ("--areas-file", "--repo", "--base-receipt", "--head-receipt"):
        s.add_argument(k, required=True)
    s.add_argument("--pr", required=True, type=int)
    s.add_argument("--link")
    s = sub.add_parser("render")
    s.add_argument("--manifest", required=True)
    s.add_argument("--body", required=True)
    a = ap.parse_args(argv)
    try:
        if a.cmd == "shots":
            areas = v.load_areas(a.areas_file)
            print(json.dumps(required_shots(areas, [x.strip() for x in a.areas.split(",")]), indent=1))
        elif a.cmd == "shoot":
            failed = shoot(a.receipt_id, a.side, v.load_areas(a.areas_file))
            if failed:
                v.fail("drive-failed", "the drive helper did not save %s" % _named(failed))
            print("shot every %s picture for receipt %s" % (a.side, a.receipt_id))
        elif a.cmd == "publish":
            m = publish(v.load_areas(a.areas_file), a.repo, a.pr, a.base_receipt, a.head_receipt, link=a.link)
            print(json.dumps(m, indent=1))
        else:
            with open(a.manifest, errors="strict") as f:
                m = json.load(f)
            with open(a.body, errors="strict") as f:
                body = f.read()
            sys.stdout.write(render_into_body(m, body))
        return 0
    except v.VerificationError as e:
        _print_problems(e)
        return e.code


if __name__ == "__main__":
    sys.stdout.reconfigure(errors="replace")
    sys.exit(main(sys.argv[1:]))
