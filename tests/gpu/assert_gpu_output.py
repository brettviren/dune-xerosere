#!/usr/bin/env python3
"""Assert that an edep-simphony-plugin run produced GPU optical photon output.

Opens the edep-sim ROOT file and checks (ddm-p5j.6):

  * EDepSimEvents  is present (the CPU energy-deposition tree), and
  * GPUPhotonHits  is present, NON-EMPTY, and carries the expected branches
    (EventId, TrackId, Process, Wavelength, HitPos).

A non-empty GPUPhotonHits tree is the proxy for "the GPU launch
(G4CXOpticks::simulate) actually ran": only the GPU readout path fills it, so
a CPU-only fallback would leave it empty.

Reads the file with PyROOT (ROOT is provided by the Spack environment the
driver activates).  Exit status: 0 = all assertions pass, 1 = a check failed,
2 = usage/IO error.
"""

import argparse
import sys

# GPUPhotonHits branches promised by the plugin README.
REQUIRED_HITS_BRANCHES = ("EventId", "TrackId", "Process", "Wavelength", "HitPos")


def tree_entries(rootfile, name):
    """Return entry count for TTree *name*, or None if the tree is absent."""
    obj = rootfile.Get(name)
    if not obj:
        return None
    return int(obj.GetEntries())


def branch_names(rootfile, name):
    obj = rootfile.Get(name)
    if not obj:
        return set()
    return {b.GetName() for b in obj.GetListOfBranches()}


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rootfile", help="edep-sim output ROOT file to inspect")
    ap.add_argument("--min-hits", type=int, default=1,
                    help="minimum GPUPhotonHits entries required (default: 1)")
    args = ap.parse_args(argv)

    try:
        import ROOT
    except ImportError as exc:
        print(f"FAIL: cannot import ROOT (PyROOT): {exc}", file=sys.stderr)
        return 2

    ROOT.gErrorIgnoreLevel = ROOT.kWarning
    f = ROOT.TFile.Open(args.rootfile)
    if not f or f.IsZombie():
        print(f"FAIL: cannot open ROOT file: {args.rootfile}", file=sys.stderr)
        return 2

    problems = []

    edep = tree_entries(f, "EDepSimEvents")
    if edep is None:
        problems.append("EDepSimEvents tree is missing")
    else:
        print(f"  EDepSimEvents: {edep} entries")

    hits = tree_entries(f, "GPUPhotonHits")
    if hits is None:
        problems.append("GPUPhotonHits tree is missing (GPU path did not run?)")
    else:
        print(f"  GPUPhotonHits: {hits} entries")
        if hits < args.min_hits:
            problems.append(
                f"GPUPhotonHits has {hits} entries, expected >= {args.min_hits} "
                "(GPU produced no detected photons — CPU-only fallback?)"
            )
        missing = [b for b in REQUIRED_HITS_BRANCHES
                   if b not in branch_names(f, "GPUPhotonHits")]
        if missing:
            problems.append(f"GPUPhotonHits missing branches: {', '.join(missing)}")

    f.Close()

    if problems:
        print("FAIL:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1

    print("PASS: GPU photon output present and non-empty")
    return 0


if __name__ == "__main__":
    sys.exit(main())
