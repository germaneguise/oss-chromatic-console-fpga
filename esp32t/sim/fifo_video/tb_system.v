// System-level bench for fifo_video_rtl: real video geometry on the write side,
// the real usb_sof-driven packet FSM on the read side.
//
// Everything before this bench drove the FIFO with synthetic patterns, which is
// why it passed while hardware failed. The dynamics that matter are:
//
//   write: 160x144 YUY2 = 46080 bytes/frame at 60 Hz = 2.76 MB/s average, but
//          delivered in per-row bursts with blanking gaps, on hClk 16.777 MHz
//   read:  usb_sof every 125 us. At each SOF the FSM looks at Almost_Full and
//          commits to a packet length for the WHOLE microframe:
//              afull      -> PACKET_SIZE (1024) = 12 header + 1012 payload
//              lastPacket -> Rnum + HEADER_SIZE
//              otherwise  -> HEADER_SIZE, i.e. no pixels at all
//          then pops 1012 bytes at 60 MHz during the packet.
//
// It takes ~367 us to accumulate 1012 bytes at the average rate, so
// Almost_Full should assert roughly every third microframe and the occupancy
// should oscillate around the threshold. If it never reaches it, every packet
// is header-only and the host sees nothing - the observed hardware symptom.
//
// PASS = the payload bytes emitted per frame equal the bytes written per frame.

`timescale 1ps/1ps

module tb_system;
    localparam WR_HALF = 29802;          // hClk 16.777216 MHz
    localparam RD_HALF = 8333;           // pClk 60 MHz
    localparam WIDTH = 160, HEIGHT = 144;
    localparam BYTES_PER_ROW = WIDTH*2;  // YUY2
    // GB LCD: 456 dots per scanline, 154 lines (144 visible + 10 vblank).
    // hclk is exactly 4x the 4.194304 MHz dot clock, so a line is 456*4 = 1824
    // hClk and a frame is 154*1824 = 280896 hClk = 16.742 ms -> 59.73 Hz.
    localparam ROW_CLKS  = 1824;
    localparam VBLANK_ROWS = 10;
    localparam PACKET_SIZE = 1024, HEADER_SIZE = 12;
    localparam PAYLOAD = PACKET_SIZE - HEADER_SIZE;   // 1012
    localparam SOF_PCLKS = 7500;         // 125 us microframe at 60 MHz

    reg WrClk=0, RdClk=0, Reset=1, WrEn=0, RdEn=0;
    reg [7:0] Data=0;
    wire [7:0] Q; wire [12:0] Rnum;
    wire Empty, Full, Almost_Full, Almost_Empty;
    wire [4:0] DbgCdcCount;

    fifo_video_rtl dut(.Data(Data),.Reset(Reset),.WrClk(WrClk),.RdClk(RdClk),
        .WrEn(WrEn),.RdEn(RdEn),.AlmostFullTh(PAYLOAD[11:0]),.Rnum(Rnum),
        .Almost_Empty(Almost_Empty),.Almost_Full(Almost_Full),.Q(Q),
        .Empty(Empty),.Full(Full),.DbgCdcCount(DbgCdcCount));

    always #WR_HALF WrClk=~WrClk;
    always #RD_HALF RdClk=~RdClk;

    integer wrote_this_frame=0, read_this_frame=0, frame=0;
    integer afull_at_sof=0, header_only_sof=0, total_sof=0;
    reg pImage_eof=0, pLastPacket=0;

    // ------------------------------------------------ write side (video)
    integer row, b;
    initial begin
        repeat(20) @(posedge WrClk); Reset=0;
        for (frame=0; frame<3; frame=frame+1) begin
            // h_sof: one WrClk pulse, flushes the FIFO
            @(negedge WrClk); Reset=1; @(negedge WrClk); Reset=0;
            wrote_this_frame=0; read_this_frame=0; pImage_eof=0; pLastPacket=0;
            for (row=0; row<HEIGHT; row=row+1) begin
                for (b=0; b<BYTES_PER_ROW; b=b+1) begin
                    @(negedge WrClk); WrEn=1; Data=b[7:0];
                    wrote_this_frame=wrote_this_frame+1;
                end
                @(negedge WrClk); WrEn=0;
                repeat (ROW_CLKS-BYTES_PER_ROW-1) @(negedge WrClk);   // blanking
            end
            // vblank: no writes for 10 line times. This is when the frame's
            // tail actually drains and the terminating packet gets sent.
            pImage_eof=1; @(negedge WrClk); pImage_eof=0;
            repeat (VBLANK_ROWS*ROW_CLKS) @(negedge WrClk);
            $display("frame %0d: wrote %0d, host got %0d payload bytes  (SOFs %0d, afull %0d, header-only %0d)",
                     frame, wrote_this_frame, read_this_frame, total_sof, afull_at_sof, header_only_sof);
            if (read_this_frame < wrote_this_frame*9/10)
                $display("   *** SHORT: host received %0d%% of the frame ***",
                         (read_this_frame*100)/wrote_this_frame);
            total_sof=0; afull_at_sof=0; header_only_sof=0;
        end
        $finish;
    end

    // ------------------------------------------- read side (usb packet FSM)
    integer sofc=0, i;
    reg [11:0] txlen;
    // mirrors usbuvcuart_top: hold the end-of-frame flag off until the clock
    // crossing has drained, so Rnum reflects the whole frame tail
    reg [5:0] pEofDly = 6'd33;
    always @(posedge RdClk)
        if (pImage_eof)            pEofDly <= 6'd0;
        else if (pEofDly != 6'd33) pEofDly <= pEofDly + 1'b1;
    wire pImage_eof_d = (pEofDly == 6'd32);

    always @(posedge RdClk) begin
        if (pImage_eof_d) pLastPacket <= 1'b1;
        sofc <= sofc + 1;
    end

    initial begin
        forever begin
            // wait a microframe
            repeat (SOF_PCLKS) @(posedge RdClk);
            total_sof = total_sof + 1;
            // usb_sof: commit to a length for this microframe
            if (Almost_Full)      begin txlen = PACKET_SIZE; afull_at_sof=afull_at_sof+1; end
            else if (pLastPacket) begin
                txlen = Rnum[11:0] + HEADER_SIZE; pLastPacket=0;
                $display("    LAST-PACKET sof: Rnum=%0d txlen=%0d Empty=%0d cdc-in-flight?", Rnum, txlen, Empty);
            end
            else                  begin txlen = HEADER_SIZE; header_only_sof=header_only_sof+1; end
            // send it: pop for pktByteCount in [HEADER_SIZE-1, txlen-1)
            if (txlen > HEADER_SIZE) begin
                for (i=0; i<txlen-HEADER_SIZE; i=i+1) begin
                    @(negedge RdClk);
                    if (!Empty) begin RdEn=1; read_this_frame=read_this_frame+1; end
                    else RdEn=0;
                end
                @(negedge RdClk); RdEn=0;
            end
        end
    end

    // ---- byte accounting: where does the frame tail actually go?
    integer cdc_drop=0, cdc_in=0, deep_in=0, popped=0;
    always @(posedge WrClk) if (!Reset) begin
        if (WrEn &&  dut.cdc_full) cdc_drop <= cdc_drop + 1;
        if (WrEn && !dut.cdc_full) cdc_in   <= cdc_in   + 1;
    end
    always @(posedge RdClk) if (!dut.rrst) begin
        // deep_wren rather than the old cdc_rd: it is the deep FIFO's write
        // enable in both configurations, whereas cdc_rd now lives inside the
        // gen_cdc generate block and does not exist when SINGLE_CLOCK bypasses it.
        if (dut.deep_wren)   deep_in <= deep_in + 1;
        if (RdEn && !Empty)  popped  <= popped  + 1;
    end
    always @(posedge RdClk) if (pImage_eof_d)
        $display("    at eof+32: cdc_in=%0d cdc_drop=%0d deep_in=%0d popped=%0d  cdcCount=%0d Rnum=%0d",
                 cdc_in, cdc_drop, deep_in, popped, DbgCdcCount, Rnum);

    initial begin #60000000000; $display("TIMEOUT"); $finish; end
endmodule
