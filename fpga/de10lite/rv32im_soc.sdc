# Timing constraints for the DE10-Lite build.

# 50 MHz board oscillator: 20 ns period.
create_clock -name clk50 -period 20.000 [get_ports {MAX10_CLK1_50}]
derive_clock_uncertainty

# Keys, switches and the UART input are asynchronous and pass through 2-flop synchronizers.
# LEDs, displays and the UART output are slow outputs. SDRAM pin timing comes from I/O-cell
# registers and the inverted SDRAM clock (same scheme as edge-ml-accelerator/boardtest, where it
# was measured on this board), so those pins aren't analyzed here.
set_false_path -from [get_ports {KEY[*] SW[*] ARDUINO_IO[*] DRAM_DQ[*]}]
# VGA: the monitor samples analog levels; nanosecond pin timing doesn't matter at 25 MHz.
set_false_path -to   [get_ports {LEDR[*] HEX*[*] ARDUINO_IO[*] DRAM_* VGA_*}]
