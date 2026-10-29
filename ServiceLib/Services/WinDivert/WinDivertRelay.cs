using System.Net;

namespace ServiceLib.Services.WinDivert;

/// <summary>
/// Original destination of a diverted connection.
/// </summary>
/// <param name="TargetIp">The real destination ip the application wanted to reach.</param>
/// <param name="TargetPort">The real destination port.</param>
/// <param name="LocalIp">The local ip used by the application (source address).</param>
/// <param name="Token">
/// Unique id of this mapping. Windows reuses an ephemeral source port as soon as the previous
/// connection is closed, so a delayed cleanup must never remove the entry of a newer
/// connection that happens to use the same port.
/// </param>
public record OriginalDestination(IPAddress TargetIp, ushort TargetPort, IPAddress LocalIp, long Token = 0);

/// <summary>
/// Local relay used by the WinDivert engine.
/// <para>
/// WinDivert rewrites the destination of an outgoing connection to this local listener and
/// injects the packet as an inbound packet. The operating system therefore completes the TCP
/// handshake on behalf of the application, while the application still believes it is talking
/// to the original server. Every accepted connection is then forwarded to the local proxy
/// inbound (socks5/http) using the original destination.
/// </para>
/// </summary>
public class WinDivertRelay : IDisposable
{
    private TcpListener? _listener;
    private CancellationTokenSource? _cts;
    private int _activeConnections;
    private bool _disposed;

    /// <summary>
    /// The local port the relay listens on. Diverted packets are rewritten to this port.
    /// </summary>
    public ushort LocalRelayPort { get; private set; }

    /// <summary>
    /// Port of the local proxy inbound (socks5/mixed) of the running core.
    /// </summary>
    public int ProxyPort { get; set; }

    /// <summary>
    /// Source port of the application -> original destination.
    /// </summary>
    public ConcurrentDictionary<ushort, OriginalDestination> NatTable { get; } = new();

    public int ActiveConnections => _activeConnections;

    public long TotalBytesRelayed { get; private set; }

    private long _tokenSeed;

    /// <summary>
    /// Creates a unique id for a new nat entry.
    /// </summary>
    public long NextToken() => Interlocked.Increment(ref _tokenSeed);

    /// <summary>
    /// Removes a nat entry, but only when it still belongs to the given connection.
    /// <para>
    /// Windows reuses an ephemeral source port immediately after the connection is closed.
    /// Removing by port alone would delete the mapping of a newer connection that reused the
    /// same port, and that connection would then leak outside of the tunnel (its packets fall
    /// through to the direct path, so the real ip is exposed and the remote service refuses it).
    /// </para>
    /// </summary>
    public void Release(ushort srcPort, long token)
    {
        if (NatTable.TryGetValue(srcPort, out var current) && current.Token == token)
        {
            NatTable.TryRemove(srcPort, out _);
        }
    }

    public void Start()
    {
        Stop();

        _cts = new CancellationTokenSource();
        var token = _cts.Token;

        _listener = new TcpListener(IPAddress.Any, 0);
        _listener.Server.NoDelay = true;
        _listener.Start();
        LocalRelayPort = (ushort)((IPEndPoint)_listener.LocalEndpoint).Port;

        _ = Task.Run(async () =>
        {
            while (!token.IsCancellationRequested && _listener != null)
            {
                try
                {
                    var client = await _listener.AcceptTcpClientAsync(token);
                    _ = HandleClientAsync(client, token);
                }
                catch (OperationCanceledException)
                {
                    break;
                }
                catch (ObjectDisposedException)
                {
                    break;
                }
                catch
                {
                    // socket errors are not fatal for the listener
                }
            }
        }, token);
    }

    private async Task HandleClientAsync(TcpClient appClient, CancellationToken token)
    {
        Interlocked.Increment(ref _activeConnections);
        ushort srcPort = 0;
        long natToken = 0;

        try
        {
            using (appClient)
            {
                appClient.NoDelay = true;
                if (appClient.Client.RemoteEndPoint is not IPEndPoint clientEndPoint)
                {
                    return;
                }
                srcPort = (ushort)clientEndPoint.Port;

                // The entry must stay alive while the connection is running, it is used to
                // rewrite the packets coming back from the proxy.
                if (!NatTable.TryGetValue(srcPort, out var originalDest))
                {
                    return;
                }
                natToken = originalDest.Token;

                using var proxyClient = new TcpClient();
                proxyClient.NoDelay = true;

                using var connectCts = CancellationTokenSource.CreateLinkedTokenSource(token);
                connectCts.CancelAfter(TimeSpan.FromSeconds(15));

                try
                {
                    await proxyClient.ConnectAsync(IPAddress.Loopback, ProxyPort, connectCts.Token);
                }
                catch (OperationCanceledException)
                {
                    // the engine is stopping, this is not an error
                    return;
                }
                catch (Exception ex)
                {
                    Logging.SaveLog("WinDivertRelay", ex);
                    return;
                }

                var proxyStream = proxyClient.GetStream();
                var appStream = appClient.GetStream();

                if (!await HandshakeSocks5Async(proxyStream, originalDest.TargetIp, originalDest.TargetPort, connectCts.Token))
                {
                    Logging.SaveLog("WinDivertRelay: SOCKS5 handshake failed.");
                    return;
                }

                using var relayCts = CancellationTokenSource.CreateLinkedTokenSource(token);
                var upTask = RelayStreamAsync(appStream, proxyStream, proxyClient.Client, relayCts);
                var downTask = RelayStreamAsync(proxyStream, appStream, appClient.Client, relayCts);

                await Task.WhenAll(upTask, downTask);
            }
        }
        catch (OperationCanceledException)
        {
            // the engine is stopping, this is not an error
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertRelay", ex);
        }
        finally
        {
            Interlocked.Decrement(ref _activeConnections);

            // Keep the mapping a little longer so the remaining fin/ack packets can be rewritten.
            // The removal is guarded by the token: a newer connection may have reused this port
            // in the meantime, and its mapping must survive.
            if (srcPort != 0 && natToken != 0)
            {
                var token_ = natToken;
                var port_ = srcPort;
                _ = Task.Delay(5000).ContinueWith(t => Release(port_, token_));
            }
        }
    }

    private async Task RelayStreamAsync(NetworkStream src, NetworkStream dst, Socket dstSocket, CancellationTokenSource relayCts)
    {
        var buffer = new byte[16384];
        try
        {
            int read;
            while ((read = await src.ReadAsync(buffer.AsMemory(0, buffer.Length), relayCts.Token)) > 0)
            {
                await dst.WriteAsync(buffer.AsMemory(0, read), relayCts.Token);
                TotalBytesRelayed += read;
            }

            try
            {
                if (dstSocket.Connected)
                {
                    dstSocket.Shutdown(SocketShutdown.Send);
                }
            }
            catch
            {
                // ignore
            }

            try
            {
                relayCts.CancelAfter(TimeSpan.FromSeconds(30));
            }
            catch
            {
                // ignore
            }
        }
        catch (OperationCanceledException)
        {
            // normal shutdown
        }
        catch
        {
            try
            {
                relayCts.Cancel();
            }
            catch
            {
                // ignore
            }
        }
    }

    private static async Task<bool> ReadExactAsync(NetworkStream stream, byte[] buffer, int count, CancellationToken token)
    {
        var offset = 0;
        while (offset < count)
        {
            var read = await stream.ReadAsync(buffer.AsMemory(offset, count - offset), token);
            if (read <= 0)
            {
                return false;
            }
            offset += read;
        }
        return true;
    }

    private static async Task<bool> HandshakeSocks5Async(NetworkStream stream, IPAddress targetIp, ushort targetPort, CancellationToken token)
    {
        // greeting: no authentication
        await stream.WriteAsync(new byte[] { 0x05, 0x01, 0x00 }, token);

        var greetingResp = new byte[2];
        if (!await ReadExactAsync(stream, greetingResp, 2, token))
        {
            return false;
        }

        if (greetingResp[0] != 0x05 || greetingResp[1] != 0x00)
        {
            return false;
        }

        // connect request (ipv4)
        var ipBytes = targetIp.GetAddressBytes();
        var req = new byte[10];
        req[0] = 0x05;
        req[1] = 0x01;
        req[2] = 0x00;
        req[3] = 0x01;
        Buffer.BlockCopy(ipBytes, 0, req, 4, 4);
        req[8] = (byte)(targetPort >> 8);
        req[9] = (byte)(targetPort & 0xFF);

        await stream.WriteAsync(req, token);

        var replyHeader = new byte[4];
        if (!await ReadExactAsync(stream, replyHeader, 4, token))
        {
            return false;
        }

        if (replyHeader[0] != 0x05 || replyHeader[1] != 0x00)
        {
            return false;
        }

        var bndLen = replyHeader[3] switch
        {
            0x01 => 4 + 2,
            0x04 => 16 + 2,
            0x03 => -1,
            _ => 6
        };

        if (bndLen == -1)
        {
            var domainLenBuf = new byte[1];
            if (!await ReadExactAsync(stream, domainLenBuf, 1, token))
            {
                return false;
            }
            bndLen = domainLenBuf[0] + 2;
        }

        var bndBuf = new byte[bndLen];
        return await ReadExactAsync(stream, bndBuf, bndLen, token);
    }

    public void Stop()
    {
        try
        {
            _cts?.Cancel();
        }
        catch
        {
            // ignore
        }

        try
        {
            _listener?.Stop();
        }
        catch
        {
            // ignore
        }

        _listener = null;
        _cts = null;
        NatTable.Clear();
        _activeConnections = 0;
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Stop();
        _disposed = true;
        GC.SuppressFinalize(this);
    }
}
