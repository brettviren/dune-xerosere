#!/usr/bin/env bash
#
# tests/phlex-dsl/run.sh — end-to-end check of the phlex.libsonnet DSL and the
# phlex-config typed node config.
#
# Authors a workflow with phlex.libsonnet (deposet source -> WCT deposet filter,
# a passthrough), runs it via `phlexed` (which — unlike `phlex -c` — resolves
# Jsonnet imports via -J), and asserts it runs to completion.  This exercises:
#   - the DSL emitting a valid { driver, sources, modules } object,
#   - the wcph_deposet_filter module reading its typed `phlex` block
#     (PhlexAlgorithmConfig: name/concurrency/inputs/outputs),
#   - implicit source->filter edge formation from matching product descriptors.
#
# `phlexed` is unofficial, so it is used only here (a top-level xerosere test),
# never in a package-level test.
#
# Usage (standalone or via `umbrella <env> test phlex-dsl`):
#   tests/phlex-dsl/run.sh [env] [outdir]
#
# Exit codes: 0 = pass, 1 = failure, 77 = skipped (env/build not present).

set -uo pipefail

SKIP=77
name="phlex-dsl"

here="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
root="$(cd "$here/../.." && pwd)"

say()  { echo "[$name] $*" >&2; }
skip() { say "SKIP: $*"; exit "$SKIP"; }
die()  { say "ERROR: $*"; exit 1; }
run()  { echo "+ $*" >&2; "$@"; }

env_name="${1:-gcc15}"
outdir="${2:-$root/builds/envs/$env_name/xerosere/$name}"

view="$root/extern/envs/$env_name/view"
install="$root/installs/envs/$env_name"
build="$root/builds/envs/$env_name/wire-cell-phlex"

phlexed="$install/bin/phlexed"
libsonnet="$install/share/jsonnet/phlex/phlex.libsonnet"

[ -x "$phlexed" ]                            || skip "phlexed not installed ($phlexed)"
[ -e "$libsonnet" ]                          || skip "phlex.libsonnet not installed ($libsonnet)"
[ -e "$build/libwcph_deposet_filter.so" ]    || skip "wire-cell-phlex plugins not built ($build)"
[ -d "$view/lib" ]                           || skip "environment view not built ($view)"

mkdir -p "$outdir"

# Plugins: wire-cell-phlex modules (build tree) + the phlex framework plugins
# (generate_layers driver) in the view.
export PHLEX_PLUGIN_PATH="$build:$view/lib"
# WCT sub-graph configs (deposet-passthrough.jsonnet) resolved via WIRECELL_PATH.
export WIRECELL_PATH="$root/devel/wire-cell-phlex/cfg"
export LD_LIBRARY_PATH="$build:$install/lib:$install/lib64:$view/lib:$view/lib64:${LD_LIBRARY_PATH:-}"

# -J <share/jsonnet> lets `import "phlex/phlex.libsonnet"` resolve.
if run "$phlexed" -J "$install/share/jsonnet" -c "$here/deposet-filter.jsonnet"; then
    say "PASS"
    exit 0
fi
die "phlexed run of the DSL-authored workflow failed"
