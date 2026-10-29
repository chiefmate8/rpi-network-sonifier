#!/usr/bin/env python3
"""blesniff.py - listens for Bluetooth LE beacons and tells SuperCollider about them.
Sends /ble <maker> <signal strength> <short anonymous id> - never contents, and each device at most every few seconds."""
import asyncio, hashlib, os, socket, struct, time
from bleak import BleakScanner

MAKERS = {0x004C: "apple", 0x0075: "samsung", 0x0006: "microsoft", 0x00E0: "google"}
GAP = 4.0                      # seconds between sounds for the same device
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
last = {}
SALT = os.urandom(8)           # random each run, so the short ids can't be traced back to a device

def osc_str(s):
    b = s.encode() + b"\0"
    return b + b"\0" * (-len(b) % 4)

def heard(device, adv):
    now = time.monotonic()
    if now - last.get(device.address, 0) < GAP:
        return
    last[device.address] = now
    ids = list(adv.manufacturer_data.keys())
    maker = MAKERS.get(ids[0], "other") if ids else "anon"
    rssi = int(adv.rssi if adv.rssi is not None else -90)
    ident = hashlib.sha1(SALT + device.address.encode()).hexdigest()[:4]   # lets the visualiser tell devices apart
    msg = osc_str("/ble") + osc_str(",sis") + osc_str(maker) + struct.pack(">i", rssi) + osc_str(ident)
    try:
        sock.sendto(msg, ("127.0.0.1", 57120))
    except OSError:
        pass

async def main():
    scanner = BleakScanner(detection_callback=heard)
    await scanner.start()
    print("Listening for Bluetooth beacons. Ctrl+C to stop.")
    while True:
        await asyncio.sleep(60)
        cutoff = time.monotonic() - 600          # forget devices not heard for 10 minutes
        for addr in [a for a, t in last.items() if t < cutoff]:
            del last[addr]

asyncio.run(main())
