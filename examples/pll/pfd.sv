// A phase-frequency detector, as a design would already have it in RTL.
// Two flops set by their clock edges and reset together once both are high.
// Nothing here is generated -- this stands in for the customer's own code.
module pfd (
  input  logic ref_clk,
  input  logic div_clk,
  output logic up,
  output logic dn
);
  // A reset path delay, as a real one has. This is correct SystemVerilog
  // and is left alone deliberately -- the file stands in for code the
  // customer already owns.
  //
  // It also only WORKS by accident, and the accident is worth knowing
  // about. This file declares no `timescale, so it takes xezim's 1 ns
  // default, which is the one time unit at which aionhw/xezim#161 is a
  // no-op: a time literal in a constant is folded against a fixed 1 ns
  // instead of the module's unit, so 300ps folds to 0.3 and 0.3 ns is
  // exactly right here. Add `timescale 1ps/1ps to the top of this file and
  // the same 0.3 rounds to zero at that precision -- the reset delay
  // disappears silently and the PFD develops a zero-width reset. Do not
  // give this file a timescale until that issue is fixed.
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
