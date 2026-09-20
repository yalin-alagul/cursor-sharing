from __future__ import annotations

import argparse
import hashlib
import collections
import sys
import threading
import time

from . import __version__
from .discovery import discover_peer, start_advertiser
from .platform import make_adapter
from .protocol import SecureChannel, connect_to_peer, listen_and_accept
from .tray import run_tray, start_tray, stop_tray


class OutboundPump:
    """Keep the input hook non-blocking and discard stale mouse positions."""

    def __init__(self, channel):
        self.channel = channel
        self._controls = collections.deque()
        self._latest_mouse = None
        self._condition = threading.Condition()
        self._stopped = False
        self._thread = threading.Thread(target=self._run, name="sidecursor-send", daemon=True)
        self._thread.start()

    def send(self, message: dict):
        with self._condition:
            if self._stopped:
                return
            if message.get("type") == "event" and message.get("event", {}).get("kind") == "mouse_move":
                self._latest_mouse = message
            else:
                self._controls.append(message)
            self._condition.notify()

    def _run(self):
        while True:
            with self._condition:
                while not self._stopped and not self._controls and self._latest_mouse is None:
                    self._condition.wait()
                if self._stopped:
                    return
                if self._controls:
                    message = self._controls.popleft()
                else:
                    message = self._latest_mouse
                    self._latest_mouse = None
            try:
                self.channel.send(message)
            except (ConnectionError, OSError):
                return

    def stop(self):
        with self._condition:
            self._stopped = True
            self._condition.notify_all()


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="SideCursor peer cursor, keyboard, and clipboard sharing")
    parser.add_argument("role", choices=("server", "client"), help="server listens; client connects")
    parser.add_argument("--token", required=True, help="same long random token on both peers")
    parser.add_argument("--port", type=int, default=24800)
    parser.add_argument("--bind", default="0.0.0.0", help="server bind address")
    parser.add_argument("--peer", help="client target IPv4 address")
    parser.add_argument(
        "--transport", choices=("tcp", "bluetooth"), default="tcp",
        help="connection transport (Bluetooth uses a separate RFCOMM link)",
    )
    parser.add_argument(
        "--bluetooth-peer", metavar="MAC",
        help="paired peer Bluetooth address, e.g. 54:14:F3:78:6E:D6",
    )
    parser.add_argument(
        "--bluetooth-channel", type=int, default=11,
        help="RFCOMM channel (must match on both computers; default: 11)",
    )
    return parser


def run(args: argparse.Namespace) -> None:
    print(f"SideCursor {__version__} — multi-monitor handoff build")
    if len(args.token) < 16:
        raise SystemExit("--token must be at least 16 characters")
    stop = threading.Event()
    advertiser = start_advertiser(args.port, stop) if args.role == "server" and args.transport == "tcp" else None
    if args.transport == "bluetooth":
        from .bluetooth_transport import connect_to_peer as bluetooth_connect
        from .bluetooth_transport import listen_and_accept as bluetooth_listen
        if not args.bluetooth_peer:
            raise SystemExit("--bluetooth-peer is required with --transport bluetooth")
        if sys.platform == "win32":
            # Windows owns the RFCOMM listener. This preserves the existing
            # input roles while moving the data plane off the IP network.
            channel = SecureChannel.accept(
                bluetooth_listen(args.bluetooth_channel), args.token
            )
        else:
            # macOS opens the paired Windows listener as its Bluetooth client.
            channel = SecureChannel.connect(
                bluetooth_connect(args.bluetooth_peer, args.bluetooth_channel), args.token
            )
    elif args.role == "server":
        channel = listen_and_accept(args.bind, args.port, args.token)
    else:
        peer, port = (args.peer, args.port) if args.peer else discover_peer()
        channel = connect_to_peer(peer, port, args.token)
    outbound = OutboundPump(channel)
    adapter = make_adapter(outbound.send)
    last_clipboard_hash = {"value": None}

    def send_clipboard(text: str) -> None:
        digest = hashlib.sha256(text.encode("utf-8")).hexdigest()
        if digest == last_clipboard_hash["value"]:
            return
        last_clipboard_hash["value"] = digest
        outbound.send({"type": "clipboard", "text": text})

    def receive_loop() -> None:
        try:
            while not stop.is_set():
                message = channel.recv()
                kind = message.get("type")
                if kind == "event":
                    adapter.inject(message["event"])
                elif kind == "control" and message.get("action") == "enter_remote_mode":
                    enter = getattr(adapter, "prepare_remote_entry", None)
                    if enter:
                        enter(message.get("y"), message.get("source_width"), message.get("source_height"))
                elif kind == "control" and message.get("action") == "release_remote_mode":
                    release = getattr(adapter, "release_remote_mode", None)
                    if release:
                        release(message.get("y"))
                elif kind == "clipboard":
                    text = message.get("text", "")
                    last_clipboard_hash["value"] = hashlib.sha256(text.encode("utf-8")).hexdigest()
                    adapter.set_clipboard(text)
                elif kind == "ping":
                    outbound.send({"type": "pong", "time": message.get("time")})
        except (ConnectionError, OSError, ValueError) as exc:
            print(f"Peer disconnected: {exc}")
        finally:
            stop.set()

    runtime_started = threading.Event()

    def start_runtime():
        if runtime_started.is_set():
            return
        # The server/capturing side owns the local input hooks. The client side
        # remains an injector and clipboard peer instead of stealing its own input.
        adapter.start(send_clipboard, capture=args.role == "server")
        threading.Thread(target=receive_loop, name="sidecursor-receive", daemon=True).start()
        runtime_started.set()
        print("Ready. Press Ctrl+Alt+F8 to toggle remote mode; Ctrl+C exits.")

    tray = start_tray(adapter, stop)
    try:
        if sys.platform == "darwin" and tray is not None:
            def stop_tray_when_done():
                stop.wait()
                stop_tray(tray)

            threading.Thread(target=stop_tray_when_done, name="sidecursor-tray-stop", daemon=True).start()

            def setup_mac_tray(icon):
                try:
                    icon.visible = True
                    start_runtime()
                except Exception as exc:
                    print(f"Mac runtime failed to start: {exc}")
                    stop.set()
                    icon.stop()

            # The Cocoa application must be running before Quartz installs the
            # global event tap. pystray invokes setup after NSApplication starts.
            run_tray(tray, setup=setup_mac_tray)
        else:
            start_runtime()
            while not stop.is_set():
                time.sleep(0.5)
    except KeyboardInterrupt:
        pass
    finally:
        stop.set()
        if runtime_started.is_set():
            adapter.stop()
        outbound.stop()
        stop_tray(tray)
        channel.close()


def main() -> None:
    run(build_parser().parse_args())


if __name__ == "__main__":
    main()
