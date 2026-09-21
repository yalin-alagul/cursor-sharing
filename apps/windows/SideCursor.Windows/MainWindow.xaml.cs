using System.ComponentModel;
using System.Globalization;
using System.Windows;
using System.Windows.Controls;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Services;

namespace SideCursor.Windows;

public partial class MainWindow : Window
{
    private readonly SideCursorRuntime _runtime;
    private IReadOnlyList<DisplayDescriptor> _displays = [];
    private bool _loading;

    public MainWindow(SideCursorRuntime runtime)
    {
        _runtime = runtime;
        InitializeComponent();
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
            ClipboardMaximumText.Text = configuration.ClipboardMaximumBytes.ToString(CultureInfo.InvariantCulture);
            DesktopLeftText.Text = configuration.Commands.DesktopLeft;
            DesktopRightText.Text = configuration.Commands.DesktopRight;
            TaskViewText.Text = configuration.Commands.TaskView;
            ShowDesktopText.Text = configuration.Commands.ShowDesktop;
            BluetoothServiceText.Text = BluetoothRfcommListener.ServiceUuid.ToString("D");
            PairingStateText.Text = _runtime.HasPairingSecret
                ? "A pairing secret is protected with Windows DPAPI."
                : "No pairing secret saved yet.";
            ElevationText.Text = SideCursorRuntime.IsElevated
                ? "Running elevated. It can inject into elevated apps on this desktop."
                : "Running as a standard user. Elevated Windows apps cannot receive injected input unless SideCursor is elevated too.";
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

    private void OnDiagnosticsClick(object sender, RoutedEventArgs eventArgs)
    {
        var tabControl = FindChild<TabControl>(this);
        if (tabControl is not null)
        {
            tabControl.SelectedIndex = 4;
        }

        RefreshDiagnostics();
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
            SessionStateText.Text = $"{snapshot.State}: {snapshot.Detail}";
            TransportStateText.Text = snapshot.Transport == TransportKind.TailscaleTcp
                ? "Tailscale TCP"
                : snapshot.IsBluetoothListening
                    ? "Bluetooth RFCOMM listener ready"
                    : "Bluetooth RFCOMM";
            LatencyText.Text = snapshot.RoundTripMilliseconds is { } milliseconds
                ? $"{milliseconds:F0} ms"
                : "Waiting for peer";
            TargetDisplayStateText.Text = snapshot.TargetDisplayLabel ?? "Select an available target display";
            RefreshDiagnostics();
        });
    }

    private async Task SaveSettingsAsync(bool reconnect)
    {
        var configuration = CaptureConfiguration();
        var pairingCode = string.IsNullOrWhiteSpace(PairingCodeBox.Password) ? null : PairingCodeBox.Password;
        _runtime.SaveConfiguration(configuration, pairingCode);
        PairingCodeBox.Clear();
        PairingStateText.Text = _runtime.HasPairingSecret
            ? "A pairing secret is protected with Windows DPAPI."
            : "No pairing secret saved yet.";
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

        if (!int.TryParse(ClipboardMaximumText.Text, NumberStyles.None, CultureInfo.InvariantCulture, out var clipboardMaximum) || clipboardMaximum is < 1 or > SideCursorConfig.MaximumClipboardBytes)
        {
            throw new InvalidOperationException("Clipboard limit must be between 1 and 1,048,576 bytes.");
        }

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

    private void RefreshDisplays(string selectedStableId)
    {
        _displays = SideCursorRuntime.GetDisplays();
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

    private static T? FindChild<T>(DependencyObject parent)
        where T : DependencyObject
    {
        var count = System.Windows.Media.VisualTreeHelper.GetChildrenCount(parent);
        for (var index = 0; index < count; index++)
        {
            var child = System.Windows.Media.VisualTreeHelper.GetChild(parent, index);
            if (child is T matched)
            {
                return matched;
            }

            var nested = FindChild<T>(child);
            if (nested is not null)
            {
                return nested;
            }
        }

        return null;
    }

    private static void ShowError(Exception exception)
    {
        MessageBox.Show(exception.Message, "SideCursor", MessageBoxButton.OK, MessageBoxImage.Error);
    }
}
