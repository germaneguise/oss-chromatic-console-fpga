// mm_burst_write.v

// Converts QSPI memory mapped transfer into a burst write to PSRAM
module mm_burst_write(
    input           QSPI_CLK,
    input           QSPI_CS,
    input   [31:0]  qAddress,
    input           qDataValid,
    input   [15:0]  qData,
    
    input           xClk,
    input           xRdEn,
    input           xRamReady,
    output  reg     xMcuReqWrite,
    
    output  [15:0]  xDout,
    output  [22:0]  xAddress
);

    assign xAddress = qAddress[22:0];

    /* The Gowin fifo1k IP is replaced by a plain inferred dual-clock BSRAM:
       none of its flags were consumed here (Empty/Full/Almost_Full were
       dangling), its resets were tied off, and both pointers free-run with
       the transfer counts managed by the QSPI protocol and the RAM arbiter -
       so all of the IP's gray-code pointer synchronisation and flag
       machinery served nothing, and being encrypted it could not be pruned.
       Read behaviour matches the IP's standard (non-FWFT) mode: Q registers
       the word at the read pointer on the RdEn edge, then increments. The
       write clock was WrClk = ~QSPI_CLK, i.e. the QSPI falling edge. */
    reg [15:0] mmfifo [1023:0] /* synthesis syn_ramstyle = "block_ram" */;
    reg [9:0]  mmf_wptr = 10'd0;
    reg [9:0]  mmf_rptr = 10'd0;
    reg [15:0] mmf_q;

    always @(negedge QSPI_CLK) begin
        if (qDataValid) begin
            mmfifo[mmf_wptr] <= qData;
            mmf_wptr <= mmf_wptr + 10'd1;
        end
    end

    always @(posedge xClk) begin
        if (xRdEn | xMcuReqWrite) begin
            mmf_q    <= mmfifo[mmf_rptr];
            mmf_rptr <= mmf_rptr + 10'd1;
        end
    end

    assign xDout = mmf_q;
    
    reg [3:0] xCS_sr;
    always@(posedge xClk)
        xCS_sr <= {xCS_sr[2:0], QSPI_CS};
    
    always@(posedge xClk)
    begin
        xMcuReqWrite <= 1'd0;
        if(xCS_sr[3:2] == 2'b01)
            xMcuReqWrite <= xRamReady;      
    end
    
endmodule
