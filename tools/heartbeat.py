"""Send the KY UFO keep-alive (bytes 01 01 to UDP 7099 once a second) and print replies.

Usage: python heartbeat.py [drone_ip]
Run this on a PC connected to the drone's Wi-Fi, then open the RTSP stream in ffplay/VLC
in another window. Sends nothing else; no flight commands.
"""
import socket
import sys
import time

host = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.1"
sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
sock.settimeout(1.0)
print(f"keep-alive -> {host}:7099 every 1 s (Ctrl+C to stop)")
while True:
    sock.sendto(b"\x01\x01", (host, 7099))
    try:
        data, addr = sock.recvfrom(1024)
        print(f"reply from {addr[0]}: {data.hex(' ')}")
    except socket.timeout:
        print("no reply")
    time.sleep(1.0)
