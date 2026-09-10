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
  // A reset path delay, as a real one has. Written with its unit, which is
  // what this file should say and what the LRM means: 5.8 scales a time
  // literal to the module's own time unit, so this is 300 ps whatever the
  // timescale above happens to be.
  //
  // It has not always been safe to write it this way here, and the history
  // is worth keeping because it is the reason the CI pins what it pins.
  // Under aionhw/xezim#161 a time literal in a CONSTANT was folded against a
  // fixed 1 ns rather than the module's unit, so `300ps` became 0.3 -- which
  // at 1 ps precision rounds to ZERO. The delay did not shrink, it
  // disappeared, and the PFD silently got a zero-width reset. The file
  // carried a bare `300` until the fix existed.
  //
  // Earlier still it declared no timescale at all, taking the 1 ns default:
  // the single unit at which that bug is a no-op, since 0.3 ns is what
  // 300ps should have been anyway. It was correct by accident, and adding a
  // timescale -- an ordinary tidying edit -- would have broken it.
  //
  // Requires the fix in aionhw/xezim-core#42, which the workflow builds
  // explicitly until it merges. See .github/workflows/ci.yml.
  localparam time RST_DELAY = 300ps;

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
