#!/usr/bin/env bash
#
# tests/edep-simphony-cli/run.sh — the edep-sim command-line counterpart of
# tests/edep-simphony (which runs the same physics through phlex).
#
# Same geometry and primary, but driven by the `edep-sim` CLI, with optical
# photon tracking on either backend:
#   cpu  Geant4 tracks photons on the CPU (no plugin) -> TG4Event.PhotonDetectors
#   gpu  the Simphony plugin offloads photons to the GPU  -> GPUPhotonHits TTree
#
# The backend is chosen by EDEP_SIMPHONY_MODE and, in GPU mode, further governed
# by the plugin's own shell-environment settings (EXTRAPHYSICS, OPTICKS_*,
# EDEP_SIMPHONY_*), which the Spack env's setup_run_environment provides.
#
# Usage (standalone or via `umbrella <env> test edep-simphony-cli`):
#   tests/edep-simphony-cli/run.sh [env] [outdir]
#     env     Spack environment name under extern/envs/   (default: gcc15)
#     outdir  output directory  (default: builds/envs/<env>/xerosere/edep-simphony-cli)
#
# Options (environment):
#   EDEP_SIMPHONY_MODE     auto | cpu | gpu   (default: auto)
#                          auto = gpu if a usable GPU + OptiX runtime is present,
#                                 else cpu.  gpu = require it (skip if missing).
#   EDEP_SIMPHONY_GDML     geometry GDML (default: the tests/edep-simphony fixture)
#   EDEP_SIMPHONY_NEVENTS  number of events   (default: 2)
#   EDEP_SIMPHONY_PHYSICS  Geant4 physics list (default: QGSP_BERT)
#
# Exit codes: 0 = pass, 1 = failure, 77 = skipped.

set -uo pipefail

SKIP=77
name="edep-simphony-cli"

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[$name] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }

env_name="${1:-gcc15}"
outdir="${2:-$root/builds/envs/$env_name/xerosere/$name}"
mode="${EDEP_SIMPHONY_MODE:-auto}"
# Geometry is shared with the phlex test so both exercise the same edep-sim config.
gdml="${EDEP_SIMPHONY_GDML:-$root/tests/edep-simphony/geometry/benchmark_small.gdml}"
nevents="${EDEP_SIMPHONY_NEVENTS:-2}"
physics="${EDEP_SIMPHONY_PHYSICS:-QGSP_BERT}"

env_dir="$root/extern/envs/$env_name"
[ -d "$env_dir" ] || skip "no such Spack env: $env_dir"
[ -f "$gdml" ] || die "geometry not found: $gdml (build it: tests/edep-simphony/geometry/build_small_gdml.sh)"

# Directory holding the driver's OptiX loader library (libnvoptix.so.1), or ""
# if not found.  Debian installs it (with libcuda.so.1, libnvidia-gpucomp) under
# /usr/lib/.../nvidia/current, which is NOT on the default loader path, so we
# locate it and add it to LD_LIBRARY_PATH for the GPU run.
nvoptix_dir() {
    local p d
    p="$(ldconfig -p 2>/dev/null | awk '/libnvoptix\.so\.1/{print $NF; exit}')"
    if [ -n "$p" ] && [ -e "$p" ]; then dirname "$p"; return; fi
    for d in /usr/lib/x86_64-linux-gnu/nvidia/current /usr/lib/x86_64-linux-gnu \
             /usr/lib64/nvidia /usr/lib64 /usr/lib/nvidia; do
        [ -e "$d/libnvoptix.so.1" ] && { echo "$d"; return; }
    done
    echo ""
}

# Why the Simphony/GPU optical path cannot run here, or "" if it can.
gpu_blocker() {
    [ -e /dev/nvidiactl ] || { echo "no GPU device (/dev/nvidiactl)"; return; }
    { command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi -L >/dev/null 2>&1; } \
        || { echo "nvidia-smi cannot communicate with the driver"; return; }
    [ -n "$(nvoptix_dir)" ] \
        || { echo "OptiX driver library libnvoptix.so.1 not found"; return; }
    echo ""
}

# --- resolve mode -----------------------------------------------------------
if [ "$mode" = auto ]; then
    blocker="$(gpu_blocker)"
    if [ -z "$blocker" ]; then mode=gpu; else say "auto: GPU optical unavailable ($blocker) -> cpu"; mode=cpu; fi
fi

# --- activate the Spack environment -----------------------------------------
export SPACK_USER_CACHE_PATH="$root/extern/cache"
export SPACK_USER_CONFIG_PATH="$root/extern/scopes/user"
export SPACK_SYSTEM_CONFIG_PATH="$root/extern/scopes/system"
export PATH="$root/extern/spack/bin:$PATH"
command -v spack >/dev/null 2>&1 || die "spack not on PATH ($root/extern/spack/bin)"
source <(spack env activate --sh -d "$env_dir")
command -v edep-sim >/dev/null 2>&1 || die "edep-sim not on PATH after activation"

mkdir -p "$outdir"

case "$mode" in
    gpu)
        blocker="$(gpu_blocker)"
        [ -z "$blocker" ] || skip "GPU mode requested but $blocker"
        [ -n "${EXTRAPHYSICS:-}" ] || die "EXTRAPHYSICS not set (edep-simphony-plugin not installed in env?)"
        [ -n "${PLUGIN_LIB:-}" ]   || die "PLUGIN_LIB not set (plugin setup_run_environment)"
        macro="$here/gpu.mac"; out="$outdir/gpu.root"
        # Put the driver's OptiX/CUDA-driver libs (nonstandard nvidia/current
        # path) on the loader path so optixInit() can dlopen libnvoptix.so.1.
        nvdir="$(nvoptix_dir)"
        [ -n "$nvdir" ] && export LD_LIBRARY_PATH="$nvdir:${LD_LIBRARY_PATH:-}"
        say "libnvoptix dir: ${nvdir:-<not found>}"
        # The plugin writes Simphony .npy scratch here.
        export OPTICKS_OUT_FOLD="${OPTICKS_OUT_FOLD:-$outdir/opticks_out}"; mkdir -p "$OPTICKS_OUT_FOLD"
        say "mode=gpu  EXTRAPHYSICS=$EXTRAPHYSICS"
        say "OPTICKS_INTEGRATION_MODE=${OPTICKS_INTEGRATION_MODE:-<unset>}  OPTICKS_MAX_SLOT=${OPTICKS_MAX_SLOT:-<unset>}"
        ;;
    cpu)
        # Pure Geant4: make sure the plugin does NOT load, whatever the env set.
        unset EXTRAPHYSICS PLUGIN_LIB OPTICKS_INTEGRATION_MODE OPTICKS_MAX_SLOT \
              CSGOptiX__ptxpath EDEPSIM_DOKEBIRKS_VISE
        macro="$here/cpu.mac"; out="$outdir/cpu.root"
        say "mode=cpu (Geant4 optical; plugin not loaded)"
        ;;
    *) die "unknown EDEP_SIMPHONY_MODE: $mode (expected auto|cpu|gpu)" ;;
esac

# --- run --------------------------------------------------------------------
rm -f "$out"
say "edep-sim -p $physics -g $gdml -o $out -e $nevents $(basename "$macro")"
if ! edep-sim -p "$physics" -g "$gdml" -o "$out" -e "$nevents" "$macro" > "$outdir/edep-sim.log" 2>&1; then
    tail -25 "$outdir/edep-sim.log" >&2
    die "edep-sim exited non-zero (see $outdir/edep-sim.log)"
fi
[ -s "$out" ] || { tail -25 "$outdir/edep-sim.log" >&2; die "edep-sim produced no output: $out"; }

# --- assert -----------------------------------------------------------------
if python3 "$here/assert.py" --mode "$mode" --min-hits 1 "$out"; then
    say "PASS ($mode) -> $out"
    exit 0
else
    say "FAIL ($mode) — output left for inspection: $out"
    exit 1
fi
