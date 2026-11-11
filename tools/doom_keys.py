"""Keyboard for Doom on the board: a small window that sends every key press and release over the
serial port, and shows what the board prints (frame rate, messages).

    python tools/doom_keys.py COM8 [--baud 2000000]

Click the window so it has focus, then play: arrows move, Ctrl fires, Space opens doors,
Shift runs, Alt strafes, Enter/Escape for the menus, 1-7 pick weapons, Tab shows the map.
Events are 2 bytes: 0xD1 key (pressed) or 0xD0 key (released), key = a doomkeys.h code.
Needs pyserial; the window uses tkinter, which comes with Python.
"""

import argparse
import queue
import threading
import tkinter as tk

import serial

KEY_RIGHTARROW, KEY_LEFTARROW, KEY_UPARROW, KEY_DOWNARROW = 0xAE, 0xAC, 0xAD, 0xAF
KEY_USE, KEY_FIRE, KEY_ESCAPE, KEY_ENTER, KEY_TAB = 0xA2, 0xA3, 27, 13, 9
KEY_RSHIFT, KEY_RALT, KEY_BACKSPACE, KEY_PAUSE = 0x80 + 0x36, 0x80 + 0x38, 0x7F, 0xFF

SPECIAL = {
    "Right": KEY_RIGHTARROW, "Left": KEY_LEFTARROW, "Up": KEY_UPARROW, "Down": KEY_DOWNARROW,
    "Control_L": KEY_FIRE, "Control_R": KEY_FIRE, "space": KEY_USE,
    "Shift_L": KEY_RSHIFT, "Shift_R": KEY_RSHIFT, "Alt_L": KEY_RALT, "Alt_R": KEY_RALT,
    "Escape": KEY_ESCAPE, "Return": KEY_ENTER, "Tab": KEY_TAB, "BackSpace": KEY_BACKSPACE,
    "Pause": KEY_PAUSE, "minus": 0x2D, "equal": 0x3D,
    **{f"F{i}": 0x80 + 0x3A + i for i in range(1, 11)}, "F11": 0x80 + 0x57, "F12": 0x80 + 0x58,
}


def doom_key(event):
    if event.keysym in SPECIAL:
        return SPECIAL[event.keysym]
    if len(event.keysym) == 1 and event.keysym.isprintable():
        return ord(event.keysym.lower())
    return None


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("port")
    parser.add_argument("--baud", type=int, default=2000000)
    args = parser.parse_args()
    port = serial.Serial(args.port, args.baud, timeout=0.1)

    text = queue.Queue()

    def reader():
        while True:
            data = port.read(256)
            if data:
                text.put(data.decode(errors="replace").replace("\r\n", "\n"))

    threading.Thread(target=reader, daemon=True).start()

    root = tk.Tk()
    root.title("Doom on rv32im-core: keyboard")
    log = tk.Text(root, width=70, height=16, bg="black", fg="#e0e0e0")
    log.pack(fill="both", expand=True)
    held = set()

    def send(event, pressed):
        key = doom_key(event)
        if key is None:
            return "break"
        # Windows repeats KeyPress while a key is held: send each press once.
        if pressed and key in held:
            return "break"
        (held.add if pressed else held.discard)(key)
        port.write(bytes([0xD1 if pressed else 0xD0, key]))
        return "break"

    root.bind("<KeyPress>", lambda e: send(e, True))
    root.bind("<KeyRelease>", lambda e: send(e, False))

    def show_output():
        while not text.empty():
            log.insert("end", text.get())
            log.see("end")
        root.after(100, show_output)

    show_output()
    root.mainloop()


if __name__ == "__main__":
    main()
