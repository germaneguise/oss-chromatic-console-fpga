// High-bandwidth (two transactions per microframe) bench for the UVC packet
// FSM against the real fifo_video_rtl.
//
// DOES NOT FAITHFULLY REPRODUCE HARDWARE - do not treat it as a reference.
// It re-implements the packet FSM behaviourally instead of instantiating it, so
// it can only check an understanding of the RTL, not the RTL itself. A
// behavioural model can agree with the real design on every case the bench
// reaches and still diverge on the one that matters, so a green run here is
// not evidence about hardware.
//
// It is kept because the geometry and pacing are right and it is the only bench
// that exercises the two-transaction path at all - useful scaffolding, but every
// conclusion from it needs confirming on hardware.
//
// The real gap remains: usbuvcuart_top instantiates USB_Device_Controller_Top
// and Gowin_PLL_UVC (vendor IP and a hard PLL macro), so the packet FSM cannot
// be simulated in place without first being split into its own module.
//
// WHY THIS EXISTS. tb_system drives 160x144 = 46080 bytes/frame = 2.76 MB/s,
// which fits in one 1024-byte transaction per microframe. It therefore never
// arms a SECOND transaction, and the continuation path - pContinuation set, no
// UVC payload header, read gate open from pktByteCount 0 - has never been
// simulated. That is the path with the bug, and it is why 320x288 shipped
// delivering 30% of its frames 11 bytes over length while every bench passed.
//
// 320x288 YUY2 = 184320 bytes/frame at 60 Hz = 11.06 MB/s, past what one
// transaction per microframe carries (8.10 MB/s), so it depends on the second
// transaction and exercises the continuation arming on every frame.
//
// With UVC_RESTAMP the writer is in pClk, so WrClk and RdClk are the same net
// and SINGLE_CLOCK bypasses the crossing - modelled here by driving both from
// one clock.
//
// PASS = payload bytes delivered per frame == 184320 exactly. Uncompressed YUY2
// means the host knows dwMaxVideoFrameSize precisely and discards any frame
// that misses it, so "close" is a dropped frame, not a blemish.
//
// LAST_CONT_ADD sweeps the constant under test: the terminating packet's length
// when it lands as the SECOND transaction. Measured on hardware:
//     Rnum + 12 -> 184331 (+11)      Rnum + 0 -> 184319 (-1)
`timescale 1ps/1ps

module tb_hbw #(
    parameter LAST_CONT_ADD = 1,   // continuation terminating: Rnum + this
    parameter LAST_HDR_ADD  = 12   // header-bearing terminating: Rnum + this
);
    localparam CLK_HALF = 8333;                  // pClk 60 MHz, single domain
    localparam WIDTH = 320, HEIGHT = 288;
    localparam FRAME_BYTES = WIDTH*HEIGHT*2;     // 184320
    localparam PACKET_SIZE = 1024, HEADER_SIZE = 12;
    localparam PAYLOAD = PACKET_SIZE - HEADER_SIZE;   // 1012
    localparam SOF_PCLKS = 7500;                 // 125 us at 60 MHz

    reg Clk=0, Reset=1, WrEn=0, RdEn=0;
    reg [7:0] Data=0;
    wire [7:0] Q; wire [12:0] Rnum;
    wire Empty, Full, Almost_Full, Almost_Empty;
    wire [4:0] DbgCdcCount;

    fifo_video_rtl #(.SINGLE_CLOCK(1)) dut(
        .Data(Data),.Reset(Reset),.WrClk(Clk),.RdClk(Clk),
        .WrEn(WrEn),.RdEn(RdEn),.AlmostFullTh(PAYLOAD[11:0]),.Rnum(Rnum),
        .Almost_Empty(Almost_Empty),.Almost_Full(Almost_Full),.Q(Q),
        .Empty(Empty),.Full(Full),.DbgCdcCount(DbgCdcCount));

    always #CLK_HALF Clk=~Clk;

    integer wrote_this_frame=0, delivered=0, frame=0;
    integer two_txn=0, one_txn=0, hdr_only=0, errors=0;
    reg pImage_eof=0, pLastPacket=0;

    // ------------------------------------------------ write side (restamped)
    // uvc_restamp emits 3 pClk per output pixel and YUY2 is 2 bytes/pixel, so
    // the active raster is 2 bytes every 3 clocks; the rest of the 60 Hz frame
    // period is blanking, which is when the tail drains and the terminating
    // packet goes out.
    // Lines are PACED, not back-to-back. uvc_restamp drains a line buffer at
    // REP rate but is still gated by the source raster, so the 288 output lines
    // are spread across the whole 60 Hz frame with per-line blanking. Writing
    // them contiguously instead overruns the 4096-byte FIFO for 4.6 ms and then
    // starves it for 12 ms, which is not the dynamic the hardware sees.
    //
    // GB is 154 lines/frame; at REP=2 that is 308 output line slots in one
    // 16.67 ms frame = 1e6 pClk at 60 MHz.
    localparam TOTAL_LINES = 308;
    localparam LINE_CLKS   = 1000000 / TOTAL_LINES;   // 3246
    localparam ACTIVE_CLKS = WIDTH * 3;               // 960, 3 pClk per pixel
    integer row, px;
    initial begin
        repeat(20) @(posedge Clk); Reset=0;
        for (frame=0; frame<16; frame=frame+1) begin
            @(negedge Clk); Reset=1; @(negedge Clk); Reset=0;
            wrote_this_frame=0; delivered=0; pImage_eof=0; pLastPacket=0;
            for (row=0; row<HEIGHT; row=row+1) begin
                for (px=0; px<WIDTH; px=px+1) begin
                    @(negedge Clk); WrEn=1; Data=px[7:0];
                    wrote_this_frame=wrote_this_frame+1;
                    @(negedge Clk); WrEn=1; Data=~px[7:0];
                    wrote_this_frame=wrote_this_frame+1;
                    @(negedge Clk); WrEn=0;          // 3rd clock of the pixel
                end
                @(negedge Clk); WrEn=0;
                repeat (LINE_CLKS - ACTIVE_CLKS - 1) @(negedge Clk);
            end
            pImage_eof=1; @(negedge Clk); pImage_eof=0;
            repeat ((TOTAL_LINES - HEIGHT) * LINE_CLKS) @(negedge Clk);
            if (delivered !== FRAME_BYTES) errors = errors + 1;
            $display("frame %0d: wrote %0d, delivered %0d (want %0d, err %0d)  2txn=%0d 1txn=%0d hdrOnly=%0d%s",
                     frame, wrote_this_frame, delivered, FRAME_BYTES,
                     delivered-FRAME_BYTES, two_txn, one_txn, hdr_only,
                     (delivered===FRAME_BYTES) ? "  OK" : "   <<< WRONG LENGTH");
            two_txn=0; one_txn=0; hdr_only=0;
        end
        $display("\nLAST_CONT_ADD=%0d LAST_HDR_ADD=%0d -> %0d frame(s) wrong",
                 LAST_CONT_ADD, LAST_HDR_ADD, errors);
        $display(errors ? "FAIL" : "PASS");
        $finish;
    end

    // ------------------------------------------- read side (usb packet FSM)
    // Mirrors usbuvcuart_top: arm at usb_sof, and if DATA1 was promised, re-arm
    // for the second transaction with pContinuation set.
    reg [5:0] pEofDly = 6'd33;
    always @(posedge Clk)
        if (pImage_eof)            pEofDly <= 6'd0;
        else if (pEofDly != 6'd33) pEofDly <= pEofDly + 1'b1;
    wire pImage_eof_d = (pEofDly == 6'd32);
    always @(posedge Clk) if (pImage_eof_d) pLastPacket <= 1'b1;

    reg [11:0] txlen; reg cont, data1; integer i, popped;

    task send;   // one transaction: pop payload, count what the host receives
        begin
            popped = 0;
            // Header-bearing packets spend HEADER_SIZE bytes on the header;
            // continuations are payload from byte 0.
            for (i=0; i<(cont ? txlen : (txlen>HEADER_SIZE ? txlen-HEADER_SIZE : 0)); i=i+1) begin
                @(negedge Clk);
                if (!Empty) begin RdEn=1; popped=popped+1; end else RdEn=0;
            end
            @(negedge Clk); RdEn=0;
            // COUNT THE DECLARED LENGTH, not what the FIFO happened to yield.
            // The host counts bytes on the wire: a transaction of length L
            // carries L bytes, of which HEADER_SIZE are header unless this is a
            // continuation. Counting pops instead hides the entire defect -
            // over-long packets are exactly the case where the declared length
            // exceeds what the FIFO holds.
            delivered = delivered + (cont ? txlen
                                          : (txlen > HEADER_SIZE ? txlen-HEADER_SIZE : 0));
            if (popped != (cont ? txlen : (txlen > HEADER_SIZE ? txlen-HEADER_SIZE : 0)))
                $display("    underrun: declared %0d payload, FIFO yielded %0d (Rnum was %0d)",
                         cont ? txlen : txlen-HEADER_SIZE, popped, Rnum);
        end
    endtask

    initial begin
        forever begin
            repeat (SOF_PCLKS) @(posedge Clk);
            // DATA1 promise: two really are available, and not the closing packet
            data1 = (!pLastPacket) && (Rnum >= 2*(PACKET_SIZE-HEADER_SIZE));
            cont  = 0;
            if (Almost_Full)      txlen = PACKET_SIZE;
            else if (pLastPacket) begin txlen = Rnum[11:0] + LAST_HDR_ADD; pLastPacket=0; end
            else                  begin txlen = HEADER_SIZE; hdr_only=hdr_only+1; end
            send;
            if (data1) begin
                two_txn = two_txn + 1;
                cont = 1;                       // second one is payload-only
                if (Almost_Full)      txlen = PACKET_SIZE;
                else if (pLastPacket) begin txlen = Rnum[11:0] + LAST_CONT_ADD; pLastPacket=0; end
                else                  txlen = 12'd0;
                send;
            end else one_txn = one_txn + 1;
        end
    end

    initial begin #2000000000000; $display("TIMEOUT"); $finish; end
endmodule
