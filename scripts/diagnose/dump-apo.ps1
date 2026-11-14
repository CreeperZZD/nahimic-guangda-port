#Requires -Version 5.1
<#
.SYNOPSIS
    导出音频端点的 APO 链与格式（只读），用于排错。

.DESCRIPTION
    对每个播放端点输出：
      - 设备状态、端点格式（声道/采样率/位深）
      - FxProperties 里所有 APO 相关键（d04e05a6 / d3993a3f / fedcc54d）
      - 归属标记 PKEY_PRODUCTID
      - 由此推断的声音追踪器可用性

.PARAMETER ShowRaw
    同时输出 WAVEFORMATEXTENSIBLE 的原始字节（十六进制）。

.PARAMETER All
    显示全部端点（包括无权访问、未连接、无 Nahimic 链的历史残留）。
    默认只显示「可用端点」与「挂有 Nahimic APO 的端点」。

.EXAMPLE
    .\dump-apo.ps1
    .\dump-apo.ps1 -All -ShowRaw | Out-File apo.txt

.NOTES
    本脚本为原创代码，MIT 许可。
    侵权投诉请联系 1876536805@qq.com
#>
[CmdletBinding()]
param(
    [switch]$ShowRaw,
    [switch]$All
)

$ErrorActionPreference = 'Continue'

$MM = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$P_NAME = '{a45c254e-df1c-4efd-8020-67d146a850e0},2'
$P_DESC = '{b3f8fa53-0004-438e-9003-51a46e139bfc},6'
$P_FMT = '{e4870e26-3cc5-4cd2-ba46-ca0a9a70ed04},0'
$P_MARK = '{f363df17-a750-4ac3-b7b5-2bbeffa9085f},11'
$P_FF = '{1da5d803-d492-4edd-8c23-e0c0ffee7f0e},0'

# 已知 CLSID 名称表（便于人读）
$known = @{
    '{670173E3-78CF-11E5-A837-0800200C9A66}' = 'Nahimic SFX'
    '{670173E4-78CF-11E5-A837-0800200C9A66}' = 'Nahimic MFX'
    '{670173E5-78CF-11E5-A837-0800200C9A66}' = 'Nahimic EFX'
    '{670173F4-78CF-11E5-A837-0800200C9A66}' = 'Nahimic (variant)'
    '{DA2C9ECE-7418-4906-B4FA-0A00B3EB88AA}' = 'Nahimic wrapper(SFX)'
    '{A296D363-EE83-4AF9-9BE7-729C1296150A}' = 'Nahimic wrapper(MFX)'
    '{A29EB043-6CE2-4EE2-B38C-F58719E0D88F}' = 'Nahimic wrapper(EFX)'
    '{C18E2F7E-933D-4965-B7D1-1EEF228D2AF3}' = 'Nahimic co-install'
    '{D7D659E7-E415-41D7-848C-2A69C2B1EE0E}' = 'Razer SFX'
    '{C57DD664-CB0F-4D5E-B5D8-851AFB2CA685}' = 'Razer MFX'
    '{4B7758E3-9361-4F88-83E9-44D8F05184EF}' = 'SteelSeries EFX'
    '{71111103-AC62-4939-B476-4BB282B2B42C}' = 'OEM provider A'
    '{7121B512-6CC5-4C77-AE3A-823F966CCD3D}' = 'OEM provider B'
}

function Resolve-Clsid([string]$s) {
    if (-not $s) { return '' }
    $out = $s
    foreach ($k in $known.Keys) {
        $out = $out -replace [regex]::Escape($k), ($known[$k] + '[' + $k.Substring(0, 9) + ']')
        $out = $out -replace [regex]::Escape($k.ToLower()), ($known[$k] + '[' + $k.Substring(0, 9) + ']')
    }
    return $out
}

function Parse-Fmt([byte[]]$b) {
    if ($null -eq $b -or $b.Length -lt 32) { return $null }
    # 端点设备格式一般带 8 字节 PROPVARIANT 头
    $off = 0
    if ($b.Length -ge 40 -and [BitConverter]::ToUInt16($b, 0) -ne 0xFFFE) { $off = 8 }
    if ($b.Length -lt ($off + 26)) { return $null }
    return [pscustomobject]@{
        Tag = [BitConverter]::ToUInt16($b, $off)
        Ch = [BitConverter]::ToUInt16($b, $off + 2)
        Rate = [BitConverter]::ToUInt32($b, $off + 4)
        Bits = [BitConverter]::ToUInt16($b, $off + 14)
        Mask = $(if ($b.Length -ge ($off + 26)) { [BitConverter]::ToUInt32($b, $off + 20) } else { 0 })
    }
}

Write-Host ''
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host '  音频端点 APO 链导出（只读）' -ForegroundColor Cyan
Write-Host '=====================================================' -ForegroundColor Cyan
Write-Host ''
Write-Host ('  时间: ' + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')) -ForegroundColor DarkGray

$eps = @(Get-ChildItem $MM -ErrorAction SilentlyContinue)
Write-Host ('  端点总数: ' + $eps.Count) -ForegroundColor DarkGray

$activeCount = 0
foreach ($ep in $eps) {
    $pk = Join-Path $ep.PSPath 'Properties'
    if (-not (Test-Path $pk)) { continue }
    $k = Get-Item $pk

    $st = (Get-Item $ep.PSPath).GetValue('DeviceState')
    if ($null -eq $st) { $st = 0 }
    $st = [int]$st
    $isActive = ((($st -band 1) -eq 1) -and (($st -band 8) -eq 0))
    if ($isActive) { $activeCount++ }

    $name = [string]$k.GetValue($P_NAME)
    $desc = [string]$k.GetValue($P_DESC)
    $ff = $k.GetValue($P_FF)
    $mark = [string]$k.GetValue($P_MARK)

    # 判断 FxProperties 里有没有真正的 Nahimic APO
    # 只看 d04e05a6 的 5/6/7/13/14/15 这几个「APO 槽位」，不看 d3993a3f 的共装标记
    $fp = Join-Path $ep.PSPath 'FxProperties'
    $hasNah = $false
    $coInstall = $false
    if (Test-Path $fp) {
        $fxItem = Get-Item $fp
        foreach ($n in $fxItem.GetValueNames()) {
            $v = $fxItem.GetValue($n)
            $s = ''
            if ($v -is [array]) { $s = $v -join ' ' } else { $s = "$v" }
            if ($n -match '^\{d04e05a6' -and $n -match ',(5|6|7|13|14|15)$' -and $s -match '670173') {
                $hasNah = $true
            }
            if ($n -match '^\{d3993a3f' -and $s -match 'C18E2F7E') {
                $coInstall = $true
            }
        }
    }

    # 默认过滤：只显示可用端点，或真正挂了 Nahimic APO 的端点
    if (-not $All) {
        if (-not $isActive -and -not $hasNah) { continue }
    }

    Write-Host ''

    Write-Host ''
    $stateTxt = if ($isActive) { '可用' } else { '不可用(0x' + $st.ToString('X') + ')' }
    Write-Host ('─────────────────────────────────────────────────────') -ForegroundColor DarkGray
    Write-Host ('  ' + $name + ' / ' + $desc) -ForegroundColor Cyan
    Write-Host ('  GUID: ' + $ep.PSChildName) -ForegroundColor DarkGray
    Write-Host ('  状态: ' + $stateTxt + '   FormFactor: ' + $ff) -ForegroundColor Gray

    $fmtBytes = $k.GetValue($P_FMT)
    $f = Parse-Fmt $fmtBytes
    if ($f) {
        $predCh = if ($f.Ch -eq 2) { '2 声道' } elseif ($f.Ch -eq 6) { '5.1' } elseif ($f.Ch -eq 8) { '7.1' } else { ($f.Ch.ToString() + ' 声道') }
        Write-Host ('  格式: ' + $f.Ch + ' ch (' + $predCh + ') / ' + $f.Rate + ' Hz / ' + $f.Bits + ' bit  mask=0x' + $f.Mask.ToString('X')) -ForegroundColor Gray
    } else {
        Write-Host '  格式: (读不到)' -ForegroundColor Gray
    }
    if ($mark) { Write-Host ('  归属: ' + $mark) -ForegroundColor Gray }

    if (Test-Path $fp) {
        $fx = Get-Item $fp
        # 只显示 APO 槽位（d04e05a6 与 fedcc54d），co-install 标记单独汇总
        $names = $fx.GetValueNames() | Where-Object { $_ -match '^\{d04e05a6|^\{fedcc54d' } | Sort-Object
        if ($names) {
            Write-Host '  APO 链:' -ForegroundColor Yellow
            foreach ($n in $names) {
                $v = $fx.GetValue($n)
                $tail = $n.Substring($n.LastIndexOf(',') + 1)
                $txt = ''
                if ($v -is [array]) { $txt = ($v -join ' | ') } else { $txt = [string]$v }
                if (-not $txt) { continue }
                if ($txt -match '^\{00000000-0000-0000-0000-000000000000\}$') { continue }
                Write-Host ('      ,' + $tail.PadLeft(2) + ' = ' + (Resolve-Clsid $txt)) -ForegroundColor Gray
            }
        } else {
            Write-Host '  APO 链: (无 APO 槽位)' -ForegroundColor DarkGray
        }
        if ($coInstall) {
            Write-Host '  共装标记: {C18E2F7E} 已写入（EXT 驱动正常工作）' -ForegroundColor DarkGray
        }
        if ($hasNah) {
            Write-Host '  结论: Nahimic 已挂入此端点' -ForegroundColor DarkGreen
        }
    } else {
        Write-Host '  APO 链: (无 FxProperties)' -ForegroundColor DarkGray
    }

    if ($ShowRaw -and $fmtBytes -is [byte[]]) {
        $hex = ($fmtBytes | ForEach-Object { $_.ToString('X2') }) -join ' '
        Write-Host ('  原始: ' + $hex) -ForegroundColor DarkGray
    }
}

# 汇总
Write-Host ''
Write-Host '─────────────────────────────────────────────────────' -ForegroundColor DarkGray
Write-Host ('  可用端点: ' + $activeCount) -ForegroundColor Gray
Write-Host ''
Write-Host '  判读参考：' -ForegroundColor Yellow
Write-Host '    Nahimic SFX/MFX 已挂 + 端点 6ch/8ch           -> 音效正常，雷达期待 360' -ForegroundColor White
Write-Host '    Nahimic SFX/MFX 已挂 + 端点 2ch + 单层三段链  -> 音效正常，雷达期待 360' -ForegroundColor White
Write-Host '    Nahimic SFX/MFX 已挂 + 端点 2ch + 复合链      -> 音效正常，雷达只有前方' -ForegroundColor White
Write-Host '    没有 Nahimic 键                              -> 音效不生效，需重装或检查驱动' -ForegroundColor White
Write-Host ''
