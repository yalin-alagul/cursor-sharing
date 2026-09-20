from __future__ import annotations

import json
import plistlib
import threading
import time
import queue
import subprocess
import tempfile
from pathlib import Path

try:
    import AppKit
    import Quartz
except ImportError as exc:  # pragma: no cover - only reached when optional macOS deps are absent
    raise RuntimeError("macOS adapter requires: python3 -m pip install pyobjc-framework-Quartz pyobjc-framework-Cocoa") from exc


class MacAdapter:
    """Quartz event tap + AppKit clipboard adapter.

    macOS Accessibility permission is required for both the event tap and event posting.
    """

    _MOUSE_MOTION_EVENTS = (
        Quartz.kCGEventMouseMoved,
        Quartz.kCGEventLeftMouseDragged,
        Quartz.kCGEventRightMouseDragged,
        Quartz.kCGEventOtherMouseDragged,
    )
    _CURRENT_HOST_DOMAIN = "@sidecursor-current-host"

    # Keep two-finger scrolling enabled: it is forwarded as a Windows wheel
    # event.  These are the macOS actions that switch Spaces, expose windows,
    # open Notification Center, or perform a local zoom/rotate instead.
    _GESTURE_SHIELD_SETTINGS = (
        ("com.apple.dock", "showAppExposeGestureEnabled", False),
        ("com.apple.dock", "showMissionControlGestureEnabled", False),
        ("com.apple.dock", "showDesktopGestureEnabled", False),
        ("com.apple.dock", "showLaunchpadGestureEnabled", False),
        ("NSGlobalDomain", "AppleEnableSwipeNavigateWithScrolls", False),
        (_CURRENT_HOST_DOMAIN, "com.apple.trackpad.threeFingerHorizSwipeGesture", 0),
        (_CURRENT_HOST_DOMAIN, "com.apple.trackpad.fourFingerHorizSwipeGesture", 0),
        (_CURRENT_HOST_DOMAIN, "com.apple.trackpad.threeFingerVertSwipeGesture", 0),
        (_CURRENT_HOST_DOMAIN, "com.apple.trackpad.fourFingerVertSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerVertSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFourFingerVertSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerHorizSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFourFingerHorizSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFourFingerPinchGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadFiveFingerPinchGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadTwoFingerDoubleTapGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadTwoFingerFromRightEdgeSwipeGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadThreeFingerTapGesture", 0),
        ("com.apple.AppleMultitouchTrackpad", "TrackpadRotate", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerVertSwipeGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFourFingerVertSwipeGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerHorizSwipeGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFourFingerHorizSwipeGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFourFingerPinchGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadFiveFingerPinchGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadTwoFingerDoubleTapGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadTwoFingerFromRightEdgeSwipeGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadThreeFingerTapGesture", 0),
        ("com.apple.driver.AppleBluetoothMultitouch.trackpad", "TrackpadRotate", 0),
    )

    def __init__(self, send_message):
        self.send_message = send_message
        self.forwarding = False
        self._stop = threading.Event()
        self._tap = None
        self._pasteboard = AppKit.NSPasteboard.generalPasteboard()
        self._last_clipboard = None
        self._last_point = None
        self._cursor_captured = False
        self._captured_display = None
        self._return_y_norm = None
        self._mode_lock = threading.RLock()
        self._edge_reentry_blocked_until = 0.0
        self._previous_frontmost_app = None
        self._cg_hide_count = 0
        self._ns_cursor_hidden = False
        self._cursor_actions = queue.Queue()
        self._cursor_thread = None
        self._gesture_shield_lock = threading.RLock()
        self._gesture_shield_active = False
        self._gesture_state_path = (
            Path.home() / "Library" / "Application Support" / "SideCursor" / "gesture-shield-state.json"
        )

    @staticmethod
    def _read_preference_domain(domain):
        command = ["defaults"]
        if domain == MacAdapter._CURRENT_HOST_DOMAIN:
            command.extend(["-currentHost", "export", "NSGlobalDomain", "-"])
        else:
            command.extend(["export", domain, "-"])
        result = subprocess.run(
            command, capture_output=True, check=False
        )
        if result.returncode:
            return {}
        return plistlib.loads(result.stdout)

    @staticmethod
    def _write_preference(domain, key, value):
        if isinstance(value, bool):
            kind, rendered = "-bool", "true" if value else "false"
        elif isinstance(value, int):
            kind, rendered = "-int", str(value)
        elif isinstance(value, float):
            kind, rendered = "-float", str(value)
        elif isinstance(value, str):
            kind, rendered = "-string", value
        else:
            raise TypeError(f"unsupported preference value for {domain}:{key}")
        command = ["defaults"]
        if domain == MacAdapter._CURRENT_HOST_DOMAIN:
            command.extend(["-currentHost", "write", "NSGlobalDomain", key])
        else:
            command.extend(["write", domain, key])
        subprocess.run(command + [kind, rendered], check=True)

    @staticmethod
    def _delete_preference(domain, key):
        command = ["defaults"]
        if domain == MacAdapter._CURRENT_HOST_DOMAIN:
            command.extend(["-currentHost", "delete", "NSGlobalDomain", key])
        else:
            command.extend(["delete", domain, key])
        subprocess.run(command, check=False)

    def _save_gesture_state(self, state):
        self._gesture_state_path.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", dir=self._gesture_state_path.parent, delete=False
        ) as temporary:
            json.dump(state, temporary)
            temporary.flush()
            Path(temporary.name).replace(self._gesture_state_path)

    def _load_gesture_state(self):
        try:
            with self._gesture_state_path.open(encoding="utf-8") as state_file:
                return json.load(state_file)
        except FileNotFoundError:
            return None

    @staticmethod
    def _reload_gesture_services():
        # Dock owns Mission Control, Show Desktop, Launchpad, and App Expose.
        # The per-host trackpad preferences are cached by cfprefsd, so restart
        # it before Dock to apply side-swipe changes without logging out.
        subprocess.run(["killall", "cfprefsd"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        time.sleep(0.15)
        subprocess.run(["killall", "Dock"], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)

    def _restore_gesture_state(self, state):
        for domain, values in state.get("domains", {}).items():
            for key, saved in values.items():
                if saved.get("present"):
                    self._write_preference(domain, key, saved["value"])
                else:
                    self._delete_preference(domain, key)
        self._reload_gesture_services()

    def _enable_gesture_shield(self):
        with self._gesture_shield_lock:
            if self._gesture_shield_active:
                return
            try:
                domains = {}
                for domain, key, _disabled_value in self._GESTURE_SHIELD_SETTINGS:
                    if domain not in domains:
                        domains[domain] = self._read_preference_domain(domain)
                state = {"domains": {}}
                for domain, key, _disabled_value in self._GESTURE_SHIELD_SETTINGS:
                    saved = state["domains"].setdefault(domain, {})
                    if key in domains[domain]:
                        saved[key] = {"present": True, "value": domains[domain][key]}
                    else:
                        saved[key] = {"present": False}
                # Persist before changing preferences so the next SideCursor
                # launch can restore them even if this process is terminated.
                self._save_gesture_state(state)
                for domain, key, disabled_value in self._GESTURE_SHIELD_SETTINGS:
                    self._write_preference(domain, key, disabled_value)
                self._reload_gesture_services()
                self._gesture_shield_active = True
                print("Mac gesture shield: ON (two-finger scroll remains enabled)")
            except Exception as exc:
                print(f"Mac gesture shield warning: {exc}")

    def _disable_gesture_shield(self, recover=False):
        with self._gesture_shield_lock:
            if not self._gesture_shield_active and not recover:
                return
            state = self._load_gesture_state()
            if state is None:
                self._gesture_shield_active = False
                return
            try:
                self._restore_gesture_state(state)
                self._gesture_state_path.unlink(missing_ok=True)
                print("Mac gesture shield: OFF (your gesture settings restored)")
            except Exception as exc:
                print(f"Mac gesture shield restore warning: {exc}")
            finally:
                self._gesture_shield_active = False

    def _recover_gesture_shield(self):
        if self._gesture_state_path.exists():
            print("Restoring trackpad gestures left disabled by an interrupted SideCursor session")
            self._disable_gesture_shield(recover=True)

    @staticmethod
    def _active_display_bounds():
        error, displays, _count = Quartz.CGGetActiveDisplayList(16, None, None)
        if error:
            display = Quartz.CGMainDisplayID()
            return [(display, Quartz.CGDisplayBounds(display))]
        return [(display, Quartz.CGDisplayBounds(display)) for display in displays]

    def _display_at_point(self, point):
        displays = self._active_display_bounds()
        for display, bounds in displays:
            if (bounds.origin.x <= point.x < bounds.origin.x + bounds.size.width and
                    bounds.origin.y <= point.y < bounds.origin.y + bounds.size.height):
                return display, bounds
        display = Quartz.CGMainDisplayID()
        return display, Quartz.CGDisplayBounds(display)

    def _set_forwarding(self, enabled, point=None):
        with self._mode_lock:
            if self.forwarding == enabled:
                return False
            self.forwarding = enabled
            if self.forwarding:
                if point is None:
                    point = Quartz.CGEventGetLocation(Quartz.CGEventCreate(None))
                display, bounds = self._display_at_point(point)
                y_norm = max(0.0, min(1.0, (point.y - bounds.origin.y) / max(1.0, bounds.size.height)))
                # Tell Windows to place its pointer slightly inside the entry edge.
                # Without this, a pointer left at x=0 from a prior session exits on
                # the first small leftward mouse movement.
                self.send_message({
                    "type": "control",
                    "action": "enter_remote_mode",
                    "y": y_norm,
                    "source_width": bounds.size.width,
                    "source_height": bounds.size.height,
                })
                self._cursor_actions.put(("capture", display))
            else:
                self._cursor_actions.put(("release", None))
            print(f"Remote mode: {'ON' if self.forwarding else 'OFF'}")
            return True

    def toggle_forwarding(self, point=None):
        with self._mode_lock:
            return self._set_forwarding(not self.forwarding, point)

    def _cursor_worker(self):
        while True:
            try:
                action, value = self._cursor_actions.get(timeout=0.1)
            except queue.Empty:
                if self.forwarding:
                    try:
                        self._ensure_cursor_hidden()
                    except Exception as exc:
                        print(f"Cursor visibility warning: {exc}")
                continue
            if action == "stop":
                return
            try:
                if action == "capture":
                    self._capture_cursor(value)
                elif action == "release":
                    self._release_cursor()
            except Exception as exc:
                # Cursor presentation must never be able to kill input capture.
                print(f"Cursor management warning: {exc}")

    def _capture_cursor(self, display):
        """Keep macOS from moving its own pointer during remote control."""
        if self._cursor_captured:
            return
        self._captured_display = display
        self._enable_gesture_shield()
        workspace = AppKit.NSWorkspace.sharedWorkspace()
        current_app = AppKit.NSRunningApplication.currentApplication()
        frontmost = workspace.frontmostApplication()
        if frontmost and frontmost.processIdentifier() != current_app.processIdentifier():
            self._previous_frontmost_app = frontmost
        # AppKit UI calls must execute on the Cocoa main thread. The menu-bar
        # application loop is running there while input/network work stays on
        # background threads.
        def activate_and_hide():
            app = AppKit.NSApplication.sharedApplication()
            app.activateIgnoringOtherApps_(True)
            AppKit.NSCursor.hide()
            self._ns_cursor_hidden = True

        self._run_on_main_thread(activate_and_hide)
        Quartz.CGAssociateMouseAndMouseCursorPosition(False)
        hide_result = Quartz.CGDisplayHideCursor(display)
        if hide_result == 0:
            self._cg_hide_count += 1
        self._cursor_captured = True
        if hide_result:
            print(f"Warning: macOS cursor hide returned CGError {hide_result}")
        self._report_cursor_visibility()

    @staticmethod
    def _run_on_main_thread(operation, timeout=1.0):
        if AppKit.NSThread.isMainThread():
            operation()
            return
        completed = threading.Event()
        error = []

        def wrapped():
            try:
                operation()
            except Exception as exc:
                error.append(exc)
            finally:
                completed.set()

        AppKit.NSOperationQueue.mainQueue().addOperationWithBlock_(wrapped)
        if not completed.wait(timeout):
            raise TimeoutError("macOS main-thread cursor operation timed out")
        if error:
            raise error[0]

    def _cursor_is_visible(self):
        check = getattr(Quartz, "CGCursorIsVisible", None)
        return bool(check()) if check else None

    def _report_cursor_visibility(self):
        visible = self._cursor_is_visible()
        if visible is not None:
            print(f"Mac cursor hidden: {'NO' if visible else 'YES'}")

    def _ensure_cursor_hidden(self):
        if not self._cursor_captured:
            return
        visible = self._cursor_is_visible()
        if visible:
            result = Quartz.CGDisplayHideCursor(self._captured_display or Quartz.CGMainDisplayID())
            if result == 0:
                self._cg_hide_count += 1

    def _release_cursor(self):
        self._disable_gesture_shield()
        if not self._cursor_captured:
            return
        display = self._captured_display or Quartz.CGMainDisplayID()
        bounds = Quartz.CGDisplayBounds(display)
        y_norm = 0.5 if self._return_y_norm is None else self._return_y_norm
        return_point = Quartz.CGPointMake(
            # Return far enough inside the Mac display that normal vertical
            # movement cannot immediately trigger another edge handoff.
            bounds.origin.x + bounds.size.width - 24,
            bounds.origin.y + max(0.0, min(1.0, y_norm)) * max(1.0, bounds.size.height - 1),
        )
        # Warping to the Mac edge generates a synthetic mouse-move event. Do
        # not interpret that event as an immediate new transition to Windows.
        self._edge_reentry_blocked_until = time.monotonic() + 0.75
        Quartz.CGWarpMouseCursorPosition(return_point)
        Quartz.CGAssociateMouseAndMouseCursorPosition(True)
        while self._cg_hide_count > 0:
            Quartz.CGDisplayShowCursor(display)
            self._cg_hide_count -= 1
        previous_app = self._previous_frontmost_app

        def unhide_and_restore_app():
            if self._ns_cursor_hidden:
                AppKit.NSCursor.unhide()
                self._ns_cursor_hidden = False
            if previous_app and not previous_app.isTerminated():
                previous_app.activateWithOptions_(AppKit.NSApplicationActivateIgnoringOtherApps)

        self._run_on_main_thread(unhide_and_restore_app)
        self._cursor_captured = False
        self._captured_display = None
        self._return_y_norm = None
        self._previous_frontmost_app = None

    def release_remote_mode(self, y_norm=None):
        with self._mode_lock:
            if self.forwarding:
                self._return_y_norm = y_norm
                self._set_forwarding(False)

    _KEYCODE_TO_VK = {
        0: 0x41, 1: 0x53, 2: 0x44, 3: 0x46, 4: 0x48, 5: 0x47, 6: 0x5A, 7: 0x58,
        8: 0x43, 9: 0x56, 11: 0x42, 12: 0x51, 13: 0x57, 14: 0x45, 15: 0x52, 16: 0x59,
        17: 0x54, 18: 0x31, 19: 0x32, 20: 0x33, 21: 0x34, 22: 0x36, 23: 0x35, 24: 0xBB,
        25: 0x39, 26: 0x37, 27: 0xBD, 28: 0x38, 29: 0x30, 30: 0xDD, 31: 0x4F, 32: 0x55,
        33: 0xDB, 34: 0x49, 35: 0x50, 36: 0x0D, 37: 0x4C, 38: 0x4A, 39: 0xDE, 40: 0x4B,
        41: 0xBA, 42: 0xDC, 43: 0xBC, 44: 0xBF, 45: 0x4E, 46: 0x4D, 47: 0xBE, 48: 0x09,
        49: 0x20, 50: 0xC0, 51: 0x08, 53: 0x1B, 55: 0x5B, 56: 0x10, 57: 0x14, 58: 0x12,
        59: 0x11, 60: 0x10, 61: 0x12, 62: 0x11, 123: 0x25, 124: 0x27, 125: 0x28, 126: 0x26,
        122: 0x70, 120: 0x71, 99: 0x72, 118: 0x73, 96: 0x74, 97: 0x75, 98: 0x76,
        100: 0x77, 101: 0x78, 109: 0x79, 103: 0x7A, 111: 0x7B, 105: 0x7C, 107: 0x7D,
    }

    @staticmethod
    def _normalized(point):
        bounds = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
        x = max(0.0, min(1.0, (point.x - bounds.origin.x) / max(1.0, bounds.size.width)))
        y = max(0.0, min(1.0, (point.y - bounds.origin.y) / max(1.0, bounds.size.height)))
        return x, y

    def _event_callback(self, _proxy, event_type, event, _refcon):
        if event_type in (Quartz.kCGEventTapDisabledByTimeout, Quartz.kCGEventTapDisabledByUserInput):
            Quartz.CGEventTapEnable(self._tap, True)
            print("Mac input tap re-enabled")
            return event
        key_down = event_type == Quartz.kCGEventKeyDown
        if key_down and Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode) == 100:
            flags = Quartz.CGEventGetFlags(event)
            if flags & Quartz.kCGEventFlagMaskControl and flags & Quartz.kCGEventFlagMaskAlternate:
                self.toggle_forwarding(Quartz.CGEventGetLocation(event))
                return None
        # A trackpad click-and-move is delivered as one of the *Dragged*
        # event types, not MouseMoved.  Capturing only MouseMoved let those
        # gestures reach macOS, which made its cursor and local drag actions
        # reappear while Windows was being controlled.
        if event_type in self._MOUSE_MOTION_EVENTS:
            point = Quartz.CGEventGetLocation(event)
            dx = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGMouseEventDeltaX)
            dy = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGMouseEventDeltaY)
            if not self.forwarding:
                if time.monotonic() < self._edge_reentry_blocked_until:
                    return event
                # The main display can end well before the right edge of an
                # external or offset display.  Test against the display that
                # actually contains this event, in the same Quartz coordinate
                # space as the event location.
                _display, bounds = self._display_at_point(point)
                at_right_edge = point.x >= bounds.origin.x + bounds.size.width - 2
                if not (at_right_edge and dx > 0):
                    return event
                print("Mac right edge reached; entering remote mode")
                self._set_forwarding(True, point)
            self.send_message({"type": "event", "event": {"kind": "mouse_move", "dx": int(dx), "dy": int(dy)}})
            return None
        if not self.forwarding:
            return event
        if event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp,
                          Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp,
                          Quartz.kCGEventOtherMouseDown, Quartz.kCGEventOtherMouseUp):
            button = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGMouseEventButtonNumber)
            down = event_type in (Quartz.kCGEventLeftMouseDown, Quartz.kCGEventRightMouseDown, Quartz.kCGEventOtherMouseDown)
            self.send_message({"type": "event", "event": {"kind": "mouse_button", "button": button, "down": down}})
            return None
        if event_type == Quartz.kCGEventScrollWheel:
            delta = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGScrollWheelEventDeltaAxis1)
            self.send_message({"type": "event", "event": {"kind": "scroll", "delta": delta}})
            return None
        if event_type in (Quartz.kCGEventKeyDown, Quartz.kCGEventKeyUp, Quartz.kCGEventFlagsChanged):
            code = Quartz.CGEventGetIntegerValueField(event, Quartz.kCGKeyboardEventKeycode)
            vk = self._KEYCODE_TO_VK.get(code)
            if vk is not None:
                if event_type == Quartz.kCGEventFlagsChanged:
                    flags = Quartz.CGEventGetFlags(event)
                    modifier_masks = {
                        55: Quartz.kCGEventFlagMaskCommand, 56: Quartz.kCGEventFlagMaskShift,
                        60: Quartz.kCGEventFlagMaskShift, 57: Quartz.kCGEventFlagMaskAlphaShift,
                        58: Quartz.kCGEventFlagMaskAlternate, 61: Quartz.kCGEventFlagMaskAlternate,
                        59: Quartz.kCGEventFlagMaskControl, 62: Quartz.kCGEventFlagMaskControl,
                    }
                    down = bool(flags & modifier_masks.get(code, 0))
                else:
                    down = key_down
                self.send_message({"type": "event", "event": {"kind": "key", "vk": vk, "down": down}})
            return None
        return event

    def _clipboard_loop(self, callback):
        change_count = -1
        while not self._stop.wait(0.25):
            count = self._pasteboard.changeCount()
            if count == change_count:
                continue
            change_count = count
            text = self._pasteboard.stringForType_(AppKit.NSPasteboardTypeString)
            if text is not None and text != self._last_clipboard:
                self._last_clipboard = text
                callback(text)

    def start(self, clipboard_callback, capture=True):
        if not capture:
            threading.Thread(target=self._clipboard_loop, args=(clipboard_callback,), name="sidecursor-mac-clipboard", daemon=True).start()
            return
        self._recover_gesture_shield()
        self._cursor_thread = threading.Thread(target=self._cursor_worker, name="sidecursor-mac-cursor", daemon=True)
        self._cursor_thread.start()
        mask = ((1 << Quartz.kCGEventMouseMoved) | (1 << Quartz.kCGEventLeftMouseDragged) |
                (1 << Quartz.kCGEventRightMouseDragged) | (1 << Quartz.kCGEventOtherMouseDragged) |
                (1 << Quartz.kCGEventLeftMouseDown) |
                (1 << Quartz.kCGEventLeftMouseUp) | (1 << Quartz.kCGEventRightMouseDown) |
                (1 << Quartz.kCGEventRightMouseUp) | (1 << Quartz.kCGEventOtherMouseDown) |
                (1 << Quartz.kCGEventOtherMouseUp) | (1 << Quartz.kCGEventKeyDown) |
                (1 << Quartz.kCGEventKeyUp) | (1 << Quartz.kCGEventFlagsChanged) |
                (1 << Quartz.kCGEventScrollWheel))
        self._tap = Quartz.CGEventTapCreate(Quartz.kCGHIDEventTap, Quartz.kCGHeadInsertEventTap,
                                             Quartz.kCGEventTapOptionDefault, mask, self._event_callback, None)
        if self._tap is None:
            raise PermissionError("Could not create macOS event tap; grant Accessibility permission")
        # The event tap source and CFRunLoop must be created on the same
        # thread. Attaching a source to the caller's loop and then running a
        # different thread's loop silently receives no global events.
        threading.Thread(target=self._run_event_loop, name="sidecursor-mac-events", daemon=True).start()
        threading.Thread(target=self._clipboard_loop, args=(clipboard_callback,), name="sidecursor-mac-clipboard", daemon=True).start()

    def _run_event_loop(self):
        source = Quartz.CFMachPortCreateRunLoopSource(None, self._tap, 0)
        loop = Quartz.CFRunLoopGetCurrent()
        Quartz.CFRunLoopAddSource(loop, source, Quartz.kCFRunLoopCommonModes)
        Quartz.CGEventTapEnable(self._tap, True)
        Quartz.CFRunLoopRun()

    def inject(self, event):
        kind = event.get("kind")
        if kind == "mouse_move":
            if "dx" in event:
                move = Quartz.CGEventCreate(None)
                Quartz.CGEventSetIntegerValueField(move, Quartz.kCGMouseEventDeltaX, int(event.get("dx", 0)))
                Quartz.CGEventSetIntegerValueField(move, Quartz.kCGMouseEventDeltaY, int(event.get("dy", 0)))
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, move)
            else:
                bounds = Quartz.CGDisplayBounds(Quartz.CGMainDisplayID())
                point = Quartz.CGPointMake(bounds.origin.x + event["x"] * bounds.size.width,
                                           bounds.origin.y + event["y"] * bounds.size.height)
                Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, Quartz.kCGEventMouseMoved, point, 0))
        elif kind == "mouse_button":
            point = AppKit.NSEvent.mouseLocation()
            button = int(event.get("button", 0))
            down = bool(event.get("down"))
            types = [Quartz.kCGEventLeftMouseDown, Quartz.kCGEventLeftMouseUp,
                     Quartz.kCGEventRightMouseDown, Quartz.kCGEventRightMouseUp]
            index = (0 if button == 0 else 2) + (0 if down else 1)
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, Quartz.CGEventCreateMouseEvent(None, types[index], point, button))
        elif kind == "scroll":
            scroll = Quartz.CGEventCreateScrollWheelEvent(None, Quartz.kCGScrollEventUnitLine, 1, int(event.get("delta", 0)))
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, scroll)
        elif kind == "key":
            key = Quartz.CGEventCreateKeyboardEvent(None, int(event["code"]), bool(event["down"]))
            Quartz.CGEventPost(Quartz.kCGHIDEventTap, key)

    def set_clipboard(self, text: str):
        self._last_clipboard = text
        self._pasteboard.clearContents()
        self._pasteboard.setString_forType_(text, AppKit.NSPasteboardTypeString)

    def stop(self):
        self.forwarding = False
        self._cursor_actions.put(("release", None))
        deadline = time.monotonic() + 0.5
        while self._cursor_captured and time.monotonic() < deadline:
            time.sleep(0.01)
        self._disable_gesture_shield()
        self._cursor_actions.put(("stop", None))
        self._stop.set()
        if self._tap:
            Quartz.CGEventTapEnable(self._tap, False)
