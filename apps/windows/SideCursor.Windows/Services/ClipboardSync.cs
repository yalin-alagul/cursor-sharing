using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Windows;
using System.Windows.Interop;
using System.Windows.Threading;

namespace SideCursor.Windows.Services;

public sealed class ClipboardSync : IDisposable
{
    private const int WmClipboardUpdate = 0x031D;
    private static readonly IntPtr HwndMessage = new(-3);
    private readonly Dispatcher _dispatcher;
    private readonly Func<int> _maximumBytes;
    private HwndSource? _source;
    private string? _lastPublishedHash;
    private string? _suppressedRemoteHash;
    private DateTimeOffset _suppressUntil;
    private bool _disposed;

    public ClipboardSync(Dispatcher dispatcher, Func<int> maximumBytes)
    {
        _dispatcher = dispatcher;
        _maximumBytes = maximumBytes;
    }

    public event EventHandler<string>? LocalTextChanged;
    public event EventHandler<string>? ClipboardError;

    public void Start()
    {
        VerifyDispatcher();
        ObjectDisposedException.ThrowIf(_disposed, this);
        if (_source is not null)
        {
            return;
        }

        var parameters = new HwndSourceParameters("SideCursorClipboardListener")
        {
            ParentWindow = HwndMessage,
            Width = 0,
            Height = 0,
            WindowStyle = 0,
        };
        _source = new HwndSource(parameters);
        _source.AddHook(WindowProcedure);
        if (!AddClipboardFormatListener(_source.Handle))
        {
            var error = Marshal.GetLastWin32Error();
            _source.RemoveHook(WindowProcedure);
            _source.Dispose();
            _source = null;
            throw new InvalidOperationException($"Unable to listen for Windows clipboard changes (Win32 error {error}).");
        }

        PublishLocalClipboardIfChanged();
    }

    public void ApplyRemoteText(string text)
    {
        ArgumentNullException.ThrowIfNull(text);
        if (!_dispatcher.CheckAccess())
        {
            // Never block the transport/receive thread on the UI dispatcher.
            // The UI thread can be waiting on that same connection during
            // shutdown, which would deadlock the app on exit.
            _dispatcher.BeginInvoke(() => ApplyRemoteText(text));
            return;
        }

        VerifyDispatcher();
        if (text.Length == 0 || !CanSync(text))
        {
            // Empty text means the remote clipboard was cleared; there is
            // nothing to paste, so leave the local clipboard untouched.
            return;
        }

        try
        {
            var hash = Hash(text);
            _suppressedRemoteHash = hash;
            _suppressUntil = DateTimeOffset.UtcNow.AddSeconds(2);
            Clipboard.SetText(text, TextDataFormat.UnicodeText);
            _lastPublishedHash = hash;
        }
        catch (COMException exception)
        {
            ClipboardError?.Invoke(this, $"Windows clipboard is busy: {exception.Message}");
        }
        catch (ExternalException exception)
        {
            ClipboardError?.Invoke(this, $"Windows clipboard could not be updated: {exception.Message}");
        }
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        if (!_dispatcher.CheckAccess())
        {
            _dispatcher.Invoke(Dispose);
            return;
        }

        _disposed = true;
        if (_source is null)
        {
            return;
        }

        _ = RemoveClipboardFormatListener(_source.Handle);
        _source.RemoveHook(WindowProcedure);
        _source.Dispose();
        _source = null;
    }

    private IntPtr WindowProcedure(IntPtr hwnd, int message, IntPtr wParam, IntPtr lParam, ref bool handled)
    {
        if (message == WmClipboardUpdate)
        {
            _dispatcher.BeginInvoke(PublishLocalClipboardIfChanged, DispatcherPriority.Background);
        }

        return IntPtr.Zero;
    }

    private void PublishLocalClipboardIfChanged()
    {
        VerifyDispatcher();
        if (_disposed || !TryGetText(out var text) || !CanSync(text))
        {
            return;
        }

        var hash = Hash(text);
        if (string.Equals(hash, _suppressedRemoteHash, StringComparison.Ordinal) && DateTimeOffset.UtcNow <= _suppressUntil)
        {
            _lastPublishedHash = hash;
            return;
        }

        if (string.Equals(hash, _lastPublishedHash, StringComparison.Ordinal))
        {
            return;
        }

        _lastPublishedHash = hash;
        LocalTextChanged?.Invoke(this, text);
    }

    private bool TryGetText(out string text)
    {
        text = string.Empty;
        try
        {
            if (!Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                return false;
            }

            text = Clipboard.GetText(TextDataFormat.UnicodeText);
            return true;
        }
        catch (COMException exception)
        {
            ClipboardError?.Invoke(this, $"Windows clipboard is busy: {exception.Message}");
            return false;
        }
        catch (ExternalException exception)
        {
            ClipboardError?.Invoke(this, $"Windows clipboard could not be read: {exception.Message}");
            return false;
        }
    }

    private bool CanSync(string text)
    {
        return Encoding.UTF8.GetByteCount(text) <= Math.Clamp(_maximumBytes(), 1, 1024 * 1024);
    }

    private static string Hash(string text)
    {
        return Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(text)));
    }

    private void VerifyDispatcher()
    {
        if (!_dispatcher.CheckAccess())
        {
            throw new InvalidOperationException("Clipboard synchronization must run on the WPF dispatcher thread.");
        }
    }

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AddClipboardFormatListener(IntPtr hwnd);

    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool RemoveClipboardFormatListener(IntPtr hwnd);
}
