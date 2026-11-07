// Simulation model of the IS42S16320 SDRAM (-7 speed grade) that also checks the rules a
// controller must follow. Every broken rule prints a message and increments `violations`.
//
// Checked: the 100 us power-up wait; init (precharge all, 2+ refreshes, mode register) before
// any access; ACTIVE only on a closed bank, READ/WRITE only on an open one; tRCD, tRAS, tRC,
// tRP, write recovery, tRFC, tMRD; refresh at least every 7.8 us; nobody else driving DQ
// while the model drives it, and the controller driving DQ during writes.
// Modelled: mode register (CAS latency, burst length), bursts, auto-precharge, byte masks.
// Testbench-only behavioural code: blocking assignments and associative-array methods are fine.
/* verilator lint_off BLKSEQ */
/* verilator lint_off WIDTHTRUNC */
module sdram_model #(
    parameter int CLK_NS = 20
) (
    input  logic        clk,
    input  logic        cs_n,
    input  logic        ras_n,
    input  logic        cas_n,
    input  logic        we_n,
    input  logic [1:0]  ba,
    input  logic [12:0] addr,
    input  logic [1:0]  dqm,
    input  logic [15:0] dq_from_ctrl,
    input  logic        dq_ctrl_oe,
    output logic [15:0] dq_to_ctrl,
    output int          violations,
    output int          refreshes
);
    function automatic int cycles(input int ns);
        return (ns + CLK_NS - 1) / CLK_NS;
    endfunction

    localparam int POWERUP = cycles(100_000);
    localparam int T_RCD = cycles(15), T_RP = cycles(15), T_RAS = cycles(37), T_RC = cycles(60);
    localparam int T_RFC = cycles(60), T_MRD = 2, T_WR = 2;
    localparam int T_REFI = cycles(7_812);

    logic [15:0] mem [int unsigned];

    int          cycle;
    int          busy_until;        // no command but NOP before this cycle (tRFC, tMRD)
    logic        open_bank [4];
    logic [12:0] open_row [4];
    int          act_cycle [4];
    int          bank_ready [4];    // earliest next ACTIVE (tRP / write recovery after a close)
    logic        mode_set, precharged_all;
    int          cas_latency, burst_length, last_refresh;

    // Burst in progress.
    int          rd_first, rd_beats, wr_beats;
    logic [1:0]  burst_bank;
    logic [12:0] burst_row;
    logic [9:0]  burst_col;
    logic        driving;

    function automatic int unsigned key(input logic [1:0] b, input logic [12:0] r, input logic [9:0] c);
        return {7'b0, b, r, c};
    endfunction

    task automatic violation(input string what);
        $display("SDRAM VIOLATION at cycle %0d: %s", cycle, what);
        violations++;
    endtask

    initial begin
        cycle = 0; violations = 0; refreshes = 0; busy_until = 0;
        mode_set = 0; precharged_all = 0; last_refresh = -1;
        rd_beats = 0; wr_beats = 0; driving = 0;
        for (int b = 0; b < 4; b++) begin
            open_bank[b] = 0; act_cycle[b] = -1000; bank_ready[b] = 0;
        end
    end

    // Simulation backdoor: +sdram_init=<hex file of 32-bit words> preloads the memory from
    // SDRAM address 0 (CPU address 0x4000_0000), as if it had been written through the
    // controller: word w at bank w[10:9], row w[23:11], columns {w[8:0],0} (low halfword) and
    // {w[8:0],1} (high halfword), the controller's address mapping.
    initial begin
        string path;
        int    fd, w;
        logic [31:0] word;
        if ($value$plusargs("sdram_init=%s", path)) begin
            fd = $fopen(path, "r");
            w = 0;
            while ($fscanf(fd, "%h", word) == 1) begin
                mem[key(w[10:9], w[23:11], {w[8:0], 1'b0})] = word[15:0];
                mem[key(w[10:9], w[23:11], {w[8:0], 1'b1})] = word[31:16];
                w++;
            end
            $fclose(fd);
            $display("SDRAM model: preloaded %0d words from %s", w, path);
        end
    end

    always @(posedge clk) begin   // a behavioural model: blocking assignments on purpose
        logic [3:0] cmd;
        cmd = {cs_n, ras_n, cas_n, we_n};
        cycle <= cycle + 1;

        if (driving && dq_ctrl_oe) violation("controller and SDRAM both drive DQ");

        // Write burst data: one halfword per edge, starting at the WRITE command's edge.
        if (wr_beats > 0) begin
            if (!dq_ctrl_oe) violation("no write data on DQ during a write burst");
            for (int i = 0; i < 2; i++) begin
                if (!dqm[i]) begin
                    logic [15:0] old;
                    old = mem.exists(key(burst_bank, burst_row, burst_col)) ?
                          mem[key(burst_bank, burst_row, burst_col)] : 16'h0000;
                    old[8*i +: 8] = dq_from_ctrl[8*i +: 8];
                    mem[key(burst_bank, burst_row, burst_col)] = old;
                end
            end
            burst_col = burst_col + 10'd1;
            wr_beats  = wr_beats - 1;
        end

        // Read burst data: each halfword is driven so that it's valid at the edge CAS latency
        // cycles after the READ.
        driving <= 1'b0;
        if (rd_beats > 0 && cycle >= rd_first) begin
            dq_to_ctrl <= mem.exists(key(burst_bank, burst_row, burst_col)) ?
                          mem[key(burst_bank, burst_row, burst_col)] : 16'h0000;
            driving    <= 1'b1;
            burst_col  = burst_col + 10'd1;
            rd_beats   = rd_beats - 1;
        end

        if (cmd != 4'b0111 && !cs_n) begin
            if (cycle < POWERUP) violation("command before the 100 us power-up wait");
            if (cycle < busy_until) violation("command too soon after REFRESH or LOAD MODE");
            case (cmd)
                4'b0010: begin // PRECHARGE
                    for (int b = 0; b < 4; b++) begin
                        if (addr[10] || ba == 2'(b)) begin
                            if (open_bank[b] && cycle - act_cycle[b] < T_RAS) violation("tRAS");
                            open_bank[b]  = 0;
                            bank_ready[b] = cycle + T_RP;
                        end
                    end
                    if (addr[10]) precharged_all = 1;
                end
                4'b0001: begin // AUTO REFRESH
                    for (int b = 0; b < 4; b++) begin
                        if (open_bank[b] || cycle < bank_ready[b]) violation("REFRESH with a bank not idle");
                    end
                    if (!precharged_all) violation("REFRESH before PRECHARGE ALL");
                    if (mode_set && last_refresh >= 0 && cycle - last_refresh > T_REFI)
                        violation($sformatf("refresh interval %0d cycles > %0d", cycle - last_refresh, T_REFI));
                    last_refresh = cycle;
                    refreshes++;
                    busy_until = cycle + T_RFC;
                end
                4'b0000: begin // LOAD MODE REGISTER
                    for (int b = 0; b < 4; b++) if (open_bank[b]) violation("LOAD MODE with a bank open");
                    if (refreshes < 2) violation("LOAD MODE before 2 refreshes");
                    cas_latency  = int'(addr[6:4]);
                    burst_length = 1 << addr[2:0];
                    mode_set     = 1;
                    busy_until   = cycle + T_MRD;
                end
                4'b0011: begin // ACTIVE
                    if (!mode_set) violation("ACTIVE before the mode register is set");
                    if (open_bank[ba]) violation("ACTIVE on a bank that is already open");
                    if (cycle < bank_ready[ba]) violation("ACTIVE too soon after the bank closed (tRP / write recovery)");
                    if (cycle - act_cycle[ba] < T_RC) violation("tRC");
                    open_bank[ba] = 1;
                    open_row[ba]  = addr;
                    act_cycle[ba] = cycle;
                end
                4'b0101, 4'b0100: begin // READ, WRITE
                    if (!open_bank[ba]) violation("READ/WRITE on a closed bank");
                    if (cycle - act_cycle[ba] < T_RCD) violation("tRCD");
                    if (rd_beats > 0 || wr_beats > 0) violation("new burst before the last one ended");
                    burst_bank = ba;
                    burst_row  = open_row[ba];
                    burst_col  = addr[9:0];
                    if (cmd == 4'b0101) begin
                        rd_first = cycle + cas_latency - 1;
                        rd_beats = burst_length;
                        if (addr[10]) begin
                            open_bank[ba]  = 0;
                            bank_ready[ba] = cycle + burst_length + T_RP;
                        end
                    end else begin
                        // The first beat is written at this same edge.
                        if (!dq_ctrl_oe) violation("no write data with the WRITE command");
                        for (int i = 0; i < 2; i++) begin
                            if (!dqm[i]) begin
                                logic [15:0] old;
                                old = mem.exists(key(ba, open_row[ba], addr[9:0])) ?
                                      mem[key(ba, open_row[ba], addr[9:0])] : 16'h0000;
                                old[8*i +: 8] = dq_from_ctrl[8*i +: 8];
                                mem[key(ba, open_row[ba], addr[9:0])] = old;
                            end
                        end
                        burst_col = addr[9:0] + 10'd1;
                        wr_beats  = burst_length - 1;
                        if (addr[10]) begin
                            open_bank[ba]  = 0;
                            bank_ready[ba] = cycle + (burst_length - 1) + T_WR + T_RP;
                        end
                    end
                end
                default: violation("unsupported command");
            endcase
        end
    end
endmodule
