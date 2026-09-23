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
    /// <summary>
    /// Legacy setting retained so older settings files still deserialize. It is
    /// no longer applied: macOS `pointerScale` is the single user-facing
    /// pointer-speed control, and applying this on top double-scaled motion.
    /// </summary>
    public double PointerCalibration { get; set; } = 1.0;
    /// <summary>
    /// Inject pointer motion as absolute virtual-desktop coordinates so it
    /// bypasses Windows pointer acceleration ("Enhance pointer precision").
    /// This gives 1:1, predictable movement and makes the return-edge math
    /// exact. Disable to fall back to accelerated relative motion.
    /// </summary>
    public bool AbsolutePointer { get; set; } = true;
    public int ReturnEdgeInsetPixels { get; set; } = 1;
    public bool ClipboardEnabled { get; set; } = true;
    public int ClipboardMaximumBytes { get; set; } = MaximumClipboardBytes;
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

    public void Normalize()
    {
        DesktopLeft = NormalizeChord(DesktopLeft, "WIN+CTRL+LEFT");
        DesktopRight = NormalizeChord(DesktopRight, "WIN+CTRL+RIGHT");
        TaskView = NormalizeChord(TaskView, "WIN+TAB");
        ShowDesktop = NormalizeChord(ShowDesktop, "WIN+D");
    }

    public string? GetForCommand(string command) => command switch
    {
        "desktop_left" => DesktopLeft,
        "desktop_right" => DesktopRight,
        "task_view" => TaskView,
        "show_desktop" => ShowDesktop,
        _ => null,
    };

    private static string NormalizeChord(string? value, string fallback)
    {
        return HotkeyChord.TryParse(value, out var chord) ? chord.ToString() : fallback;
    }
}

/// <param name="WidthMm">Physical width from the monitor's EDID, oriented like
/// <paramref name="Bounds"/>; zero when the monitor does not report it.</param>
public sealed record DisplayDescriptor(
    string StableId,
    string DeviceName,
    string FriendlyName,
    PixelBounds Bounds,
    uint DpiX,
    uint DpiY,
    bool IsPrimary,
    double WidthMm = 0,
    double HeightMm = 0)
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

    public double ScaleX => _scaleX;
    public double ScaleY => _scaleY;

    /// <summary>
    /// Switches to another display's scale mid-session, keeping the sub-pixel
    /// remainder so the change is seamless.
    /// </summary>
    public void SetScale(double scaleX, double scaleY)
    {
        if (!double.IsFinite(scaleX) || !double.IsFinite(scaleY) || scaleX <= 0 || scaleY <= 0)
        {
            return;
        }

        _scaleX = Math.Clamp(scaleX, 0.05, 20);
        _scaleY = Math.Clamp(scaleY, 0.05, 20);
    }

    /// <summary>
    /// Scale that moves the Windows pointer the same physical distance the
    /// Mac pointer would have moved: target pixels per millimetre over
    /// source points per millimetre. Null when either size is unknown.
    /// </summary>
    public static (double X, double Y)? PhysicalScale(
        double sourceUnitsPerMmX,
        double sourceUnitsPerMmY,
        PixelBounds target,
        DisplaySizeMm targetSize)
    {
        if (sourceUnitsPerMmX <= 0 || sourceUnitsPerMmY <= 0 || !target.IsUsable || !targetSize.IsUsable)
        {
            return null;
        }

        return (target.Width / targetSize.Width / sourceUnitsPerMmX, target.Height / targetSize.Height / sourceUnitsPerMmY);
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

        if (raw.Length is 2 or 3 && raw.StartsWith("F", StringComparison.OrdinalIgnoreCase) && int.TryParse(raw[1..], CultureInfo.InvariantCulture, out var function) && function is >= 1 and <= 24)
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

public enum ScreenEdge
{
    Left,
    Right,
    Top,
    Bottom,
}

public static class ScreenEdges
{
    public static bool TryParse(string? value, out ScreenEdge edge)
    {
        switch (value)
        {
            case "left": edge = ScreenEdge.Left; return true;
            case "right": edge = ScreenEdge.Right; return true;
            case "top": edge = ScreenEdge.Top; return true;
            case "bottom": edge = ScreenEdge.Bottom; return true;
            default: edge = default; return false;
        }
    }

    public static string ToWire(this ScreenEdge edge) => edge switch
    {
        ScreenEdge.Left => "left",
        ScreenEdge.Right => "right",
        ScreenEdge.Top => "top",
        _ => "bottom",
    };

    /// <summary>Left and right edges run along y; top and bottom along x.</summary>
    public static bool RunsAlongY(this ScreenEdge edge) => edge is ScreenEdge.Left or ScreenEdge.Right;
}

/// <summary>Where the pointer reappears on the Mac, in Quartz points.</summary>
public sealed record MacReturnPoint(string Display, ScreenEdge Edge, double X, double Y);

public sealed record MacZoneSide(string Display, ScreenEdge Edge, double Line, double Start, double End);

/// <summary>
/// A stretch of a Windows display edge that physically touches a Mac display,
/// computed by the Mac from the user's layout. Leaving the Windows display
/// through [Start, End) along <see cref="Edge"/> returns to the Mac; the rest of
/// an outer edge is a wall. Along-edge ranges map linearly start-to-start.
/// </summary>
public sealed record ReturnZone(string Display, ScreenEdge Edge, double Line, double Start, double End, MacZoneSide Mac)
{
    public bool Covers(string displayId, ScreenEdge edge, double along) =>
        edge == Edge && along >= Start && along < End && string.Equals(displayId, Display, StringComparison.OrdinalIgnoreCase);

    public MacReturnPoint MacPointFor(double along)
    {
        var fraction = End > Start ? (along - Start) / (End - Start) : 0;
        var macAlong = Mac.Start + Math.Clamp(fraction, 0, 1) * (Mac.End - Mac.Start);
        return Mac.Edge.RunsAlongY()
            ? new MacReturnPoint(Mac.Display, Mac.Edge, Mac.Line, macAlong)
            : new MacReturnPoint(Mac.Display, Mac.Edge, macAlong, Mac.Line);
    }
}

public readonly record struct DisplaySizeMm(double Width, double Height)
{
    public bool IsUsable => double.IsFinite(Width) && double.IsFinite(Height) && Width >= 20 && Height >= 20;
}

/// <summary>The Mac's view of the layout: corrected display sizes and return zones.</summary>
public sealed record LayoutUpdate(IReadOnlyDictionary<string, DisplaySizeMm> Sizes, IReadOnlyList<ReturnZone> Zones)
{
    public static LayoutUpdate Empty { get; } = new(new Dictionary<string, DisplaySizeMm>(), []);
}

internal readonly record struct DesktopPointerPlan(PixelPoint? MoveTo, ReturnZone? Zone, MacReturnPoint? MacPoint);

/// <summary>
/// Moves the pointer across every Windows display. A move that lands on any
/// display is taken as is, so crossing between Windows monitors works as
/// usual. A move that would leave the desktop is clamped to the display it
/// left, and returns to the Mac only when it leaves through a return zone.
/// </summary>
internal static class DesktopPointerPlanner
{
    public static DisplayDescriptor? DisplayAt(PixelPoint point, IReadOnlyList<DisplayDescriptor> displays)
    {
        foreach (var display in displays)
        {
            if (display.Bounds.Contains(point))
            {
                return display;
            }
        }

        return null;
    }

    public static DisplayDescriptor? Nearest(PixelPoint point, IReadOnlyList<DisplayDescriptor> displays)
    {
        DisplayDescriptor? nearest = null;
        var best = long.MaxValue;
        foreach (var display in displays)
        {
            var clamped = Clamp(point, display.Bounds);
            var dx = (long)clamped.X - point.X;
            var dy = (long)clamped.Y - point.Y;
            var distance = dx * dx + dy * dy;
            if (distance < best)
            {
                best = distance;
                nearest = display;
            }
        }

        return nearest;
    }

    public static PixelPoint Clamp(PixelPoint point, PixelBounds bounds) => new(
        Math.Clamp(point.X, bounds.Left, bounds.Right - 1),
        Math.Clamp(point.Y, bounds.Top, bounds.Bottom - 1));

    public static DesktopPointerPlan Plan(
        PixelPoint current,
        PixelPoint delta,
        IReadOnlyList<DisplayDescriptor> displays,
        IReadOnlyList<ReturnZone> zones)
    {
        if (displays.Count == 0 || (delta.X == 0 && delta.Y == 0))
        {
            return default;
        }

        var next = new PixelPoint(current.X + delta.X, current.Y + delta.Y);
        if (DisplayAt(next, displays) is not null)
        {
            return new DesktopPointerPlan(next, null, null);
        }

        var from = DisplayAt(current, displays) ?? Nearest(current, displays)!;
        var bounds = from.Bounds;
        var clamped = Clamp(next, bounds);
        // The edge the move pushes furthest past decides where it leaves.
        var overshoots = new (ScreenEdge Edge, long Distance)[]
        {
            (ScreenEdge.Left, (long)bounds.Left - next.X),
            (ScreenEdge.Right, (long)next.X - (bounds.Right - 1)),
            (ScreenEdge.Top, (long)bounds.Top - next.Y),
            (ScreenEdge.Bottom, (long)next.Y - (bounds.Bottom - 1)),
        };
        var exit = overshoots.MaxBy(static candidate => candidate.Distance);
        if (exit.Distance > 0)
        {
            var along = exit.Edge.RunsAlongY() ? clamped.Y : clamped.X;
            foreach (var zone in zones)
            {
                if (zone.Covers(from.StableId, exit.Edge, along))
                {
                    return new DesktopPointerPlan(clamped, zone, zone.MacPointFor(along));
                }
            }
        }

        return clamped == current ? default : new DesktopPointerPlan(clamped, null, null);
    }
}
