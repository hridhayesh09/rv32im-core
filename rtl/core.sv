// 5-stage in-order RV32IM pipeline: IF -> ID -> EX -> MEM -> WB.
//
// - Both memories have a synchronous read (like FPGA block RAM). IF sends the PC to the
//   instruction memory and the instruction arrives in ID. EX sends a load or store to the data
//   memory (the address straight from the ALU); the data arrives in MEM, where it's aligned and
//   registered, so WB only ever forwards registered values.
// - Branches and jumps are resolved in EX. IF asks the branch predictor (bpred.sv) where to
//   fetch next; the guess travels down with the instruction, and when EX finds it was wrong,
//   the two younger instructions in IF and ID are flushed and fetch restarts at the right PC.
//   With BP_MODE = 0 the core always fetches PC+4 ("predict not taken").
// - Multiply and divide run in a multi-cycle unit; EX holds the instruction until it's done.
// - Every pipeline register has a valid bit. A flushed or empty slot is a bubble: valid = 0,
//   and nothing downstream acts on it.
// - The rvfi_* outputs describe each instruction as it retires from WB; the testbench compares
//   them against Spike.
// - Data accesses may take extra cycles (bus devices, caches, SDRAM). While the instruction in MEM
//   is still waiting for its data (dmem_stall), the whole pipeline freezes.
// - Exceptions (illegal instruction, ECALL, EBREAK, misaligned load/store/jump) are taken in EX:
//   the instruction becomes a bubble, the younger ones are flushed, and fetch restarts at mtvec.
//   Older instructions (in MEM and WB) finish normally, so exceptions are precise.
module core
    import rv_pkg::*;
#(
    parameter logic [31:0] RESET_PC = 32'h8000_0000,
    parameter int BP_MODE   = 2,   // branch predictor: 0 none, 1 BTB + bimodal, 2 BTB + gshare
    parameter int BTB_BITS  = 5,   // 32-entry BTB
    parameter int BHT_BITS  = 8,   // 256 2-bit counters, 8 bits of global history
    parameter int RAS_DEPTH = 4    // return-address stack entries (0: none)
) (
    input  logic        clk,
    input  logic        rst,

    output logic        imem_en,
    output logic [31:0] imem_addr,
    input  logic [31:0] imem_rdata,
    input  logic        imem_stall,     // the instruction for ID isn't there yet (I-cache miss)
    output logic        fetch_valid,    // the instruction for ID is still wanted (not flushed)

    output logic        dmem_en,
    output logic [3:0]  dmem_we,
    output logic [31:0] dmem_addr,
    output logic [31:0] dmem_wdata,
    input  logic [31:0] dmem_rdata,
    input  logic        dmem_stall,     // the access of the instruction in MEM isn't done yet
    output logic        cache_flush,    // FENCE.I: write back the D-cache, invalidate the I-cache
    input  logic [3:0]  mem_events,     // from the memory system, counted by mhpmcounter8-11:
                                        // I-cache access, I-cache miss, D-cache access, D-cache miss

    output logic        rvfi_valid,
    output logic [31:0] rvfi_pc,
    output logic [31:0] rvfi_insn,
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
        logic        pred_taken;  // the branch predictor's guess, checked in EX
        logic [31:0] pred_target;
        logic        pred_branch;
        logic [BHT_BITS-1:0] pred_idx;
        logic [1:0]  pred_ctr;
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
        logic        is_muldiv;   // (not "muldiv": Quartus confuses it with the module name)
        logic        fence_i;
        logic        is_csr;
        logic        mret;
        logic        ecall;
        logic        ebreak;
        logic        illegal;
        logic        pred_taken;  // the branch predictor's guess, checked in EX
        logic [31:0] pred_target;
        logic        pred_branch;
        logic [BHT_BITS-1:0] pred_idx;
        logic [1:0]  pred_ctr;
    } id_ex_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] result;      // ALU result, PC+4, CSR or mul/div; the address for loads/stores
        logic [4:0]  rd;
        logic [2:0]  funct3;
        logic        reg_write;
        logic        mem_read;
        logic [3:0]  mem_wmask;   // for the retire trace: bytes stored
        logic [31:0] mem_wdata;   //   and the value, at the store's width
    } ex_mem_t;

    typedef struct packed {
        logic        valid;
        logic [31:0] pc;
        logic [31:0] instr;
        logic [31:0] result;      // the value to write back (loads: the loaded value)
        logic [4:0]  rd;
        logic        reg_write;
        logic        mem_read;
        logic [31:0] mem_addr;
        logic [3:0]  mem_wmask;
        logic [31:0] mem_wdata;
    } mem_wb_t;

    if_id_t  d;   // instruction in ID
    id_ex_t  e;   // instruction in EX
    ex_mem_t m;   // instruction in MEM
    mem_wb_t w;   // instruction in WB

    // Hazard control (set below).
    logic        redirect;      // EX: mispredicted branch or jump, exception, MRET, FENCE.I
    logic [31:0] redirect_pc;
    logic        stall_f, stall_d, stall_e, flush_d, flush_e, load_use;
    logic        freeze;        // everything holds: waiting for memory (a data access in MEM,
                                // or the instruction for ID)
    assign freeze = dmem_stall || imem_stall;

    // ---------------------------------------------------------------- IF

    logic [31:0] pc_f;
    logic        pred_taken_f, pred_branch_f;
    logic [31:0] pred_target_f;
    logic [BHT_BITS-1:0] pred_idx_f;
    logic [1:0]  pred_ctr_f;

    always_ff @(posedge clk) begin
        if (rst)           pc_f <= RESET_PC;
        else if (freeze)   ;  // hold
        else if (redirect) pc_f <= redirect_pc;
        else if (!stall_f) pc_f <= pred_taken_f ? pred_target_f : pc_f + 32'd4;
    end

    // Set in EX (below): the instruction leaving EX, for the predictor's tables.
    logic        bp_upd_valid, bp_upd_cf, bp_upd_taken, bp_upd_branch;
    logic [1:0]  bp_upd_kind;
    logic [31:0] bp_upd_target;

    bpred #(.MODE(BP_MODE), .BTB_BITS(BTB_BITS), .BHT_BITS(BHT_BITS), .RAS_DEPTH(RAS_DEPTH)) u_bpred (
        .clk, .rst,
        .pc          (pc_f),
        .advance     (!freeze && !stall_f && !redirect),
        .pred_taken  (pred_taken_f),
        .pred_target (pred_target_f),
        .pred_branch (pred_branch_f),
        .pred_idx    (pred_idx_f),
        .pred_ctr    (pred_ctr_f),
        .upd_valid   (bp_upd_valid),
        .upd_pc      (e.pc),
        .upd_kind    (bp_upd_kind),
        .upd_cf      (bp_upd_cf),
        .upd_taken   (bp_upd_taken),
        .upd_target  (bp_upd_target),
        .upd_branch  (bp_upd_branch),
        .upd_idx     (e.pred_idx),
        .upd_ctr     (e.pred_ctr),
        .recover     (redirect && !freeze)
    );

    // The instruction memory's output register doubles as the IF/ID instruction register,
    // so it is frozen (en = 0) whenever ID is stalled.
    assign imem_addr = pc_f;
    assign imem_en   = !stall_d && !freeze;
    assign fetch_valid = d.valid;

    always_ff @(posedge clk) begin
        if (rst)            d.valid <= 1'b0;
        else if (freeze)    ;  // hold
        else if (flush_d)   d.valid <= 1'b0;
        else if (!stall_d)  d       <= '{valid: 1'b1, pc: pc_f, pred_taken: pred_taken_f,
                                         pred_target: pred_target_f, pred_branch: pred_branch_f,
                                         pred_idx: pred_idx_f, pred_ctr: pred_ctr_f};
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
    logic        reg_write_d, mem_read_d, mem_write_d, branch_d, jal_d, jalr_d, muldiv_d, fence_i_d;
    logic        uses_rs1_d, uses_rs2_d, ecall_d, ebreak_d, mret_d, csr_d, illegal_d;

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
        .muldiv    (muldiv_d),
        .fence_i   (fence_i_d),
        .uses_rs1  (uses_rs1_d),
        .uses_rs2  (uses_rs2_d),
        .ecall     (ecall_d),
        .ebreak    (ebreak_d),
        .mret      (mret_d),
        .csr       (csr_d),
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
        if (rst) begin
            e.valid <= 1'b0;
        end else if (freeze) begin
            // hold
        end else if (flush_e) begin
            e.valid <= 1'b0;
        end else if (stall_e) begin
            // hold: a multiply/divide is still running
        end else if (stall_d) begin
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
                is_muldiv: muldiv_d,
                fence_i:   fence_i_d,
                is_csr:    csr_d,
                mret:      mret_d,
                ecall:     ecall_d,
                ebreak:    ebreak_d,
                illegal:   illegal_d,
                pred_taken:  d.pred_taken,
                pred_target: d.pred_target,
                pred_branch: d.pred_branch,
                pred_idx:    d.pred_idx,
                pred_ctr:    d.pred_ctr
            };
        end
    end

    // ---------------------------------------------------------------- EX

    // Forwarding: an operand read in ID may be stale because an older instruction that writes
    // it is still in MEM or WB. Take the newest value instead: MEM first (the instruction just
    // ahead), then WB. A load in MEM has no data yet; the load-use stall keeps a dependent
    // instruction out of EX until the load reaches WB. Three instructions back is covered by the
    // register file's write-before-read.
    function automatic logic [31:0] forward(input logic [4:0] rs, input logic [31:0] id_value);
        if (m.valid && m.reg_write && !m.mem_read && m.rd == rs) return m.result;
        else if (w.valid && w.reg_write && w.rd == rs)          return wb_data;
        else                                                    return id_value;
    endfunction

    logic [31:0] rs1_e, rs2_e;
    assign rs1_e = forward(e.rs1, e.rs1_val);
    assign rs2_e = forward(e.rs2, e.rs2_val);

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

    // Multiply/divide: start the unit when an M instruction reaches EX; hold it there until done.
    logic        md_done;
    logic [31:0] md_result;

    muldiv u_muldiv (
        .clk    (clk),
        .rst    (rst),
        .start  (e.valid && e.is_muldiv && !md_done && !freeze),
        .hold   (freeze),
        .op     (e.funct3),
        .a      (rs1_e),
        .b      (rs2_e),
        .done   (md_done),
        .result (md_result)
    );

    assign stall_e = e.valid && e.is_muldiv && !md_done;

    logic [31:0] target_e;
    logic        jump_e;
    assign target_e = ((e.jalr ? rs1_e : e.pc) + e.imm) & {31'h7fff_ffff, !e.jalr};  // JALR clears bit 0
    assign jump_e   = e.jal || e.jalr || (e.branch && branch_taken(e.funct3, rs1_e, rs2_e));

    // The fetch after this instruction went to the wrong place: the guess was taken/not taken
    // the wrong way, or the taken target was wrong (e.g. a JALR to a new address).
    //
    // "target == guess" is checked without waiting for the target adder's carry chain:
    // a + b == c exactly when the carry into each bit implied by c (a ^ b ^ c) matches the carry
    // out of the bit below, assuming that bit's sum was right ((a & b) | ((a | b) & ~c)).
    // Only bits 31:2 are compared (the guess's low bits are taken from a 2-bit add): a target
    // with bit 1 set traps (misaligned), so it is redirected anyway; JALR's cleared bit 0 is
    // below that too.
    function automatic logic sum_equals(input logic [31:0] a, b, c);
        logic [31:0] carry_out;
        carry_out = (a & b) | ((a | b) & ~c);
        return (a ^ b ^ c) == {carry_out[30:0], 1'b0};
    endfunction

    logic [31:0] target_base;
    logic [1:0]  target_low;
    logic        target_ok;
    assign target_base = e.jalr ? rs1_e : e.pc;
    assign target_low  = target_base[1:0] + e.imm[1:0];
    assign target_ok   = sum_equals(target_base, e.imm, {e.pred_target[31:2], target_low});

    logic mispredict;
    assign mispredict = (e.pred_taken != jump_e) || (jump_e && !target_ok);

    // ---- exceptions, CSRs, MRET
    // The instruction in EX executes (and moves on) this cycle unless the pipeline is frozen or a
    // multiply/divide is still running.
    logic        ex_fire, csr_illegal, mem_misaligned, jump_misaligned, exception;
    logic [31:0] csr_rdata, mtvec, mepc, cause, tval;
    assign ex_fire = e.valid && !freeze && !stall_e;

    // alu_y is the address for loads and stores.
    assign mem_misaligned  = (e.mem_read || e.mem_write) &&
                             ((e.funct3[1:0] == 2'b01 && alu_y[0]) ||
                              (e.funct3[1:0] == 2'b10 && alu_y[1:0] != 2'b00));
    assign jump_misaligned = jump_e && target_e[1];   // no compressed instructions: 4-byte aligned
    assign exception = e.valid && (e.illegal || e.ecall || e.ebreak || (e.is_csr && csr_illegal) ||
                                   mem_misaligned || jump_misaligned);

    always_comb begin
        if (e.illegal || (e.is_csr && csr_illegal)) begin
            cause = 32'd2;  tval = e.instr;       // illegal instruction
        end else if (e.ebreak) begin
            cause = 32'd3;  tval = e.pc;          // breakpoint
        end else if (e.ecall) begin
            cause = 32'd11; tval = '0;            // environment call from M-mode
        end else if (jump_misaligned) begin
            cause = 32'd0;  tval = target_e;      // instruction address misaligned
        end else if (e.mem_write) begin
            cause = 32'd6;  tval = alu_y;         // store address misaligned
        end else begin
            cause = 32'd4;  tval = alu_y;         // load address misaligned
        end
    end

    csr u_csr (
        .clk, .rst,
        .op_fire     (ex_fire && e.is_csr),
        .op          (e.funct3),
        .addr        (e.imm[11:0]),
        .src         (e.funct3[2] ? {27'b0, e.rs1} : rs1_e),
        .src_zero    (e.rs1 == 5'd0),
        .rdata       (csr_rdata),
        .illegal     (csr_illegal),
        .trap        (ex_fire && exception),
        .trap_pc     (e.pc),
        .trap_cause  (cause),
        .trap_tval   (tval),
        .mret_fire   (ex_fire && e.mret),
        .mtvec_out   (mtvec),
        .mepc_out    (mepc),
        .retire      (w.valid && !freeze),
        .mem_pending (m.valid),
        .wb_pending  (w.valid),
        .events      ({mem_events,                              // 8-11: caches
                        freeze,                                  // 7: memory wait cycles
                        stall_e && !freeze,                      // 6: mul/div wait cycles
                        load_use && !freeze,                     // 5: load-use stall cycles
                        ex_fire && !exception && mispredict,     // 4: mispredicts
                        ex_fire && !exception && (e.branch || e.jal || e.jalr)})  // 3: branches
    );

    // FENCE.I redirects to the next instruction: the 2 younger instructions, fetched before an
    // older store to code finished, are flushed and fetched again.
    // (Not while a multiply/divide is still running: it stays in EX, so it isn't flushed.)
    assign redirect    = e.valid && !stall_e && (exception || e.mret || e.fence_i || mispredict);
    assign cache_flush = ex_fire && e.fence_i && !exception;
    assign redirect_pc = exception ? mtvec : e.mret ? mepc :
                         (jump_e && !e.fence_i) ? target_e : e.pc + 32'd4;

    // Predictor update. Calls and returns follow the RISC-V convention: a jump that links into
    // ra or t0 (x1/x5) is a call; a JALR from ra/t0 that doesn't link is a return.
    function automatic logic is_link(input logic [4:0] r);
        return r == 5'd1 || r == 5'd5;
    endfunction

    assign bp_upd_valid  = ex_fire && !exception && (bp_upd_cf || e.pred_taken);
    assign bp_upd_cf     = e.branch || e.jal || e.jalr;
    assign bp_upd_taken  = jump_e;
    assign bp_upd_target = target_e;
    assign bp_upd_branch = e.pred_branch;
    assign bp_upd_kind   = e.branch                                ? 2'd0 :   // branch
                           ((e.jal || e.jalr) && is_link(e.rd))    ? 2'd2 :   // call
                           (e.jalr && is_link(e.rs1))              ? 2'd3 :   // return
                                                                     2'd1;    // other jump

    // ---- data memory request (sent from EX; the data comes back while the instruction is in MEM)
    // Stores: line the data up with the addressed byte lanes. Byte stores repeat the byte in
    // every lane and halfword stores repeat the halfword; the write mask picks the lanes.
    logic [3:0]  store_mask;
    logic [31:0] store_wdata, store_value;

    always_comb begin
        case (e.funct3[1:0])
            2'b00: begin
                store_mask  = 4'b0001 << alu_y[1:0];
                store_wdata = {4{rs2_e[7:0]}};
                store_value = {24'b0, rs2_e[7:0]};
            end
            2'b01: begin
                store_mask  = 4'b0011 << alu_y[1:0];
                store_wdata = {2{rs2_e[15:0]}};
                store_value = {16'b0, rs2_e[15:0]};
            end
            default: begin
                store_mask  = 4'b1111;
                store_wdata = rs2_e;
                store_value = rs2_e;
            end
        endcase
    end

    // A request goes out only in the cycle the instruction leaves EX (not while frozen), so a
    // store is never issued twice, and never for an instruction that traps.
    logic mem_fire;
    assign mem_fire   = ex_fire && !exception && (e.mem_read || e.mem_write);
    assign dmem_en    = mem_fire;
    assign dmem_addr  = alu_y;
    assign dmem_we    = (mem_fire && e.mem_write) ? store_mask : 4'b0000;
    assign dmem_wdata = store_wdata;

    always_ff @(posedge clk) begin
        if (rst) begin
            m.valid <= 1'b0;
        end else if (freeze) begin
            // hold
        end else if (stall_e) begin
            m.valid <= 1'b0;   // bubble while EX is busy
        end else begin
            m <= '{
                valid:      e.valid && !exception,   // a trapping instruction doesn't continue
                pc:         e.pc,
                instr:      e.instr,
                result:     e.is_muldiv ? md_result : e.is_csr ? csr_rdata :
                            (e.wb_sel == WB_PC4) ? e.pc + 32'd4 : alu_y,
                rd:         e.rd,
                funct3:     e.funct3,
                reg_write:  e.reg_write,
                mem_read:   e.mem_read,
                mem_wmask:  e.mem_write ? store_mask : 4'b0000,
                mem_wdata:  e.mem_write ? store_value : '0
            };
        end
    end

    // ---------------------------------------------------------------- MEM

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

    // The data for a load sent from EX last cycle arrives now (once dmem_stall is low).
    logic [31:0] mem_result;
    assign mem_result = m.mem_read ? load_extend(m.funct3, m.result[1:0], dmem_rdata) : m.result;

    always_ff @(posedge clk) begin
        if (rst) begin
            w.valid <= 1'b0;
        end else if (freeze) begin
            // hold
        end else begin
            w <= '{
                valid:     m.valid,
                pc:        m.pc,
                instr:     m.instr,
                result:    mem_result,
                rd:        m.rd,
                reg_write: m.reg_write,
                mem_read:  m.mem_read,
                mem_addr:  m.result,
                mem_wmask: m.mem_wmask,
                mem_wdata: m.mem_wdata
            };
        end
    end

    // ---------------------------------------------------------------- WB

    assign wb_data = w.result;   // a register: loads were aligned in MEM
    assign wb_we   = w.valid && w.reg_write && !freeze;

    // ---------------------------------------------------------------- hazard control

    // Load-use: the instruction in ID needs the result of a load that is in EX. The data only
    // arrives (late) in MEM and is usable from WB, so hold IF and ID for one cycle and put a
    // bubble into EX.
    // After that cycle the load is in MEM; when the consumer then moves into EX, the load is in
    // WB and forwarding supplies the value.
    assign load_use = e.valid && e.mem_read && e.reg_write && d.valid &&
                      ((uses_rs1_d && rs1_d == e.rd) || (uses_rs2_d && rs2_d == e.rd));

    assign stall_f = load_use || stall_e;
    assign stall_d = load_use || stall_e;
    assign flush_d = redirect;   // the instruction being fetched is on the wrong path
    assign flush_e = redirect;   // so is the one in ID

    // ---------------------------------------------------------------- retire trace

    assign rvfi_valid     = w.valid && !freeze;
    assign rvfi_pc        = w.pc;
    assign rvfi_insn      = w.instr;
    assign rvfi_rd        = wb_we ? w.rd : 5'd0;
    assign rvfi_rd_wdata  = wb_we ? wb_data : '0;
    assign rvfi_mem_read  = w.valid && w.mem_read;
    assign rvfi_mem_wmask = w.valid ? w.mem_wmask : 4'b0000;
    assign rvfi_mem_addr  = w.mem_addr;
    assign rvfi_mem_wdata = w.mem_wdata;

endmodule
