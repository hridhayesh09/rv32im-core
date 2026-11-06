// VGA display: 640x480 at 60 Hz, showing a 320x240 framebuffer with every pixel doubled in
// both directions, 16 colours from a programmable palette. Wishbone slave with two regions:
//
//   0x2000_0000 + y*320 + x   framebuffer, one byte per pixel (bits 3:0 = colour index).
//                             Use byte loads/stores (lbu/sb).
//   0x1000_3000 + 4*i         PALETTE[i], i = 0..15: 12-bit colour, bits 11:8 R, 7:4 G, 3:0 B
//   0x1000_3040               STATUS: bit 0 = in vertical blank (drawing now won't tear)
//   0x1000_3044               FRAME: counts frames (increments when vertical blank starts)
//
// Timing (VESA 640x480@60, here with a 25.0 MHz pixel rate from 50 MHz: one pixel every 2
// clocks, 59.5 Hz):
//   horizontal: 640 visible, 16 front porch, 96 sync, 48 back porch = 800 pixels per line
//   vertical:   480 visible, 10 front porch,  2 sync, 33 back porch = 525 lines per frame
//   both sync pulses are active low.
module wb_vga (
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

    logic visible, hs, vs, vblank;
    assign visible = h < H_VISIBLE && v < V_VISIBLE;
    assign hs      = !(h >= H_SYNC_START && h < H_SYNC_END);
    assign vs      = !(v >= V_SYNC_START && v < V_SYNC_END);
    assign vblank  = v >= V_VISIBLE;

    // ---------------------------------------------------------------- framebuffer
    // Pixel (h, v) on screen shows framebuffer pixel (h/2, v/2): index (v/2)*320 + h/2,
    // with *320 written as *256 + *64.
    logic [16:0] fetch_index;
    assign fetch_index = ({8'b0, v[9:1]} << 8) + ({8'b0, v[9:1]} << 6) + {8'b0, h[9:1]};

    logic        fb_access, cpu_fb_write;
    logic [3:0]  fb_pixel, cpu_rdata;
    logic [1:0]  lane;
    assign lane         = wb_adr[1:0];
    assign fb_access    = wb_stb && !wb_ack && wb_adr[29];
    assign cpu_fb_write = fb_access && wb_we && wb_sel[lane];

    fb_ram u_fb (
        .clk,
        .a_en    (pix),
        .a_addr  (visible ? fetch_index : 17'd0),
        .a_rdata (fb_pixel),
        .b_en    (fb_access),
        .b_we    (cpu_fb_write),
        .b_addr  (wb_adr[16:0]),
        .b_wdata (wb_dat_w[8*lane +: 4]),
        .b_rdata (cpu_rdata)
    );

    // ---------------------------------------------------------------- palette and output
    logic [11:0] palette [16];
    logic        visible_q, hs_q, vs_q;   // delayed one pixel, to line up with the RAM read

    // Outputs start at their idle levels (syncs high, black), so the monitor never sees a fake
    // sync pulse at power-up.
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
            {vga_r, vga_g, vga_b} <= visible_q ? palette[fb_pixel] : 12'h000;
            vga_hs    <= hs_q;
            vga_vs    <= vs_q;
        end
    end

    // ---------------------------------------------------------------- registers
    logic        reg_access, fb_read_pending;
    logic [31:0] reg_dat_r;
    assign reg_access = wb_stb && !wb_ack && !wb_adr[29];

    always_ff @(posedge clk) begin
        if (rst) begin
            // CGA-style default colours: black, blue, green, cyan, red, magenta, brown, light
            // grey, dark grey, and the bright versions.
            palette <= '{12'h000, 12'h00A, 12'h0A0, 12'h0AA, 12'hA00, 12'hA0A, 12'hA50, 12'hAAA,
                         12'h555, 12'h55F, 12'h5F5, 12'h5FF, 12'hF55, 12'hF5F, 12'hFF5, 12'hFFF};
            wb_ack          <= 1'b0;
            fb_read_pending <= 1'b0;
        end else begin
            wb_ack          <= wb_stb && !wb_ack;
            fb_read_pending <= fb_access;
            if (reg_access && wb_we && !wb_adr[6] && wb_sel[1:0] == 2'b11) begin
                palette[wb_adr[5:2]] <= wb_dat_w[11:0];
            end
            if (reg_access) begin
                if (!wb_adr[6])          reg_dat_r <= {20'b0, palette[wb_adr[5:2]]};
                else if (wb_adr[2])      reg_dat_r <= frame;
                else                     reg_dat_r <= {31'b0, vblank};
            end
        end
    end

    // A framebuffer read returns the pixel in every byte lane, so a byte load at any address
    // gets it.
    assign wb_dat_r = fb_read_pending ? {4{4'b0, cpu_rdata}} : reg_dat_r;
endmodule
