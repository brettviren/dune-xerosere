#!/usr/bin/env bash
#
# tests/spdir/run-bee.sh — SPDIR workflow -> Bee point-cloud zip (ddm-3bu.14).
#
# Chains tests/spdir/run.sh (produce spdir.h5 with charged 3D-imaging blobs and
# the sampled depos) then `wct-metrics bee` to write a Bee upload zip holding,
# per event, three point-cloud datasets: the true sampled depos, the sampled SP
# blobs and the sampled splat "true" blobs.  Upload the zip at the Bee display:
#   https://bnlif.github.io/wire-cell-docs/viz/uploads/
#
# Usage:
#   tests/spdir/run-bee.sh [sp=osp] [detector=pdhd] [env=gcc15] [outdir]
#
# Env vars (all optional):
#   BEE_POINTS  points sampled per blob            (default 10)
#   BEE_EVENTS  comma-separated event names, e.g. "0,1,2" (default: all events)
#   BEE_OUTPUT  output zip path                    (default: <outdir>/spdir-bee.zip)
#   BEE_REUSE   if set and spdir.h5 already exists, skip re-running the workflow
#
# Exit codes: 0 = pass, 1 = failure, 77 = skipped (env/build/feature not present).

set -uo pipefail

SKIP=77
name="spdir-bee"

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[$name] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }

sp="${1:-osp}"
detector="${2:-pdhd}"
env_name="${3:-gcc15}"
outdir="${4:-$root/builds/envs/$env_name/xerosere/spdir}"

h5="$outdir/spdir.h5"
zip="${BEE_OUTPUT:-$outdir/spdir-bee.zip}"
points="${BEE_POINTS:-10}"

# --- 1. Produce spdir.h5 (charged blobs + sampled depos) ---------------------
if [ -n "${BEE_REUSE:-}" ] && [ -s "$h5" ]; then
    say "reusing existing $h5 (BEE_REUSE set)"
else
    say "running SPDIR workflow: run.sh $sp $detector $env_name"
    "$here/run.sh" "$sp" "$detector" "$env_name" "$outdir"
    rc=$?
    [ "$rc" -eq "$SKIP" ] && skip "SPDIR workflow skipped (env/build not present)"
    [ "$rc" -eq 0 ]       || die  "SPDIR workflow failed (rc=$rc)"
fi
[ -s "$h5" ] || die "no $h5 produced"

# --- 2. Locate a wct-metrics runner ------------------------------------------
pkg="$root/python/wct-metrics"
[ -d "$pkg" ] || skip "wct-metrics package not found ($pkg)"
if [ -x "$pkg/.venv/bin/wct-metrics" ]; then
    wctm=("$pkg/.venv/bin/wct-metrics")
elif command -v uv >/dev/null 2>&1; then
    wctm=(uv run --project "$pkg" wct-metrics)
else
    skip "no wct-metrics runner (neither $pkg/.venv nor uv on PATH)"
fi

# The CLI imports matplotlib at load; give it a writable config dir (harmless
# where the default already is writable).
export MPLCONFIGDIR="${MPLCONFIGDIR:-$outdir/mpl}"
mkdir -p "$MPLCONFIGDIR"

# --- 3. Write the Bee zip ----------------------------------------------------
ev_opt=()
[ -n "${BEE_EVENTS:-}" ] && ev_opt=(--events "$BEE_EVENTS")

say "writing Bee zip -> $zip (points/blob=$points${BEE_EVENTS:+, events=$BEE_EVENTS})"
rm -f "$zip"
"${wctm[@]}" bee "$h5" -o "$zip" -n "$points" "${ev_opt[@]}" || die "wct-metrics bee failed"
[ -s "$zip" ] || die "no Bee zip produced"

say "PASS -> $zip"
say "upload it at https://bnlif.github.io/wire-cell-docs/viz/uploads/"
exit 0
