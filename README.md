# SideCursor Native

SideCursor is a native macOS-to-Windows input-sharing application. The Mac
owns capture; Windows receives cursor, keyboard, two-finger scroll, and
plain-text clipboard events only after an authenticated handoff.

The Python files in this repository are preserved only as an unsupported
historical prototype. Do not run them alongside either native companion.

## What is built

    apps/macos/       SwiftUI/AppKit menu-bar app and input host
    apps/windows/     .NET 8 WPF tray app and Windows input receiver
    shared/           native v2 protocol and interoperability fixture
    tools/            local packaging helpers

The native protocol uses an explicit pairing secret, X25519, HKDF-SHA256,
ChaCha20-Poly1305, strict sequence numbers, and replay rejection. Pairing
material is stored in macOS Keychain and Windows DPAPI; it is never passed on
a command line or written to diagnostics.

## Installed builds on these machines

- macOS: /Applications/SideCursor.app
- Windows: C:\Users\Yalin Alagul\SideCursorNative\SideCursor.Windows.exe

The Windows folder is separate from C:\Users\Yalin Alagul\SideCursor, so the
older Python setup has not been overwritten.

## First run: Tailscale TCP

1. Launch SideCursor on both devices. On Mac, click the menu-bar icon and open
   **SideCursor Settings**. On Windows, run:

       Start-Process 'C:\Users\Yalin Alagul\SideCursorNative\SideCursor.Windows.exe'

2. On Mac, open **Connection → Pairing**, choose **Generate new code**, and
   copy the displayed code. On Windows, open **Pairing & transport**, paste
   it into **Pairing code**, select **Tailscale TCP**, enter the Mac's current
   Tailscale address **100.97.142.96** and port **24800**, then choose
   **Save and reconnect**. Do not use a token from an old terminal command.

3. Back on Mac, click **Save & reconnect**. The Mac status should say it is
   listening and then **Paired Windows companion is ready**. Windows should
   show **Ready** and an RTT.

4. On Mac, grant SideCursor **Device Control and Data Access** in System
   Settings → Privacy & Security if it is not already granted. This permission
   was named **Accessibility** before macOS 27. If SideCursor also appears in
   **Input Monitoring**, enable it there. In **Display Route**, choose only the
   upper external 4K display as the source.

5. On Windows, choose the target display in **Displays & input** and save it.
   Pointer speed is adjusted on the Mac (SideCursor Settings → pointer scale);
   Windows maps Mac pointer units to the target display automatically. Leave
   **Unaccelerated 1:1 pointer movement** enabled unless you prefer Windows
   pointer acceleration. On the Mac's **Input & Gestures** tab, **Motion
   smoothing** (0–16 ms) caps the pointer send rate for high-polling mice, and
   **Windows scroll speed** scales scroll forwarding (default one eighth).

6. Move through the selected Mac display's right edge to enter Windows. Move
   through the selected Windows display's left edge to return.

## Gesture compatibility

SideCursor does not dynamically change macOS gesture settings during a remote
session. If macOS Space/side-swipe/desktop effects still interrupt remote use,
open **Input & Gestures → Gesture Compatibility Profile → Apply**.

The profile saves the exact prior value of every touched setting, including
whether a key was absent. It disables conflicting Mission Control, Desktop,
Launchpad, pinch, rotate, and three/four-finger actions for both internal and
external Apple trackpads. Sign out or restart after applying or restoring it.
Use **Verify** before testing and **Restore** to return the saved settings.
Normal pointer movement, clicks, two-finger scrolling, and local keyboard
input remain local outside remote mode.

## Bluetooth fallback

Bluetooth RFCOMM is manual and never silently replaces Tailscale:

1. Pair the Mac and Windows computer in operating-system Bluetooth settings.
2. In Windows, select **Bluetooth RFCOMM** and choose **Save and reconnect**.
   Its status must say **Bluetooth RFCOMM listener ready**.
3. In Mac settings, select **Bluetooth RFCOMM** and enter the paired Windows
   radio address in the form `AA:BB:CC:DD:EE:FF`—not the SideCursor service
   UUID shown by the Windows app.
4. Click **Save & reconnect** on Mac.

The Windows app advertises a fixed SideCursor service UUID. macOS resolves the
currently assigned RFCOMM channel through Bluetooth SDP, so no old hard-coded
channel such as 11 is used.

## Controls and recovery

- **Control + Option + F8** always stays local and immediately returns control
  to the Mac. It is never forwarded.
- **Control + Option + Left/Right** maps to Windows virtual desktops;
  **Control + Option + Up** maps to Task View; **Control + Option + Down** maps
  to Show Desktop. Each can be disabled in settings.
- Mac Command maps to Windows, Control to Control, Option to Alt, and Shift
  to Shift.
- A failed entry acknowledgement, lost peer, display change, permission loss,
  app quit, or panic action restores Mac input and releases Windows keys and
  mouse buttons.
- SideCursor does not capture displays or use a black-screen shield.

## Local development and validation

    swift test --package-path apps/macos
    swift tools/validate_protocol_vector.swift
    ./tools/build_macos_app.sh

On Windows:

    dotnet test .\apps\windows\SideCursor.Windows.sln -c Release
    .\tools\build_windows.ps1 -SelfContained

The current direct route is Tailscale peer-to-peer when available; it does not
require both machines on the same ordinary LAN. Raw Wi-Fi Direct group
negotiation is intentionally out of scope because there is no stable portable
macOS/Windows API for it.

See [the protocol contract](shared/protocol.md) and
[the session recovery contract](shared/session-state.md) for wire and safety
details.
