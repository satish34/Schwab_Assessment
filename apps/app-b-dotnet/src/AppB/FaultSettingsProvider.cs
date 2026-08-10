using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace AppB;

public sealed record FaultSettings(int InjectedLatencyMs, double InjectedErrorRate)
{
    public static FaultSettings Normal { get; } = new(0, 0.0);
}

public interface IFaultSettingsProvider
{
    FaultSettings Current { get; }
}

public sealed class FaultSettingsProvider : BackgroundService, IFaultSettingsProvider
{
    private static readonly JsonSerializerOptions SerializerOptions = new(JsonSerializerDefaults.Web);
    private readonly string _path;
    private readonly StructuredLogWriter _logger;
    private FaultSettings _current;
    private string _lastContentHash = string.Empty;

    public FaultSettingsProvider(IConfiguration configuration, StructuredLogWriter logger)
    {
        _path = configuration["FAULT_CONFIG_PATH"] ?? "/etc/app-b-faults/faults.json";
        _logger = logger;
        _current = LoadInitial(_path);
    }

    public FaultSettings Current => Volatile.Read(ref _current);

    public static FaultSettings Parse(string json)
    {
        var file = JsonSerializer.Deserialize<FaultSettingsFile>(json, SerializerOptions)
            ?? throw new InvalidDataException("Fault configuration is empty.");

        if (file.InjectedLatencyMs is null)
        {
            throw new InvalidDataException("injected_latency_ms is required.");
        }

        if (file.InjectedLatencyMs is < 0 or > 60_000)
        {
            throw new InvalidDataException("injected_latency_ms must be between 0 and 60000.");
        }

        if (file.InjectedErrorRate is null)
        {
            throw new InvalidDataException("injected_error_rate is required.");
        }

        if (double.IsNaN(file.InjectedErrorRate.Value) ||
            file.InjectedErrorRate is < 0.0 or > 1.0)
        {
            throw new InvalidDataException("injected_error_rate must be between 0.0 and 1.0.");
        }

        return new FaultSettings(file.InjectedLatencyMs.Value, file.InjectedErrorRate.Value);
    }

    public static bool ShouldInjectFailure(string sampleKey, double errorRate)
    {
        if (errorRate <= 0.0)
        {
            return false;
        }

        if (errorRate >= 1.0)
        {
            return true;
        }

        ArgumentException.ThrowIfNullOrWhiteSpace(sampleKey);
        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(sampleKey));
        var sample = BinaryPrimitives.ReadUInt64BigEndian(hash) / (double)ulong.MaxValue;
        return sample < errorRate;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        using var timer = new PeriodicTimer(TimeSpan.FromSeconds(1));

        while (await timer.WaitForNextTickAsync(stoppingToken))
        {
            await ReloadIfChangedAsync(stoppingToken);
        }
    }

    private static FaultSettings LoadInitial(string path)
    {
        if (!File.Exists(path))
        {
            return FaultSettings.Normal;
        }

        try
        {
            return Parse(File.ReadAllText(path));
        }
        catch (Exception)
        {
            return FaultSettings.Normal;
        }
    }

    private async Task ReloadIfChangedAsync(CancellationToken cancellationToken)
    {
        if (!File.Exists(_path))
        {
            return;
        }

        string content;
        try
        {
            content = await File.ReadAllTextAsync(_path, cancellationToken);
        }
        catch (IOException)
        {
            return;
        }

        var contentHash = Convert.ToHexString(SHA256.HashData(Encoding.UTF8.GetBytes(content)));
        if (contentHash == _lastContentHash)
        {
            return;
        }

        _lastContentHash = contentHash;

        try
        {
            var settings = Parse(content);
            Volatile.Write(ref _current, settings);
            _logger.WriteLifecycle("INFO", "fault configuration reloaded");
        }
        catch (Exception exception) when (exception is JsonException or InvalidDataException)
        {
            _logger.WriteException(
                "fault configuration rejected",
                "lifecycle",
                string.Empty,
                string.Empty,
                0,
                0,
                string.Empty,
                "invalid_fault_configuration",
                exception);
        }
    }

    private sealed record FaultSettingsFile(
        [property: JsonPropertyName("injected_latency_ms")] int? InjectedLatencyMs,
        [property: JsonPropertyName("injected_error_rate")] double? InjectedErrorRate);
}
