"""Send a program to the rv32im-core UART bootloader, then show what the board prints.

    python tools/upload.py COM5 build/programs/soc-hello.bin
    python tools/upload.py /dev/ttyUSB0 build/programs/soc-hello.bin --until DONE

Needs pyserial (pip install pyserial). The board must be showing "ready" (press reset if not).
Protocol: "BOOT", length (u32 LE), program bytes, CRC-32 (u32 LE); the board answers OK or ERR.
"""

import argparse
import struct
import sys
import time
import zlib

import serial


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port", help="serial port, e.g. COM5 or /dev/ttyUSB0")
    parser.add_argument("program", help="raw binary (.bin) linked at 0x80000000")
    parser.add_argument("--baud", type=int, default=115200)
    parser.add_argument("--until", help="stop after the board prints this text")
    args = parser.parse_args()

    image = open(args.program, "rb").read()
    packet = b"BOOT" + struct.pack("<I", len(image)) + image + struct.pack("<I", zlib.crc32(image))

    with serial.Serial(args.port, args.baud, timeout=0.1) as port:
        port.reset_input_buffer()
        print(f"sending {len(image)} bytes ({len(image) * 10 / args.baud:.1f} s at {args.baud} baud)")
        port.write(packet)
        port.flush()   # wait until everything has been sent

        reply = b""
        deadline = time.time() + 5
        while b"OK\r\n" not in reply and not (b"ERR" in reply and reply.endswith(b"\n")):
            if time.time() > deadline:
                sys.exit("no answer from the board: is it showing 'ready'? (press reset)")
            reply += port.read(64)
        if b"ERR" in reply:
            sys.exit(f"board rejected the program: {reply.decode(errors='replace').strip()}")
        print("board: OK, program running\n")
        sys.stdout.write(reply.split(b"OK\r\n", 1)[1].decode(errors="replace"))

        seen = ""
        try:
            while True:
                text = port.read(256).decode(errors="replace")
                sys.stdout.write(text)
                sys.stdout.flush()
                seen = (seen + text)[-4096:]
                if args.until and args.until in seen:
                    break
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
