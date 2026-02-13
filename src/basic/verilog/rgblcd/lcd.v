module LCDC
(
    input  rst,
    input  pclk,

    output LCD_DE,
    output LCD_HSYNC,
    output LCD_VSYNC,

    output [4:0] LCD_B,
    output [5:0] LCD_G,
    output [4:0] LCD_R
);

    reg [15:0] x;
    reg [15:0] y;

    localparam vbp    = 16'd12;
    localparam vpulse = 16'd1;
    localparam vact   = 16'd272;
    localparam vfp    = 16'd1;

    localparam hbp    = 16'd43;
    localparam hpulse = 16'd1;
    localparam hact   = 16'd480;
    localparam hfp    = 16'd2;

    localparam xmax = hact + hbp + hfp;
    localparam ymax = vact + vbp + vfp;

    // --- Pixel scan counters ---
    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            y <= 16'b0;
            x <= 16'b0;
        end else if (x == xmax) begin
            x <= 16'b0;
            y <= y + 1'b1;
        end else if (y == ymax) begin
            y <= 16'b0;
            x <= 16'b0;
        end else
            x <= x + 1'b1;
    end

    // --- Sync and data enable ---
    assign LCD_HSYNC = ((x >= hpulse) && (x <= (xmax - hfp))) ? 1'b0 : 1'b1;
    assign LCD_VSYNC = ((y >= vpulse) && (y <= (ymax - 0)))    ? 1'b0 : 1'b1;
    assign LCD_DE    = ((x >= hbp) && (x <= xmax - hfp) &&
                        (y >= vbp) && (y <= ymax - vfp - 1))   ? 1'b1 : 1'b0;

    // --- Active pixel coordinates ---
    wire [15:0] px = x - hbp;
    wire [15:0] py = y - vbp;

    // --- Frame counter (~60 Hz) ---
    reg [23:0] frame_cnt;
    always @(posedge pclk or negedge rst) begin
        if (!rst)
            frame_cnt <= 24'd0;
        else if (x == 16'd0 && y == 16'd0)
            frame_cnt <= frame_cnt + 1'b1;
    end

    // =========================================================
    //  Background: animated diagonal rainbow stripes
    // =========================================================
    wire [7:0] diag = px[7:0] + py[7:0] + frame_cnt[7:0];
    wire [2:0] stripe = diag[5:3];

    reg [4:0] bg_r;
    reg [5:0] bg_g;
    reg [4:0] bg_b;

    always @(*) begin
        case (stripe)
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

    // =========================================================
    //  Bouncing diamond #1 (large, rainbow-filled interior)
    // =========================================================
    reg [15:0] ball1_x, ball1_y;
    reg ball1_dx, ball1_dy;

    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            ball1_x  <= 16'd240;
            ball1_y  <= 16'd136;
            ball1_dx <= 1'b0;
            ball1_dy <= 1'b0;
        end else if (x == 16'd0 && y == 16'd0) begin
            ball1_x <= ball1_dx ? (ball1_x - 16'd2) : (ball1_x + 16'd2);
            ball1_y <= ball1_dy ? (ball1_y - 16'd1) : (ball1_y + 16'd1);
            if (ball1_x >= 16'd449)     ball1_dx <= 1'b1;
            else if (ball1_x <= 16'd30) ball1_dx <= 1'b0;
            if (ball1_y >= 16'd241)     ball1_dy <= 1'b1;
            else if (ball1_y <= 16'd30) ball1_dy <= 1'b0;
        end
    end

    wire [15:0] d1x   = (px > ball1_x) ? (px - ball1_x) : (ball1_x - px);
    wire [15:0] d1y   = (py > ball1_y) ? (py - ball1_y) : (ball1_y - py);
    wire [15:0] dist1 = d1x + d1y;
    wire in_dia1   = (dist1 < 16'd30);
    wire edge_dia1 = (dist1 >= 16'd30) && (dist1 < 16'd34);

    // Interior cycles through rainbow colours over time
    wire [2:0] dia1_hue = dist1[4:2] + frame_cnt[3:1];
    reg [4:0] dia1_r;
    reg [5:0] dia1_g;
    reg [4:0] dia1_b;
    always @(*) begin
        case (dia1_hue)
            3'd0: begin dia1_r = 5'd31; dia1_g = 6'd0;  dia1_b = 5'd16; end
            3'd1: begin dia1_r = 5'd31; dia1_g = 6'd32; dia1_b = 5'd0;  end
            3'd2: begin dia1_r = 5'd16; dia1_g = 6'd63; dia1_b = 5'd0;  end
            3'd3: begin dia1_r = 5'd0;  dia1_g = 6'd63; dia1_b = 5'd16; end
            3'd4: begin dia1_r = 5'd0;  dia1_g = 6'd32; dia1_b = 5'd31; end
            3'd5: begin dia1_r = 5'd16; dia1_g = 6'd0;  dia1_b = 5'd31; end
            3'd6: begin dia1_r = 5'd31; dia1_g = 6'd16; dia1_b = 5'd31; end
            3'd7: begin dia1_r = 5'd31; dia1_g = 6'd63; dia1_b = 5'd16; end
        endcase
    end

    // =========================================================
    //  Bouncing diamond #2 (smaller, cyan, different velocity)
    // =========================================================
    reg [15:0] ball2_x, ball2_y;
    reg ball2_dx, ball2_dy;

    always @(posedge pclk or negedge rst) begin
        if (!rst) begin
            ball2_x  <= 16'd100;
            ball2_y  <= 16'd200;
            ball2_dx <= 1'b1;
            ball2_dy <= 1'b0;
        end else if (x == 16'd0 && y == 16'd0) begin
            ball2_x <= ball2_dx ? (ball2_x - 16'd1) : (ball2_x + 16'd1);
            ball2_y <= ball2_dy ? (ball2_y - 16'd2) : (ball2_y + 16'd2);
            if (ball2_x >= 16'd461)     ball2_dx <= 1'b1;
            else if (ball2_x <= 16'd18) ball2_dx <= 1'b0;
            if (ball2_y >= 16'd253)     ball2_dy <= 1'b1;
            else if (ball2_y <= 16'd18) ball2_dy <= 1'b0;
        end
    end

    wire [15:0] d2x   = (px > ball2_x) ? (px - ball2_x) : (ball2_x - px);
    wire [15:0] d2y   = (py > ball2_y) ? (py - ball2_y) : (ball2_y - py);
    wire [15:0] dist2 = d2x + d2y;
    wire in_dia2   = (dist2 < 16'd18);
    wire edge_dia2 = (dist2 >= 16'd18) && (dist2 < 16'd22);

    // =========================================================
    //  Colour-cycling screen border (4 px wide)
    // =========================================================
    wire near_edge = (px < 16'd4) || (px >= 16'd476) ||
                     (py < 16'd4) || (py >= 16'd268);
    wire [2:0] border_phase = frame_cnt[4:2];
    reg [4:0] border_r;
    reg [5:0] border_g;
    reg [4:0] border_b;
    always @(*) begin
        case (border_phase)
            3'd0: begin border_r = 5'd31; border_g = 6'd0;  border_b = 5'd0;  end
            3'd1: begin border_r = 5'd31; border_g = 6'd63; border_b = 5'd0;  end
            3'd2: begin border_r = 5'd0;  border_g = 6'd63; border_b = 5'd0;  end
            3'd3: begin border_r = 5'd0;  border_g = 6'd63; border_b = 5'd31; end
            3'd4: begin border_r = 5'd0;  border_g = 6'd0;  border_b = 5'd31; end
            3'd5: begin border_r = 5'd31; border_g = 6'd0;  border_b = 5'd31; end
            3'd6: begin border_r = 5'd31; border_g = 6'd32; border_b = 5'd16; end
            3'd7: begin border_r = 5'd16; border_g = 6'd32; border_b = 5'd31; end
        endcase
    end

    // =========================================================
    //  Final pixel compositing (priority: DE > border > dia1 > dia2 > bg)
    // =========================================================
    assign LCD_R = !LCD_DE   ? 5'd0     :
                   near_edge ? border_r :
                   edge_dia1 ? 5'd31    :
                   in_dia1   ? dia1_r   :
                   edge_dia2 ? 5'd0     :
                   in_dia2   ? 5'd0     :
                   bg_r;

    assign LCD_G = !LCD_DE   ? 6'd0     :
                   near_edge ? border_g :
                   edge_dia1 ? 6'd63    :
                   in_dia1   ? dia1_g   :
                   edge_dia2 ? 6'd0     :
                   in_dia2   ? 6'd63    :
                   bg_g;

    assign LCD_B = !LCD_DE   ? 5'd0     :
                   near_edge ? border_b :
                   edge_dia1 ? 5'd31    :
                   in_dia1   ? dia1_b   :
                   edge_dia2 ? 5'd0     :
                   in_dia2   ? 5'd31    :
                   bg_b;

endmodule
