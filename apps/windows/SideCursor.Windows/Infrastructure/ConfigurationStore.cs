using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;
using SideCursor.Windows.Core;

namespace SideCursor.Windows.Infrastructure;

public sealed class AppDataPaths
{
    public AppDataPaths(string? rootDirectory = null)
    {
        RootDirectory = rootDirectory ?? Path.Combine(
            Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
            "SideCursor");
    }

    public string RootDirectory { get; }
    public string ConfigurationPath => Path.Combine(RootDirectory, "settings.json");
    public string PairingSecretPath => Path.Combine(RootDirectory, "pairing.secret");
}

public sealed class ConfigurationStore
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        Converters = { new JsonStringEnumConverter(JsonNamingPolicy.CamelCase) },
    };

    private readonly AppDataPaths _paths;

    public ConfigurationStore(AppDataPaths paths)
    {
        _paths = paths;
    }

    public SideCursorConfig Load()
    {
        if (!File.Exists(_paths.ConfigurationPath))
        {
            return new SideCursorConfig();
        }

        var json = File.ReadAllText(_paths.ConfigurationPath, Encoding.UTF8);
        var configuration = JsonSerializer.Deserialize<SideCursorConfig>(json, JsonOptions)
            ?? throw new InvalidDataException("SideCursor settings file is empty or malformed.");
        configuration.Normalize();
        return configuration;
    }

    public void Save(SideCursorConfig configuration)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        configuration.Normalize();
        Directory.CreateDirectory(_paths.RootDirectory);

        var temporaryPath = _paths.ConfigurationPath + ".tmp";
        try
        {
            File.WriteAllText(temporaryPath, JsonSerializer.Serialize(configuration, JsonOptions), new UTF8Encoding(false));
            File.Move(temporaryPath, _paths.ConfigurationPath, overwrite: true);
        }
        finally
        {
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}

public sealed class PairingSecretStore
{
    private static readonly byte[] Entropy = SHA256.HashData(Encoding.UTF8.GetBytes("SideCursor/v2/Windows/DPAPI"));
    private readonly AppDataPaths _paths;

    public PairingSecretStore(AppDataPaths paths)
    {
        _paths = paths;
    }

    public bool HasSecret => File.Exists(_paths.PairingSecretPath);

    public byte[] Read()
    {
        if (!File.Exists(_paths.PairingSecretPath))
        {
            throw new InvalidOperationException("No pairing secret has been saved. Pair this Windows device first.");
        }

        var protectedBytes = File.ReadAllBytes(_paths.PairingSecretPath);
        try
        {
            var secret = ProtectedData.Unprotect(protectedBytes, Entropy, DataProtectionScope.CurrentUser);
            if (secret.Length != 32)
            {
                CryptographicOperations.ZeroMemory(secret);
                throw new InvalidDataException("The protected pairing secret has an invalid length.");
            }

            return secret;
        }
        finally
        {
            CryptographicOperations.ZeroMemory(protectedBytes);
        }
    }

    public void Save(ReadOnlySpan<byte> secret)
    {
        if (secret.Length != 32)
        {
            throw new ArgumentException("A v2 pairing secret must contain exactly 32 bytes.", nameof(secret));
        }

        Directory.CreateDirectory(_paths.RootDirectory);
        var protectedBytes = ProtectedData.Protect(secret.ToArray(), Entropy, DataProtectionScope.CurrentUser);
        var temporaryPath = _paths.PairingSecretPath + ".tmp";
        try
        {
            File.WriteAllBytes(temporaryPath, protectedBytes);
            File.Move(temporaryPath, _paths.PairingSecretPath, overwrite: true);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(protectedBytes);
            if (File.Exists(temporaryPath))
            {
                File.Delete(temporaryPath);
            }
        }
    }
}

public static class PairingSecretParser
{
    public static byte[] Parse(string pairingCode)
    {
        if (string.IsNullOrWhiteSpace(pairingCode))
        {
            throw new ArgumentException("Enter a pairing code before saving settings.", nameof(pairingCode));
        }

        var normalized = pairingCode.Trim();
        if (TryDecodeBase64Url(normalized, out var decoded) && decoded.Length == 32)
        {
            return decoded;
        }

        CryptographicOperations.ZeroMemory(decoded);
        if (normalized.Length is < 16 or > 512)
        {
            throw new ArgumentException("A textual pairing code must contain 16 to 512 characters.", nameof(pairingCode));
        }

        return SHA256.HashData(Encoding.UTF8.GetBytes(normalized));
    }

    private static bool TryDecodeBase64Url(string value, out byte[] decoded)
    {
        decoded = Array.Empty<byte>();
        if (value.Any(char.IsWhiteSpace))
        {
            return false;
        }

        var base64 = value.Replace('-', '+').Replace('_', '/');
        var remainder = base64.Length % 4;
        if (remainder == 1)
        {
            return false;
        }

        if (remainder != 0)
        {
            base64 = base64.PadRight(base64.Length + (4 - remainder), '=');
        }

        try
        {
            decoded = Convert.FromBase64String(base64);
            return true;
        }
        catch (FormatException)
        {
            return false;
        }
    }
}

public sealed class DiagnosticLog
{
    private static readonly string LogFilePath = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData),
        "SideCursor",
        "diagnostics.log");

    private readonly object _gate = new();
    private readonly Queue<string> _entries = new();
    private const int Capacity = 160;

    public void Add(string message)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(message);
        var line = $"{DateTimeOffset.Now:HH:mm:ss.fff}  {message}";
        lock (_gate)
        {
            _entries.Enqueue(line);
            while (_entries.Count > Capacity)
            {
                _entries.Dequeue();
            }

            // Keep a persistent copy for remote diagnosis of transient
            // reconnects that are otherwise invisible in the in-memory UI log.
            try
            {
                File.AppendAllText(LogFilePath, line + Environment.NewLine);
            }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException)
            {
                // Logging must never take down the app.
            }
        }
    }

    public IReadOnlyList<string> Snapshot()
    {
        lock (_gate)
        {
            return _entries.ToArray();
        }
    }
}
