// NPU: the 16x16 systolic array as a memory-mapped accelerator (Wishbone slave).
//
// The CPU loads a 16x16 weight tile into the array, writes activation rows into the A buffer,
// and starts a matrix product. A sequencer then streams COUNT rows through the array, one per
// clock, and writes (or adds) each result row into the C buffer:
//
//   for i in 0..COUNT-1:
//       C[C_BASE + i*C_STRIDE] (+)= A[A_BASE + i*A_STRIDE] x W        (16 x int32 per row)
//
// Address map (byte addresses, word accesses):
//   0x3000_0000  A buffer: 1024 rows x 16 int8. Row r, bytes 4w..4w+3 at + r*16 + w*4. Write only.
//   0x3001_0000  C buffer:  256 rows x 16 int32. Row r, column j at + r*64 + j*4. Read only;
//                read it only while the NPU is idle.
//   0x1000_4000  CTRL      write: bit 0 = start, bit 1 = accumulate (add into C instead of
//                          overwriting)
//   0x1000_4004  STATUS    bit 0 = busy
//   0x1000_4008  A_BASE    0x1000_400C A_STRIDE   (rows)
//   0x1000_4010  C_BASE    0x1000_4014 C_STRIDE   (rows)
//   0x1000_4018  COUNT     rows to process
//   0x1000_4020  W_DATA    weight tile, 64 writes in order: write 4w+k holds W[w][4k..4k+3]
//                          (row w = input index, byte j = output column); every 4th write loads
//                          one PE row into the array
//   0x1000_4024  W_RESET   any write: the next W_DATA write starts at row 0
//   0x1000_4028  CYCLES    clock cycles the last matrix product took (start to last write)
//
// Weights must not change while busy (the array holds them during the product).
module wb_npu (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,
    input  logic [3:0]  wb_sel,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wb_dat_w,
    output logic [31:0] wb_dat_r,
    output logic        wb_ack
);
    localparam int N = 16;

    // ---------------------------------------------------------------- bus decode
    logic access, to_regs, to_a, to_c;
    assign access  = wb_stb && !wb_ack;
    assign to_regs = wb_adr[29:28] == 2'b01;                      // 0x1000_4xxx
    assign to_a    = wb_adr[29:28] == 2'b11 && !wb_adr[16];       // 0x3000_xxxx
    assign to_c    = wb_adr[29:28] == 2'b11 &&  wb_adr[16];       // 0x3001_xxxx

    // ---------------------------------------------------------------- registers
    logic        busy, accumulate;
    logic [9:0]  a_base, a_stride;
    logic [7:0]  c_base, c_stride;
    logic [10:0] count;
    logic [31:0] cycles;
    logic [5:0]  w_word;            // next W_DATA write, 0..63
    logic [95:0] w_staging;         // the first 3 words of the PE row being written
    logic        start;

    // ---------------------------------------------------------------- A buffer
    // 4 lanes of 1024 x 32 bits: the CPU writes one lane, the sequencer reads all 4 (one row).
    logic [9:0]   a_raddr;
    logic [127:0] a_rdata;
    genvar lane;
    generate
    for (lane = 0; lane < 4; lane++) begin : g_a
        sdp_ram #(.WIDTH(32), .DEPTH(1024)) u_a (
            .clk,
            .we    (access && wb_we && to_a && {30'b0, wb_adr[3:2]} == lane),
            .waddr (wb_adr[13:4]),
            .wdata (wb_dat_w),
            .raddr (a_raddr),
            .rdata (a_rdata[32*lane +: 32])
        );
    end
    endgenerate

    // ---------------------------------------------------------------- C buffer
    // 16 lanes of 256 x 32 bits: the sequencer writes whole rows; the read port is shared by the
    // sequencer (old values, to accumulate) and the CPU (results, while idle).
    logic         c_we;
    logic [7:0]   c_waddr, c_raddr, seq_c_raddr;
    logic [511:0] c_wdata, c_rdata;
    assign c_raddr = busy ? seq_c_raddr : wb_adr[13:6];
    generate
    for (lane = 0; lane < N; lane++) begin : g_c
        sdp_ram #(.WIDTH(32), .DEPTH(256)) u_c (
            .clk,
            .we    (c_we),
            .waddr (c_waddr),
            .wdata (c_wdata[32*lane +: 32]),
            .raddr (c_raddr),
            .rdata (c_rdata[32*lane +: 32])
        );
    end
    endgenerate

    // ---------------------------------------------------------------- the array
    logic         w_row_we, in_valid, pre_valid, out_valid;
    logic [3:0]   w_row_idx;
    logic [127:0] w_row_data;
    logic [511:0] c_row;

    systolic_array #(.N(N)) u_array (
        .clk, .rst,
        .w_we       (1'b0),
        .w_addr     (8'd0),
        .w_data     (8'd0),
        .w_row_we,
        .w_row_idx,
        .w_row_data,
        .in_valid,
        .a_row      (a_rdata),
        .pre_valid,
        .out_valid,
        .c_row
    );

    // ---------------------------------------------------------------- sequencer
    logic [10:0] issued, written;
    logic [9:0]  a_ptr;
    logic [7:0]  c_rd_ptr, c_wr_ptr;
    logic        a_valid;           // a row was read from the A buffer last cycle

    assign a_raddr     = a_ptr;
    assign in_valid    = a_valid;   // the row read last cycle enters the array now
    assign seq_c_raddr = c_rd_ptr;

    // Accumulate: the old row was read when pre_valid was high, so it's ready with out_valid.
    always_comb begin
        for (int j = 0; j < N; j++) begin
            c_wdata[32*j +: 32] = accumulate ? c_rdata[32*j +: 32] + c_row[32*j +: 32]
                                             : c_row[32*j +: 32];
        end
    end
    assign c_we    = busy && out_valid;
    assign c_waddr = c_wr_ptr;

    always_ff @(posedge clk) begin
        if (rst) begin
            busy    <= 1'b0;
            a_valid <= 1'b0;
            cycles  <= '0;
        end else if (!busy) begin
            a_valid <= 1'b0;
            if (start && count != '0) begin
                busy     <= 1'b1;
                issued   <= '0;
                written  <= '0;
                a_ptr    <= a_base;
                c_rd_ptr <= c_base;
                c_wr_ptr <= c_base;
                cycles   <= '0;
            end
        end else begin
            cycles <= cycles + 32'd1;
            // Issue: read the next A row (it enters the array next cycle). The first busy cycle reads
            // A_BASE, because a_ptr was loaded with it when the product started.
            a_valid <= issued != count;
            if (issued != count) begin
                issued <= issued + 11'd1;
                a_ptr  <= a_ptr + a_stride;
            end
            if (pre_valid) c_rd_ptr <= c_rd_ptr + c_stride;
            if (out_valid) begin
                c_wr_ptr <= c_wr_ptr + c_stride;
                written  <= written + 11'd1;
                if (written + 11'd1 == count) busy <= 1'b0;
            end
        end
    end

    // ---------------------------------------------------------------- register writes
    always_ff @(posedge clk) begin
        if (rst) begin
            w_word     <= '0;
            w_row_we   <= 1'b0;
            start      <= 1'b0;
            accumulate <= 1'b0;
            a_base     <= '0;
            a_stride   <= 10'd1;
            c_base     <= '0;
            c_stride   <= 8'd1;
            count      <= '0;
        end else begin
            w_row_we <= 1'b0;
            start    <= 1'b0;
            if (access && wb_we && to_regs) begin
                case (wb_adr[5:2])
                    4'h0: begin start <= wb_dat_w[0]; accumulate <= wb_dat_w[1]; end
                    4'h2: a_base   <= wb_dat_w[9:0];
                    4'h3: a_stride <= wb_dat_w[9:0];
                    4'h4: c_base   <= wb_dat_w[7:0];
                    4'h5: c_stride <= wb_dat_w[7:0];
                    4'h6: count    <= wb_dat_w[10:0];
                    4'h8: begin
                        if (w_word[1:0] == 2'd3) begin
                            w_row_we   <= 1'b1;
                            w_row_idx  <= w_word[5:2];
                            w_row_data <= {wb_dat_w, w_staging};
                        end else begin
                            w_staging[32*w_word[1:0] +: 32] <= wb_dat_w;
                        end
                        w_word <= w_word + 6'd1;
                    end
                    4'h9: w_word <= '0;
                    default: ;
                endcase
            end
        end
    end

    // ---------------------------------------------------------------- reads
    logic        c_read;
    logic [3:0]  c_read_col;
    logic [31:0] reg_dat_r;

    always_ff @(posedge clk) begin
        if (rst) begin
            wb_ack <= 1'b0;
            c_read <= 1'b0;
        end else begin
            wb_ack     <= access;
            c_read     <= access && !wb_we && to_c;
            c_read_col <= wb_adr[5:2];
            if (access && !wb_we && to_regs) begin
                case (wb_adr[5:2])
                    4'h1:    reg_dat_r <= {31'b0, busy};
                    4'h2:    reg_dat_r <= {22'b0, a_base};
                    4'h3:    reg_dat_r <= {22'b0, a_stride};
                    4'h4:    reg_dat_r <= {24'b0, c_base};
                    4'h5:    reg_dat_r <= {24'b0, c_stride};
                    4'h6:    reg_dat_r <= {21'b0, count};
                    4'h9:    reg_dat_r <= {26'b0, w_word};
                    4'hA:    reg_dat_r <= cycles;
                    default: reg_dat_r <= '0;
                endcase
            end else begin
                reg_dat_r <= '0;   // A buffer reads return 0
            end
        end
    end

    assign wb_dat_r = c_read ? c_rdata[32*c_read_col +: 32] : reg_dat_r;
endmodule
