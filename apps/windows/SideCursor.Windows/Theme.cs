using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Media;
using Microsoft.Win32;

namespace SideCursor.Windows;

/// <summary>
/// Windows 11 light and dark palettes. The window follows the Windows app
/// theme (Settings → Personalization → Colors) and switches live.
/// </summary>
internal static class Theme
{
    private const int DwmUseImmersiveDarkMode = 20;

    public static bool IsDark { get; private set; }

    public static bool SystemPrefersDark()
    {
        try
        {
            using var key = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
            return key?.GetValue("AppsUseLightTheme") is int value && value == 0;
        }
        catch (Exception exception) when (exception is System.Security.SecurityException or UnauthorizedAccessException or IOException)
        {
            return false;
        }
    }

    public static void Apply(ResourceDictionary resources, bool dark)
    {
        IsDark = dark;
        var palette = dark
            ? new Dictionary<string, string>
            {
                ["WindowBackground"] = "#202020",
                ["CardBackground"] = "#2B2B2B",
                ["CardBorder"] = "#1C1C1C",
                ["TextPrimary"] = "#FFFFFF",
                ["TextSecondary"] = "#C8C8C8",
                ["Accent"] = "#60CDFF",
                ["AccentHover"] = "#5ABDEB",
                ["AccentText"] = "#000000",
                ["ControlBackground"] = "#2D2D2D",
                ["ControlHover"] = "#323232",
                ["ControlBorder"] = "#3C3C3C",
                ["NavHover"] = "#2D2D2D",
                ["NavSelected"] = "#2E2E2E",
                ["InfoBackground"] = "#1E2A35",
                ["InfoBorder"] = "#28394A",
            }
            : new Dictionary<string, string>
            {
                ["WindowBackground"] = "#F3F3F3",
                ["CardBackground"] = "#FFFFFF",
                ["CardBorder"] = "#E5E5E5",
                ["TextPrimary"] = "#1B1B1B",
                ["TextSecondary"] = "#5F5F5F",
                ["Accent"] = "#005FB8",
                ["AccentHover"] = "#1A6FC2",
                ["AccentText"] = "#FFFFFF",
                ["ControlBackground"] = "#FBFBFB",
                ["ControlHover"] = "#F3F3F3",
                ["ControlBorder"] = "#D2D2D2",
                ["NavHover"] = "#EAEAEA",
                ["NavSelected"] = "#E3E3E3",
                ["InfoBackground"] = "#EEF4FB",
                ["InfoBorder"] = "#D2E2F4",
            };

        foreach (var (key, color) in palette)
        {
            var brush = new SolidColorBrush((Color)ColorConverter.ConvertFromString(color));
            brush.Freeze();
            resources[key] = brush;
        }
    }

    /// <summary>Matches the title bar to the theme.</summary>
    public static void ApplyTitleBar(Window window)
    {
        var handle = new WindowInteropHelper(window).Handle;
        if (handle == IntPtr.Zero)
        {
            return;
        }

        var value = IsDark ? 1 : 0;
        _ = DwmSetWindowAttribute(handle, DwmUseImmersiveDarkMode, ref value, sizeof(int));
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int size);
}
