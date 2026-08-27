// tb_restamp_strobed.v
//
// Covers uvc_restamp's WRITE side, which nothing else does - tb_hbw models
// restamp's output rather than instantiating it.
//
// The failure mode this exists to catch: fed from a level source (panel
// scanout, s_enable high across the active line, a pixel every CLKS_PER_PX
// cycles) the write side is correct. Fed a one-cycle strobe per pixel - the
// emulator's own lcd_clkena - the level-mode write side both captures one
// pixel per three source pixels AND treats every inter-pixel gap as a line
// end, so no line ever fills and the output is dead. That is what
// SRC_STROBED handles.
//
//   1  level source, SRC_STROBED=0  - the shipping contract still works
//   2  strobed source, SRC_STROBED=1 - uniform cadence
//   3  strobed source, bursty        - gaps between strobes, as the real PPU
//                                      does during sprite fetches
//   4  strobed source, SRC_STROBED=0 - asserted to produce NO frame, proving
//                                      the mode parameter is load-bearing
`timescale 1ns/1ps

module tb_restamp_strobed;

    localparam integer SRC_W = 160;
    localparam integer SRC_H = 8;      // short frames; height is not the risk

    reg hclk = 0, pclk = 0, rst = 1;
    always #10 hclk = ~hclk;           // 50 MHz-ish, ratio is what matters
    always #3  pclk = ~pclk;

    reg         s_fv = 0, s_en = 0, s_le = 0;
    reg  [17:0] s_data = 0;
    reg  [1:0]  rep = 1;

    wire        m_fv, m_lv, m_en;
    wire [17:0] m_data;

    // Two instances, same stimulus, differing only in SRC_STROBED.
    wire m_fv0, m_lv0, m_en0; wire [17:0] m_data0;
    wire m_fv1, m_lv1, m_en1; wire [17:0] m_data1;

    uvc_restamp #(.SRC_W(SRC_W), .SRC_H(SRC_H), .SRC_STROBED(0)) dut_level (
        .hclk(hclk), .hrst(rst), .s_frame_valid(s_fv), .s_enable(s_en),
        .s_data(s_data), .s_line_end(s_le), .pclk(pclk), .prst(rst), .rep(rep),
        .m_frame_valid(m_fv0), .m_line_valid(m_lv0), .m_enable(m_en0),
        .m_data(m_data0));

    uvc_restamp #(.SRC_W(SRC_W), .SRC_H(SRC_H), .SRC_STROBED(1)) dut_strobe (
        .hclk(hclk), .hrst(rst), .s_frame_valid(s_fv), .s_enable(s_en),
        .s_data(s_data), .s_line_end(s_le), .pclk(pclk), .prst(rst), .rep(rep),
        .m_frame_valid(m_fv1), .m_line_valid(m_lv1), .m_enable(m_en1),
        .m_data(m_data1));

    // Count pixels emitted by each instance.
    integer px0 = 0, px1 = 0;
    always @(posedge pclk) if (!rst) begin
        if (m_en0) px0 = px0 + 1;
        if (m_en1) px1 = px1 + 1;
    end

    integer errors = 0;

    // ---- stimulus tasks -------------------------------------------------
    // Level source: enable high across the line, pixel every 3 clocks.
    task send_frame_level;
        integer y, x, k;
        begin
            @(posedge hclk); s_fv <= 1;
            repeat (4) @(posedge hclk);
            for (y = 0; y < SRC_H; y = y + 1) begin
                s_en <= 1;
                for (x = 0; x < SRC_W; x = x + 1) begin
                    s_data <= x[17:0];
                    for (k = 0; k < 3; k = k + 1) @(posedge hclk);
                end
                s_en <= 0;
                repeat (6) @(posedge hclk);
            end
            s_fv <= 0;
            repeat (20) @(posedge hclk);
        end
    endtask

    // Strobed source: one cycle of enable per pixel. gap=0 is back-to-back,
    // gap>0 models the PPU stalling mid-line on sprite fetches.
    task send_frame_strobed;
        input integer gap;
        integer y, x;
        begin
            @(posedge hclk); s_fv <= 1;
            repeat (4) @(posedge hclk);
            for (y = 0; y < SRC_H; y = y + 1) begin
                for (x = 0; x < SRC_W; x = x + 1) begin
                    s_data <= x[17:0];
                    s_en   <= 1; @(posedge hclk);
                    s_en   <= 0;
                    // irregular stalls, like sprite_fetch_hold
                    if (gap > 0 && (x % 7) == 3) repeat (gap) @(posedge hclk);
                end
                s_le <= 1; @(posedge hclk); s_le <= 0;   // line end
                repeat (8) @(posedge hclk);   // inter-line gap
            end
            s_fv <= 0;
            repeat (20) @(posedge hclk);
        end
    endtask

    // Lines that deliver fewer than SRC_W pixels before the line ends.
    task send_short_lines;
        input integer n;
        integer y, x;
        begin
            for (y = 0; y < n; y = y + 1) begin
                for (x = 0; x < SRC_W/2; x = x + 1) begin
                    s_data <= x[17:0];
                    s_en   <= 1; @(posedge hclk);
                    s_en   <= 0;
                end
                s_le <= 1; @(posedge hclk); s_le <= 0;
                repeat (8) @(posedge hclk);
            end
        end
    endtask

    task check;
        input [255:0] name;
        input integer got;
        input integer want;
        begin
            if (got == want)
                $display("PASS  %0s: %0d pixels", name, got);
            else begin
                $display("FAIL  %0s: got %0d pixels, want %0d", name, got, want);
                errors = errors + 1;
            end
        end
    endtask

    integer expect_px;

    initial begin
        expect_px = SRC_W * SRC_H;      // rep=1, so output == source geometry
        repeat (10) @(posedge hclk);
        rst = 0;
        repeat (10) @(posedge hclk);

        // 1 + 4: level stimulus. Level mode must work; strobed mode is not
        // expected to track a level source, so only the level DUT is checked.
        px0 = 0; px1 = 0;
        send_frame_level;
        repeat (4000) @(posedge pclk);
        check("level source, SRC_STROBED=0", px0, expect_px);

        // 2: strobed, uniform.
        px0 = 0; px1 = 0;
        send_frame_strobed(0);
        repeat (4000) @(posedge pclk);
        check("strobed source, SRC_STROBED=1", px1, expect_px);
        // the bug: level-mode write side fed a strobe emits nothing
        if (px0 == 0)
            $display("PASS  strobed source, SRC_STROBED=0 emits nothing (the bug)");
        else begin
            $display("FAIL  expected the level-mode DUT to emit nothing, got %0d", px0);
            errors = errors + 1;
        end

        // 3: strobed, bursty - the real PPU shape.
        px0 = 0; px1 = 0;
        send_frame_strobed(5);
        repeat (6000) @(posedge pclk);
        check("strobed source, bursty stalls", px1, expect_px);

        // 5: lines that under-deliver must be discarded, not jam the write
        // side. Two short lines, then a normal frame: the normal frame must
        // still come out whole. Ending a line purely on pixel count never
        // resyncs here, and everything after is lost.
        px0 = 0; px1 = 0;
        send_short_lines(2);
        send_frame_strobed(0);
        repeat (6000) @(posedge pclk);
        check("short lines then a good frame", px1, expect_px);

        if (errors == 0) $display("\n=== ALL PASS ===");
        else             $display("\n=== %0d FAILURE(S) ===", errors);
        $finish;
    end

    initial begin
        #20_000_000;
        $display("FAIL  timeout");
        $finish;
    end

endmodule
