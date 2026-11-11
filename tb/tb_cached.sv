// The core with an instruction cache and a data cache in front of a slow line memory: the whole
// program (at 0x8000_0000) is reached only through the caches. Same retire trace as tb_top, so
// every lockstep test can run through the caches. Cache sizes and associativity are parameters.
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
    logic        imem_en, imem_stall, fetch_valid, cache_flush;
    logic        dmem_en, dmem_stall;
    logic [3:0]  dmem_we, mem_events;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;

    core u_core (.*);

    logic         i_req, i_we, i_ack, d_req, d_we, d_ack, m_req, m_we, m_ack;
    logic [31:0]  i_addr, d_addr, m_addr;
    logic [127:0] i_wdata, d_wdata, m_wdata, m_rdata;
    logic         i_access, i_miss, d_access, d_miss;

    cache #(.SIZE(ICACHE_SIZE), .WAYS(ICACHE_WAYS), .WRITABLE(1'b0)) u_icache (
        .clk, .rst,
        .req_en    (imem_en),
        .req_we    (4'b0000),
        .req_addr  (imem_addr),
        .req_wdata ('0),
        .keep      (fetch_valid),
        .rdata     (imem_rdata),
        .stall     (imem_stall),
        .flush     (cache_flush),
        .mem_req   (i_req), .mem_we (i_we), .mem_addr (i_addr), .mem_wdata (i_wdata),
        .mem_rdata (m_rdata), .mem_ack (i_ack),
        .ev_access (i_access), .ev_miss (i_miss)
    );

    cache #(.SIZE(DCACHE_SIZE), .WAYS(DCACHE_WAYS), .WRITABLE(1'b1)) u_dcache (
        .clk, .rst,
        .req_en    (dmem_en),
        .req_we    (dmem_we),
        .req_addr  (dmem_addr),
        .req_wdata (dmem_wdata),
        .keep      (1'b1),
        .rdata     (dmem_rdata),
        .stall     (dmem_stall),
        .flush     (cache_flush),
        .mem_req   (d_req), .mem_we (d_we), .mem_addr (d_addr), .mem_wdata (d_wdata),
        .mem_rdata (m_rdata), .mem_ack (d_ack),
        .ev_access (d_access), .ev_miss (d_miss)
    );

    assign mem_events = {d_miss, d_access, i_miss, i_access};

    mem_arbiter u_arbiter (
        .clk, .rst,
        .req0 (d_req), .we0 (d_we), .addr0 (d_addr), .wdata0 (d_wdata), .ack0 (d_ack),
        .req1 (i_req), .we1 (i_we), .addr1 (i_addr), .wdata1 (i_wdata), .ack1 (i_ack),
        .mem_req (m_req), .mem_we (m_we), .mem_addr (m_addr), .mem_wdata (m_wdata),
        .mem_ack (m_ack)
    );

    line_mem u_mem (
        .clk, .rst,
        .req (m_req), .we (m_we), .addr (m_addr), .wdata (m_wdata), .rdata (m_rdata), .ack (m_ack)
    );
endmodule
