// Dual-port RAM, the shape of an FPGA block RAM in true dual-port mode (MAX 10 M9K):
//   port A: read only (instruction fetch)
//   port B: read/write with byte enables (data)
// Both ports read synchronously: data appears the cycle after the address. Code and data share
// one array, so a store through port B is visible to fetch through port A (FENCE.I works).
module dpram #(
    parameter int    WORDS        = 16384,  // 64 KB
    parameter string INIT_FILE    = "",     // synthesis/simulation: hex file loaded at start
    parameter string INIT_PLUSARG = ""      // simulation: hex file named by +<arg>=<path>
) (
    input  logic        clk,

    input  logic        a_en,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] a_addr,     // byte addresses; only the word index bits are used
    input  logic [31:0] b_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] a_rdata,

    input  logic        b_en,
    input  logic [3:0]  b_we,
    input  logic [31:0] b_wdata,
    output logic [31:0] b_rdata
);
    localparam int AW = $clog2(WORDS);

    logic [31:0] mem [WORDS];

    always_ff @(posedge clk) begin
        if (a_en) a_rdata <= mem[a_addr[AW+1:2]];
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            for (int i = 0; i < 4; i++) begin
                if (b_we[i]) mem[b_addr[AW+1:2]][8*i +: 8] <= b_wdata[8*i +: 8];
            end
            b_rdata <= mem[b_addr[AW+1:2]];
        end
    end

    initial begin
        string path;
        if (INIT_FILE != "") $readmemh(INIT_FILE, mem);
        if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, path)) begin
            $readmemh(path, mem);
        end
    end
endmodule
