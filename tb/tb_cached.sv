// The ASIC design (rtl/rv32im_asic.sv: core, instruction cache, data cache, arbiter) in front of a
// slow line memory: the whole program (at 0x8000_0000) is reached only through the caches. Same
// retire trace as tb_top, so every lockstep test can run through the caches. Cache sizes and
// associativity are parameters.
module tb_cached #(
    parameter int ICACHE_SIZE = 256,
    parameter int ICACHE_WAYS = 1,
    parameter int DCACHE_SIZE = 256,
    parameter int DCACHE_WAYS = 1
) (
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
    logic         mem_req, mem_we, mem_ack;
    logic [31:0]  mem_addr;
    logic [127:0] mem_wdata, mem_rdata;

    rv32im_asic #(.ICACHE_SIZE(ICACHE_SIZE), .ICACHE_WAYS(ICACHE_WAYS),
                  .DCACHE_SIZE(DCACHE_SIZE), .DCACHE_WAYS(DCACHE_WAYS)) u_dut (.*);

    line_mem u_mem (
        .clk, .rst,
        .req (mem_req), .we (mem_we), .addr (mem_addr), .wdata (mem_wdata), .rdata (mem_rdata),
        .ack (mem_ack)
    );
endmodule
