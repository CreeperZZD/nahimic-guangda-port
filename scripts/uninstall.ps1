#Requires -Version 5.1
<#
.SYNOPSIS
    完整卸载 Nahimic 3 移植套件，恢复到安装前状态。

.DESCRIPTION
    依次执行：
      1. 停止并删除 NahimicService
      2. 卸载 A-Volute 的 SWC / EXT 驱动包（pnputil）
      3. 清理 HKLM\SOFTWARE\Nahimic
      4. 卸载 Edge 外的 Appx 应用
      5. 清理音频端点上的 Nahimic 归属属性
      6. 可选：关闭测试签名（需再次重启）

    重要：关闭测试签名之前必须先卸载驱动，否则下次启动可能签名校验失败。

.PARAMETER KeepTestsigning
    保留测试签名模式（仍显示测试模式水印）。

.PARAMETER Force
    跳过逐项确认，直接执行。

.EXAMPLE
    .\uninstall.ps1
    .\uninstall.ps1 -KeepTestsigning -Force

.NOTES
    本脚本为原创代码，MIT 许可。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param(
    [switch]$KeepTestsigning,
    [switch]$Force
)

$ErrorActionPreference = 'Continue'

function Info($m) { Write-Host ('  ' + $m) -ForegroundColor Gray }
function Ok($m) { Write-Host ('  [OK] ' + $m) -ForegroundColor Green }
function Warn($m) { Write-Host ('  [!] ' + $m) -ForegroundColor Yellow }
function Fail($m) { Write-Host ('  [X] ' + $m) -ForegroundColor Red }
function Step($m) { Write-Host ''; Write-Host ('== ' + $m + ' ==') -ForegroundColor Cyan }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Fail '需要管理员权限。请右键「以管理员身份运行」。'
    Read-Host '按 Enter 关闭窗口' | Out-Null
    exit 1
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  Nahimic 3 移植套件 - 卸载' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''

if (-not $Force) {
    Write-Host '  将执行以下操作：' -ForegroundColor Yellow
    Write-Host '    - 删除 NahimicService 服务' -ForegroundColor White
    Write-Host '    - 卸载 A-Volute 驱动包' -ForegroundColor White
    Write-Host '    - 删除 HKLM\SOFTWARE\Nahimic' -ForegroundColor White
    Write-Host '    - 卸载 Nahimic UWP 应用' -ForegroundColor White
    Write-Host '    - 清理音频端点上的 Nahimic 属性' -ForegroundColor White
    if (-not $KeepTestsigning) { Write-Host '    - 关闭测试签名（需重启）' -ForegroundColor White }
    Write-Host ''
    $ans = Read-Host '  确认卸载？(y/N)'
    if ($ans -ne 'y' -and $ans -ne 'Y') { Info '已取消，未做任何修改。'; exit 0 }
}

# ---------- 1. 服务 ----------
Step '1. 停止并删除 NahimicService'

$svc = Get-Service -Name 'NahimicService' -ErrorAction SilentlyContinue
if ($svc) {
    try { Stop-Service -Name 'NahimicService' -Force -ErrorAction Stop; Ok '已停止' } catch { Info '服务未在运行' }
    # 同时结束进程
    foreach ($n in @('NahimicService', 'NahimicSvc32', 'NahimicSvc64', 'NhNotifSys')) {
        Get-Process -Name $n -ErrorAction SilentlyContinue | ForEach-Object {
            try { $_.Kill(); Info ('结束进程 ' + $n) } catch { }
        }
    }
    & sc.exe delete NahimicService 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) { Ok '服务已删除' } else { Info '服务删除返回非 0（可能已不存在）' }
} else {
    Info '没有 NahimicService，跳过'
}

# ---------- 2. 驱动包 ----------
Step '2. 卸载 A-Volute 驱动包'

$drivers = & pnputil.exe /enum-drivers 2>&1 | Out-String
$blocks = $drivers -split "(?m)^\s*$"
$removed = 0
foreach ($b in $blocks) {
    if ($b -notmatch 'a-?volute|nahimic') { continue }
    if ($b -match 'Published Name\s*:\s*(oem\d+\.inf)') {
        $oemInf = $Matches[1]
        Info ('卸载 ' + $oemInf + ' ...')
        & pnputil.exe /delete-driver $oemInf /uninstall /force 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok ($oemInf + ' 已卸载'); $removed++ }
        else { Warn ($oemInf + ' 卸载返回 ' + $LASTEXITCODE) }
    }
}
if ($removed -eq 0) { Info '没有找到已安装的 A-Volute 驱动包' }

# ---------- 3. 注册表 ----------
Step '3. 清理注册表'

if (Test-Path 'HKLM:\SOFTWARE\Nahimic') {
    try {
        Remove-Item 'HKLM:\SOFTWARE\Nahimic' -Recurse -Force -ErrorAction Stop
        Ok 'HKLM\SOFTWARE\Nahimic 已删除'
    } catch { Warn ('删除失败: ' + $_.Exception.Message + '（可能需重启后再删）') }
} else { Info '注册表项不存在，跳过' }

# ---------- 4. 应用 ----------
Step '4. 卸载 Nahimic 应用'

$pkgs = Get-AppxPackage -Name '*Nahimic*' -ErrorAction SilentlyContinue
if ($pkgs) {
    foreach ($p in $pkgs) {
        Info ('移除 ' + $p.Name + ' ' + $p.Version)
        try { Remove-AppxPackage -Package $p.PackageFullName -ErrorAction Stop; Ok '已移除' }
        catch { Warn ('移除失败: ' + $_.Exception.Message) }
    }
} else { Info '没有安装 Nahimic 应用' }

# ---------- 5. 端点属性 ----------
Step '5. 清理音频端点上的 Nahimic 属性'

$MM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$cleaned = 0
foreach ($ep in (Get-ChildItem $MM -ErrorAction SilentlyContinue)) {
    $pk = Join-Path $ep.PSPath 'Properties'
    if (-not (Test-Path $pk)) { continue }
    try {
        $k = Get-Item $pk
        $mark = [string]$k.GetValue('{f363df17-a750-4ac3-b7b5-2bbeffa9085f},11')
        if ($mark -match 'Nahimic|A-Volute') {
            Remove-ItemProperty -Path $pk -Name '{f363df17-a750-4ac3-b7b5-2bbeffa9085f},11' -Force -ErrorAction SilentlyContinue
            $cleaned++
        }
    } catch { }
    # FxProperties 里的 Nahimic APO 键
    $fp = Join-Path $ep.PSPath 'FxProperties'
    if (Test-Path $fp) {
        try {
            $fx = Get-Item $fp
            foreach ($n in @(
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},5',
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},6',
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},7',
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},13',
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},14',
                '{d04e05a6-594b-4fb6-a80d-01af5eed7d1d},15'
            )) {
                $v = $fx.GetValue($n)
                if ($null -eq $v) { continue }
                $isNah = $false
                if ($v -is [array]) { foreach ($x in $v) { if ("$x" -match '670173') { $isNah = $true } } }
                elseif ("$v" -match '670173') { $isNah = $true }
                if ($isNah) {
                    Remove-ItemProperty -Path $fp -Name $n -Force -ErrorAction SilentlyContinue
                    $cleaned++
                }
            }
        } catch { }
    }
}
if ($cleaned -gt 0) { Ok ('已清理 ' + $cleaned + ' 处端点属性') } else { Info '端点上没有 Nahimic 残留' }

# ---------- 6. 测试签名 ----------
Step '6. 测试签名'

if ($KeepTestsigning) {
    Info '已指定 -KeepTestsigning，保留测试签名模式。'
} else {
    $bcd = & bcdedit /enum '{current}' 2>&1 | Out-String
    if ($bcd -match 'testsigning\s+Yes') {
        & bcdedit /set testsigning off 2>&1 | Out-Null
        if ($LASTEXITCODE -eq 0) { Ok '测试签名已关闭（重启后生效，水印消失）' }
        else { Warn '关闭测试签名失败（Secure Boot 可能已开启）' }
    } else {
        Info '测试签名本来就是关闭的'
    }
}

# ---------- 完成 ----------
Step '完成'

Write-Host ''
Write-Host '  建议重启电脑完成清理。' -ForegroundColor Yellow
Write-Host '  重启后检查：' -ForegroundColor White
Write-Host '    - 设备管理器 -> 软件组件 -> 不应再有 A-Volute 组件' -ForegroundColor White
Write-Host '    - 服务 -> 不应再有 NahimicService' -ForegroundColor White
Write-Host ''
if (-not $KeepTestsigning) {
    Write-Host '  如果重启后进不了系统：' -ForegroundColor Yellow
    Write-Host '    开机连续强制关机 3 次进入恢复环境 -> 疑难解答 -> 高级选项 -> 启动设置 ->' -ForegroundColor White
    Write-Host '    重启后按 7 禁用驱动程序签名强制，进去后重跑本脚本。' -ForegroundColor White
    Write-Host ''
}
Read-Host '按 Enter 关闭窗口' | Out-Null
