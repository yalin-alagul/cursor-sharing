from __future__ import annotations

import json
import socket
import threading
import time

DISCOVERY_PORT = 24801
MAGIC = "sidecursor-discovery-v1"


def _is_tailscale(address: str) -> bool:
    parts = address.split(".")
    if len(parts) != 4:
        return False
    try:
        value = tuple(int(part) for part in parts)
    except ValueError:
        return False
    return value[0] == 100 and 64 <= value[1] <= 127


def start_advertiser(port: int, stop_event: threading.Event):
    """Advertise the listener on the local broadcast domain only.

    Broadcast packets do not traverse Tailscale or the wider internet. The
    advertised address is used only as a rendezvous hint; the encrypted token
    handshake still authenticates the peer before any input is accepted.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    message = json.dumps({"magic": MAGIC, "port": port, "name": socket.gethostname()}, separators=(",", ":")).encode()

    def loop():
        try:
            while not stop_event.is_set():
                try:
                    sock.sendto(message, ("255.255.255.255", DISCOVERY_PORT))
                except OSError:
                    pass
                stop_event.wait(0.5)
        finally:
            sock.close()

    thread = threading.Thread(target=loop, name="sidecursor-discovery-advertiser", daemon=True)
    thread.start()
    return thread


def discover_peer(timeout: float = 20.0) -> tuple[str, int]:
    """Find the first SideCursor server on a local/direct Wi-Fi link."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    sock.settimeout(0.5)
    try:
        sock.bind(("", DISCOVERY_PORT))
        deadline = time.monotonic() + timeout
        print("Discovering SideCursor on the local/direct Wi-Fi link...")
        while time.monotonic() < deadline:
            try:
                data, address = sock.recvfrom(4096)
            except socket.timeout:
                continue
            if _is_tailscale(address[0]):
                continue
            try:
                message = json.loads(data.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError):
                continue
            if message.get("magic") == MAGIC:
                port = int(message.get("port", 24800))
                print(f"Found {message.get('name', 'peer')} at {address[0]}:{port}")
                return address[0], port
    finally:
        sock.close()
    raise TimeoutError("No SideCursor peer found on the direct/local Wi-Fi link")
