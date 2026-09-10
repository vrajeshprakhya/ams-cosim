`timescale 1ps/1ps
// Feedback divider, as a design would already have it in RTL.
// Divides by N on rising edges; the output is a ~50% duty clock for even N.
//
// The timescale is declared even though this module has no delays and no
// time literals, so nothing here can currently depend on it. Without it the
// module inherits whatever directive precedes it in the compilation unit,
// which makes a property of this file depend on the ORDER the files are
// passed to the simulator. That is ordinary SystemVerilog scoping, not a
// simulator quirk, and it is the same order-dependence that made pfd.sv's
// reset delay accidentally correct. Cheaper to declare it than to rely on
// nobody ever adding a delay here.
module divn #(
  parameter int N = 40
) (
  input  logic clk_in,
  output logic clk_out
);
  int unsigned count;

  initial begin
    count   = 0;
    clk_out = 1'b0;
  end

  always @(posedge clk_in) begin
    if (count == (N / 2) - 1) begin
      count   <= 0;
      clk_out <= ~clk_out;
    end else begin
      count <= count + 1;
    end
  end
endmodule
