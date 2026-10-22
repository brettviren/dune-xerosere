# Evaluation: a WCT C++ component that populates the IWire/IChannel graph directly

**Status:** evaluation + plan (not yet implemented). Beads: `ddm-kdr` (under epic
`ddm-xao`). Companion doc: `duneggd-wcwires-export.md`.

## Goal

Replace the current "read a wires file" step in WCT with a C++ component that
builds the wire/channel geometry **algorithmically, in-process**, from a compact
set of detector parameters — so WCT can construct its `IWire`/`IChannel`/
`IAnodePlane` object graph for a DUNE detector without shipping or iterating a
`wires.json.bz2` file, while still matching LArSoft's wire/channel numbering
exactly.

## Current ingestion path (what we are replacing)

```
wires file (.json.bz2)
  │  WireSchema::load()                 util/src/WireSchema.cxx
  ▼
WireSchema::Store  (StoreDB: Detector/Anode/Face/Plane/Wire + inline points)
  │  wrapped by Gen::WireSchemaFile     gen/src/WireSchemaFile.cxx   (an IWireSchema)
  ▼
IWireSchema::wire_schema_store()        iface/.../IWireSchema.h      ◄── THE SEAM
  │  Gen::AnodePlane::configure()       gen/src/AnodePlane.cxx
  ▼
SimpleWire / SimpleChannel / WirePlane / AnodeFace → IAnodePlane graph
```

The decisive finding: **`AnodePlane` never touches a file.** It resolves an
`IWireSchema` component by `type:name` and calls `wire_schema_store()`, then
consumes a `WireSchema::Store`. Everything downstream — the `IChannel` graph,
the WAN `index`, the channel→wires grouping, the plane→channels lists — is
**derived** from two per-wire integer fields (`channel`, `segment`) plus
wire-in-plane (WIP) order. In particular:

- Channel ident is taken **verbatim** from `WireSchema::Wire::channel`
  (`AnodePlane.cxx` wire loop); not recomputed.
- Segment is taken **verbatim** from `WireSchema::Wire::segment`; multi-segment
  wires are grouped into one `SimpleChannel` (sorted by segment).
- `IWire::index` is the plane loop counter (so `plane.wires` **must** be in WIP
  order); `IChannel::index` (WAN) is computed as the running count of segment-0
  wires.

**Consequence: the seam is the `IWireSchema` interface, nothing deeper.** A
file-free provider is a drop-in — no `AnodePlane` change at all.

## Design

### The component

```cpp
class DirectWireSchema : public IWireSchema, public IConfigurable {
public:
  // IConfigurable
  WireCell::Configuration default_configuration() const override;
  void configure(const WireCell::Configuration& cfg) override;
  // IWireSchema
  const WireSchema::Store& wire_schema_store() const override { return m_store; }
private:
  WireSchema::Store m_store;   // built in configure()
};
WIRECELL_FACTORY(DirectWireSchema, ..., IWireSchema, IConfigurable)
```

`configure()` builds a `WireSchema::StoreDB` (the five flat vectors
`detectors/anodes/faces/planes/wires`, wires carrying `{ident, channel, segment,
tail, head}`) and wraps it: `Store(make_shared<StoreDB>(...))`. Then WCT config
simply points `AnodePlane.wire_schema` at `DirectWireSchema:<name>` instead of
`WireSchemaFile:<name>`. **That is the entire integration change.**

### What `configure()` must compute

Two layers, the same two as the gegede exporter (`duneggd-wcwires-export.md`):

1. **Wire geometry** — per CRU/APA, per plane, generate wire endpoints on the
   detector's pitch/angle grid clipped to the active rectangle, then place each
   CRU/APA at its world position. This is a C++ port of the duneggd wire-layout
   math (the `line_clip` VD algorithm; the APA/wrapped layout for HD). WCT
   already has a helper, `WireSchema::generate(store, plane, pitch, bounds, wid)`
   (`WireSchema.h`/`.cxx`), that fills a plane's wires from a pitch ray + bounds
   — usable for the simple planes, but it sets `channel=segment=0`, so
   numbering is still ours to do.

2. **Numbering** — reproduce the LArSoft `WireReadout*` assignment: TPC sort +
   per-plane wire sort + channel arithmetic, writing each wire's `channel` and
   `segment`. This is a C++ port of the engines validated in `gdml-to-wires`
   (`WireReadoutCRUGeom` hierarchical; `CRPWireReadoutGeom` shared/open-book; the
   APA map). See `wire-cell-python/docs/gdml-to-wires.md` and beads `ddm-n7t`
   for the exact algorithms.

### Honoring WCT Store conventions (important)

`WireSchemaFile` runs `WireSchema::load`'s **correction passes**
(`plane_fixer_order/direction/pitch`) which a hand-built Store does **not** get
automatically. `AnodePlane` relies on them:

- `plane.wires` must be in **WIP order** (the loop index becomes `IWire::index`;
  pitch min/max come from `wires[0]`/`wires[nwires-1]`).
- Wire direction / pitch conventions (W = P × X; tail→head ordering) must hold
  or `Pimpos`/RayGrid geometry is wrong.
- Faces front/back ordered; planes U/V/W ordered.

The component must either emit already-corrected geometry or run the same
correction/validation (`WireSchema::validate(store)` exists). This is a real but
bounded constraint.

### Configuration

```jsonnet
{
  type: "DirectWireSchema",
  name: "fdvd",
  data: {
    detector: "fdvd",            // selects geometry + numbering family
    variant:  "1x8x14",          // size/workspace knob
    readout:  "WireReadoutCRUGeom",  // numbering profile (see companion doc)
    // optional explicit geometry params (pitch/angle/active area/CRU grid),
    // else defaults per detector
  }
}
```

The `detector`/`readout` selection is the same "numbering profile" idea as the
exporter: the LArSoft class is a configuration fact and must be selectable.

## What it would take (scope)

This is a **larger lift than the gegede exporter**, because the C++ component
must own *both* layers (geometry generation **and** numbering) in C++, whereas
the exporter reuses duneggd for geometry and the existing Python numbering:

- **Port the numbering engines to C++.** The algorithms are small and fully
  specified/validated (CRU hierarchical, CRP open-book, APA). Moderate effort,
  low risk — they are pure integer/geometry logic.
- **Port the wire-layout generation to C++.** The VD `line_clip` grid is simple.
  The **APA/HD wrapped layout is the hard part** — in duneggd it is sourced from
  an Excel spreadsheet, not an analytic generator, so either (a) bake the
  resulting per-wire endpoints + segment/channel map into a compact data table
  compiled into the component, or (b) implement an analytic APA wrap generator
  (larfd's `WirePoints.py` is a legacy analytic attempt worth studying). This is
  the main cost/risk.
- **CRU/APA world placement.** Port the cryostat placement loops (grid, gaps,
  mirrored drift) from duneggd, parameterized by the `variant` knob.
- **Corrections/validation** to satisfy AnodePlane's WIP/direction assumptions.
- **Build-system plumbing** (new component in `gen` or a new sub-package;
  `WIRECELL_FACTORY` registration; tests).

### Effort and phasing

- **Phase 1 — FD-VD only, parameters-in, geometry+numbering in C++.** Reuses the
  validated `WireReadoutCRUGeom` logic and the simple VD grid. This proves the
  seam end-to-end (AnodePlane fed with no file) and covers the current FD-VD
  interest. Small-to-moderate.
- **Phase 2 — ProtoDUNE-VD / open-book CRP numbering.** Moderate.
- **Phase 3 — FD-HD / APA wrapped.** Largest; needs the APA map and wrap
  geometry (data-table or analytic). Decide table-vs-analytic early.

## Trade-offs

**Pros:**
- No wires files to generate, ship, version, or load; geometry defined by a few
  parameters. Smaller artifacts, simpler deployment.
- Fast, in-process; no bz2/JSON parse.
- A single parameterized component can cover many variants (1x8x6, 1x8x14, full
  detector) by config, instead of one file per variant.
- Natural home for a WCT-blessed, authoritative DUNE geometry.

**Cons / risks:**
- Must port and **maintain** both geometry generation and LArSoft numbering in
  C++ — duplication of logic that also lives in Python (`gdml-to-wires`) and in
  duneggd. Divergence risk if any of LArSoft / duneggd / the wires schema change.
- The APA/HD wrapped layout is genuinely hard to reproduce analytically (Excel
  provenance).
- Loses the "the file was produced by the same chain LArSoft uses" audit trail;
  correctness now rests entirely on our reimplementation (mitigated by
  validating against LArSoft `FLAG` dumps and existing reference wires files).
- Any geometry bug is now a code change + rebuild rather than regenerating a file.

### Validation strategy

For each detector/variant, build the Store two ways — this component and the
existing `WireSchemaFile` reading the blessed wires file — and assert the two
`WireSchema::Store`s are identical (same per-wire `ident`/`channel`/`segment`/
endpoints, same plane WIP order). Cross-check against a LArSoft `FLAG` dump of
the matching geometry. Reuse the same ground truth as `gdml-to-wires`.

## Relationship to the gegede exporter (companion doc)

The two deliverables share the **numbering** logic and much of the **geometry
generation** logic. The difference is packaging and timing:

| | gegede `wcwires` exporter | WCT `DirectWireSchema` component |
|---|---|---|
| Language | Python | C++ |
| Geometry source | duneggd builders (reused) | ported into C++ |
| Numbering | reuse `gdml-to-wires` engine | port engine to C++ |
| Output | a wires file (still a file) | in-memory `Store`, no file |
| Integration | new gegede export module | new `IWireSchema` provider |
| Lift | smaller | larger |

**Recommended sequencing:** do the gegede exporter first (lower risk, reuses the
validated Python engine, immediately replaces the baroque chain). Then, if a
file-free runtime path is wanted, build `DirectWireSchema`, ideally driven by a
**single authoritative numbering specification** shared with the Python side so
the two cannot diverge. One concrete option to avoid double-maintenance: define
the numbering once in C++ (inside WCT) and expose a thin Python binding that the
exporter and `gdml-to-wires` call — but that couples the Python tooling to a WCT
build, so weigh it against keeping the Python engine canonical and treating the
C++ port as a validated mirror.

## Open questions / decisions for the user

1. **Is the primary motivation** eliminating file management, runtime speed, or a
   single authoritative in-WCT geometry? (Shapes how much to invest and whether
   Phase 3 is in scope.)
2. **Where does the authoritative numbering live** long-term — canonical in
   Python (C++ mirrors it) or canonical in C++ (Python binds it)?
3. **APA/HD wrap:** compiled data table vs analytic generator?
4. **Scope:** FD-VD-only component (small, high value now) vs all-families
   (large). Recommend starting FD-VD-only to prove the seam.

---

### Note for future maintainers / LLM agents

The integration seam is `IWireSchema::wire_schema_store()`; do not add file
logic to `AnodePlane`. Keep the numbering engine identical to the one used by
`wcpy util gdml-to-wires` (share or mirror, never fork). A hand-built
`WireSchema::Store` must satisfy the loader's correction invariants (WIP order,
direction/pitch, face/plane order) — run `WireSchema::validate` and the
correction passes. Validate every detector/variant against both the blessed
wires file and a LArSoft `FLAG` dump. Keep this document free of absolute
working-area paths; refer to packages by their in-repo relative names.
