#Requires -Version 5.1
<#
.SYNOPSIS
    Nahimic 3 音效套件移植安装（两段式）。

.DESCRIPTION
    第 1 段：检测到未开测试签名 -> 开启 -> 提示重启，退出。
    第 2 段：重启后再次运行 -> 安装 SWC 驱动、EXT 驱动、应用 -> 重启生效。

    前置条件：
      - 已在 BIOS 关闭 Secure Boot
      - 已用 prepare-kit.ps1 生成适配本机的 kit（或在 KitDir 里放好自己改好的 EXT INF）

.PARAMETER KitDir
    适配后的驱动目录，需包含 1-Driver-APO 与 2-Driver-EXT。

.PARAMETER AppxDir
    应用包目录（appxbundle + 依赖 + License xml）。默认取 KitDir\appx。

.PARAMETER SkipAppx
    只装驱动，不装应用。

.EXAMPLE
    .\install.ps1 -KitDir "D:\kit-ready"

.NOTES
    本脚本为原创代码，MIT 许可。安装过程中调用的驱动与应用均为使用者自行提供的
    第三方文件，其许可由使用者与该权利人约定。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$KitDir,

    [string]$AppxDir,

    [switch]$SkipAppx
)

$ErrorActionPreference = 'Stop'

# ============================ 输出helper ============================
function Info($m) { Write-Host ('  ' + $m) -ForegroundColor Gray }
function Ok($m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [!] ' + $m) -ForegroundColor Yellow }
function Fail($m) { Write-Host ('  [X] ' + $m) -ForegroundColor Red }
function Step($m) { Write-Host ''; Write-Host ('== ' + $m + ' ==') -ForegroundColor Cyan }

function Done([string]$msg) {
    Write-Host ''
    Write-Host $msg -ForegroundColor Yellow
    Write-Host ''
    Read-Host '按 Enter 关闭窗口' | Out-Null
    exit
}

# ============================ 管理员检查 ============================
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail '需要管理员权限。请右键「以管理员身份运行」。'
    Read-Host '按 Enter 关闭窗口' | Out-Null
    exit 1
}

$log = Join-Path $PSScriptRoot 'install-log.txt'
try { Start-Transcript -Path $log -Append -Force | Out-Null } catch { }

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  Nahimic 3 移植安装' -ForegroundColor Cyan
Write-Host ('  ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray
Write-Host '=====================================================' -ForegroundColor Cyan

# ============================ 0. 预检 ============================
Step '0. 环境预检'

if (-not (Test-Path $KitDir)) { Fail ('找不到 KitDir: ' + $KitDir); Done '中止。' }
$KitDir = (Resolve-Path $KitDir).Path
Info ('套件目录 : ' + $KitDir)

$apoDir = Join-Path $KitDir '1-Driver-APO'
$extDir = Join-Path $KitDir '2-Driver-EXT'

$swcInf = $null
if (Test-Path $apoDir) {
    $swcInf = Get-ChildItem $apoDir -Filter '*Swc.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $swcInf) { $swcInf = Get-ChildItem $apoDir -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1 }
}
$extInf = $null
if (Test-Path $extDir) {
    $extInf = Get-ChildItem $extDir -Filter '*Ext.inf' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $extInf) { $extInf = Get-ChildItem $extDir -Filter '*.inf' -ErrorAction SilentlyContinue | Select-Object -First 1 }
}

if (-not $swcInf) { Warn '没有找到 SWC 驱动的 INF（1-Driver-APO 目录）' } else { Info ('SWC 驱动  : ' + $swcInf.Name) }
if (-not $extInf) { Fail '没有找到 EXT 驱动的 INF（2-Driver-EXT 目录），无法继续。'; Done '中止。' }
Info ('EXT 驱动  : ' + $extInf.Name)

# Secure Boot
$sbVal = $null
try { $sbVal = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop).UEFISecureBootEnabled } catch { }
if ($sbVal -eq 1) {
    Fail 'Secure Boot 仍处于开启状态。'
    Write-Host ''
    Write-Host '  改过匹配表的驱动签名会失效，Secure Boot 开启时无法装载。' -ForegroundColor Yellow
    Write-Host '  请先进入 BIOS 关闭 Secure Boot（通常在 Security 或 Boot 选项卡），再运行本脚本。' -ForegroundColor Yellow
    Done '已中止，未做任何修改。'
} elseif ($null -eq $sbVal) {
    Info 'Secure Boot : 读不到状态（可能是传统 BIOS 或非 UEFI），继续'
} else {
    Info 'Secure Boot : 已关闭 OK'
}

# 声卡
$codec = $null
foreach ($p in @('INTELAUDIO\FUNC_01&VEN_10EC*', 'HDAUDIO\FUNC_01&VEN_10EC*')) {
    $codec = Get-PnpDevice -Class Media -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like $p } | Select-Object -First 1
    if ($codec) { break }
}
if (-not $codec) {
    Fail '没有找到 Realtek（VEN_10EC）音频编解码器。'
    Done '请先确认声卡驱动正常。'
}
Info ('声卡      : ' + $codec.InstanceId)

# EXT INF 是否包含本机 ID
$mySubsys = $null
if ($codec.InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') { $mySubsys = $Matches[1].ToUpper() }
$infBytes = [System.IO.File]::ReadAllBytes($extInf.FullName)
$infText = $null
if ($infBytes.Length -ge 2 -and $infBytes[0] -eq 0xFF -and $infBytes[1] -eq 0xFE) {
    $infText = [System.Text.Encoding]::Unicode.GetString($infBytes, 2, $infBytes.Length - 2)
} else {
    $infText = [System.Text.Encoding]::Default.GetString($infBytes)
}
if ($mySubsys) {
    if ($infText -match [regex]::Escape('SUBSYS_' + $mySubsys)) {
        Ok ('EXT INF 已包含本机 SUBSYS_' + $mySubsys)
    } else {
        Fail ('EXT INF 里没有本机 SUBSYS_' + $mySubsys)
        Write-Host ''
        Write-Host '  请先运行 prepare-kit.ps1 生成适配本机的套件，然后用 -KitDir 指向输出目录。' -ForegroundColor Yellow
        Done '已中止，未做任何修改。'
    }
}

# ============================ 1. 测试签名 ============================
Step '1. 测试签名状态'

$tsOn = $false
$bcd = & bcdedit /enum '{current}' 2>&1 | Out-String
if ($bcd -match 'testsigning\s+Yes') { $tsOn = $true }

if (-not $tsOn) {
    Warn '未开启测试签名，正在开启...'
    & bcdedit /set testsigning on | Out-Host
    if ($LASTEXITCODE -ne 0) {
        Fail '开启测试签名失败。请确认 Secure Boot 已关闭，且以管理员身份运行。'
        Done '[阶段 1 失败]'
    }
    Done @'
[阶段 1 完成] 测试签名已开启。

请现在【重启电脑】。
重启后桌面右下角会出现「测试模式」水印，属正常现象。
重启后再次以管理员身份运行本脚本，完成第 2 段安装。
'@
}

Ok '测试签名已生效，进入安装阶段'

# ============================ 2. 安装 SWC 驱动 ============================
Step '2. 安装 APO 软件组件驱动 (SWC)'

if ($swcInf) {
    Info ('pnputil /add-driver "' + $swcInf.FullName + '"')
    & pnputil.exe /add-driver $swcInf.FullName /install | Out-Host
    $rc = $LASTEXITCODE
    if ($rc -ne 0 -and $rc -ne 259 -and $rc -ne 3010) {
        Warn ('返回码 ' + $rc + '（无新驱动 / 已存在 通常无害，继续）')
    } else {
        Ok 'SWC 驱动已安装'
    }
} else {
    Warn '跳过（没有 SWC INF）'
}

# ============================ 3. 安装 EXT 驱动 ============================
Step '3. 安装 EXT 扩展驱动'

Info ('pnputil /add-driver "' + $extInf.FullName + '"')
& pnputil.exe /add-driver $extInf.FullName /install | Out-Host
$rc = $LASTEXITCODE
if ($rc -ne 0 -and $rc -ne 259 -and $rc -ne 3010) {
    Fail ('EXT 驱动安装失败，返回码 ' + $rc)
    Write-Host ''
    Write-Host '  常见原因：' -ForegroundColor Yellow
    Write-Host '    1. 测试签名没生效 —— 是否真的重启过？' -ForegroundColor Yellow
    Write-Host '    2. 签名校验失败 —— Secure Boot 是否已关闭？' -ForegroundColor Yellow
    Write-Host '    3. INF 里的匹配表没有本机 ID —— 重跑 prepare-kit.ps1' -ForegroundColor Yellow
    Done '[阶段 2 失败] 详见上方 pnputil 输出与日志。'
}
Ok 'EXT 驱动已安装'

# ============================ 4. 等待 SWC 组件 ============================
Step '4. 重扫设备并等待 A-Volute 软件组件'

& pnputil.exe /scan-devices | Out-Null
$swcDev = $null
for ($i = 0; $i -lt 15; $i++) {
    Start-Sleep -Seconds 2
    $swcDev = Get-PnpDevice -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'SWC\VEN_AVOL*' -and $_.Status -eq 'OK' } |
        Select-Object -First 1
    if ($swcDev) { break }
}
if ($swcDev) {
    Ok ('组件已创建: ' + $swcDev.FriendlyName)
    Info ('           ' + $swcDev.InstanceId)
} else {
    Warn 'SWC 组件暂未出现，重启后通常会完成创建。'
}

# ============================ 5. 注册表权限 ============================
Step '5. 设置 Nahimic 注册表权限'

if (Test-Path 'HKLM:\SOFTWARE\Nahimic') {
    try {
        $acl = Get-Acl 'HKLM:\SOFTWARE\Nahimic'
        $rule = New-Object System.Security.AccessControl.RegistryAccessRule(
            'NT AUTHORITY\LocalService', 'FullControl',
            @('ContainerInherit', 'ObjectInherit'), 'None', 'Allow')
        $acl.SetAccessRule($rule)
        Set-Acl -Path 'HKLM:\SOFTWARE\Nahimic' -AclObject $acl
        Ok '已授予 LocalService 完全控制'
    } catch {
        Warn ('设置权限失败: ' + $_.Exception.Message)
    }
} else {
    Warn 'HKLM\SOFTWARE\Nahimic 尚不存在（驱动可能未完全生效，重启后再看）'
}

# ============================ 6. 安装应用 ============================
Step '6. 安装 Nahimic 3 应用'

if ($SkipAppx) {
    Info '已指定 -SkipAppx，跳过应用安装。'
} else {
    if (-not $AppxDir) { $AppxDir = Join-Path $KitDir 'appx' }
    if (-not (Test-Path $AppxDir)) {
        $AppxDir = $KitDir
    }
    Info ('应用目录 : ' + $AppxDir)

    $bundle = Get-ChildItem $AppxDir -Filter '*.appxbundle' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $bundle) { $bundle = Get-ChildItem $AppxDir -Filter '*.appx' -ErrorAction SilentlyContinue | Select-Object -First 1 }

    if (-not $bundle) {
        Warn ('在 ' + $AppxDir + ' 里找不到 appxbundle。')
        Warn '请把官方应用包放进该目录，或用 -AppxDir 指定路径后重跑（驱动部分已完成，不会重复装）。'
    } else {
        Info ('应用包   : ' + $bundle.Name)
        $deps = @(Get-ChildItem $AppxDir -Filter '*.appx' -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ne $bundle.Name } | Select-Object -ExpandProperty FullName)

        $installed = $false
        try {
            if ($deps.Count -gt 0) {
                Add-AppxPackage -Path $bundle.FullName -DependencyPath $deps
            } else {
                Add-AppxPackage -Path $bundle.FullName
            }
            $installed = $true
            Ok '应用安装完成'
        } catch {
            Warn ('Add-AppxPackage 失败: ' + $_.Exception.Message)
            $lic = Get-ChildItem $AppxDir -Filter '*License*.xml' -ErrorAction SilentlyContinue | Select-Object -First 1
            if (-not $lic) {
                Warn '没有找到 License xml，无法改用 DISM 预配方式。'
            } else {
                Info '改用 DISM 预配...'
                $dismArgs = @(
                    '/Online', '/Add-ProvisionedAppxPackage',
                    ('/PackagePath:' + $bundle.FullName),
                    ('/LicensePath:' + $lic.FullName)
                )
                foreach ($d in $deps) { $dismArgs += ('/DependencyPackagePath:' + $d) }
                $dismArgs += '/region:all'
                & dism.exe @dismArgs | Out-Host
                if ($LASTEXITCODE -eq 0) { $installed = $true; Ok '应用已通过 DISM 预配' }
            }
        }
        if (-not $installed) { Warn '应用未安装成功，可稍后手动安装或查看日志。' }
    }
}

# ============================ 7. 服务 ============================
Step '7. 重启音频与 Nahimic 服务'

& net.exe stop Audiosrv /y 2>&1 | Out-Null
Start-Sleep -Milliseconds 800
& net.exe start Audiosrv 2>&1 | Out-Null
Start-Sleep -Seconds 1
$svc = Get-Service -Name 'NahimicService' -ErrorAction SilentlyContinue
if ($svc) {
    if ($svc.Status -ne 'Running') {
        try { Start-Service -Name 'NahimicService' -ErrorAction Stop; Ok 'NahimicService 已启动' }
        catch { Warn ('NahimicService 启动失败: ' + $_.Exception.Message) }
    } else {
        Ok 'NahimicService 运行中'
    }
} else {
    Warn 'NahimicService 尚未创建（重启后应该会出现）'
}

# ============================ 完成 ============================
Step '完成'

Write-Host ''
Write-Host '  请重启电脑，然后验证：' -ForegroundColor Yellow
Write-Host '    1) 设备管理器 -> 软件组件 -> 应有 "A-Volute Nh4 Audio Effects Component"' -ForegroundColor White
Write-Host '    2) 服务 -> NahimicService 处于「正在运行」' -ForegroundColor White
Write-Host '    3) 开始菜单打开 Nahimic，应能识别到扬声器/耳机' -ForegroundColor White
Write-Host ''
Write-Host '  如果 App 能打开但没效果：' -ForegroundColor Yellow
Write-Host '    -> 跑 .\scripts\diagnose\dump-apo.ps1 看端点 APO 链是否挂上' -ForegroundColor White
Write-Host ''
Write-Host '  要恢复原状：.\scripts\uninstall.ps1' -ForegroundColor DarkGray
Write-Host ''

try { Stop-Transcript | Out-Null } catch { }
Read-Host '按 Enter 关闭窗口' | Out-Null
