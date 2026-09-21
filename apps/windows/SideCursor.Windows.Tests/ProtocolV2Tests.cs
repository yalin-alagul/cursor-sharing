using System.Buffers.Binary;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Security.Authentication;
using System.Security.Cryptography;
using System.Text.Json;
using Org.BouncyCastle.Crypto.Parameters;
using SideCursor.Windows.Protocol;
using NativeProtocolViolationException = SideCursor.Windows.Protocol.ProtocolViolationException;

namespace SideCursor.Windows.Tests;

public sealed class ProtocolV2Tests
{
    [Fact]
    public async Task PairedPeersCompleteHandshakeAndExchangeEncryptedFrames()
    {
        var pairingSecret = RandomNumberGenerator.GetBytes(V2Protocol.PairingSecretBytes);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            var serverTask = Task.Run(async () =>
            {
                var accepted = await listener.AcceptTcpClientAsync();
                var channel = await V2Handshake.AcceptAsServerAsync(accepted.GetStream(), pairingSecret, CancellationToken.None);
                return (accepted, channel);
            });

            using var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, endpoint.Port);
            await using var clientChannel = await V2Handshake.ConnectAsClientAsync(client.GetStream(), pairingSecret, CancellationToken.None);
            var server = await serverTask;
            using var accepted = server.accepted;
            await using var serverChannel = server.channel;

            await clientChannel.SendAsync(new { type = "ping", sentAtMs = 123L }, CancellationToken.None);
            var received = await serverChannel.ReceiveAsync(CancellationToken.None);
            Assert.Equal("ping", received.GetProperty("type").GetString());
            Assert.Equal(123L, received.GetProperty("sentAtMs").GetInt64());

            await serverChannel.SendAsync(new { type = "pong", sentAtMs = 123L }, CancellationToken.None);
            var response = await clientChannel.ReceiveAsync(CancellationToken.None);
            Assert.Equal("pong", response.GetProperty("type").GetString());
        }
        finally
        {
            listener.Stop();
            CryptographicOperations.ZeroMemory(pairingSecret);
        }
    }

    [Fact]
    public async Task WrongPairingSecretIsRejected()
    {
        var serverSecret = RandomNumberGenerator.GetBytes(V2Protocol.PairingSecretBytes);
        var clientSecret = RandomNumberGenerator.GetBytes(V2Protocol.PairingSecretBytes);
        var listener = new TcpListener(IPAddress.Loopback, 0);
        listener.Start();
        try
        {
            var endpoint = (IPEndPoint)listener.LocalEndpoint;
            var serverTask = Task.Run(async () =>
            {
                using var accepted = await listener.AcceptTcpClientAsync();
                await Assert.ThrowsAsync<AuthenticationException>(() => V2Handshake.AcceptAsServerAsync(accepted.GetStream(), serverSecret, CancellationToken.None));
            });

            using var client = new TcpClient();
            await client.ConnectAsync(IPAddress.Loopback, endpoint.Port);
            await Assert.ThrowsAnyAsync<Exception>(() => V2Handshake.ConnectAsClientAsync(client.GetStream(), clientSecret, CancellationToken.None));
            await serverTask;
        }
        finally
        {
            listener.Stop();
            CryptographicOperations.ZeroMemory(serverSecret);
            CryptographicOperations.ZeroMemory(clientSecret);
        }
    }

    [Fact]
    public void SequenceWindowRejectsReplayAndOutOfOrderFrames()
    {
        var sequence = new StrictSequenceWindow();
        sequence.ValidateAndAdvance(1);

        Assert.Throws<NativeProtocolViolationException>(() => sequence.ValidateAndAdvance(1));
        Assert.Throws<NativeProtocolViolationException>(() => sequence.ValidateAndAdvance(3));
        sequence.ValidateAndAdvance(2);
    }

    [Fact]
    public void Base64UrlRejectsWrongKeyLength()
    {
        Assert.Throws<NativeProtocolViolationException>(() => Base64Url.Decode("AQID", V2Protocol.PublicKeyBytes, "pub"));
    }

    [Fact]
    public async Task MacInteropFixtureDerivesAndReadsTheExactV2Frame()
    {
        using var fixture = JsonDocument.Parse(File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "interop-vectors.json")));
        var root = fixture.RootElement;
        var frame = root.GetProperty("frame");
        var pairingSecret = Decode(root.GetProperty("pairingSecret").GetString()!);
        var serverPrivateBytes = Decode(root.GetProperty("serverPrivate").GetString()!);
        var clientPublic = Decode(root.GetProperty("clientPublic").GetString()!);
        var serverNonce = Decode(root.GetProperty("serverNonce").GetString()!);
        var clientNonce = Decode(root.GetProperty("clientNonce").GetString()!);
        byte[]? sessionKey = null;
        try
        {
            var serverPrivate = new X25519PrivateKeyParameters(serverPrivateBytes, 0);
            Assert.Equal(root.GetProperty("serverPublic").GetString(), Base64Url.Encode(serverPrivate.GeneratePublicKey().GetEncoded()));

            var pairTranscript = V2Handshake.Concat(
                serverPrivate.GeneratePublicKey().GetEncoded(),
                clientPublic,
                serverNonce,
                clientNonce);
            try
            {
                var pairProof = HMACSHA256.HashData(pairingSecret, pairTranscript);
                try
                {
                    Assert.Equal(root.GetProperty("pairProof").GetString(), Base64Url.Encode(pairProof));
                }
                finally
                {
                    CryptographicOperations.ZeroMemory(pairProof);
                }
            }
            finally
            {
                CryptographicOperations.ZeroMemory(pairTranscript);
            }

            sessionKey = V2Handshake.DeriveSessionKey(serverPrivate, clientPublic, serverNonce, clientNonce, pairingSecret);
            Assert.Equal(root.GetProperty("sessionKey").GetString(), Base64Url.Encode(sessionKey));
            var acceptProof = HMACSHA256.HashData(sessionKey, "accept"u8.ToArray());
            try
            {
                Assert.Equal(root.GetProperty("acceptProof").GetString(), Base64Url.Encode(acceptProof));
            }
            finally
            {
                CryptographicOperations.ZeroMemory(acceptProof);
            }

            var sequence = frame.GetProperty("sequence").GetUInt64();
            var combined = Decode(frame.GetProperty("combined").GetString()!);
            var encryptedPayload = new byte[sizeof(ulong) + combined.Length];
            BinaryPrimitives.WriteUInt64BigEndian(encryptedPayload, sequence);
            combined.CopyTo(encryptedPayload, sizeof(ulong));
            var framed = new byte[sizeof(uint) + encryptedPayload.Length];
            BinaryPrimitives.WriteUInt32BigEndian(framed, checked((uint)encryptedPayload.Length));
            encryptedPayload.CopyTo(framed, sizeof(uint));

            await using var reader = new V2SecureChannel(new MemoryStream(framed, writable: false), sessionKey);
            var decrypted = await reader.ReceiveAsync(CancellationToken.None);
            Assert.Equal("ping", decrypted.GetProperty("type").GetString());
            Assert.Equal(123L, decrypted.GetProperty("sentAtMs").GetInt64());

            using var writerStream = new MemoryStream();
            await using var writer = new V2SecureChannel(writerStream, sessionKey);
            await writer.SendAsync(new { type = "ping", sentAtMs = 123L }, CancellationToken.None);
            var writerFrame = writerStream.ToArray();
            Assert.Equal(
                checked((uint)(writerFrame.Length - sizeof(uint))),
                BinaryPrimitives.ReadUInt32BigEndian(writerFrame));
        }
        finally
        {
            CryptographicOperations.ZeroMemory(pairingSecret);
            CryptographicOperations.ZeroMemory(serverPrivateBytes);
            CryptographicOperations.ZeroMemory(clientPublic);
            CryptographicOperations.ZeroMemory(serverNonce);
            CryptographicOperations.ZeroMemory(clientNonce);
            if (sessionKey is not null)
            {
                CryptographicOperations.ZeroMemory(sessionKey);
            }
        }
    }

    private static byte[] Decode(string value)
    {
        var normalized = value.Replace('-', '+').Replace('_', '/');
        normalized = normalized.PadRight(normalized.Length + ((4 - normalized.Length % 4) % 4), '=');
        return Convert.FromBase64String(normalized);
    }
}
