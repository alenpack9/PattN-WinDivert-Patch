@echo off
chcp 65001 >nul
title PattN WinDivert All-in-One Auto-Patcher and Builder
color 0B

echo ========================================================
echo        PattN WinDivert All-in-One Builder
echo ========================================================
echo.

set "SCRIPT_DIR=%~dp0"
set "DOTNET_CMD=%LOCALAPPDATA%\dotnet\dotnet.exe"

if not exist "%DOTNET_CMD%" (
    set "DOTNET_CMD=dotnet"
)

:: 1. Close any running instances of PattN and lingering cores to prevent file/port locks
taskkill /F /IM PattN.exe >nul 2>&1
taskkill /F /IM p-xray-p.exe >nul 2>&1
taskkill /F /IM xray.exe >nul 2>&1
taskkill /F /IM sing-box.exe >nul 2>&1
taskkill /F /IM mihomo.exe >nul 2>&1
taskkill /F /IM aether.exe >nul 2>&1
taskkill /F /IM lyrebird.exe >nul 2>&1
taskkill /F /IM psiphon-tunnel-core.exe >nul 2>&1

:: 2. Auto-detect default PattN source path or accept CLI parameter
if not "%~1"=="" (
    set "TARGET_DIR=%~1"
    goto PROCESS_TARGET_PATH
)

set "DEFAULT_PATH="
if exist "D:\ADM\PattN-my-releases\v2rayN\ServiceLib\ServiceLib.csproj" (
    set "DEFAULT_PATH=D:\ADM\PattN-my-releases"
) else if exist "D:\VPN\PattN-my-releases\v2rayN\ServiceLib\ServiceLib.csproj" (
    set "DEFAULT_PATH=D:\VPN\PattN-my-releases"
) else if exist "%SCRIPT_DIR%..\PattN-my-releases\v2rayN\ServiceLib\ServiceLib.csproj" (
    set "DEFAULT_PATH=%SCRIPT_DIR%..\PattN-my-releases"
)

:ASK_PATH
if defined DEFAULT_PATH (
    echo Masire poosheye PattN ra vared konid:
    echo [Dokmeye Enter ra bezanid baraye pishfarz: %DEFAULT_PATH%]
    set /p TARGET_DIR="> "
    if "%TARGET_DIR%"=="" set "TARGET_DIR=%DEFAULT_PATH%"
) else (
    echo Lotfan masire poosheye PattN ra vared konid:
    echo (Masalan: D:\VPN\PattN-my-releases)
    set /p TARGET_DIR="> "
)

:PROCESS_TARGET_PATH
:: Remove surrounding quotes
set TARGET_DIR=%TARGET_DIR:"=%

:: Trim leading and trailing spaces
for /f "tokens=* delims= " %%a in ("%TARGET_DIR%") do set "TARGET_DIR=%%a"
:TRIM_LOOP
if "%TARGET_DIR:~-1%"==" " (
    set "TARGET_DIR=%TARGET_DIR:~0,-1%"
    goto TRIM_LOOP
)

if "%TARGET_DIR%"=="" (
    echo [!] Masir nemitavanad khali bashad. Lotfan dobare talash konid.
    echo.
    goto ASK_PATH
)

if not exist "%TARGET_DIR%" (
    echo [!] Masire vared shode peyda nashod: "%TARGET_DIR%"
    echo.
    goto ASK_PATH
)

echo.
echo [+] Dar hale emale patch-haye WinDivert va hamgam-sazi resurs-ha...
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%Apply-WinDivert.ps1" -TargetDir "%TARGET_DIR%"
if %errorlevel% neq 0 (
    color 0C
    echo.
    echo [!] Khata dar emale patch! Amaliat motavaghef shod.
    goto FINISH
)

:: Find the v2rayN.csproj path
set "CSPROJ_PATH=%TARGET_DIR%\v2rayN\v2rayN\v2rayN.csproj"
if not exist "%CSPROJ_PATH%" (
    set "CSPROJ_PATH=%TARGET_DIR%\v2rayN\v2rayN.csproj"
)

if not exist "%CSPROJ_PATH%" (
    color 0C
    echo [!] File proje peyda nashod: %CSPROJ_PATH%
    goto FINISH
)

:: Define clean output release directory
set "OUTPUT_DIR=%TARGET_DIR%\PattN-WinDivert-Release"
set "OUTPUT_BIN=%OUTPUT_DIR%\bin"

echo.
echo [+] Dar hale build va bastabandiye kamel (Self-Contained Standalone)...
echo [%DOTNET_CMD% publish "%CSPROJ_PATH%" -c Release -r win-x64 -p:SelfContained=true -p:EnableWindowsTargeting=true -o "%OUTPUT_DIR%"]
echo.

"%DOTNET_CMD%" publish "%CSPROJ_PATH%" -c Release -r win-x64 -p:SelfContained=true -p:EnableWindowsTargeting=true -o "%OUTPUT_DIR%"
if %errorlevel% neq 0 (
    color 0C
    echo.
    echo [!] Khata dar Build kardan!
    goto FINISH
)

:: Auto-download cores if missing in patch bin
if not exist "%SCRIPT_DIR%bin\xray\xray.exe" (
    echo.
    echo [+] Dar hale daryafte hasteh-ha va resurs-haye morede niaz az GitHub...
    if exist "%SCRIPT_DIR%scripts\Ensure-Cores.ps1" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%scripts\Ensure-Cores.ps1" -BinDir "%SCRIPT_DIR%bin"
    )
) else if not exist "%SCRIPT_DIR%bin\aether\aether.exe" (
    echo.
    echo [+] Dar hale daryafte hasteye Aether az GitHub...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "& { Add-Type -AssemblyName System.IO.Compression.FileSystem; $u = 'https://github.com/patterniha/Aether/releases/latest/download/aether-windows-x86_64.zip'; $t = Join-Path $env:TEMP 'aether.zip'; curl.exe -sSL -o $t $u; if (Test-Path $t) { $dest = '%SCRIPT_DIR%bin\aether'; New-Item -ItemType Directory -Path $dest -Force | Out-Null; $z = [System.IO.Compression.ZipFile]::OpenRead($t); foreach ($e in $z.Entries) { if ($e.Name -in @('aether.exe','lyrebird.exe','psiphon-tunnel-core.exe','run-aether.bat')) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $dest $e.Name), $true) } elseif ($e.FullName -like 'LICENSES/*') { $ld = Join-Path $dest 'LICENSES'; New-Item -ItemType Directory -Path $ld -Force | Out-Null; if ($e.Name) { [System.IO.Compression.ZipFileExtensions]::ExtractToFile($e, (Join-Path $ld $e.Name), $true) } } }; $z.Dispose(); Remove-Item $t -Force } }"
)

echo.
echo [+] Dar hale kopy kardane hasteh-ha (Aether, Xray, sing-box, mihomo, Geo-Data)...
robocopy "%SCRIPT_DIR%bin" "%OUTPUT_BIN%" /E /XO /NP /NFL /NDL /NJH /NJS >nul

:: Ensure native WinDivert files exist in output
if not exist "%OUTPUT_DIR%\WinDivert.dll" (
    copy /Y "%SCRIPT_DIR%native\x64\WinDivert.dll" "%OUTPUT_DIR%\" >nul
)
if not exist "%OUTPUT_DIR%\WinDivert64.sys" (
    copy /Y "%SCRIPT_DIR%native\x64\WinDivert64.sys" "%OUTPUT_DIR%\" >nul
)

:: Also mirror cores to internal directories as backup
set "INTERNAL_BIN1=%TARGET_DIR%\v2rayN\v2rayN\bin\Release\net10.0-windows10.0.19041.0\win-x64\bin"
set "INTERNAL_BIN2=%TARGET_DIR%\v2rayN\v2rayN\bin\Release\net10.0-windows10.0.19041.0\bin"
if exist "%TARGET_DIR%\v2rayN\v2rayN\bin\Release\net10.0-windows10.0.19041.0\win-x64" (
    robocopy "%SCRIPT_DIR%bin" "%INTERNAL_BIN1%" /E /XO /NP /NFL /NDL /NJH /NJS >nul
)
if exist "%TARGET_DIR%\v2rayN\v2rayN\bin\Release\net10.0-windows10.0.19041.0" (
    robocopy "%SCRIPT_DIR%bin" "%INTERNAL_BIN2%" /E /XO /NP /NFL /NDL /NJH /NJS >nul
)

color 0A
echo.
echo ========================================================
echo [V] AMALIAT BA MOVAFAGHIAT BE PAYAN RESID!
echo ========================================================
echo.
echo Poosheye khorooji-e amadeye ejra:
echo   %OUTPUT_DIR%
echo.
echo File ejraee:
echo   %OUTPUT_DIR%\PattN.exe
echo ========================================================
echo.

:: Skip interactive UI in CI / non-interactive mode
if defined CI goto FINISH_SUCCESS
if /i "%~2"=="--ci" goto FINISH_SUCCESS
if /i "%~2"=="--non-interactive" goto FINISH_SUCCESS

:: Automatically open output folder in Explorer
start "" explorer.exe "%OUTPUT_DIR%"

set /p RUN_NOW="Aya mikhahid PattN hamin alan ejra shavad? [Y/N, pishfarz: Y]: "
if /i "%RUN_NOW%"=="" set RUN_NOW=Y
if /i "%RUN_NOW%"=="Y" (
    echo [+] Dar hale ejraye PattN...
    start "" "%OUTPUT_DIR%\PattN.exe"
)

:FINISH_SUCCESS
echo.
echo [V] Operation completed successfully.
exit /b 0

:FINISH
echo.
if not defined CI (
    if /i not "%~2"=="--ci" (
        if /i not "%~2"=="--non-interactive" pause
    )
)
exit /b 1
