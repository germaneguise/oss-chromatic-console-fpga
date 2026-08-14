// audio_resample.v
//
// Replaces audio_filter in the emu audio path. Same port list, so the swap is
// one line in emu_system_top.
//
// audio_filter did three things: an IIR low-pass, DC blocking, and - almost
// incidentally - it held its output steady at a low rate. Only the low-pass is
// gone:
//
//   DC blocking   -> kept, as MiSTer's DC_blocker below (pole 1 - 2^-9 at
//                    hclk/256, a 20.4 Hz corner - the same corner audio_filter
//                    had). It stays in fabric rather than moving to the
//                    codec's own high-pass; see the note above the
//                    instantiations for why.
//   IIR low-pass  -> dropped entirely. Decoded from the coefficients
//                    audio_filter passed (MiSTer's module defaults) it is a
//                    3rd-order low-pass, -3 dB at 20.6 kHz, running at 7.056
//                    MHz: +0.07 dB at 10 kHz, -0.68 dB at 16 kHz. Inaudible,
//                    and the codec's own DAC interpolation filter does the
//                    anti-imaging it existed for. Its 8 MULT27X36 are what
//                    freed the DSPs (28/28 -> 16.5/28).
//
// WHY THIS MODULE STILL EXISTS, rather than wiring the core straight through:
// aud_system_top latches left/right in the gClk domain, and evt1_x2.sdc
// declares hclk and gclk asynchronous -
//
//   set_clock_groups -asynchronous -group [get_clocks {hclk}] -group [get_clocks {gclk}]
//
// so that 16-bit path is never timed. audio_filter made it safe by only
// updating its output at sample_ce = hclk/256 = 65536 Hz, which left the bus
// stable for ~15 us either side of every I2S capture. Drive the core outputs
// through combinationally and a capture can land mid-transition, taking
// different bits from different samples - a torn 16-bit word, i.e. a
// full-scale glitch, on an audio stream. That is the one behaviour of
// audio_filter that was load-bearing.
//
// Costs ~120 FFs, against the 11.5 DSPs the IIR cost.

module audio_resample
(
	input        reset,
	input        clk,        // hclk, 16.777216 MHz

	input [15:0] core_l,
	input [15:0] core_r,

	output [15:0] filter_l,
	output [15:0] filter_r
);

// hclk / 256 = 65536 Hz, the rate audio_filter presented its output at.
reg [7:0] div = 8'd0;
reg       sample_ce;
always @(posedge clk) begin
	div <= div + 8'd1;
	if (!div) div <= 8'd1;
	sample_ce <= !div;
end

// Same construction audio_filter used: take a value only once it has been
// stable for two clocks.
reg [15:0] cl1, cl2, cl, cr1, cr2, cr;
always @(posedge clk) begin
	cl1 <= core_l; cl2 <= cl1;
	if (cl2 == cl1) cl <= cl2;
	cr1 <= core_r; cr2 <= cr1;
	if (cr2 == cr1) cr <= cr2;
end

// audio_filter muted until its pipeline had filled (~125 ms, dly2[13] at
// sample_ce). Keep it: without a ramp the codec plays whatever is on the bus
// at power-up.
reg [13:0] dly;
reg        en;
reg [15:0] out_l, out_r;
always @(posedge clk or posedge reset) begin
	if (reset) begin
		dly   <= 14'd0;
		en    <= 1'b0;
		out_l <= 16'd0;
		out_r <= 16'd0;
	end
	else if (sample_ce) begin
		if (!dly[13]) dly <= dly + 1'd1;
		else          en  <= 1'b1;
		out_l <= en ? cl : 16'd0;
		out_r <= en ? cr : 16'd0;
	end
end

// DC blocking has to happen HERE, not in the codec, because top.v fans
// left/right out to two consumers in different clock domains:
//
//   aud_system_top  (gClk)        -> I2S -> TLV320 -> speaker/headphones
//   usbuvcuart_top  (PHY_CLKOUT)  -> UAC -> USB host
//
// The codec sits on the first branch only, so using its page 9 high-pass would
// leave the UAC endpoint sending the raw Game Boy APU offset to the host.
// Blocking here, upstream of the split, covers both consumers from one
// implementation - as audio_filter did.
//
// This is MiSTer's DC_blocker verbatim (was in iir_filter.sv alongside the
// IIR low-pass). It has no multipliers, just shifts and adds, so it costs
// ~160 FF and no DSP - the 8 MULT27X36 that made audio_filter expensive were
// all in IIR_filter, which stays deleted.
DC_blocker dcb_l (.clk(clk), .ce(sample_ce), .sample_rate(1'b0),
                  .mute(~en), .din(out_l), .dout(filter_l));

DC_blocker dcb_r (.clk(clk), .ce(sample_ce), .sample_rate(1'b0),
                  .mute(~en), .din(out_r), .dout(filter_r));

endmodule


// Lifted unchanged from Gameboy_MiSTer's iir_filter.sv so that file can stay
// out of the build. With sample_rate=0 the pole is 1 - 2^-9, which at
// sample_ce = hclk/256 = 65536 Hz is a 20.4 Hz corner.
module DC_blocker
(
	input         clk,
	input         ce,
	input         mute,

	input         sample_rate,
	input  [15:0] din,
	output [15:0] dout
);

reg  [39:0] x1, y;

wire [39:0] x  = {din[15], din, 23'd0};
wire [39:0] x0 = x - (sample_rate ? {{11{x[39]}}, x[39:11]} : {{10{x[39]}}, x[39:10]});
wire [39:0] y1 = y - (sample_rate ? {{10{y[39]}}, y[39:10]} : {{09{y[39]}}, y[39:09]});
wire [39:0] y0 = x0 - x1 + y1;

always @(posedge clk) if(ce) begin
	x1 <= x0;
	y  <= ^y0[39:38] ? {{2{y0[39]}},{38{y0[38]}}} : y0;
end

assign dout = mute ? 16'd0 : y[38:23];

endmodule
