#!/usr/bin/env python3
"""fr-path-sums.py -- sanity-check Wire-Cell field-response (FR) files.

For each plane, integrate every path's induced-current response over time and
report the result, the response width, and (optionally) draw the responses.

Physical expectation (unit drifting charge):

  * A path whose charge is COLLECTED on the wire of interest integrates to ~ +/-1.0
    (all the charge lands on the wire).
  * A path whose charge is collected on a NEIGHBOUR wire integrates to ~ 0.0
    (the wire of interest sees a purely bipolar induction signal).

The "wire of interest" is the reference wire (relative wire 0); a path's
`pitchpos` is the transverse impact position, so a path at pitchpos = n*pitch
sits directly above relative wire n.  For a healthy COLLECTION plane the wire-0
path integrates to ~1.0 and is a narrow spike; for INDUCTION planes every path
integrates to ~0.0.  A collection response that is much BROADER than normal (or
whose wire-0 integral is far from 1.0) points to a field-response problem.  An
O(1%) miss on the collection "1.0" is expected (finite Garfield domain).

Sign convention: WCT stores the collection response unipolar-negative; integrals
are reported with sign, compare magnitudes.

Usage:
  fr-path-sums.py FR.json[.bz2] [FR2 ...] [--plane N] [--all-paths]
                  [--pdf OUT.pdf] [--nwires K] [--tol 0.05]

  --pdf OUT.pdf   write a multi-page figure: one page per FR file, one subplot
                  per plane, showing the response vs time for the paths directly
                  above relative wires 0,1,2,... (one side; neighbours are
                  symmetric).  The legend gives the relative wire number and the
                  time-integral (charge) of each response.
  --nwires K      how many relative wires (0..K-1) to draw / summarise (default 5).

Exit status is non-zero if any file's collection wire-0 integral is farther than
--tol from +/-1.0 (a quick automated red flag for CI use).
"""

import os
import sys
import bz2
import gzip
import json
import argparse

import numpy as np


# --------------------------------------------------------------------------- IO
def _open(path):
    if path.endswith(".bz2"):
        return bz2.open(path, "rt")
    if path.endswith(".gz"):
        return gzip.open(path, "rt")
    return open(path, "rt")


def load_fr(path):
    with _open(path) as fp:
        doc = json.load(fp)
    return doc["FieldResponse"] if "FieldResponse" in doc else doc


def _current(path_response):
    """FR 'current' is either a plain list or {'array': {'elements': [...]}}."""
    cur = path_response["current"]
    if isinstance(cur, dict):
        arr = cur.get("array", cur)
        return np.asarray(arr["elements"], dtype=float)
    return np.asarray(cur, dtype=float)


def _plane_of(pentry):
    return pentry["PlaneResponse"] if "PlaneResponse" in pentry else pentry


def _paths_of(plane):
    return [p["PathResponse"] if "PathResponse" in p else p for p in plane["paths"]]


# ---------------------------------------------------------------- measurements
def integral(cur, period):
    """Time-integrated charge for one path = sum(current) * period (~1 collecting)."""
    return float(cur.sum()) * period


def width10(cur, period):
    """Extent (ns) over which |response| exceeds 10% of its peak magnitude."""
    s = np.abs(cur)
    if s.max() <= 0:
        return 0.0
    idx = np.where(s > 0.1 * s.max())[0]
    return float(idx[-1] - idx[0]) * period if len(idx) else 0.0


def wire_paths(plane, period, nwires):
    """Select the path sitting directly above relative wire n, for n=0..nwires-1.

    Matches on |pitchpos| closest to n*pitch (neighbours are symmetric, so either
    sign serves).  Returns an ordered list of (n, pitchpos, current).
    """
    pitch = plane.get("pitch")
    paths = _paths_of(plane)
    pos = np.array([p.get("pitchpos", 0.0) for p in paths])
    out = []
    if not pitch:
        return out
    for n in range(nwires):
        target = n * pitch
        j = int(np.argmin(np.abs(np.abs(pos) - target)))
        # Skip if there is no path within half a pitch of this wire centre.
        if abs(abs(pos[j]) - target) > 0.5 * pitch and n > 0:
            continue
        out.append((n, float(pos[j]), _current(paths[j])))
    return out


def central_region_paths(plane, period):
    """All impact paths that fall on the CENTRAL wire (|pitchpos| <= pitch/2).

    These sub-pitch impacts sample the response across the face of relative
    wire 0.  Neighbours are symmetric, so one side is shown: for each distinct
    |pitchpos| the path with the larger |integral| is kept (this surfaces the
    "real" side when a file is asymmetric or has a broken exact-centre path).
    Returns an ordered list of (abs_pitchpos, pitchpos, current), inner-first.
    """
    pitch = plane.get("pitch")
    if not pitch:
        return []
    half = 0.5 * pitch
    paths = _paths_of(plane)
    by_abs = {}
    for p in paths:
        pp = p.get("pitchpos", 0.0)
        if abs(pp) > half + 1e-6 * pitch:
            continue
        key = round(abs(pp), 4)
        cur = _current(p)
        q = abs(integral(cur, period))
        if key not in by_abs or q > by_abs[key][2]:
            by_abs[key] = (float(pp), cur, q)
    return [(k, v[0], v[1]) for k, v in sorted(by_abs.items())]


# ------------------------------------------------------------------- reporting
def analyze(fr, name, want_plane=None, all_paths=False, nwires=5):
    period = fr["period"]
    planes = fr["planes"]
    print("\n===== %s =====" % name)
    print("# period=%g  speed=%s  origin=%s  axis=%s  nplanes=%d"
          % (period, fr.get("speed"), fr.get("origin"), fr.get("axis"), len(planes)))

    worst_collection_err = None
    for pentry in planes:
        pl = _plane_of(pentry)
        pid = pl.get("planeid")
        if want_plane is not None and pid != want_plane:
            continue
        pitch = pl.get("pitch")
        wps = wire_paths(pl, period, nwires)

        # wire-0 path characterises the plane (collection spike / induction lobe).
        w0 = next((wp for wp in wps if wp[0] == 0), None)
        w0_int = integral(w0[2], period) if w0 else float("nan")
        w0_wid = width10(w0[2], period) if w0 else float("nan")

        print("\n## planeid=%s  location=%s  pitch=%s  npaths=%d"
              % (pid, pl.get("location"), pitch, len(pl["paths"])))
        print("   wire-0 path: integral=%+.4f  width(>10%%peak)=%.0f ns" % (w0_int, w0_wid))
        # Per-wire integrals (charge sharing across neighbours).
        share = "  ".join("w%d=%+.3f" % (n, integral(c, period)) for n, _, c in wps)
        print("   per-wire integral: %s" % share)

        looks_collection = abs(w0_int) > 0.5
        if looks_collection:
            err = abs(abs(w0_int) - 1.0)
            print("   => COLLECTION-like: wire-0 integral %+.4f (expect ~1.0, err %.1f%%); "
                  "width %.0f ns" % (w0_int, 100 * err, w0_wid))
            if worst_collection_err is None or err > worst_collection_err:
                worst_collection_err = err
        else:
            print("   => INDUCTION-like: wire-0 integral %+.4f (expect ~0.0); "
                  "lobe width %.0f ns" % (w0_int, w0_wid))

        if all_paths:
            print("   path pitchpos[mm]  integral")
            for p in _paths_of(pl):
                print("     %+10.3f  %+.5f" % (p.get("pitchpos", 0.0),
                                               integral(_current(p), period)))

    return worst_collection_err


# ------------------------------------------------------------------------- PDF
def _window(curves, period, pad_frac=0.10):
    """Common x-range (ns) covering where any curve exceeds 2% of the global max."""
    gmax = max((np.abs(c).max() for c in curves), default=0.0)
    if gmax <= 0:
        return None
    lo, hi = None, None
    for c in curves:
        idx = np.where(np.abs(c) > 0.02 * gmax)[0]
        if not len(idx):
            continue
        a, b = idx[0] * period, idx[-1] * period
        lo = a if lo is None else min(lo, a)
        hi = b if hi is None else max(hi, b)
    if lo is None:
        return None
    pad = (hi - lo) * pad_frac + period
    return lo - pad, hi + pad


def make_pdf(fr_files, out_pdf, nwires=5):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.backends.backend_pdf import PdfPages

    plane_name = {0: "U (induction)", 1: "V (induction)", 2: "W (collection)"}
    with PdfPages(out_pdf) as pdf:
        for path in fr_files:
            fr = load_fr(path)
            period = fr["period"]
            planes = [_plane_of(pe) for pe in fr["planes"]]
            n = len(planes)
            # Gather every curve to be drawn first, so all subplots on the page
            # can share ONE set of X and Y limits (comparable across planes).
            per_plane = []       # list of (pl, [(label, current), ...])
            all_curves = []
            for pl in planes:
                pitch = pl.get("pitch")
                curves = []
                # All impacts on the central wire (inner->outer, one side).
                for absp, pp, cur in central_region_paths(pl, period):
                    curves.append(("c @%.2fmm (Q=%+.3f)" % (absp, integral(cur, period)), cur))
                # Neighbour wires 1..nwires-1 (single centre path each).
                for wn, pp, cur in wire_paths(pl, period, nwires):
                    if wn == 0:
                        continue
                    curves.append(("wire %d (Q=%+.3f)" % (wn, integral(cur, period)), cur))
                per_plane.append((pl, curves))
                all_curves.extend(c for _, c in curves)

            win = _window(all_curves, period)
            ymax = max((np.abs(c).max() for c in all_curves), default=1.0)

            fig, axes = plt.subplots(n, 1, figsize=(8.5, 3.0 * n + 0.5),
                                     squeeze=False, sharex=True, sharey=True)
            axes = axes[:, 0]
            for ax, (pl, curves) in zip(axes, per_plane):
                pid = pl.get("planeid")
                for label, cur in curves:
                    ax.plot(np.arange(len(cur)) * period / 1000.0, cur, lw=1.1, label=label)
                ax.axhline(0.0, color="0.7", lw=0.6)
                ax.set_title("planeid=%s: %s   pitch=%.3f mm"
                             % (pid, plane_name.get(pid, "?"), pl.get("pitch", float("nan"))),
                             fontsize=9)
                ax.set_ylabel("induced current", fontsize=8)
                ax.legend(fontsize=6, loc="upper right", ncol=2)
                ax.tick_params(labelsize=7)
            if win:
                axes[0].set_xlim(win[0] / 1000.0, win[1] / 1000.0)   # shared via sharex
            axes[0].set_ylim(-1.05 * ymax, 1.05 * ymax)              # shared via sharey
            axes[-1].set_xlabel("time [us]", fontsize=8)
            fig.suptitle(os.path.basename(path), fontsize=11)
            fig.tight_layout(rect=[0, 0, 1, 0.97])
            pdf.savefig(fig)
            plt.close(fig)
    print("wrote %s (%d pages)" % (out_pdf, len(fr_files)))


# ------------------------------------------------------------------------ main
def main(argv=None):
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("fr_file", nargs="+", help="field response .json/.json.bz2/.json.gz")
    ap.add_argument("--plane", type=int, default=None, help="only this planeid")
    ap.add_argument("--all-paths", action="store_true", help="print every path integral")
    ap.add_argument("--nwires", type=int, default=5, help="relative wires 0..K-1 (default 5)")
    ap.add_argument("--pdf", default=None, help="write a multi-page PDF figure to this path")
    ap.add_argument("--tol", type=float, default=0.05,
                    help="max |wire0_collection_integral - 1.0| before non-zero exit")
    args = ap.parse_args(argv)

    worst = None
    for path in args.fr_file:
        w = analyze(load_fr(path), path, args.plane, args.all_paths, args.nwires)
        if w is not None and (worst is None or w > worst):
            worst = w

    if args.pdf:
        make_pdf(args.fr_file, args.pdf, args.nwires)

    if worst is None:
        print("\n(no collection-like plane detected)")
        return 0
    print("\nworst collection wire-0 integral error: %.1f%% (tol %.1f%%)"
          % (100 * worst, 100 * args.tol))
    return 0 if worst <= args.tol else 1


if __name__ == "__main__":
    sys.exit(main())
