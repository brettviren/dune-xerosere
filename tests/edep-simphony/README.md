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
| `geometry/example.gdml` | Geometry fixture (see below). |

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

The test asserts the HDF5 carries the `edep.observables` TableGroup — its
`segments` member group with an Arrow schema, and the
`arrow.group.type = "edep.observables"` marker.

## Cleanup vs. the benchmark

The benchmark `run.sh` entangles the shell environment with an `OPTIC_GPU_ROOT`
checkout (via `config.sh` / `setup_env.sh`, and machine-specific install
prefixes). This version removes all of that: everything is derived from the
Spack environment and the project build tree
(`builds/envs/<env>/<pkg>` on `PHLEX_PLUGIN_PATH`, `EDEPSIM_ROOT` resolved from
the view). This is the runtime analog of the dependency-finding cleanup done in
the `edep-simphony-plugin` CMake files.

## Scope and future work

Today this covers the **observables** part of `TG4Event` (segments + photons
Arrow tables) serialized through `arrow-hdf`. With `geometry/example.gdml` and a
plain edep-sim run, the `segments` table is populated (ionisation) and the
`photons` table is present but empty.

Planned extensions (each will grow this test):

- **GenEvent serialization** — the MC-truth HepMC graph converter is future
  work; once available, this test will also persist and check it.
- **GPU optical photons** — running the edep-simphony GPU plugin inside the
  edep-sim phlex node (ddm-p5j.7) will populate the `photons` table. That also
  wants a LAr-optical geometry: the benchmark's `benchmark_ggd` gegede geometry
  (a nested-shell LAr detector with a photon-sensor surface) is the intended
  fixture, replacing `example.gdml`. It is not committed here because building
  it requires `gegede`; `example.gdml` is the dependency-free stand-in for the
  observables pipeline.
