// A phase-frequency detector, as a design would already have it in RTL.
// Two flops set by their clock edges and reset together once both are high.
// Nothing here is generated -- this stands in for the customer's own code.
module pfd (
  input  logic ref_clk,
  input  logic div_clk,
  output logic up,
  output logic dn
);
  localparam time RST_DELAY = 300ps;   // reset path delay, as a real one has

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
