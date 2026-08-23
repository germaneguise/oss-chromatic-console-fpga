// Bench for cart_reader's EP3 receive path.
//
// On hardware, dumper mode answers only the FIRST command in a USB OUT packet,
// and single queries alternate answered/unanswered. Restoring the deep EP3 RX
// cross FIFO changed nothing, so the delivery side is not at fault and the
// question is what cart_reader does with the bytes it is handed.
//
// usb_rx_buf hands over one byte per TWO i_ep_clk cycles, as a single-cycle
// o_ep_rx_dval pulse with the data valid alongside:
//
//   c_fifo_rd :  _/‾\_/‾\_     (forced low the cycle after it asserts)
//   dval      :  __/‾\_/‾\_    (registered c_fifo_rd & !empty)
//
// so the consumer sees valid high for exactly one clock, every other clock,
// for as long as the FIFO has data. This bench reproduces that exactly, then
// sweeps the gap to find the spacing at which cart_reader stops dropping.
//
// PASS = every command issued produces one 37-byte ID response.

`timescale 1ns/1ps

module tb_cart_rx;
    localparam CLK_HALF = 8.333;      // 60 MHz, matching CLK_FREQ

    reg clk = 0, reset = 1;
    reg rx_valid = 0;
    reg [7:0] rx_data = 0;
    wire tx_valid;
    wire [7:0] tx_data;

    wire [15:0] cart_a;
    wire cart_clk, cart_cs, cart_rd, cart_wr, cart_rst;
    wire cart_data_dir_e, cart_audio, cart_pullups;
    wire [7:0] cart_d_out;

    cart_reader #(.CLK_FREQ(60_000_000)) dut (
        .clk(clk), .reset(reset),
        .rx_valid(rx_valid), .rx_data(rx_data),
        .tx_valid(tx_valid), .tx_data(tx_data),
        .cart_a(cart_a), .cart_clk(cart_clk), .cart_cs(cart_cs),
        .cart_rd(cart_rd), .cart_wr(cart_wr), .cart_rst(cart_rst),
        .cart_data_dir_e(cart_data_dir_e), .cart_d_out(cart_d_out),
        .cart_d_in(8'hFF), .cart_audio(cart_audio),
        .cart_det(1'b1), .cart_pullups_enabled(cart_pullups)
    );

    always #CLK_HALF clk = ~clk;

    // ---- response collector
    integer resp_bytes = 0;
    reg [8*48-1:0] resp_txt;
    integer ri;
    always @(posedge clk) if (!reset && tx_valid) begin
        resp_bytes = resp_bytes + 1;
        if (resp_bytes <= 40) resp_txt = {resp_txt[8*47-1:0], tx_data};
    end

    // ---- deliver one byte as a single-cycle pulse
    task put(input [7:0] b, input integer gap);
        integer g;
        begin
            @(negedge clk); rx_valid = 1'b1; rx_data = b;
            @(negedge clk); rx_valid = 1'b0;
            for (g = 0; g < gap; g = g + 1) @(negedge clk);
        end
    endtask

    task send_cmds(input integer n, input integer gap);
        integer c;
        begin
            for (c = 0; c < n; c = c + 1) begin
                put(8'h55, gap);
                put(8'hAA, gap);
            end
        end
    endtask

    task settle; begin repeat (4000) @(posedge clk); end endtask

    integer gap, n, expect_n;
    integer fails = 0;

    initial begin
        repeat (20) @(posedge clk); reset = 0; repeat (200) @(posedge clk);

        $display("=== A. one command, varying inter-byte gap ===");
        $display("    gap is idle clocks between valid pulses; 1 = the hardware rate");
        for (gap = 1; gap <= 64; gap = gap * 2) begin
            resp_bytes = 0;
            send_cmds(1, gap);
            settle;
            $display("    gap %3d clk -> %3d bytes %s",
                     gap, resp_bytes, (resp_bytes == 37) ? "OK" : "<-- DROPPED");
            if (resp_bytes != 37) fails = fails + 1;
        end

        $display("\n=== B. bursts at the hardware rate (gap 1) ===");
        for (n = 1; n <= 4; n = n + 1) begin
            resp_bytes = 0;
            send_cmds(n, 1);
            settle;
            $display("    %0d commands -> %3d bytes = %0.1f responses %s",
                     n, resp_bytes, resp_bytes/37.0,
                     (resp_bytes == 37*n) ? "OK" : "<-- SHORT");
            if (resp_bytes != 37*n) fails = fails + 1;
        end

        $display("\n=== C. bursts with a generous gap (64 clk) ===");
        for (n = 1; n <= 4; n = n + 1) begin
            resp_bytes = 0;
            send_cmds(n, 64);
            settle;
            $display("    %0d commands -> %3d bytes = %0.1f responses %s",
                     n, resp_bytes, resp_bytes/37.0,
                     (resp_bytes == 37*n) ? "OK" : "<-- SHORT");
            if (resp_bytes != 37*n) fails = fails + 1;
        end

        // D: drive the protocol as actually specified. After the ID the device
        // waits for "LK" - FlashGBX's enable-LK step. A bare repeat of 55 AA is
        // a protocol error by the host, not a fault in the device.
        $display("\n=== D. correct sequence: 55 AA, ID, then LK ===");
        resp_bytes = 0; send_cmds(1, 4); settle;
        $display("    55 AA -> %0d bytes (the ID string)", resp_bytes);
        resp_bytes = 0; put(8'h4C, 4); put(8'h4B, 4); settle;   // 'L','K'
        $display("    LK    -> %0d bytes (expect 1: the 0xFF ack)", resp_bytes);

        $display("\n=== E. one junk byte resyncs to P_INIT: every query answers ===");
        for (n = 0; n < 4; n = n + 1) begin
            resp_bytes = 0;
            put(8'h00, 4);          // any non-'L' byte sends WAIT_L back to INIT
            send_cmds(1, 4); settle;
            $display("    resync+query %0d -> %3d bytes %s",
                     n, resp_bytes, (resp_bytes == 37) ? "OK" : "<-- FAIL");
        end

        // F: the command FlashGBX actually hangs on. SET_VARIABLE is 0xA6 plus
        // size(1) + key(4 BE) + value(4 BE) = 10 bytes, issued in ONE write, so
        // the endpoint hands them over back-to-back. ACK is a single 0x01.
        // This is AGB_READ_METHOD (key 0x0C), the exact call in the traceback.
        $display("\n=== F. SET_VARIABLE(AGB_READ_METHOD) after a real handshake ===");
        for (gap = 1; gap <= 32; gap = gap * 2) begin
            put(8'h00, 4); put(8'h55, 4); put(8'hAA, 4); settle;   // resync + identify
            put(8'h4C, 4); put(8'h4B, 4); settle;                  // LK -> P_CMD
            resp_bytes = 0;
            put(8'hA6, gap); put(8'h01, gap);                      // cmd, size=1
            put(8'h00, gap); put(8'h00, gap);
            put(8'h00, gap); put(8'h0C, gap);                      // key = 0x0000000C
            put(8'h00, gap); put(8'h00, gap);
            put(8'h00, gap); put(8'h00, gap);                      // value = 0
            settle;
            $display("    gap %2d clk -> %0d ACK byte(s) %s",
                     gap, resp_bytes, (resp_bytes == 1) ? "OK" : "<-- NO ACK (hangs)");
        end

        $display("\n%0s (%0d failing cases in A-C)", fails ? "REPRODUCED" : "ALL PASS", fails);
        $finish;
    end

    initial begin #200_000_000; $display("TIMEOUT"); $finish; end
endmodule
