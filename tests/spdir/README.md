# tests/spdir — SPDIR island workflow

A Phlex reimplementation of the first stage of the legacy `spdir` (signal-processing
direction) metrics chain
(`devel/wire-cell-toolkit/test/scripts/spdir`), built from **WCT "islands"**
connected through **Arrow** data products so every intermediate can be persisted.

This stage produces, per ionization-line direction, the two frames that the SPDIR
metrics compare: the **sim + signal-processing** frame and the **DepoFluxSplat
"true"** frame — sharing a common upstream sampling + drift. The metric
calculation, summary statistics and plots are follow-on work (bd `ddm-179`).

## Graph

```
edp_line_gen (source)              ideal line segments   → edep.observables (Arrow)
  → wire_cell_phlex_arrow_edep_segments   Arrow → WCT TrackSegmentSet
  → wcph_tracksegmentset_to_deposet       sample depos (quanta mode) → DepoSet   [SAMPLED]
  → wcph_deposet_filter  (COMMON drift)   WCT drift              → DepoSet        [DRIFTED]
      ├→ wcph_deposet_to_frame  (sim+sigproc, input='drifted')  → Frame          [SIM+SP]
      └→ wcph_deposet_to_frame  (splat "true", input='drifted') → Frame          [SPLAT]
```

The WCT products flow island→island in memory; **every boundary is tapped** by a
`wire_cell_phlex_arrow_convert` node and written by `phlex_arrow_hdf_output`, so
`spdir.h5` holds all six products per event (matching the tapping pattern of
`devel/wire-cell-phlex-arrow/test/smoke-efield-quanta-pdhd.jsonnet`):

| Product (Arrow)        | Creator node | HDF group (per event/cell)              |
|------------------------|--------------|-----------------------------------------|
| `edep.observables`     | `lines`      | `lines/edep_line_gen/observables/segments` |
| `wc.tracksegmentset`   | `a_segs`     | `a_segs/.../tracksegmentset`            |
| `wc.deposet` (sampled) | `a_sampled`  | `a_sampled/.../deposet`                 |
| `wc.deposet` (drifted) | `a_drifted`  | `a_drifted/.../deposet`                 |
| `wc.frame` (sim+SP)    | `a_simsp`    | `a_simsp/.../frame/traces`              |
| `wc.frame` (splat)     | `a_splat`    | `a_splat/.../frame/traces`              |

The `simsp` and `splat` islands consume the **same** drifted-depo product from the
common drift island: their `wct_tla.input='drifted'` makes each skip its own
internal `DepoSetDrifter`, so drift happens exactly once.

## Design notes

- **Detector: pdhd APA0.** The DUNE detectors configured in this tree are `pdhd`
  and `pdvd` (`devel/wire-cell-phlex/cfg/dune/wct/dets.jsonnet`); the legacy spdir
  used `pdsp`, which has no island config here yet. The line `center` is chosen
  inside APA0's face-0 drift volume.
- **Ideal lines → quanta sampling.** `edp_line_gen` segments carry `n_electrons`
  directly (`density·length`), so the sampler runs in `ionization='quanta'` mode
  (no recombination model).
- **Common-drift split.** The stock `sim-sigproc.jsonnet` and `splat.jsonnet`
  island configs bundle a `DepoSetDrifter`. To make drift a single shared island,
  those two configs gained a backward-compatible `input='drifted'` mode (skip the
  internal drifter); the common drift island is `dune/wct/job/drift.jsonnet` with
  `input='deposet'`.
- **OSP → SPNG.** Swapping OmnibusSigProc for SPNG later is a change of the
  `simsp` island's `wct_config` only; the rest of the graph is unaffected.
- **Coupling.** Islands pass WCT products in memory with Arrow taps at each
  boundary (the reference-smoke pattern). A stricter "Arrow as the transport"
  variant — inserting `wire_cell_phlex_arrow_from_arrow` between islands so a stage
  reads its input back from Arrow — is a per-hop addition if full job-splitting is
  wanted later.

## Running

```bash
tests/spdir/run.sh [sp=osp] [detector=pdhd] [env=gcc15] [outdir]
```

- `sp` — signal processing: `osp` (OmnibusSigProc) or `spng` (Signal Processing
  Next Gen). Only the `simsp` island's `wct_config`+plugins change; the OSP→SPNG
  swap is a one-line island-config selection. **`spng` is not yet wired** (SPNG is
  a torch/TensorSet subsystem with no phlex island config); it skips cleanly (exit
  77) until `dune/wct/job/sim-spng.jsonnet` exists (ddm-179 follow-on).
- `detector` — `pdhd` or `pdvd`.

`spdir.jsonnet.in` is a token template (`@SP@`/`@DETECTOR@`/`@CENTER@`); the script
substitutes it (phlex has no TLA/ext-var support) into `<outdir>/spdir.jsonnet` and
runs that, writing `<outdir>/spdir.h5`. It asserts both frame chains and the
intermediate depo/segment products are present and non-empty. Exit codes: 0 pass,
1 fail, 77 skipped. Sets `PHLEX_PLUGIN_PATH`, `WIRECELL_PATH`, `LD_LIBRARY_PATH`
and `GODEBUG=asyncpreemptoff=1` (needed when several WCT islands run per event).

Requires the `edep-phlex`, `wire-cell-phlex` and `wire-cell-phlex-arrow` build
trees, the install prefix (`phlex_arrow_hdf_output`), and
`reference/wire-cell-data`.

## Metrics

`python/wct-metrics` reads `spdir.h5` directly and produces the SPDIR
efficiency/bias/resolution metrics + a multi-page PDF:

```bash
cd python/wct-metrics && uv run wct-metrics spdir <outdir>/spdir.h5 -o spdir.pdf
```
