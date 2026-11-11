// DE10-Lite top level: the SoC on the board's pins.
//
//   Clock      MAX10_CLK1_50 (50 MHz), used directly by the whole SoC
//   Reset      at power-up, or hold KEY0 and KEY1 together
//   UART       Arduino header: IO0 = RX into the FPGA, IO1 = TX out of the FPGA
//              (the DE10-Lite has no USB serial port: use a 3.3 V USB-serial adapter)
//   VGA        640x480 at 60 Hz on the VGA connector
//   SDRAM      DRAM_CLK is the inverted system clock, so the chip samples each command half a
//              cycle after the controller sends it. Read data is then sampled 60 ns after READ;
//              on this board (edge-ml-accelerator/boardtest) reads were clean from 50 to 70 ns.
// Build configurations (set per Quartus revision, see rv32im_soc.qsf / rv32im_cpu.qsf):
//   full SoC: NPU, no caches (meets timing with the NPU)
//   CPU-only: no NPU, instruction and data caches (programs can run from SDRAM)
module de10lite_top #(
    parameter bit NPU         = 1'b1,
    parameter int ICACHE_SIZE = 0,
    parameter int ICACHE_WAYS = 1,
    parameter int DCACHE_SIZE = 0,
    parameter int DCACHE_WAYS = 1
) (
    input  logic        MAX10_CLK1_50,
    input  logic [1:0]  KEY,
    input  logic [9:0]  SW,
    output logic [9:0]  LEDR,
    output logic [7:0]  HEX0, HEX1, HEX2, HEX3, HEX4, HEX5,
    inout  wire  [15:0] ARDUINO_IO,

    output logic [3:0]  VGA_R,
    output logic [3:0]  VGA_G,
    output logic [3:0]  VGA_B,
    output logic        VGA_HS,
    output logic        VGA_VS,

    output logic        DRAM_CLK,
    output logic        DRAM_CKE,
    output logic        DRAM_CS_N,
    output logic        DRAM_RAS_N,
    output logic        DRAM_CAS_N,
    output logic        DRAM_WE_N,
    output logic [1:0]  DRAM_BA,
    output logic [12:0] DRAM_ADDR,
    output logic        DRAM_LDQM,
    output logic        DRAM_UDQM,
    inout  wire  [15:0] DRAM_DQ
);
    logic clk;
    assign clk = MAX10_CLK1_50;

    // ---------------------------------------------------------------- reset
    // Power-on: the counter starts at 0 when the FPGA is configured and holds the SoC in reset
    // for 2^16 cycles (1.3 ms). Both keys pressed (active low) restart it.
    logic [16:0] por_count = '0;
    logic [1:0]  keys_sync = 2'b11;
    always_ff @(posedge clk) begin
        keys_sync <= KEY;
        if (keys_sync == 2'b00)  por_count <= '0;
        else if (!por_count[16]) por_count <= por_count + 17'd1;
    end
    logic rst;
    assign rst = !por_count[16];

    // ---------------------------------------------------------------- SoC
    logic [47:0] hex_n;
    logic [15:0] dq_out;
    logic        dq_oe;
    logic [1:0]  dqm;
    logic        txd;

    soc #(
        .CLK_HZ       (32'd50_000_000),
        .UART_DIVISOR (434),                         // 115200 baud
        .BOOTROM_FILE ("../../build/sw/bootrom.mif"), // from `make sw`  
        .NPU          (NPU),
        .ICACHE_SIZE  (ICACHE_SIZE),
        .ICACHE_WAYS  (ICACHE_WAYS),
        .DCACHE_SIZE  (DCACHE_SIZE),
        .DCACHE_WAYS  (DCACHE_WAYS)
    ) u_soc (
        .clk, .rst,
        .txd,
        .rxd          (ARDUINO_IO[0]),
        .ledr         (LEDR),
        .sw           (SW),
        .key_n        (KEY),
        .hex_n,
        .vga_r        (VGA_R),
        .vga_g        (VGA_G),
        .vga_b        (VGA_B),
        .vga_hs       (VGA_HS),
        .vga_vs       (VGA_VS),
        .sdram_cke    (DRAM_CKE),
        .sdram_cs_n   (DRAM_CS_N),
        .sdram_ras_n  (DRAM_RAS_N),
        .sdram_cas_n  (DRAM_CAS_N),
        .sdram_we_n   (DRAM_WE_N),
        .sdram_ba     (DRAM_BA),
        .sdram_addr   (DRAM_ADDR),
        .sdram_dqm    (dqm),
        .sdram_dq_out (dq_out),
        .sdram_dq_oe  (dq_oe),
        .sdram_dq_in  (DRAM_DQ)
    );

    assign {HEX5, HEX4, HEX3, HEX2, HEX1, HEX0} = hex_n;
    assign DRAM_CLK  = ~clk;
    assign DRAM_LDQM = dqm[0];
    assign DRAM_UDQM = dqm[1];
    assign DRAM_DQ   = dq_oe ? dq_out : 16'bz;

    // Arduino header: IO1 is the UART output; everything else is an input (IO0 = UART input).
    assign ARDUINO_IO = {14'bz, txd, 1'bz};
endmodule
