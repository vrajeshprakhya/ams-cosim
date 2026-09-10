`timescale 1ps/1ps
// A phase-frequency detector, as a design would already have it in RTL.
// Two flops set by their clock edges and reset together once both are high.
// Nothing here is generated -- this stands in for the customer's own code.
//
// The timescale is declared rather than inherited. Without it this file took
// whatever the tool defaults to (1 ns on xezim), which made the reset delay
// below depend on the order the files happen to be passed to the simulator.
module pfd (
  input  logic ref_clk,
  input  logic div_clk,
  output logic up,
  output logic dn
);
  // A reset path delay, as a real one has: 300 ps, in the 1 ps units
  // declared above.
  //
  // Written as a BARE number rather than `300ps` for the same reason every
  // delay in the testbenches is, and this file is where it actually bit.
  // Under aionhw/xezim#161 a time literal in a constant is folded against a
  // fixed 1 ns instead of the module's unit, so `300ps` becomes 0.3 -- which
  // at 1 ps precision rounds to ZERO. The reset delay does not shrink, it
  // disappears, and the PFD silently gets a zero-width reset.
  //
  // This file used to declare no timescale, which took the 1 ns default: the
  // single unit at which that bug is a no-op, since 0.3 ns is what 300ps
  // should have been anyway. It was correct by accident, and adding a
  // timescale -- an ordinary tidying edit -- would have broken it.
  //
  // A bare number in a declared unit is right on both sides of the fix, and
  // does not depend on file order. That is the portable way to write it
  // until the fix is released.
  localparam time RST_DELAY = 300;

  logic rst;
  assign #(RST_DELAY) rst = up & dn;

  always @(posedge ref_clk or posedge rst)
    if (rst) up <= 1'b0; else up <= 1'b1;

  always @(posedge div_clk or posedge rst)
    if (rst) dn <= 1'b0; else dn <= 1'b1;

  initial begin
    up = 1'b0;
    dn = 1'b0;
  end
endmodule
