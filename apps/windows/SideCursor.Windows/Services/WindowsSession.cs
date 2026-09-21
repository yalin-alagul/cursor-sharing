using System.Diagnostics;
using System.Text;
using System.Text.Json;
using SideCursor.Windows.Core;
using SideCursor.Windows.Infrastructure;
using SideCursor.Windows.Protocol;

namespace SideCursor.Windows.Services;

public sealed class WindowsSession : IDisposable
{
    private readonly SideCursorConfig _configuration;
    private readonly WindowsInputInjector _input;
    private readonly ClipboardSync _clipboard;
    private readonly SessionStateMachine _state;
    private readonly DiagnosticLog _diagnostics;
    private readonly Action<double> _roundTripUpdated;
    private readonly CancellationTokenSource _sessionCancellation = new();
    private V2SecureChannel? _channel;
    private string? _returnRequestId;
    private int _stopped;
    private int _disposed;
    private DateTimeOffset _lastPongAtUtc = DateTimeOffset.UtcNow;

    public WindowsSession(
        SideCursorConfig configuration,
        WindowsInputInjector input,
        ClipboardSync clipboard,
        SessionStateMachine state,
        DiagnosticLog diagnostics,
        Action<double> roundTripUpdated)
    {
        _configuration = Clone(configuration);
        _input = input;
        _clipboard = clipboard;
        _state = state;
        _diagnostics = diagnostics;
        _roundTripUpdated = roundTripUpdated;
    }

    public async Task RunAsync(V2SecureChannel channel, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(channel);
        _channel = channel;
        _clipboard.LocalTextChanged += OnLocalClipboardChanged;
        try
        {
            using var linkedCancellation = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken, _sessionCancellation.Token);
            var pingTask = RunPingLoopAsync(linkedCancellation.Token);
            try
            {
                while (!linkedCancellation.IsCancellationRequested)
                {
                    var message = await channel.ReceiveAsync(linkedCancellation.Token).ConfigureAwait(false);
                    await HandleMessageAsync(message, linkedCancellation.Token).ConfigureAwait(false);
                }
            }
            finally
            {
                _sessionCancellation.Cancel();
                try
                {
                    await pingTask.ConfigureAwait(false);
                }
                catch (OperationCanceledException)
                {
                    // Expected when the session is ending.
                }
            }
        }
        finally
        {
            _clipboard.LocalTextChanged -= OnLocalClipboardChanged;
            ReleaseInputSafely("session ended");
            _channel = null;
        }
    }

    public async Task RequestLocalReturnAsync()
    {
        var snapshot = _state.Snapshot;
        if (snapshot.State == SessionState.Remote)
        {
            await BeginReturnAsync(0.5, CancellationToken.None).ConfigureAwait(false);
        }
        else
        {
            ReleaseInputSafely("local return requested while not remote");
        }
    }

    public async Task ShutdownAsync(string reason)
    {
        if (Interlocked.Exchange(ref _stopped, 1) != 0)
        {
            return;
        }

        try
        {
            // Bound the release-all send so a hung peer with a full send buffer
            // can never block application exit indefinitely.
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await SendAsync(new { type = "release_all", reason }, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or OperationCanceledException)
        {
            _diagnostics.Add("Peer was unavailable while sending release-all.");
        }
        finally
        {
            ReleaseInputSafely(reason);
            _sessionCancellation.Cancel();
        }
    }

    public void Dispose()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        _clipboard.LocalTextChanged -= OnLocalClipboardChanged;
        _sessionCancellation.Cancel();
        _sessionCancellation.Dispose();
    }

    private async Task HandleMessageAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var type = RequiredString(message, "type");
        switch (type)
        {
            case "enter_request":
                await HandleEnterRequestAsync(message, cancellationToken).ConfigureAwait(false);
                break;
            case "input":
                await HandleInputAsync(message, cancellationToken).ConfigureAwait(false);
                break;
            case "command":
                HandleCommand(message);
                break;
            case "return_ack":
                HandleReturnAcknowledgement(message);
                break;
            case "return_request":
                await HandlePeerReturnRequestAsync(message, cancellationToken).ConfigureAwait(false);
                break;
            case "release_all":
                HandleReleaseAll(message);
                break;
            case "clipboard":
                HandleClipboard(message);
                break;
            case "ping":
                await HandlePingAsync(message, cancellationToken).ConfigureAwait(false);
                break;
            case "pong":
                HandlePong(message);
                break;
            default:
                throw new ProtocolViolationException($"Unsupported v2 message type '{type}'.");
        }
    }

    private async Task HandleEnterRequestAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var id = ReadRequestId(message);
        if (!_state.BeginEntering())
        {
            await SendAsync(new { type = "enter_reject", id, reason = "Windows is not ready for a new remote session" }, cancellationToken).ConfigureAwait(false);
            return;
        }

        try
        {
            var normalizedY = ReadNormalized(message, "y");
            if (!message.TryGetProperty("source", out var source) || source.ValueKind != JsonValueKind.Object)
            {
                throw new ProtocolViolationException("enter_request must include a source display object.");
            }

            var sourceDisplay = RequiredString(source, "display");
            var sourceWidth = ReadPositiveInt(source, "width");
            var sourceHeight = ReadPositiveInt(source, "height");
            var target = _input.EnterRemote(_configuration, sourceDisplay, sourceWidth, sourceHeight, normalizedY);
            // Confirm the session reached Remote *before* acknowledging entry.
            // If the state slipped (a concurrent shutdown or local return), the
            // Mac must never be told entry succeeded, otherwise it would capture
            // its cursor and forward input to a Windows side that is discarding
            // it, leaving the Mac stuck suppressing input.
            if (!_state.MarkRemote($"Controlling {target.Label}"))
            {
                throw new InputInjectionException("Windows session state changed before remote entry could complete.");
            }

            await SendAsync(new { type = "enter_ack", id }, cancellationToken).ConfigureAwait(false);
            _diagnostics.Add($"Remote input acknowledged for {target.Label}.");
        }
        catch (Exception exception) when (exception is InputInjectionException or InvalidOperationException or ProtocolViolationException)
        {
            ReleaseInputSafely("entry failed");
            _state.BeginRecovery($"Remote entry failed: {exception.Message}");
            _state.FinishRecovery(peerStillConnected: true, "Paired peer is ready");
            await SendAsync(new { type = "enter_reject", id, reason = SanitizeRemoteReason(exception.Message) }, cancellationToken).ConfigureAwait(false);
            _diagnostics.Add($"Remote entry rejected: {exception.Message}");
        }
    }

    private async Task HandleInputAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var sessionState = _state.Snapshot.State;
        if (sessionState != SessionState.Remote)
        {
            // Input frames can already be in flight when the selected Windows
            // edge starts (or completes) a return to the Mac. They are
            // harmlessly discarded rather than treated as a protocol fault that
            // tears down an otherwise healthy session.
            return;
        }

        if (!message.TryGetProperty("event", out var input) || input.ValueKind != JsonValueKind.Object)
        {
            throw new ProtocolViolationException("Input message must include an event object.");
        }

        var kind = RequiredString(input, "kind");
        switch (kind)
        {
            case "pointer":
            {
                var result = _input.InjectPointer(ReadFiniteDouble(input, "dx"), ReadFiniteDouble(input, "dy"));
                if (result.ReturnRequested)
                {
                    await BeginReturnAsync(result.ReturnY, cancellationToken).ConfigureAwait(false);
                }

                break;
            }
            case "button":
                _input.InjectButton(RequiredString(input, "button"), ReadBoolean(input, "down"));
                break;
            case "scroll":
                _input.InjectScroll(ReadFiniteDouble(input, "horizontal"), ReadFiniteDouble(input, "vertical"));
                break;
            case "key":
                _input.InjectKey((ushort)ReadIntInRange(input, "vk", 1, ushort.MaxValue), ReadBoolean(input, "down"), ReadOptionalBoolean(input, "extended"));
                break;
            default:
                throw new ProtocolViolationException($"Unsupported input event '{kind}'.");
        }
    }

    private void HandleCommand(JsonElement message)
    {
        if (_state.Snapshot.State != SessionState.Remote)
        {
            // Same in-flight tolerance as pointer/keyboard input.
            return;
        }

        var name = RequiredString(message, "name");
        try
        {
            _input.InjectCommand(name, _configuration.Commands);
        }
        catch (InputInjectionException exception)
        {
            // A rejected shortcut must never take down an otherwise healthy
            // session; report it and keep the transport alive.
            _diagnostics.Add($"Remote command '{name}' was ignored: {exception.Message}");
        }
    }

    private void HandleReturnAcknowledgement(JsonElement message)
    {
        var id = ReadRequestId(message);
        // GUIDs are case-insensitive by value. Windows emits the id in
        // lowercase "D" form while the Mac echoes it back as an uppercase
        // uuidString, so an ordinal comparison rejects every valid return.
        if (!string.Equals(id, _returnRequestId, StringComparison.OrdinalIgnoreCase))
        {
            throw new ProtocolViolationException("return_ack did not match the outstanding Windows return request.");
        }

        _returnRequestId = null;
        if (!_state.CompleteReturn())
        {
            throw new ProtocolViolationException("return_ack was received outside the Returning state.");
        }

        _diagnostics.Add("Mac acknowledged the return to local control.");
    }

    private async Task HandlePeerReturnRequestAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var id = ReadRequestId(message);
        if (_state.Snapshot.State == SessionState.Remote)
        {
            _state.BeginReturning("Mac requested local return");
        }

        ReleaseInputSafely("Mac requested local return");
        await SendAsync(new { type = "return_ack", id }, cancellationToken).ConfigureAwait(false);
        if (_state.Snapshot.State == SessionState.Returning)
        {
            _ = _state.CompleteReturn();
        }
    }

    private void HandleReleaseAll(JsonElement message)
    {
        _ = RequiredString(message, "reason");
        ReleaseInputSafely("peer release-all");
        if (_state.Snapshot.State is SessionState.Remote or SessionState.Entering or SessionState.Returning)
        {
            _state.BeginRecovery("Peer released remote input");
            _state.FinishRecovery(peerStillConnected: true, "Paired peer is ready");
        }
    }

    private void HandleClipboard(JsonElement message)
    {
        if (!_configuration.ClipboardEnabled)
        {
            return;
        }

        var origin = RequiredString(message, "origin");
        if (string.Equals(origin, _configuration.DeviceId, StringComparison.OrdinalIgnoreCase))
        {
            return;
        }

        // Clipboard text may legitimately be empty (the remote clipboard was
        // cleared). RequiredString rejects empty strings, which used to turn a
        // benign clear into a protocol violation and force a reconnect.
        if (!message.TryGetProperty("text", out var textValue) || textValue.ValueKind != JsonValueKind.String)
        {
            throw new ProtocolViolationException("Message property 'text' is required.");
        }

        var text = textValue.GetString()!;
        if (text.Length == 0)
        {
            return;
        }

        if (Encoding.UTF8.GetByteCount(text) > Math.Min(_configuration.ClipboardMaximumBytes, V2Protocol.MaximumClipboardBytes))
        {
            throw new ProtocolViolationException("Clipboard text exceeds the configured v2 limit.");
        }

        _clipboard.ApplyRemoteText(text);
    }

    private async Task HandlePingAsync(JsonElement message, CancellationToken cancellationToken)
    {
        var sentAtMs = ReadInt64(message, "sentAtMs");
        await SendAsync(new { type = "pong", sentAtMs }, cancellationToken).ConfigureAwait(false);
    }

    private void HandlePong(JsonElement message)
    {
        var sentAtMs = ReadInt64(message, "sentAtMs");
        _lastPongAtUtc = DateTimeOffset.UtcNow;
        var elapsed = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() - sentAtMs;
        if (elapsed is >= 0 and <= 60_000)
        {
            _roundTripUpdated(elapsed);
        }
    }

    private async Task BeginReturnAsync(double normalizedY, CancellationToken cancellationToken)
    {
        if (!_state.BeginReturning())
        {
            return;
        }

        try
        {
            ReleaseInputSafely("Windows target left edge reached");
            _returnRequestId = Guid.NewGuid().ToString("D");
            await SendAsync(new { type = "return_request", id = _returnRequestId, y = Math.Clamp(normalizedY, 0.0, 1.0) }, cancellationToken).ConfigureAwait(false);
            _diagnostics.Add("Windows target left edge reached; requested return to Mac.");
        }
        catch
        {
            _state.BeginRecovery("Unable to request return to Mac");
            throw;
        }
    }

    private async Task RunPingLoopAsync(CancellationToken cancellationToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(2));
        while (await timer.WaitForNextTickAsync(cancellationToken).ConfigureAwait(false))
        {
            // Mirror the Mac's dead-peer watchdog. If the Mac stops answering
            // while it owns Windows input, Windows must release injected keys
            // and buttons and return to a retryable state instead of holding
            // them down forever.
            if (_state.Snapshot.State is SessionState.Remote or SessionState.Entering or SessionState.Returning &&
                DateTimeOffset.UtcNow - _lastPongAtUtc > TimeSpan.FromSeconds(6))
            {
                ReleaseInputSafely("peer stopped responding to keepalive");
                _state.BeginRecovery("Peer stopped responding to keepalive");
                _sessionCancellation.Cancel();
                throw new IOException("The paired Mac stopped responding to keepalive while Windows was being controlled.");
            }

            var sentAtMs = DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();
            await SendAsync(new { type = "ping", sentAtMs }, cancellationToken).ConfigureAwait(false);
        }
    }

    private void OnLocalClipboardChanged(object? sender, string text)
    {
        if (!_configuration.ClipboardEnabled || Volatile.Read(ref _stopped) != 0)
        {
            return;
        }

        _ = SendClipboardSafelyAsync(text);
    }

    private async Task SendClipboardSafelyAsync(string text)
    {
        try
        {
            if (Encoding.UTF8.GetByteCount(text) > Math.Min(_configuration.ClipboardMaximumBytes, V2Protocol.MaximumClipboardBytes))
            {
                _diagnostics.Add("Local clipboard was not sent because it exceeds the configured limit.");
                return;
            }

            // Bound the send so a wedged socket cannot hold the send gate open
            // forever and silently stop clipboard sync.
            using var timeout = new CancellationTokenSource(TimeSpan.FromSeconds(2));
            await SendAsync(new { type = "clipboard", origin = _configuration.DeviceId, text }, timeout.Token).ConfigureAwait(false);
        }
        catch (Exception exception) when (exception is IOException or ObjectDisposedException or OperationCanceledException)
        {
            _diagnostics.Add("Local clipboard update was dropped because the peer disconnected.");
        }
    }

    private Task SendAsync<T>(T message, CancellationToken cancellationToken)
    {
        var channel = _channel ?? throw new IOException("The secure channel is not available.");
        return channel.SendAsync(message, cancellationToken);
    }

    private void ReleaseInputSafely(string reason)
    {
        try
        {
            _input.ReleaseAll();
        }
        catch (Exception exception)
        {
            _diagnostics.Add($"Release-all reported an input error during {reason}: {exception.Message}");
        }
    }

    private static SideCursorConfig Clone(SideCursorConfig source)
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

    private static string ReadRequestId(JsonElement element)
    {
        var id = RequiredString(element, "id");
        if (!Guid.TryParse(id, out _))
        {
            throw new ProtocolViolationException("Protocol request id must be a UUID.");
        }

        return id;
    }

    private static string RequiredString(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(value.GetString()))
        {
            throw new ProtocolViolationException($"Message property '{property}' is required.");
        }

        return value.GetString()!;
    }

    private static int ReadPositiveInt(JsonElement element, string property) => ReadIntInRange(element, property, 1, 100_000);

    private static int ReadIntInRange(JsonElement element, string property, int minimum, int maximum)
    {
        if (!element.TryGetProperty(property, out var value) || !value.TryGetInt32(out var parsed) || parsed < minimum || parsed > maximum)
        {
            throw new ProtocolViolationException($"Message property '{property}' is out of range.");
        }

        return parsed;
    }

    private static long ReadInt64(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || !value.TryGetInt64(out var parsed))
        {
            throw new ProtocolViolationException($"Message property '{property}' must be an integer.");
        }

        return parsed;
    }

    private static double ReadFiniteDouble(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || !value.TryGetDouble(out var parsed) || !double.IsFinite(parsed))
        {
            throw new ProtocolViolationException($"Message property '{property}' must be a finite number.");
        }

        return parsed;
    }

    private static double ReadNormalized(JsonElement element, string property)
    {
        var value = ReadFiniteDouble(element, property);
        if (value is < 0 or > 1)
        {
            throw new ProtocolViolationException($"Message property '{property}' must be between zero and one.");
        }

        return value;
    }

    private static bool ReadBoolean(JsonElement element, string property)
    {
        if (!element.TryGetProperty(property, out var value) || value.ValueKind is not JsonValueKind.True and not JsonValueKind.False)
        {
            throw new ProtocolViolationException($"Message property '{property}' must be a boolean.");
        }

        return value.GetBoolean();
    }

    private static bool ReadOptionalBoolean(JsonElement element, string property)
    {
        return element.TryGetProperty(property, out var value) &&
               (value.ValueKind is JsonValueKind.True or JsonValueKind.False) &&
               value.GetBoolean();
    }

    private static string SanitizeRemoteReason(string reason)
    {
        return reason.Length <= 160 ? reason : reason[..160];
    }
}
