from __future__ import annotations

import sys

def start_tray(adapter, stop_event):
    """Start a small macOS menu-bar / Windows notification-area controller.

    The import is lazy so headless SSH sessions can still run the transport.
    """
    try:
        import pystray
        from PIL import Image, ImageDraw
    except ImportError:
        print("GUI tray unavailable; install pystray and Pillow to enable it")
        return None

    image = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    draw.polygon([(15, 7), (49, 39), (35, 39), (43, 56), (35, 60), (27, 41), (17, 50)],
                 fill=(30, 120, 235, 255), outline=(255, 255, 255, 255))

    def toggle(_icon, _item):
        adapter.toggle_forwarding()

    def mode_text(_item):
        return f"Remote mode: {'ON' if adapter.forwarding else 'OFF'}"

    def quit_app(icon, _item):
        stop_event.set()
        icon.stop()

    menu = pystray.Menu(
        pystray.MenuItem(mode_text, toggle),
        pystray.MenuItem("Connected", None, enabled=False),
        pystray.MenuItem("Quit SideCursor", quit_app),
    )
    icon = pystray.Icon("sidecursor", image, "SideCursor", menu)
    if sys.platform == "darwin":
        # pystray's Darwin run_detached implementation only marks the icon as
        # ready; it does not run NSApplication. app.py runs this icon on the
        # main thread after all network workers have started.
        import AppKit
        AppKit.NSApplication.sharedApplication().setActivationPolicy_(
            AppKit.NSApplicationActivationPolicyAccessory)
    else:
        icon.run_detached()
    return icon


def run_tray(icon, setup=None):
    if icon is not None:
        icon.run(setup=setup)


def stop_tray(icon):
    if icon is not None:
        icon.stop()
