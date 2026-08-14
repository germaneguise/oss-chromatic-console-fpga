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
    // The far end of this UART is the ESP32, fixed at 115200 8N1 - see
    // chromatic_mcu main.c app_main(). MRUpdater flashes the MCU over this same
    // link and also stays at 115200: its flashing_tool modules define
    // MCU_BAUD_RATE / initial_baud and never call esptool's change_baud, and
    // 115200 is the only baud constant anywhere in that bundle. So the divisor
    // is a constant, and Fixed_Point_Divider_Top was spending
    // 126 REG / 69 ALU / 122 LUT recomputing it forever from a value that never
    // changes.
    //
    // Fixed_Point_Divider_Top is NOT an integer divider: it returns the quotient
    // with 3 fractional bits, so div_out = (dividend * 8) / divisor. uart_tx.vhd
    // counts tx_ticks up to divider_value per bit, i.e. divider_value is
    // clocks-per-bit, which pins the scaling down - at CLK_FREQ 60 MHz (pClk is
    // PHY_CLKOUT, not the 33.55 MHz pclk) that has to be 60e6/115200 = 520.83.
    //
    //   div_out       = (CLK_FREQ*4 * 8) / BAUD = CLK_FREQ*32 / BAUD = 16666
    //   divider_value = div_out[28:5] = 520
    //   div_correct   = div_out[4:3]  = 3      (3/4 = 0.75, vs true frac 0.83)
    //
    // Reading it as a plain integer divide gives divider_value 65 - 8x too fast -
    // and the link returns framing garbage (0xC0 repeating). Measured.
    //
    // The BAUD_RATE port stays but is unused. The CDC SET_LINE_CODING path
    // still accepts and acknowledges rate changes, it just no longer retunes the
    // UART. Windows usbser.sys issues SET_LINE_CODING on every port open
    // regardless of the ACM bmCapabilities bit, and STALLing it would fail the
    // open - and with it esptool, and with it firmware updates.
    localparam [31:0] FIXED_BAUD = 32'd115200;
    localparam [31:0] DIV_OUT_C  = ({CLK_FREQ, 5'b00000}) / FIXED_BAUD;

    wire  [1:0] div_correct   = DIV_OUT_C[4:3];
    wire [23:0] divider_value = DIV_OUT_C[28:5];
    // -------------------------------------------------------------------------
    // UART DIVIDER VALUE
    // -------------------------------------------------------------------------
    //always @(posedge CLK or posedge RST) begin
    //    if (RST) begin
    //        divider_value <= 24'd0;
    //    end
    //    else begin
    //        //divider_value <= CLK_FREQ/(15*BAUD_RATE);
    //        divider_value <= CLK_FREQ/(BAUD_RATE);
    //    end
    //end
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



    // Fixed_Point_Divider_Top instance removed - divider_value and div_correct
    // are now the localparams above. See the note at their declaration.
    

 
endmodule
