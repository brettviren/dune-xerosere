#!/usr/bin/env bash
#
# build_small_gdml.sh — regenerate benchmark_small.gdml from the benchmark_ggd
# gegede geometry package.
#
# The committed benchmark_small.gdml is a SMALL (20 cm cube) variant of the
# edep-simphony-benchmark LAr optical geometry: same materials, WLS shells and
# 100%-efficiency photon-detector shell (edep-sim `SurfaceDetector` aux), but
# small enough that CPU optical-photon tracking is fast.  It is committed so the
# test needs no gegede at run time; this script only reproduces it.
#
# Requires network access (installs gegede from git into a throwaway venv).
#
# Usage:  tests/edep-simphony/geometry/build_small_gdml.sh
set -euo pipefail

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
out="$here/benchmark_small.gdml"
ggd="$here/benchmark_ggd"

command -v uv >/dev/null 2>&1 || { echo "need 'uv' to create the gegede venv" >&2; exit 1; }

venv="$(mktemp -d)"
trap 'rm -rf "$venv"' EXIT
uv venv --python 3.11 "$venv" >/dev/null
# shellcheck disable=SC1091
. "$venv/bin/activate"
# The optical `surfaces` API used by the benchmark geometry is only in the
# upstream (brettviren) gegede, not the PyPI release.
uv pip install "git+https://github.com/brettviren/gegede" >/dev/null

PYTHONPATH="$ggd" python - "$out" <<'PY'
import sys, benchmark, build_geo
# Small LAr cube for fast CPU optical tracking (fixture, not the DUNE-scale
# benchmark, which is 60 x 13.5 x 13 m and only tractable on the GPU).
benchmark.LAR_X = benchmark.LAR_Y = benchmark.LAR_Z = 200.0  # mm
build_geo.build(output=sys.argv[1])
PY

echo "wrote: $out"
