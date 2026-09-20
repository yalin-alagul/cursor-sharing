from __future__ import annotations

import sys


def make_adapter(send_message):
    if sys.platform == "darwin":
        from .mac import MacAdapter
        return MacAdapter(send_message)
    if sys.platform == "win32":
        from .windows import WindowsAdapter
        return WindowsAdapter(send_message)
    raise RuntimeError("SideCursor currently supports macOS and Windows only")
