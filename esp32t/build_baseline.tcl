# esp32t baseline, driven from build_evt1_x2.tcl's list.
#
# NOT the .gprj. On main the .gprj was the maintained list and build.tcl was
# stale; on integration/resource-savings that is REVERSED - 56fdebb fixed
# build.tcl, and the .gprj now misses files the design needs (audio_resample.v
# among them, which fails as "Instantiating unknown module").
#
# build_evt1_x2.tcl sources build.tcl for the file list and then sets the
# device and options, so it is the right driver here; this only adds effort
# and renames the output.

source build_evt1_x2_nofinish.tcl

# esp32t is dense: on main it is 88% logic, 81% BSRAM and 100% DSP, and at
# default effort PnR gave up with 754 unrouted nets. Same settings our own
# chromatic examples use, where they were also not cosmetic.
set_option -place_option 2
set_option -route_option 1
set_option -replicate_resources 1
set_option -clock_route_order 1

set_option -output_base_name evt1_x2_baseline

run all
