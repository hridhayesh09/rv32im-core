// Instruction decoder for RV32IM: turns a 32-bit instruction into register numbers,
// a sign-extended immediate and the control signals the later pipeline stages need.
// Purely combinational. An illegal instruction comes out with every side effect off
// (no register write, no memory access, no jump) and `illegal` set.
module decoder
    import rv_pkg::*;
(
    input  logic [31:0] instr,
    output logic [4:0]  rs1,
    output logic [4:0]  rs2,
    output logic [4:0]  rd,
    output logic [31:0] imm,
    output logic [2:0]  funct3,     // branch condition / load-store size, passed through
    output alu_op_t     alu_op,
    output src_a_t      src_a,
    output src_b_t      src_b,
    output wb_sel_t     wb_sel,
    output logic        reg_write,  // writes rd, and rd != x0
    output logic        mem_read,
    output logic        mem_write,
    output logic        branch,
    output logic        jal,
    output logic        jalr,
    output logic        muldiv,     // M extension: result comes from the multiply/divide unit
    output logic        fence_i,    // refetch everything after this instruction
    output logic        uses_rs1,   // rs1/rs2 are real operands (for hazard detection)
    output logic        uses_rs2,
    output logic        ecall,
    output logic        ebreak,
    output logic        illegal
);
    logic [6:0] opcode;
    logic [6:0] funct7;

    assign opcode = instr[6:0];
    assign funct3 = instr[14:12];
    assign funct7 = instr[31:25];
    assign rd     = instr[11:7];
    assign rs1    = instr[19:15];
    assign rs2    = instr[24:20];

    // The five immediate formats. Bit positions are chosen by the ISA so that the sign
    // bit is always instr[31] and register fields never move.
    logic [31:0] imm_i, imm_s, imm_b, imm_u, imm_j;
    assign imm_i = {{20{instr[31]}}, instr[31:20]};
    assign imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    assign imm_b = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
    assign imm_u = {instr[31:12], 12'b0};
    assign imm_j = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};

    // ALU operation for OP and OP-IMM, from funct3. instr[30] picks SRA over SRL;
    // SUB vs ADD is only for register-register OP and is handled below.
    alu_op_t arith_op;
    always_comb begin
        case (funct3)
            3'b000:  arith_op = ALU_ADD;
            3'b001:  arith_op = ALU_SLL;
            3'b010:  arith_op = ALU_SLT;
            3'b011:  arith_op = ALU_SLTU;
            3'b100:  arith_op = ALU_XOR;
            3'b101:  arith_op = instr[30] ? ALU_SRA : ALU_SRL;
            3'b110:  arith_op = ALU_OR;
            default: arith_op = ALU_AND;
        endcase
    end

    logic writes_rd;

    always_comb begin
        imm       = imm_i;
        alu_op    = ALU_ADD;
        src_a     = SRC_A_RS1;
        src_b     = SRC_B_IMM;
        wb_sel    = WB_ALU;
        writes_rd = 1'b0;
        mem_read  = 1'b0;
        mem_write = 1'b0;
        branch    = 1'b0;
        jal       = 1'b0;
        jalr      = 1'b0;
        muldiv    = 1'b0;
        fence_i   = 1'b0;
        uses_rs1  = 1'b0;
        uses_rs2  = 1'b0;
        ecall     = 1'b0;
        ebreak    = 1'b0;
        illegal   = 1'b0;

        case (opcode)
            OP_LUI: begin                       // rd = imm
                imm       = imm_u;
                src_a     = SRC_A_ZERO;
                writes_rd = 1'b1;
            end
            OP_AUIPC: begin                     // rd = pc + imm
                imm       = imm_u;
                src_a     = SRC_A_PC;
                writes_rd = 1'b1;
            end
            OP_JAL: begin                       // rd = pc + 4; pc = pc + imm
                imm       = imm_j;
                jal       = 1'b1;
                wb_sel    = WB_PC4;
                writes_rd = 1'b1;
            end
            OP_JALR: begin                      // rd = pc + 4; pc = (rs1 + imm) & ~1
                jalr      = 1'b1;
                wb_sel    = WB_PC4;
                writes_rd = 1'b1;
                uses_rs1  = 1'b1;
                illegal   = funct3 != 3'b000;
            end
            OP_BRANCH: begin                    // if (rs1 cmp rs2) pc = pc + imm
                imm       = imm_b;
                src_b     = SRC_B_RS2;
                branch    = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                illegal   = funct3 inside {3'b010, 3'b011};
            end
            OP_LOAD: begin                      // rd = mem[rs1 + imm]
                mem_read  = 1'b1;
                wb_sel    = WB_MEM;
                writes_rd = 1'b1;
                uses_rs1  = 1'b1;
                illegal   = !(funct3 inside {3'b000, 3'b001, 3'b010, 3'b100, 3'b101});
            end
            OP_STORE: begin                     // mem[rs1 + imm] = rs2
                imm       = imm_s;
                mem_write = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                illegal   = funct3 > 3'b010;
            end
            OP_IMM: begin                       // rd = rs1 op imm
                alu_op    = arith_op;
                writes_rd = 1'b1;
                uses_rs1  = 1'b1;
                if (funct3 == 3'b001)      illegal = funct7 != 7'b0000000;
                else if (funct3 == 3'b101) illegal = !(funct7 inside {7'b0000000, 7'b0100000});
            end
            OP_OP: begin                        // rd = rs1 op rs2
                alu_op    = (funct3 == 3'b000 && instr[30]) ? ALU_SUB : arith_op;
                src_b     = SRC_B_RS2;
                writes_rd = 1'b1;
                uses_rs1  = 1'b1;
                uses_rs2  = 1'b1;
                muldiv    = funct7 == 7'b0000001;   // MUL..REMU, any funct3
                illegal   = !(funct7 == 7'b0000000 || muldiv ||
                              (funct7 == 7'b0100000 && funct3 inside {3'b000, 3'b101}));
            end
            OP_MISC_MEM: begin
                // FENCE is a no-op on this in-order core. FENCE.I (Zifencei) makes stores to code
                // visible to fetch: the core refetches the instructions after it.
                fence_i   = funct3 == 3'b001;
                illegal   = !(funct3 inside {3'b000, 3'b001});
            end
            OP_SYSTEM: begin
                ecall     = instr == 32'h0000_0073;
                ebreak    = instr == 32'h0010_0073;
                illegal   = !(ecall || ebreak);
            end
            default: illegal = 1'b1;
        endcase

        if (illegal) begin
            writes_rd = 1'b0;
            mem_read  = 1'b0;
            mem_write = 1'b0;
            branch    = 1'b0;
            jal       = 1'b0;
            jalr      = 1'b0;
            muldiv    = 1'b0;
            fence_i   = 1'b0;
            uses_rs1  = 1'b0;
            uses_rs2  = 1'b0;
        end
    end

    assign reg_write = writes_rd && rd != 5'd0;
endmodule
