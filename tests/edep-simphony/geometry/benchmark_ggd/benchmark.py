"""
Benchmark geometry in gegede.

A rectangular liquid-argon volume of 60 m x 13.5 m x 13 m (active mass 14.7 kt
at rho_LAr = 1.396 g/cc), enclosed by three nested optical layers:

    1. 200 um  para-terphenyl (pTP) wavelength-shifting layer   (innermost shell)
    2. 6 mm    TPB-doped acrylic wavelength-shifting layer       (middle shell)
    3. 1 mm    outer photon-detector shell                       (outer shell)

The outer shell is an idealized photon-counting boundary: 100% detection
efficiency over the full optical band (a SurfaceDetector with REFLECTIVITY=0,
EFFICIENCY=1), not a model of any specific photon detector.

Geometry is built as concentric boxes (Geant4 mother/daughter hierarchy):

    World
     └─ detector shell   (Silicon, sensitive)      half = LAr/2 + 200um + 6mm + 1mm
         └─ TPB acrylic   (bluewlsacrylic)          half = LAr/2 + 200um + 6mm
             └─ pTP layer  (pTP)                     half = LAr/2 + 200um
                 └─ active LAr (G4_lAr, scintillator) half = LAr/2

Material physics (RINDEX, scintillation, WLS, *CONSTANT etc.) is reused from
the light_trap_ggd lighttrap package so the CPU and GPU-plugin yield models
agree, exactly as in that test.

Run:  python build_geo.py   ->  benchmark.gdml
"""

import gegede.construct as construct
from gegede.export import gdml as gdml_mod

# ── reuse the validated material/surface physics from the local lighttrap ────
# (a self-contained copy of the light_trap_ggd lighttrap materials/surfaces)
import sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from lighttrap.materials import define_materials, ENERGY      # noqa: E402
from lighttrap.surfaces  import define_surfaces               # noqa: E402


# ── benchmark dimensions (full extents, mm) ──────────────────────────────────
LAR_X = 60_000.0    # 60   m
LAR_Y = 13_500.0    # 13.5 m
LAR_Z = 13_000.0    # 13   m

PTP_THICK      = 0.2     # mm   (200 um pTP WLS layer)
TPB_THICK      = 6.0     # mm   (TPB-doped acrylic WLS layer)
SHELL_THICK    = 1.0     # mm   (outer photon-detector shell)

LAR_DENSITY    = 1.396   # g/cc  (for the mass cross-check printout)


def _ep(values):
    return list(zip(ENERGY, values))


def build():
    geom = construct.Geometry()

    # materials (pTP, acrylicMcMaster, bluewlsacrylic, G4_lAr, Silicon) +
    # surfaces (Vikuiti, SiPMSurface). The detector shell reuses SiPMSurface:
    # dielectric_metal, REFLECTIVITY=0, EFFICIENCY=1 -> idealized 100% counter.
    define_materials(geom)
    define_surfaces(geom)

    # ── half-extents of each concentric box (mm) ─────────────────────────────
    hx0, hy0, hz0 = LAR_X / 2., LAR_Y / 2., LAR_Z / 2.                 # active LAr
    hx1, hy1, hz1 = hx0 + PTP_THICK,   hy0 + PTP_THICK,   hz0 + PTP_THICK    # + pTP
    hx2, hy2, hz2 = hx1 + TPB_THICK,   hy1 + TPB_THICK,   hz1 + TPB_THICK    # + TPB
    hx3, hy3, hz3 = hx2 + SHELL_THICK, hy2 + SHELL_THICK, hz2 + SHELL_THICK  # + shell
    hxW, hyW, hzW = hx3 + 100., hy3 + 100., hz3 + 100.                 # world margin

    def box(name, hx, hy, hz):
        return geom.shapes.Box(name, dx=f"{hx} mm", dy=f"{hy} mm", dz=f"{hz} mm")

    sh_lar   = box("solidActiveLAr", hx0, hy0, hz0)
    sh_ptp   = box("solidPTP",       hx1, hy1, hz1)
    sh_tpb   = box("solidTPB",       hx2, hy2, hz2)
    sh_shell = box("solidShell",     hx3, hy3, hz3)
    sh_world = box("solidWorld",     hxW, hyW, hzW)

    def at_origin(name, vol):
        pos = geom.structure.Position(f"{name}_pos", x="0 mm", y="0 mm", z="0 mm")
        return geom.structure.Placement(name, volume=vol, pos=pos)

    # ── innermost: active liquid-argon scintillator ──────────────────────────
    # Uniform 500 V/cm drift field along +x (long axis), attached to the LAr
    # volume; DokeBirksSaturation queries it per step to set the recombination
    # -> NonIonizingEnergyDeposit (photons), matching the lighttrap test.
    # The SegmentDetector aux makes edep-sim record the charge (ionisation) dE/dx
    # of every charged track crossing the LAr as TG4HitSegments, written to
    # TG4Event.SegmentDetectors["lar"]. This is the charge half of the event.
    vol_lar = geom.structure.Volume(
        "logicActiveLAr", material="G4_lAr", shape=sh_lar,
        params=[("EField", "(500 V/cm, 0 V/cm, 0 V/cm)"),
                ("SegmentDetector", "lar")],
    )

    # ── pTP WLS layer (innermost shell), LAr placed inside ───────────────────
    vol_ptp = geom.structure.Volume(
        "logicPTP", material="pTP", shape=sh_ptp,
        placements=[at_origin("physActiveLAr", "logicActiveLAr").name],
    )

    # ── TPB-doped acrylic WLS layer (middle shell), pTP placed inside ────────
    vol_tpb = geom.structure.Volume(
        "logicTPB", material="bluewlsacrylic", shape=sh_tpb,
        placements=[at_origin("physPTP", "logicPTP").name],
    )

    # ── outer photon-detector shell (sensitive), TPB placed inside ───────────
    vol_shell = geom.structure.Volume(
        "logicShell", material="Silicon", shape=sh_shell,
        params=[("SurfaceDetector", "PhotonDetector")],
        placements=[at_origin("physTPB", "logicTPB").name],
    )

    # ── world, shell placed inside ───────────────────────────────────────────
    vol_world = geom.structure.Volume(
        "logicWorld", material="G4_lAr", shape=sh_world,
        placements=[at_origin("physShell", "logicShell").name],
    )
    geom.set_world(vol_world.name)

    # ── idealized 100% photon counter on the detector shell ──────────────────
    geom.surfaces.SkinSurface("skinShell", surface="SiPMSurface", volume="logicShell")

    # ── mass cross-check (printed at build time) ─────────────────────────────
    vol_cm3 = (LAR_X / 10.) * (LAR_Y / 10.) * (LAR_Z / 10.)   # mm->cm
    mass_kt = vol_cm3 * LAR_DENSITY / 1e9                      # g -> kt
    print(f"[benchmark] active LAr = {LAR_X/1000:.0f} x {LAR_Y/1000:.1f} x "
          f"{LAR_Z/1000:.0f} m  ->  {mass_kt:.2f} kt")

    return geom


if __name__ == "__main__":
    geom = build()
    tree = gdml_mod.convert(geom)
    gdml_mod.output(tree, "benchmark.gdml")
    print("Written: benchmark.gdml")
