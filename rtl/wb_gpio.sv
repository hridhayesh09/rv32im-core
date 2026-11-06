// GPIO for the DE10-Lite as a Wishbone slave.
//
//   +0x00 LEDS       10 red LEDs, read/write (1 = on)
//   +0x04 SWITCHES   10 slide switches, read only (1 = up)
//   +0x08 KEYS       2 push buttons, read only (1 = pressed; the board's buttons are active low)
//   +0x10..+0x24     HEX0..HEX5: the six 7-segment displays, one register each, read/write.
//                    Bits 6:0 = segments a..g, bit 7 = decimal point (1 = lit; the board's
//                    displays are active low, inverted here).
module wb_gpio (
    input  logic        clk,
    input  logic        rst,
    input  logic        wb_stb,
    input  logic        wb_we,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] wb_adr,     // only bits [5:2] select a register
    input  logic [31:0] wb_dat_w,
    input  logic [3:0]  wb_sel,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] wb_dat_r,
    output logic        wb_ack,
    output logic [9:0]  ledr,
    input  logic [9:0]  sw,
    input  logic [1:0]  key_n,
    output logic [47:0] hex_n       // HEX5..HEX0, 8 bits each, active low as on the board
);
    logic [7:0] hex [6];
    logic [9:0] sw_sync1, sw_sync2;
    logic [1:0] key_sync1, key_sync2;
    logic       access;
    assign access = wb_stb && !wb_ack;

    logic [2:0] hex_idx;   // which display, for addresses +0x10..+0x24
    assign hex_idx = 3'(wb_adr[5:2] - 4'd4);

    // Switches and buttons are asynchronous inputs: two flip-flops each before use.
    always_ff @(posedge clk) begin
        sw_sync1  <= sw;
        sw_sync2  <= sw_sync1;
        key_sync1 <= ~key_n;
        key_sync2 <= key_sync1;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            ledr   <= '0;
            hex    <= '{default: '0};
            wb_ack <= 1'b0;
        end else begin
            wb_ack <= access;
            if (access && wb_we) begin
                if (wb_adr[5:2] == 4'd0) begin
                    if (wb_sel[0]) ledr[7:0] <= wb_dat_w[7:0];
                    if (wb_sel[1]) ledr[9:8] <= wb_dat_w[9:8];
                end else if (wb_adr[5:2] >= 4'd4 && wb_adr[5:2] <= 4'd9 && wb_sel[0]) begin
                    hex[hex_idx] <= wb_dat_w[7:0];
                end
            end
            if (access && !wb_we) begin
                case (wb_adr[5:2])
                    4'd0:    wb_dat_r <= {22'b0, ledr};
                    4'd1:    wb_dat_r <= {22'b0, sw_sync2};
                    4'd2:    wb_dat_r <= {30'b0, key_sync2};
                    4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9:
                             wb_dat_r <= {24'b0, hex[hex_idx]};
                    default: wb_dat_r <= '0;
                endcase
            end
        end
    end

    always_comb begin
        for (int i = 0; i < 6; i++) hex_n[8*i +: 8] = ~hex[i];
    end
endmodule
