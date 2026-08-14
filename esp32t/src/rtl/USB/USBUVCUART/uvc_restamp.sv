// uvc_restamp.sv
//
// Crosses the video raster from hClk to pClk through ping-pong line buffers,
// and replays it at REP x REP, regenerating ModRetro's raster contract so
// EVERYTHING DOWNSTREAM IS UNTOUCHED - their colour space converter, fram_d,
// uvc_fifo and packet packer all see exactly what they saw before, just on the
// USB clock and at the output geometry.
//
// WHY THIS SHAPE
// --------------
// The previous attempt expanded 2x on the READ side of uvc_fifo, reassembling
// YUY2 bytes. It failed on hardware eleven times while passing 18/18 in
// simulation, because it reimplemented byte packing their design already does
// correctly. Crossing on RGB instead means:
//
//   - the slow domain only ever carries SOURCE-rate data, so the CSC and FIFO
//     write bandwidth limits that forced a 4:4:4 detour disappear. Their CSC
//     gets 20 Mpx/s at 60 MHz against the 5.53 a 320x288 frame needs.
//   - scaling ahead of the CSC becomes affordable again, so their 4:2:2 pair
//     averaging is lossless for free: each averaged pair is one source pixel
//     with itself. No 4:4:4 mode, no chroma detour.
//   - the byte layer is theirs, and is already proven by the working 160x144
//     path and by commit 572ac9e, where 320x288 through this same unmodified
//     pipeline streamed correctly.
//
// A WHOLE LINE, OR NOTHING
// ------------------------
// Their packer cannot be back-pressured: once a packet is under way it pops
// every cycle, so a beat with no data is not a stall, it is a stale byte
// transmitted and counted. The previous design tried to guarantee liveness with
// credit counters and got it wrong repeatedly.
//
// Here a line is only ever replayed once it is COMPLETE in a buffer, so for the
// whole of that line the data is provably present. The guarantee is structural
// and needs one comparison, not arithmetic.
//
// NO BYPASS. REP=1 is 160x144 and REP=2 is 320x288, through identical logic.
// Two parallel pipelines is exactly what hid the last failure: the 160 path
// worked, the 320 path did not, and neither told us anything about the other.
// REP=1 must reproduce the un-restamped output byte for byte.

module uvc_restamp #(
    parameter int SRC_W       = 160,
    parameter int SRC_H       = 144,
    parameter int NBUF        = 4,     // 2 suffices; BSRAM is nearly free
    parameter int CLKS_PER_PX = 3,     // their hCount3 contract
    parameter int LINE_GAP    = 16,    // output blanking, ends a line for them
    parameter int FRAME_LEAD  = 16     // frame_valid leads enable, see below
) (
    // ---- source side, hClk ----
    input  wire        hclk,
    input  wire        hrst,
    input  wire        s_frame_valid,
    input  wire        s_enable,
    input  wire [17:0] s_data,

    // ---- output side, pClk ----
    input  wire        pclk,
    input  wire        prst,
    input  wire [1:0]  rep,            // 1 or 2, latched per frame
    output reg         m_frame_valid,
    output reg         m_line_valid,
    output reg         m_enable,
    output reg [17:0]  m_data
);

    localparam int SELW   = $clog2(NBUF);
    localparam int STRIDE = 256;                       // >= SRC_W, power of two
    localparam int AW     = $clog2(NBUF * STRIDE);

    // The buffer IS the clock crossing: written on hclk, read on pclk. Gowin
    // BSRAM supports independent clocks natively, so no separate FIFO.
    reg [17:0] lbuf [0:NBUF*STRIDE-1];

    // =====================================================================
    // Write side (hclk)
    //
    // s_enable is a LEVEL for the whole active line and a pixel lasts
    // CLKS_PER_PX cycles, so the write side keeps its own phase counter -
    // the same shape as their hCount3.
    // =====================================================================
    reg [1:0]      w_phase;
    reg [SELW-1:0] w_sel;
    reg [8:0]      w_idx;
    reg            s_en_q;
    reg [NBUF-1:0] w_tog;              // toggles when a line completes
    reg            w_frame_tog;        // toggles at each source frame start
    reg            s_fv_q;

    always_ff @(posedge hclk or posedge hrst) begin
        if (hrst) begin
            w_phase <= 2'd0; w_sel <= '0; w_idx <= '0;
            s_en_q  <= 1'b0; w_tog <= '0; w_frame_tog <= 1'b0; s_fv_q <= 1'b0;
        end else begin
            s_en_q <= s_enable;
            s_fv_q <= s_frame_valid;

            // Source frame start. Crossed as a toggle so the read side sees it
            // exactly once regardless of clock ratio.
            if (s_frame_valid && !s_fv_q) begin
                w_frame_tog <= ~w_frame_tog;
                w_sel       <= '0;
                w_idx       <= '0;
                w_phase     <= 2'd0;
            end else if (s_enable) begin
                // Capture one pixel per CLKS_PER_PX cycles.
                if (w_phase == 2'(CLKS_PER_PX - 1)) begin
                    w_phase <= 2'd0;
                    if (w_idx < 9'(SRC_W)) begin
                        lbuf[{w_sel, w_idx[7:0]}] <= s_data;
                        w_idx <= w_idx + 9'd1;
                    end
                end else begin
                    w_phase <= w_phase + 2'd1;
                end
            end else if (s_en_q) begin
                // Line just ended: publish it and move on.
                w_tog[w_sel] <= ~w_tog[w_sel];
                w_idx        <= '0;
                w_phase      <= 2'd0;
                w_sel        <= (w_sel == SELW'(NBUF-1)) ? '0 : w_sel + SELW'(1);
            end
        end
    end

    // =====================================================================
    // Read side (pclk)
    // =====================================================================
    // Two-flop synchronisers on the single-bit toggles. Nothing multi-bit
    // crosses, so there is nothing to tear.
    reg [NBUF-1:0] w_tog_s1, w_tog_s2, r_tog;
    reg            frm_s1, frm_s2, frm_s3;
    always_ff @(posedge pclk or posedge prst) begin
        if (prst) begin
            w_tog_s1 <= '0; w_tog_s2 <= '0;
            frm_s1 <= 1'b0; frm_s2 <= 1'b0; frm_s3 <= 1'b0;
        end else begin
            w_tog_s1 <= w_tog;  w_tog_s2 <= w_tog_s1;
            frm_s1 <= w_frame_tog; frm_s2 <= frm_s1; frm_s3 <= frm_s2;
        end
    end
    wire frame_start = (frm_s2 != frm_s3);

    localparam [1:0] ST_IDLE = 2'd0,   // waiting for a complete line
                     ST_LEAD = 2'd1,   // frame_valid up, enable still low
                     ST_PIX  = 2'd2,
                     ST_GAP  = 2'd3;

    reg [1:0]      st;
    reg [SELW-1:0] r_sel;
    reg [8:0]      r_px;               // source pixel within the line
    reg [1:0]      r_dup;              // which copy of this pixel
    reg [1:0]      r_phase;            // CLKS_PER_PX
    reg            r_pass;             // which copy of this line
    reg [9:0]      r_line;             // output lines emitted this frame
    reg [8:0]      r_gap;
    reg [1:0]      rep_l;              // latched at frame start

    wire line_ready = (w_tog_s2[r_sel] != r_tog[r_sel]);
    wire [9:0] out_lines = 10'(SRC_H) * {8'd0, rep_l};

    always_ff @(posedge pclk or posedge prst) begin
        if (prst) begin
            st <= ST_IDLE; r_sel <= '0; r_px <= '0; r_dup <= 2'd0;
            r_phase <= 2'd0; r_pass <= 1'b0; r_line <= '0; r_gap <= '0;
            r_tog <= '0; rep_l <= 2'd1;
            m_frame_valid <= 1'b0; m_line_valid <= 1'b0; m_enable <= 1'b0;
            m_data <= 18'd0;
        end else if (frame_start) begin
            // Realign to the source frame. Everything half-emitted belongs to
            // the previous one.
            st            <= ST_LEAD;
            r_sel         <= '0;
            r_px          <= '0;
            r_dup         <= 2'd0;
            r_phase       <= 2'd0;
            r_pass        <= 1'b0;
            r_line        <= '0;
            r_gap         <= '0;
            r_tog         <= w_tog_s2;      // adopt, do not consume
            rep_l         <= (rep == 2'd2) ? 2'd2 : 2'd1;
            m_frame_valid <= 1'b1;
            m_line_valid  <= 1'b0;
            m_enable      <= 1'b0;
        end else begin
            case (st)
                // frame_valid is up but data waits FRAME_LEAD cycles: their
                // uvc_fifo is cleared by h_sof, and raising enable on the same
                // cycle makes that clear land on top of the first write.
                ST_LEAD: begin
                    if (r_gap == 9'(FRAME_LEAD - 1)) begin
                        r_gap <= '0;
                        st    <= ST_IDLE;
                    end else begin
                        r_gap <= r_gap + 9'd1;
                    end
                end

                ST_IDLE: begin
                    m_enable     <= 1'b0;
                    m_line_valid <= 1'b0;
                    if (r_line >= out_lines) begin
                        m_frame_valid <= 1'b0;     // frame done, wait for next
                    end else if (line_ready) begin
                        st           <= ST_PIX;
                        r_px         <= '0;
                        r_dup        <= 2'd0;
                        r_phase      <= 2'd0;
                        m_enable     <= 1'b1;
                        m_line_valid <= 1'b1;
                        // PRELOADED, so data is valid on the FIRST enable
                        // cycle. Their hCount3 resets while enable is low and
                        // captures Y on its first cycle, so a value that only
                        // arrives a cycle later shifts every line by a pixel.
                        // Their own packer preloads video_txdat for the same
                        // reason.
                        m_data       <= lbuf[{r_sel, 8'd0}];
                    end
                end

                ST_PIX: begin
                    if (r_phase == 2'(CLKS_PER_PX - 1)) begin
                        r_phase <= 2'd0;
                        if (r_dup == rep_l - 2'd1) begin
                            r_dup <= 2'd0;
                            if (r_px == 9'(SRC_W - 1)) begin
                                st           <= ST_GAP;
                                r_gap        <= '0;
                                m_enable     <= 1'b0;
                                m_line_valid <= 1'b0;
                            end else begin
                                r_px   <= r_px + 9'd1;
                                // Fetch the next pixel now so it is on the bus
                                // for its own first cycle.
                                m_data <= lbuf[{r_sel, r_px[7:0] + 8'd1}];
                            end
                        end else begin
                            r_dup <= r_dup + 2'd1;   // same pixel, data unchanged
                        end
                    end else begin
                        r_phase <= r_phase + 2'd1;
                    end
                end

                // Blanking. Dropping enable is what advances their hCountY.
                ST_GAP: begin
                    if (r_gap == 9'(LINE_GAP - 1)) begin
                        r_line <= r_line + 10'd1;
                        if (r_pass == rep_l - 2'd1) begin
                            // Both copies of this source line are out; release
                            // it and take the next.
                            r_pass       <= 1'b0;
                            r_tog[r_sel] <= ~r_tog[r_sel];
                            r_sel        <= (r_sel == SELW'(NBUF-1)) ? '0 : r_sel + SELW'(1);
                        end else begin
                            r_pass <= r_pass + 1'b1;   // replay the same line
                        end
                        st <= ST_IDLE;
                    end else begin
                        r_gap <= r_gap + 9'd1;
                    end
                end
            endcase
        end
    end

endmodule
