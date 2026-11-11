// UART (8 data bits, no parity, 1 stop bit) as a Wishbone slave.
//
//   +0x0 DATA     write: send a byte (ignored unless STATUS.tx_ready)
//                 read:  the oldest received byte, taken out of the receive FIFO
//   +0x4 STATUS   bit 0 tx_ready, bit 1 rx_valid (the FIFO isn't empty), bit 2 rx_overrun (a
//                 byte arrived while the FIFO was full and was lost; cleared by reading DATA)
//   +0x8 DIVISOR  clock cycles per bit (clock frequency / baud rate), read/write
//
// Received bytes wait in a FIFO (RX_DEPTH bytes), so they aren't lost while the CPU is busy for
// a while (drawing a frame, or a cache miss while a 2 Mbaud upload streams in).
//
// Wishbone: single-cycle registered acknowledge (ack the cycle after stb).
module wb_uart #(
    parameter logic [15:0] DEFAULT_DIVISOR = 16'd434,  // 50 MHz / 115200 baud
    parameter int          RX_DEPTH        = 64        // power of 2
) (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,     // only bits [3:2] select a register
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,
    output logic        txd,
    input  logic        rxd
);
    logic [15:0] divisor;

    // ---------------------------------------------------------------- transmit
    logic [9:0]  tx_shift;    // stop bit, 8 data bits (LSB first), start bit
    logic [3:0]  tx_bits;     // bits still to send; 0 = idle
    logic [15:0] tx_count;
    logic        tx_ready;
    assign tx_ready = tx_bits == 4'd0;
    assign txd = tx_ready ? 1'b1 : tx_shift[0];

    // ---------------------------------------------------------------- receive
    logic [1:0]  rxd_sync;    // two flip-flops: rxd comes from outside this clock domain
    logic        rx_in;
    assign rx_in = rxd_sync[1];

    logic        rx_busy;
    logic [3:0]  rx_bit;      // 0 = start bit, 1..8 = data bits, 9 = stop bit
    logic [15:0] rx_count;
    logic [7:0]  rx_shift;
    logic        rx_valid, rx_overrun;

    // Receive FIFO: write pointer, read pointer, one extra bit each to tell full from empty.
    localparam int RW = $clog2(RX_DEPTH);
    logic [7:0]  rx_fifo [RX_DEPTH];
    logic [RW:0] rx_wp, rx_rp;
    logic        rx_push, rx_full;
    logic [7:0]  rx_head;
    assign rx_valid = rx_wp != rx_rp;
    assign rx_head  = rx_fifo[rx_rp[RW-1:0]];

    // ---------------------------------------------------------------- bus access
    logic access, write_data, read_data;
    assign access     = wb_stb && !wb_ack;   // first cycle of a bus access
    assign write_data = access && wb_we && wb_adr[3:2] == 2'd0 && wb_sel[0];
    assign read_data  = access && !wb_we && wb_adr[3:2] == 2'd0;

    always_ff @(posedge clk) begin
        if (rst) begin
            divisor    <= DEFAULT_DIVISOR;
            tx_bits    <= '0;
            rxd_sync   <= 2'b11;
            rx_busy    <= 1'b0;
            rx_wp      <= '0;
            rx_rp      <= '0;
            rx_overrun <= 1'b0;
            wb_ack     <= 1'b0;
        end else begin
            wb_ack <= access;

            // Register reads.
            if (access && !wb_we) begin
                case (wb_adr[3:2])
                    2'd0:    wb_dat_r <= {24'b0, rx_head};
                    2'd1:    wb_dat_r <= {29'b0, rx_overrun, rx_valid, tx_ready};
                    2'd2:    wb_dat_r <= {16'b0, divisor};
                    default: wb_dat_r <= '0;
                endcase
            end
            if (access && wb_we && wb_adr[3:2] == 2'd2 && wb_sel[1:0] == 2'b11) begin
                divisor <= wb_dat_w[15:0];
            end

            // Transmit: load a byte, then shift one bit out every `divisor` cycles.
            if (write_data && tx_ready) begin
                tx_shift <= {1'b1, wb_dat_w[7:0], 1'b0};
                tx_bits  <= 4'd10;
                tx_count <= divisor - 16'd1;
            end else if (!tx_ready) begin
                if (tx_count == '0) begin
                    tx_shift <= {1'b1, tx_shift[9:1]};
                    tx_bits  <= tx_bits - 4'd1;
                    tx_count <= divisor - 16'd1;
                end else begin
                    tx_count <= tx_count - 16'd1;
                end
            end

            // Receive: on a falling edge wait half a bit to reach the middle of the start bit,
            // then sample every `divisor` cycles.
            rxd_sync <= {rxd_sync[0], rxd};
            if (read_data) begin
                if (rx_valid) rx_rp <= rx_rp + 1'b1;
                rx_overrun <= 1'b0;
            end
            if (rx_push) begin
                if (rx_full) rx_overrun <= 1'b1;
                else         rx_wp      <= rx_wp + 1'b1;
            end
            if (!rx_busy) begin
                if (!rx_in) begin
                    rx_busy  <= 1'b1;
                    rx_bit   <= 4'd0;
                    rx_count <= divisor >> 1;
                end
            end else if (rx_count != '0) begin
                rx_count <= rx_count - 16'd1;
            end else begin
                rx_count <= divisor - 16'd1;
                if (rx_bit == 4'd0) begin
                    if (rx_in) rx_busy <= 1'b0;          // a glitch, not a start bit
                    else       rx_bit  <= 4'd1;
                end else if (rx_bit <= 4'd8) begin
                    rx_shift <= {rx_in, rx_shift[7:1]};  // LSB first
                    rx_bit   <= rx_bit + 4'd1;
                end else begin                           // stop bit (rx_push)
                    rx_busy <= 1'b0;
                end
            end
        end
    end

    // A byte is complete when its stop bit is sampled high.
    assign rx_push = rx_busy && rx_count == '0 && rx_bit > 4'd8 && rx_in;
    assign rx_full = rx_wp[RW] != rx_rp[RW] && rx_wp[RW-1:0] == rx_rp[RW-1:0];

    always_ff @(posedge clk) begin
        if (rx_push && !rx_full) rx_fifo[rx_wp[RW-1:0]] <= rx_shift;
    end
endmodule
