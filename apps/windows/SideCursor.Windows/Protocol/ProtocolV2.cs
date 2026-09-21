using System.Buffers.Binary;
using System.IO;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using Org.BouncyCastle.Crypto;
using Org.BouncyCastle.Crypto.Modes;
using Org.BouncyCastle.Crypto.Parameters;
using Org.BouncyCastle.Security;

namespace SideCursor.Windows.Protocol;

public sealed class ProtocolViolationException : IOException
{
    public ProtocolViolationException(string message)
        : base(message)
    {
    }
}

public static class V2Protocol
{
    public const int Version = 2;
    public const int PairingSecretBytes = 32;
    public const int PublicKeyBytes = 32;
    public const int NonceBytes = 16;
    public const int AeadNonceBytes = 12;
    public const int AeadTagBytes = 16;
    public const int MaximumHandshakeBytes = 16 * 1024;
    public const int MaximumEncryptedFrameBytes = 2 * 1024 * 1024;
    public const int MaximumClipboardBytes = 1024 * 1024;
    public static readonly byte[] HkdfInfoPrefix = Encoding.UTF8.GetBytes("SideCursor/v2");

    public static void ValidatePairingSecret(ReadOnlySpan<byte> pairingSecret)
    {
        if (pairingSecret.Length != PairingSecretBytes)
        {
            throw new ArgumentException("The v2 pairing secret must contain exactly 32 bytes.", nameof(pairingSecret));
        }
    }
}

public static class Base64Url
{
    public static string Encode(ReadOnlySpan<byte> bytes)
    {
        return Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');
    }

    public static byte[] Decode(string value, int expectedLength, string fieldName)
    {
        if (string.IsNullOrWhiteSpace(value) || value.Any(char.IsWhiteSpace))
        {
            throw new ProtocolViolationException($"Handshake field '{fieldName}' is missing or malformed.");
        }

        var normalized = value.Replace('-', '+').Replace('_', '/');
        var remainder = normalized.Length % 4;
        if (remainder == 1)
        {
            throw new ProtocolViolationException($"Handshake field '{fieldName}' is malformed.");
        }

        if (remainder != 0)
        {
            normalized = normalized.PadRight(normalized.Length + (4 - remainder), '=');
        }

        try
        {
            var decoded = Convert.FromBase64String(normalized);
            if (decoded.Length != expectedLength)
            {
                CryptographicOperations.ZeroMemory(decoded);
                throw new ProtocolViolationException($"Handshake field '{fieldName}' has an invalid length.");
            }

            return decoded;
        }
        catch (FormatException exception)
        {
            throw new ProtocolViolationException($"Handshake field '{fieldName}' is malformed.") { Source = exception.Source };
        }
    }
}

public static class V2Handshake
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static async Task<V2SecureChannel> ConnectAsClientAsync(
        Stream stream,
        ReadOnlyMemory<byte> pairingSecret,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        V2Protocol.ValidatePairingSecret(pairingSecret.Span);

        var hello = await ReadHandshakeMessageAsync(stream, cancellationToken).ConfigureAwait(false);
        ValidateEnvelope(hello, "hello");
        var serverPublic = Base64Url.Decode(ReadRequiredString(hello, "pub"), V2Protocol.PublicKeyBytes, "pub");
        var serverNonce = Base64Url.Decode(ReadRequiredString(hello, "nonce"), V2Protocol.NonceBytes, "nonce");
        var clientPrivate = new X25519PrivateKeyParameters(new SecureRandom());
        var clientPublic = clientPrivate.GeneratePublicKey().GetEncoded();
        var clientNonce = RandomNumberGenerator.GetBytes(V2Protocol.NonceBytes);

        byte[]? sessionKey = null;
        try
        {
            var proofInput = Concat(serverPublic, clientPublic, serverNonce, clientNonce);
            var proof = HMACSHA256.HashData(pairingSecret.Span, proofInput);
            try
            {
                await WriteHandshakeMessageAsync(stream, new
                {
                    v = V2Protocol.Version,
                    kind = "pair",
                    pub = Base64Url.Encode(clientPublic),
                    nonce = Base64Url.Encode(clientNonce),
                    proof = Base64Url.Encode(proof),
                }, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(proofInput);
                CryptographicOperations.ZeroMemory(proof);
            }

            sessionKey = DeriveSessionKey(clientPrivate, serverPublic, serverNonce, clientNonce, pairingSecret.Span);
            var accept = await ReadHandshakeMessageAsync(stream, cancellationToken).ConfigureAwait(false);
            ValidateEnvelope(accept, "accept");
            var remoteProof = Base64Url.Decode(ReadRequiredString(accept, "proof"), 32, "proof");
            var expectedProof = HMACSHA256.HashData(sessionKey, Encoding.UTF8.GetBytes("accept"));
            try
            {
                if (!CryptographicOperations.FixedTimeEquals(remoteProof, expectedProof))
                {
                    throw new AuthenticationException("The paired peer could not prove the negotiated v2 session key.");
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(remoteProof);
                CryptographicOperations.ZeroMemory(expectedProof);
            }

            var channel = new V2SecureChannel(stream, sessionKey);
            sessionKey = null;
            return channel;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(serverPublic);
            CryptographicOperations.ZeroMemory(serverNonce);
            CryptographicOperations.ZeroMemory(clientPublic);
            CryptographicOperations.ZeroMemory(clientNonce);
            if (sessionKey is not null)
            {
                CryptographicOperations.ZeroMemory(sessionKey);
            }
        }
    }

    public static async Task<V2SecureChannel> AcceptAsServerAsync(
        Stream stream,
        ReadOnlyMemory<byte> pairingSecret,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(stream);
        V2Protocol.ValidatePairingSecret(pairingSecret.Span);

        var serverPrivate = new X25519PrivateKeyParameters(new SecureRandom());
        var serverPublic = serverPrivate.GeneratePublicKey().GetEncoded();
        var serverNonce = RandomNumberGenerator.GetBytes(V2Protocol.NonceBytes);
        byte[]? clientPublic = null;
        byte[]? clientNonce = null;
        byte[]? sessionKey = null;

        try
        {
            await WriteHandshakeMessageAsync(stream, new
            {
                v = V2Protocol.Version,
                kind = "hello",
                pub = Base64Url.Encode(serverPublic),
                nonce = Base64Url.Encode(serverNonce),
            }, cancellationToken).ConfigureAwait(false);

            var pair = await ReadHandshakeMessageAsync(stream, cancellationToken).ConfigureAwait(false);
            ValidateEnvelope(pair, "pair");
            clientPublic = Base64Url.Decode(ReadRequiredString(pair, "pub"), V2Protocol.PublicKeyBytes, "pub");
            clientNonce = Base64Url.Decode(ReadRequiredString(pair, "nonce"), V2Protocol.NonceBytes, "nonce");
            var suppliedProof = Base64Url.Decode(ReadRequiredString(pair, "proof"), 32, "proof");
            var proofInput = Concat(serverPublic, clientPublic, serverNonce, clientNonce);
            var expectedProof = HMACSHA256.HashData(pairingSecret.Span, proofInput);
            try
            {
                if (!CryptographicOperations.FixedTimeEquals(suppliedProof, expectedProof))
                {
                    throw new AuthenticationException("The pairing proof was rejected.");
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(suppliedProof);
                CryptographicOperations.ZeroMemory(proofInput);
                CryptographicOperations.ZeroMemory(expectedProof);
            }

            sessionKey = DeriveSessionKey(serverPrivate, clientPublic, serverNonce, clientNonce, pairingSecret.Span);
            var acceptProof = HMACSHA256.HashData(sessionKey, Encoding.UTF8.GetBytes("accept"));
            try
            {
                await WriteHandshakeMessageAsync(stream, new
                {
                    v = V2Protocol.Version,
                    kind = "accept",
                    proof = Base64Url.Encode(acceptProof),
                }, cancellationToken).ConfigureAwait(false);
            }
            finally
            {
                CryptographicOperations.ZeroMemory(acceptProof);
            }

            var channel = new V2SecureChannel(stream, sessionKey);
            sessionKey = null;
            return channel;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(serverPublic);
            CryptographicOperations.ZeroMemory(serverNonce);
            if (clientPublic is not null)
            {
                CryptographicOperations.ZeroMemory(clientPublic);
            }

            if (clientNonce is not null)
            {
                CryptographicOperations.ZeroMemory(clientNonce);
            }

            if (sessionKey is not null)
            {
                CryptographicOperations.ZeroMemory(sessionKey);
            }
        }
    }

    internal static byte[] DeriveSessionKey(
        X25519PrivateKeyParameters localPrivate,
        ReadOnlySpan<byte> remotePublic,
        ReadOnlySpan<byte> serverNonce,
        ReadOnlySpan<byte> clientNonce,
        ReadOnlySpan<byte> pairingSecret)
    {
        V2Protocol.ValidatePairingSecret(pairingSecret);
        if (remotePublic.Length != V2Protocol.PublicKeyBytes ||
            serverNonce.Length != V2Protocol.NonceBytes ||
            clientNonce.Length != V2Protocol.NonceBytes)
        {
            throw new ProtocolViolationException("The peer supplied invalid X25519 material.");
        }

        var sharedSecret = new byte[V2Protocol.PublicKeyBytes];
        var saltInput = Concat(serverNonce.ToArray(), clientNonce.ToArray());
        var salt = SHA256.HashData(saltInput);
        var info = Concat(V2Protocol.HkdfInfoPrefix, pairingSecret.ToArray());
        try
        {
            localPrivate.GenerateSecret(new X25519PublicKeyParameters(remotePublic.ToArray(), 0), sharedSecret, 0);
            return HkdfSha256(sharedSecret, salt, info, 32);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(sharedSecret);
            CryptographicOperations.ZeroMemory(saltInput);
            CryptographicOperations.ZeroMemory(salt);
            CryptographicOperations.ZeroMemory(info);
        }
    }

    private static async Task WriteHandshakeMessageAsync(Stream stream, object message, CancellationToken cancellationToken)
    {
        var json = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        if (json.Length > V2Protocol.MaximumHandshakeBytes)
        {
            throw new ProtocolViolationException("Handshake frame exceeds the 16 KiB protocol limit.");
        }

        var header = new byte[sizeof(uint)];
        BinaryPrimitives.WriteUInt32BigEndian(header, checked((uint)json.Length));
        try
        {
            await stream.WriteAsync(header, cancellationToken).ConfigureAwait(false);
            await stream.WriteAsync(json, cancellationToken).ConfigureAwait(false);
            await stream.FlushAsync(cancellationToken).ConfigureAwait(false);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(json);
            CryptographicOperations.ZeroMemory(header);
        }
    }

    private static async Task<JsonElement> ReadHandshakeMessageAsync(Stream stream, CancellationToken cancellationToken)
    {
        var header = new byte[sizeof(uint)];
        try
        {
            await ReadExactlyAsync(stream, header, cancellationToken).ConfigureAwait(false);
            var length = BinaryPrimitives.ReadUInt32BigEndian(header);
            if (length is 0 or > V2Protocol.MaximumHandshakeBytes)
            {
                throw new ProtocolViolationException("Handshake frame has an invalid length.");
            }

            var payload = new byte[checked((int)length)];
            try
            {
                await ReadExactlyAsync(stream, payload, cancellationToken).ConfigureAwait(false);
                using var document = JsonDocument.Parse(payload);
                if (document.RootElement.ValueKind != JsonValueKind.Object)
                {
                    throw new ProtocolViolationException("Handshake frame must contain a JSON object.");
                }

                return document.RootElement.Clone();
            }
            catch (JsonException exception)
            {
                throw new ProtocolViolationException($"Handshake JSON is invalid: {exception.Message}");
            }
            finally
            {
                CryptographicOperations.ZeroMemory(payload);
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(header);
        }
    }

    private static void ValidateEnvelope(JsonElement message, string expectedKind)
    {
        if (!message.TryGetProperty("v", out var version) || version.ValueKind != JsonValueKind.Number ||
            !version.TryGetInt32(out var parsedVersion) || parsedVersion != V2Protocol.Version)
        {
            throw new ProtocolViolationException("The peer does not speak SideCursor native protocol v2.");
        }

        if (!message.TryGetProperty("kind", out var kind) || kind.ValueKind != JsonValueKind.String ||
            !string.Equals(kind.GetString(), expectedKind, StringComparison.Ordinal))
        {
            throw new ProtocolViolationException($"Expected handshake message '{expectedKind}'.");
        }
    }

    private static string ReadRequiredString(JsonElement message, string property)
    {
        if (!message.TryGetProperty(property, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrEmpty(value.GetString()))
        {
            throw new ProtocolViolationException($"Handshake property '{property}' is required.");
        }

        return value.GetString()!;
    }

    private static byte[] HkdfSha256(ReadOnlySpan<byte> ikm, ReadOnlySpan<byte> salt, ReadOnlySpan<byte> info, int outputLength)
    {
        var extractKey = HMACSHA256.HashData(salt, ikm);
        var output = new byte[outputLength];
        var previous = Array.Empty<byte>();
        var offset = 0;
        try
        {
            for (byte counter = 1; offset < outputLength; counter++)
            {
                var input = Concat(previous, info.ToArray(), [counter]);
                try
                {
                    var next = HMACSHA256.HashData(extractKey, input);
                    CryptographicOperations.ZeroMemory(previous);
                    previous = next;
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(input);
                }

                var take = Math.Min(previous.Length, outputLength - offset);
                previous.AsSpan(0, take).CopyTo(output.AsSpan(offset));
                offset += take;
            }

            return output;
        }
        catch
        {
            CryptographicOperations.ZeroMemory(output);
            throw;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(extractKey);
            CryptographicOperations.ZeroMemory(previous);
        }
    }

    internal static async Task ReadExactlyAsync(Stream stream, Memory<byte> buffer, CancellationToken cancellationToken)
    {
        var read = 0;
        while (read < buffer.Length)
        {
            var received = await stream.ReadAsync(buffer[read..], cancellationToken).ConfigureAwait(false);
            if (received == 0)
            {
                throw new EndOfStreamException("The paired peer closed the transport.");
            }

            read += received;
        }
    }

    internal static byte[] Concat(params byte[][] values)
    {
        var length = values.Sum(static value => value.Length);
        var result = new byte[length];
        var offset = 0;
        foreach (var value in values)
        {
            value.AsSpan().CopyTo(result.AsSpan(offset));
            offset += value.Length;
        }

        return result;
    }
}

public sealed class StrictSequenceWindow
{
    private ulong _lastSequence;

    public ulong LastSequence => _lastSequence;

    public void ValidateAndAdvance(ulong sequence)
    {
        if (sequence == 0 || sequence != checked(_lastSequence + 1))
        {
            throw new ProtocolViolationException("Encrypted frame sequence is not exactly increasing.");
        }

        _lastSequence = sequence;
    }
}

public sealed class V2SecureChannel : IAsyncDisposable
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly Stream _stream;
    private readonly byte[] _sessionKey;
    private readonly SemaphoreSlim _sendGate = new(1, 1);
    private readonly StrictSequenceWindow _receiveSequence = new();
    private ulong _sendSequence;
    private int _disposed;

    internal V2SecureChannel(Stream stream, ReadOnlySpan<byte> sessionKey)
    {
        ArgumentNullException.ThrowIfNull(stream);
        if (sessionKey.Length != 32)
        {
            throw new ArgumentException("A v2 session key must contain 32 bytes.", nameof(sessionKey));
        }

        _stream = stream;
        _sessionKey = sessionKey.ToArray();
    }

    public async Task SendAsync<T>(T message, CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var plaintext = JsonSerializer.SerializeToUtf8Bytes(message, JsonOptions);
        try
        {
            if (plaintext.Length > V2Protocol.MaximumEncryptedFrameBytes - sizeof(ulong) - V2Protocol.AeadNonceBytes - V2Protocol.AeadTagBytes)
            {
                throw new ProtocolViolationException("Encrypted plaintext exceeds the v2 frame limit.");
            }

            await _sendGate.WaitAsync(cancellationToken).ConfigureAwait(false);
            try
            {
                var sequence = checked(_sendSequence + 1);
                var nonce = RandomNumberGenerator.GetBytes(V2Protocol.AeadNonceBytes);
                var aad = new byte[sizeof(ulong)];
                BinaryPrimitives.WriteUInt64BigEndian(aad, sequence);
                var ciphertext = Encrypt(plaintext, nonce, aad);
                var lengthHeader = new byte[sizeof(uint)];
                try
                {
                    BinaryPrimitives.WriteUInt32BigEndian(
                        lengthHeader,
                        checked((uint)(aad.Length + nonce.Length + ciphertext.Length)));
                    await _stream.WriteAsync(lengthHeader, cancellationToken).ConfigureAwait(false);
                    await _stream.WriteAsync(aad, cancellationToken).ConfigureAwait(false);
                    await _stream.WriteAsync(nonce, cancellationToken).ConfigureAwait(false);
                    await _stream.WriteAsync(ciphertext, cancellationToken).ConfigureAwait(false);
                    await _stream.FlushAsync(cancellationToken).ConfigureAwait(false);
                    _sendSequence = sequence;
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(lengthHeader);
                    CryptographicOperations.ZeroMemory(aad);
                    CryptographicOperations.ZeroMemory(nonce);
                    CryptographicOperations.ZeroMemory(ciphertext);
                }
            }
            finally
            {
                _sendGate.Release();
            }
        }
        finally
        {
            CryptographicOperations.ZeroMemory(plaintext);
        }
    }

    public async Task<JsonElement> ReceiveAsync(CancellationToken cancellationToken)
    {
        ThrowIfDisposed();
        var lengthHeader = new byte[sizeof(uint)];
        var sequenceBytes = new byte[sizeof(ulong)];
        var nonce = new byte[V2Protocol.AeadNonceBytes];
        byte[]? ciphertext = null;
        byte[]? plaintext = null;
        try
        {
            await V2Handshake.ReadExactlyAsync(_stream, lengthHeader, cancellationToken).ConfigureAwait(false);
            var payloadLength = BinaryPrimitives.ReadUInt32BigEndian(lengthHeader);
            var minimumPayloadLength = (uint)(sizeof(ulong) + V2Protocol.AeadNonceBytes + V2Protocol.AeadTagBytes);
            if (payloadLength < minimumPayloadLength || payloadLength > V2Protocol.MaximumEncryptedFrameBytes)
            {
                throw new ProtocolViolationException("Encrypted frame has an invalid length.");
            }

            await V2Handshake.ReadExactlyAsync(_stream, sequenceBytes, cancellationToken).ConfigureAwait(false);
            var sequence = BinaryPrimitives.ReadUInt64BigEndian(sequenceBytes);
            _receiveSequence.ValidateAndAdvance(sequence);
            await V2Handshake.ReadExactlyAsync(_stream, nonce, cancellationToken).ConfigureAwait(false);
            ciphertext = new byte[checked((int)payloadLength - sizeof(ulong) - V2Protocol.AeadNonceBytes)];
            await V2Handshake.ReadExactlyAsync(_stream, ciphertext, cancellationToken).ConfigureAwait(false);
            plaintext = Decrypt(ciphertext, nonce, sequenceBytes);
            using var document = JsonDocument.Parse(plaintext);
            if (document.RootElement.ValueKind != JsonValueKind.Object)
            {
                throw new ProtocolViolationException("Encrypted frame must contain a JSON object.");
            }

            return document.RootElement.Clone();
        }
        catch (JsonException exception)
        {
            throw new ProtocolViolationException($"Encrypted JSON is invalid: {exception.Message}");
        }
        finally
        {
            CryptographicOperations.ZeroMemory(lengthHeader);
            CryptographicOperations.ZeroMemory(sequenceBytes);
            CryptographicOperations.ZeroMemory(nonce);
            if (ciphertext is not null)
            {
                CryptographicOperations.ZeroMemory(ciphertext);
            }

            if (plaintext is not null)
            {
                CryptographicOperations.ZeroMemory(plaintext);
            }
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (Interlocked.Exchange(ref _disposed, 1) != 0)
        {
            return;
        }

        CryptographicOperations.ZeroMemory(_sessionKey);
        _sendGate.Dispose();
        await _stream.DisposeAsync().ConfigureAwait(false);
    }

    private byte[] Encrypt(ReadOnlySpan<byte> plaintext, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> aad)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        var parameters = new AeadParameters(new KeyParameter(_sessionKey), V2Protocol.AeadTagBytes * 8, nonce.ToArray(), aad.ToArray());
        cipher.Init(true, parameters);
        var output = new byte[cipher.GetOutputSize(plaintext.Length)];
        try
        {
            var length = cipher.ProcessBytes(plaintext.ToArray(), 0, plaintext.Length, output, 0);
            length += cipher.DoFinal(output, length);
            return output[..length];
        }
        catch
        {
            CryptographicOperations.ZeroMemory(output);
            throw;
        }
    }

    private byte[] Decrypt(ReadOnlySpan<byte> ciphertext, ReadOnlySpan<byte> nonce, ReadOnlySpan<byte> aad)
    {
        var cipher = new Org.BouncyCastle.Crypto.Modes.ChaCha20Poly1305();
        var parameters = new AeadParameters(new KeyParameter(_sessionKey), V2Protocol.AeadTagBytes * 8, nonce.ToArray(), aad.ToArray());
        cipher.Init(false, parameters);
        var output = new byte[cipher.GetOutputSize(ciphertext.Length)];
        try
        {
            var length = cipher.ProcessBytes(ciphertext.ToArray(), 0, ciphertext.Length, output, 0);
            length += cipher.DoFinal(output, length);
            return output[..length];
        }
        catch (InvalidCipherTextException exception)
        {
            CryptographicOperations.ZeroMemory(output);
            throw new AuthenticationException("Encrypted frame authentication failed.", exception);
        }
        catch
        {
            CryptographicOperations.ZeroMemory(output);
            throw;
        }
    }

    private void ThrowIfDisposed()
    {
        ObjectDisposedException.ThrowIf(Volatile.Read(ref _disposed) != 0, this);
    }
}
