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
{"type":"enter_request","id":"uuid","y":0.5,"source":{"display":"stable-id","width":2048,"height":1152,"widthMm":287,"heightMm":179},"target":{"display":"windows-id","x":8,"y":576}}
{"type":"enter_ack","id":"uuid"}
{"type":"enter_reject","id":"uuid","reason":"target unavailable"}
{"type":"input","event":{"kind":"pointer","dx":4,"dy":-2}}
{"type":"input","event":{"kind":"button","button":"left","down":true}}
{"type":"input","event":{"kind":"scroll","horizontal":0,"vertical":-1}}
{"type":"input","event":{"kind":"key","vk":17,"down":true,"extended":false}}
{"type":"input","event":{"kind":"zoom","steps":1}}
{"type":"command","name":"desktop_left"}
{"type":"return_request","id":"uuid","y":0.5,"mac":{"display":"stable-id","edge":"right","x":1440,"y":450}}
{"type":"return_ack","id":"uuid"}
{"type":"release_all","reason":"disconnect"}
{"type":"clipboard","origin":"peer-uuid","text":"plain text"}
{"type":"clipboard_part","origin":"peer-uuid","id":"uuid","index":0,"count":640,"text":"first 16 KiB"}
{"type":"ping","sentAtMs":0}
{"type":"pong","sentAtMs":0}
{"type":"displays","displays":[{"id":"windows-id","name":"DELL S2725QS","x":0,"y":0,"width":3840,"height":2160,"widthMm":597,"heightMm":336,"primary":true}]}
{"type":"layout","displays":[{"id":"windows-id","widthMm":597,"heightMm":336}],"zones":[{"display":"windows-id","edge":"left","line":0,"start":505,"end":1656,"mac":{"display":"stable-id","edge":"right","line":1440,"start":0,"end":900}}]}
```

### Physical display layout

Windows sends `displays` (pixels in its virtual desktop, sizes from EDID,
zero when unknown) when a session starts and whenever its displays change.
The Mac places those displays around its own in millimetres, from the user's
arrangement, and replies with `layout`: the corrected Windows display sizes
and one zone per stretch where a Windows edge physically touches a Mac edge.
Along-edge coordinates increase the same way on both platforms, so a zone's
Windows `start`/`end` (pixels) map linearly onto its `mac` `start`/`end`
(points); `line` is each edge's coordinate.

With a layout, `enter_request.target` names the Windows display and pixel the
pointer physically arrives at, and `source.widthMm`/`heightMm` let Windows
scale motion so it covers the same physical distance. The pointer then moves
across every Windows display; leaving through a zone sends `return_request`
with `mac`, the matching point on the Mac edge, and any other outer edge stops
the pointer. Without `target` (older Macs), Windows uses its configured target
display, `y`, and its left edge as before; without `displays` (older Windows),
the Mac uses its configured source display's right edge.

Maximum clipboard text is 10 MiB and maximum encrypted frame is 2 MiB. Text
over 16 KiB is sent as ordered `clipboard_part` messages of at most 16 KiB
(UTF-8, split only at character boundaries), sending each part after the
previous one has been written so input keeps flowing between parts. The
receiver joins them once all `count` parts of an `id` arrive; a gap, a new
`id`, or a total over the limit discards the partial text. A single
`clipboard` message stays at or under 1 MiB.  Mouse
motion may be coalesced; buttons, key transitions, mode transitions, and
`release_all` are ordered and never discarded.

## Required safety behavior

- A Mac controller does not enter `Remote` until both `enter_ack` and local
  cursor capture succeed.
- A Windows receiver sends `return_request` once when the pointer leaves
  through a return zone (or, without a layout, its configured left edge),
  releases held input, and waits for `return_ack`.
- Either peer sends `release_all` before closing a remote session.
- Any transport, permission, display, or input-hook failure returns the Mac to
  local control immediately and releases Windows input.
