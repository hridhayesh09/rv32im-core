// Branch predictor, looked up in IF with the PC being fetched.
//
// - BTB (branch target buffer): a direct-mapped table, indexed by PC, of control-flow
//   instructions that were taken: their target and their kind (branch, jump, call, return).
//   A BTB hit is the only way the predictor knows, before decode, that the PC holds a branch.
// - BHT: 2-bit saturating counters for conditional branches (>= 2 means "taken").
//   MODE 1 (bimodal) indexes them with the PC; MODE 2 (gshare) with PC XOR global history
//   (the directions of the last BHT_BITS predicted branches).
// - RAS (return-address stack): a call pushes PC+4, a return pops it as its target.
//
// History and stack are updated speculatively in IF (so back-to-back branches and calls see
// each other), and again, non-speculatively, when the instruction leaves EX. When EX redirects
// fetch (mispredict, exception, ...), the speculative copies are restored from the committed
// ones. Predictions only change timing: EX checks every one.
module bpred #(
    parameter int MODE      = 2,    // 0: none (always PC+4), 1: BTB + bimodal, 2: BTB + gshare
    parameter int BTB_BITS  = 5,    // 2**BTB_BITS BTB entries
    parameter int BHT_BITS  = 8,    // 2**BHT_BITS counters; also the gshare history length
    parameter int RAS_DEPTH = 4     // 0: no return-address stack
) (
    input  logic                clk,
    input  logic                rst,

    // IF
    input  logic [31:0]         pc,
    input  logic                advance,      // the fetch at pc moves on to ID this cycle
    output logic                pred_taken,
    output logic [31:0]         pred_target,
    output logic                pred_branch,  // a BTB hit on a conditional branch (it is in the history)
    output logic [BHT_BITS-1:0] pred_idx,     // the counter used, and its value, for the update
    output logic [1:0]          pred_ctr,

    // EX (once per instruction, when it leaves EX without trapping)
    input  logic                upd_valid,    // a control-flow instruction, or one predicted taken
    input  logic [31:0]         upd_pc,
    input  logic [1:0]          upd_kind,     // K_* below; ignored when !upd_cf
    input  logic                upd_cf,       // it really is a branch or jump
    input  logic                upd_taken,
    input  logic [31:0]         upd_target,
    input  logic                upd_branch,   // its pred_branch
    input  logic [BHT_BITS-1:0] upd_idx,
    input  logic [1:0]          upd_ctr,
    input  logic                recover       // EX redirects fetch this cycle
);

    localparam logic [1:0] K_BRANCH = 2'd0, K_CALL = 2'd2, K_RET = 2'd3;   // 1: other jump
    localparam int BTB_N = 1 << BTB_BITS;
    localparam int BHT_N = 1 << BHT_BITS;
    localparam int TAG_W = 30 - BTB_BITS;
    localparam int RAS_N = (RAS_DEPTH > 0) ? RAS_DEPTH : 1;
    localparam int RAS_W = (RAS_N > 1) ? $clog2(RAS_N) : 1;
    localparam logic [31:0]      RAS_N32  = RAS_N;
    localparam logic [31:0]      RAS_M32  = RAS_N - 1;
    localparam logic [RAS_W-1:0] RAS_LAST = RAS_M32[RAS_W-1:0];   // highest stack index
    localparam logic [RAS_W:0]   RAS_FULL = RAS_N32[RAS_W:0];     // entry count when full

    // ---- tables
    logic               btb_valid  [BTB_N];
    logic [TAG_W-1:0]   btb_tag    [BTB_N];
    logic [29:0]        btb_target [BTB_N];
    logic [1:0]         btb_kind   [BTB_N];
    logic [1:0]         bht        [BHT_N];

    // ---- speculative (s_) and committed (c_) global history and return stack
    logic [BHT_BITS-1:0] s_ghr, c_ghr, c_ghr_n;
    logic [29:0]         s_ras [RAS_N];
    logic [29:0]         c_ras [RAS_N];
    logic [29:0]         c_ras_n [RAS_N];
    logic [RAS_W-1:0]    s_top, c_top, c_top_n;     // index of the top entry
    logic [RAS_W:0]      s_cnt, c_cnt, c_cnt_n;     // entries in use (saturates at RAS_N)

    function automatic logic [RAS_W-1:0] ras_inc(input logic [RAS_W-1:0] p);
        return (p == RAS_LAST) ? '0 : p + 1'b1;
    endfunction
    function automatic logic [RAS_W-1:0] ras_dec(input logic [RAS_W-1:0] p);
        return (p == '0) ? RAS_LAST : p - 1'b1;
    endfunction

    // ---- lookup (IF)
    logic [BTB_BITS-1:0] bi;
    logic                hit;
    logic [1:0]          kind;
    assign bi   = pc[2 +: BTB_BITS];
    assign hit  = (MODE != 0) && btb_valid[bi] && btb_tag[bi] == pc[31 -: TAG_W];
    assign kind = btb_kind[bi];

    assign pred_idx    = (MODE == 2) ? (pc[2 +: BHT_BITS] ^ s_ghr) : pc[2 +: BHT_BITS];
    assign pred_ctr    = bht[pred_idx];
    assign pred_branch = hit && kind == K_BRANCH;
    assign pred_taken  = hit && (kind != K_BRANCH || pred_ctr[1]);
    assign pred_target = {(kind == K_RET && RAS_DEPTH > 0 && s_cnt != '0) ? s_ras[s_top]
                                                                          : btb_target[bi], 2'b00};

    // ---- committed history and stack after this cycle's EX update
    always_comb begin
        c_ghr_n = c_ghr;
        c_ras_n = c_ras;
        c_top_n = c_top;
        c_cnt_n = c_cnt;
        if (upd_valid && upd_cf) begin
            if (upd_branch) c_ghr_n = {c_ghr[BHT_BITS-2:0], upd_taken};
            if (upd_kind == K_CALL) begin
                c_top_n          = ras_inc(c_top);
                c_ras_n[c_top_n] = upd_pc[31:2] + 30'd1;
                if (c_cnt != RAS_FULL) c_cnt_n = c_cnt + 1'b1;
            end else if (upd_kind == K_RET && c_cnt != '0) begin
                c_top_n = ras_dec(c_top);
                c_cnt_n = c_cnt - 1'b1;
            end
        end
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            c_ghr <= '0;
            c_top <= '0;
            c_cnt <= '0;
            s_ghr <= '0;
            s_top <= '0;
            s_cnt <= '0;
        end else begin
            c_ghr <= c_ghr_n;
            c_ras <= c_ras_n;
            c_top <= c_top_n;
            c_cnt <= c_cnt_n;
            if (recover) begin
                s_ghr <= c_ghr_n;
                s_ras <= c_ras_n;
                s_top <= c_top_n;
                s_cnt <= c_cnt_n;
            end else if (advance && hit) begin
                if (kind == K_BRANCH) s_ghr <= {s_ghr[BHT_BITS-2:0], pred_ctr[1]};
                if (kind == K_CALL) begin
                    s_top                <= ras_inc(s_top);
                    s_ras[ras_inc(s_top)] <= pc[31:2] + 30'd1;
                    if (s_cnt != RAS_FULL) s_cnt <= s_cnt + 1'b1;
                end else if (kind == K_RET && s_cnt != '0) begin
                    s_top <= ras_dec(s_top);
                    s_cnt <= s_cnt - 1'b1;
                end
            end
        end
    end

    // ---- table updates (EX)
    logic [BTB_BITS-1:0] ui;
    assign ui = upd_pc[2 +: BTB_BITS];

    always_ff @(posedge clk) begin
        if (rst) begin
            for (int i = 0; i < BTB_N; i++) btb_valid[i] <= 1'b0;
            for (int i = 0; i < BHT_N; i++) bht[i] <= 2'b01;    // weakly not taken
        end else if (upd_valid) begin
            if (!upd_cf) begin
                btb_valid[ui] <= 1'b0;            // a stale entry predicted a non-branch taken
            end else if (upd_taken) begin
                btb_valid[ui]  <= 1'b1;           // allocate taken branches and all jumps
                btb_tag[ui]    <= upd_pc[31 -: TAG_W];
                btb_target[ui] <= upd_target[31:2];
                btb_kind[ui]   <= upd_kind;
            end
            if (upd_cf && upd_kind == K_BRANCH) begin
                if (upd_taken && upd_ctr != 2'b11)       bht[upd_idx] <= upd_ctr + 2'd1;
                else if (!upd_taken && upd_ctr != 2'b00) bht[upd_idx] <= upd_ctr - 2'd1;
                else                                     bht[upd_idx] <= upd_ctr;
            end
        end
    end

    // pc[1:0], upd_pc[1:0] and upd_target[1:0] are always 0 here.
    logic unused;
    assign unused = ^{pc[1:0], upd_pc[1:0], upd_target[1:0]};

endmodule
