// Simple dual-port RAM for the caches: one write port with byte enables, one read port with a
// read enable (the output holds while it's low). Synchronous read: data the cycle after.
// Simulation and the ASIC flow (ASIC defined: flip-flops) use the behavioural model; the FPGA
// build instantiates the block-RAM primitive (automatic inference was unreliable for this shape,
// see dpram.sv).
`ifdef VERILATOR
 `define CACHE_RAM_BEHAVIOURAL
`elsif ASIC
 `define CACHE_RAM_BEHAVIOURAL
`endif
module cache_ram #(
    parameter int WIDTH = 32,               // a multiple of 8
    parameter int DEPTH = 256
) (
    input  logic                     clk,
    input  logic [WIDTH/8-1:0]       we,     // byte enables
    input  logic [$clog2(DEPTH)-1:0] waddr,
    input  logic [WIDTH-1:0]         wdata,
    input  logic                     re,
    input  logic [$clog2(DEPTH)-1:0] raddr,
    output logic [WIDTH-1:0]         rdata
);
`ifdef CACHE_RAM_BEHAVIOURAL
    logic [WIDTH-1:0] mem [DEPTH];

    always_ff @(posedge clk) begin
        for (int i = 0; i < WIDTH / 8; i++) begin
            if (we[i]) mem[waddr][8*i +: 8] <= wdata[8*i +: 8];
        end
        if (re) rdata <= mem[raddr];
    end
`else
    localparam int AW = $clog2(DEPTH);

    altsyncram #(
        .operation_mode                     ("DUAL_PORT"),
        .intended_device_family             ("MAX 10"),
        .lpm_type                           ("altsyncram"),
        .width_a                            (WIDTH),
        .widthad_a                          (AW),
        .numwords_a                         (DEPTH),
        .width_b                            (WIDTH),
        .widthad_b                          (AW),
        .numwords_b                         (DEPTH),
        .width_byteena_a                    (WIDTH / 8),
        .byte_size                          (8),
        .outdata_reg_b                      ("UNREGISTERED"),
        .address_reg_b                      ("CLOCK0"),
        .rdcontrol_reg_b                    ("CLOCK0"),
        .read_during_write_mode_mixed_ports ("OLD_DATA"),
        .power_up_uninitialized             ("TRUE")
    ) u_ram (
        .clock0         (clk),
        .wren_a         (we != '0),
        .byteena_a      (we),
        .address_a      (waddr),
        .data_a         (wdata),
        .rden_b         (re),
        .address_b      (raddr),
        .q_b            (rdata)
    );
`endif
endmodule
