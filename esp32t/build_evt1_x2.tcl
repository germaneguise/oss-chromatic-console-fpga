source build.tcl
set_device GW5A-EV25UG256CC1/I0 -device_version A 
set_option -synthesis_tool gowinsynthesis
set_option -top_module top
set_option -verilog_std sysv2017
set_option -vhdl_std vhd2008
set_option -rw_check_on_ram 1
set_option -use_sspi_as_gpio 1
set_option -power_on_reset_monitor 1
set_option -use_i2c_as_gpio 1
set_option -use_cpu_as_gpio 1
set_option -multi_boot 0
set_option -bit_format bin
set_option -bg_programming jtag_sspi_qsspi
set_option -output_base_name evt1_x2_v07
set_option -use_mspi_as_gpio 1
add_file -type cst      "src/board/evt1_x2/evt1_x2.cst"
add_file -type sdc      "src/board/evt1_x2/evt1_x2.sdc"
#add_file -type gao      "src/psram.rao"

#add_file -type verilog "src/rtl/USB/USBUVC/usbuvc_top.v"
#add_file -type verilog "src/rtl/USB/USBUVC/Gowin_PLL_UVC/Gowin_PLL_UVC.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb_video/usb_defs.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb_video/usb_descriptor_video.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb_video/uvc_defs.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb_device_controller/usb_device_controller.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb2_0_softphy/usb2_0_softphy_top.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb2_0_softphy/usb2_0_softphy_name.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb2_0_softphy/usb2_0_softphy_encryption.v"
#add_file -type verilog "src/rtl/USB/USBUVC/usb2_0_softphy/static_macro_define.v"

# MUST precede usbuvcuart_top.v: its ifdef UVC_RESTAMP is evaluated when that
# file is analysed, and a define added later is invisible to it. Ordered after,
# the build still succeeds - it just silently compiles the un-restamped path.
add_file -type verilog "src/rtl/USB/USBUVCUART/usb_video/uvc_esp32t_opts.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usbuvcuart_top.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/Gowin_PLL_UVC/Gowin_PLL_UVC.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb_video/usb_defs.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb_video/usb_descriptor_video.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb_video/uvc_defs.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/uvc_restamp.sv"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb_device_controller/usb_device_controller.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb2_0_softphy/usb2_0_softphy_top.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb2_0_softphy/usb2_0_softphy_name.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb2_0_softphy/usb2_0_softphy_encryption.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/usb2_0_softphy/static_macro_define.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/uart/uart.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/sync_fifo/usb_fifo.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/sync_fifo/sync_rx_pkt_fifo.v"
add_file -type verilog "src/rtl/USB/USBUVCUART/sync_fifo/sync_tx_pkt_fifo.v"

add_file -type verilog "src/gowin_pll_preevt/gowin_pll.v"
add_file -type verilog "src/top.v"

# Stamp the bitstream USERCODE (32 bits) with the short hash of the source
# commit - exactly 8 hex digits - so a bitstream file or flash dump can be
# traced back to the source that built it. Left at the project default when
# git is unavailable (e.g. building from a release tarball).
set repo_dir [file dirname [info script]]
if {[catch {exec git -C $repo_dir rev-parse --short=8 HEAD} commit]} {
    puts "WARNING: git commit unavailable, USERCODE left at default"
} else {
    set commit [string range [string trim $commit] 0 7]
    if {![catch {exec git -C $repo_dir status --porcelain} dirty] && $dirty ne ""} {
        puts "WARNING: working tree is dirty, USERCODE $commit does not identify this bitstream exactly"
    }
    set_option -user_code $commit
    puts "USERCODE set to commit $commit"
}

run all
