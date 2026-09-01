#!/usr/bin/env bash
#
# tests/spdir/run.sh — SPDIR island workflow (ddm-179).
#
# Runs spdir.jsonnet(.in): edp_line_gen ideal line segments -> WCT sampler ->
# COMMON drift island -> {sim+sigproc, depo-flux-splat} frame islands, tapping
# every boundary to Arrow and writing spdir.h5.  Asserts the HDF5 holds the
# sim+sigproc and splat frames (non-empty trace charge) plus the intermediate
# depo/segment products.
#
# The workflow is a token template (phlex has no TLA/ext-var support): this script
# substitutes @SP@ / @DETECTOR@ / @CENTER@ / @TOFFSET@ into spdir.jsonnet.in to produce a
# concrete spdir.jsonnet in the output directory, then runs it.
#
# Usage:
#   tests/spdir/run.sh [sp=osp] [detector=pdhd] [env=gcc15] [outdir]
#     sp       : 'osp' (OmnibusSigProc) or 'spng' (Signal Processing Next Gen)
#     detector : 'pdhd' or 'pdvd'
#
# Exit codes: 0 = pass, 1 = failure, 77 = skipped (env/build/feature not present).

set -uo pipefail

SKIP=77
name="spdir"

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[$name] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }
run()  { echo "+ $*" >&2; "$@"; }

sp="${1:-osp}"
detector="${2:-pdhd}"
env_name="${3:-gcc15}"
outdir="${4:-$root/builds/envs/$env_name/xerosere/$name}"

case "$sp" in osp|spng) ;; *) die "sp must be 'osp' or 'spng' (got '$sp')";; esac
case "$detector" in pdhd|pdvd|pdsp) ;; *) die "detector must be 'pdhd', 'pdvd' or 'pdsp' (got '$detector')";; esac

# Per-detector line center (mm), inside the detector's anode-0 drift volume, and
# BlobDepoFill time_offset (ns) aligning drifted-depo times with the splat frame's
# slice times.
#
# DepoFluxSplat places charge using depo->time() + field_response.origin/speed
# (gen/src/DepoFluxSplat.cxx), but BlobDepoFill only sees the raw drifted
# depo->time() (no knowledge of the field response origin) -- toffset must supply
# that same origin/speed term.  origin is a per-field-response-file constant
# (matches each detector's response_plane, mm): PDHD dune-garfield-1d565
# origin=100mm, PDVD protodunevd_FR_norminal_260324 origin=181mm.  origin/speed
# gives a first estimate (PDHD: 100/1.6=62500ns, close to the working 63000ns);
# empirical scans (tests/spdir, single ideal line, theta_xz in [0,89]deg) found
# each detector's non-zero-charge toffset window and this picks its midpoint:
# PDHD [62500,?] tightened to 63000 (prior calibration); PDVD scanned
# [111000,123000]ns -> 117000ns (xerosere ddm-usy).
case "$detector" in
  pdhd) center='[-1000.0, 2000.0, 1000.0]'; toffset='63000' ;;
  # PDVD (vertical drift): anode-0 active region is Y in [-3364,-6] mm,
  # Z in [0.5,1490.5] mm, drift in X from the anode (x=-3415) toward x=0.
  # Center the line well inside (face0 half: Y in [-1685,-6]).
  pdvd) center='[-1000.0, -1000.0, 745.0]'; toffset='117000' ;;
  # PDSP APA0 (n=0) face0 drift volume spans x in [-3578, -1.6] mm; z-span of the
  # first APA column is low z.  Center the 0.5 m line mid-drift in APA0.
  pdsp) center='[-1000.0, 2000.0, 1000.0]'; toffset='63000' ;;
esac

view="$root/extern/envs/$env_name/view"
install="$root/installs/envs/$env_name"
builds="$root/builds/envs/$env_name"

phlex="$view/bin/phlex"
h5ls="$view/bin/h5ls"

# --- required artifacts (skip cleanly if the env/build is not present) --------
[ -x "$phlex" ]                                              || skip "phlex not found ($phlex)"
[ -e "$builds/edep-phlex/libedp_line_gen.so" ]              || skip "edep-phlex not built ($builds/edep-phlex)"
[ -e "$builds/wire-cell-phlex/libwcph_deposet_filter.so" ]  || skip "wire-cell-phlex not built"
[ -e "$builds/wire-cell-phlex/libwcph_frame_to_cluster.so" ] || skip "charged imaging island (wcph_frame_to_cluster) not built"
[ -e "$builds/wire-cell-phlex/libwcph_frame_deposet_to_cluster.so" ] || skip "charged imaging island (wcph_frame_deposet_to_cluster) not built"
[ -e "$builds/wire-cell-phlex-arrow/libwire_cell_phlex_arrow_convert.so" ] || skip "wire-cell-phlex-arrow not built"
[ -e "$install/lib/libphlex_arrow_hdf_output.so" ]          || skip "phlex-arrow-hdf not installed"
[ -d "$root/reference/wire-cell-data" ]                     || skip "wire-cell-data not present"

# The SPNG signal-processing island is not wired yet (ddm-179 follow-on): SPNG is
# a torch/TensorSet subsystem with no phlex island config.  Skip cleanly for now.
if [ "$sp" = "spng" ]; then
    [ -e "$root/devel/wire-cell-phlex/cfg/dune/wct/job/sim-spng.jsonnet" ] \
        || skip "sp='spng' island (dune/wct/job/sim-spng.jsonnet) not yet wired (ddm-179 follow-on)"
fi

mkdir -p "$outdir"

# --- generate the concrete workflow from the token template ------------------
job="$outdir/spdir.jsonnet"
sed -e "s|@SP@|$sp|g" -e "s|@DETECTOR@|$detector|g" -e "s|@CENTER@|$center|g" -e "s|@TOFFSET@|$toffset|g" \
    "$here/spdir.jsonnet.in" > "$job"

# Phlex plugin search path: the edep-phlex, wire-cell-phlex and
# wire-cell-phlex-arrow build trees, the install lib (phlex_arrow_hdf_output) and
# the view lib (generate_layers driver + WCT plugins).
export PHLEX_PLUGIN_PATH="$builds/edep-phlex:$builds/wire-cell-phlex:$builds/wire-cell-phlex-arrow:$install/lib:$view/lib"
# Transitive shared libs for the dlopen'd modules (libedep_phlex.so lives in the
# edep-phlex build tree; edep_arrow/phlex_arrow_common in the install prefix).
export LD_LIBRARY_PATH="$builds/edep-phlex:$install/lib:$install/lib64:$view/lib:$view/lib64:${LD_LIBRARY_PATH:-}"
# WCT sub-graph configs + detector data, resolved by WCT's Main inside each island:
#   wire-cell-phlex/cfg   -> dune/wct/job/*.jsonnet, dune/wct/dets/*, tracksegmentset-sampler.jsonnet
#   reference/wire-cell-data -> field responses / wires / noise (.json.bz2)
#   share/wirecell       -> WCT built-in jsonnet library (wirecell.jsonnet, ...)
export WIRECELL_PATH="$root/devel/wire-cell-phlex/cfg:$root/reference/wire-cell-data:$root/reference/dunereco/dunereco/DUNEWireCell/protodunevd:$install/share/wirecell:$view/share/wirecell"
# Each WCT island runs the embedded go-jsonnet engine; with several islands per
# event the Go async preemption can deadlock without this.
export GODEBUG="${GODEBUG:+$GODEBUG,}asyncpreemptoff=1"

out="$outdir/spdir.h5"
rm -f "$out"

say "sp=$sp detector=$detector -> $out"
# phlex writes output_file relative to CWD; run from the output directory.
( cd "$outdir" && run "$phlex" -c "$job" ) || die "phlex run failed"

[ -f "$out" ] || die "expected output $out not produced"

say "## h5ls -r $out"
listing="$("$h5ls" -r "$out" 2>/dev/null)"
echo "$listing" >&2

have() { grep -q "$1" <<<"$listing" || die "missing $1"; }

# Both frame chains present with trace charge, plus the intermediate depo and
# segment products.  HDF path: /event/<n>/<cell>/<convert-node>/wc_<t>_to_arrow/...
have "/a_simsp/.*/frame/traces/wc.trace.charge Dataset"
have "/a_splat/.*/frame/traces/wc.trace.charge Dataset"
have "/a_sampled/.*/deposet/deposet/wc.depo.charge Dataset"
have "/a_drifted/.*/deposet/deposet/wc.depo.charge Dataset"
have "/a_segs/.*/tracksegmentset"
have "/lines/edep_line_gen/observables/segments"

# Both charged imaging products present and kept distinct (path member is 'blobs'
# under the 'cluster' product suffix: .../wc_cluster_to_arrow/cluster/blobs/...).
have "/a_img_sp/.*/blobs/wc.blob.value Dataset"
have "/a_img_splat/.*/blobs/wc.blob.value Dataset"

# Non-empty: each wc.blobs table must have > 0 blob rows (h5ls prints "{N}").
blob_rows() {
    printf '%s\n' "$listing" | grep -E "/$1/.*/blobs/wc.blob.value Dataset" | \
        grep -oE '\{[0-9]+\}' | tr -dc '0-9\n' | awk '{s+=$1} END {print s+0}'
}
# Non-zero CHARGE: the event-0 wc.blob.value dataset must contain a value != 0
# (BlobSolving / BlobDepoFill actually put charge on the blobs).  h5ls -d prints
# the Data: block; an all-zero table has no non-zero digit there.
charged() {
    local vp data
    vp="$(printf '%s\n' "$listing" | grep -oE "/event/[^ ]*/$1/[^ ]*/blobs/wc.blob.value" | head -1)"
    [ -n "$vp" ] || return 1
    # Capture first: grep -q would SIGPIPE-kill h5ls under `set -o pipefail`.
    data="$("$h5ls" -d "$out/$vp" 2>/dev/null | awk '/Data:/{d=1; next} d')"
    [[ "$data" =~ [1-9] ]]
}
n_sp="$(blob_rows a_img_sp)"; n_splat="$(blob_rows a_img_splat)"
say "blobs: SP(solve)=${n_sp:-0}  splat(depofill)=${n_splat:-0}"
[ "${n_sp:-0}"    -gt 0 ] || die "a_img_sp wc.blobs table is EMPTY (SP frame tiled no blobs)"
[ "${n_splat:-0}" -gt 0 ] || die "a_img_splat wc.blobs table is EMPTY (splat frame tiled no blobs)"
charged a_img_sp    || die "a_img_sp wc.blob.value is all zero (BlobSolving assigned no charge)"
charged a_img_splat || die "a_img_splat wc.blob.value is all zero (BlobDepoFill assigned no charge)"
say "charge present on both SP (solved) and splat (true) blobs"

say "PASS"
exit 0
