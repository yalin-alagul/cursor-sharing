using System.Net.Sockets;
using System.Security.Cryptography;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Protocol;

try
{
    if (args.Length > 0 && string.Equals(args[0], "tcp", StringComparison.OrdinalIgnoreCase))
    {
        if (args.Length is < 3 or > 4 || !int.TryParse(args[2], out var port) || port is < 1 or > 65_535)
        {
            throw new ArgumentException("Usage: tcp <mac-tailscale-address> <port> [seconds]");
        }

        var seconds = args.Length == 4 && int.TryParse(args[3], out var parsedSeconds)
            ? Math.Clamp(parsedSeconds, 1, 60)
            : 20;
        await RunTcpProbeAsync(args[1], port, seconds);
    }
    else
    {
        var seconds = args.Length == 1 && int.TryParse(args[0], out var parsedSeconds)
            ? Math.Clamp(parsedSeconds, 1, 60)
            : 20;
        await RunBluetoothProbeAsync(seconds);
    }
}
catch (Exception exception)
{
    Console.Error.WriteLine($"SIDECURSOR_HARDWARE_PROBE_FAILED {exception}");
    return 1;
}

return 0;

static async Task RunBluetoothProbeAsync(int seconds)
{
    await using var listener = new BluetoothRfcommListener();
    using var startupTimeout = new CancellationTokenSource(TimeSpan.FromSeconds(15));
    using var probeLifetime = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
    await listener.StartAsync(startupTimeout.Token);
    if (!listener.IsListening)
    {
        throw new InvalidOperationException("RFCOMM listener did not report ready.");
    }

    Console.WriteLine($"SIDECURSOR_BLUETOOTH_READY {BluetoothRfcommListener.ServiceUuid}");
    try
    {
        await using var stream = await listener.AcceptAsync(probeLifetime.Token);
        Console.WriteLine("SIDECURSOR_BLUETOOTH_CONNECTED");
        await CompleteEncryptedProbeAsync(stream, probeLifetime.Token, "SIDECURSOR_BLUETOOTH", expectedPings: 1);
        await Task.Delay(Timeout.InfiniteTimeSpan, probeLifetime.Token);
    }
    catch (OperationCanceledException) when (probeLifetime.IsCancellationRequested)
    {
        // The probe window elapsed without a connection, or after reporting
        // a verified connection. Either way, disposal withdraws the service.
    }

    Console.WriteLine("SIDECURSOR_BLUETOOTH_STOPPED");
}

static async Task RunTcpProbeAsync(string host, int port, int seconds)
{
    using var probeLifetime = new CancellationTokenSource(TimeSpan.FromSeconds(seconds));
    using var client = new TcpClient { NoDelay = true };
    await client.ConnectAsync(host, port, probeLifetime.Token);
    Console.WriteLine("SIDECURSOR_TCP_CONNECTED");
    await using var stream = client.GetStream();
    await CompleteEncryptedProbeAsync(stream, probeLifetime.Token, "SIDECURSOR_TCP", expectedPings: 25);
    Console.WriteLine("SIDECURSOR_TCP_STOPPED");
}

static async Task CompleteEncryptedProbeAsync(
    Stream stream,
    CancellationToken cancellationToken,
    string marker,
    int expectedPings)
{
    var pairingSecret = Enumerable.Range(0, V2Protocol.PairingSecretBytes).Select(static value => (byte)value).ToArray();
    try
    {
        await using var channel = await V2Handshake.ConnectAsClientAsync(stream, pairingSecret, cancellationToken);
        Console.WriteLine($"{marker}_SECURE");

        for (var index = 0; index < expectedPings; index += 1)
        {
            var message = await channel.ReceiveAsync(cancellationToken);
            if (!message.TryGetProperty("type", out var type) || type.GetString() != "ping" ||
                !message.TryGetProperty("sentAtMs", out var sentAtMs))
            {
                throw new InvalidDataException("The Mac did not send the expected encrypted probe ping.");
            }

            await channel.SendAsync(new { type = "pong", sentAtMs = sentAtMs.GetInt64() }, cancellationToken);
        }

        Console.WriteLine($"{marker}_ENCRYPTED_PONG {expectedPings}");
    }
    finally
    {
        CryptographicOperations.ZeroMemory(pairingSecret);
    }
}
