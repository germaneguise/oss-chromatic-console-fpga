// fifo_video_rtl.v
//
// Open replacement for Gowin's encrypted fifo_video IP, pin-compatible so
// usbuvcuart_top changes only the module name.
//
// STRUCTURE: cross the clock domain FIRST in a shallow FIFO, then do the deep
// buffering synchronously in the read domain.
//
//   hClk 16.777 MHz                        pClk / PHY_CLKOUT 60 MHz
//     fram_d --> [cdc fifo, 16 deep] --> [sync fifo, 2048x8 BSRAM, FWFT] --> Q
//
// WHY, rather than one deep async FIFO like the IP it replaces. The design's
// worst setup path was
//
//   usb_transact_inst/s_endpt_2 (encrypted controller) -> txpop_o
//     -> video_txpop -> uvc_fifo_rden
//     -> fifo_inst/rbin_num_next -> rgraynext -> mem address
//
// i.e. RdEn arrived and only then did a 12-bit increment, a binary-to-gray
// conversion and the memory addressing happen combinationally. Measured on the
// 5-way integration that tail was ~6.6 ns of a 19.3 ns path and PHY_CLKOUT
// closed with 0.35 ns to spare. A synchronous deep FIFO has no gray code in the
// read path at all, and its memory address is a plain register.
//
// It also fixes an accuracy problem. Rnum is READ-side occupancy and
// usbuvcuart_top uses it directly as a packet length
// (video_txdat_len <= uvc_fifo_rnum[11:0] + HEADER_SIZE). In an async FIFO that
// count comes from a write pointer synchronised across domains, so it lags.
// Here it is a subtraction of two registers in one domain, and exact.
//
// Occupancy counts only what has reached the read-side memory - bytes still in
// the cdc stage are not included, deliberately. Adding them would put an adder
// between the gray-synchronised pointer and the Almost_Full compare, on the
// read-side critical path, to correct what is purely a latency effect. The
// consumer handles it for free by holding its end-of-frame flag off for 32 pClk
// until the crossing has drained - see pEofDly in usbuvcuart_top.v.
//
// Full is not connected by the consumer and overflow is dropped, exactly as
// before; real flow control is can_write upstream.
//
// SIMULATED by sim/fifo_video/tb_system.v, which drives real 160x144 YUY2
// geometry (456-dot lines, 154 lines, 10 of vblank) against the real usb_sof
// packet FSM. That bench is what caught both of this module's data-loss bugs -
// the 32-bit width promotion in the Full compare, and the reset stretch gating
// the write pointer. Synthetic patterns had passed for both.

module fifo_video_rtl #(
    parameter DW = 8,
    parameter AW = 12,              // 4096 entries (2 BSRAM at 8 bits wide)
    // Set when WrClk and RdClk are the same net. With UVC_RESTAMP, uvc_restamp
    // already crosses the raster into pClk, so usbuvcuart_top drives
    // .WrClk(vClk) with vClk == pClk and the stage-1 crossing crosses a clock
    // to itself - gray-coded pointers and two-flop synchronisers doing nothing,
    // the same redundancy 9e87e48 removed from the USB endpoint FIFOs.
    //
    // It is not merely wasteful. Rnum reports the deep FIFO only, so bytes
    // parked in the crossing are invisible to the terminating packet's
    // Rnum + HEADER_SIZE length, and the consumer covers that blind spot by
    // delaying end-of-frame (pEofDly). Bypassing the stage removes the
    // uncounted staging entirely rather than waiting it out.
    parameter SINGLE_CLOCK = 0
)(
    input  [DW-1:0]   Data,
    input             Reset,        // asserted in the WrClk domain (RESET_IN | h_sof)
    input             WrClk,
    input             RdClk,
    input             WrEn,
    input             RdEn,
    input  [11:0]     AlmostFullTh,  // ditto
    output [12:0]     Rnum,          // width fixed by the consumer, not by AW
    output            Almost_Empty,
    output            Almost_Full,
    output [DW-1:0]   Q,
    output            Empty,
    output            Full,
    output [4:0]      DbgCdcCount   // debug only
);

    // SYNCHRONOUS reset, matching RESET_SYNC=true in fifo_video.ipc, and not
    // merely for parity: usbuvcuart_top drives Reset as a combinational OR,
    //     .Reset(RESET_IN | h_sof)   with h_sof = yFrameValid & ~yFrameValid_r1
    // so treating it as an ASYNC reset lets any glitch on that network flush the
    // whole FIFO. A FIFO that is spuriously flushed never reaches the 1012 bytes
    // Almost_Full needs, the write FSM then emits header-only packets, and the
    // host sees no frames while everything still enumerates.
    //
    // The stretch is for the CROSSING ONLY. It must not gate the write pointer:
    // the video source has no backpressure, so every cycle the write side spends
    // in reset is a byte silently swallowed. An earlier version stretched to 15
    // WrClk and applied that to the pointer, which ate the first 15 bytes of
    // every frame - measured at exactly 14 lost per frame in
    // sim/fifo_video/tb_system.v, surfacing as a short frame tail because Rnum
    // then under-reports what the terminating packet should carry.
    //
    // Note the stretch is barely needed even for the crossing: hClk is 16.777
    // MHz against RdClk 60 MHz, so one WrClk-wide pulse is already ~3.5 RdClk
    // periods. Three cycles is margin, not necessity.
    reg [1:0] wrst_cnt = 2'h3;
    always @(posedge WrClk)
        if (Reset)              wrst_cnt <= 2'h3;
        else if (wrst_cnt != 0) wrst_cnt <= wrst_cnt - 1'b1;
    wire wrst_long = (wrst_cnt != 0);   // crosses to RdClk
    wire wrst      = Reset;             // write pointer: the pulse itself

    reg [1:0] rrst_sr = 2'b11;
    always @(posedge RdClk) rrst_sr <= {rrst_sr[0], wrst_long};
    // One clock means no crossing to stretch for, and the two-flop delay would
    // only postpone the deep FIFO's reset past the write pointer's - which is
    // the direction that swallows the first bytes of a frame.
    wire rrst = SINGLE_CLOCK ? Reset : rrst_sr[1];

    // ------------------------------------------------ stage 1: the crossing
    wire [DW-1:0] cdc_q;
    wire          cdc_empty, cdc_full;
    wire [4:0]    cdc_rcount;
    wire          sync_full;
    wire          deep_wren;
    wire [DW-1:0] deep_data;

    generate
    if (SINGLE_CLOCK) begin : gen_no_cdc
        // Straight through: the writer feeds the deep FIFO in its own domain,
        // so nothing is ever staged outside what Rnum reports.
        assign deep_wren  = WrEn && !sync_full;
        assign deep_data  = Data;
        assign cdc_q      = {DW{1'b0}};
        assign cdc_empty  = 1'b1;
        assign cdc_full   = sync_full;
        assign cdc_rcount = 5'd0;
    end else begin : gen_cdc
        wire cdc_rd = !cdc_empty && !sync_full;   // drain continuously
        fifo_video_cdc #(.DW(DW), .AW(4)) u_cdc (
            .WrClk (WrClk), .wrst (wrst), .WrEn (WrEn && !cdc_full), .Data (Data),
            .RdClk (RdClk), .rrst (rrst), .RdEn (cdc_rd),            .Q    (cdc_q),
            .Empty (cdc_empty), .Full (cdc_full), .RCount (cdc_rcount)
        );
        assign deep_wren = cdc_rd;
        assign deep_data = cdc_q;
    end
    endgenerate

    // ------------------------------------------- stage 2: the deep buffering
    fifo_video_sync #(.DW(DW), .AW(AW)) u_deep (
        .clk   (RdClk), .rst (rrst),
        .WrEn  (deep_wren), .Data (deep_data),
        .RdEn  (RdEn),   .Q    (Q),
        .Rnum  (Rnum),   .Empty (Empty), .Full (sync_full),
        .AlmostFullTh (AlmostFullTh),
        .Almost_Full  (Almost_Full), .Almost_Empty (Almost_Empty)
    );

    assign Full = cdc_full;
    assign DbgCdcCount = cdc_rcount;

endmodule


// --------------------------------------------------------------------------
// Shallow dual-clock crossing. Gray-coded pointers, two-flop synchronisers.
// Small enough for distributed RAM.
// --------------------------------------------------------------------------
module fifo_video_cdc #(parameter DW = 8, parameter AW = 4)
(
    input             WrClk, wrst, WrEn,
    input  [DW-1:0]   Data,
    input             RdClk, rrst, RdEn,
    output [DW-1:0]   Q,
    output            Empty, Full,
    output [AW:0]     RCount        // read-domain view of what is still in here
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    reg [AW:0] wbin, wgray, rbin, rgray;
    reg [AW:0] wq1, wq2, rq1, rq2;

    function [AW:0] g2b(input [AW:0] g);
        integer i; begin
            g2b[AW] = g[AW];
            for (i = AW-1; i >= 0; i = i-1) g2b[i] = g2b[i+1] ^ g[i];
        end
    endfunction
    function [AW:0] b2g(input [AW:0] b); b2g = (b >> 1) ^ b; endfunction

    always @(posedge WrClk) if (WrEn && !Full) mem[wbin[AW-1:0]] <= Data;

    always @(posedge WrClk)
        if (wrst) begin wbin <= 0; wgray <= 0; end
        else if (WrEn && !Full) begin wbin <= wbin + 1'b1; wgray <= b2g(wbin + 1'b1); end

    always @(posedge WrClk) if (wrst) begin wq1 <= 0; wq2 <= 0; end
                            else begin wq1 <= rgray; wq2 <= wq1; end

    always @(posedge RdClk)
        if (rrst) begin rbin <= 0; rgray <= 0; end
        else if (RdEn && !Empty) begin rbin <= rbin + 1'b1; rgray <= b2g(rbin + 1'b1); end

    always @(posedge RdClk) if (rrst) begin rq1 <= 0; rq2 <= 0; end
                            else begin rq1 <= wgray; rq2 <= rq1; end

    assign Q     = mem[rbin[AW-1:0]];              // async read, distributed RAM
    // The subtraction MUST stay AW+1 bits wide. Writing it inline against the
    // integer (1<<AW) promotes the whole expression to 32 bits, which destroys
    // the modular wraparound: once wbin wraps 31->0 while the read pointer is
    // still near the top, 0-30 evaluates as unsigned 4294967266 >= 16 and Full
    // asserts spuriously until the read pointer wraps too. That silently drops
    // a few percent of writes forever - measured at 3.3% in sim, and enough on
    // hardware to keep occupancy below the 1012 Almost_Full threshold, so the
    // write FSM never commits to a full packet and the host gets no frames.
    wire [AW:0] wcount = wbin - g2b(wq2);
    wire [AW:0] rcount = g2b(rq2) - rbin;

    assign Empty  = (rgray == rq2);
    assign Full   = wcount[AW];
    assign RCount = rcount;
endmodule


// --------------------------------------------------------------------------
// Deep synchronous FIFO, BSRAM, first-word fall-through. One clock, so
// occupancy is exact and there is no gray code in the read path.
// --------------------------------------------------------------------------
module fifo_video_sync #(parameter DW = 8, parameter AW = 12)
(
    input             clk, rst,
    input             WrEn,
    input  [DW-1:0]   Data,
    input             RdEn,
    output [DW-1:0]   Q,
    output [12:0]     Rnum,          // width fixed by the consumer, not by AW
    output            Empty, Full,
    input  [11:0]     AlmostFullTh,  // ditto
    output            Almost_Full, Almost_Empty
);
    (* syn_ramstyle = "block_ram" *)
    reg [DW-1:0] mem [0:(1<<AW)-1];

    reg [AW:0] wptr, rptr;
    wire [AW:0] cnt = wptr - rptr;          // bytes still in memory
    wire mem_empty  = (wptr == rptr);

    // FWFT: q_reg presents the head, RdEn pops it. Prefetch whenever memory has
    // data and the output slot is free or being consumed this cycle. The memory
    // address is rptr, a register - RdEn only gates the enable, so it is not in
    // the address path. That is the whole point of this rewrite.
    reg [DW-1:0] q_reg;
    reg          q_valid;
    wire         int_rd = !mem_empty && (!q_valid || RdEn);

    always @(posedge clk) begin
        if (rst) begin
            wptr <= 0; rptr <= 0; q_valid <= 1'b0;
        end else begin
            if (WrEn && !Full) begin
                mem[wptr[AW-1:0]] <= Data;
                wptr <= wptr + 1'b1;
            end
            if (int_rd) begin
                q_reg   <= mem[rptr[AW-1:0]];
                rptr    <= rptr + 1'b1;
                q_valid <= 1'b1;
            end else if (RdEn) begin
                q_valid <= 1'b0;
            end
        end
    end

    assign Q            = q_reg;
    assign Empty        = !q_valid;
    assign Full         = cnt[AW];
    // Rnum must mean what usbuvcuart_top's write FSM assumes, because at usb_sof
    // it commits to a full 1012-byte payload the moment Almost_Full is set and
    // there is no backpressure to fall back on - can_write is gated on pixel
    // position only, so a short packet is simply short.
    //
    // The two uses of the count are NOT the same quantity, so they are split:
    //
    //  - Almost_Full compares memory only. Upstream's comment at the
    //    uvc_fifo_afull check says "one extra byte is always kept at the fifo
    //    output", i.e. it expects a memory-only count; including the head byte
    //    made Almost_Full fire with exactly 1012 available and zero slack
    //    instead of 1013. Keeping the compare on cnt alone also keeps any adder
    //    off the read-side critical path.
    //
    //  - Rnum reports what is actually READABLE, which is memory plus the byte
    //    already fronted on Q. This matters only for the terminating packet,
    //    whose length is Rnum + HEADER_SIZE, and it matters absolutely: the
    //    format is uncompressed YUY2, so dwMaxVideoFrameSize is exactly 46080
    //    and the host knows it. A frame delivered one byte short is not a frame
    //    with one bad pixel, it is a frame the driver discards - which presents
    //    as no video at all while everything else looks healthy. The +1 lands
    //    on the video_txdat_len register path, not on the Almost_Full compare.
    //
    // Bytes still in the CDC stage are deliberately NOT counted here. A single
    // async FIFO (which this replaces) counts them inherently, and the frame
    // tail is short by up to the crossing depth without them - measured 525
    // against 540 at end of frame in sim/fifo_video/tb_system.v. But adding
    // InFlight puts a 13-bit adder between the gray-synchronised pointer and
    // the Almost_Full compare, on the read-side critical path, to correct a
    // pure latency effect. The consumer fixes it for free instead by delaying
    // its end-of-frame flag until the crossing has drained - see pEofDly in
    // usbuvcuart_top.v. Rnum is therefore a plain pointer difference.
    wire [12:0] mem_cnt = {{(12-AW){1'b0}}, cnt};
    assign Rnum         = mem_cnt + {12'd0, q_valid};
    assign Almost_Full  = (mem_cnt >= {1'b0, AlmostFullTh});
    assign Almost_Empty = (Rnum <= 1);
endmodule
