// Framebuffer memory for the 8-bit VGA mode: 320 x 200 pixels of 8 bits (64,000 bytes).
//   write port: CPU, one 32-bit word (4 pixels) per write, with byte enables
//   read port:  display, one pixel (byte) per read, synchronous
// Simple dual-port (the CPU can't read it back): an M9K port is at most 18 bits wide in
// true dual-port mode, but a 32-bit write port is allowed in simple dual-port mode. Simulation
// uses the behavioural model; the FPGA build instantiates the block-RAM primitive: 63 M9Ks.
module fb8_ram #(
    parameter int PIXELS = 320 * 200
) (
    input  logic        clk,
    input  logic [3:0]  w_be,       // bytes to write (0: no write)
    input  logic [13:0] w_addr,     // word index
    input  logic [31:0] w_data,
    input  logic        r_en,
    input  logic [15:0] r_addr,     // pixel index
    output logic [7:0]  r_data
);
    localparam int WORDS = PIXELS / 4;

`ifdef VERILATOR
    logic [31:0] mem [WORDS];

    always_ff @(posedge clk) begin
        for (int i = 0; i < 4; i++)
            if (w_be[i]) mem[w_addr][8*i +: 8] <= w_data[8*i +: 8];
    end

    always_ff @(posedge clk) begin
        if (r_en) r_data <= mem[r_addr[15:2]][8*r_addr[1:0] +: 8];
    end

    initial begin
        for (int i = 0; i < WORDS; i++) mem[i] = '0;
    end
`else
    altsyncram #(
        .operation_mode                 ("DUAL_PORT"),
        .intended_device_family         ("MAX 10"),
        .lpm_type                       ("altsyncram"),
        .width_a                        (32),
        .widthad_a                      (14),
        .numwords_a                     (WORDS),
        .width_byteena_a                (4),
        .byte_size                      (8),
        .width_b                        (8),
        .widthad_b                      (16),
        .numwords_b                     (PIXELS),
        .outdata_reg_b                  ("UNREGISTERED"),
        .address_reg_b                  ("CLOCK1"),
        .clock_enable_input_a           ("BYPASS"),
        .clock_enable_input_b           ("NORMAL"),
        .clock_enable_output_b          ("BYPASS"),
        .power_up_uninitialized         ("FALSE")
    ) u_ram (
        .clock0     (clk),
        .address_a  (w_addr),
        .wren_a     (|w_be),
        .byteena_a  (w_be),
        .data_a     (w_data),
        .clock1     (clk),
        .clocken1   (r_en),
        .address_b  (r_addr),
        .q_b        (r_data)
    );
`endif
endmodule
