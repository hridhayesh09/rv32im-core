// Single-port RAM with synchronous read and byte write enables: the shape of an FPGA block RAM
// (MAX 10 M9K). The read data appears the cycle after the address. A read and a write to the
// same word in one cycle returns the old value.
module ram #(
    parameter int    WORDS        = 16384,  // 64 KB
    parameter string INIT_PLUSARG = ""      // simulation: load a hex file named by +<arg>=<path>
) (
    input  logic        clk,
    input  logic        en,
    input  logic [3:0]  we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] addr,   // byte address; only the word index bits are used
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wdata,
    output logic [31:0] rdata
);
    localparam int AW = $clog2(WORDS);

    logic [31:0] mem [WORDS];
    logic [AW-1:0] idx;
    assign idx = addr[AW+1:2];

    always_ff @(posedge clk) begin
        if (en) begin
            for (int i = 0; i < 4; i++) begin
                if (we[i]) mem[idx][8*i +: 8] <= wdata[8*i +: 8];
            end
            rdata <= mem[idx];
        end
    end

    initial begin
        string path;
        if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, path)) begin
            $readmemh(path, mem);
        end
    end
endmodule
