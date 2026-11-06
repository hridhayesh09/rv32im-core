# Board bring-up: Stage 2 (the SoC on the DE10-Lite)

Everything here has been simulated (`make test`) and compiled with Quartus. These steps are the
part that needs the real board.

## What you need
- The DE10-Lite and its USB cable (USB-Blaster, for programming).
- A **3.3 V USB-serial adapter** (FTDI, CP2102 or CH340). The DE10-Lite has no USB serial port of
  its own. Wiring on the Arduino header:

  | Adapter | DE10-Lite |
  |---|---|
  | TX | Arduino IO0 (UART into the FPGA) |
  | RX | Arduino IO1 (UART out of the FPGA) |
  | GND | any GND pin on the header |

  Make sure the adapter is set to **3.3 V**, not 5 V.
- On the PC: Quartus Programmer, `pip install pyserial`, and a serial terminal (PuTTY, or
  `python -m serial.tools.miniterm COM5 115200`).

## 1. Build (no board needed)
In WSL:
```bash
make sw          # build/sw/bootrom.mif (boot ROM) + build/sw/*.bin (programs)
```
In Windows, in `fpga\de10lite`:
```bash
quartus_sh --flow compile rv32im_soc
```
Output: `fpga/de10lite/output_files/rv32im_soc.sof`.

## 2. Program the FPGA
```bash
quartus_pgm -c USB-Blaster -m jtag -o "p;output_files/rv32im_soc.sof"
```
(or Quartus → Tools → Programmer → Start). A `.sof` is lost at power-off; that's fine for now.

**Expect:** LEDR0 on (the bootloader is waiting).

## 3. Talk to the bootloader
Open the terminal on the adapter's port at **115200 baud, 8N1**, then press **KEY0 and KEY1
together** (reset).

**Expect:**
```
rv32im-core bootloader
ready
```
If nothing shows: swap the TX/RX wires, check GND, check the baud rate. If LEDR0 is also off,
the CPU isn't running the bootloader: the FPGA's block-RAM primitive (altsyncram) is the one
part not covered by the Verilator simulations, so check the boot ROM first.

## 4. Run hello
Close the terminal (the port can only be open once), then:
```bash
python tools/upload.py COM5 build/sw/hello.bin --until DONE
```
**Expect:** `board: OK, program running`, then `Hello from rv32im-core!`, `fib(30) = 832040`, the
switch positions in hex (flip some switches and rerun: send `R` from a terminal after a reset to
rerun without uploading), LEDs 1,3,5,7,9 on, and `C0FFEE` on the 7-segment displays.

## 5. Test the SDRAM
```bash
python tools/upload.py COM5 build/sw/sdram_test.bin --until DONE
```
**Expect:** `address lines: ok`, `random words: ok`, `bytes and halfwords: ok`, `copy: ok, ...`
and `SDRAM PASS`. The copy line's cycle counts should match simulation (2,855 write / 3,615 read)
if the board behaves like the model.

If the SDRAM test fails: the sample point for read data is the first suspect. The controller
samples at T+60 ns (`READ_LATENCY = 3`); the boardtest measurements on this board were clean from
T+50 to T+70. Note which test fails and what values come back.

## 6. Record the results
Copy the terminal output into `docs/results/stage2_board.txt` and the copy cycle counts into the
README. Those are the first numbers measured on hardware.

## What to film (Stage 2 demo video, ~1 minute)
1. The board with the USB-serial adapter wired up (2 s close-up).
2. Pressing the two keys together: the terminal shows the bootloader banner and `ready`.
3. Running `upload.py` with `hello.bin`: the upload line, `OK`, then the hello output scrolling.
4. Flipping a few switches, resetting, sending `R`: the new switch value printed.
5. The LEDs and the `C0FFEE` on the 7-segment displays.
6. The SDRAM test ending with `SDRAM PASS`.
7. End card: "RV32IM CPU + SoC, designed from scratch: 5-stage pipeline, Wishbone, UART, SDRAM,
   bootloader".
