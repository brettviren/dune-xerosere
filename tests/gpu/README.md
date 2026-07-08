# GPU standalone test for edep-simphony-plugin (ddm-p5j.6)

Exercises the **Spack-installed** `edep-simphony-plugin` end-to-end at the
edep-sim level (before Phlex integration) and asserts it produced GPU optical
photon output. This is the standalone GPU proof that the plugin works on real
hardware.

## Files

| File | Role |
|---|---|
| `run.sh` | Driver: GPU gate → activate Spack env → run edep-sim → assert. |
| `plugin_gpu_test.mac` | Self-contained edep-sim macro (inlines the plugin action loading). |
| `assert_gpu_output.py` | PyROOT check: `EDepSimEvents` present + non-empty `GPUPhotonHits`. |

## Running

```bash
# A LAr optical GDML must be supplied (see "Geometry fixture" below).
PLUGIN_TEST_GDML=/path/to/lar_optical.gdml tests/gpu/run.sh
# or via the project test runner:
PLUGIN_TEST_GDML=/path/to/lar_optical.gdml ./umbrella gcc15 test gpu
```

Without `PLUGIN_TEST_GDML` the test **skips** (exit 77) rather than failing, so
it is safe under `umbrella <env> test` (run-all) until the fixture lands.

Configuration (environment variables):

| Variable | Default | Meaning |
|---|---|---|
| `PLUGIN_TEST_GDML` | *(required)* | fixture geometry (ddm-p5j.5) |
| `PLUGIN_TEST_ENV` | `gcc15` | Spack env under `extern/envs/` |
| `PLUGIN_TEST_MACRO` | `plugin_gpu_test.mac` | edep-sim macro |
| `PLUGIN_TEST_PHYSICS` | `QGSP_BERT` | Geant4 physics list |
| `PLUGIN_TEST_NEVENTS` | `5` | events to simulate |
| `PLUGIN_TEST_MIN_HITS` | `1` | min `GPUPhotonHits` entries to pass |
| `PLUGIN_TEST_OUT` | temp file | output ROOT file |

Exit codes: `0` pass, `1` failure, **`77` skipped** (no usable GPU — the
autotools "skip" convention, so CI can treat it as skipped rather than failed).

## GPU / driver / OptiX requirements

The plugin's whole purpose is GPU OptiX transport, so a working NVIDIA GPU is
mandatory. Critically, **the OptiX ABI that simphony's `libCSGOptiX.so` was
built against must be supported by the installed driver**:

- simphony must be built against **OptiX headers whose ABI the driver provides**.
- Check what simphony was built against:
  ```bash
  nm -D $(spack -e extern/envs/gcc15 location -i simphony)/lib/libCSGOptiX.so \
    | grep g_optixFunctionTable    # -> g_optixFunctionTable_<ABI>
  ```
- Confirm the driver:
  ```bash
  cat /proc/driver/nvidia/version   # NVRM version
  nvidia-smi
  ```

Record the exact GPU model, driver version, OptiX ABI, and CUDA version used
for any successful run in the ddm-p5j.6 issue.

## Geometry fixture (ddm-p5j.5)

No geometry is committed here yet. The test requires a GDML whose active LAr
volume has optical material properties (RINDEX, SCINTILLATION*, etc.) and whose
photon sensors carry a G4 SensitiveDetector (the plugin's
`LArTPCSensorIdentifier` finds them automatically). Candidates to adapt live in
`reference/simphony/tests/geom/` (e.g. `opticks_raindrop_with_scintillation.gdml`,
`8x8SiPM_w_CSI_optial_grease.gdml`). The gun position/energy in
`plugin_gpu_test.mac` must be tuned so the beam traverses the active volume.

## Current status / blockers (NOT yet validated)

Authored on `wcgpu0.phy.bnl.gov`, where it **cannot currently be run**:

1. **GPU unreachable**: no `/dev/nvidia*` device nodes and `nvidia-smi` cannot
   communicate with the driver, although the kernel module (`NVRM 555.42.06`)
   is loaded. Needs host-admin action or a different host.
2. **OptiX ABI mismatch**: the `gcc15` env concretized `optix-dev@9.1.0`, and
   `libCSGOptiX.so` exports `g_optixFunctionTable_118` (OptiX ABI 118). Driver
   555.42.06 supports OptiX 8.1.0 / ABI 93 only, so `optixInit()` will not bind
   the ABI-118 table. Reconcile by pinning `optix-dev@8.1.0` (and rebuilding
   simphony + plugin) or upgrading the host driver.

Because of these, the assertions in this harness are **defined but unverified**.
They should be confirmed on a host where the GPU is reachable and the driver
matches simphony's OptiX ABI.
