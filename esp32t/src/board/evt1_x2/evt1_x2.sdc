create_generated_clock -name xclk2 -source [get_ports {CLK_FPGA}] -master_clock exclk -divide_by 1 -multiply_by 4 [get_pins {u_Gowin_PLL/PLLA_inst/CLKOUT0}]
create_generated_clock -name pclk -source [get_ports {CLK_FPGA}] -master_clock exclk -divide_by 1 -multiply_by 1 [get_pins {u_Gowin_PLL/PLLA_inst/CLKOUT1}]
create_generated_clock -name hclk -source [get_ports {CLK_FPGA}] -master_clock exclk -divide_by 2 -multiply_by 1 [get_pins {u_Gowin_PLL/PLLA_inst/CLKOUT2}]
create_generated_clock -name gclk -source [get_ports {CLK_FPGA}] -master_clock exclk -divide_by 4 -multiply_by 1 [get_pins {u_Gowin_PLL/PLLA_inst/CLKOUT3}]
create_generated_clock -name xclk -source [get_ports {CLK_FPGA}] -master_clock exclk -divide_by 1 -multiply_by 2 [get_pins {u_Gowin_PLL/PLLA_inst/CLKOUT4}]

create_clock -name sclk -period 25 [get_ports {QSPI_CLK}]
create_clock -name exclk -period 29.802322 [get_ports {CLK_FPGA}]

set_clock_groups -asynchronous -group [get_clocks {pclk}] -group [get_clocks {hclk}]
set_clock_groups -asynchronous -group [get_clocks {pclk}] -group [get_clocks {gclk}]
set_clock_groups -asynchronous -group [get_clocks {hclk}] -group [get_clocks {gclk}]

set_max_delay -from [get_ports {CART_D[*]}] -to [get_clocks {hclk}] 13
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_A[*]}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_WR}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_RD}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_CS}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {LINK_SD}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_D[*]}] 14
// PHI, the direction control, cart reset and the detect input were never
// constrained. Address and strobes are bounded at 14 ns while the clock the
// whole cart bus is referenced to floats free, so their RELATIVE skew is
// undefined and settled by placement. Direct paths hid it; putting a mux in
// front of these pins is what made the omission bite. CART_DET is sampled on
// xclk and gates memrst, which holds the core in reset.
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_CLK}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_DATA_DIR_E}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_RST}] 14
set_max_delay -from [get_clocks {hclk}] -to  [get_ports {CART_AUDIN}] 14
set_max_delay -from [get_ports {CART_DET}] -to [get_clocks {xclk}] 13

create_clock -name ck24 -period 41.666667 -waveform {0 20.833333} [get_ports {CLK_24MHz}]

set_clock_groups -asynchronous -group [get_clocks {pclk}] -group [get_clocks {hclk}]
set_clock_groups -asynchronous -group [get_clocks {pclk}] -group [get_clocks {gclk}]
set_clock_groups -asynchronous -group [get_clocks {hclk}] -group [get_clocks {gclk}]

// USB Clocks
create_generated_clock -name PHY_CLKOUT -source [get_ports {CLK_24MHz}] -master_clock ck24 -divide_by 16 -multiply_by 40 [get_pins {u_usb_top/u_Gowin_PLL_USB/PLLA_inst/CLKOUT1}]
create_generated_clock -name fclk_960M -source [get_ports {CLK_24MHz}] -master_clock ck24 -divide_by 1 -multiply_by 40 [get_nets {u_usb_top/fclk_960M}]
create_generated_clock -name clk24p -source [get_ports {CLK_24MHz}] -master_clock ck24 -divide_by 1 -multiply_by 1 [get_pins {u_usb_top/u_Gowin_PLL_USB/PLLA_inst/CLKOUT2}]
create_clock -name usbintsclk -period 8 -waveform {0 4} [get_nets {u_usb_top/u_USB_SoftPHY_Top/usb2_0_softphy/u_usb_20_phy_utmi/u_usb2_0_softphy/u_usb_phy_hs/sclk}] -add
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {fclk_960M}]
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {usbintsclk}]

// CLK_FPGA and CLK_24MHz are separate oscillators, so everything derived from
// one is asynchronous to everything derived from the other. That was never
// stated, which left the video<->USB crossing unconstrained rather than
// failing: uvc_restamp crosses gclk (video, off CLK_FPGA) into PHY_CLKOUT
// (USB, off CLK_24MHz), and no report flags it - the Max Frequency Summary
// only ever showed intra-domain numbers, and PHY_CLKOUT closes at 88.9 MHz
// against its 60 MHz constraint while the crossing itself went unanalysed.
//
// Unconstrained is worse than tight here, because the placer is free to give
// the data path and the synchronised control path arbitrary relative delay,
// and that changes build to build with nothing in the flow objecting.
//
// -group says only "A is async to B"; it makes no claim about clocks within a
// group, so this does not contradict the pclk/hclk/gclk grouping above.
//
// One statement per pair, on one line each: this SDC parser rejects backslash
// line continuation with "syntax error near token '\'", and the error aborts
// the run before a bitstream is written.
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {gclk}]
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {hclk}]
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {pclk}]
set_clock_groups -asynchronous -group [get_clocks {PHY_CLKOUT}] -group [get_clocks {xclk}]

// The cart bus is driven from two clocks, but only one was ever constrained.
// The set_max_delay block above is entirely -from/-to hclk, written when the
// emulator was the only master. cart_reader runs in PHY_CLKOUT and drives the
// same pins through the top-level mux, and PHY_CLKOUT is declared asynchronous
// to hclk, so those paths carry no bound at all - the placer may give address,
// data and strobes arbitrary relative delay, and that changes build to build.
// Same argument as the video<->USB crossing above: unconstrained is worse than
// tight, because nothing in the flow objects.
//
// 14 ns to match the hclk side. What matters is not the absolute number - a
// Game Boy bus cycle is ~954 ns, so nanoseconds are noise against it - but that
// address, data and strobes share one bound instead of floating independently.
// CART_DATA_DIR_E, CART_CLK and CART_RST are included because cart_reader
// drives them too; the hclk block omits them.
set_max_delay -from [get_ports {CART_D[*]}] -to [get_clocks {PHY_CLKOUT}] 13
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_A[*]}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_D[*]}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_DATA_DIR_E}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_CS}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_RD}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_WR}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_CLK}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_RST}] 14
set_max_delay -from [get_clocks {PHY_CLKOUT}] -to [get_ports {CART_AUDIN}] 14
