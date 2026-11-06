// Simple dual-port RAM: one write port, one read port, registered read. The same coding style as
// edge-ml-accelerator's sdp_ram.v, which Quartus maps onto M9K block RAM.
module sdp_ram #(
    parameter int WIDTH = 32,
    parameter int DEPTH = 256
) (
    input  logic                     clk,
    input  logic                     we,
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0]         wdata,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0]         rdata
);
    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end
endmodule
