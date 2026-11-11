// Slow memory with a 16-byte line port, for the cache tests: 1 MB at 0x8000_0000, loaded from
// +program=<hex>. Each line request takes LATENCY cycles, or a random 1-16 with +random_stalls.
/* verilator lint_off BLKSEQ */
module line_mem #(
    parameter int LATENCY = 6
) (
    input  logic         clk,
    input  logic         rst,
    input  logic         req,
    input  logic         we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]  addr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [127:0] wdata,
    output logic [127:0] rdata,
    output logic         ack
);
    localparam int WORDS = 1 << 18;
    logic [31:0] mem [WORDS];
    logic        random_stalls;
    logic [15:0] lfsr;
    int          wait_cycles;
    logic        busy;

    initial begin
        string path;
        random_stalls = $test$plusargs("random_stalls");
        for (int i = 0; i < WORDS; i++) mem[i] = 32'h0;
        if ($value$plusargs("program=%s", path)) $readmemh(path, mem);
    end

    // Word index of the line's first word (the address is held for the whole request). A wire,
    // not an automatic variable, so Icarus (gate-level simulation) accepts it too.
    logic [17:0] base;
    assign base = {addr[19:4], 2'b00};

    always_ff @(posedge clk) begin
        if (rst) begin
            ack  <= 1'b0;
            busy <= 1'b0;
            lfsr <= 16'hBEEF;
        end else begin
            lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
            ack  <= 1'b0;
            if (req && !busy && !ack) begin
                busy        <= 1'b1;
                wait_cycles <= random_stalls ? 1 + int'(lfsr[3:0]) : LATENCY;
            end else if (busy) begin
                if (wait_cycles <= 1) begin
                    busy <= 1'b0;
                    ack  <= 1'b1;
                    for (int i = 0; i < 4; i++) begin
                        if (we) mem[int'(base) + i] = wdata[32*i +: 32];
                        rdata[32*i +: 32] <= mem[int'(base) + i];
                    end
                end else begin
                    wait_cycles <= wait_cycles - 1;
                end
            end
        end
    end
endmodule
