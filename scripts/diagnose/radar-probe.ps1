#Requires -Version 5.1
<#
.SYNOPSIS
    声音追踪器（Sound Tracker）方向探测（只读）。验证雷达是否真的在输出方位数据。

.DESCRIPTION
    Nahimic 把雷达数据写在注册表里：
      HKLM\SOFTWARE\Nahimic\A-Volute.Nahimic\{703F89B6-...}\{752EDE94-...}\*
    共 24 个值，每个 8 字节 = 两个 float32（偏移 0 = 当前电平，偏移 4 = 峰值）。
    本脚本解析这些值，报告"有能量的方向数"。

    用法：
      1. 先开着音乐/游戏（要有真实内容的方位信息）
      2. 运行本脚本，默认连续采样 15 次
      3. 观察方向数变化

.PARAMETER Count
    采样次数，默认 15。

.PARAMETER IntervalMs
    采样间隔毫秒，默认 700。

.PARAMETER Threshold
    判定"有能量"的电平阈值，默认 0.08。

.EXAMPLE
    .\radar-probe.ps1
    .\radar-probe.ps1 -Count 30 -IntervalMs 500

.NOTES
    判读：
      - 静音时方向数应为 0（否则是残留）
      - 放音乐/游戏时方向数 >= 3 说明方位分析在工作
      - 一直只有 1 个方向，说明端点组合不支持（见 docs/02）
    本脚本为原创代码，MIT 许可。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param(
    [int]$Count = 15,
    [int]$IntervalMs = 700,
    [double]$Threshold = 0.08
)

$ErrorActionPreference = 'Continue'

$RADAR_ROOT = 'HKLM:\SOFTWARE\Nahimic\A-Volute.Nahimic\{703F89B6-57E8-4B2D-A4C1-F56E236D64FA}'

function Get-Radar {
    $best = 0
    $peak = 0.0
    $detail = @()
    if (-not (Test-Path $RADAR_ROOT)) { return $null }
    $subs = @(Get-ChildItem $RADAR_ROOT -Recurse -ErrorAction SilentlyContinue) + @(Get-Item $RADAR_ROOT)
    foreach ($s in $subs) {
        $pp = $null
        try { $pp = Get-ItemProperty $s.PSPath -ErrorAction SilentlyContinue } catch { }
        if (-not $pp) { continue }
        $n = 0
        $lp = 0.0
        $vals = @()
        foreach ($prop in $pp.PSObject.Properties) {
            if ($prop.Name -notmatch '0CA8E8B0') { continue }
            $v = $prop.Value
            if (-not ($v -is [byte[]]) -or $v.Length -ne 8) { continue }
            $f = [BitConverter]::ToSingle($v, 0)
            if ([float]::IsNaN($f) -or [float]::IsInfinity($f)) { continue }
            if ($f -lt 0) { continue }
            $vals += $f
            if ($f -gt $lp) { $lp = $f }
            if ($f -gt $Threshold) { $n++ }
        }
        if ($n -gt $best) { $best = $n; $detail = $vals }
        if ($lp -gt $peak) { $peak = $lp }
    }
    return [pscustomobject]@{ Dir = $best; Peak = $peak; Vals = $detail }
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  声音追踪器方向探测（只读）' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''

if (-not (Test-Path $RADAR_ROOT)) {
    Write-Host '  [X] 找不到 Nahimic 雷达数据源。' -ForegroundColor Red
    Write-Host ''
    Write-Host '  可能原因：' -ForegroundColor Yellow
    Write-Host '    1. Nahimic 未安装或服务未运行' -ForegroundColor White
    Write-Host '    2. 应用里从未打开过「声音追踪器」，数据源节点尚未创建' -ForegroundColor White
    Write-Host ''
    Write-Host '  处理：打开 Nahimic -> 声音追踪器 -> 点「体验」，然后再运行本脚本。' -ForegroundColor White
    Write-Host ''
    exit 1
}

Write-Host ('  数据源: ' + $RADAR_ROOT) -ForegroundColor DarkGray
Write-Host ('  阈值  : ' + $Threshold + '    采样 ' + $Count + ' 次 / ' + $IntervalMs + ' ms') -ForegroundColor DarkGray
Write-Host ''
Write-Host '  提示：请确保正在播放带方位信息的真实内容（游戏、音乐），' -ForegroundColor Yellow
Write-Host '        纯合成测试音本身没有方位，只会显示 1 个方向。' -ForegroundColor Yellow
Write-Host ''

$maxDir = 0
$maxPeak = 0.0
$allOne = $true

for ($i = 1; $i -le $Count; $i++) {
    $r = Get-Radar
    if (-not $r) { break }
    $ts = (Get-Date).ToString('HH:mm:ss')
    $bar = ''
    if ($r.Dir -gt 0) { $bar = ('#' * [math]::Min($r.Dir, 24)) }
    Write-Host ('  [' + $ts + ']  方向 ' + $r.Dir.ToString().PadLeft(2) + '   峰值 ' + $r.Peak.ToString('F3') + '  ' + $bar) -ForegroundColor Gray

    if ($r.Dir -gt $maxDir) { $maxDir = $r.Dir }
    if ($r.Peak -gt $maxPeak) { $maxPeak = $r.Peak }
    if ($r.Dir -gt 1) { $allOne = $false }

    if ($i -lt $Count) { Start-Sleep -Milliseconds $IntervalMs }
}

Write-Host ''
Write-Host '─────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ('  最大方向数: ' + $maxDir) -ForegroundColor Cyan
Write-Host ('  最大电平  : ' + $maxPeak.ToString('F3')) -ForegroundColor Cyan
Write-Host ''

if ($maxPeak -le 0.001) {
    Write-Host '  ❌ 完全没有数据。' -ForegroundColor Red
    Write-Host '     -> 雷达未启用，或当前没有音频在播。' -ForegroundColor White
    Write-Host '     -> 打开 Nahimic -> 声音追踪器 -> 体验，再试。' -ForegroundColor White
} elseif ($maxDir -le 1) {
    Write-Host '  ⚠️  只有 0~1 个方向。' -ForegroundColor Yellow
    Write-Host '     若此时确实在放游戏/音乐，说明方位分析没生效：' -ForegroundColor White
    Write-Host '     检查端点是否为「2 声道 + 复合链」组合（见 docs/02）。' -ForegroundColor White
    Write-Host '     换 USB 声卡或内置扬声器可恢复到 360。' -ForegroundColor White
} elseif ($maxDir -le 3) {
    Write-Host '  ⚠️  有少量方向（' + $maxDir + ' 个）。' -ForegroundColor Yellow
    Write-Host '     可能是内容本身方位有限（如立体声音乐），建议用游戏或体验功能复测。' -ForegroundColor White
} else {
    Write-Host '  ✅ 方位分析正常工作（最多 ' + $maxDir + ' 个方向同时有能量）。' -ForegroundColor Green
}

Write-Host ''
