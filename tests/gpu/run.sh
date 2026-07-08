#!/usr/bin/env bash
#
# tests/gpu/run.sh — exercise the Spack-installed edep-simphony-plugin
# end-to-end on a real GPU and assert it produced GPU optical-photon output
# (ddm-p5j.6).
#
# It:
#   1. Skips (exit 77) when no usable NVIDIA GPU is present, or when no
#      geometry fixture has been provided yet (ddm-p5j.5).
#   2. Activates the Spack environment so the plugin's runtime env
#      (EXTRAPHYSICS, PLUGIN_LIB, OPTICKS_*, CSGOptiX__ptxpath) and the
#      edep-sim binary are available.
#   3. Runs  edep-sim -p <phys> -g <gdml> -o <out> -e <N> <macro>.
#   4. Asserts EDepSimEvents + a non-empty GPUPhotonHits tree via
#      assert_gpu_output.py.
#
# Usage (standalone or via `umbrella <env> test gpu`):
#   tests/gpu/run.sh [env] [outdir]
#     env     Spack environment name under extern/envs/   (default: gcc15)
#     outdir  output directory  (default: builds/envs/<env>/xerosere/gpu)
#
# Optional overrides:
#   PLUGIN_TEST_GDML      geometry GDML   (no default -> skip; a LAr optical
#                         GDML, ddm-p5j.5)
#   PLUGIN_TEST_MACRO     edep-sim macro       (default: tests/gpu/plugin_gpu_test.mac)
#   PLUGIN_TEST_PHYSICS   Geant4 physics list  (default: QGSP_BERT)
#   PLUGIN_TEST_NEVENTS   number of events     (default: 5)
#   PLUGIN_TEST_MIN_HITS  minimum GPUPhotonHits entries  (default: 1)
#
# Exit codes:  0 = pass,  1 = assertion/run failed,  77 = skipped.

set -uo pipefail

SKIP=77

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[gpu-test] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }

env_name="${1:-gcc15}"
outdir="${2:-$root/builds/envs/$env_name/xerosere/gpu}"

# --- 1. GPU gate ------------------------------------------------------------
# Require both a control device node and a working nvidia-smi enumeration.
[ -e /dev/nvidiactl ] || skip "no /dev/nvidiactl device node — no usable GPU on $(hostname)"
command -v nvidia-smi >/dev/null 2>&1 || skip "nvidia-smi not found"
nvidia-smi -L >/dev/null 2>&1 || skip "nvidia-smi cannot communicate with the driver on $(hostname)"
say "GPU detected: $(nvidia-smi -L 2>/dev/null | head -1)"

# --- 2. geometry fixture (skip if absent — ddm-p5j.5) -----------------------
gdml="${PLUGIN_TEST_GDML:-}"
[ -n "$gdml" ] || skip "PLUGIN_TEST_GDML unset — no LAr optical geometry fixture yet (ddm-p5j.5)"
[ -f "$gdml" ] || die "geometry not found: $gdml"

# --- 3. activate the Spack environment --------------------------------------
env_dir="$root/extern/envs/$env_name"
[ -d "$env_dir" ] || die "Spack env not found: $env_dir"

export SPACK_USER_CACHE_PATH="$root/extern/cache"
export SPACK_USER_CONFIG_PATH="$root/extern/scopes/user"
export SPACK_SYSTEM_CONFIG_PATH="$root/extern/scopes/system"
export PATH="$root/extern/spack/bin:$PATH"
command -v spack >/dev/null 2>&1 || die "spack not on PATH ($root/extern/spack/bin)"

say "activating Spack env: $env_dir"
# Applies each installed spec's setup_run_environment, incl. the plugin's
# EXTRAPHYSICS / PLUGIN_LIB / OPTICKS_* and edep-sim on PATH.  Use -d because
# this is a directory (anonymous) environment, not a named one.
source <(spack env activate --sh -d "$env_dir")

command -v edep-sim >/dev/null 2>&1 || die "edep-sim not on PATH after activation"
[ -n "${EXTRAPHYSICS:-}" ] || die "EXTRAPHYSICS not set — is edep-simphony-plugin installed in the env?"
[ -n "${PLUGIN_LIB:-}" ]   || die "PLUGIN_LIB not set — reinstall the plugin (setup_run_environment)"
say "EXTRAPHYSICS=$EXTRAPHYSICS"
say "PLUGIN_LIB=$PLUGIN_LIB"
say "CSGOptiX__ptxpath=${CSGOptiX__ptxpath:-<unset>}"

# --- 4. inputs --------------------------------------------------------------
macro="${PLUGIN_TEST_MACRO:-$here/plugin_gpu_test.mac}"
[ -f "$macro" ] || die "macro not found: $macro"
physics="${PLUGIN_TEST_PHYSICS:-QGSP_BERT}"
nevents="${PLUGIN_TEST_NEVENTS:-5}"
min_hits="${PLUGIN_TEST_MIN_HITS:-1}"

mkdir -p "$outdir"
out="$outdir/gpu.root"
rm -f "$out"

# --- 5. run edep-sim --------------------------------------------------------
say "running: edep-sim -p $physics -g $gdml -o $out -e $nevents $macro"
if ! edep-sim -p "$physics" -g "$gdml" -o "$out" -e "$nevents" "$macro" > "$outdir/edep-sim.log" 2>&1; then
    tail -20 "$outdir/edep-sim.log" >&2
    die "edep-sim exited non-zero (see $outdir/edep-sim.log)"
fi
[ -s "$out" ] || die "edep-sim produced no output file: $out"

# --- 6. assert GPU photon output --------------------------------------------
say "asserting GPU photon output in $out"
if python3 "$here/assert_gpu_output.py" --min-hits "$min_hits" "$out"; then
    say "PASS"
    exit 0
else
    say "FAIL — output left for inspection: $out"
    exit 1
fi
