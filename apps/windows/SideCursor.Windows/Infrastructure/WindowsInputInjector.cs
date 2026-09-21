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

public sealed record PointerInjectionResult(bool ReturnRequested, double ReturnY)
{
    public static PointerInjectionResult Continue { get; } = new(false, 0);
}

public sealed class WindowsInputInjector
{
    private readonly object _gate = new();
    private readonly RelativeMotionMapper _motionMapper = new();
    private readonly HashSet<ushort> _pressedKeys = [];
    private readonly HashSet<string> _pressedButtons = new(StringComparer.Ordinal);
    private DisplayDescriptor? _targetDisplay;
    private int _returnEdgeInsetPixels;
    private bool _returnRequested;

    public bool IsRemote
    {
        get
        {
            lock (_gate)
            {
                return _targetDisplay is not null;
            }
        }
    }

    public DisplayDescriptor EnterRemote(SideCursorConfig configuration, string sourceDisplayId, int sourceWidth, int sourceHeight, double normalizedY)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        if (string.IsNullOrWhiteSpace(sourceDisplayId))
        {
            throw new InputInjectionException("The Mac did not provide a stable source display identifier.");
        }

        lock (_gate)
        {
            var target = DisplayCatalog.ResolveTarget(configuration);
            _motionMapper.Configure(sourceWidth, sourceHeight, target.Bounds, configuration.PointerCalibration);
            var entry = target.Bounds.EntryPoint(normalizedY, insetPixels: 2);
            if (!NativeMethods.SetCursorPos(entry.X, entry.Y))
            {
                NativeMethods.ThrowLastError("Unable to position the Windows pointer at the target display edge");
            }

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
            VerifyTargetStillPresent(target);
            var relative = _motionMapper.Translate(sourceDx, sourceDy);
            var current = ReadCursorPosition();
            var returnPlan = ReturnEdgePlanner.Plan(current, relative, target.Bounds, _returnEdgeInsetPixels);
            if (returnPlan.RequestReturn)
            {
                var boundary = returnPlan.ClampCursorTo.GetValueOrDefault();
                if (!NativeMethods.SetCursorPos(boundary.X, boundary.Y))
                {
                    NativeMethods.ThrowLastError("Unable to keep the Windows pointer inside the selected return edge");
                }
                return RequestReturn(target, boundary);
            }

            if (relative.X != 0 || relative.Y != 0)
            {
                SendMouse(relative.X, relative.Y, 0, NativeMethods.MouseeventfMove);
            }

            return PointerInjectionResult.Continue;
        }
    }

    public void InjectButton(string button, bool down)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(button);
        lock (_gate)
        {
            _ = RequireTarget();
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
            _ = RequireTarget();
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

    public void InjectKey(ushort virtualKey, bool down, bool extended)
    {
        if (virtualKey == 0)
        {
            throw new InputInjectionException("A key event must include a non-zero virtual-key code.");
        }

        lock (_gate)
        {
            _ = RequireTarget();
            SendKey(virtualKey, down, extended);
            if (down)
            {
                _pressedKeys.Add(virtualKey);
            }
            else
            {
                _pressedKeys.Remove(virtualKey);
            }
        }
    }

    public void InjectCommand(string command, CommandBindings commandBindings)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(command);
        ArgumentNullException.ThrowIfNull(commandBindings);
        lock (_gate)
        {
            _ = RequireTarget();
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
                    SendKey(key, down: false, IsExtendedKey(key));
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
            NativeMethods.ThrowLastError("Unable to read the Windows pointer position");
        }

        return new PixelPoint(point.X, point.Y);
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

    private static void SendMouse(int dx, int dy, int mouseData, uint flags)
    {
        var input = new NativeMethods.Input
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
        Send([input]);
    }

    private static void SendKey(ushort virtualKey, bool down, bool extended)
    {
        var input = new NativeMethods.Input
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
        Send([input]);
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
