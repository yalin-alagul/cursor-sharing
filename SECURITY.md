# Security policy

SideCursor injects keyboard and mouse input and shares your clipboard between
two computers, so security reports are taken seriously.

## Reporting a vulnerability

Please **do not open a public issue** for a security problem. Use GitHub's
private reporting instead: open the **Security** tab of this repository and choose
**Report a vulnerability**.

Include what you found, the steps to reproduce it, and which platform
(macOS, Windows, or the shared protocol) it affects. You can expect an
acknowledgement within a few days. This is a spare-time project, so fixes may
take longer.

## What is in scope

- The authenticated handshake, key derivation and encrypted framing described
  in [`shared/protocol.md`](shared/protocol.md).
- Replay, downgrade or unauthenticated-input attacks against either app.
- Pairing-secret handling (macOS Keychain, Windows DPAPI).
- Anything that leaves input stuck, or Windows keys or buttons held down,
  after a disconnect.

## Not in scope

- Problems that need an attacker who already has your unlocked computer.
- The unsupported Python prototype in the repository root.
