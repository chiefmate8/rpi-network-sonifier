#!/usr/bin/env python3
"""sonifier-viz: receives note events over UDP, streams them to browsers via SSE.

The sonifier (netsong.scd) sends OSC: /viz <proto> <note> <vel> <dur> <mac> [<delay>]
(delay = seconds until the sound starts, so the page can fly the traffic in to land on the beat)
Anything else is read as JSON, one object per UDP packet:
  {"proto": "arp", "note": 62, "vel": 80, "dur": 0.4, "src": "device ip, mac or name"}

"dur" is the note length in seconds (optional). The page uses it so a held note
lasts as long as the sound and a run of short notes gives a run of short pulses.

"src" is looked up in devices.json (ip or mac -> friendly name), so the
page can show which device fired each note.

FAKE=auto  fake events only when no real ones arrived recently (default)
FAKE=on    always generate fake events
FAKE=off   never generate fake events
"""
import json
import os
import queue
import random
import socket
import struct
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

HTTP_PORT = int(os.environ.get("HTTP_PORT", "8080"))
UDP_PORT = int(os.environ.get("UDP_PORT", "5005"))
FAKE = os.environ.get("FAKE", "auto").lower()
LIVE_TIMEOUT = 15  # seconds without real events before fake takes over (auto)
STATIC = Path(__file__).parent / "static"
DEVICES_FILE = Path(os.environ.get("DEVICES_FILE", Path(__file__).parent / "devices.json"))
_names = {"mtime": 0, "map": {}}


def device_name(src):
    """Map an ip or mac to a friendly name, reloading devices.json if it changed."""
    try:
        m = DEVICES_FILE.stat().st_mtime
        if m != _names["mtime"]:
            raw = json.loads(DEVICES_FILE.read_text())
            _names["map"] = {k.lower(): str(v) for k, v in raw.items() if not k.startswith("_")}
            _names["mtime"] = m
    except (OSError, ValueError):
        pass
    src = (src or "").strip()
    return _names["map"].get(src.lower(), src) or "unknown"

# name, {protocol: weight}, note range, how chatty
FAKE_DEVICES = [
    ("iphone",        {"mdns": 4, "https": 4, "arp": 2, "dns": 3}, (60, 88), 6),
    ("lights bridge",    {"mdns": 3, "ssdp": 3, "udp": 4, "arp": 1}, (66, 84), 3),
    ("ring doorbell", {"udp": 6, "tcp": 4, "dns": 2},           (50, 70), 3),
    ("smart speaker",    {"dns": 5, "https": 5, "mdns": 2},        (48, 66), 5),
    ("streamer",         {"mdns": 4, "arp": 3, "tcp": 2},          (55, 75), 3),
    ("server",          {"dns": 6, "tcp": 4, "mdns": 2, "arp": 1}, (40, 60), 5),
    ("router",        {"dhcp": 3, "arp": 6, "udp": 2},          (36, 52), 3),
    ("esp32 sensor",    {"udp": 5, "mdns": 3, "dns": 1},          (70, 92), 3),
    ("laptop",          {"tcp": 3, "https": 4, "dns": 4, "mdns": 3, "ssdp": 1}, (52, 76), 4),
]

clients = set()
clients_lock = threading.Lock()
last_live = 0.0
stats = {"live": 0, "fake": 0}

# audio stream switch: the page sets "want", the Pi polls it (and reports what it is actually doing)
stream = {"want": False, "actual": "unknown", "seen": 0.0}


def stream_json():
    seen = stream["seen"]
    return json.dumps({"want": stream["want"], "actual": stream["actual"],
                       "seen_ago": round(time.time() - seen, 1) if seen else None}).encode()


def broadcast(ev):
    data = "data: " + json.dumps(ev, separators=(",", ":")) + "\n\n"
    with clients_lock:
        for q in list(clients):
            try:
                q.put_nowait(data)
            except queue.Full:
                pass  # slow client, drop the event


def clean(raw):
    """Validate and normalise an incoming event. Returns dict or None."""
    try:
        d = json.loads(raw)
        note = int(d.get("note", 60))
        vel = int(d.get("vel", 80))
    except (ValueError, TypeError, AttributeError):
        return None
    try:
        dur = float(d["dur"]) if d.get("dur") is not None else None
        dur = None if dur is None else max(0.03, min(10.0, dur))
    except (ValueError, TypeError):
        dur = None
    try:
        delay = float(d["delay"]) if d.get("delay") is not None else None
        delay = None if delay is None else max(0.0, min(3.0, delay))
    except (ValueError, TypeError):
        delay = None
    proto = str(d.get("proto", "other"))[:12]
    src = device_name(str(d.get("src", ""))[:40])[:40]
    ev = {"proto": proto, "note": max(0, min(127, note)),
          "vel": max(1, min(127, vel)), "src": src, "t": time.time()}
    if dur is not None:
        ev["dur"] = round(dur, 3)
    if delay is not None:
        ev["delay"] = round(delay, 3)
    # for the cli view: which instrument played, what kind of gesture, packet size (or dBm), trigger id
    for k, n in (("inst", 16), ("gest", 12)):
        if d.get(k) is not None:
            ev[k] = str(d[k])[:n]
    for k in ("size", "trig"):
        try:
            if d.get(k) is not None:
                ev[k] = int(d[k])
        except (ValueError, TypeError):
            pass
    return ev


def parse_osc(data):
    """Read one OSC message (strings, ints and floats). Returns (address, args) or None."""
    def rd_str(i):
        end = data.index(b"\0", i)
        return data[i:end].decode("utf-8", "replace"), (end + 4) & ~3
    try:
        addr, i = rd_str(0)
        tags, i = rd_str(i)
        args = []
        for t in tags.lstrip(","):
            if t == "s":
                v, i = rd_str(i)
            elif t == "i":
                v = struct.unpack(">i", data[i:i + 4])[0]; i += 4
            elif t == "f":
                v = struct.unpack(">f", data[i:i + 4])[0]; i += 4
            elif t == "d":
                v = struct.unpack(">d", data[i:i + 8])[0]; i += 8
            elif t == "h":
                v = struct.unpack(">q", data[i:i + 8])[0]; i += 8
            else:
                return None
            args.append(v)
        return addr, args
    except (ValueError, struct.error):
        return None


def clean_osc(raw):
    msg = parse_osc(raw)
    if not msg or msg[0] != "/viz" or len(msg[1]) < 5:
        return None
    proto, note, vel, dur, src = msg[1][:5]
    d = {"proto": proto, "note": note, "vel": vel, "dur": dur, "src": src}
    if len(msg[1]) > 5:
        d["delay"] = msg[1][5]
    for k, v in zip(("inst", "gest", "size", "trig"), msg[1][6:10]):
        d[k] = v
    return clean(json.dumps(d))


def udp_listener():
    global last_live
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind(("0.0.0.0", UDP_PORT))
    print(f"udp listening on :{UDP_PORT}", flush=True)
    while True:
        raw, _ = s.recvfrom(2048)
        ev = clean_osc(raw) if raw.startswith(b"/") else clean(raw)
        if ev:
            last_live = time.time()
            stats["live"] += 1
            ev["live"] = True
            broadcast(ev)


def fake_generator():
    """Quiet gaps, then rhythm. Devices wander in and out of activity."""
    mood = 0.0
    activity = {d[0]: 1.0 for d in FAKE_DEVICES}
    next_shuffle = time.time()

    def emit(name, proto, note, dur):
        stats["fake"] += 1
        if proto == "bt":
            gest, size = "sparkle", -random.randint(45, 90)
        else:
            gest, size = random.choice(FAKE_GESTS), random.choice([60, 74, 98, 120, 342, 590, 1514])
        broadcast({"proto": proto, "note": max(24, min(108, note)),
                   "vel": random.randint(30, 127), "src": name, "dur": round(dur, 3), "delay": 0.3,
                   "inst": random.choice(FAKE_INSTS), "gest": gest, "size": size, "trig": stats["fake"],
                   "t": time.time(), "live": False})

    while True:
        time.sleep(random.expovariate(1 / (0.15 if mood > 0.5 else 0.9)))
        mood = max(0.0, mood - 0.04) + (random.random() < 0.06) * 1.0
        now = time.time()
        if now > next_shuffle:  # a random device gets loud or goes quiet
            activity[random.choice(list(activity))] = random.choice([0.05, 0.3, 1.0, 2.5])
            next_shuffle = now + random.uniform(2, 7)
        live_recent = (now - last_live) < LIVE_TIMEOUT
        if FAKE == "off" or (FAKE == "auto" and live_recent):
            continue
        if random.random() < 0.03:  # a stranger passes through
            name = "unknown %02x:%02x" % (random.randint(0, 255), random.randint(0, 255))
            devs = [(name, {random.choice(RANGES_FALLBACK): 1}, (40, 90), 1)]
        else:
            devs = FAKE_DEVICES
        name, protos, (lo, hi), _ = random.choices(
            devs, [d[3] * activity.get(d[0], 1.0) + 0.001 for d in devs])[0]
        proto = random.choices(list(protos), list(protos.values()))[0]
        base = random.randint(lo, hi)
        r = random.random()
        if r < 0.18:    # du du du: a run of short notes, each pulse as short as its note
            gap = random.uniform(0.16, 0.34)
            for i in range(random.randint(3, 5)):
                emit(name, proto, base + (0 if i % 2 == 0 else random.choice([0, 0, 5, 7])), gap * 0.55)
                time.sleep(gap)
        elif r < 0.30:  # one long held note
            emit(name, proto, base, random.uniform(1.6, 4.0))
        else:           # a short stab or a medium note
            emit(name, proto, base, random.choice([random.uniform(0.07, 0.2), random.uniform(0.25, 0.9)]))


FAKE_INSTS = ["buchla", "arp2600", "cs", "tenori", "harp", "rhodes", "microfreak", "es335", "prophet", "sub37"]
FAKE_GESTS = ["note", "call", "run", "chord", "glide", "sh", "glitch", "bass", "perc"]
RANGES_FALLBACK = ["arp", "mdns", "dns", "udp", "bt", "tcp"]


class Handler(BaseHTTPRequestHandler):
    def log_message(self, *a):
        pass

    def do_GET(self):
        path = self.path.split("?")[0]
        if path == "/events":
            return self.sse()
        if path == "/api/stream":
            qs = parse_qs(urlparse(self.path).query)
            if "is" in qs:   # the Pi reports its real state each time it polls
                stream["actual"] = qs["is"][0][:12]
                stream["seen"] = time.time()
            return self.send(200, "application/json", stream_json())
        if path == "/status":
            body = json.dumps({"fake": FAKE, "stats": stats,
                               "live_recent": (time.time() - last_live) < LIVE_TIMEOUT,
                               "clients": len(clients)}).encode()
            return self.send(200, "application/json", body)
        if path in ("/", "/index.html"):
            f = STATIC / "index.html"
            return self.send(200, "text/html; charset=utf-8", f.read_bytes())
        self.send(404, "text/plain", b"not found")

    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        if n:
            self.rfile.read(min(n, 4096))
        if self.path.split("?")[0] == "/api/stream":
            qs = parse_qs(urlparse(self.path).query)
            if "want" in qs:
                stream["want"] = qs["want"][0] in ("1", "true", "on")
            return self.send(200, "application/json", stream_json())
        self.send(404, "text/plain", b"not found")

    def send(self, code, ctype, body):
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(body)

    def sse(self):
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Accel-Buffering", "no")
        self.end_headers()
        q = queue.Queue(maxsize=500)
        with clients_lock:
            clients.add(q)
        try:
            self.wfile.write(b": connected\n\n")
            self.wfile.flush()
            while True:
                try:
                    self.wfile.write(q.get(timeout=15).encode())
                except queue.Empty:
                    self.wfile.write(b": keepalive\n\n")  # stops proxies timing out
                self.wfile.flush()
        except (BrokenPipeError, ConnectionResetError, OSError):
            pass
        finally:
            with clients_lock:
                clients.discard(q)


if __name__ == "__main__":
    threading.Thread(target=udp_listener, daemon=True).start()
    threading.Thread(target=fake_generator, daemon=True).start()
    srv = ThreadingHTTPServer(("0.0.0.0", HTTP_PORT), Handler)
    srv.daemon_threads = True
    print(f"http listening on :{HTTP_PORT} (FAKE={FAKE})", flush=True)
    srv.serve_forever()
