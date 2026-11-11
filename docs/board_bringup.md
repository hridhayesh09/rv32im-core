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

## CoreMark (Stage 5)
Both bitstreams are built by Quartus in `fpga/de10lite/output_files/`: `rv32im_soc.sof` (whole SoC
with the NPU, no caches) and `rv32im_cpu.sof` (CPU only, 4 KB instruction and data caches). Run
`make sw` first. CoreMark picks its own iteration count so the timed part lasts about 10 seconds
(the rule for a valid score), after a shorter calibration run.

From on-chip RAM (either bitstream):
```bash
python tools/upload.py COM5 build/sw/coremark_ram.bin --until "COREMARK DONE"
```
From SDRAM through the caches (`rv32im_cpu.sof` only):
```bash
python tools/upload.py COM5 build/sw/jump_to_sdram.bin --data 0x40000000 build/sw/coremark_sdram.bin --until "COREMARK DONE"
```
To switch bitstreams: `quartus_pgm -c USB-Blaster -m jtag -o "p;output_files/rv32im_cpu.sof"`.

**Expect:** `Correct operation validated.`, the CRCs `seedcrc 0xe9f5`, `crclist 0xe714`,
`crcmatrix 0x1fd7`, `crcstate 0x8e3a`, and the raw numbers at the end (`Timed cycles`,
`Iterations`, `Timed mispredicts`). CoreMark/MHz = Iterations x 1,000,000 / Timed cycles.
Save the whole output into the board log.

## Doom
Needs the CPU-only bitstream (`rv32im_cpu.sof`: caches and the 8-bit VGA mode) and a WAD: Freedoom
(`freedoom1.wad` from freedoom.github.io, free) or your own `DOOM1.WAD`. Build with
`python3 tools/build_doom.py` (in WSL), then:
```bash
python tools/upload.py COM8 build/sw/jump_to_sdram.bin --fast 2000000 --data 0x40000000 build/sw/doom.bin --data 0x42000000 build/doom/freedoom1.wad --until "fps"
```
The WAD goes at 2 Mbaud (about 2.5 minutes for Freedoom). **SW0 down: play; SW0 up: Doom's
benchmark** (`-timedemo demo1`, prints `timed ... fps` at the end). To play, close the upload and
start the keyboard window, click it, and use arrows, Ctrl (fire), Space (open), Enter/Escape:
```bash
python tools/doom_keys.py COM8
```
The frame rate is printed every 5 seconds (in the keyboard window, or on the terminal).

## What to film (Stage 2 demo video, ~1 minute)
1. The board with the USB-serial adapter wired up (2 s close-up).
2. Pressing the two keys together: the terminal shows the bootloader banner and `ready`.
3. Running `upload.py` with `hello.bin`: the upload line, `OK`, then the hello output scrolling.
4. Flipping a few switches, resetting, sending `R`: the new switch value printed.
5. The LEDs and the `C0FFEE` on the 7-segment displays.
6. The SDRAM test ending with `SDRAM PASS`.
7. End card: "RV32IM CPU + SoC, designed from scratch: 5-stage pipeline, Wishbone, UART, SDRAM,
   bootloader".

---

# Board bring-up: Stage 3 (VGA and Snake)

Do Stage 2 first (bootloader and `hello` working). Then:

1. Connect a VGA monitor to the DE10-Lite's VGA connector, and build and program the FPGA as in
   Stage 2 (`make sw`, Quartus compile, program the `.sof`).
2. Upload Snake:
   ```bash
   python tools/upload.py COM5 build/sw/snake.bin
   ```
   **Expect:** the monitor shows a big green `SNAKE` title and `PRESS A KEY OR BUTTON`; the
   terminal shows `SNAKE ready`.
3. Press KEY0 (or type `d` in the terminal) to start. **Expect:** grey walls, a green snake moving
   right, a red food square, `SCORE 000` at the top and `0` on the 7-segment displays.
4. Steer: KEY0 turns right, KEY1 turns left (or W/A/S/D in the terminal). Eat food: the score goes
   up on screen, on the 7-segment displays and as `score N` lines in the terminal.
5. Crash into a wall: **expect** yellow `GAME OVER`. Press a key to play again.

If the monitor says "no signal" or "out of range": the timing is standard 640x480 at 59.5 Hz
(checked in simulation), so first check the cable and that the FPGA is programmed. If colours are
wrong, note which: the pin order of VGA_R/G/B came from the boardtest project, where VGA was not
yet tested on the board.

## What to film (Stage 3 demo video, ~1 minute)
1. The monitor showing the SNAKE title screen, the board and the monitor in one shot.
2. Starting the game with KEY0, steering with both keys: the snake turning on screen.
3. Eating food: the score going up on the monitor and on the 7-segment displays at the same time.
4. Crashing: GAME OVER, then restarting.
5. A short cut to the terminal showing `score N` lines arriving while you play.
6. End card: "Snake on my own RISC-V CPU: C code → my VGA controller → monitor".
