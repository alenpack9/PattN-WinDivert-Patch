<#
.SYNOPSIS
    Verifies that the running PattN WinDivert tunnel behaves correctly.

.DESCRIPTION
    Runs a series of checks against the live system and reports PASS/FAIL for each.
    It is meant to be run while PattN is connected with the WinDivert mode enabled.

    Checks:
      1. The WinDivert driver is loaded.
      2. The proxy inbound port of the core is listening.
      3. Direct (non proxy) traffic is tunneled, i.e. the exit ip differs from the ISP ip.
      4. The Google APIs that Antigravity / Gemini use are reachable (no 403).
      5. No application connection leaks outside of the relay.
      6. AAAA queries are answered without an address (so ipv6 never stalls a connection).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\scripts\Test-WinDivertTunnel.ps1
#>

param (
    [int]$ProxyPort = 10808,
    [string]$RelayProcessName = "PattN",
    [switch]$NoPause,
    [string]$LogPath = ""
)

$ErrorActionPreference = "Continue"
$script:Failed = 0
$script:Passed = 0

# Tee everything to a log file so the result is readable even when the window closes.
if ([string]::IsNullOrWhiteSpace($LogPath)) {
    $LogPath = Join-Path $env:TEMP ("WinDivert-tunnel-test-{0:yyyyMMdd-HHmmss}.log" -f (Get-Date))
}

try {
    Start-Transcript -Path $LogPath -Force | Out-Null
}
catch {
    # transcription is not fatal
}

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

    if ($Detail) {
        Write-Host ("         {0}" -f $Detail) -ForegroundColor DarkGray
    }
}

function Get-CurlStatus {
    param ([string[]]$Arguments)

    $out = & curl.exe @Arguments 2>$null
    return ($out | Select-Object -Last 1)
}

Write-Host ""
Write-Host "=== PattN WinDivert tunnel verification ===" -ForegroundColor Cyan
Write-Host ""

# 1. driver
Write-Host "[1] WinDivert driver" -ForegroundColor White
$driver = sc.exe query WinDivert 2>$null | Out-String
Write-Result -Name "the WinDivert kernel driver is running" -Ok ($driver -match "RUNNING")

# 2. proxy port
Write-Host ""
Write-Host "[2] Proxy inbound" -ForegroundColor White
$listening = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue |
    Where-Object { $_.LocalPort -eq $ProxyPort }
Write-Result -Name "the core listens on 127.0.0.1:$ProxyPort" -Ok ($null -ne $listening)

# 3. tunneling
Write-Host ""
Write-Host "[3] Tunneling" -ForegroundColor White
$directIp = Get-CurlStatus -Arguments @("-s", "--max-time", "25", "--noproxy", "*", "https://api.ipify.org")
$proxyIp = Get-CurlStatus -Arguments @("-s", "--max-time", "25", "--socks5-hostname", "127.0.0.1:$ProxyPort", "https://api.ipify.org")

$directOk = $directIp -match '^\d+\.\d+\.\d+\.\d+$'
Write-Result -Name "a direct connection reaches the internet" -Ok $directOk -Detail "exit ip: $directIp"

if ($directOk -and ($proxyIp -match '^\d+\.\d+\.\d+\.\d+$')) {
    Write-Result -Name "direct traffic exits through the proxy" -Ok ($directIp -eq $proxyIp) -Detail "direct: $directIp / proxy: $proxyIp"
}

# 4. google apis (the antigravity / gemini failure mode)
Write-Host ""
Write-Host "[4] Google APIs used by Antigravity" -ForegroundColor White
$apiHosts = @(
    "daily-cloudcode-pa.googleapis.com",
    "cloudcode-pa.googleapis.com",
    "antigravity-pa.googleapis.com",
    "oauth2.googleapis.com",
    "accounts.google.com"
)

foreach ($hostName in $apiHosts) {
    # a bare request answers 404 (or 302/401); 403 is the geo block page, 000 is a failure
    $code = Get-CurlStatus -Arguments @("-s", "-o", "NUL", "-w", "%{http_code}", "--max-time", "20", "--noproxy", "*", "https://$hostName/")
    $ok = $code -ne "403" -and $code -ne "000"
    Write-Result -Name "$hostName reachable" -Ok $ok -Detail "http status: $code"
}

# 5. leaked connections
Write-Host ""
Write-Host "[5] Connection leaks" -ForegroundColor White
$relay = Get-Process -Name $RelayProcessName -ErrorAction SilentlyContinue | Select-Object -First 1
if ($null -eq $relay) {
    Write-Result -Name "PattN is running" -Ok $false
}
else {
    $connections = Get-NetTCPConnection -ErrorAction SilentlyContinue
    $relayPort = ($connections | Where-Object { $_.OwningProcess -eq $relay.Id -and $_.State -eq 'Listen' } | Select-Object -First 1).LocalPort

    if ($null -eq $relayPort) {
        Write-Result -Name "the relay listens locally" -Ok $false
    }
    else {
        # every established connection of another process should have a matching relay socket.
        # Only the ports the engine diverts are considered: other ports are not tunneled by
        # design, so reporting them would be a false positive (an update service, a game, ...).
        $foreign = $connections | Where-Object {
            $_.State -eq 'Established' -and
            $_.OwningProcess -ne $relay.Id -and
            $_.RemotePort -in 80, 443 -and
            $_.RemoteAddress -notmatch '^(127\.|::1|0\.0\.0\.0)' -and
            $_.RemoteAddress -ne '::'
        }

        $leaks = @()
        foreach ($conn in $foreign) {
            $relayed = $connections | Where-Object {
                $_.LocalPort -eq $relayPort -and
                $_.RemotePort -eq $conn.LocalPort -and
                $_.RemoteAddress -eq $conn.RemoteAddress
            }

            # the proxy core itself reaches its server directly by design
            $owner = Get-Process -Id $conn.OwningProcess -ErrorAction SilentlyContinue
            $isCore = $owner -and ($owner.ProcessName -match 'xray|sing-box|mihomo|pattn|aether|lyrebird|psiphon')

            if (-not $relayed -and -not $isCore) {
                $leaks += ("{0} ({1} -> {2}:{3})" -f $owner.ProcessName, $conn.LocalPort, $conn.RemoteAddress, $conn.RemotePort)
            }
        }

        Write-Result -Name "no application connection bypasses the tunnel" -Ok ($leaks.Count -eq 0) -Detail ($(if ($leaks.Count) { $leaks -join "; " } else { "all connections are relayed" }))
    }
}

# 6. dns
Write-Host ""
Write-Host "[6] DNS" -ForegroundColor White
try {
    $aaaa = Resolve-DnsName -Name "www.google.com" -Type AAAA -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -eq 'AAAA' -and $_.IP6Address }
    Write-Result -Name "AAAA queries are answered without an ipv6 address" -Ok ($null -eq $aaaa) -Detail "AAAA answers: $($aaaa.Count)"

    $a = Resolve-DnsName -Name "www.google.com" -Type A -DnsOnly -ErrorAction Stop |
        Where-Object { $_.Type -eq 'A' }
    Write-Result -Name "A queries are still answered" -Ok ($a.Count -gt 0) -Detail "A answers: $($a.Count)"
}
catch {
    Write-Result -Name "the resolver answers" -Ok $false -Detail $_.Exception.Message
}

# summary
Write-Host ""
Write-Host "=== $script:Passed passed, $script:Failed failed ===" -ForegroundColor $(if ($script:Failed -eq 0) { "Green" } else { "Red" })
Write-Host ""
Write-Host "Log file: $LogPath" -ForegroundColor DarkGray
Write-Host ""

try {
    Stop-Transcript | Out-Null
}
catch {
    # transcription was not started
}

# Keep the window open so the result can be read.
if (-not $NoPause) {
    Read-Host "Press Enter to close"
}

exit $(if ($script:Failed -eq 0) { 0 } else { 1 })
