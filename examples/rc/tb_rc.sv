`timescale 1ns/1ns
// The timescale is 1ns so that a BARE delay of 100 below really is 100 ns.
// It matters that this is honest rather than merely self-consistent: an
// earlier version used 1fs/1fs, so the digital side ticked every 100 fs
// while telling the analog those ticks were 100 ns. Both halves used the
// same wrong conversion, the skew printed as 0.0 and the RC waveform came
// out right -- because only the ANALOG time reaches the physics. The
// handshake was real and the absolute time mapping was off by 10^6.
// The coupling as a real design would use it: DIGITAL TIME DRIVES.
//
// The timescale above is load-bearing, not boilerplate. Without it this
// file took xezim's default unit (ns) while the code below divided
// $realtime by 1e15 to get seconds -- so the analog was asked to advance to
// 3.5e-11 s, it never moved, and every reading came back 0.000000 with the
// digital clock apparently frozen at zero. The simulation was in fact
// running; only the conversion was wrong. A units mistake in a coupling
// does not announce itself, it just produces a flat waveform.
//
// The first bench proved the handshake but ran entirely inside one initial
// block, tracking analog time in a variable -- xezim's own clock never
// advanced, and it reported "finished at time 0". That is enough to show
// the two simulators exchange values and enough to show nothing else. A
// real design has clocked RTL, so the analog side must be advanced FROM
// xezim's event queue, with $realtime as the authority on how far.
//
// So here a clock runs, an always block advances the analog to match
// $realtime, and the RC's drive comes from a counter in that clock domain.
// If the two clocks disagreed the capacitor would charge for the wrong
// length of time and the checks below would miss.
module tb;

  import "DPI-C" function int  ams_open(input string deck);
  import "DPI-C" function int  ams_drive(input string node, input real init);
  import "DPI-C" function int  ams_start(input real tstep, input real tstop);
  import "DPI-C" function int  ams_set(input string node, input real v);
  import "DPI-C" function int  ams_advance(input real t);
  import "DPI-C" function real ams_get(input string node);
  import "DPI-C" function real ams_time();
  import "DPI-C" function void ams_close();

  // 100 ns digital tick, and the analog is granted exactly the same.
  //
  // Written as a BARE number, not `100ns`. Measured on this simulator: with
  // `timescale 1fs/1fs` the literal `100ns` evaluates to 100.0 rather than
  // to 100_000_000, i.e. unit-suffixed time literals are not scaled by the
  // timescale, while a bare delay is one nanosecond (which is also what
  // --max-time documents). Depending on the suffix here asked the analog to
  // advance to 3.5e-11 s: it never moved, every reading came back
  // 0.000000, and the digital clock looked frozen at zero while in fact
  // running normally. A units mistake in a coupling does not announce
  // itself, it produces a flat waveform.
  localparam int  TICK_NS   = 100;     // bare delay units == ns here
  localparam real SEC_PER_NS = 1.0e-9;
  localparam real TICK_S    = 100.0e-9;
  localparam int  HALF_TICK = 50;      // 50 ticks = 5 us = 5 tau
  localparam real VDD       = 1.0;

  logic clk = 1'b0;
  logic drive = 1'b0;
  int   tick, rc, flips, bad;
  real  v, t_ana, t_dig;

  always #(TICK_NS / 2) clk = ~clk;

  initial begin
    bad = 0;
    if (ams_open("rc.cir") != 0) begin
      $display("AMS-FAIL open"); $finish;
    end
    if (ams_drive("vdrv", 0.0) != 0) begin
      $display("AMS-FAIL drive"); $finish;
    end
    if (ams_start(TICK_S, 40e-6) != 0) begin
      $display("AMS-FAIL start"); $finish;
    end
  end

  // One analog step per digital tick, and the target time comes from
  // $realtime rather than from a counter -- so a digital clock that drifted
  // would drag the analog with it instead of the two silently diverging.
  always @(posedge clk) begin
    t_dig = $realtime * SEC_PER_NS;      // ns -> s; see TICK_NS above
    rc = ams_advance(t_dig);
    if (rc < 0) begin
      $display("AMS-FAIL analog stalled at digital t=%0.3f us", t_dig * 1e6);
      bad = 1;
      $finish;
    end
    tick++;

    if (tick % HALF_TICK == 0) begin
      v = ams_get("out");
      t_ana = ams_time();
      $display("AMS dig=%0.3f us  ana=%0.3f us  skew=%0.1f ns  drive=%0b  v=%0.6f",
               t_dig * 1e6, t_ana * 1e6, (t_dig - t_ana) * 1e9, drive, v);
      // The two clocks must agree to within one granted step.
      if ((t_dig - t_ana) > 1.5 * TICK_S) bad = 1;
      if (drive === 1'b1 && v < 0.98 * VDD) bad = 1;
      if (drive === 1'b0 && flips > 0 && v > 0.02 * VDD) bad = 1;
      drive = ~drive;
      rc = ams_set("vdrv", drive ? VDD : 0.0);
      flips++;
      if (flips == 7) begin
        if (bad) $display("AMS-FAIL clocks or waveform diverged");
        else     $display("AMS-OK digital time drove the analog for %0d half periods",
                          flips);
        ams_close();
        $finish;
      end
    end
  end

endmodule
