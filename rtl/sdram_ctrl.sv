// SDRAM controller for the DE10-Lite's IS42S16320 (64 MB: 4 banks x 8192 rows x 1024 columns
// x 16 bits). Two ports:
//   - a Wishbone slave: one 32-bit word per access (uncached accesses);
//   - a line port for the caches: one 16-byte line (4 words) per access.
//
// Kept simple on purpose:
//   - every access opens the row (ACTIVE), streams its data, and the last command closes the row
//     again with auto-precharge ("closed page"); no row stays open between accesses;
//   - a word is a burst of 2 halfwords (mode register burst length 2); a line is 4 READ or WRITE
//     commands, one every 2 cycles in the same row, so the data streams without gaps;
//   - refresh happens between accesses, every REFRESH_CYCLES;
//   - timings are given in clock cycles for a 50 MHz clock (20 ns); see the defaults.
//
// Byte address -> SDRAM: [12:11] bank, [25:13] row, [10:2] column / 2. Bits [31:26] are ignored.
// A 16-byte line (address bits [3:0] = 0) is 8 consecutive columns in one row.
// Commands go out of registers, so the chip sees each one at the clock edge after it's set.
module sdram_ctrl #(
    parameter int INIT_CYCLES    = 10000,  // power-up wait: >= 100 us (200 us at 50 MHz)
    parameter int REFRESH_CYCLES = 360,    // 64 ms / 8192 rows = 7.8 us = 390 cycles; the margin
                                           //   covers a refresh waiting for a line transfer (~20)
    parameter int T_RP           = 1,      // PRECHARGE -> next command: 15 ns
    parameter int T_RFC          = 3,      // REFRESH -> next command: 60 ns
    parameter int T_MRD          = 2,      // LOAD MODE -> next command: 2 cycles
    parameter int READ_LATENCY   = 3       // cycles from READ until the first halfword is in the
                                           //   burst buffer (captured at the pins half a cycle
                                           //   earlier, see dq_in_q)
) (
    input  logic         clk,
    input  logic         rst,

    input  logic         wb_stb,
    input  logic         wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0]  wb_adr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0]  wb_dat_w,
    input  logic [3:0]   wb_sel,
    output logic [31:0]  wb_dat_r,
    output logic         wb_ack,

    // Line port: hold line_req (and the rest) until line_ack, which is high for one cycle; for a
    // read, line_rdata is valid with it. Word i of the line is bits [32*i +: 32].
    input  logic         line_req,
    input  logic         line_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [25:0]  line_addr,     // byte address in SDRAM; bits [3:0] are ignored
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [127:0] line_wdata,
    output logic [127:0] line_rdata,
    output logic         line_ack,

    output logic         sdram_cke,
    output logic         sdram_cs_n,
    output logic         sdram_ras_n,
    output logic         sdram_cas_n,
    output logic         sdram_we_n,
    output logic [1:0]   sdram_ba,
    output logic [12:0]  sdram_addr,
    output logic [1:0]   sdram_dqm,
    output logic [15:0]  sdram_dq_out,
    output logic         sdram_dq_oe,
    input  logic [15:0]  sdram_dq_in
);
    // Commands: {cs_n, ras_n, cas_n, we_n}
    typedef enum logic [3:0] {
        CMD_NOP       = 4'b0111,
        CMD_ACTIVE    = 4'b0011,
        CMD_READ      = 4'b0101,
        CMD_WRITE     = 4'b0100,
        CMD_PRECHARGE = 4'b0010,
        CMD_REFRESH   = 4'b0001,
        CMD_LOAD_MODE = 4'b0000
    } cmd_t;

    // Mode register: burst length 2, sequential, CAS latency 2, burst writes.
    localparam logic [12:0] MODE = 13'b000_0_00_010_0_001;

    typedef enum logic [3:0] {
        S_INIT_WAIT, S_INIT_PRECHARGE, S_INIT_REFRESH, S_INIT_MODE,
        S_IDLE, S_ACTIVATE, S_ACCESS, S_WRITE_BURST, S_READ_BURST, S_READ_DONE,
        S_REFRESH, S_DELAY
    } state_t;

    state_t      state, after_delay;
    logic [15:0] delay;
    logic [3:0]  init_refreshes;
    logic [15:0] refresh_count;
    logic        refresh_due, refresh_tick;
    assign refresh_tick = refresh_count == REFRESH_LAST;

    // Power-up value NOP: before the first reset edge an all-zero register would be LOAD MODE.
    // FPGA registers take this initial value when the device is configured.
    cmd_t        cmd = CMD_NOP;
    assign {sdram_cs_n, sdram_ras_n, sdram_cas_n, sdram_we_n} = cmd;
    assign sdram_cke = 1'b1;

    // The request being served.
    logic         req_line;    // 4 words for the line port, 1 for Wishbone
    logic         req_we;
    logic [127:0] req_data;
    logic [3:0]   req_sel;
    logic [1:0]   req_bank;
    logic [12:0]  req_row;
    logic [8:0]   req_col;     // in 32-bit words; the SDRAM column of word i is {req_col + i, 0}

    // Streaming: phase counts cycles from the first READ/WRITE (phase 0); command i goes out at
    // phase 2i; halfword h is written at phase h, or read (sampled) at phase READ_LATENCY + h.
    logic [3:0]   phase, beat;
    logic [2:0]   issued;
    logic [127:0] rbuf;
    logic [2:0]   words;
    logic [3:0]   last_beat;
    assign words     = req_line ? 3'd4 : 3'd1;
    assign last_beat = req_line ? 4'd7 : 4'd1;

    // After the access the bank needs time before the next ACTIVE: write recovery (2 cycles) plus
    // the auto-precharge (T_RP) after a write; the precharge after the burst for a read.
    localparam int READ_RECOVERY  = T_RP + 1;
    localparam int WRITE_RECOVERY = 2 + T_RP;

    // The same numbers as 16-bit values for the delay counter.
    localparam int REFRESH_LAST_INT = REFRESH_CYCLES - 1;
    localparam logic [15:0] INIT_DELAY          = INIT_CYCLES[15:0];
    localparam logic [15:0] REFRESH_LAST        = REFRESH_LAST_INT[15:0];
    localparam logic [15:0] RP_DELAY            = T_RP[15:0];
    localparam logic [15:0] RFC_DELAY           = T_RFC[15:0];
    localparam logic [15:0] MRD_DELAY           = T_MRD[15:0];
    localparam logic [15:0] WRITE_DELAY         = WRITE_RECOVERY[15:0];
    localparam logic [15:0] READ_RECOVERY_DELAY = READ_RECOVERY[15:0];
    // Read data capture. The DQ pins go into one register in the I/O cell (FAST_INPUT_REGISTER in
    // the .qsf) clocked on the FALLING edge: for halfword 0 that is 50 ns after the READ
    // (READ_LATENCY - 0.5 cycles), the middle of the window measured on this board (clean from
    // 50 to 70 ns, edge-ml-accelerator/boardtest). The burst buffer copies it at the next rising
    // edge. Board history: sampling the pins straight into the 8-slot buffer (fan-out 8, capture
    // time set by routing) corrupted line reads; a rising-edge I/O register at 60 ns read every
    // halfword one cycle late.
    localparam logic [3:0]  SAMPLE_FIRST        = READ_LATENCY[3:0];

    logic [15:0] dq_in_q;
    always_ff @(negedge clk) dq_in_q <= sdram_dq_in;

    // Column address for command i, with A10 (auto-precharge) on the last one.
    function automatic logic [12:0] column(input logic [8:0] col, input logic [2:0] i,
                                           input logic last);
        logic [8:0] c;
        c = col + {6'b0, i};
        return {2'b00, last, c, 1'b0};
    endfunction

    // Byte mask (DQM, active high = masked) for halfword h: a line writes everything.
    function automatic logic [1:0] mask(input logic line, input logic [3:0] sel, input logic [3:0] h);
        if (line) return 2'b00;
        return h[0] ? ~sel[3:2] : ~sel[1:0];
    endfunction

    always_ff @(posedge clk) begin
        if (rst) begin
            state          <= S_INIT_WAIT;
            delay          <= INIT_DELAY;
            cmd            <= CMD_NOP;
            sdram_dq_oe    <= 1'b0;
            sdram_dqm      <= 2'b11;
            wb_ack         <= 1'b0;
            line_ack       <= 1'b0;
            refresh_count  <= '0;
            refresh_due    <= 1'b0;
            init_refreshes <= '0;
        end else begin
            cmd         <= CMD_NOP;
            sdram_dq_oe <= 1'b0;
            wb_ack      <= 1'b0;
            line_ack    <= 1'b0;

            if (refresh_tick) begin
                refresh_count <= '0;
                refresh_due   <= 1'b1;
            end else begin
                refresh_count <= refresh_count + 16'd1;
            end

            case (state)
                // ---------------------------------------------------- power-up sequence
                S_INIT_WAIT: begin
                    if (delay == '0) state <= S_INIT_PRECHARGE;
                    else             delay <= delay - 16'd1;
                end
                S_INIT_PRECHARGE: begin
                    cmd         <= CMD_PRECHARGE;
                    sdram_addr  <= 13'b0_0100_0000_0000;   // A10 = 1: all banks
                    delay       <= RP_DELAY;
                    after_delay <= S_INIT_REFRESH;
                    state       <= S_DELAY;
                end
                S_INIT_REFRESH: begin
                    cmd            <= CMD_REFRESH;
                    init_refreshes <= init_refreshes + 4'd1;
                    delay          <= RFC_DELAY;
                    after_delay    <= (init_refreshes == 4'd7) ? S_INIT_MODE : S_INIT_REFRESH;
                    state          <= S_DELAY;
                end
                S_INIT_MODE: begin
                    cmd         <= CMD_LOAD_MODE;
                    sdram_ba    <= 2'b00;
                    sdram_addr  <= MODE;
                    delay       <= MRD_DELAY;
                    after_delay <= S_IDLE;
                    state       <= S_DELAY;
                end

                // ---------------------------------------------------- normal operation
                S_IDLE: begin
                    // Refresh first, then the caches' line port, then Wishbone.
                    if (refresh_due) begin
                        state <= S_REFRESH;
                    end else if (line_req && !line_ack) begin
                        req_line <= 1'b1;
                        req_we   <= line_we;
                        req_data <= line_wdata;
                        req_sel  <= 4'b1111;
                        req_bank <= line_addr[12:11];
                        req_row  <= line_addr[25:13];
                        req_col  <= {line_addr[10:4], 2'b00};
                        state    <= S_ACTIVATE;
                    end else if (wb_stb && !wb_ack) begin
                        req_line <= 1'b0;
                        req_we   <= wb_we;
                        req_data <= {96'b0, wb_dat_w};
                        req_sel  <= wb_sel;
                        req_bank <= wb_adr[12:11];
                        req_row  <= wb_adr[25:13];
                        req_col  <= wb_adr[10:2];
                        state    <= S_ACTIVATE;
                    end
                end
                S_REFRESH: begin
                    cmd         <= CMD_REFRESH;
                    refresh_due <= refresh_tick;   // don't lose a tick that lands right now
                    delay       <= RFC_DELAY;
                    after_delay <= S_IDLE;
                    state       <= S_DELAY;
                end
                S_ACTIVATE: begin
                    cmd        <= CMD_ACTIVE;
                    sdram_ba   <= req_bank;
                    sdram_addr <= req_row;
                    state      <= S_ACCESS;   // next cycle is 20 ns later: tRCD (15 ns) is met
                end
                S_ACCESS: begin              // phase 0: the first READ or WRITE
                    cmd        <= req_we ? CMD_WRITE : CMD_READ;
                    sdram_addr <= column(req_col, 3'd0, !req_line);
                    if (req_we) begin
                        sdram_dq_out <= req_data[15:0];
                        sdram_dqm    <= mask(req_line, req_sel, 4'd0);
                        sdram_dq_oe  <= 1'b1;
                    end else begin
                        sdram_dqm    <= 2'b00;
                    end
                    issued <= 3'd1;
                    phase  <= 4'd1;
                    beat   <= 4'd0;
                    state  <= req_we ? S_WRITE_BURST : S_READ_BURST;
                end
                S_WRITE_BURST: begin         // halfword `phase` this cycle
                    sdram_dq_out <= req_data[16*phase +: 16];
                    sdram_dqm    <= mask(req_line, req_sel, phase);
                    sdram_dq_oe  <= 1'b1;
                    if (!phase[0] && issued != words) begin
                        cmd        <= CMD_WRITE;
                        sdram_addr <= column(req_col, issued, issued == words - 3'd1);
                        issued     <= issued + 3'd1;
                    end
                    phase <= phase + 4'd1;
                    if (phase == last_beat) begin
                        if (req_line) line_ack <= 1'b1;
                        else          wb_ack   <= 1'b1;
                        delay       <= WRITE_DELAY;
                        after_delay <= S_IDLE;
                        state       <= S_DELAY;
                    end
                end
                S_READ_BURST: begin
                    if (!phase[0] && issued != words) begin
                        cmd        <= CMD_READ;
                        sdram_addr <= column(req_col, issued, issued == words - 3'd1);
                        issued     <= issued + 3'd1;
                    end
                    if (phase >= SAMPLE_FIRST) begin
                        rbuf[16*beat +: 16] <= dq_in_q;
                        beat <= beat + 4'd1;
                        if (beat == last_beat) state <= S_READ_DONE;
                    end
                    phase <= phase + 4'd1;
                end
                S_READ_DONE: begin
                    wb_dat_r    <= rbuf[31:0];
                    line_rdata  <= rbuf;
                    if (req_line) line_ack <= 1'b1;
                    else          wb_ack   <= 1'b1;
                    delay       <= READ_RECOVERY_DELAY;
                    after_delay <= S_IDLE;
                    state       <= S_DELAY;
                end
                S_DELAY: begin
                    if (delay <= 16'd1) state <= after_delay;
                    else                delay <= delay - 16'd1;
                end
                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
