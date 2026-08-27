// mem_system_top.v

module mem_system_top #(parameter ISSIMU=0)
(
    input               xClk,
    input               fClk,
    input               hClk,
    input               reset,
    
    input               QSPI_CLK,
    input               QSPI_MOSI,
    input               QSPI_MISO,
    input               QSPI_CS,
    input               QSPI_WP,
    input               QSPI_HD,

    output              PS_CE_N,
    output              PS_CLK,
    inout   [7:0]       PS_DQ,
    inout               PS_DQS,
    
    input               hGBNewLine,
    input   [22:0]      hGBAddress,
    input               hGBWrite,
    input   [15:0]      hGBData,
    
    input               hValid,
    input               hHsync,
    input               hVsync,
    output              qMenuInit,
    output  [15:0]      hWrBurstQ,
    output  [15:0]      hWrBurstQ2,
    input               hDrawOSD
);
    
    // Was 5 with RAMPORT_BIST = 0. Must stay in lockstep with RAMPORTCOUNT in
    // MultiPortRamCtrl.vhd, which sizes the round-robin arbiter and every
    // per-port array.
    localparam RAMPORTCOUNT = 4;
    localparam RAMPORT_QSPI = 0;
    localparam RAMPORT_FBRD = 1;
    localparam RAMPORT_FBWR = 2;
    localparam RAMPORT_FBRDOSD = 3;
    
    typedef logic tRAMIn_request     [RAMPORTCOUNT];
    typedef logic tRAMIn_RnW         [RAMPORTCOUNT];
    typedef logic [22:0] tRAMIn_addr        [RAMPORTCOUNT];
    typedef logic [15:0] tRAMIn_din         [RAMPORTCOUNT];
    typedef logic [10:0] tRAMIn_burst_length[RAMPORTCOUNT];
                  
    typedef logic tRAMOut_writeNext   [RAMPORTCOUNT];
    typedef logic tRAMOut_done        [RAMPORTCOUNT];
    typedef logic tRAMOut_dout_valid  [RAMPORTCOUNT];

    tRAMIn_request      RAMIn_request;     
    tRAMIn_RnW          RAMIn_RnW;     
    tRAMIn_addr         RAMIn_addr;     
    tRAMIn_din          RAMIn_din;     
    tRAMIn_burst_length RAMIn_burst_length; 
                            
    tRAMOut_writeNext   RAMOut_writeNext; 
    tRAMOut_done        RAMOut_done; 
    tRAMOut_dout_valid  RAMOut_dout_valid; 
   
    assign RAMIn_RnW[RAMPORT_QSPI]          = 1'b0;
    assign RAMIn_burst_length[RAMPORT_QSPI] = 11'd1024;
    
    assign RAMIn_RnW[RAMPORT_FBRD]          = 1'b1;
    assign RAMIn_burst_length[RAMPORT_FBRD] = 11'd320;
    assign RAMIn_din[RAMPORT_FBRD] = 16'd0;   

    assign RAMIn_RnW[RAMPORT_FBRDOSD]          = 1'b1;
    assign RAMIn_burst_length[RAMPORT_FBRDOSD] = 11'd320;
    assign RAMIn_din[RAMPORT_FBRDOSD] = 16'd0;   

    assign RAMIn_RnW[RAMPORT_FBWR]          = 1'b0;
    assign RAMIn_burst_length[RAMPORT_FBWR] = 11'd320;

    wire RAM_ready;
    wire [15:0] RAM_dout;    

    // BIST_finished used to gate every consumer's xRamReady, and it was STICKY:
    // once the test passed it stayed high forever. RAM_ready is not a
    // substitute - PSRAMController drives it as
    //     ready <= '1' when (state = IDLE and cfg_1_VendorID = x"0D")
    // i.e. "can accept a command right now", so it drops on every transaction.
    // The consumers sample xRamReady on a single cycle:
    //     if (xEndOfLine || xStartOfFrame) xGbReqRead <= xRamReady;
    // so any line whose edge lands while the controller is busy serving another
    // port silently loses its fetch. That breaks the OSD.
    //
    // Latch the first assertion instead. RAM_ready also requires the PSRAM to
    // have been identified (VendorID 0x0D), so this means "PSRAM configured and
    // up", which is what BIST_finished actually stood for - the pass/fail result
    // was never consumed by anything.
    reg RAM_init_done;
    always @(posedge xClk or posedge reset)
        if (reset)          RAM_init_done <= 1'b0;
        else if (RAM_ready) RAM_init_done <= 1'b1;
    
    MultiPortRamCtrl #(ISSIMU)
    iMultiPortRamCtrl
    (
       .clk_sys            (xClk),      
       .clk_fsys           (fClk),
       .rst                (reset),      
       
       .RAMIn_request      (RAMIn_request),  
       .RAMIn_RnW          (RAMIn_RnW),         
       .RAMIn_addr         (RAMIn_addr),        
       .RAMIn_din          (RAMIn_din),         
       .RAMIn_burst_length (RAMIn_burst_length),
            
       .RAMOut_writeNext   (RAMOut_writeNext),   
       .RAMOut_done        (RAMOut_done),        
       .RAMOut_dout_valid  (RAMOut_dout_valid),  
 
       .ram_ready          (RAM_ready), 
       .ram_dout           (RAM_dout),  
            
       .psram_clk          (PS_CLK), 
       .psram_cs_n         (PS_CE_N),
       .psram_rwds         (PS_DQS),
       .psram_dq           (PS_DQ)
    );
    
    wire [15:0] qData;
    wire [31:0] qAddress;
    wire qDataValid;

    QSPI_Slave u_QSPI_Slave(
        .QSPI_CLK(QSPI_CLK),
        .QSPI_CS(QSPI_CS),
        .QSPI_MOSI(QSPI_MOSI),
        .QSPI_MISO(QSPI_MISO),
        .QSPI_WP(QSPI_WP),
        .QSPI_HD(QSPI_HD),
        
        .qMenuInit(qMenuInit),
        .qDataValid(qDataValid),
        .qData(qData),
        .qAddress(qAddress)
    );

    mm_burst_write u_mm_burst_write(
        .QSPI_CLK(QSPI_CLK),
        .QSPI_CS(QSPI_CS),
        .qAddress(qAddress),
        .qDataValid(qDataValid),
        .qData(qData),

        .xClk(xClk),
        // Standard FIFO uses xRegWrite here (not FWFT FIFO)
        .xRdEn(RAMOut_writeNext[RAMPORT_QSPI]),
        .xRamReady(RAM_init_done),
        .xMcuReqWrite(RAMIn_request[RAMPORT_QSPI]),
        .xDout(RAMIn_din[RAMPORT_QSPI]),
        .xAddress(RAMIn_addr[RAMPORT_QSPI])
    );
    
    /* ONE line reader for two planes. The OSD instance duplicated this one
       - its own block, its own MPMC channel - to read a second plane the
       display only ever shows INSTEAD of frame blending: with the OSD up,
       the menu covers the screen and the blend result is invisible. So the
       single reader retargets per frame: the OSD plane while hDrawOSD (a
       signal vid_system_top already latches at vsync), the frame-blend
       history otherwise, and vid_system_top disables blending on OSD
       frames. Frees a block and an MPMC channel.

       hDrawOSD changes only at the hVsync edge; two xClk flops settle it
       well inside the 3-4 cycles before the module's own xStartOfFrame
       samples the base, and a one-frame slip either way at the toggle is a
       menu appearing one frame late at worst. */
    reg [1:0] xDrawOSD_sr;
    always @(posedge xClk)
        xDrawOSD_sr <= {xDrawOSD_sr[0], hDrawOSD};

    mm_burst_read_to_stream u_mm_burst_read_to_stream(
        .hClk(hClk),
        .hVsync(hVsync),
        .hHsync(hHsync),
        .hValid(hValid),
        .xClk(xClk),
        .xBasePointer(xDrawOSD_sr[1] ? 23'h0 : 23'h10000),

        .xRamReady(RAM_init_done),
        .xStreamValid(RAMOut_dout_valid[RAMPORT_FBRD]),
        .xStreamData(RAM_dout),
        .xWrBurstDone(RAMOut_done[RAMPORT_FBRD]),
        .xGbReqRead(RAMIn_request[RAMPORT_FBRD]),

        .hWrBurstQ(hWrBurstQ),
        .xGbAddress(RAMIn_addr[RAMPORT_FBRD])
    );

    /* The OSD consumer's timing contract is one hClk behind the blend
       consumer's - the deleted instance ran on _r1-delayed syncs - so its
       data is the same stream registered once. It only carries OSD pixels
       on frames where hDrawOSD retargeted the reader; on other frames the
       consumers of hWrBurstQ2 are gated off by hDrawOSD anyway. */
    reg [15:0] hWrBurstQ2_r;
    always @(posedge hClk)
        hWrBurstQ2_r <= hWrBurstQ;
    assign hWrBurstQ2 = hWrBurstQ2_r;

    /* The freed channel idles; the port stays for the memory-controller
       refactor to reclaim. */
    assign RAMIn_request[RAMPORT_FBRDOSD]      = 1'b0;
    assign RAMIn_addr[RAMPORT_FBRDOSD]         = 23'd0;

    
    gb_burst_write u_gb_burst_write(
        .hClk(hClk),
        .hVsync(hVsync),
        .hNewLine(hGBNewLine),
        .hAddress(hGBAddress),
        .hWrite(hGBWrite),
        .hData(hGBData),

        .xClk(xClk),
        .xRdEn(RAMOut_writeNext[RAMPORT_FBWR]),
        .xRamReady(RAM_init_done),
        .xMcuReqWrite(RAMIn_request[RAMPORT_FBWR]),
        .xDout(RAMIn_din[RAMPORT_FBWR]),
        .xAddress(RAMIn_addr[RAMPORT_FBWR])
    );
    
endmodule
