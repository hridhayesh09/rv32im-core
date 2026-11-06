// A simulated VGA monitor: finds lines and frames from the sync pulses alone (as a real monitor
// does), checks the 640x480@60 timing, and saves each complete frame as a PPM image when
// +vga_dump=<prefix> is given (<prefix>NNN.ppm).
//
// Timing checked (in 50 MHz clocks, one pixel = 2 clocks): HS every 1600 clocks, HS low for
// 192 (96 pixels); VS every 525 lines, VS low for 2 lines. Visible pixels start 48 pixels after
// HS rises; visible lines start 35 lines after VS falls.
//
// Testbench-only behavioural code.
/* verilator lint_off BLKSEQ */
module vga_capture (
    input  logic       clk,
    input  logic       rst,             // nothing is checked or captured during reset
    input  logic [3:0] r,
    input  logic [3:0] g,
    input  logic [3:0] b,
    input  logic       hs,
    input  logic       vs,
    output int         frames,          // VS falling edges seen
    output int         timing_errors
);
    logic [11:0] img [640*480];
    logic        hs_q = 1'b1, vs_q = 1'b1;
    int          clk_count = 0, hs_fall_at = -1, vs_fall_at_line = -1;
    int          lines = 0;             // HS falls since the last VS fall
    int          total_lines = 0;
    int          since_rise = 100000, line_y = -1;
    string       prefix;
    logic        dump;

    initial begin
        frames = 0;
        timing_errors = 0;
        dump = $value$plusargs("vga_dump=%s", prefix);
    end

    task automatic error(input string what);
        $display("VGA TIMING ERROR at clock %0d: %s", clk_count, what);
        timing_errors++;
    endtask

    task automatic save(input int n);
        int fd;
        fd = $fopen($sformatf("%s%03d.ppm", prefix, n), "wb");
        $fwrite(fd, "P6\n640 480\n255\n");
        for (int i = 0; i < 640 * 480; i++) begin
            $fwrite(fd, "%c%c%c", 8'(img[i][11:8] * 17), 8'(img[i][7:4] * 17), 8'(img[i][3:0] * 17));
        end
        $fclose(fd);
    endtask

    always @(posedge clk) begin
        clk_count++;
        since_rise++;
        if (!rst) begin

        if (hs_q && !hs) begin                         // HS falls
            if (hs_fall_at >= 0 && clk_count - hs_fall_at != 1600)
                error($sformatf("line length %0d clocks, expected 1600", clk_count - hs_fall_at));
            hs_fall_at = clk_count;
            lines++;
            total_lines++;
        end
        if (!hs_q && hs) begin                         // HS rises
            if (clk_count - hs_fall_at != 192)
                error($sformatf("HS pulse %0d clocks, expected 192", clk_count - hs_fall_at));
            since_rise = 0;
            line_y = lines - 35;                       // the line whose pixels come next
        end
        if (vs_q && !vs) begin                         // VS falls: a new frame
            if (vs_fall_at_line >= 0 && total_lines - vs_fall_at_line != 525)
                error($sformatf("frame of %0d lines, expected 525", total_lines - vs_fall_at_line));
            vs_fall_at_line = total_lines;
            // Frame N is everything between VS fall N and N+1 (the first full frame is 1).
            if (frames > 0 && dump) save(frames);
            frames++;
            lines = 0;
        end
        if (!vs_q && vs && total_lines - vs_fall_at_line != 2)
            error($sformatf("VS pulse %0d lines, expected 2", total_lines - vs_fall_at_line));

        // Visible pixels: 48 pixels (96 clocks) after HS rises, one every 2 clocks; sample the
        // second clock of each pixel.
        if (line_y >= 0 && line_y < 480 && since_rise >= 97 && since_rise < 97 + 1280 &&
            (since_rise - 97) % 2 == 0) begin
            img[line_y * 640 + (since_rise - 97) / 2] = {r, g, b};
        end

        end
        hs_q = hs;
        vs_q = vs;
    end
endmodule
