#Requires -Version 5.1
<#
.SYNOPSIS
    环境体检（只读）。判断本机是否具备移植条件。

.DESCRIPTION
    检查项：
      1. Secure Boot 状态
      2. Realtek 编解码器与硬件 ID
      3. 子系统厂商（是否广达 152D）
      4. Realtek 音频驱动版本
      5. Realtek Audio Universal Service 状态
      6. 是否已有 Nahimic / A-Volute 残留
      7. 测试签名状态
      8. 当前播放端点的声道与 APO 链形态（影响声音追踪器可用性）

    本脚本不修改任何设置。全部为读取操作。

.EXAMPLE
    .\check-env.ps1

.NOTES
    本脚本为原创代码，MIT 许可。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Continue'

function Info($m) { Write-Host ('  ' + $m) -ForegroundColor Gray }
function Ok($m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [!] ' + $m) -ForegroundColor Yellow }
function Bad($m) { Write-Host ('  [X] ' + $m) -ForegroundColor Red }
function Step($m) { Write-Host ''; Write-Host ('== ' + $m + ' ==') -ForegroundColor Cyan }

$score = 0
$issues = New-Object System.Collections.ArrayList

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  Nahimic 移植 - 环境体检（只读）' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan

# ---------- 1. Secure Boot ----------
Step '1. Secure Boot'

$sb = $null
try { $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -Name UEFISecureBootEnabled -ErrorAction Stop).UEFISecureBootEnabled } catch { }
if ($null -eq $sb) {
    Warn '读不到 Secure Boot 状态（传统 BIOS 或非 UEFI 启动）'
    Info '若为传统 BIOS，通常不存在签名强制问题，可继续。'
} elseif ($sb -eq 1) {
    Bad 'Secure Boot = 已开启'
    Info '必须先在 BIOS 关闭，否则改签名的驱动无法装载。'
    [void]$issues.Add('需要在 BIOS 关闭 Secure Boot')
} else {
    Ok 'Secure Boot = 已关闭'
    $score++
}

# ---------- 2. 编解码器 ----------
Step '2. 音频编解码器'

$codec = $null
$bus = $null
foreach ($p in @('INTELAUDIO\FUNC_01&VEN_10EC*', 'HDAUDIO\FUNC_01&VEN_10EC*')) {
    $codec = Get-PnpDevice -Class Media -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like $p } | Select-Object -First 1
    if ($codec) { $bus = ($p -split '\\')[0]; break }
}

if (-not $codec) {
    Bad '没有找到 Realtek（VEN_10EC）音频设备'
    Info '本方案只适用于 Realtek ALC 系列，请确认声卡驱动正常。'
    [void]$issues.Add('未检测到 Realtek 声卡')
} else {
    Ok ('找到设备: ' + $codec.FriendlyName)
    Info ('实例 ID : ' + $codec.InstanceId)
    Info ('状态    : ' + $codec.Status)

    $ven = $null; $devId = $null; $subsys = $null
    if ($codec.InstanceId -match 'VEN_([0-9A-Fa-f]{4})') { $ven = $Matches[1].ToUpper() }
    if ($codec.InstanceId -match 'DEV_([0-9A-Fa-f]{4})') { $devId = $Matches[1].ToUpper() }
    if ($codec.InstanceId -match 'SUBSYS_([0-9A-Fa-f]{8})') { $subsys = $Matches[1].ToUpper() }

    if ($devId) {
        $codecName = switch ($devId) {
            '0256' { 'ALC256' }
            '0255' { 'ALC255' }
            '0269' { 'ALC269/ALC257 系列' }
            '0287' { 'ALC287' }
            '0294' { 'ALC294' }
            '0233' { 'ALC233' }
            '0295' { 'ALC295' }
            '0330' { 'ALC3306' }
            default { '未知型号 (' + $devId + ')' }
        }
        Info ('型号    : ' + $codecName + '  (DEV_' + $devId + ')')
        if ($devId -eq '0256') { $score++ } else { Warn '不是 ALC256 —— 本项目只实测过 ALC256，其他型号需自行验证' }
    }

    if ($subsys) {
        $subVendor = $subsys.Substring(0, 4)
        Info ('子系统  : SUBSYS_' + $subsys + '  (厂商 0x' + $subVendor + ')')
        if ($subVendor -eq '152D') {
            Ok '子系统厂商 = 广达（Quanta, 0x152D），与雷神猎刃 16 同族'
            $score++
        } else {
            Warn ('子系统厂商不是广达（当前 0x' + $subVendor + '）')
            Info '仍可能可用，但"同模具"假设不成立，调音与端点拓扑可能不匹配。'
            [void]$issues.Add('子系统厂商非广达，兼容性未知')
        }
    }
}

# ---------- 3. Realtek 驱动 ----------
Step '3. Realtek 音频驱动版本'

$rtkDrv = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'Realtek.*Audio' -and $_.DriverVersion } |
    Select-Object -First 1
if ($rtkDrv) {
    Ok ('驱动版本: ' + $rtkDrv.DriverVersion)
    Info ('驱动日期: ' + $rtkDrv.DriverDate)
    Info ('提供者  : ' + $rtkDrv.DriverProviderName)
} else {
    Warn '读不到 Realtek 音频驱动版本'
}

$rtkSvc = Get-Service -Name 'RtkAudioUniversalService' -ErrorAction SilentlyContinue
if ($rtkSvc) {
    if ($rtkSvc.Status -eq 'Running') { Ok 'Realtek Audio Universal Service 运行中'; $score++ }
    else {
        Warn ('Realtek Audio Universal Service 未运行（' + $rtkSvc.Status + '）')
        Info '该服务负责插孔检测与控制台，建议启动：Start-Service RtkAudioUniversalService'
        [void]$issues.Add('Realtek Audio Universal Service 未运行')
    }
} else {
    Warn '没有 Realtek Audio Universal Service（部分机型没有，可忽略）'
}

# ---------- 4. Nahimic 残留 ----------
Step '4. 检查 Nahimic / A-Volute 残留'

$residual = @()
if (Test-Path 'HKLM:\SOFTWARE\Nahimic') { $residual += '注册表 HKLM\SOFTWARE\Nahimic' }
$svcOld = Get-Service -Name 'NahimicService' -ErrorAction SilentlyContinue
if ($svcOld) { $residual += ('服务 NahimicService（' + $svcOld.Status + '）') }
$pkgOld = Get-AppxPackage -Name '*Nahimic*' -ErrorAction SilentlyContinue
if ($pkgOld) { $residual += ('应用 ' + ($pkgOld.Name -join ', ')) }
$drvOld = (& pnputil.exe /enum-drivers 2>&1 | Out-String)
if ($drvOld -match 'a-?volute|nahimic') { $residual += '驱动包（pnputil 里有 A-Volute 条目）' }

if ($residual.Count -eq 0) {
    Ok '没有检测到任何残留，干净的系统'
    $score++
} else {
    Warn '检测到以下条目：'
    foreach ($r in $residual) { Info ('  - ' + $r) }
    Info '如果是之前装过想重装，用 uninstall.ps1 清理后再装。'
    Info '如果是全新安装，这些可能是包装层残留，一般不影响。'
}

# ---------- 5. 测试签名 ----------
Step '5. 测试签名'

$bcd = & bcdedit /enum '{current}' 2>&1 | Out-String
if ($bcd -match 'testsigning\s+Yes') {
    Ok '测试签名 = 已开启'
    $score++
} else {
    Info '测试签名 = 未开启（安装脚本会自动开启并提示重启）'
}

# ---------- 6. 播放端点 ----------
Step '6. 当前可用播放端点（影响声音追踪器）'

$MM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$K_SFX = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5'
$K_C13 = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},13'
$K_EFX = '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7'
$P_NAME = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$P_DESC = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
$P_FMT = '{e4870e26-3cc5-4cd2-ba46-ca0a9a70ed04},0'

$rows = @()
foreach ($ep in (Get-ChildItem $MM -ErrorAction SilentlyContinue)) {
    $pk = Join-Path $ep.PSPath 'Properties'
    if (-not (Test-Path $pk)) { continue }
    $st = (Get-Item $ep.PSPath).GetValue('DeviceState')
    if ($null -eq $st) { $st = 0 }
    $st = [int]$st
    if (-not ((($st -band 1) -eq 1) -and (($st -band 8) -eq 0))) { continue }
    $k = Get-Item $pk

    $fmt = '?'
    $fb = $k.GetValue($P_FMT)
    if ($fb -is [byte[]] -and $fb.Length -ge 32) {
        $ch = [BitConverter]::ToUInt16($fb, 10)
        $rate = [BitConverter]::ToUInt32($fb, 12)
        $fmt = "$ch ch / $rate Hz"
    }

    $apo = '无'
    $fp = Join-Path $ep.PSPath 'FxProperties'
    if (Test-Path $fp) {
        $fx = Get-Item $fp
        $sfx = [string]$fx.GetValue($K_SFX)
        if ($sfx -match '670173') {
            if ($null -ne $fx.GetValue($K_C13)) { $apo = '复合链(,13/14/15)' }
            elseif ([string]$fx.GetValue($K_EFX) -match '670173') { $apo = '单层三段(,5/6/7)' }
            else { $apo = '单层两段(,5/6)' }
        }
    }

    # 预测雷达
    $pred = ''
    if ($apo -like '复合链*' -and $fmt -match '^2 ch') { $pred = '雷达: 只有前方' }
    elseif ($apo -ne '无') { $pred = '雷达: 期待 360' }

    $rows += [pscustomobject]@{
        Name = ([string]$k.GetValue($P_NAME) + ' / ' + [string]$k.GetValue($P_DESC))
        Fmt = $fmt
        Apo = $apo
        Pred = $pred
    }
}

if ($rows.Count -eq 0) {
    Warn '没有读取到可用端点'
} else {
    foreach ($r in $rows) {
        Write-Host ('  * ' + $r.Name) -ForegroundColor White
        Write-Host ('      ' + $r.Fmt + '   ' + $r.Apo + '   ' + $r.Pred) -ForegroundColor DarkGray
    }
    Write-Host ''
    Info '注：以上为注册表记录的端点格式，运行时实际混音格式可能为 2ch（Windows 下混）。'
    Info '    "雷达: 只有前方" 的预测来自实测规律（复合链 + 2 声道 = 方位分析失效）。'
}

# ---------- 总结 ----------
Step '结论'

Write-Host ''
if ($score -ge 5) {
    Write-Host '  ✅ 本机具备移植条件，可以继续。' -ForegroundColor Green
} elseif ($score -ge 3) {
    Write-Host '  ⚠️  基本具备条件，但存在需要注意的项目（见上）。' -ForegroundColor Yellow
} else {
    Write-Host '  ❌ 条件不足，建议先解决上面的红色项目。' -ForegroundColor Red
}

if ($issues.Count -gt 0) {
    Write-Host ''
    Write-Host '  待处理：' -ForegroundColor Yellow
    $i = 0
    foreach ($x in $issues) { $i++; Write-Host ('    ' + $i + ') ' + $x) -ForegroundColor White }
}

Write-Host ''
Write-Host '  下一步：.\scripts\prepare-kit.ps1 -KitDir <你的官方驱动目录>' -ForegroundColor DarkGray
Write-Host ''
