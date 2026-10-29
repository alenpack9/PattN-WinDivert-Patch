using WinDivertSharp;

namespace ServiceLib.Services.WinDivert;

/// <summary>
/// Options of the WinDivert engine.
/// </summary>
public class WinDivertOptions
{
    /// <summary>
    /// Intercept dns queries and resolve them through the proxy (dns over https).
    /// </summary>
    public bool EnableDnsHijack { get; set; } = true;

    /// <summary>
    /// Drop quic/http3 traffic, so applications fall back to tcp which can be tunneled.
    /// </summary>
    public bool DropQuic { get; set; } = true;

    /// <summary>
    /// Do not divert traffic to private/local network addresses.
    /// </summary>
    public bool BypassLan { get; set; } = true;

    /// <summary>
    /// The dns-over-https server used to resolve the intercepted queries.
    /// </summary>
    public string DnsUrl { get; set; } = "https://1.1.1.1/dns-query";

    /// <summary>
    /// Answer AAAA (ipv6) queries with an empty answer.
    /// <para>
    /// The engine can not tunnel ipv6 traffic, it is silently dropped so Windows and the
    /// applications fall back to ipv4. When the resolver still hands out AAAA records, every
    /// application tries ipv6 first and hangs until its fallback timer expires (Go, Electron
    /// and Chromium based applications, ...). Returning no AAAA record removes that stall at
    /// the source and also prevents ipv6 leaks.
    /// </para>
    /// </summary>
    public bool BlockAaaa { get; set; } = true;

    /// <summary>
    /// Reset the tcp connections that were already established when the interception started,
    /// so the applications open new ones that the engine can divert to the relay.
    /// <para>
    /// See WinDivertEngine.ResetStaleConnections for the reason: a pre-existing connection is
    /// not diverted and keeps leaking the real ip, which makes some services fail (Google
    /// returns 403 to its own apis when they are reached directly from Iran).
    /// </para>
    /// </summary>
    public bool ResetStaleConnections { get; set; } = true;

    /// <summary>
    /// Local socks/mixed port of the running core.
    /// </summary>
    public int ProxyPort { get; set; }
}

/// <summary>
/// WinDivert based traffic interception.
/// <para>
/// All outgoing tcp connections are diverted to a local relay which forwards them through
/// the running core, so applications that ignore the system proxy are tunneled as well,
/// without requiring a tun adapter (wintun).
/// </para>
/// </summary>
public class WinDivertEngine : IDisposable
{
    private const string _tag = "WinDivertEngine";

    /// <summary>
    /// The packets that are diverted.
    /// <para>
    /// Do not add "not loopback" here: the relay talks to the application through the local ip
    /// address, and those packets must still be seen (and rewritten) by the engine. Loopback is
    /// handled per packet instead, see ProcessPacket.
    /// </para>
    /// </summary>
    private const string _filter = "(ip or ipv6) and (tcp or (udp and (udp.DstPort == 53 or udp.DstPort == 443 or udp.DstPort == 853 or udp.DstPort == 3478 or udp.DstPort == 19302)))";

    private const int _dnsTypeAaaa = 28;
    private const int _portDnsOverQuic = 853;

    private readonly WinDivertRelay _relay;
    private readonly WinDivertDnsResolver _dnsResolver;
    private readonly WinDivertOptions _options;
    private readonly ConcurrentDictionary<int, bool> _excludedPids = new();
    private readonly ConcurrentDictionary<long, long> _bypassedPorts = new();
    private readonly ConcurrentDictionary<ushort, long> _staleResets = new();
    private readonly CancellationTokenSource _cts = new();

    private IntPtr _handle = IntPtr.Zero;
    private Thread? _worker;
    private volatile bool _running;
    private long _lastPidRefresh;
    private long _lastCleanupTicks;
    private long _lastSendFailureLog;
    private long _sendFailures;
    private long _hijackedDnsQueries;
    private long _dnsServFailResponses;
    private int _statsLogged;
    private bool _disposed;

    [DllImport("dnsapi.dll")]
    private static extern int DnsFlushResolverCache();

    public WinDivertEngine(WinDivertRelay relay, WinDivertDnsResolver dnsResolver, WinDivertOptions options)
    {
        _relay = relay;
        _dnsResolver = dnsResolver;
        _options = options;
    }

    public bool IsRunning => _running;

    /// <summary>
    /// The last fatal error of the engine (the driver closed, the handle failed, ...).
    /// </summary>
    public string? LastError { get; private set; }

    public long TunneledPackets { get; private set; }

    public long BypassedPackets { get; private set; }

    public long HijackedDnsQueries => Interlocked.Read(ref _hijackedDnsQueries);

    public long DnsServFailResponses => Interlocked.Read(ref _dnsServFailResponses);

    /// <summary>
    /// Opens the WinDivert handle and starts the interception.
    /// </summary>
    public void Start()
    {
        if (_running)
        {
            return;
        }

        _relay.ProxyPort = _options.ProxyPort;
        _relay.Start();

        _handle = WinDivertSharp.WinDivert.WinDivertOpen(_filter, WinDivertLayer.Network, 0, WinDivertOpenFlags.None);
        if (_handle == IntPtr.Zero || _handle == new IntPtr(-1))
        {
            var error = Marshal.GetLastWin32Error();
            _relay.Stop();
            throw new InvalidOperationException(GetOpenErrorMessage(error));
        }

        // A larger queue avoids packet loss (and therefore stalled connections) while the
        // worker thread is busy, for example while a dns query is being resolved.
        try
        {
            WinDivertSharp.WinDivert.WinDivertSetParam(_handle, WinDivertParam.QueueLen, 8192);
            WinDivertSharp.WinDivert.WinDivertSetParam(_handle, WinDivertParam.QueueTime, 8000);
            WinDivertSharp.WinDivert.WinDivertSetParam(_handle, WinDivertParam.QueueSize, 32 * 1024 * 1024);
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }

        _running = true;
        LastError = null;
        RefreshExcludedPids();
        FlushDnsCache();
        Logging.SaveLog($"{_tag}: started, relay port {_relay.LocalRelayPort}, proxy port {_options.ProxyPort}, DNS hijack: {_options.EnableDnsHijack}.");

        // The filter only sees new connections (the SYN packet), so the connections that were
        // already established keep flowing to the real destination outside of the tunnel. They
        // are captured now, before the engine rewrites anything, and reset a moment later so
        // the applications reconnect through the tunnel.
        if (_options.ResetStaleConnections)
        {
            try
            {
                var stale = WinDivertProcessResolver.GetEstablishedTcpConnections()
                    .Where(x => x.RemotePort is 443 or 80)
                    .Where(x => !IPAddress.IsLoopback(x.RemoteIp) && !IPAddress.IsLoopback(x.LocalIp))
                    .Where(x => x.Pid != Environment.ProcessId)
                    .ToList();

                if (stale.Count > 0)
                {
                    var resetThread = new Thread(() => ResetStaleConnections(stale))
                    {
                        IsBackground = true,
                        Name = "WinDivert-StaleReset",
                    };
                    resetThread.Start();
                }
            }
            catch (Exception ex)
            {
                Logging.SaveLog(_tag, ex);
            }
        }

        _worker = new Thread(PacketLoop)
        {
            IsBackground = true,
            Name = "WinDivert-PacketLoop",
        };
        _worker.Start();
    }

    public void Stop()
    {
        _running = false;

        try
        {
            _cts.Cancel();
        }
        catch
        {
            // ignore
        }

        if (_handle != IntPtr.Zero && _handle != new IntPtr(-1))
        {
            WinDivertSharp.WinDivert.WinDivertClose(_handle);
            _handle = IntPtr.Zero;
        }

        _relay.Stop();
        _excludedPids.Clear();

        if (Interlocked.Exchange(ref _statsLogged, 1) == 0 && TunneledPackets + BypassedPackets > 0)
        {
            Logging.SaveLog($"{_tag}: stopped, tunneled {TunneledPackets}, bypassed {BypassedPackets}, hijacked DNS {HijackedDnsQueries} (SERVFAIL {DnsServFailResponses}), DoH requests {_dnsResolver.Queries} (failed {_dnsResolver.Failures}, stale {_dnsResolver.StaleAnswers}).");
        }
    }

    /// <summary>
    /// Updates the proxy port used by the forwarded connections and the DNS resolver.
    /// </summary>
    public void UpdateProxyPort(int port)
    {
        if (port > 0)
        {
            _options.ProxyPort = port;
        }
    }

    /// <summary>
    /// Flushes the Windows DNS cache so the names that were resolved before the interception
    /// (possibly through the poisoned system resolver) are resolved again through the hijack.
    /// </summary>
    private void FlushDnsCache()
    {
        try
        {
            if (DnsFlushResolverCache() != 0)
            {
                Logging.SaveLog($"{_tag}: the DNS cache was flushed, names re-resolve through the DNS hijack.");
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }
    }

    private void PacketLoop()
    {
        using var packet = new WinDivertBuffer();
        var addr = new WinDivertAddress();
        uint readLen = 0;

        while (_running)
        {
            try
            {
                if (!WinDivertSharp.WinDivert.WinDivertRecv(_handle, packet, ref addr, ref readLen))
                {
                    if (!_running)
                    {
                        break;
                    }

                    // A failed receive while the engine runs means the handle or the driver is
                    // gone. The engine stops so IsRunning reports the failure and the log shows
                    // it, instead of silently forwarding nothing.
                    var error = Marshal.GetLastWin32Error();
                    LastError = $"WinDivertRecv failed (error {error}).";
                    Logging.SaveLog($"{_tag}: the interception stopped, WinDivertRecv failed (error {error}).");
                    Stop();
                    break;
                }

                RefreshExcludedPids();

                long nowTicks = Environment.TickCount64;
                if (nowTicks - _lastCleanupTicks > 5000)
                {
                    _lastCleanupTicks = nowTicks;
                    foreach (var kvp in _bypassedPorts)
                    {
                        if (nowTicks > kvp.Value)
                        {
                            _bypassedPorts.TryRemove(kvp.Key, out _);
                        }
                    }
                }

                ProcessPacket(packet, ref addr, readLen);
            }
            catch (Exception ex)
            {
                Logging.SaveLog(_tag, ex);
            }
        }
    }

    /// <summary>
    /// Resets the tcp connections that were already established when the interception started.
    /// <para>
    /// The filter only sees new connections (the SYN packet), so a pre-existing connection
    /// keeps flowing to the real destination outside of the tunnel. That leaks the real ip and
    /// breaks the services that refuse it: Google answers 403 to its own apis (cloudcode,
    /// antigravity, gemini) when they are reached from a datacenter or a sanctioned region,
    /// even though every other site works.
    /// </para>
    /// <para>
    /// Resetting the connection makes the application open a new one, which the engine then
    /// diverts to the relay. It runs for a short window after the start only, so a later user
    /// activity is never interrupted.
    /// </para>
    /// </summary>
    private void ResetStaleConnections(List<WinDivertProcessResolver.EstablishedConnection> staleConnections)
    {
        // Give the engine a moment to be fully ready before the applications reconnect.
        try
        {
            Thread.Sleep(1500);
        }
        catch
        {
            return;
        }

        var reset = 0;
        foreach (var conn in staleConnections)
        {
            if (!_running)
            {
                return;
            }

            // The relay publishes the source port of every diverted connection, so a
            // connection that is already tunneled must never be touched.
            if (_relay.NatTable.ContainsKey(conn.LocalPort))
            {
                continue;
            }

            // the traffic of the excluded processes (the proxy core, this application) must be
            // left alone, it reaches its server directly by design
            if (_excludedPids.ContainsKey(conn.Pid))
            {
                continue;
            }

            var (name, _) = WinDivertProcessResolver.GetProcessInfo(conn.Pid);
            if (name.IsNullOrEmpty() || WinDivertProcessResolver.IsKnownProxyProcess(name))
            {
                continue;
            }

            if (WinDivertProcessResolver.ResetConnection(conn.LocalIp, conn.LocalPort, conn.RemoteIp, conn.RemotePort))
            {
                reset++;
                Logging.SaveLog($"{_tag}: reset stale connection {name} {conn.LocalIp}:{conn.LocalPort} -> {conn.RemoteIp}:{conn.RemotePort} so it reconnects through the tunnel.");
            }
        }

        if (reset > 0)
        {
            Logging.SaveLog($"{_tag}: {reset} connection(s) opened before the interception were reset, they reconnect through the tunnel.");
        }
    }

    private void ProcessPacket(WinDivertBuffer packet, ref WinDivertAddress addr, uint len)
    {
        var result = WinDivertSharp.WinDivert.WinDivertHelperParsePacket(packet, len);

        if (result.IsIPv6)
        {
            // Loopback must always pass: "localhost" resolves to ::1 first on Windows, and
            // dropping those packets makes every local connection of the machine hang (the
            // language server / ui server of Electron and Go applications, local databases, ...).
            if (addr.Loopback)
            {
                SendPacket(packet, len, ref addr);
                return;
            }

            // The engine can not tunnel ipv6 (the relay is ipv4 only), so outbound ipv6 is
            // dropped to prevent ipv6 leaks and the disclosure of the real ip address.
            //
            // Dropping alone is not enough: an application that connects over ipv6 waits for
            // the connect timeout before it falls back to ipv4. That is why AAAA queries are
            // answered with an empty answer (see BuildDnsEmptyAnswer), so applications never
            // obtain an ipv6 address in the first place.
            if (addr.Direction == WinDivertDirection.Outbound)
            {
                BypassedPackets++;
                return;
            }
            SendPacket(packet, len, ref addr);
            return;
        }

        if (!result.IsIPv4)
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        if (result.IsUdp)
        {
            HandleUdp(packet, ref addr, len, result);
            return;
        }

        if (result.IsTcp)
        {
            HandleTcp(packet, ref addr, len, result);
            return;
        }

        SendPacket(packet, len, ref addr);
    }

    #region tcp

    private void HandleTcp(WinDivertBuffer packet, ref WinDivertAddress addr, uint len, WinDivertParseResult result)
    {
        ref var ipHeader = ref result.IPv4Header;
        ref var tcpHeader = ref result.TcpHeader;

        var srcPort = (ushort)(((tcpHeader.SrcPort & 0xFF) << 8) | ((tcpHeader.SrcPort >> 8) & 0xFF));
        var dstPort = (ushort)(((tcpHeader.DstPort & 0xFF) << 8) | ((tcpHeader.DstPort >> 8) & 0xFF));

        // 1. packets sent by the local relay back to the application
        if (addr.Direction == WinDivertDirection.Outbound && srcPort == _relay.LocalRelayPort)
        {
            if (_relay.NatTable.TryGetValue(dstPort, out var original))
            {
                // restore the original destination, the application expects the answer
                // to come from the server it asked for
                ipHeader.SrcAddr = original.TargetIp;
                tcpHeader.SrcPort = (ushort)(((original.TargetPort & 0xFF) << 8) | ((original.TargetPort >> 8) & 0xFF));
                ipHeader.DstAddr = original.LocalIp;

                addr.Direction = WinDivertDirection.Inbound;
                WinDivertSharp.WinDivert.WinDivertHelperCalcChecksums(packet, len, ref addr, WinDivertChecksumHelperParam.All);
                SendPacket(packet, len, ref addr);
                TunneledPackets++;
            }
            else
            {
                SendPacket(packet, len, ref addr);
            }
            return;
        }

        if (addr.Direction != WinDivertDirection.Outbound)
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        // 2. Already marked bypassed connection: pass directly
        if (_bypassedPorts.TryGetValue(MakeBypassKey(srcPort, ipHeader.DstAddr, dstPort), out _))
        {
            if (tcpHeader.Fin == 1 || tcpHeader.Rst == 1)
            {
                _bypassedPorts.TryRemove(MakeBypassKey(srcPort, ipHeader.DstAddr, dstPort), out _);
            }
            SendPacket(packet, len, ref addr);
            BypassedPackets++;
            return;
        }

        // 3. a new connection, the handshake is redirected to the local relay
        if (tcpHeader.Syn == 1 && tcpHeader.Ack == 0)
        {
            var targetIp = ipHeader.DstAddr;
            var localIp = ipHeader.SrcAddr;

            if (ShouldBypass(targetIp, srcPort, false))
            {
                // Remember the bypassed connection so its following packets are not diverted.
                // The key must include the destination: a source port is reused for different
                // destinations, and keying by port alone would send a new connection of the same
                // port to the old destination (a direct leak of the real ip address).
                _bypassedPorts[MakeBypassKey(srcPort, targetIp, dstPort)] = Environment.TickCount64 + 60_000;
                BypassedPackets++;
                SendPacket(packet, len, ref addr);
                return;
            }

            _relay.NatTable[srcPort] = new OriginalDestination(targetIp, dstPort, localIp, _relay.NextToken());

            // the packet is injected as inbound, so the operating system answers the
            // application on behalf of the original destination
            ipHeader.DstAddr = localIp;
            tcpHeader.DstPort = (ushort)(((_relay.LocalRelayPort & 0xFF) << 8) | ((_relay.LocalRelayPort >> 8) & 0xFF));
            ipHeader.SrcAddr = targetIp;

            addr.Direction = WinDivertDirection.Inbound;
            WinDivertSharp.WinDivert.WinDivertHelperCalcChecksums(packet, len, ref addr, WinDivertChecksumHelperParam.All);
            SendPacket(packet, len, ref addr);
            TunneledPackets++;
            return;
        }

        // 3. traffic of an already diverted connection, it is sent to the local relay
        if (_relay.NatTable.TryGetValue(srcPort, out var current))
        {
            ipHeader.DstAddr = current.LocalIp;
            tcpHeader.DstPort = (ushort)(((_relay.LocalRelayPort & 0xFF) << 8) | ((_relay.LocalRelayPort >> 8) & 0xFF));
            ipHeader.SrcAddr = current.TargetIp;

            addr.Direction = WinDivertDirection.Inbound;
            WinDivertSharp.WinDivert.WinDivertHelperCalcChecksums(packet, len, ref addr, WinDivertChecksumHelperParam.All);
            SendPacket(packet, len, ref addr);
            TunneledPackets++;
            return;
        }

        // 4. An outbound packet of an already running connection that has no nat entry.
        // It must NEVER be forwarded as is: this is exactly the leak that makes the real ip
        // address reach the remote service (Google then answers "User location is not
        // supported" or 403, and the connection drops in the middle of a stream).
        //
        // The flow is remembered as stale, so the following packets are dropped without
        // another process lookup.
        if (_staleResets.ContainsKey(srcPort))
        {
            if (tcpHeader.Fin == 1 || tcpHeader.Rst == 1)
            {
                _ = Task.Delay(2000).ContinueWith(t => _staleResets.TryRemove(srcPort, out _));
            }
            BypassedPackets++;
            return;
        }

        // a connection to the local network (a nas, a printer, a router) is not tunneled at all,
        // so it must keep working even when it was opened before the interception started
        if (_options.BypassLan && IsPrivateAddress(ipHeader.DstAddr))
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        // The traffic of the excluded processes (the proxy core, this application) is the only
        // traffic that may leave outside of the tunnel.
        if (IsExcludedTraffic(srcPort))
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        // Dropping the packet keeps the real ip private. The connection is reset once so the
        // application reconnects immediately, and that new connection is diverted normally.
        DropStaleConnection(ipHeader.SrcAddr, srcPort, ipHeader.DstAddr, dstPort);
        BypassedPackets++;
    }

    /// <summary>
    /// Checks whether the given local tcp port belongs to a process that must never be diverted.
    /// </summary>
    private bool IsExcludedTraffic(ushort srcPort)
    {
        var pid = WinDivertProcessResolver.GetPidForLocalPort(srcPort);
        if (pid <= 0)
        {
            return false;
        }

        if (pid == Environment.ProcessId || _excludedPids.ContainsKey(pid))
        {
            return true;
        }

        // the listener of the proxy is excluded by pid, its helpers (aether, lyrebird,
        // psiphon, lantern, ...) are only recognizable by name; remember them so the
        // following packets skip the process lookup
        var (name, _) = WinDivertProcessResolver.GetProcessInfo(pid);
        if (WinDivertProcessResolver.IsKnownProxyProcess(name))
        {
            _excludedPids[pid] = true;
            return true;
        }

        return false;
    }

    /// <summary>
    /// Resets a connection that has no nat entry, so the application reconnects right away.
    /// <para>
    /// It is throttled per port: the reset is attempted once and the following packets of the
    /// same connection are simply dropped.
    /// </para>
    /// </summary>
    private void DropStaleConnection(IPAddress localIp, ushort srcPort, IPAddress targetIp, ushort dstPort)
    {
        if (!_staleResets.TryAdd(srcPort, Environment.TickCount64))
        {
            return;
        }

        _ = Task.Run(() =>
        {
            try
            {
                if (WinDivertProcessResolver.ResetConnection(localIp, srcPort, targetIp, dstPort))
                {
                    Logging.SaveLog($"{_tag}: a connection without tunnel mapping was reset ({localIp}:{srcPort} -> {targetIp}:{dstPort}), it reconnects through the tunnel.");
                }
            }
            catch (Exception ex)
            {
                Logging.SaveLog(_tag, ex);
            }
            finally
            {
                // allow another attempt later if the port is reused
                _ = Task.Delay(10_000).ContinueWith(t => _staleResets.TryRemove(srcPort, out _));
            }
        });
    }

    /// <summary>
    /// Builds the key of the bypass cache.
    /// <para>
    /// The source port alone is not unique: windows reuses it for a different destination, and
    /// keying by port only would mark the new connection as bypassed, leaking it directly.
    /// </para>
    /// </summary>
    private static long MakeBypassKey(ushort srcPort, IPAddress dstIp, ushort dstPort)
    {
        var bytes = dstIp.GetAddressBytes();
        // fold the 4 address bytes into a 30 bit value, then add port and destination port
        var addr = ((long)bytes[0] << 22) | ((long)bytes[1] << 14) | ((long)bytes[2] << 6) | ((long)bytes[3] >> 2);
        return (addr << 34) ^ ((long)srcPort << 18) ^ dstPort;
    }

    #endregion tcp

    #region udp

    private void HandleUdp(WinDivertBuffer packet, ref WinDivertAddress addr, uint len, WinDivertParseResult result)
    {
        if (addr.Direction != WinDivertDirection.Outbound)
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        ref var ipHeader = ref result.IPv4Header;
        ref var udpHeader = ref result.UdpHeader;

        var srcPort = (ushort)(((udpHeader.SrcPort & 0xFF) << 8) | ((udpHeader.SrcPort >> 8) & 0xFF));
        var dstPort = (ushort)(((udpHeader.DstPort & 0xFF) << 8) | ((udpHeader.DstPort >> 8) & 0xFF));

        // 1. WebRTC STUN Leak prevention (ports 3478, 19302):
        // Drop outbound STUN requests so WebRTC in browsers cannot discover the real Iranian public IP.
        if (dstPort == 3478 || dstPort == 19302)
        {
            BypassedPackets++;
            return;
        }

        // DNS over QUIC can not be tunneled here; dropping it makes the client fall back to
        // DoT/DoH over tcp, which is tunneled, instead of leaving the tunnel directly.
        if (dstPort == _portDnsOverQuic)
        {
            BypassedPackets++;
            return;
        }

        if (dstPort != 53 && dstPort != 443)
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        // 2. DNS Hijack (port 53):
        // MUST be checked BEFORE ShouldBypass because 99.9% of home routers configure DNS as
        // a private LAN IP (192.168.1.1). If we checked ShouldBypass first, all DNS queries
        // to the router would be bypassed directly to TIC (Iran), causing severe DNS leaks!
        if (dstPort == 53 && _options.EnableDnsHijack)
        {
            var pid = WinDivertProcessResolver.GetPidForLocalUdpPort(srcPort);
            if (pid > 0 && (_excludedPids.ContainsKey(pid) || pid == Environment.ProcessId))
            {
                SendPacket(packet, len, ref addr);
                return;
            }

            HandleDnsQuery(packet, ref addr, len, result, srcPort);
            return;
        }

        if (ShouldBypass(ipHeader.DstAddr, srcPort, true))
        {
            BypassedPackets++;
            SendPacket(packet, len, ref addr);
            return;
        }

        if (dstPort == 443 && _options.DropQuic)
        {
            // quic/http3 can not be tunneled here, dropping it makes the applications
            // fall back to tcp
            BypassedPackets++;
            return;
        }

        SendPacket(packet, len, ref addr);
    }

    private void HandleDnsQuery(WinDivertBuffer packet, ref WinDivertAddress addr, uint len, WinDivertParseResult result, ushort clientPort)
    {
        ref var ipHeader = ref result.IPv4Header;

        var clientIp = ipHeader.SrcAddr;
        var serverIp = ipHeader.DstAddr;

        var payload = result.PacketPayload;
        if (payload.Length == 0)
        {
            SendPacket(packet, len, ref addr);
            return;
        }

        var query = payload.ToArray();
        var originalAddr = addr;
        Interlocked.Increment(ref _hijackedDnsQueries);

        // the engine can not tunnel ipv6, so an AAAA answer would only give the application an
        // address it can never reach and every connection attempt would stall until the tcp
        // timeout expires. Answering with an empty AAAA answer makes the client fall back to
        // ipv4 (which is tunneled) immediately.
        if (_options.BlockAaaa)
        {
            var qType = GetDnsQuestionType(query);
            if (qType == _dnsTypeAaaa)
            {
                var empty = BuildDnsEmptyAnswer(query);
                if (empty != null)
                {
                    InjectDnsResponse(serverIp, clientIp, clientPort, empty, originalAddr);
                    return;
                }
            }
        }

        // the query is dropped here, it is answered by the encrypted DoH resolver
        _ = Task.Run(async () =>
        {
            try
            {
                var response = await _dnsResolver.ResolveAsync(query, _options.ProxyPort, _cts.Token);
                if (response != null)
                {
                    InjectDnsResponse(serverIp, clientIp, clientPort, response, originalAddr);
                }
                else
                {
                    // NEVER leak to the unencrypted system resolver (TIC - Iran) on failure!
                    // Return a DNS Server Failure (SERVFAIL) response so the client retries via proxy.
                    Interlocked.Increment(ref _dnsServFailResponses);
                    var servFail = BuildDnsServFailResponse(query);
                    if (servFail != null)
                    {
                        InjectDnsResponse(serverIp, clientIp, clientPort, servFail, originalAddr);
                    }
                }
            }
            catch (Exception ex)
            {
                Logging.SaveLog(_tag, ex);
            }
        });
    }

    /// <summary>
    /// Returns the qtype of the first question of the dns query, or -1 when it can not be parsed.
    /// </summary>
    private static int GetDnsQuestionType(byte[] query)
    {
        var offset = 12;
        var end = ReadDnsQuestion(query, offset, out var qType);
        return end < 0 ? -1 : qType;
    }

    /// <summary>
    /// Walks over the (possibly compressed) dns name and returns the offset right after the
    /// question section.
    /// </summary>
    private static int ReadDnsQuestion(byte[] query, int offset, out int qType)
    {
        qType = -1;

        while (offset >= 0 && offset < query.Length)
        {
            var length = query[offset];
            if (length == 0)
            {
                offset++;
                break;
            }

            // compression pointer, it ends the name
            if ((length & 0xC0) == 0xC0)
            {
                offset += 2;
                break;
            }

            offset += length + 1;
        }

        // qtype (2 bytes) + qclass (2 bytes)
        if (offset < 0 || offset + 4 > query.Length)
        {
            return -1;
        }

        qType = (query[offset] << 8) | query[offset + 1];
        return offset + 4;
    }

    /// <summary>
    /// Builds a dns response with NOERROR and no answer record.
    /// <para>
    /// It is used for AAAA queries: the tunnel is ipv4 only, so an ipv6 address would be
    /// unreachable and every connection would stall until it times out. An empty answer tells
    /// the client that the name has no ipv6 record, which is a normal and expected reply.
    /// </para>
    /// </summary>
    private static byte[]? BuildDnsEmptyAnswer(byte[] query)
    {
        if (query.Length < 12)
        {
            return null;
        }

        var questionEnd = ReadDnsQuestion(query, 12, out _);
        if (questionEnd < 0 || questionEnd > query.Length)
        {
            return null;
        }

        var response = new byte[questionEnd];
        Buffer.BlockCopy(query, 0, response, 0, questionEnd);

        response[2] = (byte)(0x81 | (query[2] & 0x01)); // QR=1, RD kept from the query
        response[3] = 0x80;                             // RA=1, RCODE=0 (NoError)
        response[6] = 0;                                // ANCOUNT = 0
        response[7] = 0;
        response[8] = 0;                                // NSCOUNT = 0
        response[9] = 0;
        response[10] = 0;                               // ARCOUNT = 0
        response[11] = 0;

        return response;
    }

    private static byte[]? BuildDnsServFailResponse(byte[] query)
    {
        if (query.Length < 12)
        {
            return null;
        }

        // A response with QDCOUNT > 0 but no question section is malformed and several
        // clients discard it; the question is copied so the answer is accepted.
        var questionEnd = ReadDnsQuestion(query, 12, out _);
        if (questionEnd < 0 || questionEnd > query.Length)
        {
            return null;
        }

        var response = new byte[questionEnd];
        Buffer.BlockCopy(query, 0, response, 0, questionEnd);

        response[2] = (byte)(0x81 | (query[2] & 0x01)); // QR=1, RD kept from the query
        response[3] = 0x82;                             // RA=1, RCODE=2 (Server Failure)
        response[6] = 0;                                // ANCOUNT = 0
        response[7] = 0;
        response[8] = 0;                                // NSCOUNT = 0
        response[9] = 0;
        response[10] = 0;                               // ARCOUNT = 0
        response[11] = 0;
        return response;
    }

    /// <summary>
    /// Builds an ipv4/udp packet and injects it as inbound traffic.
    /// </summary>
    private static byte[] BuildUdpPacket(IPAddress srcIp, IPAddress dstIp, ushort srcPort, ushort dstPort, byte[] payload)
    {
        var udpLength = 8 + payload.Length;
        var totalLength = 20 + udpLength;
        var buffer = new byte[totalLength];

        // ipv4 header
        buffer[0] = 0x45;
        buffer[1] = 0x00;
        buffer[2] = (byte)(totalLength >> 8);
        buffer[3] = (byte)(totalLength & 0xFF);
        buffer[4] = 0x00;
        buffer[5] = 0x00;
        buffer[6] = 0x00;
        buffer[7] = 0x00;
        buffer[8] = 64;
        buffer[9] = 17;
        buffer[10] = 0x00;
        buffer[11] = 0x00;

        var src = srcIp.GetAddressBytes();
        var dst = dstIp.GetAddressBytes();
        Buffer.BlockCopy(src, 0, buffer, 12, 4);
        Buffer.BlockCopy(dst, 0, buffer, 16, 4);

        var checksum = ComputeChecksum(buffer, 0, 20);
        buffer[10] = (byte)(checksum >> 8);
        buffer[11] = (byte)(checksum & 0xFF);

        // udp header
        buffer[20] = (byte)(srcPort >> 8);
        buffer[21] = (byte)(srcPort & 0xFF);
        buffer[22] = (byte)(dstPort >> 8);
        buffer[23] = (byte)(dstPort & 0xFF);
        buffer[24] = (byte)(udpLength >> 8);
        buffer[25] = (byte)(udpLength & 0xFF);
        buffer[26] = 0x00;
        buffer[27] = 0x00;

        Buffer.BlockCopy(payload, 0, buffer, 28, payload.Length);

        return buffer;
    }

    private static int ComputeChecksum(byte[] buffer, int offset, int length)
    {
        var sum = 0;
        for (var i = 0; i < length; i += 2)
        {
            sum += (buffer[offset + i] << 8) + buffer[offset + i + 1];
        }
        while ((sum >> 16) != 0)
        {
            sum = (sum & 0xFFFF) + (sum >> 16);
        }
        return ~sum & 0xFFFF;
    }

    #endregion udp

    #region bypass

    /// <summary>
    /// Decides if the given traffic must not be diverted.
    /// </summary>
    private bool ShouldBypass(IPAddress dstIp, ushort srcPort, bool isUdp)
    {
        if (IPAddress.IsLoopback(dstIp))
        {
            return true;
        }

        if (_options.BypassLan && IsPrivateAddress(dstIp))
        {
            return true;
        }

        var pid = isUdp
            ? WinDivertProcessResolver.GetPidForLocalUdpPort(srcPort)
            : WinDivertProcessResolver.GetPidForLocalPort(srcPort);

        if (pid <= 0 && !isUdp)
        {
            // the connection may not be listed yet when the very first packet is seen
            Thread.Sleep(1);
            pid = WinDivertProcessResolver.GetPidForLocalPort(srcPort);
        }

        if (pid <= 0)
        {
            return false;
        }

        // this application (the relay, the dns resolver, ...)
        if (pid == Environment.ProcessId)
        {
            return true;
        }

        // the proxy core, it has to reach the server without being diverted
        if (_excludedPids.ContainsKey(pid))
        {
            return true;
        }

        var (name, _) = WinDivertProcessResolver.GetProcessInfo(pid);
        if (WinDivertProcessResolver.IsKnownProxyProcess(name))
        {
            _excludedPids[pid] = true;
            return true;
        }

        return false;
    }

    private static bool IsPrivateAddress(IPAddress ip)
    {
        if (ip.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            return false;
        }

        var bytes = ip.GetAddressBytes();

        // 10.10.34.0/24 is Iran's national DNS poisoning redirection sinkhole IP range!
        // We must NEVER treat it as local LAN, it MUST be intercepted and tunneled.
        if (bytes[0] == 10 && bytes[1] == 10 && bytes[2] == 34)
        {
            return false;
        }

        // 100.64.0.0/10 is the carrier-grade NAT range (Tailscale, WARP, some ISPs); it is not
        // a public destination, so it must keep working outside of the tunnel.
        if (bytes[0] == 100 && bytes[1] >= 64 && bytes[1] < 128)
        {
            return true;
        }

        return bytes[0] switch
        {
            10 => true,
            127 => true,
            172 => bytes[1] >= 16 && bytes[1] < 32,
            192 => bytes[1] == 168,
            169 => bytes[1] == 254,
            0 => true,
            _ => false,
        };
    }

    /// <summary>
    /// Refreshes the list of processes that must not be diverted (the running core).
    /// </summary>
    private void RefreshExcludedPids()
    {
        var now = Environment.TickCount64;
        if (now - _lastPidRefresh < 3000)
        {
            return;
        }
        _lastPidRefresh = now;

        try
        {
            if (_options.ProxyPort > 0)
            {
                var pid = WinDivertProcessResolver.GetPidListeningOnPort(_options.ProxyPort);
                if (pid > 0)
                {
                    _excludedPids[pid] = true;
                    var parentPid = WinDivertProcessResolver.GetParentProcessId(pid);
                    if (parentPid > 0)
                    {
                        _excludedPids[parentPid] = true;
                    }
                }
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }
    }

    #endregion bypass

    #region send

    private void SendPacket(WinDivertBuffer packet, uint len, ref WinDivertAddress addr)
    {
        try
        {
            if (!WinDivertSharp.WinDivert.WinDivertSend(_handle, packet, len, ref addr))
            {
                LogSendFailure();
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }
    }

    private void InjectPacket(byte[] bytes, WinDivertAddress addr)
    {
        if (!_running)
        {
            return;
        }

        try
        {
            using var buffer = new WinDivertBuffer(bytes);
            WinDivertSharp.WinDivert.WinDivertHelperCalcChecksums(buffer, (uint)bytes.Length, ref addr, WinDivertChecksumHelperParam.All);
            if (!WinDivertSharp.WinDivert.WinDivertSend(_handle, buffer, (uint)bytes.Length, ref addr))
            {
                LogSendFailure();
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog(_tag, ex);
        }
    }

    /// <summary>
    /// Reports a failed injection; throttled so a broken handle does not flood the log.
    /// </summary>
    private void LogSendFailure()
    {
        var total = Interlocked.Increment(ref _sendFailures);
        var now = Environment.TickCount64;
        if (total == 1 || now - Interlocked.Read(ref _lastSendFailureLog) > 10_000)
        {
            Interlocked.Exchange(ref _lastSendFailureLog, now);
            Logging.SaveLog($"{_tag}: WinDivertSend failed (error {Marshal.GetLastWin32Error()}), {total} packet(s) could not be written back.");
        }
    }

    private void InjectDnsResponse(IPAddress serverIp, IPAddress clientIp, ushort clientPort, byte[] dnsPayload, WinDivertAddress originalAddr)
    {
        var bytes = BuildUdpPacket(serverIp, clientIp, 53, clientPort, dnsPayload);
        var addr = originalAddr;
        addr.Direction = WinDivertDirection.Inbound;
        InjectPacket(bytes, addr);
    }

    #endregion send

    private static string GetOpenErrorMessage(int error)
    {
        return error switch
        {
            5 => "Access denied, the application must run as administrator.",
            2 => "The WinDivert driver files (WinDivert.dll / WinDivert64.sys) were not found in the application folder.",
            577 => "The digital signature of the WinDivert driver was not accepted by Windows.",
            _ => $"Could not open the WinDivert handle, error code: {error}",
        };
    }

    public void Dispose()
    {
        if (_disposed)
        {
            return;
        }

        Stop();
        try
        {
            _cts.Dispose();
        }
        catch
        {
            // ignore
        }
        _disposed = true;
        GC.SuppressFinalize(this);
    }
}
