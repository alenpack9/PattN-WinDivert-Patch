param (
    [string]$BinDir = ""
)

if ([string]::IsNullOrWhiteSpace($BinDir)) {
    $BinDir = Join-Path $PSScriptRoot "..\bin"
}

$BinDir = [System.IO.Path]::GetFullPath($BinDir)
New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
Write-Host "[+] Ensuring cores and geo files in: $BinDir" -ForegroundColor Cyan

function Download-And-Extract-Zip {
    param([string]$Url, [string]$DestDir, [string[]]$FilesToKeep)
    $tempZip = Join-Path $env:TEMP ("core_" + [System.Guid]::NewGuid().ToString() + ".zip")
    Write-Host "    Downloading: $Url" -ForegroundColor Yellow
    curl.exe -sSL -o $tempZip $Url
    if (Test-Path $tempZip) {
        $tempExtract = Join-Path $env:TEMP ("extract_" + [System.Guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $tempExtract -Force | Out-Null
        Expand-Archive -Path $tempZip -DestinationPath $tempExtract -Force
        
        New-Item -ItemType Directory -Path $DestDir -Force | Out-Null
        if ($FilesToKeep -and $FilesToKeep.Count -gt 0) {
            Get-ChildItem -Path $tempExtract -Recurse | Where-Object { $_.Name -in $FilesToKeep } | ForEach-Object {
                Copy-Item -Path $_.FullName -Destination $DestDir -Force
            }
        } else {
            Copy-Item -Path "$tempExtract\*" -Destination $DestDir -Recurse -Force
        }
        Remove-Item -Path $tempExtract -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $tempZip -Force -ErrorAction SilentlyContinue
    }
}

function Download-Single-File {
    param([string]$Url, [string]$DestFile)
    if (-not (Test-Path $DestFile)) {
        Write-Host "    Downloading: $DestFile" -ForegroundColor Yellow
        $destDir = Split-Path $DestFile -Parent
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
        curl.exe -sSL -o $DestFile $Url
    }
}

# 1. Aether
$aetherExe = Join-Path $BinDir "aether\aether.exe"
if (-not (Test-Path $aetherExe)) {
    Download-And-Extract-Zip -Url "https://github.com/patterniha/Aether/releases/latest/download/aether-windows-x86_64.zip" -DestDir (Join-Path $BinDir "aether")
}

# 2. Xray
$xrayExe = Join-Path $BinDir "xray\xray.exe"
if (-not (Test-Path $xrayExe)) {
    Download-And-Extract-Zip -Url "https://github.com/patterniha/Xray-core/releases/latest/download/Xray-windows-64.zip" -DestDir (Join-Path $BinDir "xray")
}

# 3. v2rayN-core-bin (sing-box, mihomo, etc.)
$singBoxExe = Join-Path $BinDir "sing_box\sing-box.exe"
$mihomoExe = Join-Path $BinDir "mihomo\mihomo.exe"
if ((-not (Test-Path $singBoxExe)) -or (-not (Test-Path $mihomoExe))) {
    Download-And-Extract-Zip -Url "https://github.com/2dust/v2rayN-core-bin/raw/refs/heads/master/v2rayN-windows-64.zip" -DestDir $BinDir
}

# 4. Chocolate4U geo files
Download-Single-File -Url "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geosite.dat" -DestFile (Join-Path $BinDir "geosite.dat")
Download-Single-File -Url "https://github.com/Chocolate4U/Iran-v2ray-rules/releases/latest/download/geoip.dat" -DestFile (Join-Path $BinDir "geoip.dat")

# 5. Chocolate4U sing-box rule-sets (srs)
Download-Single-File -Url "https://raw.githubusercontent.com/chocolate4u/Iran-sing-box-rules/rule-set/geosite-category-ir.srs" -DestFile (Join-Path $BinDir "srss\geosite-category-ir.srs")
Download-Single-File -Url "https://raw.githubusercontent.com/chocolate4u/Iran-sing-box-rules/rule-set/geoip-ir.srs" -DestFile (Join-Path $BinDir "srss\geoip-ir.srs")

Write-Host "[V] All cores and geo files verified." -ForegroundColor Green
