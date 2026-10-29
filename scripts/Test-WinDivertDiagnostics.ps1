<#
.SYNOPSIS
    Diagnoses the PattN WinDivert tunnel: DNS interception, tunnel coverage per
    process, and the egress IP seen by remote services (rotation / datacenter).

.DESCRIPTION
    Run while PattN is connected (WinDivert enabled). Checks:

      1. Environment         - admin rights, WinDivert driver, core and relay
      2. Config              - DNS hijack, DoH endpoint, core direct DNS
      3. Tunnel coverage     - every established TCP connection, relayed or not,
                               with the owning process (leaks are listed)
      4. Egress IP           - samples the public IP several times: detects an
                               exit that rotates per connection or is hosted in a
                               datacenter (the reason Google returns
                               "User location is not supported")
      5. DNS                 - A/AAAA answers and a hijack proof that does not
                               change any system setting (UDP 53 to an
                               unroutable server must still be answered)
      6. Logs                - DoH timeouts / relay errors in the PattN log and
                               "User location is not supported" in the
                               Antigravity language server log

    Read-only: it does not change the config, the DNS servers or the firewall.

.PARAMETER ProxyPort
    Local socks/mixed port of the core. Default 10808.

.PARAMETER RelayProcessName
    Process name of PattN (without .exe). Default PattN.

.PARAMETER AppDir
    Folder that contains PattN.exe (guiConfigs / guiLogs). Detected automatically
    when omitted.

.PARAMETER Samples
    How many fresh connections are used to sample the egress IP. Default 5.

.PARAMETER SkipEgress
    Skip the egress IP sampling.

.PARAMETER NoPause
    Do not wait for Enter at the end.

.PARAMETER LogPath
    Transcript path. Defaults to %TEMP%\WinDivert-diagnostics-<timestamp>.log.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Test-WinDivertDiagnostics.ps1
#>

param (
    [int]$ProxyPort = 10808,
    [string]$RelayProcessName = "PattN",
    [string]$AppDir = "",
    [int]$Samples = 5,
    [switch]$SkipEgress,
    [switch]$NoPause,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"
$script:Passed = 0
$script:Failed = 0
$script:Warned = 0

if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP ("WinDivert-diagnostics-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}
try { Start-Transcript -Path $LogPath -Force | Out-Null } catch { }

function Write-Result {
    param ([string]$Name, [bool]$Ok, [string]$Detail = "")
    if ($Ok) {
        $script:Passed++
        Write-Host ("  [PASS] {0}" -f $Name) -ForegroundColor Green
    }
    else {
        $script:Failed++
        Write-Host ("  [FAIL] {0}" -f $Name) -ForegroundColor Red
    }
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Write-Warn {
    param ([string]$Name, [string]$Detail = "")
    $script:Warned++
    Write-Host ("  [WARN] {0}" -f $Name) -ForegroundColor Yellow
    if ($Detail) { Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray }
}

function Write-Info {
    param ([string]$Text)
    Write-Host ("         {0}" -f $Text) -ForegroundColor DarkGray
}

function Get-ProcessNameSafe {
    param ([int]$ProcessId)
    if ($ProcessId -le 0) { return "" }
    $p = Get-Process -Id $ProcessId -ErrorAction SilentlyContinue
    if ($null -eq $p) { return "" }
    return $p.ProcessName
}

function Test-PrivateAddress {
    param ([string]$Ip)
    if ($Ip -notmatch '^\d+\.\d+\.\d+\.\d+$') { return $false }
    $b = $Ip.Split('.') | ForEach-Object { [int]$_ }
    if ($b[0] -eq 10) { return $true }
    if ($b[0] -eq 127) { return $true }
    if ($b[0] -eq 172 -and $b[1] -ge 16 -and $b[1] -lt 32) { return $true }
    if ($b[0] -eq 192 -and $b[1] -eq 168) { return $true }
    if ($b[0] -eq 169 -and $b[1] -eq 254) { return $true }
    return $false
}

function Test-DriverRunning {
    param ([string]$Name)
    $out = & sc.exe query $Name 2>$null | Out-String
    return ($out -match "RUNNING")
}

function Get-LastLines {
    param ([string]$Path, [int]$Count)
    if (-not (Test-Path $Path)) { return @() }
    return @(Get-Content -Path $Path -Tail $Count -ErrorAction SilentlyContinue)
}

function Shorten {
    param ([string]$Text, [int]$Max = 220)
    if ($null -eq $Text) { return "" }
    $Text = $Text.Trim()
    if ($Text.Length -le $Max) { return $Text }
    return $Text.Substring(0, $Max) + "..."
}

Write-Host ""
Write-Host "=== PattN WinDivert diagnostics ===" -ForegroundColor Cyan
Write-Host ""

# ---------------------------------------------------------------- 1. environment
Write-Host "[1] Environment" -ForegroundColor White

$isAdmin = $false
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
catch { }
Write-Info ("elevated: {0}" -f $isAdmin)

$driverName = $null
foreach ($name in @("WinDivert", "WinDivert1.4", "WinDivert2.2")) {
    if (Test-DriverRunning $name) { $driverName = $name; break }
}
Write-Result -Name "the WinDivert kernel driver is running" -Ok ($null -ne $driverName) -Detail ($(if ($driverName) { "service: $driverName" } else { "no WinDivert driver service is running" }))

$pattn = Get-Process -Name $RelayProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
Write-Result -Name "$RelayProcessName is running" -Ok ($null -ne $pattn) -Detail ($(if ($pattn) { "pid: $($pattn.Id)" } else { "start the application first" }))

$corePid = -1
$coreName = ""
$coreConn = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $ProxyPort } | Select-Object -First 1
if ($null -ne $coreConn) { $corePid = [int]$coreConn.OwningProcess; $coreName = Get-ProcessNameSafe $corePid }
Write-Result -Name "the core listens on 127.0.0.1:$ProxyPort" -Ok ($null -ne $coreConn) -Detail ($(if ($coreConn) { "process: $coreName (pid $corePid)" } else { "the proxy inbound is not listening" }))

$allConns = Get-NetTCPConnection -ErrorAction SilentlyContinue

$relayPort = 0
$relayCandidates = @()
if ($null -ne $pattn) {
    $relayCandidates = @($allConns | Where-Object { $_.OwningProcess -eq $pattn.Id -and $_.State -eq 'Listen' -and $_.LocalPort -ne $ProxyPort })
    $ranked = $relayCandidates | ForEach-Object {
        $p = $_.LocalPort
        $n = @($allConns | Where-Object { $_.LocalPort -eq $p -and $_.State -eq 'Established' }).Count
        [pscustomobject]@{ Port = $p; Established = $n }
    } | Sort-Object Established -Descending
    if ($null -ne $ranked) { $relayPort = [int]($ranked | Select-Object -First 1).Port }
}
Write-Result -Name "the relay listener is up" -Ok ($relayPort -gt 0) -Detail ($(if ($relayPort -gt 0) { "port: $relayPort" } else { "no relay listener on the $RelayProcessName process - the engine is probably stopped" }))

# ---------------------------------------------------------------- 2. config
Write-Host ""
Write-Host "[2] Configuration" -ForegroundColor White

$appDir = $AppDir
if (-not $appDir -and $null -ne $pattn) {
    # Process.Path throws for a process of another elevation level, CIM usually still answers
    try { $appDir = Split-Path -Parent $pattn.Path } catch { }
    if (-not $appDir) {
        try {
            $cim = Get-CimInstance Win32_Process -Filter ("ProcessId={0}" -f $pattn.Id) -ErrorAction SilentlyContinue
            if ($null -ne $cim -and $cim.ExecutablePath) { $appDir = Split-Path -Parent $cim.ExecutablePath }
        }
        catch { }
    }
}
# Last resort for a non-elevated shell: the folder the script was started from.
if (-not $appDir) {
    foreach ($candidate in @((Get-Location).Path, (Join-Path $PSScriptRoot ".."))) {
        if ($candidate -and (Test-Path (Join-Path $candidate "guiConfigs\guiNConfig.json"))) { $appDir = $candidate; break }
    }
}
$guiConfigPath = ""
if ($appDir) { $guiConfigPath = Join-Path $appDir "guiConfigs\guiNConfig.json" }
$cfg = $null
if ($guiConfigPath -and (Test-Path $guiConfigPath)) {
    try { $cfg = Get-Content -Path $guiConfigPath -Raw | ConvertFrom-Json } catch { }
}

if ($null -eq $cfg) {
    Write-Warn -Name "the application config could not be read" -Detail ("run the script as administrator, or pass -AppDir <folder with PattN.exe>; tried: {0}" -f $(if ($guiConfigPath) { $guiConfigPath } else { "<app dir not found>" }))
}
else {
    Write-Info ("config: {0}" -f $guiConfigPath)
    $wd = $cfg.WinDivertItem
    if ($null -eq $wd) {
        Write-Warn -Name "no WinDivertItem in the config"
    }
    else {
        Write-Info ("WinDivert.Enable={0}  EnableDnsHijack={1}  DropQuic={2}  BypassLan={3}" -f $wd.Enable, $wd.EnableDnsHijack, $wd.DropQuic, $wd.BypassLan)
        Write-Result -Name "the DNS hijack is enabled" -Ok ([bool]$wd.EnableDnsHijack) -Detail ($(if ($wd.EnableDnsHijack) { "queries to udp/53 are answered through DoH" } else { "EnableDnsHijack is false: every DNS query leaves the machine directly" }))

        $dnsUrl = [string]$wd.DnsUrl
        $dnsHost = ($dnsUrl -replace '^[a-z]+://', '' -replace '[:/].*$', '')
        $isIpLiteral = ($dnsHost -match '^\d+\.\d+\.\d+\.\d+$')
        # WinDivertService rewrites cloudflare-dns.com to https://1.1.1.1/dns-query
        $isRewritten = ($dnsUrl -match 'cloudflare-dns\.com')
        if ($dnsUrl -and -not $isIpLiteral -and -not $isRewritten) {
            Write-Info ("DoH endpoint: {0} (a host name; over SOCKS5 it is resolved by the core, an IP literal is still safer)" -f $dnsUrl)
        }
        else {
            Write-Info ("DoH endpoint: {0}{1}" -f $dnsUrl, $(if ($isRewritten) { " (rewritten to https://1.1.1.1/dns-query by the app)" } else { "" }))
        }
    }

    $sysProxy = $cfg.SystemProxyItem
    if ($null -ne $sysProxy) {
        Write-Info ("SystemProxyType: {0} {1}" -f $sysProxy.SysProxyType, $(if ([int]$sysProxy.SysProxyType -eq 0) { "(off: WinDivert is the only tunnel)" } else { "" }))
    }

    $sd = $cfg.SimpleDNSItem
    if ($null -ne $sd) {
        Write-Info ("core DNS: DirectDNS={0}  BootstrapDNS={1}  RemoteDNS={2}" -f $sd.DirectDNS, $sd.BootstrapDNS, $sd.RemoteDNS)
        $plain = @()
        foreach ($v in @([string]$sd.DirectDNS, [string]$sd.BootstrapDNS)) {
            if ($v -match '^\d+\.\d+\.\d+\.\d+$') { $plain += $v }
        }
        if ($plain.Count -gt 0) {
            Write-Warn -Name "the core resolves some names in plaintext outside the tunnel" -Detail ("DirectDNS/BootstrapDNS = {0}; the core is excluded from WinDivert, so udp/53 from it bypasses the tunnel" -f ($plain -join ", "))
        }
    }
}

# ---------------------------------------------------------------- 3. coverage
Write-Host ""
Write-Host "[3] Tunnel coverage" -ForegroundColor White

$knownProxyPattern = 'xray|sing-box|mihomo|clash|hiddify|nekoray|v2ray|aether|lyrebird|psiphon|warp|wireguard|openvpn|pattn'
$relayed = 0
$byDesign = 0
$lanBypass = 0
$leaks = @()

if ($relayPort -le 0) {
    Write-Warn -Name "the coverage cannot be measured" -Detail "the relay listener was not found"
}
else {
    # The spoofed inbound SYN gives the relay socket the original destination as its
    # peer address, so the app's local port is the only reliable key (it is unique
    # per host at any point in time).
    $relayPeerPorts = @{}
    $relaySockets = @($allConns | Where-Object { $_.LocalPort -eq $relayPort -and $_.State -eq 'Established' })
    foreach ($r in $relaySockets) { $relayPeerPorts[[int]$r.RemotePort] = $true }

    $candidates = @($allConns | Where-Object {
        $_.State -eq 'Established' -and
        $_.LocalPort -ne $relayPort -and
        $_.RemoteAddress -notin @('0.0.0.0', '::', '::1') -and
        $_.RemoteAddress -notmatch '^(127\.|::1)' -and
        $_.RemotePort -ne 0
    })

    foreach ($c in $candidates) {
        $owner = Get-ProcessNameSafe ([int]$c.OwningProcess)
        $isRelayed = $relayPeerPorts.ContainsKey([int]$c.LocalPort)

        if ($isRelayed) { $relayed++; continue }

        if ($c.OwningProcess -eq $corePid -or ($owner -match $knownProxyPattern)) { $byDesign++; continue }
        if (Test-PrivateAddress $c.RemoteAddress) { $lanBypass++; continue }

        $leaks += ("{0} (pid {1}) {2}:{3} -> {4}:{5}" -f $owner, $c.OwningProcess, $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort)
    }

    Write-Info ("relay-side sockets: {0}   relayed app connections: {1}" -f $relaySockets.Count, $relayed)
    Write-Info ("direct by design (core / proxy processes): {0}" -f $byDesign)
    Write-Info ("direct by design (LAN destinations): {0}" -f $lanBypass)

    $antigravityLeaks = @($leaks | Where-Object { $_ -match 'language_server|Antigravity' })
    if ($antigravityLeaks.Count -gt 0) {
        Write-Result -Name "no Antigravity connection bypasses the tunnel" -Ok $false -Detail (Shorten ($antigravityLeaks -join "; ") 500)
    }
    else {
        Write-Result -Name "no Antigravity connection bypasses the tunnel" -Ok $true -Detail "language_server / Antigravity sockets found: $(@($candidates | Where-Object { (Get-ProcessNameSafe ([int]$_.OwningProcess)) -match 'language_server|Antigravity' }).Count)"
    }

    if ($leaks.Count -gt 0) {
        Write-Warn -Name ("{0} application connection(s) are not relayed" -f $leaks.Count) -Detail (Shorten ($leaks -join "; ") 700)
    }
    else {
        Write-Result -Name "no application connection bypasses the tunnel" -Ok $true -Detail "every non-LAN, non-core connection has a matching relay socket"
    }

    # Antigravity detail: the sockets and whether they are relayed
    $antConns = @($candidates | Where-Object { (Get-ProcessNameSafe ([int]$_.OwningProcess)) -match 'language_server|Antigravity' })
    if ($antConns.Count -gt 0) {
        Write-Host "         Antigravity sockets:" -ForegroundColor DarkGray
        foreach ($c in $antConns) {
            $owner = Get-ProcessNameSafe ([int]$c.OwningProcess)
            $state = if ($relayPeerPorts.ContainsKey([int]$c.LocalPort)) { "tunneled" } else { "DIRECT" }
            Write-Host ("           {0,-16} {1}:{2} -> {3}:{4}  {5}" -f $owner, $c.LocalAddress, $c.LocalPort, $c.RemoteAddress, $c.RemotePort, $state) -ForegroundColor DarkGray
        }
    }
}

# ---------------------------------------------------------------- 4. egress ip
Write-Host ""
Write-Host "[4] Egress IP (what remote services see)" -ForegroundColor White

$sampleList = @()
if ($SkipEgress) {
    Write-Info "skipped (-SkipEgress)"
}
else {
    for ($i = 1; $i -le $Samples; $i++) {
        $json = $null
        try {
            $json = & curl.exe -s -m 12 --noproxy '*' "https://ipinfo.io/json" 2>$null
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($json)) { $json = $null }
            if ($null -ne $json) {
                $o = $json | ConvertFrom-Json
                $sampleList += [pscustomobject]@{ Ip = [string]$o.ip; Country = [string]$o.country; Org = [string]$o.org }
            }
        }
        catch { }
        if ($null -eq $json) {
            $ip = & curl.exe -s -m 12 --noproxy '*' "https://api.ipify.org" 2>$null
            if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($ip)) {
                $sampleList += [pscustomobject]@{ Ip = [string]$ip; Country = "?"; Org = "?" }
            }
        }
    }

    if ($sampleList.Count -eq 0) {
        Write-Warn -Name "the egress IP could not be sampled" -Detail "curl failed (no internet, or the tunnel is black-holing traffic)"
    }
    else {
        foreach ($s in $sampleList) {
            Write-Host ("           {0}  {1}  {2}" -f $s.Ip, $s.Country, $s.Org) -ForegroundColor DarkGray
        }

        $distinctIps = @($sampleList | Select-Object -ExpandProperty Ip -Unique | Where-Object { $_ })
        $distinctCountries = @($sampleList | Select-Object -ExpandProperty Country -Unique | Where-Object { $_ -and $_ -ne "?" })

        Write-Result -Name "the egress IP is stable across connections" -Ok ($distinctIps.Count -le 1) -Detail ($(if ($distinctIps.Count -le 1) { "ip: $($distinctIps -join ', ')" } else { "the exit rotates: $($distinctIps -join ', ') - each new connection can get a different IP" }))

        if ($distinctCountries.Count -gt 1) {
            Write-Warn -Name "the exit changes country between connections" -Detail ("countries: {0}" -f ($distinctCountries -join ", "))
        }

        $hostingPattern = 'datacamp|cdn77|fdcservers|m247|contabo|hetzner|ovh|digitalocean|linode|vultr|leaseweb|psychz|choopa|colocation|colo|hosting|datacenter|data center|vps|gcore|zenlayer|aeza|timeweb|selectel|oracle|amazon|alibaba|tencent|cloud'
        $hosted = @($sampleList | Where-Object { $_.Org -match $hostingPattern } | Select-Object -ExpandProperty Org -Unique)
        if ($hosted.Count -gt 0) {
            Write-Warn -Name "the exit is a hosting/datacenter network" -Detail ("{0} - Google AI APIs (Antigravity, Gemini) often answer 'User location is not supported' to such addresses" -f ($hosted -join "; "))
        }

        if ($null -eq $driverName) {
            Write-Info "note: no WinDivert driver is running, so these are your real (ISP) addresses"
        }
    }
}

# ---------------------------------------------------------------- 5. dns
Write-Host ""
Write-Host "[5] DNS" -ForegroundColor White

try {
    $dnsServers = @(Get-DnsClientServerAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
        Where-Object { $_.ServerAddresses.Count -gt 0 } |
        ForEach-Object { "{0}: {1}" -f $_.InterfaceAlias, ($_.ServerAddresses -join ", ") })
    if ($dnsServers.Count -gt 0) { Write-Info ("configured DNS: {0}" -f ($dnsServers -join " | ")) }
}
catch { }

try {
    $a = @(Resolve-DnsName -Name "www.google.com" -Type A -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
    Write-Result -Name "A queries are answered" -Ok ($a.Count -gt 0) -Detail ("A answers: {0}" -f $a.Count)
}
catch {
    Write-Result -Name "A queries are answered" -Ok $false -Detail $_.Exception.Message
}

try {
    $aaaa = @(Resolve-DnsName -Name "www.google.com" -Type AAAA -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'AAAA' -and $_.IP6Address })
    Write-Result -Name "AAAA queries are answered without an ipv6 address" -Ok ($aaaa.Count -eq 0) -Detail ("AAAA answers: {0}" -f $aaaa.Count)
}
catch {
    Write-Warn -Name "the AAAA answer could not be verified" -Detail $_.Exception.Message
}

# Hijack proof without touching the system settings: a query to an unroutable
# server (TEST-NET-3) can only be answered when udp/53 is intercepted.
try {
    $probe = @(Resolve-DnsName -Name "www.example.com" -Type A -Server "203.0.113.53" -DnsOnly -QuickTimeout -ErrorAction Stop | Where-Object { $_.Type -eq 'A' })
    if ($probe.Count -gt 0) {
        Write-Result -Name "DNS hijack is active (a query to an unroutable server was answered)" -Ok $true -Detail "203.0.113.53 answered - the query was intercepted and resolved through DoH"
    }
    else {
        Write-Warn -Name "DNS hijack probe returned no address" -Detail "the query was intercepted but the DoH resolver returned no answer"
    }
}
catch {
    Write-Warn -Name "DNS hijack probe failed" -Detail ("{0} - if this is a timeout, udp/53 is not intercepted (DNS leak); check the DoH timeouts in the log" -f (Shorten $_.Exception.Message 300))
}

# ---------------------------------------------------------------- 6. logs
Write-Host ""
Write-Host "[6] Logs" -ForegroundColor White

if ($appDir) {
    $today = Get-Date -Format 'yyyy-MM-dd'
    $appLog = Join-Path $appDir ("guiLogs\{0}.txt" -f $today)
    if (-not (Test-Path $appLog)) {
        $latest = Get-ChildItem -Path (Join-Path $appDir "guiLogs") -Filter "*.txt" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($null -ne $latest) { $appLog = $latest.FullName }
    }
    if (Test-Path $appLog) {
        $tail = Get-LastLines -Path $appLog -Count 3000
        $doh = @($tail | Select-String -Pattern 'WinDivertDnsResolver')
        $relayErr = @($tail | Select-String -Pattern 'WinDivertRelay')
        $resets = @($tail | Select-String -Pattern 'without tunnel mapping')
        Write-Info ("app log: {0}" -f $appLog)
        Write-Info ("DoH failures in the tail: {0}   relay errors: {1}   stale resets: {2}" -f $doh.Count, $relayErr.Count, $resets.Count)
        if ($doh.Count -gt 0) {
            Write-Warn -Name "the DoH resolver failed recently" -Detail (Shorten ($doh | Select-Object -Last 1).Line 300)
        }
        if ($relayErr.Count -gt 0) {
            Write-Info ("last relay error: {0}" -f (Shorten ($relayErr | Select-Object -Last 1).Line 200))
        }
    }
    else {
        Write-Info "no application log found"
    }
}
else {
    Write-Info "the application log was skipped (app dir unknown; pass -AppDir)"
}

$lsLog = Join-Path $env:APPDATA "Antigravity\logs\language_server.log"
if (Test-Path $lsLog) {
    $lsTail = Get-LastLines -Path $lsLog -Count 4000
    $loc = @($lsTail | Select-String -Pattern 'User location is not supported')
    if ($loc.Count -gt 0) {
        Write-Warn -Name "Antigravity reported a location restriction" -Detail (Shorten ($loc | Select-Object -Last 1).Line 400)
    }
    else {
        Write-Info "no 'User location is not supported' in the recent Antigravity log"
    }
}
else {
    Write-Info "no Antigravity language server log found"
}

# ---------------------------------------------------------------- 7. hints
Write-Host ""
Write-Host "[7] Root cause hints" -ForegroundColor White

$hints = @()
if ($null -eq $driverName) { $hints += "The WinDivert driver is not running: nothing is intercepted, every connection and DNS query leaves directly." }
if ($null -ne $cfg -and $null -ne $cfg.WinDivertItem -and -not [bool]$cfg.WinDivertItem.EnableDnsHijack) { $hints += "EnableDnsHijack=false: DNS is not intercepted." }
if ($relayPort -le 0) { $hints += "The relay listener is missing: the engine is stopped (check the WinDivert switch / admin rights)." }
if ($leaks.Count -gt 0) { $hints += ("{0} connection(s) are not relayed; see section 3 for the process names." -f $leaks.Count) }
if ($sampleList -and @($sampleList | Select-Object -ExpandProperty Ip -Unique).Count -gt 1) { $hints += "The exit IP rotates per connection. Sessions that open several connections (Antigravity's language server) can be seen from different IPs/countries, which breaks Google's location policy mid-session." }
if ($hints.Count -eq 0) { $hints += "No structural problem was found in the tunnel." }

foreach ($h in $hints) { Write-Host ("         - {0}" -f $h) -ForegroundColor DarkGray }

# ---------------------------------------------------------------- summary
Write-Host ""
$color = if ($script:Failed -eq 0) { "Green" } else { "Red" }
Write-Host ("=== {0} passed, {1} failed, {2} warning(s) ===" -f $script:Passed, $script:Failed, $script:Warned) -ForegroundColor $color
Write-Host ("Log file: {0}" -f $LogPath) -ForegroundColor DarkGray
Write-Host ""

try { Stop-Transcript | Out-Null } catch { }

if (-not $NoPause) { Read-Host "Press Enter to close" }

exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
