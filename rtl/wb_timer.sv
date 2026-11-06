// Timer as a Wishbone slave: a 64-bit counter of clock cycles and a compare value.
//
//   +0x00 TIME_LO   counter, low 32 bits  (read only)
//   +0x04 TIME_HI   counter, high 32 bits (read only)
//   +0x08 CMP_LO    compare value, low 32 bits
//   +0x0C CMP_HI    compare value, high 32 bits
//   +0x10 STATUS    bit 0: TIME >= CMP
//   +0x14 CLK_HZ    the clock frequency (read only), so software can convert cycles to time
//
// Reading the 64-bit counter safely from a 32-bit CPU: read HI, LO, then HI again; if HI
// changed, the low half wrapped in between, so read again.
module wb_timer #(
    parameter logic [31:0] CLK_HZ = 32'd50_000_000
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,     // only bits [4:2] select a register
    input  logic [3:0]  wb_sel,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wb_dat_w,
    output logic [31:0] wb_dat_r,
    output logic        wb_ack
);
    logic [63:0] count, compare;
    logic        access;
    assign access = wb_stb && !wb_ack;

    always_ff @(posedge clk) begin
        if (rst) begin
            count   <= '0;
            compare <= '1;
            wb_ack  <= 1'b0;
        end else begin
            count  <= count + 64'd1;
            wb_ack <= access;
            if (access && wb_we && wb_sel == 4'b1111) begin
                case (wb_adr[4:2])
                    3'd2:    compare[31:0]  <= wb_dat_w;
                    3'd3:    compare[63:32] <= wb_dat_w;
                    default: ;
                endcase
            end
            if (access && !wb_we) begin
                case (wb_adr[4:2])
                    3'd0:    wb_dat_r <= count[31:0];
                    3'd1:    wb_dat_r <= count[63:32];
                    3'd2:    wb_dat_r <= compare[31:0];
                    3'd3:    wb_dat_r <= compare[63:32];
                    3'd4:    wb_dat_r <= {31'b0, count >= compare};
                    3'd5:    wb_dat_r <= CLK_HZ;
                    default: wb_dat_r <= '0;
                endcase
            end
        end
    end
endmodule
