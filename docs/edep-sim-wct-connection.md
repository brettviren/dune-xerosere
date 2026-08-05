beads ddm-69y.1 asks my feedback

1, 2, 3 and 4: Seeing your break-down I want the scope to be slightly more ambitious and do the segment ionization and sampling inside Wire-Cell Toolkit.  To do that, we will model the segment information as a ITrackSegment and ITrackSegmentSet in devel/wire-cell-toolkit's iface/ and implementations SimpleTrackSegment*  under aux/.  The iface/ area will also get an ITrackSegmentSampler that is an IFunctionNode taking ITrackSegmentSet input and IDepoSet output.  The gen/ package can then get a TrackSegmentSampler implementation.  I have switched devel/wire-cell-toolkit to a feature branch "track-segment-sampling" to receive this new code.

The wire-cell-arrow package will need an ArrowTrackSegmentSet class and a converter between that and ITrackSegmentSet.  The wire-cell-arrow package then needs an .  This will also require new variants of the Phlex and WCT level Jsonnet files from the ones that previously input deposets. 

3. The modal switch can be accomplished in TrackSegmentSampler.  It would be driven by a configuration parameter and in the configure() method, a suitable function object would be stored as an instance member.  This avoids the mode switch being an "if()" inside each call to TrackSegmentSampler::operator().  E-field and any other parameters needed by TrackSegmentSampler would be provided in WCT Jsonnet configuration.

4. The details of this step are good.

5. This is reasonable.

6. Given the change to place the track segment sampling into WCT: yes on an edep-arrow package.  I think the other parts are covered by the above.


Geometry and wires files


PDVD:
reference/dunecore/Geometry/gdml/protodunevd_v5_ggd_nowires.gdml
reference/wire-cell-data/protodunevd-wires-larsoft-v5.json.bz2

PDHD:
reference/dunecore/Geometry/gdml/protodunehd_v8_refactored_nowires.gdml
reference/wire-cell-data/protodunehd-wires-larsoft-v1.json.bz2

