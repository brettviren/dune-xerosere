# edep-simphony CLI test

The `edep-sim` command-line counterpart of [`tests/edep-simphony`](../edep-simphony/)
(which runs the same physics through **phlex**). Same geometry and primary, but
driven by the `edep-sim` program, with optical-photon tracking on either
backend — this is the standalone "edep-sim + plugin" GPU test (epic ddm-p5j.6),
generalised to also run the CPU reference.

| Mode | Backend | Optical output |
|---|---|---|
| `cpu` | Geant4 tracks photons on the CPU (plugin **not** loaded) | `TG4Event.PhotonDetectors` in the `EDepSimEvents` tree |
| `gpu` | the Simphony plugin offloads photons to the GPU (OptiX) | `GPUPhotonHits` TTree (written by the plugin) |

## Files

| File | Role |
|---|---|
| `run.sh` | Driver: pick backend, run `edep-sim`, assert optical output. |
| `cpu.mac` / `gpu.mac` | edep-sim macros for the two backends. |
| `assert.py` | Mode-aware check (`PhotonDetectors` / `GPUPhotonHits`). |

The geometry is **shared** with `tests/edep-simphony`
(`../edep-simphony/geometry/benchmark_small.gdml`) so both tests exercise the
identical edep-sim configuration.

## Running

```bash
./umbrella gcc15 test edep-simphony-cli     # via the project test runner
# or standalone:
tests/edep-simphony-cli/run.sh gcc15
```

Backend selection (env `EDEP_SIMPHONY_MODE`):

- `auto` (default) — use the GPU if a usable GPU **and** OptiX runtime are
  present, otherwise fall back to CPU.
- `cpu` — always Geant4/CPU (no GPU needed).
- `gpu` — require the Simphony/GPU path; **skip** (exit 77) if the GPU or OptiX
  runtime is missing, rather than failing.

Other overrides: `EDEP_SIMPHONY_GDML`, `EDEP_SIMPHONY_NEVENTS`,
`EDEP_SIMPHONY_PHYSICS`. Output (`cpu.root` / `gpu.root`, `edep-sim.log`) goes to
`builds/envs/<env>/xerosere/edep-simphony-cli/`.

In `gpu` mode the plugin's behaviour is further governed by its own
shell-environment settings (`OPTICKS_INTEGRATION_MODE`, `OPTICKS_MAX_SLOT`,
`EDEP_SIMPHONY_*`, …), which the Spack env's `setup_run_environment` provides.

## GPU / OptiX runtime prerequisites

The `gpu` path needs a working NVIDIA GPU and the driver's OptiX loader library:

- GPU device nodes + a driver `nvidia-smi` can talk to;
- the driver's OptiX library `libnvoptix.so.1` (its absence is the
  `OPTIX_ERROR_LIBRARY_NOT_FOUND` from `optixInit()`).  On Debian this lives in
  `/usr/lib/x86_64-linux-gnu/nvidia/current/`, which is **not** on the default
  loader path — `run.sh` locates it (`nvoptix_dir`) and prepends it to
  `LD_LIBRARY_PATH` for the run.

`run.sh` probes these and, in `auto` mode, quietly falls back to CPU when
missing (reporting which).

**OptiX version must match the driver.** simphony is built against the
`optix-dev` version Spack concretizes, and its ABI must be one the installed
driver provides (see `simphony/docs/getting-started.md`): OptiX 8.1.0 needs
driver ≥ 555, OptiX 9.1.0 needs ≥ 590.  This host (driver 555.42.06) pins
`optix-dev@8.1.0` in the gcc15 env; check with
`nm -D $(spack -e extern/envs/gcc15 location -i simphony)/lib/libCSGOptiX.so | grep g_optixFunctionTable`.
