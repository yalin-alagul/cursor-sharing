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
            var friendlyName = string.IsNullOrWhiteSpace(displayDevice.DeviceString)
                ? monitorInfo.Device
                : displayDevice.DeviceString;
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
            displays.Add(new DisplayDescriptor(
                stableId,
                monitorInfo.Device,
                friendlyName,
                bounds,
                dpiX,
                dpiY,
                (monitorInfo.Flags & 1) != 0));
            return true;
        };

        if (!NativeMethods.EnumDisplayMonitors(IntPtr.Zero, IntPtr.Zero, callback, IntPtr.Zero))
        {
            NativeMethods.ThrowLastError("Unable to enumerate Windows displays");
        }

        return displays.OrderBy(static display => display.DeviceName, StringComparer.OrdinalIgnoreCase).ToArray();
    }

    public static DisplayDescriptor ResolveTarget(SideCursorConfig configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        var displays = GetDisplays();
        var configured = displays.FirstOrDefault(display => string.Equals(display.StableId, configuration.TargetDisplayId, StringComparison.OrdinalIgnoreCase));
        if (configured is not null)
        {
            return configured;
        }

        if (string.IsNullOrWhiteSpace(configuration.TargetDisplayId) && displays.Count == 1)
        {
            return displays[0];
        }

        throw new InvalidOperationException("The configured Windows target display is unavailable. Select an available display before entering remote mode.");
    }
}
