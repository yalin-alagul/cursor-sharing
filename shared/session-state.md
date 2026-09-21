# Session state machine

```text
Disconnected -> Connecting -> Ready -> Entering -> Remote -> Returning -> Ready
                                      |             |              |
                                      +-------------+--------------+-> Recovering -> Ready
```

`Recovering` is mandatory on connection loss, failed cursor capture, lost
permission, display reconfiguration, panic hotkey, process shutdown, or an
invalid protocol frame.  It restores local Mac input before exposing `Ready`.

Only `Ready` may process a configured display-edge handoff.  Only `Remote` may
forward normal input.  The local panic hotkey is recognized in every state.
