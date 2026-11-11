// The SoC with a simulated SDRAM chip attached (tb/sdram_model.sv), for SoC-level tests.
module tb_soc #(
    parameter int UART_DIVISOR = 434,
    parameter int ICACHE_SIZE  = 4096,     // cache and branch predictor configuration (see soc.sv)
    parameter int ICACHE_WAYS  = 1,
    parameter int DCACHE_SIZE  = 4096,
    parameter int DCACHE_WAYS  = 1,
    parameter int BP_MODE      = 2,
    parameter int BTB_BITS     = 5,
    parameter int BHT_BITS     = 8,
    parameter int RAS_DEPTH    = 4,
    parameter int VGA8         = 0
) (
    input  logic        clk,
    input  logic        rst,
    output logic        txd,
    input  logic        rxd,
    output logic [9:0]  ledr,
    input  logic [9:0]  sw,
    input  logic [1:0]  key_n,
    output logic [47:0] hex_n,
    output int          sdram_violations,
    output int          sdram_refreshes,
    output int          vga_frames,
    output int          vga_timing_errors
);
    logic [3:0]  vga_r, vga_g, vga_b;
    logic        vga_hs, vga_vs;
    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba, dqm;
    logic [12:0] addr;
    logic [15:0] dq_out, dq_in;

    soc #(.UART_DIVISOR(UART_DIVISOR), .ICACHE_SIZE(ICACHE_SIZE), .ICACHE_WAYS(ICACHE_WAYS),
          .DCACHE_SIZE(DCACHE_SIZE), .DCACHE_WAYS(DCACHE_WAYS), .BP_MODE(BP_MODE),
          .BTB_BITS(BTB_BITS), .BHT_BITS(BHT_BITS), .RAS_DEPTH(RAS_DEPTH), .VGA8(VGA8 != 0)) u_soc (
        .clk, .rst, .txd, .rxd, .ledr, .sw, .key_n, .hex_n,
        .vga_r, .vga_g, .vga_b, .vga_hs, .vga_vs,
        .sdram_cke(cke), .sdram_cs_n(cs_n), .sdram_ras_n(ras_n), .sdram_cas_n(cas_n),
        .sdram_we_n(we_n), .sdram_ba(ba), .sdram_addr(addr), .sdram_dqm(dqm),
        .sdram_dq_out(dq_out), .sdram_dq_oe(dq_oe), .sdram_dq_in(dq_in)
    );

    /* verilator lint_off UNUSEDSIGNAL */
    logic unused_cke;
    assign unused_cke = cke;
    /* verilator lint_on UNUSEDSIGNAL */

    sdram_model u_chip (
        .clk, .cs_n, .ras_n, .cas_n, .we_n, .ba, .addr, .dqm,
        .dq_from_ctrl(dq_out), .dq_ctrl_oe(dq_oe), .dq_to_ctrl(dq_in),
        .violations(sdram_violations), .refreshes(sdram_refreshes)
    );
    // The simulated monitor; +vga_dump=<prefix> saves frames.
    vga_capture u_monitor (
        .clk, .rst, .r(vga_r), .g(vga_g), .b(vga_b), .hs(vga_hs), .vs(vga_vs),
        .frames(vga_frames), .timing_errors(vga_timing_errors)
    );
endmodule
