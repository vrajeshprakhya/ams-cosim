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
// far as $realtime has reached. Every delay here is a bare number in
// timescale units, which avoids a simulator bug in unit-suffixed literals:
// on xezim 0.10.5 the timescale scaling required by IEEE 1800-2017 5.8 is
// applied at run time but NOT at elaboration, so `localparam realtime T =
// 100ns` under 1fs/1fs yields 100.0 where `#100ns` correctly yields 1e8.
// A tick constant takes the broken path. See tb_rc.sv for the full table.
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
  import "DPI-C" function int  ams_write_raw(input string path,
                                             input string vectors);
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
  localparam real TOL_PCT    = 2.0;      // see the verdict below

  logic samp = 1'b0;                     // the coupling tick
  logic ref_clk = 1'b0;
  logic vco_clk = 1'b0;
  logic div_clk, up, dn;
  real  t_dig, v_aout, v_ctrl;
  int   ticks, refc, vco_edges, rc;
  int   report_at, up_ticks, dn_ticks;
  real  t_win0, f_meas, f_targ;
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

  // Waveforms, one file per simulator, each in its own native format.
  //
  // They are NOT merged into one file, and that is deliberate: ngspice's
  // timepoints are chosen by its own error control and are neither uniform
  // nor the coupling ticks, so putting the analog into the VCD would mean
  // resampling it onto the digital grid. That is the step that turns a real
  // waveform into a plausible-looking one. Two files, two timebases, both
  // exact -- and the same wall-clock seconds on each axis, so any viewer
  // that opens both will line them up.
  initial begin
    $dumpfile("pll_digital.vcd");
    $dumpvars(0, tb);
  end

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
      f_meas = real'(vco_edges - edges_win0) / ((t_dig - t_win0) * 1e6);
      f_targ = REF_HZ * NDIV / 1e6;
      v_ctrl = ams_get("vout");
      $display("PLL f_vco = %0.2f MHz over %0.1f ns  (target %0.2f MHz)",
               f_meas, (t_dig - t_win0) * 1e9, f_targ);
      $display("PLL-DONE vctrl=%0.4f V", v_ctrl);

      // A VERDICT, not just numbers. The output being N x the reference is
      // what says the loop closed; a loop that has run away, stalled, or
      // been wired backwards is also quiet, and prints just as tidily.
      //
      // TOL_PCT is 2%, not tighter, because this example runs 3 us so it
      // finishes while you watch, and 3 us is mid-settle -- the 20 us run
      // reaches 400.00 MHz exactly, this one lands near 397.5. The check
      // still separates a working loop from a broken one by a wide margin:
      // an inverted loop runs away to a rail, and an open one sits at
      // whatever the VCO free-runs at.
      // One string literal each, not two adjacent ones: SystemVerilog has
      // no C-style adjacent-literal concatenation and the parser is right
      // to refuse it.
      if (vco_edges < 100)
        $display("PLL-FAIL the VCO produced almost no edges (%0d) -- the analog side is not oscillating", vco_edges);
      else if (v_ctrl < 0.2 || v_ctrl > 3.1)
        $display("PLL-FAIL control voltage %0.4f V has run to a rail -- the loop is inverted or open", v_ctrl);
      else if (((f_meas - f_targ) / f_targ) >  TOL_PCT / 100.0 ||
               ((f_meas - f_targ) / f_targ) < -TOL_PCT / 100.0)
        $display("PLL-FAIL %0.2f MHz is %0.2f%% off %0.2f MHz",
                 f_meas, 100.0 * (f_meas - f_targ) / f_targ, f_targ);
      else
        $display("PLL-OK locked within %0.2f%% of %0.2f MHz at %0.4f V",
                 100.0 * (f_meas - f_targ) / f_targ, f_targ, v_ctrl);

      // Before ams_close: the plot belongs to the run, and halting the
      // background thread is what ends it.
      if (ams_write_raw("pll_analog.raw",
                        "v(aout) v(vout) v(dra) v(pupb) v(pdn)") != 0)
        $display("PLL-NOTE could not write pll_analog.raw");
      else
        $display("PLL-WAVE analog -> pll_analog.raw, digital -> pll_digital.vcd");

      ams_close();
      $finish;
    end
  end

endmodule
