# edep-simphony-plugin → TG4Event integration: issue & suggestions

Discussion brief for the edep-simphony-plugin author and the edep-sim author.
Context: we are running edep-sim as a **Phlex data-flow node** (epic ddm-4nd) and
want the GPU optical plugin to work in that context, not only in the standalone
`edep-sim` CLI.

## The issue

The plugin was assumed to be a drop-in replacement for Geant4/CPU optical-photon
tracking. It is not equivalent in **where its output goes**.

- **Geant4/CPU photons** are recorded into the edep-sim *event data model*:
  hits land in `TG4Event.PhotonDetectors` (a `map<string, vector<TG4PhotonHit>>`)
  via the sensitive detector. This representation is **serialization-agnostic** —
  whoever persists the `TG4Event` (ROOT, or anything else) gets the photons.

- **The GPU plugin** instead writes its results straight into ROOT `TTree`s
  (`GPUPhotonHits`, `GPUPhotonTracks`, `GPUPhotonSteps`, …) that it creates by
  down-casting the active Geant4 persistency manager to
  `EDepSim::RootPersistencyManager` and calling `GetTFile()`
  (`SimphonyRunAction.cc` BeginOfRunAction). It bypasses `TG4Event` entirely.

Consequences of that coupling:

1. It hard-requires ROOT output **and** that the active persistency manager *is*
   `EDepSim::RootPersistencyManager`. If the cast fails or the file isn't open,
   the plugin logs a warning and creates **no** trees (silent no-op).
2. When edep-sim is embedded as a Phlex node, the node deliberately installs a
   **non-ROOT** persistency manager (a "summary" persistency that just fills a
   `TG4Event` and hands it to the graph). So the cast returns `nullptr`, the
   plugin produces nothing, and even if it did, nothing downstream reads a ROOT
   file — the Phlex product *is* the `TG4Event`.

In short: **the CPU path emits data (into `TG4Event`); the GPU path emits a
serialization (ROOT trees).** Only the former survives outside standalone ROOT.

## Suggested change to edep-simphony-plugin

Make the plugin deposit its detected GPU hits into the **event data model**
instead of into ROOT trees. After `G4CXOpticks::simulate()`, convert each
detected `SEvt` hit into a `TG4PhotonHit` and add it to the current event's
`TG4Event.PhotonDetectors` under a detector key (e.g. `"PhotonDetector"`).

The single most important change: **the plugin should not depend on
`EDepSim::RootPersistencyManager` / `GetTFile()` at all.** Its dependency should
be the abstract `TG4Event`, not the concrete ROOT sink. With that, the same
plugin works in both contexts unchanged:

- **standalone edep-sim** — `RootPersistencyManager` serializes the (now
  GPU-populated) `TG4Event.PhotonDetectors` to ROOT automatically; the plugin no
  longer manages its own `TTree`s;
- **Phlex node** — the summary persistency's `TG4Event` carries the GPU hits, and
  the existing observables converter turns `PhotonDetectors` into the
  `edep.observables` `photons` Arrow table with **zero** extra work.

Two ways the plugin can reach `TG4Event`:

- **(1) via the sensitive-detector hit collection** — the plugin adds synthetic
  G4 hits to the photon-detector SD's hit collection so edep-sim's *existing*
  end-of-event path turns them into `TG4PhotonHit`. Pro: **no edep-sim API
  change**; reuses the `PhotonDetectors` recording verbatim. Con: the plugin must
  fabricate G4 hits and get action ordering right (its `EndOfEventAction` must
  populate the collection before edep-sim builds the summary — this interacts
  with the external-action ordering already being addressed in ddm-p5j.3).

- **(2) via a small edep-sim API** — `EDepSim::PersistencyManager` (or the event
  action) exposes a hook to append `TG4PhotonHit`s to the in-flight `TG4Event`.
  The plugin calls it after `simulate()`. Pro: explicit, decoupled from
  hit-collection timing. Con: needs an edep-sim change (small and general —
  useful to any external optical-photon source).

## If/how TG4Event and EDepSim::PersistencyManager need to change

- **`TG4Event` (data model): no schema change needed for the core case.**
  `PhotonDetectors` already holds `TG4PhotonHit` keyed by SD name, and
  `TG4PhotonHit` carries `Start` / `Stop` (`TLorentzVector` = position + time),
  `PrimaryId`, `Process`, and `EnergyDeposit`. A detected GPU hit maps cleanly
  (wavelength ↔ photon energy via `E[eV] = 1239.84 / λ[nm]`). If the GPU hit must
  also carry fields `TG4PhotonHit` lacks (e.g. an Opticks flag/fate), that is the
  only reason to consider extending `TG4PhotonHit`.

- **`EDepSim::PersistencyManager`:**
  - Under option (1): **no change**, but the persistency/user-action ordering
    must allow an external action to add to the hit collection before the summary
    is built (the ddm-p5j.3 change moves the external-action loop earlier and is
    aligned with this).
  - Under option (2): add a **public hook** to append photon hits to the current
    `TG4Event` — a small, general API, independent of the output format.

## Out of scope for the core integration

The plugin currently also emits richer debug output — `GPUPhotonTracks` /
`GPUPhotonSteps` (per-photon fate + full trajectory) — which has no home in
`TG4PhotonHit`. Mapping **detected** GPU hits into `PhotonDetectors` is the
symmetric, minimal integration (it matches exactly what the CPU path produces).
If the richer per-photon debug data must also flow through Phlex, that is a
separate Arrow side-table design, not part of getting the plugin to work as a
node.

## One-line recommendation

Decouple the plugin from `RootPersistencyManager`; have it write detected hits
into `TG4Event.PhotonDetectors` (preferably via a small edep-sim append hook, or
via the SD hit collection). No `TG4Event` schema change is required for detected
hits.
