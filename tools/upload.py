"""Send data and a program to the rv32im-core UART bootloader, then show what the board prints.

    python tools/upload.py COM8 build/sw/hello.bin --until DONE
    python tools/upload.py COM8 build/sw/mnist.bin --data 0x40000000 build/mnist/mnist_blob.bin

--data ADDR FILE (repeatable) is sent first with the LOAD command (SDRAM, or RAM below 48 KB),
then the program with BOOT. --fast BAUD first asks the bootloader to switch to BAUD (e.g.
2000000, for big files like a Doom WAD); the program then talks at that rate too. Needs pyserial (pip install pyserial). The board must be showing
"ready" (press KEY0 and KEY1 together if not).
Protocol: "LOAD", address, length, bytes, CRC-32 / "BOOT", length, bytes, CRC-32 / "BAUD",
clock divisor (numbers u32 little-endian); the board answers OK or ERR to each.
"""

import argparse
import struct
import sys
import time
import zlib

import serial


def send(port, packet, what, nbytes, baud):
    print(f"{what}: sending {nbytes} bytes ({nbytes * 10 / baud:.1f} s at {baud} baud)")
    port.write(packet)
    port.flush()   # wait until everything has been sent
    reply = b""
    deadline = time.time() + 5 + nbytes * 1e-6   # the board checks the CRC: ~0.2 us per byte
    while b"OK\r\n" not in reply and not (b"ERR" in reply and reply.endswith(b"\n")):
        if time.time() > deadline:
            sys.exit("no answer from the board: is it showing 'ready'? (press KEY0+KEY1)")
        reply += port.read(64)
    if b"ERR" in reply:
        sys.exit(f"board rejected {what}: {reply.decode(errors='replace').strip()}")
    return reply.split(b"OK\r\n", 1)[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port", help="serial port, e.g. COM8 or /dev/ttyUSB0")
    parser.add_argument("program", help="raw binary (.bin) linked at 0x80000000")
    parser.add_argument("--data", nargs=2, action="append", default=[], metavar=("ADDR", "FILE"),
                        help="load FILE at ADDR first (e.g. 0x40000000 for SDRAM)")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--until", help="stop after the board prints this text")
    parser.add_argument("--fast", type=int, metavar="BAUD",
                        help="switch the bootloader to this rate first (50 MHz / BAUD must be whole)")
    args = parser.parse_args()

    with serial.Serial(args.port, args.baud, timeout=0.1) as port:
        port.reset_input_buffer()
        if args.fast:
            divisor = round(50_000_000 / args.fast)
            send(port, b"BAUD" + struct.pack("<I", divisor), f"switch to {args.fast} baud", 0,
                 args.baud)
            time.sleep(0.05)
            port.baudrate = args.baud = args.fast
            time.sleep(0.05)
            port.reset_input_buffer()
        for addr_text, path in args.data:
            data = open(path, "rb").read()
            addr = int(addr_text, 0)
            packet = (b"LOAD" + struct.pack("<II", addr, len(data)) + data +
                      struct.pack("<I", zlib.crc32(data)))
            send(port, packet, f"{path} -> {addr:#010x}", len(data), args.baud)
            # The bootloader prints "ready" again; drain it before the next command.
            time.sleep(0.05)
            port.read(64)

        image = open(args.program, "rb").read()
        packet = b"BOOT" + struct.pack("<I", len(image)) + image + struct.pack("<I", zlib.crc32(image))
        rest = send(port, packet, args.program, len(image), args.baud)
        print("board: OK, program running\n")

        seen = rest.decode(errors="replace").replace("\r\n", "\n")
        sys.stdout.write(seen)
        try:
            while not (args.until and args.until in seen):
                text = port.read(256).decode(errors="replace").replace("\r\n", "\n")
                sys.stdout.write(text)
                sys.stdout.flush()
                seen = (seen + text)[-4096:]
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
