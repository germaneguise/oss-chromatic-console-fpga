// Reproduce the hardware observation: with RdEn tied LOW, occupancy must climb
// monotonically to the 4096 depth. On hardware rnum plateaus near 960 with
// rden=0 for the whole window, which should be impossible.
`timescale 1ps/1ps
module tb_fill;
    localparam WR_HALF=29802, RD_HALF=8333;
    reg WrClk=0, RdClk=0, Reset=1, WrEn=0, RdEn=0;
    reg [7:0] Data=0;
    wire [7:0] Q; wire [12:0] Rnum;
    wire Empty, Full, Almost_Full, Almost_Empty;
    fifo_video_rtl dut(.Data(Data),.Reset(Reset),.WrClk(WrClk),.RdClk(RdClk),
        .WrEn(WrEn),.RdEn(RdEn),.AlmostFullTh(12'd1012),.Rnum(Rnum),
        .Almost_Empty(Almost_Empty),.Almost_Full(Almost_Full),.Q(Q),
        .Empty(Empty),.Full(Full),.DbgCdcCount());
    always #WR_HALF WrClk=~WrClk;
    always #RD_HALF RdClk=~RdClk;
    integer i, wrote=0; reg [12:0] peak=0;
    initial begin
        repeat(10) @(posedge WrClk); Reset=0; repeat(10) @(posedge RdClk);
        // duty cycle roughly like active video: write, short gaps
        for (i=0;i<6000;i=i+1) begin
            @(negedge WrClk);
            WrEn = ((i%10)<6);          // 60% duty, like can_write over a line
            if (WrEn) begin Data=i[7:0]; wrote=wrote+1; end
            if (Rnum>peak) peak=Rnum;
            if (i%1000==0)
              $display("  i=%5d wrote=%5d cdc_wr=%4d cdc_rd=%4d deep_wr=%5d Rnum=%5d cdcFull=%0d deepFull=%0d",
                       i, wrote, dut.u_cdc.wbin, dut.u_cdc.rbin, dut.u_deep.wptr,
                       Rnum, dut.cdc_full, dut.sync_full);
        end
        @(negedge WrClk); WrEn=0; repeat(50) @(posedge RdClk);
        $display("\n  wrote %0d bytes with RdEn tied low", wrote);
        $display("  final Rnum=%0d  peak=%0d  Full=%0d  Almost_Full=%0d", Rnum, peak, Full, Almost_Full);
        if (Rnum < 4000 && wrote > 4200)
            $display("  *** REPRODUCED: occupancy stalls below depth despite no reads ***");
        else $display("  occupancy behaved (climbed toward depth)");
        $finish;
    end
endmodule
