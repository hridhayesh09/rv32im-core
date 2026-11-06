// SDRAM controller for the DE10-Lite's IS42S16320 (64 MB: 4 banks x 8192 rows x 1024 columns
// x 16 bits), as a Wishbone slave. One 32-bit word = a burst of 2 halfwords.
//
// Kept simple on purpose:
//   - every access opens the row (ACTIVE), reads or writes with auto-precharge, and the row is
//     closed again afterwards ("closed page"); no row is ever left open between accesses;
//   - refresh happens between accesses, every REFRESH_CYCLES;
//   - timings are given in clock cycles for a 50 MHz clock (20 ns); see the defaults.
//
// Byte address -> SDRAM: [12:11] bank, [25:13] row, [10:2] column / 2. Bits [31:26] are ignored.
// Commands go out of registers, so the chip sees each one at the clock edge after it's set.
module sdram_ctrl #(
    parameter int INIT_CYCLES    = 10000,  // power-up wait: >= 100 us (200 us at 50 MHz)
    parameter int REFRESH_CYCLES = 380,    // 64 ms / 8192 rows = 7.8 us = 390 cycles; some margin
    parameter int T_RP           = 1,      // PRECHARGE -> next command: 15 ns
    parameter int T_RFC          = 3,      // REFRESH -> next command: 60 ns
    parameter int T_MRD          = 2,      // LOAD MODE -> next command: 2 cycles
    parameter int READ_LATENCY   = 3       // cycles from READ to sampling the first halfword:
                                           //   CAS latency 2, plus 1 for the registered command
) (
    input  logic        clk,
    input  logic        rst,

    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,
    /* verilator lint_on UNUSEDSIGNAL */
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,

    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_addr,
    output logic [1:0]  sdram_dqm,
    output logic [15:0] sdram_dq_out,
    output logic        sdram_dq_oe,
    input  logic [15:0] sdram_dq_in
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
        S_IDLE, S_ACTIVATE, S_ACCESS, S_WRITE_HIGH, S_READ_WAIT, S_READ_HIGH,
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
    logic        req_we;
    logic [31:0] req_data;
    logic [3:0]  req_sel;
    logic [1:0]  req_bank;
    logic [12:0] req_row;
    logic [8:0]  req_col;   // in 32-bit words; the SDRAM column is {req_col, 0}

    // After a closed-page access, the bank needs time before the next ACTIVE: for a write, the
    // write recovery (2 cycles) plus the auto-precharge (T_RP); for a read, the precharge after
    // the burst. And ACTIVE-to-ACTIVE must be at least 60 ns (3 cycles). These delays cover both.
    localparam int READ_RECOVERY  = T_RP + 1;
    localparam int WRITE_RECOVERY = 2 + T_RP;

    // The same numbers as 16-bit values for the delay counter.
    localparam int REFRESH_LAST_INT = REFRESH_CYCLES - 1;
    localparam int READ_DELAY_INT   = READ_LATENCY - 1;
    localparam logic [15:0] INIT_DELAY          = INIT_CYCLES[15:0];
    localparam logic [15:0] REFRESH_LAST        = REFRESH_LAST_INT[15:0];
    localparam logic [15:0] RP_DELAY            = T_RP[15:0];
    localparam logic [15:0] RFC_DELAY           = T_RFC[15:0];
    localparam logic [15:0] MRD_DELAY           = T_MRD[15:0];
    localparam logic [15:0] READ_DELAY          = READ_DELAY_INT[15:0];
    localparam logic [15:0] WRITE_DELAY         = WRITE_RECOVERY[15:0];
    localparam logic [15:0] READ_RECOVERY_DELAY = READ_RECOVERY[15:0];

    always_ff @(posedge clk) begin
        if (rst) begin
            state          <= S_INIT_WAIT;
            delay          <= INIT_DELAY;
            cmd            <= CMD_NOP;
            sdram_dq_oe    <= 1'b0;
            sdram_dqm      <= 2'b11;
            wb_ack         <= 1'b0;
            refresh_count  <= '0;
            refresh_due    <= 1'b0;
            init_refreshes <= '0;
        end else begin
            cmd         <= CMD_NOP;
            sdram_dq_oe <= 1'b0;
            wb_ack      <= 1'b0;

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
                    if (refresh_due) begin
                        state <= S_REFRESH;
                    end else if (wb_stb && !wb_ack) begin
                        req_we   <= wb_we;
                        req_data <= wb_dat_w;
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
                S_ACCESS: begin
                    cmd        <= req_we ? CMD_WRITE : CMD_READ;
                    sdram_addr <= {2'b00, 1'b1, req_col, 1'b0};   // A10 = 1: auto-precharge
                    if (req_we) begin
                        sdram_dq_out <= req_data[15:0];
                        sdram_dqm    <= ~req_sel[1:0];
                        sdram_dq_oe  <= 1'b1;
                        state        <= S_WRITE_HIGH;
                    end else begin
                        sdram_dqm    <= 2'b00;
                        delay        <= READ_DELAY;
                        state        <= S_READ_WAIT;
                    end
                end
                S_WRITE_HIGH: begin                 // second halfword of the burst
                    sdram_dq_out <= req_data[31:16];
                    sdram_dqm    <= ~req_sel[3:2];
                    sdram_dq_oe  <= 1'b1;
                    wb_ack       <= 1'b1;
                    delay        <= WRITE_DELAY;
                    after_delay  <= S_IDLE;
                    state        <= S_DELAY;
                end
                S_READ_WAIT: begin
                    if (delay == '0) begin
                        wb_dat_r[15:0] <= sdram_dq_in;
                        state          <= S_READ_HIGH;
                    end else begin
                        delay <= delay - 16'd1;
                    end
                end
                S_READ_HIGH: begin
                    wb_dat_r[31:16] <= sdram_dq_in;
                    wb_ack          <= 1'b1;
                    delay           <= READ_RECOVERY_DELAY;
                    after_delay     <= S_IDLE;
                    state           <= S_DELAY;
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
