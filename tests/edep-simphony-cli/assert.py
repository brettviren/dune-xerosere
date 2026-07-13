#!/usr/bin/env python3
"""Assert an edep-sim CLI run produced optical-photon output.

Two modes, matching the two optical-tracking backends:

  --mode gpu : Simphony/GPU.  The plugin's UserEventAction writes a GPUPhotonHits
               TTree; assert it exists and is non-empty (with the expected
               branches).  A non-empty tree is the proxy for "the GPU launch
               actually ran".
  --mode cpu : Geant4/CPU.  Optical photons are tracked to the photon-detector
               shell and recorded in TG4Event.PhotonDetectors inside the
               EDepSimEvents tree; assert the summed hit count is non-empty.

Exit status: 0 = pass, 1 = a check failed, 2 = usage/IO error.
"""

import argparse
import sys

REQUIRED_HITS_BRANCHES = ("EventId", "TrackId", "Process", "Wavelength", "HitPos")


def report(problems, what):
    if problems:
        print("FAIL:", file=sys.stderr)
        for p in problems:
            print(f"  - {p}", file=sys.stderr)
        return 1
    print(f"PASS: {what}")
    return 0


def check_gpu(ROOT, args):
    f = ROOT.TFile.Open(args.rootfile)
    if not f or f.IsZombie():
        print(f"FAIL: cannot open {args.rootfile}", file=sys.stderr)
        return 2
    problems = []
    if not f.Get("EDepSimEvents"):
        problems.append("EDepSimEvents tree missing")
    hits = f.Get("GPUPhotonHits")
    if not hits:
        problems.append("GPUPhotonHits tree missing (GPU path did not run?)")
    else:
        n = int(hits.GetEntries())
        print(f"  GPUPhotonHits: {n} entries")
        if n < args.min_hits:
            problems.append(f"GPUPhotonHits has {n} entries, expected >= {args.min_hits}")
        have = {b.GetName() for b in hits.GetListOfBranches()}
        missing = [b for b in REQUIRED_HITS_BRANCHES if b not in have]
        if missing:
            problems.append(f"GPUPhotonHits missing branches: {', '.join(missing)}")
    f.Close()
    return report(problems, "GPU photon output (non-empty GPUPhotonHits)")


def check_cpu(ROOT, args):
    # TG4Event lives in the edep-sim I/O dictionary.
    if ROOT.gSystem.Load("libedepsim_io") < 0:
        print("FAIL: cannot load libedepsim_io (edep-sim I/O dictionary)", file=sys.stderr)
        return 2
    f = ROOT.TFile.Open(args.rootfile)
    if not f or f.IsZombie():
        print(f"FAIL: cannot open {args.rootfile}", file=sys.stderr)
        return 2
    t = f.Get("EDepSimEvents")
    if not t:
        print("FAIL: EDepSimEvents tree missing", file=sys.stderr)
        return 1
    photons = segments = 0
    for e in t:
        for sd in e.Event.PhotonDetectors:
            photons += sd.second.size()
        for sd in e.Event.SegmentDetectors:
            segments += sd.second.size()
    print(f"  EDepSimEvents: {t.GetEntries()} entries")
    print(f"  PhotonDetectors hits: {photons}")
    print(f"  SegmentDetectors segments: {segments}")
    f.Close()
    problems = []
    if photons < args.min_hits:
        problems.append(
            f"PhotonDetectors has {photons} hits, expected >= {args.min_hits} "
            "(optical tracking off, or geometry has no photon detector?)"
        )
    return report(problems, "CPU photon output (non-empty PhotonDetectors)")


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("rootfile", help="edep-sim output ROOT file")
    ap.add_argument("--mode", choices=["cpu", "gpu"], required=True)
    ap.add_argument("--min-hits", type=int, default=1)
    args = ap.parse_args(argv)

    try:
        import ROOT
    except ImportError as exc:
        print(f"FAIL: cannot import ROOT (PyROOT): {exc}", file=sys.stderr)
        return 2
    ROOT.gErrorIgnoreLevel = ROOT.kError

    return check_gpu(ROOT, args) if args.mode == "gpu" else check_cpu(ROOT, args)


if __name__ == "__main__":
    sys.exit(main())
