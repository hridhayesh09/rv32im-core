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

    // Reads are written out per port (not through a shared function): Quartus didn't treat a
    // memory read inside a function as a use of the memory and removed the registers.
    always_comb begin
        if (rs1_addr == 5'd0)                rs1_data = '0;
        else if (we && rd_addr == rs1_addr)  rs1_data = rd_data;
        else                                 rs1_data = regs[rs1_addr];
    end

    always_comb begin
        if (rs2_addr == 5'd0)                rs2_data = '0;
        else if (we && rd_addr == rs2_addr)  rs2_data = rd_data;
        else                                 rs2_data = regs[rs2_addr];
    end
endmodule
