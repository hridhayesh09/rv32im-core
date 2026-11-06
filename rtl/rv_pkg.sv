// Shared definitions for the RV32IM core: opcodes and the control-signal encodings
// the decoder produces. tests/unit/rv_defs.py mirrors these values for the testbenches.
package rv_pkg;

    // Major opcodes (instr[6:0]) used by RV32I.
    localparam logic [6:0] OP_LUI      = 7'b0110111;
    localparam logic [6:0] OP_AUIPC    = 7'b0010111;
    localparam logic [6:0] OP_JAL      = 7'b1101111;
    localparam logic [6:0] OP_JALR     = 7'b1100111;
    localparam logic [6:0] OP_BRANCH   = 7'b1100011;
    localparam logic [6:0] OP_LOAD     = 7'b0000011;
    localparam logic [6:0] OP_STORE    = 7'b0100011;
    localparam logic [6:0] OP_IMM      = 7'b0010011;
    localparam logic [6:0] OP_OP       = 7'b0110011;
    localparam logic [6:0] OP_MISC_MEM = 7'b0001111;
    localparam logic [6:0] OP_SYSTEM   = 7'b1110011;

    typedef enum logic [3:0] {
        ALU_ADD  = 4'd0,
        ALU_SUB  = 4'd1,
        ALU_SLL  = 4'd2,
        ALU_SLT  = 4'd3,
        ALU_SLTU = 4'd4,
        ALU_XOR  = 4'd5,
        ALU_SRL  = 4'd6,
        ALU_SRA  = 4'd7,
        ALU_OR   = 4'd8,
        ALU_AND  = 4'd9
    } alu_op_t;

    // ALU operand A: rs1, the instruction's PC (AUIPC), or zero (LUI).
    typedef enum logic [1:0] {
        SRC_A_RS1  = 2'd0,
        SRC_A_PC   = 2'd1,
        SRC_A_ZERO = 2'd2
    } src_a_t;

    // ALU operand B: rs2 or the immediate.
    typedef enum logic {
        SRC_B_RS2 = 1'b0,
        SRC_B_IMM = 1'b1
    } src_b_t;

    // What gets written back to rd: the ALU result, loaded data, or PC+4 (JAL/JALR).
    typedef enum logic [1:0] {
        WB_ALU = 2'd0,
        WB_MEM = 2'd1,
        WB_PC4 = 2'd2
    } wb_sel_t;

endpackage
