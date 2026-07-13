#!/usr/bin/env bash
#
# tests/edep-simphony/run.sh — phlex analog of the edep-simphony-benchmark
# run.sh.  Runs the workflow
#
#   hmp_gen_event_gun -> esp_tracking -> esp_observables -> phlex_arrow_hdf_output
#
# and asserts the produced HDF5 file carries the `edep.observables` TableGroup.
#
# Cleaned up vs. the benchmark: NO OPTIC_GPU_ROOT / setup_env.sh / config.sh.
# Everything is derived from the Spack environment and the project build tree,
# analogous to the edep-simphony-plugin CMake cleanup.
#
# Usage (standalone or via `umbrella <env> test edep-simphony`):
#   tests/edep-simphony/run.sh [env] [outdir]
#     env     Spack environment name under extern/envs/   (default: gcc15)
#     outdir  output directory  (default: builds/envs/<env>/xerosere/edep-simphony)
#
# Optional overrides:
#   EDEP_SIMPHONY_GDML       geometry GDML   (default: geometry/benchmark_small.gdml)
#   EDEP_SIMPHONY_NEVENTS    number of events (default: 2)
#
# Exit codes: 0 = pass, 1 = failure, 77 = skipped (env/build not present).

set -uo pipefail

SKIP=77
name="edep-simphony"

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[$name] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }

env_name="${1:-gcc15}"
outdir="${2:-$root/builds/envs/$env_name/xerosere/$name}"
view="$root/extern/envs/$env_name/view"

# --- prerequisites (missing build tree -> skip, not fail) -------------------
[ -x "$view/bin/phlex" ] || skip "phlex not found in $view/bin (env '$env_name' not built?)"
builds="$root/builds/envs/$env_name"
for p in hepmc-phlex edep-sim-phlex phlex-arrow-hdf; do
    [ -d "$builds/$p" ] || skip "phlex plugin build missing: $builds/$p (run 'umbrella $env_name build')"
done

# --- runtime environment (no OPTIC_GPU_ROOT) --------------------------------
# phlex loads the node plugins by name from PHLEX_PLUGIN_PATH; they live in the
# per-package build dirs plus the Spack view (for phlex core + shared deps).
export PHLEX_PLUGIN_PATH="$builds/hepmc-phlex:$builds/edep-sim-phlex:$builds/phlex-arrow-hdf:$view/lib:$root/installs/envs/$env_name/lib"
export LD_LIBRARY_PATH="$PHLEX_PLUGIN_PATH:${LD_LIBRARY_PATH:-}"
export PATH="$view/bin:$PATH"   # phlex, h5ls
# edep-sim resources: resolve the exact edepsim prefix the node links (via the
# view symlink), rather than globbing (there may be several edepsim installs).
edepsim_lib="$(readlink -f "$view/lib/libedepsim.so" 2>/dev/null || true)"
[ -n "$edepsim_lib" ] || die "cannot resolve edepsim via $view/lib/libedepsim.so"
export EDEPSIM_ROOT="${edepsim_lib%/lib/libedepsim.so}"

# --- inputs -----------------------------------------------------------------
gdml="${EDEP_SIMPHONY_GDML:-$here/geometry/benchmark_small.gdml}"
[ -f "$gdml" ] || die "geometry not found: $gdml"
nevents="${EDEP_SIMPHONY_NEVENTS:-2}"

# --- assemble the run directory ---------------------------------------------
mkdir -p "$outdir"
out_h5="$outdir/observables.h5"
rm -f "$out_h5"
# params.libsonnet carries the run-specific values into the committed workflow;
# both files must sit together so phlex's jsonnet `import` resolves.
cat > "$outdir/params.libsonnet" <<EOF
{
  gdml: '$gdml',
  nevents: $nevents,
  output_file: '$out_h5',
}
EOF
cp "$here/edep-simphony.jsonnet" "$outdir/edep-simphony.jsonnet"

# --- run --------------------------------------------------------------------
say "env=$env_name  nevents=$nevents"
say "gdml=$gdml"
say "outdir=$outdir"
log="$outdir/phlex.log"
if ! ( cd "$outdir" && phlex -c edep-simphony.jsonnet ) > "$log" 2>&1; then
    say "phlex failed; tail of $log:"; tail -20 "$log" >&2
    die "phlex exited non-zero"
fi

# --- assert -----------------------------------------------------------------
[ -f "$out_h5" ] || { tail -20 "$log" >&2; die "no HDF5 output produced: $out_h5"; }
listing="$(h5ls -r "$out_h5" 2>/dev/null)"

# Sum the rows of a given observables column across all event cells, from the
# "Dataset {N}" dimensions in the h5ls listing.
count_rows() {
    grep -oE "$1 Dataset \{[0-9]+\}" <<<"$listing" \
        | grep -oE '\{[0-9]+\}' | tr -dc '0-9\n' | awk '{s+=$1} END{print s+0}'
}

problems=()
# The observables TableGroup was serialized: its member groups with an Arrow
# schema blob must be present under an event data cell.
grep -qE '/segments .*Group'          <<<"$listing" || problems+=("no observables 'segments' group in HDF5")
grep -qE '/segments/__arrow_schema__' <<<"$listing" || problems+=("segments group has no __arrow_schema__")
grep -qE '/photons .*Group'           <<<"$listing" || problems+=("no observables 'photons' group in HDF5")
# Type marker confirms it is the edep.observables product.
marker="$(h5dump -N 'arrow.group.type' "$out_h5" 2>/dev/null || true)"
grep -q '"edep.observables"' <<<"$marker" || problems+=("arrow.group.type marker != edep.observables")

# Both observable tables must carry data: segments (ionisation) and photons
# (scintillation reaching the photon-detector shell).
seg_rows="$(count_rows '/segments/energy_deposit')"
pho_rows="$(count_rows '/photons/energy')"
[ "$seg_rows" -gt 0 ] || problems+=("segments table is empty (no ionisation recorded)")
[ "$pho_rows" -gt 0 ] || problems+=("photons table is empty (no photon-detector hits — optical tracking off or geometry has no photon detector)")

if [ "${#problems[@]}" -ne 0 ]; then
    say "FAIL:"; for p in "${problems[@]}"; do say "  - $p"; done
    say "h5ls -r $out_h5:"; echo "$listing" | sed 's/^/    /' >&2
    exit 1
fi

say "PASS: edep.observables serialized to $out_h5"
say "segments rows=$seg_rows  photons rows=$pho_rows  (across $(grep -cE '/segments .*Group' <<<"$listing") event(s))"
exit 0
