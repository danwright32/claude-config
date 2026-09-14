#!/usr/bin/env python3
"""Recompute Dan's coffee taste profile from the tracker export.

Reads the newest "Coffee Tracker*.csv" in Downloads (or a named file), checks
the columns are the ones the analysis depends on, and prints every number the
profile page needs. Refuses loudly, with a distinct message, when the export is
missing, when a column has been renamed, or when the previous-run record is
unreadable (LESSONS L11, L215): a silent default in any of those would produce a
confident profile of the wrong thing.

Every category cut (roast, roaster, grind, process, type) is reported WITH its
blank count and a confound check: if removing one roaster from a group erases
that group's difference from the overall average, the roaster is named. That
check exists because the first profile blamed "fully washed" and "medium-light"
for what was one roaster (see memory: check-confounds-before-categorical-claims).

Usage:
  python3 analyze.py --record              # the real run: newest export in ~/Downloads, and
                                           # remember it as the previous run for next time
  python3 analyze.py                       # look only; the previous-run record is not touched
  python3 analyze.py --json                # same, as JSON
  python3 analyze.py --csv PATH            # a specific export
  python3 analyze.py --downloads DIR --state DIR   # seams, used by the tests
"""
import argparse
import csv
import json
import re
import statistics
import sys
from collections import defaultdict
from datetime import date
from pathlib import Path

ATTRIBUTES = ["Aroma", "Boldness", "Bitterness", "Sweetness", "Aftertaste", "Smoothness"]
REQUIRED = ["Coffee Name", "Roaster", "Type", "Origin", "Notes", "Milling Process",
            "Roast Level", "Grind", *ATTRIBUTES, "Overall Enjoyment", "Buy Again?"]
GROUPS = {"roast": "Roast Level", "roaster": "Roaster", "grind": "Grind",
          "process": "Milling Process", "type": "Type", "origin": "Origin"}
LIKED_AT, DISLIKED_AT = 7, 3   # label words come from coffees scored at or beyond these
EXPORT_GLOB = "Coffee Tracker*.csv"
MIN_DEVIATION = 0.75  # a group closer than this to the overall mean has no effect to explain
STATE_FILE = "last-run.json"
DEFAULT_DOWNLOADS = Path.home() / "Downloads"
# Named "runs", not "state": the config sync ignores any folder called state at any depth.
DEFAULT_STATE = Path(__file__).resolve().parent / "runs"


class NoExport(Exception):
    pass


class SchemaChanged(Exception):
    pass


class StateUnreadable(Exception):
    pass


def find_csv(downloads):
    downloads = Path(downloads)
    candidates = sorted(downloads.glob(EXPORT_GLOB), key=lambda p: p.stat().st_mtime)
    if not candidates:
        raise NoExport(f'No "{EXPORT_GLOB}" export found in {downloads}. '
                       "Export the Coffee Tracker sheet as CSV to that folder first.")
    return candidates[-1]


def score(text):
    m = re.match(r"\s*(\d+)", text or "")
    return int(m.group(1)) if m else None


def load(path):
    with open(path, newline="", encoding="utf-8") as fh:
        rows = list(csv.reader(fh))
    header = [h.strip() for h in rows[0]]
    missing = [c for c in REQUIRED if c not in header]
    if missing:
        raise SchemaChanged(f"The export at {path} is missing the column(s) {missing}. "
                            "The sheet's headers have changed; update REQUIRED in analyze.py once "
                            "you have confirmed what they mean now.")
    ix = {h: i for i, h in enumerate(header) if h}
    records = []
    for r in rows[1:]:
        if not any(cell.strip() for cell in r):
            continue
        get = lambda col: (r[ix[col]] if ix[col] < len(r) else "").strip()  # noqa: E731
        rec = {
            "name": get("Coffee Name"), "roaster": get("Roaster"), "type": get("Type"),
            "origin": get("Origin"), "notes": get("Notes"), "process": get("Milling Process"),
            "roast": get("Roast Level"), "grind": get("Grind"),
            "enjoy": score(get("Overall Enjoyment")), "buy": score(get("Buy Again?")),
        }
        for a in ATTRIBUTES:
            rec[a] = score(get(a))
        records.append(rec)
    return records


def pearson(xs, ys):
    mx, my = statistics.mean(xs), statistics.mean(ys)
    sx = sum((x - mx) ** 2 for x in xs) ** 0.5
    sy = sum((y - my) ** 2 for y in ys) ** 0.5
    if not sx or not sy:
        return None
    return sum((x - mx) * (y - my) for x, y in zip(xs, ys)) / (sx * sy)


def analyze(records):
    scored = [r for r in records if r["enjoy"] is not None]
    overall = statistics.mean(r["enjoy"] for r in scored)
    result = {
        "n": len(scored),
        "mean_enjoy": overall,
        "buy": {"yes": sum(r["buy"] == 3 for r in scored),
                "consider": sum(r["buy"] == 2 for r in scored),
                "no": sum(r["buy"] == 1 for r in scored)},
        "correlations": {}, "correlation_n": {}, "level_means": {},
        "groups": {}, "confounds": [],
    }
    for a in ATTRIBUTES:
        pts = [(r[a], r["enjoy"]) for r in scored if r[a] is not None]
        result["correlation_n"][a] = len(pts)
        result["correlations"][a] = pearson([p[0] for p in pts], [p[1] for p in pts]) if len(pts) > 1 else None
        levels = defaultdict(list)
        for v, e in pts:
            levels[v].append(e)
        result["level_means"][a] = {str(k): {"n": len(v), "mean": statistics.mean(v), "max": max(v)}
                                    for k, v in sorted(levels.items())}
    for key, col in GROUPS.items():
        field = key
        values = defaultdict(list)
        blank = 0
        for r in scored:
            if r[field]:
                values[r[field]].append(r)
            else:
                blank += 1
        result["groups"][key] = {
            "column": col, "blank": blank,
            "values": {k: {"n": len(v), "mean": statistics.mean(x["enjoy"] for x in v),
                           "yes": sum(x["buy"] == 3 for x in v), "no": sum(x["buy"] == 1 for x in v)}
                       for k, v in sorted(values.items(), key=lambda kv: -statistics.mean(x["enjoy"] for x in kv[1]))},
        }
        if key != "roaster":
            result["confounds"].extend(_confounds(key, values, overall))
    ranked = sorted(scored, key=lambda r: (-r["enjoy"], r["name"]))
    brief = lambda r: {k: r[k] for k in ("name", "roaster", "roast", "enjoy", "buy", "notes")}  # noqa: E731
    result["top"] = [brief(r) for r in ranked[:5]]
    result["bottom"] = [brief(r) for r in sorted(scored, key=lambda r: (r["enjoy"], r["name"]))[:5]]
    roasters = sorted({r["roaster"] for r in scored if r["roaster"]})
    result["roasters"] = {"all": roasters,
                          "liked": [x for x in roasters if any(r["roaster"] == x and r["buy"] == 3 for r in scored)]}
    result["coffees_logged"] = [r["name"] for r in scored]
    result["coffees"] = [{k: r[k] for k in ("name", "roaster", "roast", "origin", "notes", "process", "grind", "enjoy", "buy")}
                         for r in ranked]
    result["label_words"] = _label_words(scored)
    return result


def _phrases(notes):
    """Split a Notes cell into lowercase label phrases. Separators are commas,
    periods, semicolons, the bullet some roasters use, and dashes, so none of
    those characters ever survives into a phrase."""
    parts = re.split(r"[,.;\u2022\u2013\u2014]+", notes.lower())
    phrases = (re.sub(r"^(and|with|of)\s+", "", p.strip()) for p in parts)
    return {p for p in phrases if p}


def _label_words(scored):
    liked, disliked = set(), set()
    for r in scored:
        if r["enjoy"] >= LIKED_AT:
            liked |= _phrases(r["notes"])
        elif r["enjoy"] <= DISLIKED_AT:
            disliked |= _phrases(r["notes"])
    return {"yes": sorted(liked - disliked), "no": sorted(disliked - liked), "both": sorted(liked & disliked)}


def _confounds(group, values, overall):
    """Name a roaster whose removal erases a group's difference from the mean.

    Only judged where the group has at least three coffees, sits at least
    MIN_DEVIATION from the overall mean, the roaster has at least two of the
    coffees, and at least two remain after removal: below any of those a
    single cup decides everything, or there was no effect to carry, and the
    flag would be noise.
    """
    flags = []
    for value, coffees in values.items():
        if len(coffees) < 3:
            continue
        mean_with = statistics.mean(r["enjoy"] for r in coffees)
        dev_with = mean_with - overall
        if abs(dev_with) < MIN_DEVIATION:
            continue
        by_roaster = defaultdict(list)
        for r in coffees:
            by_roaster[r["roaster"]].append(r)
        for roaster, own in by_roaster.items():
            rest = [r for r in coffees if r["roaster"] != roaster]
            if len(own) < 2 or len(rest) < 2:
                continue
            mean_without = statistics.mean(r["enjoy"] for r in rest)
            dev_without = mean_without - overall
            flipped = (dev_with > 0) != (dev_without > 0)
            shrunk = abs(dev_without) < 0.5 * abs(dev_with)
            if flipped or shrunk:
                flags.append({"group": group, "value": value, "roaster": roaster,
                              "roaster_n": len(own), "n": len(coffees),
                              "mean_with": mean_with, "mean_without": mean_without})
    return flags


def run(csv_path, state_dir, record=False):
    state_dir = Path(state_dir)
    state_path = state_dir / STATE_FILE
    previous = None
    if state_path.exists():
        try:
            previous = json.loads(state_path.read_text())
        except (OSError, ValueError) as e:
            raise StateUnreadable(f"{state_path} exists but cannot be read ({e}). "
                                  "Fix or delete it; the run is not proceeding as if there were no previous run.")
    records = load(csv_path)
    result = analyze(records)
    result["csv"] = str(csv_path)
    result["run_date"] = date.today().isoformat()
    result["previous"] = previous and {k: previous.get(k) for k in ("run_date", "n", "mean_enjoy", "correlations", "buy")}
    seen_before = set(previous["coffees_logged"]) if previous else set()
    result["new_coffees"] = [c for c in result["coffees_logged"] if c not in seen_before] if previous else []
    result["recorded"] = record
    if not record:
        return result
    state_dir.mkdir(parents=True, exist_ok=True)
    state_path.write_text(json.dumps({k: result[k] for k in ("run_date", "n", "mean_enjoy", "correlations", "buy", "coffees_logged")}, indent=2))
    return result


def summary(r):
    out = []
    p = out.append
    p(f"Coffee profile, {r['run_date']}, from {r['csv']}" + ("" if r["recorded"] else "  (look only: not recorded as the previous run)"))
    p(f"{r['n']} coffees, mean enjoyment {r['mean_enjoy']:.2f}, buy again yes {r['buy']['yes']} / consider {r['buy']['consider']} / no {r['buy']['no']}")
    if r["previous"]:
        pv = r["previous"]
        p(f"Previous run {pv['run_date']}: {pv['n']} coffees, mean {pv['mean_enjoy']:.2f}. New since then: {', '.join(r['new_coffees']) or 'none'}")
    else:
        p("No previous run recorded.")
    p("\nCorrelation with enjoyment (n with a value):")
    for a in ATTRIBUTES:
        c = r["correlations"][a]
        p(f"  {a:11} {c:+.2f}  n={r['correlation_n'][a]}" if c is not None else f"  {a:11} n/a")
    p("\nMean enjoyment by level:")
    for a in ATTRIBUTES:
        p(f"  {a:11} " + "  ".join(f"{k}: mean {v['mean']:.1f} max {v['max']} (n{v['n']})" for k, v in r["level_means"][a].items()))
    for key, g in r["groups"].items():
        p(f"\n{g['column']} ({g['blank']} blank):")
        for k, v in g["values"].items():
            p(f"  {k[:34]:34} n={v['n']:2} mean={v['mean']:.1f} yes={v['yes']} no={v['no']}")
    p("\nConfounds (one roaster carries the group; do not report the group as a preference):")
    if not r["confounds"]:
        p("  none flagged")
    for f in r["confounds"]:
        p(f"  {f['group']}={f['value']}: {f['roaster']} is {f['roaster_n']} of {f['n']}; mean {f['mean_with']:.1f} with, {f['mean_without']:.1f} without")
    p("\nTop:")
    for c in r["top"]:
        p(f"  {c['enjoy']:2} {c['name']} ({c['roaster']}, {c['roast'] or '?'}) {c['notes']}")
    p("Bottom:")
    for c in r["bottom"]:
        p(f"  {c['enjoy']:2} {c['name']} ({c['roaster']}, {c['roast'] or '?'}) {c['notes']}")
    p("\nLabel words (from the notes of coffees scored 7+ / 3 or below / both sides):")
    p(f"  yes:  {', '.join(r['label_words']['yes'])}")
    p(f"  no:   {', '.join(r['label_words']['no'])}")
    p(f"  both: {', '.join(r['label_words']['both']) or 'none'}")
    p("\nEvery coffee (score, name, roaster, roast, origin, notes):")
    for c in r["coffees"]:
        p(f"  {c['enjoy']:2} {c['name']} | {c['roaster']} | {c['roast'] or 'roast not recorded'} | {c['origin'] or 'origin not recorded'} | {c['notes']}")
    p(f"\nRoasters with a Yes (eligible for an untried bag): {', '.join(r['roasters']['liked'])}")
    p(f"All roasters in the tracker (excluded as new companies): {', '.join(r['roasters']['all'])}")
    return "\n".join(out)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--csv", help="a specific export instead of the newest in Downloads")
    ap.add_argument("--downloads", default=str(DEFAULT_DOWNLOADS))
    ap.add_argument("--state", default=str(DEFAULT_STATE))
    ap.add_argument("--json", action="store_true")
    ap.add_argument("--record", action="store_true", help="remember this run as the previous run for next time")
    args = ap.parse_args(argv)
    try:
        csv_path = Path(args.csv) if args.csv else find_csv(args.downloads)
        result = run(csv_path, args.state, record=args.record)
    except NoExport as e:
        print(f"NO EXPORT: {e}", file=sys.stderr)
        return 2
    except SchemaChanged as e:
        print(f"SCHEMA CHANGED: {e}", file=sys.stderr)
        return 3
    except StateUnreadable as e:
        print(f"STATE UNREADABLE: {e}", file=sys.stderr)
        return 4
    print(json.dumps(result, indent=2) if args.json else summary(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
