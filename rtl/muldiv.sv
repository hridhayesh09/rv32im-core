// Multiply/divide unit for the M extension. Multi-cycle: the core holds the instruction in EX
// until `done`.
//
//   Multiply (MUL, MULH, MULHSU, MULHU): 2 cycles. The operands are registered first, so the
//     33x33-bit multiplier sits between two registers (one full cycle for the FPGA DSP blocks).
//   Divide/remainder (DIV, DIVU, REM, REMU): 33 cycles. Restoring division on the magnitudes,
//     one quotient bit per cycle, then the signs are fixed up.
//
// Handshake: `start` is accepted only when idle. `done` is high for one cycle with `result`;
// the unit is idle again the cycle after.
module muldiv (
    input  logic        clk,
    input  logic        rst,
    input  logic        start,
    input  logic [2:0]  op,       // funct3
    input  logic [31:0] a,        // rs1
    input  logic [31:0] b,        // rs2
    output logic        done,
    output logic [31:0] result
);
    localparam logic [2:0] MUL = 3'b000, MULH = 3'b001, MULHSU = 3'b010;
    localparam logic [2:0] DIV = 3'b100, REM = 3'b110;

    typedef enum logic [1:0] { IDLE, MULTIPLY, DIVIDE, DONE } state_t;
    state_t state;

    logic [2:0]  op_q;
    logic [31:0] result_q;

    // ---------------------------------------------------------------- multiply
    // Extending each operand to 33 bits (sign bit or zero) makes one signed multiplier
    // handle all four variants.
    logic signed [32:0] mul_a, mul_b;
    logic signed [65:0] product;
    assign product = mul_a * mul_b;

    // ---------------------------------------------------------------- divide
    logic [31:0] quotient, remainder, divisor;
    logic [5:0]  count;
    logic        negate_q, negate_r;

    logic        signed_div;
    logic [31:0] abs_a, abs_b;
    assign signed_div = op == DIV || op == REM;
    assign abs_a = (signed_div && a[31]) ? -a : a;
    assign abs_b = (signed_div && b[31]) ? -b : b;

    // One step of restoring division: shift the next dividend bit into the remainder and
    // subtract the divisor if it fits.
    logic [33:0] trial;
    logic [31:0] quotient_next, remainder_next;
    always_comb begin
        trial = {1'b0, remainder, quotient[31]} - {2'b0, divisor};
        if (trial[33]) begin  // negative: divisor didn't fit
            remainder_next = {remainder[30:0], quotient[31]};
            quotient_next  = {quotient[30:0], 1'b0};
        end else begin
            remainder_next = trial[31:0];
            quotient_next  = {quotient[30:0], 1'b1};
        end
    end

    function automatic logic [31:0] div_result(input logic [2:0] f3, input logic [31:0] q, r,
                                               input logic neg_q, neg_r);
        if (f3[1] == 1'b0) return neg_q ? -q : q;   // DIV, DIVU
        else               return neg_r ? -r : r;   // REM, REMU
    endfunction

    // ---------------------------------------------------------------- control

    always_ff @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
        end else begin
            case (state)
                IDLE: if (start) begin
                    op_q <= op;
                    if (!op[2]) begin
                        mul_a <= {(op == MULH || op == MULHSU) & a[31], a};
                        mul_b <= {(op == MULH) & b[31], b};
                        state <= MULTIPLY;
                    end else begin
                        quotient  <= abs_a;      // dividend bits shift out of the top
                        remainder <= '0;
                        divisor   <= abs_b;
                        count     <= 6'd32;
                        // Signs of the results (truncating division). Division by zero
                        // returns all ones for the quotient, so no sign fix there.
                        negate_q  <= signed_div && (a[31] ^ b[31]) && b != '0;
                        negate_r  <= signed_div && a[31];
                        state     <= DIVIDE;
                    end
                end
                MULTIPLY: begin
                    result_q <= (op_q == MUL) ? product[31:0] : product[63:32];
                    state    <= DONE;
                end
                DIVIDE: begin
                    quotient  <= quotient_next;
                    remainder <= remainder_next;
                    count     <= count - 6'd1;
                    if (count == 6'd1) begin
                        result_q <= div_result(op_q, quotient_next, remainder_next, negate_q, negate_r);
                        state    <= DONE;
                    end
                end
                default: state <= IDLE;   // DONE
            endcase
        end
    end

    assign done   = state == DONE;
    assign result = result_q;
endmodule
