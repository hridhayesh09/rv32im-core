// Cache: direct-mapped (WAYS = 1) or 2-way set associative (WAYS = 2, LRU replacement), 16-byte
// lines. Used as the instruction cache (read only) and as the data cache (write-back,
// write-allocate).
//
// Timing (the same as the block RAM it replaces): a request in cycle t (req_en) reads the tags
// and data; in cycle t+1 the tags are compared and, on a hit, rdata is valid and stall is low.
// On a miss, stall stays high while the cache
//   1. writes the victim line back to memory if it's dirty,
//   2. reads the requested line from memory into the victim way,
//   3. replays the lookup, which now hits.
// A store that hits writes its bytes into the data RAM in its compare cycle. A request issued in
// that same cycle reads the RAM before the write lands, so the just-written bytes are forwarded
// to it (to its load data, and to the victim data if it evicts that line).
//
// `keep` low in the compare cycle drops the request instead of handling a miss (the instruction
// cache uses it for fetches the core has already flushed).
// `flush` (one cycle) writes back every dirty line (data cache) or invalidates every line
// (instruction cache); stall stays high until it's done, then a pending request is replayed.
// FENCE.I uses both.
module cache #(
    parameter int SIZE     = 4096,          // bytes
    parameter int WAYS     = 1,             // 1 or 2
    parameter bit WRITABLE = 1'b1           // 0 for the instruction cache
) (
    input  logic         clk,
    input  logic         rst,

    // core side
    input  logic         req_en,
    input  logic [3:0]   req_we,            // byte write enables; 0 = read
    input  logic [31:0]  req_addr,
    input  logic [31:0]  req_wdata,
    input  logic         keep,
    output logic [31:0]  rdata,
    output logic         stall,
    input  logic         flush,

    // memory side: one 16-byte line per request (hold mem_req until mem_ack)
    output logic         mem_req,
    output logic         mem_we,
    output logic [31:0]  mem_addr,
    output logic [127:0] mem_wdata,
    input  logic [127:0] mem_rdata,
    input  logic         mem_ack,

    // performance events (one cycle each)
    output logic         ev_access,
    output logic         ev_miss
);
    localparam int LINES = SIZE / (16 * WAYS);     // lines per way
    localparam int IB    = $clog2(LINES);           // index bits
    localparam int TB    = 32 - 4 - IB;             // tag bits
    localparam int TW    = ((TB + 7) / 8) * 8;      // tag RAM width (whole bytes)
    localparam int LAST_LINE_INT = LINES - 1;
    localparam logic [IB-1:0] LAST_LINE = LAST_LINE_INT[IB-1:0];
    localparam logic          TWO_WAYS  = WAYS == 2;

    function automatic logic [IB-1:0] index_of(input logic [31:0] a);
        return a[4 +: IB];
    endfunction
    function automatic logic [TB-1:0] tag_of(input logic [31:0] a);
        return a[31 -: TB];
    endfunction

    // ---------------------------------------------------------------- storage
    // Valid, dirty and LRU bits are flip-flops (a flush clears them at once); tags and data are
    // block RAM: per way, a tag RAM and 4 data lanes (word i of every line in lane i).
    logic [WAYS-1:0][LINES-1:0] valid;
    logic [WAYS-1:0][LINES-1:0] dirty;
    logic [LINES-1:0] lru;                          // 2-way: the way to replace next

    logic [IB-1:0]   rd_index, wr_index;
    logic            rd_en;
    logic [WAYS-1:0] tag_we;
    // Packed arrays (indexed the same way as unpacked ones): the ASIC flow's Yosys reads
    // multi-dimensional unpacked arrays badly.
    logic [WAYS-1:0][3:0][3:0]  lane_we;
    logic [3:0][31:0]           lane_wdata;
    logic [TB-1:0]   tag_wdata;
    logic [WAYS-1:0][TW-1:0]    tag_raw;
    logic [WAYS-1:0][TB-1:0]    tag_out;
    logic [WAYS-1:0][3:0][31:0] data_out;

    genvar w, l;
    generate
        for (w = 0; w < WAYS; w++) begin : g_way
            cache_ram #(.WIDTH(TW), .DEPTH(LINES)) u_tag (
                .clk,
                .we    ({(TW / 8){tag_we[w]}}),
                .waddr (wr_index),
                .wdata ({{(TW - TB){1'b0}}, tag_wdata}),
                .re    (rd_en),
                .raddr (rd_index),
                .rdata (tag_raw[w])
            );
            assign tag_out[w] = tag_raw[w][TB-1:0];
            for (l = 0; l < 4; l++) begin : g_lane
                cache_ram #(.WIDTH(32), .DEPTH(LINES)) u_data (
                    .clk,
                    .we    (lane_we[w][l]),
                    .waddr (wr_index),
                    .wdata (lane_wdata[l]),
                    .re    (rd_en),
                    .raddr (rd_index),
                    .rdata (data_out[w][l])
                );
            end
        end
    endgenerate

    // ---------------------------------------------------------------- the request being compared
    logic          pend;                // a request is waiting for its compare
    logic          pend_replayed;       // ...and it's a replay (don't count the access twice)
    logic [31:0]   q_addr, q_wdata;
    logic [3:0]    q_we;
    logic [IB-1:0] q_index;
    assign q_index = index_of(q_addr);

    logic [WAYS-1:0] way_hit;
    logic            hit, hit_way;     // hit_way: which way (0 for direct-mapped)
    always_comb begin
        hit_way = 1'b0;
        for (int i = 0; i < WAYS; i++) begin
            way_hit[i] = valid[i][q_index] && tag_out[i] == tag_of(q_addr);
            if (way_hit[i] && i == 1) hit_way = 1'b1;
        end
        hit = |way_hit;
    end

    // Store forwarding: a store hit wrote these bytes after this request's RAM read had already
    // started. It stays valid until the next RAM read (which sees the new bytes itself), so a
    // result held while the core is frozen keeps them.
    logic          fwd_valid, fwd_way;
    logic [IB-1:0] fwd_index;
    logic [1:0]    fwd_lane;
    logic [3:0]    fwd_be;
    logic [31:0]   fwd_data;

    function automatic logic [31:0] forwarded(input logic [31:0] data, input logic way,
                                              input logic [1:0] lane);
        logic [31:0] d;
        d = data;
        if (fwd_valid && fwd_index == q_index && fwd_way == way && fwd_lane == lane) begin
            for (int b = 0; b < 4; b++) if (fwd_be[b]) d[8*b +: 8] = fwd_data[8*b +: 8];
        end
        return d;
    endfunction

    assign rdata = forwarded(data_out[hit_way][q_addr[3:2]], hit_way, q_addr[3:2]);

    // ---------------------------------------------------------------- control
    typedef enum logic [2:0] { S_RUN, S_WRITEBACK, S_REFILL, S_REPLAY, S_FLUSH_READ, S_FLUSH_CHECK,
                               S_FLUSH_WRITE } state_t;
    state_t        state;
    logic          victim;
    logic [127:0]  victim_data;
    logic [31:0]   victim_addr;
    logic          flush_pending;
    logic [IB-1:0] flush_index;
    logic          flush_way;

    // The way a miss fills: an invalid way first, else the least recently used.
    logic choose;
    always_comb begin
        if (!TWO_WAYS)                 choose = 1'b0;
        else if (!valid[0][q_index])   choose = 1'b0;
        else if (!valid[WAYS-1][q_index]) choose = 1'b1;
        else                           choose = lru[q_index];
    end

    logic [127:0] choose_line;          // the line in that way, with a just-written store merged
    always_comb begin
        for (int j = 0; j < 4; j++) begin
            choose_line[32*j +: 32] = forwarded(data_out[choose][j], choose, j[1:0]);
        end
    end

    logic compare, miss_now;
    assign compare  = state == S_RUN && pend;
    assign miss_now = compare && !hit && keep;

    always_comb begin
        // RAM read port: the core's request, or the FSM (replay, flush walk).
        rd_en    = req_en;
        rd_index = index_of(req_addr);
        if (state == S_REPLAY) begin
            rd_en    = 1'b1;
            rd_index = q_index;
        end else if (state == S_FLUSH_READ) begin
            rd_en    = 1'b1;
            rd_index = flush_index;
        end

        // RAM write port: a store hit (compare cycle) or a refill.
        tag_we    = '0;
        tag_wdata = tag_of(q_addr);
        wr_index  = q_index;
        for (int i = 0; i < WAYS; i++) for (int j = 0; j < 4; j++) lane_we[i][j] = 4'b0000;
        for (int j = 0; j < 4; j++) lane_wdata[j] = q_wdata;
        if (WRITABLE && compare && hit && q_we != 4'b0000) begin
            lane_we[hit_way][q_addr[3:2]] = q_we;
        end
        if (state == S_REFILL && mem_req && mem_ack) begin
            tag_we[victim] = 1'b1;
            for (int j = 0; j < 4; j++) begin
                lane_we[victim][j] = 4'b1111;
                lane_wdata[j]      = mem_rdata[32*j +: 32];
            end
        end
    end

    // Stall while the request isn't done, and while a flush is waiting or running.
    assign stall     = miss_now || state != S_RUN || flush_pending;
    assign ev_access = compare && keep && !pend_replayed;
    assign ev_miss   = miss_now;

    always_ff @(posedge clk) begin
        if (rst) begin
            state         <= S_RUN;
            pend          <= 1'b0;
            pend_replayed <= 1'b0;
            fwd_valid     <= 1'b0;
            flush_pending <= 1'b0;
            mem_req       <= 1'b0;
            valid <= '0;
            dirty <= '0;
            lru <= '0;
        end else begin
            if (rd_en) fwd_valid <= 1'b0;
            if (flush) flush_pending <= 1'b1;

            case (state)
                S_RUN: begin
                    if (compare && hit && keep) begin
                        if (TWO_WAYS) lru[q_index] <= !hit_way;
                        if (WRITABLE && q_we != 4'b0000) begin
                            dirty[hit_way][q_index] <= 1'b1;
                            fwd_valid <= 1'b1;
                            fwd_index <= q_index;
                            fwd_way   <= hit_way;
                            fwd_lane  <= q_addr[3:2];
                            fwd_be    <= q_we;
                            fwd_data  <= q_wdata;
                        end
                    end

                    if (miss_now) begin
                        victim      <= choose;
                        victim_data <= choose_line;
                        victim_addr <= {tag_out[choose], q_index, 4'b0000};
                        state <= (WRITABLE && valid[choose][q_index] && dirty[choose][q_index])
                                 ? S_WRITEBACK : S_REFILL;
                        // pend stays set: the request is replayed after the refill
                    end else if (flush_pending) begin
                        // A request compared in this cycle had to wait for the flush (stall is
                        // high), so it's replayed afterwards: pend stays as it is.
                        flush_pending <= 1'b0;
                        if (WRITABLE) begin
                            flush_index <= '0;
                            flush_way   <= 1'b0;
                            state       <= S_FLUSH_READ;
                        end else begin
                            valid <= '0;
                            if (pend) state <= S_REPLAY;
                        end
                    end else begin
                        pend          <= req_en;
                        pend_replayed <= 1'b0;
                        if (req_en) begin
                            q_addr  <= req_addr;
                            q_we    <= req_we;
                            q_wdata <= req_wdata;
                        end
                    end
                end
                S_WRITEBACK: begin
                    mem_req <= 1'b1;
                    if (mem_req && mem_ack) begin
                        mem_req <= 1'b0;
                        dirty[victim][q_index] <= 1'b0;
                        state <= S_REFILL;
                    end
                end
                S_REFILL: begin
                    mem_req <= 1'b1;
                    if (mem_req && mem_ack) begin
                        mem_req <= 1'b0;
                        valid[victim][q_index] <= 1'b1;
                        dirty[victim][q_index] <= 1'b0;
                        state <= S_REPLAY;
                    end
                end
                S_REPLAY: begin                     // read the line again; compare next cycle
                    pend_replayed <= 1'b1;
                    state <= S_RUN;
                end
                S_FLUSH_READ: begin                 // read flush_index's tags and data
                    state <= S_FLUSH_CHECK;
                end
                S_FLUSH_CHECK: begin
                    if (valid[flush_way][flush_index] && dirty[flush_way][flush_index]) begin
                        victim      <= flush_way;
                        victim_data <= {data_out[flush_way][3], data_out[flush_way][2],
                                        data_out[flush_way][1], data_out[flush_way][0]};
                        victim_addr <= {tag_out[flush_way], flush_index, 4'b0000};
                        state       <= S_FLUSH_WRITE;
                    end else if (TWO_WAYS && !flush_way) begin
                        flush_way <= 1'b1;          // both ways were read together
                    end else if (flush_index == LAST_LINE) begin
                        state <= pend ? S_REPLAY : S_RUN;
                    end else begin
                        flush_way   <= 1'b0;
                        flush_index <= flush_index + 1'b1;
                        state       <= S_FLUSH_READ;
                    end
                end
                S_FLUSH_WRITE: begin
                    mem_req <= 1'b1;
                    if (mem_req && mem_ack) begin
                        mem_req <= 1'b0;
                        dirty[victim][flush_index] <= 1'b0;
                        state <= S_FLUSH_CHECK;     // the same line again: clean now, moves on
                    end
                end
                default: state <= S_RUN;
            endcase
        end
    end

    // Memory request: write back a victim, or read the requested line.
    assign mem_we    = state == S_WRITEBACK || state == S_FLUSH_WRITE;
    assign mem_addr  = mem_we ? victim_addr : {q_addr[31:4], 4'b0000};
    assign mem_wdata = victim_data;
endmodule
