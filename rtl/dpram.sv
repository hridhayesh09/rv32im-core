// Dual-port RAM, the shape of an FPGA block RAM in true dual-port mode (MAX 10 M9K):
//   port A: read only (instruction fetch)
//   port B: read/write with byte enables (data)
// Both ports read synchronously: data appears the cycle after the address, and a port's output
// holds while its enable is low. Code and data share one memory, so a store through port B is
// visible to fetch through port A (FENCE.I works).
//
// Simulation (Verilator) uses the behavioural model below. For the FPGA, Intel's block-RAM
// primitive is instantiated directly: Quartus's automatic RAM inference either duplicated this
// memory (one copy per read port, twice the block RAM) or gave up on it.
module dpram #(
    parameter int WORDS        = 16384,  // 64 KB
    /* verilator lint_off UNUSEDPARAM */
    parameter     INIT_MIF     = "",     // FPGA: initial contents (.mif), e.g. the boot ROM
    /* verilator lint_on UNUSEDPARAM */
    parameter     INIT_PLUSARG = ""      // simulation: hex file named by +<arg>=<path>
) (
    input  logic        clk,

    input  logic        a_en,
    /* verilator lint_off UNUSEDSIGNAL */
    input  logic [31:0] a_addr,     // byte addresses; only the word index bits are used
    input  logic [31:0] b_addr,
    /* verilator lint_on UNUSEDSIGNAL */
    output logic [31:0] a_rdata,

    input  logic        b_en,
    input  logic [3:0]  b_we,
    input  logic [31:0] b_wdata,
    output logic [31:0] b_rdata
);
    localparam int AW = $clog2(WORDS);

`ifdef VERILATOR
    logic [31:0] mem [WORDS];

    always_ff @(posedge clk) begin
        if (a_en) a_rdata <= mem[a_addr[AW+1:2]];
    end

    always_ff @(posedge clk) begin
        if (b_en) begin
            for (int i = 0; i < 4; i++) begin
                if (b_we[i]) mem[b_addr[AW+1:2]][8*i +: 8] <= b_wdata[8*i +: 8];
            end
            b_rdata <= mem[b_addr[AW+1:2]];
        end
    end

    initial begin
        string path;
        if (INIT_PLUSARG != "" && $value$plusargs({INIT_PLUSARG, "=%s"}, path)) begin
            $readmemh(path, mem);
        end
    end
`else
    // Port A on clock0 with clocken0 = a_en, port B on clock1 (the same clock) with
    // clocken1 = b_en: each port's address register and output hold while its enable is low.
    altsyncram #(
        .operation_mode                 ("BIDIR_DUAL_PORT"),
        .intended_device_family         ("MAX 10"),
        .lpm_type                       ("altsyncram"),
        .width_a                        (32),
        .widthad_a                      (AW),
        .numwords_a                     (WORDS),
        .width_b                        (32),
        .widthad_b                      (AW),
        .numwords_b                     (WORDS),
        .width_byteena_a                (1),
        .width_byteena_b                (4),
        .byte_size                      (8),
        .outdata_reg_a                  ("UNREGISTERED"),
        .outdata_reg_b                  ("UNREGISTERED"),
        .address_reg_b                  ("CLOCK1"),
        .indata_reg_b                   ("CLOCK1"),
        .wrcontrol_wraddress_reg_b      ("CLOCK1"),
        .byteena_reg_b                  ("CLOCK1"),
        .clock_enable_input_a           ("NORMAL"),
        .clock_enable_input_b           ("NORMAL"),
        .clock_enable_output_a          ("BYPASS"),
        .clock_enable_output_b          ("BYPASS"),
        .read_during_write_mode_port_b  ("NEW_DATA_NO_NBE_READ"),
        .init_file                      (INIT_MIF == "" ? "UNUSED" : INIT_MIF),
        .power_up_uninitialized         (INIT_MIF == "" ? "TRUE" : "FALSE")
    ) u_ram (
        .clock0     (clk),
        .clocken0   (a_en),
        .address_a  (a_addr[AW+1:2]),
        .wren_a     (1'b0),
        .data_a     (32'b0),
        .q_a        (a_rdata),
        .clock1     (clk),
        .clocken1   (b_en),
        .address_b  (b_addr[AW+1:2]),
        .wren_b     (b_we != 4'b0000),
        .byteena_b  (b_we),
        .data_b     (b_wdata),
        .q_b        (b_rdata)
    );
`endif
endmodule
