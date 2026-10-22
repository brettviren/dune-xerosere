# Evaluation: a native WCT "wires file" exporter for duneggd/gegede

**Status:** evaluation + plan (not yet implemented). Beads: `ddm-ghm` (under epic
`ddm-xao`). Companion doc: `wct-direct-wires-component.md`.

## Goal

Make `gegede` able to emit a Wire-Cell Toolkit (WCT) *wires-schema* JSON file
directly — as a new export format `-f wcwires` — for DUNE geometries built by
`duneggd`. The output must carry the **same wire coordinates, wire idents,
channel numbers and segments that LArSoft assigns**, so the file is a drop-in
for the ones currently produced by the "long baroque" GDML→LArSoft→dump→convert
chain.

This is the generator-side analogue of the existing `wcpy util gdml-to-wires`
command (see `wire-cell-python/docs/gdml-to-wires.md`), which recovers the same
information by parsing an already-written GDML file.

## The central fact that shapes everything

**duneggd/GDML describes wire *geometry*; it does not contain channel numbers.**

The duneggd survey confirms this across every detector family:

- No builder stores a LArSoft channel number. A wire's only identity is an
  implicit loop index baked into the LArSoft-mandated volume/placement name
  (`volTPCWire{view}{idx}`, `..._{quad}`).
- The channel *numbering* is applied later by LArSoft's `geo::WireReadout*`
  class, chosen at geometry-service configuration time from the detector
  **Name** (see `gdml-to-wires.md` → "Which LArSoft class?"). The reference
  "dump loop" (`geom->PlaneWireToChannel(p,w,t,c)`) is just reading out that
  class's assignment.

Therefore a `wcwires` exporter must do two things that duneggd itself never
does:

1. **Recover the full wire geometry** (endpoints, per plane, per CRU/APA, in
   world coordinates).
2. **Reimplement the LArSoft wire-readout numbering** for the detector in
   question (`WireReadoutCRUGeom`, `CRPWireReadoutGeom`, the APA map,
   ProtoDUNE\*), i.e. the TPC sort + per-plane wire sort + channel arithmetic
   that we already reverse-engineered for `gdml-to-wires`.

In other words: **the exporter is the `gdml-to-wires` pipeline, run at
generation time against gegede's in-memory model instead of against parsed GDML
XML.** The hard, already-solved part (the numbering) is shared; only the
front-end (where wire geometry comes from) changes.

## What the two codebases give us

### gegede side (the export seam)

- An exporter is simply a module `src/gegede/export/<fmt>.py` providing
  `convert(geom) -> obj` and `output(obj, filename)` (optional `dumps`,
  `validate_object`). Selected by `-f <fmt>` → imports `gegede.export.<fmt>`.
  No registry or entry points; dropping the file is enough.
- `convert` receives the constructed `gegede.construct.Geometry` (`geom`), with
  `geom.world` (top volume name) and `geom.store` (OrderedDicts of
  shapes/structure keyed by name). It does **not** receive the builder tree.
- A wire is a `Tubs` solid: axis along local **+z**, half-length `dz`, so local
  endpoints are `(0,0,±dz)`. The exporter must **compose parent placement
  transforms itself** (gegede stores only relative placements) to get world
  endpoints. Positions/rotations are pint `Quantity`s (convert with
  `.to('mm').magnitude`); rotations follow the GDML/Geant4 convention.
- **Key limitation:** pitch/angle/plane-id/channel are **not** in `geom`. They
  live as builder attributes (lost after construction) or must be reconstructed
  geometrically — unless the builder stashes them into the Volume `params`
  (which gegede emits as GDML `<auxiliary>` and the exporter can read).

### duneggd side (where wire geometry lives)

Per-family findings (full detail in the survey; summarized here):

| Family | Wire source | Wrapping/segments | Recoverable from `geom` alone? |
|---|---|---|---|
| **FD-VD** (`dunefdvd/Wires.py`+`TPC.py`) | computed (`line_clip` clip to rectangle); params in `dunefdvd/utils/globals.py` | none (1 segment/wire) | **Yes** — U/V reconstructable from center+length+angle; Z identity from placement index |
| **ProtoDUNE-VD** (`protodunevd/tpcs.py`) | computed (`line_clip`) + `split_wires`/`flip_wires`, 4-quadrant CRP | yes (split at y=0; quadrants) | **Yes** — each wire its own solid, quad in name |
| **FD-HD / APA** (`larfd/TPCPlane.py`) | **Excel `Aran-Sheet.xlsx`** | **yes** (Front/Back segment rows) | **Partial** — segment→channel map lives only in the spreadsheet, discarded at build |
| **LArND** (`larnd/TPCPlane.py`) | uniform loop (placeholder) | none | Yes (trivial) |

Important structural facts:

- **No common base class.** `line_clip` is copy-pasted between FD-VD and PD-VD;
  larfd is spreadsheet-driven; larnd is a stub. A unified exporter needs
  **per-family adapters**.
- The richest wire data is the builders' in-memory `winfo` / `wire_configs`
  lists (they carry both endpoints). But those are **builder attributes the
  exporter cannot see** — at the GDML/`geom` level the U/V endpoints are dropped
  and only center+length+rotation survive (endpoints are still reconstructable).
- **FD-HD is the hard case:** the wire-segment→electronics-channel (wrapping)
  mapping is in Excel columns the builder *discards*. No amount of geometry
  traversal recovers it; the exporter must read the spreadsheet (or the builder
  must be changed to retain the mapping).

## Design

### Architecture

```
gegede build (duneggd builders) ──► Geometry `geom`
                                      │
                 ┌────────────────────┴───────────────────────┐
                 │  gegede.export.wcwires.convert(geom, cfg)   │
                 │                                             │
                 │  1. wire extraction  (per-family adapter)   │  ◄── geometry
                 │       → list of wires with world endpoints, │
                 │         grouped by detector/CRU/plane/view  │
                 │  2. numbering        (LArSoft class port)   │  ◄── channels
                 │       → wire ident, channel, segment        │
                 │  3. schema assembly  → WCT wires JSON        │
                 └─────────────────────────────────────────────┘
```

Steps 2 and 3 are **exactly the logic already written** in
`wire-cell-python/wirecell/util/wires/gdml.py` (the `_vdfd_*` functions for
`WireReadoutCRUGeom`, the `vd` connectivity for `CRPWireReadoutGeom`, the `hd`
path, plus `schema`/`persist`). The clean move is to **factor that numbering +
schema layer into a reusable library** that both the GDML parser and the gegede
exporter call. Only step 1 (wire extraction) is new and family-specific.

### Selecting the combination (user input)

Because duneggd can combine builders freely and because the same geometry can be
numbered by different LArSoft classes (e.g. FD-VD workspace =
`WireReadoutCRUGeom`; full FD-VD detector file = `CRPWireReadoutGeom` open-book —
see `gdml-to-wires.md`), the exporter needs an explicit **"numbering profile"**
chosen by the user, not inferred. Concretely a small config mapping:

```
profile = {
  detector_family: "fdvd" | "pdvd" | "fdhd" | "larnd",
  readout_class:   "WireReadoutCRUGeom" | "CRPWireReadoutGeom" | "APA" | ...,
  tpc_sorter:      "GeoObjectSorterCRU" | "GeoObjectSorterCRU60D" | "APA",
  wire_sorter:     "WireReadoutSorterCRU" | "CRPWireReadoutSorter" | ...,
  anode_model:     "one-face-per-CRU" | "open-book-2face",
}
```

Pass it via a CLI option or a dedicated cfg section. Default profiles per family
can be provided, but the override must exist because the class dispatch is a
LArSoft-configuration fact, not a geometry fact.

### Two routes for step 1 (wire extraction) — recommendation

**Route A — geometry reconstruction (no duneggd changes).** Traverse `geom`
top-down, compose transforms, collect every `Tubs` placement as a wire with
world endpoints, and infer plane/view/CRU grouping from the LArSoft-mandated
volume names (same role-pattern approach as `gdml-to-wires`). Works today for
FD-VD, PD-VD, LArND. *Fails for FD-HD wrapping* (channel map not in geometry).

**Route B — builder annotations (small duneggd changes).** Extend the wire
builders to stash per-wire metadata (`view`, `plane`, `cru/apa index`,
`segment`, and for HD the `channel`/segment from the Excel) into the Volume
`params` (GDML `<auxiliary>`), which the exporter can then read directly. This
removes all geometric guessing, makes HD tractable, and keeps the GDML and the
wires file provably consistent.

**Recommendation:** Route A first (it reuses `gdml-to-wires` wholesale and needs
no duneggd edits), with Route B added where Route A is insufficient —
specifically **FD-HD**, where the Excel-based wrapping map must be surfaced
(either read the spreadsheet in the exporter or annotate during build).

### Implementation plan

1. **Factor a shared numbering/schema library.** Extract the numbering engines
   and schema assembly from `gdml.py` into functions that accept a neutral
   "list of wires grouped by detector/anode/face/plane/view with world
   endpoints" and return a WCT `schema.Store`. Both `gdml-to-wires` and the new
   exporter call it. (Mostly a refactor; the engines already exist and are
   validated.)
2. **Write `src/gegede/export/wcwires.py`.** `convert(geom)` walks `geom.world`
   with composed transforms (handle `Placement`, and `Division`/`Replica`),
   collects `Tubs` placements, groups them by the role-name patterns, and calls
   the shared numbering library with the user-selected profile. `output()`
   writes JSON (mirror `ggdjson.py`; reuse `wire-cell-python`'s `persist`
   format). Note: no composed transforms are cached — multiply manually; do
   **not** dedup repeated volumes (each placement is a distinct wire).
3. **Per-family adapters.** FD-VD + PD-VD share extraction; FD-HD needs the
   Excel/annotation path; LArND is trivial. Encode default numbering profiles
   per family.
4. **Validation.** For each family, generate the geometry, export `wcwires`,
   and diff against (a) the `gdml-to-wires` output of the *same* GDML (must be
   identical), and (b) a LArSoft `FLAG` dump of the same geometry (ground truth
   for channels/endpoints). Add tests mirroring
   `test_gdml_integration_fdvd.py`.

### Effort and phasing

- **Phase 1 (FD-VD, Route A):** small. Reuses the validated `WireReadoutCRUGeom`
  port; only the gegede traversal is new. This is the natural first deliverable
  and directly serves the current FD-VD workspace work.
- **Phase 2 (PD-VD):** moderate. Needs the open-book `CRPWireReadoutGeom`
  numbering (spec exists in `gdml-to-wires.md`/beads `ddm-n7t`) plus the
  quadrant/split structure.
- **Phase 3 (FD-HD/APA):** largest. Requires the APA channel map and the
  Excel-sourced wrapping; strongly favors Route B annotations.
- **LArND:** trivial, do opportunistically.

## Trade-offs vs the current GDML-parsing path

**Pros of a gegede exporter:**
- Generated together with the GDML → provably consistent, single source of
  truth, no post-hoc XML parsing or role-regex guessing against a written file.
- The detector family/variant is known at generation time, so the numbering
  profile can be selected deterministically instead of inferred from a Name.
- Can access builder-level metadata (Route B) that is lost in the GDML.

**Cons / risks:**
- The exporter only receives `geom`, not builders, so pitch/angle/channel
  metadata is not directly available without Route B annotations.
- FD-HD's channel map lives in an Excel file outside the geometry model.
- Still must maintain a faithful reimplementation of LArSoft numbering (shared
  with `gdml-to-wires`); divergence risk if LArSoft changes.
- gegede/duneggd is itself under active adoption; the builder internals
  (`winfo` shapes, cfg knobs) may move.

## Open questions / decisions for the user

1. **Numbering profile source:** CLI option vs cfg section vs per-family
   default-with-override? (Recommend default-with-override.)
2. **Route A vs B for FD-HD:** read `Aran-Sheet.xlsx` in the exporter, or change
   the larfd builder to retain the segment→channel mapping as `params`?
3. **Where the shared numbering library lives:** keep it in `wire-cell-python`
   (import from the exporter) or vendor it into gegede/duneggd? (Recommend
   factor in `wire-cell-python`, import.)
4. **Scope/priority order of detector families** (FD-VD first is assumed).

## Relationship to the WCT C++ component (companion doc)

Both tasks need the *same* LArSoft numbering logic. The gegede exporter keeps it
in Python and writes a file; the WCT C++ component (`wct-direct-wires-component.md`)
would reimplement geometry+numbering in C++ and skip the file. The cleanest
long-term design is a **single authoritative numbering specification** reused by
both (Python for the generator/exporter, C++ for the runtime component), so the
two never diverge. Implementing the exporter first is lower-risk and immediately
useful; the C++ component is the heavier, runtime-oriented follow-on.

---

### Note for future maintainers / LLM agents

When you implement or extend this exporter, keep the numbering engine shared
with `wcpy util gdml-to-wires` (do not fork the LArSoft arithmetic), update the
per-family table above with any new detector, record which LArSoft class/sorter
each family maps to, and validate against a LArSoft `FLAG` dump of the exact
geometry. Keep this document free of absolute working-area paths; refer to
packages by their in-repo relative names.
