using System.Runtime.InteropServices;
using SideCursor.Windows.Core;

namespace SideCursor.Windows.Infrastructure;

public static class DisplayCatalog
{
    public static IReadOnlyList<DisplayDescriptor> GetDisplays()
    {
        var displays = new List<DisplayDescriptor>();
        NativeMethods.MonitorEnumProc callback = (monitor, _, _, _) =>
        {
            var monitorInfo = new NativeMethods.MonitorInfoEx
            {
                Size = Marshal.SizeOf<NativeMethods.MonitorInfoEx>(),
                Device = string.Empty,
            };
            if (!NativeMethods.GetMonitorInfo(monitor, ref monitorInfo))
            {
                return true;
            }

            var displayDevice = new NativeMethods.DisplayDevice
            {
                Size = Marshal.SizeOf<NativeMethods.DisplayDevice>(),
                DeviceName = string.Empty,
                DeviceString = string.Empty,
                DeviceId = string.Empty,
                DeviceKey = string.Empty,
            };
            _ = NativeMethods.EnumDisplayDevices(monitorInfo.Device, 0, ref displayDevice, 0);
            var stableId = string.IsNullOrWhiteSpace(displayDevice.DeviceId)
                ? monitorInfo.Device
                : displayDevice.DeviceId;
            // A second query returns the monitor's device interface, which
            // leads to its EDID for the physical size and model name.
            var interfaceDevice = new NativeMethods.DisplayDevice
            {
                Size = Marshal.SizeOf<NativeMethods.DisplayDevice>(),
                DeviceName = string.Empty,
                DeviceString = string.Empty,
                DeviceId = string.Empty,
                DeviceKey = string.Empty,
            };
            var edid = NativeMethods.EnumDisplayDevices(monitorInfo.Device, 0, ref interfaceDevice, NativeMethods.EddGetDeviceInterfaceName)
                ? Edid.ReadForInterface(interfaceDevice.DeviceId)
                : null;
            var friendlyName = edid?.Name
                ?? (string.IsNullOrWhiteSpace(displayDevice.DeviceString) ? monitorInfo.Device : displayDevice.DeviceString);
            var dpiX = 96u;
            var dpiY = 96u;
            if (NativeMethods.GetDpiForMonitor(monitor, NativeMethods.MdtEffectiveDpi, out var resolvedDpiX, out var resolvedDpiY) == 0)
            {
                dpiX = resolvedDpiX;
                dpiY = resolvedDpiY;
            }

            var bounds = new PixelBounds(
                monitorInfo.Monitor.Left,
                monitorInfo.Monitor.Top,
                monitorInfo.Monitor.Right - monitorInfo.Monitor.Left,
                monitorInfo.Monitor.Bottom - monitorInfo.Monitor.Top);
            var (widthMm, heightMm) = OrientedSize(edid, bounds);
            displays.Add(new DisplayDescriptor(
                stableId,
                monitorInfo.Device,
                friendlyName,
                bounds,
                dpiX,
                dpiY,
                (monitorInfo.Flags & 1) != 0,
                widthMm,
                heightMm));
            return true;
        };

        if (!NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
        {
            NativeMethods.ThrowLastError("Unable to enumerate Windows displays");
        }

        return displays.OrderBy(static display => display.DeviceName, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    /// <summary>
    /// EDID sizes are landscape; a rotated display has portrait pixel bounds.
    /// </summary>
    internal static (double Width, double Height) OrientedSize(EdidInfo? edid, PixelBounds bounds)
    {
        if (edid is not { } info || info.WidthMm < 20 || info.HeightMm < 20)
        {
            return (0, 0);
        }

        return (bounds.Width >= bounds.Height) == (info.WidthMm >= info.HeightMm)
            ? (info.WidthMm, info.HeightMm)
            : (info.HeightMm, info.WidthMm);
    }

    public static DisplayDescriptor ResolveTarget(SideCursorConfig configuration) =>
        ResolveTarget(configuration, GetDisplays());

    /// <summary>
    /// Prefers the saved target display. When that monitor is not connected
    /// (a different external monitor, a closed lid, a new dock port), falls
    /// back to the primary display instead of rejecting every remote entry.
    /// The saved choice is left untouched so it wins again once reconnected.
    /// </summary>
    public static DisplayDescriptor ResolveTarget(SideCursorConfig configuration, IReadOnlyList<DisplayDescriptor> displays)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(displays);
        var configured = displays.FirstOrDefault(display => IsConfiguredTarget(configuration, display));
        if (configured is not null)
        {
            return configured;
        }

        return displays.FirstOrDefault(static display => display.IsPrimary)
            ?? (displays.Count > 0 ? displays[0] : null)
            ?? throw new InvalidOperationException("No Windows display is available for remote mode.");
    }

    public static bool IsConfiguredTarget(SideCursorConfig configuration, DisplayDescriptor display) =>
        string.Equals(display.StableId, configuration.TargetDisplayId, StringComparison.OrdinalIgnoreCase);
}
