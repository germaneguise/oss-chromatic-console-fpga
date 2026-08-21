// flash_bridge.sv
//
// Bridges the ESP32's shared QSPI bus to the FPGA's config flash whenever the
// bridge chip select is low and the display slave's CS is idle. 1-bit
// commands pass through transparently. Quad-output fast read (0x6B) is
// additionally supported: the command byte is snooped on IO0, and after its
// 8 command + 24 address + 8 dummy rising edges the data lanes reverse so
// the flash drives all four IOs back to the host. No other multi-line
// command is decoded - the host must not issue one (the MCU driver only
// uses 0x03/0x0B/0x6B/0x9F/status commands).
//
// WP_n/HOLD_n (flash IO2/IO3) are never driven by the fabric: with the
// flash's QE bit clear they are held high by the cst pull-ups, and with QE
// set they are data lanes the flash controls during quad reads. The
// direction FSM is clocked by the SPI clock itself and reset by CS, the
// same async style as QSPI_Slave.

module flash_bridge (
    // host side (ESP32 shared QSPI bus)
    input  cs2_n,      // bridge chip select (I2S_WS), pulled up in the cst
    input  disp_cs_n,  // display slave CS - bridge inert unless it is idle
    input  sclk,
    inout  host_io0,   // QSPI_MOSI
    inout  host_io1,   // QSPI_MISO
    inout  host_io2,   // QSPI_WP
    inout  host_io3,   // QSPI_HD
    // flash side
    output flash_clk,
    output flash_cs_n,
    inout  flash_io0,  // FLASH_MOSI
    input  flash_io1,  // FLASH_MISO
    input  flash_io2,  // FLASH_MD2 (WP_n)
    input  flash_io3   // FLASH_MD3 (HOLD_n)
);

    wire en = ~cs2_n & disp_cs_n;

    localparam [7:0] CMD_QUAD_FAST_READ = 8'h6B;
    // 8 command + 24 address + 8 dummy rising edges precede quad data
    localparam [6:0] QUAD_DATA_AFTER_EDGE = 7'd39;

    reg [7:0] cmd_shift = 8'd0;
    reg [6:0] edge_cnt  = 7'd0; // saturating
    reg       quad_data = 1'b0;

    always @(posedge sclk or posedge cs2_n) begin
        if (cs2_n) begin
            cmd_shift <= 8'd0;
            edge_cnt  <= 7'd0;
            quad_data <= 1'b0;
        end else begin
            if (~&edge_cnt)
                edge_cnt <= edge_cnt + 1'd1;
            if (edge_cnt < 7'd8)
                cmd_shift <= {cmd_shift[6:0], host_io0};
            if ((edge_cnt == QUAD_DATA_AFTER_EDGE) && (cmd_shift == CMD_QUAD_FAST_READ))
                quad_data <= 1'b1;
        end
    end

    assign flash_clk  = en ? sclk : 1'b0;
    assign flash_cs_n = ~en;

    // IO0: host drives command/address/1-bit data; flash drives it back only
    // in the quad data phase.
    assign flash_io0 = (en & ~quad_data) ? host_io0  : 1'bz;
    assign host_io0  = (en &  quad_data) ? flash_io0 : 1'bz;

    // IO1 is flash-to-host in every supported command.
    assign host_io1  = en ? flash_io1 : 1'bz;

    // IO2/IO3 carry data to the host only in the quad data phase; otherwise
    // they belong to the display link (host-driven) or idle at their pulls.
    assign host_io2  = (en & quad_data) ? flash_io2 : 1'bz;
    assign host_io3  = (en & quad_data) ? flash_io3 : 1'bz;

endmodule
