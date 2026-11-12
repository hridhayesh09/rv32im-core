// Machine-mode control and status registers (Zicsr), traps and MRET.
//
// Implemented (machine mode only, no interrupts yet):
//   0x300 mstatus   MIE (bit 3), MPIE (bit 7); MPP (bits 12:11) is always 3 (machine)
//   0x301 misa      RV32IM (read only here; writes ignored)
//   0x304 mie       read/write (MSIE, MTIE, MEIE bits); 0x344 mip reads 0
//   0x305 mtvec     trap vector, direct mode (bits 1:0 read 0)
//   0x310 mstatush  reads 0
//   0x340 mscratch, 0x341 mepc (bits 1:0 read 0), 0x342 mcause, 0x343 mtval
//   0xB00/0xB80 mcycle(h), 0xB02/0xB82 minstret(h): 64-bit counters, read/write
//   0xC00/0xC80 cycle(h), 0xC02/0xC82 instret(h): read-only copies
//   0xF11-0xF15 mvendorid, marchid, mimpid, mhartid, mconfigptr: read 0
//   0xB03-0xB0B/0xB83-0xB8B mhpmcounter3-11(h): event counters (see events), read/write;
//                  0xC03-0xC0B/0xC83-0xC8B: read-only copies; 0x323-0x32B mhpmevent3-11 read 0
//                  (each counter's event is fixed)
// Any other address, or a write to a read-only CSR (address bits 11:10 = 11), is illegal.
//
// A CSR instruction executes in EX. minstret counts retired instructions (at WB); when EX reads
// it, the older instructions still in MEM and WB haven't retired yet, so they're added in, which
// makes the value match the ISA's definition (all instructions before this one).
module csr (
    input  logic        clk,
    input  logic        rst,

    // CSR instruction in EX
    input  logic        op_fire,        // a CSR instruction executes this cycle
    input  logic [2:0]  op,             // funct3: x01 write, x10 set, x11 clear
    input  logic [11:0] addr,
    input  logic [31:0] src,            // rs1, or the 5-bit immediate for the I forms
    input  logic        src_zero,       // rs1 field is 0: set/clear don't write
    output logic [31:0] rdata,
    output logic        illegal,

    // traps and MRET, from EX
    input  logic        trap,           // take a trap this cycle
    input  logic [31:0] trap_pc,
    input  logic [31:0] trap_cause,
    input  logic [31:0] trap_tval,
    input  logic        mret_fire,
    output logic [31:0] mtvec_out,
    output logic [31:0] mepc_out,

    // retirement, for minstret
    input  logic        retire,         // an instruction retires (WB) this cycle
    input  logic        mem_pending,    // an instruction in MEM will still retire
    input  logic        wb_pending,     // an instruction in WB retires this cycle

    // performance events, one bit per counter: events[i] adds 1 to mhpmcounter(3+i) this cycle
    input  logic [8:0]  events
);
    localparam int NUM_HPM = 9;          // mhpmcounter3 .. mhpmcounter11
    logic        mie_bit, mpie;
    logic [31:0] mie, mtvec, mscratch, mepc, mcause, mtval;
    logic [63:0] mcycle, minstret;
    logic [63:0] hpm [NUM_HPM];

    // A write to minstret takes two cycles: the value is stored this cycle and corrected next cycle
    // (minus the instructions that will still retire), so the 64-bit arithmetic isn't on the long
    // path from forwarding through the CSR logic (the slowest path in the ASIC flow). The core
    // flushes the instructions after such a write, so nothing reads minstret in between.
    logic        ir_wr, ir_wr_adj;
    logic [63:0] ir_wr_value;

    // Events are registered before they're counted, so the 64-bit increment isn't on the path from
    // the event's source (deep in EX). A read adds the registered event, so the count stays exact.
    logic [NUM_HPM-1:0] events_q;

    // Which event counter (if any) an address names: 0xB03.. / 0xB83.. / 0xC03.. / 0xC83..
    logic        hpm_sel, hpm_high, hpm_event_sel;
    logic [3:0]  hpm_idx;
    always_comb begin
        hpm_idx  = addr[3:0] - 4'd3;
        hpm_sel  = (addr[11:8] == 4'hB || addr[11:8] == 4'hC) && addr[6:4] == 3'b000 &&
                   addr[3:0] >= 4'd3 && addr[3:0] <= 4'd11;
        hpm_high = addr[7];
        hpm_event_sel = addr[11:4] == 8'h32 && addr[3:0] >= 4'd3 && addr[3:0] <= 4'd11;
    end

    logic [63:0] instret_now;           // minstret as the instruction in EX sees it
    assign instret_now = minstret + {63'b0, mem_pending} + {63'b0, wb_pending};

    logic [31:0] mstatus;
    assign mstatus = {19'b0, 2'b11, 3'b0, mpie, 3'b0, mie_bit, 3'b0};

    // ---------------------------------------------------------------- read
    logic        known;
    logic [63:0] hpm_now;
    always_comb begin
        known   = 1'b1;
        hpm_now = '0;
        case (addr)
            12'h300: rdata = mstatus;
            12'h301: rdata = 32'h4000_1100;          // MXL = 32 bits, I and M
            12'h304: rdata = mie;
            12'h305: rdata = mtvec;
            12'h310: rdata = '0;
            12'h340: rdata = mscratch;
            12'h341: rdata = mepc;
            12'h342: rdata = mcause;
            12'h343: rdata = mtval;
            12'h344: rdata = '0;
            12'hB00, 12'hC00: rdata = mcycle[31:0];
            12'hB80, 12'hC80: rdata = mcycle[63:32];
            12'hB02, 12'hC02: rdata = instret_now[31:0];
            12'hB82, 12'hC82: rdata = instret_now[63:32];
            12'hF11, 12'hF12, 12'hF13, 12'hF14, 12'hF15: rdata = '0;
            default: begin
                if (hpm_sel) begin
                    hpm_now = hpm[hpm_idx] + {63'b0, events_q[hpm_idx]};
                    rdata   = hpm_high ? hpm_now[63:32] : hpm_now[31:0];
                end
                else if (hpm_event_sel)  rdata = '0;
                else begin
                    rdata = '0;
                    known = 1'b0;
                end
            end
        endcase
    end

    logic wants_write, writes;
    assign wants_write = op[1:0] == 2'b01 || !src_zero;
    assign illegal     = !known || (addr[11:10] == 2'b11 && wants_write);
    assign writes      = op_fire && !illegal && wants_write;

    logic [31:0] wdata;
    always_comb begin
        case (op[1:0])
            2'b01:   wdata = src;               // CSRRW
            2'b10:   wdata = rdata | src;       // CSRRS
            default: wdata = rdata & ~src;      // CSRRC
        endcase
    end

    // ---------------------------------------------------------------- write, traps, counters
    always_ff @(posedge clk) begin
        if (rst) begin
            mie_bit  <= 1'b0;
            mpie     <= 1'b0;
            mie      <= '0;
            mtvec    <= '0;
            mscratch <= '0;
            mepc     <= '0;
            mcause   <= '0;
            mtval    <= '0;
            mcycle   <= '0;
            minstret <= '0;
            for (int i = 0; i < NUM_HPM; i++) hpm[i] <= '0;
            events_q <= '0;
            ir_wr    <= 1'b0;
        end else begin
            events_q <= events;
            mcycle   <= mcycle + 64'd1;
            ir_wr    <= 1'b0;
            if (ir_wr) minstret <= ir_wr_value - {63'b0, ir_wr_adj} - 64'd1 + {63'b0, retire};
            else       minstret <= minstret + {63'b0, retire};
            for (int i = 0; i < NUM_HPM; i++) hpm[i] <= hpm[i] + {63'b0, events_q[i]};

            if (trap) begin
                mepc    <= {trap_pc[31:2], 2'b00};
                mcause  <= trap_cause;
                mtval   <= trap_tval;
                mpie    <= mie_bit;
                mie_bit <= 1'b0;
            end else if (mret_fire) begin
                mie_bit <= mpie;
                mpie    <= 1'b1;
            end else if (writes) begin
                case (addr)
                    12'h300: begin mie_bit <= wdata[3]; mpie <= wdata[7]; end
                    12'h304: mie      <= wdata & 32'h0000_0888;
                    12'h305: mtvec    <= {wdata[31:2], 2'b00};
                    12'h340: mscratch <= wdata;
                    12'h341: mepc     <= {wdata[31:2], 2'b00};
                    12'h342: mcause   <= wdata;
                    12'h343: mtval    <= wdata;
                    12'hB00: mcycle[31:0]  <= wdata;
                    12'hB80: mcycle[63:32] <= wdata;
                    // The ISA says the write takes effect after this instruction, which doesn't
                    // count itself: the next read should return the value written plus the
                    // instructions retired since. The writer and an older instruction in MEM will
                    // still retire (and count), so start that much lower (applied next cycle).
                    12'hB02: begin
                        ir_wr       <= 1'b1;
                        ir_wr_value <= {minstret[63:32], wdata};
                        ir_wr_adj   <= mem_pending;
                    end
                    // Writing the high half: the low half keeps counting, so the older instructions
                    // (in WB now, in MEM later) do count; only the writer itself doesn't. (Found by
                    // the lockstep test: this used the low-half correction and lost 2 counts.)
                    12'hB82: begin
                        ir_wr       <= 1'b1;
                        ir_wr_value <= {wdata, minstret[31:0] + {31'b0, wb_pending}};
                        ir_wr_adj   <= 1'b0;
                    end
                    default: begin
                        if (hpm_sel && addr[11:8] == 4'hB) begin
                            if (hpm_high) hpm[hpm_idx][63:32] <= wdata;
                            else          hpm[hpm_idx][31:0]  <= wdata;
                        end
                    end
                endcase
            end
        end
    end

    assign mtvec_out = mtvec;
    assign mepc_out  = mepc;
endmodule
