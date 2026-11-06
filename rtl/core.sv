// 5-stage in-order RV32I pipeline: IF -> ID -> EX -> MEM -> WB.
//
// - Both memories have a synchronous read (like FPGA block RAM). IF sends the PC to the
//   instruction memory and the instruction arrives in ID; MEM sends the address to the data
//   memory and the loaded data arrives in WB.
// - Branches and jumps are resolved in EX. The core always fetches PC+4 next ("predict not
//   taken"); when EX finds a taken branch or a jump, the two younger instructions in IF and ID
//   are flushed and fetch restarts at the target.
// - Every pipeline register has a valid bit. A flushed or empty slot is a bubble: valid = 0,
//   and nothing downstream acts on it.
// - The rvfi_* outputs describe each instruction as it retires from WB; the testbench compares
//   them against Spike.
module core
    import rv_pkg::*;
#(
    parameter logic [31:0] RESET_PC = 32'h8000_0000
) (
    input  logic        clk,
    input  logic        rst,

    output logic        imem_en,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,

    output logic        dmem_en,
    output logic [3:0]  dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,

    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc,
    output logic [31:0] rvfi_insn,
    output logic        rvfi_trap,      // illegal instruction, ECALL or EBREAK
    output logic [4:0]  rvfi_rd,        // 0 when nothing was written
    output logic [31:0] rvfi_rd_wdata,
    output logic        rvfi_mem_read,
    output logic [3:0]  rvfi_mem_wmask, // bytes written; 0 when not a store
    output logic [31:0] rvfi_mem_addr,
    output logic [31:0] rvfi_mem_wdata  // store data, at the store's width
);

    // ---------------------------------------------------------------- pipeline registers

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
    } if_id_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] rs1_val;
        logic [31:0] rs2_val;
        logic [31:0] imm;
        logic [4:0]  rs1;
        logic [4:0]  rs2;
        logic [4:0]  rd;
        logic [2:0]  funct3;
        alu_op_t     alu_op;
        src_a_t      src_a;
        src_b_t      src_b;
        wb_sel_t     wb_sel;
        logic        reg_write;
        logic        mem_read;
        logic        mem_write;
        logic        branch;
        logic        jal;
        logic        jalr;
        logic        trap;
    } id_ex_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] result;      // ALU result or PC+4; the address for loads and stores
        logic [31:0] store_data;
        logic [4:0]  rd;
        logic [2:0]  funct3;
        logic        reg_write;
        logic        mem_read;
        logic        mem_write;
        logic        trap;
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] result;
        logic [4:0]  rd;
        logic [2:0]  funct3;
        logic        reg_write;
        logic        mem_read;
        logic        trap;
        logic [3:0]  mem_wmask;
        logic [31:0] mem_wdata;
    } mem_wb_t;

    if_id_t  d;   // instruction in ID
    id_ex_t  e;   // instruction in EX
    ex_mem_t m;   // instruction in MEM
    mem_wb_t w;   // instruction in WB

    // Hazard control (set below).
    logic        redirect;      // EX: taken branch or jump
    logic [31:0] redirect_pc;
    logic        stall_f, stall_d, flush_d, flush_e;

    // ---------------------------------------------------------------- IF

    logic [31:0] pc_f;

    always_ff @(posedge clk) begin
        if (rst)           pc_f <= RESET_PC;
        else if (redirect) pc_f <= redirect_pc;
        else if (!stall_f) pc_f <= pc_f + 32'd4;
    end

    // The instruction memory's output register doubles as the IF/ID instruction register,
    // so it is frozen (en = 0) whenever ID is stalled.
    assign imem_addr = pc_f;
    assign imem_en   = !stall_d;

    always_ff @(posedge clk) begin
        if (rst || flush_d) d.valid <= 1'b0;
        else if (!stall_d)  d       <= '{valid: 1'b1, pc: pc_f};
    end

    // ---------------------------------------------------------------- ID

    logic [31:0] instr_d;
    assign instr_d = imem_rdata;

    logic [4:0]  rs1_d, rs2_d, rd_d;
    logic [31:0] imm_d, rs1_val_d, rs2_val_d;
    logic [2:0]  funct3_d;
    alu_op_t     alu_op_d;
    src_a_t      src_a_d;
    src_b_t      src_b_d;
    wb_sel_t     wb_sel_d;
    logic        reg_write_d, mem_read_d, mem_write_d, branch_d, jal_d, jalr_d;
    logic        uses_rs1_d, uses_rs2_d, ecall_d, ebreak_d, illegal_d;

    decoder u_decoder (
        .instr     (instr_d),
        .rs1       (rs1_d),
        .rs2       (rs2_d),
        .rd        (rd_d),
        .imm       (imm_d),
        .funct3    (funct3_d),
        .alu_op    (alu_op_d),
        .src_a     (src_a_d),
        .src_b     (src_b_d),
        .wb_sel    (wb_sel_d),
        .reg_write (reg_write_d),
        .mem_read  (mem_read_d),
        .mem_write (mem_write_d),
        .branch    (branch_d),
        .jal       (jal_d),
        .jalr      (jalr_d),
        .uses_rs1  (uses_rs1_d),
        .uses_rs2  (uses_rs2_d),
        .ecall     (ecall_d),
        .ebreak    (ebreak_d),
        .illegal   (illegal_d)
    );

    logic        wb_we;
    logic [31:0] wb_data;

    regfile u_regfile (
        .clk      (clk),
        .rs1_addr (rs1_d),
        .rs2_addr (rs2_d),
        .rs1_data (rs1_val_d),
        .rs2_data (rs2_val_d),
        .we       (wb_we),
        .rd_addr  (w.rd),
        .rd_data  (wb_data)
    );

    always_ff @(posedge clk) begin
        if (rst || flush_e || stall_d) begin
            e.valid <= 1'b0;   // bubble
        end else begin
            e <= '{
                valid:     d.valid,
                pc:        d.pc,
                instr:     instr_d,
                rs1_val:   rs1_val_d,
                rs2_val:   rs2_val_d,
                imm:       imm_d,
                rs1:       rs1_d,
                rs2:       rs2_d,
                rd:        rd_d,
                funct3:    funct3_d,
                alu_op:    alu_op_d,
                src_a:     src_a_d,
                src_b:     src_b_d,
                wb_sel:    wb_sel_d,
                reg_write: reg_write_d,
                mem_read:  mem_read_d,
                mem_write: mem_write_d,
                branch:    branch_d,
                jal:       jal_d,
                jalr:      jalr_d,
                trap:      illegal_d || ecall_d || ebreak_d
            };
        end
    end

    // ---------------------------------------------------------------- EX

    logic [31:0] rs1_e, rs2_e;   // operand values (forwarding is added in step 3)
    assign rs1_e = e.rs1_val;
    assign rs2_e = e.rs2_val;

    logic [31:0] alu_a, alu_b, alu_y;

    always_comb begin
        case (e.src_a)
            SRC_A_PC:   alu_a = e.pc;
            SRC_A_ZERO: alu_a = '0;
            default:    alu_a = rs1_e;
        endcase
        alu_b = (e.src_b == SRC_B_IMM) ? e.imm : rs2_e;
    end

    alu u_alu (.a(alu_a), .b(alu_b), .op(e.alu_op), .y(alu_y));

    function automatic logic branch_taken(input logic [2:0] f3, input logic [31:0] a, b);
        case (f3)
            3'b000:  return a == b;                       // BEQ
            3'b001:  return a != b;                       // BNE
            3'b100:  return $signed(a) <  $signed(b);     // BLT
            3'b101:  return $signed(a) >= $signed(b);     // BGE
            3'b110:  return a <  b;                       // BLTU
            3'b111:  return a >= b;                       // BGEU
            default: return 1'b0;
        endcase
    endfunction

    logic [31:0] target_e;
    assign target_e    = ((e.jalr ? rs1_e : e.pc) + e.imm) & ~32'(e.jalr);  // JALR clears bit 0
    assign redirect    = e.valid && (e.jal || e.jalr || (e.branch && branch_taken(e.funct3, rs1_e, rs2_e)));
    assign redirect_pc = target_e;

    always_ff @(posedge clk) begin
        if (rst) begin
            m.valid <= 1'b0;
        end else begin
            m <= '{
                valid:      e.valid,
                pc:         e.pc,
                instr:      e.instr,
                result:     (e.wb_sel == WB_PC4) ? e.pc + 32'd4 : alu_y,
                store_data: rs2_e,
                rd:         e.rd,
                funct3:     e.funct3,
                reg_write:  e.reg_write,
                mem_read:   e.mem_read,
                mem_write:  e.mem_write,
                trap:       e.trap
            };
        end
    end

    // ---------------------------------------------------------------- MEM

    // Stores: line the data up with the addressed byte lanes. Byte stores repeat the byte in
    // every lane and halfword stores repeat the halfword; the write mask picks the lanes.
    logic [3:0]  store_mask;
    logic [31:0] store_wdata, store_value;

    always_comb begin
        case (m.funct3[1:0])
            2'b00: begin
                store_mask  = 4'b0001 << m.result[1:0];
                store_wdata = {4{m.store_data[7:0]}};
                store_value = {24'b0, m.store_data[7:0]};
            end
            2'b01: begin
                store_mask  = 4'b0011 << m.result[1:0];
                store_wdata = {2{m.store_data[15:0]}};
                store_value = {16'b0, m.store_data[15:0]};
            end
            default: begin
                store_mask  = 4'b1111;
                store_wdata = m.store_data;
                store_value = m.store_data;
            end
        endcase
    end

    logic store_m;
    assign store_m    = m.valid && m.mem_write;
    assign dmem_addr  = m.result;
    assign dmem_en    = m.valid && (m.mem_read || m.mem_write);
    assign dmem_we    = store_m ? store_mask : 4'b0000;
    assign dmem_wdata = store_wdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            w.valid <= 1'b0;
        end else begin
            w <= '{
                valid:     m.valid,
                pc:        m.pc,
                instr:     m.instr,
                result:    m.result,
                rd:        m.rd,
                funct3:    m.funct3,
                reg_write: m.reg_write,
                mem_read:  m.mem_read,
                trap:      m.trap,
                mem_wmask: store_m ? store_mask : 4'b0000,
                mem_wdata: store_m ? store_value : '0
            };
        end
    end

    // ---------------------------------------------------------------- WB

    // Loads: pick the addressed byte/halfword out of the word and sign- or zero-extend it.
    function automatic logic [31:0] load_extend(input logic [2:0] f3, input logic [1:0] offset,
                                                input logic [31:0] word);
        logic [31:0] shifted;
        shifted = word >> {offset, 3'b000};
        case (f3)
            3'b000:  return {{24{shifted[7]}}, shifted[7:0]};     // LB
            3'b001:  return {{16{shifted[15]}}, shifted[15:0]};   // LH
            3'b100:  return {24'b0, shifted[7:0]};                // LBU
            3'b101:  return {16'b0, shifted[15:0]};               // LHU
            default: return word;                                 // LW
        endcase
    endfunction

    assign wb_data = w.mem_read ? load_extend(w.funct3, w.result[1:0], dmem_rdata) : w.result;
    assign wb_we   = w.valid && w.reg_write;

    // ---------------------------------------------------------------- hazard control

    assign stall_f = 1'b0;
    assign stall_d = 1'b0;
    assign flush_d = redirect;   // the instruction being fetched is on the wrong path
    assign flush_e = redirect;   // so is the one in ID

    // ---------------------------------------------------------------- retire trace

    assign rvfi_valid     = w.valid;
    assign rvfi_pc        = w.pc;
    assign rvfi_insn      = w.instr;
    assign rvfi_trap      = w.trap;
    assign rvfi_rd        = wb_we ? w.rd : 5'd0;
    assign rvfi_rd_wdata  = wb_we ? wb_data : '0;
    assign rvfi_mem_read  = w.valid && w.mem_read;
    assign rvfi_mem_wmask = w.valid ? w.mem_wmask : 4'b0000;
    assign rvfi_mem_addr  = w.result;
    assign rvfi_mem_wdata = w.mem_wdata;

endmodule
