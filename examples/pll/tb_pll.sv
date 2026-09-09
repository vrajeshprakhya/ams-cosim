`timescale 1ps/1ps
//======================================================================
// The PLL as a real design is partitioned: ANALOG IN NGSPICE, DIGITAL IN
// RTL, coupled in lockstep.
//
// The VCO, the charge pump and the loop filter are transistor-level SPICE.
// The phase-frequency detector and the divider are the same SystemVerilog
// modules a design would already have. Nothing here is a generated model --
// that is the point. This is the GOLDEN the generated models get checked
// against, and until now there was no way to produce one for an
// analog-only netlist without re-expressing the digital in XSPICE.
//
// TIME. A bare delay is ONE TIMESCALE UNIT, so the `timescale` above is
// what sets the coupling granularity, and the analog is granted exactly as
// far as $realtime has reached. Do not write `100ns` and expect 100
// nanoseconds: measured on this simulator, a unit-suffixed literal is NOT
// scaled by the timescale (`100ns` under 1fs/1fs evaluates to 100.0, not
// 100_000_000), so every delay here is a bare number in timescale units.
//
// POLARITY. Taken from what the pipeline MEASURED on this same netlist,
// not from the port names:
//
//   Kvco is NEGATIVE (-3.297e8 Hz/V), so speeding the VCO up needs the
//   control voltage to FALL, so UP must select the SINKING control. The
//   off state was measured at pdn=0/pupb=1, which makes pdn active HIGH
//   and pupb active LOW.
//
//     UP  -> pdn,  asserted HIGH
//     DOWN-> pupb, asserted LOW   (hence the inversion below)
//
// Wiring it the textbook way inverts the loop, and every per-block check
// still passes when it is inverted -- that is how this project's charge
// pump shipped upside down once already.
//======================================================================
module tb;

  import "DPI-C" function int  ams_open(input string deck);
  import "DPI-C" function int  ams_drive(input string node, input real init);
  import "DPI-C" function int  ams_start(input real tstep, input real tstop);
  import "DPI-C" function int  ams_set(input string node, input real v);
  import "DPI-C" function int  ams_advance(input real t);
  import "DPI-C" function real ams_get(input string node);
  import "DPI-C" function real ams_time();
  import "DPI-C" function void ams_close();

  // A BARE delay is one timescale unit -- verified on this simulator, and
  // the reason the timescale above is picoseconds rather than the 1fs the
  // generated models use. The coupling tick has to be well under a VCO
  // period: the ring runs near 400 MHz, so 2.5 ns per cycle. Sampling its
  // output every 1 ns aliases, and the failure is quiet -- 199 edges over
  // 1600 ns reads as a confident 124 MHz for a ring actually running at
  // three times that. 100 ps gives 25 samples per cycle.
  localparam int  STEP        = 100;      // ticks -> 100 ps
  localparam real SEC_PER_TICK = 1.0e-12;
  localparam real VDD        = 3.3;
  localparam real VTH        = 1.65;     // where the analog VCO reads as 1
  localparam int  NDIV       = 40;
  localparam real REF_HZ     = 10.0e6;
  localparam int  REF_HALF_TICKS = 500;  // 500 * 100 ps = 50 ns -> 10 MHz

  logic samp = 1'b0;                     // the coupling tick
  logic ref_clk = 1'b0;
  logic vco_clk = 1'b0;
  logic div_clk, up, dn;
  real  t_dig, v_aout, v_ctrl;
  int   ticks, refc, vco_edges, rc;
  int   report_at, up_ticks, dn_ticks;
  real  t_win0;
  int   edges_win0;

  // The design's own RTL, unmodified.
  pfd  u_pfd (.ref_clk(ref_clk), .div_clk(div_clk), .up(up), .dn(dn));
  divn #(.N(NDIV)) u_div (.clk_in(vco_clk), .clk_out(div_clk));

  // HALF of STEP, because the body below runs on the POSEDGE and a toggle
  // every STEP gives a posedge every 2*STEP. Getting that wrong made the
  // coupling tick 20 ns instead of 100 ps -- so the VCO was sampled far
  // below its own rate and the reference ran at 50 kHz instead of 10 MHz,
  // while every printed number still looked like a plausible PLL.
  always #(STEP / 2) samp = ~samp;

  initial begin
    if (ams_open("pll_analog.cir") != 0)          begin $display("AMS-FAIL open");  $finish; end
    if (ams_drive("vpupb", VDD) != 0)          begin $display("AMS-FAIL drive1"); $finish; end
    if (ams_drive("vpdn", 0.0) != 0)           begin $display("AMS-FAIL drive2"); $finish; end
    // Grant ngspice a fine step; it may take smaller ones, never larger.
    if (ams_start(20.0e-12, 3.0e-6) != 0)      begin $display("AMS-FAIL start"); $finish; end
    report_at = 4000;
  end

  always @(posedge samp) begin
    t_dig = $realtime * SEC_PER_TICK;
    rc = ams_advance(t_dig);
    if (rc < 0) begin
      $display("AMS-FAIL analog stalled at %0.3f ns", t_dig * 1e9);
      $finish;
    end
    if (rc > 0) begin
      $display("AMS-NOTE analog ended at %0.4f us", ams_time() * 1e6);
      $finish;
    end

    // --- analog -> digital: square up the VCO output ------------------
    v_aout = ams_get("aout");
    if (v_aout > VTH && !vco_clk) begin
      vco_clk = 1'b1;
      vco_edges++;
    end else if (v_aout <= VTH && vco_clk) begin
      vco_clk = 1'b0;
    end

    // --- the reference, generated digitally ---------------------------
    ticks++;
    refc++;
    if (refc >= REF_HALF_TICKS) begin
      refc = 0;
      ref_clk = ~ref_clk;
    end

    // --- digital -> analog: the pump gates ----------------------------
    // UP asserts pdn HIGH (sinks); DOWN asserts pupb LOW (sources).
    rc = ams_set("vpdn",  up ? VDD : 0.0);
    rc = ams_set("vpupb", dn ? 0.0 : VDD);

    // Sampling up/dn at a report boundary says almost nothing -- they are
    // narrow pulses and the sample lands wherever it lands. What decides
    // which way the loop pushes is how LONG each is asserted, so count it.
    if (up) up_ticks++;
    if (dn) dn_ticks++;

    if (ticks % report_at == 0) begin
      v_ctrl = ams_get("vout");
      $display("PLL t=%7.1f ns  vctrl=%6.4f V  vco=%0d edges  up=%0d dn=%0d ticks  (net %0d)",
               t_dig * 1e9, v_ctrl, vco_edges, up_ticks, dn_ticks,
               up_ticks - dn_ticks);
      up_ticks = 0;
      dn_ticks = 0;
    end

    // Count VCO edges over a window once things are moving, so the output
    // frequency is a measurement rather than an impression.
    if (ticks == 5000) begin
      t_win0 = t_dig;
      edges_win0 = vco_edges;
    end
    if (ticks == 29000) begin
      $display("PLL f_vco = %0.2f MHz over %0.1f ns  (target %0.2f MHz)",
               real'(vco_edges - edges_win0) / ((t_dig - t_win0) * 1e6),
               (t_dig - t_win0) * 1e9, REF_HZ * NDIV / 1e6);
      $display("PLL-DONE vctrl=%0.4f V", ams_get("vout"));
      ams_close();
      $finish;
    end
  end

endmodule
