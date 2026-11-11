// VGA display: 640x480 at 60 Hz, every framebuffer pixel doubled in both directions. Two modes
// (parameter MODE8, fixed per build):
//
//   MODE8 = 0: 320x240 framebuffer, 16 colours (4 bits per pixel), 16-entry palette.
//   MODE8 = 1: 320x200 framebuffer, 256 colours (8 bits per pixel), 256-entry palette; the
//              picture is 640x400 with black bars of 40 lines above and below (Doom's format).
//
// Wishbone slave:
//   0x2000_0000 + y*320 + x   framebuffer, one byte per pixel. Mode 0: bits 3:0 = colour index,
//                             use byte loads/stores. Mode 1: write only (reads return 0), any
//                             width; a word write sets 4 pixels.
//   0x1000_3000 + 4*i         PALETTE[i], i = 0..15 (mode 0): 12-bit colour, bits 11:8 R,
//                             7:4 G, 3:0 B
//   0x1000_3400 + 4*i         PALETTE256[i], i = 0..255 (mode 1), same format, write only
//   0x1000_3040               STATUS: bit 0 = in vertical blank (drawing now won't tear)
//   0x1000_3044               FRAME: counts frames (increments when vertical blank starts)
//
// Timing (VESA 640x480@60, here with a 25.0 MHz pixel rate from 50 MHz: one pixel every 2
// clocks, 59.5 Hz):
//   horizontal: 640 visible, 16 front porch, 96 sync, 48 back porch = 800 pixels per line
//   vertical:   480 visible, 10 front porch,  2 sync, 33 back porch = 525 lines per frame
//   both sync pulses are active low.
module wb_vga #(
    parameter bit MODE8 = 1'b0
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,
    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs
);
    localparam logic [9:0] H_VISIBLE = 10'd640, H_SYNC_START = 10'd656, H_SYNC_END = 10'd752,
                           H_LAST    = 10'd799;
    localparam logic [9:0] V_VISIBLE = 10'd480, V_SYNC_START = 10'd490, V_SYNC_END = 10'd492,
                           V_LAST    = 10'd524, V_LAST_VISIBLE = 10'd479;
    localparam logic [9:0] V_TOP8    = 10'd40,  V_BOTTOM8 = 10'd440;   // mode 1: 400 lines

    // ---------------------------------------------------------------- timing
    logic       pix;          // one clock in two: the 25 MHz pixel rate
    logic [9:0] h, v;         // position of the pixel being fetched
    logic [31:0] frame;

    always_ff @(posedge clk) begin
        if (rst) begin
            pix   <= 1'b0;
            h     <= '0;
            v     <= '0;
            frame <= '0;
        end else begin
            pix <= !pix;
            if (pix) begin
                if (h == H_LAST) begin
                    h <= '0;
                    if (v == V_LAST) v <= '0;
                    else                       v <= v + 10'd1;
                    if (v == V_LAST_VISIBLE) frame <= frame + 32'd1;
                end else begin
                    h <= h + 10'd1;
                end
            end
        end
    end

    logic hs, vs, vblank;
    assign hs     = !(h >= H_SYNC_START && h < H_SYNC_END);
    assign vs     = !(v >= V_SYNC_START && v < V_SYNC_END);
    assign vblank = v >= V_VISIBLE;

    logic fb_access, reg_access, fb_read_pending;
    assign fb_access  = wb_stb && !wb_ack && wb_adr[29];
    assign reg_access = wb_stb && !wb_ack && !wb_adr[29];

    logic [31:0] fb_dat_r;    // framebuffer read data for the bus, valid the cycle after
    logic [31:0] reg_dat_r;
    logic [11:0] palette16 [16];

    // ---------------------------------------------------------------- framebuffer and output
    generate
        if (MODE8) begin : g_mode8
            // Pixel (h, v) on screen shows framebuffer pixel (h/2, (v-40)/2).
            logic        visible;
            logic [8:0]  line;
            logic [15:0] fetch_index;
            assign visible     = h < H_VISIBLE && v >= V_TOP8 && v < V_BOTTOM8;
            assign line        = v[9:1] - 9'd20;
            assign fetch_index = ({7'b0, line} << 8) + ({7'b0, line} << 6) + {7'b0, h[9:1]};

            logic [7:0] fb_pixel;
            fb8_ram u_fb (
                .clk,
                .w_be    ((fb_access && wb_we) ? wb_sel : 4'b0000),
                .w_addr  (wb_adr[15:2]),
                .w_data  (wb_dat_w),
                .r_en    (pix),
                .r_addr  (visible ? fetch_index : 16'd0),
                .r_data  (fb_pixel)
            );
            assign fb_dat_r = '0;   // write only in this mode

            // 256-entry palette: written by the CPU, read with the pixel just fetched (one more
            // pixel of delay, so the syncs are delayed by two pixels here).
            logic [11:0] palette256 [256];
            logic [11:0] colour;
            always_ff @(posedge clk) begin
                if (reg_access && wb_we && wb_adr[10] && wb_sel[1:0] == 2'b11)
                    palette256[wb_adr[9:2]] <= wb_dat_w[11:0];
                if (pix)
                    colour <= palette256[fb_pixel];
            end

            logic [1:0] visible_q, hs_q, vs_q;
            always_ff @(posedge clk) begin
                if (rst) begin
                    visible_q <= '0;
                    hs_q      <= 2'b11;
                    vs_q      <= 2'b11;
                    {vga_r, vga_g, vga_b} <= 12'h000;
                    vga_hs    <= 1'b1;
                    vga_vs    <= 1'b1;
                end else if (pix) begin
                    visible_q <= {visible_q[0], visible};
                    hs_q      <= {hs_q[0], hs};
                    vs_q      <= {vs_q[0], vs};
                    {vga_r, vga_g, vga_b} <= visible_q[1] ? colour : 12'h000;
                    vga_hs    <= hs_q[1];
                    vga_vs    <= vs_q[1];
                end
            end
        end else begin : g_mode4
            // Pixel (h, v) on screen shows framebuffer pixel (h/2, v/2): index (v/2)*320 + h/2,
            // with *320 written as *256 + *64.
            logic        visible;
            logic [16:0] fetch_index;
            assign visible     = h < H_VISIBLE && v < V_VISIBLE;
            assign fetch_index = ({8'b0, v[9:1]} << 8) + ({8'b0, v[9:1]} << 6) + {8'b0, h[9:1]};

            logic [1:0] lane;
            logic [3:0] fb_pixel, cpu_rdata;
            assign lane = wb_adr[1:0];

            fb_ram u_fb (
                .clk,
                .a_en    (pix),
                .a_addr  (visible ? fetch_index : 17'd0),
                .a_rdata (fb_pixel),
                .b_en    (fb_access),
                .b_we    (fb_access && wb_we && wb_sel[lane]),
                .b_addr  (wb_adr[16:0]),
                .b_wdata (wb_dat_w[8*lane +: 4]),
                .b_rdata (cpu_rdata)
            );
            // A read returns the pixel in every byte lane, so a byte load at any address gets it.
            assign fb_dat_r = {4{4'b0, cpu_rdata}};

            logic visible_q, hs_q, vs_q;   // delayed one pixel, to line up with the RAM read
            // Outputs start at their idle levels (syncs high, black), so the monitor never sees a
            // fake sync pulse at power-up.
            always_ff @(posedge clk) begin
                if (rst) begin
                    visible_q <= 1'b0;
                    hs_q      <= 1'b1;
                    vs_q      <= 1'b1;
                    {vga_r, vga_g, vga_b} <= 12'h000;
                    vga_hs    <= 1'b1;
                    vga_vs    <= 1'b1;
                end else if (pix) begin
                    visible_q <= visible;
                    hs_q      <= hs;
                    vs_q      <= vs;
                    {vga_r, vga_g, vga_b} <= visible_q ? palette16[fb_pixel] : 12'h000;
                    vga_hs    <= hs_q;
                    vga_vs    <= vs_q;
                end
            end
        end
    endgenerate

    // ---------------------------------------------------------------- registers
    always_ff @(posedge clk) begin
        if (rst) begin
            // CGA-style default colours: black, blue, green, cyan, red, magenta, brown, light
            // grey, dark grey, and the bright versions.
            palette16 <= '{12'h000, 12'h00A, 12'h0A0, 12'h0AA, 12'hA00, 12'hA0A, 12'hA50, 12'hAAA,
                           12'h555, 12'h55F, 12'h5F5, 12'h5FF, 12'hF55, 12'hF5F, 12'hFF5, 12'hFFF};
            wb_ack          <= 1'b0;
            fb_read_pending <= 1'b0;
        end else begin
            wb_ack          <= wb_stb && !wb_ack;
            fb_read_pending <= fb_access;
            if (reg_access && wb_we && !wb_adr[10] && !wb_adr[6] && wb_sel[1:0] == 2'b11) begin
                palette16[wb_adr[5:2]] <= wb_dat_w[11:0];
            end
            if (reg_access) begin
                if (!wb_adr[6])          reg_dat_r <= {20'b0, palette16[wb_adr[5:2]]};
                else if (wb_adr[2])      reg_dat_r <= frame;
                else                     reg_dat_r <= {31'b0, vblank};
            end
        end
    end

    assign wb_dat_r = fb_read_pending ? fb_dat_r : reg_dat_r;
endmodule
