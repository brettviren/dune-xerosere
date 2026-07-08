// edep-simphony.jsonnet — phlex analog of the edep-simphony-benchmark run.sh.
//
// Data-flow graph (all nodes are Spack-built phlex plugins):
//
//   hmp_gen_event_gun   (hepmc-phlex)      fires one primary per event as a
//                                          HepMC3::GenEvent.
//     -> esp_tracking   (edep-sim-phlex)   runs it through edep-sim/Geant4,
//                                          emitting a native TG4Event.
//       -> esp_observables (edep-sim-phlex) converts the TG4Event into the
//                                          `edep.observables` Arrow TableGroup
//                                          (segments + photons members).
//         -> phlex_arrow_hdf_output (phlex-arrow-hdf) serializes every
//                                          Arrow-typed product to one HDF5 file.
//
// Unlike the benchmark's run.sh this needs NO machine-specific environment
// (no OPTIC_GPU_ROOT): the driver sets PHLEX_PLUGIN_PATH from the Spack build
// tree and injects the run-specific paths through params.libsonnet, which
// run.sh generates next to this file in the output directory.
//
// SCOPE: today this exercises the TG4Event *observables* converters serialized
// via arrow-hdf.  Serializing the MC-truth GenEvent graph, and running the
// edep-simphony GPU optical plugin inside the edep-sim node, are later work
// (GenEvent converter; ddm-p5j.7) — this test will be extended to cover them.

local params = import 'params.libsonnet';

{
  driver: {
    cpp: 'generate_layers',
    layers: {
      event: { parent: 'job', total: params.nevents, starting_number: 0 },
    },
  },

  sources: {
    // One 1 GeV muon along +z per event (a reliable ionisation source that
    // fills the observables `segments` table).  Tune for the geometry.
    gun: {
      cpp: 'hmp_gen_event_gun',
      output_layer: 'event',
      pdg: 13,             // mu-
      mass: 105.658,       // MeV
      energy: 1000.0,      // MeV kinetic
      direction: [0, 0, 1],
      position: [0, 0, -2500],  // mm, upstream of the detector
      number: 1,
      momentum_unit: 'MeV',
      length_unit: 'mm',
    },
  },

  modules: {
    edep_sim_tracking: {
      cpp: 'esp_tracking',
      input_layer: 'event',
      gdml: params.gdml,
      // physics_list / macro omitted -> edep-sim default (QGSP_BERT + optical).
    },
    edep_observables: {
      cpp: 'esp_observables',
      input_layer: 'event',
      input_from: 'edep_sim_tracking',  // consumes the TG4Event
    },
    hdf_out: {
      cpp: 'phlex_arrow_hdf_output',
      output_file: params.output_file,  // writes all Arrow-typed products
    },
  },
}
