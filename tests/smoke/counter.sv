// Stage 0 smoke test: proves the Verilator + cocotb flow works end to end.
module counter (
    input  logic       clk,
    input  logic       rst,
    output logic [7:0] count
);
    always_ff @(posedge clk) begin
        if (rst) count <= '0;
        else     count <= count + 8'd1;
    end
endmodule
