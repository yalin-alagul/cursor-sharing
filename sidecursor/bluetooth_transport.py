"""Native Bluetooth RFCOMM transport for macOS and Windows."""
from __future__ import annotations

import csv
import io
import platform
import socket
import subprocess
import threading
import time
from collections import deque

RFCOMM_FAMILY = 32  # AF_BTH; Python does not publish this on Windows.
RFCOMM_PROTOCOL = 3  # BTHPROTO_RFCOMM
DEFAULT_CHANNEL = 11
MAC_RFCOMM_CONNECT_TIMEOUT = 25.0
MAC_RFCOMM_RETRY_INTERVAL = 0.5


def _normalise_address(value: str) -> str:
    compact = "".join(ch for ch in value if ch.isalnum())
    if len(compact) != 12:
        raise ValueError(f"invalid Bluetooth address: {value}")
    return ":".join(compact[i:i + 2].upper() for i in range(0, 12, 2))


def _windows_bluetooth_address() -> str:
    output = subprocess.check_output(
        ["getmac", "/v", "/fo", "csv"], text=True, encoding="utf-8", errors="replace"
    )
    for row in csv.DictReader(io.StringIO(output)):
        connection = (row.get("Connection Name") or "").lower()
        physical = (row.get("Physical Address") or "").strip()
        if "bluetooth" in connection and physical and physical.lower() != "n/a":
            return _normalise_address(physical)
    raise RuntimeError("could not find the local Bluetooth adapter")


class _WindowsRFCOMMStream:
    def __init__(self, sock: socket.socket):
        self.sock = sock

    def send(self, data: bytes) -> int:
        return self.sock.send(data)

    def recv(self, size: int) -> bytes:
        return self.sock.recv(size)

    def sendall(self, data: bytes) -> None:
        self.sock.sendall(data)

    def shutdown(self, how: int) -> None:
        self.sock.shutdown(how)

    def close(self) -> None:
        self.sock.close()


def _windows_listen(channel: int) -> _WindowsRFCOMMStream:
    address = _windows_bluetooth_address()
    listener = socket.socket(RFCOMM_FAMILY, socket.SOCK_STREAM, RFCOMM_PROTOCOL)
    listener.bind((address, channel))
    listener.listen(1)
    print(f"Bluetooth RFCOMM listening on {address}, channel {channel}; waiting for the Mac...")
    sock, peer = listener.accept()
    listener.close()
    print(f"Bluetooth peer connected from {peer[0]}, channel {peer[1]}")
    return _WindowsRFCOMMStream(sock)


def _windows_connect(peer: str, channel: int) -> _WindowsRFCOMMStream:
    sock = socket.socket(RFCOMM_FAMILY, socket.SOCK_STREAM, RFCOMM_PROTOCOL)
    sock.settimeout(15)
    sock.connect((_normalise_address(peer), channel))
    sock.settimeout(None)
    print(f"Connected to Bluetooth peer {_normalise_address(peer)}, channel {channel}")
    return _WindowsRFCOMMStream(sock)


class _MacDelegate:
    def __init__(self):
        import Foundation
        import IOBluetooth
        import objc

        class Delegate(Foundation.NSObject):
            def init(self):
                self = objc.super(Delegate, self).init()
                self.queue = deque()
                self.condition = threading.Condition()
                self.closed = False
                return self

            def rfcommChannelData_data_length_(self, channel, data, length):
                del channel
                with self.condition:
                    self.queue.append(bytes(data)[: int(length)])
                    self.condition.notify_all()

            rfcommChannelData_data_length_ = objc.selector(
                rfcommChannelData_data_length_, signature=b"v@:@@I"
            )

            def rfcommChannelClosed_(self, channel):
                del channel
                with self.condition:
                    self.closed = True
                    self.condition.notify_all()

            rfcommChannelClosed_ = objc.selector(rfcommChannelClosed_, signature=b"v@:@")

        self.Foundation = Foundation
        self.IOBluetooth = IOBluetooth
        self.delegate = Delegate.alloc().init()


class _MacRFCOMMStream:
    def __init__(self, device, channel, bridge: _MacDelegate):
        self.device = device
        self.channel = channel
        self._bridge = bridge  # keep the Objective-C delegate alive
        self._send_lock = threading.Lock()

    @classmethod
    def connect(cls, peer: str, channel_id: int) -> "_MacRFCOMMStream":
        bridge = _MacDelegate()
        address = _normalise_address(peer)
        device = bridge.IOBluetooth.IOBluetoothDevice.deviceWithAddressString_(address)
        if device is None:
            raise ConnectionError(f"Bluetooth device {address} is not available")
        deadline = time.monotonic() + MAC_RFCOMM_CONNECT_TIMEOUT
        last_status = None
        next_notice = 0.0
        while True:
            if not device.isConnected():
                status = device.openConnection()
                if status != 0:
                    last_status = status
            if device.isConnected():
                status, channel = device.openRFCOMMChannelSync_withChannelID_delegate_(
                    None, channel_id, bridge.delegate
                )
                last_status = status
                if status == 0 and channel is not None and channel.isOpen():
                    channel.setDelegate_(bridge.delegate)
                    print(f"Connected to Bluetooth peer {address}, RFCOMM channel {channel_id}")
                    return cls(device, channel, bridge)
                if channel is not None:
                    channel.closeChannel()
            now = time.monotonic()
            if now >= deadline:
                raise ConnectionError(
                    f"could not open RFCOMM channel {channel_id} after "
                    f"{MAC_RFCOMM_CONNECT_TIMEOUT:.0f}s (last status {last_status}). "
                    "Start the Windows Bluetooth client first and keep it running."
                )
            if now >= next_notice:
                print(
                    f"Waiting for Bluetooth RFCOMM channel {channel_id} on {address}; "
                    "make sure the Windows client is listening..."
                )
                next_notice = now + 5.0
            time.sleep(MAC_RFCOMM_RETRY_INTERVAL)

    def send(self, data: bytes) -> int:
        with self._send_lock:
            mtu = int(self.channel.getMTU())
            sent = 0
            while sent < len(data):
                chunk = data[sent:sent + mtu]
                status = self.channel.writeSync_length_(chunk, len(chunk))
                if status != 0:
                    raise OSError(f"Bluetooth write failed (status {status})")
                sent += len(chunk)
            return sent

    def sendall(self, data: bytes) -> None:
        self.send(data)

    def recv(self, size: int) -> bytes:
        condition = self._bridge.delegate.condition
        while True:
            with condition:
                if self._bridge.delegate.queue:
                    payload = self._bridge.delegate.queue.popleft()
                    if len(payload) > size:
                        self._bridge.delegate.queue.appendleft(payload[size:])
                        return payload[:size]
                    return payload
                if self._bridge.delegate.closed:
                    return b""
                condition.wait(timeout=0.05)
            # Do this outside the condition lock: callbacks use the same lock
            # to enqueue data, and holding it while pumping Cocoa would deadlock.
            self._bridge.Foundation.NSRunLoop.currentRunLoop().runUntilDate_(
                self._bridge.Foundation.NSDate.dateWithTimeIntervalSinceNow_(0.05)
            )

    def shutdown(self, how: int) -> None:
        del how  # RFCOMM has no separate half-close operation in IOBluetooth.

    def close(self) -> None:
        try:
            self.channel.setDelegate_(None)
            self.channel.closeChannel()
        finally:
            self.device.closeConnection()


def listen_and_accept(channel: int = DEFAULT_CHANNEL):
    if platform.system() != "Windows":
        raise RuntimeError("Bluetooth listener mode is currently implemented on Windows")
    return _windows_listen(channel)


def connect_to_peer(peer: str, channel: int = DEFAULT_CHANNEL):
    if platform.system() == "Windows":
        return _windows_connect(peer, channel)
    if platform.system() == "Darwin":
        return _MacRFCOMMStream.connect(peer, channel)
    raise RuntimeError("Bluetooth RFCOMM transport requires macOS or Windows")
