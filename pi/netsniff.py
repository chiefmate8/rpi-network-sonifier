#!/usr/bin/env python3
"""
netsniff.py - listens to the network and tells SuperCollider about each packet.

Sends an OSC message /packet <type> <size> <source MAC> to SuperCollider
(netsong.scd) for every packet it hears. Only metadata - never contents.
Needs python3-scapy. Run with sudo (packet capture needs root).
"""

import argparse
import socket
import struct

from scapy.all import ARP, TCP, UDP, Ether, get_if_hwaddr, sniff


def osc_str(s):
    b = s.encode() + b"\0"
    return b + b"\0" * (-len(b) % 4)


def osc_packet(kind, size, mac):
    return osc_str("/packet") + osc_str(",sis") + osc_str(kind) + struct.pack(">i", size) + osc_str(mac)


def classify(pkt):
    if pkt.haslayer(ARP):
        return "arp"
    if pkt.haslayer(UDP):
        ports = {pkt[UDP].sport, pkt[UDP].dport}
        if 5353 in ports:
            return "mdns"
        if 53 in ports:
            return "dns"
        if ports & {67, 68}:
            return "dhcp"
        if 1900 in ports:
            return "ssdp"
        return "udp"
    if pkt.haslayer(TCP):
        ports = {pkt[TCP].sport, pkt[TCP].dport}
        return "https" if 443 in ports else "tcp"
    return None


def source_mac(pkt):
    if pkt.haslayer(ARP):
        return pkt[ARP].hwsrc
    if pkt.haslayer(Ether):
        return pkt[Ether].src
    return "unknown"


def main():
    p = argparse.ArgumentParser(description="Send network packet metadata to SuperCollider.")
    p.add_argument("--iface", default="wlan0", help="interface to listen on (wlan0 or eth0)")
    p.add_argument("--filter", default=None,
                   help="BPF filter. Default ignores SSH, the visualiser and stream traffic (ports 5005, 8000, 8095) "
                        "and anything sent by this Pi itself, so the sonifier never hears its own voice")
    p.add_argument("--port", type=int, default=57120, help="SuperCollider (sclang) OSC port")
    args = p.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    target = ("127.0.0.1", args.port)

    def on_packet(pkt):
        kind = classify(pkt)
        if kind:
            try:
                sock.sendto(osc_packet(kind, len(pkt), source_mac(pkt)), target)
            except OSError:
                pass   # SuperCollider not ready yet

    flt = args.filter or f"not port 22 and not port 5005 and not port 8000 and not port 8095 and not ether src {get_if_hwaddr(args.iface)}"
    print(f"Listening on {args.iface} (filter: {flt}), sending to SuperCollider on port {args.port}. Ctrl+C to stop.")
    sniff(iface=args.iface, filter=flt, prn=on_packet, store=False)


if __name__ == "__main__":
    main()
