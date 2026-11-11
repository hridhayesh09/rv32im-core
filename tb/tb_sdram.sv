// SDRAM controller + chip model, for the controller's unit tests.
module tb_sdram (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    input  logic [31:0] wb_adr,
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,
    input  logic         line_req,
    input  logic         line_we,
    input  logic [25:0]  line_addr,
    input  logic [127:0] line_wdata,
    output logic [127:0] line_rdata,
    output logic         line_ack,
    output int          violations,
    output int          refreshes
);
    logic        cke, cs_n, ras_n, cas_n, we_n, dq_oe;
    logic [1:0]  ba, dqm;
    logic [12:0] addr;
    logic [15:0] dq_out, dq_in;

    sdram_ctrl u_ctrl (
        .clk, .rst, .wb_stb, .wb_we, .wb_adr, .wb_dat_w, .wb_sel, .wb_dat_r, .wb_ack,
        .line_req, .line_we, .line_addr, .line_wdata, .line_rdata, .line_ack,
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
        .violations, .refreshes
    );
endmodule
