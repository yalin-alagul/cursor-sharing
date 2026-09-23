using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Services;

namespace SideCursor.Windows;

/// <summary>One of this PC's displays, as listed on the Displays page.</summary>
public sealed record DisplayRow(string Name, string Detail, Visibility PrimaryVisibility);

public partial class MainWindow : Window
{
    private readonly SideCursorRuntime _runtime;
    private IReadOnlyList<DisplayDescriptor> _displays = [];
    private bool _loading;

    public MainWindow(SideCursorRuntime runtime)
    {
        _runtime = runtime;
        InitializeComponent();
        // Selected here, not in XAML: selecting during XAML loading raises
        // SelectionChanged before the pages below the sidebar exist.
        Navigation.SelectedIndex = 0;
        Loaded += OnLoaded;
        _runtime.StatusChanged += OnRuntimeStatusChanged;
    }

    private void OnLoaded(object sender, RoutedEventArgs eventArgs)
    {
        _loading = true;
        try
        {
            var configuration = _runtime.GetConfiguration();
            SelectTransport(configuration.Transport);
            PeerHostText.Text = configuration.PeerHost;
            PeerPortText.Text = configuration.PeerPort.ToString(CultureInfo.InvariantCulture);
            AbsolutePointerCheck.IsChecked = configuration.AbsolutePointer;
            ReturnEdgeInsetText.Text = configuration.ReturnEdgeInsetPixels.ToString(CultureInfo.InvariantCulture);
            ClipboardEnabledCheck.IsChecked = configuration.ClipboardEnabled;
            ShowClipboardMaximum(configuration.ClipboardMaximumBytes);
            DesktopLeftText.Text = configuration.Commands.DesktopLeft;
            DesktopRightText.Text = configuration.Commands.DesktopRight;
            TaskViewText.Text = configuration.Commands.TaskView;
            ShowDesktopText.Text = configuration.Commands.ShowDesktop;
            BluetoothServiceRun.Text = BluetoothRfcommListener.ServiceUuid.ToString("D");
            PairingStateText.Text = PairingStateDescription;
            ElevationText.Text = SideCursorRuntime.IsElevated
                ? "Running as administrator, so it can also control apps that run as administrator."
                : "To control apps that run as administrator, run SideCursor as administrator too.";
            RefreshDisplays(configuration.TargetDisplayId);
            RefreshDiagnostics();
        }
        catch (Exception exception)
        {
            MessageBox.Show(exception.Message, "SideCursor settings", MessageBoxButton.OK, MessageBoxImage.Warning);
        }
        finally
        {
            _loading = false;
        }
    }

    private async void OnReconnectClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            await SaveSettingsAsync(reconnect: true);
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private async void OnReturnClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            await _runtime.RequestLocalReturnAsync();
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private void OnSourceInitialized(object? sender, EventArgs eventArgs)
    {
        Theme.ApplyTitleBar(this);
    }

    private void OnNavigationChanged(object sender, SelectionChangedEventArgs eventArgs)
    {
        if ((Navigation.SelectedItem as ListBoxItem)?.Tag is string page)
        {
            ShowPage(page);
        }
    }

    /// <summary>Shows one page: Status, Connection, Displays, Input, Clipboard or Diagnostics.</summary>
    internal void ShowPage(string page)
    {
        StatusPage.Visibility = page == "Status" ? Visibility.Visible : Visibility.Collapsed;
        ConnectionPage.Visibility = page == "Connection" ? Visibility.Visible : Visibility.Collapsed;
        DisplaysPage.Visibility = page == "Displays" ? Visibility.Visible : Visibility.Collapsed;
        InputPage.Visibility = page == "Input" ? Visibility.Visible : Visibility.Collapsed;
        ClipboardPage.Visibility = page == "Clipboard" ? Visibility.Visible : Visibility.Collapsed;
        DiagnosticsPage.Visibility = page == "Diagnostics" ? Visibility.Visible : Visibility.Collapsed;
        foreach (var item in Navigation.Items.OfType<ListBoxItem>())
        {
            if (item.Tag as string == page && !item.IsSelected)
            {
                item.IsSelected = true;
            }
        }

        PageScroller.ScrollToTop();
        if (page == "Diagnostics")
        {
            RefreshDiagnostics();
        }
    }

    private async void OnSaveSettingsClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            await SaveSettingsAsync(reconnect: false);
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private async void OnSaveAndReconnectClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            await SaveSettingsAsync(reconnect: true);
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private void OnRefreshDisplaysClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            var selectedId = (TargetDisplayCombo.SelectedItem as DisplayDescriptor)?.StableId ?? _runtime.GetConfiguration().TargetDisplayId;
            RefreshDisplays(selectedId);
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private void OnRefreshDiagnosticsClick(object sender, RoutedEventArgs eventArgs)
    {
        RefreshDiagnostics();
    }

    private void OnCopyDiagnosticsClick(object sender, RoutedEventArgs eventArgs)
    {
        Clipboard.SetText(DiagnosticsText.Text);
    }

    private void OnTransportChanged(object sender, SelectionChangedEventArgs eventArgs)
    {
        if (_loading)
        {
            return;
        }

        var isTcp = ReadTransportSelection() == TransportKind.TailscaleTcp;
        TcpSettingsPanel.Visibility = isTcp ? Visibility.Visible : Visibility.Collapsed;
        BluetoothSettingsPanel.Visibility = isTcp ? Visibility.Collapsed : Visibility.Visible;
    }

    private void OnReleaseInputClick(object sender, RoutedEventArgs eventArgs)
    {
        try
        {
            _runtime.ReleaseInputNow();
        }
        catch (Exception exception)
        {
            ShowError(exception);
        }
    }

    private void OnRuntimeStatusChanged(object? sender, RuntimeSnapshot snapshot)
    {
        Dispatcher.BeginInvoke(() =>
        {
            var (title, glyph, color) = Describe(snapshot.State);
            StatusTitleText.Text = title;
            StatusGlyph.Text = glyph;
            StatusBadge.Fill = new SolidColorBrush(color);
            NavStatusText.Text = title;
            SessionStateText.Text = snapshot.Detail;
            ReturnButton.IsEnabled = snapshot.State is SessionState.Remote or SessionState.Entering or SessionState.Returning;
            TransportStateText.Text = snapshot.Transport == TransportKind.TailscaleTcp
                ? "Tailscale"
                : snapshot.IsBluetoothListening
                    ? "Bluetooth (waiting for the Mac)"
                    : "Bluetooth";
            LatencyText.Text = snapshot.RoundTripMilliseconds is { } milliseconds
                ? $"{milliseconds:F0} ms"
                : "—";
            TargetDisplayStateText.Text = snapshot.TargetDisplayLabel ?? "—";
            RefreshDiagnostics();
        });
    }

    private async Task SaveSettingsAsync(bool reconnect)
    {
        var configuration = CaptureConfiguration();
        var pairingCode = string.IsNullOrWhiteSpace(PairingCodeBox.Password) ? null : PairingCodeBox.Password;
        _runtime.SaveConfiguration(configuration, pairingCode);
        PairingCodeBox.Clear();
        PairingStateText.Text = PairingStateDescription;
        if (reconnect)
        {
            await _runtime.ReconnectAsync();
        }

        RefreshDiagnostics();
    }

    private SideCursorConfig CaptureConfiguration()
    {
        if (!int.TryParse(PeerPortText.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var port) || port is < 1 or > 65535)
        {
            throw new InvalidOperationException("Mac listener port must be between 1 and 65535.");
        }

        if (!int.TryParse(ReturnEdgeInsetText.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var returnInset) || returnInset is < 0 or > 32)
        {
            throw new InvalidOperationException("Return-edge inset must be between 0 and 32 physical pixels.");
        }

        var clipboardMaximum = (ClipboardMaximumCombo.SelectedItem as ComboBoxItem)?.Tag is int bytes
            ? bytes
            : SideCursorConfig.MaximumClipboardBytes;

        var selectedDisplay = TargetDisplayCombo.SelectedItem as DisplayDescriptor;
        if (selectedDisplay is null)
        {
            throw new InvalidOperationException("Select a Windows target display before saving settings.");
        }

        var configuration = _runtime.GetConfiguration();
        configuration.Transport = ReadTransportSelection();
        configuration.PeerHost = PeerHostText.Text.Trim();
        configuration.PeerPort = port;
        configuration.TargetDisplayId = selectedDisplay.StableId;
        configuration.AbsolutePointer = AbsolutePointerCheck.IsChecked == true;
        configuration.ReturnEdgeInsetPixels = returnInset;
        configuration.ClipboardEnabled = ClipboardEnabledCheck.IsChecked == true;
        configuration.ClipboardMaximumBytes = clipboardMaximum;
        configuration.Commands = new CommandBindings
        {
            DesktopLeft = DesktopLeftText.Text.Trim(),
            DesktopRight = DesktopRightText.Text.Trim(),
            TaskView = TaskViewText.Text.Trim(),
            ShowDesktop = ShowDesktopText.Text.Trim(),
        };
        configuration.Normalize();
        return configuration;
    }

    private TransportKind ReadTransportSelection()
    {
        return (TransportCombo.SelectedItem as ComboBoxItem)?.Tag as string == "BluetoothRfcomm"
            ? TransportKind.BluetoothRfcomm
            : TransportKind.TailscaleTcp;
    }

    private void SelectTransport(TransportKind transport)
    {
        foreach (var item in TransportCombo.Items.OfType<ComboBoxItem>())
        {
            if (string.Equals(item.Tag as string, transport.ToString(), StringComparison.Ordinal))
            {
                TransportCombo.SelectedItem = item;
                break;
            }
        }

        var isTcp = transport == TransportKind.TailscaleTcp;
        TcpSettingsPanel.Visibility = isTcp ? Visibility.Visible : Visibility.Collapsed;
        BluetoothSettingsPanel.Visibility = isTcp ? Visibility.Collapsed : Visibility.Visible;
    }

    /// <summary>Fills the size picker, keeping a saved value that is not a preset.</summary>
    private void ShowClipboardMaximum(int current)
    {
        int[] presets = [64 * 1024, 256 * 1024, 1024 * 1024, 5 * 1024 * 1024, SideCursorConfig.MaximumClipboardBytes];
        var sizes = presets.Contains(current) ? presets : presets.Append(current).Order().ToArray();
        ClipboardMaximumCombo.Items.Clear();
        foreach (var size in sizes)
        {
            var item = new ComboBoxItem
            {
                Tag = size,
                Content = size >= 1024 * 1024
                    ? string.Format(CultureInfo.CurrentCulture, "{0:0.#} MB", size / (1024.0 * 1024.0))
                    : string.Format(CultureInfo.CurrentCulture, "{0:0} KB", size / 1024.0),
            };
            ClipboardMaximumCombo.Items.Add(item);
            if (size == current)
            {
                ClipboardMaximumCombo.SelectedItem = item;
            }
        }
    }

    private string PairingStateDescription => _runtime.HasPairingSecret
        ? "Saved and protected by Windows. Paste a new code only to replace it."
        : "No pairing code saved yet. Paste the code from the Mac.";

    /// <summary>Plain-English title, Segoe icon glyph and colour for a session state.</summary>
    internal static (string Title, string Glyph, Color Color) Describe(SessionState state) => state switch
    {
        SessionState.Disconnected => ("Not connected", "\uE711", Color.FromRgb(0xC4, 0x2B, 0x1C)),
        SessionState.Connecting => ("Waiting for the Mac", "\uE895", Color.FromRgb(0x9D, 0x5D, 0x00)),
        SessionState.Ready => ("Ready", "\uE73E", Color.FromRgb(0x0F, 0x7B, 0x0F)),
        SessionState.Entering => ("Switching to Windows…", "\uE8AB", Color.FromRgb(0x9D, 0x5D, 0x00)),
        SessionState.Remote => ("The Mac is controlling this PC", "\uE7F4", Color.FromRgb(0x00, 0x5F, 0xB8)),
        SessionState.Returning => ("Returning to the Mac…", "\uE8AB", Color.FromRgb(0x9D, 0x5D, 0x00)),
        _ => ("Recovering…", "\uE72C", Color.FromRgb(0x9D, 0x5D, 0x00)),
    };

    private void RefreshDisplays(string selectedStableId)
    {
        _displays = SideCursorRuntime.GetDisplays();
        DisplayList.ItemsSource = _displays.Select(static display => new DisplayRow(
            display.FriendlyName,
            display.WidthMm >= 20
                ? string.Format(
                    CultureInfo.CurrentCulture,
                    "{0} × {1}  ·  {2:0} × {3:0} mm ({4:0.0}″)",
                    display.Bounds.Width,
                    display.Bounds.Height,
                    display.WidthMm,
                    display.HeightMm,
                    Math.Sqrt(display.WidthMm * display.WidthMm + display.HeightMm * display.HeightMm) / 25.4)
                : $"{display.Bounds.Width} × {display.Bounds.Height}  ·  size not reported",
            display.IsPrimary ? Visibility.Visible : Visibility.Collapsed)).ToArray();
        TargetDisplayCombo.ItemsSource = _displays;
        TargetDisplayCombo.SelectedItem = _displays.FirstOrDefault(display => string.Equals(display.StableId, selectedStableId, StringComparison.OrdinalIgnoreCase))
            ?? (_displays.Count > 0 ? _displays[0] : null);
    }

    private void RefreshDiagnostics()
    {
        var lines = new List<string>
        {
            $"Protocol: native v2",
            $"Pairing secret: {(_runtime.HasPairingSecret ? "stored with DPAPI" : "not configured")}",
            $"Displays: {_displays.Count}",
        };
        lines.AddRange(_runtime.Diagnostics);
        DiagnosticsText.Text = string.Join(Environment.NewLine, lines);
    }

    private void OnClosing(object? sender, CancelEventArgs eventArgs)
    {
        eventArgs.Cancel = true;
        ((App)Application.Current).HideMainWindow();
    }

    private static void ShowError(Exception exception)
    {
        MessageBox.Show(exception.Message, "SideCursor", MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
