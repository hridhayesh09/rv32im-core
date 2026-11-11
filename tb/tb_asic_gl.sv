// Gate-level simulation of the ASIC flow's final netlist (asic/runs/<tag>/final/nl/rv32im_asic.nl.v,
// Sky130 standard cells) in front of the slow line memory: the same retire trace as tb_cached, so
// the same lockstep test checks it against Spike.
module tb_asic_gl (
    input  logic        clk,
    input  logic        rst,
    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc,
    output logic [31:0] rvfi_insn,
    output logic [4:0]  rvfi_rd,
    output logic [31:0] rvfi_rd_wdata,
    output logic        rvfi_mem_read,
    output logic [3:0]  rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_addr,
    output logic [31:0] rvfi_mem_wdata
);
    wire         mem_req, mem_we, mem_ack;
    wire [31:0]  mem_addr;
    wire [127:0] mem_wdata, mem_rdata;

    rv32im_asic u_dut (
        .clk, .rst,
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_rdata, .mem_ack,
        .rvfi_valid, .rvfi_pc, .rvfi_insn, .rvfi_rd, .rvfi_rd_wdata,
        .rvfi_mem_read, .rvfi_mem_wmask, .rvfi_mem_addr, .rvfi_mem_wdata
    );

    line_mem u_mem (
        .clk, .rst,
        .req (mem_req), .we (mem_we), .addr (mem_addr), .wdata (mem_wdata), .rdata (mem_rdata),
        .ack (mem_ack)
    );
endmodule
