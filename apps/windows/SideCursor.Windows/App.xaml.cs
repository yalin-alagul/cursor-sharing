using System.Windows;
using System.Windows.Threading;
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

    internal SideCursorRuntime Runtime { get; private set; } = null!;

    protected override void OnStartup(StartupEventArgs e)
    {
        // The manifest declares PerMonitorV2. This makes the process context
        // explicit for unpackaged launches before any WPF window is created.
        _ = NativeMethods.SetProcessDpiAwarenessContext(new IntPtr(-4));
        base.OnStartup(e);

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
        _trayIcon?.Dispose();
        _trayIcon = null;
        if (Runtime is not null)
        {
            Runtime.StatusChanged -= OnRuntimeStatusChanged;
            Runtime.DisposeAsync().AsTask().GetAwaiter().GetResult();
        }

        _clipboard?.Dispose();
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
        menu.Items.Add("Reconnect", null, async (_, _) => await Runtime.ReconnectAsync().ConfigureAwait(false));
        menu.Items.Add("Return control to Mac", null, async (_, _) => await Runtime.RequestLocalReturnAsync().ConfigureAwait(false));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Exit", null, (_, _) => Dispatcher.Invoke(ExitApplication));

        _trayIcon = new Forms.NotifyIcon
        {
            Icon = System.Drawing.SystemIcons.Application,
            Text = "SideCursor: starting",
            Visible = true,
            ContextMenuStrip = menu,
        };
        _trayIcon.DoubleClick += (_, _) => Dispatcher.Invoke(ShowMainWindow);
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
