using System.Globalization;
using System.Text.Json.Serialization;

namespace SideCursor.Windows.Core;

public enum TransportKind
{
    TailscaleTcp,
    BluetoothRfcomm,
}

public enum SessionState
{
    Disconnected,
    Connecting,
    Ready,
    Entering,
    Remote,
    Returning,
    Recovering,
}

public sealed class SideCursorConfig
{
    public const int CurrentSchemaVersion = 1;
    public const int MaximumClipboardBytes = 1024 * 1024;

    public int SchemaVersion { get; set; } = CurrentSchemaVersion;
    public string DeviceId { get; set; } = Guid.NewGuid().ToString("D");
    public TransportKind Transport { get; set; } = TransportKind.TailscaleTcp;
    public string PeerHost { get; set; } = string.Empty;
    public int PeerPort { get; set; } = 24800;
    public string TargetDisplayId { get; set; } = string.Empty;
    public double PointerCalibration { get; set; } = 1.0;
    public int ReturnEdgeInsetPixels { get; set; } = 1;
    public bool ClipboardEnabled { get; set; } = true;
    public int ClipboardMaximumBytes { get; set; } = MaximumClipboardBytes;
    public bool BluetoothReadyOnly { get; set; } = true;
    public CommandBindings Commands { get; set; } = new();

    public void Normalize()
    {
        SchemaVersion = CurrentSchemaVersion;
        if (!Guid.TryParse(DeviceId, out _))
        {
            DeviceId = Guid.NewGuid().ToString("D");
        }

        PeerHost = PeerHost.Trim();
        PeerPort = PeerPort is >= 1 and <= 65535 ? PeerPort : 24800;
        TargetDisplayId = TargetDisplayId.Trim();
        PointerCalibration = Math.Clamp(PointerCalibration, 0.1, 5.0);
        ReturnEdgeInsetPixels = Math.Clamp(ReturnEdgeInsetPixels, 0, 32);
        ClipboardMaximumBytes = Math.Clamp(ClipboardMaximumBytes, 1, MaximumClipboardBytes);
        Commands ??= new CommandBindings();
        Commands.Normalize();
    }
}

public sealed class CommandBindings
{
    public string DesktopLeft { get; set; } = "WIN+CTRL+LEFT";
    public string DesktopRight { get; set; } = "WIN+CTRL+RIGHT";
    public string TaskView { get; set; } = "WIN+TAB";
    public string ShowDesktop { get; set; } = "WIN+D";
    public string CloseTaskView { get; set; } = "ESCAPE";

    public void Normalize()
    {
        DesktopLeft = NormalizeChord(DesktopLeft, "WIN+CTRL+LEFT");
        DesktopRight = NormalizeChord(DesktopRight, "WIN+CTRL+RIGHT");
        TaskView = NormalizeChord(TaskView, "WIN+TAB");
        ShowDesktop = NormalizeChord(ShowDesktop, "WIN+D");
        CloseTaskView = NormalizeChord(CloseTaskView, "ESCAPE");
    }

    public string? GetForCommand(string command) => command switch
    {
        "desktop_left" => DesktopLeft,
        "desktop_right" => DesktopRight,
        "task_view" => TaskView,
        "show_desktop" => ShowDesktop,
        "close_task_view" => CloseTaskView,
        _ => null,
    };

    private static string NormalizeChord(string? value, string fallback)
    {
        return HotkeyChord.TryParse(value, out var chord) ? chord.ToString() : fallback;
    }
}

public sealed record DisplayDescriptor(
    string StableId,
    string DeviceName,
    string FriendlyName,
    PixelBounds Bounds,
    uint DpiX,
    uint DpiY,
    bool IsPrimary)
{
    public string Label => $"{FriendlyName} — {Bounds.Width}×{Bounds.Height} at ({Bounds.Left}, {Bounds.Top})";
}

public readonly record struct PixelPoint(int X, int Y);

public readonly record struct PixelBounds(int Left, int Top, int Width, int Height)
{
    public int Right => Left + Width;
    public int Bottom => Top + Height;
    public bool IsUsable => Width > 0 && Height > 0;

    public bool Contains(PixelPoint point) =>
        point.X >= Left && point.X < Right && point.Y >= Top && point.Y < Bottom;

    public double NormalizeY(int y)
    {
        return Math.Clamp((y - Top) / (double)Math.Max(1, Height - 1), 0.0, 1.0);
    }

    public PixelPoint EntryPoint(double y, int insetPixels)
    {
        var x = Math.Clamp(Left + Math.Max(0, insetPixels), Left, Right - 1);
        var normalizedY = Math.Clamp(y, 0.0, 1.0);
        var targetY = Top + (int)Math.Round(normalizedY * Math.Max(1, Height - 1), MidpointRounding.AwayFromZero);
        return new PixelPoint(x, Math.Clamp(targetY, Top, Bottom - 1));
    }
}

public sealed class RelativeMotionMapper
{
    private double _scaleX = 1.0;
    private double _scaleY = 1.0;
    private double _remainderX;
    private double _remainderY;

    public void Configure(int sourceWidth, int sourceHeight, PixelBounds target, double calibration)
    {
        if (sourceWidth <= 0 || sourceHeight <= 0 || !target.IsUsable)
        {
            throw new ArgumentOutOfRangeException(nameof(sourceWidth), "Source and target display dimensions must be positive.");
        }

        var sanitizedCalibration = Math.Clamp(calibration, 0.1, 5.0);
        _scaleX = target.Width / (double)sourceWidth * sanitizedCalibration;
        _scaleY = target.Height / (double)sourceHeight * sanitizedCalibration;
        _remainderX = 0;
        _remainderY = 0;
    }

    public PixelPoint Translate(double sourceDx, double sourceDy)
    {
        var scaledX = sourceDx * _scaleX + _remainderX;
        var scaledY = sourceDy * _scaleY + _remainderY;
        var dx = (int)Math.Truncate(scaledX);
        var dy = (int)Math.Truncate(scaledY);
        _remainderX = scaledX - dx;
        _remainderY = scaledY - dy;
        return new PixelPoint(dx, dy);
    }
}

/// Computes the selected-display return boundary without touching native
/// input APIs.  A large negative delta must never be injected past the target
/// display's left edge, otherwise a multi-monitor Windows desktop can leak
/// the pointer onto another local display before the Mac gets the return ack.
internal readonly record struct ReturnEdgePlan(bool RequestReturn, PixelPoint? ClampCursorTo)
{
    public static ReturnEdgePlan Continue { get; } = new(false, null);
}

internal static class ReturnEdgePlanner
{
    public static ReturnEdgePlan Plan(
        PixelPoint current,
        PixelPoint relative,
        PixelBounds target,
        int requestedInsetPixels)
    {
        if (relative.X >= 0 || current.Y < target.Top || current.Y >= target.Bottom)
        {
            return ReturnEdgePlan.Continue;
        }

        var safeInset = Math.Clamp(requestedInsetPixels, 0, Math.Max(0, target.Width - 1));
        var boundaryX = target.Left + safeInset;
        var projectedX = (long)current.X + relative.X;
        if (current.X > boundaryX && projectedX > boundaryX)
        {
            return ReturnEdgePlan.Continue;
        }

        var projectedY = (long)current.Y + relative.Y;
        var clampedY = (int)Math.Clamp(projectedY, target.Top, target.Bottom - 1L);
        return new ReturnEdgePlan(true, new PixelPoint(boundaryX, clampedY));
    }
}

public sealed record SessionSnapshot(SessionState State, string Detail, DateTimeOffset ChangedAt);

public sealed record RuntimeSnapshot(
    SessionState State,
    string Detail,
    TransportKind Transport,
    double? RoundTripMilliseconds,
    bool IsBluetoothListening,
    string? TargetDisplayLabel);

public sealed class HotkeyChord
{
    private static readonly Dictionary<string, ushort> KeyNames = new(StringComparer.OrdinalIgnoreCase)
    {
        ["CTRL"] = 0x11,
        ["CONTROL"] = 0x11,
        ["ALT"] = 0x12,
        ["SHIFT"] = 0x10,
        ["WIN"] = 0x5B,
        ["WINDOWS"] = 0x5B,
        ["TAB"] = 0x09,
        ["LEFT"] = 0x25,
        ["UP"] = 0x26,
        ["RIGHT"] = 0x27,
        ["DOWN"] = 0x28,
        ["ESC"] = 0x1B,
        ["ESCAPE"] = 0x1B,
        ["SPACE"] = 0x20,
        ["ENTER"] = 0x0D,
        ["DELETE"] = 0x2E,
    };

    private static readonly Dictionary<ushort, string> CanonicalNames = new()
    {
        [0x11] = "CTRL",
        [0x12] = "ALT",
        [0x10] = "SHIFT",
        [0x5B] = "WIN",
        [0x09] = "TAB",
        [0x25] = "LEFT",
        [0x26] = "UP",
        [0x27] = "RIGHT",
        [0x28] = "DOWN",
        [0x1B] = "ESC",
        [0x20] = "SPACE",
        [0x0D] = "ENTER",
        [0x2E] = "DELETE",
    };

    public HotkeyChord(IReadOnlyList<ushort> virtualKeys)
    {
        if (virtualKeys.Count is < 1 or > 4)
        {
            throw new ArgumentOutOfRangeException(nameof(virtualKeys), "A hotkey must contain one to four keys.");
        }

        VirtualKeys = virtualKeys;
    }

    public IReadOnlyList<ushort> VirtualKeys { get; }

    public static bool TryParse(string? value, out HotkeyChord chord)
    {
        chord = null!;
        if (string.IsNullOrWhiteSpace(value))
        {
            return false;
        }

        var keys = new List<ushort>();
        foreach (var rawPart in value.Split('+', StringSplitOptions.TrimEntries | StringSplitOptions.RemoveEmptyEntries))
        {
            if (!TryParseKey(rawPart, out var key) || keys.Contains(key))
            {
                return false;
            }

            keys.Add(key);
        }

        if (keys.Count is < 1 or > 4)
        {
            return false;
        }

        chord = new HotkeyChord(keys);
        return true;
    }

    public override string ToString()
    {
        return string.Join("+", VirtualKeys.Select(CanonicalName));
    }

    private static bool TryParseKey(string raw, out ushort key)
    {
        if (KeyNames.TryGetValue(raw, out key))
        {
            return true;
        }

        if (raw.Length == 1 && char.IsLetterOrDigit(raw[0]))
        {
            key = char.ToUpperInvariant(raw[0]);
            return true;
        }

        if (raw.Length is 2 or 3 && raw.StartsWith('F') && int.TryParse(raw[1..], CultureInfo.InvariantCulture, out var function) && function is >= 1 and <= 24)
        {
            key = (ushort)(0x70 + function - 1);
            return true;
        }

        key = 0;
        return false;
    }

    private static string CanonicalName(ushort key)
    {
        if (CanonicalNames.TryGetValue(key, out var name))
        {
            return name;
        }

        if (key is >= (ushort)'A' and <= (ushort)'Z' or >= (ushort)'0' and <= (ushort)'9')
        {
            return ((char)key).ToString(CultureInfo.InvariantCulture);
        }

        if (key is >= 0x70 and <= 0x87)
        {
            return $"F{key - 0x70 + 1}";
        }

        return $"0x{key:X2}";
    }
}
