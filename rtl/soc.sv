// The system-on-chip: core + boot ROM + on-chip RAM + caches + Wishbone bus with peripherals.
//
//   0x0000_0000  boot ROM, 8 KB      (tightly coupled: no wait states; reset address)
//   0x1000_0000  UART                (Wishbone)
//   0x1000_1000  timer               (Wishbone)
//   0x1000_2000  GPIO                (Wishbone)
//   0x1000_3000  VGA registers       (Wishbone: palette, status)
//   0x2000_0000  VGA framebuffer     (Wishbone: 320x240, one byte per pixel)
//   0x1000_4000  NPU registers       (Wishbone; when NPU = 1)
//   0x3000_0000  NPU buffers         (Wishbone: activations, results)
//   0x4000_0000  SDRAM, 64 MB        (through the caches; without a cache, on Wishbone)
//   0x8000_0000  on-chip RAM, 64 KB  (tightly coupled: no wait states)
//   anything else                    (Wishbone; reads 0, writes ignored)
//
// Instructions can be fetched from the boot ROM, the RAM, and (with an instruction cache) SDRAM.
// ROM and RAM take one cycle; cache hits too. A cache miss or a bus access freezes the core until
// it's done. The caches share the SDRAM controller's line port.
module soc #(
    parameter logic [31:0] CLK_HZ       = 32'd50_000_000,
    parameter int          UART_DIVISOR = 434,            // CLK_HZ / 115200
    parameter              BOOTROM_FILE = "",             // hex images for synthesis
    parameter              RAM_FILE     = "",
    parameter int          ICACHE_SIZE  = 4096,           // bytes; 0 = no instruction cache
    parameter int          ICACHE_WAYS  = 1,
    parameter int          DCACHE_SIZE  = 4096,           // bytes; 0 = no data cache
    parameter int          DCACHE_WAYS  = 1,
    parameter bit          NPU          = 1'b1,           // include the 16x16 NPU
    parameter int          BP_MODE      = 2,              // branch predictor (see core.sv)
    parameter int          BTB_BITS     = 5,
    parameter int          BHT_BITS     = 8,
    parameter int          RAS_DEPTH    = 4,
    parameter bit          VGA8         = 1'b0            // VGA mode: 0 = 320x240x4, 1 = 320x200x8
) (
    input  logic        clk,
    input  logic        rst,
    output logic        txd,
    input  logic        rxd,
    output logic [9:0]  ledr,
    input  logic [9:0]  sw,
    input  logic [1:0]  key_n,
    output logic [47:0] hex_n,

    output logic [3:0]  vga_r,
    output logic [3:0]  vga_g,
    output logic [3:0]  vga_b,
    output logic        vga_hs,
    output logic        vga_vs,

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
    localparam bit HAS_ICACHE = ICACHE_SIZE != 0;
    localparam bit HAS_DCACHE = DCACHE_SIZE != 0;

    // ---------------------------------------------------------------- core

    logic        imem_en, imem_stall, fetch_valid, cache_flush;
    logic        dmem_en, dmem_stall;
    logic [3:0]  dmem_we, mem_events;
    logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;

    /* verilator lint_off PINCONNECTEMPTY */
    core #(.RESET_PC(32'h0000_0000), .BP_MODE(BP_MODE), .BTB_BITS(BTB_BITS), .BHT_BITS(BHT_BITS),
           .RAS_DEPTH(RAS_DEPTH)) u_core (
        .clk, .rst,
        .imem_en, .imem_addr, .imem_rdata, .imem_stall, .fetch_valid, .cache_flush,
        .dmem_en, .dmem_we, .dmem_addr, .dmem_wdata, .dmem_rdata, .dmem_stall,
        .mem_events,
        .rvfi_valid(), .rvfi_pc(), .rvfi_insn(), .rvfi_rd(), .rvfi_rd_wdata(),
        .rvfi_mem_read(), .rvfi_mem_wmask(), .rvfi_mem_addr(), .rvfi_mem_wdata()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ---------------------------------------------------------------- where accesses go

    typedef enum logic [1:0] { TARGET_ROM, TARGET_RAM, TARGET_BUS, TARGET_CACHE } target_t;

    function automatic target_t decode_fetch(input logic [31:0] addr);
        if (addr[31])                               return TARGET_RAM;
        else if (addr[31:28] == 4'h4 && HAS_ICACHE) return TARGET_CACHE;
        else                                        return TARGET_ROM;
    endfunction

    function automatic target_t decode_data(input logic [31:0] addr);
        if (addr[31])                               return TARGET_RAM;
        else if (addr[31:28] == '0)                 return TARGET_ROM;
        else if (addr[31:28] == 4'h4 && HAS_DCACHE) return TARGET_CACHE;
        else                                        return TARGET_BUS;
    endfunction

    target_t fetch_target, fetch_target_q, data_target, data_target_q;
    assign fetch_target = decode_fetch(imem_addr);
    assign data_target  = decode_data(dmem_addr);

    // Remember where the access in flight went, to pick its read data next cycle.
    always_ff @(posedge clk) begin
        if (imem_en) fetch_target_q <= fetch_target;
        if (dmem_en) data_target_q  <= data_target;
    end

    // ---------------------------------------------------------------- tightly coupled memories

    logic [31:0] rom_a_rdata, rom_b_rdata, ram_a_rdata, ram_b_rdata;

    dpram #(.WORDS(2048), .INIT_MIF(BOOTROM_FILE), .INIT_PLUSARG("bootrom")) u_bootrom (
        .clk,
        .a_en    (imem_en && fetch_target == TARGET_ROM),
        .a_addr  (imem_addr),
        .a_rdata (rom_a_rdata),
        .b_en    (dmem_en && data_target == TARGET_ROM),
        .b_we    (4'b0000),               // read only
        .b_addr  (dmem_addr),
        .b_wdata ('0),
        .b_rdata (rom_b_rdata)
    );

    dpram #(.WORDS(16384), .INIT_MIF(RAM_FILE), .INIT_PLUSARG("program")) u_ram (
        .clk,
        .a_en    (imem_en && fetch_target == TARGET_RAM),
        .a_addr  (imem_addr),
        .a_rdata (ram_a_rdata),
        .b_en    (dmem_en && data_target == TARGET_RAM),
        .b_we    (data_target == TARGET_RAM ? dmem_we : 4'b0000),
        .b_addr  (dmem_addr),
        .b_wdata (dmem_wdata),
        .b_rdata (ram_b_rdata)
    );

    // ---------------------------------------------------------------- caches (SDRAM)

    logic         i_req, i_we, i_ack, d_req, d_we, d_ack, line_req, line_we, line_ack;
    logic [31:0]  i_addr, d_addr, icache_rdata, dcache_rdata;
    /* verilator lint_off UNUSEDSIGNAL */
    logic [31:0]  line_addr;            // bits [31:26] aren't used: SDRAM is 64 MB
    /* verilator lint_on UNUSEDSIGNAL */
    logic [127:0] i_wdata, d_wdata, line_wdata, line_rdata;
    logic         icache_stall, dcache_stall, i_access, i_miss, d_access, d_miss;

    generate
        if (HAS_ICACHE) begin : g_icache
            cache #(.SIZE(ICACHE_SIZE), .WAYS(ICACHE_WAYS), .WRITABLE(1'b0)) u_icache (
                .clk, .rst,
                .req_en    (imem_en && fetch_target == TARGET_CACHE),
                .req_we    (4'b0000),
                .req_addr  (imem_addr),
                .req_wdata ('0),
                .keep      (fetch_valid),
                .rdata     (icache_rdata),
                .stall     (icache_stall),
                .flush     (cache_flush),
                .mem_req   (i_req), .mem_we (i_we), .mem_addr (i_addr), .mem_wdata (i_wdata),
                .mem_rdata (line_rdata), .mem_ack (i_ack),
                .ev_access (i_access), .ev_miss (i_miss)
            );
        end else begin : g_no_icache
            assign {i_req, i_we, i_addr, i_wdata, icache_rdata} = '0;
            assign {icache_stall, i_access, i_miss} = '0;
        end

        if (HAS_DCACHE) begin : g_dcache
            cache #(.SIZE(DCACHE_SIZE), .WAYS(DCACHE_WAYS), .WRITABLE(1'b1)) u_dcache (
                .clk, .rst,
                .req_en    (dmem_en && data_target == TARGET_CACHE),
                .req_we    (data_target == TARGET_CACHE ? dmem_we : 4'b0000),
                .req_addr  (dmem_addr),
                .req_wdata (dmem_wdata),
                .keep      (1'b1),
                .rdata     (dcache_rdata),
                .stall     (dcache_stall),
                .flush     (cache_flush),
                .mem_req   (d_req), .mem_we (d_we), .mem_addr (d_addr), .mem_wdata (d_wdata),
                .mem_rdata (line_rdata), .mem_ack (d_ack),
                .ev_access (d_access), .ev_miss (d_miss)
            );
        end else begin : g_no_dcache
            assign {d_req, d_we, d_addr, d_wdata, dcache_rdata} = '0;
            assign {dcache_stall, d_access, d_miss} = '0;
        end
    endgenerate

    mem_arbiter u_arbiter (
        .clk, .rst,
        .req0 (d_req), .we0 (d_we), .addr0 (d_addr), .wdata0 (d_wdata), .ack0 (d_ack),
        .req1 (i_req), .we1 (i_we), .addr1 (i_addr), .wdata1 (i_wdata), .ack1 (i_ack),
        .mem_req (line_req), .mem_we (line_we), .mem_addr (line_addr), .mem_wdata (line_wdata),
        .mem_ack (line_ack)
    );

    assign mem_events = {d_miss, d_access, i_miss, i_access};
    assign imem_stall = icache_stall;
    assign imem_rdata = (fetch_target_q == TARGET_RAM)   ? ram_a_rdata :
                        (fetch_target_q == TARGET_CACHE) ? icache_rdata : rom_a_rdata;

    // ---------------------------------------------------------------- Wishbone bridge
    // A bus access is captured when the core sends it (instruction leaving EX) and driven on
    // the bus while that instruction waits in MEM; the core is frozen until the access is done.
    // The slave's read data and ack are registered here before the core sees them, so no path
    // runs from inside a peripheral into the core in one cycle (one extra cycle per bus access).

    // Which slave an access goes to is decoded when the request is captured and kept in a
    // register, so the address decoder isn't on the path from a slave's ack to the core's stall.
    typedef enum logic [2:0] { SLAVE_UART, SLAVE_TIMER, SLAVE_GPIO, SLAVE_VGA, SLAVE_NPU, SLAVE_SDRAM,
                               SLAVE_NONE } slave_t;

    function automatic slave_t decode_slave(input logic [31:0] addr);
        if (addr[31:16] == 16'h1000) begin
            case (addr[15:12])
                4'h0:    return SLAVE_UART;
                4'h1:    return SLAVE_TIMER;
                4'h2:    return SLAVE_GPIO;
                4'h3:    return SLAVE_VGA;
                4'h4:    return NPU ? SLAVE_NPU : SLAVE_NONE;
                default: return SLAVE_NONE;
            endcase
        end else if (addr[31:28] == 4'h2) begin
            return SLAVE_VGA;
        end else if (addr[31:28] == 4'h3) begin
            return NPU ? SLAVE_NPU : SLAVE_NONE;
        end else if (addr[31:28] == 4'h4 || addr[31:28] == 4'h5) begin
            // 0x4...: SDRAM (reaches the bus only without a data cache). 0x5...: the same SDRAM,
            // never cached (for buffers shared with hardware; the data cache doesn't see these
            // accesses, so software keeps the two views apart).
            return SLAVE_SDRAM;
        end else begin
            return SLAVE_NONE;
        end
    endfunction

    slave_t      slave;
    logic        bus_stb, bus_we, bus_ack;
    logic [31:0] bus_adr, bus_dat_w, bus_dat_r, bus_rdata_q;
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
            slave     <= decode_slave(dmem_addr);
        end else if (bus_ack) begin
            bus_stb     <= 1'b0;
            bus_rdata_q <= bus_dat_r;
        end
    end

    // The bus stall is a register (the access ends the cycle after the ack); the data cache stalls
    // for its own misses and for a FENCE.I flush.
    assign dmem_stall = bus_stb || dcache_stall;

    always_comb begin
        case (data_target_q)
            TARGET_ROM:   dmem_rdata = rom_b_rdata;
            TARGET_RAM:   dmem_rdata = ram_b_rdata;
            TARGET_CACHE: dmem_rdata = dcache_rdata;
            default:      dmem_rdata = bus_rdata_q;
        endcase
    end

    // ---------------------------------------------------------------- Wishbone interconnect

    localparam logic [15:0] UART_DIVISOR_16 = UART_DIVISOR[15:0];

    logic [31:0] uart_dat_r, timer_dat_r, gpio_dat_r, vga_dat_r, npu_dat_r, sdram_dat_r;
    logic        uart_ack, timer_ack, gpio_ack, vga_ack, npu_ack, sdram_ack, none_ack;

    wb_uart #(.DEFAULT_DIVISOR(UART_DIVISOR_16)) u_uart (
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

    wb_vga #(.MODE8(VGA8)) u_vga (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_VGA),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (vga_dat_r),
        .wb_ack   (vga_ack),
        .vga_r, .vga_g, .vga_b, .vga_hs, .vga_vs
    );

    generate
        if (NPU) begin : g_npu
            wb_npu u_npu (
                .clk, .rst,
                .wb_stb   (bus_stb && slave == SLAVE_NPU),
                .wb_we    (bus_we),
                .wb_adr   (bus_adr),
                .wb_dat_w (bus_dat_w),
                .wb_sel   (bus_sel),
                .wb_dat_r (npu_dat_r),
                .wb_ack   (npu_ack)
            );
        end else begin : g_no_npu
            assign npu_dat_r = '0;
            assign npu_ack   = 1'b0;
        end
    endgenerate

    sdram_ctrl u_sdram (
        .clk, .rst,
        .wb_stb   (bus_stb && slave == SLAVE_SDRAM),
        .wb_we    (bus_we),
        .wb_adr   (bus_adr),
        .wb_dat_w (bus_dat_w),
        .wb_sel   (bus_sel),
        .wb_dat_r (sdram_dat_r),
        .wb_ack   (sdram_ack),
        .line_req,
        .line_we,
        .line_addr  (line_addr[25:0]),
        .line_wdata,
        .line_rdata,
        .line_ack,
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
            SLAVE_VGA:   begin bus_ack = vga_ack;   bus_dat_r = vga_dat_r;   end
            SLAVE_NPU:   begin bus_ack = npu_ack;   bus_dat_r = npu_dat_r;   end
            SLAVE_SDRAM: begin bus_ack = sdram_ack; bus_dat_r = sdram_dat_r; end
            default:     begin bus_ack = none_ack;  bus_dat_r = '0;          end
        endcase
    end
endmodule
