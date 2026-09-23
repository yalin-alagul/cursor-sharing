using System.ComponentModel;
using System.Runtime.InteropServices;
using SideCursor.Windows.Core;

namespace SideCursor.Windows.Infrastructure;

public sealed class InputInjectionException : Exception
{
    public InputInjectionException(string message, Exception? innerException = null)
        : base(message, innerException)
    {
    }
}

public sealed record PointerInjectionResult(bool ReturnRequested, double ReturnY, MacReturnPoint? MacPoint = null)
{
    public static PointerInjectionResult Continue { get; } = new(false, 0);
}

/// <summary>
/// A held key is identified by its virtual key together with its extended
/// flag. Keys such as the main and keypad variants of Enter share a virtual
/// key but differ in scan code, so tracking the extended flag lets ReleaseAll
/// release exactly the key that was pressed.
/// </summary>
internal readonly record struct PressedKey(ushort Vk, bool Extended);

public sealed class WindowsInputInjector
{
    private const ushort VkControl = 0x11;
    private const ushort VkLeftControl = 0xA2;
    private const ushort VkRightControl = 0xA3;
    private readonly object _gate = new();
    private readonly RelativeMotionMapper _motionMapper = new();
    private readonly HashSet<PressedKey> _pressedKeys = [];
    private readonly HashSet<string> _pressedButtons = new(StringComparer.Ordinal);
    private DisplayDescriptor? _targetDisplay;
    private int _returnEdgeInsetPixels;
    private bool _returnRequested;
    private DateTime _lastTargetCheckUtc = DateTime.MinValue;
    private bool _useAbsolutePointer = true;
    private int _virtualLeft;
    private int _virtualTop;
    private int _virtualWidth = 1;
    private int _virtualHeight = 1;
    private int _cursorX;
    private int _cursorY;
    // Physical layout from the Mac. In layout mode the pointer moves across
    // every Windows display and returns only through the Mac's return zones.
    private LayoutUpdate _layout = LayoutUpdate.Empty;
    private IReadOnlyList<DisplayDescriptor> _desktop = [];
    private bool _layoutMode;
    private double _sourceUnitsPerMmX;
    private double _sourceUnitsPerMmY;
    private string? _scaledDisplayId;

    public void ConfigureLayout(LayoutUpdate layout)
    {
        ArgumentNullException.ThrowIfNull(layout);
        lock (_gate)
        {
            _layout = layout;
            _scaledDisplayId = null;
        }
    }

    /// <param name="targetDisplayId">From the Mac's layout: the display and
    /// pixel the pointer physically enters at. Without it the configured
    /// target display and <paramref name="normalizedY"/> are used.</param>
    public DisplayDescriptor EnterRemote(
        SideCursorConfig configuration,
        string sourceDisplayId,
        int sourceWidth,
        int sourceHeight,
        double normalizedY,
        string? targetDisplayId = null,
        PixelPoint? targetPoint = null,
        double sourceWidthMm = 0,
        double sourceHeightMm = 0)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        if (string.IsNullOrWhiteSpace(sourceDisplayId))
        {
            throw new InputInjectionException("The Mac did not provide a stable source display identifier.");
        }

        lock (_gate)
        {
            var displays = DisplayCatalog.GetDisplays();
            DisplayDescriptor target;
            PixelPoint entry;
            if (targetDisplayId is not null && targetPoint is { } point)
            {
                target = displays.FirstOrDefault(display => string.Equals(display.StableId, targetDisplayId, StringComparison.OrdinalIgnoreCase))
                    ?? throw new InvalidOperationException("The Windows display in the Mac's layout is not connected. Reconnect it or rearrange the displays in the Mac's Display Layout settings.");
                entry = DesktopPointerPlanner.Clamp(point, target.Bounds);
                _layoutMode = true;
            }
            else
            {
                target = DisplayCatalog.ResolveTarget(configuration, displays);
                // Only a small inset keeps the pointer a hair off the return edge.
                // Handoff is meant to be instant both ways, so do not push the entry
                // point far inside the display.
                var entryInset = Math.Max(2, configuration.ReturnEdgeInsetPixels + 6);
                entry = target.Bounds.EntryPoint(normalizedY, insetPixels: entryInset);
                _layoutMode = false;
            }

            _desktop = displays;
            // macOS owns the user-facing pointer-speed control (`pointerScale`).
            // Windows applies only the source-to-target scale: physical when
            // both sizes are known, otherwise the resolution ratio. The legacy
            // PointerCalibration setting is retained for configuration
            // compatibility but must not multiply on top, which double-scaled
            // pointer motion when both controls were raised.
            _motionMapper.Configure(sourceWidth, sourceHeight, target.Bounds, calibration: 1.0);
            _sourceUnitsPerMmX = sourceWidthMm >= 20 ? sourceWidth / sourceWidthMm : 0;
            _sourceUnitsPerMmY = sourceHeightMm >= 20 ? sourceHeight / sourceHeightMm : 0;
            _scaledDisplayId = null;
            if (_layoutMode)
            {
                ApplyPhysicalScale(target);
            }

            SetCursorPosOrThrow(entry.X, entry.Y, "Unable to position the Windows pointer at the target display edge");

            _useAbsolutePointer = configuration.AbsolutePointer && CacheVirtualScreen(target);
            TrackCursor(entry);
            _targetDisplay = target;
            _returnEdgeInsetPixels = configuration.ReturnEdgeInsetPixels;
            _returnRequested = false;
            return target;
        }
    }

    public PointerInjectionResult InjectPointer(double sourceDx, double sourceDy)
    {
        lock (_gate)
        {
            var target = RequireTarget();
            EnsureTargetStillPresent(target);
            if (_layoutMode)
            {
                return InjectLayoutPointer(sourceDx, sourceDy);
            }

            var relative = _motionMapper.Translate(sourceDx, sourceDy);
            // In absolute mode the injected position is tracked locally, so the
            // return-edge plan is computed from an exact position instead of a
            // possibly-accelerated GetCursorPos reading.
            var current = _useAbsolutePointer ? new PixelPoint(_cursorX, _cursorY) : ReadCursorPosition();
            var returnPlan = ReturnEdgePlanner.Plan(current, relative, target.Bounds, _returnEdgeInsetPixels);
            if (returnPlan.RequestReturn)
            {
                var boundary = returnPlan.ClampCursorTo.GetValueOrDefault();
                SetCursorPosOrThrow(boundary.X, boundary.Y, "Unable to keep the Windows pointer inside the selected return edge");
                TrackCursor(boundary);
                return RequestReturn(target, boundary);
            }

            if (relative.X != 0 || relative.Y != 0)
            {
                if (_useAbsolutePointer)
                {
                    var nextX = Math.Clamp(_cursorX + relative.X, target.Bounds.Left, target.Bounds.Right - 1);
                    var nextY = Math.Clamp(_cursorY + relative.Y, target.Bounds.Top, target.Bounds.Bottom - 1);
                    if (nextX != _cursorX || nextY != _cursorY)
                    {
                        SendAbsoluteMove(nextX, nextY);
                        TrackCursor(new PixelPoint(nextX, nextY));
                    }
                }
                else
                {
                    SendMouse(relative.X, relative.Y, 0, NativeMethods.MouseeventfMove);
                }
            }

            return PointerInjectionResult.Continue;
        }
    }

    private PointerInjectionResult InjectLayoutPointer(double sourceDx, double sourceDy)
    {
        var current = _useAbsolutePointer ? new PixelPoint(_cursorX, _cursorY) : ReadCursorPosition();
        var display = DesktopPointerPlanner.DisplayAt(current, _desktop);
        if (display is not null && !string.Equals(display.StableId, _scaledDisplayId, StringComparison.OrdinalIgnoreCase))
        {
            ApplyPhysicalScale(display);
        }

        var relative = _motionMapper.Translate(sourceDx, sourceDy);
        var plan = DesktopPointerPlanner.Plan(current, relative, _desktop, _layout.Zones);
        if (plan.Zone is not null && plan.MoveTo is { } exit)
        {
            SetCursorPosOrThrow(exit.X, exit.Y, "Unable to keep the Windows pointer at the return edge");
            TrackCursor(exit);
            if (_returnRequested)
            {
                return PointerInjectionResult.Continue;
            }

            _returnRequested = true;
            var bounds = (DesktopPointerPlanner.DisplayAt(exit, _desktop) ?? display ?? RequireTarget()).Bounds;
            return new PointerInjectionResult(true, bounds.NormalizeY(exit.Y), plan.MacPoint);
        }

        if (plan.MoveTo is { } next && next != current)
        {
            if (_useAbsolutePointer)
            {
                SendAbsoluteMove(next.X, next.Y);
                TrackCursor(next);
            }
            else
            {
                SendMouse(relative.X, relative.Y, 0, NativeMethods.MouseeventfMove);
            }
        }

        return PointerInjectionResult.Continue;
    }

    /// <summary>
    /// Uses the Mac's corrected size for the display when it sent one,
    /// otherwise the display's own EDID size.
    /// </summary>
    private void ApplyPhysicalScale(DisplayDescriptor display)
    {
        _scaledDisplayId = display.StableId;
        var size = _layout.Sizes.TryGetValue(display.StableId, out var corrected)
            ? corrected
            : new DisplaySizeMm(display.WidthMm, display.HeightMm);
        if (RelativeMotionMapper.PhysicalScale(_sourceUnitsPerMmX, _sourceUnitsPerMmY, display.Bounds, size) is { } scale)
        {
            _motionMapper.SetScale(scale.X, scale.Y);
        }
    }

    public void InjectButton(string button, bool down)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(button);
        lock (_gate)
        {
            EnsureTargetStillPresent(RequireTarget());
            var normalized = button.ToLowerInvariant();
            var flags = (normalized, down) switch
            {
                ("left", true) => NativeMethods.MouseeventfLeftDown,
                ("left", false) => NativeMethods.MouseeventfLeftUp,
                ("right", true) => NativeMethods.MouseeventfRightDown,
                ("right", false) => NativeMethods.MouseeventfRightUp,
                ("middle", true) => NativeMethods.MouseeventfMiddleDown,
                ("middle", false) => NativeMethods.MouseeventfMiddleUp,
                _ => throw new InputInjectionException($"Unsupported mouse button '{button}'."),
            };
            SendMouse(0, 0, 0, flags);
            if (down)
            {
                _pressedButtons.Add(normalized);
            }
            else
            {
                _pressedButtons.Remove(normalized);
            }
        }
    }

    public void InjectScroll(double horizontal, double vertical)
    {
        lock (_gate)
        {
            EnsureTargetStillPresent(RequireTarget());
            if (Math.Abs(vertical) > double.Epsilon)
            {
                SendMouse(0, 0, ToWheelDelta(vertical), NativeMethods.MouseeventfWheel);
            }

            if (Math.Abs(horizontal) > double.Epsilon)
            {
                SendMouse(0, 0, ToWheelDelta(horizontal), NativeMethods.MouseeventfHWheel);
            }
        }
    }

    /// <summary>
    /// Replays a Mac trackpad pinch as Ctrl+wheel, the zoom input Windows
    /// apps (and precision touchpads) use. Ctrl is pressed and released in
    /// the same SendInput batch so it can never be left stuck down, and is
    /// skipped when the user is already holding a forwarded Ctrl key.
    /// </summary>
    public void InjectZoom(int steps)
    {
        if (steps == 0)
        {
            return;
        }

        lock (_gate)
        {
            EnsureTargetStillPresent(RequireTarget());
            var ctrlHeld = _pressedKeys.Any(static key => key.Vk is VkControl or VkLeftControl or VkRightControl);
            Send(BuildZoomInputs(steps, ctrlHeld));
        }
    }

    internal static NativeMethods.Input[] BuildZoomInputs(int steps, bool ctrlHeld)
    {
        var wheel = MouseInput(0, 0, steps * NativeMethods.WheelDelta, NativeMethods.MouseeventfWheel);
        return ctrlHeld
            ? [wheel]
            : [KeyInput(VkControl, down: true, extended: false), wheel, KeyInput(VkControl, down: false, extended: false)];
    }

    public void InjectKey(ushort virtualKey, bool down, bool extended)
    {
        if (virtualKey == 0)
        {
            throw new InputInjectionException("A key event must include a non-zero virtual-key code.");
        }

        lock (_gate)
        {
            EnsureTargetStillPresent(RequireTarget());
            SendKey(virtualKey, down, extended);
            var pressedKey = new PressedKey(virtualKey, extended);
            if (down)
            {
                _pressedKeys.Add(pressedKey);
            }
            else
            {
                _pressedKeys.Remove(pressedKey);
            }
        }
    }

    public void InjectCommand(string command, CommandBindings commandBindings)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command);
        ArgumentNullException.ThrowIfNull(commandBindings);
        lock (_gate)
        {
            EnsureTargetStillPresent(RequireTarget());
            var binding = commandBindings.GetForCommand(command)
                ?? throw new InputInjectionException($"Unsupported remote command '{command}'.");
            if (!HotkeyChord.TryParse(binding, out var chord))
            {
                throw new InputInjectionException($"The configured shortcut '{binding}' is invalid.");
            }

            try
            {
                foreach (var key in chord.VirtualKeys)
                {
                    SendKey(key, down: true, IsExtendedKey(key));
                }
            }
            finally
            {
                foreach (var key in chord.VirtualKeys.Reverse())
                {
                    SendKey(key, down: false, IsExtendedKey(key));
                }
            }
        }
    }

    public void ReleaseAll()
    {
        lock (_gate)
        {
            var failures = new List<Exception>();
            foreach (var key in Enumerable.Reverse(_pressedKeys.ToArray()))
            {
                try
                {
                    SendKey(key.Vk, down: false, key.Extended);
                }
                catch (Exception exception)
                {
                    failures.Add(exception);
                }
                finally
                {
                    _pressedKeys.Remove(key);
                }
            }

            foreach (var button in _pressedButtons.ToArray())
            {
                try
                {
                    var flags = button switch
                    {
                        "left" => NativeMethods.MouseeventfLeftUp,
                        "right" => NativeMethods.MouseeventfRightUp,
                        "middle" => NativeMethods.MouseeventfMiddleUp,
                        _ => 0u,
                    };
                    if (flags != 0)
                    {
                        SendMouse(0, 0, 0, flags);
                    }
                }
                catch (Exception exception)
                {
                    failures.Add(exception);
                }
                finally
                {
                    _pressedButtons.Remove(button);
                }
            }

            _targetDisplay = null;
            _returnRequested = false;
            if (failures.Count > 0)
            {
                throw new AggregateException("One or more injected inputs could not be released.", failures);
            }
        }
    }

    private DisplayDescriptor RequireTarget()
    {
        return _targetDisplay ?? throw new InputInjectionException("Windows input was received outside an acknowledged remote session.");
    }

    /// <summary>
    /// Re-checks the target display at most once per second. Enumerating
    /// monitors on every input sample made remote movement laggy, but checking
    /// only during pointer motion meant a keyboard-only or click-only session
    /// kept injecting into a display that had already been unplugged. Calling
    /// this from every injection path closes that gap while staying throttled.
    /// </summary>
    private void EnsureTargetStillPresent(DisplayDescriptor target)
    {
        if (DateTime.UtcNow - _lastTargetCheckUtc <= TimeSpan.FromSeconds(1))
        {
            return;
        }

        _lastTargetCheckUtc = DateTime.UtcNow;
        if (_layoutMode)
        {
            // The pointer may be on any Windows display, so refresh them all
            // instead of pinning the session to the entry display.
            var displays = DisplayCatalog.GetDisplays();
            if (displays.Count == 0)
            {
                throw new InputInjectionException("No Windows display is connected.");
            }

            _desktop = displays;
            _scaledDisplayId = null;
            if (_useAbsolutePointer)
            {
                // Absolute moves are normalised over the virtual desktop,
                // which changes when a monitor is added or removed.
                CacheVirtualScreen(displays[0]);
                if (DesktopPointerPlanner.DisplayAt(new PixelPoint(_cursorX, _cursorY), displays) is null)
                {
                    TrackCursor(ReadCursorPosition());
                }
            }

            return;
        }

        VerifyTargetStillPresent(target);
    }

    private static void VerifyTargetStillPresent(DisplayDescriptor target)
    {
        var stillPresent = DisplayCatalog.GetDisplays().Any(display => string.Equals(display.StableId, target.StableId, StringComparison.OrdinalIgnoreCase));
        if (!stillPresent)
        {
            throw new InputInjectionException("The configured Windows target display was disconnected during a remote session.");
        }
    }

    private static PixelPoint ReadCursorPosition()
    {
        if (!NativeMethods.GetCursorPos(out var point))
        {
            throw new InputInjectionException(
                "Unable to read the Windows pointer position",
                new Win32Exception(Marshal.GetLastWin32Error()));
        }

        return new PixelPoint(point.X, point.Y);
    }

    private static void SetCursorPosOrThrow(int x, int y, string operation)
    {
        if (!NativeMethods.SetCursorPos(x, y))
        {
            throw new InputInjectionException(operation, new Win32Exception(Marshal.GetLastWin32Error()));
        }
    }

    private PointerInjectionResult RequestReturn(DisplayDescriptor target, PixelPoint? pointer = null)
    {
        if (_returnRequested)
        {
            return PointerInjectionResult.Continue;
        }

        var point = pointer ?? ReadCursorPosition();
        _returnRequested = true;
        return new PointerInjectionResult(true, target.Bounds.NormalizeY(point.Y));
    }

    private static int ToWheelDelta(double notchDelta)
    {
        var scaled = notchDelta * NativeMethods.WheelDelta;
        return (int)Math.Clamp(Math.Round(scaled, MidpointRounding.AwayFromZero), int.MinValue, int.MaxValue);
    }

    private static bool IsExtendedKey(ushort virtualKey)
    {
        return virtualKey is 0x21 or 0x22 or 0x23 or 0x24 or 0x25 or 0x26 or 0x27 or 0x28 or 0x2D or 0x2E or 0x5B or 0x5C or 0xA3 or 0xA5;
    }

    /// <summary>
    /// Reads the virtual-desktop metrics used to normalize absolute pointer
    /// coordinates. Falls back to the target display's bounds if the metrics
    /// are unavailable, and reports false (relative mode) if neither works.
    /// </summary>
    private bool CacheVirtualScreen(DisplayDescriptor target)
    {
        _virtualLeft = NativeMethods.GetSystemMetrics(NativeMethods.SmXvirtualscreen);
        _virtualTop = NativeMethods.GetSystemMetrics(NativeMethods.SmYvirtualscreen);
        _virtualWidth = NativeMethods.GetSystemMetrics(NativeMethods.SmCxvirtualscreen);
        _virtualHeight = NativeMethods.GetSystemMetrics(NativeMethods.SmCyvirtualscreen);
        if (_virtualWidth > 0 && _virtualHeight > 0)
        {
            return true;
        }

        _virtualLeft = target.Bounds.Left;
        _virtualTop = target.Bounds.Top;
        _virtualWidth = target.Bounds.Width;
        _virtualHeight = target.Bounds.Height;
        return _virtualWidth > 0 && _virtualHeight > 0;
    }

    private void TrackCursor(PixelPoint point)
    {
        _cursorX = point.X;
        _cursorY = point.Y;
    }

    /// <summary>
    /// Moves the cursor with MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK.
    /// Unlike relative motion, absolute motion is not passed through Windows
    /// pointer acceleration, so remote movement is 1:1 and predictable.
    /// </summary>
    private void SendAbsoluteMove(int x, int y)
    {
        var width = Math.Max(1, _virtualWidth - 1);
        var height = Math.Max(1, _virtualHeight - 1);
        var normalizedX = (int)Math.Round((x - _virtualLeft) * 65535.0 / width, MidpointRounding.AwayFromZero);
        var normalizedY = (int)Math.Round((y - _virtualTop) * 65535.0 / height, MidpointRounding.AwayFromZero);
        SendMouse(
            Math.Clamp(normalizedX, 0, 65535),
            Math.Clamp(normalizedY, 0, 65535),
            0,
            NativeMethods.MouseeventfMove | NativeMethods.MouseeventfAbsolute | NativeMethods.MouseeventfVirtualDesk);
    }

    private static void SendMouse(int dx, int dy, int mouseData, uint flags)
    {
        Send([MouseInput(dx, dy, mouseData, flags)]);
    }

    private static NativeMethods.Input MouseInput(int dx, int dy, int mouseData, uint flags)
    {
        return new NativeMethods.Input
        {
            Type = NativeMethods.InputMouse,
            Data = new NativeMethods.InputUnion
            {
                Mouse = new NativeMethods.MouseInput
                {
                    Dx = dx,
                    Dy = dy,
                    MouseData = unchecked((uint)mouseData),
                    Flags = flags,
                },
            },
        };
    }

    private static void SendKey(ushort virtualKey, bool down, bool extended)
    {
        Send([KeyInput(virtualKey, down, extended)]);
    }

    private static NativeMethods.Input KeyInput(ushort virtualKey, bool down, bool extended)
    {
        return new NativeMethods.Input
        {
            Type = NativeMethods.InputKeyboard,
            Data = new NativeMethods.InputUnion
            {
                Keyboard = new NativeMethods.KeyboardInput
                {
                    VirtualKey = virtualKey,
                    Flags = (extended ? NativeMethods.KeyeventfExtendedKey : 0) |
                            (down ? 0 : NativeMethods.KeyeventfKeyUp),
                },
            },
        };
    }

    private static void Send(NativeMethods.Input[] inputs)
    {
        var sent = NativeMethods.SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<NativeMethods.Input>());
        if (sent != inputs.Length)
        {
            var error = new Win32Exception(Marshal.GetLastWin32Error());
            throw new InputInjectionException("Windows rejected an injected input. Elevated applications require SideCursor to run elevated.", error);
        }
    }
}
