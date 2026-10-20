#!/usr/bin/env python3
"""check-decision-map.py <settled design file> [plan.json]

Holds a settled design to its decision map (claude-config#1290, L780). On 2026-10-17 a redesign
settled 65 decisions and the PRD got 16 numbered requirements; the build was one pull request per
requirement, every one shipped, and about 35 decisions with no owner shipped as the old screen while
the milestone read as nearly done. A sentence in the skill saying each decision goes back into the
PRD did not stop that, so this check does (L27).

The map lives inside the settled design file, beside its decision record, as one block:

    <script type="application/json" id="decision-map">
    {"decisions": [
      {"id": "D1", "decision": "The invoice list is one column", "requirement": "6.4"},
      {"id": "D2", "decision": "The heading reads Invoices", "noCode": "Copy only, nothing to build"}
    ]}
    </script>

Every decision carries exactly one of `requirement` (the PRD's number for the requirement that owns
it) or `noCode` (why it has no code consequence). One with neither, or both, is refused by name.

Given the plan a planner hands to create-milestone.sh, it also refuses while any requirement the map
names is named by no issue in the plan, as `Requirement <number>` in the issue's title or body.

Exit codes, each distinct so no caller can read one as another (L11):
  0  every decision is owned (and, with a plan, every requirement has an issue)
  1  refused: the lines starting UNMAPPED, AMBIGUOUS, DUPLICATE, UNSTATED, MISTYPED or NO-ISSUE
     say what is missing
  2  unreadable: no file, no map, more than one map, a map or plan that is not JSON or not the
     shape above, or a map with no decisions, which is never read as a pass (L98)
"""
import json
import os
import re
import sys

# The one reader of a settled design's JSON blocks, shared with the design match score (#1364).
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from design_file import find_blocks  # noqa: E402

MAP_ID = "decision-map"


def unreadable(why):
    print("DECISION-MAP UNREADABLE: %s" % why)
    sys.exit(2)


def text(v):
    return v.strip() if isinstance(v, str) else ""


def named_by(requirement, issues_text):
    # `Requirement 6.4` names 6.4, never 6.41 or 6.4.1; a full stop ending the sentence still counts.
    pattern = r"\bRequirement\s+" + re.escape(requirement) + r"(?![0-9A-Za-z]|\.[0-9A-Za-z])"
    return re.search(pattern, issues_text, re.IGNORECASE) is not None


def main(argv):
    if len(argv) not in (2, 3):
        print(__doc__.strip())
        return 2
    design = argv[1]
    try:
        with open(design, encoding="utf-8", errors="replace") as fh:
            source = fh.read()
    except OSError as err:
        unreadable("the settled design %s could not be read: %s" % (design, err.strerror or err))
    maps = find_blocks(source, [MAP_ID])[MAP_ID]
    if not maps:
        unreadable("%s holds no <script type=\"application/json\" id=\"%s\"> block, so no decision in it "
                   "can be shown to have an owner" % (design, MAP_ID))
    if len(maps) > 1:
        unreadable("%s holds %d decision map blocks; keep one" % (design, len(maps)))
    try:
        data = json.loads(maps[0])
    except ValueError as err:
        unreadable("the decision map in %s is not JSON: %s" % (design, err))
    decisions = data.get("decisions") if isinstance(data, dict) else None
    if not isinstance(decisions, list):
        unreadable("the decision map in %s has no \"decisions\" list" % design)
    if not decisions:
        unreadable("the decision map in %s lists no decisions, and a settled design always has some" % design)

    problems = []
    owners = {}  # requirement -> the decision ids it owns, in map order
    seen = set()
    no_code = 0
    for n, d in enumerate(decisions, 1):
        if not isinstance(d, dict):
            unreadable("decision %d in the map is not an object" % n)
        did = text(d.get("id")) or "#%d" % n
        what = text(d.get("decision"))
        if not what:
            problems.append("UNSTATED %s: the decision has no text, so nobody can check what was built against it" % did)
        if did in seen:
            problems.append("DUPLICATE %s: two decisions share this id" % did)
        seen.add(did)
        # An owner or reason given as something other than text (a requirement written as the number
        # 6.4) is named as mistyped, never reported as missing (lessons review of #1290, L11).
        mistyped = [(k, d[k]) for k in ("requirement", "noCode") if k in d and d[k] is not None and not isinstance(d[k], str)]
        if mistyped:
            for k, v in mistyped:
                # The value is shown as the JSON parser read it, and the fix is said in words rather
                # than as a suggested string: a number has already lost any trailing zero by now.
                kind = ("boolean" if isinstance(v, bool) else "number" if isinstance(v, (int, float))
                        else "list" if isinstance(v, list) else "object")
                problems.append("MISTYPED %s: %s (its %s was read as the %s %s; write it as text in quotes, "
                                "exactly as the PRD numbers it)" % (did, what, k, kind, json.dumps(v)))
            continue
        req = text(d.get("requirement"))
        reason = text(d.get("noCode"))
        if req and reason:
            problems.append("AMBIGUOUS %s: %s (it names Requirement %s and also says it has no code consequence)" % (did, what, req))
        elif req:
            owners.setdefault(req, []).append(did)
        elif reason:
            no_code += 1
        else:
            problems.append("UNMAPPED %s: %s" % (did, what))

    if len(argv) == 3:
        try:
            with open(argv[2], encoding="utf-8") as fh:
                plan = json.load(fh)
        except (OSError, ValueError) as err:
            unreadable("the plan %s could not be read as JSON: %s" % (argv[2], err))
        issues = plan.get("issues") if isinstance(plan, dict) else None
        if not isinstance(issues, list):
            issues = []
        issues_text = "\n".join(
            "%s\n%s" % (i.get("title") or "", i.get("body") or "") for i in issues if isinstance(i, dict))
        for req, dids in owners.items():
            if not named_by(req, issues_text):
                problems.append("NO-ISSUE Requirement %s (%s)" % (req, ", ".join(dids)))

    if problems:
        for p in problems:
            print(p)
        print("DECISION-MAP REFUSED: %d problem(s) in %s. Every decision needs the PRD requirement that "
              "owns it, or a noCode reason, and every requirement needs an issue that names it as "
              "Requirement <number>. Nothing was filed." % (len(problems), design))
        return 1
    print("DECISION-MAP OK: %d decisions, %d owned by %d requirements, %d with no code consequence%s"
          % (len(decisions), len(decisions) - no_code, len(owners), no_code,
             ", every requirement named by an issue" if len(argv) == 3 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
