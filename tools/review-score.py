#!/usr/bin/env python3
"""Score the pre merge lessons review on a fixed set of judged cases (claude-config#1355).

    review-score.py run      [--cases DIR] [--results-dir DIR] [--all | --sample N | --only ID,ID]
                             [--repeat N] [--model M] [--window N] [--jobs N] [--deadline S]
                             [--hooks-lib DIR] [--lessons-dir DIR] [--save-baseline]
    review-score.py rescore  RUN.json [--cases DIR] [--results-dir DIR] [--window N]
    review-score.py baseline RUN.json [--cases DIR] [--results-dir DIR]
    review-score.py check    [--cases DIR]

Run it BY HAND when the review's prompt, its runner or its model changes, never per pull request.
It reports two numbers: CATCH RATE, the real defects in the cases that the review found, and WRONG
FINDING RATE, the review's CHECKED findings (those matching a judged item) that match one judged
wrong. A finding matching no judged item is UNCHECKED: it is neither right nor wrong here, so it is
counted on a line of its own and never in the wrong rate's denominator, where it once made the rate
look about ten times better than what had been checked (claude-config#3556). Every rate carries its
count and its 95% Wilson range. With several reviews per case the range is as wide as one review
per case would give, since repeats of a case are not independent samples.

A COMPARISON with the baseline is CASE BY CASE (paired): each real defect is newly caught, newly
missed or the same, and each item judged wrong is raised more often, less often or the same, and an
exact two sided sign test over the items that changed (McNemar's exact test when each case had one
review per run) says whether the change holds at the 95% level the ranges use. Six changes all one
way is the fewest that can. Inside that the runs CANNOT be told apart, and the tool says so rather
than calling luck a regression or an improvement.

WHERE THE CASES LIVE. --cases, else $REVIEW_SCORE_CASES, else ~/.claude-review-cases. The real
judged set quotes private code from other repositories and this repository is public, so it lives
on the Mac, outside this repository and outside ~/.claude: nothing the config sync ever carries can
reach it. ~/.claude/state is not mirrored today either (MIRROR_DIRS in claude-sync names hooks,
agents, commands, audits and mods, and .gitignore drops state/), but a folder outside ~/.claude
cannot start being carried by a later change to the sync. tools/review-score-sample is a small
INVENTED set, public on purpose, that proves the scorer works. A case set that is not there is
reported as UNMEASURED and exits 2, never as a zero score (L411, L90).

A CASE is one directory: input.diff, exactly what the reviewer reads on standard input (the
"===== FILES THIS PUSH CHANGED" block, then the diff), and case.json, whose "items" are the judged
points in that diff, each {id, verdict, file, line, quote, keywords, claim}. The verdict is real (a
defect the review should catch), trivial (true but minor), wrong (a finding judged wrong, to watch
for) or unsure. An optional "package_json" object stands in for the repository's package.json,
which the runner reads to name the framework.

MATCHING a finding (`path:line: text`) to an item: the same file, and EITHER the cited line within
--window lines of the item's (default 20: the 2026-10-19 sample found 44 of 60 findings citing the
wrong line, nearly all within about 20 lines, #1357) OR the finding quoting the item's line text,
AND the finding making the item's claim (claim_matches): one keyword when the item lists only one,
otherwise two of them, or one plus the quoted line or a restatement of the item's claim, so a
finding near a defect that makes some other claim does not count as catching it, even when it
shares a word with it (claude-config#1367). A finding takes the closest
matching item. A real item matched by any finding is caught, once however many findings hit it.
A finding matching no item is UNCHECKED: it is outside the wrong rate, and its text is kept in the
results file for a person to judge and add to the case.

WHAT A RUN COSTS. Each case is one review by the real runner (payload/hooks/lib/ai-review-run.py,
the prompt and scope beside it, the lessons index under payload/), so one review per case per
repeat. The cost is MEASURED, not estimated: the runner reads claude's stream and records in each
review's metadata the cost and token counts claude's result reports, and the scorer reads them from
there. With no selection a run reviews an evenly spread sample of 3 cases; --all reviews every
case. Each review costs about what one lessons review of that diff costs. The --jobs reviews
started together take turns (claude-config#1619, STARTS IN TURN in the runner) in one folder per
run, so they read the cached lessons back rather than each writing them.

RESULTS go to --results-dir (default <cases>/results): run-<UTC time>.json per run, holding every
review's raw findings, and baseline.json. A comparison re-matches BOTH runs against the case set as
it is now, over only the cases both measured, so a judgement added after the baseline was taken
applies to both sides, and a subset run is compared like for like. The terminal shows ids and
counts only, never a finding's text, which can quote private code (L222).

EXIT: 0 compared and no different or better, 1 worse than the baseline, 2 unmeasured (no case set,
no claude, or no case could be reviewed), 3 scored with no baseline covering these cases, 4 compared
and the runs cannot be told apart (something changed, inside the noise).
"""
import argparse
import concurrent.futures
import datetime
import hashlib
import importlib.util
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time

# No cache left in the hooks lib (#2600). Set here, before anything loads from it, rather than in
# one loader: review-answered.py is loaded as this file is imported, and a setting inside the
# runner's loader came too late for it (#2840).
sys.dont_write_bytecode = True

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_HOOKS_LIB = os.path.join(REPO, "payload", "hooks", "lib")
DEFAULT_LESSONS_DIR = os.path.join(REPO, "payload")
DEFAULT_SAMPLE = 3
DEFAULT_WINDOW = 20
VERDICTS = ("real", "trivial", "wrong", "unsure")

EXIT_OK, EXIT_WORSE, EXIT_UNMEASURED, EXIT_NO_BASELINE, EXIT_CANNOT_TELL = 0, 1, 2, 3, 4

# The 95% the ranges and the paired test use: the level claude-config#3556 names. One level for
# both, so a range and a verdict printed side by side never disagree about what counts as noise.
LEVEL = 0.05
Z95 = 1.959963984540054


def _fewest_flips():
    """The fewest changes, all one way, an exact two sided sign test can call significant at LEVEL."""
    n = 1
    while 2 * 0.5 ** n >= LEVEL:
        n += 1
    return n


FEWEST_FLIPS = _fewest_flips()


class Unmeasured(Exception):
    """Nothing could be measured; the message says why."""


# ---------------------------------------------------------------------------------------------
# The case set

def cases_dir(arg):
    if arg:
        return os.path.abspath(os.path.expanduser(arg))
    env = os.environ.get("REVIEW_SCORE_CASES", "")
    if env:
        return os.path.abspath(os.path.expanduser(env))
    return os.path.join(os.path.expanduser("~"), ".claude-review-cases")


def require_cases(path):
    if not os.path.isdir(path):
        raise Unmeasured(
            f"no case set at {path}. Point at one with --cases DIR or REVIEW_SCORE_CASES=DIR; "
            "the public invented sample is tools/review-score-sample.")
    ids = sorted(d for d in os.listdir(path)
                 if os.path.isfile(os.path.join(path, d, "case.json")))
    if not ids:
        raise Unmeasured(f"{path} holds no case (a directory with a case.json).")
    return ids


def diff_files(diff_text):
    """The paths the diff changes, from its +++ lines and its file list."""
    files = set()
    for line in diff_text.splitlines():
        if line.startswith("+++ "):
            p = line[4:].strip()
            if p != "/dev/null":
                files.add(norm(p))
        elif line.startswith("diff --git "):
            parts = line.split()
            if len(parts) >= 4:
                files.add(norm(parts[3]))
    return files


def load_case(root, cid):
    """(case dict, list of problems). A case with problems is not scored."""
    d = os.path.join(root, cid)
    problems = []
    try:
        with open(os.path.join(d, "case.json"), encoding="utf-8") as f:
            case = json.load(f)
    except (OSError, ValueError) as e:
        return None, [f"case.json does not read: {e}"]
    diff_path = os.path.join(d, "input.diff")
    try:
        with open(diff_path, encoding="utf-8", errors="replace") as f:
            diff = f.read()
    except OSError:
        diff = ""
    if not diff.strip():
        problems.append("input.diff is missing or empty")
    changed = diff_files(diff)
    items = case.get("items")
    if not isinstance(items, list):
        return None, problems + ["case.json has no items list"]
    seen = set()
    for i, it in enumerate(items):
        if not isinstance(it, dict):
            problems.append(f"item {i + 1} is not an object")
            continue
        iid = it.get("id") or f"#{i + 1}"
        it["id"] = iid  # scoring keys every item by its id, so one with none keys by its position
        if iid in seen:
            problems.append(f"item id {iid} is used twice")
        seen.add(iid)
        if it.get("verdict") not in VERDICTS:
            problems.append(f"item {iid} has verdict {it.get('verdict')!r}, not one of {', '.join(VERDICTS)}")
        if not isinstance(it.get("line"), int):
            problems.append(f"item {iid} has no whole number line")
        f = it.get("file")
        if not isinstance(f, str) or not f:
            problems.append(f"item {iid} names no file")
        elif changed and not any(same_file(f, c) for c in changed):
            problems.append(f"item {iid} names {f}, which the diff does not change, so no review can find it there")
    case["diff_path"] = diff_path
    case["id"] = cid
    return case, problems


# ---------------------------------------------------------------------------------------------
# Matching

def _runner_module(hooks_lib):
    """The runner itself, so a finding line is recognised by the same pattern the gate counts."""
    path = os.path.join(hooks_lib, "ai-review-run.py")
    spec = importlib.util.spec_from_file_location("ai_review_run", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


FINDING_PARTS = re.compile(r"^(\S+):(\d+): (.*)$")


def norm(p):
    p = p.strip().strip("`")
    for pre in ("a/", "b/", "./"):
        if p.startswith(pre):
            p = p[len(pre):]
    return p


def same_file(a, b):
    a, b = norm(a), norm(b)
    return a == b or a.endswith("/" + b) or b.endswith("/" + a)


def parse_findings(lines):
    out = []
    for line in lines:
        m = FINDING_PARTS.match(line)
        if m:
            out.append({"file": m.group(1), "line": int(m.group(2)), "text": m.group(3)})
    return out


def _answered_module():
    """review-answered.py, whose measure decides two lessons review findings make the same point
    (claude-config#1338): a restated claim is judged by that one measure and threshold, not a copy."""
    path = os.path.join(DEFAULT_HOOKS_LIB, "review-answered.py")
    spec = importlib.util.spec_from_file_location("review_answered", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_ANSWERED = _answered_module()


def claim_matches(text, item, quoted, raw):
    """Whether a finding's text makes the item's claim. An item listing one keyword, or none,
    needs that one. One listing several needs two of them, or one plus either the item's quoted
    line or a restatement of its claim: a single shared word such as "range" credited an off topic
    finding with a catch in #1355's smoke run (claude-config#1367)."""
    kws = [k.lower() for k in item.get("keywords") or [] if k]
    if not kws:
        return True
    hits = sum(1 for k in kws if k in text)
    if hits == 0:
        return False
    if len(kws) == 1 or hits >= 2 or quoted:
        return True
    claim = item.get("claim") or ""
    return bool(claim) and _ANSWERED.similarity(raw, claim) >= _ANSWERED.MIN_SIMILARITY


def match_item(finding, items, window):
    """The item this finding is about, or None."""
    text = finding["text"].lower()
    best, best_dist = None, None
    for it in items:
        if not same_file(finding["file"], it.get("file", "")):
            continue
        quote = (it.get("quote") or "").strip()
        dist = abs(finding["line"] - it.get("line", 0))
        if quote and quote.lower() in text:
            dist = 0
        elif dist > window:
            continue
        if not claim_matches(text, it, bool(quote and quote.lower() in text), finding["text"]):
            continue
        if best is None or dist < best_dist:
            best, best_dist = it, dist
    return best


def score_case(case, reviews, window):
    """Counts for one case over its measured reviews. "items" holds, per judged item, its verdict
    and how often the reviews met it: for a real defect the number of reviews that caught it, for
    any other the number of findings matching it, so two runs can be compared item by item
    (claude-config#3556). "caught_each" is how many defects each review caught, the spread between
    repeats. "missed" is the defects no review caught; "partly" those only some reviews caught."""
    items = case["items"]
    real = [it for it in items if it.get("verdict") == "real"]
    s = {"reviews": 0, "real": 0, "caught": 0, "findings": 0,
         "real_findings": 0, "trivial": 0, "wrong": 0, "unsure": 0, "unjudged": 0,
         "missed": [], "partly": [], "caught_each": [], "n_real": len(real),
         "items": {it["id"]: [it["verdict"], 0] for it in items}, "unjudged_text": []}
    for rv in reviews:
        if rv.get("status") != "ok":
            continue
        s["reviews"] += 1
        s["real"] += len(real)
        hit = set()
        for f in parse_findings(rv.get("findings", [])):
            s["findings"] += 1
            it = match_item(f, items, window)
            if it is None:
                s["unjudged"] += 1
                s["unjudged_text"].append(f"{f['file']}:{f['line']}: {f['text']}")
                continue
            v = it["verdict"]
            if v == "real":
                s["real_findings"] += 1
                hit.add(it["id"])
            else:
                s[v] += 1
                s["items"][it["id"]][1] += 1
        s["caught"] += len(hit)
        s["caught_each"].append(len(hit))
        for iid in hit:
            s["items"][iid][1] += 1
    for it in real:
        n = s["items"][it["id"]][1]
        if s["reviews"] and n == 0:
            s["missed"].append(it["id"])
        elif n < s["reviews"]:
            s["partly"].append(it["id"])
    return s


def totals(per_case):
    keys = ("reviews", "real", "caught", "findings", "real_findings", "trivial", "wrong", "unsure", "unjudged")
    t = {k: 0 for k in keys}
    for s in per_case.values():
        for k in keys:
            t[k] += s[k]
    # A finding is CHECKED when it matched a judged item, whatever that item's verdict: only those
    # can be wrong, so the wrong rate is over them (claude-config#3556).
    t["checked"] = t["findings"] - t["unjudged"]
    # Reviews per measured case, which widens every range back to one review per case.
    t["per_case"] = (t["reviews"] / len(per_case)) if per_case else 1.0
    return t


def pct(n, d):
    return round(100.0 * n / d) if d else None


def wilson(k, n, z=Z95):
    """The Wilson score interval for k of n, as (low, high) fractions; None when n is 0. k may be
    fractional, which a range over repeats needs. Wilson rather than the normal approximation
    because it stays inside 0 to 1 and is honest at the small counts and the 0 and 100% ends this
    tool sees."""
    if n <= 0:
        return None
    p = k / n
    d = 1 + z * z / n
    c = (p + z * z / (2 * n)) / d
    h = z * math.sqrt(max(0.0, p * (1 - p) / n + z * z / (4 * n * n))) / d
    return max(0.0, c - h), min(1.0, c + h)


def rate_text(k, n, per_case=1.0):
    """"46%, 95% range 28% to 65%", or None when n is 0, so no caller can print 0% over nothing.
    With more than one review per case the range is taken over n / per_case, as wide as one review
    per case would give: two reviews of one diff are not two independent samples."""
    if not n:
        return None
    eff = n / per_case if per_case > 1 else n
    lo, hi = wilson(k / n * eff, eff)
    return f"{pct(k, n)}%, 95% range {round(100 * lo)}% to {round(100 * hi)}%"


def sign_test(good, bad):
    """The exact two sided sign test's p for `good` changes one way and `bad` the other, ties left
    out; None when nothing changed. For one yes or no outcome per item per run this is McNemar's
    exact test. Exact rather than the normal approximation, which is wrong at the handful of
    changes a run of a few dozen cases gives."""
    n = good + bad
    if n == 0:
        return None
    k = min(good, bad)
    tail = sum(math.comb(n, i) for i in range(k + 1)) / 2 ** n
    return min(1.0, 2 * tail)


def score_run(run, cases, window):
    """{case id: counts} for the measured cases of a stored run, judged by the cases as they are now."""
    per = {}
    for cid, entry in run["cases"].items():
        case = cases.get(cid)
        if case is None:
            continue
        s = score_case(case, entry.get("reviews", []), window)
        if s["reviews"]:
            per[cid] = s
    return per


# ---------------------------------------------------------------------------------------------
# Reviewing

# What a review cost, read from the runner's own metadata: it records the cost and token counts
# claude's result reports, under the API's names (claude-config#1619, which replaced a claude shim
# here that asked for JSON, since the runner now reads claude's stream itself).
USAGE_FIELDS = ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens", "output_tokens")


def review_once(case, cfg):
    """One review of one case by the real runner. Never raises: a failure is a status, so one case
    whose setup fails (a full disk, its diff gone) cannot end the run before its results are written."""
    started = time.time()
    try:
        return _review_once(case, cfg, started)
    except Exception as e:  # noqa: BLE001  any failure here is this one review's, reported as such
        return {"status": "error", "note": f"the review could not be set up: {type(e).__name__}: {e}"[:200],
                "findings": [], "seconds": round(time.time() - started)}


def _review_once(case, cfg, started):
    tmp = tempfile.mkdtemp(prefix="review-score-")
    try:
        state = os.path.join(tmp, "state"); os.mkdir(state)
        repo = os.path.join(tmp, "repo"); os.mkdir(repo)
        if isinstance(case.get("package_json"), dict):
            with open(os.path.join(repo, "package.json"), "w", encoding="utf-8") as f:
                json.dump(case["package_json"], f)
        diff = os.path.join(tmp, "input.diff")
        shutil.copyfile(case["diff_path"], diff)  # the runner deletes the diff it was given
        # One folder of turns for the whole run (claude-config#1619), so the --jobs reviews started
        # together take turns and read the lessons back, while each keeps its own state.
        env = dict(os.environ, AI_REVIEW_STATE_DIR=state, AI_REVIEW_WARM_DIR=cfg["warm_dir"])
        lib = cfg["hooks_lib"]
        cmd = [sys.executable, os.path.join(lib, "ai-review-run.py"),
               "--state-dir", state, "--key", "score", "--sha", case["id"], "--name", "review",
               "--kind", "pr", "--base", "score", "--repo-label", case["id"], "--branch", "score",
               "--repo-dir", repo, "--model", cfg["model"],
               "--prompt-file", os.path.join(lib, "ai-review-prompt.txt"),
               "--scope-file", os.path.join(lib, "ai-review-pr-scope.txt"),
               "--lessons-dir", cfg["lessons_dir"], "--diff-file", diff,
               "--deadline", str(cfg["deadline"]), "--started", str(int(started))]
        try:
            subprocess.run(cmd, env=env, stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                           stderr=subprocess.DEVNULL, timeout=cfg["deadline"] + 60, check=False)
        except subprocess.TimeoutExpired:
            return {"status": "timeout", "note": "the runner itself did not return", "findings": [],
                    "seconds": round(time.time() - started)}
        out = os.path.join(state, "review.txt")
        try:
            with open(out, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            return {"status": "error", "note": "the runner left no finished review", "findings": [],
                    "seconds": round(time.time() - started)}
        head, _, body = text.partition("\n\n")
        meta = dict(l.split("=", 1) for l in head.splitlines() if "=" in l)
        status = meta.get("status", "error")
        lines = body.splitlines()
        rv = {"status": status, "findings": [l for l in lines if cfg["finding_re"].match(l)],
              "seconds": round(time.time() - started)}
        if status != "ok":
            rv["note"] = (lines[0] if lines else "")[:200]
        if meta.get("start_order"):
            rv["start_order"] = meta["start_order"]
        if "cost_usd" in meta:
            try:
                rv["cost_usd"] = float(meta["cost_usd"])
            except ValueError:
                rv["cost_usd"] = None  # reported, but unreadable: counted as a review with no cost
            rv["usage"] = {k: int(meta[k]) for k in USAGE_FIELDS if meta.get(k, "").isdigit()}
        return rv
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def pick(ids, args):
    if args.only:
        want = [x.strip() for x in args.only.split(",") if x.strip()]
        unknown = [x for x in want if x not in ids]
        if unknown:
            raise Unmeasured(f"no case named {', '.join(unknown)} in the case set.")
        return want, f"{len(want)} named case{'s' if len(want) != 1 else ''}"
    if args.all:
        return ids, f"all {len(ids)} cases"
    n = args.sample if args.sample is not None else DEFAULT_SAMPLE
    if n <= 0:
        raise Unmeasured("--sample must be at least 1.")
    if n >= len(ids):
        return ids, f"all {len(ids)} cases"
    chosen = [ids[(i * len(ids)) // n] for i in range(n)]
    return chosen, f"sample of {n} of {len(ids)} cases"


def default_model(hooks_lib):
    """The model the lessons review uses, read from pr-review.sh so the two cannot drift."""
    with open(os.path.join(hooks_lib, "pr-review.sh"), encoding="utf-8") as f:
        m = re.search(r"AI_REVIEW_MODEL:-([A-Za-z0-9._-]+)", f.read())
    if not m:
        raise Unmeasured("could not read the lessons review's default model from pr-review.sh; pass --model.")
    return os.environ.get("AI_REVIEW_MODEL") or m.group(1)


def file_hash(path):
    try:
        with open(path, "rb") as f:
            return hashlib.sha256(f.read()).hexdigest()[:12]
    except OSError:
        return ""


# ---------------------------------------------------------------------------------------------
# Reporting

def plural(n, word, words=None):
    return f"{n} {word if n == 1 else (words or word + 's')}"


def catch_text(t):
    """The catch rate with its count and range, or what stops there being one."""
    if not t["real"]:
        return "unmeasured (these cases hold no real defect)"
    return (f"{t['caught']} of {t['real']} real defects caught "
            f"({rate_text(t['caught'], t['real'], t['per_case'])})")


def wrong_text(t):
    """The wrong finding rate over CHECKED findings, or what stops there being one, in words."""
    if not t["findings"]:
        return "none, the review raised no finding"
    if not t["checked"]:
        return f"no rate, none of the {plural(t['findings'], 'finding')} matched a judged item"
    return (f"{t['wrong']} of {t['checked']} checked findings judged wrong "
            f"({rate_text(t['wrong'], t['checked'], t['per_case'])})")


def print_scores(t, per, unmeasured, cost):
    many = t["per_case"] > 1
    note = "; with several reviews per case each range counts each case's reviews as one" if many else ""
    print(f"  catch rate: {catch_text(t)}{note if t['real'] else ''}")
    print(f"  wrong findings: {wrong_text(t)}{note if t['checked'] else ''}")
    if t["findings"]:
        # The figure this tool printed before claude-config#3556, kept and labelled for what it is:
        # the wrong rate only if every unchecked finding were right, so a floor (L11).
        floor = (f"; if every unchecked finding were right, the wrong rate over all {t['findings']} "
                 f"would be {pct(t['wrong'], t['findings'])}% ({t['wrong']} of {t['findings']}), "
                 "the figure this tool printed before, a floor") if t["unjudged"] else ""
        print(f"  unchecked: {t['unjudged']} of {plural(t['findings'], 'finding')} matched no judged item, "
              f"so they are neither right nor wrong here{floor}")
    print(f"  also: trivial {t['trivial']}, unsure {t['unsure']}")
    if any(len(s["caught_each"]) > 1 for s in per.values()):
        print_repeats(per)
    missed = [f"{cid} {m}" for cid in sorted(per) for m in per[cid]["missed"]]
    print(f"  missed: {', '.join(missed) if missed else 'none'}")
    print(f"  unmeasured: {', '.join(unmeasured) if unmeasured else 'none'}")
    print(cost)


def print_repeats(per):
    """The spread between the repeats of each case (claude-config#3556): how many defects each
    review caught, and which defects only some reviews caught. Ids and counts only."""
    counts = sorted({len(s["caught_each"]) for s in per.values()})
    each = "/".join(str(c) for c in counts)
    with_real = [cid for cid in sorted(per) if per[cid]["n_real"]]
    differ = [cid for cid in with_real if per[cid]["partly"]]
    print(f"  repeats: {each} reviews per case; the reviews of {len(differ)} of "
          f"{plural(len(with_real), 'case')} caught different defects")
    spread = "; ".join(f"{cid} {', '.join(str(n) for n in per[cid]['caught_each'])} of {per[cid]['n_real']}"
                       for cid in with_real)
    print(f"  caught in each review: {spread if spread else 'no case holds a real defect'}")
    partly = [f"{cid} {iid} ({per[cid]['items'][iid][1]} of {per[cid]['reviews']})"
              for cid in differ for iid in per[cid]["partly"]]
    print(f"  caught by only some reviews: {', '.join(partly) if partly else 'none'}")


def cost_line(run):
    usd, tin, tout, n, gaps = 0.0, 0, 0, 0, 0
    for entry in run["cases"].values():
        for rv in entry.get("reviews", []):
            if rv.get("status") != "ok" and "cost_usd" not in rv:
                continue  # a review that failed before claude answered cost nothing to report
            if rv.get("cost_usd") is None:
                gaps += 1
                continue
            n += 1
            usd += float(rv["cost_usd"])
            u = rv.get("usage") or {}
            tin += sum(int(u.get(k) or 0) for k in ("input_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))
            tout += int(u.get("output_tokens") or 0)
    if not n:
        return "  cost: unmeasured (no review reported its cost)"
    gap = f", {gaps} review{'s' if gaps != 1 else ''} did not report one" if gaps else ""
    return (f"  cost: ${usd:.2f} measured over {n} review{'s' if n != 1 else ''} "
            f"({tin:,} input tokens, {tout:,} output tokens, about ${usd / n:.2f} a review){gap}")


def measured_ids(run):
    """The cases a stored run reviewed successfully at least once, from the file itself."""
    return {cid for cid, e in run.get("cases", {}).items()
            if any(rv.get("status") == "ok" for rv in e.get("reviews", []))}


def side_text(t):
    """One run's two rates for a comparison line, each with its count and range."""
    catch = (f"catch {t['caught']} of {t['real']} ({rate_text(t['caught'], t['real'], t['per_case'])})"
             if t["real"] else "catch unmeasured (no real defect)")
    if not t["findings"]:
        wrong = "wrong: no finding raised"
    elif not t["checked"]:
        wrong = f"wrong: no rate, none of {plural(t['findings'], 'finding')} checked"
    else:
        wrong = (f"wrong {t['wrong']} of {t['checked']} checked findings "
                 f"({rate_text(t['wrong'], t['checked'], t['per_case'])})")
    return f"{catch}; {wrong}, {t['unjudged']} unchecked"


def paired(now, then, common, real):
    """Item by item over the cases both runs measured: (up, down, same) for the real defects when
    `real`, else for every item judged wrong. An item's figure is how often it was met per review
    (caught, for a defect; matched by a finding, for a wrong item), so repeats compare as averages
    and a run of one review per case compares as yes or no. Compared by cross multiplying, never by
    dividing, so equal averages are equal."""
    up, down, same = [], [], 0
    for cid in common:
        for iid, (verdict, b_hits) in then[cid]["items"].items():
            if (verdict == "real") != real or (not real and verdict != "wrong"):
                continue
            n_hits = now[cid]["items"].get(iid, [verdict, 0])[1]
            rb, rn = then[cid]["reviews"], now[cid]["reviews"]
            a, b = n_hits * rb, b_hits * rn
            # With repeats a change can be partial, so it carries both sides' counts.
            name = f"{cid} {iid}" + (f" ({b_hits} in {rb} then, {n_hits} in {rn} now)" if rb > 1 or rn > 1 else "")
            if a > b:
                up.append(name)
            elif a < b:
                down.append(name)
            else:
                same += 1
    return up, down, same


def judge(good, bad, total):
    """'unmeasured', 'same', 'better', 'worse' or 'unclear', with the sign test's p."""
    if not total:
        return "unmeasured", None
    if not good and not bad:
        return "same", None
    p = sign_test(len(good), len(bad))
    if p < LEVEL:
        return ("better" if len(good) > len(bad) else "worse"), p
    return "unclear", p


def compare(run, base, cases, window):
    """(exit code, lines). Both runs judged by the cases as they are now, over the cases both
    measured, and compared CASE BY CASE (claude-config#3556): a verdict either way only when an
    exact sign test over the items that changed clears the 95% level; otherwise CANNOT TELL."""
    now = score_run(run, cases, window)
    then = score_run(base, cases, window)
    common = sorted(set(now) & set(then))
    if not common:
        return EXIT_NO_BASELINE, ["Baseline: none of these cases was measured in the baseline, so nothing is compared."]
    tn = totals({c: now[c] for c in common})
    tb = totals({c: then[c] for c in common})
    # Read from the files, not the scores: only the cases a run names are loaded, so a baseline case
    # this run did not review is not in `then` at all, and would otherwise vanish without a word.
    in_base, in_run = measured_ids(base), measured_ids(run)
    only_base = sorted(in_base - in_run)
    only_run = sorted(in_run - in_base)
    unscored = sorted((in_base & in_run) - set(common))
    lines = [f"Baseline {base.get('name', '')} (model {base.get('model', '?')}), same {plural(len(common), 'case')}, "
             "compared case by case:",
             f"  baseline: {side_text(tb)}",
             f"  this run: {side_text(tn)}",
             f"  measured only in the baseline: {', '.join(only_base) if only_base else 'none'}",
             f"  measured only in this run: {', '.join(only_run) if only_run else 'none'}"]
    if unscored:
        lines.append(f"  measured in both but not compared (gone from the case set, or failing its check):{', '.join(unscored)}")
    c_up, c_down, c_same = paired(now, then, common, real=True)
    w_up, w_down, w_same = paired(now, then, common, real=False)
    c_total, w_total = len(c_up) + len(c_down) + c_same, len(w_up) + len(w_down) + w_same
    lines.append(f"  catch: {len(c_up)} newly caught, {len(c_down)} newly missed, {c_same} the same, "
                 f"of {plural(c_total, 'defect')} in both runs")
    if c_up:
        lines.append(f"  newly caught: {', '.join(c_up)}")
    if c_down:
        lines.append(f"  newly missed: {', '.join(c_down)}")
    lines.append(f"  known wrong findings: {len(w_up)} raised more often, {len(w_down)} less often, "
                 f"{w_same} the same, of {plural(w_total, 'judged wrong item')}")
    if w_up:
        lines.append(f"  raised more often: {', '.join(w_up)}")
    if w_down:
        lines.append(f"  raised less often: {', '.join(w_down)}")
    lines.append("  Test: an exact two sided sign test over the items that changed, ties left out (McNemar's "
                 "exact test when each case has one review per run), at the 95% level the ranges use; "
                 f"{FEWEST_FLIPS} changes all one way is the fewest that can clear it.")
    catch = judge(c_up, c_down, c_total)
    wrong = judge(w_down, w_up, w_total)  # fewer known wrong findings is the good direction
    say = {
        "catch": lambda p: f"catch {len(c_up)} newly caught, {len(c_down)} newly missed (p = {p:.3f})",
        "wrong": lambda p: f"known wrong findings raised {len(w_up)} more often, {len(w_down)} less often (p = {p:.3f})",
    }
    verdicts = {"catch": catch, "wrong": wrong}
    worse = [say[k](p) for k, (v, p) in verdicts.items() if v == "worse"]
    unclear = [say[k](p) for k, (v, p) in verdicts.items() if v == "unclear"]
    better = [say[k](p) for k, (v, p) in verdicts.items() if v == "better"]
    if worse:
        lines.append("REGRESSION: " + "; ".join(worse) + ". Keep the change only if this holds up on a second run.")
        return EXIT_WORSE, lines
    if unclear:
        n_changed = max(len(c_up) + len(c_down), len(w_up) + len(w_down))
        why = (f"{n_changed} {'change is' if n_changed == 1 else 'changes are'} too few for the exact test to reach the 95% level, which needs "
               f"at least {FEWEST_FLIPS} all one way" if n_changed < FEWEST_FLIPS
               else "the changes are too evenly split to tell from runs that came out differently by chance")
        lines.append("CANNOT TELL: " + "; ".join(unclear) + f"; {why}. "
                     + (f"Also better: {'; '.join(better)}. " if better else "")
                     + "Read the ranges above, or score more cases or more repeats.")
        return EXIT_CANNOT_TELL, lines
    if better:
        lines.append("IMPROVEMENT: " + "; ".join(better) + ".")
        return EXIT_OK, lines
    if catch[0] == "unmeasured" and wrong[0] == "unmeasured":
        lines.append("UNMEASURED: these cases hold no real defect and no item judged wrong, so nothing could be compared.")
        return EXIT_UNMEASURED, lines
    lines.append("NO DIFFERENCE: no defect was caught or missed differently, and no finding judged wrong was "
                 "raised more or less often.")
    return EXIT_OK, lines


def failed_reviews(run):
    """One line per case of a run with a failed review, for both a run and a rescore: a case whose
    reviews all failed is left out of the score, and one where only some failed is scored on fewer
    reviews, and neither may happen without being said."""
    out = []
    for cid in sorted(run["cases"]):
        statuses = [rv.get("status", "error") for rv in run["cases"][cid].get("reviews", [])]
        failed = sorted({s for s in statuses if s != "ok"})
        if failed and "ok" not in statuses:
            out.append(f"{cid} ({', '.join(failed)})")
        elif failed:
            n_bad = sum(1 for s in statuses if s != "ok")
            out.append(f"{cid} ({n_bad} of {len(statuses)} reviews failed: {', '.join(failed)})")
    return out


def load_all_cases(root, ids):
    cases, bad = {}, {}
    for cid in ids:
        case, problems = load_case(root, cid)
        if case is None or problems:
            bad[cid] = problems
        else:
            cases[cid] = case
    return cases, bad


def report(run, cases, window, results_dir, unmeasured):
    per = score_run(run, cases, window)
    if not per:
        print("UNMEASURED: no case was reviewed successfully, so there is no score."
              + (f" Unmeasured: {', '.join(unmeasured)}." if unmeasured else ""))
        return EXIT_UNMEASURED
    t = totals(per)
    print(f"Lessons review score: {run.get('selection', '')}, model {run.get('model', '?')}, "
          f"{run.get('repeat', 1)} review{'s' if run.get('repeat', 1) != 1 else ''} each")
    print_scores(t, per, unmeasured, cost_line(run))
    base_path = os.path.join(results_dir, "baseline.json")
    if not os.path.isfile(base_path):
        print(f"Baseline: no baseline yet in {results_dir}. Save this run as one with: "
              f"review-score.py baseline {run.get('path', 'RUN.json')} --results-dir {results_dir}")
        return EXIT_NO_BASELINE
    with open(base_path, encoding="utf-8") as f:
        base = json.load(f)
    code, lines = compare(run, base, cases, window)
    for line in lines:
        print(line)
    return code


# ---------------------------------------------------------------------------------------------
# Commands

def cmd_check(args):
    root = cases_dir(args.cases)
    ids = require_cases(root)
    counts = {v: 0 for v in VERDICTS}
    n_items, bad = 0, 0
    for cid in ids:
        case, problems = load_case(root, cid)
        for p in problems:
            print(f"{cid}: {p}")
        if problems:
            bad += 1
        for it in (case or {}).get("items", []):
            if isinstance(it, dict) and it.get("verdict") in counts:
                counts[it["verdict"]] += 1
            n_items += 1
    print(f"{len(ids)} case{'s' if len(ids) != 1 else ''}, {n_items} items: "
          + ", ".join(f"{counts[v]} {v}" for v in VERDICTS))
    if bad:
        print(f"{bad} case{'s' if bad != 1 else ''} with problems: a run would leave them unmeasured.")
        return 1
    return 0


def cmd_run(args):
    root = cases_dir(args.cases)
    ids = require_cases(root)
    chosen, selection = pick(ids, args)
    if args.repeat < 1:
        raise Unmeasured("--repeat must be at least 1.")
    if not shutil.which("claude"):
        raise Unmeasured("claude is not on PATH, so no review can run.")
    hooks_lib = os.path.abspath(args.hooks_lib)
    cfg = {"hooks_lib": hooks_lib, "lessons_dir": os.path.abspath(args.lessons_dir),
           "model": args.model or default_model(hooks_lib), "deadline": args.deadline,
           "finding_re": _runner_module(hooks_lib).FINDING}
    cases, bad = load_all_cases(root, chosen)
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    os.makedirs(results_dir, exist_ok=True)
    stamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    path = os.path.join(results_dir, f"run-{stamp}.json")
    n = 1
    while os.path.exists(path):
        n += 1
        path = os.path.join(results_dir, f"run-{stamp}-{n}.json")
    run = {"version": 1, "name": os.path.basename(path), "path": path, "started": int(time.time()),
           "model": cfg["model"], "repeat": args.repeat, "window": args.window, "selection": selection,
           "cases_dir": root,
           "hashes": {"prompt": file_hash(os.path.join(hooks_lib, "ai-review-prompt.txt")),
                      "scope": file_hash(os.path.join(hooks_lib, "ai-review-pr-scope.txt")),
                      "runner": file_hash(os.path.join(hooks_lib, "ai-review-run.py"))},
           "cases": {}}
    unmeasured = [f"{cid} ({'; '.join(p)})" for cid, p in sorted(bad.items())]
    jobs = [(cid, r) for cid in chosen if cid in cases for r in range(args.repeat)]
    print(f"Reviewing {len(jobs)} time{'s' if len(jobs) != 1 else ''} ({selection}, {args.repeat} each) "
          f"with {cfg['model']}, {args.jobs} at once; each review takes about as long as a lessons review.",
          flush=True)
    cfg["warm_dir"] = tempfile.mkdtemp(prefix="review-score-turns-")
    try:
        _run_jobs(run, jobs, cases, cfg, args.jobs)
    finally:
        shutil.rmtree(cfg["warm_dir"], ignore_errors=True)
    unmeasured += failed_reviews(run)
    run["finished"] = int(time.time())
    per = score_run(run, cases, args.window)
    run["scored"] = per
    with open(path, "w", encoding="utf-8") as f:
        json.dump(run, f, indent=2)
    print(f"Results: {path}")
    code = report(run, cases, args.window, results_dir, unmeasured)
    if args.save_baseline:
        save_baseline_if_safe(run, path, code, results_dir)
    return code


def _run_jobs(run, jobs, cases, cfg, width):
    """Every review, `width` at once, each one's result into the run as it lands."""
    done = 0
    with concurrent.futures.ThreadPoolExecutor(max_workers=max(1, width)) as pool:
        futs = {pool.submit(review_once, cases[cid], cfg): cid for cid, _ in jobs}
        for fut in concurrent.futures.as_completed(futs):
            cid = futs[fut]
            rv = fut.result()
            run["cases"].setdefault(cid, {"reviews": []})["reviews"].append(rv)
            done += 1
            print(f"  [{done}/{len(jobs)}] {cid}: {rv['status']}, {len(rv['findings'])} finding"
                  f"{'s' if len(rv['findings']) != 1 else ''}, {rv['seconds']}s"
                  + (f" ({rv['note']})" if rv.get("note") else ""), flush=True)


def save_baseline_if_safe(run, path, code, results_dir):
    """Replace the baseline only with a run that is no different or better AND measured every case
    the baseline did, or when there is none yet. A regressed run saved would make the next
    comparison measure against the regression, a run that cannot be told apart from it would let
    the yardstick drift down one change inside the noise at a time (claude-config#3556), and a
    subset run saved would drop every other case from all later comparisons (L5). Accepting any of
    them on purpose is the baseline command, named in the refusal."""
    base_path = os.path.join(results_dir, "baseline.json")
    accept = f"To accept it anyway: review-score.py baseline {path} --results-dir {results_dir}"
    if code == EXIT_UNMEASURED:
        print("Nothing was measured, so it was not saved as the baseline.")
        return
    if not os.path.isfile(base_path):
        shutil.copyfile(path, base_path)
        print(f"Saved as the baseline in {results_dir}.")
        return
    if code == EXIT_WORSE:
        print(f"This run is worse than the baseline, so it was not saved as the baseline. {accept}")
        return
    if code == EXIT_CANNOT_TELL:
        print(f"This run cannot be told apart from the baseline, so it was not saved as the baseline. {accept}")
        return
    with open(base_path, encoding="utf-8") as f:
        base = json.load(f)
    left_out = sorted(measured_ids(base) - measured_ids(run))
    if left_out:
        print(f"This run covers only some of the baseline's cases ({len(left_out)} of the baseline's "
              f"{len(measured_ids(base))} not measured here), so it was not saved as the baseline. {accept}")
        return
    shutil.copyfile(path, base_path)
    print(f"Saved as the baseline in {results_dir}.")


def read_run(path):
    try:
        with open(path, encoding="utf-8") as f:
            run = json.load(f)
    except (OSError, ValueError) as e:
        raise Unmeasured(f"cannot read the run {path}: {e}")
    if not isinstance(run.get("cases"), dict):
        raise Unmeasured(f"{path} is not a run written by review-score.py.")
    return run


def cmd_rescore(args):
    run = read_run(args.run)
    root = cases_dir(args.cases or run.get("cases_dir"))
    ids = require_cases(root)
    cases, bad = load_all_cases(root, [c for c in run["cases"] if c in ids])
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    unmeasured = sorted([f"{cid} ({'; '.join(p)})" for cid, p in bad.items()]
                        + [f"{cid} (no longer in the case set)" for cid in run["cases"] if cid not in ids]
                        + failed_reviews(run))
    print(f"Rescoring {os.path.basename(args.run)} against the case set as it is now (no review is run).")
    return report(run, cases, args.window, results_dir, unmeasured)


def cmd_baseline(args):
    run = read_run(args.run)
    root = cases_dir(args.cases or run.get("cases_dir"))
    results_dir = os.path.abspath(args.results_dir or os.path.join(root, "results"))
    os.makedirs(results_dir, exist_ok=True)
    shutil.copyfile(args.run, os.path.join(results_dir, "baseline.json"))
    print(f"Saved {os.path.basename(args.run)} (model {run.get('model', '?')}, {run.get('selection', '')}) "
          f"as the baseline in {results_dir}.")
    return 0


def main(argv):
    ap = argparse.ArgumentParser(description="Score the pre merge lessons review on a judged case set.")
    sub = ap.add_subparsers(dest="cmd", required=True)

    def common(p):
        p.add_argument("--cases", default=None)
        p.add_argument("--results-dir", default=None)

    r = sub.add_parser("run"); common(r)
    sel = r.add_mutually_exclusive_group()
    sel.add_argument("--all", action="store_true")
    sel.add_argument("--sample", type=int, default=None)
    sel.add_argument("--only", default="")
    r.add_argument("--repeat", type=int, default=1)
    r.add_argument("--model", default="")
    r.add_argument("--window", type=int, default=DEFAULT_WINDOW)
    r.add_argument("--jobs", type=int, default=3)
    r.add_argument("--deadline", type=int, default=600)
    r.add_argument("--hooks-lib", default=DEFAULT_HOOKS_LIB)
    r.add_argument("--lessons-dir", default=DEFAULT_LESSONS_DIR)
    r.add_argument("--save-baseline", action="store_true")

    rs = sub.add_parser("rescore"); rs.add_argument("run"); common(rs)
    rs.add_argument("--window", type=int, default=DEFAULT_WINDOW)

    b = sub.add_parser("baseline"); b.add_argument("run"); common(b)

    c = sub.add_parser("check"); c.add_argument("--cases", default=None)

    args = ap.parse_args(argv)
    try:
        return {"run": cmd_run, "rescore": cmd_rescore, "baseline": cmd_baseline, "check": cmd_check}[args.cmd](args)
    except Unmeasured as e:
        print(f"UNMEASURED: {e}")
        return EXIT_UNMEASURED


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
