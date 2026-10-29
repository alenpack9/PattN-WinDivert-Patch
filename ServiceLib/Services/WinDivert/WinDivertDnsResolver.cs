using System.Net;
using System.Net.Http.Headers;

namespace ServiceLib.Services.WinDivert;

/// <summary>
/// Resolves dns queries with "dns over https" through the local proxy inbound.
/// <para>
/// The queries are sent to the dns-over-https server through the running core, so the
/// resolution is not poisoned and does not leak the requested domains.
/// </para>
/// <para>
/// A short lived cache keeps the resolver usable when the tunnel is slow: the DoH request has
/// a timeout, and a failed request serves the last known answer (stale) instead of failing the
/// client, because falling back to the plaintext system resolver would be a DNS leak.
/// </para>
/// </summary>
public class WinDivertDnsResolver : IDisposable
{
    private const string DefaultPrimaryDoh = "https://1.1.1.1/dns-query";
    private const string DefaultFallbackDoh = "https://8.8.8.8/dns-query";

    private const int CacheMaxEntries = 512;
    private const int CacheMinTtlSeconds = 5;
    private const int CacheMaxTtlSeconds = 300;
    private const int CacheDefaultTtlSeconds = 30;
    private static readonly TimeSpan StaleLimit = TimeSpan.FromMinutes(10);
    private static readonly TimeSpan ResolveDeadline = TimeSpan.FromSeconds(10);
    private static readonly TimeSpan AttemptTimeout = TimeSpan.FromSeconds(6);

    private readonly string _primaryDohUrl;
    private readonly string _fallbackDohUrl;
    private readonly ConcurrentDictionary<string, CacheEntry> _cache = new();
    private HttpClient? _httpClient;
    private int _proxyPort;
    private long _queries;
    private long _failures;
    private long _staleAnswers;

    public WinDivertDnsResolver(string? dohUrl)
    {
        // Prefer direct IP addresses to avoid chicken-and-egg bootstrap DNS lookups
        _primaryDohUrl = string.IsNullOrWhiteSpace(dohUrl) || dohUrl.Contains("cloudflare-dns.com")
            ? DefaultPrimaryDoh
            : dohUrl;
        _fallbackDohUrl = DefaultFallbackDoh;
    }

    public long Queries => Interlocked.Read(ref _queries);

    public long Failures => Interlocked.Read(ref _failures);

    public long StaleAnswers => Interlocked.Read(ref _staleAnswers);

    /// <summary>
    /// Sends the raw dns query to the dns-over-https server and returns the raw dns answer.
    /// </summary>
    /// <param name="query">Raw dns query (wire format).</param>
    /// <param name="socksPort">Local socks/mixed port of the running core.</param>
    /// <param name="token">Cancellation token.</param>
    /// <returns>The raw dns response or null when the query could not be answered.</returns>
    public async Task<byte[]?> ResolveAsync(byte[] query, int socksPort, CancellationToken token)
    {
        if (query.Length < 12)
        {
            return null;
        }

        Interlocked.Increment(ref _queries);

        // The transaction id (the first two bytes) is different for every query, so the key
        // starts after it; the id is restored when the cached answer is returned.
        var key = Convert.ToHexString(query, 2, query.Length - 2);
        _cache.TryGetValue(key, out var cached);

        var now = Environment.TickCount64;
        if (cached != null && now < cached.ExpiresAtTicks)
        {
            return Stamp(cached.Response, query);
        }

        using var overall = CancellationTokenSource.CreateLinkedTokenSource(token);
        overall.CancelAfter(ResolveDeadline);

        // Try primary DoH first (e.g. 1.1.1.1), then the fallback (e.g. 8.8.8.8)
        var result = await QueryDohAsync(_primaryDohUrl, query, socksPort, overall.Token);
        if (result == null && !string.Equals(_primaryDohUrl, _fallbackDohUrl, StringComparison.OrdinalIgnoreCase))
        {
            result = await QueryDohAsync(_fallbackDohUrl, query, socksPort, overall.Token);
        }

        if (result != null)
        {
            Store(key, result);
            return result;
        }

        Interlocked.Increment(ref _failures);

        // Never fail open to the plaintext resolver: an old answer is better than a leak.
        if (cached != null && now - cached.StoredAtTicks < StaleLimit.TotalMilliseconds)
        {
            Interlocked.Increment(ref _staleAnswers);
            return Stamp(cached.Response, query);
        }

        return null;
    }

    private static byte[] Stamp(byte[] response, byte[] query)
    {
        var copy = (byte[])response.Clone();
        copy[0] = query[0];
        copy[1] = query[1];
        return copy;
    }

    private void Store(string key, byte[] response)
    {
        if (_cache.Count > CacheMaxEntries)
        {
            var now = Environment.TickCount64;
            foreach (var entry in _cache)
            {
                if (now >= entry.Value.ExpiresAtTicks)
                {
                    _cache.TryRemove(entry.Key, out _);
                }
                if (_cache.Count <= CacheMaxEntries / 2)
                {
                    break;
                }
            }
            if (_cache.Count > CacheMaxEntries)
            {
                _cache.Clear();
            }
        }

        var stored = (byte[])response.Clone();
        stored[0] = 0;
        stored[1] = 0;

        var ticks = Environment.TickCount64;
        _cache[key] = new CacheEntry(stored, ticks + (GetMinTtl(response) * 1000L), ticks);
    }

    /// <summary>
    /// Returns the smallest ttl of the answer records, clamped to a cacheable range.
    /// </summary>
    private static int GetMinTtl(byte[] response)
    {
        try
        {
            if (response.Length < 12)
            {
                return CacheDefaultTtlSeconds;
            }

            var questions = (response[4] << 8) | response[5];
            var answers = (response[6] << 8) | response[7];
            var records = answers + ((response[8] << 8) | response[9]) + ((response[10] << 8) | response[11]);

            var offset = 12;
            for (var i = 0; i < questions; i++)
            {
                offset = SkipName(response, offset);
                if (offset < 0)
                {
                    return CacheDefaultTtlSeconds;
                }
                offset += 4;
            }

            long min = long.MaxValue;
            for (var i = 0; i < records; i++)
            {
                offset = SkipName(response, offset);
                if (offset < 0 || offset + 10 > response.Length)
                {
                    return CacheDefaultTtlSeconds;
                }

                var type = (response[offset] << 8) | response[offset + 1];
                long ttl = ((long)response[offset + 4] << 24) | ((long)response[offset + 5] << 16)
                    | ((long)response[offset + 6] << 8) | response[offset + 7];
                var rdLength = (response[offset + 8] << 8) | response[offset + 9];
                offset += 10 + rdLength;

                if (offset > response.Length)
                {
                    return CacheDefaultTtlSeconds;
                }

                // type 41 is the EDNS OPT record, it has no real ttl
                if (i < answers && type != 41 && ttl < min)
                {
                    min = ttl;
                }
            }

            if (min == long.MaxValue)
            {
                return CacheDefaultTtlSeconds;
            }

            return (int)Math.Clamp(min, CacheMinTtlSeconds, CacheMaxTtlSeconds);
        }
        catch
        {
            return CacheDefaultTtlSeconds;
        }
    }

    /// <summary>
    /// Walks over a (possibly compressed) dns name and returns the offset right after it.
    /// </summary>
    private static int SkipName(byte[] buffer, int offset)
    {
        var guard = 0;
        while (offset >= 0 && offset < buffer.Length && guard++ < 128)
        {
            var length = buffer[offset];
            if (length == 0)
            {
                return offset + 1;
            }
            if ((length & 0xC0) == 0xC0)
            {
                return offset + 2;
            }
            offset += length + 1;
        }
        return -1;
    }

    private async Task<byte[]?> QueryDohAsync(string url, byte[] query, int socksPort, CancellationToken token)
    {
        try
        {
            var client = GetClient(socksPort);
            using var content = new ByteArrayContent(query);
            content.Headers.ContentType = new MediaTypeHeaderValue("application/dns-message");

            using var cts = CancellationTokenSource.CreateLinkedTokenSource(token);
            cts.CancelAfter(AttemptTimeout);

            using var response = await client.PostAsync(url, content, cts.Token);
            if (!response.IsSuccessStatusCode)
            {
                return null;
            }

            var bytes = await response.Content.ReadAsByteArrayAsync(cts.Token);
            if (bytes.Length < 12)
            {
                return null;
            }

            // Some resolvers answer with a zeroed transaction id, restore the original one.
            bytes[0] = query[0];
            bytes[1] = query[1];

            return bytes;
        }
        catch (OperationCanceledException)
        {
            // the attempt timed out (or the engine is stopping), counted by the caller
            return null;
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertDnsResolver", ex);
            return null;
        }
    }

    private HttpClient GetClient(int socksPort)
    {
        if (_httpClient != null && _proxyPort == socksPort)
        {
            return _httpClient;
        }

        _httpClient?.Dispose();

        var handler = new SocketsHttpHandler
        {
            UseProxy = true,
            Proxy = new WebProxy(new Uri($"socks5://{IPAddress.Loopback}:{socksPort}")),
            ConnectTimeout = TimeSpan.FromSeconds(4),
            PooledConnectionLifetime = TimeSpan.FromMinutes(2),
            MaxConnectionsPerServer = 4,
            EnableMultipleHttp2Connections = true,
        };

        _httpClient = new HttpClient(handler)
        {
            Timeout = TimeSpan.FromSeconds(10),
        };
        _proxyPort = socksPort;

        return _httpClient;
    }

    public void Dispose()
    {
        _httpClient?.Dispose();
        _httpClient = null;
        _cache.Clear();
    }

    private sealed class CacheEntry
    {
        public CacheEntry(byte[] response, long expiresAtTicks, long storedAtTicks)
        {
            Response = response;
            ExpiresAtTicks = expiresAtTicks;
            StoredAtTicks = storedAtTicks;
        }

        public byte[] Response { get; }

        public long ExpiresAtTicks { get; }

        public long StoredAtTicks { get; }
    }
}
