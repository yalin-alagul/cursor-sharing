using System;
using System.IO;
using System.Threading;
using System.Windows;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Services;

namespace SideCursor.Windows.Tests;

/// <summary>
/// Renders every page of the main window to PNGs for visual review. Does
/// nothing unless SIDECURSOR_SNAPSHOT_DIR is set; SIDECURSOR_SNAPSHOT_THEME
/// picks "light" (default) or "dark", one theme per test run:
///
///     $env:SIDECURSOR_SNAPSHOT_DIR = "C:\temp\shots"; dotnet test --filter WindowSnapshotTests
/// </summary>
public sealed class WindowSnapshotTests
{
    private static readonly string[] Pages = ["Status", "Connection", "Displays", "Input", "Clipboard", "Diagnostics"];

    [Fact]
    public void RenderMainWindowPages()
    {
        var directory = Environment.GetEnvironmentVariable("SIDECURSOR_SNAPSHOT_DIR");
        if (string.IsNullOrWhiteSpace(directory))
        {
            return;
        }

        Exception? failure = null;
        var thread = new Thread(() =>
        {
            try
            {
                Render(directory);
            }
            catch (Exception exception)
            {
                failure = exception;
            }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        thread.Join();
        if (failure is not null)
        {
            throw new InvalidOperationException("Snapshot rendering failed.", failure);
        }
    }

    private static void Render(string directory)
    {
        Directory.CreateDirectory(directory);
        // A plain Application with SideCursor's styles. Creating the real App
        // would queue its startup, which launches a second live SideCursor.
        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
        app.Resources.MergedDictionaries.Add(new ResourceDictionary
        {
            Source = new Uri("pack://application:,,,/SideCursor.Windows;component/Styles.xaml"),
        });
        var paths = new AppDataPaths(Path.Combine(Path.GetTempPath(), "sidecursor-snapshot-" + Guid.NewGuid().ToString("N")));
        var clipboard = new ClipboardSync(Dispatcher.CurrentDispatcher, () => 1024);
        var runtime = new SideCursorRuntime(new ConfigurationStore(paths), new PairingSecretStore(paths), clipboard);

        var dark = string.Equals(Environment.GetEnvironmentVariable("SIDECURSOR_SNAPSHOT_THEME"), "dark", StringComparison.OrdinalIgnoreCase);
        {
            Theme.Apply(app.Resources, dark);
            var window = new MainWindow(runtime)
            {
                Left = -12_000,
                Top = -12_000,
                Width = 980,
                Height = 700,
                ShowActivated = false,
                ShowInTaskbar = false,
            };
            window.Show();
            foreach (var page in Pages)
            {
                window.ShowPage(page);
                Settle();
                var content = (FrameworkElement)window.Content;
                var bitmap = new RenderTargetBitmap((int)content.ActualWidth, (int)content.ActualHeight, 96, 96, PixelFormats.Pbgra32);
                var background = new DrawingVisual();
                using (var context = background.RenderOpen())
                {
                    context.DrawRectangle(window.Background, null, new Rect(0, 0, content.ActualWidth, content.ActualHeight));
                }

                bitmap.Render(background);
                bitmap.Render(content);
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(bitmap));
                using var file = File.Create(Path.Combine(directory, $"{page.ToLowerInvariant()}-{(dark ? "dark" : "light")}.png"));
                encoder.Save(file);
            }

            window.Hide();
        }
    }

    private static void Settle()
    {
        for (var pass = 0; pass < 3; pass++)
        {
            Dispatcher.CurrentDispatcher.Invoke(() => { }, DispatcherPriority.ApplicationIdle);
        }
    }
}
