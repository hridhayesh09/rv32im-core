// Framebuffer memory: 320 x 240 pixels of 4 bits, true dual-port.
//   port A: display (read only)
//   port B: CPU (read/write, one pixel per address)
// Synchronous reads on both ports. Simulation uses the behavioural model; the FPGA build
// instantiates the block-RAM primitive (as in dpram.sv), 4 bits wide: 38 M9Ks.
module fb_ram #(
    parameter int PIXELS = 320 * 240
) (
    input  logic        clk,
    input  logic        a_en,
    input  logic [16:0] a_addr,
    output logic [3:0]  a_rdata,
    input  logic        b_en,
    input  logic        b_we,
    input  logic [16:0] b_addr,
    input  logic [3:0]  b_wdata,
    output logic [3:0]  b_rdata
);
`ifdef VERILATOR
    logic [3:0] mem [PIXELS];

    always_ff @(posedge clk) begin
        if (a_en) a_rdata <= mem[a_addr];
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            if (b_we) mem[b_addr] <= b_wdata;
            b_rdata <= mem[b_addr];
        end
    end

    initial begin
        for (int i = 0; i < PIXELS; i++) mem[i] = 4'd0;
    end
`else
    altsyncram #(
        .operation_mode                 ("BIDIR_DUAL_PORT"),
        .intended_device_family         ("MAX 10"),
        .lpm_type                       ("altsyncram"),
        .width_a                        (4),
        .widthad_a                      (17),
        .numwords_a                     (PIXELS),
        .width_b                        (4),
        .widthad_b                      (17),
        .numwords_b                     (PIXELS),
        .outdata_reg_a                  ("UNREGISTERED"),
        .outdata_reg_b                  ("UNREGISTERED"),
        .address_reg_b                  ("CLOCK1"),
        .indata_reg_b                   ("CLOCK1"),
        .wrcontrol_wraddress_reg_b      ("CLOCK1"),
        .clock_enable_input_a           ("NORMAL"),
        .clock_enable_input_b           ("NORMAL"),
        .clock_enable_output_a          ("BYPASS"),
        .clock_enable_output_b          ("BYPASS"),
        .read_during_write_mode_port_b  ("NEW_DATA_NO_NBE_READ"),
        .power_up_uninitialized         ("FALSE")
    ) u_ram (
        .clock0     (clk),
        .clocken0   (a_en),
        .address_a  (a_addr),
        .wren_a     (1'b0),
        .data_a     (4'b0),
        .q_a        (a_rdata),
        .clock1     (clk),
        .clocken1   (b_en),
        .address_b  (b_addr),
        .wren_b     (b_we),
        .data_b     (b_wdata),
        .q_b        (b_rdata)
    );
`endif
endmodule
