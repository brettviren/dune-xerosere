# edep-simphony phlex test

A phlex-workflow analog of the `edep-simphony-benchmark` `run.sh`. Where the
benchmark drives the `edep-sim` command-line program and writes a ROOT file,
this drives **phlex** with the data-flow graph we are developing and writes an
**Arrow → HDF5** file.

```
hmp_gen_event_gun (hepmc-phlex)      one primary/event as a HepMC3::GenEvent
  -> esp_tracking (edep-sim-phlex)   edep-sim/Geant4 -> TG4Event
    -> esp_observables (edep-sim-phlex) TG4Event -> edep.observables TableGroup
      -> phlex_arrow_hdf_output (phlex-arrow-hdf) -> HDF5
```

## Files

| File | Role |
|---|---|
| `run.sh` | Driver: sets up the runtime env, runs `phlex`, asserts the HDF5. |
| `edep-simphony.jsonnet` | The phlex workflow (imports `params.libsonnet`). |
| `geometry/benchmark_small.gdml` | Committed geometry fixture (see below). |
| `geometry/benchmark_ggd/` | The gegede generator the fixture is built from. |
| `geometry/build_small_gdml.sh` | Regenerates `benchmark_small.gdml` (needs gegede). |

`params.libsonnet` and the copied workflow are generated into the output
directory by `run.sh` — the committed jsonnet stays parameter-free.

## Running

```bash
./umbrella gcc15 test edep-simphony      # via the project test runner
# or standalone:
tests/edep-simphony/run.sh gcc15
```

Output goes to `builds/envs/<env>/xerosere/edep-simphony/`:
`observables.h5`, `phlex.log`, and the resolved workflow. Overrides:
`EDEP_SIMPHONY_GDML`, `EDEP_SIMPHONY_NEVENTS`.

The test asserts the HDF5 carries the `edep.observables` TableGroup with the
`arrow.group.type = "edep.observables"` marker and **both** member tables
non-empty: `segments` (ionisation) and `photons` (scintillation photons that
reached the photon-detector shell).

## Cleanup vs. the benchmark

The benchmark `run.sh` entangles the shell environment with an `OPTIC_GPU_ROOT`
checkout (via `config.sh` / `setup_env.sh`, and machine-specific install
prefixes). This version removes all of that: everything is derived from the
Spack environment and the project build tree
(`builds/envs/<env>/<pkg>` on `PHLEX_PLUGIN_PATH`, `EDEPSIM_ROOT` resolved from
the view). This is the runtime analog of the dependency-finding cleanup done in
the `edep-simphony-plugin` CMake files.

## Geometry fixture

`geometry/benchmark_small.gdml` is a **20 cm LAr cube** variant of the
`edep-simphony-benchmark` optical geometry (`benchmark_ggd`): the same LAr
scintillator, WLS shells, and an outer 100%-efficiency photon-detector shell
carrying edep-sim's `SurfaceDetector` aux tag (→ `TG4Event.PhotonDetectors` →
the `photons` table).  The benchmark's own geometry is DUNE-scale
(60 × 13.5 × 13 m) and only tractable on the GPU; the small cube keeps CPU
optical tracking fast (~1 s / event).

It is committed so the test needs no `gegede` at run time.  Regenerate it with
`geometry/build_small_gdml.sh` (installs `gegede` from git into a throwaway
venv).

## Scope and future work

Today this covers the **observables** part of `TG4Event` (segments + photons
Arrow tables) serialized through `arrow-hdf`.  Photons are produced by **CPU**
optical tracking (the workflow enables `setStackPhotons`).

Planned extensions (each will grow this test):

- **GenEvent serialization** — the MC-truth HepMC graph converter is future
  work; once available, this test will also persist and check it.
- **GPU optical photons** — running the edep-simphony GPU plugin inside the
  edep-sim phlex node (ddm-p5j.7) will fill `photons` from the GPU path instead
  of CPU tracking, and is where this test meets the GPU standalone test in
  `tests/gpu/`.
