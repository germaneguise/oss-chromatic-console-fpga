//
// File name          :uart.v
// Module name        :uart.v
// Created by         :GaoYun Semi
// Author             :(Winson)
// Created On         :2020-11-05 14:26 GuangZhou
// Last Modified      :
// Update Count       :2020-11-05 14:26
// Description        :
//----------------------------------------------------------------------
//===========================================
module UART 
#(    parameter CLK_FREQ    = 30'd60000000 // set system clock frequency in Hz
      //parameter BAUD_RATE   = 4000000   // baud rate value
     // parameter P_PARITY_BIT  = "none"   // legal values: "none", "even", "odd", "mark", "space"
)
(
    input              CLK        , // clock
    input              RST        , // reset
        // UART INTERFACE
    output             UART_TXD   ,
    input              UART_RXD   ,
    output             UART_RTS   , // when UART_RTS = 0, UART This Device Ready to receive.
    input              UART_CTS   , // when UART_CTS = 0, UART Opposite Device Ready to receive.
        // UART Control Reg
    input  [31:0]      BAUD_RATE ,
    input  [7:0]       PARITY_BIT,
    input  [7:0]       STOP_BIT  ,
    input  [7:0]       DATA_BITS ,
        // USER DATA INPUT INTERFACE
    input   [15:0]     TX_DATA    , //
    input              TX_DATA_VAL, // when TX_DATA_VAL = 1, data on TX_DATA will be transmit, DATA_SEND can set to 1 only when BUSY = 0
    output             TX_BUSY    , // when BUSY = 1 transiever is busy, you must not set DATA_SEND to 1
        // USER FIFO CONTROL INTERFACE
    output  [15:0]     RX_DATA    , //
    output             RX_DATA_VAL  //
);


    reg  [3:0] uart_rxd_shreg     ;
    reg        uart_rxd_debounced ;
    reg  [3:0] uart_cts_shreg     ;
    reg        uart_cts_debounced ;
    wire       uart_tx_busy       ;
    reg  [1:0] div_correct;

    reg [23:0] divider_value;
    // -------------------------------------------------------------------------
    // UART DIVIDER VALUE
    // -------------------------------------------------------------------------
    // The far end of this UART is the ESP32's console. The stock MCU firmware
    // and every existing flashing tool (MRUpdater's flashing_tool, esptool)
    // run it at 115200 8N1; a console firmware configured for 921600 is
    // reached by opening the port at that rate. Exactly these two rates are
    // supported, selected by the host's CDC SET_LINE_CODING. Any other
    // requested rate falls back to 115200 so 115200-only tools keep working
    // even when a host opens the port with a stale line coding (Windows
    // usbser.sys issues SET_LINE_CODING on every open). GET_LINE_CODING still
    // answers with whatever the host requested, even after a fallback.
    //
    // Divider constants are precomputed at elaboration, replacing the runtime
    // Fixed_Point_Divider IP. That divider was NOT an integer divider: it
    // returned the quotient with 3 fractional bits and its dividend was
    // CLK_FREQ*4, so DIV_OUT = (CLK_FREQ * 32) / BAUD, where
    //   [28:5] = floor(CLK_FREQ / BAUD)  clocks per bit (520 @ 115200, 65 @ 921600)
    //   [4:3]  = quarter-bit correction  (3 @ 115200, 0 @ 921600)
    // CLK_FREQ is 60 MHz here: usbuvcuart_top's pClk is PHY_CLKOUT, not the
    // 33.55 MHz pclk. Reading DIV_OUT as a plain integer divide runs the link
    // 8x fast and returns framing garbage - measured as 0xC0 repeating.
    localparam [31:0] DIV_OUT_115200 = ({CLK_FREQ, 5'b00000}) / 32'd115200;
    localparam [31:0] DIV_OUT_921600 = ({CLK_FREQ, 5'b00000}) / 32'd921600;

    always @(posedge CLK or posedge RST) begin
        if (RST) begin
            divider_value <= DIV_OUT_115200[28:5];
            div_correct   <= DIV_OUT_115200[4:3];
        end
        else begin
            case (BAUD_RATE)
                32'd921600 : begin divider_value <= DIV_OUT_921600[28:5]; div_correct <= DIV_OUT_921600[4:3]; end
                // 115200, and any unsupported rate, falls back to 115200
                default    : begin divider_value <= DIV_OUT_115200[28:5]; div_correct <= DIV_OUT_115200[4:3]; end
            endcase
        end
    end
    // -------------------------------------------------------------------------
    // UART RXD DEBAUNCER
    // -------------------------------------------------------------------------
    always @(posedge CLK or posedge RST) begin
        if (RST) begin
            uart_rxd_shreg <= 4'hF;
            uart_rxd_debounced <= 1'b1;
        end
        else begin
            uart_rxd_shreg <= {UART_RXD, uart_rxd_shreg[3:1]};
            uart_rxd_debounced <= uart_rxd_shreg[0]|uart_rxd_shreg[1]|uart_rxd_shreg[2]|uart_rxd_shreg[3];
        end
    end

    always @(posedge CLK or posedge RST) begin
        if (RST) begin
            uart_cts_shreg <= 4'hF;
            uart_cts_debounced <= 1'b1;
        end
        else begin
            uart_cts_shreg <= {UART_CTS, uart_cts_shreg[3:1]};
            uart_cts_debounced <= uart_cts_shreg[0]|uart_cts_shreg[1]|uart_cts_shreg[2]|uart_cts_shreg[3];
        end
    end

    assign UART_RTS  = 1'b0;
    assign TX_BUSY   = uart_tx_busy | UART_CTS;

    // -------------------------------------------------------------------------
    // UART TRANSMITTER
    // -------------------------------------------------------------------------
    UART_TX 
    //#( .P_PARITY_BIT (P_PARITY_BIT)) 
        uart_tx_inst (
            .CLK         (CLK         )
           ,.RST         (RST         )
            // UART INTERFACE
           //,.UART_CLK_EN (uart_clk_en )
           ,.UART_TXD    (UART_TXD    )
            // UART PARAMETER
           //,.UART_PARITY_BIT (UART_PARITY_BIT  )
           //,.UART_DATA_BIT   (UART_DATA_BIT    )
           ,.PARITY_BIT  (PARITY_BIT)
           ,.STOP_BIT    (STOP_BIT  )//0: 1 stop bit  1: 1.5 stop bit 2: 2 stop bit
           ,.DATA_BITS   (DATA_BITS )//5 6 7 8 16
           ,.DIVIDER_VALUE(divider_value )//16'd37
           ,.DIV_CORRECT(div_correct  )//16'd37

            // USER DATA INPUT INTERFACE
           ,.DATA_IN     (TX_DATA     )
           ,.DATA_SEND   (TX_DATA_VAL )
           ,.BUSY        (uart_tx_busy)
    );

    // -------------------------------------------------------------------------
    // UART RECEIVER
    // ------------------------------------------------------------------------- 
    UART_RX 
    #( .P_PARITY_BIT ("odd")) 
        uart_rx_inst (
            .CLK         (CLK                )
           ,.RST         (RST                )
           // UART INTERFACE
           //,.UART_CLK_EN (uart_clk_en        )
           ,.UART_RXD    (uart_rxd_debounced )
            // UART PARAMETER
           //,.UART_PARITY_BIT (UART_PARITY_BIT  )
           //,.UART_DATA_BIT (UART_DATA_BIT  )
           ,.PARITY_BIT  (PARITY_BIT )
           ,.STOP_BIT    (STOP_BIT   )//0: 1 stop bit  1: 1.5 stop bit 2: 2 stop bit
           ,.DATA_BITS   (DATA_BITS  )//5 6 7 8 16
           ,.DIVIDER_VALUE(divider_value)//
           ,.DIV_CORRECT(div_correct  )//16'd37
            // USER DATA INPUT INTERFACE
           ,.DATA_OUT    (RX_DATA    )
           ,.DATA_VLD    (RX_DATA_VAL)
           ,.FRAME_ERROR (           )
    );


endmodule
