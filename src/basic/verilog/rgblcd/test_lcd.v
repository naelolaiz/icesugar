// =============================================================================
// TESTBENCH: test_lcd.v — Testbench for the LCDC module
// =============================================================================
`timescale 1ns / 1ps

module test_lcd;

    // ---- DUT Inputs ----
    reg rst;
    reg pclk;

    // ---- DUT Outputs ----
    wire LCD_DE;
    wire LCD_HSYNC;
    wire LCD_VSYNC;
    wire [4:0] LCD_B;
    wire [5:0] LCD_G;
    wire [4:0] LCD_R;

    // ---- Instantiate the Device Under Test (DUT) ----
    LCDC uut (
        .rst      (rst),
        .pclk     (pclk),
        .LCD_DE   (LCD_DE),
        .LCD_HSYNC(LCD_HSYNC),
        .LCD_VSYNC(LCD_VSYNC),
        .LCD_B    (LCD_B),
        .LCD_G    (LCD_G),
        .LCD_R    (LCD_R)
    );

    // ---- Timing parameters (mirrored from DUT for checking) ----
    localparam hbp    = 43;
    localparam hpulse = 1;
    localparam hact   = 480;
    localparam hfp    = 2;
    localparam xmax   = hact + hbp + hfp; // 525

    localparam vbp    = 12;
    localparam vpulse = 1;
    localparam vact   = 272;
    localparam vfp    = 1;
    localparam ymax   = vact + vbp + vfp; // 285

    // x counts 0..xmax inclusive, so one line = xmax+1 clocks.
    // y counts 0..ymax; y==ymax is reached when x wraps from xmax to 0,
    // then on the next cycle the y==ymax branch resets both to (0,0).
    localparam line_clks  = xmax + 1;             // 526 clocks per line
    // A full frame = ymax lines of line_clks each, plus the 1 extra clock
    // where y==ymax before it wraps back to (0,0).
    localparam frame_clks = ymax * line_clks + 1; // 149911 clocks per frame

    // ---- Clock generation: 10ns period (100 MHz, but period is arbitrary for test) ----
    initial pclk = 0;
    always #5 pclk = ~pclk;

    // ---- Helper variables ----
    integer errors;
    integer i, j;
    integer de_count;
    integer hsync_low_count;
    integer vsync_transitions;
    integer frame_pixel_count;

    // ---- Access internal signals for deeper checks ----
    // (In a real simulator, we reach into the hierarchy.)
    wire [15:0] dut_x = uut.x;
    wire [15:0] dut_y = uut.y;
    wire [15:0] dut_px = uut.px;
    wire [15:0] dut_py = uut.py;
    wire [23:0] dut_frame_cnt = uut.frame_cnt;
    wire [15:0] dut_ball1_x = uut.ball1_x;
    wire [15:0] dut_ball1_y = uut.ball1_y;
    wire        dut_ball1_dx = uut.ball1_dx;
    wire        dut_ball1_dy = uut.ball1_dy;
    wire [15:0] dut_ball2_x = uut.ball2_x;
    wire [15:0] dut_ball2_y = uut.ball2_y;
    wire        dut_ball2_dx = uut.ball2_dx;
    wire        dut_ball2_dy = uut.ball2_dy;

    // ---- Task: wait N clock cycles ----
    task wait_clks;
        input integer n;
        integer k;
        begin
            for (k = 0; k < n; k = k + 1)
                @(posedge pclk);
        end
    endtask

    // ---- Task: wait until start of next frame (x==0, y==0) ----
    task wait_frame_start;
        begin
            // Wait until we see x==0 && y==0
            @(posedge pclk);
            while (!(dut_x == 16'd0 && dut_y == 16'd0))
                @(posedge pclk);
        end
    endtask

    // ---- Main test sequence ----
    initial begin
        $dumpfile("test_lcd.vcd");
        $dumpvars(0, test_lcd);

        errors = 0;
        rst = 1;
        pclk = 0;

        // =================================================================
        // TEST 1: Reset behaviour
        // =================================================================
        $display("TEST 1: Reset behaviour");
        rst = 0;
        #20;
        @(posedge pclk);
        #1; // small delay after clock edge for signals to settle

        if (dut_x !== 16'd0) begin
            $display("  FAIL: x should be 0 after reset, got %0d", dut_x);
            errors = errors + 1;
        end
        if (dut_y !== 16'd0) begin
            $display("  FAIL: y should be 0 after reset, got %0d", dut_y);
            errors = errors + 1;
        end
        if (dut_frame_cnt !== 24'd0) begin
            $display("  FAIL: frame_cnt should be 0 after reset, got %0d", dut_frame_cnt);
            errors = errors + 1;
        end
        if (dut_ball1_x !== 16'd240) begin
            $display("  FAIL: ball1_x should be 240 after reset, got %0d", dut_ball1_x);
            errors = errors + 1;
        end
        if (dut_ball1_y !== 16'd136) begin
            $display("  FAIL: ball1_y should be 136 after reset, got %0d", dut_ball1_y);
            errors = errors + 1;
        end
        if (dut_ball1_dx !== 1'b0) begin
            $display("  FAIL: ball1_dx should be 0 after reset, got %0d", dut_ball1_dx);
            errors = errors + 1;
        end
        if (dut_ball1_dy !== 1'b0) begin
            $display("  FAIL: ball1_dy should be 0 after reset, got %0d", dut_ball1_dy);
            errors = errors + 1;
        end
        if (dut_ball2_x !== 16'd100) begin
            $display("  FAIL: ball2_x should be 100 after reset, got %0d", dut_ball2_x);
            errors = errors + 1;
        end
        if (dut_ball2_y !== 16'd200) begin
            $display("  FAIL: ball2_y should be 200 after reset, got %0d", dut_ball2_y);
            errors = errors + 1;
        end
        if (dut_ball2_dx !== 1'b1) begin
            $display("  FAIL: ball2_dx should be 1 after reset, got %0d", dut_ball2_dx);
            errors = errors + 1;
        end
        if (dut_ball2_dy !== 1'b0) begin
            $display("  FAIL: ball2_dy should be 0 after reset, got %0d", dut_ball2_dy);
            errors = errors + 1;
        end
        $display("  TEST 1 done.");

        // =================================================================
        // TEST 2: Release reset and verify counters start incrementing
        // =================================================================
        $display("TEST 2: Counter increment after reset release");
        rst = 1;
        @(posedge pclk); #1;
        // After one clock with rst=1, x should increment from 0 to 1
        // (at reset release, x was 0; first posedge with rst=1 increments it)
        @(posedge pclk); #1;
        if (dut_x === 16'd0 && dut_y === 16'd0) begin
            // x might still be 0 if we just released reset on this edge.
            // Give one more cycle.
            @(posedge pclk); #1;
        end
        if (dut_x < 16'd1) begin
            $display("  FAIL: x should be incrementing, got %0d", dut_x);
            errors = errors + 1;
        end
        $display("  TEST 2 done. x=%0d, y=%0d", dut_x, dut_y);

        // =================================================================
        // TEST 3: Verify x wraps at xmax and y increments
        // =================================================================
        $display("TEST 3: Horizontal wrap and vertical increment");
        // Reset and run exactly xmax+1 cycles to see wrap
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // Run xmax clocks: x should go 0,1,2,...,xmax, then wrap to 0 with y=1
        for (i = 0; i < xmax; i = i + 1)
            @(posedge pclk);
        #1;

        // After xmax clocks from x=0, x should have wrapped to 0 and y should be 1
        if (dut_x !== 16'd0) begin
            $display("  FAIL: x should wrap to 0 at xmax, got x=%0d", dut_x);
            errors = errors + 1;
        end
        if (dut_y !== 16'd1) begin
            $display("  FAIL: y should be 1 after first line, got y=%0d", dut_y);
            errors = errors + 1;
        end
        $display("  TEST 3 done. x=%0d, y=%0d", dut_x, dut_y);

        // =================================================================
        // TEST 4: Verify full frame wrap (y wraps at ymax)
        // =================================================================
        $display("TEST 4: Full frame wrap (y resets at ymax)");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // After first posedge, x=1. A full frame from (0,0) back to (0,0)
        // takes frame_clks clocks. We already consumed 1, so need frame_clks-1 more.
        for (i = 0; i < frame_clks - 1; i = i + 1)
            @(posedge pclk);
        #1;

        if (dut_x !== 16'd0 || dut_y !== 16'd0) begin
            $display("  FAIL: Counters should wrap to (0,0) after full frame. Got x=%0d, y=%0d", dut_x, dut_y);
            errors = errors + 1;
        end
        $display("  TEST 4 done. x=%0d, y=%0d", dut_x, dut_y);

        // =================================================================
        // TEST 5: Frame counter increments once per frame
        // =================================================================
        $display("TEST 5: Frame counter increment");
        rst = 0; #20; rst = 1;
        // NOTE: On the first posedge after reset, x==0 && y==0 is true,
        // so frame_cnt increments immediately from 0 to 1.
        @(posedge pclk); #1;

        if (dut_frame_cnt !== 24'd1) begin
            $display("  FAIL: frame_cnt should be 1 right after reset release, got %0d", dut_frame_cnt);
            errors = errors + 1;
        end

        // Run one complete frame (back to x=0,y=0) then one more clock for the update
        for (i = 0; i < frame_clks - 1; i = i + 1)
            @(posedge pclk);
        // Now at (0,0). Next posedge will increment frame_cnt.
        @(posedge pclk); #1;

        if (dut_frame_cnt !== 24'd2) begin
            $display("  FAIL: frame_cnt should be 2 after one frame, got %0d", dut_frame_cnt);
            errors = errors + 1;
        end

        // Run another frame
        for (i = 0; i < frame_clks - 1; i = i + 1)
            @(posedge pclk);
        @(posedge pclk); #1;

        if (dut_frame_cnt !== 24'd3) begin
            $display("  FAIL: frame_cnt should be 3 after two frames, got %0d", dut_frame_cnt);
            errors = errors + 1;
        end
        $display("  TEST 5 done. frame_cnt=%0d", dut_frame_cnt);

        // =================================================================
        // TEST 6: HSYNC signal timing
        // =================================================================
        $display("TEST 6: HSYNC signal behaviour");
        rst = 0; #20; rst = 1;
        // After reset, x=0 asynchronously. Check BEFORE first clock edge.
        #1;

        // At x=0: HSYNC = ((0 >= 1) && ...) ? 0 : 1 → HSYNC = 1 (HIGH)
        if (LCD_HSYNC !== 1'b1) begin
            $display("  FAIL: HSYNC should be HIGH at x=0, got %0b", LCD_HSYNC);
            errors = errors + 1;
        end

        // First posedge: x becomes 1 (hpulse=1)
        @(posedge pclk); #1;
        // At x=1: 1 >= 1 is true, 1 <= 523 is true → HSYNC = 0
        if (LCD_HSYNC !== 1'b0) begin
            $display("  FAIL: HSYNC should be LOW at x=hpulse(%0d), got %0b", hpulse, LCD_HSYNC);
            errors = errors + 1;
        end

        // Advance to x = xmax - hfp = 523. Currently at x=1, need 522 more clocks.
        for (i = 2; i <= xmax - hfp; i = i + 1)
            @(posedge pclk);
        #1;
        // At x=523: 523 >= 1 is true, 523 <= 523 is true → HSYNC = 0
        if (LCD_HSYNC !== 1'b0) begin
            $display("  FAIL: HSYNC should be LOW at x=%0d, got %0b", xmax - hfp, LCD_HSYNC);
            errors = errors + 1;
        end

        // Advance one more to x = xmax - hfp + 1 = 524
        @(posedge pclk); #1;
        // At x=524: 524 >= 1 is true, 524 <= 523 is false → HSYNC = 1
        if (LCD_HSYNC !== 1'b1) begin
            $display("  FAIL: HSYNC should be HIGH at x=%0d (front porch), got %0b", xmax - hfp + 1, LCD_HSYNC);
            errors = errors + 1;
        end
        $display("  TEST 6 done.");

        // =================================================================
        // TEST 7: VSYNC signal timing
        // =================================================================
        $display("TEST 7: VSYNC signal behaviour");
        rst = 0; #20; rst = 1;
        #1;

        // At y=0 (right after reset, before first clock):
        // VSYNC = ((0 >= 1) && ...) ? 0 : 1 → VSYNC = 1 (HIGH/idle)
        if (LCD_VSYNC !== 1'b1) begin
            $display("  FAIL: VSYNC should be HIGH at y=0, got %0b", LCD_VSYNC);
            errors = errors + 1;
        end

        // Advance to y=1: first posedge increments x to 1, then need
        // xmax more clocks to wrap x and increment y to 1.
        // Total: line_clks clocks from (0,0) to reach (0,1).
        for (i = 0; i < line_clks; i = i + 1)
            @(posedge pclk);
        #1;
        // At y=1: 1 >= 1 is true, 1 <= 285 is true → VSYNC = 0
        if (LCD_VSYNC !== 1'b0) begin
            $display("  FAIL: VSYNC should be LOW at y=vpulse(%0d), got %0b", vpulse, LCD_VSYNC);
            errors = errors + 1;
        end
        $display("  TEST 7 done.");

        // =================================================================
        // TEST 8: DE signal — active only in visible area
        // =================================================================
        $display("TEST 8: DE signal in visible area");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // DE should be LOW during blanking (y=0 is before vbp=12)
        if (LCD_DE !== 1'b0) begin
            $display("  FAIL: DE should be LOW during blanking at y=0, got %0b", LCD_DE);
            errors = errors + 1;
        end

        // Advance to y=vbp (12), x=hbp (43) — first visible pixel.
        // Currently at x=1, y=0 after first posedge. Use line_clks per line.
        // Need to reach x=hbp, y=vbp. From (1,0):
        //   rest of line 0: xmax clocks → (0,1)
        //   lines 1..11: 11 * line_clks clocks → (0,12)
        //   advance to x=hbp: hbp clocks → (hbp, 12)
        // Total: xmax + 11*line_clks + hbp
        for (i = 0; i < xmax + (vbp - 1) * line_clks + hbp; i = i + 1)
            @(posedge pclk);
        #1;
        // Now x=hbp=43, y=vbp=12 → DE should be HIGH
        if (LCD_DE !== 1'b1) begin
            $display("  FAIL: DE should be HIGH at first visible pixel (x=%0d, y=%0d), got %0b", dut_x, dut_y, LCD_DE);
            errors = errors + 1;
        end
        $display("  TEST 8 done. x=%0d, y=%0d, DE=%0b", dut_x, dut_y, LCD_DE);

        // =================================================================
        // TEST 9: Count DE-active pixels in one full line
        // DE is active for x in [hbp .. xmax-hfp] = 43..523 = 481 pixels
        // =================================================================
        $display("TEST 9: DE pixel count per visible line");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // Advance to y=vbp (first visible line), x=0.
        // From (1,0): xmax clocks to (0,1), then (vbp-1)*line_clks to (0,vbp).
        for (i = 0; i < xmax + (vbp - 1) * line_clks; i = i + 1)
            @(posedge pclk);

        // Count DE-high pixels over one full line (line_clks clocks)
        de_count = 0;
        for (i = 0; i < line_clks; i = i + 1) begin
            @(posedge pclk); #1;
            if (LCD_DE) de_count = de_count + 1;
        end

        // DE spans x = hbp to xmax - hfp inclusive = (xmax - hfp) - hbp + 1
        if (de_count !== (xmax - hfp - hbp + 1)) begin
            $display("  FAIL: Expected %0d DE-active pixels per line, got %0d", xmax - hfp - hbp + 1, de_count);
            errors = errors + 1;
        end
        $display("  TEST 9 done. DE count per line = %0d", de_count);

        // =================================================================
        // TEST 10: Count total DE-active pixels per frame (should be 480*272)
        // =================================================================
        $display("TEST 10: Total DE pixels per frame");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        de_count = 0;
        for (i = 0; i < frame_clks - 1; i = i + 1) begin
            @(posedge pclk); #1;
            if (LCD_DE) de_count = de_count + 1;
        end

        // DE per line = (xmax-hfp-hbp+1) = 481, visible lines = vact = 272
        if (de_count !== (xmax - hfp - hbp + 1) * vact) begin
            $display("  FAIL: Expected %0d DE-active pixels per frame, got %0d", (xmax - hfp - hbp + 1) * vact, de_count);
            errors = errors + 1;
        end
        $display("  TEST 10 done. Total DE pixels = %0d (expected %0d)", de_count, (xmax - hfp - hbp + 1) * vact);

        // =================================================================
        // TEST 11: Blanking area outputs black (R=0, G=0, B=0)
        // =================================================================
        $display("TEST 11: Blanking outputs black");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // At x=0, y=0: DE is LOW, so output should be black
        if (LCD_R !== 5'd0 || LCD_G !== 6'd0 || LCD_B !== 5'd0) begin
            $display("  FAIL: During blanking, output should be black. Got R=%0d G=%0d B=%0d", LCD_R, LCD_G, LCD_B);
            errors = errors + 1;
        end

        // Check a few more blanking pixels
        @(posedge pclk); #1;
        if (LCD_R !== 5'd0 || LCD_G !== 6'd0 || LCD_B !== 5'd0) begin
            $display("  FAIL: During blanking (x=1, y=0), output should be black. Got R=%0d G=%0d B=%0d", LCD_R, LCD_G, LCD_B);
            errors = errors + 1;
        end
        $display("  TEST 11 done.");

        // =================================================================
        // TEST 12: Active area outputs non-trivially (not all black)
        // =================================================================
        $display("TEST 12: Active area produces visible pixels");
        rst = 0; #20; rst = 1;
        @(posedge pclk); #1;

        // Advance to first visible pixel
        // From (1,0): xmax + (vbp-1)*line_clks + hbp clocks → (hbp, vbp)
        for (i = 0; i < xmax + (vbp - 1) * line_clks + hbp; i = i + 1)
            @(posedge pclk);
        #1;

        // Check that at least some pixels in the first visible line are non-black
        begin : non_black_check
            integer found_nonblack;
            found_nonblack = 0;
            for (i = 0; i < hact; i = i + 1) begin
                @(posedge pclk); #1;
                if (LCD_R != 0 || LCD_G != 0 || LCD_B != 0)
                    found_nonblack = 1;
            end
            if (!found_nonblack) begin
                $display("  FAIL: All visible pixels on first line are black — expected colour output");
                errors = errors + 1;
            end
        end
        $display("  TEST 12 done.");

        // =================================================================
        // TEST 13: Ball 1 movement — direction and position after one frame
        // =================================================================
        $display("TEST 13: Ball 1 position update after one frame");
        rst = 0; #20; rst = 1;
        // NOTE: On the first posedge, x==0 && y==0 triggers ball update.
        // So ball1 moves immediately: (240,136) → (242,137) on first clock.
        @(posedge pclk); #1;

        // After first clock: ball1 already moved once (dx=0→right +2, dy=0→down +1)
        if (dut_ball1_x !== 16'd242 || dut_ball1_y !== 16'd137) begin
            $display("  FAIL: Ball1 should be (242,137) after first frame update. x=%0d y=%0d", dut_ball1_x, dut_ball1_y);
            errors = errors + 1;
        end

        // Run one full frame to trigger the next update
        for (i = 0; i < frame_clks - 1; i = i + 1)
            @(posedge pclk);
        @(posedge pclk); #1;

        // After second frame update: x = 242+2 = 244, y = 137+1 = 138
        if (dut_ball1_x !== 16'd244) begin
            $display("  FAIL: Ball1 x should be 244 after two frames, got %0d", dut_ball1_x);
            errors = errors + 1;
        end
        if (dut_ball1_y !== 16'd138) begin
            $display("  FAIL: Ball1 y should be 138 after two frames, got %0d", dut_ball1_y);
            errors = errors + 1;
        end
        $display("  TEST 13 done. ball1_x=%0d, ball1_y=%0d", dut_ball1_x, dut_ball1_y);

        // =================================================================
        // TEST 14: Ball 2 movement — direction and position after one frame
        // =================================================================
        $display("TEST 14: Ball 2 position update after one frame");
        // Ball2 started at (100, 200), dx=1 (left), dy=0 (down), speed 1h/2v.
        // It has been updated twice (first clock after reset + one frame later).
        // After 2 updates: x = 100-1-1 = 98, y = 200+2+2 = 204
        if (dut_ball2_x !== 16'd98) begin
            $display("  FAIL: Ball2 x should be 98 after two frames, got %0d", dut_ball2_x);
            errors = errors + 1;
        end
        if (dut_ball2_y !== 16'd204) begin
            $display("  FAIL: Ball2 y should be 204 after two frames, got %0d", dut_ball2_y);
            errors = errors + 1;
        end
        $display("  TEST 14 done. ball2_x=%0d, ball2_y=%0d", dut_ball2_x, dut_ball2_y);

        // =================================================================
        // SUMMARY
        // =================================================================
        $display("======================================");
        if (errors == 0)
            $display("ALL TESTS PASSED");
        else
            $display("FAILED: %0d error(s)", errors);
        $display("======================================");

        $finish;
    end

endmodule
