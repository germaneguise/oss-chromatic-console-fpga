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

// audio_filter's "stable for two clocks" input guard is dropped: core_l/r
// come from gbc_snd's registered mixer in the SAME hClk domain, so they are
// stable every cycle by construction. The guard was a vestige of MiSTer's
// cross-domain use; the real crossing (gClk consumers) is handled by the
// sample_ce hold below, exactly as before.

// audio_filter muted until its pipeline had filled (~125 ms, dly2[13] at
// sample_ce). Keep it: without a ramp the codec plays whatever is on the bus
// at power-up.
reg [13:0] dly;
reg        en;
// Was out_l/out_r, gated with "en ? core : 0". The gating was redundant -
// DC_blocker's mute (driven by ~en) already forces the output to zero - so
// these are now a plain capture of the sample instant. Same register count,
// and the integrator gets real samples during the ramp instead of zeros, so
// it is already settled when en releases. Both channels are captured on the
// same edge, which is what lets the shared filter below walk them on
// consecutive cycles without pulling them a sample apart.
reg [15:0] hold_l, hold_r;
always @(posedge clk or posedge reset) begin
	if (reset) begin
		dly    <= 14'd0;
		en     <= 1'b0;
		hold_l <= 16'd0;
		hold_r <= 16'd0;
	end
	else if (sample_ce) begin
		if (!dly[13]) dly <= dly + 1'd1;
		else          en  <= 1'b1;
		hold_l <= core_l;
		hold_r <= core_r;
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
DC_blocker_2ch dcb (.clk(clk), .ce(sample_ce), .mute(~en),
                    .din_l(hold_l), .din_r(hold_r),
                    .dout_l(filter_l), .dout_r(filter_r));

endmodule


// Was two DC_blocker instances lifted from Gameboy_MiSTer's iir_filter.sv.
// The maths is unchanged - with sample_rate=0 the pole is 1 - 2^-9, a 20.4 Hz
// corner at sample_ce = hclk/256 = 65536 Hz - but the two channels now share
// one arithmetic unit instead of having one each.
//
// WHY THAT IS FREE: ce fires once every 256 clocks and the datapath is purely
// combinational within a cycle, so each channel used its adders for 1 cycle in
// 256 and idled for the other 255. Two channels fit in the gap with 254 to
// spare. Only the state is per-channel; the four 40-bit add/subs are not.
//
// The channels are walked on the two cycles AFTER ce, not starting on it, so
// both read the same captured sample. Walking them on ce and ce+1 would give
// the right channel a sample the left had not seen yet - a 22.7 us stereo
// offset, which is audible as a shifted image. The remaining skew is one clock
// between the two register updates, 59.6 ns, inside a window where the value
// is held stable for 15.3 us either side for the asynchronous gClk consumers.
// Both channels still carry the same sample index; nothing moves on the audio
// timeline.
module DC_blocker_2ch
(
	input         clk,
	input         ce,          // one pulse per stereo sample
	input         mute,
	input  [15:0] din_l,
	input  [15:0] din_r,
	output [15:0] dout_l,
	output [15:0] dout_r
);

reg [39:0] x1 [0:1];
reg [39:0] y  [0:1];

// ph: 0 idle, 1 = left this cycle, 2 = right this cycle.
reg [1:0] ph = 2'd0;
always @(posedge clk) begin
	if (ce)              ph <= 2'd1;
	else if (ph == 2'd1) ph <= 2'd2;
	else                 ph <= 2'd0;
end

wire        active = ph[0] | ph[1];
wire        chan   = ph[1];
wire [15:0] din    = chan ? din_r : din_l;

wire [39:0] x  = {din[15], din, 23'd0};
wire [39:0] x0 = x - {{10{x[39]}}, x[39:10]};
wire [39:0] yc = y[chan];
wire [39:0] y1 = yc - {{09{yc[39]}}, yc[39:09]};
wire [39:0] y0 = x0 - x1[chan] + y1;

always @(posedge clk) if (active) begin
	x1[chan] <= x0;
	y[chan]  <= ^y0[39:38] ? {{2{y0[39]}},{38{y0[38]}}} : y0;
end

assign dout_l = mute ? 16'd0 : y[0][38:23];
assign dout_r = mute ? 16'd0 : y[1][38:23];

endmodule
