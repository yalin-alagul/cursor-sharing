from __future__ import annotations

import ctypes
import threading
from ctypes import wintypes

user32 = ctypes.windll.user32
kernel32 = ctypes.windll.kernel32


def _enable_per_monitor_dpi_awareness():
    """Opt out of Windows' DPI coordinate virtualization.

    Cursor coordinates, virtual-screen metrics, and ``SetCursorPos`` must all
    use the same physical-pixel coordinate space.  Without this, Windows can
    report scaled coordinates to this Python process on high-DPI displays,
    which makes the remote pointer appear slow and makes edge positions wrong.
    ``SetProcessDpiAwarenessContext`` is available on Windows 10 1703+; the
    older calls keep the client usable on earlier supported Windows versions.
    """
    try:
        # DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2.  This must happen before
        # any window or DPI-sensitive UI is created.
        if user32.SetProcessDpiAwarenessContext(ctypes.c_void_p(-4)):
            return "per-monitor-v2"
    except (AttributeError, OSError):
        pass
    try:
        shcore = ctypes.windll.shcore
        # PROCESS_PER_MONITOR_DPI_AWARE
        if shcore.SetProcessDpiAwareness(2) == 0:
            return "per-monitor"
    except (AttributeError, OSError):
        pass
    try:
        if user32.SetProcessDPIAware():
            return "system"
    except (AttributeError, OSError):
        pass
    return "unavailable"


_DPI_AWARENESS = _enable_per_monitor_dpi_awareness()
_dpi_thread_state = threading.local()


def _enable_thread_per_monitor_dpi_awareness():
    """Use Per-Monitor-V2 in the current thread when Python is manifested.

    The stock Python executable may already declare *system* DPI awareness in
    its manifest.  Windows then correctly rejects a later process-wide change,
    but permits a Per-Monitor-V2 context on each input/receive thread.
    """
    cached = getattr(_dpi_thread_state, "mode", None)
    if cached:
        return cached
    try:
        set_context = user32.SetThreadDpiAwarenessContext
        set_context.argtypes = [ctypes.c_void_p]
        set_context.restype = ctypes.c_void_p
        # V2 is Windows 10 1703+.  Fall back to the original Per-Monitor
        # context for earlier Windows 10 builds.
        for context, mode in ((-4, "thread-per-monitor-v2"), (-3, "thread-per-monitor")):
            if set_context(ctypes.c_void_p(context)):
                _dpi_thread_state.mode = mode
                return mode
    except (AttributeError, OSError):
        pass
    _dpi_thread_state.mode = _DPI_AWARENESS
    return _dpi_thread_state.mode

kernel32.GetModuleHandleW.argtypes = [wintypes.LPCWSTR]
kernel32.GetModuleHandleW.restype = ctypes.c_void_p
user32.SetWindowsHookExW.argtypes = [ctypes.c_int, ctypes.c_void_p, ctypes.c_void_p, wintypes.DWORD]
user32.SetWindowsHookExW.restype = ctypes.c_void_p
user32.UnhookWindowsHookEx.argtypes = [ctypes.c_void_p]
user32.UnhookWindowsHookEx.restype = wintypes.BOOL
user32.OpenClipboard.argtypes = [wintypes.HWND]
user32.OpenClipboard.restype = wintypes.BOOL
user32.CloseClipboard.argtypes = []
user32.CloseClipboard.restype = wintypes.BOOL
user32.GetClipboardData.argtypes = [wintypes.UINT]
user32.GetClipboardData.restype = ctypes.c_void_p
user32.EmptyClipboard.argtypes = []
user32.EmptyClipboard.restype = wintypes.BOOL
user32.SetClipboardData.argtypes = [wintypes.UINT, ctypes.c_void_p]
user32.SetClipboardData.restype = ctypes.c_void_p
kernel32.GlobalLock.argtypes = [ctypes.c_void_p]
kernel32.GlobalLock.restype = ctypes.c_void_p
kernel32.GlobalUnlock.argtypes = [ctypes.c_void_p]
kernel32.GlobalUnlock.restype = wintypes.BOOL
kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
kernel32.GlobalAlloc.restype = wintypes.HGLOBAL

WH_KEYBOARD_LL = 13
WH_MOUSE_LL = 14
WM_KEYDOWN, WM_KEYUP = 0x0100, 0x0101
WM_SYSKEYDOWN, WM_SYSKEYUP = 0x0104, 0x0105
WM_MOUSEMOVE = 0x0200
WM_LBUTTONDOWN, WM_LBUTTONUP = 0x0201, 0x0202
WM_RBUTTONDOWN, WM_RBUTTONUP = 0x0204, 0x0205
WM_MBUTTONDOWN, WM_MBUTTONUP = 0x0207, 0x0208
WM_MOUSEWHEEL = 0x020A
LLKHF_INJECTED, LLMHF_INJECTED = 0x10, 0x01
VK_CONTROL, VK_MENU, VK_F8 = 0x11, 0x12, 0x77
CF_UNICODETEXT, GMEM_MOVEABLE = 13, 0x0002
SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN = 76, 77
SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN = 78, 79
# Applied after the source/target desktop-size calibration.  Keep Windows
# deliberately half-speed without changing the return path to macOS.
WINDOWS_REMOTE_POINTER_SPEED = 0.5


class KBDLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("vkCode", wintypes.DWORD), ("scanCode", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]


class MSLLHOOKSTRUCT(ctypes.Structure):
    _fields_ = [("pt", wintypes.POINT), ("mouseData", wintypes.DWORD), ("flags", wintypes.DWORD),
                ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]


class INPUT(ctypes.Structure):
    class _U(ctypes.Union):
        class _M(ctypes.Structure):
            _fields_ = [("dx", wintypes.LONG), ("dy", wintypes.LONG), ("mouseData", wintypes.DWORD),
                        ("dwFlags", wintypes.DWORD), ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]
        class _K(ctypes.Structure):
            _fields_ = [("wVk", wintypes.WORD), ("wScan", wintypes.WORD), ("dwFlags", wintypes.DWORD),
                        ("time", wintypes.DWORD), ("dwExtraInfo", ctypes.POINTER(wintypes.ULONG))]
        _fields_ = [("mi", _M), ("ki", _K)]
    _fields_ = [("type", wintypes.DWORD), ("u", _U)]


class WindowsAdapter:
    def __init__(self, send_message):
        self.send_message = send_message
        self.forwarding = False
        self._stop = threading.Event()
        self._keyboard_hook = None
        self._mouse_hook = None
        self._callbacks = []
        self._last_clipboard = None
        self._ctrl = False
        self._alt = False
        self._remote_entry_x = None
        self._release_sent = False
        self._relative_scale_x = 1.0
        self._relative_scale_y = 1.0
        self._dpi_awareness = _enable_thread_per_monitor_dpi_awareness()

    def toggle_forwarding(self):
        self.forwarding = not self.forwarding
        print(f"Remote mode: {'ON' if self.forwarding else 'OFF'}")

    def _normalized(self, x, y):
        _enable_thread_per_monitor_dpi_awareness()
        left = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
        top = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
        width = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
        height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
        return (max(0.0, min(1.0, (x - left) / max(1, width - 1))),
                max(0.0, min(1.0, (y - top) / max(1, height - 1))))

    def _keyboard_proc(self, code, wparam, lparam):
        if code < 0:
            return user32.CallNextHookEx(self._keyboard_hook, code, wparam, lparam)
        data = ctypes.cast(lparam, ctypes.POINTER(KBDLLHOOKSTRUCT)).contents
        down = wparam in (WM_KEYDOWN, WM_SYSKEYDOWN)
        if data.vkCode in (VK_CONTROL, 0xA2, 0xA3): self._ctrl = down
        if data.vkCode in (VK_MENU, 0xA4, 0xA5): self._alt = down
        if down and data.vkCode == VK_F8 and self._ctrl and self._alt:
            self.forwarding = not self.forwarding
            print(f"Remote mode: {'ON' if self.forwarding else 'OFF'}")
            return 1
        if self.forwarding and not (data.flags & LLKHF_INJECTED):
            self.send_message({"type": "event", "event": {"kind": "key", "vk": int(data.vkCode), "scan": int(data.scanCode), "down": down, "extended": bool(data.flags & 1)}})
            return 1
        return user32.CallNextHookEx(self._keyboard_hook, code, wparam, lparam)

    def _mouse_proc(self, code, wparam, lparam):
        if code < 0:
            return user32.CallNextHookEx(self._mouse_hook, code, wparam, lparam)
        data = ctypes.cast(lparam, ctypes.POINTER(MSLLHOOKSTRUCT)).contents
        if self.forwarding and not (data.flags & LLMHF_INJECTED):
            if wparam == WM_MOUSEMOVE:
                x, y = self._normalized(data.pt.x, data.pt.y)
                event = {"kind": "mouse_move", "x": x, "y": y}
            elif wparam in (WM_LBUTTONDOWN, WM_LBUTTONUP, WM_RBUTTONDOWN, WM_RBUTTONUP, WM_MBUTTONDOWN, WM_MBUTTONUP):
                button = {WM_LBUTTONDOWN: 0, WM_LBUTTONUP: 0, WM_RBUTTONDOWN: 1, WM_RBUTTONUP: 1, WM_MBUTTONDOWN: 2, WM_MBUTTONUP: 2}[wparam]
                event = {"kind": "mouse_button", "button": button, "down": wparam in (WM_LBUTTONDOWN, WM_RBUTTONDOWN, WM_MBUTTONDOWN)}
            elif wparam == WM_MOUSEWHEEL:
                event = {"kind": "scroll", "delta": ctypes.c_short((data.mouseData >> 16) & 0xffff).value // 120}
            else:
                return user32.CallNextHookEx(self._mouse_hook, code, wparam, lparam)
            self.send_message({"type": "event", "event": event})
            return 1
        return user32.CallNextHookEx(self._mouse_hook, code, wparam, lparam)

    def _clipboard_text(self):
        if not user32.OpenClipboard(None): return None
        try:
            handle = user32.GetClipboardData(CF_UNICODETEXT)
            if not handle: return None
            pointer = kernel32.GlobalLock(handle)
            if not pointer: return None
            try: return ctypes.wstring_at(pointer)
            finally: kernel32.GlobalUnlock(handle)
        finally: user32.CloseClipboard()

    def _clipboard_loop(self, callback):
        while not self._stop.wait(0.25):
            text = self._clipboard_text()
            if text is not None and text != self._last_clipboard:
                self._last_clipboard = text
                callback(text)

    def prepare_remote_entry(self, y_norm=None, source_width=None, source_height=None):
        """Place the pointer just inside Windows and calibrate relative motion.

        The old 160--320 pixel inset looked like an early edge trigger.  A
        two-pixel inset is enough to avoid an immediate return while preserving
        the expected continuous transition at the display boundary.
        """
        self._dpi_awareness = _enable_thread_per_monitor_dpi_awareness()
        point = wintypes.POINT()
        user32.GetCursorPos(ctypes.byref(point))
        left = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
        top = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
        width = user32.GetSystemMetrics(SM_CXVIRTUALSCREEN)
        height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
        inset = min(2, max(0, width - 1))
        entry_x = min(left + width - 1, left + inset)
        if y_norm is None:
            entry_y = max(top, min(point.y, top + height - 1))
        else:
            entry_y = top + int(max(0.0, min(1.0, float(y_norm))) * max(1, height - 1))
        user32.SetCursorPos(entry_x, entry_y)
        self._remote_entry_x = entry_x
        self._release_sent = False
        # Events from macOS are relative display-coordinate deltas.  Map a
        # full display-width/height movement to the physical Windows virtual
        # desktop so a Retina or scaled source display does not feel slow.
        try:
            source_width = float(source_width)
            if source_width > 0:
                self._relative_scale_x = width / source_width
        except (TypeError, ValueError):
            self._relative_scale_x = 1.0
        try:
            source_height = float(source_height)
            if source_height > 0:
                self._relative_scale_y = height / source_height
        except (TypeError, ValueError):
            self._relative_scale_y = 1.0
        print(
            "Windows remote entry: "
            f"DPI={self._dpi_awareness}, relative scale "
            f"{self._relative_scale_x:.2f}x/{self._relative_scale_y:.2f}x"
        )

    def start(self, clipboard_callback, capture=True):
        if not capture:
            threading.Thread(target=self._clipboard_loop, args=(clipboard_callback,), name="sidecursor-windows-clipboard", daemon=True).start()
            return
        # LRESULT is a signed pointer-sized value.  It is not exposed by
        # ctypes.wintypes on every Python/Windows combination.
        callback_result = ctypes.c_ssize_t
        keyboard_type = ctypes.WINFUNCTYPE(callback_result, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        mouse_type = ctypes.WINFUNCTYPE(callback_result, ctypes.c_int, wintypes.WPARAM, wintypes.LPARAM)
        self._callbacks = [keyboard_type(self._keyboard_proc), mouse_type(self._mouse_proc)]
        module = kernel32.GetModuleHandleW(None)
        self._keyboard_hook = user32.SetWindowsHookExW(WH_KEYBOARD_LL, self._callbacks[0], module, 0)
        self._mouse_hook = user32.SetWindowsHookExW(WH_MOUSE_LL, self._callbacks[1], module, 0)
        if not self._keyboard_hook or not self._mouse_hook:
            raise OSError("SetWindowsHookExW failed")
        threading.Thread(target=self._clipboard_loop, args=(clipboard_callback,), name="sidecursor-windows-clipboard", daemon=True).start()
        threading.Thread(target=self._message_loop, name="sidecursor-windows-hooks", daemon=True).start()

    def _message_loop(self):
        _enable_thread_per_monitor_dpi_awareness()
        message = wintypes.MSG()
        while not self._stop.is_set() and user32.GetMessageW(ctypes.byref(message), None, 0, 0) > 0:
            user32.TranslateMessage(ctypes.byref(message))
            user32.DispatchMessageW(ctypes.byref(message))

    @staticmethod
    def _send_input(input_value):
        user32.SendInput(1, ctypes.byref(input_value), ctypes.sizeof(INPUT))

    def inject(self, event):
        self._dpi_awareness = _enable_thread_per_monitor_dpi_awareness()
        kind = event.get("kind")
        if kind == "mouse_move":
            item = INPUT(); item.type = 0
            if "dx" in event:
                item.u.mi.dx = round(float(event.get("dx", 0)) * self._relative_scale_x * WINDOWS_REMOTE_POINTER_SPEED)
                item.u.mi.dy = round(float(event.get("dy", 0)) * self._relative_scale_y * WINDOWS_REMOTE_POINTER_SPEED)
                item.u.mi.dwFlags = 0x0001
            else:
                item.u.mi.dx = int(event["x"] * 65535); item.u.mi.dy = int(event["y"] * 65535)
                # Normalized coordinates are relative to the virtual desktop,
                # not only its primary monitor.
                item.u.mi.dwFlags = 0x0001 | 0x8000 | 0x4000
            self._send_input(item)
            # Crossing the far-left side of Windows returns control to the
            # Mac. This is the counterpart to the Mac's right-edge entry.
            if "dx" in event and int(event.get("dx", 0)) < 0 and not self._release_sent:
                point = wintypes.POINT()
                virtual_left = user32.GetSystemMetrics(SM_XVIRTUALSCREEN)
                if user32.GetCursorPos(ctypes.byref(point)) and point.x <= virtual_left:
                    print(f"Windows left edge reached at x={virtual_left}; returning control to Mac")
                    virtual_top = user32.GetSystemMetrics(SM_YVIRTUALSCREEN)
                    virtual_height = user32.GetSystemMetrics(SM_CYVIRTUALSCREEN)
                    y_norm = (point.y - virtual_top) / max(1, virtual_height - 1)
                    self._release_sent = True
                    self.send_message({"type": "control", "action": "release_remote_mode", "y": y_norm})
        elif kind == "mouse_button":
            flags = {(0, True): 0x0002, (0, False): 0x0004, (1, True): 0x0008, (1, False): 0x0010,
                     (2, True): 0x0020, (2, False): 0x0040}[int(event.get("button", 0)), bool(event.get("down"))]
            item = INPUT(); item.type = 0; item.u.mi.dwFlags = flags; self._send_input(item)
        elif kind == "scroll":
            item = INPUT(); item.type = 0; item.u.mi.mouseData = int(event.get("delta", 0)) * 120; item.u.mi.dwFlags = 0x0800; self._send_input(item)
        elif kind == "key":
            item = INPUT(); item.type = 1; item.u.ki.wVk = int(event["vk"]); item.u.ki.wScan = int(event.get("scan", 0)); item.u.ki.dwFlags = (0x0008 if event.get("extended") else 0) | (0x0002 if not event.get("down") else 0); self._send_input(item)

    def set_clipboard(self, text: str):
        encoded = (text + "\0").encode("utf-16-le")
        if not user32.OpenClipboard(None): return
        try:
            user32.EmptyClipboard()
            handle = kernel32.GlobalAlloc(GMEM_MOVEABLE, len(encoded))
            pointer = kernel32.GlobalLock(handle)
            ctypes.memmove(pointer, encoded, len(encoded))
            kernel32.GlobalUnlock(handle)
            user32.SetClipboardData(CF_UNICODETEXT, handle)
            self._last_clipboard = text
        finally:
            user32.CloseClipboard()

    def stop(self):
        self._stop.set()
        if self._keyboard_hook: user32.UnhookWindowsHookEx(self._keyboard_hook)
        if self._mouse_hook: user32.UnhookWindowsHookEx(self._mouse_hook)
