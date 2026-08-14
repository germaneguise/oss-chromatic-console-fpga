// Icarus bench for fifo_video_rtl, the open replacement for Gowin's encrypted
// fifo_video IP.
//
// Real clock ratio: WrClk = hClk = 16.777216 MHz (video pixels), RdClk = pClk =
// PHY_CLKOUT = 60 MHz (USB). Reset is a single WrClk pulse per "video frame",
// exactly as usbuvcuart_top drives it (RESET_IN | h_sof).
//
// The live suspicion: usbuvcuart_top only emits pixel data when Almost_Full is
// set --
//     if (uvc_fifo_afull) video_txdat_len <= PACKET_SIZE;   // 1024
//     else ...            video_txdat_len <= HEADER_SIZE;   // 12, header only
// so if Almost_Full never asserts, every packet is header-only and the host
// sees no frames. That is the observed hardware symptom.

`timescale 1ps/1ps

module tb_fifo_video;

    localparam WR_HALF = 29802;      // 16.777216 MHz
    localparam RD_HALF = 8333;       // 60 MHz
    localparam [11:0] AFULL_TH = 12'd1012;   // PACKET_SIZE 1024 - HEADER_SIZE 12

    reg         WrClk = 0, RdClk = 0;
    reg         Reset = 1;
    reg         WrEn  = 0, RdEn = 0;
    reg  [7:0]  Data  = 0;
    wire [7:0]  Q;
    wire [12:0] Rnum;
    wire        Empty, Full, Almost_Full, Almost_Empty;

    fifo_video_rtl dut (
        .Data(Data), .Reset(Reset), .WrClk(WrClk), .RdClk(RdClk),
        .WrEn(WrEn), .RdEn(RdEn), .AlmostFullTh(AFULL_TH),
        .Rnum(Rnum), .Almost_Empty(Almost_Empty), .Almost_Full(Almost_Full),
        .Q(Q), .Empty(Empty), .Full(Full));

    always #WR_HALF WrClk = ~WrClk;
    always #RD_HALF RdClk = ~RdClk;

    // ------------------------------------------------------------ reference
    reg  [7:0] refq [0:16383];
    integer    rhead = 0, rtail = 0;
    integer    errors = 0, dchecks = 0, rchecks = 0;
    integer    afull_at = -1;
    integer    max_rnum = 0;

    task oops(input [255:0] what, input integer got, input integer want);
        begin
            if (errors < 12)
                $display("  FAIL %0s: got %0d want %0d   (t=%0t, occ=%0d)",
                         what, got, want, $time, rtail-rhead);
            errors = errors + 1;
        end
    endtask

    // write side
    always @(posedge WrClk) begin
        if (Reset) begin
            rhead = 0; rtail = 0;
        end else if (WrEn && !Full) begin
            refq[rtail] = Data; rtail = rtail + 1;
        end
    end

    // read side - sampled AT the edge, so these are the pre-edge values, which
    // is what first-word fall-through must present
    always @(posedge RdClk) begin
        if (!Reset) begin
            if (Rnum > max_rnum) max_rnum = Rnum;
            if (Almost_Full && afull_at < 0) afull_at = Rnum;

            rchecks = rchecks + 1;
            if (Rnum > (rtail - rhead)) oops("Rnum OVERCOUNT", Rnum, rtail-rhead);

            if (RdEn && !Empty) begin
                dchecks = dchecks + 1;
                if (Q !== refq[rhead]) oops("Q data", Q, refq[rhead]);
                rhead = rhead + 1;
            end
        end
    end

    // --------------------------------------------------------------- stimulus
    integer i, frame;
    reg [7:0] v = 0;

    task frame_reset;   // one WrClk pulse, as h_sof does
        begin
            @(posedge WrClk); Reset = 1;
            @(posedge WrClk); Reset = 0;
            repeat (8) @(posedge RdClk);
        end
    endtask

    initial begin
        Reset = 1;
        repeat (10) @(posedge WrClk);
        Reset = 0;
        repeat (10) @(posedge RdClk);
        $display("after reset: Empty=%0d Full=%0d Rnum=%0d AFull=%0d AEmpty=%0d",
                 Empty, Full, Rnum, Almost_Full, Almost_Empty);

        // ---- fill without reading: does Almost_Full ever assert? ----------
        RdEn = 0;
        for (i = 0; i < 4000; i = i + 1) begin
            @(negedge WrClk); WrEn = 1; Data = v; v = v + 1;
            if (afull_at >= 0 && i > 1200) i = 4000;
        end
        @(negedge WrClk); WrEn = 0;
        repeat (40) @(posedge RdClk);
        $display("");
        if (afull_at >= 0)
            $display("fill: Almost_Full asserted at Rnum=%0d (threshold %0d)", afull_at, AFULL_TH);
        else begin
            $display("fill: Almost_Full NEVER ASSERTED  (max Rnum %0d, occupancy %0d)",
                     max_rnum, rtail-rhead);
            errors = errors + 1;
        end

        // ---- drain, checking order ---------------------------------------
        for (i = 0; i < 3000 && (rtail-rhead) > 0; i = i + 1) begin
            @(negedge RdClk); RdEn = 1;
        end
        @(negedge RdClk); RdEn = 0;
        $display("drain: occupancy now %0d, %0d data checks", rtail-rhead, dchecks);

        // ---- reset WITH TRAFFIC IN FLIGHT --------------------------------
        // The part most likely to be wrong, and the part the previous stimulus
        // never reached: h_sof fires once per video frame while bytes are still
        // crossing the CDC stage and sitting in the deep FIFO.
        for (frame = 0; frame < 4; frame = frame + 1) begin
            // load a few hundred bytes and start draining
            fork
                begin
                    for (i = 0; i < 400; i = i + 1) begin
                        @(negedge WrClk); WrEn = 1; Data = v; v = v + 1;
                    end
                    @(negedge WrClk); WrEn = 0;
                end
                begin
                    repeat (200) @(negedge RdClk);
                    for (i = 0; i < 600; i = i + 1) begin
                        @(negedge RdClk); RdEn = ((($random) % 10) < 5);
                    end
                    @(negedge RdClk); RdEn = 0;
                end
            join
            $display("frame %0d before reset: occ=%0d Rnum=%0d Empty=%0d AFull=%0d",
                     frame, rtail-rhead, Rnum, Empty, Almost_Full);
            frame_reset;
            // after a flush both must agree that nothing is buffered
            repeat (20) @(posedge RdClk);
            if (Rnum !== 0)  oops("Rnum after reset", Rnum, 0);
            if (Empty !== 1) oops("Empty after reset", Empty, 1);
            if (Almost_Full !== 0) oops("AFull after reset", Almost_Full, 0);
            $display("frame %0d after  reset: Rnum=%0d Empty=%0d AFull=%0d  (%0d data checks so far)",
                     frame, Rnum, Empty, Almost_Full, dchecks);
        end

        $display("");
        $display("%0s (%0d errors)", errors ? "FAILED" : "ALL PASS", errors);
        $finish;
    end

    initial begin
        #2000000000;
        $display("TIMEOUT");
        $finish;
    end

endmodule
