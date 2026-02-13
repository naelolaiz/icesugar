// =============================================================================
// MODULE: LCDC — LCD Controller
// =============================================================================
// This module drives an RGB LCD panel (480 x 272 pixels, 16-bit colour).
// It generates all the timing signals the panel needs (HSYNC, VSYNC, DE) and
// outputs pixel colour data (R, G, B) every clock cycle.
//
// The visual output is:
//   - A fullscreen animated diagonal rainbow-stripe background
//   - Two bouncing diamond shapes on top of it
//   - A colour-cycling border around the screen edges
//
// VERILOG PRIMER (for non-Verilog readers):
//   "module"   = a self-contained hardware block (like a function in software).
//   "input"    = a signal coming INTO this module from the outside world.
//   "output"   = a signal this module DRIVES to the outside world.
//   "reg"      = a variable that can STORE a value (like a flip-flop / latch).
//   "wire"     = a connection between things — no storage, just passes a value.
//   "assign"   = continuously connects the right-hand side to the wire on the
//                left. Whenever any input changes, the output updates instantly
//                (combinational logic, like hooking wires together).
//   "always @(posedge clk)" = a block of logic that runs once every RISING
//                EDGE of the clock — this creates sequential (clocked) logic.
//   "always @(*)"           = a block that re-evaluates whenever ANY of its
//                inputs change — this creates combinational logic (no clock).
//   "localparam" = a constant known at synthesis time (like `const` in C).
//   "[N:0]"     = a bus (group of wires) N+1 bits wide. Bit 0 is the LSB.
//   "? :"       = ternary operator, same as in C:  condition ? if_true : if_false
//   "<="        = non-blocking assignment (used inside clocked always blocks).
//                 All "<=" in the same block happen simultaneously at the clock edge.
//   "16'd42"    = the number 42 expressed as a 16-bit decimal literal.
//   "1'b0"      = a single-bit literal with value 0.
// =============================================================================

module LCDC
(
    // ---- Inputs ----
    input  rst,       // Active-low reset: when rst=0, everything resets.
                      // When rst=1, normal operation runs.
    input  pclk,      // Pixel clock: one tick per pixel. The LCD panel and
                      // this module both run from this clock. Typical freq
                      // is ~9 MHz for a 480x272 panel at ~60 Hz refresh.

    // ---- Outputs to the LCD panel ----
    output LCD_DE,    // Data Enable: tells the panel "the R/G/B values on the
                      // bus right now are valid pixel data — display them."
                      // HIGH during the visible (active) area, LOW during
                      // blanking (porch / sync) intervals.
    output LCD_HSYNC, // Horizontal sync: pulses LOW once per scan line to tell
                      // the panel "start a new row of pixels."
    output LCD_VSYNC, // Vertical sync: pulses LOW once per frame to tell the
                      // panel "start a new frame (top-left corner)."

    output [4:0] LCD_B,  // Blue  channel — 5 bits → 32 levels (0..31)
    output [5:0] LCD_G,  // Green channel — 6 bits → 64 levels (0..63)
                          //   (Human eyes are most sensitive to green, so
                          //    RGB565 gives green one extra bit.)
    output [4:0] LCD_R   // Red   channel — 5 bits → 32 levels (0..31)
                          // Together these make "RGB565": 5+6+5 = 16 bits per
                          // pixel, giving 65 536 possible colours.
);

    // =====================================================================
    //  SECTION 1 — TIMING PARAMETERS
    // =====================================================================
    // An LCD panel doesn't just show 480x272 pixels — each scan line has
    // invisible "blanking" regions around the visible area. This is a legacy
    // of CRT monitors but is still used to give the panel time to prepare.
    //
    // A single horizontal line looks like this in time:
    //
    //  |<-hpulse->|<---hbp--->|<------hact (480 visible pixels)------>|<-hfp->|
    //    sync        back                  active                       front
    //    pulse       porch                 (visible)                    porch
    //
    // The same structure repeats vertically for lines:
    //
    //  |<-vpulse->|<---vbp--->|<------vact (272 visible lines)------->|<-vfp->|
    //
    // The *pulse* is the sync signal.  The *porches* are padding.
    // The *act* (active) region is where we actually output pixel colours.
    // =====================================================================

    // x counts the current horizontal pixel position (column) within a line.
    // y counts the current vertical line number within a frame.
    // Both include blanking, so they go beyond the visible 480x272.
    reg [15:0] x;  // 16-bit register: can count 0..65535 (way more than needed,
                   // but 16 bits is a convenient round size on an FPGA).
    reg [15:0] y;  // Same for vertical line counter.

    // Vertical timing constants (in lines):
    localparam vbp    = 16'd12;   // Vertical back porch:  12 blank lines after
                                  //   VSYNC before visible area starts.
    localparam vpulse = 16'd1;    // Vertical sync pulse width: 1 line.
    localparam vact   = 16'd272;  // Vertical active: 272 visible lines.
    localparam vfp    = 16'd1;    // Vertical front porch: 1 blank line after
                                  //   visible area before next VSYNC.

    // Horizontal timing constants (in pixel clocks):
    localparam hbp    = 16'd43;   // Horizontal back porch: 43 blank pixels after
                                  //   HSYNC before visible pixels start.
    localparam hpulse = 16'd1;    // Horizontal sync pulse width: 1 pixel clock.
    localparam hact   = 16'd480;  // Horizontal active: 480 visible pixels per line.
    localparam hfp    = 16'd2;    // Horizontal front porch: 2 blank pixels after
                                  //   visible area before next HSYNC.

    // Maximum counter values for x and y.  x counts 0..xmax inclusive
    // (xmax+1 = 526 pixel clocks per line); y counts 0..ymax inclusive
    // (but y==ymax is a transient state that resets immediately).
    localparam xmax = hact + hbp + hfp;   // = 480 + 43 + 2 = 525 (last x value in a line)
    localparam ymax = vact + vbp + vfp;   // = 272 + 12 + 1 = 285 (last y value in a frame)

    // =====================================================================
    //  SECTION 2 — PIXEL / LINE COUNTERS
    // =====================================================================
    // On every rising edge of pclk, we increment x.
    // When x reaches xmax, we reset x to 0 and increment y.
    // When y reaches ymax (checked only when x is NOT xmax), we reset
    // both to 0.  Note: since the x==xmax check has priority, y==ymax
    // is only processed once x wraps back to 0 on the next cycle.
    // This produces a raster scan: left→right, top→bottom, repeating.
    //
    // "always @(posedge pclk or negedge rst)" means:
    //   "run this block whenever pclk goes 0→1  OR  rst goes 1→0."
    //   The rst part makes the reset ASYNCHRONOUS — it takes effect
    //   immediately, without waiting for a clock edge.
    // =====================================================================
    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            // RESET: when rst is LOW (active-low), force counters to zero.
            y <= 16'b0;    // 16'b0 = 16-bit binary zero (same as 16'd0).
            x <= 16'b0;
        end else if (x == xmax) begin
            // End of a horizontal line: go back to column 0, next row.
            x <= 16'b0;
            y <= y + 1'b1;   // 1'b1 = single-bit "1". Verilog will auto-widen
                              // it to 16 bits to match y.
        end else if (y == ymax) begin
            // End of the entire frame: wrap back to the very start (top-left).
            y <= 16'b0;
            x <= 16'b0;
        end else
            // Normal case: just move one pixel to the right.
            x <= x + 1'b1;
    end

    // =====================================================================
    //  SECTION 3 — SYNC & DATA-ENABLE SIGNALS
    // =====================================================================
    // These three "assign" statements create purely combinational logic:
    // the outputs track the current values of x and y with no delay.
    //
    // HSYNC is LOW (active) during the sync pulse region of each line.
    // VSYNC is LOW (active) during the sync pulse region of each frame.
    // DE is HIGH only when we are inside the visible pixel rectangle.
    // =====================================================================

    // HSYNC: LOW (active) during the back-porch and active regions,
    // i.e. when x is in [hpulse .. xmax-hfp] = [1 .. 523].
    // HIGH during the sync pulse (x=0) and front porch (x=524..525).
    assign LCD_HSYNC = ((x >= hpulse) && (x <= (xmax - hfp))) ? 1'b0 : 1'b1;

    // VSYNC: LOW when y is in [vpulse .. ymax] = [1 .. 285].
    // HIGH only at y=0 (the sync pulse line).
    assign LCD_VSYNC = ((y >= vpulse) && (y <= (ymax - 0)))    ? 1'b0 : 1'b1;

    // DE (Data Enable): HIGH only inside the visible area.
    // Horizontal: x in [hbp .. xmax-hfp] = [43 .. 523] → 481 pixels wide.
    // Vertical:   y in [vbp .. ymax-vfp-1] = [12 .. 283] → 272 lines.
    // The panel ignores R/G/B values whenever DE is LOW.
    assign LCD_DE    = ((x >= hbp) && (x <= xmax - hfp) &&
                        (y >= vbp) && (y <= ymax - vfp - 1))   ? 1'b1 : 1'b0;

    // =====================================================================
    //  SECTION 4 — ACTIVE PIXEL COORDINATES
    // =====================================================================
    // px and py are convenience signals that map the raw counters (x, y)
    // into (0,0)-based coordinates within the 480x272 visible area.
    // We simply subtract the back-porch offsets.
    //
    // "wire" means these are just wires — no storage. They continuously
    // reflect (x - hbp) and (y - vbp) in real time.
    // =====================================================================
    wire [15:0] px = x - hbp;   // px: 0 = left edge,  480 = right edge (481 pixels)
    wire [15:0] py = y - vbp;   // py: 0 = top  edge,  271 = bottom edge (272 lines)

    // =====================================================================
    //  SECTION 5 — FRAME COUNTER (animation timer)
    // =====================================================================
    // We want things to move over time.  frame_cnt increments by 1 every
    // frame (~60 Hz).  We detect "start of frame" by checking x==0 && y==0.
    //
    // IMPORTANT: the very first clock after reset also has x==0 && y==0,
    // so frame_cnt (and ball positions) update immediately on the first
    // posedge after reset is released — there is no "frame 0" idle state.
    //
    // 24 bits can count up to 16 777 215 frames — at 60 fps that's ~77 hours
    // before it wraps around (which is fine; wrapping just restarts the
    // animation cycle).
    // =====================================================================
    reg [23:0] frame_cnt;  // 24-bit register for the frame counter.

    always @(posedge pclk or negedge rst) begin
        if (!rst)
            frame_cnt <= 24'd0;                        // Reset to 0.
        else if (x == 16'd0 && y == 16'd0)             // First pixel of a new frame?
            frame_cnt <= frame_cnt + 1'b1;             // Yes → count it.
    end

    // =====================================================================
    //  SECTION 6 — BACKGROUND: ANIMATED DIAGONAL RAINBOW STRIPES
    // =====================================================================
    // We add the pixel's x, y, and the animation timer together. Because we
    // only keep the low 8 bits, the sum wraps every 256 — creating repeating
    // diagonal stripes.  Adding frame_cnt makes the stripes scroll over time.
    //
    // We then grab bits [5:3] of the result (3 bits → values 0..7) to pick
    // one of eight rainbow colours.  Each colour band is 8 pixels wide
    // (2^3 = 8 values of the lower bits per stripe index change).
    // =====================================================================

    // diag: the combined position + time, truncated to 8 bits.
    wire [7:0] diag = px[7:0] + py[7:0] + frame_cnt[7:0];

    // stripe: picks which of the 8 rainbow colours this pixel belongs to.
    // Bits [5:3] means we divide diag by 8 (ignoring the lowest 3 bits).
    wire [2:0] stripe = diag[5:3];

    // bg_r, bg_g, bg_b: the background colour for this pixel.
    // "reg" here doesn't mean a flip-flop — since these are assigned inside
    // an "always @(*)" block (combinational), the synthesizer builds a MUX
    // (multiplexer) rather than a register.
    reg [4:0] bg_r;   // 5 bits for red   (matches LCD_R width)
    reg [5:0] bg_g;   // 6 bits for green  (matches LCD_G width)
    reg [4:0] bg_b;   // 5 bits for blue   (matches LCD_B width)

    // "always @(*)" means "re-evaluate this block whenever ANY signal it
    //  reads changes."  This is purely combinational — like a truth table
    //  or a chain of if/else or a switch/case in hardware.
    always @(*) begin
        // "case (stripe)" is like "switch (stripe)" in C.
        // For each value of stripe (0..7), assign an RGB colour.
        case (stripe)
            //          Red max=31      Green max=63     Blue max=31
            3'd0: begin bg_r = 5'd31; bg_g = 6'd0;  bg_b = 5'd0;  end // Red
            3'd1: begin bg_r = 5'd31; bg_g = 6'd40; bg_b = 5'd0;  end // Orange
            3'd2: begin bg_r = 5'd31; bg_g = 6'd63; bg_b = 5'd0;  end // Yellow
            3'd3: begin bg_r = 5'd0;  bg_g = 6'd63; bg_b = 5'd0;  end // Green
            3'd4: begin bg_r = 5'd0;  bg_g = 6'd48; bg_b = 5'd24; end // Teal
            3'd5: begin bg_r = 5'd0;  bg_g = 6'd0;  bg_b = 5'd31; end // Blue
            3'd6: begin bg_r = 5'd20; bg_g = 6'd0;  bg_b = 5'd31; end // Purple
            3'd7: begin bg_r = 5'd31; bg_g = 6'd0;  bg_b = 5'd20; end // Magenta
        endcase
    end

    // =====================================================================
    //  SECTION 7 — BOUNCING DIAMOND #1 (large, rainbow-filled interior)
    // =====================================================================
    // This diamond's centre (ball1_x, ball1_y) moves across the screen.
    // Two direction flags (ball1_dx, ball1_dy) control whether it moves
    // left/right and up/down.  When it hits a boundary, the flag flips.
    // This is the classic "bouncing ball" / DVD screensaver logic.
    // =====================================================================

    // Position of diamond #1's centre, in active-pixel coordinates.
    reg [15:0] ball1_x, ball1_y;

    // Direction flags: 0 = moving right/down, 1 = moving left/up.
    reg ball1_dx, ball1_dy;

    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            // On reset, place the diamond in the centre of the screen.
            ball1_x  <= 16'd240;   // Horizontal centre (480 / 2)
            ball1_y  <= 16'd136;   // Vertical centre   (272 / 2)
            ball1_dx <= 1'b0;      // Start moving right
            ball1_dy <= 1'b0;      // Start moving down
        end else if (x == 16'd0 && y == 16'd0) begin
            // --- Once per frame (start-of-frame), update position ---

            // Move horizontally: if dx=1 go left (subtract), else right (add).
            // "? :" is a ternary/conditional — same as in C.
            // The speed is 2 pixels per frame horizontally.
            ball1_x <= ball1_dx ? (ball1_x - 16'd2) : (ball1_x + 16'd2);

            // Move vertically: speed is 1 pixel per frame.
            ball1_y <= ball1_dy ? (ball1_y - 16'd1) : (ball1_y + 16'd1);

            // --- Boundary checks: reverse direction at screen edges ---
            // The diamond has radius 30 (see dist1 < 30 below), so:
            //   Right wall:  480 - 1 - 30 = 449  → reverse when x >= 449
            //   Left wall:   0 + 30 = 30          → reverse when x <= 30
            if (ball1_x >= 16'd449)     ball1_dx <= 1'b1;  // Hit right → go left
            else if (ball1_x <= 16'd30) ball1_dx <= 1'b0;  // Hit left  → go right

            //   Bottom wall: 272 - 1 - 30 = 241  → reverse when y >= 241
            //   Top wall:    0 + 30 = 30          → reverse when y <= 30
            if (ball1_y >= 16'd241)     ball1_dy <= 1'b1;  // Hit bottom → go up
            else if (ball1_y <= 16'd30) ball1_dy <= 1'b0;  // Hit top    → go down
        end
        // NOTE: on all other clock cycles (not start-of-frame), nothing
        // happens — the registers keep their current values automatically.
    end

    // --- Diamond shape detection ---
    // A diamond (rotated square) centred at (cx,cy) with radius r is the set
    // of all pixels where |px - cx| + |py - cy| < r.
    // This is the "Manhattan distance" or "taxicab distance."
    //
    // d1x = |px - ball1_x|  (horizontal distance from centre)
    // d1y = |py - ball1_y|  (vertical distance from centre)
    // dist1 = d1x + d1y     (Manhattan distance)
    wire [15:0] d1x   = (px > ball1_x) ? (px - ball1_x) : (ball1_x - px);
    wire [15:0] d1y   = (py > ball1_y) ? (py - ball1_y) : (ball1_y - py);
    wire [15:0] dist1 = d1x + d1y;

    // in_dia1: true if this pixel is INSIDE the diamond (distance < 30).
    wire in_dia1   = (dist1 < 16'd30);

    // edge_dia1: true if this pixel is on the diamond's OUTLINE (distance 30..33).
    // This 4-pixel-wide ring will be drawn in a bright "edge" colour.
    wire edge_dia1 = (dist1 >= 16'd30) && (dist1 < 16'd34);

    // --- Diamond #1 interior colour: rainbow rings that cycle over time ---
    // We use 3 bits of the distance (creating concentric rings of same hue)
    // plus 3 bits of the frame counter (making the colours rotate over time).
    // The result (dia1_hue) selects one of 8 colours, just like the background.
    wire [2:0] dia1_hue = dist1[4:2] + frame_cnt[3:1];

    reg [4:0] dia1_r;
    reg [5:0] dia1_g;
    reg [4:0] dia1_b;

    always @(*) begin
        case (dia1_hue)
            3'd0: begin dia1_r = 5'd31; dia1_g = 6'd0;  dia1_b = 5'd16; end // Rose
            3'd1: begin dia1_r = 5'd31; dia1_g = 6'd32; dia1_b = 5'd0;  end // Orange
            3'd2: begin dia1_r = 5'd16; dia1_g = 6'd63; dia1_b = 5'd0;  end // Lime
            3'd3: begin dia1_r = 5'd0;  dia1_g = 6'd63; dia1_b = 5'd16; end // Spring
            3'd4: begin dia1_r = 5'd0;  dia1_g = 6'd32; dia1_b = 5'd31; end // Cyan
            3'd5: begin dia1_r = 5'd16; dia1_g = 6'd0;  dia1_b = 5'd31; end // Indigo
            3'd6: begin dia1_r = 5'd31; dia1_g = 6'd16; dia1_b = 5'd31; end // Pink
            3'd7: begin dia1_r = 5'd31; dia1_g = 6'd63; dia1_b = 5'd16; end // Gold
        endcase
    end

    // =====================================================================
    //  SECTION 8 — BOUNCING DIAMOND #2 (smaller, cyan, different speed)
    // =====================================================================
    // Identical logic to diamond #1, but with:
    //   - a smaller radius (18 instead of 30)
    //   - different starting position (100, 200)
    //   - different velocity (1 px/frame horizontal, 2 px/frame vertical)
    //   - starts moving left & down instead of right & down
    // This makes the two diamonds trace different paths and rarely overlap
    // the same way twice, keeping things visually interesting.
    // =====================================================================

    reg [15:0] ball2_x, ball2_y;   // Centre position of diamond #2.
    reg ball2_dx, ball2_dy;        // Direction flags for diamond #2.

    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            ball2_x  <= 16'd100;   // Start near the left side
            ball2_y  <= 16'd200;   // Start near the bottom
            ball2_dx <= 1'b1;      // Start moving LEFT (opposite of diamond #1)
            ball2_dy <= 1'b0;      // Start moving down
        end else if (x == 16'd0 && y == 16'd0) begin
            // Horizontal speed: 1 pixel/frame (slower than diamond #1).
            ball2_x <= ball2_dx ? (ball2_x - 16'd1) : (ball2_x + 16'd1);

            // Vertical speed: 2 pixels/frame (faster than diamond #1 vertically).
            ball2_y <= ball2_dy ? (ball2_y - 16'd2) : (ball2_y + 16'd2);

            // Bounce limits: radius is 18, so:
            //   Right:  480 - 1 - 18 = 461    Left:  18
            //   Bottom: 272 - 1 - 18 = 253    Top:   18
            if (ball2_x >= 16'd461)     ball2_dx <= 1'b1;  // Hit right → go left
            else if (ball2_x <= 16'd18) ball2_dx <= 1'b0;  // Hit left  → go right
            if (ball2_y >= 16'd253)     ball2_dy <= 1'b1;  // Hit bottom → go up
            else if (ball2_y <= 16'd18) ball2_dy <= 1'b0;  // Hit top    → go down
        end
    end

    // Manhattan distance from this pixel to diamond #2's centre.
    wire [15:0] d2x   = (px > ball2_x) ? (px - ball2_x) : (ball2_x - px);
    wire [15:0] d2y   = (py > ball2_y) ? (py - ball2_y) : (ball2_y - py);
    wire [15:0] dist2 = d2x + d2y;

    // Inside diamond #2 (distance < 18).
    wire in_dia2   = (dist2 < 16'd18);

    // Edge/outline of diamond #2 (distance 18..21 — 4 px wide).
    wire edge_dia2 = (dist2 >= 16'd18) && (dist2 < 16'd22);

    // =====================================================================
    //  SECTION 9 — COLOUR-CYCLING SCREEN BORDER (4 pixels wide)
    // =====================================================================
    // If the pixel is within 4 pixels of any screen edge, we draw a border
    // instead of the background.  The border colour cycles through 8 hues
    // over time (driven by bits [4:2] of frame_cnt, which changes every
    // 4 frames — giving a smooth-ish colour rotation).
    // =====================================================================

    // near_edge is true when the pixel is within 4 pixels of any screen edge.
    // "||" is logical OR.
    wire near_edge = (px < 16'd4) || (px >= 16'd476) ||   // left or right edge
                     (py < 16'd4) || (py >= 16'd268);     // top or bottom edge

    // Pick a colour phase from the frame counter.
    // Bits [4:2] → the phase changes every 4 frames (2^2 = 4).
    wire [2:0] border_phase = frame_cnt[4:2];

    reg [4:0] border_r;
    reg [5:0] border_g;
    reg [4:0] border_b;

    always @(*) begin
        case (border_phase)
            3'd0: begin border_r = 5'd31; border_g = 6'd0;  border_b = 5'd0;  end // Red
            3'd1: begin border_r = 5'd31; border_g = 6'd63; border_b = 5'd0;  end // Yellow
            3'd2: begin border_r = 5'd0;  border_g = 6'd63; border_b = 5'd0;  end // Green
            3'd3: begin border_r = 5'd0;  border_g = 6'd63; border_b = 5'd31; end // Cyan
            3'd4: begin border_r = 5'd0;  border_g = 6'd0;  border_b = 5'd31; end // Blue
            3'd5: begin border_r = 5'd31; border_g = 6'd0;  border_b = 5'd31; end // Magenta
            3'd6: begin border_r = 5'd31; border_g = 6'd32; border_b = 5'd16; end // Salmon
            3'd7: begin border_r = 5'd16; border_g = 6'd32; border_b = 5'd31; end // Sky
        endcase
    end

    // =====================================================================
    //  SECTION 10 — FINAL PIXEL COMPOSITING
    // =====================================================================
    // For each pixel, we decide which "layer" to show.  This is a priority
    // chain: the first condition that matches wins.  Think of it like layers
    // in a graphics editor — the topmost visible layer is drawn.
    //
    // Priority (highest to lowest):
    //   1. If LCD_DE is LOW (blanking area) → output black (0,0,0).
    //   2. If on the border → output the cycling border colour.
    //   3. If on diamond #1's edge → bright white-ish outline.
    //   4. If inside diamond #1 → rainbow ring colour.
    //   5. If on diamond #2's edge → dark outline (R=0,G=0,B=0).
    //   6. If inside diamond #2 → solid cyan (R=0,G=63,B=31).
    //   7. Otherwise → the rainbow-stripe background.
    //
    // Each "assign" is a chain of ternary operators (condition ? a : b).
    // In hardware this becomes a priority multiplexer — a big selector
    // circuit that picks one of several inputs based on the control signals.
    // =====================================================================

    assign LCD_R = !LCD_DE   ? 5'd0     :   // Blanking → black
                   near_edge ? border_r :   // Border layer
                   edge_dia1 ? 5'd31    :   // Diamond 1 outline → bright
                   in_dia1   ? dia1_r   :   // Diamond 1 fill → rainbow
                   edge_dia2 ? 5'd0     :   // Diamond 2 outline → dark
                   in_dia2   ? 5'd0     :   // Diamond 2 fill → no red (it's cyan)
                   bg_r;                    // Background rainbow stripes

    assign LCD_G = !LCD_DE   ? 6'd0     :   // Blanking → black
                   near_edge ? border_g :   // Border layer
                   edge_dia1 ? 6'd63    :   // Diamond 1 outline → bright
                   in_dia1   ? dia1_g   :   // Diamond 1 fill → rainbow
                   edge_dia2 ? 6'd0     :   // Diamond 2 outline → dark
                   in_dia2   ? 6'd63    :   // Diamond 2 fill → full green (cyan)
                   bg_g;                    // Background rainbow stripes

    assign LCD_B = !LCD_DE   ? 5'd0     :   // Blanking → black
                   near_edge ? border_b :   // Border layer
                   edge_dia1 ? 5'd31    :   // Diamond 1 outline → bright
                   in_dia1   ? dia1_b   :   // Diamond 1 fill → rainbow
                   edge_dia2 ? 5'd0     :   // Diamond 2 outline → dark
                   in_dia2   ? 5'd31    :   // Diamond 2 fill → full blue (cyan)
                   bg_b;                    // Background rainbow stripes

endmodule
