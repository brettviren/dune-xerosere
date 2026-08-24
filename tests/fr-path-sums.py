#!/usr/bin/env python3
"""fr-path-sums.py -- sanity-check a Wire-Cell field-response (FR) file.

For each plane, integrate every path's induced-current response over time and
report the result.  Physical expectation (unit drifting charge):

  * A path whose charge is COLLECTED on the wire of interest integrates to ~ +/-1.0
    (all the charge lands on the wire).
  * A path whose charge is collected on a NEIGHBOUR wire integrates to ~ 0.0
    (the wire of interest sees a purely bipolar induction signal).

The "wire of interest" is the central wire; a path's `pitchpos` is its transverse
impact position relative to that wire, so |pitchpos| < pitch/2 is the collecting
region.  For a healthy COLLECTION plane the collecting paths should sum to ~1.0;
for INDUCTION planes every path sums to ~0.0 (nothing is collected).

A collection plane whose collecting paths sum to much less than 1.0 points to an
under-normalised field response (or an electronics/filter normalisation bug
elsewhere in the chain).  An O(1%) miss on the collection "1.0" is expected and
harmless -- it comes from the Garfield calculation being done over a finite
transverse domain.

Sign convention: WCT stores the collection response as unipolar-negative, so the
integral is reported with its sign; compare magnitudes.

Usage:
  fr-path-sums.py FR.json[.bz2] [--plane N] [--all-paths] [--tol 0.05]

Exit status is non-zero if any collection plane's best collecting path integral
is farther than --tol from +/-1.0 (a quick automated red flag).
"""

import sys
import bz2
import gzip
import json
import argparse


def _open(path):
    if path.endswith(".bz2"):
        return bz2.open(path, "rt")
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def _as_list(current):
    """FR 'current' is either a plain list or {'array': {'elements': [...]}}."""
    if isinstance(current, dict):
        arr = current.get("array", current)
        return arr["elements"]
    return current


def load_fr(path):
    with _open(path) as fp:
        doc = json.load(fp)
    fr = doc["FieldResponse"] if "FieldResponse" in doc else doc
    return fr


def path_integral(path_response, period):
    """Integrated charge for one path = sum(current) * period.

    With WCT's normalisation this makes a collecting path integrate to ~1.
    """
    cur = _as_list(path_response["current"])
    return sum(cur) * period


def analyze(fr, want_plane=None, all_paths=False, tol=0.05):
    period = fr["period"]
    planes = fr["planes"]
    print("# period=%g  speed=%g  origin=%g  axis=%s  nplanes=%d"
          % (period, fr.get("speed"), fr.get("origin"), fr.get("axis"), len(planes)))

    worst_collection_err = None
    for pentry in planes:
        pl = pentry["PlaneResponse"] if "PlaneResponse" in pentry else pentry
        pid = pl.get("planeid")
        if want_plane is not None and pid != want_plane:
            continue
        pitch = pl.get("pitch")
        paths = [p["PathResponse"] if "PathResponse" in p else p for p in pl["paths"]]

        rows = []
        for p in paths:
            pp = p.get("pitchpos")
            integ = path_integral(p, period)
            rows.append((pp, integ))

        half = (pitch / 2.0) if pitch else None
        collecting = [(pp, v) for pp, v in rows
                      if half is not None and abs(pp) < half]
        # Best (largest-magnitude) collecting path integral.
        best = max((abs(v) for _, v in collecting), default=0.0)

        print("\n## planeid=%s  location=%s  pitch=%s  npaths=%d"
              % (pid, pl.get("location"), pitch, len(rows)))
        if collecting:
            cvals = [v for _, v in collecting]
            print("   collecting paths (|pitchpos|<pitch/2): n=%d  integrals: "
                  "min=%+.4f max=%+.4f  best|.|=%.4f"
                  % (len(collecting), min(cvals), max(cvals), best))
        noncol = [v for pp, v in rows if half is None or abs(pp) >= half]
        if noncol:
            print("   other paths: n=%d  max|integral|=%.4f  mean|integral|=%.4f"
                  % (len(noncol), max(abs(v) for v in noncol),
                     sum(abs(v) for v in noncol) / len(noncol)))

        # A collection plane is the one whose collecting paths approach 1.
        # Heuristic: flag if best collecting integral > 0.5 (looks collection-y).
        looks_collection = best > 0.5
        if looks_collection:
            err = abs(best - 1.0)
            print("   => COLLECTION-like: best collecting integral %.4f "
                  "(expect ~1.0, err %.1f%%)" % (best, 100 * err))
            if worst_collection_err is None or err > worst_collection_err:
                worst_collection_err = err
        elif half is not None:
            print("   => INDUCTION-like: max collecting integral %.4f "
                  "(expect ~0.0)" % best)

        if all_paths:
            print("   path pitchpos[mm]  integral")
            for pp, v in rows:
                mark = "  <collect>" if (half is not None and abs(pp) < half) else ""
                print("     %+10.3f  %+.5f%s" % (pp, v, mark))

    return worst_collection_err


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fr_file", help="field response .json/.json.bz2/.json.gz")
    ap.add_argument("--plane", type=int, default=None,
                    help="only this planeid (0=U,1=V,2=W typically)")
    ap.add_argument("--all-paths", action="store_true",
                    help="print every path's pitchpos and integral")
    ap.add_argument("--tol", type=float, default=0.05,
                    help="max allowed |best_collection_integral - 1.0| "
                         "before a non-zero exit (default 0.05)")
    args = ap.parse_args(argv)

    fr = load_fr(args.fr_file)
    worst = analyze(fr, args.plane, args.all_paths, args.tol)

    if worst is None:
        print("\n(no collection-like plane detected)")
        return 0
    print("\nworst collection-integral error: %.1f%% (tol %.1f%%)"
          % (100 * worst, 100 * args.tol))
    return 0 if worst <= args.tol else 1


if __name__ == "__main__":
    sys.exit(main())
