using System.Text;
using Microsoft.Win32;

namespace SideCursor.Windows.Infrastructure;

/// <summary>Physical size and model name read from a monitor's EDID.</summary>
internal readonly record struct EdidInfo(double WidthMm, double HeightMm, string? Name);

internal static class Edid
{
    private static readonly byte[] Header = [0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00];

    /// <summary>
    /// Prefers the first detailed timing descriptor's millimetre size and
    /// falls back to the base block's centimetre size. The name comes from
    /// the monitor-name descriptor (tag 0xFC).
    /// </summary>
    public static EdidInfo? Parse(ReadOnlySpan<byte> edid)
    {
        if (edid.Length < 128 || !edid[..8].SequenceEqual(Header))
        {
            return null;
        }

        double width = 0;
        double height = 0;
        var pixelClock = edid[54] | (edid[55] << 8);
        if (pixelClock != 0)
        {
            width = edid[66] | ((edid[68] & 0xF0) << 4);
            height = edid[67] | ((edid[68] & 0x0F) << 8);
        }

        if (width < 20 || height < 20)
        {
            width = edid[21] * 10.0;
            height = edid[22] * 10.0;
        }

        string? name = null;
        for (var offset = 54; offset <= 108; offset += 18)
        {
            if (edid[offset] == 0 && edid[offset + 1] == 0 && edid[offset + 3] == 0xFC)
            {
                var text = Encoding.ASCII.GetString(edid.Slice(offset + 5, 13));
                var end = text.IndexOf('\n');
                name = (end >= 0 ? text[..end] : text).Trim();
                if (name.Length == 0)
                {
                    name = null;
                }
            }
        }

        return new EdidInfo(width, height, name);
    }

    /// <summary>
    /// Maps a monitor device interface such as
    /// <c>\\?\DISPLAY#DELA277#4&amp;2638bbf3&amp;0&amp;UID4145#{e6f07b5f-...}</c> to its
    /// registry key under <c>HKLM\SYSTEM\CurrentControlSet\Enum</c>.
    /// </summary>
    public static string? RegistryKeyForInterface(string? deviceInterface)
    {
        if (string.IsNullOrWhiteSpace(deviceInterface))
        {
            return null;
        }

        var trimmed = deviceInterface.StartsWith(@"\\?\", StringComparison.Ordinal) ? deviceInterface[4..] : deviceInterface;
        var parts = trimmed.Split('#');
        if (parts.Length < 3 || parts.Take(3).Any(static part => part.Length == 0 || part.Contains('\\')))
        {
            return null;
        }

        return $@"SYSTEM\CurrentControlSet\Enum\{parts[0]}\{parts[1]}\{parts[2]}\Device Parameters";
    }

    public static EdidInfo? ReadForInterface(string? deviceInterface)
    {
        var keyPath = RegistryKeyForInterface(deviceInterface);
        if (keyPath is null)
        {
            return null;
        }

        try
        {
            using var key = Registry.LocalMachine.OpenSubKey(keyPath);
            return key?.GetValue("EDID") is byte[] bytes ? Parse(bytes) : null;
        }
        catch (Exception exception) when (exception is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return null;
        }
    }
}
