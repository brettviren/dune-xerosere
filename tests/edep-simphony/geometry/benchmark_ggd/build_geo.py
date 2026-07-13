#!/usr/bin/env python
"""
Build the benchmark nested-shell LAr optical geometry and export to GDML.

Usage:
    python build_geo.py [output.gdml]

Default output: benchmark.gdml
"""

import sys
import os

sys.path.insert(0, os.path.dirname(__file__))

from gegede.export import gdml as gdml_mod
import benchmark

DEFAULT_OUTPUT = os.path.join(os.path.dirname(__file__), "benchmark.gdml")


def _patch_lar_state(gdml_path):
    """Inject state="liquid" into the <material name="G4_lAr" ...> tag.

    gegede's Mixture schema has no `state` field, but Geant4's
    G4Scintillation + Birks-law model only kicks in for materials whose
    G4State is kStateLiquid. Patch the attribute in post.
    """
    import re
    with open(gdml_path, "r") as f:
        text = f.read()
    new_text, n = re.subn(
        r'(<material name="G4_lAr"[^>]*?)(\s*>)',
        lambda m: m.group(1) + ' state="liquid"' + m.group(2),
        text, count=1,
    )
    if n == 0:
        print('WARNING: could not find <material name="G4_lAr"> to patch')
        return
    with open(gdml_path, "w") as f:
        f.write(new_text)
    print('Patched: <material name="G4_lAr"> state="liquid"')


def build(output=DEFAULT_OUTPUT):
    geom = benchmark.build()
    print(f"Exporting GDML to: {output}")
    tree = gdml_mod.convert(geom)
    gdml_mod.output(tree, output)
    _patch_lar_state(output)
    print("Done.")
    return output


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else DEFAULT_OUTPUT
    build(output=out)
