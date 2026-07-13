"""
Material definitions for the Light Trap geometry.

All materials correspond to sim_lighttrap/src/construction.cc:
  DefinePTPMaterial, DefineAcrylicMaterial, DefineBlueWLSMaterial,
  DefineWorldMaterial.

Energy axis: 8 wavelengths [nm] = {530, 425, 400, 340, 305, 160, 128, 106}
converted to MeV (Geant4 internal unit): E = hc/lambda.
"""

# hc in MeV·nm
_hc = 1239.841939e-6

WLS_NM = [530, 425, 400, 340, 305, 160, 128, 106]
ENERGY = [_hc / w for w in WLS_NM]   # MeV


def _ep(values):
    """Pair ENERGY with values into [(E, v), ...] for gegede properties."""
    return list(zip(ENERGY, values))


def define_materials(geom):
    """Add all materials to *geom* and return them as a dict."""

    # ── elements ─────────────────────────────────────────────────────────────
    geom.matter.Element("C",  symbol="C",  z=6,  a="12.011 g/mole")
    geom.matter.Element("H",  symbol="H",  z=1,  a="1.008 g/mole")
    geom.matter.Element("O",  symbol="O",  z=8,  a="15.999 g/mole")
    geom.matter.Element("Ar", symbol="Ar", z=18, a="39.948 g/mole")

    # ── pTP (p-terphenyl, C18H14) — UV wavelength shifter ────────────────────
    pTP = geom.matter.Molecule(
        "pTP", density="1.23 g/cc",
        elements=[("C", 18), ("H", 14)],
        properties=[
            ("RINDEX",          _ep([1.65]*8)),
            # absorption length in mm; absorbs strongly below 305 nm
            ("WLSABSLENGTH",    _ep([1e4, 1e4, 1e4, 1e4, 0.187, 5e-4, 5e-4, 5e-4])),
            ("WLSCOMPONENT",    _ep([0., 5e-4, 0.002, 0.022, 5e-4, 0., 0., 0.])),
            ("WLSTIMECONSTANT", [1.136]),   # ns
        ],
    )

    # ── acrylicMcMaster (C5H8O2) — pTP substrate ─────────────────────────────
    acrylicMcMaster = geom.matter.Molecule(
        "acrylicMcMaster", density="1.19 g/cc",
        elements=[("C", 5), ("H", 8), ("O", 2)],
        properties=[
            ("RINDEX", _ep([1.5]*8)),
        ],
    )

    # ── bluewlsacrylic (C9H10) — EJ-280 blue-shifting plate ──────────────────
    bluewlsacrylic = geom.matter.Molecule(
        "bluewlsacrylic", density="1.023 g/cc",
        elements=[("C", 9), ("H", 10)],
        properties=[
            ("RINDEX",          _ep([1.58]*8)),
            # absorption length in mm; good in blue window (425–530 nm)
            ("WLSABSLENGTH",    _ep([2e2, 2e2, 0.8, 0.8, 3.0, 1e-4, 1e-4, 1e-4])),
            ("WLSCOMPONENT",    _ep([5e-4, 0.02, 0., 0., 0., 0., 0., 0.])),
            ("WLSTIMECONSTANT", [1.26]),    # ns
        ],
    )

    # ── liquid argon — world medium and scintillator ──────────────────────────
    lAr = geom.matter.Mixture(
        "G4_lAr", density="1.396 g/cc",
        components=[("Ar", 1.0)],
        properties=[
            ("RINDEX",                  _ep([1.23, 1.23, 1.23, 1.23, 1.235, 1.315, 1.45, 5.45])),
            ("RAYLEIGH",                _ep([900.]*8)),     # mm
            ("ABSLENGTH",               _ep([1e4]*8)),      # mm
            ("SCINTILLATIONCOMPONENT1", _ep([0., 0., 0., 0., 0.,
                                            2.38409e-4, 3.98859e-2, 4.22473e-3])),
            ("SCINTILLATIONCOMPONENT2", _ep([0., 0., 0., 0., 0.,
                                            2.38409e-4, 3.98859e-2, 4.22473e-3])),
            # Legacy Geant4 ≤10 names kept for backwards compatibility
            ("FASTCOMPONENT",           _ep([0., 0., 0., 0., 0.,
                                            2.38409e-4, 3.98859e-2, 4.22473e-3])),
            ("SLOWCOMPONENT",           _ep([0., 0., 0., 0., 0.,
                                            2.38409e-4, 3.98859e-2, 4.22473e-3])),
            ("REEMISSIONPROB",          _ep([0.]*8)),
            # TEMP: matches the W=19.5 eV model used by EDepSim::DokeBirksSaturation
            # and the eic-opticks plugin (EDEPSIM_DOKEBIRKS_VISE=1). G4Scintillation
            # multiplies this by the DokeBirks-suppressed visible energy; setting
            # it to 1/(19.5 eV) makes CPU NumPhotons = visE / (19.5 eV), matching
            # the GPU plugin's yield rule. Was 24000.
            ("SCINTILLATIONYIELD",      [1.0/19.5e-6]),  # = 51282.05 photons/MeV
            ("RESOLUTIONSCALE",         [1.0]),
            ("SCINTILLATIONTIMECONSTANT1", [7.]),    # ns  (singlet)
            ("SCINTILLATIONTIMECONSTANT2", [1400.]), # ns  (triplet)
            ("SCINTILLATIONYIELD1",     [0.75]),
            ("SCINTILLATIONYIELD2",     [0.25]),
            # eic-opticks Local_DsG4Scintillation reads (time, yield_ratio) pairs
            # from a *CONSTANT MaterialPropertyVector for the fast/slow split.
            # Picked by particle: e/gamma → GammaCONSTANT, opticalphoton → OpticalCONSTANT,
            # alpha → AlphaCONSTANT, else → NeutronCONSTANT. Each entry: row 0 = fast
            # (singlet, 7 ns, ratio 0.75), row 1 = slow (triplet, 1400 ns, ratio 0.25).
            ("GammaCONSTANT",   [(7., 0.75), (1400., 0.25)]),
            ("OpticalCONSTANT", [(7., 0.75), (1400., 0.25)]),
            ("AlphaCONSTANT",   [(7., 0.75), (1400., 0.25)]),
            ("NeutronCONSTANT", [(7., 0.75), (1400., 0.25)]),
        ],
    )

    # ── silicon — SiPM photocathode material ─────────────────────────────────
    # RINDEX for Si (~3.5) creates a real optical boundary with LAr (1.23),
    # required for G4OpBoundaryProcess to fire and invoke the SurfaceDetector.
    geom.matter.Element("Si", symbol="Si", z=14, a="28.085 g/mole")
    silicon = geom.matter.Molecule(
        "Silicon", density="2.33 g/cc",
        elements=[("Si", 1)],
        properties=[
            ("RINDEX", _ep([3.5]*8)),
        ],
    )

    return dict(pTP=pTP, acrylicMcMaster=acrylicMcMaster,
                bluewlsacrylic=bluewlsacrylic, lAr=lAr, silicon=silicon)
