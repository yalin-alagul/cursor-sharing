using System.ComponentModel;
using System.IO;
using System.Net.Sockets;
using System.Security.Cryptography;
using System.Security.Principal;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Protocol;

namespace SideCursor.Windows.Services;

public sealed class SideCursorRuntime : IAsyncDisposable
{
    private readonly object _gate = new();
    private readonly ConfigurationStore _configurationStore;
    private readonly PairingSecretStore _pairingSecretStore;
    private readonly WindowsInputInjector _input;
    private readonly ClipboardSync _clipboard;
    private readonly SessionStateMachine _state = new();
    private readonly DiagnosticLog _diagnostics = new();
    private SideCursorConfig _configuration;
    private CancellationTokenSource? _runCancellation;
    private Task? _runTask;
    private WindowsSession? _activeSession;
    private double? _roundTripMilliseconds;
    private bool _bluetoothListening;
    private int _disposed;

    public SideCursorRuntime(
        ConfigurationStore configurationStore,
        PairingSecretStore pairingSecretStore,
        ClipboardSync clipboard)
    {
        _configurationStore = configurationStore;
        _pairingSecretStore = pairingSecretStore;
        _input = new WindowsInputInjector();
        _clipboard = clipboard;
        _configuration = configurationStore.Load();
        _configuration.Normalize();
        // Pass the event's own state: a forced disconnect raises Changed more
        // than once, and re-reading the live snapshot would skip Recovering.
        _state.Changed += (_, snapshot) => PublishSnapshot(snapshot.Detail, snapshot.State);
        _clipboard.ClipboardError += (_, message) => _diagnostics.Add(message);
    }

    public event EventHandler<RuntimeSnapshot>? StatusChanged;

    public IReadOnlyList<string> Diagnostics => _diagnostics.Snapshot();

    public bool HasPairingSecret => _pairingSecretStore.HasSecret;

    public static bool IsElevated
    {
        get
        {
            using var identity = WindowsIdentity.GetCurrent();
            return new WindowsPrincipal(identity).IsInRole(WindowsBuiltInRole.Administrator);
        }
    }

    public SideCursorConfig GetConfiguration()
    {
        lock (_gate)
        {
            return CloneConfiguration(_configuration);
        }
    }

    public static IReadOnlyList<DisplayDescriptor> GetDisplays() => DisplayCatalog.GetDisplays();

    public void SaveConfiguration(SideCursorConfig configuration, string? pairingCode)
    {
        ThrowIfDisposed();
        ArgumentNullException.ThrowIfNull(configuration);
        configuration.Normalize();
        byte[]? secret = null;
        try
        {
            if (!string.IsNullOrWhiteSpace(pairingCode))
            {
                secret = PairingSecretParser.Parse(pairingCode);
                _pairingSecretStore.Save(secret);
                _diagnostics.Add("Pairing secret stored with Windows DPAPI.");
            }

            _configurationStore.Save(configuration);
            lock (_gate)
            {
                _configuration = CloneConfiguration(configuration);
            }

            _diagnostics.Add("Settings saved.");
            PublishSnapshot("Settings saved; reconnect to apply changes to a live session.");
        }
        finally
        {
            if (secret is not null)
            {
                System.Security.Cryptography.CryptographicOperations.ZeroMemory(secret);
            }
        }
    }

    public async Task ReconnectAsync()
    {
        ThrowIfDisposed();
        await StopAsync("Reconnect requested").ConfigureAwait(false);
        await StartAsync().ConfigureAwait(false);
    }

    public Task StartAsync()
    {
        ThrowIfDisposed();
        lock (_gate)
        {
            if (_runTask is not null)
            {
                return Task.CompletedTask;
            }

            var configuration = CloneConfiguration(_configuration);
            if (!_pairingSecretStore.HasSecret)
            {
                _diagnostics.Add("Connection is blocked until a pairing code is saved.");
                PublishSnapshot("Pairing code required");
                return Task.CompletedTask;
            }

            if (configuration.Transport == TransportKind.TailscaleTcp && string.IsNullOrWhiteSpace(configuration.PeerHost))
            {
                _diagnostics.Add("Connection is blocked until a Tailscale peer address is configured.");
                PublishSnapshot("Tailscale peer address required");
                return Task.CompletedTask;
            }

            _runCancellation = new CancellationTokenSource();
            _runTask = Task.Run(() => RunConnectionLoopAsync(_runCancellation.Token));
            return Task.CompletedTask;
        }
    }

    /// <summary>
    /// Releases every key and mouse button SideCursor injected, without asking
    /// the Mac to return control. Backs the "Release all injected input now"
    /// button, which previously shared the Return-control handler.
    /// </summary>
    public void ReleaseInputNow()
    {
        ThrowIfDisposed();
        ReleaseInputSafely("manual release requested");
        PublishSnapshot("Released all injected Windows input.");
    }

    public async Task RequestLocalReturnAsync()
    {
        WindowsSession? session;
        lock (_gate)
        {
            session = _activeSession;
        }

        if (session is not null)
        {
            await session.RequestLocalReturnAsync().ConfigureAwait(false);
        }
        else
        {
            ReleaseInputSafely("local return without an active session");
        }
    }

    public async Task StopAsync(string reason = "SideCursor stopped")
    {
        CancellationTokenSource? cancellation;
        Task? runTask;
        WindowsSession? session;
        lock (_gate)
        {
            cancellation = _runCancellation;
            runTask = _runTask;
            session = _activeSession;
            _runCancellation = null;
            _runTask = null;
            _activeSession = null;
        }

        if (session is not null)
        {
            await session.ShutdownAsync(reason).ConfigureAwait(false);
        }

        cancellation?.Cancel();
        if (runTask is not null)
        {
            try
            {
                await runTask.ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                // Normal shutdown path.
            }
        }

        cancellation?.Dispose();
        ReleaseInputSafely(reason);
        _state.ForceDisconnected(reason);
        PublishSnapshot(reason);
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        await StopAsync("SideCursor exited").ConfigureAwait(false);
    }

    private async Task RunConnectionLoopAsync(CancellationToken cancellationToken)
    {
        var retryDelay = TimeSpan.FromSeconds(1);
        while (!cancellationToken.IsCancellationRequested)
        {
            V2SecureChannel? channel = null;
            TransportConnection? connection = null;
            WindowsSession? session = null;
            try
            {
                _ = _state.BeginConnecting();
                PublishSnapshot("Connecting to paired peer");
                var configuration = GetConfiguration();
                var secret = _pairingSecretStore.Read();
                try
                {
                    connection = await OpenTransportAsync(configuration, cancellationToken).ConfigureAwait(false);
                    channel = connection.WindowsActsAsClient
                        ? await V2Handshake.ConnectAsClientAsync(connection.Stream, secret, cancellationToken).ConfigureAwait(false)
                        : await V2Handshake.AcceptAsServerAsync(connection.Stream, secret, cancellationToken).ConfigureAwait(false);
                }
                finally
                {
                    System.Security.Cryptography.CryptographicOperations.ZeroMemory(secret);
                }

                retryDelay = TimeSpan.FromSeconds(1);
                _ = _state.MarkReady("Paired peer is ready");
                session = new WindowsSession(configuration, _input, _clipboard, _state, _diagnostics, UpdateRoundTrip);
                lock (_gate)
                {
                    _activeSession = session;
                }

                _diagnostics.Add($"Secure v2 {configuration.Transport} session established.");
                await session.RunAsync(channel, cancellationToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception exception) when (exception is IOException or SocketException or AuthenticationException or ProtocolViolationException or InputInjectionException or InvalidOperationException or Win32Exception or ArgumentException or CryptographicException or InvalidDataException)
            {
                _diagnostics.Add($"Connection recovery [{exception.GetType().Name}]: {exception.Message}");
                TryRecoverFromConnectionFailure($"Connection recovery: {exception.Message}");
            }
            catch (Exception exception)
            {
                // A background retry loop must not die permanently on an
                // unexpected error (for example a corrupt pairing secret that
                // escapes the specific filter above). Log it, release input,
                // and keep retrying with the normal backoff.
                _diagnostics.Add($"Connection recovery [unexpected {exception.GetType().Name}]: {exception.Message}");
                TryRecoverFromConnectionFailure($"Unexpected connection error: {exception.Message}");
            }
            finally
            {
                lock (_gate)
                {
                    if (ReferenceEquals(_activeSession, session))
                    {
                        _activeSession = null;
                    }
                }

                ReleaseInputSafely("connection closed");
                if (channel is not null)
                {
                    await channel.DisposeAsync().ConfigureAwait(false);
                }

                if (connection is not null)
                {
                    await connection.DisposeAsync().ConfigureAwait(false);
                }

                session?.Dispose();

                SetBluetoothListening(false);
            }

            if (!cancellationToken.IsCancellationRequested)
            {
                await Task.Delay(retryDelay, cancellationToken).ConfigureAwait(false);
                retryDelay = TimeSpan.FromSeconds(Math.Min(retryDelay.TotalSeconds * 2, 10));
            }
        }
    }

    private async Task<TransportConnection> OpenTransportAsync(SideCursorConfig configuration, CancellationToken cancellationToken)
    {
        if (configuration.Transport == TransportKind.TailscaleTcp)
        {
            var client = new TcpClient();
            client.NoDelay = true;
            try
            {
                await client.ConnectAsync(configuration.PeerHost, configuration.PeerPort, cancellationToken).ConfigureAwait(false);
                return new TransportConnection(client.GetStream(), windowsActsAsClient: true, client);
            }
            catch
            {
                client.Dispose();
                throw;
            }
        }

        var bluetooth = new BluetoothRfcommListener();
        try
        {
            await bluetooth.StartAsync(cancellationToken).ConfigureAwait(false);
            SetBluetoothListening(true);
            _diagnostics.Add(
                $"Bluetooth RFCOMM listener ready for SideCursor service {BluetoothRfcommListener.ServiceUuid}.");
            var stream = await bluetooth.AcceptAsync(cancellationToken).ConfigureAwait(false);
            // RFCOMM socket direction is independent of the authenticated v2
            // handshake direction.  The Mac remains the protocol server on
            // both transports, so Windows sends Pair after receiving Hello.
            return new TransportConnection(stream, windowsActsAsClient: true, bluetooth);
        }
        catch
        {
            await bluetooth.DisposeAsync().ConfigureAwait(false);
            SetBluetoothListening(false);
            throw;
        }
    }

    private void UpdateRoundTrip(double milliseconds)
    {
        lock (_gate)
        {
            _roundTripMilliseconds = milliseconds;
        }

        PublishSnapshot(_state.Snapshot.Detail);
    }

    private void SetBluetoothListening(bool value)
    {
        lock (_gate)
        {
            _bluetoothListening = value;
        }

        PublishSnapshot(_state.Snapshot.Detail);
    }

    private void PublishSnapshot(string detail, SessionState? state = null)
    {
        SideCursorConfig configuration;
        double? roundTrip;
        bool bluetoothListening;
        lock (_gate)
        {
            configuration = CloneConfiguration(_configuration);
            roundTrip = _roundTripMilliseconds;
            bluetoothListening = _bluetoothListening;
        }

        string? displayLabel = null;
        try
        {
            displayLabel = DisplayCatalog.ResolveTarget(configuration).Label;
        }
        catch (Exception exception) when (exception is InvalidOperationException or Win32Exception)
        {
            // The settings UI displays the configuration error separately.
            // A native monitor-enumeration failure must not escape a status
            // update, which also runs on every round-trip report.
        }

        StatusChanged?.Invoke(this, new RuntimeSnapshot(
            state ?? _state.Snapshot.State,
            detail,
            configuration.Transport,
            roundTrip,
            bluetoothListening,
            displayLabel));
    }

    private void TryRecoverFromConnectionFailure(string reason)
    {
        try
        {
            _state.BeginRecovery(reason);
        }
        catch (Exception exception)
        {
            _diagnostics.Add($"State machine rejected recovery: {exception.Message}");
        }

        ReleaseInputSafely("connection failure");

        try
        {
            _state.FinishRecovery(peerStillConnected: false, "Disconnected; retrying");
        }
        catch (Exception exception)
        {
            _diagnostics.Add($"State machine rejected recovery completion: {exception.Message}");
        }
    }

    private void ReleaseInputSafely(string reason)
    {
        try
        {
            _input.ReleaseAll();
        }
        catch (Exception exception)
        {
            _diagnostics.Add($"Release-all warning during {reason}: {exception.Message}");
        }
    }

    private static SideCursorConfig CloneConfiguration(SideCursorConfig source)
    {
        return new SideCursorConfig
        {
            SchemaVersion = source.SchemaVersion,
            DeviceId = source.DeviceId,
            Transport = source.Transport,
            PeerHost = source.PeerHost,
            PeerPort = source.PeerPort,
            TargetDisplayId = source.TargetDisplayId,
            PointerCalibration = source.PointerCalibration,
            AbsolutePointer = source.AbsolutePointer,
            ReturnEdgeInsetPixels = source.ReturnEdgeInsetPixels,
            ClipboardEnabled = source.ClipboardEnabled,
            ClipboardMaximumBytes = source.ClipboardMaximumBytes,
            Commands = new CommandBindings
            {
                DesktopLeft = source.Commands.DesktopLeft,
                DesktopRight = source.Commands.DesktopRight,
                TaskView = source.Commands.TaskView,
                ShowDesktop = source.Commands.ShowDesktop,
            },
        };
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }

    private sealed class TransportConnection : IAsyncDisposable
    {
        private readonly IAsyncDisposable? _asyncOwner;
        private readonly IDisposable? _owner;

        public TransportConnection(Stream stream, bool windowsActsAsClient, object owner)
        {
            Stream = stream;
            WindowsActsAsClient = windowsActsAsClient;
            _asyncOwner = owner as IAsyncDisposable;
            _owner = owner as IDisposable;
        }

        public Stream Stream { get; }
        public bool WindowsActsAsClient { get; }

        public async ValueTask DisposeAsync()
        {
            if (_asyncOwner is not null)
            {
                await _asyncOwner.DisposeAsync().ConfigureAwait(false);
            }

            _owner?.Dispose();
        }
    }
}
