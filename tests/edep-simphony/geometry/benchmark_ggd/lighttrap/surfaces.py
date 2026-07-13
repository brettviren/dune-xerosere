"""
Optical surface definitions for the Light Trap geometry.

Vikuiti: 3M Enhanced Specular Reflector (ESR) film applied to all
reflective foil volumes. Corresponds to construction.cc DefineOpticalSurface().
"""

from lighttrap.materials import ENERGY


def _ep(values):
    return list(zip(ENERGY, values))


def define_surfaces(geom):
    """Add optical surfaces to *geom* and return them as a dict."""

    # 3M Vikuiti ESR: dielectric_metal, ground finish, R=98% across spectrum
    vikuiti = geom.surfaces.OpticalSurface(
        "Vikuiti",
        model="unified",
        finish="ground",
        type="dielectric_metal",
        value=0.0,
        properties=[
            ("REFLECTIVITY", _ep([0.98]*8)),
        ],
    )

    # SiPM photocathode: dielectric_metal, polished
    # REFLECTIVITY=0 forces absorption (no reflection); EFFICIENCY=1 means all
    # absorbed photons get Detection status and are recorded as hits.
    sipm_surface = geom.surfaces.OpticalSurface(
        "SiPMSurface",
        model="unified",
        finish="polished",
        type="dielectric_metal",
        value=0.0,
        properties=[
            ("REFLECTIVITY", _ep([0.0]*8)),
            ("EFFICIENCY",   _ep([1.0]*8)),
        ],
    )

    return dict(vikuiti=vikuiti, sipm_surface=sipm_surface)
