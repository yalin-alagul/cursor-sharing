using System.IO;
using Windows.Devices.Bluetooth.Rfcomm;
using Windows.Networking.Sockets;
using Windows.Storage.Streams;

namespace SideCursor.Windows.Infrastructure;

/// <summary>
/// Windows is the manually-started RFCOMM listener. The Mac opens this service
/// only when the user selects Bluetooth; TCP/Tailscale remains the default.
/// </summary>
public sealed class BluetoothRfcommListener : IAsyncDisposable
{
    public static readonly Guid ServiceUuid = new("2A99401E-C4A4-4CD4-9AB1-8090C2444BB6");

    private readonly object _gate = new();
    private TaskCompletionSource<StreamSocket>? _connection;
    private RfcommServiceProvider? _provider;
    private StreamSocketListener? _listener;
    private StreamSocket? _acceptedSocket;
    private bool _advertising;

    public bool IsListening { get; private set; }

    public async Task StartAsync(CancellationToken cancellationToken)
    {
        lock (_gate)
        {
            if (IsListening)
            {
                return;
            }
        }

        var provider = await RfcommServiceProvider.CreateAsync(RfcommServiceId.FromUuid(ServiceUuid)).AsTask(cancellationToken).ConfigureAwait(false);
        var listener = new StreamSocketListener();
        var connection = new TaskCompletionSource<StreamSocket>(TaskCreationOptions.RunContinuationsAsynchronously);
        listener.ConnectionReceived += OnConnectionReceived;
        try
        {
            await listener.BindServiceNameAsync(
                provider.ServiceId.AsString(),
                SocketProtectionLevel.BluetoothEncryptionAllowNullAuthentication).AsTask(cancellationToken).ConfigureAwait(false);
            lock (_gate)
            {
                _provider = provider;
                _listener = listener;
                _connection = connection;
                _advertising = true;
                IsListening = true;
            }
            provider.StartAdvertising(listener);
        }
        catch
        {
            lock (_gate)
            {
                if (ReferenceEquals(_provider, provider))
                {
                    _provider = null;
                    _listener = null;
                    _connection = null;
                    _advertising = false;
                    IsListening = false;
                }
            }
            listener.ConnectionReceived -= OnConnectionReceived;
            listener.Dispose();
            StopAdvertisingSafely(provider);
            throw;
        }
    }

    public async Task<Stream> AcceptAsync(CancellationToken cancellationToken)
    {
        Task<StreamSocket> waitForConnection;
        lock (_gate)
        {
            if (!IsListening || _connection is null)
            {
                throw new InvalidOperationException("Bluetooth RFCOMM is not listening.");
            }

            waitForConnection = _connection.Task;
        }

        var socket = await waitForConnection.WaitAsync(cancellationToken).ConfigureAwait(false);
        lock (_gate)
        {
            _acceptedSocket = socket;
        }

        return new WinRtDuplexStream(socket.InputStream, socket.OutputStream, socket);
    }

    public ValueTask DisposeAsync()
    {
        StreamSocketListener? listener;
        RfcommServiceProvider? provider;
        StreamSocket? socket;
        TaskCompletionSource<StreamSocket>? connection;
        bool wasAdvertising;
        lock (_gate)
        {
            listener = _listener;
            provider = _provider;
            socket = _acceptedSocket;
            connection = _connection;
            wasAdvertising = _advertising;
            _listener = null;
            _provider = null;
            _acceptedSocket = null;
            _connection = null;
            _advertising = false;
            IsListening = false;
        }

        connection?.TrySetCanceled();
        if (listener is not null)
        {
            listener.ConnectionReceived -= OnConnectionReceived;
            listener.Dispose();
        }

        if (wasAdvertising && provider is not null)
        {
            StopAdvertisingSafely(provider);
        }
        socket?.Dispose();
        return ValueTask.CompletedTask;
    }

    private void OnConnectionReceived(StreamSocketListener sender, StreamSocketListenerConnectionReceivedEventArgs args)
    {
        RfcommServiceProvider? provider;
        StreamSocketListener? listener;
        TaskCompletionSource<StreamSocket>? connection;
        bool wasAdvertising;
        lock (_gate)
        {
            provider = _provider;
            listener = _listener;
            connection = _connection;
            wasAdvertising = _advertising;
            _listener = null;
            _advertising = false;
            IsListening = false;
        }

        if (wasAdvertising && provider is not null)
        {
            StopAdvertisingSafely(provider);
        }
        if (listener is not null)
        {
            listener.ConnectionReceived -= OnConnectionReceived;
            listener.Dispose();
        }

        if (connection is null || !connection.TrySetResult(args.Socket))
        {
            args.Socket.Dispose();
        }
    }

    private static void StopAdvertisingSafely(RfcommServiceProvider provider)
    {
        try
        {
            provider.StopAdvertising();
        }
        catch (InvalidOperationException)
        {
            // WinRT reports this after the Bluetooth stack has already
            // withdrawn the service as part of an accepted connection.
        }
    }
}

internal sealed class WinRtDuplexStream : Stream
{
    private readonly IInputStream _input;
    private readonly IOutputStream _output;
    private readonly StreamSocket _socket;
    private int _disposed;

    public WinRtDuplexStream(IInputStream input, IOutputStream output, StreamSocket socket)
    {
        _input = input;
        _output = output;
        _socket = socket;
    }

    public override bool CanRead => Volatile.Read(ref _disposed) == 0;
    public override bool CanSeek => false;
    public override bool CanWrite => Volatile.Read(ref _disposed) == 0;
    public override long Length => throw new NotSupportedException();
    public override long Position
    {
        get => throw new NotSupportedException();
        set => throw new NotSupportedException();
    }

    public override void Flush() => FlushAsync(CancellationToken.None).GetAwaiter().GetResult();

    public override async Task FlushAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        _ = await _output.FlushAsync().AsTask(cancellationToken).ConfigureAwait(false);
    }

    public override int Read(byte[] buffer, int offset, int count) =>
        ReadAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

    public override async ValueTask<int> ReadAsync(Memory<byte> buffer, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (buffer.Length == 0)
        {
            return 0;
        }

        var nativeBuffer = await _input.ReadAsync(
            new global::Windows.Storage.Streams.Buffer((uint)buffer.Length),
            (uint)buffer.Length,
            InputStreamOptions.Partial).AsTask(cancellationToken).ConfigureAwait(false);
        if (nativeBuffer.Length == 0)
        {
            return 0;
        }

        var copied = new byte[nativeBuffer.Length];
        try
        {
            using var reader = DataReader.FromBuffer(nativeBuffer);
            reader.ReadBytes(copied);
            copied.AsSpan().CopyTo(buffer.Span);
            return copied.Length;
        }
        finally
        {
            Array.Clear(copied);
        }
    }

    public override void Write(byte[] buffer, int offset, int count) =>
        WriteAsync(buffer.AsMemory(offset, count), CancellationToken.None).AsTask().GetAwaiter().GetResult();

    public override async ValueTask WriteAsync(ReadOnlyMemory<byte> buffer, CancellationToken cancellationToken = default)
    {
        ThrowIfDisposed();
        if (buffer.Length == 0)
        {
            return;
        }

        using var writer = new DataWriter(_output);
        writer.WriteBytes(buffer.ToArray());
        _ = await writer.StoreAsync().AsTask(cancellationToken).ConfigureAwait(false);
        writer.DetachStream();
    }

    public override long Seek(long offset, SeekOrigin origin) => throw new NotSupportedException();
    public override void SetLength(long value) => throw new NotSupportedException();

    protected override void Dispose(bool disposing)
    {
        if (disposing && Interlocked.Exchange(ref _disposed, 1) == 0)
        {
            _input.Dispose();
            _output.Dispose();
            _socket.Dispose();
        }

        base.Dispose(disposing);
    }

    public override ValueTask DisposeAsync() => base.DisposeAsync();

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }
}
