// Feedback divider, as a design would already have it in RTL.
// Divides by N on rising edges; the output is a ~50% duty clock for even N.
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
