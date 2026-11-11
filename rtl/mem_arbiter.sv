// Shares one line-memory port between the data cache (port 0, priority) and the instruction cache
// (port 1). A granted request keeps the port until its ack.
module mem_arbiter (
    input  logic         clk,
    input  logic         rst,

    input  logic         req0,
    input  logic         we0,
    input  logic [31:0]  addr0,
    input  logic [127:0] wdata0,
    output logic         ack0,

    input  logic         req1,
    input  logic         we1,
    input  logic [31:0]  addr1,
    input  logic [127:0] wdata1,
    output logic         ack1,

    output logic         mem_req,
    output logic         mem_we,
    output logic [31:0]  mem_addr,
    output logic [127:0] mem_wdata,
    input  logic         mem_ack
);
    logic busy, owner_q, owner;

    // A new grant goes to port 0 if it asks, else port 1.
    assign owner = busy ? owner_q : !req0;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
        end else if (!busy && (req0 || req1)) begin
            busy    <= !mem_ack;
            owner_q <= owner;
        end else if (busy && mem_ack) begin
            busy <= 1'b0;
        end
    end

    assign mem_req   = owner ? req1   : req0;
    assign mem_we    = owner ? we1    : we0;
    assign mem_addr  = owner ? addr1  : addr0;
    assign mem_wdata = owner ? wdata1 : wdata0;
    assign ack0      = mem_ack && !owner;
    assign ack1      = mem_ack &&  owner;
endmodule
