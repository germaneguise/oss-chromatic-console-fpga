// csc_only.v - extracted copy of rgb_to_ycbcr_pipeline and delay from
// usbuvcuart_top.v, for benches that cannot pull in the full USB top.
// Regenerate whenever the originals change.


module rgb_to_ycbcr_pipeline(
    input rst,
    input hClk,
    input hLineValid,
    input hEnable,
    input hFrameValid,
    input [7:0] R,
    input [7:0] G,
    input [7:0] B,
    output yLineValid,
    output yEnable,
    output yFrameValid,
    output [7:0] Y,
    output [7:0] Cb,
    output [7:0] Cr
);
    /* Was Gowin's encrypted Color_Space_Convertor_Top: 9 DSPs and a 6-stage
       pipeline running 8x8 multipliers on inputs whose low two bits are
       hardwired zero upstream. Same BT.601 studio-range matrix as constant
       shift-adds in three stages:

         Y  =  16 + ( 66R + 129G +  25B) >> 8
         Cb = 128 + (-38R -  74G + 112B) >> 8
         Cr = 128 + (112R -  94G -  18B) >> 8

       Plain floor, no rounding bias: that is what the original core
       computes, so this is a bit-identical drop-in for every producible
       input (verified exhaustively - see sim/fifo_video/tb_csc.v, and the
       release notes for the on-device comparison). A +128 half-LSB bias
       would be marginally more accurate and no longer bit-identical.

       Every result is in range by construction (Y 16..235, chroma 16..240),
       so there is no clamp stage. Constants decompose as 66=64+2, 129=128+1,
       25=16+8+1, 38=32+4+2, 74=64+8+2, 112=64+32+16, 94=64+32-2, 18=16+2.

       Latency is 3 hClk; the hs/vs delay instances in this module carry the
       same figure, replacing the IP's 6. */

    // stage 1: partial products
    reg [15:0] yR, yG, yB;   // 129*255 = 32,895 needs 16 bits
    reg signed [15:0] bR, bG, bB;
    reg signed [15:0] rR, rG, rB;
    reg v1, v2;
    always @(posedge hClk) begin
        // widths are exact: unsigned partials peak at 129*255 = 32,895
        // (16 bits), signed ones at +/-28,560 (16 bits incl. sign)
        yR <= {2'd0, R, 6'd0} + {7'd0, R, 1'd0};                     //  66R
        yG <= {1'd0, G, 7'd0} + {8'd0, G};                           // 129G
        yB <= {4'd0, B, 4'd0} + {5'd0, B, 3'd0} + {8'd0, B};         //  25B
        bR <= -$signed({3'd0, R, 5'd0}) - $signed({6'd0, R, 2'd0})
              - $signed({7'd0, R, 1'd0});                            // -38R
        bG <= -$signed({2'd0, G, 6'd0}) - $signed({5'd0, G, 3'd0})
              - $signed({7'd0, G, 1'd0});                            // -74G
        bB <= $signed({2'd0, B, 6'd0}) + $signed({3'd0, B, 5'd0})
              + $signed({4'd0, B, 4'd0});                            // 112B
        rR <= $signed({2'd0, R, 6'd0}) + $signed({3'd0, R, 5'd0})
              + $signed({4'd0, R, 4'd0});                            // 112R
        rG <= -$signed({2'd0, G, 6'd0}) - $signed({3'd0, G, 5'd0})
              + $signed({7'd0, G, 1'd0});                            // -94G
        rB <= -$signed({4'd0, B, 4'd0}) - $signed({7'd0, B, 1'd0});  // -18B
        v1 <= hEnable & ~rst;
    end

    // stage 2: sums with rounding
    reg [15:0] ySum;
    reg signed [16:0] bSum, rSum;
    always @(posedge hClk) begin
        ySum <= yR + yG + yB;             // max 56,100, fits 16
        bSum <= bR + bG + bB;
        rSum <= rR + rG + rB;
        v2 <= v1;
    end

    // stage 3: scale and offset
    reg [7:0] yQ, cbQ, crQ;
    reg v3;
    always @(posedge hClk) begin
        yQ  <= ySum[15:8] + 8'd16;
        cbQ <= bSum[15:8] + 8'd128;
        crQ <= rSum[15:8] + 8'd128;
        v3 <= v2;
    end

    assign Y  = yQ;
    assign Cb = cbQ;
    assign Cr = crQ;
    assign yEnable = v3;

    delay #(.DELAY(3)) hs(rst, hClk, hLineValid, yLineValid);
    delay #(.DELAY(3)) vs(rst, hClk, hFrameValid, yFrameValid);

endmodule

module delay(input rst, input clk, input in, output out);

    parameter DELAY = 6;

    reg [DELAY-1:0] d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            d <= 0;
        end else begin
            d <= {d[DELAY - 2:0], in};
        end
    end
    assign out = d[DELAY-1];

endmodule