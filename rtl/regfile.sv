// 32 x 32-bit register file: two combinational read ports, one write port.
// x0 always reads as zero. A read of the register being written in the same cycle
// returns the new value (write-before-read), so WB never needs a forwarding path to ID.
// Registers have no reset, like real RISC-V cores; software initializes what it uses.
module regfile (
    input  logic        clk,
    input  logic [4:0]  rs1_addr,
    input  logic [4:0]  rs2_addr,
    output logic [31:0] rs1_data,
    output logic [31:0] rs2_data,
    input  logic        we,
    input  logic [4:0]  rd_addr,
    input  logic [31:0] rd_data
);
    logic [31:0] regs [32];

    always_ff @(posedge clk) begin
        if (we && rd_addr != 5'd0) regs[rd_addr] <= rd_data;
    end

    function automatic logic [31:0] read(input logic [4:0] addr);
        if (addr == 5'd0)               return '0;
        else if (we && rd_addr == addr) return rd_data;
        else                            return regs[addr];
    endfunction

    assign rs1_data = read(rs1_addr);
    assign rs2_data = read(rs2_addr);
endmodule
