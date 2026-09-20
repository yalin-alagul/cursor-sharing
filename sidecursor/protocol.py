from __future__ import annotations

import base64
import hashlib
import hmac
import json
import secrets
import socket
import struct
import threading
from dataclasses import dataclass

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import ChaCha20Poly1305
from cryptography.hazmat.primitives.kdf.hkdf import HKDF

MAX_FRAME = 2 * 1024 * 1024


def _b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode("ascii")


def _unb64(value: str) -> bytes:
    return base64.urlsafe_b64decode(value.encode("ascii"))


def _send_all(sock, data: bytes) -> None:
    sendall = getattr(sock, "sendall", None)
    if sendall is not None:
        sendall(data)
        return
    sent = 0
    while sent < len(data):
        count = sock.send(data[sent:])
        if not count:
            raise ConnectionError("peer closed the connection while sending")
        sent += count


def _send_plain(sock, message: dict) -> None:
    data = json.dumps(message, separators=(",", ":")).encode("utf-8")
    _send_all(sock, struct.pack("!I", len(data)) + data)


def _recv_exact(sock: socket.socket, size: int) -> bytes:
    chunks = bytearray()
    while len(chunks) < size:
        chunk = sock.recv(size - len(chunks))
        if not chunk:
            raise ConnectionError("peer closed the connection")
        chunks.extend(chunk)
    return bytes(chunks)


def _recv_plain(sock: socket.socket) -> dict:
    size = struct.unpack("!I", _recv_exact(sock, 4))[0]
    if size > MAX_FRAME:
        raise ValueError("handshake frame is too large")
    return json.loads(_recv_exact(sock, size).decode("utf-8"))


def _derive_key(shared_secret: bytes, token: str, server_nonce: bytes, client_nonce: bytes) -> bytes:
    salt = hashlib.sha256(server_nonce + client_nonce).digest()
    return HKDF(algorithm=hashes.SHA256(), length=32, salt=salt,
                info=b"sidecursor-v1:" + token.encode("utf-8")).derive(shared_secret)


@dataclass
class SecureChannel:
    sock: socket.socket
    key: bytes
    is_server: bool

    def __post_init__(self) -> None:
        self._send_lock = threading.Lock()

    @classmethod
    def accept(cls, sock: socket.socket, token: str) -> "SecureChannel":
        server_key = X25519PrivateKey.generate()
        server_pub = server_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        server_nonce = secrets.token_bytes(16)
        _send_plain(sock, {"type": "server_hello", "pub": _b64(server_pub), "nonce": _b64(server_nonce)})
        hello = _recv_plain(sock)
        if hello.get("type") != "client_hello":
            raise ValueError("invalid client handshake")
        client_pub = _unb64(hello["pub"])
        client_nonce = _unb64(hello["nonce"])
        transcript = server_pub + client_pub + server_nonce + client_nonce
        expected = hmac.new(token.encode("utf-8"), transcript, hashlib.sha256).digest()
        if not hmac.compare_digest(expected, _unb64(hello["proof"])):
            raise PermissionError("shared token rejected")
        shared = server_key.exchange(X25519PublicKey.from_public_bytes(client_pub))
        key = _derive_key(shared, token, server_nonce, client_nonce)
        _send_plain(sock, {"type": "server_accept", "proof": _b64(hmac.new(key, b"accept", hashlib.sha256).digest())})
        return cls(sock, key, True)

    @classmethod
    def connect(cls, sock: socket.socket, token: str) -> "SecureChannel":
        hello = _recv_plain(sock)
        if hello.get("type") != "server_hello":
            raise ValueError("invalid server handshake")
        server_pub = _unb64(hello["pub"])
        server_nonce = _unb64(hello["nonce"])
        client_key = X25519PrivateKey.generate()
        client_pub = client_key.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
        client_nonce = secrets.token_bytes(16)
        transcript = server_pub + client_pub + server_nonce + client_nonce
        proof = hmac.new(token.encode("utf-8"), transcript, hashlib.sha256).digest()
        _send_plain(sock, {"type": "client_hello", "pub": _b64(client_pub), "nonce": _b64(client_nonce), "proof": _b64(proof)})
        accepted = _recv_plain(sock)
        shared = client_key.exchange(X25519PublicKey.from_public_bytes(server_pub))
        key = _derive_key(shared, token, server_nonce, client_nonce)
        expected = hmac.new(key, b"accept", hashlib.sha256).digest()
        if accepted.get("type") != "server_accept" or not hmac.compare_digest(expected, _unb64(accepted["proof"])):
            raise PermissionError("server did not accept the shared token")
        return cls(sock, key, False)

    def send(self, message: dict) -> None:
        plaintext = json.dumps(message, separators=(",", ":")).encode("utf-8")
        nonce = secrets.token_bytes(12)
        ciphertext = ChaCha20Poly1305(self.key).encrypt(nonce, plaintext, None)
        frame = nonce + ciphertext
        if len(frame) > MAX_FRAME:
            raise ValueError("frame is too large")
        with self._send_lock:
            _send_all(self.sock, struct.pack("!I", len(frame)) + frame)

    def recv(self) -> dict:
        size = struct.unpack("!I", _recv_exact(self.sock, 4))[0]
        if size < 12 or size > MAX_FRAME:
            raise ValueError("encrypted frame has an invalid size")
        frame = _recv_exact(self.sock, size)
        plaintext = ChaCha20Poly1305(self.key).decrypt(frame[:12], frame[12:], None)
        return json.loads(plaintext.decode("utf-8"))

    def close(self) -> None:
        try:
            self.sock.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        self.sock.close()


def listen_and_accept(bind: str, port: int, token: str) -> SecureChannel:
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((bind, port))
    listener.listen(1)
    print(f"Listening on {bind}:{port}; waiting for a peer...")
    sock, address = listener.accept()
    listener.close()
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    print(f"Peer connected from {address[0]}:{address[1]}")
    return SecureChannel.accept(sock, token)


def connect_to_peer(peer: str, port: int, token: str) -> SecureChannel:
    sock = socket.create_connection((peer, port), timeout=12)
    sock.settimeout(None)
    sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
    channel = SecureChannel.connect(sock, token)
    print(f"Connected to {peer}:{port}")
    return channel
