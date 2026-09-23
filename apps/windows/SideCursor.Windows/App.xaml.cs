using System.Windows;
using System.Windows.Threading;
using Microsoft.Win32;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Services;
using Forms = System.Windows.Forms;

namespace SideCursor.Windows;

[System.Diagnostics.CodeAnalysis.SuppressMessage(
    "Design",
    "CA1001:Types that own disposable fields should be disposable",
    Justification = "The WPF Application lifetime owns these fields and deterministically disposes them in OnExit.")]
public partial class App : System.Windows.Application
{
    private Forms.NotifyIcon? _trayIcon;
    private ClipboardSync? _clipboard;
    private Mutex? _instanceMutex;

    internal SideCursorRuntime Runtime { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        // Only one SideCursor may run per user session. A second instance would
        // open a second connection to the Mac, and the Mac would flap between
        // the two peers on every reconnect — surfacing as a visible "reconnect"
        // and dropped remote control. Reject any duplicate instance up front.
        _instanceMutex = new Mutex(initiallyOwned: true, "SideCursor.Windows.SingleInstance", out var createdNew);
        if (!createdNew)
        {
            _instanceMutex.Dispose();
            _instanceMutex = null;
            System.Windows.MessageBox.Show(
                "SideCursor is already running. Look for its tray icon near the clock.",
                "SideCursor",
                MessageBoxButton.OK,
                MessageBoxImage.Information);
            Shutdown();
            return;
        }

        // The manifest declares PerMonitorV2. This makes the process context
        // explicit for unpackaged launches before any WPF window is created.
        _ = NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4));
        base.OnStartup(e);
        Theme.Apply(Resources, Theme.SystemPrefersDark());
        SystemEvents.UserPreferenceChanged += OnUserPreferenceChanged;

        try
        {
            var paths = new AppDataPaths();
            var configurationStore = new ConfigurationStore(paths);
            var pairingSecretStore = new PairingSecretStore(paths);
            SideCursorRuntime? runtime = null;
            _clipboard = new ClipboardSync(Dispatcher, () => runtime?.GetConfiguration().ClipboardMaximumBytes ?? 1024 * 1024);
            _clipboard.Start();
            runtime = new SideCursorRuntime(configurationStore, pairingSecretStore, _clipboard);
            Runtime = runtime;
            Runtime.StatusChanged += OnRuntimeStatusChanged;

            var window = new MainWindow(Runtime);
            MainWindow = window;
            CreateTrayIcon(window);
            window.Show();
            _ = Runtime.StartAsync();
        }
        catch (Exception exception)
        {
            System.Windows.MessageBox.Show(
                $"SideCursor could not start: {exception.Message}",
                "SideCursor",
                MessageBoxButton.OK,
                MessageBoxImage.Error);
            Shutdown(-1);
        }
    }

    protected override void OnExit(ExitEventArgs e)
    {
        SystemEvents.UserPreferenceChanged -= OnUserPreferenceChanged;
        _trayIcon?.Dispose();
        _trayIcon = null;
        if (Runtime is not null)
        {
            Runtime.StatusChanged -= OnRuntimeStatusChanged;
            Runtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        _clipboard?.Dispose();

        if (_instanceMutex is not null)
        {
            try
            {
                _instanceMutex.ReleaseMutex();
            }
            catch (ApplicationException)
            {
                // Already released or not owned by this thread.
            }

            _instanceMutex.Dispose();
            _instanceMutex = null;
        }

        base.OnExit(e);
    }

    internal void HideMainWindow()
    {
        MainWindow?.Hide();
    }

    internal void ShowMainWindow()
    {
        if (MainWindow is null)
        {
            return;
        }

        MainWindow.Show();
        MainWindow.WindowState = WindowState.Normal;
        MainWindow.Activate();
    }

    internal void ExitApplication()
    {
        Shutdown();
    }

    private void CreateTrayIcon(Window window)
    {
        var menu = new Forms.ContextMenuStrip();
        menu.Items.Add("Open SideCursor", null, (_, _) => Dispatcher.Invoke(ShowMainWindow));
        menu.Items.Add("Reconnect", null, (_, _) => RunTrayActionAsync(Runtime.ReconnectAsync));
        menu.Items.Add("Return control to Mac", null, (_, _) => RunTrayActionAsync(Runtime.RequestLocalReturnAsync));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Dispatcher.Invoke(ExitApplication));

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = LoadTrayIcon() ?? System.Drawing.SystemIcons.Application,
            Text = "SideCursor: starting",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
    }

    /// <summary>The app icon at the tray's small-icon size for this DPI.</summary>
    private static System.Drawing.Icon? LoadTrayIcon()
    {
        try
        {
            var resource = GetResourceStream(new Uri("pack://application:,,,/SideCursor.Windows;component/Assets/SideCursor.ico"));
            if (resource is null)
            {
                return null;
            }

            using var stream = resource.Stream;
            return new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize);
        }
        catch (Exception exception) when (exception is IOException or ArgumentException)
        {
            return null;
        }
    }

    /// <summary>Follows the Windows light/dark app theme while running.</summary>
    private void OnUserPreferenceChanged(object sender, UserPreferenceChangedEventArgs eventArgs)
    {
        if (eventArgs.Category != UserPreferenceCategory.General)
        {
            return;
        }

        Dispatcher.BeginInvoke(() =>
        {
            var dark = Theme.SystemPrefersDark();
            if (dark == Theme.IsDark)
            {
                return;
            }

            Theme.Apply(Resources, dark);
            if (MainWindow is not null)
            {
                Theme.ApplyTitleBar(MainWindow);
            }
        });
    }

    /// <summary>
    /// Runs a tray action from the WinForms threadpool callback. Without the
    /// try/catch an exception from an <c>async void</c> handler crashes the
    /// process; instead it is surfaced to the user.
    /// </summary>
    private async void RunTrayActionAsync(Func<Task> action)
    {
        try
        {
            await action().ConfigureAwait(false);
        }
        catch (Exception exception)
        {
            _ = Dispatcher.BeginInvoke(() => System.Windows.MessageBox.Show(
                $"SideCursor could not complete the action: {exception.Message}",
                "SideCursor",
                MessageBoxButton.OK,
                MessageBoxImage.Warning));
        }
    }

    private void OnRuntimeStatusChanged(object? sender, Core.RuntimeSnapshot snapshot)
    {
        Dispatcher.BeginInvoke(() =>
        {
            if (_trayIcon is not null)
            {
                var text = $"SideCursor: {snapshot.State} — {snapshot.Detail}";
                _trayIcon.Text = text.Length > 63 ? text[..63] : text;
            }
        }, DispatcherPriority.Background);
    }
}
