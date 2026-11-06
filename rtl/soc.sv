// The system-on-chip: core + boot ROM + on-chip RAM + Wishbone bus with peripherals.
//
//   0x0000_0000  boot ROM, 8 KB      (tightly coupled: no wait states; reset address)
//   0x1000_0000  UART                (Wishbone)
//   0x1000_1000  timer               (Wishbone)
//   0x1000_2000  GPIO                (Wishbone)
//   0x4000_0000  SDRAM, 64 MB        (Wishbone; the first access waits for the 200 us init)
//   0x8000_0000  on-chip RAM, 64 KB  (tightly coupled: no wait states)
//   anything else                    (Wishbone; reads 0, writes ignored)
//
// Instructions can be fetched from the boot ROM and the RAM. Data accesses to ROM and RAM take
// one cycle like in Stage 1; bus accesses freeze the core until the device acknowledges.
module soc #(
    parameter logic [31:0] CLK_HZ       = 32'd50_000_000,
    parameter int          UART_DIVISOR = 434,            // CLK_HZ / 115200
    parameter string       BOOTROM_FILE = "",             // hex images for synthesis
    parameter string       RAM_FILE     = ""
) (
    input  logic        clk,
    input  logic        rst,
    output logic        txd,
    input  logic        rxd,
    output logic [9:0]  ledr,
    input  logic [9:0]  sw,
    input  logic [1:0]  key_n,
    output logic [47:0] hex_n,

    output logic        sdram_cke,
    output logic        sdram_cs_n,
    output logic        sdram_ras_n,
    output logic        sdram_cas_n,
    output logic        sdram_we_n,
    output logic [1:0]  sdram_ba,
    output logic [12:0] sdram_addr,
    output logic [1:0]  sdram_dqm,
    output logic [15:0] sdram_dq_out,   // DQ is bidirectional on the board; the top level
    output logic        sdram_dq_oe,    // turns these three into one inout bus
    input  logic [15:0] sdram_dq_in
);
    // ---------------------------------------------------------------- core

    logic        imem_en, dmem_en, dmem_stall;
    logic [3:0]  dmem_we;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;

    /* verilator lint_off PINCONNECTEMPTY */
    core #(.RESET_PC(32'h0000_0000)) u_core (
        .clk, .rst,
        .imem_en, .imem_addr, .imem_rdata,
        .dmem_en, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_rdata, .dmem_stall,
        .rvfi_valid(), .rvfi_pc(), .rvfi_insn(), .rvfi_trap(), .rvfi_rd(), .rvfi_rd_wdata(),
        .rvfi_mem_read(), .rvfi_mem_wmask(), .rvfi_mem_addr(), .rvfi_mem_wdata()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------------------------------------------------------- memories

    typedef enum logic [1:0] { TARGET_ROM, TARGET_RAM, TARGET_BUS } target_t;

    function automatic target_t decode(input logic [31:0] addr);
        if (addr[31])               return TARGET_RAM;
        else if (addr[31:28] == '0) return TARGET_ROM;
        else                        return TARGET_BUS;
    endfunction

    logic [31:0] rom_a_rdata, rom_b_rdata, ram_a_rdata, ram_b_rdata;
    target_t     fetch_target_q, data_target, data_target_q;
    assign data_target = decode(dmem_addr);

    dpram #(.WORDS(2048), .INIT_FILE(BOOTROM_FILE), .INIT_PLUSARG("bootrom")) u_bootrom (
        .clk,
        .a_en    (imem_en && decode(imem_addr) == TARGET_ROM),
        .a_addr  (imem_addr),
        .a_rdata (rom_a_rdata),
        .b_en    (dmem_en && data_target == TARGET_ROM),
        .b_we    (4'b0000),               // read only
        .b_addr  (dmem_addr),
        .b_wdata ('0),
        .b_rdata (rom_b_rdata)
    );

    dpram #(.WORDS(16384), .INIT_FILE(RAM_FILE), .INIT_PLUSARG("program")) u_ram (
        .clk,
        .a_en    (imem_en && decode(imem_addr) == TARGET_RAM),
        .a_addr  (imem_addr),
        .a_rdata (ram_a_rdata),
        .b_en    (dmem_en && data_target == TARGET_RAM),
        .b_we    (data_target == TARGET_RAM ? dmem_we : 4'b0000),
        .b_addr  (dmem_addr),
        .b_wdata (dmem_wdata),
        .b_rdata (ram_b_rdata)
    );

    // Remember where the access in flight went, to pick its read data next cycle.
    always_ff @(posedge clk) begin
        if (imem_en) fetch_target_q <= decode(imem_addr);
        if (dmem_en) data_target_q  <= data_target;
    end

    assign imem_rdata = (fetch_target_q == TARGET_RAM) ? ram_a_rdata : rom_a_rdata;

    // ---------------------------------------------------------------- Wishbone bridge
    // A bus access is captured when the core sends it (instruction leaving MEM) and driven on
    // the bus while that instruction waits in WB; the core is frozen until the slave acks.

    logic        bus_stb, bus_we, bus_ack;
    logic [31:0] bus_adr, bus_dat_w, bus_dat_r;
    logic [3:0]  bus_sel;

    always_ff @(posedge clk) begin
        if (rst) begin
            bus_stb <= 1'b0;
        end else if (dmem_en && data_target == TARGET_BUS) begin
            bus_stb   <= 1'b1;
            bus_we    <= dmem_we != 4'b0000;
            bus_adr   <= dmem_addr;
            bus_dat_w <= dmem_wdata;
            bus_sel   <= (dmem_we != 4'b0000) ? dmem_we : 4'b1111;
        end else if (bus_ack) begin
            bus_stb <= 1'b0;
        end
    end

    assign dmem_stall = bus_stb && !bus_ack;

    always_comb begin
        case (data_target_q)
            TARGET_ROM: dmem_rdata = rom_b_rdata;
            TARGET_RAM: dmem_rdata = ram_b_rdata;
            default:    dmem_rdata = bus_dat_r;
        endcase
    end

    // ---------------------------------------------------------------- Wishbone interconnect

    typedef enum logic [2:0] { SLAVE_UART, SLAVE_TIMER, SLAVE_GPIO, SLAVE_SDRAM, SLAVE_NONE } slave_t;
    slave_t slave;
    always_comb begin
        if (bus_adr[31:16] == 16'h1000) begin
            case (bus_adr[15:12])
                4'h0:    slave = SLAVE_UART;
                4'h1:    slave = SLAVE_TIMER;
                4'h2:    slave = SLAVE_GPIO;
                default: slave = SLAVE_NONE;
            endcase
        end else if (bus_adr[31:28] == 4'h4) begin
            slave = SLAVE_SDRAM;
        end else begin
            slave = SLAVE_NONE;
        end
    end

    logic [31:0] uart_dat_r, timer_dat_r, gpio_dat_r, sdram_dat_r;
    logic        uart_ack, timer_ack, gpio_ack, sdram_ack, none_ack;

    wb_uart #(.DEFAULT_DIVISOR(16'(UART_DIVISOR))) u_uart (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_UART),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (uart_dat_r),
        .wb_ack   (uart_ack),
        .txd, .rxd
    );

    wb_timer #(.CLK_HZ(CLK_HZ)) u_timer (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_TIMER),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (timer_dat_r),
        .wb_ack   (timer_ack)
    );

    wb_gpio u_gpio (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_GPIO),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (gpio_dat_r),
        .wb_ack   (gpio_ack),
        .ledr, .sw, .key_n, .hex_n
    );

    sdram_ctrl u_sdram (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_SDRAM),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (sdram_dat_r),
        .wb_ack   (sdram_ack),
        .sdram_cke, .sdram_cs_n, .sdram_ras_n, .sdram_cas_n, .sdram_we_n,
        .sdram_ba, .sdram_addr, .sdram_dqm, .sdram_dq_out, .sdram_dq_oe, .sdram_dq_in
    );

    // Unmapped addresses still get an acknowledge, so a wrong pointer can't hang the core.
    always_ff @(posedge clk) begin
        if (rst) none_ack <= 1'b0;
        else     none_ack <= bus_stb && slave == SLAVE_NONE && !none_ack;
    end

    always_comb begin
        case (slave)
            SLAVE_UART:  begin bus_ack = uart_ack;  bus_dat_r = uart_dat_r;  end
            SLAVE_TIMER: begin bus_ack = timer_ack; bus_dat_r = timer_dat_r; end
            SLAVE_GPIO:  begin bus_ack = gpio_ack;  bus_dat_r = gpio_dat_r;  end
            SLAVE_SDRAM: begin bus_ack = sdram_ack; bus_dat_r = sdram_dat_r; end
            default:     begin bus_ack = none_ack;  bus_dat_r = '0;          end
        endcase
    end
endmodule
