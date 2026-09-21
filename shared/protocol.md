# SideCursor native protocol v2

The native apps use this protocol only with an explicitly paired peer.  It is
transport-agnostic: Tailscale TCP is the default byte stream and Bluetooth
RFCOMM is an optional byte stream.  A native v2 peer never talks to the legacy
Python protocol.

## Pairing and handshake

For Tailscale TCP, the Mac listens and Windows connects. For Bluetooth RFCOMM,
Windows advertises the SideCursor service UUID
`2A99401E-C4A4-4CD4-9AB1-8090C2444BB6`; the Mac performs Bluetooth SDP
discovery and opens the resulting live RFCOMM channel. In both cases the Mac
is the logical handshake server and sends `hello`; Windows replies with
`pair`. Neither side guesses or persists a dynamic RFCOMM channel.

Both sides receive the same 32-byte pairing secret through the pairing UI. It
is stored in Keychain or Windows DPAPI and must never appear in logs.

Each handshake begins with length-prefixed UTF-8 JSON, limited to 16 KiB:

```json
{"v":2,"kind":"hello","pub":"base64url-x25519-public-key","nonce":"base64url-16-bytes"}
{"v":2,"kind":"pair","pub":"base64url-x25519-public-key","nonce":"base64url-16-bytes","proof":"base64url-hmac"}
{"v":2,"kind":"accept","proof":"base64url-hmac"}
```

`proof` for `pair` is HMAC-SHA256(pairingSecret,
serverPublic || clientPublic || serverNonce || clientNonce).  Both peers derive
the 32-byte session key with X25519 followed by HKDF-SHA256:

- input key material: X25519 shared secret
- salt: SHA256(serverNonce || clientNonce)
- info: UTF-8 `SideCursor/v2` followed by the pairing secret

`accept.proof` is HMAC-SHA256(sessionKey, UTF-8 `accept`).  Invalid messages,
wrong versions, failed proofs, or oversized frames close the connection.

## Encrypted frame

Every post-handshake frame is:

```text
uint32-be payloadLength
uint64-be sequence
12-byte ChaCha20-Poly1305 nonce
ciphertext-and-16-byte-tag
```

The encrypted plaintext is compact UTF-8 JSON.  A receiving peer requires an
exactly increasing sequence (`last + 1`), which rejects replay, duplicates, and
out-of-order data.  The sequence header is included as AEAD additional
authenticated data.  The receiver must authenticate the frame before it commits
the new sequence, so a forged frame cannot consume the next sequence number.

The default Tailscale TCP port is `24800`.  The Mac listens on it; Windows
connects to the Mac's Tailscale address and this port.

`interop-vectors.json` contains deterministic handshake and encrypted-frame
fixtures.  Both native test suites must validate them before a release.  In the
fixture, `frame.combined` is the AEAD body only (`nonce || ciphertext || tag`).
To reconstruct the wire frame, read `frame.sequence` as uint64 big-endian and
prepend it to `frame.combined`, then prefix the resulting length as uint32
big-endian.  The 12-byte nonce is not required to follow the sender's
`random-4-byte-prefix || sequence` construction; the sequence is always taken
from the wire header and never from the nonce.

## Messages

```json
{"type":"enter_request","id":"uuid","y":0.5,"source":{"display":"stable-id","width":2048,"height":1152}}
{"type":"enter_ack","id":"uuid"}
{"type":"enter_reject","id":"uuid","reason":"target unavailable"}
{"type":"input","event":{"kind":"pointer","dx":4,"dy":-2}}
{"type":"input","event":{"kind":"button","button":"left","down":true}}
{"type":"input","event":{"kind":"scroll","horizontal":0,"vertical":-1}}
{"type":"input","event":{"kind":"key","vk":17,"down":true,"extended":false}}
{"type":"command","name":"desktop_left"}
{"type":"return_request","id":"uuid","y":0.5}
{"type":"return_ack","id":"uuid"}
{"type":"release_all","reason":"disconnect"}
{"type":"clipboard","origin":"peer-uuid","text":"plain text"}
{"type":"ping","sentAtMs":0}
{"type":"pong","sentAtMs":0}
```

Maximum clipboard text is 1 MiB and maximum encrypted frame is 2 MiB.  Mouse
motion may be coalesced; buttons, key transitions, mode transitions, and
`release_all` are ordered and never discarded.

## Required safety behavior

- A Mac controller does not enter `Remote` until both `enter_ack` and local
  cursor capture succeed.
- A Windows receiver sends `return_request` once when its configured left edge
  is crossed, releases held input, and waits for `return_ack`.
- Either peer sends `release_all` before closing a remote session.
- Any transport, permission, display, or input-hook failure returns the Mac to
  local control immediately and releases Windows input.
