// The design for the ASIC flow (Stage 6, asic/): the core with an instruction cache and a write-
// back data cache, sharing one 16-byte line port to the outside memory through the arbiter.
// Everything the CPU reads or writes goes through the caches, so the chip needs only that port
// (plus clock and reset). The retire trace (rvfi_*) is brought out so the gate-level netlist can
// be checked against Spike exactly like the RTL.
//
// tb/tb_cached.sv is this module plus a simulated line memory: every lockstep test also runs on it.
// The caches' RAMs are flip-flops here (cache_ram.sv without the FPGA primitive), so cache sizes
// stay small.
module rv32im_asic #(
    parameter int ICACHE_SIZE = 256,
    parameter int ICACHE_WAYS = 1,
    parameter int DCACHE_SIZE = 256,
    parameter int DCACHE_WAYS = 1,
    parameter int BP_MODE     = 2,
    parameter int BTB_BITS    = 5,
    parameter int BHT_BITS    = 8,
    parameter int RAS_DEPTH   = 4
) (
    input  logic         clk,
    input  logic         rst,

    // Line port: hold mem_req (and the rest) until mem_ack; mem_rdata is valid with mem_ack.
    output logic         mem_req,
    output logic         mem_we,
    output logic [31:0]  mem_addr,
    output logic [127:0] mem_wdata,
    input  logic [127:0] mem_rdata,
    input  logic         mem_ack,

    output logic         rvfi_valid,
    output logic [31:0]  rvfi_pc,
    output logic [31:0]  rvfi_insn,
    output logic [4:0]   rvfi_rd,
    output logic [31:0]  rvfi_rd_wdata,
    output logic         rvfi_mem_read,
    output logic [3:0]   rvfi_mem_wmask,
    output logic [31:0]  rvfi_mem_addr,
    output logic [31:0]  rvfi_mem_wdata
);
    logic        imem_en, imem_stall, fetch_valid, cache_flush;
    logic        dmem_en, dmem_stall;
    logic [3:0]  dmem_we, mem_events;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;

    core #(.BP_MODE(BP_MODE), .BTB_BITS(BTB_BITS), .BHT_BITS(BHT_BITS), .RAS_DEPTH(RAS_DEPTH))
        u_core (.*);

    logic         i_req, i_we, i_ack, d_req, d_we, d_ack;
    logic [31:0]  i_addr, d_addr;
    logic [127:0] i_wdata, d_wdata;
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
        .mem_rdata (mem_rdata), .mem_ack (i_ack),
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
        .mem_rdata (mem_rdata), .mem_ack (d_ack),
        .ev_access (d_access), .ev_miss (d_miss)
    );

    assign mem_events = {d_miss, d_access, i_miss, i_access};

    mem_arbiter u_arbiter (
        .clk, .rst,
        .req0 (d_req), .we0 (d_we), .addr0 (d_addr), .wdata0 (d_wdata), .ack0 (d_ack),
        .req1 (i_req), .we1 (i_we), .addr1 (i_addr), .wdata1 (i_wdata), .ack1 (i_ack),
        .mem_req, .mem_we, .mem_addr, .mem_wdata, .mem_ack
    );
endmodule
