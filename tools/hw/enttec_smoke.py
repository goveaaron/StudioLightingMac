#!/usr/bin/env python3
"""Talk to an ENTTEC DMX USB Pro directly — no Prism, no dependencies (macOS/Linux).

Use it to prove the USB → DMX → light path works before blaming the app, and to drive exact
DMX values while you watch the lights (or a webcam snapshot).

    python3 tools/hw/enttec_smoke.py ports                 # list candidate serial ports
    python3 tools/hw/enttec_smoke.py info                  # serial number, firmware, timing
    python3 tools/hw/enttec_smoke.py set 2=255 3=17 4=128  # channel=value … (others 0)
    python3 tools/hw/enttec_smoke.py set 2-8=0 --hold 3    # ranges; keep re-sending 3 s
    python3 tools/hw/enttec_smoke.py blink 2 255,17,128,0,0,0,0   # values from address 2, ×3
    python3 tools/hw/enttec_smoke.py blackout

Quit Lightkey / QLC+ / Prism first: only one app can own the port. The Pro keeps transmitting
the last frame it received, so lights stay as set after this script exits (use `blackout`).
Mind fixture modes with strobe/effect channels: only send values you understand.

Protocol (ENTTEC "DMX USB Pro API"): 0x7E, label, length LSB, length MSB, data…, 0xE7.
Label 6 = output-only send DMX (data = start code 0 + 24..512 channel bytes),
label 10 = get serial number (reply: 4 bytes BCD, little-endian),
label 3 = get widget parameters (reply: fw LSB, fw MSB, break, MAB, refresh rate, …).
"""
import argparse
import glob
import os
import select
import sys
import termios
import time
import tty

SOM, EOM = 0x7E, 0xE7
LABEL_PARAMS, LABEL_SEND_DMX, LABEL_SERIAL = 3, 6, 10


def candidate_ports():
    pats = ["/dev/cu.usbserial-*", "/dev/ttyUSB*"]
    return sorted(p for pat in pats for p in glob.glob(pat))


def open_port(path):
    fd = os.open(path, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)
    try:
        import fcntl
        fcntl.ioctl(fd, getattr(termios, "TIOCEXCL", 0x2000740D))  # exclusive, like Prism
    except OSError:
        pass
    tty.setraw(fd)
    attrs = termios.tcgetattr(fd)
    attrs[4] = attrs[5] = termios.B57600  # irrelevant for the FTDI FIFO, but must be valid
    termios.tcsetattr(fd, termios.TCSANOW, attrs)
    return fd


def close_port(fd):
    try:
        import fcntl
        fcntl.ioctl(fd, getattr(termios, "TIOCNXCL", 0x2000740E))  # don't leave it locked
    except OSError:
        pass
    os.close(fd)


def packet(label, data=b""):
    n = len(data)
    return bytes([SOM, label, n & 0xFF, n >> 8]) + bytes(data) + bytes([EOM])


def write_all(fd, buf, timeout=1.0):
    end = time.monotonic() + timeout
    while buf:
        if time.monotonic() > end:
            raise TimeoutError("write timed out — is another app holding the port?")
        _, w, _ = select.select([], [fd], [], 0.1)
        if w:
            try:
                buf = buf[os.write(fd, buf):]
            except BlockingIOError:
                pass


def read_reply(fd, label, timeout=1.0):
    """Return the data of the first well-formed reply with `label`, or None."""
    buf, end = b"", time.monotonic() + timeout
    while time.monotonic() < end:
        r, _, _ = select.select([fd], [], [], 0.05)
        if r:
            try:
                buf += os.read(fd, 1024)
            except BlockingIOError:
                pass
        while True:
            i = buf.find(bytes([SOM]))
            if i < 0 or len(buf) - i < 5:
                break
            lab, n = buf[i + 1], buf[i + 2] | (buf[i + 3] << 8)
            if len(buf) - i < 5 + n:
                break
            body, tail = buf[i + 4:i + 4 + n], buf[i + 4 + n]
            buf = buf[i + 5 + n:]
            if tail == EOM and lab == label:
                return body
    return None


def dmx_frame(levels):
    data = bytearray(513)  # start code 0 + 512 channels
    for ch, v in levels.items():
        data[ch] = v
    return packet(LABEL_SEND_DMX, data)


def parse_levels(specs):
    levels = {}
    for spec in specs:
        key, _, val = spec.partition("=")
        if not val:
            sys.exit(f"bad '{spec}': use CH=VALUE or A-B=VALUE")
        lo, _, hi = key.partition("-")
        lo, hi, v = int(lo), int(hi or lo), int(val)
        if not (1 <= lo <= hi <= 512 and 0 <= v <= 255):
            sys.exit(f"bad '{spec}': channels 1–512, values 0–255")
        for ch in range(lo, hi + 1):
            levels[ch] = v
    return levels


def send(fd, levels, hold):
    frame = dmx_frame(levels)
    end = time.monotonic() + hold
    while True:
        write_all(fd, frame)
        if time.monotonic() >= end:
            break
        time.sleep(1 / 30)


def main():
    common = argparse.ArgumentParser(add_help=False)
    common.add_argument("--port", help="serial device (default: the only /dev/cu.usbserial-*)")
    common.add_argument("--hold", type=float, default=0.5, help="seconds to keep re-sending (default 0.5)")
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    sub.add_parser("ports", parents=[common])
    sub.add_parser("info", parents=[common])
    s = sub.add_parser("set", parents=[common])
    s.add_argument("levels", nargs="+", metavar="CH=V")
    b = sub.add_parser("blink", parents=[common])
    b.add_argument("address", type=int)
    b.add_argument("values", help="comma-separated values starting at ADDRESS, e.g. 255,17,128,0")
    b.add_argument("--times", type=int, default=3)
    sub.add_parser("blackout", parents=[common])
    a = ap.parse_args()

    ports = candidate_ports()
    if a.cmd == "ports":
        print("\n".join(ports) or "No /dev/cu.usbserial-* devices. Is the box plugged in? "
              "If Lightkey is running it may hide the port (FTDI D2XX) — quit it.")
        return
    port = a.port or (ports[0] if len(ports) == 1 else None)
    if not port:
        sys.exit("Pick a port with --port: " + (", ".join(ports) or "none found"))
    try:
        fd = open_port(port)
    except FileNotFoundError:
        sys.exit(f"{port} doesn't exist. Run `ports` to see what's plugged in.")
    except OSError as e:
        sys.exit(f"Can't open {port}: {e.strerror}. Another app probably has it — quit Lightkey/QLC+/Prism "
                 f"(`lsof {port}` shows who).")

    try:
        if a.cmd == "info":
            write_all(fd, packet(LABEL_SERIAL))
            sn = read_reply(fd, LABEL_SERIAL)
            write_all(fd, packet(LABEL_PARAMS, b"\x00\x00"))
            pr = read_reply(fd, LABEL_PARAMS)
            if sn is None and pr is None:
                sys.exit(f"{port}: no reply. Not an ENTTEC Pro (Open DMX / clones don't answer), "
                         "or another app holds it.")
            if sn and len(sn) >= 4:
                print("Serial number:", "".join(f"{b:02X}" for b in reversed(sn[:4])).lstrip("0"))
            if pr and len(pr) >= 5:
                print(f"Firmware: {pr[1]}.{pr[0]}  break: {pr[2] * 10.67:.0f} µs  "
                      f"MAB: {pr[3] * 10.67:.0f} µs  refresh: {pr[4] or 'max'} fps")
            print("Port:", port, "— OK")
        elif a.cmd == "set":
            send(fd, parse_levels(a.levels), a.hold)
            print("Sent. The box keeps outputting this frame until something else is sent.")
        elif a.cmd == "blink":
            vals = [int(x) for x in a.values.split(",") if x.strip()]
            on = {a.address + i: v for i, v in enumerate(vals) if 1 <= a.address + i <= 512}
            for _ in range(a.times):
                send(fd, on, 0.6)
                send(fd, {}, 0.4)
            print(f"Blinked {len(on)} channels from address {a.address}; left at zero.")
        elif a.cmd == "blackout":
            send(fd, {}, a.hold)
            print("All 512 channels at 0.")
    finally:
        close_port(fd)


if __name__ == "__main__":
    main()
