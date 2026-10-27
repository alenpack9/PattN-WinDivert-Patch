<#
.SYNOPSIS
    Applies WinDivert Transparent Proxy & Connect/Disconnect functionality to an upstream PattN/v2rayN codebase.
.DESCRIPTION
    Copies the WinDivert service engine files, config models, UI elements, and references
    into a fresh repository clone or extracted source release of PattN.
#>

param (
    [string]$TargetDir = ""
)

$ErrorActionPreference = "Stop"

Write-Host "=== Applying WinDivert & Connect/Disconnect to PattN ===" -ForegroundColor Cyan

if ([string]::IsNullOrWhiteSpace($TargetDir)) {
    Write-Host "[!] Target directory parameter is missing." -ForegroundColor Red
    Write-Host "Usage:" -ForegroundColor Yellow
    Write-Host "  .\Apply-WinDivert.ps1 -TargetDir 'C:\Path\To\PattN-my-releases'" -ForegroundColor Yellow
    Exit 1
}

$ResolvedTarget = Resolve-Path $TargetDir -ErrorAction SilentlyContinue

# If the user passed the parent folder containing 'v2rayN', resolve to the inner 'v2rayN' folder
if ($ResolvedTarget -and (Test-Path "$($ResolvedTarget.Path)\v2rayN\ServiceLib\ServiceLib.csproj")) {
    $target = "$($ResolvedTarget.Path)\v2rayN"
}
elseif ($ResolvedTarget -and (Test-Path "$($ResolvedTarget.Path)\ServiceLib\ServiceLib.csproj")) {
    $target = $ResolvedTarget.Path
}
else {
    Write-Host "[!] Target directory does not contain a valid PattN/v2rayN solution: $TargetDir" -ForegroundColor Red
    Write-Host "Checked locations:" -ForegroundColor Yellow
    Write-Host "  - $TargetDir\ServiceLib\ServiceLib.csproj" -ForegroundColor Yellow
    Write-Host "  - $TargetDir\v2rayN\ServiceLib\ServiceLib.csproj" -ForegroundColor Yellow
    Exit 1
}

Write-Host "[+] Target path resolved to: $target" -ForegroundColor Green

# 0. Check and restore GlobalHotKeys submodule if missing in downloaded zip
$destHotkeys = "$target\GlobalHotKeys\src\GlobalHotKeys\GlobalHotKeys.csproj"
if (-not (Test-Path $destHotkeys)) {
    Write-Host "[+] Restoring missing GlobalHotKeys submodule..." -ForegroundColor Green
    $sourceHotkeys = "$PSScriptRoot\GlobalHotKeys"
    if (Test-Path "$sourceHotkeys\src\GlobalHotKeys\GlobalHotKeys.csproj") {
        New-Item -ItemType Directory -Path "$target\GlobalHotKeys" -Force | Out-Null
        Copy-Item -Path "$sourceHotkeys\*" -Destination "$target\GlobalHotKeys" -Recurse -Force
    }
}

# 1. Copy Services\WinDivert directory
$sourceServices = "$PSScriptRoot\ServiceLib\Services\WinDivert"
$destServices = "$target\ServiceLib\Services\WinDivert"
Write-Host "[+] Copying WinDivert engine files to: $destServices" -ForegroundColor Green
New-Item -ItemType Directory -Path $destServices -Force | Out-Null
Copy-Item -Path "$sourceServices\*" -Destination $destServices -Recurse -Force

# 2. Update UI files from UI_Reference
Write-Host "[+] Updating UI files (StatusBar)..." -ForegroundColor Green
Copy-Item -Path "$PSScriptRoot\UI_Reference\ServiceLib\StatusBarViewModel.cs" -Destination "$target\ServiceLib\ViewModels\StatusBarViewModel.cs" -Force
Copy-Item -Path "$PSScriptRoot\UI_Reference\v2rayN\StatusBarView.xaml" -Destination "$target\v2rayN\Views\StatusBarView.xaml" -Force
Copy-Item -Path "$PSScriptRoot\UI_Reference\v2rayN\StatusBarView.xaml.cs" -Destination "$target\v2rayN\Views\StatusBarView.xaml.cs" -Force

# 2.0 Update ResUI safely without overwriting PattN's existing strings
Write-Host "[+] Updating localization resources (ResUI)..." -ForegroundColor Green
$targetResx = "$target\ServiceLib\Resx\ResUI.resx"
if (Test-Path $targetResx) {
    $contentResx = [System.IO.File]::ReadAllText($targetResx, [System.Text.Encoding]::UTF8)
    if ($contentResx -notmatch "TbEnableWinDivertAs") {
        Write-Host "    - Adding TbEnableWinDivertAs to ResUI.resx" -ForegroundColor Green
        $winDivertResxNode = "`r`n  <data name=`"TbEnableWinDivertAs`" xml:space=`"preserve`">`r`n    <value>Enable WinDivert</value>`r`n  </data>"
        $contentResx = $contentResx -replace '(?s)(<data name="TbEnableTunAs".*?</data>)', "`$1$winDivertResxNode"
        [System.IO.File]::WriteAllText($targetResx, $contentResx, [System.Text.Encoding]::UTF8)
    }
    if ($contentResx -notmatch '<data name="menuConnect"') {
        Write-Host "    - Adding Connect/Disconnect strings to ResUI.resx" -ForegroundColor Green
        $connectResxNode = "`r`n  <data name=`"menuConnect`" xml:space=`"preserve`">`r`n    <value>Connect</value>`r`n  </data>`r`n  <data name=`"menuDisconnect`" xml:space=`"preserve`">`r`n    <value>Disconnect</value>`r`n  </data>`r`n  <data name=`"TipConnected`" xml:space=`"preserve`">`r`n    <value>Connected to VPN</value>`r`n  </data>`r`n  <data name=`"TipDisconnected`" xml:space=`"preserve`">`r`n    <value>Disconnected from VPN</value>`r`n  </data>"
        $contentResx = $contentResx -replace '(?s)(<data name="menuReload".*?</data>)', "`$1$connectResxNode"
        [System.IO.File]::WriteAllText($targetResx, $contentResx, [System.Text.Encoding]::UTF8)
    }
}

$targetFaResx = "$target\ServiceLib\Resx\ResUI.fa.resx"
if (Test-Path $targetFaResx) {
    $contentFaResx = [System.IO.File]::ReadAllText($targetFaResx, [System.Text.Encoding]::UTF8)
    if ($contentFaResx -notmatch "TbEnableWinDivertAs") {
        Write-Host "    - Adding TbEnableWinDivertAs to ResUI.fa.resx" -ForegroundColor Green
        $winDivertFaNode = "`r`n  <data name=`"TbEnableWinDivertAs`" xml:space=`"preserve`">`r`n    <value>`u0641`u0639`u0627`u0644 `u0633`u0627`u0632`u06cc WinDivert</value>`r`n  </data>"
        $contentFaResx = $contentFaResx -replace '(?s)(<data name="TbEnableTunAs".*?</data>)', "`$1$winDivertFaNode"
        [System.IO.File]::WriteAllText($targetFaResx, $contentFaResx, [System.Text.Encoding]::UTF8)
    }
    if ($contentFaResx -notmatch '<data name="menuConnect"') {
        Write-Host "    - Adding Connect/Disconnect strings to ResUI.fa.resx" -ForegroundColor Green
        $connectFaNode = "`r`n  <data name=`"menuConnect`" xml:space=`"preserve`">`r`n    <value>`u0627`u062a`u0635`u0627`u0644</value>`r`n  </data>`r`n  <data name=`"menuDisconnect`" xml:space=`"preserve`">`r`n    <value>`u0642`u0637`u0639 `u0627`u062a`u0635`u0627`u0644</value>`r`n  </data>`r`n  <data name=`"TipConnected`" xml:space=`"preserve`">`r`n    <value>`u0627`u0631`u062a`u0628`u0627`u0637 `u0628`u0627 `u0648`u06cc`u200c`u067e`u06cc`u200c`u0627`u0646 `u0628`u0631`u0642`u0631`u0627`u0631 `u0634`u062f</value>`r`n  </data>`r`n  <data name=`"TipDisconnected`" xml:space=`"preserve`">`r`n    <value>`u0627`u0631`u062a`u0628`u0627`u0637 `u0628`u0627 `u0648`u06cc`u200c`u067e`u06cc`u200c`u0627`u0646 `u0642`u0637`u0639 `u0634`u062f</value>`r`n  </data>"
        $contentFaResx = $contentFaResx -replace '(?s)(<data name="menuReload".*?</data>)', "`$1$connectFaNode"
        [System.IO.File]::WriteAllText($targetFaResx, $contentFaResx, [System.Text.Encoding]::UTF8)
    }
}

$targetDesigner = "$target\ServiceLib\Resx\ResUI.Designer.cs"
if (Test-Path $targetDesigner) {
    $contentDesigner = [System.IO.File]::ReadAllText($targetDesigner, [System.Text.Encoding]::UTF8)
    if ($contentDesigner -notmatch "TbEnableWinDivertAs") {
        Write-Host "    - Adding TbEnableWinDivertAs to ResUI.Designer.cs" -ForegroundColor Green
        $propBlock = "`r`n        `r`n        /// <summary>`r`n        ///   Looks up a localized string similar to Enable WinDivert.`r`n        /// </summary>`r`n        public static string TbEnableWinDivertAs {`r`n            get {`r`n                return ResourceManager.GetString(`"TbEnableWinDivertAs`", resourceCulture);`r`n            }`r`n        }"
        $contentDesigner = $contentDesigner -replace '(?s)(public static string TbEnableTunAs\s*\{\s*get\s*\{.*?\}\s*\})', "`$1$propBlock"
        [System.IO.File]::WriteAllText($targetDesigner, $contentDesigner, [System.Text.Encoding]::UTF8)
    }
    if ($contentDesigner -notmatch 'public static string menuConnect\b') {
        Write-Host "    - Adding Connect/Disconnect properties to ResUI.Designer.cs" -ForegroundColor Green
        $connectDesignerProps = @"
        
        /// <summary>
        ///   Looks up a localized string similar to Connect.
        /// </summary>
        public static string menuConnect {
            get {
                return ResourceManager.GetString("menuConnect", resourceCulture);
            }
        }
        
        /// <summary>
        ///   Looks up a localized string similar to Disconnect.
        /// </summary>
        public static string menuDisconnect {
            get {
                return ResourceManager.GetString("menuDisconnect", resourceCulture);
            }
        }

        /// <summary>
        ///   Looks up a localized string similar to Connected to VPN.
        /// </summary>
        public static string TipConnected {
            get {
                return ResourceManager.GetString("TipConnected", resourceCulture);
            }
        }

        /// <summary>
        ///   Looks up a localized string similar to Disconnected from VPN.
        /// </summary>
        public static string TipDisconnected {
            get {
                return ResourceManager.GetString("TipDisconnected", resourceCulture);
            }
        }
"@
        $contentDesigner = $contentDesigner -replace '(?s)(public static string menuReload\s*\{\s*get\s*\{.*?\}\s*\})', "`$1$connectDesignerProps"
        [System.IO.File]::WriteAllText($targetDesigner, $contentDesigner, [System.Text.Encoding]::UTF8)
    }
}

# 2.1 Enable RollForward to higher .NET versions (e.g. .NET 11) in Directory.Build.props
$buildPropsPath = "$target\Directory.Build.props"
if (Test-Path $buildPropsPath) {
    $buildPropsContent = Get-Content $buildPropsPath -Raw
    if ($buildPropsContent -notmatch "<RollForward>") {
        Write-Host "[+] Adding RollForward=LatestMajor to Directory.Build.props" -ForegroundColor Green
        $buildPropsContent = $buildPropsContent -replace '(<TargetFramework>net10\.0</TargetFramework>)', "`$1`r`n        <RollForward>LatestMajor</RollForward>"
        Set-Content -Path $buildPropsPath -Value $buildPropsContent -Encoding utf8
    }
}

# 2.2 Update GlobalUsings.cs to include ServiceLib.Services.WinDivert
$globalUsingsPath = "$target\ServiceLib\GlobalUsings.cs"
if (Test-Path $globalUsingsPath) {
    $globalUsingsContent = Get-Content $globalUsingsPath -Raw
    if ($globalUsingsContent -notmatch "ServiceLib\.Services\.WinDivert") {
        Write-Host "[+] Adding ServiceLib.Services.WinDivert to GlobalUsings.cs" -ForegroundColor Green
        $globalUsingsContent += "`r`nglobal using ServiceLib.Services.WinDivert;`r`n"
        Set-Content -Path $globalUsingsPath -Value $globalUsingsContent -Encoding utf8
    }
}

# 3. Update Directory.Packages.props (Central Package Management) & ServiceLib.csproj
$packagesPropsPath = "$target\Directory.Packages.props"
if (Test-Path $packagesPropsPath) {
    $packagesContent = Get-Content $packagesPropsPath -Raw
    if ($packagesContent -notmatch 'Include="WinDivertSharp"') {
        Write-Host "[+] Adding WinDivertSharp to Directory.Packages.props" -ForegroundColor Green
        $packagesContent = $packagesContent -replace '(?s)(<PackageVersion Include="TaskScheduler".*?/>)', "`$1`r`n    <PackageVersion Include=""WinDivertSharp"" Version=""1.4.3.2"" />"
        Set-Content -Path $packagesPropsPath -Value $packagesContent -Encoding utf8
    }
}

$serviceLibCsproj = "$target\ServiceLib\ServiceLib.csproj"
$serviceLibContent = Get-Content $serviceLibCsproj -Raw
if ($serviceLibContent -notmatch "WinDivertSharp") {
    Write-Host "[+] Adding WinDivertSharp package to ServiceLib.csproj" -ForegroundColor Green
    $packageRef = @"
		<PackageReference Include="WinDivertSharp">
			<ExcludeAssets>build</ExcludeAssets>
		</PackageReference>
"@
    $serviceLibContent = $serviceLibContent -replace '(?s)(<PackageReference Include="TaskScheduler" />)', "`$1`r`n$packageRef"
    Set-Content -Path $serviceLibCsproj -Value $serviceLibContent -Encoding utf8
}

# 4. Update v2rayN.csproj to copy native WinDivert files on build
$v2rayNCsproj = "$target\v2rayN\v2rayN.csproj"
$v2rayNContent = Get-Content $v2rayNCsproj -Raw
if ($v2rayNContent -notmatch "WinDivertSharp") {
    Write-Host "[+] Adding WinDivert build targets to v2rayN.csproj" -ForegroundColor Green
    $nativeSection = @"
	<!-- WinDivert driver, required by the WinDivert mode (windows only) -->
	<PropertyGroup Condition="`$([MSBuild]::IsOSPlatform('Windows'))">
		<WinDivertPath>`$(NuGetPackageRoot)windivertsharp\1.4.3.2\build\</WinDivertPath>
		<WinDivertArch Condition="'`$(RuntimeIdentifier)' != '' and `$(RuntimeIdentifier.Contains('x86'))">x86</WinDivertArch>
		<WinDivertArch Condition="'`$(WinDivertArch)' == ''">x64</WinDivertArch>
		<WinDivertSys Condition="'`$(WinDivertArch)' == 'x86'">WinDivert32.sys</WinDivertSys>
		<WinDivertSys Condition="'`$(WinDivertSys)' == ''">WinDivert64.sys</WinDivertSys>
	</PropertyGroup>
	<ItemGroup Condition="`$([MSBuild]::IsOSPlatform('Windows'))">
		<None Include="`$(WinDivertPath)`$(WinDivertArch)\WinDivert.dll" Link="WinDivert.dll" Condition="Exists('`$(WinDivertPath)`$(WinDivertArch)\WinDivert.dll')">
			<CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
			<CopyToPublishDirectory>PreserveNewest</CopyToPublishDirectory>
			<ExcludeFromSingleFile>true</ExcludeFromSingleFile>
		</None>
		<None Include="`$(WinDivertPath)`$(WinDivertArch)\`$(WinDivertSys)" Link="`$(WinDivertSys)" Condition="Exists('`$(WinDivertPath)`$(WinDivertArch)\`$(WinDivertSys)')">
			<CopyToOutputDirectory>PreserveNewest</CopyToOutputDirectory>
			<CopyToPublishDirectory>PreserveNewest</CopyToPublishDirectory>
			<ExcludeFromSingleFile>true</ExcludeFromSingleFile>
		</None>
	</ItemGroup>
"@
    $v2rayNContent = $v2rayNContent -replace "</Project>", "$nativeSection`r`n</Project>"
    Set-Content -Path $v2rayNCsproj -Value $v2rayNContent -Encoding utf8
}

# 5. Update ConfigItems.cs (add WinDivertItem class)
$configItemsPath = "$target\ServiceLib\Models\Configs\ConfigItems.cs"
$configItemsContent = Get-Content $configItemsPath -Raw
if ($configItemsContent -notmatch "class WinDivertItem") {
    Write-Host "[+] Adding WinDivertItem model to ConfigItems.cs" -ForegroundColor Green
    $winDivertItemClass = @"

[Serializable]
public class WinDivertItem
{
    public bool Enable { get; set; }
    public bool EnableDnsHijack { get; set; } = true;
    public bool DropQuic { get; set; } = true;
    public bool BypassLan { get; set; } = true;
    public bool BypassProxyCore { get; set; } = true;
    public string DnsUrl { get; set; } = "https://cloudflare-dns.com/dns-query";
}
"@
    $configItemsContent += $winDivertItemClass
    Set-Content -Path $configItemsPath -Value $configItemsContent -Encoding utf8
}
elseif ($configItemsContent -notmatch "DnsUrl") {
    Write-Host "[+] Updating WinDivertItem model with DnsUrl in ConfigItems.cs" -ForegroundColor Green
    $configItemsContent = $configItemsContent -replace '(?s)public class WinDivertItem\s*\{.*?\}(?=\s*$)', @"
public class WinDivertItem
{
    public bool Enable { get; set; }
    public bool EnableDnsHijack { get; set; } = true;
    public bool DropQuic { get; set; } = true;
    public bool BypassLan { get; set; } = true;
    public bool BypassProxyCore { get; set; } = true;
    public string DnsUrl { get; set; } = "https://cloudflare-dns.com/dns-query";
}
"@
    Set-Content -Path $configItemsPath -Value $configItemsContent -Encoding utf8
}

# 6. Update Config.cs (add WinDivertItem property)
$configPath = "$target\ServiceLib\Models\Configs\Config.cs"
$configContent = Get-Content $configPath -Raw
if ($configContent -notmatch "WinDivertItem WinDivertItem") {
    Write-Host "[+] Adding WinDivertItem property to Config.cs" -ForegroundColor Green
    $configContent = $configContent -replace 'public TunModeItem TunModeItem \{ get; set; \}', "public TunModeItem TunModeItem { get; set; }`r`n    public WinDivertItem WinDivertItem { get; set; }"
    Set-Content -Path $configPath -Value $configContent -Encoding utf8
}

# 7. Update ConfigHandler.cs default initialization
$configHandlerPath = "$target\ServiceLib\Handler\ConfigHandler.cs"
$configHandlerContent = [System.IO.File]::ReadAllText($configHandlerPath, [System.Text.Encoding]::UTF8)
if ($configHandlerContent -notmatch "config\.WinDivertItem") {
    Write-Host "[+] Adding default initialization to ConfigHandler.cs" -ForegroundColor Green
    $divertInit = @"
        config.WinDivertItem ??= new WinDivertItem
        {
            Enable = false,
            EnableDnsHijack = true,
            DropQuic = true,
            BypassLan = true,
        };
"@
    $configHandlerContent = $configHandlerContent -replace 'config\.GuiItem \?\?=', "$divertInit`r`n        config.GuiItem ??="
    [System.IO.File]::WriteAllText($configHandlerPath, $configHandlerContent, [System.Text.Encoding]::UTF8)
}

# 8. Update CoreManager.cs (call WinDivertService.Instance.UpdateProxyPort and cleanup lingering cores)
$coreManagerPath = "$target\ServiceLib\Manager\CoreManager.cs"
$coreManagerContent = [System.IO.File]::ReadAllText($coreManagerPath, [System.Text.Encoding]::UTF8)
if ($coreManagerContent -notmatch "WinDivertService\.Instance\.Start") {
    Write-Host "[+] Hooking WinDivertService into CoreManager.cs" -ForegroundColor Green
    $coreManagerHook = @"
        // the WinDivert mode forwards the diverted traffic to the local inbound of the core
        WinDivertService.Instance.UpdateProxyPort(AppManager.Instance.GetLocalPort(EInboundProtocol.socks));
        if (_config.WinDivertItem.Enable && Utils.IsWindows() && Utils.IsAdministrator())
        {
            WinDivertService.Instance.Start(_config);
        }
"@
    if ($coreManagerContent -match "WinDivertService\.Instance\.UpdateProxyPort") {
        $coreManagerContent = $coreManagerContent -replace 'WinDivertService\.Instance\.UpdateProxyPort\(AppManager\.Instance\.GetLocalPort\(EInboundProtocol\.socks\)\);', "WinDivertService.Instance.UpdateProxyPort(AppManager.Instance.GetLocalPort(EInboundProtocol.socks));`r`n        if (_config.WinDivertItem.Enable && Utils.IsWindows() && Utils.IsAdministrator())`r`n        {`r`n            WinDivertService.Instance.Start(_config);`r`n        }"
    } else {
        $coreManagerContent = $coreManagerContent -replace '(await CoreStartPreService\(preContext\);)', "`$1`r`n$coreManagerHook"
    }
    [System.IO.File]::WriteAllText($coreManagerPath, $coreManagerContent, [System.Text.Encoding]::UTF8)
}

if ($coreManagerContent -notmatch "KillLingeringCores") {
    Write-Host "[+] Adding KillLingeringCores to CoreManager.cs to prevent port collisions" -ForegroundColor Green
    $killMethod = @"

    public static void KillLingeringCores()
    {
        if (!Utils.IsWindows())
        {
            return;
        }

        var coreNames = new[] { `"p-xray-p`", `"xray`", `"sing-box`", `"mihomo`", `"aether`", `"lyrebird`", `"psiphon-tunnel-core`" };
        var currentPid = Environment.ProcessId;

        foreach (var name in coreNames)
        {
            try
            {
                foreach (var p in System.Diagnostics.Process.GetProcessesByName(name))
                {
                    try
                    {
                        if (p.Id != currentPid)
                        {
                            p.Kill();
                            p.WaitForExit(300);
                        }
                    }
                    catch { }
                    finally
                    {
                        p.Dispose();
                    }
                }
            }
            catch { }
        }
    }
"@
    $coreManagerContent = $coreManagerContent -replace '(?s)(private async Task CoreStopInTurn\(\).*?\{)', "`$1`r`n            KillLingeringCores();"
    $coreManagerContent = $coreManagerContent -replace '(?s)(public async Task Init\(Config config.*?\{)', "`$1`r`n        KillLingeringCores();"
    $coreManagerContent = $coreManagerContent -replace '(?s)(private async Task CoreStart\(CoreConfigContext context\).*?\{)', "`$1`r`n        KillLingeringCores();"
    $coreManagerContent = $coreManagerContent -replace '(#endregion Private)', "$killMethod`r`n`r`n    `$1"
    [System.IO.File]::WriteAllText($coreManagerPath, $coreManagerContent, [System.Text.Encoding]::UTF8)
}

# 9. Update AppManager.cs (stop WinDivertService on exit)
$appManagerPath = "$target\ServiceLib\Manager\AppManager.cs"
$appManagerContent = Get-Content $appManagerPath -Raw
if ($appManagerContent -notmatch "WinDivertService\.Instance\.Stop") {
    Write-Host "[+] Hooking WinDivertService.Instance.Stop into AppManager.cs" -ForegroundColor Green
    $appManagerHook = "`r`n            WinDivertService.Instance.Stop();"
    $appManagerContent = $appManagerContent -replace '(await CoreManager\.Instance\.CoreStop\(\);)', "`$1$appManagerHook"
    Set-Content -Path $appManagerPath -Value $appManagerContent -Encoding utf8
}

# 10. Update MainWindow.xaml (add Connect/Disconnect button to top toolbar)
$mainWindowXaml = "$target\v2rayN\Views\MainWindow.xaml"
if (Test-Path $mainWindowXaml) {
    $xamlContent = [System.IO.File]::ReadAllText($mainWindowXaml, [System.Text.Encoding]::UTF8)
    if ($xamlContent -notmatch "menuConnectDisconnect") {
        Write-Host "[+] Adding Connect/Disconnect button to MainWindow.xaml toolbar" -ForegroundColor Green
        $connectToolbarNode = @"
                        <Separator />
                        <Menu Margin="0,1" Style="{StaticResource ToolbarMenu}">
                            <MenuItem
                                x:Name="menuConnectDisconnect"
                                Padding="{StaticResource MarginLeftRight8}">
                                <MenuItem.Header>
                                    <StackPanel Orientation="Horizontal">
                                        <materialDesign:PackIcon
                                            x:Name="iconConnectDisconnect"
                                            Margin="{StaticResource MarginRight8}"
                                            VerticalAlignment="Center"
                                            Kind="Power" />
                                        <TextBlock x:Name="txtConnectDisconnect" Text="{x:Static resx:ResUI.menuDisconnect}" />
                                    </StackPanel>
                                </MenuItem.Header>
                            </MenuItem>
                        </Menu>
"@
        $xamlContent = $xamlContent -replace '(?s)(<MenuItem\s+x:Name="menuReload".*?</Menu>)', "`$1`r`n$connectToolbarNode"
        [System.IO.File]::WriteAllText($mainWindowXaml, $xamlContent, [System.Text.Encoding]::UTF8)
    }
}

# 11. Update MainWindow.xaml.cs (bind Connect/Disconnect button)
$mainWindowCs = "$target\v2rayN\Views\MainWindow.xaml.cs"
if (Test-Path $mainWindowCs) {
    $csContent = [System.IO.File]::ReadAllText($mainWindowCs, [System.Text.Encoding]::UTF8)
    if ($csContent -notmatch "menuConnectDisconnect") {
        Write-Host "[+] Hooking Connect/Disconnect into MainWindow.xaml.cs" -ForegroundColor Green
        $connectCsHook = @"
            this.BindCommand(ViewModel, vm => vm.StatusBarViewModel.ToggleConnectCmd, v => v.menuConnectDisconnect).DisposeWith(disposables);
            this.WhenAnyValue(x => x.ViewModel.StatusBarViewModel.IsConnected)
                .ObserveOn(RxSchedulers.MainThreadScheduler)
                .Subscribe(connected =>
                {
                    txtConnectDisconnect.Text = connected ? ResUI.menuDisconnect : ResUI.menuConnect;
                    iconConnectDisconnect.Kind = connected ? MaterialDesignThemes.Wpf.PackIconKind.PowerOff : MaterialDesignThemes.Wpf.PackIconKind.Power;
                })
                .DisposeWith(disposables);
"@
        $csContent = $csContent -replace '(this\.BindCommand\(ViewModel, vm => vm\.ReloadCmd, v => v\.menuReload\)\.DisposeWith\(disposables\);)', "`$1`r`n$connectCsHook"
        [System.IO.File]::WriteAllText($mainWindowCs, $csContent, [System.Text.Encoding]::UTF8)
    }
}

# 12. Update MainWindowViewModel.cs (sync IsConnected on Reload)
$mainViewModelCs = "$target\ServiceLib\ViewModels\MainWindowViewModel.cs"
if (Test-Path $mainViewModelCs) {
    $vmContent = [System.IO.File]::ReadAllText($mainViewModelCs, [System.Text.Encoding]::UTF8)
    if ($vmContent -notmatch "StatusBarViewModel\.IsConnected = true") {
        Write-Host "[+] Hooking IsConnected state into MainWindowViewModel.cs Reload" -ForegroundColor Green
        $vmContent = $vmContent -replace '(var allResult = await CoreConfigContextBuilder\.BuildAll\(_config, profileItem\);)', "StatusBarViewModel.IsConnected = true;`r`n            `$1"
        [System.IO.File]::WriteAllText($mainViewModelCs, $vmContent, [System.Text.Encoding]::UTF8)
    }
}

Write-Host "=== WinDivert & Connect/Disconnect successfully applied to $target ===" -ForegroundColor Cyan
Write-Host "Next step: Run the build command:" -ForegroundColor Yellow
$dotnetCmd = if (Test-Path "$env:LOCALAPPDATA\dotnet\dotnet.exe") { "& ""$env:LOCALAPPDATA\dotnet\dotnet.exe""" } else { "dotnet" }
Write-Host "  $dotnetCmd build ""$target\v2rayN\v2rayN.csproj"" -c Release" -ForegroundColor Green
