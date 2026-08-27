// tb_csc.v - exhaustive check of the hand-written rgb_to_ycbcr_pipeline
// against the BT.601 studio-range integer model, for every input the design
// can produce (R,G,B are 6-bit values shifted left 2 upstream: 64^3 combos).
`timescale 1ns/1ps
module tb_csc;
    reg clk = 0, rst = 1, en = 0, lv = 0, fv = 0;
    reg [7:0] R = 0, G = 0, B = 0;
    wire yLV, yEN, yFV;
    wire [7:0] Y, Cb, Cr;
    always #5 clk = ~clk;

    rgb_to_ycbcr_pipeline dut(
        .rst(rst), .hClk(clk),
        .hLineValid(lv), .hEnable(en), .hFrameValid(fv),
        .R(R), .G(G), .B(B),
        .yLineValid(yLV), .yEnable(yEN), .yFrameValid(yFV),
        .Y(Y), .Cb(Cb), .Cr(Cr));

    // golden: arithmetic-shift model, matches the RTL's mod-256 wrap claims
    function [7:0] gY;  input [7:0] r,g,b; begin gY  = 8'd16  + ((16'd66*r + 16'd129*g + 16'd25*b) >> 8); end endfunction
    function [7:0] gCb; input [7:0] r,g,b; integer s; begin s = -38*r - 74*g + 112*b; gCb = 8'd128 + (s >>> 8); end endfunction
    function [7:0] gCr; input [7:0] r,g,b; integer s; begin s = 112*r - 94*g - 18*b; gCr = 8'd128 + (s >>> 8); end endfunction

    reg [7:0] eR [0:3], eG [0:3], eB [0:3];   // pipeline shadow
    integer i, errors = 0, checked = 0;
    integer ri, gi, bi;

    initial begin
        repeat (4) @(posedge clk);
        rst = 0; en = 1;
        for (ri = 0; ri < 64; ri = ri + 1)
        for (gi = 0; gi < 64; gi = gi + 1)
        for (bi = 0; bi < 64; bi = bi + 1) begin
            R = ri << 2; G = gi << 2; B = bi << 2;
            @(posedge clk);
            #1;
            eR[0]=R; eG[0]=G; eB[0]=B;
            if (yEN) begin
                checked = checked + 1;
                if (Y  !== gY (eR[2],eG[2],eB[2]) ||
                    Cb !== gCb(eR[2],eG[2],eB[2]) ||
                    Cr !== gCr(eR[2],eG[2],eB[2])) begin
                    errors = errors + 1;
                    if (errors < 6)
                        $display("MISMATCH R=%0d G=%0d B=%0d  Y=%0d/%0d Cb=%0d/%0d Cr=%0d/%0d",
                          eR[2],eG[2],eB[2], Y,gY(eR[2],eG[2],eB[2]),
                          Cb,gCb(eR[2],eG[2],eB[2]), Cr,gCr(eR[2],eG[2],eB[2]));
                end
            end
            for (i = 3; i > 0; i = i - 1) begin
                eR[i]=eR[i-1]; eG[i]=eG[i-1]; eB[i]=eB[i-1];
            end
        end
        // flush: keep clocking with enable low, still checking the pipe's tail
        en = 0;
        repeat (4) begin
            @(posedge clk);
            #1;
            eR[0]=R; eG[0]=G; eB[0]=B;
            if (yEN) begin
                checked = checked + 1;
                if (Y  !== gY (eR[2],eG[2],eB[2]) ||
                    Cb !== gCb(eR[2],eG[2],eB[2]) ||
                    Cr !== gCr(eR[2],eG[2],eB[2])) errors = errors + 1;
            end
            for (i = 3; i > 0; i = i - 1) begin
                eR[i]=eR[i-1]; eG[i]=eG[i-1]; eB[i]=eB[i-1];
            end
        end
        if (errors == 0) $display("PASS  %0d vectors, zero mismatches", checked);
        else             $display("FAIL  %0d mismatches of %0d", errors, checked);
        $finish;
    end
endmodule
