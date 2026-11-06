// Simulation top: the core with separate instruction and data RAMs, both loaded from the
// same program image (+program=<hex file>). The retire trace is brought out as ports.
//
// +random_stalls makes data accesses take a random number of extra cycles (like a slow bus
// device), to test the core's wait-state handling with every program.
module tb_top (
    input  logic        clk,
    input  logic        rst,
    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,
    output logic [4:0]  rvfi_rd,
    output logic [31:0] rvfi_rd_wdata,
    output logic        rvfi_mem_read,
    output logic [3:0]  rvfi_mem_wmask,
    output logic [31:0] rvfi_mem_addr,
    output logic [31:0] rvfi_mem_wdata
);
    logic        imem_en, dmem_en, dmem_stall;
    logic [3:0]  dmem_we;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;

    core u_core (.*);

    ram #(.INIT_PLUSARG("program")) u_imem (
        .clk   (clk),
        .en    (imem_en),
        .we    (4'b0000),
        .addr  (imem_addr),
        .wdata ('0),
        .rdata (imem_rdata)
    );

    ram #(.INIT_PLUSARG("program")) u_dmem (
        .clk   (clk),
        .en    (dmem_en),
        .we    (dmem_we),
        .addr  (dmem_addr),
        .wdata (dmem_wdata),
        .rdata (dmem_rdata)
    );

    // Random wait states. `pending`: a data access was sent and its instruction is now in WB.
    // While it is pending, each cycle a pseudo-random bit decides whether the data is late.
    // The RAM isn't enabled during a stall, so its output holds the right data.
    logic        random_stalls, pending;
    logic [15:0] lfsr;

    initial random_stalls = $test$plusargs("random_stalls");

    always_ff @(posedge clk) begin
        if (rst) begin
            pending <= 1'b0;
            lfsr    <= 16'hACE1;
        end else begin
            if (!dmem_stall) pending <= dmem_en;
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
        end
    end

    assign dmem_stall = random_stalls && pending && lfsr[0];
endmodule
