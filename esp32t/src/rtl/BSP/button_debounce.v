// Debounce with a shared time base: the caller supplies one `tick` strobe
// (top.v: 2^11 gClk cycles, ~244 us) common to every instance, and each
// button keeps only a 3-bit stability counter instead of its own 15-bit
// prescaler. Semantics match the previous per-button-counter version: the
// synchronised input must disagree with `filtered` for 8 consecutive ticks
// (2^11 x 8 = 2^14 gClk cycles, ~2 ms - the old count[14] window exactly)
// before the output flips; any sample that agrees with `filtered` restarts
// the count.
module button_debouncer
(
   input      clk,
   input      tick,
   input      unfiltered,
   output reg filtered
);

   reg [2:0] input_sampling;
   reg [2:0] stable;

   always @(posedge clk) begin
      input_sampling <= {input_sampling[1:0], unfiltered};

      if (tick) begin
         if (input_sampling[2] == filtered) begin
            stable <= 'd0;
         end else if (&stable) begin
            filtered <= input_sampling[2];
            stable   <= 'd0;
         end else begin
            stable <= stable + 1'd1;
         end
      end
   end

endmodule
