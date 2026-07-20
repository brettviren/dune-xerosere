// DSL-authored workflow: deposet source -> WCT deposet filter (passthrough).
// Built with phlex.libsonnet; run via `phlexed -J <share/jsonnet>` so the
// import resolves (plain `phlex -c` has no import search path).
local phlex = import 'phlex/phlex.libsonnet';

local src = phlex.source('deposet_source', 'wcph_deposet_source',
                         layer='event', outputs=['deposet']);

local filt = phlex.node('deposet_filter', 'wcph_deposet_filter', layer='event',
                        inputs=[src.output('deposet')],
                        outputs=['deposet'],
                        config={ executor: { wct_config: 'deposet-passthrough.jsonnet',
                                             wct_plugins: ['WireCellPgraph'] } });

phlex.workflow(
  phlex.generate_layers({ event: { parent: 'job', total: 3, starting_number: 1 } }),
  nodes=[filt], sources=[src])
