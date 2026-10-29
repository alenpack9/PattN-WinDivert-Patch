namespace ServiceLib.Services.WinDivert;

/// <summary>
/// Resolves the process that owns a local TCP/UDP port.
/// Used by the WinDivert engine to detect traffic that must not be intercepted
/// (the proxy core itself, this application, ...).
/// </summary>
public static class WinDivertProcessResolver
{
    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedTcpTable(IntPtr pTcpTable, ref int pdwSize, bool bOrder, int ulAf, int tableClass, uint reserved = 0);

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint GetExtendedUdpTable(IntPtr pUdpTable, ref int pdwSize, bool bOrder, int ulAf, int tableClass, uint reserved = 0);

    [DllImport("iphlpapi.dll", SetLastError = true)]
    private static extern uint SetTcpEntry(IntPtr pTcprow);

    private const uint MIB_TCP_STATE_DELETE_TCB = 12;

    /// <summary>
    /// The row used by SetTcpEntry to reset a connection.
    /// </summary>
    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_TCPROW
    {
        public uint dwState;
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwRemoteAddr;
        public uint dwRemotePort;
    }

    /// <summary>
    /// Forcibly resets an established tcp connection of the machine.
    /// <para>
    /// A connection that was established before the interception started is not diverted by
    /// the filter, so it keeps talking to the real destination and leaks the real ip. Resetting
    /// it makes the application reconnect, and that new connection is diverted to the relay.
    /// </para>
    /// </summary>
    /// <returns>True when the connection was reset.</returns>
    public static bool ResetConnection(IPAddress localIp, ushort localPort, IPAddress remoteIp, ushort remotePort)
    {
        if (!Utils.IsWindows() || localIp.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork
            || remoteIp.AddressFamily != System.Net.Sockets.AddressFamily.InterNetwork)
        {
            return false;
        }

        try
        {
            var row = new MIB_TCPROW
            {
                dwState = MIB_TCP_STATE_DELETE_TCB,
                dwLocalAddr = BitConverter.ToUInt32(localIp.GetAddressBytes(), 0),
                dwLocalPort = ToNetworkPort(localPort),
                dwRemoteAddr = BitConverter.ToUInt32(remoteIp.GetAddressBytes(), 0),
                dwRemotePort = ToNetworkPort(remotePort),
            };

            var ptr = Marshal.AllocHGlobal(Marshal.SizeOf<MIB_TCPROW>());
            try
            {
                Marshal.StructureToPtr(row, ptr, false);
                return SetTcpEntry(ptr) == 0;
            }
            finally
            {
                Marshal.FreeHGlobal(ptr);
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertProcessResolver", ex);
            return false;
        }
    }

    private static uint ToNetworkPort(ushort port)
    {
        // the port is stored in network byte order inside the low 16 bits
        return (uint)(((port & 0xFF) << 8) | ((port >> 8) & 0xFF));
    }

    private const int AF_INET = 2;
    private const int AF_INET6 = 23;
    private const int TCP_TABLE_OWNER_PID_ALL = 5;
    private const int UDP_TABLE_OWNER_PID = 1;

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_TCPROW_OWNER_PID
    {
        public uint dwState;
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwRemoteAddr;
        public uint dwRemotePort;
        public uint dwOwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_TCP6ROW_OWNER_PID
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] ucLocalAddr;
        public uint dwLocalScopeId;
        public uint dwLocalPort;
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] ucRemoteAddr;
        public uint dwRemoteScopeId;
        public uint dwRemotePort;
        public uint dwState;
        public uint dwOwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_UDPROW_OWNER_PID
    {
        public uint dwLocalAddr;
        public uint dwLocalPort;
        public uint dwOwningPid;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MIB_UDP6ROW_OWNER_PID
    {
        [MarshalAs(UnmanagedType.ByValArray, SizeConst = 16)]
        public byte[] ucLocalAddr;
        public uint dwLocalScopeId;
        public uint dwLocalPort;
        public uint dwOwningPid;
    }

    private static readonly ConcurrentDictionary<int, (string? Name, string? Path, long ExpireTicks)> _pidCache = new();

    /// <summary>
    /// An established tcp connection of the machine.
    /// </summary>
    /// <param name="LocalIp">Source address used by the application.</param>
    /// <param name="LocalPort">Source port used by the application.</param>
    /// <param name="RemoteIp">Destination address.</param>
    /// <param name="RemotePort">Destination port.</param>
    /// <param name="Pid">Process owning the connection.</param>
    public record EstablishedConnection(IPAddress LocalIp, ushort LocalPort, IPAddress RemoteIp, ushort RemotePort, int Pid);

    private const uint MIB_TCP_STATE_ESTAB = 5;

    /// <summary>
    /// Returns all established ipv4 tcp connections of the machine.
    /// <para>
    /// It is used at startup: only new connections (the SYN packet) are diverted, so a
    /// connection that was already established before the interception started keeps talking
    /// to the real destination and leaks the real ip address.
    /// </para>
    /// </summary>
    public static List<EstablishedConnection> GetEstablishedTcpConnections()
    {
        var list = new List<EstablishedConnection>();
        if (!Utils.IsWindows())
        {
            return list;
        }

        var bufferSize = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref bufferSize, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0);
        if (bufferSize <= 0)
        {
            return list;
        }

        var tablePtr = Marshal.AllocHGlobal(bufferSize);
        try
        {
            if (GetExtendedTcpTable(tablePtr, ref bufferSize, false, AF_INET, TCP_TABLE_OWNER_PID_ALL, 0) != 0)
            {
                return list;
            }

            var rowCount = Marshal.ReadInt32(tablePtr);
            var rowPtr = IntPtr.Add(tablePtr, 4);
            var rowSize = Marshal.SizeOf<MIB_TCPROW_OWNER_PID>();

            for (var i = 0; i < rowCount; i++)
            {
                var row = Marshal.PtrToStructure<MIB_TCPROW_OWNER_PID>(rowPtr);
                rowPtr = IntPtr.Add(rowPtr, rowSize);

                // dwLocalAddr / dwRemoteAddr are stored in network byte order
                if (row.dwState != MIB_TCP_STATE_ESTAB || row.dwRemoteAddr == 0 || row.dwOwningPid == 0)
                {
                    continue;
                }

                var localIp = new IPAddress(row.dwLocalAddr);
                var remoteIp = new IPAddress(row.dwRemoteAddr);
                var localPort = (ushort)(((row.dwLocalPort & 0xFF) << 8) | ((row.dwLocalPort >> 8) & 0xFF));
                var remotePort = (ushort)(((row.dwRemotePort & 0xFF) << 8) | ((row.dwRemotePort >> 8) & 0xFF));

                if (localPort == 0 || remotePort == 0)
                {
                    continue;
                }

                list.Add(new EstablishedConnection(localIp, localPort, remoteIp, remotePort, (int)row.dwOwningPid));
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertProcessResolver", ex);
        }
        finally
        {
            Marshal.FreeHGlobal(tablePtr);
        }

        return list;
    }

    /// <summary>
    /// Known proxy cores / tunnels. Their traffic must never be diverted,
    /// otherwise the proxy would connect to itself.
    /// </summary>
    private static readonly HashSet<string> _knownProxyProcesses = new(StringComparer.OrdinalIgnoreCase)
    {
        "xray", "p-xray-p", "v2ray", "wv2ray", "v2rayn", "pattn", "v2raya", "v2ray-core",
        "sing-box", "clash", "clash-meta", "clash-verge", "clash-verge-service", "mihomo",
        "nekobox", "nekoray", "hiddify", "hiddify-core", "shadowsocks", "ss-local", "outline",
        "trojan", "trojan-go", "naive", "naiveproxy", "warp-svc", "wireguard", "openvpn",
        // the tunnels shipped in the bin folder / used by the app: their traffic must reach
        // their own servers directly and never be forwarded to the local proxy again
        "aether", "aether-core", "lyrebird", "psiphon", "psiphon-tunnel-core",
        "tun2socks", "lantern", "lanternsvc"
    };

    /// <summary>
    /// Finds the process id owning the given local TCP port.
    /// </summary>
    public static int GetPidForLocalPort(ushort localPort)
    {
        if (!Utils.IsWindows())
        {
            return -1;
        }

        var pid = GetPidOnPortInternal(localPort, AF_INET);
        return pid > 0 ? pid : GetPidOnPortInternal(localPort, AF_INET6);
    }

    /// <summary>
    /// Finds the process id listening on the given TCP port.
    /// </summary>
    public static int GetPidListeningOnPort(int targetPort)
    {
        if (targetPort <= 0 || targetPort > 65535)
        {
            return -1;
        }

        return GetPidForLocalPort((ushort)targetPort);
    }

    /// <summary>
    /// Finds the process id owning the given local UDP port.
    /// </summary>
    public static int GetPidForLocalUdpPort(ushort localPort)
    {
        if (!Utils.IsWindows())
        {
            return -1;
        }

        var pid = GetUdpPidOnPortInternal(localPort, AF_INET);
        return pid > 0 ? pid : GetUdpPidOnPortInternal(localPort, AF_INET6);
    }

    /// <summary>
    /// Checks whether the given process name belongs to a known proxy core or tunnel client.
    /// </summary>
    public static bool IsKnownProxyProcess(string? name)
    {
        if (name.IsNullOrEmpty())
        {
            return false;
        }

        var clean = name.Trim();
        if (clean.EndsWith(".exe", StringComparison.OrdinalIgnoreCase))
        {
            clean = clean[..^4];
        }

        if (_knownProxyProcesses.Contains(clean))
        {
            return true;
        }

        var lower = clean.ToLowerInvariant();
        return lower.Contains("xray")
            || lower.Contains("v2ray")
            || lower.Contains("pattn")
            || lower.Contains("sing-box")
            || lower.Contains("clash")
            || lower.Contains("mihomo")
            || lower.Contains("nekobox")
            || lower.Contains("hiddify")
            || lower.Contains("aether")
            || lower.Contains("lyrebird")
            || lower.Contains("psiphon")
            || lower.Contains("lantern")
            || lower.Contains("tun2socks");
    }

    /// <summary>
    /// Returns the process name and path for the given pid (cached for a short while).
    /// </summary>
    public static (string? Name, string? Path) GetProcessInfo(int pid)
    {
        if (pid <= 0)
        {
            return (null, null);
        }

        var now = Environment.TickCount64;
        if (_pidCache.TryGetValue(pid, out var cached) && now < cached.ExpireTicks)
        {
            return (cached.Name, cached.Path);
        }

        try
        {
            using var proc = Process.GetProcessById(pid);
            var name = proc.ProcessName;
            string? path = null;
            try
            {
                path = proc.MainModule?.FileName;
            }
            catch
            {
                // access denied for protected processes
            }

            _pidCache[pid] = (name, path, now + 30_000);
            return (name, path);
        }
        catch
        {
            return (null, null);
        }
    }

    private static int GetPidOnPortInternal(ushort targetPort, int af)
    {
        var bufferSize = 0;
        GetExtendedTcpTable(IntPtr.Zero, ref bufferSize, false, af, TCP_TABLE_OWNER_PID_ALL, 0);
        if (bufferSize <= 0)
        {
            return -1;
        }

        var tablePtr = Marshal.AllocHGlobal(bufferSize);
        try
        {
            if (GetExtendedTcpTable(tablePtr, ref bufferSize, false, af, TCP_TABLE_OWNER_PID_ALL, 0) != 0)
            {
                return -1;
            }

            var rowCount = Marshal.ReadInt32(tablePtr);
            var rowPtr = IntPtr.Add(tablePtr, 4);

            if (af == AF_INET)
            {
                var rowSize = Marshal.SizeOf<MIB_TCPROW_OWNER_PID>();
                for (var i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<MIB_TCPROW_OWNER_PID>(rowPtr);
                    var port = (ushort)(((row.dwLocalPort & 0xFF) << 8) | ((row.dwLocalPort >> 8) & 0xFF));
                    if (port == targetPort)
                    {
                        return (int)row.dwOwningPid;
                    }
                    rowPtr = IntPtr.Add(rowPtr, rowSize);
                }
            }
            else
            {
                var rowSize = Marshal.SizeOf<MIB_TCP6ROW_OWNER_PID>();
                for (var i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<MIB_TCP6ROW_OWNER_PID>(rowPtr);
                    var port = (ushort)(((row.dwLocalPort & 0xFF) << 8) | ((row.dwLocalPort >> 8) & 0xFF));
                    if (port == targetPort)
                    {
                        return (int)row.dwOwningPid;
                    }
                    rowPtr = IntPtr.Add(rowPtr, rowSize);
                }
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertProcessResolver", ex);
        }
        finally
        {
            Marshal.FreeHGlobal(tablePtr);
        }

        return -1;
    }

    private static int GetUdpPidOnPortInternal(ushort targetPort, int af)
    {
        var bufferSize = 0;
        GetExtendedUdpTable(IntPtr.Zero, ref bufferSize, false, af, UDP_TABLE_OWNER_PID, 0);
        if (bufferSize <= 0)
        {
            return -1;
        }

        var tablePtr = Marshal.AllocHGlobal(bufferSize);
        try
        {
            if (GetExtendedUdpTable(tablePtr, ref bufferSize, false, af, UDP_TABLE_OWNER_PID, 0) != 0)
            {
                return -1;
            }

            var rowCount = Marshal.ReadInt32(tablePtr);
            var rowPtr = IntPtr.Add(tablePtr, 4);

            if (af == AF_INET)
            {
                var rowSize = Marshal.SizeOf<MIB_UDPROW_OWNER_PID>();
                for (var i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<MIB_UDPROW_OWNER_PID>(rowPtr);
                    var port = (ushort)(((row.dwLocalPort & 0xFF) << 8) | ((row.dwLocalPort >> 8) & 0xFF));
                    if (port == targetPort)
                    {
                        return (int)row.dwOwningPid;
                    }
                    rowPtr = IntPtr.Add(rowPtr, rowSize);
                }
            }
            else
            {
                var rowSize = Marshal.SizeOf<MIB_UDP6ROW_OWNER_PID>();
                for (var i = 0; i < rowCount; i++)
                {
                    var row = Marshal.PtrToStructure<MIB_UDP6ROW_OWNER_PID>(rowPtr);
                    var port = (ushort)(((row.dwLocalPort & 0xFF) << 8) | ((row.dwLocalPort >> 8) & 0xFF));
                    if (port == targetPort)
                    {
                        return (int)row.dwOwningPid;
                    }
                    rowPtr = IntPtr.Add(rowPtr, rowSize);
                }
            }
        }
        catch (Exception ex)
        {
            Logging.SaveLog("WinDivertProcessResolver", ex);
        }
        finally
        {
            Marshal.FreeHGlobal(tablePtr);
        }

        return -1;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct PROCESS_BASIC_INFORMATION
    {
        public IntPtr ExitStatus;
        public IntPtr PebBaseAddress;
        public IntPtr AffinityMask;
        public IntPtr BasePriority;
        public UIntPtr UniqueProcessId;
        public IntPtr InheritedFromUniqueProcessId;
    }

    [DllImport("ntdll.dll")]
    private static extern int NtQueryInformationProcess(
        IntPtr processHandle,
        int processInformationClass,
        ref PROCESS_BASIC_INFORMATION processInformation,
        int processInformationLength,
        out int returnLength);

    public static int GetParentProcessId(int pid)
    {
        if (pid <= 0) return -1;
        try
        {
            using var proc = Process.GetProcessById(pid);
            var pbi = new PROCESS_BASIC_INFORMATION();
            int returnLength;
            int status = NtQueryInformationProcess(proc.Handle, 0, ref pbi, Marshal.SizeOf(pbi), out returnLength);
            if (status == 0)
            {
                return pbi.InheritedFromUniqueProcessId.ToInt32();
            }
        }
        catch
        {
        }
        return -1;
    }
}
