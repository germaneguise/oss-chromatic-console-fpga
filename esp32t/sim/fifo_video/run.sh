#!/usr/bin/env bash
# Benches for fifo_video_rtl, the open replacement for Gowin's encrypted
# fifo_video IP.
#
#   ./run.sh            # all three
#   ./run.sh tb_system  # just one
#
# The benches are self-contained Verilog (written for Icarus), so they run under
# "verilator --binary" rather than the --cc/--exe C++ harness path. An earlier
# revision of this script drove a tb_fifo_video.cpp that no longer exists.
#
#   tb_fill        RdEn tied low: occupancy must climb monotonically to depth.
#                  Reproduces the hardware observation where rnum plateaued near
#                  960 with rden=0, which should be impossible.
#   tb_fifo_video  Unit level: flags, thresholds, data integrity, and the
#                  per-video-frame reset that usbuvcuart_top drives.
#   tb_system      Real geometry both sides: 456-dot lines, 154 lines with 10 of
#                  vblank, 160x144 YUY2 on the write side at hClk 16.777 MHz,
#                  against the real usb_sof-driven packet FSM on pClk 60 MHz.
#                  Synthetic patterns passed while hardware failed; this is the
#                  bench that models the dynamics that actually matter.
set -euo pipefail
cd "$(dirname "$0")"

export PATH="/c/msys64/ucrt64/bin:/c/msys64/usr/bin:$PATH"
# Only honour VERILATOR_ROOT if the caller set it. Forcing a default makes this
# verilator refuse to start - "VERILATOR_ROOT is set to inconsistent path,
# suggest leaving it unset" - because the binary already knows its own root.
[ -n "${VERILATOR_ROOT:-}" ] && export VERILATOR_ROOT || true

# -static-libstdc++: this MSYS2 gcc's libstdc++ does not export the basic_string
# move ctor that Verilator's runtime references, so the dynamic link fails.
# -D_GLIBCXX_EXTERN_TEMPLATE=0: since the gcc 16.1.0 update, static linking is no
# longer enough - libstdc++.a itself stopped carrying that out-of-line symbol, so
# the extern-template declaration promises something nothing provides. Suppress
# the declaration and the ctor is instantiated locally.
CXXFIX='-D_GLIBCXX_EXTERN_TEMPLATE=0'
RTL=../../src/rtl/USB/USBUVCUART/fifo_video/fifo_video_rtl.v

# Unquoted on purpose: "${@:-a b c}" would make the default a single word.
for tb in ${@:-tb_fill tb_fifo_video tb_system}; do
    echo "===== $tb ====="
    # Verilator does not rewrite unchanged generated files, so an incremental
    # run can silently test a stale copy of the RTL. Wipe unless FAST=1.
    [ "${FAST:-0}" = "1" ] || rm -rf "obj_$tb"
    verilator --binary -j 0 --Mdir "obj_$tb" \
        -CFLAGS "$CXXFIX -O1" -LDFLAGS "-static-libstdc++ -static-libgcc" \
        -Wall -Wno-fatal -Wno-DECLFILENAME -Wno-UNUSEDSIGNAL -Wno-WIDTHTRUNC \
        -Wno-WIDTHEXPAND -Wno-PROCASSINIT -Wno-MULTIDRIVEN -Wno-TIMESCALEMOD \
        --top-module "$tb" "$RTL" "$tb.v" -o "$tb" >/dev/null
    "./obj_$tb/$tb"
done
