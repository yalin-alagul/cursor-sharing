# SideCursor

Use one Mac keyboard, mouse and trackpad on a Windows PC. Move the pointer off
the edge of your Mac screen and it continues on the Windows display next to it.
Clipboard text and images follow you in both directions.

SideCursor is a native macOS and Windows app, not a port of Barrier or Synergy.
Every handoff is authenticated and everything on the wire is encrypted.

**Free for noncommercial use** under the
[PolyForm Noncommercial License 1.0.0](LICENSE). See [License](#license).

## Features

- **Seamless edge crossing** across multiple monitors. The Display Layout screen
  shows every Mac and Windows display at real physical size, so the pointer
  leaves and enters at the same physical spot.
- **Keyboard, mouse and two-finger scroll** forwarded to Windows, with Mac
  Command mapped to Windows, Control to Control, Option to Alt and Shift to Shift.
- **Trackpad gestures:** three-finger swipes switch Windows virtual desktops,
  open Task View or show the desktop, and pinch zooms (sent as Ctrl + mouse wheel).
- **Clipboard sync:** text up to 10 MB, sent in parts, and images, in both directions.
- **A panic key:** Control + Option + F8 always stays local and returns control
  to the Mac immediately.
- **Two transports:** Tailscale TCP (direct, peer to peer) or a manual Bluetooth
  RFCOMM fallback.
- **Safe recovery:** a lost connection, display change, lost permission, app quit
  or the panic key restores Mac input and releases any Windows keys and buttons.

## Download

Get the Mac app and the Windows app from the
[latest release](https://github.com/yalin-alagul/cursor-sharing/releases/latest):

| | File | Needs |
|---|---|---|
| Mac | `SideCursor-macOS.dmg` | Apple Silicon Mac, macOS 13 or later |
| Windows | `SideCursor-Windows.zip` | 64-bit Windows 10 (version 2004) or later |

The Mac app is built for Apple Silicon. On an Intel Mac you can build it from
source (see below); that is untested.

Neither app is signed with a developer certificate yet, so both operating
systems warn you the first time:

- **macOS:** drag SideCursor into Applications, then right-click it, choose
  **Open**, and confirm. If macOS says the app is damaged, run
  `xattr -dr com.apple.quarantine /Applications/SideCursor.app` in Terminal.
  Because the build is ad-hoc signed, macOS may ask you to grant the permissions
  below again after an update.
- **Windows:** extract the zip anywhere, run `SideCursor.Windows.exe`, and if
  SmartScreen appears choose **More info**, then **Run anyway**.

## First run: Tailscale TCP

Both computers need [Tailscale](https://tailscale.com) signed in to the same
tailnet. It gives them a direct route even when they are not on the same LAN.

1. Launch SideCursor on both computers. On the Mac, click the menu-bar icon and
   open **SideCursor Settings**.
2. On the Mac, open **Connection → Pairing**, choose **Generate new code**, and
   copy the code. On Windows, open **Pairing & transport**, paste it into
   **Pairing code**, select **Tailscale TCP**, enter the Mac's Tailscale address
   (`100.x.y.z`) and port **24800**, then choose **Save and reconnect**.
3. Back on the Mac, click **Save & reconnect**. The Mac status should say it is
   listening and then **Paired Windows companion is ready**. Windows should show
   **Ready** and a round-trip time.
4. On the Mac, grant SideCursor **Device Control and Data Access** in System
   Settings → Privacy & Security (called **Accessibility** before macOS 27). If
   SideCursor also appears under **Input Monitoring**, enable it there too.
5. On the Mac, open **Display Layout**. Once Windows is connected it shows every
   Mac and Windows display at real physical size, readable from each monitor and
   correctable per display. Drag the Windows displays to where they sit on your
   desk; they snap against a Mac edge. The pointer crosses only where edges touch
   (shown in green), at the same physical spot on both sides, and the rest of a
   Windows edge stops the pointer.
6. Move through a green edge to enter Windows. Move back through a green edge to
   return, and the Mac pointer reappears at the matching spot.

Pointer speed on Windows matches physical distance; adjust it on the Mac
(pointer scale). Leave **Unaccelerated 1:1 pointer movement** on unless you want
Windows pointer acceleration. On the Mac's **Input & Gestures** tab, **Motion
smoothing** (0–16 ms) caps the send rate for high-polling mice, and **Windows
scroll speed** scales scroll forwarding (default one eighth).

## Bluetooth fallback

Bluetooth RFCOMM is manual and never silently replaces Tailscale:

1. Pair the Mac and the Windows computer in each operating system's Bluetooth settings.
2. On Windows, select **Bluetooth RFCOMM** and choose **Save and reconnect**. The
   status must say **Bluetooth RFCOMM listener ready**.
3. In Mac settings, select **Bluetooth RFCOMM** and enter the paired Windows radio
   address in the form `AA:BB:CC:DD:EE:FF`, not the SideCursor service UUID the
   Windows app shows.
4. Click **Save & reconnect** on the Mac.

The Windows app advertises a fixed SideCursor service UUID. macOS resolves the
current RFCOMM channel through Bluetooth SDP, so no channel number is hard-coded.

## Gesture compatibility

SideCursor does not change macOS gesture settings on its own during a remote
session. If Spaces, side-swipes or desktop effects still interrupt remote use,
open **Input & Gestures → Gesture Compatibility Profile → Apply**.

The profile saves the exact prior value of every setting it touches, including
whether a key was absent. It disables conflicting Mission Control, Desktop,
Launchpad, pinch, rotate and three/four-finger actions for internal and external
Apple trackpads. Sign out or restart after applying or restoring it. Use
**Verify** before testing and **Restore** to return the saved settings. Normal
pointer movement, clicks, two-finger scrolling and local keyboard input stay
local outside remote mode.

## Controls

- **Control + Option + F8** returns control to the Mac. It is never forwarded.
- **Control + Option + Left/Right** switches Windows virtual desktops, **Up**
  opens Task View and **Down** shows the desktop. Each can be disabled in settings.
- Three-finger swipes do the same in remote mode. This relies on macOS
  three-finger swipes being off (System Settings → Trackpad), which makes macOS
  report them as scrolls that SideCursor tells apart by finger count.
- SideCursor does not capture displays or use a black-screen shield.

## Security

The Mac owns input capture. Windows receives cursor, keyboard, scroll and
clipboard data only after an authenticated handoff.

- **Handshake:** an explicit 32-byte pairing secret, X25519 key agreement and
  HKDF-SHA256 key derivation.
- **Frames:** ChaCha20-Poly1305 authenticated encryption, strict sequence
  numbers and replay rejection.
- **Storage:** pairing material lives in the macOS Keychain and Windows DPAPI.
  It is never passed on a command line or written to diagnostics.
- **No cloud:** there is no account and no server. The two computers talk
  directly, over Tailscale or Bluetooth.

The wire format is specified in [`shared/protocol.md`](shared/protocol.md), and
`shared/interop-vectors.json` holds deterministic test vectors that both apps
must pass before a release. Those vectors use fixed, obviously synthetic values;
they are not real keys. See [`shared/session-state.md`](shared/session-state.md)
for the recovery contract and [SECURITY.md](SECURITY.md) to report a problem.

## Build from source

    apps/macos/       SwiftUI/AppKit menu-bar app and input host
    apps/windows/     .NET 8 WPF tray app and Windows input receiver
    shared/           native v2 protocol and interoperability vectors
    tools/            packaging helpers

On a Mac:

    swift test --package-path apps/macos
    swift tools/validate_protocol_vector.swift
    ./tools/build_macos_app.sh          # writes dist/SideCursor.app

`build_macos_app.sh` signs with a local identity named `SideCursor Local Signing`
if you have one, and falls back to ad-hoc signing otherwise. A stable identity
keeps macOS from resetting the Accessibility grant after each rebuild. Create one
in Keychain Access under **Certificate Assistant → Create a Certificate** (type
**Code Signing**), or set `SIDECURSOR_SIGN_IDENTITY` to another identity.

On Windows:

    dotnet test .\apps\windows\SideCursor.Windows.sln -c Release
    .\tools\build_windows.ps1 -SelfContained

The Python files in the repository root are an unsupported historical prototype.
Do not run them alongside either native app.

Raw Wi-Fi Direct group negotiation is out of scope, because there is no stable
portable macOS and Windows API for it.

## License

Copyright 2026 Yalin Alagul. Released under the
[PolyForm Noncommercial License 1.0.0](LICENSE): free for personal, hobby,
research, educational and other noncommercial use. **Commercial use is not
permitted.** Contact the author if you want a commercial license. This is a
*source-available* license, not an OSI-approved open-source license.
Third-party components are listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
