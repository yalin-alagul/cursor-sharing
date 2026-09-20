# SideCursor

SideCursor is a low-latency, peer-to-peer cursor, keyboard, and clipboard sharing prototype for macOS and Windows.

It is intentionally split into two layers:

1. The **link layer** creates a direct IP path between the computers. This can be a Wi-Fi Direct group, a macOS Personal Hotspot/peer link, USB tethering, or another point-to-point interface. The application does not need both computers on the same ordinary LAN.
2. The **SideCursor layer** listens or connects over that path, authenticates the peer with a shared token, encrypts frames with X25519 + ChaCha20-Poly1305, and transports input and clipboard events.

macOS AWDL and Windows Wi-Fi Direct are controlled by different private/platform APIs. There is no stable public API that lets one portable Python program negotiate an arbitrary Mac-to-Windows Wi-Fi Direct group. The included scripts therefore prepare/check the OS link, while SideCursor handles the fast data plane once the link has an IP address.

## Requirements

- Python 3.10 or newer on both computers
- `cryptography`
- macOS: grant the terminal/Python process **Accessibility** permission in System Settings → Privacy & Security → Accessibility
- Windows: run the terminal as the same user that owns the desktop session; elevated access may be needed for global hooks on protected applications

Install the dependencies:

```bash
python3 -m pip install -r requirements.txt
```

## Quick start

On the computer that should capture input, run the server. It advertises itself on the local/direct Wi-Fi link:

```bash
python3 mac_sidecursor.py server --token 'replace-with-a-long-random-token'
```

On Windows, after the direct link is established, run the client without an IP:

```powershell
py -3.12 windows_sidecursor.py client --token "replace-with-a-long-random-token"
```

The server binds to `0.0.0.0:24800` and advertises on UDP `24801`. Use `--peer <address>` only as a fallback. Discovery only works after the operating system has created a direct/local link; it does not create the Wi-Fi Direct group itself. The supplied SSH endpoint is useful for copying or launching the Windows package, but SSH is not used as the cursor transport.

### Bluetooth RFCOMM

After pairing the computers in their Bluetooth settings, Bluetooth can be used
as a separate link while both machines remain connected to IllinoisNet. Start
Windows first so it can own the RFCOMM listener, then start macOS with the
Windows adapter address:

```powershell
py -3.12 windows_sidecursor.py client --transport bluetooth --bluetooth-peer 54:14:F3:78:6E:D6 --token "replace-with-a-long-random-token"
```

```bash
python3 mac_sidecursor.py server --transport bluetooth --bluetooth-peer 54:14:F3:78:6E:D6 --token 'replace-with-a-long-random-token'
```

The default RFCOMM channel is 11; pass `--bluetooth-channel` on both sides if
another paired service already occupies it. This mode does not use IllinoisNet,
Tailscale, or an IP address for SideCursor traffic.

SideCursor adds a small cursor icon to the macOS menu bar or Windows notification area. On the Mac server, move the cursor into the right edge of the screen to enter Windows-control mode. **Ctrl+Alt+F8** is also available as a manual toggle. In remote mode, mouse and keyboard events on the Mac are forwarded as relative input and suppressed locally. Clipboard synchronization remains bidirectional while connected.

## Direct Wi-Fi link

The application needs an IP address on the direct interface. It does not assume the normal home/office LAN:

- On Windows, inspect Wi-Fi Direct support with `powershell -ExecutionPolicy Bypass -File tools/windows_link_check.ps1`.
- On macOS, use a Personal Hotspot or a peer-to-peer Wi-Fi interface and inspect addresses with `ifconfig`.
- Verify reachability from Windows with `Test-NetConnection <mac-ip> -Port 24800`.
- If the Wi-Fi Direct group assigns a different peer address, pass that address to `--peer`.

The transport uses TCP for reliable control/clipboard messages and encrypted compact frames. Mouse movement is coalesced so stale positions do not build up behind the network. On Windows, SideCursor enables per-monitor DPI awareness for its input threads before reading desktop metrics, and each Mac-to-Windows handoff scales relative motion to the two active desktop sizes. Different resolutions and Retina scaling therefore do not need a shared configuration. The pointer enters Windows two physical pixels from its left edge (rather than jumping 160--320 pixels inward), and the Mac checks the edge of the display that currently contains the cursor.

## Layout

```text
sidecursor/
  app.py          command-line runtime and connection orchestration
  protocol.py     authenticated encrypted framed transport
  platform.py     platform adapter selection
  mac.py          Quartz/AppKit global events and clipboard
  windows.py      Win32 low-level hooks, SendInput, and clipboard
mac_sidecursor.py
windows_sidecursor.py
tools/windows_link_check.ps1
```

This is an MVP foundation: it provides the core path and platform adapters, but it does not yet include a polished tray UI, multi-monitor edge routing, or automatic Wi-Fi Direct group negotiation.
