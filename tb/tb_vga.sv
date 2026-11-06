// The VGA block with the simulated monitor, for its unit tests.
module tb_vga (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [31:0] wb_adr,
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,
    output int          frames,
    output int          timing_errors
);
    logic [3:0] r, g, b;
    logic       hs, vs;

    wb_vga u_vga (
        .clk, .rst, .wb_stb, .wb_we, .wb_adr, .wb_dat_w, .wb_sel, .wb_dat_r, .wb_ack,
        .vga_r(r), .vga_g(g), .vga_b(b), .vga_hs(hs), .vga_vs(vs)
    );

    vga_capture u_monitor (.clk, .rst, .r, .g, .b, .hs, .vs, .frames, .timing_errors);
endmodule
